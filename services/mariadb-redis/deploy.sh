#!/usr/bin/env bash

# ==============================================================================
# OpenShip Shared Infrastructure Deployment Script (MariaDB + Redis + PMA)
# ==============================================================================
#
# Idempotent deployer for MariaDB 11.4 LTS, Redis 7.4, and phpMyAdmin running on
# the shared FrankenPHP (PHP 8.4+) runtime. Database ports stay closed to the
# host; services communicate via Docker DNS aliases ('mariadb', 'redis', 'phpmyadmin').
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

    if [[ $EUID -ne 0 ]] && ! groups | grep -qE '(^| )docker( |$)'; then
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

    if [[ ! -f "$ENV_FILE" && -f "$ENV_EXAMPLE" ]]; then
        cp "$ENV_EXAMPLE" "$ENV_FILE"
    fi

    local maria_pass redis_pass maria_ver redis_ver maria_pool php_ver pma_ver pma_limit redis_policy enable_pma
    maria_ver="$(grep -E '^MARIADB_VERSION=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '11.4')"
    redis_ver="$(grep -E '^REDIS_VERSION=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '7.4-alpine')"
    maria_pass="$(grep -E '^MARIADB_ROOT_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || true)"
    [[ -z "$maria_pass" ]] && maria_pass="$(grep -E '^DB_ROOT_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || true)"
    redis_pass="$(grep -E '^REDIS_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || true)"
    maria_pool="$(grep -E '^MARIADB_BUFFER_POOL_SIZE=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo "${MARIADB_BUFFER_POOL_SIZE}")"
    php_ver="$(grep -E '^PHP_VERSION=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '8.4')"
    pma_ver="$(grep -E '^PHPMYADMIN_VERSION=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo 'latest')"
    pma_limit="$(grep -E '^PHPMYADMIN_MEMORY_LIMIT=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '128M')"
    redis_policy="$(grep -E '^REDIS_MAXMEMORY_POLICY=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo 'allkeys-lru')"
    enable_pma="$(grep -E '^ENABLE_PHPMYADMIN=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo "${ENABLE_PHPMYADMIN:-true}")"

    [[ -z "$maria_ver" ]] && maria_ver="11.4"
    [[ -z "$redis_ver" ]] && redis_ver="7.4-alpine"
    [[ -z "$maria_pool" ]] && maria_pool="${MARIADB_BUFFER_POOL_SIZE}"
    [[ -z "$php_ver" ]] && php_ver="8.4"
    [[ -z "$pma_ver" ]] && pma_ver="latest"
    [[ -z "$pma_limit" ]] && pma_limit="128M"
    [[ -z "$redis_policy" ]] && redis_policy="allkeys-lru"

    if [[ -n "$cli_pma" ]]; then
        enable_pma="$cli_pma"
    elif [[ -n "${ENABLE_PHPMYADMIN:-}" ]]; then
        enable_pma="${ENABLE_PHPMYADMIN}"
    fi

    if [[ "$enable_pma" == "true" || "$enable_pma" == "yes" || "$enable_pma" == "1" || -z "$enable_pma" ]]; then
        enable_pma="true"
    else
        enable_pma="false"
    fi

    if [[ -z "$maria_pass" ]]; then
        if [[ -t 0 ]]; then
            while [[ -z "$maria_pass" ]]; do
                read -r -s -p "Enter MariaDB root password: " maria_pass
                echo
                [[ -z "$maria_pass" ]] && warn "MariaDB root password cannot be empty."
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
                [[ -z "$redis_pass" ]] && warn "Redis password cannot be empty."
            done
        else
            error "REDIS_PASSWORD is required. Set it in ${ENV_FILE} or environment."
            exit 1
        fi
    fi

    cat > "$ENV_FILE" <<EOF
# OpenShip Shared Services — MariaDB + Redis + phpMyAdmin (FrankenPHP)
# Generated on: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

DB_ROOT_PASSWORD=${maria_pass}
MARIADB_VERSION=${maria_ver}
MARIADB_ROOT_PASSWORD=${maria_pass}
MARIADB_BUFFER_POOL_SIZE=${maria_pool}
MARIADB_MAX_CONNECTIONS=30
MARIADB_MEMORY_LIMIT=512M

REDIS_VERSION=${redis_ver}
REDIS_PASSWORD=${redis_pass}
REDIS_MAXMEMORY=48mb
REDIS_MAXMEMORY_POLICY=${redis_policy}
REDIS_MEMORY_LIMIT=80M

PHP_VERSION=${php_ver}
ENABLE_PHPMYADMIN=${enable_pma}
PHPMYADMIN_VERSION=${pma_ver}
PHPMYADMIN_HOST=mariadb
PHPMYADMIN_UPLOAD_LIMIT=512M
PHPMYADMIN_MEMORY_LIMIT=${pma_limit}
EOF

    chmod 600 "$ENV_FILE"
    success "Configuration secured in ${ENV_FILE} (PHP ${php_ver}, phpMyAdmin enabled: ${enable_pma})"
}

wait_for_healthy() {
    local enable_pma="${1:-true}"
    log "Waiting for containers to become healthy..."
    local max_wait=60
    local elapsed=0
    local healthy=false

    while (( elapsed < max_wait )); do
        local maria_status redis_status pma_status
        maria_status="$(docker inspect --format='{{json .State.Health.Status}}' mariadb 2>/dev/null || echo '"starting"')"
        redis_status="$(docker inspect --format='{{json .State.Health.Status}}' redis 2>/dev/null || echo '"starting"')"

        if [[ "$enable_pma" == "true" ]]; then
            pma_status="$(docker inspect --format='{{json .State.Health.Status}}' phpmyadmin 2>/dev/null || echo '"starting"')"
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

    if [[ "$healthy" == "true" ]]; then
        success "All selected services are healthy!"
    else
        warn "Containers started. Current health statuses:"
        warn "MariaDB:    $(docker inspect --format='{{json .State.Health.Status}}' mariadb 2>/dev/null || echo 'not found')"
        warn "Redis:      $(docker inspect --format='{{json .State.Health.Status}}' redis 2>/dev/null || echo 'not found')"
        if [[ "$enable_pma" == "true" ]]; then
            warn "phpMyAdmin: $(docker inspect --format='{{json .State.Health.Status}}' phpmyadmin 2>/dev/null || echo 'not found')"
        fi
    fi
}

start_services() {
    local enable_pma
    enable_pma="$(grep -E '^ENABLE_PHPMYADMIN=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo 'true')"

    if [[ "$enable_pma" == "true" ]]; then
        section "Deploying MariaDB, Redis and phpMyAdmin (FrankenPHP)"
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

    wait_for_healthy "$enable_pma"
}

stop_services() {
    section "Stopping services"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down
    success "Services stopped. (Data volumes preserved)"
}

restart_services() {
    section "Restarting services"
    local enable_pma
    enable_pma="$(grep -E '^ENABLE_PHPMYADMIN=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo 'true')"
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
        docker exec phpmyadmin rm -f /app/public/.pma-version 2>/dev/null || true
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --force-recreate
    else
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull mariadb redis
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d mariadb redis
    fi
    wait_for_healthy "$enable_pma"
    success "Services updated."
}

show_status() {
    section "Shared Services Status"

    echo -e "${BOLD}Containers:${NC}"
    docker ps -a --filter "name=mariadb" --filter "name=redis" --filter "name=phpmyadmin" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Networks}}"

    echo
    echo -e "${BOLD}Volumes:${NC}"
    docker volume ls --filter "name=mariadb_data" --filter "name=redis_data" --filter "name=pma_data"
}

follow_logs() {
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs -f
}

print_summary() {
    local enable_pma php_ver
    enable_pma="$(grep -E '^ENABLE_PHPMYADMIN=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo 'true')"
    php_ver="$(grep -E '^PHP_VERSION=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'\'' \r\n' || echo '8.4')"

    section "Ready! Connection Details"

    echo -e "${BOLD}1. Internal DNS Aliases (No host ports exposed):${NC}"
    echo "------------------------------------------------------------"
    echo "MariaDB Host:          mariadb:3306"
    echo "Redis Host:            redis:6379"
    echo "------------------------------------------------------------"
    echo
    echo -e "${BOLD}2. Web Management (phpMyAdmin on FrankenPHP ${php_ver}):${NC}"
    echo "------------------------------------------------------------"
    if [[ "$enable_pma" == "true" ]]; then
        echo "Internal Target:       phpmyadmin:80"
        echo "Public Domain:         Route via OpenShip Edge (exposedPort: 80)"
    else
        echo "phpMyAdmin:            Disabled (deploy with --with-pma to enable)"
    fi
    echo "Credentials file:      ${ENV_FILE}"
    echo "------------------------------------------------------------"
}

show_help() {
    cat <<EOF
OpenShip Shared Services Deployer (MariaDB + Redis + phpMyAdmin)

Usage:
  sudo ./deploy.sh [OPTIONS]

Deployment options:
  --with-pma, --enable-pma      Deploy phpMyAdmin on shared FrankenPHP runtime
  --without-pma, --disable-pma  Deploy without phpMyAdmin

Management options:
  --status                      Display current status and volumes
  --restart                     Restart containers
  --stop                        Stop containers (volumes preserved)
  --logs                        Follow container logs in real time
  --pull                        Pull updated Docker images and recreate containers
  --help, -h                    Display this help message

Environment variables:
  ENABLE_PHPMYADMIN=true|false  Toggle phpMyAdmin installation
  PHP_VERSION=8.4               Shared FrankenPHP version for phpMyAdmin
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
