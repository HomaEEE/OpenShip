#!/usr/bin/env bash

# ==============================================================================
# OpenShip Control Plane Installer (Standalone Single-File Edition)
# ==============================================================================
#
# Supported:
#   Ubuntu 24.04 LTS
#
# Installation modes:
#   BARE      - OpenShip Control Plane (lightweight Node process, embedded DB)
#               Optionally with OpenShip Edge (:80/:443 via Docker)
#   STANDARD  - Full OpenShip Docker Compose stack
#
# Usage:
#   sudo ./install.sh
#   curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/install.sh | sudo bash
#
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="2.5.0"
readonly OPENSHIP_INSTALL_URL="https://get.openship.io"
readonly GENERATOR_URL="https://homaeee.github.io/OpenShip-deploy/"

readonly LOG_FILE="/var/log/openship-control-install.log"
readonly STATE_DIR="/etc/openship-control"
readonly STATE_FILE="${STATE_DIR}/install.conf"

# Resource thresholds
readonly MIN_RAM_MB=768
readonly LOW_RAM_MB=1024
readonly RECOMMENDED_RAM_MB=2048
readonly MIN_DISK_GB=10

# Configuration defaults (can be set via CLI flags or ENV vars)
INSTALL_MODE="${INSTALL_MODE:-}"
HOSTNAME_INPUT="${HOSTNAME_INPUT:-}"
TIMEZONE_INPUT="${TIMEZONE_INPUT:-}"
SSH_PORT_INPUT="${SSH_PORT_INPUT:-}"
ADMIN_USER_INPUT="${ADMIN_USER_INPUT:-}"
SSH_KEY_INPUT="${SSH_KEY_INPUT:-}"
ENABLE_UFW="${ENABLE_UFW:-}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-}"
ENABLE_SWAP="${ENABLE_SWAP:-}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-}"
OPENSHIP_ADMIN_NAME_INPUT="${OPENSHIP_ADMIN_NAME_INPUT:-}"
OPENSHIP_ADMIN_EMAIL_INPUT="${OPENSHIP_ADMIN_EMAIL_INPUT:-}"
OPENSHIP_ADMIN_PASSWORD_INPUT="${OPENSHIP_ADMIN_PASSWORD_INPUT:-}"
OPENSHIP_DOMAIN_KIND="${OPENSHIP_DOMAIN_KIND:-}"
OPENSHIP_HOST="${OPENSHIP_HOST:-}"
OPENSHIP_PUBLIC_URL="${OPENSHIP_PUBLIC_URL:-}"
OPENSHIP_EDGE_ENABLED="${OPENSHIP_EDGE_ENABLED:-}"
OPENSHIP_PROXY_MODE="${OPENSHIP_PROXY_MODE:-}"
OPENSHIP_NO_HOST_CONTROL="${OPENSHIP_NO_HOST_CONTROL:-}"
CADDY_SSL_MODE="${CADDY_SSL_MODE:-}"
CADDY_ORIGIN_CERT_PATH="${CADDY_ORIGIN_CERT_PATH:-}"
CADDY_ORIGIN_KEY_PATH="${CADDY_ORIGIN_KEY_PATH:-}"
CADDY_ORIGIN_CERT_CONTENT="${CADDY_ORIGIN_CERT_CONTENT:-}"
CADDY_ORIGIN_KEY_CONTENT="${CADDY_ORIGIN_KEY_CONTENT:-}"

# ------------------------------------------------------------------------------
# Colors
# ------------------------------------------------------------------------------

if [[ -t 1 || -p /dev/stdout ]]; then
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

# Terminal width (default 60 if unknown)
_TW="$(tput cols 2>/dev/null || echo 60)"

# ------------------------------------------------------------------------------
# CLI Flag Parser & Help
# ------------------------------------------------------------------------------

DRY_RUN=false
NON_INTERACTIVE=false

show_help() {
    echo "Usage: sudo ./install.sh [OPTIONS]"
    echo
    echo "OpenShip Standalone Control Plane Installer"
    echo
    echo "Web Command & Flag Generator:"
    echo "  ${GENERATOR_URL}"
    echo
    echo "General Options:"
    echo "  --dry-run                    Validate system without modifying configuration"
    echo "  --non-interactive            Run fully unattended with flags or defaults"
    echo "  --mode=bare|standard         Installation mode (bare: embedded Node, standard: compose)"
    echo "  --version, -v                Display version"
    echo "  --help, -h                   Display this help message"
    echo
    echo "System & Network Options:"
    echo "  --hostname=NAME              Control plane hostname (default: openship-control)"
    echo "  --timezone=TZ                Timezone (e.g. UTC, Europe/Kyiv, America/New_York)"
    echo "  --ssh-port=PORT              SSH port (default: 22)"
    echo "  --ssh-key=KEY                Authorize SSH public key (enables key-only SSH access)"
    echo "  --admin-user=USER            System admin Linux username (default: openship)"
    echo "  --enable-ufw / --disable-ufw Configure UFW firewall rules"
    echo "  --enable-fail2ban / --disable-fail2ban Protect SSH with Fail2ban"
    echo "  --enable-swap / --disable-swap Manage swapfile"
    echo "  --swap-size=GB               Swap file size in gigabytes (e.g. 2, 4)"
    echo
    echo "OpenShip Application Options:"
    echo "  --admin-name=NAME            OpenShip dashboard administrator name"
    echo "  --admin-email=EMAIL          OpenShip dashboard administrator email"
    echo "  --admin-password=SECRET      OpenShip dashboard administrator password"
    echo "  --domain=DOMAIN              Domain for OpenShip (alias: --host)"
    echo "  --public-url=URL             Full public URL (e.g. https://os.example.com)"
    echo "  --proxy-mode=MODE            Reverse proxy mode: caddy, edge, or none"
    echo "  --ssl-mode=MODE              Caddy SSL: auto, cloudflare_flexible, cloudflare_origin, http_ip"
    echo "  --origin-cert-path=PATH      Path to Cloudflare Origin CA certificate file"
    echo "  --origin-key-path=PATH       Path to Cloudflare Origin CA private key file"
    echo "  --host-control               Allow dashboard terminal into Control VPS"
    echo "  --no-host-control            Strict isolation (terminal to Control VPS blocked)"
    echo
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --version|-v)
            echo "OpenShip Installer v${SCRIPT_VERSION}"
            exit 0
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        --mode=*)
            INSTALL_MODE="${1#*=}"
            shift
            ;;
        --mode)
            INSTALL_MODE="$2"
            shift 2
            ;;
        --hostname=*)
            HOSTNAME_INPUT="${1#*=}"
            shift
            ;;
        --hostname)
            HOSTNAME_INPUT="$2"
            shift 2
            ;;
        --timezone=*)
            TIMEZONE_INPUT="${1#*=}"
            shift
            ;;
        --timezone)
            TIMEZONE_INPUT="$2"
            shift 2
            ;;
        --ssh-port=*)
            SSH_PORT_INPUT="${1#*=}"
            shift
            ;;
        --ssh-port)
            SSH_PORT_INPUT="$2"
            shift 2
            ;;
        --ssh-key=*)
            SSH_KEY_INPUT="${1#*=}"
            shift
            ;;
        --ssh-key)
            SSH_KEY_INPUT="$2"
            shift 2
            ;;
        --admin-user=*)
            ADMIN_USER_INPUT="${1#*=}"
            shift
            ;;
        --admin-user)
            ADMIN_USER_INPUT="$2"
            shift 2
            ;;
        --admin-name=*)
            OPENSHIP_ADMIN_NAME_INPUT="${1#*=}"
            shift
            ;;
        --admin-name)
            OPENSHIP_ADMIN_NAME_INPUT="$2"
            shift 2
            ;;
        --admin-email=*)
            OPENSHIP_ADMIN_EMAIL_INPUT="${1#*=}"
            shift
            ;;
        --admin-email)
            OPENSHIP_ADMIN_EMAIL_INPUT="$2"
            shift 2
            ;;
        --admin-password=*)
            OPENSHIP_ADMIN_PASSWORD_INPUT="${1#*=}"
            shift
            ;;
        --admin-password)
            OPENSHIP_ADMIN_PASSWORD_INPUT="$2"
            shift 2
            ;;
        --domain=*|--host=*)
            OPENSHIP_HOST="${1#*=}"
            shift
            ;;
        --domain|--host)
            OPENSHIP_HOST="$2"
            shift 2
            ;;
        --public-url=*)
            OPENSHIP_PUBLIC_URL="${1#*=}"
            shift
            ;;
        --public-url)
            OPENSHIP_PUBLIC_URL="$2"
            shift 2
            ;;
        --proxy-mode=*)
            OPENSHIP_PROXY_MODE="${1#*=}"
            shift
            ;;
        --proxy-mode)
            OPENSHIP_PROXY_MODE="$2"
            shift 2
            ;;
        --ssl-mode=*)
            CADDY_SSL_MODE="${1#*=}"
            shift
            ;;
        --ssl-mode)
            CADDY_SSL_MODE="$2"
            shift 2
            ;;
        --origin-cert-path=*)
            CADDY_ORIGIN_CERT_PATH="${1#*=}"
            shift
            ;;
        --origin-cert-path)
            CADDY_ORIGIN_CERT_PATH="$2"
            shift 2
            ;;
        --origin-key-path=*)
            CADDY_ORIGIN_KEY_PATH="${1#*=}"
            shift
            ;;
        --origin-key-path)
            CADDY_ORIGIN_KEY_PATH="$2"
            shift 2
            ;;
        --origin-cert=*)
            CADDY_ORIGIN_CERT_CONTENT="${1#*=}"
            shift
            ;;
        --origin-key=*)
            CADDY_ORIGIN_KEY_CONTENT="${1#*=}"
            shift
            ;;
        --host-control)
            OPENSHIP_NO_HOST_CONTROL=false
            shift
            ;;
        --no-host-control)
            OPENSHIP_NO_HOST_CONTROL=true
            shift
            ;;
        --swap-size=*)
            SWAP_SIZE_GB="${1#*=}"
            ENABLE_SWAP=true
            shift
            ;;
        --swap-size)
            SWAP_SIZE_GB="$2"
            ENABLE_SWAP=true
            shift 2
            ;;
        --enable-swap)
            ENABLE_SWAP=true
            shift
            ;;
        --disable-swap)
            ENABLE_SWAP=false
            SWAP_SIZE_GB=0
            shift
            ;;
        --enable-ufw)
            ENABLE_UFW=true
            shift
            ;;
        --disable-ufw)
            ENABLE_UFW=false
            shift
            ;;
        --enable-fail2ban)
            ENABLE_FAIL2BAN=true
            shift
            ;;
        --disable-fail2ban)
            ENABLE_FAIL2BAN=false
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use --help for available options, or visit: ${GENERATOR_URL}" >&2
            exit 1
            ;;
    esac
done

# Fallback: Auto-detect non-interactive if piped from curl and no TTY is attached
if [[ ! -t 0 && ! -e /dev/tty ]]; then
    NON_INTERACTIVE=true
fi

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

if [[ $EUID -eq 0 ]] || mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; then
    touch "$LOG_FILE" 2>/dev/null || true
    exec > >(tee -a "$LOG_FILE") 2>&1
fi


# ==============================================================================
# OpenShip Installer — Common Utilities, Logging & Prompts
# ==============================================================================

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

    if [[ -e /dev/tty && -w /dev/tty ]]; then
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

# ------------------------------------------------------------------------------
# Error handling
# ------------------------------------------------------------------------------

on_error() {
    local exit_code=$?
    local line_no=$1

    echo
    error "Installation failed."
    error "Line: ${line_no}"
    error "Exit code: ${exit_code}"
    error "Log: ${LOG_FILE}"
    echo

    exit "$exit_code"
}

trap 'on_error ${LINENO}' ERR

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

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
    local answer

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
        y|yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

ask_default() {
    local prompt="$1"
    local default="$2"
    local value

    read -r -p "$prompt [$default]: " value </dev/tty
    value="${value//[$'\r\n']/}"

    echo "${value:-$default}"
}

ask_password() {
    local prompt="$1"
    local password=""
    local char=""

    if [[ ! -e /dev/tty || ! -r /dev/tty ]]; then
        read -r -s -p "$prompt" password
        echo
        echo "${password//[$'\r\n']/}"
        return
    fi

    printf "%s" "$prompt" >/dev/tty

    while IFS= read -r -s -n 1 char </dev/tty; do
        if [[ -z "$char" || "$char" == $'\r' || "$char" == $'\n' ]]; then
            printf "\n" >/dev/tty
            break
        fi

        # Backspace / Delete (127 or \b)
        if [[ "$char" == $'\177' || "$char" == $'\b' ]]; then
            if (( ${#password} > 0 )); then
                password="${password%?}"
                printf "\b \b" >/dev/tty
            fi
        else
            password+="$char"
            printf "*" >/dev/tty
        fi
    done

    echo "${password//[$'\r\n']/}"
}

valid_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]
}

valid_ssh_port() {
    [[ "$1" =~ ^[0-9]+$ ]] &&
        (( "$1" >= 1 && "$1" <= 65535 ))
}

# ------------------------------------------------------------------------------
# Root
# ------------------------------------------------------------------------------

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        die "Run this installer as root or with sudo."
    fi
}

# ------------------------------------------------------------------------------
# OS
# ------------------------------------------------------------------------------


# ==============================================================================
# OpenShip Installer — System Checks & Configuration
# ==============================================================================

check_os() {
    section "Operating system"

    [[ -f /etc/os-release ]] ||
        die "/etc/os-release not found."

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "Ubuntu is required. Detected: ${ID:-unknown}"
    fi

    local major_ver="${VERSION_ID%%.*}"
    if ! [[ "$major_ver" =~ ^[0-9]+$ ]] || (( major_ver < 24 )); then
        warn "This installer is designed for Ubuntu 24+ (detected: Ubuntu ${VERSION_ID:-unknown})."

        if ! ask_yes_no "Continue anyway?" "N"; then
            die "Installation cancelled."
        fi
    fi

    success "Ubuntu ${VERSION_ID:-unknown}"
}

# ------------------------------------------------------------------------------
# Architecture
# ------------------------------------------------------------------------------

check_architecture() {
    section "Architecture"

    local arch
    arch="$(dpkg --print-architecture)"

    case "$arch" in
        amd64|arm64)
            success "Architecture: ${arch}"
            ;;
        *)
            die "Unsupported architecture: ${arch}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Resources
# ------------------------------------------------------------------------------

detect_resources() {
    RAM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
    DISK_GB="$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')"
    CPU_COUNT="$(nproc)"
}

check_resources() {
    section "System resources"

    detect_resources

    echo "RAM:         ${RAM_MB} MB"
    echo "Minimum:     ${MIN_RAM_MB} MB (Bare Control Plane)"
    echo "Recommended: ${RECOMMENDED_RAM_MB} MB (Standard Docker Stack)"
    echo "CPU cores:   ${CPU_COUNT}"
    echo "Disk:        ${DISK_GB} GB free"
    echo

    if (( RAM_MB < MIN_RAM_MB )); then
        die "At least ${MIN_RAM_MB} MiB RAM is required. Detected: ${RAM_MB} MB."
    elif (( RAM_MB < LOW_RAM_MB )); then
        warn "Low-memory VPS detected: ${RAM_MB} MB RAM (supported with warning)."
        warn "Bare mode is required. Standard Docker mode is not recommended."
    elif (( RAM_MB < RECOMMENDED_RAM_MB )); then
        success "RAM: ${RAM_MB} MB (supported for Bare Control Plane)."
    else
        success "RAM is sufficient for Standard mode (${RAM_MB} MB)."
    fi

    if (( DISK_GB < MIN_DISK_GB )); then
        die "At least ${MIN_DISK_GB} GB free disk space is required."
    fi

    success "Resource check passed."
}

# ------------------------------------------------------------------------------
# Installation mode selection
# ------------------------------------------------------------------------------


configure_hostname() {
    section "Hostname"

    hostnamectl set-hostname "$HOSTNAME_INPUT"

    if grep -qE '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
        sed -i \
            "s/^127\.0\.1\.1.*/127.0.1.1 ${HOSTNAME_INPUT}/" \
            /etc/hosts
    else
        echo "127.0.1.1 ${HOSTNAME_INPUT}" >> /etc/hosts
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
        timedatectl set-timezone UTC || true
        warn "Timezone set to UTC."
    fi
}

# ------------------------------------------------------------------------------
# System packages & update
# ------------------------------------------------------------------------------

install_and_update_packages() {
    section "System packages & update"

    export DEBIAN_FRONTEND=noninteractive

    wait_for_dpkg_lock() {
        local max_wait=120
        local waited=0
        while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1 || pgrep -x "unattended-upgrades|apt.systemd.daily" >/dev/null 2>&1; do
            if [[ $waited -ge $max_wait ]]; then
                warn "dpkg lock held for >${max_wait}s. Stopping background upgrade services..."
                systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
                killall -9 unattended-upgrade apt-get apt dpkg 2>/dev/null || true
                fuser -k -9 /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock 2>/dev/null || true
                rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
                dpkg --configure -a 2>/dev/null || true
                break
            fi
            log "Waiting for background apt/dpkg update to release lock (${waited}s)..."
            sleep 5
            waited=$((waited + 5))
        done
    }

    # Clean up broken/expired Caddy Cloudsmith repos from previous runs before apt-get update
    rm -f /etc/apt/sources.list.d/caddy-stable.list /etc/apt/sources.list.d/caddy-stable.sources /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    wait_for_dpkg_lock
    run_task "Updating package lists" apt-get update -qq

    run_task "Upgrading system packages" env DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    run_task "Installing base packages" apt-get install -y -qq \
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
        warn "A system restart is recommended after kernel/library updates."
        warn "You can complete the OpenShip installation now and reboot afterward."
    fi
}

# ------------------------------------------------------------------------------
# System tuning
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

optimize_system() {
    section "System tuning & resource optimization"

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
        log "Low-memory profile active (< 2GB RAM): conservative socket buffers (4MB) and journald (50MB)."
    fi

    # 4. File descriptor & process limits
    log "Configuring file descriptor & process limits (nofile 65535, nproc 65535)..."
    cat > /etc/security/limits.d/99-openship.conf <<'EOF'
* soft nofile 65535
* hard nofile 131072
root soft nofile 65535
root hard nofile 131072
* soft nproc 65535
* hard nproc 65535
root soft nproc 65535
root hard nproc 65535
EOF

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
    if modprobe tcp_bbr 2>/dev/null; then
        mkdir -p /etc/modules-load.d
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
        bbr_applied=true
        log "BBR congestion control module loaded."
    fi

    # 7. Sysctl low-latency & memory tuning
    modprobe br_netfilter 2>/dev/null || true
    log "Applying kernel network, low-latency, and memory optimizations..."
    cat > /etc/sysctl.d/99-openship-control.conf <<EOF
# OpenShip Kernel & Network Tuning

# Network connection backlog & buffers
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535

# Socket buffer sizes (Dynamic based on RAM)
net.core.rmem_max = ${sock_buf_max}
net.core.wmem_max = ${sock_buf_max}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 ${sock_buf_max}
net.ipv4.tcp_wmem = 4096 87380 ${sock_buf_max}

# Low-latency TCP (reduces TTFB)
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 1024 65535

# Keepalive timeouts
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# Memory management & swapping
vm.overcommit_memory = 1
vm.max_map_count = 262144
vm.min_free_kbytes = ${min_free_kb}
vm.panic_on_oom = 0
vm.oom_kill_allocating_task = 0
vm.swappiness = 20
vm.vfs_cache_pressure = 50
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
        cat >> /etc/sysctl.d/99-openship-control.conf <<'EOF'
# TCP BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    fi

    sysctl --system >> "$LOG_FILE" 2>&1 || true

    # 8. CPU scaling governor
    configure_cpu_governor

    # 9. Transparent HugePages (THP = never)
    configure_thp

    # 10. Disk I/O & noatime
    configure_disk_io

    success "System tuning applied successfully."
}

# ------------------------------------------------------------------------------
# Swap (Hybrid zRAM + Swapfile)
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

    if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
        echo '/swapfile none swap sw,pri=10 0 0' >> /etc/fstab
    fi

    success "${swap_gb} GB disk swap configured (hybrid zRAM + swapfile active)."
}

# ------------------------------------------------------------------------------
# Administrator user
# ------------------------------------------------------------------------------


# ==============================================================================
# OpenShip Installer — Security, SSH, UFW, Fail2ban
# ==============================================================================

configure_admin_user() {
    section "Administrator user"

    if id "$ADMIN_USER_INPUT" >/dev/null 2>&1; then
        log "User '${ADMIN_USER_INPUT}' already exists."
    else
        adduser \
            --disabled-password \
            --gecos "" \
            "$ADMIN_USER_INPUT"
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

# ------------------------------------------------------------------------------
# SSH
# ------------------------------------------------------------------------------

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
        if [[ "${NON_INTERACTIVE:-false}" != "true" && -e /dev/tty && -r /dev/tty ]]; then
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

    local config="/etc/ssh/sshd_config.d/99-openship-control.conf"
    mkdir -p "$(dirname "$config")"

    {
        echo "# OpenShip Control Plane"
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
        success "SSH configuration validated."
    else
        warn "sshd -t test returned warning or syntax error; reverting configuration to prevent lockout."
        rm -f "$config"
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# UFW
# ------------------------------------------------------------------------------

configure_ufw() {
    section "Firewall"

    if [[ "$ENABLE_UFW" != "true" ]]; then
        warn "UFW disabled."
        return
    fi

    ufw default deny incoming
    ufw default allow outgoing

    ufw allow "${SSH_PORT_INPUT}/tcp" \
        comment "SSH"

    # Web ports (:80/:443) — only when Edge or Caddy is enabled.
    # In Private mode (no proxy), only SSH is exposed.
    if [[ "${OPENSHIP_EDGE_ENABLED:-false}" == "true" || "${OPENSHIP_PROXY_MODE:-none}" == "caddy" ]]; then
        ufw allow 80/tcp \
            comment "Web HTTP (ACME + proxy)"

        ufw allow 443/tcp \
            comment "Web HTTPS"

        ufw allow 443/udp \
            comment "Web HTTPS (HTTP/3 QUIC)"

        log "UFW: opened :80 (ACME challenge), :443/tcp (TLS), and :443/udp (HTTP/3 QUIC) for web traffic."
    else
        log "UFW: Private mode — :80/:443 NOT opened (no public proxy)."
    fi

    # Ensure Docker container bridge forwarding is permitted by UFW
    if [[ -f /etc/default/ufw ]]; then
        sed -i -E 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw 2>/dev/null || true
    fi

    # Repair any corrupted single quotes in UFW rule files
    for f in /etc/ufw/user.rules /etc/ufw/user6.rules; do
        if [[ -f "$f" ]]; then
            sed -i "s/Let's Encrypt/Lets Encrypt/g" "$f" 2>/dev/null || true
            sed -i "s/'s /s /g" "$f" 2>/dev/null || true
        fi
    done

    # Ensure ports 3001 and 4000 are closed externally (Caddy reverse-proxies :80/:443 to localhost)
    ufw delete allow 3001/tcp >/dev/null 2>&1 || true
    ufw delete allow 3001 >/dev/null 2>&1 || true
    ufw delete allow 4000/tcp >/dev/null 2>&1 || true
    ufw delete allow 4000 >/dev/null 2>&1 || true

    ufw --force enable

    success "UFW enabled (ports 3001/4000 secured, Docker bridge forwarding enabled)."
}

# ------------------------------------------------------------------------------
# Fail2ban
# ------------------------------------------------------------------------------

configure_fail2ban() {
    section "Fail2ban"

    if [[ "$ENABLE_FAIL2BAN" != "true" ]]; then
        warn "Fail2ban disabled."
        return
    fi

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

    systemctl enable fail2ban
    systemctl restart fail2ban

    success "Fail2ban enabled."
}

# ------------------------------------------------------------------------------
# Automatic security updates
# ------------------------------------------------------------------------------

configure_unattended_upgrades() {
    section "Automatic security updates"

    systemctl enable --now unattended-upgrades

    success "Unattended upgrades enabled."
}

# ------------------------------------------------------------------------------
# Docker
# ------------------------------------------------------------------------------


# ==============================================================================
# OpenShip Installer — Docker Engine, Compose & Network
# ==============================================================================

install_docker() {
    section "Docker Engine"

    if [[ "$INSTALL_MODE" == "bare" && "${OPENSHIP_EDGE_ENABLED:-false}" != "true" && "${OPENSHIP_NO_HOST_CONTROL:-false}" == "true" ]]; then
        log "Bare mode with strict isolation (--no-host-control) and without Edge."
        log "Docker installation skipped."
        return
    fi

    if [[ "$INSTALL_MODE" == "bare" ]]; then
        if [[ "${OPENSHIP_NO_HOST_CONTROL:-false}" != "true" ]]; then
            log "Host control is ENABLED: Docker Engine is required for OpenShip to monitor This Server."
        elif [[ "${OPENSHIP_EDGE_ENABLED:-false}" == "true" ]]; then
            log "OpenShip Edge (:80/:443) container requires Docker Engine."
        fi
    fi

    if command_exists docker; then
        success "Docker already installed: $(docker --version)"
        return
    fi

    run_task "Adding Docker repository" bash -c '
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        # shellcheck disable=SC1091
        source /etc/os-release
        cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-${VERSION_CODENAME}} stable
EOF
        apt-get update -qq
    '

    run_task "Installing Docker CE Engine" apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    run_task "Starting Docker daemon" systemctl enable --now docker
}

# ------------------------------------------------------------------------------
# Docker daemon
# ------------------------------------------------------------------------------

configure_docker() {
    if ! command_exists docker; then
        return
    fi

    section "Docker configuration"

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

    systemctl restart docker

    docker info >/dev/null

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

    success "Docker daemon configured & optimized (overlay2, systemd cgroup, prune timer)."
}

# ------------------------------------------------------------------------------
# Runtime mode enforcement
# ------------------------------------------------------------------------------

prepare_runtime_for_openship() {
    section "OpenShip runtime"

    if [[ "$INSTALL_MODE" == "bare" ]]; then
        if command_exists docker; then
            log "Docker is available for the OpenShip Edge container (:80/:443)."
            log "OpenShip Control Plane will run as a lightweight Bare process."
        fi

        if [[ "${OPENSHIP_NO_HOST_CONTROL:-false}" == "true" ]]; then
            success "Bare runtime selected: OpenShip will start with --bare --no-host-control."
        else
            success "Bare runtime selected: OpenShip will start with --bare (host control enabled)."
        fi
        return
    fi

    command_exists docker ||
        die "Standard mode requires Docker."

    success "Standard runtime selected: OpenShip will use Docker Compose."
}

# ------------------------------------------------------------------------------
# OpenShip CLI
# ------------------------------------------------------------------------------


ensure_openship_docker_network() {
    local net_name="openship"
    if command_exists docker && docker info >/dev/null 2>&1; then
        if ! docker network inspect "$net_name" >/dev/null 2>&1; then
            run_task "Creating shared Docker network '${net_name}'" \
                docker network create --driver bridge --opt "com.docker.network.bridge.enable_icc=true" "$net_name"
        else
            ok "Docker network '${net_name}' already exists"
        fi
    fi
}

# ==============================================================================
# OpenShip Installer — Caddy Reverse Proxy & Cloudflare SSL
# ==============================================================================

collect_cloudflare_origin_credentials() {
    local domain="$1"
    local cert_file="/etc/caddy/certs/${domain}.crt"
    local key_file="/etc/caddy/certs/${domain}.key"

    mkdir -p /etc/caddy/certs
    chmod 755 /etc/caddy/certs

    if [[ -n "${CADDY_ORIGIN_CERT_CONTENT:-}" && -n "${CADDY_ORIGIN_KEY_CONTENT:-}" ]]; then
        printf "%s\n" "$CADDY_ORIGIN_CERT_CONTENT" > "$cert_file"
        printf "%s\n" "$CADDY_ORIGIN_KEY_CONTENT" > "$key_file"
        chmod 644 "$cert_file"
        chmod 640 "$key_file"
        CADDY_ORIGIN_CERT_PATH="$cert_file"
        CADDY_ORIGIN_KEY_PATH="$key_file"
        success "Cloudflare Origin CA certificate and key installed from input."
        return
    fi

    if [[ -n "${CADDY_ORIGIN_CERT_PATH:-}" && -f "${CADDY_ORIGIN_CERT_PATH:-}" && -n "${CADDY_ORIGIN_KEY_PATH:-}" && -f "${CADDY_ORIGIN_KEY_PATH:-}" ]]; then
        if [[ "$CADDY_ORIGIN_CERT_PATH" != "$cert_file" ]]; then
            cp -f "$CADDY_ORIGIN_CERT_PATH" "$cert_file"
            CADDY_ORIGIN_CERT_PATH="$cert_file"
        fi
        if [[ "$CADDY_ORIGIN_KEY_PATH" != "$key_file" ]]; then
            cp -f "$CADDY_ORIGIN_KEY_PATH" "$key_file"
            CADDY_ORIGIN_KEY_PATH="$key_file"
        fi
        chmod 644 "$cert_file"
        chmod 640 "$key_file"
        success "Cloudflare Origin CA certificate and key loaded from paths."
        return
    fi

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        die "Origin SSL mode selected without valid certificate/key files or content."
    fi

    echo
    echo "Provide Cloudflare Origin Certificate & Private Key for ${domain}:"
    echo "  1) Paste PEM content directly in terminal"
    echo "  2) Specify paths to existing files on this server"
    echo

    local method_choice
    read -r -p "Select [1]: " method_choice </dev/tty
    method_choice="${method_choice//[$'\r\n\t ']/}"
    method_choice="${method_choice:-1}"

    if [[ "$method_choice" == "2" ]]; then
        while true; do
            local input_cert
            input_cert="$(ask_default "Path to Origin Certificate (.crt/.pem)" "")"
            if [[ -f "$input_cert" ]]; then
                cp -f "$input_cert" "$cert_file"
                chmod 644 "$cert_file"
                break
            fi
            warn "File not found: ${input_cert}"
        done

        while true; do
            local input_key
            input_key="$(ask_default "Path to Private Key (.key)" "")"
            if [[ -f "$input_key" ]]; then
                cp -f "$input_key" "$key_file"
                chmod 600 "$key_file"
                break
            fi
            warn "File not found: ${input_key}"
        done
    else
        while true; do
            echo
            echo -e "  ${BOLD}Paste Cloudflare Origin Certificate (.pem/.crt):${NC}"
            echo -e "  ${DIM}(Starts with '-----BEGIN CERTIFICATE-----', automatically ends after '-----END CERTIFICATE-----')${NC}"
            : > "$cert_file"
            while IFS= read -r line </dev/tty; do
                echo "$line" >> "$cert_file"
                if [[ "$line" == *"END CERTIFICATE"* ]]; then
                    break
                fi
            done
            chmod 644 "$cert_file"

            if grep -q "BEGIN CERTIFICATE" "$cert_file" && grep -q "END CERTIFICATE" "$cert_file"; then
                success "Certificate captured."
                break
            fi
            warn "Invalid certificate: missing 'BEGIN CERTIFICATE' or 'END CERTIFICATE' markers. Try again."
        done

        while true; do
            echo
            echo -e "  ${BOLD}Paste Cloudflare Private Key (.key):${NC}"
            echo -e "  ${DIM}(Starts with '-----BEGIN ... KEY-----', automatically ends after '-----END ... KEY-----')${NC}"
            : > "$key_file"
            while IFS= read -r line </dev/tty; do
                echo "$line" >> "$key_file"
                if [[ "$line" == *"END "* && "$line" == *"KEY-----"* ]]; then
                    break
                fi
            done
            chmod 640 "$key_file"

            if grep -q "BEGIN" "$key_file" && grep -q "END" "$key_file" && grep -q "KEY" "$key_file"; then
                success "Private key captured."
                break
            fi
            warn "Invalid private key: missing 'BEGIN' or 'END' markers. Try again."
        done
    fi

    CADDY_ORIGIN_CERT_PATH="$cert_file"
    CADDY_ORIGIN_KEY_PATH="$key_file"
    success "Cloudflare Origin CA certificate and key configured."
}


install_caddy_package() {
    rm -f /etc/apt/sources.list.d/caddy*.sources /etc/apt/sources.list.d/caddy*.list /etc/apt/trusted.gpg.d/caddy*.gpg /usr/share/keyrings/caddy*.gpg

    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    [[ "$arch" == "x86_64" ]] && arch="amd64"
    [[ "$arch" == "aarch64" ]] && arch="arm64"

    local tag ver deb_url
    tag="$(basename "$(curl -sIL -o /dev/null -w '%{url_effective}' https://github.com/caddyserver/caddy/releases/latest 2>/dev/null)")"
    ver="${tag#v}"
    if [[ -n "$ver" && "$ver" =~ ^[0-9]+\.[0-9]+ ]]; then
        deb_url="https://github.com/caddyserver/caddy/releases/download/${tag}/caddy_${ver}_linux_${arch}.deb"
    else
        deb_url="https://github.com/caddyserver/caddy/releases/download/v2.8.4/caddy_2.8.4_linux_${arch}.deb"
    fi

    if ! curl -fsSL "$deb_url" -o /tmp/caddy.deb || [[ ! -s /tmp/caddy.deb ]]; then
        curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v2.8.4/caddy_2.8.4_linux_${arch}.deb" -o /tmp/caddy.deb
    fi

    dpkg -i /tmp/caddy.deb || (apt-get install -f -y -qq && dpkg -i /tmp/caddy.deb)
    rm -f /tmp/caddy.deb

    command -v caddy >/dev/null 2>&1
}

configure_caddy() {
    if [[ "${OPENSHIP_PROXY_MODE:-none}" != "caddy" ]]; then
        return
    fi

    section "Caddy Reverse Proxy"

    if ! command_exists caddy; then
        run_task "Installing Caddy web server" install_caddy_package
    else
        success "Caddy is already installed."
    fi

    local site_address="${OPENSHIP_HOST}"
    local tls_directive=""
    local proto_header="        header_up X-Forwarded-Proto https"

    if [[ -z "${OPENSHIP_HOST}" || "${CADDY_SSL_MODE:-auto}" == "http_ip" ]]; then
        site_address=":80"
        proto_header=""
    elif [[ "${CADDY_SSL_MODE:-auto}" == "cloudflare_flexible" ]]; then
        site_address="http://${OPENSHIP_HOST}"
    elif [[ "${CADDY_SSL_MODE:-auto}" == "cloudflare_origin" && -n "${CADDY_ORIGIN_CERT_PATH:-}" && -f "${CADDY_ORIGIN_CERT_PATH:-}" && -n "${CADDY_ORIGIN_KEY_PATH:-}" && -f "${CADDY_ORIGIN_KEY_PATH:-}" ]]; then
        tls_directive="    tls ${CADDY_ORIGIN_CERT_PATH} ${CADDY_ORIGIN_KEY_PATH}"
        chown -R caddy:caddy /etc/caddy/certs 2>/dev/null || true
        chmod 755 /etc/caddy/certs 2>/dev/null || true
        chmod 644 /etc/caddy/certs/*.crt 2>/dev/null || true
        chmod 640 /etc/caddy/certs/*.key 2>/dev/null || true
    fi

    write_caddyfile() {
        mkdir -p /etc/caddy
        cat > /etc/caddy/Caddyfile <<EOF
${site_address} {
${tls_directive}
    # OpenShip API (port 4000) for frontend same-origin proxy (including terminal WebSockets)
    handle_path /api/proxy/* {
        reverse_proxy 127.0.0.1:4000 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
${proto_header}
        }
    }

    # OpenShip API (port 4000) for direct API requests
    handle /api/* {
        reverse_proxy 127.0.0.1:4000 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
${proto_header}
        }
    }

    # OpenShip Dashboard UI (port 3001) for all other web requests
    handle {
        reverse_proxy 127.0.0.1:3001 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
${proto_header}
        }
    }
}
EOF
        chmod 644 /etc/caddy/Caddyfile
        systemctl enable caddy
        systemctl restart caddy
    }

    run_task "Configuring Caddyfile (${site_address} -> :3001, :4000)" write_caddyfile

    verify_caddy_service() {
        for i in {1..5}; do
            if systemctl is-active --quiet caddy; then
                return 0
            fi
            sleep 1
        done
        journalctl -u caddy --no-pager -n 20
        return 1
    }

    run_task "Verifying Caddy service health" verify_caddy_service

    success "Caddy configured and running for ${OPENSHIP_PUBLIC_URL}"
}

# ------------------------------------------------------------------------------
# Post-install
# ------------------------------------------------------------------------------


# ==============================================================================
# OpenShip Installer — OpenShip CLI, Runtime & Service Setup
# ==============================================================================

collect_bare_openship_credentials() {
    section "OpenShip Control Plane Credentials & Domain"

    # Administrator Name
    if [[ -z "${OPENSHIP_ADMIN_NAME_INPUT:-}" ]]; then
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            OPENSHIP_ADMIN_NAME_INPUT="${ADMIN_USER_INPUT:-Admin}"
        else
            OPENSHIP_ADMIN_NAME_INPUT="$(ask_default "OpenShip administrator name" "$ADMIN_USER_INPUT")"
        fi
    fi
    success "OpenShip admin name: ${OPENSHIP_ADMIN_NAME_INPUT}"

    # Administrator Email
    if [[ -z "${OPENSHIP_ADMIN_EMAIL_INPUT:-}" ]]; then
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            OPENSHIP_ADMIN_EMAIL_INPUT="admin@${OPENSHIP_HOST:-example.com}"
        else
            while true; do
                OPENSHIP_ADMIN_EMAIL_INPUT="$(ask_default "OpenShip administrator email" "")"
                if [[ "$OPENSHIP_ADMIN_EMAIL_INPUT" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
                    break
                fi
                warn "Enter a valid email address."
            done
        fi
    fi
    success "OpenShip admin email: ${OPENSHIP_ADMIN_EMAIL_INPUT}"

    # Administrator Password
    if [[ -z "${OPENSHIP_ADMIN_PASSWORD_INPUT:-}" ]]; then
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            OPENSHIP_ADMIN_PASSWORD_INPUT="$(openssl rand -hex 16)"
            log "Non-interactive: generated random admin password."
        else
            while true; do
                OPENSHIP_ADMIN_PASSWORD_INPUT="$(ask_password "OpenShip administrator password: ")"
                if [[ -z "$OPENSHIP_ADMIN_PASSWORD_INPUT" ]]; then
                    warn "Password cannot be empty."
                    continue
                fi
                if (( ${#OPENSHIP_ADMIN_PASSWORD_INPUT} < 8 )); then
                    warn "Password must contain at least 8 characters (entered: ${#OPENSHIP_ADMIN_PASSWORD_INPUT})."
                    continue
                fi
                break
            done
        fi
    fi
    success "Password accepted (${#OPENSHIP_ADMIN_PASSWORD_INPUT} characters)."

    # Domain & Proxy configuration
    local default_host="${OPENSHIP_HOST:-}"
    if [[ -z "$default_host" && "$HOSTNAME_INPUT" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$ ]]; then
        default_host="$HOSTNAME_INPUT"
    fi
    OPENSHIP_HOST="${OPENSHIP_HOST:-$default_host}"
    OPENSHIP_HOST="${OPENSHIP_HOST#*://}"
    OPENSHIP_HOST="${OPENSHIP_HOST%%/*}"

    if [[ -n "${OPENSHIP_PROXY_MODE:-}" ]]; then
        case "$OPENSHIP_PROXY_MODE" in
            caddy)
                OPENSHIP_DOMAIN_KIND="byo"
                OPENSHIP_EDGE_ENABLED="false"
                if [[ -n "$OPENSHIP_HOST" ]]; then
                    OPENSHIP_PUBLIC_URL="https://$OPENSHIP_HOST"
                    CADDY_SSL_MODE="${CADDY_SSL_MODE:-auto}"
                    if [[ "$CADDY_SSL_MODE" == "cloudflare_origin" ]]; then
                        collect_cloudflare_origin_credentials "$OPENSHIP_HOST"
                    fi
                else
                    SERVER_IP="$(curl -4s --max-time 3 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
                    OPENSHIP_PUBLIC_URL="http://${SERVER_IP:-localhost}"
                    CADDY_SSL_MODE="http_ip"
                fi
                ;;
            edge)
                OPENSHIP_DOMAIN_KIND="custom"
                OPENSHIP_EDGE_ENABLED="true"
                OPENSHIP_PUBLIC_URL="https://$OPENSHIP_HOST"
                ;;
            none)
                if [[ -n "$OPENSHIP_HOST" ]]; then
                    OPENSHIP_DOMAIN_KIND="byo"
                    OPENSHIP_PUBLIC_URL="https://$OPENSHIP_HOST"
                else
                    OPENSHIP_DOMAIN_KIND="none"
                    OPENSHIP_PUBLIC_URL=""
                fi
                OPENSHIP_EDGE_ENABLED="false"
                ;;
        esac
        success "Proxy mode configured: ${OPENSHIP_PROXY_MODE} (domain: ${OPENSHIP_HOST:-none})"
    elif [[ "$NON_INTERACTIVE" == "true" ]]; then
        if [[ -n "$OPENSHIP_HOST" ]]; then
            OPENSHIP_PROXY_MODE="caddy"
            OPENSHIP_DOMAIN_KIND="byo"
            OPENSHIP_EDGE_ENABLED="false"
            OPENSHIP_PUBLIC_URL="https://$OPENSHIP_HOST"
            CADDY_SSL_MODE="${CADDY_SSL_MODE:-auto}"
        else
            OPENSHIP_PROXY_MODE="none"
            OPENSHIP_DOMAIN_KIND="none"
            OPENSHIP_EDGE_ENABLED="false"
            OPENSHIP_PUBLIC_URL=""
        fi
        success "Non-interactive reachability: ${OPENSHIP_PROXY_MODE}"
    else
        echo
        echo "OpenShip instance reachability:"
        echo
        echo "  1) Public HTTPS via OpenShip Edge (Docker required)"
        echo "     Use OpenShip containerized Edge (:80/:443) with Let's Encrypt."
        echo
        echo "  2) Local / private"
        echo "     Dashboard stays on internal port 3001 without public ingress."
        echo "     Cloudflare Tunnel or custom VPN can be configured later."
        echo
        echo "  3) Public HTTPS via Caddy (Native, no Docker — Recommended for Bare)"
        echo "     Installs Caddy, auto-issues SSL certificate, and reverse-proxies"
        echo "     :80/:443 directly to OpenShip (:3001). Ultra-lightweight."
        echo
        echo "  4) Cancel"
        echo
        if [[ -n "$default_host" ]]; then
            echo -e "  ${DIM}Pre-filled domain from hostname: ${BOLD}${default_host}${NC}"
            echo
        fi

        while true; do
            read -r -p "Select [3]: " reachability </dev/tty
            reachability="${reachability//[$'\r\n\t ']/}"
            reachability="${reachability:-3}"
            case "$reachability" in
                1)
                    OPENSHIP_DOMAIN_KIND="custom"
                    OPENSHIP_EDGE_ENABLED="true"
                    OPENSHIP_PROXY_MODE="edge"
                    while true; do
                        OPENSHIP_HOST="$(ask_default "OpenShip domain" "${default_host:-os.example.com}")"
                        if [[ "$OPENSHIP_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$ ]]; then
                            break
                        fi
                        warn "Enter a valid DNS hostname, for example os.example.com."
                    done
                    OPENSHIP_PUBLIC_URL="https://$OPENSHIP_HOST"
                    break
                    ;;
                2)
                    OPENSHIP_DOMAIN_KIND="none"
                    OPENSHIP_EDGE_ENABLED="false"
                    OPENSHIP_PROXY_MODE="none"
                    OPENSHIP_PUBLIC_URL=""
                    warn "Local mode: OpenShip runs without a public HTTPS domain."
                    warn "GitHub App creation requires HTTPS; raw IP/local will fail with: 'redirect_url must be a valid URL'."
                    break
                    ;;
                3)
                    OPENSHIP_DOMAIN_KIND="byo"
                    OPENSHIP_EDGE_ENABLED="false"
                    OPENSHIP_PROXY_MODE="caddy"
                    if [[ -n "$default_host" ]]; then
                        OPENSHIP_HOST="$(ask_default "OpenShip domain" "$default_host")"
                    else
                        OPENSHIP_HOST="$(ask_default "OpenShip domain (or press Enter for direct IP on :80)" "")"
                    fi
                    if [[ -n "$OPENSHIP_HOST" ]]; then
                        while true; do
                            if [[ "$OPENSHIP_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$ ]]; then
                                break
                            fi
                            warn "Enter a valid DNS hostname, for example os.example.com."
                            OPENSHIP_HOST="$(ask_default "OpenShip domain" "$default_host")"
                        done
                        OPENSHIP_PUBLIC_URL="https://$OPENSHIP_HOST"

                        echo
                        echo "Caddy proxy / SSL mode for ${OPENSHIP_HOST}:"
                        echo
                        echo "  1) Cloudflare Flexible mode (Recommended if Cloudflare is in Flexible)"
                        echo "     Caddy listens on HTTP (:80), no SSL certificates needed on server."
                        echo "     Cloudflare handles HTTPS for clients. Zero maintenance, no redirect loops."
                        echo
                        echo "  2) Cloudflare Origin CA certificate (For Cloudflare Full / Full strict)"
                        echo "     Paste your 15-year Origin Certificate from Cloudflare Dashboard."
                        echo "     Immune to ACME challenges and rate limits."
                        echo
                        echo "  3) Automatic Let's Encrypt / ZeroSSL (Standard Caddy auto-TLS)"
                        echo "     Caddy requests and renews certificates via ACME HTTP-01."
                        echo

                        while true; do
                            read -r -p "Select SSL mode [1]: " ssl_choice </dev/tty
                            ssl_choice="${ssl_choice//[$'\r\n\t ']/}"
                            ssl_choice="${ssl_choice:-1}"
                            case "$ssl_choice" in
                                1)
                                    CADDY_SSL_MODE="cloudflare_flexible"
                                    success "Caddy mode: Cloudflare Flexible (HTTP :80, no local SSL)."
                                    break
                                    ;;
                                2)
                                    CADDY_SSL_MODE="cloudflare_origin"
                                    collect_cloudflare_origin_credentials "$OPENSHIP_HOST"
                                    break
                                    ;;
                                3)
                                    CADDY_SSL_MODE="auto"
                                    success "Caddy SSL: Automatic Let's Encrypt."
                                    echo
                                    echo -e "  ${YELLOW}Notice for Cloudflare users:${NC}"
                                    echo -e "  ${DIM}If ${OPENSHIP_HOST} is on Cloudflare, ensure its DNS record is${NC}"
                                    echo -e "  ${DIM}temporarily set to 'DNS only' (gray cloud) so Let's Encrypt can verify.${NC}"
                                    echo -e "  ${DIM}You can switch back to 'Proxied' + Full (strict) immediately after install.${NC}"
                                    echo
                                    break
                                    ;;
                                *)
                                    echo "Invalid choice."
                                    ;;
                            esac
                        done
                    else
                        SERVER_IP="$(curl -4s --max-time 3 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
                        OPENSHIP_PUBLIC_URL="http://${SERVER_IP:-localhost}"
                        CADDY_SSL_MODE="http_ip"
                        success "Caddy mode: direct IP HTTP on port :80 (${OPENSHIP_PUBLIC_URL})."
                        warn "Notice: GitHub App creation requires an HTTPS domain. Raw HTTP/IP will fail with: 'redirect_url must be a valid URL'."
                    fi
                    break
                    ;;
                4)
                    die "Installation cancelled."
                    ;;
                *)
                    echo "Invalid choice."
                    ;;
            esac
        done
    fi

    # Host Control
    if [[ -z "${OPENSHIP_NO_HOST_CONTROL:-}" ]]; then
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            OPENSHIP_NO_HOST_CONTROL="false"
        else
            echo
            echo -e "${BOLD}OpenShip Host Control Mode${NC}"
            echo
            echo "OpenShip can optionally manage the Control VPS itself as a server."
            echo "  1) Full control (Recommended for most setups)"
            echo "  2) Strict isolation (--no-host-control)"
            echo

            while true; do
                read -r -p "Select [1]: " hc_choice </dev/tty
                hc_choice="${hc_choice//[$'\r\n\t ']/}"
                hc_choice="${hc_choice:-1}"
                case "$hc_choice" in
                    1)
                        OPENSHIP_NO_HOST_CONTROL="false"
                        break
                        ;;
                    2)
                        OPENSHIP_NO_HOST_CONTROL="true"
                        break
                        ;;
                    *)
                        echo "Invalid choice."
                        ;;
                esac
            done
        fi
    fi

    if [[ "$OPENSHIP_NO_HOST_CONTROL" == "true" ]]; then
        warn "Host control: DISABLED (--no-host-control)"
    else
        success "Host control: ENABLED"
    fi

    echo
    success "OpenShip Control Plane parameters collected."
}


install_openship_cli() {
    section "OpenShip CLI"

    if command_exists openship; then
        success "OpenShip CLI already installed: $(openship --version 2>/dev/null || true)"
        return
    fi

    run_task "Downloading and installing OpenShip CLI" bash -c "curl -fsSL '$OPENSHIP_INSTALL_URL' | sh"

    export PATH="/root/.openship/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

    if ! command_exists openship && [[ -x "/root/.openship/bin/openship" ]]; then
        ln -sf \
            "/root/.openship/bin/openship" \
            "/usr/local/bin/openship"
    fi

    command_exists openship ||
        die "OpenShip CLI was not found after installation."

    success "OpenShip CLI ready: $(openship --version 2>/dev/null || true)"

    success "OpenShip CLI installed."
}

# ------------------------------------------------------------------------------
# OpenShip preflight
# ------------------------------------------------------------------------------

preflight_openship() {
    section "OpenShip pre-flight"

    command_exists openship ||
        die "OpenShip CLI is not available."

    if [[ "$INSTALL_MODE" == "standard" ]]; then
        command_exists docker ||
            die "Docker is required for Standard mode."

        docker info >/dev/null ||
            die "Docker daemon is not running."
    fi

    success "Pre-flight checks passed."
}

# ------------------------------------------------------------------------------
# OpenShip setup
# ------------------------------------------------------------------------------

run_bare_openship_setup() {
    echo
    echo "Preparing OpenShip Bare service..."
    echo

    # Stop any existing or orphaned OpenShip instances and free ports
    if systemctl is-active --quiet openship 2>/dev/null; then
        log "Stopping active OpenShip systemd service..."
        systemctl stop openship 2>/dev/null || true
    fi
    if command_exists openship; then
        openship stop 2>/dev/null || true
    fi

    # Kill any processes locking the default and fallback OpenShip ports
    fuser -k 4000/tcp 3001/tcp 4001/tcp 3002/tcp 2>/dev/null || true

    # Reset stored ports cache so OpenShip always binds standard 4000/3001
    rm -f /root/.openship/ports.json

    export OPENSHIP_ADMIN_PASSWORD="$OPENSHIP_ADMIN_PASSWORD_INPUT"

    local -a args
    args=(
        up
        --bare
        --non-interactive
        --port 4000
        --dashboard-port 3001
        --host 127.0.0.1
        --admin-email "$OPENSHIP_ADMIN_EMAIL_INPUT"
        --admin-name "$OPENSHIP_ADMIN_NAME_INPUT"
        --domain-kind "$OPENSHIP_DOMAIN_KIND"
    )

    if [[ "${OPENSHIP_PROXY_MODE:-none}" == "caddy" ]]; then
        args+=( --trust-proxy )
    fi

    # --no-host-control: prevents OpenShip from registering this VPS as a
    # managed server. Blocks dashboard terminal to Control VPS.
    # User chose this during configuration.
    if [[ "${OPENSHIP_NO_HOST_CONTROL:-false}" == "true" ]]; then
        args+=( --no-host-control )
        log "--no-host-control is ENABLED: Control VPS will not appear as a server."
    else
        log "--no-host-control is DISABLED: Control VPS terminal will be accessible."
    fi

    if [[ -n "${OPENSHIP_PUBLIC_URL:-}" ]]; then
        args+=( --public-url "$OPENSHIP_PUBLIC_URL" )
    fi

    if [[ -n "${OPENSHIP_HOST:-}" ]]; then
        args+=( --hostname "$OPENSHIP_HOST" )
    fi

    if [[ "$OPENSHIP_DOMAIN_KIND" == "custom" ]]; then
        # OpenShip Edge (:80/:443 via OpenResty Docker container + Let's Encrypt TLS)
        args+=(
            --edge takeover
            --acme-email "$OPENSHIP_ADMIN_EMAIL_INPUT"
        )
    fi

    log "Starting OpenShip Bare service with arguments:"
    echo "  openship ${args[*]}"
    echo

    openship "${args[@]}"

    # Ensure systemd service persistently sets public URL and trusted origins for terminal WebSockets & GitHub App manifests
    if [[ -n "$OPENSHIP_PUBLIC_URL" ]]; then
        mkdir -p /root/.openship
        echo "{\"publicUrl\":\"${OPENSHIP_PUBLIC_URL}\"}" > /root/.openship/instance.json
        mkdir -p /etc/systemd/system/openship.service.d
        cat > /etc/systemd/system/openship.service.d/override.conf <<EOF
[Service]
Environment="OPENSHIP_PUBLIC_URL=${OPENSHIP_PUBLIC_URL}"
Environment="OPENSHIP_EXTRA_TRUSTED_ORIGINS=${OPENSHIP_PUBLIC_URL},http://${OPENSHIP_HOST},https://${OPENSHIP_HOST}"
EOF
        if [[ -f /etc/systemd/system/openship.service ]]; then
            sed -i -E 's|up --foreground|up --foreground --port 4000 --dashboard-port 3001 --host 127.0.0.1 --public-url '"${OPENSHIP_PUBLIC_URL}"'|g' /etc/systemd/system/openship.service 2>/dev/null || true
            sed -i 's/--port [0-9]* --port/--port/g' /etc/systemd/system/openship.service 2>/dev/null || true
            sed -i 's/--dashboard-port [0-9]* --dashboard-port/--dashboard-port/g' /etc/systemd/system/openship.service 2>/dev/null || true
            sed -i 's/--public-url [^ ]* --public-url/--public-url/g' /etc/systemd/system/openship.service 2>/dev/null || true
        fi
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart openship 2>/dev/null || true
    fi

    unset OPENSHIP_ADMIN_PASSWORD
    unset OPENSHIP_ADMIN_PASSWORD_INPUT

    success "OpenShip Bare setup completed."
}

run_openship_setup() {
    section "OpenShip first-run setup"

    echo -e "${BOLD}Selected mode: ${INSTALL_MODE^^}${NC}"
    echo

    if [[ "$INSTALL_MODE" == "bare" ]]; then
        if [[ "${OPENSHIP_NO_HOST_CONTROL:-false}" == "true" ]]; then
            echo "OpenShip will use the explicit --bare runtime mode with --no-host-control."
        else
            echo "OpenShip will use the explicit --bare runtime mode with host control enabled."
        fi
        echo "The interactive guided wizard will NOT be used."
        echo
        run_bare_openship_setup
        wait_for_api_healthy
        configure_caddy
        return
    fi

    echo "OpenShip will be started using Docker Compose."
    echo
    echo -e "${YELLOW}Do not close this terminal during setup.${NC}"
    echo

    read -r -p "Press ENTER to start OpenShip..." </dev/tty

    [[ -e /dev/tty ]] ||
        die "Interactive terminal /dev/tty is not available for OpenShip setup."

    echo
    log "Starting OpenShip interactive setup with direct TTY I/O..."
    echo

    openship </dev/tty >/dev/tty 2>/dev/tty
}

# ------------------------------------------------------------------------------
# API health-check & rollback
# ------------------------------------------------------------------------------

rollback_bare_openship() {
    echo
    warn "Rolling back OpenShip Bare service..."

    systemctl stop openship 2>/dev/null || true
    openship stop 2>/dev/null || true

    echo
    warn "Last 50 lines from openship logs:"
    echo "--------------------------------------"
    openship logs --tail 50 2>/dev/null || journalctl -u openship -n 50 --no-pager 2>/dev/null || true
    echo "--------------------------------------"
    echo

    die "OpenShip API did not become healthy. See logs above and ${LOG_FILE}."
}

wait_for_api_healthy() {
    if [[ "$INSTALL_MODE" != "bare" ]]; then
        return
    fi

    section "OpenShip API health-check"

    local api_port=4000
    local retries=30
    local interval=10
    local attempt=0

    log "Polling /api/health — up to $((retries * interval / 60)) minutes..."
    printf "      "

    while (( attempt < retries )); do
        attempt=$(( attempt + 1 ))

        if curl -fsS --max-time 5 "http://localhost:${api_port}/api/health" >/dev/null 2>&1; then
            echo  # newline after dots
            success "OpenShip API is healthy (attempt ${attempt}/${retries})."
            return
        fi

        printf "."
        sleep "$interval"
    done

    echo  # newline after dots

    rollback_bare_openship
}

# ------------------------------------------------------------------------------
# Caddy Reverse Proxy
# ------------------------------------------------------------------------------


# ==============================================================================
# Interactive Setup Wizard & Configuration
# ==============================================================================

select_installation_mode() {
    section "OpenShip installation mode"

    if [[ -n "${INSTALL_MODE:-}" ]]; then
        INSTALL_MODE="${INSTALL_MODE,,}"
        success "Installation mode specified: ${INSTALL_MODE^^}"
        return
    fi

    if [[ "$NON_INTERACTIVE" == "true" || ! -e /dev/tty ]]; then
        if (( RAM_MB < RECOMMENDED_RAM_MB )); then
            INSTALL_MODE="bare"
        else
            INSTALL_MODE="standard"
        fi
        log "Non-interactive mode: selected ${INSTALL_MODE^^} mode automatically based on RAM (${RAM_MB} MB)."
        return
    fi

    if (( RAM_MB < RECOMMENDED_RAM_MB )); then
        echo -e "${BOLD}${YELLOW}"
        echo "RECOMMENDATION FOR LOW-MEMORY VPS (< 2 GB RAM)"
        echo "----------------------------------------------------------------"
        echo "This server will act as an OpenShip Control Plane."
        echo "Bare mode runs OpenShip as a lightweight native service with"
        echo "an embedded database (avoiding Postgres & Redis containers)."
        echo "Web traffic can be routed via Caddy or OpenShip Edge (:80/:443)."
        echo -e "${NC}"

        echo "Choose installation mode:"
        echo
        echo "  1) Bare (Recommended)"
        echo "     Lightweight Control Plane (Node process + embedded DB)."
        echo "     Optionally with Edge on :80/:443."
        echo
        echo "  2) Standard"
        echo "     Full OpenShip Docker Compose stack (Postgres + Redis)."
        echo "     Requires more RAM."
        echo
        echo "  3) Cancel"
        echo

        while true; do
            read -r -p "Select [1]: " choice </dev/tty
            choice="${choice//[$'\r\n\t ']/}"
            choice="${choice:-1}"

            case "$choice" in
                1)
                    INSTALL_MODE="bare"
                    break
                    ;;
                2)
                    echo
                    warn "You selected Standard Docker mode on a low-memory VPS."
                    warn "The system may use swap heavily or become unstable."
                    echo

                    if ask_yes_no "Are you sure you want Standard mode?" "N"; then
                        INSTALL_MODE="standard"
                        break
                    fi
                    ;;
                3)
                    die "Installation cancelled."
                    ;;
                *)
                    echo "Invalid choice."
                    ;;
            esac
        done
    else
        echo "Choose installation mode:"
        echo
        echo "  1) Standard"
        echo "     Full OpenShip Docker Compose stack."
        echo "     Recommended for 2+ GB RAM."
        echo
        echo "  2) Bare"
        echo "     Lightweight Control Plane (Node process + embedded DB)."
        echo
        echo "  3) Cancel"
        echo

        while true; do
            read -r -p "Select [1]: " choice </dev/tty
            choice="${choice//[$'\r\n\t ']/}"
            choice="${choice:-1}"

            case "$choice" in
                1)
                    INSTALL_MODE="standard"
                    break
                    ;;
                2)
                    INSTALL_MODE="bare"
                    break
                    ;;
                3)
                    die "Installation cancelled."
                    ;;
                *)
                    echo "Invalid choice."
                    ;;
            esac
        done
    fi

    echo

    if [[ "$INSTALL_MODE" == "bare" ]]; then
        success "Selected mode: BARE Control Plane"
        log "OpenShip daemon will run as a native service with embedded database."
    else
        success "Selected mode: STANDARD Docker Stack"
        log "OpenShip will run using Docker Compose."
    fi
}

collect_configuration() {
    section "Control Plane host configuration"

    if [[ -f "$STATE_FILE" ]]; then
        echo
        echo -e "${YELLOW}A previous installation state was found at:${NC}"
        echo "  ${STATE_FILE}"
        echo

        local use_state=false
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            use_state=true
        elif ask_yes_no "Resume using previously entered values?" "Y"; then
            use_state=true
        fi

        if [[ "$use_state" == "true" ]]; then
            while IFS="=" read -r key val || [[ -n "$key" ]]; do
                [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
                key="$(echo "$key" | tr -d '[:space:]')"
                val="${val#\"}"
                val="${val%\"}"
                val="${val#\'}"
                val="${val%\'}"
                case "$key" in
                    INSTALL_MODE)             INSTALL_MODE="$val" ;;
                    HOSTNAME)                 HOSTNAME_INPUT="$val" ;;
                    TIMEZONE)                 TIMEZONE_INPUT="$val" ;;
                    SSH_PORT)                 SSH_PORT_INPUT="$val" ;;
                    ADMIN_USER)               ADMIN_USER_INPUT="$val" ;;
                    ENABLE_UFW)               ENABLE_UFW="$val" ;;
                    ENABLE_FAIL2BAN)          ENABLE_FAIL2BAN="$val" ;;
                    ENABLE_SWAP)              ENABLE_SWAP="$val" ;;
                    SWAP_SIZE_GB)             SWAP_SIZE_GB="$val" ;;
                    OPENSHIP_ADMIN_NAME)      OPENSHIP_ADMIN_NAME_INPUT="$val" ;;
                    OPENSHIP_ADMIN_EMAIL)     OPENSHIP_ADMIN_EMAIL_INPUT="$val" ;;
                    OPENSHIP_DOMAIN_KIND)     OPENSHIP_DOMAIN_KIND="$val" ;;
                    OPENSHIP_HOST)            OPENSHIP_HOST="$val" ;;
                    OPENSHIP_PUBLIC_URL)      OPENSHIP_PUBLIC_URL="$val" ;;
                    OPENSHIP_EDGE_ENABLED)    OPENSHIP_EDGE_ENABLED="$val" ;;
                    OPENSHIP_PROXY_MODE)      OPENSHIP_PROXY_MODE="$val" ;;
                    OPENSHIP_NO_HOST_CONTROL) OPENSHIP_NO_HOST_CONTROL="$val" ;;
                    CADDY_SSL_MODE)           CADDY_SSL_MODE="$val" ;;
                    CADDY_ORIGIN_CERT_PATH)   CADDY_ORIGIN_CERT_PATH="$val" ;;
                    CADDY_ORIGIN_KEY_PATH)    CADDY_ORIGIN_KEY_PATH="$val" ;;
                esac
            done < "$STATE_FILE"

            HOSTNAME_INPUT="${HOSTNAME_INPUT:-openship-control}"
            TIMEZONE_INPUT="${TIMEZONE_INPUT:-UTC}"
            SSH_PORT_INPUT="${SSH_PORT_INPUT:-22}"
            ADMIN_USER_INPUT="${ADMIN_USER_INPUT:-openship}"
            ENABLE_UFW="${ENABLE_UFW:-true}"
            ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
            ENABLE_SWAP="${ENABLE_SWAP:-true}"
            SWAP_SIZE_GB="${SWAP_SIZE_GB:-2}"
            OPENSHIP_DOMAIN_KIND="${OPENSHIP_DOMAIN_KIND:-none}"
            OPENSHIP_EDGE_ENABLED="${OPENSHIP_EDGE_ENABLED:-false}"
            OPENSHIP_PROXY_MODE="${OPENSHIP_PROXY_MODE:-none}"
            OPENSHIP_NO_HOST_CONTROL="${OPENSHIP_NO_HOST_CONTROL:-false}"
            CADDY_SSL_MODE="${CADDY_SSL_MODE:-auto}"

            if [[ "$OPENSHIP_PROXY_MODE" == "none" ]]; then
                if [[ "$OPENSHIP_EDGE_ENABLED" == "true" ]]; then
                    OPENSHIP_PROXY_MODE="edge"
                    OPENSHIP_DOMAIN_KIND="custom"
                elif [[ "$OPENSHIP_DOMAIN_KIND" == "byo" && -n "${OPENSHIP_HOST:-}" ]]; then
                    OPENSHIP_PROXY_MODE="caddy"
                fi
            elif [[ "$OPENSHIP_PROXY_MODE" == "edge" ]]; then
                OPENSHIP_EDGE_ENABLED="true"
                OPENSHIP_DOMAIN_KIND="custom"
            elif [[ "$OPENSHIP_PROXY_MODE" == "caddy" ]]; then
                OPENSHIP_EDGE_ENABLED="false"
                OPENSHIP_DOMAIN_KIND="byo"
            fi

            echo
            echo "Loaded values:"
            echo "  Hostname:   ${HOSTNAME_INPUT}"
            echo "  Timezone:   ${TIMEZONE_INPUT}"
            echo "  SSH port:   ${SSH_PORT_INPUT}"
            echo "  Admin user: ${ADMIN_USER_INPUT}"
            echo "  Mode:       ${INSTALL_MODE}"
            echo "  Domain:     ${OPENSHIP_HOST:-none}"
            echo

            if [[ "$INSTALL_MODE" == "bare" && -z "${OPENSHIP_ADMIN_PASSWORD_INPUT:-}" ]]; then
                if [[ "$NON_INTERACTIVE" == "true" ]]; then
                    OPENSHIP_ADMIN_PASSWORD_INPUT="${OPENSHIP_ADMIN_PASSWORD_INPUT:-$(openssl rand -hex 16)}"
                    log "Non-interactive: generated admin password."
                else
                    echo -e "${YELLOW}Admin password must be entered again (never stored).${NC}"
                    echo
                    while true; do
                        OPENSHIP_ADMIN_PASSWORD_INPUT="$(ask_password "OpenShip administrator password: ")"
                        if [[ -z "$OPENSHIP_ADMIN_PASSWORD_INPUT" ]]; then
                            warn "Password cannot be empty."
                            continue
                        fi
                        if (( ${#OPENSHIP_ADMIN_PASSWORD_INPUT} < 8 )); then
                            warn "Password must be at least 8 characters (entered: ${#OPENSHIP_ADMIN_PASSWORD_INPUT})."
                            continue
                        fi
                        success "Password accepted (${#OPENSHIP_ADMIN_PASSWORD_INPUT} characters)."
                        break
                    done
                fi
            fi

            success "Configuration loaded from state file."
            return
        fi
        echo
    fi

    echo "This VPS will act as the OpenShip Control Plane."
    echo "Production applications (Laravel/CRM) should NOT be deployed here."
    echo

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        HOSTNAME_INPUT="${HOSTNAME_INPUT:-openship-control}"
        TIMEZONE_INPUT="${TIMEZONE_INPUT:-UTC}"
        SSH_PORT_INPUT="${SSH_PORT_INPUT:-22}"
        ADMIN_USER_INPUT="${ADMIN_USER_INPUT:-openship}"
        ENABLE_UFW="${ENABLE_UFW:-true}"
        ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
        ENABLE_SWAP="${ENABLE_SWAP:-true}"
        SWAP_SIZE_GB="${SWAP_SIZE_GB:-2}"
        if [[ "$INSTALL_MODE" == "bare" ]]; then
            collect_bare_openship_credentials
        fi
        save_configuration
        return
    fi

    # Hostname
    if [[ -z "${HOSTNAME_INPUT:-}" ]]; then
        while true; do
            HOSTNAME_INPUT="$(ask_default "Control Plane hostname" "openship-control")"
            if valid_hostname "$HOSTNAME_INPUT"; then
                break
            fi
            warn "Invalid hostname."
        done
    else
        success "Hostname specified: ${HOSTNAME_INPUT}"
    fi

    # Timezone
    if [[ -z "${TIMEZONE_INPUT:-}" ]]; then
        _select_timezone() {
            local auto_tz=""
            local ssh_raw="${SSH_CLIENT:-${SSH_CONNECTION:-}}"
            local client_ip="${ssh_raw%% *}"

            if [[ -n "$client_ip" && ! "$client_ip" =~ ^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
                auto_tz="$(curl -fsSL --max-time 2 "http://ip-api.com/line/${client_ip}?fields=timezone" 2>/dev/null || true)"
                if [[ ! "$auto_tz" =~ ^[A-Za-z0-9_+-]+/[A-Za-z0-9_+-]+$ ]]; then
                    auto_tz=""
                fi
            fi

            if [[ -z "$auto_tz" ]]; then
                auto_tz="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
            fi

            case "${auto_tz}" in
                "Europe/Kiev")     auto_tz="Europe/Kyiv" ;;
                "Asia/Calcutta")   auto_tz="Asia/Kolkata" ;;
            esac

            local default_tz="${auto_tz:-UTC}"
            echo
            log "Detected timezone: ${BOLD}${default_tz}${NC}"

            if ask_yes_no "Use ${default_tz}?" "Y"; then
                TIMEZONE_INPUT="$default_tz"
            else
                local regions
                regions="$(timedatectl list-timezones 2>/dev/null | cut -d/ -f1 | sort -u)"
                local region_count
                region_count="$(echo "$regions" | wc -l)"

                echo
                echo -e "  ${BOLD}Regions:${NC}"
                echo "$regions" | nl -w3 -s') ' | column -c 60
                echo

                local region_num region
                while true; do
                    read -r -p "  Region [1-${region_count}]: " region_num </dev/tty
                    region_num="${region_num//[$'\r\n\t ']/}"
                    region="$(echo "$regions" | sed -n "${region_num}p")"
                    [[ -n "$region" ]] && break
                    warn "Invalid number, try again."
                done

                local cities
                cities="$(timedatectl list-timezones 2>/dev/null | grep "^${region}/" | sed "s|^${region}/||")"
                local city_count
                city_count="$(echo "$cities" | wc -l)"

                echo
                echo -e "  ${BOLD}Cities in ${region}:${NC}"
                echo "$cities" | nl -w3 -s') ' | column -c 60
                echo

                local city_num city
                while true; do
                    read -r -p "  City [1-${city_count}]: " city_num </dev/tty
                    city_num="${city_num//[$'\r\n\t ']/}"
                    city="$(echo "$cities" | sed -n "${city_num}p")"
                    [[ -n "$city" ]] && break
                    warn "Invalid number, try again."
                done

                TIMEZONE_INPUT="${region}/${city}"
            fi

            if ! timedatectl list-timezones 2>/dev/null | grep -Fxq "$TIMEZONE_INPUT"; then
                warn "Timezone '${TIMEZONE_INPUT}' not recognised. Falling back to UTC."
                TIMEZONE_INPUT="UTC"
            fi
            success "Timezone: ${TIMEZONE_INPUT}"
        }
        _select_timezone
    else
        success "Timezone specified: ${TIMEZONE_INPUT}"
    fi

    # SSH Port
    if [[ -z "${SSH_PORT_INPUT:-}" ]]; then
        while true; do
            SSH_PORT_INPUT="$(ask_default "SSH port" "22")"
            if valid_ssh_port "$SSH_PORT_INPUT"; then
                break
            fi
            warn "Invalid SSH port."
        done
    else
        success "SSH port specified: ${SSH_PORT_INPUT}"
    fi

    # Admin User
    if [[ -z "${ADMIN_USER_INPUT:-}" ]]; then
        ADMIN_USER_INPUT="$(ask_default "Linux administrator" "openship")"
        if ! [[ "$ADMIN_USER_INPUT" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            die "Invalid Linux username: ${ADMIN_USER_INPUT}"
        fi
    else
        success "Admin user specified: ${ADMIN_USER_INPUT}"
    fi

    # UFW
    if [[ -z "${ENABLE_UFW:-}" ]]; then
        echo
        if ask_yes_no "Enable UFW firewall?" "Y"; then
            ENABLE_UFW="true"
        else
            ENABLE_UFW="false"
        fi
    else
        success "UFW firewall: ${ENABLE_UFW}"
    fi

    # Fail2ban
    if [[ -z "${ENABLE_FAIL2BAN:-}" ]]; then
        if ask_yes_no "Enable Fail2ban for SSH?" "Y"; then
            ENABLE_FAIL2BAN="true"
        else
            ENABLE_FAIL2BAN="false"
        fi
    else
        success "Fail2ban: ${ENABLE_FAIL2BAN}"
    fi

    # Swap
    local rec_swap=2
    if (( RAM_MB > 2048 )); then
        rec_swap=4
    fi

    if [[ -z "${ENABLE_SWAP:-}" ]]; then
        echo
        echo "SWAP configuration:"
        echo "  Recommended swap for ${RAM_MB} MB RAM: ${rec_swap} GB"
        echo

        if ask_yes_no "Configure ${rec_swap} GB swap?" "Y"; then
            ENABLE_SWAP="true"
            SWAP_SIZE_GB="$rec_swap"
        else
            ENABLE_SWAP="false"
            SWAP_SIZE_GB=0
        fi
    else
        if [[ "$ENABLE_SWAP" == "true" ]]; then
            SWAP_SIZE_GB="${SWAP_SIZE_GB:-$rec_swap}"
            success "Swap: ENABLED (${SWAP_SIZE_GB} GB)"
        else
            SWAP_SIZE_GB=0
            success "Swap: DISABLED"
        fi
    fi

    if [[ "$INSTALL_MODE" == "bare" ]]; then
        collect_bare_openship_credentials
    fi

    save_configuration
}

save_configuration() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    cat > "$STATE_FILE" <<EOF
INSTALL_MODE="${INSTALL_MODE}"
OPENSHIP_ROLE="control"
OPENSHIP_HOST_CONTROL="false"
HOSTNAME="${HOSTNAME_INPUT}"
TIMEZONE="${TIMEZONE_INPUT}"
SSH_PORT="${SSH_PORT_INPUT}"
ADMIN_USER="${ADMIN_USER_INPUT}"
ENABLE_UFW="${ENABLE_UFW}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN}"
ENABLE_SWAP="${ENABLE_SWAP}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-2}"
OPENSHIP_ADMIN_NAME="${OPENSHIP_ADMIN_NAME_INPUT:-}"
OPENSHIP_ADMIN_EMAIL="${OPENSHIP_ADMIN_EMAIL_INPUT:-}"
OPENSHIP_DOMAIN_KIND="${OPENSHIP_DOMAIN_KIND:-none}"
OPENSHIP_HOST="${OPENSHIP_HOST:-}"
OPENSHIP_PUBLIC_URL="${OPENSHIP_PUBLIC_URL:-}"
OPENSHIP_EDGE_ENABLED="${OPENSHIP_EDGE_ENABLED:-false}"
OPENSHIP_PROXY_MODE="${OPENSHIP_PROXY_MODE:-none}"
OPENSHIP_NO_HOST_CONTROL="${OPENSHIP_NO_HOST_CONTROL:-false}"
CADDY_SSL_MODE="${CADDY_SSL_MODE:-auto}"
CADDY_ORIGIN_CERT_PATH="${CADDY_ORIGIN_CERT_PATH:-}"
CADDY_ORIGIN_KEY_PATH="${CADDY_ORIGIN_KEY_PATH:-}"
EOF

    chmod 600 "$STATE_FILE"
}

post_install_checks() {
    {
        echo "=== Post-install verification ==="
        echo "OpenShip status:"
        openship status || true

        if command_exists docker; then
            echo "Docker containers:"
            docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
        fi

        echo "Memory:"
        free -h

        echo "Disk:"
        df -h /

        echo "Swap:"
        swapon --show || true

        echo "Listening ports:"
        ss -lntp || true

        echo "Firewall:"
        ufw status verbose || true

        echo "Fail2ban:"
        fail2ban-client status sshd 2>/dev/null || true
    } >> "$LOG_FILE" 2>&1
}

print_summary() {
    clear 2>/dev/null || true

    section "Installation complete"

    local mode_label="${INSTALL_MODE^^}"
    local proxy_label="none"
    if [[ "${OPENSHIP_PROXY_MODE:-none}" == "caddy" ]]; then
        if [[ "${CADDY_SSL_MODE:-auto}" == "cloudflare_flexible" ]]; then
            proxy_label="Caddy (Cloudflare Flexible / HTTP :80)"
        elif [[ "${CADDY_SSL_MODE:-auto}" == "cloudflare_origin" ]]; then
            proxy_label="Caddy (Cloudflare Origin CA)"
        else
            proxy_label="Caddy (Let's Encrypt HTTPS)"
        fi
    elif [[ "${OPENSHIP_EDGE_ENABLED:-false}" == "true" ]]; then
        proxy_label="OpenShip Edge (Docker)"
    fi

    local hc_label="enabled"
    if [[ "${OPENSHIP_NO_HOST_CONTROL:-false}" == "true" ]]; then
        hc_label="disabled"
    fi

    local domain_label="${OPENSHIP_HOST:-none}"
    if [[ -z "$domain_label" || "$domain_label" == "none" ]]; then
        domain_label="none (private / port 3001)"
    fi

    echo -e "  ${BOLD}${CYAN}OpenShip Control Plane${NC}"
    echo
    printf "  ${DIM}%-18s${NC}  %s\n" "Mode"          "$mode_label"
    printf "  ${DIM}%-18s${NC}  %s\n" "Host control"  "$hc_label"
    printf "  ${DIM}%-18s${NC}  %s\n" "Hostname"      "${HOSTNAME_INPUT}"
    printf "  ${DIM}%-18s${NC}  %s\n" "Timezone"      "${TIMEZONE_INPUT}"
    printf "  ${DIM}%-18s${NC}  %s:%s\n" "SSH"        "${ADMIN_USER_INPUT}" "${SSH_PORT_INPUT}"
    printf "  ${DIM}%-18s${NC}  %s\n" "UFW"           "${ENABLE_UFW}"
    printf "  ${DIM}%-18s${NC}  %s\n" "Fail2ban"      "${ENABLE_FAIL2BAN}"
    printf "  ${DIM}%-18s${NC}  %s GB\n" "Swap"        "${SWAP_SIZE_GB:-2}"
    printf "  ${DIM}%-18s${NC}  %s\n" "Domain"        "$domain_label"
    printf "  ${DIM}%-18s${NC}  %s\n" "Proxy"         "$proxy_label"
    echo
    printf "  ${DIM}%-18s${NC}  %s\n" "State file"    "${STATE_FILE}"
    printf "  ${DIM}%-18s${NC}  %s\n" "Install log"   "${LOG_FILE}"
    echo

    if [[ "$INSTALL_MODE" == "bare" ]]; then
        if [[ -n "${OPENSHIP_PUBLIC_URL:-}" ]]; then
            success "OpenShip Bare  →  ${OPENSHIP_PUBLIC_URL} (${proxy_label})"
        else
            success "OpenShip Bare  →  http://localhost:3001  (private)"
        fi
    else
        success "OpenShip Standard (Docker Compose)"
    fi

    if [[ "${OPENSHIP_PROXY_MODE:-none}" == "caddy" ]]; then
        echo
        echo -e "  ${YELLOW}Cloudflare setup:${NC}"
        echo -e "  ${DIM}1. In Cloudflare DNS, set ${OPENSHIP_HOST} to 'Proxied' (orange cloud).${NC}"
        echo -e "  ${DIM}2. Under SSL/TLS, ensure encryption mode is set to 'Full (strict)'.${NC}"
    fi

    if [[ -n "${OPENSHIP_HOST:-}" ]]; then
        echo
        echo -e "  ${YELLOW}Self-hosted GitHub App endpoints (HTTPS mandatory):${NC}"
        echo -e "  ${DIM}• Setup Callback:  https://${OPENSHIP_HOST}/auth/callback/github-app${NC}"
        echo -e "  ${DIM}• Webhook URL:     https://${OPENSHIP_HOST}/api/proxy/api/webhooks/github${NC}"
    fi

    echo
    echo -e "  ${DIM}This VPS is strictly a Control Plane. Remote deployment servers${NC}"
    echo -e "  ${DIM}are added via 'openship server add'. Never deploy apps here.${NC}"
    echo
}

# ==============================================================================
# Main Entry Point
# ==============================================================================

main() {
    clear 2>/dev/null || true

    echo
    echo   "  ╔══════════════════════════════════════════════════════╗"
    echo   "  ║                                                      ║"
    printf "  ║   ⚓  %-46s  ║\n" "OpenShip Control Plane Installer"
    printf "  ║   %-48s  ║\n" "Version ${SCRIPT_VERSION} · Ubuntu 24.04 LTS"
    echo   "  ║                                                      ║"
    printf "  ║   %-48s  ║\n" "Flag & Command Generator:                       "
    printf "  ║   %-48s  ║\n" "${GENERATOR_URL}"
    echo   "  ║                                                      ║"
    echo   "  ╚══════════════════════════════════════════════════════╝"
    echo

    require_root

    check_os
    check_architecture
    check_resources

    select_installation_mode

    if [[ "$DRY_RUN" == "true" ]]; then
        echo
        success "Dry-run validation successful. System is compatible and ready for OpenShip installation."
        exit 0
    fi

    collect_configuration

    configure_hostname
    configure_timezone

    install_and_update_packages
    optimize_system

    configure_swap
    configure_admin_user
    configure_ssh

    configure_ufw
    configure_fail2ban
    configure_unattended_upgrades

    install_docker
    configure_docker
    ensure_openship_docker_network

    prepare_runtime_for_openship

    install_openship_cli
    preflight_openship

    run_openship_setup

    post_install_checks
    print_summary
}

main "$@"

