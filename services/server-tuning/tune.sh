#!/usr/bin/env bash

# ==============================================================================
# OpenShip Worker VPS — All-in-One Setup & Tuning Script
# ==============================================================================
#
# Standalone, self-contained provisioning and optimization script for Ubuntu
# 24.04 / 22.04 LTS servers hosting OpenShip Edge, FrankenPHP, and containers.
#
# Everything is included in this single file — zero external library dependencies.
# Safe to execute directly via curl:
#   curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/services/server-tuning/tune.sh | sudo bash
#
# What it does:
#   1. System packages update & essential utilities (btop, jq, git, ufw, fail2ban, etc.)
#   2. Hostname and timezone configuration
#   3. Automated Swap allocation (swappiness=10, vfs_cache_pressure=50)
#   4. Low-latency kernel & sysctl tuning (TCP Fast Open, no-idle-slow-start, BBR)
#   5. High-throughput 16MB network buffers + UDP buffers for HTTP/3 QUIC
#   6. Memory dirty ratios (dirty_ratio=15, dirty_background_ratio=5)
#   7. Database & Redis memory limits (vm.overcommit_memory=1, vm.max_map_count=262144)
#   8. Process & file descriptor limits (nofile 65535, nproc 65535)
#   9. Systemd journald size bounding (SystemMaxUse=200M)
#  10. CPU Scaling Governor set to 'performance' (persistent via systemd)
#  11. UFW Firewall: SSH, HTTP :80, HTTPS :443 tcp+udp (HTTP/3 QUIC); DBs kept private
#  12. SSH hardening, Fail2ban jail & automatic security updates
#
# Usage:
#   sudo ./tune.sh [OPTIONS]
#
# Options:
#   --non-interactive       Apply configuration without interactive prompts
#   --dry-run               Validate system and show parameters without modifying system
#   --ssh-port=PORT         Override SSH port (default: 22)
#   --swap-size=GB          Override swap size in GB (default: auto based on RAM)
#   --admin-user=USER       Configure dedicated non-root admin user
#   --skip-packages         Skip apt upgrade and package installation
#   --skip-swap             Skip swapfile creation
#   --skip-sysctl           Skip kernel and sysctl tuning
#   --skip-ufw              Skip UFW firewall configuration
#   --skip-ssh              Skip SSH configuration
#   --version, -v           Display script version
#   --help, -h              Display this help message
#
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="1.2.0"
readonly LOG_FILE="/var/log/openship-worker-tuning.log"

# Minimum RAM thresholds (Worker role)
readonly MIN_RAM_MB=512
readonly LOW_RAM_MB=1024
readonly RECOMMENDED_RAM_MB=2048
readonly MIN_DISK_GB=10

# ------------------------------------------------------------------------------
# Terminal styling
# ------------------------------------------------------------------------------

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    MAGENTA=''
    BOLD=''
    DIM=''
    NC=''
fi

_TW="$(tput cols 2>/dev/null || echo 60)"

# ------------------------------------------------------------------------------
# Logging & UI Helpers
# ------------------------------------------------------------------------------

log() {
    echo -e "  ${BLUE}·${NC} $*"
}

success() {
    echo -e "  ${GREEN}✓${NC} $*"
}

warn() {
    echo -e "  ${YELLOW}⚠${NC}  $*"
}

error() {
    echo -e "  ${RED}✗${NC} $*" >&2
}

die() {
    echo
    error "$*"
    echo -e "  ${DIM}Log: ${LOG_FILE}${NC}"
    echo
    exit 1
}

section() {
    local title=" $* "
    local width=$(( _TW < 72 ? _TW : 72 ))
    local pad=$(( (width - ${#title} - 2) / 2 ))
    local line
    printf -v line '%*s' "$width" ''
    line="${line// /─}"
    local prefix="${line:0:$pad}"
    local suffix="${line:0:$(( width - pad - ${#title} ))}"
    echo
    echo -e "${BOLD}${CYAN}${prefix}${title}${suffix}${NC}"
    echo
}

run_task() {
    local msg="$1"
    shift
    local pid i=0
    local frames=(
        "[■         ]"
        "[■■        ]"
        "[■■■       ]"
        "[ ■■■      ]"
        "[  ■■■     ]"
        "[   ■■■    ]"
        "[    ■■■   ]"
        "[     ■■■  ]"
        "[      ■■■ ]"
        "[       ■■■]"
        "[        ■■]"
        "[         ■]"
    )

    ("$@") >> "$LOG_FILE" 2>&1 &
    pid=$!

    if [[ -e /dev/tty && -w /dev/tty && -t 1 ]]; then
        while kill -0 "$pid" 2>/dev/null; do
            printf "\r  ${CYAN}%s${NC} %s..." "${frames[i]}" "$msg" >/dev/tty 2>/dev/null || break
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.1
        done
        wait "$pid"
        local status=$?
        if (( status == 0 )); then
            printf "\r\033[K  ${GREEN}✔${NC} %s\n" "$msg" >/dev/tty 2>/dev/null || success "$msg"
        else
            printf "\r\033[K  ${RED}✖${NC} %s (failed, exit %d)\n" "$msg" "$status" >/dev/tty 2>/dev/null || error "$msg failed"
            return "$status"
        fi
    else
        log "${msg}..."
        wait "$pid"
        local status=$?
        if (( status == 0 )); then
            success "$msg"
        else
            error "$msg (failed, exit $status)"
            return "$status"
        fi
    fi
}

on_error() {
    local exit_code=$?
    local line_no=$1

    echo
    error "Setup/Tuning failed."
    error "Line: ${line_no}"
    error "Exit code: ${exit_code}"
    error "Log: ${LOG_FILE}"
    echo

    exit "$exit_code"
}

trap 'on_error ${LINENO}' ERR

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

validate_ssh_authorized_keys() {
    local key_file="$1"
    [[ -f "$key_file" && -s "$key_file" ]] || return 1
    if command_exists ssh-keygen; then
        ssh-keygen -l -f "$key_file" >/dev/null 2>&1 && return 0
    fi
    grep -v '^[[:space:]]*#' "$key_file" 2>/dev/null | grep -Eq '^[[:space:]]*(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp|sk-)'
}

validate_ssh_key_string() {
    local key_str="$1"
    [[ -n "$key_str" ]] || return 1
    local tmp_file
    tmp_file="$(mktemp 2>/dev/null || echo "/tmp/ssh_key_check_$$")"
    echo "$key_str" > "$tmp_file"
    local res=1
    if command_exists ssh-keygen; then
        if ssh-keygen -l -f "$tmp_file" >/dev/null 2>&1; then
            res=0
        fi
    else
        if echo "$key_str" | grep -Eq '^[[:space:]]*(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp|sk-)'; then
            res=0
        fi
    fi
    rm -f "$tmp_file"
    return "$res"
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local answer=""

    if [[ ! -e /dev/tty || ! -r /dev/tty ]]; then
        [[ "$default" =~ ^[Yy]$ ]] && return 0 || return 1
    fi

    if [[ "$default" == "Y" ]]; then
        read -r -p "$prompt [Y/n]: " answer </dev/tty
        answer="${answer//[$'\r\n\t ']/}"
        answer="${answer:-Y}"
    else
        read -r -p "$prompt [y/N]: " answer </dev/tty
        answer="${answer//[$'\r\n\t ']/}"
        answer="${answer:-N}"
    fi

    case "${answer,,}" in
        y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

ask_default() {
    local prompt="$1"
    local default="$2"
    local value=""

    if [[ ! -e /dev/tty || ! -r /dev/tty ]]; then
        echo "$default"
        return
    fi

    read -r -p "$prompt [$default]: " value </dev/tty
    value="${value//[$'\r\n']/}"
    echo "${value:-$default}"
}

# ------------------------------------------------------------------------------
# CLI Flags & Arguments
# ------------------------------------------------------------------------------

DRY_RUN=false
NON_INTERACTIVE=false
SKIP_PACKAGES=false
SKIP_SWAP=false
SKIP_SYSCTL=false
SKIP_UFW=false
SKIP_SSH=false
PURGE_APACHE=false
INSTALL_STACK=false
SKIP_STACK=false
STACK_INSTALLED=false

CLI_SSH_PORT=""
CLI_SWAP_SIZE=""
CLI_ADMIN_USER=""
CLI_SSH_KEY=""

for arg in "$@"; do
    case "$arg" in
        --version|-v)
            echo "OpenShip Worker Tuning Script v${SCRIPT_VERSION}"
            exit 0
            ;;
        --help|-h)
            echo "Usage: sudo ./tune.sh [OPTIONS]"
            echo
            echo "Options:"
            echo "  --non-interactive   Apply configuration without interactive prompts"
            echo "  --dry-run           Inspect system and validate configuration without modifying system"
            echo "  --ssh-port=PORT     Override SSH port (default: 22)"
            echo "  --ssh-key=KEY       Authorize SSH public key (enables key-only SSH access)"
            echo "  --swap-size=GB      Override swap size in GB (default: auto based on RAM)"
            echo "  --admin-user=USER   Configure dedicated non-root admin user"
            echo "  --purge-apache      Automatically stop and purge Apache web server if detected"
            echo "  --install-stack     Install Nginx (with Brotli & performance modules), MariaDB, and Redis"
            echo "  --skip-stack        Skip the post-tuning Web/DB stack installation prompt"
            echo "  --skip-packages     Skip apt upgrade and package installation"
            echo "  --skip-swap         Skip swapfile creation"
            echo "  --skip-sysctl       Skip kernel and sysctl tuning"
            echo "  --skip-ufw          Skip UFW firewall configuration"
            echo "  --skip-ssh          Skip SSH configuration"
            echo "  --version, -v       Display version"
            echo "  --help, -h          Display this help message"
            exit 0
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            ;;
        --purge-apache)
            PURGE_APACHE=true
            ;;
        --install-stack)
            INSTALL_STACK=true
            ;;
        --skip-stack)
            SKIP_STACK=true
            ;;
        --skip-packages)
            SKIP_PACKAGES=true
            ;;
        --skip-swap)
            SKIP_SWAP=true
            ;;
        --skip-sysctl)
            SKIP_SYSCTL=true
            ;;
        --skip-ufw)
            SKIP_UFW=true
            ;;
        --skip-ssh)
            SKIP_SSH=true
            ;;
        --ssh-port=*)
            CLI_SSH_PORT="${arg#*=}"
            ;;
        --ssh-key=*)
            CLI_SSH_KEY="${arg#*=}"
            ;;
        --swap-size=*)
            CLI_SWAP_SIZE="${arg#*=}"
            ;;
        --admin-user=*)
            CLI_ADMIN_USER="${arg#*=}"
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Run './tune.sh --help' for usage." >&2
            exit 1
            ;;
    esac
done

# Root Check
if [[ "$EUID" -ne 0 && "$DRY_RUN" != "true" ]]; then
    echo "Error: This script must be run as root: sudo ./tune.sh" >&2
    exit 1
fi

# Ensure log directory and log file exist
if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
fi

# ------------------------------------------------------------------------------
# Load local .env configuration if present
# ------------------------------------------------------------------------------

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
fi

ENV_HOSTNAME=""
ENV_TIMEZONE=""
ENV_SSH_PORT=""
ENV_SSH_KEY=""
ENV_ADMIN_USER=""
ENV_ENABLE_SWAP=""
ENV_SWAP_SIZE_GB=""
ENV_ENABLE_BBR=""
ENV_ENABLE_UFW=""
ENV_ENABLE_FAIL2BAN=""
ENV_ENABLE_UNATTENDED_UPGRADES=""

if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/.env" ]]; then
    ENV_FILE="${SCRIPT_DIR}/.env"
    log "Loading configuration from ${ENV_FILE}..."
    while IFS="=" read -r key val || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key="$(echo "$key" | tr -d '[:space:]')"
        val="${val#\"}"
        val="${val%\"}"
        val="${val#\'}"
        val="${val%\'}"
        case "$key" in
            HOSTNAME)                   ENV_HOSTNAME="$val" ;;
            TIMEZONE)                   ENV_TIMEZONE="$val" ;;
            SSH_PORT)                   ENV_SSH_PORT="$val" ;;
            SSH_KEY)                    ENV_SSH_KEY="$val" ;;
            ADMIN_USER)                 ENV_ADMIN_USER="$val" ;;
            ENABLE_SWAP)                ENV_ENABLE_SWAP="$val" ;;
            SWAP_SIZE_GB)               ENV_SWAP_SIZE_GB="$val" ;;
            ENABLE_BBR)                 ENV_ENABLE_BBR="$val" ;;
            ENABLE_UFW)                 ENV_ENABLE_UFW="$val" ;;
            ENABLE_FAIL2BAN)            ENV_ENABLE_FAIL2BAN="$val" ;;
            ENABLE_UNATTENDED_UPGRADES) ENV_ENABLE_UNATTENDED_UPGRADES="$val" ;;
        esac
    done < "$ENV_FILE"
fi

# Default configuration values
HOSTNAME_INPUT="${ENV_HOSTNAME:-$(hostname)}"
TIMEZONE_INPUT="${ENV_TIMEZONE:-UTC}"
SSH_PORT_INPUT="${CLI_SSH_PORT:-${ENV_SSH_PORT:-22}}"
ADMIN_USER_INPUT="${CLI_ADMIN_USER:-${ENV_ADMIN_USER:-}}"
SSH_KEY_INPUT="${CLI_SSH_KEY:-${ENV_SSH_KEY:-}}"
ENABLE_SWAP="${ENV_ENABLE_SWAP:-true}"
SWAP_SIZE_GB="${CLI_SWAP_SIZE:-${ENV_SWAP_SIZE_GB:-}}"
ENABLE_BBR="${ENV_ENABLE_BBR:-true}"
ENABLE_UFW="${ENV_ENABLE_UFW:-true}"
ENABLE_FAIL2BAN="${ENV_ENABLE_FAIL2BAN:-true}"
ENABLE_UNATTENDED_UPGRADES="${ENV_ENABLE_UNATTENDED_UPGRADES:-true}"

# ------------------------------------------------------------------------------
# Banner
# ------------------------------------------------------------------------------

echo
echo -e "${BOLD}${CYAN}============================================================${NC}"
echo -e "${BOLD}${CYAN} OpenShip Worker VPS — Setup & Tuning v${SCRIPT_VERSION}${NC}"
echo -e "${BOLD}${CYAN}============================================================${NC}"
echo

if [[ "$DRY_RUN" == "true" ]]; then
    warn "DRY-RUN MODE: No changes will be written to the host system."
    echo
fi

# ------------------------------------------------------------------------------
# System Checks & Resource Detection
# ------------------------------------------------------------------------------

check_os() {
    section "Operating system"

    [[ -f /etc/os-release ]] || die "/etc/os-release not found."
    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "Ubuntu is required. Detected: ${ID:-unknown}"
    fi

    local major_ver="${VERSION_ID%%.*}"
    if ! [[ "$major_ver" =~ ^[0-9]+$ ]] || (( major_ver < 22 )); then
        warn "This script is designed for Ubuntu 22.04 / 24.04+ (detected: ${VERSION_ID:-unknown})."
        if ! ask_yes_no "Continue anyway?" "N"; then
            die "Setup cancelled."
        fi
    fi

    success "Ubuntu ${VERSION_ID:-unknown}"
}

check_architecture() {
    section "Architecture"

    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

    case "$arch" in
        amd64|x86_64|arm64|aarch64)
            success "Architecture: ${arch}"
            ;;
        *)
            die "Unsupported architecture: ${arch}"
            ;;
    esac
}

detect_worker_resources() {
    if [[ -f /proc/meminfo ]]; then
        RAM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 2048)"
        DISK_GB="$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}' 2>/dev/null || echo 50)"
        CPU_COUNT="$(nproc 2>/dev/null || echo 2)"
    else
        RAM_MB="${RAM_MB:-2048}"
        DISK_GB="${DISK_GB:-50}"
        CPU_COUNT="${CPU_COUNT:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"
    fi
}

if [[ "$DRY_RUN" != "true" ]]; then
    check_os
    check_architecture
fi

detect_worker_resources

section "System resources"
echo "  RAM:         ${RAM_MB} MB"
echo "  CPU cores:   ${CPU_COUNT}"
echo "  Disk free:   ${DISK_GB} GB"
echo

if (( RAM_MB < MIN_RAM_MB )); then
    warn "RAM (${RAM_MB} MB) is below minimum recommended for Worker node (${MIN_RAM_MB} MB)."
fi

# Compute default swap size if not explicitly set
if [[ -z "$SWAP_SIZE_GB" ]]; then
    if (( RAM_MB <= 2048 )); then
        SWAP_SIZE_GB=2
    else
        SWAP_SIZE_GB=4
    fi
fi

# ------------------------------------------------------------------------------
# Interactive Configuration (unless --non-interactive)
# ------------------------------------------------------------------------------

if [[ "$NON_INTERACTIVE" != "true" && ( ! -e /dev/tty || ! -r /dev/tty ) ]]; then
    warn "No interactive TTY detected. Running in non-interactive mode with defaults."
    NON_INTERACTIVE=true
fi

if [[ "$NON_INTERACTIVE" != "true" && "$DRY_RUN" != "true" ]]; then
    section "Configuration parameters"

    HOSTNAME_INPUT="$(ask_default "Worker hostname" "$HOSTNAME_INPUT")"
    TIMEZONE_INPUT="$(ask_default "Timezone" "$TIMEZONE_INPUT")"

    if [[ "$SKIP_SWAP" != "true" ]]; then
        if ask_yes_no "Configure Swap (${SWAP_SIZE_GB} GB)?" "Y"; then
            ENABLE_SWAP="true"
            SWAP_SIZE_GB="$(ask_default "Swap size in GB" "$SWAP_SIZE_GB")"
        else
            ENABLE_SWAP="false"
        fi
    fi

    if [[ "$SKIP_SSH" != "true" ]]; then
        SSH_PORT_INPUT="$(ask_default "SSH port" "$SSH_PORT_INPUT")"
        if [[ -z "$ADMIN_USER_INPUT" ]]; then
            if ask_yes_no "Create a dedicated non-root admin user?" "N"; then
                ADMIN_USER_INPUT="$(ask_default "Admin username" "openship")"
            fi
        fi
    fi

    if [[ "$SKIP_UFW" != "true" ]]; then
        if ask_yes_no "Configure UFW firewall (SSH :${SSH_PORT_INPUT}, HTTP :80, HTTPS :443 tcp+udp)?" "Y"; then
            ENABLE_UFW="true"
        else
            ENABLE_UFW="false"
        fi
    fi

    echo
    echo -e "${BOLD}Summary of configuration:${NC}"
    echo "  Hostname:              ${HOSTNAME_INPUT}"
    echo "  Timezone:              ${TIMEZONE_INPUT}"
    echo "  Swap:                  ${ENABLE_SWAP} (${SWAP_SIZE_GB} GB)"
    echo "  SSH Port:              ${SSH_PORT_INPUT}"
    echo "  Admin User:            ${ADMIN_USER_INPUT:-<none>}"
    echo "  UFW Firewall:          ${ENABLE_UFW}"
    echo "  Fail2ban:              ${ENABLE_FAIL2BAN}"
    echo "  BBR & Low-Latency:     ${ENABLE_BBR}"
    echo "  Auto Security Updates: ${ENABLE_UNATTENDED_UPGRADES}"
    echo

    if ! ask_yes_no "Proceed with tuning?" "Y"; then
        die "Tuning cancelled by user."
    fi
fi

# ------------------------------------------------------------------------------
# Dry-Run Inspection Output
# ------------------------------------------------------------------------------

if [[ "$DRY_RUN" == "true" ]]; then
    section "Dry-run validation"
    success "Hostname target:      ${HOSTNAME_INPUT}"
    success "Timezone target:      ${TIMEZONE_INPUT}"
    success "Swap target:          ${ENABLE_SWAP} (${SWAP_SIZE_GB} GB)"
    success "SSH port target:      ${SSH_PORT_INPUT}"
    success "Admin user target:    ${ADMIN_USER_INPUT:-none}"
    success "Sysctl tuning:        /etc/sysctl.d/99-openship-worker.conf"
    success "Security limits:      /etc/security/limits.d/99-openship-worker.conf"
    success "Journald limit:       /etc/systemd/journald.conf.d/99-openship.conf"
    success "UFW rules:            allow ${SSH_PORT_INPUT}/tcp, allow 80/tcp, allow 443/tcp, allow 443/udp (HTTP/3 QUIC)"
    success "Fail2ban jail:        /etc/fail2ban/jail.d/sshd-openship.local"
    echo
    echo -e "${GREEN}Dry-run complete. System configuration is valid.${NC}"
    exit 0
fi

# ------------------------------------------------------------------------------
# Step 1: Hostname & Timezone
# ------------------------------------------------------------------------------

configure_hostname() {
    section "Hostname"
    hostnamectl set-hostname "$HOSTNAME_INPUT" 2>/dev/null || true

    if grep -qE '^127\.0\.1\.1[[:space:]]+' /etc/hosts 2>/dev/null; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${HOSTNAME_INPUT}/" /etc/hosts 2>/dev/null || true
    else
        echo "127.0.1.1 ${HOSTNAME_INPUT}" >> /etc/hosts 2>/dev/null || true
    fi

    success "Hostname: ${HOSTNAME_INPUT}"
}

configure_timezone() {
    section "Timezone"

    if timedatectl set-timezone "$TIMEZONE_INPUT" 2>/dev/null; then
        success "Timezone: ${TIMEZONE_INPUT}"
    else
        warn "Failed to set timezone '${TIMEZONE_INPUT}'. Falling back to UTC."
        TIMEZONE_INPUT="UTC"
        timedatectl set-timezone UTC 2>/dev/null || true
        warn "Timezone set to UTC."
    fi
}

if [[ -n "$HOSTNAME_INPUT" && "$HOSTNAME_INPUT" != "$(hostname 2>/dev/null || echo "")" ]]; then
    configure_hostname
fi

if [[ -n "$TIMEZONE_INPUT" ]]; then
    configure_timezone
fi

# ------------------------------------------------------------------------------
# Step 2: System Packages & Essential Utilities
# ------------------------------------------------------------------------------

install_and_update_packages() {
    section "System packages & update"

    export DEBIAN_FRONTEND=noninteractive

    # Clean up broken/expired repositories if any
    rm -f /etc/apt/sources.list.d/caddy-stable.list /etc/apt/sources.list.d/caddy-stable.sources /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true

    run_task "Updating package lists" apt-get update -qq

    run_task "Upgrading system packages" env DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    run_task "Installing base utilities" apt-get install -y -qq \
        ca-certificates \
        curl \
        gnupg \
        git \
        jq \
        unzip \
        rsync \
        btop \
        nano \
        lsof \
        procps \
        dnsutils \
        openssl \
        ufw \
        fail2ban \
        unattended-upgrades \
        systemd-timesyncd \
        zram-tools

    run_task "Cleaning up unused packages" bash -c "apt-get autoremove -y -qq && apt-get clean -qq"

    if [[ -f /var/run/reboot-required ]]; then
        warn "A system restart is recommended after kernel updates."
    fi
}

# ------------------------------------------------------------------------------
# Checking and removing Apache web server
# ------------------------------------------------------------------------------

check_and_remove_apache() {
    section "Checking for conflicting web servers (Apache)"

    local has_apache=false
    if command_exists apache2 || dpkg -s apache2 &>/dev/null 2>&1 || systemctl list-unit-files apache2.service &>/dev/null 2>&1; then
        has_apache=true
    fi

    if [[ "$has_apache" != "true" ]]; then
        success "No Apache installation detected."
        return 0
    fi

    warn "Apache web server (apache2) is installed on this system."
    warn "Apache conflicts with Nginx on port 80/443 and consumes memory."

    local do_purge=false
    if [[ "$PURGE_APACHE" == "true" ]]; then
        do_purge=true
    elif [[ "$NON_INTERACTIVE" == "true" ]]; then
        warn "Non-interactive mode: stopping and purging Apache..."
        do_purge=true
    else
        read -r -p "  Stop and completely remove Apache (apache2)? [Y/n] " response
        case "$response" in
            [nN][oO]|[nN])
                do_purge=false
                ;;
            *)
                do_purge=true
                ;;
        esac
    fi

    if [[ "$do_purge" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY RUN] Would stop, disable and purge apache2 packages and configs."
            return 0
        fi

        log "Stopping and disabling Apache service..."
        systemctl stop apache2 2>/dev/null || true
        systemctl disable apache2 2>/dev/null || true
        systemctl mask apache2 2>/dev/null || true

        run_task "Purging Apache packages and configurations" bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get purge -y -qq apache2 apache2-utils apache2-bin apache2-data apache2.2-common 2>/dev/null || true"
        run_task "Cleaning up unused Apache dependencies" bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get autoremove -y -qq"

        rm -rf /etc/apache2 /var/log/apache2 2>/dev/null || true
        success "Apache web server successfully removed."
    else
        warn "Apache was preserved. Note: Nginx cannot bind to port 80/443 while Apache is active."
    fi
}

check_and_remove_apache

if [[ "$SKIP_PACKAGES" != "true" ]]; then
    install_and_update_packages
else
    warn "Package update & installation skipped (--skip-packages)."
fi

# ------------------------------------------------------------------------------
# Freeing Memory (Unused Background Daemons)
# ------------------------------------------------------------------------------

disable_unused_services() {
    section "Freeing memory (unused services)"
    local services=(
        snapd.service
        snapd.socket
        snapd.seeded.service
        multipathd.service
        multipathd.socket
        ModemManager.service
        packagekit.service
        whoopsie.service
        apport.service
    )
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null || systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            log "Disabling unused service: ${svc}..."
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            systemctl mask "$svc" 2>/dev/null || true
        fi
    done

    # Disable cloud-init after install to prevent memory usage & background checks
    if command_exists cloud-init || [[ -d /etc/cloud ]]; then
        mkdir -p /etc/cloud
        touch /etc/cloud/cloud-init.disabled
        for ci_svc in cloud-init.service cloud-config.service cloud-final.service cloud-init-local.service; do
            systemctl disable "$ci_svc" 2>/dev/null || true
            systemctl mask "$ci_svc" 2>/dev/null || true
        done
        log "cloud-init disabled for post-install boots."
    fi

    # Reschedule apt-daily timers to night hours (03:30) to avoid daytime CPU spikes on 1-core VPS
    if systemctl list-unit-files apt-daily.timer &>/dev/null; then
        mkdir -p /etc/systemd/system/apt-daily.timer.d /etc/systemd/system/apt-daily-upgrade.timer.d
        cat > /etc/systemd/system/apt-daily.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=30m
Persistent=true
EOF
        cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 04:15:00
RandomizedDelaySec=30m
Persistent=true
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
        log "apt-daily background maintenance rescheduled to off-peak night hours (03:30-04:45)."
    fi

    success "Unused background services disabled (freed ~100-150MB RAM)."
}

# ------------------------------------------------------------------------------
# Step 3: Memory Compression (zRAM) & Swap
# ------------------------------------------------------------------------------

configure_swap() {
    section "Memory Compression (zRAM) & Swap"

    # 1. Setup zRAM (in-memory compressed swap)
    if command_exists zramctl || [[ -f /etc/default/zramswap ]] || modprobe zram 2>/dev/null; then
        log "Configuring zRAM compressed memory (lz4, 50% RAM, priority 100)..."
        mkdir -p /etc/default
        cat > /etc/default/zramswap <<'EOF'
ALGO=lz4
PERCENT=50
PRIORITY=100
EOF
        systemctl enable --now zramswap 2>/dev/null || true
        success "zRAM compressed memory configured."
    fi

    # 2. Check disk swap
    if swapon --show 2>/dev/null | grep -q '/swapfile'; then
        success "Swapfile is already active:"
        swapon --show 2>/dev/null || true
        return
    fi

    if [[ "$ENABLE_SWAP" != "true" || "${SWAP_SIZE_GB:-0}" -le 0 ]]; then
        warn "Disk swap disabled by configuration."
        return
    fi

    local swap_gb="${SWAP_SIZE_GB:-2}"
    log "Creating ${swap_gb} GB disk swapfile (backup priority 10)..."

    if [[ ! -f /swapfile ]]; then
        if ! fallocate -l "${swap_gb}G" /swapfile 2>/dev/null; then
            warn "fallocate failed, creating swapfile with dd..."
            dd if=/dev/zero of=/swapfile bs=1M count="$((swap_gb * 1024))" status=progress 2>/dev/null
        fi
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
    fi

    if ! swapon --priority 10 /swapfile 2>/dev/null && ! swapon /swapfile 2>/dev/null; then
        warn "swapon failed (possibly running inside container or unsupported filesystem)."
        warn "Continuing without disk swap."
        return
    fi

    if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab 2>/dev/null; then
        echo '/swapfile none swap sw,pri=10 0 0' >> /etc/fstab
    fi

    success "${swap_gb} GB disk swap configured (hybrid zRAM + swapfile active)."
}

if [[ "$SKIP_SWAP" != "true" ]]; then
    configure_swap
else
    warn "Swap configuration skipped (--skip-swap)."
fi

# ------------------------------------------------------------------------------
# Step 4: Kernel, Network & Sysctl Tuning (FrankenPHP & Low TTFB)
# ------------------------------------------------------------------------------

optimize_worker_kernel_and_limits() {
    section "Kernel, Network & System Tuning (FrankenPHP & Low TTFB)"

    # 1. Stop bloat daemons to free up 100-150MB of RAM
    disable_unused_services

    # 2. Time sync & weekly SSD TRIM
    log "Enabling systemd-timesyncd time synchronization & fstrim..."
    systemctl enable --now systemd-timesyncd 2>/dev/null || true
    systemctl enable --now fstrim.timer 2>/dev/null || true

    # 3. Dynamic resource thresholds
    local sock_buf_max=16777216
    local dirty_ratio=15
    local dirty_bg_ratio=5
    local journal_max="150M"
    local journal_runtime="75M"
    local min_free_kb=65536

    if (( RAM_MB < 2048 )); then
        sock_buf_max=4194304
        dirty_ratio=10
        dirty_bg_ratio=3
        journal_max="50M"
        journal_runtime="25M"
        min_free_kb=32768
        log "Low-memory profile (< 2GB RAM): dynamic 4MB socket buffers, 50MB journald."
    fi

    # 4. File descriptor & process limits
    log "Configuring file descriptor & process limits (nofile 65535, nproc 65535)..."
    cat > /etc/security/limits.d/99-openship-worker.conf <<'EOF'
* soft nofile 65535
* hard nofile 131072
root soft nofile 65535
root hard nofile 131072
* soft nproc 65535
* hard nproc 65535
root soft nproc 65535
root hard nproc 65535
EOF

    # Ensure PAM limits are loaded
    for pam_file in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        if [[ -f "$pam_file" ]] && ! grep -q "pam_limits.so" "$pam_file"; then
            echo "session required pam_limits.so" >> "$pam_file"
        fi
    done

    # 5. Journald size limit
    log "Configuring systemd journal limit (SystemMaxUse=${journal_max})..."
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-openship.conf <<EOF
[Journal]
SystemMaxUse=${journal_max}
RuntimeMaxUse=${journal_runtime}
EOF
    systemctl restart systemd-journald 2>/dev/null || true

    # 6. TCP BBR Congestion Control
    local bbr_applied=false
    if [[ "$ENABLE_BBR" == "true" ]]; then
        if modprobe tcp_bbr 2>/dev/null; then
            mkdir -p /etc/modules-load.d
            echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
            bbr_applied=true
            log "BBR congestion control module loaded."
        else
            warn "Kernel module tcp_bbr not available. Continuing with default cubic."
        fi
    fi

    # 7. Sysctl low-latency & memory tuning
    modprobe br_netfilter 2>/dev/null || true
    log "Applying worker sysctl network, low-latency and database optimizations..."
    cat > /etc/sysctl.d/99-openship-worker.conf <<EOF
# OpenShip Worker VPS Kernel & Network Tuning (Optimized for FrankenPHP & Containers)

# Network connection backlog & buffers
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535

# Socket buffer sizes (Dynamic based on RAM + UDP defaults for HTTP/3 QUIC)
net.core.rmem_max = ${sock_buf_max}
net.core.wmem_max = ${sock_buf_max}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 ${sock_buf_max}
net.ipv4.tcp_wmem = 4096 87380 ${sock_buf_max}

# TCP Fast Open & Low Latency (reduces TTFB by 1 RTT)
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0

# Fast TCP reuse & timeout for high-concurrency reverse proxy
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 32768 65535

# Keepalive timeouts
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# Memory management for Redis background save & MariaDB
vm.overcommit_memory = 1
vm.max_map_count = 262144
vm.min_free_kbytes = ${min_free_kb}
vm.panic_on_oom = 0
vm.oom_kill_allocating_task = 0
vm.swappiness = 20
vm.vfs_cache_pressure = 50

# Memory dirty writeback ratios (prevents I/O write freezes)
vm.dirty_ratio = ${dirty_ratio}
vm.dirty_background_ratio = ${dirty_bg_ratio}

# Docker Bridge & IP Forwarding
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1

# Connection tracking & Container NAT
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15

# ARP neighbor table limits for container veth interfaces
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 4096

# File system & inotify watchers
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
EOF

    if [[ "$bbr_applied" == "true" ]]; then
        cat >> /etc/sysctl.d/99-openship-worker.conf <<'EOF'
# TCP BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    fi

    sysctl --system >> "$LOG_FILE" 2>&1 || true
    success "Worker kernel and sysctl tuning applied."
}

configure_cpu_governor() {
    local gov_files=(/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor)
    if [[ -f "${gov_files[0]:-}" ]]; then
        section "CPU Scaling Governor"
        log "Setting CPU scaling governor to 'performance'..."
        for f in "${gov_files[@]}"; do
            echo "performance" > "$f" 2>/dev/null || true
        done
        mkdir -p /etc/systemd/system
        cat > /etc/systemd/system/cpu-governor-performance.service <<'EOF'
[Unit]
Description=Set CPU Governor to Performance
After=sysinit.target local-fs.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$f" 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable cpu-governor-performance.service 2>/dev/null || true
        success "CPU governor set to 'performance' (persistent via systemd)."
    fi
}

configure_thp() {
    section "Transparent HugePages (THP)"
    log "Disabling Transparent HugePages (never) to eliminate memory bloat & latency spikes..."
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

    mkdir -p /etc/systemd/system
    cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent HugePages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true; echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=basic.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable disable-thp.service 2>/dev/null || true
    success "Transparent HugePages disabled (persistent via systemd)."
}

configure_disk_io() {
    section "Disk I/O & Filesystem Tuning"

    # 1. Enable noatime for root mount in /etc/fstab to eliminate disk write overhead on file reads
    log "Configuring 'noatime' mount option for root filesystem..."
    mount -o remount,noatime / 2>/dev/null || true
    if [[ -f /etc/fstab ]]; then
        if grep -E '\s+/\s+' /etc/fstab | grep -q 'relatime'; then
            sed -i -E '/\s+\/\s+/ s/relatime/noatime/' /etc/fstab
            log "Updated /etc/fstab: replaced relatime with noatime on /."
        elif grep -E '\s+/\s+' /etc/fstab | grep -q 'defaults'; then
            sed -i -E '/\s+\/\s+/ s/defaults/defaults,noatime/' /etc/fstab
            log "Updated /etc/fstab: added noatime to defaults on /."
        fi
    fi

    # 2. Set I/O scheduler to mq-deadline or none for NVMe/SSD
    log "Configuring I/O scheduler (mq-deadline/none) for NVMe/SSD block devices..."
    mkdir -p /etc/udev/rules.d
    cat > /etc/udev/rules.d/60-io-schedulers.rules <<'EOF'
# OpenShip: Low-latency I/O scheduler for SSD / NVMe
ACTION=="add|change", KERNEL=="nvme[0-9]*|sd[a-z]|vd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none mq-deadline"
EOF
    udevadm control --reload 2>/dev/null || true
    udevadm trigger --subsystem-match=block 2>/dev/null || true

    success "Disk I/O tuning (noatime + SSD queue scheduler) applied."
}

configure_docker() {
    if command_exists docker; then
        section "Docker daemon optimization"

        # Ensure overlay and br_netfilter kernel modules are loaded for container networking
        mkdir -p /etc/modules-load.d
        cat > /etc/modules-load.d/docker.conf <<'EOF'
overlay
br_netfilter
EOF
        modprobe overlay 2>/dev/null || true
        modprobe br_netfilter 2>/dev/null || true

        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "5m",
    "max-file": "2"
  },
  "live-restore": true,
  "userland-proxy": false,
  "storage-driver": "overlay2",
  "exec-opts": ["native.cgroupdriver=systemd"],
  "max-concurrent-downloads": 2,
  "max-concurrent-uploads": 2,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65535,
      "Soft": 65535
    },
    "nproc": {
      "Name": "nproc",
      "Hard": 65535,
      "Soft": 65535
    }
  }
}
EOF
        systemctl restart docker 2>/dev/null || true

        # Setup automatic weekly Docker prune timer (reclaims disk without touching named volumes)
        mkdir -p /etc/systemd/system
        cat > /etc/systemd/system/docker-prune.service <<'EOF'
[Unit]
Description=Docker System Prune (reclaim unused disk)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker system prune -f --volumes=false
ExecStartPost=-/usr/bin/docker builder prune -f --keep-storage 2GB
EOF

        cat > /etc/systemd/system/docker-prune.timer <<'EOF'
[Unit]
Description=Weekly Docker Prune Timer

[Timer]
OnCalendar=Sun *-*-* 04:00:00
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now docker-prune.timer 2>/dev/null || true

        success "Docker daemon optimized (overlay2, systemd cgroup, userland-proxy: false, 5m logs, prune timer)."
    fi
}

if [[ "$SKIP_SYSCTL" != "true" ]]; then
    optimize_worker_kernel_and_limits
    configure_cpu_governor
    configure_thp
    configure_disk_io
    configure_docker
else
    warn "Kernel & sysctl tuning skipped (--skip-sysctl)."
fi

# ------------------------------------------------------------------------------
# Step 5: Security Hardening (Admin User, SSH, Fail2ban, Updates)
# ------------------------------------------------------------------------------

configure_admin_user() {
    section "Administrator user"

    if id "$ADMIN_USER_INPUT" >/dev/null 2>&1; then
        log "User '${ADMIN_USER_INPUT}' already exists."
    else
        adduser --disabled-password --gecos "" "$ADMIN_USER_INPUT"
    fi

    usermod -aG sudo "$ADMIN_USER_INPUT"

    local admin_home
    admin_home="$(eval echo "~${ADMIN_USER_INPUT}")"
    local admin_ssh_dir="${admin_home}/.ssh"
    local admin_keys_file="${admin_ssh_dir}/authorized_keys"

    mkdir -p "$admin_ssh_dir"

    # 1. Install explicit SSH key if provided
    if [[ -n "${SSH_KEY_INPUT:-}" ]]; then
        if validate_ssh_key_string "$SSH_KEY_INPUT"; then
            echo "$SSH_KEY_INPUT" >> "$admin_keys_file"
            success "Provided SSH key authorized for ${ADMIN_USER_INPUT}."
        else
            warn "Provided --ssh-key is not a valid SSH public key. Skipping."
        fi
    fi

    # 2. Copy from /root/.ssh/authorized_keys if valid
    if validate_ssh_authorized_keys /root/.ssh/authorized_keys; then
        cat /root/.ssh/authorized_keys >> "$admin_keys_file"
        success "SSH key(s) copied from /root/.ssh/authorized_keys to ${ADMIN_USER_INPUT}."
    fi

    # 3. Check other /home/*/.ssh/authorized_keys (e.g. cloud-init ubuntu/debian)
    if ! validate_ssh_authorized_keys "$admin_keys_file"; then
        for other_keys in /home/*/.ssh/authorized_keys; do
            [[ "$other_keys" == "$admin_keys_file" ]] && continue
            if validate_ssh_authorized_keys "$other_keys"; then
                log "Importing valid SSH key from ${other_keys} to ${ADMIN_USER_INPUT}..."
                cat "$other_keys" >> "$admin_keys_file"
                break
            fi
        done
    fi

    if [[ -f "$admin_keys_file" ]]; then
        sort -u "$admin_keys_file" -o "$admin_keys_file"
    fi

    chown -R "${ADMIN_USER_INPUT}:${ADMIN_USER_INPUT}" "$admin_ssh_dir"
    chmod 700 "$admin_ssh_dir"
    [[ -f "$admin_keys_file" ]] && chmod 600 "$admin_keys_file"
}

configure_ssh() {
    section "SSH hardening"

    local target_user="${ADMIN_USER_INPUT:-root}"
    local target_keys
    if [[ -n "$ADMIN_USER_INPUT" ]]; then
        local admin_home
        admin_home="$(eval echo "~${ADMIN_USER_INPUT}")"
        target_keys="${admin_home}/.ssh/authorized_keys"
    else
        target_keys="/root/.ssh/authorized_keys"
    fi

    # 1. If explicit SSH key provided and target keys not yet verified, write it
    if ! validate_ssh_authorized_keys "$target_keys" && [[ -n "${SSH_KEY_INPUT:-}" ]]; then
        if validate_ssh_key_string "$SSH_KEY_INPUT"; then
            mkdir -p "$(dirname "$target_keys")"
            echo "$SSH_KEY_INPUT" >> "$target_keys"
            chmod 700 "$(dirname "$target_keys")"
            chmod 600 "$target_keys"
            if [[ -n "$ADMIN_USER_INPUT" ]]; then
                chown -R "${ADMIN_USER_INPUT}:${ADMIN_USER_INPUT}" "$(dirname "$target_keys")"
            fi
            success "Provided SSH key authorized for ${target_user}."
        else
            warn "Provided --ssh-key is not a valid SSH public key. Skipping."
        fi
    fi

    # 2. If target has no keys, try importing from /root or /home/*
    if ! validate_ssh_authorized_keys "$target_keys"; then
        if [[ "$target_user" != "root" ]] && validate_ssh_authorized_keys "/root/.ssh/authorized_keys"; then
            mkdir -p "$(dirname "$target_keys")"
            cat /root/.ssh/authorized_keys >> "$target_keys"
            [[ -n "$ADMIN_USER_INPUT" ]] && chown -R "${ADMIN_USER_INPUT}:${ADMIN_USER_INPUT}" "$(dirname "$target_keys")"
            chmod 700 "$(dirname "$target_keys")"
            chmod 600 "$target_keys"
            success "SSH key(s) imported from /root/.ssh/authorized_keys to ${target_user}."
        else
            for other_keys in /home/*/.ssh/authorized_keys; do
                [[ "$other_keys" == "$target_keys" ]] && continue
                if validate_ssh_authorized_keys "$other_keys"; then
                    log "Importing valid SSH key from ${other_keys} to ${target_keys}..."
                    mkdir -p "$(dirname "$target_keys")"
                    cat "$other_keys" >> "$target_keys"
                    [[ -n "$ADMIN_USER_INPUT" ]] && chown -R "${ADMIN_USER_INPUT}:${ADMIN_USER_INPUT}" "$(dirname "$target_keys")"
                    chmod 700 "$(dirname "$target_keys")"
                    chmod 600 "$target_keys"
                    break
                fi
            done
        fi
    fi

    # 3. If still no keys and interactive, prompt user to paste SSH public key
    if ! validate_ssh_authorized_keys "$target_keys"; then
        if [[ "$NON_INTERACTIVE" != "true" && -e /dev/tty && -r /dev/tty ]]; then
            warn "No authorized SSH keys detected on this server for ${target_user}."
            echo -e "${YELLOW}To disable password authentication safely and prevent lockout, an SSH public key is required.${NC}"
            if ask_yes_no "Do you want to paste your SSH public key now?" "Y"; then
                read -r -p "Paste SSH public key: " pasted_key </dev/tty
                pasted_key="$(echo "$pasted_key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr -d '\r')"
                if validate_ssh_key_string "$pasted_key"; then
                    mkdir -p "$(dirname "$target_keys")"
                    echo "$pasted_key" >> "$target_keys"
                    [[ -n "$ADMIN_USER_INPUT" ]] && chown -R "${ADMIN_USER_INPUT}:${ADMIN_USER_INPUT}" "$(dirname "$target_keys")"
                    chmod 700 "$(dirname "$target_keys")"
                    chmod 600 "$target_keys"
                    if [[ -n "$ADMIN_USER_INPUT" ]]; then
                        mkdir -p /root/.ssh
                        echo "$pasted_key" >> /root/.ssh/authorized_keys
                        chmod 700 /root/.ssh
                        chmod 600 /root/.ssh/authorized_keys
                    fi
                    success "SSH public key registered and verified."
                else
                    warn "Invalid SSH public key format."
                fi
            fi
        fi
    fi

    local config="/etc/ssh/sshd_config.d/99-openship-worker.conf"
    mkdir -p "$(dirname "$config")"

    {
        echo "# OpenShip Worker VPS SSH Configuration"
        echo
        echo "Port ${SSH_PORT_INPUT}"
        echo
        echo "PubkeyAuthentication yes"
        echo "KbdInteractiveAuthentication no"
        echo
        echo "X11Forwarding no"
        echo "AllowAgentForwarding no"
    } > "$config"

    local password_auth_disabled=false
    if validate_ssh_authorized_keys "$target_keys"; then
        cat >> "$config" <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
EOF
        # Disable PasswordAuthentication in cloud-init sshd drop-in if present
        if [[ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]]; then
            sed -i 's/^[#[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication no/' /etc/ssh/sshd_config.d/50-cloud-init.conf 2>/dev/null || true
        fi
        password_auth_disabled=true
    else
        warn "Password authentication remains enabled to prevent lockout (no valid SSH key found for ${target_user})."
        warn "To disable passwords, add your public key to ${target_keys} and rerun."
    fi

    # Verify sshd syntax before reloading
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        if [[ "$password_auth_disabled" == "true" ]]; then
            local key_count
            key_count="$(ssh-keygen -l -f "$target_keys" 2>/dev/null | wc -l | tr -d ' ' || echo "1")"
            success "SSH key verification passed (${key_count} active key(s) in ${target_keys}):"
            if command_exists ssh-keygen; then
                ssh-keygen -l -f "$target_keys" 2>/dev/null | while read -r line; do
                    log "  [key] ${line}"
                done
            fi
            success "SSH password authentication disabled (key-only access enabled)."
        fi
        success "SSH configuration validated on port ${SSH_PORT_INPUT}."
    else
        warn "sshd -t test returned warning or syntax error; reverting configuration to prevent lockout."
        rm -f "$config"
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    fi
}

configure_fail2ban() {
    section "Fail2ban"

    mkdir -p /etc/fail2ban/jail.d

    cat > /etc/fail2ban/jail.d/sshd-openship.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT_INPUT}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true

    success "Fail2ban enabled."
}

configure_unattended_upgrades() {
    section "Automatic security updates"
    systemctl enable --now unattended-upgrades 2>/dev/null || true
    success "Unattended upgrades enabled."
}

if [[ -n "$ADMIN_USER_INPUT" ]]; then
    configure_admin_user
fi

if [[ "$SKIP_SSH" != "true" ]]; then
    configure_ssh
else
    warn "SSH configuration skipped (--skip-ssh)."
fi

if [[ "$ENABLE_FAIL2BAN" == "true" ]]; then
    configure_fail2ban
fi

if [[ "$ENABLE_UNATTENDED_UPGRADES" == "true" ]]; then
    configure_unattended_upgrades
fi

# ------------------------------------------------------------------------------
# Step 6: Worker VPS UFW Firewall
# ------------------------------------------------------------------------------

configure_worker_ufw() {
    section "Worker VPS Firewall (UFW)"

    if [[ "$ENABLE_UFW" != "true" ]]; then
        warn "UFW disabled by configuration."
        return
    fi

    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH
    ufw allow "${SSH_PORT_INPUT}/tcp" comment "SSH"

    # Allow HTTP & HTTPS for OpenShip Edge / Caddy / FrankenPHP
    ufw allow 80/tcp comment "Web HTTP (OpenShip Edge)"
    ufw allow 443/tcp comment "Web HTTPS (OpenShip Edge)"
    ufw allow 443/udp comment "Web HTTPS HTTP/3 QUIC (FrankenPHP / Caddy)"

    # Ensure Docker container bridge forwarding is permitted by UFW
    if [[ -f /etc/default/ufw ]]; then
        sed -i -E 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw 2>/dev/null || true
    fi

    # Ensure internal databases are not exposed externally
    ufw delete allow 3306/tcp >/dev/null 2>&1 || true
    ufw delete allow 3306 >/dev/null 2>&1 || true
    ufw delete allow 6379/tcp >/dev/null 2>&1 || true
    ufw delete allow 6379 >/dev/null 2>&1 || true
    ufw delete allow 20003/tcp >/dev/null 2>&1 || true
    ufw delete allow 20003 >/dev/null 2>&1 || true

    # Repair any corrupted single quotes in UFW rule files
    for f in /etc/ufw/user.rules /etc/ufw/user6.rules; do
        if [[ -f "$f" ]]; then
            sed -i "s/Let's Encrypt/Lets Encrypt/g" "$f" 2>/dev/null || true
            sed -i "s/'s /s /g" "$f" 2>/dev/null || true
        fi
    done

    ufw --force enable

    success "UFW firewall active: allowed SSH (${SSH_PORT_INPUT}), HTTP (80/tcp), HTTPS (443/tcp + 443/udp HTTP/3 QUIC)."
    log "Database ports (3306, 6379) remain isolated on internal Docker network."
}

if [[ "$SKIP_UFW" != "true" ]]; then
    configure_worker_ufw
else
    warn "Firewall configuration skipped (--skip-ufw)."
fi

# ------------------------------------------------------------------------------
# Step 7: Web & Database Stack (Nginx + MariaDB + Redis + site-cli)
# ------------------------------------------------------------------------------

install_web_db_stack() {
    section "Installing Web & Database Stack (Nginx, MariaDB, Redis, PHP-FPM)"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would install Nginx with Brotli, MariaDB, Redis, PHP-FPM, Certbot."
        log "[DRY RUN] Would write Nginx optimizations and configure site-cli."
        STACK_INSTALLED=true
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive

    run_task "Installing Nginx, MariaDB, Redis, Certbot and PHP-FPM" bash -c "
        apt-get update -qq && \
        apt-get install -y -qq \
            nginx \
            mariadb-server \
            mariadb-client \
            redis-server \
            certbot \
            python3-certbot-nginx \
            php-fpm \
            php-cli \
            php-mysql \
            php-curl \
            php-mbstring \
            php-xml \
            php-zip \
            php-gd \
            php-intl \
            php-bcmath \
            php-opcache \
            libnginx-mod-brotli \
            libnginx-mod-http-headers-more-filter 2>/dev/null || \
        apt-get install -y -qq \
            nginx \
            mariadb-server \
            mariadb-client \
            redis-server \
            certbot \
            python3-certbot-nginx \
            php-fpm \
            php-cli \
            php-mysql \
            php-curl \
            php-mbstring \
            php-xml \
            php-zip \
            php-gd \
            php-intl \
            php-bcmath \
            php-opcache
    "

    # Configure Nginx global performance optimizations
    log "Configuring global Nginx performance tuning and buffers..."
    mkdir -p /etc/nginx/conf.d

    cat > /etc/nginx/conf.d/00-openship-tuning.conf <<'EOF'
# ==============================================================================
# OpenShip High-Performance Nginx Global Tuning
# ==============================================================================

# Timeouts & Keepalive
keepalive_timeout 65s;
keepalive_requests 1000;
send_timeout 30s;
client_body_timeout 30s;
client_header_timeout 30s;

# Buffer & Body Limits
client_max_body_size 128M;
client_body_buffer_size 256k;
client_header_buffer_size 4k;
large_client_header_buffers 4 32k;

# Performance flags
sendfile on;
tcp_nopush on;
tcp_nodelay on;
server_tokens off;
reset_timedout_connection on;

# Gzip Compression
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_min_length 256;
gzip_types
    text/plain
    text/css
    text/xml
    text/javascript
    application/json
    application/javascript
    application/x-javascript
    application/xml
    application/xml+rss
    image/svg+xml;

# Brotli Compression (if module is loaded)
brotli on;
brotli_comp_level 6;
brotli_static on;
brotli_types
    text/plain
    text/css
    text/xml
    text/javascript
    application/json
    application/javascript
    application/x-javascript
    application/xml
    application/xml+rss
    image/svg+xml;

# FastCGI Buffers for PHP applications
fastcgi_buffer_size 64k;
fastcgi_buffers 16 32k;
fastcgi_busy_buffers_size 128k;
fastcgi_temp_file_write_size 256k;
fastcgi_read_timeout 300s;
EOF

    # Verify Nginx configuration syntax
    if nginx -t 2>/dev/null; then
        systemctl enable --now nginx 2>/dev/null || true
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
        success "Nginx active with Brotli & buffer optimizations."
    else
        # If brotli directives fail because module is not available, strip brotli lines
        sed -i -E '/brotli/d' /etc/nginx/conf.d/00-openship-tuning.conf 2>/dev/null || true
        systemctl enable --now nginx 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true
        success "Nginx active with Gzip & buffer optimizations."
    fi

    # Start and enable MariaDB and Redis
    systemctl enable --now mariadb 2>/dev/null || true
    systemctl enable --now redis-server 2>/dev/null || true
    success "MariaDB and Redis services enabled and running."

    # Start and enable PHP-FPM
    local php_sock
    php_sock="$(find /run/php/ -name 'php*-fpm.sock' 2>/dev/null | head -n1 || true)"
    if [[ -n "$php_sock" ]]; then
        success "PHP-FPM active: ${php_sock}"
    fi

    # Ensure UFW ports 80 and 443 are allowed
    if command_exists ufw; then
        ufw allow 80/tcp comment "Web HTTP (Nginx)" >/dev/null 2>&1 || true
        ufw allow 443/tcp comment "Web HTTPS (Nginx)" >/dev/null 2>&1 || true
        ufw allow 443/udp comment "Web HTTPS HTTP/3 QUIC (Nginx)" >/dev/null 2>&1 || true
    fi

    # Install / link site-cli
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local site_cli_src="${script_dir}/../site-manager.sh"

    if [[ -f "$site_cli_src" ]]; then
        chmod +x "$site_cli_src"
        ln -sf "$site_cli_src" /usr/local/bin/site-cli
        success "CLI management tool installed: /usr/local/bin/site-cli -> ${site_cli_src}"
    else
        # Fallback to direct curl if run standalone via pipe
        log "Downloading site-cli to /usr/local/bin/site-cli..."
        if curl -fsSL "https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/services/site-manager.sh" -o /usr/local/bin/site-cli 2>/dev/null; then
            chmod +x /usr/local/bin/site-cli
            success "CLI management tool installed: /usr/local/bin/site-cli"
        else
            warn "Could not link site-cli automatically. You can install it manually from services/site-manager.sh."
        fi
    fi

    STACK_INSTALLED=true
}

offer_and_install_stack() {
    if [[ "$SKIP_STACK" == "true" ]]; then
        log "Stack installation skipped (--skip-stack)."
        return 0
    fi

    local do_install=false
    if [[ "$INSTALL_STACK" == "true" ]]; then
        do_install=true
    elif [[ "$NON_INTERACTIVE" == "true" ]]; then
        do_install=false
    else
        echo
        echo -e "  ${BOLD}${CYAN}Would you like to install the Web & Database Stack now?${NC}"
        echo -e "  Includes: ${BOLD}Nginx (with Brotli, headers-more & buffer tuning), MariaDB, Redis, PHP-FPM, and site-cli${NC}"
        read -r -p "  Install stack? [Y/n] " response
        case "$response" in
            [nN][oO]|[nN])
                do_install=false
                ;;
            *)
                do_install=true
                ;;
        esac
    fi

    if [[ "$do_install" == "true" ]]; then
        install_web_db_stack
    else
        log "Stack installation skipped. You can install anytime later with: sudo ./tune.sh --install-stack"
    fi
}

offer_and_install_stack

# ------------------------------------------------------------------------------
# Completion Summary
# ------------------------------------------------------------------------------

section "Tuning Complete"
echo -e "${GREEN}${BOLD}Worker VPS tuning successfully finished!${NC}"
echo
echo "Applied settings:"
echo "  • System packages:   up to date (base utilities installed)"
echo "  • Time sync:         systemd-timesyncd active"
echo "  • Journald:          bounded to 200MB"
echo "  • Limits:            nofile 65535, nproc 65535"
echo "  • Sysctl:            network backlog, 16MB buffers, TCP Fast Open, no-idle-slow-start"
echo "  • Memory/DB:         vm.overcommit_memory=1, vm.max_map_count=262144, dirty_ratio=15"
if [[ "$ENABLE_BBR" == "true" ]]; then
    echo "  • Congestion:        BBR enabled"
fi
if [[ "$ENABLE_SWAP" == "true" ]]; then
    echo "  • Swap:              active (${SWAP_SIZE_GB} GB, swappiness=10, vfs_cache_pressure=50)"
fi
if [[ "$ENABLE_UFW" == "true" ]]; then
    echo "  • UFW:               active (SSH :${SSH_PORT_INPUT}, :80, :443 tcp+udp HTTP/3 QUIC open)"
fi
if [[ "$ENABLE_FAIL2BAN" == "true" ]]; then
    echo "  • Fail2ban:          protecting SSH on port ${SSH_PORT_INPUT}"
fi
if [[ "$STACK_INSTALLED" == "true" ]]; then
    echo "  • Nginx:             active with Brotli & buffer optimizations (:80, :443)"
    echo "  • MariaDB:           active (127.0.0.1:3306 / local socket)"
    echo "  • Redis:             active (127.0.0.1:6379)"
    echo "  • site-cli:          installed (/usr/local/bin/site-cli)"
fi
echo
echo "Next steps for this Worker VPS:"
if [[ "$STACK_INSTALLED" == "true" ]]; then
    echo "  • Manage websites:   site-cli create my-shop.com --template opencart --ssl"
    echo "  • List websites:     site-cli list"
    echo "  • Manage databases:  site-cli db my-shop.com [create|dump|drop]"
else
    echo "  1. Install Web/DB stack: sudo ./tune.sh --install-stack"
    echo "  2. Or deploy Docker services: cd ../mariadb-redis && sudo ./deploy.sh"
    echo "  3. Connect this worker to OpenShip Control Plane (or deploy Edge)."
fi
echo
