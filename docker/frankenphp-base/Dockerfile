FROM dunglas/frankenphp:1-php8.4-bookworm

LABEL org.opencontainers.image.source="https://github.com/HomaEEE/OpenShip-deploy"
LABEL org.opencontainers.image.description="Prebuilt FrankenPHP 8.4 + Composer 2 + Node.js 22 + Laravel PHP extensions base image for OpenShip"

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    unzip \
    mariadb-client \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN install-php-extensions \
    bcmath \
    exif \
    gd \
    intl \
    opcache \
    pcntl \
    pdo_mysql \
    redis \
    zip

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
COPY --from=node:22-bookworm-slim /usr/local/bin/node /usr/local/bin/node
COPY --from=node:22-bookworm-slim /usr/local/lib/node_modules /usr/local/lib/node_modules

RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

RUN { \
      echo "opcache.enable=1"; \
      echo "opcache.validate_timestamps=0"; \
      echo "opcache.memory_consumption=128"; \
      echo "opcache.interned_strings_buffer=16"; \
      echo "opcache.max_accelerated_files=20000"; \
      echo "memory_limit=256M"; \
      echo "upload_max_filesize=64M"; \
      echo "post_max_size=64M"; \
    } > /usr/local/etc/php/conf.d/99-openship.ini

WORKDIR /app
