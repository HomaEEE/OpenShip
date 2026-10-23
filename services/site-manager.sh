#!/usr/bin/env bash

# ==============================================================================
# OpenShip Site & Nginx Manager CLI (site-cli)
# ==============================================================================
#
# Production site provisioner for Nginx, PHP-FPM, MariaDB & Redis.
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

readonly CLI_VERSION="1.0.0"
readonly SITES_AVAILABLE="/etc/nginx/sites-available"
readonly SITES_ENABLED="/etc/nginx/sites-enabled"
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

detect_php_socket() {
    local custom_php="${1:-}"

    if [[ -n "$custom_php" ]]; then
        # Check specific PHP version socket
        local specific_sock="/run/php/php${custom_php}-fpm.sock"
        if [[ -S "$specific_sock" ]]; then
            echo "unix:${specific_sock}"
            return 0
        fi
    fi

    # Find active php-fpm unix socket in /run/php
    local found_sock
    found_sock="$(find /run/php/ -maxdepth 1 -name 'php*-fpm.sock' 2>/dev/null | sort -V -r | head -n1 || true)"
    if [[ -n "$found_sock" && -S "$found_sock" ]]; then
        echo "unix:${found_sock}"
        return 0
    fi

    # Default fallback to php8.3 or php8.2
    if [[ -S "/run/php/php8.3-fpm.sock" ]]; then
        echo "unix:/run/php/php8.3-fpm.sock"
    elif [[ -S "/run/php/php8.2-fpm.sock" ]]; then
        echo "unix:/run/php/php8.2-fpm.sock"
    elif [[ -S "/run/php/php8.1-fpm.sock" ]]; then
        echo "unix:/run/php/php8.1-fpm.sock"
    else
        echo "unix:/run/php/php-fpm.sock"
    fi
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

generate_nginx_config() {
    local domain="$1"
    local web_root="$2"
    local template="$3"
    local php_sock="$4"

    case "$template" in
        opencart)
            cat <<EOF
# ==============================================================================
# OpenShip Nginx Configuration for ${domain} (Template: OpenCart)
# ==============================================================================

server {
    listen 80;
    listen [::]:80;
    server_name ${domain} www.${domain};

    root ${web_root};
    index index.php index.html index.htm;

    # Logging
    access_log /var/log/nginx/${domain}.access.log;
    error_log /var/log/nginx/${domain}.error.log warn;

    # Security Headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # OpenCart SEO URL rewrites
    location / {
        try_files \$uri \$uri/ @opencart;
    }

    location @opencart {
        rewrite ^/(.+)$ /index.php?_route_=\$1 last;
    }

    # OpenCart SEO Feeds
    location = /sitemap.xml {
        rewrite ^ /index.php?route=extension/feed/google_sitemap break;
    }
    location = /googlebase.xml {
        rewrite ^ /index.php?route=extension/feed/google_base break;
    }

    # Block sensitive OpenCart system storage and configs
    location ^~ /system/storage/ {
        deny all;
        return 403;
    }
    location ^~ /system/ {
        deny all;
        return 403;
    }
    location ~* \.(ini|log|tpl|twig|yaml|yml|sql)$ {
        deny all;
        return 403;
    }

    # PHP-FPM Handler
    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass ${php_sock};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffer_size 64k;
        fastcgi_buffers 16 32k;
        fastcgi_busy_buffers_size 128k;
        fastcgi_read_timeout 300s;
    }

    # Static Assets Caching & Brotli/Gzip
    location ~* \.(jpg|jpeg|gif|png|webp|svg|ico|css|js|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        try_files \$uri \$uri/ /index.php?\$args;
        access_log off;
    }

    # Protect Hidden Files
    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
            ;;

        wordpress)
            cat <<EOF
# ==============================================================================
# OpenShip Nginx Configuration for ${domain} (Template: WordPress)
# ==============================================================================

server {
    listen 80;
    listen [::]:80;
    server_name ${domain} www.${domain};

    root ${web_root};
    index index.php index.html index.htm;

    access_log /var/log/nginx/${domain}.access.log;
    error_log /var/log/nginx/${domain}.error.log warn;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass ${php_sock};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffer_size 64k;
        fastcgi_buffers 16 32k;
        fastcgi_busy_buffers_size 128k;
        fastcgi_read_timeout 300s;
    }

    location ~* wp-config.php {
        deny all;
    }
    location ~* /(?:uploads|files)/.*\.php$ {
        deny all;
    }
    location ~ /\.(?!well-known).* {
        deny all;
    }

    location ~* \.(jpg|jpeg|gif|png|webp|svg|ico|css|js|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        access_log off;
    }
}
EOF
            ;;

        laravel)
            cat <<EOF
# ==============================================================================
# OpenShip Nginx Configuration for ${domain} (Template: Laravel)
# ==============================================================================

server {
    listen 80;
    listen [::]:80;
    server_name ${domain} www.${domain};

    root ${web_root};
    index index.php index.html;

    access_log /var/log/nginx/${domain}.access.log;
    error_log /var/log/nginx/${domain}.error.log warn;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass ${php_sock};
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffer_size 64k;
        fastcgi_buffers 16 32k;
        fastcgi_busy_buffers_size 128k;
        fastcgi_read_timeout 300s;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    location ~* \.(jpg|jpeg|gif|png|webp|svg|ico|css|js|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        access_log off;
    }
}
EOF
            ;;

        static)
            cat <<EOF
# ==============================================================================
# OpenShip Nginx Configuration for ${domain} (Template: Static HTML)
# ==============================================================================

server {
    listen 80;
    listen [::]:80;
    server_name ${domain} www.${domain};

    root ${web_root};
    index index.html index.htm;

    access_log /var/log/nginx/${domain}.access.log;
    error_log /var/log/nginx/${domain}.error.log warn;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    location ~* \.(jpg|jpeg|gif|png|webp|svg|ico|css|js|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        access_log off;
    }
}
EOF
            ;;

        generic|*)
            cat <<EOF
# ==============================================================================
# OpenShip Nginx Configuration for ${domain} (Template: Generic PHP)
# ==============================================================================

server {
    listen 80;
    listen [::]:80;
    server_name ${domain} www.${domain};

    root ${web_root};
    index index.php index.html index.htm;

    access_log /var/log/nginx/${domain}.access.log;
    error_log /var/log/nginx/${domain}.error.log warn;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass ${php_sock};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffer_size 64k;
        fastcgi_buffers 16 32k;
        fastcgi_busy_buffers_size 128k;
        fastcgi_read_timeout 300s;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    location ~* \.(jpg|jpeg|gif|png|webp|svg|ico|css|js|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        access_log off;
    }
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
    <title>${domain} — Powered by OpenShip</title>
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
        <span class="badge">OpenShip Static</span>
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
    <title><?= htmlspecialchars($domain) ?> — Powered by OpenShip</title>
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
            <span class="badge">OpenShip LEMP Stack</span>
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
    local enable_ssl="false"
    local custom_db_name=""
    local custom_db_user=""
    local dry_run="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --template=*)
                template="${1#*=}"
                shift
                ;;
            --template)
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

    # Normalize domain
    domain="$(echo "$domain" | tr '[:upper:]' '[:lower:]' | sed 's|^https\?://||;s|/.*$||')"

    # Validate template
    case "$template" in
        generic|wordpress|opencart|laravel|static)
            ;;
        *)
            die "Invalid template: '${template}'. Allowed: generic, wordpress, opencart, laravel, static"
            ;;
    esac

    local site_root="${WWW_ROOT}/${domain}"
    local web_root="${site_root}/public"
    local nginx_available="${SITES_AVAILABLE}/${domain}.conf"
    local nginx_enabled="${SITES_ENABLED}/${domain}.conf"
    local env_file="${site_root}/.env"
    local creds_file="${site_root}/credentials.txt"

    section "Creating Website: ${domain}"
    log "Template:  ${template}"
    log "Site root: ${site_root}"
    log "Web root:  ${web_root}"

    if [[ "$dry_run" == "true" ]]; then
        log "[DRY RUN] Would create directory ${site_root} and ${web_root}"
        log "[DRY RUN] Would generate Nginx config at ${nginx_available}"
        log "[DRY RUN] Would link to ${nginx_enabled} and test with nginx -t"
        if [[ "$with_db" == "true" ]]; then
            log "[DRY RUN] Would create MariaDB database and user"
            log "[DRY RUN] Would write credentials to ${env_file} and ${creds_file}"
        fi
        if [[ "$enable_ssl" == "true" ]]; then
            log "[DRY RUN] Would run certbot --nginx -d ${domain} -d www.${domain}"
        fi
        success "[DRY RUN] Site validation completed successfully."
        return 0
    fi

    require_root

    # 1. Directories
    mkdir -p "${web_root}"
    mkdir -p "${SITES_AVAILABLE}" "${SITES_ENABLED}"

    # 2. PHP Socket
    local php_sock
    php_sock="$(detect_php_socket "$custom_php")"
    log "PHP-FPM:   ${php_sock}"

    # 3. Nginx Config
    log "Generating Nginx server block..."
    generate_nginx_config "$domain" "$web_root" "$template" "$php_sock" > "${nginx_available}"
    ln -sf "${nginx_available}" "${nginx_enabled}"

    # 4. Verify Nginx Syntax
    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
        success "Nginx configuration activated and reloaded."
    else
        error "Nginx configuration test failed! Reverting link..."
        rm -f "${nginx_enabled}"
        nginx -t || true
        die "Check /var/log/nginx/error.log or ${nginx_available}"
    fi

    # 5. Database
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

        # Write credentials on level ABOVE web root: /var/www/<domain>/.env and credentials.txt
        log "Writing database credentials to site directory (level above web root)..."
        cat > "${env_file}" <<EOF
# ==============================================================================
# Environment Configuration for ${domain}
# Generated by OpenShip site-cli at $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# ==============================================================================

APP_ENV=production
APP_URL=http://${domain}
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
OpenShip Site Access Summary
================================================================================
Domain:           ${domain} (www.${domain})
Template:         ${template}
Date Created:     $(date -u +"%Y-%m-%d %H:%M:%S UTC")

Directories:
  Site Directory: ${site_root}
  Web Directory:  ${web_root}
  Nginx Config:   ${nginx_available}
  Log Files:      /var/log/nginx/${domain}.access.log
                  /var/log/nginx/${domain}.error.log

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

    # 6. Starter Page
    create_starter_page "$domain" "$web_root" "$template" "$db_name" "$db_user"

    # 7. Permissions
    local web_user="www-data"
    chown -R "${web_user}:${web_user}" "${site_root}" 2>/dev/null || true
    chmod 755 "${site_root}" "${web_root}" 2>/dev/null || true

    # 8. SSL via Certbot if requested
    if [[ "$enable_ssl" == "true" ]]; then
        cmd_ssl "$domain"
    fi

    section "Site Created Successfully"
    echo -e "  Domain:    ${BOLD}${GREEN}http://${domain}${NC}"
    echo -e "  Web root:  ${web_root}"
    if [[ "$with_db" == "true" ]]; then
        echo -e "  Database:  ${db_name} (User: ${db_user})"
        echo -e "  Config:    ${env_file}"
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
    local nginx_available="${SITES_AVAILABLE}/${domain}.conf"
    local nginx_enabled="${SITES_ENABLED}/${domain}.conf"
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

    # Remove Nginx configurations
    log "Removing Nginx configuration..."
    rm -f "${nginx_enabled}" "${nginx_available}"
    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || true
    fi
    success "Nginx configuration removed and reloaded."

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

    if [[ ! -d "${SITES_AVAILABLE}" ]]; then
        warn "Nginx sites directory not found at ${SITES_AVAILABLE}."
        return 0
    fi

    local count=0
    printf "  %-24s %-10s %-8s %-12s %s\n" "DOMAIN" "STATUS" "SSL" "TEMPLATE" "WEB ROOT"
    printf "  %-24s %-10s %-8s %-12s %s\n" "------------------------" "----------" "--------" "------------" "------------------------"

    for conf in "${SITES_AVAILABLE}"/*.conf; do
        [[ -f "$conf" ]] || continue
        local domain
        domain="$(basename "$conf" .conf)"
        [[ "$domain" != "default" && "$domain" != "00-default" ]] || continue

        local status="disabled"
        if [[ -f "${SITES_ENABLED}/${domain}.conf" ]]; then
            status="active"
        fi

        local ssl="no"
        if grep -q "ssl_certificate" "$conf" 2>/dev/null || grep -q "listen 443" "$conf" 2>/dev/null; then
            ssl="yes"
        fi

        local template="generic"
        if grep -q "Template: OpenCart" "$conf" 2>/dev/null; then
            template="opencart"
        elif grep -q "Template: WordPress" "$conf" 2>/dev/null; then
            template="wordpress"
        elif grep -q "Template: Laravel" "$conf" 2>/dev/null; then
            template="laravel"
        elif grep -q "Template: Static" "$conf" 2>/dev/null; then
            template="static"
        fi

        local root_path
        root_path="$(grep -E '^\s*root\s+' "$conf" | head -n1 | awk '{print $2}' | tr -d ';' || echo "${WWW_ROOT}/${domain}/public")"

        local status_styled="${RED}${status}${NC}"
        if [[ "$status" == "active" ]]; then
            status_styled="${GREEN}${status}${NC}"
        fi

        local ssl_styled="${YELLOW}${ssl}${NC}"
        if [[ "$ssl" == "yes" ]]; then
            ssl_styled="${GREEN}${ssl}${NC}"
        fi

        printf "  %-24s %-19b %-17b %-12s %s\n" "${domain}" "${status_styled}" "${ssl_styled}" "${template}" "${root_path}"
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

    require_root

    if ! command_exists certbot; then
        die "'certbot' is required for automated SSL. Please install certbot and python3-certbot-nginx."
    fi

    section "Issuing Let's Encrypt SSL Certificate for ${domain}"
    log "Requesting certificate for ${domain} and www.${domain}..."

    if certbot --nginx --non-interactive --agree-tos --redirect -m "admin@${domain}" -d "${domain}" -d "www.${domain}"; then
        success "SSL certificate successfully installed and HTTPS redirect enabled!"
    else
        warn "Issuance with www.${domain} failed. Retrying with root domain only: ${domain}..."
        if certbot --nginx --non-interactive --agree-tos --redirect -m "admin@${domain}" -d "${domain}"; then
            success "SSL certificate successfully installed for ${domain}!"
        else
            die "Certbot failed to obtain SSL certificate. Ensure domain DNS records point to this VPS IP and port 80 is open."
        fi
    fi

    # Update .env APP_URL if exists
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
OpenShip Site & Nginx Manager CLI (v${CLI_VERSION})

Usage:
  site-cli <command> [arguments] [options]

Commands:
  create <domain> [options]    Create a new website, Nginx config, and MariaDB database
  delete <domain> [options]    Delete a website and optionally its database
  list                         List all configured websites and their status
  ssl <domain>                 Issue / install Let's Encrypt SSL certificate via Certbot
  db <domain> [create|dump|drop] Manage MariaDB database for a domain
  install-global               Install symlink to /usr/local/bin/site-cli
  version, -v                  Display CLI version
  help, -h                     Display this help message

Options for 'create':
  --template=<type>            Site template: opencart, wordpress, laravel, generic, static (default: generic)
  --php=<version>              PHP version (e.g. 8.3, 8.2) or auto-detect
  --with-db                    Create MariaDB database & user (default)
  --without-db                 Skip database creation
  --db-name=<name>             Custom database name (default: <domain>_db)
  --db-user=<user>             Custom database user (default: <domain>_usr)
  --ssl                        Issue Let's Encrypt SSL certificate via Certbot
  --dry-run                    Simulate creation without writing changes

Options for 'delete':
  --with-db                    Drop the associated MariaDB database and user
  --force, -f                  Do not prompt for confirmation

Directory structure created:
  /var/www/<domain>/
  ├── .env                     <- Database & app credentials (chmod 600)
  ├── credentials.txt          <- Detailed access summary (chmod 600)
  └── public/                  <- Web root served by Nginx
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
