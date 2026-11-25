#!/usr/bin/env bash

# ==============================================================================
# Site & FrankenPHP Manager CLI (site-cli)
# ==============================================================================
#
# Production site provisioner for FrankenPHP (Caddy + PHP), MariaDB & Redis.
#
# Usage:
#   site-cli create <domain> [options]
#   site-cli delete <domain> [options]
#   site-cli list
#   site-cli ssl <domain>
#   site-cli db <domain> <action: create|dump|drop>
#   site-cli install-global
#
# ==============================================================================

set -Eeuo pipefail

readonly CLI_VERSION="2.0.0"
readonly CADDYFILE="/etc/frankenphp/Caddyfile"
readonly SITES_DIR="/etc/frankenphp/sites.d"
readonly WWW_ROOT="/var/www"

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

log()     { echo -e "  ${BLUE}·${NC} $*"; }
success() { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $*"; }
error()   { echo -e "  ${RED}✗${NC} $*" >&2; }
die()     { echo; error "$*"; echo; exit 1; }

section() {
    echo
    echo -e "${BOLD}${CYAN}=== $* ===${NC}"
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

require_root() {
    if [[ $EUID -ne 0 && "${DRY_RUN:-false}" != "true" ]]; then
        die "This command requires root privileges. Please run with sudo: sudo site-cli $*"
    fi
}

command_exists() {
    command -v "$1" &>/dev/null
}

sanitize_name() {
    local raw="$1"
    # Replace dots, dashes and invalid chars with underscores
    local clean
    clean="$(echo "$raw" | tr -c 'a-zA-Z0-9_' '_' | tr -s '_' | sed 's/^_//;s/_$//')"
    # Truncate to max 24 chars to stay safely below MariaDB username limits
    echo "${clean:0:24}"
}

generate_password() {
    if command_exists openssl; then
        openssl rand -base64 24 | tr -dc 'A-Za-z0-9!@#$%^&*' | head -c 24
    else
        LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*' </dev/urandom | head -c 24
    fi
}

ensure_frankenphp_layout() {
    mkdir -p "$SITES_DIR" "/var/log/frankenphp"
    if [[ ! -f "$CADDYFILE" ]]; then
        cat > "$CADDYFILE" <<'EOF'
{
    frankenphp
}

import /etc/frankenphp/sites.d/*.caddy
EOF
    elif ! grep -q "import ${SITES_DIR}/\*.caddy" "$CADDYFILE" 2>/dev/null; then
        echo "" >> "$CADDYFILE"
        echo "import ${SITES_DIR}/*.caddy" >> "$CADDYFILE"
    fi
}

reload_frankenphp() {
    if ! command_exists frankenphp; then
        warn "frankenphp binary not found. Skipping config validation/reload."
        return 0
    fi
    if frankenphp validate --config "$CADDYFILE" >/dev/null 2>&1; then
        systemctl reload frankenphp 2>/dev/null || systemctl restart frankenphp 2>/dev/null || true
        return 0
    fi
    return 1
}

check_mysql_client() {
    if command_exists mariadb; then
        echo "mariadb"
    elif command_exists mysql; then
        echo "mysql"
    else
        echo ""
    fi
}

# ------------------------------------------------------------------------------
# Database Management
# ------------------------------------------------------------------------------

db_execute() {
    local sql="$1"
    local client
    client="$(check_mysql_client)"
    if [[ -z "$client" ]]; then
        die "Neither 'mariadb' nor 'mysql' client found. Please install mariadb-server."
    fi

    $client -e "$sql"
}

db_create() {
    local db_name="$1"
    local db_user="$2"
    local db_pass="$3"

    log "Creating MariaDB database '${db_name}' and user '${db_user}'..."

    db_execute "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    db_execute "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"
    db_execute "CREATE USER IF NOT EXISTS '${db_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';"
    db_execute "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';"
    db_execute "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'127.0.0.1';"
    db_execute "FLUSH PRIVILEGES;"

    success "Database '${db_name}' and user '${db_user}' configured."
}

db_drop() {
    local db_name="$1"
    local db_user="$2"

    warn "Dropping MariaDB database '${db_name}' and user '${db_user}'..."
    db_execute "DROP DATABASE IF EXISTS \`${db_name}\`;" || true
    db_execute "DROP USER IF EXISTS '${db_user}'@'localhost';" || true
    db_execute "DROP USER IF EXISTS '${db_user}'@'127.0.0.1';" || true
    db_execute "FLUSH PRIVILEGES;" || true
    success "Database and user dropped."
}

# ------------------------------------------------------------------------------
# Nginx Configuration Generator
# ------------------------------------------------------------------------------

generate_caddy_config() {
    local domain="$1"
    local web_root="$2"
    local template="$3"
    local enable_ssl="${4:-true}"
    local proxy_port="${5:-8080}"

    local site_addr="${domain}, www.${domain}"
    if [[ "$enable_ssl" != "true" ]]; then
        site_addr="http://${domain}, http://www.${domain}"
    fi

    cat <<EOF
# ==============================================================================
# FrankenPHP / Caddy Configuration for ${domain} (Template: ${template})
# ==============================================================================

${site_addr} {
    encode zstd gzip

    log {
        output file /var/log/frankenphp/${domain}.access.log
    }

    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }
EOF

    case "$template" in
        opencart)
            cat <<EOF

    root * ${web_root}

    @forbidden {
        path /system/* *.ini *.log *.tpl *.twig *.yaml *.yml *.sql /.env* /.*
        not path /.well-known/*
    }
    respond @forbidden 403

    @sitemap path /sitemap.xml
    rewrite @sitemap /index.php?route=extension/feed/google_sitemap

    @googlebase path /googlebase.xml
    rewrite @googlebase /index.php?route=extension/feed/google_base

    @static file
    header @static Cache-Control "public, max-age=2592000"

    php_server {
        try_files {path} {path}/ /index.php?_route_={path}&{query}
    }
}
EOF
            ;;

        wordpress)
            cat <<EOF

    root * ${web_root}

    @forbidden {
        path /wp-config.php /xmlrpc.php /wp-content/uploads/*.php /wp-includes/*.php /.env* /.*
        not path /.well-known/*
    }
    respond @forbidden 403

    @static file
    header @static Cache-Control "public, max-age=2592000"

    php_server
}
EOF
            ;;

        laravel)
            cat <<EOF

    root * ${web_root}

    @forbidden {
        path /.env* /.*
        not path /.well-known/*
    }
    respond @forbidden 403

    @static file
    header @static Cache-Control "public, max-age=2592000"

    php_server
}
EOF
            ;;

        static)
            cat <<EOF

    root * ${web_root}

    @forbidden {
        path /.env* /.*
        not path /.well-known/*
    }
    respond @forbidden 403

    @static file
    header @static Cache-Control "public, max-age=2592000"

    file_server
}
EOF
            ;;

        proxy)
            cat <<EOF

    reverse_proxy 127.0.0.1:${proxy_port}
}
EOF
            ;;

        generic|*)
            cat <<EOF

    root * ${web_root}

    @forbidden {
        path /.env* /.*
        not path /.well-known/*
    }
    respond @forbidden 403

    @static file
    header @static Cache-Control "public, max-age=2592000"

    php_server
}
EOF
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Starter Page Generator
# ------------------------------------------------------------------------------

create_starter_page() {
    local domain="$1"
    local web_root="$2"
    local template="$3"
    local db_name="${4:-}"
    local db_user="${5:-}"

    if [[ -f "${web_root}/index.php" || -f "${web_root}/index.html" ]]; then
        return 0
    fi

    if [[ "$template" == "static" ]]; then
        cat > "${web_root}/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${domain} — Server Ready</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #f8fafc; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
        .card { background: #1e293b; padding: 2.5rem; border-radius: 1rem; box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.3); border: 1px solid #334155; max-width: 500px; text-align: center; }
        h1 { margin-top: 0; color: #38bdf8; font-size: 1.8rem; }
        p { color: #94a3b8; line-height: 1.6; }
        .badge { display: inline-block; background: #0369a1; color: #e0f2fe; padding: 0.3rem 0.8rem; border-radius: 9999px; font-size: 0.85rem; font-weight: 600; margin-bottom: 1rem; }
    </style>
</head>
<body>
    <div class="card">
        <span class="badge">Static Site</span>
        <h1>${domain}</h1>
        <p>Your high-performance static website is ready. Replace this file at <code>${web_root}/index.html</code>.</p>
    </div>
</body>
</html>
EOF
    else
        cat > "${web_root}/index.php" <<'EOF'
<?php
$domain = $_SERVER['HTTP_HOST'] ?? 'Website';
$envFile = dirname(__DIR__) . '/.env';
$dbConnected = false;
$dbError = '';

if (file_exists($envFile)) {
    $env = parse_ini_file($envFile);
    if (!empty($env['DB_DATABASE']) && !empty($env['DB_USERNAME'])) {
        try {
            $pdo = new PDO(
                "mysql:host=" . ($env['DB_HOST'] ?? '127.0.0.1') . ";port=" . ($env['DB_PORT'] ?? '3306') . ";dbname=" . $env['DB_DATABASE'],
                $env['DB_USERNAME'],
                $env['DB_PASSWORD'] ?? '',
                [PDO::ATTR_TIMEOUT => 2, PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
            );
            $dbConnected = true;
        } catch (Exception $e) {
            $dbError = $e->getMessage();
        }
    }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><?= htmlspecialchars($domain) ?> — Server Ready</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #f8fafc; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
        .card { background: #1e293b; padding: 2.5rem; border-radius: 1rem; box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.3); border: 1px solid #334155; max-width: 520px; width: 100%; }
        h1 { margin-top: 0; color: #38bdf8; font-size: 1.8rem; text-align: center; }
        p { color: #94a3b8; line-height: 1.6; }
        .badge { display: inline-block; background: #0284c7; color: #f0f9ff; padding: 0.3rem 0.8rem; border-radius: 9999px; font-size: 0.85rem; font-weight: 600; }
        .status { margin: 1.5rem 0; padding: 1rem; border-radius: 0.5rem; font-size: 0.95rem; }
        .status.ok { background: rgba(34, 197, 94, 0.15); border: 1px solid #22c55e; color: #4ade80; }
        .status.err { background: rgba(239, 68, 68, 0.15); border: 1px solid #ef4444; color: #f87171; }
        .info { background: #0f172a; padding: 1rem; border-radius: 0.5rem; font-size: 0.85rem; color: #cbd5e1; font-family: monospace; }
        .header { text-align: center; margin-bottom: 1.5rem; }
    </style>
</head>
<body>
    <div class="card">
        <div class="header">
            <span class="badge">LEMP Stack</span>
            <h1><?= htmlspecialchars($domain) ?></h1>
            <p>Your high-performance web environment is ready.</p>
        </div>

        <?php if ($dbConnected): ?>
            <div class="status ok">✓ MariaDB Database: Connected successfully</div>
        <?php elseif (!empty($dbError)): ?>
            <div class="status err">✗ Database connection failed: <?= htmlspecialchars($dbError) ?></div>
        <?php else: ?>
            <div class="status ok">✓ PHP <?= PHP_VERSION ?> running</div>
        <?php endif; ?>

        <div class="info">
            <div><strong>PHP Version:</strong> <?= PHP_VERSION ?></div>
            <div><strong>Web Root:</strong> <?= htmlspecialchars(__DIR__) ?></div>
            <div><strong>Config File:</strong> <?= htmlspecialchars($envFile) ?></div>
        </div>
    </div>
</body>
</html>
EOF
    fi
}

# ------------------------------------------------------------------------------
# Subcommand: create
# ------------------------------------------------------------------------------

cmd_create() {
    local domain=""
    local template="generic"
    local custom_php=""
    local with_db="true"
    local enable_ssl="true"
    local proxy_port="8080"
    local custom_db_name=""
    local custom_db_user=""
    local dry_run="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --template=*|--type=*)
                template="${1#*=}"
                shift
                ;;
            --template|--type)
                template="${2:-generic}"
                shift 2
                ;;
            --php=*)
                custom_php="${1#*=}"
                shift
                ;;
            --php)
                custom_php="${2:-}"
                shift 2
                ;;
            --port=*)
                proxy_port="${1#*=}"
                shift
                ;;
            --port)
                proxy_port="${2:-8080}"
                shift 2
                ;;
            --with-db)
                with_db="true"
                shift
                ;;
            --without-db)
                with_db="false"
                shift
                ;;
            --ssl)
                enable_ssl="true"
                shift
                ;;
            --no-ssl)
                enable_ssl="false"
                shift
                ;;
            --db-name=*)
                custom_db_name="${1#*=}"
                shift
                ;;
            --db-user=*)
                custom_db_user="${1#*=}"
                shift
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                if [[ -z "$domain" ]]; then
                    domain="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$domain" ]]; then
        die "Domain name required: site-cli create <domain> [options]"
    fi

    domain="$(echo "$domain" | tr '[:upper:]' '[:lower:]' | sed 's|^https\?://||;s|/.*$||')"

    case "$template" in
        generic|php) template="generic" ;;
        wordpress|opencart|laravel|static|proxy) ;;
        *)
            die "Invalid template: '${template}'. Allowed: generic, php, wordpress, opencart, laravel, static, proxy"
            ;;
    esac

    local site_root="${WWW_ROOT}/${domain}"
    local web_root="${site_root}/public"
    local caddy_snippet="${SITES_DIR}/${domain}.caddy"
    local env_file="${site_root}/.env"
    local creds_file="${site_root}/credentials.txt"

    section "Creating Website: ${domain}"
    log "Template:  ${template}"
    log "Site root: ${site_root}"
    log "Web root:  ${web_root}"
    [[ -n "$custom_php" ]] && log "Note:      FrankenPHP uses embedded PHP (--php=${custom_php} ignored)."

    if [[ "$dry_run" == "true" ]]; then
        log "[DRY RUN] Would create directory ${site_root} and ${web_root}"
        log "[DRY RUN] Would generate FrankenPHP config at ${caddy_snippet}"
        log "[DRY RUN] Would validate with frankenphp validate and reload frankenphp"
        if [[ "$with_db" == "true" ]]; then
            log "[DRY RUN] Would create MariaDB database and user"
        fi
        success "[DRY RUN] Site validation completed successfully."
        return 0
    fi

    require_root

    mkdir -p "${web_root}"
    ensure_frankenphp_layout

    log "Generating FrankenPHP / Caddy config..."
    generate_caddy_config "$domain" "$web_root" "$template" "$enable_ssl" "$proxy_port" > "${caddy_snippet}"

    if reload_frankenphp; then
        success "FrankenPHP configuration validated and reloaded."
    else
        error "FrankenPHP configuration validation failed! Reverting ${caddy_snippet}..."
        rm -f "${caddy_snippet}"
        frankenphp validate --config "$CADDYFILE" || true
        die "Check ${CADDYFILE} or ${caddy_snippet}"
    fi

    local db_name=""
    local db_user=""
    local db_pass=""

    if [[ "$with_db" == "true" ]]; then
        local clean_name
        clean_name="$(sanitize_name "$domain")"
        db_name="${custom_db_name:-${clean_name}_db}"
        db_user="${custom_db_user:-${clean_name}_usr}"
        db_pass="$(generate_password)"

        db_create "$db_name" "$db_user" "$db_pass"

        local scheme="https"
        [[ "$enable_ssl" != "true" ]] && scheme="http"

        log "Writing database credentials to site directory (level above web root)..."
        cat > "${env_file}" <<EOF
# ==============================================================================
# Environment Configuration for ${domain}
# Generated by site-cli at $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# ==============================================================================

APP_ENV=production
APP_URL=${scheme}://${domain}
APP_DEBUG=false

# Database (MariaDB)
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${db_name}
DB_USERNAME=${db_user}
DB_PASSWORD="${db_pass}"

# Cache / Queue (Redis)
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=null

# Site Paths
SITE_ROOT=${site_root}
WEB_ROOT=${web_root}
TEMPLATE=${template}
EOF

        cat > "${creds_file}" <<EOF
================================================================================
Site Access Summary
================================================================================
Domain:           ${domain} (www.${domain})
Template:         ${template}
Date Created:     $(date -u +"%Y-%m-%d %H:%M:%S UTC")

Directories:
  Site Directory: ${site_root}
  Web Directory:  ${web_root}
  Caddy Config:   ${caddy_snippet}
  Log File:       /var/log/frankenphp/${domain}.access.log

MariaDB Database Credentials:
  Host:           127.0.0.1 (or localhost via socket)
  Port:           3306
  Database Name:  ${db_name}
  Database User:  ${db_user}
  Database Pass:  ${db_pass}

Redis Cache:
  Host:           127.0.0.1
  Port:           6379

Config Files:
  Environment:    ${env_file} (chmod 600)
  Summary:        ${creds_file} (chmod 600)
================================================================================
EOF
        chmod 600 "${env_file}" "${creds_file}"
        success "Credentials securely written to ${env_file} and ${creds_file} (chmod 600)."
    fi

    create_starter_page "$domain" "$web_root" "$template" "$db_name" "$db_user"

    local web_user="www-data"
    chown -R "${web_user}:${web_user}" "${site_root}" 2>/dev/null || true
    chmod 755 "${site_root}" "${web_root}" 2>/dev/null || true

    local display_scheme="https"
    [[ "$enable_ssl" != "true" ]] && display_scheme="http"

    section "Site Created Successfully"
    echo -e "  Domain:    ${BOLD}${GREEN}${display_scheme}://${domain}${NC}"
    echo -e "  Web root:  ${web_root}"
    echo -e "  Config:    ${caddy_snippet}"
    if [[ "$with_db" == "true" ]]; then
        echo -e "  Database:  ${db_name} (User: ${db_user})"
        echo -e "  Env file:  ${env_file}"
    fi
    echo
}

# ------------------------------------------------------------------------------
# Subcommand: delete
# ------------------------------------------------------------------------------

cmd_delete() {
    local domain=""
    local with_db="false"
    local force="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-db)
                with_db="true"
                shift
                ;;
            --force|-f)
                force="true"
                shift
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                if [[ -z "$domain" ]]; then
                    domain="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$domain" ]]; then
        die "Domain name required: site-cli delete <domain> [options]"
    fi

    domain="$(echo "$domain" | tr '[:upper:]' '[:lower:]' | sed 's|^https\?://||;s|/.*$||')"

    local site_root="${WWW_ROOT}/${domain}"
    local caddy_snippet="${SITES_DIR}/${domain}.caddy"
    local env_file="${site_root}/.env"

    if [[ "$force" != "true" ]]; then
        echo
        echo -e "  ${YELLOW}${BOLD}Are you sure you want to delete website '${domain}'?${NC}"
        if [[ "$with_db" == "true" ]]; then
            echo -e "  ${RED}WARNING: Associated MariaDB database and user will also be permanently deleted!${NC}"
        fi
        read -r -p "  Proceed with deletion? [y/N] " response
        case "$response" in
            [yY][eE][sS]|[yY])
                ;;
            *)
                echo "Aborted."
                return 0
                ;;
        esac
    fi

    require_root

    # Delete DB if requested
    if [[ "$with_db" == "true" ]]; then
        local db_name=""
        local db_user=""
        if [[ -f "$env_file" ]]; then
            db_name="$(grep -E '^DB_DATABASE=' "$env_file" | cut -d '=' -f2- | tr -d '"'"'" || true)"
            db_user="$(grep -E '^DB_USERNAME=' "$env_file" | cut -d '=' -f2- | tr -d '"'"'" || true)"
        fi
        if [[ -z "$db_name" ]]; then
            local clean_name
            clean_name="$(sanitize_name "$domain")"
            db_name="${clean_name}_db"
            db_user="${clean_name}_usr"
        fi
        db_drop "$db_name" "$db_user"
    fi

    # Remove FrankenPHP/Caddy configuration
    log "Removing FrankenPHP configuration..."
    rm -f "${caddy_snippet}"
    reload_frankenphp || true
    success "FrankenPHP configuration removed and reloaded."

    # Remove site directory
    if [[ -d "${site_root}" ]]; then
        log "Removing site files from ${site_root}..."
        rm -rf "${site_root}"
        success "Site files removed."
    fi

    success "Site '${domain}' deleted."
}

# ------------------------------------------------------------------------------
# Subcommand: list
# ------------------------------------------------------------------------------

cmd_list() {
    section "Configured Websites"

    if [[ ! -d "${SITES_DIR}" ]]; then
        warn "FrankenPHP sites directory not found at ${SITES_DIR}."
        return 0
    fi

    local count=0
    printf "  %-24s %-10s %-8s %-12s %s\n" "DOMAIN" "STATUS" "SSL" "TEMPLATE" "WEB ROOT / TARGET"
    printf "  %-24s %-10s %-8s %-12s %s\n" "------------------------" "----------" "--------" "------------" "------------------------"

    for conf in "${SITES_DIR}"/*.caddy; do
        [[ -f "$conf" ]] || continue
        local domain
        domain="$(basename "$conf" .caddy)"

        local status="active"
        local ssl="auto-tls"
        if grep -qE '^\s*http://' "$conf" 2>/dev/null; then
            ssl="http"
        fi

        local template="generic"
        if grep -qi "Template: opencart" "$conf" 2>/dev/null; then
            template="opencart"
        elif grep -qi "Template: wordpress" "$conf" 2>/dev/null; then
            template="wordpress"
        elif grep -qi "Template: laravel" "$conf" 2>/dev/null; then
            template="laravel"
        elif grep -qi "Template: static" "$conf" 2>/dev/null; then
            template="static"
        elif grep -qi "Template: proxy" "$conf" 2>/dev/null; then
            template="proxy"
        fi

        local target_path
        if [[ "$template" == "proxy" ]]; then
            target_path="$(grep -E '^\s*reverse_proxy\s+' "$conf" | head -n1 | awk '{print $2}' || echo "127.0.0.1:8080")"
        else
            target_path="$(grep -E '^\s*root\s+\*\s+' "$conf" | head -n1 | awk '{print $3}' || echo "${WWW_ROOT}/${domain}/public")"
        fi

        printf "  %-24s %-19b %-17b %-12s %s\n" "${domain}" "${GREEN}${status}${NC}" "${GREEN}${ssl}${NC}" "${template}" "${target_path}"
        count=$((count + 1))
    done

    echo
    if [[ $count -eq 0 ]]; then
        log "No websites configured yet. Create one with: site-cli create <domain>"
    else
        success "Total sites: ${count}"
    fi
    echo
}

# ------------------------------------------------------------------------------
# Subcommand: ssl
# ------------------------------------------------------------------------------

cmd_ssl() {
    local domain="${1:-}"

    if [[ -z "$domain" ]]; then
        die "Domain name required: site-cli ssl <domain>"
    fi

    domain="$(echo "$domain" | tr '[:upper:]' '[:lower:]' | sed 's|^https\?://||;s|/.*$||')"
    local caddy_snippet="${SITES_DIR}/${domain}.caddy"

    require_root

    if [[ ! -f "$caddy_snippet" ]]; then
        die "Site config not found: ${caddy_snippet}"
    fi

    section "Enabling Automatic HTTPS (Caddy/FrankenPHP) for ${domain}"
    sed -i -E 's|http://([^ ,]+)|\1|g' "$caddy_snippet"

    if reload_frankenphp; then
        success "Automatic HTTPS enabled and FrankenPHP reloaded for ${domain}!"
    else
        die "FrankenPHP validation failed for ${caddy_snippet}."
    fi

    local env_file="${WWW_ROOT}/${domain}/.env"
    if [[ -f "$env_file" ]]; then
        sed -i -E 's|^APP_URL=http://|APP_URL=https://|' "$env_file" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Subcommand: db
# ------------------------------------------------------------------------------

cmd_db() {
    local domain="${1:-}"
    local action="${2:-create}"

    if [[ -z "$domain" ]]; then
        die "Usage: site-cli db <domain> [create|dump|drop]"
    fi

    domain="$(echo "$domain" | tr '[:upper:]' '[:lower:]' | sed 's|^https\?://||;s|/.*$||')"
    local env_file="${WWW_ROOT}/${domain}/.env"

    local db_name=""
    local db_user=""
    local db_pass=""

    if [[ -f "$env_file" ]]; then
        db_name="$(grep -E '^DB_DATABASE=' "$env_file" | cut -d '=' -f2- | tr -d '"'"'" || true)"
        db_user="$(grep -E '^DB_USERNAME=' "$env_file" | cut -d '=' -f2- | tr -d '"'"'" || true)"
        db_pass="$(grep -E '^DB_PASSWORD=' "$env_file" | cut -d '=' -f2- | tr -d '"'"'" || true)"
    fi

    if [[ -z "$db_name" ]]; then
        local clean_name
        clean_name="$(sanitize_name "$domain")"
        db_name="${clean_name}_db"
        db_user="${clean_name}_usr"
    fi

    require_root

    case "$action" in
        create)
            if [[ -z "$db_pass" ]]; then
                db_pass="$(generate_password)"
            fi
            db_create "$db_name" "$db_user" "$db_pass"
            echo "Database: ${db_name}"
            echo "User:     ${db_user}"
            echo "Password: ${db_pass}"
            ;;
        drop)
            db_drop "$db_name" "$db_user"
            ;;
        dump)
            local client
            client="$(check_mysql_client)"
            local dump_file="${WWW_ROOT}/${domain}/${db_name}_backup_$(date +%Y%m%d_%H%M%S).sql"
            log "Dumping database '${db_name}' to ${dump_file}..."
            mysqldump "$db_name" > "$dump_file"
            chmod 600 "$dump_file"
            success "Dump saved to ${dump_file}"
            ;;
        *)
            die "Unknown db action: '$action'. Allowed: create, dump, drop"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Subcommand: install-global
# ------------------------------------------------------------------------------

cmd_install_global() {
    require_root
    local src_script
    src_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    log "Linking ${src_script} -> /usr/local/bin/site-cli..."
    chmod +x "${src_script}"
    ln -sf "${src_script}" /usr/local/bin/site-cli
    success "Installed successfully! You can now run 'site-cli' from any directory."
}

# ------------------------------------------------------------------------------
# Help
# ------------------------------------------------------------------------------

show_help() {
    cat <<EOF
Site & FrankenPHP Manager CLI (v${CLI_VERSION})

Usage:
  site-cli <command> [arguments] [options]

Commands:
  create <domain> [options]    Create a new website, FrankenPHP/Caddy config, and MariaDB database
  delete <domain> [options]    Delete a website and optionally its database
  list                         List all configured websites and their status
  ssl <domain>                 Enable automatic HTTPS (Caddy/FrankenPHP) for a domain
  db <domain> [create|dump|drop] Manage MariaDB database for a domain
  install-global               Install symlink to /usr/local/bin/site-cli
  version, -v                  Display CLI version
  help, -h                     Display this help message

Options for 'create':
  --template=<type>, --type=   Site template: opencart, wordpress, laravel, php, generic, static, proxy (default: generic)
  --port=<port>                Backend port for proxy template (default: 8080)
  --with-db                    Create MariaDB database & user (default)
  --without-db                 Skip database creation
  --db-name=<name>             Custom database name (default: <domain>_db)
  --db-user=<user>             Custom database user (default: <domain>_usr)
  --ssl / --no-ssl             Enable automatic HTTPS (default: enabled) or HTTP-only
  --dry-run                    Simulate creation without writing changes

Options for 'delete':
  --with-db                    Drop the associated MariaDB database and user
  --force, -f                  Do not prompt for confirmation

Directory structure created:
  /var/www/<domain>/
  ├── .env                     <- Database & app credentials (chmod 600)
  ├── credentials.txt          <- Detailed access summary (chmod 600)
  └── public/                  <- Web root served by FrankenPHP
      └── index.php            <- Starter status page

Examples:
  site-cli create shop.example.com --template opencart --ssl
  site-cli create blog.example.com --template wordpress --ssl
  site-cli create api.example.com --template laravel
  site-cli list
  site-cli db shop.example.com dump
  site-cli delete shop.example.com --with-db
EOF
}

# ------------------------------------------------------------------------------
# Main Dispatcher
# ------------------------------------------------------------------------------

main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        create)
            cmd_create "$@"
            ;;
        delete|remove)
            cmd_delete "$@"
            ;;
        list|ls)
            cmd_list "$@"
            ;;
        ssl)
            cmd_ssl "$@"
            ;;
        db)
            cmd_db "$@"
            ;;
        install-global|--install-global)
            cmd_install_global "$@"
            ;;
        version|-v|--version)
            echo "site-cli v${CLI_VERSION}"
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            die "Unknown command: '$cmd'. Run 'site-cli --help' for usage."
            ;;
    esac
}

main "$@"
