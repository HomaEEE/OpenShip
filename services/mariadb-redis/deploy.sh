#!/usr/bin/env bash

# ==============================================================================
# OpenShip Shared Infrastructure Deployment Script (MariaDB + Redis + phpMyAdmin)
# ==============================================================================
#
# Idempotent deployer for production MariaDB 11.4 LTS, Redis 7.4, and phpMyAdmin
# configured with static IPs on the shared 'openship' Docker network (172.20.0.0/16),
# inter-bridge kernel routing, and auto-attacher service for automatic container DNS.
#
# ==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log()     { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}=== $* ===${NC}"; }

require_root_or_docker() {
    if ! command -v docker &>/dev/null; then
        error "Docker is required but not installed. Please install Docker first."
        exit 1
    fi

    if [[ $EUID -ne 0 ]] && ! groups | grep -q ' docker '; then
        error "Permission denied. Run with sudo or add your user to the 'docker' group."
        exit 1
    fi
}

ensure_docker_and_compose() {
    if ! docker compose version &>/dev/null; then
        error "Docker Compose v2 plugin is required ('docker compose')."
        exit 1
    fi
}

ensure_docker_network() {
    local net_name="${OPENSHIP_NETWORK:-openship-mariadb}"
    local subnet="${OPENSHIP_SUBNET:-172.20.0.0/16}"
    local gateway="${OPENSHIP_GATEWAY:-172.20.0.1}"

    if ! docker network inspect "$net_name" &>/dev/null; then
        log "Creating shared user-defined Docker network '${net_name}' (${subnet}, gw: ${gateway})..."
        docker network create \
            --driver bridge \
            --subnet "$subnet" \
            --gateway "$gateway" \
            --opt "com.docker.network.bridge.enable_icc=true" \
            "$net_name"
        success "Network '${net_name}' created (internal Docker DNS & static IP active)."
    else
        local existing_subnet
        existing_subnet="$(docker network inspect "$net_name" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)"
        if [[ -n "$existing_subnet" && "$existing_subnet" != "$subnet" ]]; then
            local attached_count
            attached_count="$(docker network inspect "$net_name" --format '{{len .Containers}}' 2>/dev/null || echo 0)"
            if (( attached_count == 0 )); then
                log "Re-creating empty network '${net_name}' with required subnet ${subnet}..."
                docker network rm "$net_name" >/dev/null 2>&1 || true
                docker network create \
                    --driver bridge \
                    --subnet "$subnet" \
                    --gateway "$gateway" \
                    --opt "com.docker.network.bridge.enable_icc=true" \
                    "$net_name"
                success "Network '${net_name}' re-created with subnet ${subnet}."
            else
                warn "Network '${net_name}' has subnet '${existing_subnet}' with active containers. Keeping network."
            fi
        else
            log "Using existing Docker network '${net_name}' (${subnet})."
        fi
    fi
}

ensure_inter_bridge_routing() {
    local subnet="${OPENSHIP_SUBNET:-172.20.0.0/16}"
    log "Configuring inter-bridge firewall routing for ${subnet}..."

    if command -v iptables &>/dev/null; then
        if ! iptables -C FORWARD -d "$subnet" -j ACCEPT 2>/dev/null; then
            iptables -I FORWARD 1 -d "$subnet" -j ACCEPT 2>/dev/null || true
        fi
        if ! iptables -C FORWARD -s "$subnet" -j ACCEPT 2>/dev/null; then
            iptables -I FORWARD 2 -s "$subnet" -j ACCEPT 2>/dev/null || true
        fi
    fi

    # Persist in UFW /etc/ufw/after.rules if UFW is configured
    if [[ -f /etc/ufw/after.rules ]]; then
        if ! grep -q "OpenShip inter-bridge routing" /etc/ufw/after.rules 2>/dev/null; then
            log "Persisting inter-bridge routing in /etc/ufw/after.rules..."
            sed -i "/^COMMIT/i # OpenShip inter-bridge routing\n-A ufw-after-forward -d ${subnet} -j ACCEPT\n-A ufw-after-forward -s ${subnet} -j ACCEPT\n" /etc/ufw/after.rules 2>/dev/null || true
            if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
                ufw reload >/dev/null 2>&1 || true
            fi
        fi
    fi
    success "Inter-bridge routing active for ${subnet}."
}

ensure_auto_attacher_service() {
    local net_name="${OPENSHIP_NETWORK:-openship-mariadb}"
    local attacher_src="${SCRIPT_DIR}/openship-network-attacher.sh"
    local attacher_bin="/usr/local/bin/openship-network-attacher"
    local unit_file="/etc/systemd/system/openship-network-attacher.service"

    section "Configuring OpenShip Network Auto-Attacher"

    if [[ ! -f "$attacher_src" ]]; then
        warn "Source script not found at ${attacher_src}. Skipping auto-attacher service setup."
        return 0
    fi

    if [[ $EUID -eq 0 ]]; then
        cp -f "$attacher_src" "$attacher_bin"
        chmod +x "$attacher_bin"

        cat > "$unit_file" <<EOF
[Unit]
Description=OpenShip Shared Network Auto-Attacher
After=docker.service
Requires=docker.service

[Service]
Type=simple
Environment="OPENSHIP_NETWORK=${net_name}"
ExecStart=${attacher_bin}
Restart=always
RestartSec=3s
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

        if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
            systemctl daemon-reload
            systemctl enable --now openship-network-attacher.service >/dev/null 2>&1 || true
            if systemctl is-active --quiet openship-network-attacher.service; then
                success "Auto-attacher active: containers with name 'openship-*' will automatically join '${net_name}'."
            else
                warn "Auto-attacher service created but not running. Check: systemctl status openship-network-attacher.service"
            fi
        else
            log "systemd not available; auto-attacher binary installed to ${attacher_bin}."
        fi
    else
        warn "Root permissions required to install systemd auto-attacher service (run with sudo to enable)."
    fi
}

tune_mariadb_buffer_pool() {
    local mem_total_mb=2048
    if [[ -f /proc/meminfo ]]; then
        mem_total_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 2048)"
    fi

    local pool_mb=256
    if (( mem_total_mb <= 2048 )); then
        pool_mb=128
    elif (( mem_total_mb <= 4096 )); then
        pool_mb=256
    elif (( mem_total_mb <= 8192 )); then
        pool_mb=512
    else
        pool_mb=1024
    fi
    MARIADB_BUFFER_POOL_SIZE="${pool_mb}M"
    log "Optimized MariaDB innodb_buffer_pool_size = ${MARIADB_BUFFER_POOL_SIZE} for ${mem_total_mb}MB host RAM."
}

configure_environment() {
    local cli_pma="${1:-}"
    section "Configuring Environment (.env)"

    tune_mariadb_buffer_pool

    if [[ ! -f "$ENV_FILE" ]]; then
        if [[ -f "$ENV_EXAMPLE" ]]; then
            cp "$ENV_EXAMPLE" "$ENV_FILE"
        fi
    fi

    # Read current values if present
    local maria_pass redis_pass maria_ver redis_ver maria_pool pma_ver pma_port pma_limit redis_policy net_name enable_pma
    local net_subnet net_gw maria_ip redis_ip pma_ip
    maria_ver="$(grep -E '^MARIADB_VERSION=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '11.4')"
    redis_ver="$(grep -E '^REDIS_VERSION=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '7.4-alpine')"
    maria_pass="$(grep -E '^MARIADB_ROOT_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || true)"
    [[ -z "$maria_pass" ]] && maria_pass="$(grep -E '^DB_ROOT_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || true)"
    redis_pass="$(grep -E '^REDIS_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || true)"
    maria_pool="$(grep -E '^MARIADB_BUFFER_POOL_SIZE=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo "${MARIADB_BUFFER_POOL_SIZE}")"
    pma_ver="$(grep -E '^PHPMYADMIN_VERSION=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo 'latest')"
    pma_port="$(grep -E '^PHPMYADMIN_PORT=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '20003')"
    pma_limit="$(grep -E '^PHPMYADMIN_MEMORY_LIMIT=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '256M')"
    redis_policy="$(grep -E '^REDIS_MAXMEMORY_POLICY=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo 'noeviction')"
    net_name="$(grep -E '^OPENSHIP_NETWORK=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo 'openship-mariadb')"
    net_subnet="$(grep -E '^OPENSHIP_SUBNET=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '172.20.0.0/16')"
    net_gw="$(grep -E '^OPENSHIP_GATEWAY=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '172.20.0.1')"
    maria_ip="$(grep -E '^MARIADB_STATIC_IP=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '172.20.0.10')"
    redis_ip="$(grep -E '^REDIS_STATIC_IP=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '172.20.0.11')"
    pma_ip="$(grep -E '^PHPMYADMIN_STATIC_IP=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '172.20.0.12')"
    enable_pma="$(grep -E '^ENABLE_PHPMYADMIN=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo "${ENABLE_PHPMYADMIN:-true}")"

    [[ -z "$maria_ver" ]] && maria_ver="11.4"
    [[ -z "$redis_ver" ]] && redis_ver="7.4-alpine"
    [[ -z "$maria_pool" ]] && maria_pool="${MARIADB_BUFFER_POOL_SIZE}"
    [[ -z "$pma_ver" ]] && pma_ver="latest"
    [[ -z "$pma_port" ]] && pma_port="20003"
    [[ -z "$pma_limit" ]] && pma_limit="256M"
    [[ -z "$redis_policy" ]] && redis_policy="noeviction"
    [[ -z "$net_name" ]] && net_name="openship-mariadb"
    [[ -z "$net_subnet" ]] && net_subnet="172.20.0.0/16"
    [[ -z "$net_gw" ]] && net_gw="172.20.0.1"
    [[ -z "$maria_ip" ]] && maria_ip="172.20.0.10"
    [[ -z "$redis_ip" ]] && redis_ip="172.20.0.11"
    [[ -z "$pma_ip" ]] && pma_ip="172.20.0.12"

    # Resolve phpMyAdmin toggle (CLI flag > ENV var > existing .env > default true)
    if [[ -n "$cli_pma" ]]; then
        enable_pma="$cli_pma"
    elif [[ -n "${ENABLE_PHPMYADMIN:-}" ]]; then
        enable_pma="${ENABLE_PHPMYADMIN}"
    fi

    if [[ -z "$enable_pma" ]]; then
        enable_pma="true"
    fi

    if [[ "$enable_pma" == "true" || "$enable_pma" == "yes" || "$enable_pma" == "1" ]]; then
        enable_pma="true"
    else
        enable_pma="false"
    fi

    if [[ -z "$maria_pass" ]]; then
        if [[ -t 0 ]]; then
            while [[ -z "$maria_pass" ]]; do
                read -r -s -p "Enter MariaDB root password: " maria_pass
                echo
                if [[ -z "$maria_pass" ]]; then
                    warn "MariaDB root password cannot be empty."
                fi
            done
        else
            error "MARIADB_ROOT_PASSWORD is required. Set it in ${ENV_FILE} or environment."
            exit 1
        fi
    fi

    if [[ -z "$redis_pass" ]]; then
        if [[ -t 0 ]]; then
            while [[ -z "$redis_pass" ]]; do
                read -r -s -p "Enter Redis password: " redis_pass
                echo
                if [[ -z "$redis_pass" ]]; then
                    warn "Redis password cannot be empty."
                fi
            done
        else
            error "REDIS_PASSWORD is required. Set it in ${ENV_FILE} or environment."
            exit 1
        fi
    fi

    cat > "$ENV_FILE" <<EOF
# OpenShip Shared Services — MariaDB + Redis + phpMyAdmin
# Generated on: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

DB_ROOT_PASSWORD=${maria_pass}
MARIADB_VERSION=${maria_ver}
MARIADB_ROOT_PASSWORD=${maria_pass}
MARIADB_BUFFER_POOL_SIZE=${maria_pool}
MARIADB_MEMORY_LIMIT=1024M

REDIS_VERSION=${redis_ver}
REDIS_PASSWORD=${redis_pass}
REDIS_MAXMEMORY=256mb
REDIS_MAXMEMORY_POLICY=${redis_policy}
REDIS_MEMORY_LIMIT=512M

ENABLE_PHPMYADMIN=${enable_pma}
PHPMYADMIN_VERSION=${pma_ver}
PHPMYADMIN_HOST=mariadb
PHPMYADMIN_PORT=${pma_port}
PHPMYADMIN_BIND_IP=127.0.0.1
PHPMYADMIN_UPLOAD_LIMIT=512M
PHPMYADMIN_MEMORY_LIMIT=${pma_limit}

OPENSHIP_NETWORK=${net_name}
OPENSHIP_SUBNET=${net_subnet}
OPENSHIP_GATEWAY=${net_gw}
MARIADB_STATIC_IP=${maria_ip}
REDIS_STATIC_IP=${redis_ip}
PHPMYADMIN_STATIC_IP=${pma_ip}
EOF

    chmod 600 "$ENV_FILE"
    success "Configuration secured in ${ENV_FILE} (phpMyAdmin enabled: ${enable_pma})"
}

start_services() {
    local enable_pma
    enable_pma="$(grep -E '^ENABLE_PHPMYADMIN=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo 'true')"

    ensure_docker_network
    ensure_inter_bridge_routing
    ensure_auto_attacher_service

    if [[ "$enable_pma" == "true" ]]; then
        section "Deploying MariaDB, Redis and phpMyAdmin containers"
        log "Starting stack..."
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
    else
        section "Deploying MariaDB and Redis containers (phpMyAdmin disabled)"
        log "Starting core database services..."
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d mariadb redis
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E -q '^(shared-phpmyadmin|phpmyadmin)$'; then
            log "phpMyAdmin is disabled. Stopping existing container..."
            docker stop shared-phpmyadmin phpmyadmin 2>/dev/null || true
            docker rm shared-phpmyadmin phpmyadmin 2>/dev/null || true
            success "phpMyAdmin container removed."
        fi
    fi

    log "Waiting for containers to become healthy..."
    local max_wait=50
    local elapsed=0
    local healthy=false

    while (( elapsed < max_wait )); do
        local maria_status redis_status pma_status
        maria_status="$(docker inspect --format='{{json .State.Health.Status}}' shared-mariadb 2>/dev/null || docker inspect --format='{{json .State.Health.Status}}' mariadb 2>/dev/null || echo '"starting"')"
        redis_status="$(docker inspect --format='{{json .State.Health.Status}}' shared-redis 2>/dev/null || docker inspect --format='{{json .State.Health.Status}}' redis 2>/dev/null || echo '"starting"')"

        if [[ "$enable_pma" == "true" ]]; then
            pma_status="$(docker inspect --format='{{json .State.Health.Status}}' shared-phpmyadmin 2>/dev/null || docker inspect --format='{{json .State.Health.Status}}' phpmyadmin 2>/dev/null || echo '"starting"')"
            if [[ "$maria_status" == '"healthy"' && "$redis_status" == '"healthy"' && "$pma_status" == '"healthy"' ]]; then
                healthy=true
                break
            fi
        else
            if [[ "$maria_status" == '"healthy"' && "$redis_status" == '"healthy"' ]]; then
                healthy=true
                break
            fi
        fi

        sleep 2
        elapsed=$(( elapsed + 2 ))
        echo -n "."
    done
    echo

    local net
    net="$(grep -E '^OPENSHIP_NETWORK=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo 'openship-mariadb')"
    [[ -z "$net" ]] && net="openship-mariadb"

    if [[ "$healthy" == "true" ]]; then
        if [[ "$enable_pma" == "true" ]]; then
            success "MariaDB, Redis and phpMyAdmin are healthy and running on '${net}'!"
        else
            success "MariaDB and Redis are healthy and running on '${net}'!"
        fi
    else
        warn "Containers started. Checking final statuses:"
        warn "MariaDB:    $(docker inspect --format='{{json .State.Health.Status}}' shared-mariadb 2>/dev/null || docker inspect --format='{{json .State.Health.Status}}' mariadb 2>/dev/null || echo 'not found')"
        warn "Redis:      $(docker inspect --format='{{json .State.Health.Status}}' shared-redis 2>/dev/null || docker inspect --format='{{json .State.Health.Status}}' redis 2>/dev/null || echo 'not found')"
        if [[ "$enable_pma" == "true" ]]; then
            warn "phpMyAdmin: $(docker inspect --format='{{json .State.Health.Status}}' shared-phpmyadmin 2>/dev/null || docker inspect --format='{{json .State.Health.Status}}' phpmyadmin 2>/dev/null || echo 'not found')"
        fi
    fi
}

stop_services() {
    section "Stopping services"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down
    if command -v systemctl &>/dev/null && systemctl is-active --quiet openship-network-attacher.service 2>/dev/null; then
        systemctl stop openship-network-attacher.service 2>/dev/null || true
    fi
    success "Services stopped. (Data volumes preserved)"
}

restart_services() {
    section "Restarting services"
    local enable_pma
    enable_pma="$(grep -E '^ENABLE_PHPMYADMIN=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo 'true')"
    ensure_docker_network
    ensure_inter_bridge_routing
    ensure_auto_attacher_service

    if [[ "$enable_pma" == "true" ]]; then
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" restart
    else
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" restart mariadb redis
    fi
    success "Services restarted."
}

pull_images() {
    section "Pulling updated images"
    local enable_pma
    enable_pma="$(grep -E '^ENABLE_PHPMYADMIN=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo 'true')"
    if [[ "$enable_pma" == "true" ]]; then
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
    else
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull mariadb redis
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d mariadb redis
    fi
    success "Services updated."
}

show_status() {
    section "Shared Services Status"

    echo -e "${BOLD}Containers:${NC}"
    docker ps -a --filter "name=mariadb" --filter "name=redis" --filter "name=phpmyadmin" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Networks}}"

    local net
    net="$(grep -E '^OPENSHIP_NETWORK=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo 'openship-mariadb')"
    [[ -z "$net" ]] && net="openship-mariadb"
    echo
    echo -e "${BOLD}Network (${net}):${NC}"
    docker network inspect "$net" --format '{{range .Containers}}{{.Name}} ({{.IPv4Address}}){{"\n"}}{{end}}' 2>/dev/null || echo "Network not found."

    echo
    echo -e "${BOLD}Auto-Attacher Service:${NC}"
    if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
        systemctl status openship-network-attacher.service --no-pager 2>/dev/null || echo "Service not installed or inactive."
    else
        echo "systemd not available in this environment."
    fi

    echo
    echo -e "${BOLD}Volumes:${NC}"
    docker volume ls --filter "name=mariadb_data" --filter "name=redis_data"
}

follow_logs() {
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs -f
}

print_summary() {
    local pma_port pma_ip net_name enable_pma maria_ip redis_ip
    pma_port="$(grep -E '^PHPMYADMIN_PORT=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '20003')"
    pma_ip="$(grep -E '^PHPMYADMIN_BIND_IP=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '127.0.0.1')"
    net_name="$(grep -E '^OPENSHIP_NETWORK=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo 'openship-mariadb')"
    maria_ip="$(grep -E '^MARIADB_STATIC_IP=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '172.20.0.10')"
    redis_ip="$(grep -E '^REDIS_STATIC_IP=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '172.20.0.11')"
    enable_pma="$(grep -E '^ENABLE_PHPMYADMIN=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo 'true')"

    section "Ready! Connection Details"

    echo -e "${BOLD}1. Recommended Access (Auto-connected via DNS hostnames):${NC}"
    echo "------------------------------------------------------------"
    echo "MariaDB Host:          mariadb:3306"
    echo "Redis Host:            redis:6379"
    echo "Auto-Attacher:         ACTIVE (openship-* containers auto-join '${net_name}')"
    echo "------------------------------------------------------------"
    echo
    echo -e "${BOLD}2. Direct Static IP Access (Routing enabled across all Docker bridges):${NC}"
    echo "------------------------------------------------------------"
    echo "MariaDB IP:            ${maria_ip}:3306"
    echo "Redis IP:              ${redis_ip}:6379"
    echo "------------------------------------------------------------"
    echo
    echo -e "${BOLD}3. Web Management (phpMyAdmin):${NC}"
    echo "------------------------------------------------------------"
    if [[ "$enable_pma" == "true" ]]; then
        echo "Local Port:            http://${pma_ip}:${pma_port}"
        echo "OpenShip Edge Proxy:   Target container 'phpmyadmin:80' or http://${pma_ip}:${pma_port}"
    else
        echo "phpMyAdmin:            Disabled (deploy with --with-pma to enable)"
    fi
    echo "Credentials file:      ${ENV_FILE}"
    echo "------------------------------------------------------------"
    echo
    echo -e "${BOLD}4. Project Database Provisioning:${NC}"
    echo "------------------------------------------------------------"
    echo "Projects auto-provision their DB & user during deployment"
    if [[ "$enable_pma" == "true" ]]; then
        echo "using DB_ROOT_PASSWORD or manage tables via phpMyAdmin."
    else
        echo "using DB_ROOT_PASSWORD."
    fi
    echo "------------------------------------------------------------"
}

show_help() {
    cat <<EOF
OpenShip Shared Services Deployer (MariaDB + Redis + phpMyAdmin)

Usage:
  sudo ./deploy.sh [OPTIONS]

Deployment options:
  --with-pma, --enable-pma      Deploy phpMyAdmin for database management
  --without-pma, --disable-pma  Deploy without phpMyAdmin

Management options:
  --status                      Display current status and health of containers
  --restart                     Restart containers
  --stop                        Stop containers (volumes preserved)
  --logs                        Follow container logs in real time
  --pull                        Pull updated Docker images and recreate containers
  --help, -h                    Display this help message

Environment variables:
  ENABLE_PHPMYADMIN=true|false  Toggle phpMyAdmin installation
EOF
}

main() {
    local cli_action=""
    local cli_pma=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-pma|--enable-pma)
                cli_pma="true"
                shift
                ;;
            --without-pma|--disable-pma)
                cli_pma="false"
                shift
                ;;
            --status)
                cli_action="status"
                shift
                ;;
            --restart)
                cli_action="restart"
                shift
                ;;
            --stop)
                cli_action="stop"
                shift
                ;;
            --logs)
                cli_action="logs"
                shift
                ;;
            --pull)
                cli_action="pull"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                error "Unknown argument: $1"
                show_help
                exit 1
                ;;
        esac
    done

    require_root_or_docker
    ensure_docker_and_compose

    case "$cli_action" in
        status)
            show_status
            ;;
        restart)
            restart_services
            ;;
        stop)
            stop_services
            ;;
        logs)
            follow_logs
            ;;
        pull)
            pull_images
            ;;
        "")
            configure_environment "$cli_pma"
            start_services
            print_summary
            ;;
    esac
}

main "$@"
