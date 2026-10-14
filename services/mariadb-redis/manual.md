# Руководство по инфраструктуре OpenShip: MariaDB, Redis, PMA и деплой проектов (Noire / Hookah-CRM)

Документ фиксирует рабочую конфигурацию серверов, контейнеров и сетей на сервере **<SERVER_IP>**, учётные данные, сетевую модель OpenShip и пошаговую инструкцию для построения автоматизированного CI/CD пайплайна подключения новых проектов к MariaDB и Redis.

---

## 1. Сведения о сервере и панели управления

- **Хост сервера**: `<SERVER_IP>`
- **ID сервера в OpenShip**: `<SERVER_ID>` (`Pool 1`)
- **Панель управления**: OpenShip (`https://os.example.com`)
- **Организация / Workspace**: `<WORKSPACE_ID>`
- **Edge Proxy**: `openship-edge` (OpenResty 1.27.1, порты 80/443 на host-интерфейсе, SSL через Cloudflare / Let's Encrypt).
- **Конфигурация vhosts**: `/var/lib/openship/edge/sites-enabled/`

---

## 2. Учётные данные и сервисы инфраструктуры

Проект инфраструктуры в OpenShip: **`OpenShip-deploy`** (`<PROJECT_ID>`)  
Исходный код: `HomaEEE/OpenShip-deploy` (ветка `main`, путь `services/mariadb-redis/docker-compose.yml`)

### 2.1. MariaDB 11.4 LTS

- **Имя контейнера**: `openship-openship-deploy-mariadb`
- **Основная сеть**: `openship-openship-deploy` (подсеть `172.18.0.0/16`, IP: `172.18.0.2`)
- **Внутренний порт**: `3306`
- **Сетевой алиас (DNS)**: `mariadb`
- **Том (Volume)**: `mariadb_data:/var/lib/mysql`
- **Root пользователь**: `root`
- **Root пароль**: `<MARIADB_ROOT_PASSWORD>`
- **Параметры запуска**:
  ```text
  --default-storage-engine=InnoDB
  --innodb-buffer-pool-size=192M
  --innodb-buffer-pool-instances=1
  --innodb-flush-log-at-trx-commit=2
  --innodb-flush-method=O_DIRECT
  --innodb-io-capacity=2000
  --innodb-io-capacity-max=4000
  --performance-schema=OFF
  --skip-name-resolve=1
  --max-connections=30
  --max-connect-errors=10000
  --thread-cache-size=16
  --wait-timeout=600
  --interactive-timeout=600
  ```

#### База данных проекта Noire:

- **Имя БД**: `noire`
- **Пользователь**: `noire`
- **Пароль**: `<NOIRE_DB_PASSWORD>`
- **Привилегии**: `ALL PRIVILEGES ON \`noire\`.\* TO 'noire'@'%'`

### 2.2. Redis 7.4-alpine

- **Имя контейнера**: `openship-openship-deploy-redis`
- **Основная сеть**: `openship-openship-deploy` (подсеть `172.18.0.0/16`, IP: `172.18.0.3`)
- **Внутренний порт**: `6379`
- **Сетевой алиас (DNS)**: `redis`
- **Том (Volume)**: `redis_data:/data`
- **Пароль аутентификации**: `<REDIS_PASSWORD>`
- **Параметры запуска**:
  ```text
  redis-server --requirepass <REDIS_PASSWORD> --maxmemory 48mb --maxmemory-policy allkeys-lru
  ```

### 2.3. phpMyAdmin (PMA)

- **Имя контейнера**: `openship-openship-deploy-phpmyadmin`
- **Локальный порт проксирования**: `127.0.0.1:20003` -> контейнер `:80`
- **Публичный домен**: **`https://pma.example.com`**
- **Статус**: `HTTP 200 OK`, форма входа активна.
- **Подключение к MariaDB**: автоматически направлено на хост `mariadb:3306`.
- **Вход**: пользователь `root` (пароль `<MARIADB_ROOT_PASSWORD>`) или `noire` (пароль `<NOIRE_DB_PASSWORD>`).

---

## 3. Развёрнутый проект: Noire (Hookah-CRM)

Проект в OpenShip: **`Noire`** (`<PROJECT_ID>`)  
Исходный код: `HomaEEE/Hookah-CRM` (ветка `v4`, путь `deploy/docker-compose.yml`)

- **Имя контейнера**: `openship-noire-web`
- **Локальный порт**: `127.0.0.1:20000` -> контейнер `:80`
- **Публичный домен**: **`https://noire-test.example.com`**
- **Стек runtime**: **FrankenPHP 1.x (PHP 8.4.26) + Caddy + Laravel 12 + Livewire + Filament 5**
- **Статус**: `HTTP 200 OK`, главная страница отдается со сжатием и кэшем.
- **Сессии и кэш**: активны в Redis (ключи с префиксами `noire_database_noire_cache_*`).
- **СУБД**: подключена к `mariadb:3306` (76 таблиц, все миграции применены).

---

## 4. Сетевая модель OpenShip и межпроектное взаимодействие

### 4.1. Особенность OpenShip

OpenShip для каждого создаваемого проекта автоматически генерирует изолированную Docker-сеть bridge:

- Проект инфраструктуры: сеть `openship-openship-deploy` (172.18.0.0/16).
- Проект Noire: сеть `openship-noire` (172.19.0.0/16).
- Любой будущий проект: сеть `openship-<project_slug>` (172.20.0.0/16 и т.д.).

### 4.2. Как контейнеры получают доступ к `mariadb` и `redis`

В Docker контейнер может быть одновременно подключен к двум и более сетям:

1. Контейнер проекта создаётся в своей сети проекта (для связи со своим edge-роутером).
2. Контейнер подключается к сети СУБД командой:
   ```bash
   docker network connect openship-openship-deploy <container_name>
   ```
3. После подключения к сети `openship-openship-deploy` внутренний Docker DNS начинает мгновенно разрешать имена `mariadb` и `redis` для этого контейнера!

---

## 5. Точные команды, выполненные при деплое

### Шаг 1. Создание и деплой инфраструктуры MariaDB + Redis + PMA

```bash
# Через OpenShip MCP / API:
# 1. post_projects
#    name: "OpenShip-deploy", slug: "openship-deploy", serverId: "<SERVER_ID>"
#    gitOwner: "HomaEEE", gitRepo: "OpenShip-deploy", gitBranch: "main"
#    composePath: "services/mariadb-redis/docker-compose.yml"
#
# 2. post_deployments_build_access (передача паролей)
#    MARIADB_ROOT_PASSWORD: "<MARIADB_ROOT_PASSWORD>"
#    REDIS_PASSWORD: "<REDIS_PASSWORD>"
#    ENABLE_PHPMYADMIN: "true"

# 3. Маршрутизация PMA на домен pma.example.com
#    post_domains: hostname: "pma.example.com", isPrimary: true, externalIngress: true
#    patch_projects_by_id_services_by_serviceId (<SERVICE_ID>): customDomain: "pma.example.com", exposed: true, exposedPort: "80"
#    patch_projects_by_id: port: 20003, routeStrategy: "loopback-port"
#    post_projects_by_id_routing_retry
```

### Шаг 2. Создание базы данных и пользователя под Noire

```bash
docker exec openship-openship-deploy-mariadb mariadb -u root -p<MARIADB_ROOT_PASSWORD> -e "
CREATE DATABASE IF NOT EXISTS \`noire\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'noire'@'%' IDENTIFIED BY '<NOIRE_DB_PASSWORD>';
ALTER USER 'noire'@'%' IDENTIFIED BY '<NOIRE_DB_PASSWORD>';
GRANT ALL PRIVILEGES ON \`noire\`.* TO 'noire'@'%';
FLUSH PRIVILEGES;
"
```

### Шаг 3. Деплой проекта Noire в OpenShip

```bash
# 1. post_projects
#    name: "Noire", slug: "noire", serverId: "<SERVER_ID>"
#    gitOwner: "HomaEEE", gitRepo: "Hookah-CRM", gitBranch: "v4"
#    composePath: "deploy/docker-compose.yml", port: 80

# 2. post_deployments_build_access
#    Передача переменных окружения (APP_KEY, DB_HOST=mariadb, DB_DATABASE=noire, DB_USERNAME=noire, DB_PASSWORD, REDIS_HOST=redis, REDIS_PASSWORD...)
#    Маршрутизация noire-test.example.com -> порт 80
```

### Шаг 4. Подключение контейнера Noire к сети MariaDB/Redis

```bash
docker network connect openship-deploy openship-noire-web
docker restart openship-noire-web
```

---

## 6. Универсальный пайплайн для автоматизации деплоя других проектов

Для подключения любого нового проекта к MariaDB и Redis достаточно автоматизировать 2 действия после сборки контейнера в OpenShip:

1. Создать БД и пользователя в MariaDB.
2. Подключить контейнер проекта к сети `openship-openship-deploy`.

### 6.1. Скрипт автоматического подключения (`openship-link-infra.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

PROJECT_SLUG="$1"              # например: newapp
DB_NAME="${2:-$PROJECT_SLUG}"  # имя БД
DB_USER="${3:-$PROJECT_SLUG}"  # имя пользователя
DB_PASS="$4"                   # пароль пользователя

INFRA_NET="openship-deploy"
MARIADB_CONTAINER="openship-openship-deploy-mariadb"
ROOT_PASS="<MARIADB_ROOT_PASSWORD>"

# 1. Создание БД и пользователя в MariaDB
echo "==> Provisioning database '${DB_NAME}' in MariaDB..."
docker exec "$MARIADB_CONTAINER" mariadb -u root -p"$ROOT_PASS" -e "
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
"
echo "==> Database '${DB_NAME}' provisioned."

# 2. Поиск контейнера проекта и подключение к общей сети
TARGET_CONTAINER="$(docker ps --filter "name=openship-${PROJECT_SLUG}" --format '{{.Names}}' | head -n 1)"

if [[ -z "$TARGET_CONTAINER" ]]; then
    echo "==> ERROR: Container for project '${PROJECT_SLUG}' not found."
    exit 1
fi

echo "==> Connecting '${TARGET_CONTAINER}' to '${INFRA_NET}'..."
if ! docker inspect "$TARGET_CONTAINER" --format '{{json .NetworkSettings.Networks}}' | grep -q "$INFRA_NET"; then
    docker network connect "$INFRA_NET" "$TARGET_CONTAINER"
    docker restart "$TARGET_CONTAINER"
    echo "==> Successfully connected '${TARGET_CONTAINER}' to '${INFRA_NET}'."
else
    echo "==> '${TARGET_CONTAINER}' is already connected to '${INFRA_NET}'."
fi
```

---

## 7. Новые возможности OpenShip (версии 0.9.0 – 0.9.1)

### 7.1. Встроенный CI/CD движок: OpenShip Actions (0.9.0+)

- **Локальный GitHub Actions Runner**: исполнение пайплайнов `.github/workflows/*.yml` или `.openship/workflows/*.yml` непосредственно на своих серверах (Linux/macOS) или Cloud-раннерах.
- **GitHub Deployment Checks**: автоматическая передача статусов сборки и деплоя обратно в GitHub (коммиты, Pull Requests) через GitHub App / Checks API.
- **Reusable Workflows (Переиспользуемые воркфлоу)**: поддержка локальных и удаленных вызовов (`uses:`), типизированных входных параметров, передачи секретов, матричных сборок (`matrix`) и выражений.
- **Визуальный редактор воркфлоу**: граф топологии задач, редактирование шагов по месту, синхронизация с Git.
- **OIDC токены и артефакты**: генерация короткоживущих OIDC-токенов для авторизации без постоянных секретов, кеширование зависимостей между запусками.

### 7.2. Управление средами исполнения и деплоем (0.9.1)

- **Нативная поддержка PHP 8.3 и 8.4**: параметр `runtimeVersion: "8.4"` для автоматической сборки PHP без ручного написания Dockerfile.
- **Кастомные образы (`runtimeImage`)**: возможность переопределить базовый runtime-образ для production-контейнеров.
- **Изолированный перезапуск (Selective Redeploy)**: при перезапуске compose-стеков OpenShip 0.9.1 обновляет только те сервисы, чьи образы или конфигурация изменились. Внешние сервисы (базы данных, Redis) остаются активными без обрыва сессий.
- **Path-based Routing**: OpenResty сохраняет точечные префиксные маршруты (`/api`, `/admin`) без необходимости наличия глобального catch-all хоста.
- **Каталог приложений (App Catalog)** и русская локализация панели управления.

---

## 8. Варианты деплоя Laravel-проектов в OpenShip

### 8.1. Способ 1: Готовый контейнер FrankenPHP (Рекомендуемый / Noire Stack)

Максимальная производительность (Worker mode), HTTP/3, автоматический HTTPS и низкое потребление RAM.

- **Конфигурация `deploy/docker-compose.yml`**:

  ```yaml
  services:
    web:
      build:
        context: ..
        dockerfile: deploy/Dockerfile
      restart: unless-stopped
      environment:
        APP_ENV: production
        APP_DEBUG: "false"
        APP_KEY: ${APP_KEY}
        DB_CONNECTION: mysql
        DB_HOST: mariadb
        DB_PORT: 3306
        DB_DATABASE: ${DB_DATABASE}
        DB_USERNAME: ${DB_USERNAME}
        DB_PASSWORD: ${DB_PASSWORD}
        CACHE_STORE: redis
        SESSION_DRIVER: redis
        QUEUE_CONNECTION: redis
        REDIS_HOST: redis
        REDIS_PASSWORD: ${REDIS_PASSWORD}
        REDIS_PORT: 6379
        FRANKENPHP_CONFIG: "worker ./public/index.php"
      networks:
        - default
        - infra_net

  networks:
    default:
    infra_net:
      external: true
      name: openship-openship-deploy
  ```

- **Преимущество**: Декларативное подключение к внешней сети `openship-openship-deploy` прямо в Compose-файле устраняет необходимость ручного вызова `docker network connect`.

### 8.2. Способ 2: Нативный сборщик OpenShip (Buildpacks / Runtime)

В конфигурации проекта (`openship.json` или через UI панели OpenShip):

```json
{
  "runtime": "php",
  "runtimeVersion": "8.4",
  "buildCommand": "composer install --no-dev --optimize-autoloader && php artisan config:cache && php artisan route:cache && php artisan view:cache",
  "runCommand": "php artisan serve --host=0.0.0.0 --port=80",
  "env": {
    "APP_ENV": "production",
    "DB_HOST": "mariadb"
  }
}
```

### 8.3. Способ 3: Раздельные воркеры (Web + Queue + Cron)

Для высоконагруженных Laravel-проектов в одном Compose-проекте OpenShip:

```yaml
services:
  web:
    build: .
    ports: ["80"]
  queue:
    build: .
    command: php artisan horizon # или: php artisan queue:work --sleep=3 --tries=3
    restart: unless-stopped
  scheduler:
    build: .
    command: php artisan schedule:work
    restart: unless-stopped
```

---

## 9. Модульная система GitHub и частичные обновления

Возможно ли использовать модульную архитектуру и выполнять частичные обновления? **Да, через 3 взаимодополняющих механизма**:

### 9.1. Механизм 1: Фильтрация по путям в GitHub / OpenShip Actions (`paths`)

Если проект организован как монорепозиторий или модульный монолит (например, `nWidart/laravel-modules` или отдельные директории фронтенда/воркеров):

```yaml
# .github/workflows/deploy-module.yml
name: Deploy Billing Module
on:
  push:
    branches: [main]
    paths:
      - "Modules/Billing/**"
      - "config/billing.php"

jobs:
  test-and-deploy:
    runs-on: self-hosted # Запуск на раннере OpenShip
    steps:
      - uses: actions/checkout@v4
      - name: Run Module Tests
        run: php artisan module:test Billing
      - name: Trigger Partial Module Migration
        run: |
          docker exec openship-noire-web php artisan module:migrate Billing --force
          docker exec openship-noire-web php artisan module:publish-translation Billing
```

- **Результат**: Изменения в одном модуле не запускают полную пересборку монолита; выполняются только изолированные миграции и тесты модуля.

### 9.2. Механизм 2: Переиспользуемые воркфлоу (Reusable Workflows)

Для распределённых репозиториев (когда модули живут в отдельных Git-репозиториях `org/crm-billing`, `org/crm-auth`):

```yaml
# В репозитории модуля: .github/workflows/release.yml
name: Release Module
on:
  push:
    tags: ["v*"]

jobs:
  call-deploy:
    uses: HomaEEE/OpenShip-deploy/.github/workflows/reusable-module-deploy.yml@main
    with:
      module_name: "Billing"
      target_project: "noire"
    secrets: inherit
```

OpenShip Actions (0.9.0+) полноценно валидирует и исполняет Reusable Workflows со сквозной передачей секретов.

### 9.3. Механизм 3: Git Submodules (Субмодули)

При использовании `git submodule`:

1. **Особенность OpenShip**: базовый агент деплоя делает стандартный `git clone`. Для подгрузки субмодулей сборка в Dockerfile должна содержать:
   ```dockerfile
   # В Dockerfile при сборке:
   ARG GITHUB_TOKEN
   RUN git submodule update --init --recursive
   ```
   Или субмодули монтируются как общие тома (`volumes`), если код интерпретируется на лету.
2. **Частичный деплой**: Обновление ссылки на коммит субмодуля в родительском репо (`git add Modules/Billing && git commit`) фиксирует точный SHA версии модуля.

### 9.4. Механизм 4: Selective Container Recreation (OpenShip 0.9.1)

В Compose-проектах OpenShip 0.9.1 отслеживает хеши неизменных образов и сервисов:

- Если изменен только код `web`-сервиса или отдельного микросервиса, пересобирается и заменяется **только его контейнер**.
- Сервисы очередей, кеша и баз данных остаются нетронутыми, исключая простой всей системы.

---

## 10. Регламент деплоя нового модуля в существующий проект (Шпаргалка)

1. **Коммит изменений модуля** с тегом или пушем в ветку `main`.
2. **Автоматический триггер OpenShip Actions** по маске путей (`paths`).
3. **Применение миграций конкретного модуля**:
   ```bash
   docker exec openship-<slug>-web php artisan module:migrate <ModuleName> --force
   ```
4. **Сброс кеша маршрутов и конфигурации**:
   ```bash
   docker exec openship-<slug>-web php artisan optimize:clear
   docker exec openship-<slug>-web php artisan optimize
   ```
5. **Worker Reload (при использовании FrankenPHP / Octane)**:
   ```bash
   # Мягкий перезапуск воркеров без перезапуска самого контейнера:
   docker exec openship-<slug>-web php artisan octane:reload
   ```
