#!/usr/bin/env bash
set -Eeuo pipefail

readonly LOG_FILE="/var/log/openship-doctor.log"
readonly STATE_FILE="/etc/openship-control/install.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

log() { echo -e "$CYAN[INFO]$NC $*"; }
ok() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "$GREEN[PASS]$NC $*"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); echo -e "$YELLOW[WARN]$NC $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "$RED[FAIL]$NC $*"; }

AUDIT_ONLY="false"
REPORT_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Usage: sudo ./doctor.sh [--audit] [--report <path>]"
            echo
            echo "Diagnoses host system, OpenShip Control Plane / Worker status, and runs VPS Security Audit."
            echo "  --audit          Run VPS Security Audit only (skip OpenShip Control Plane checks)"
            echo "  --report <path>  Save report output to a custom file"
            exit 0
            ;;
        --audit)
            AUDIT_ONLY="true"
            shift
            ;;
        --report=*)
            REPORT_FILE="${1#*=}"
            shift
            ;;
        --report)
            REPORT_FILE="${2:-}"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ "$EUID" -ne 0 ]]; then
    echo "Run as root: sudo ./doctor.sh" >&2
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

FAILED=0
INSTALL_MODE=""
SSH_PORT=""
ADMIN_USER=""
OPENSHIP_ROLE="control"
OPENSHIP_DOMAIN_KIND="none"
OPENSHIP_EDGE_ENABLED="false"
OPENSHIP_HOST=""

echo
echo "============================================================"
echo " OpenShip Diagnostic Doctor"
echo "============================================================"
echo

log "Host"
echo "  Hostname: $(hostname)"
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "  OS:       ${PRETTY_NAME:-Linux}"
fi
echo "  Kernel:   $(uname -r)"
echo "  Arch:     $(dpkg --print-architecture 2>/dev/null || uname -m)"
echo "  CPU:      $(nproc) cores"
echo "  RAM:      $(free -h | awk '/^Mem:/ {print $2}')"
echo "  Disk:     $(df -h / | awk 'NR==2 {print $4 " free / " $2}')"
echo

if [[ -f "$STATE_FILE" ]]; then
    ok "Installer state exists: $STATE_FILE"
    while IFS="=" read -r key val || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key="$(echo "$key" | tr -d '[:space:]')"
        val="${val#\"}"
        val="${val%\"}"
        val="${val#\'}"
        val="${val%\'}"
        case "$key" in
            INSTALL_MODE)             INSTALL_MODE="$val" ;;
            OPENSHIP_ROLE)            OPENSHIP_ROLE="$val" ;;
            SSH_PORT)                 SSH_PORT="$val" ;;
            ADMIN_USER)               ADMIN_USER="$val" ;;
            OPENSHIP_HOST)            OPENSHIP_HOST="$val" ;;
            OPENSHIP_DOMAIN_KIND)     OPENSHIP_DOMAIN_KIND="$val" ;;
            OPENSHIP_EDGE_ENABLED)    OPENSHIP_EDGE_ENABLED="$val" ;;
            OPENSHIP_PROXY_MODE)      OPENSHIP_PROXY_MODE="$val" ;;
            OPENSHIP_NO_HOST_CONTROL) OPENSHIP_NO_HOST_CONTROL="$val" ;;
            OPENSHIP_PUBLIC_URL)      OPENSHIP_PUBLIC_URL="$val" ;;
        esac
    done < "$STATE_FILE"
    echo "  Mode:         ${INSTALL_MODE:-unknown}"
    echo "  Role:         ${OPENSHIP_ROLE:-control}"
    echo "  SSH port:     ${SSH_PORT:-22}"
    echo "  Admin user:   ${ADMIN_USER:-unknown}"
    echo "  Domain:       ${OPENSHIP_HOST:-none} (${OPENSHIP_DOMAIN_KIND:-none})"
    echo "  Public URL:   ${OPENSHIP_PUBLIC_URL:-none}"
    echo "  Edge:         ${OPENSHIP_EDGE_ENABLED:-false}"
fi

# Control Plane checks (if installed or state file exists, and not --audit)
if [[ "$AUDIT_ONLY" != "true" ]] && { [[ -f "$STATE_FILE" ]] || command -v openship >/dev/null 2>&1; }; then
    echo
    log "OpenShip Control Plane CLI"

    if command -v openship >/dev/null 2>&1; then
        ok "openship command found: $(command -v openship) ($(openship --version 2>/dev/null || true))"
    else
        fail "openship command not found"
        FAILED=1
    fi

    echo
    log "OpenShip Control Plane Service"

    if [[ "${INSTALL_MODE:-}" == "bare" ]]; then
        if systemctl is-active --quiet openship 2>/dev/null; then
            ok "OpenShip systemd unit (openship.service) is active"
        else
            fail "OpenShip systemd unit (openship.service) is NOT active"
            FAILED=1
        fi

        if [[ -f /root/.openship/instance.json ]] && grep -q '"publicUrl"' /root/.openship/instance.json 2>/dev/null; then
            local_pub_url="$(grep -o '"publicUrl": *"[^"]*"' /root/.openship/instance.json | cut -d'"' -f4)"
            if [[ "$local_pub_url" =~ ^https:// ]]; then
                ok "OpenShip public URL configured: $local_pub_url"
            else
                warn "OpenShip public URL in /root/.openship/instance.json is not HTTPS: $local_pub_url (GitHub App manifest will fail)"
            fi
        else
            warn "/root/.openship/instance.json missing publicUrl (GitHub App manifest redirect_url will default to localhost)"
        fi
    fi

    if command -v openship >/dev/null 2>&1; then
        if openship status; then
            ok "OpenShip status/API health"
        else
            fail "OpenShip status/API health"
            FAILED=1
        fi

        echo
        log "OpenShip internal doctor"

        if openship doctor; then
            ok "OpenShip doctor check passed"
        else
            fail "OpenShip doctor reported issues"
            FAILED=1
        fi
    fi
fi

if [[ "$AUDIT_ONLY" != "true" ]]; then
    # Caddy Reverse Proxy checks
    if command -v caddy >/dev/null 2>&1; then
    echo
    log "Caddy Reverse Proxy"
    if systemctl is-active --quiet caddy; then
        ok "Caddy service is active"
    else
        fail "Caddy service is installed but NOT active"
        FAILED=1
    fi
    if [[ -f /etc/caddy/Caddyfile ]]; then
        if grep -q "127.0.0.1:3001" /etc/caddy/Caddyfile; then
            ok "Caddyfile proxies Dashboard to 127.0.0.1:3001"
        fi
        if grep -q "127.0.0.1:4000" /etc/caddy/Caddyfile; then
            ok "Caddyfile proxies API to 127.0.0.1:4000"
        else
            warn "Caddyfile does NOT proxy API to 127.0.0.1:4000 (terminal WebSockets / API may fail)"
        fi
        if grep -q "handle_path /api/proxy/\*" /etc/caddy/Caddyfile; then
            ok "Caddyfile routes /api/proxy/* to API :4000 (terminal WebSockets enabled)"
        else
            warn "Caddyfile missing 'handle_path /api/proxy/*' (terminal WebSockets may fail)"
        fi
        if grep -qE "^[a-zA-Z0-9.-]+ \{" /etc/caddy/Caddyfile && ! grep -qE "^http://" /etc/caddy/Caddyfile; then
            echo "  ℹ Cloudflare SSL tip: if 'Too Many Redirects', switch Cloudflare SSL to 'Full' or prefix domain with 'http://' in /etc/caddy/Caddyfile."
        fi
    fi
fi

# Docker & Edge checks
echo
log "Docker Daemon & Edge Services"

if command -v docker >/dev/null 2>&1; then
    if systemctl is-active --quiet docker; then
        ok "Docker daemon is running: $(docker --version)"
    else
        if [[ "${OPENSHIP_EDGE_ENABLED:-false}" == "true" || "${INSTALL_MODE:-}" == "standard" ]]; then
            fail "Docker daemon is not running"
            FAILED=1
        else
            warn "Docker daemon is installed but not running"
        fi
    fi

    # Check OpenShip Edge container if enabled
    if [[ "${OPENSHIP_EDGE_ENABLED:-false}" == "true" ]]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^openship-edge$'; then
            ok "OpenShip Edge container is running on :80/:443"
        elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^openship-edge$'; then
            fail "OpenShip Edge container exists but is STOPPED"
            FAILED=1
        else
            warn "OpenShip Edge container not found (may still be provisioning)"
        fi
    fi

    # Check Worker Database Services (only if explicitly deployed on this host)
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qE '^openship-(mariadb|redis)$'; then
        echo
        log "OpenShip Worker Services (MariaDB + Redis)"

        for service in openship-mariadb openship-redis; do
            if docker ps --format '{{.Names}}' | grep -q "^${service}$"; then
                health="$(docker inspect --format='{{json .State.Health.Status}}' "$service" 2>/dev/null || echo '"running"')"
                ok "${service} is running (health: ${health//\"/})"
            elif docker ps -a --format '{{.Names}}' | grep -q "^${service}$"; then
                warn "${service} exists but is STOPPED"
            fi
        done

        local net="${OPENSHIP_NETWORK:-openship}"
        if docker network inspect "$net" >/dev/null 2>&1; then
            ok "Docker network '${net}' is active"
        fi
    else
        if [[ "${OPENSHIP_ROLE:-control}" == "control" ]]; then
            echo "  ○ Worker databases (MariaDB/Redis): not required on Control Plane"
            echo "  ○ Production applications: not required on Control Plane"
        fi
    fi
else
    if [[ "${OPENSHIP_ROLE:-control}" == "control" && "${OPENSHIP_EDGE_ENABLED:-false}" != "true" ]]; then
        if [[ "${OPENSHIP_NO_HOST_CONTROL:-false}" != "true" ]]; then
            fail "Docker daemon is NOT running! OpenShip reports 'connect ENOENT /var/run/docker.sock' because Host Control is enabled. Start Docker: 'systemctl enable --now docker'."
            FAILED=1
        else
            ok "Docker daemon: not required (strict isolation --no-host-control active)"
        fi
    elif [[ "${OPENSHIP_EDGE_ENABLED:-false}" == "true" ]]; then
        fail "Docker is required for OpenShip Edge (:80/:443)"
        FAILED=1
    fi
fi
fi # end AUDIT_ONLY != true

run_vps_security_audit() {
    echo
    echo "============================================================"
    echo " VPS Security Audit"
    echo "============================================================"

    # 1. SSH Hardening
    echo
    log "Audit: SSH Hardening"
    local sshd_cfg=""
    local active_ssh_port="${SSH_PORT:-22}"
    if command -v sshd >/dev/null 2>&1; then
        sshd_cfg="$(sshd -T 2>/dev/null || true)"
        local root_login pass_auth empty_pass max_tries cfg_port
        root_login="$(echo "$sshd_cfg" | awk '/^permitrootlogin / {print $2; exit}')"
        pass_auth="$(echo "$sshd_cfg" | awk '/^passwordauthentication / {print $2; exit}')"
        empty_pass="$(echo "$sshd_cfg" | awk '/^permitemptypasswords / {print $2; exit}')"
        max_tries="$(echo "$sshd_cfg" | awk '/^maxauthtries / {print $2; exit}')"
        cfg_port="$(echo "$sshd_cfg" | awk '/^port / {print $2; exit}')"
        [[ -n "$cfg_port" ]] && active_ssh_port="$cfg_port"

        if [[ "$root_login" == "no" || "$root_login" == "prohibit-password" ]]; then
            ok "SSH PermitRootLogin is '${root_login}'"
        elif [[ -n "$root_login" ]]; then
            fail "SSH PermitRootLogin is '${root_login}' (recommend 'no' or 'prohibit-password')"
            FAILED=1
        fi

        if [[ "$pass_auth" == "no" ]]; then
            ok "SSH PasswordAuthentication is disabled (key-only)"
        elif [[ -n "$pass_auth" ]]; then
            fail "SSH PasswordAuthentication is '${pass_auth}' (recommend 'no')"
            FAILED=1
        fi

        if [[ "$empty_pass" == "no" ]]; then
            ok "SSH PermitEmptyPasswords is 'no'"
        elif [[ -n "$empty_pass" ]]; then
            fail "SSH PermitEmptyPasswords is '${empty_pass}'"
            FAILED=1
        fi

        if [[ -n "$max_tries" ]] && (( max_tries <= 4 )); then
            ok "SSH MaxAuthTries is ${max_tries}"
        elif [[ -n "$max_tries" ]]; then
            warn "SSH MaxAuthTries is ${max_tries} (recommend <= 4)"
        fi

        if [[ "$active_ssh_port" != "22" ]]; then
            ok "SSH runs on non-default port ${active_ssh_port}"
        else
            warn "SSH runs on default port 22"
        fi
    else
        warn "sshd binary not found; skipping sshd -T checks."
    fi

    # 2. Firewall & Exposed Attack Surface
    echo
    log "Audit: Firewall & Publicly Exposed Ports"
    if command -v ufw >/dev/null 2>&1; then
        local ufw_out
        ufw_out="$(ufw status verbose 2>/dev/null || true)"
        if echo "$ufw_out" | grep -q "Status: active"; then
            if echo "$ufw_out" | grep -qiE "Default: (deny|reject) \(incoming\)"; then
                ok "UFW is active with default incoming deny/reject"
            else
                warn "UFW is active but default incoming policy is not deny"
            fi
        else
            fail "UFW is installed but NOT active"
            FAILED=1
        fi
    elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q "chain "; then
        ok "nftables ruleset is active"
    else
        fail "No active firewall (UFW/nftables) detected"
        FAILED=1
    fi

    local exposed_db=""
    exposed_db="$(ss -lntH 2>/dev/null | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\[::\]|\*):(3306|5432|6379|27017|11211)$' || true)"
    if [[ -n "$exposed_db" ]]; then
        fail "Sensitive DB/cache port exposed publicly: $(echo "$exposed_db" | tr '\n' ' ')"
        FAILED=1
    else
        ok "No DB/cache ports (3306/5432/6379/27017/11211) bound to public interfaces"
    fi

    # 3. Fail2ban & Failed Logins
    echo
    log "Audit: Intrusion Prevention (Fail2ban)"
    if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active --quiet fail2ban 2>/dev/null; then
        if fail2ban-client status sshd >/dev/null 2>&1; then
            ok "Fail2ban sshd jail is active"
            local f2b_port
            f2b_port="$(fail2ban-client get sshd port 2>/dev/null | tr -dc '0-9,' || true)"
            if [[ -n "$f2b_port" && "$f2b_port" != *"$active_ssh_port"* ]]; then
                warn "Fail2ban sshd jail port (${f2b_port}) does not match SSH port (${active_ssh_port})"
            else
                ok "Fail2ban sshd jail port aligns with SSH (${active_ssh_port})"
            fi
        else
            warn "Fail2ban is running but 'sshd' jail is not active"
        fi
    else
        warn "Fail2ban is not active"
    fi

    local failed_24h=0
    if command -v journalctl >/dev/null 2>&1; then
        failed_24h="$(journalctl -u ssh -u sshd --since "24 hours ago" --no-pager 2>/dev/null | grep -cE "Failed password|Invalid user|Authentication failure" || true)"
    elif [[ -f /var/log/auth.log ]]; then
        failed_24h="$(grep -cE "Failed password|Invalid user" /var/log/auth.log 2>/dev/null || true)"
    fi
    if (( failed_24h > 50 )); then
        warn "High failed SSH attempts detected (24h): ${failed_24h}"
    else
        ok "Failed SSH attempts (24h): ${failed_24h}"
    fi

    # 4. System Security Updates
    echo
    log "Audit: Security Updates"
    if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
        ok "unattended-upgrades is enabled"
    else
        warn "unattended-upgrades is not enabled"
    fi
    if command -v apt >/dev/null 2>&1; then
        local sec_updates=0
        sec_updates="$(apt list --upgradable 2>/dev/null | grep -ci "security" || true)"
        if (( sec_updates > 0 )); then
            warn "${sec_updates} pending security update(s) via apt (run: apt update && apt upgrade)"
        else
            ok "No pending apt security updates"
        fi
    fi

    # 5. Accounts, Sudo, Password Policy & SUID
    echo
    log "Audit: Accounts, Sudo & SUID Binaries"
    local uid0_users
    uid0_users="$(awk -F: '($3 == 0 && $1 != "root") {print $1}' /etc/passwd 2>/dev/null || true)"
    if [[ -n "$uid0_users" ]]; then
        fail "Non-root UID 0 account(s) detected: ${uid0_users}"
        FAILED=1
    else
        ok "Only 'root' has UID 0"
    fi

    if grep -rqE 'logfile|log_output' /etc/sudoers /etc/sudoers.d 2>/dev/null; then
        ok "Sudo command logging is configured"
    else
        warn "Sudo logging (logfile/log_output) not configured in /etc/sudoers*"
    fi

    local min_len=""
    if [[ -f /etc/security/pwquality.conf ]]; then
        min_len="$(awk -F= '/^[[:space:]]*minlen[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' /etc/security/pwquality.conf 2>/dev/null || true)"
    fi
    if [[ -z "$min_len" && -f /etc/login.defs ]]; then
        min_len="$(awk '/^[[:space:]]*PASS_MIN_LEN[[:space:]]+/ {print $2; exit}' /etc/login.defs 2>/dev/null || true)"
    fi
    if [[ -n "$min_len" ]] && (( min_len >= 8 )); then
        ok "Password minimum length policy is ${min_len}"
    else
        warn "Password minimum length is weak or unset (${min_len:-none})"
    fi

    local suspicious_suid=""
    suspicious_suid="$(find / -xdev -perm -4000 -type f 2>/dev/null | while read -r f; do
        case "$(basename "$f")" in
            su|sudo|passwd|chsh|chfn|gpasswd|newgrp|mount|umount|fusermount|fusermount3|pkexec|unix_chkpwd|ssh-keysign|dbus-daemon-launch-helper|ntfs-3g|ping|ping6|pppd|ksu) ;;
            *) echo "$f" ;;
        esac
    done || true)"
    if [[ -n "$suspicious_suid" ]]; then
        warn "Unexpected SUID binaries found: $(echo "$suspicious_suid" | tr '\n' ' ')"
    else
        ok "No unexpected SUID binaries found"
    fi

    # 6. FrankenPHP (if installed)
    if command -v frankenphp >/dev/null 2>&1; then
        echo
        log "Audit: FrankenPHP Web Server"
        if systemctl is-active --quiet frankenphp 2>/dev/null; then
            ok "frankenphp.service is active"
        else
            warn "frankenphp binary installed but frankenphp.service is not active"
        fi
        if [[ -f /etc/frankenphp/Caddyfile ]] && frankenphp validate --config /etc/frankenphp/Caddyfile >/dev/null 2>&1; then
            ok "/etc/frankenphp/Caddyfile syntax is valid"
        else
            warn "FrankenPHP Caddyfile validation failed or missing"
        fi
    fi
}

run_vps_security_audit

echo
log "Network & Listening Ports"
ss -lntp | sed -n '1p;/LISTEN/p' || true

if [[ -n "$SSH_PORT" ]]; then
    if ss -lnt "sport = :$SSH_PORT" 2>/dev/null | grep -q LISTEN; then
        ok "SSH listens on port $SSH_PORT"
    else
        warn "Configured SSH port $SSH_PORT is not detected by ss."
    fi
fi

if [[ "${INSTALL_MODE:-}" == "bare" ]]; then
    if ss -lnt "sport = :3001" 2>/dev/null | grep -q LISTEN; then
        ok "OpenShip Dashboard listens internally on port 3001"
    else
        warn "OpenShip Dashboard port 3001 not detected in LISTEN state."
    fi

    if ss -lnt "sport = :4000" 2>/dev/null | grep -q LISTEN; then
        ok "OpenShip API listens internally on port 4000"
    else
        warn "OpenShip API port 4000 not detected in LISTEN state."
    fi

    if curl -fsS --max-time 3 "http://127.0.0.1:4000/api/health" >/dev/null 2>&1; then
        ok "OpenShip API responds on http://127.0.0.1:4000/api/health"
    else
        warn "OpenShip API not responding on http://127.0.0.1:4000/api/health"
    fi

    if curl -fsS --max-time 3 -I "http://127.0.0.1:3001" >/dev/null 2>&1; then
        ok "OpenShip Dashboard responds on http://127.0.0.1:3001"
    else
        warn "OpenShip Dashboard not responding on http://127.0.0.1:3001"
    fi
fi

if [[ "${OPENSHIP_EDGE_ENABLED:-false}" == "true" ]]; then
    if ss -lnt "sport = :80" 2>/dev/null | grep -q LISTEN; then
        ok "Edge HTTP listens on port 80"
    else
        warn "Edge HTTP port 80 not detected in LISTEN state."
    fi

    if ss -lnt "sport = :443" 2>/dev/null | grep -q LISTEN; then
        ok "Edge HTTPS listens on port 443"
    else
        warn "Edge HTTPS port 443 not detected in LISTEN state."
    fi
fi

echo
log "Firewall (UFW)"
if command -v ufw >/dev/null 2>&1; then
    ufw status verbose || true
    if ufw status 2>/dev/null | grep -qE "(3001|3001/tcp).*ALLOW"; then
        warn "Port 3001 is open in UFW! Direct public access to 3001 bypasses Caddy reverse proxy. Run: 'ufw delete allow 3001/tcp'."
    else
        ok "Port 3001 is not exposed in UFW (safe behind Caddy / internal)."
    fi
    if ufw status 2>/dev/null | grep -qE "(4000|4000/tcp).*ALLOW"; then
        warn "Port 4000 is open in UFW! Direct public access to 4000 bypasses Caddy reverse proxy. Run: 'ufw delete allow 4000/tcp'."
    else
        ok "Port 4000 is not exposed in UFW (safe behind Caddy / internal)."
    fi
else
    warn "UFW is not installed."
fi

echo
log "Fail2ban"
if command -v fail2ban-client >/dev/null 2>&1; then
    fail2ban-client status sshd 2>/dev/null || true
else
    warn "Fail2ban is not installed."
fi

echo
log "Swap"
swapon --show || true

echo
log "Disk"
df -h /

echo
log "Memory"
free -h

echo
echo "Summary: ${PASS_COUNT} PASS | ${WARN_COUNT} WARN | ${FAIL_COUNT} FAIL"
if (( FAILED == 0 )); then
    ok "Doctor finished: no critical failures detected."
else
    fail "Doctor finished with critical failures."
fi

if [[ -n "$REPORT_FILE" ]]; then
    cp "$LOG_FILE" "$REPORT_FILE" 2>/dev/null || true
    echo "Report: $REPORT_FILE"
fi
echo
echo "Log: $LOG_FILE"

exit "$FAILED"
