# Руководство по пакету MariaDB + Redis + PMA на общем PHP 8.4 и деплою проектов без Dockerfile

Документ описывает архитектуру и эксплуатацию общего стека баз данных (`MariaDB + Redis + phpMyAdmin`), настроенного под единый образ PHP (`dunglas/frankenphp:1-php8.4-bookworm`), доступ по DNS-алиасам без открытия портов БД наружу, а также правила развёртывания и обновления PHP в проектах OpenShip.

---

## 1. Архитектура пакета `MariaDB + Redis + PMA`

Конфигурация описана в [`services/mariadb-redis/docker-compose.yml`](file:///Users/arthurboyko/Sites/OpenShip-deploy/services/mariadb-redis/docker-compose.yml) и [`openship.json`](file:///Users/arthurboyko/Sites/OpenShip-deploy/openship.json).

### 1.1. Состав сервисов и закрытый периметр

| Сервис | Образ | Алиас (DNS) | Внешние порты на хосте | Постоянный том (Volume) | Назначение |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`mariadb`** | `mariadb:11.4` | `mariadb:3306` | **Нет** (закрыт) | `mariadb_data:/var/lib/mysql` | Основная СУБД |
| **`redis`** | `redis:7.4-alpine` | `redis:6379` | **Нет** (закрыт) | `redis_data:/data` | Кэш, сессии, очереди |
| **`phpmyadmin`** | `dunglas/frankenphp:1-php${PHP_VERSION:-8.4}-bookworm` | `phpmyadmin:80` | **Нет** (только `:80` для Edge) | `pma_data:/app/public` | Веб-панель БД через HTTPS-домен |

- **Безопасность**: порты `3306` и `6379` не проброшены на хост (`ports:` отсутствует). Подключиться к базам можно только из контейнеров, находящихся в одной Docker-сети со стеком.
- **Сеть проекта**: OpenShip автоматически создаёт изолированную bridge-сеть при деплое стека (например, `openship-openship-deploy`). Никаких ручных сетей с `external: true` в `docker-compose.yml` не требуется.
- **Общий PHP-пакет для phpMyAdmin**: вместо отдельного тяжёлого Apache-образа `phpmyadmin` запускается на том же базовом образе `dunglas/frankenphp:1-php8.4-bookworm`, который OpenShip использует для всех PHP-проектов. При первом старте в том `pma_data` загружается дистрибутив phpMyAdmin и подключается расширение `mysqli`.

### 1.2. Публичный домен для phpMyAdmin

Чтобы в UI OpenShip появилось поле ввода домена для `phpmyadmin` (а БД-порты оставались закрыты):
1. В `docker-compose.yml` у сервиса `phpmyadmin` указан `ports: ["80"]` (без привязки внешнего порта хоста — OpenShip сканирует именно `ports:` для отображения переключателя **Public / Domain** в UI; при использовании `expose:` OpenShip помечает сервис как `Internal: No public ports detected`).
2. В панели OpenShip перейдите в проект инфраструктуры → **Services** → `phpmyadmin` → включите публичный доступ и введите домен (например, `pma.example.com`).
3. При необходимости укажите `PHPMYADMIN_DOMAIN` в переменных окружения (`pma.example.com`) для корректных HTTPS-редиректов (`PMA_ABSOLUTE_URI`).
4. OpenShip Edge (`openship-edge`) автоматически выпустит SSL-сертификат и будет проксировать HTTPS-трафик на `phpmyadmin:80`.

---

## 2. Безопасное обновление контейнеров без потери данных

Все данные лежат в именованных томах (`mariadb_data`, `redis_data`, `pma_data`). При пересборке или обновлении контейнеров тома не удаляются.

### 2.1. Резервная копия перед обновлением

Перед изменением версии `MARIADB_VERSION` или параметров запуска выполните дамп всех баз:

```bash
sudo ./services/mariadb-redis/backup.sh
```

Архивы сохраняются в `/var/backups/openship-services/mariadb_all_<TIMESTAMP>.sql.gz`. Для восстановления при необходимости используется `sudo ./services/mariadb-redis/restore.sh <путь_к_архиву>`.

### 2.2. Обновление MariaDB

- В **OpenShip UI**: внесите изменения в репозиторий (или смените `MARIADB_VERSION` в переменных) и нажмите **Redeploy**. Переменная `MARIADB_AUTO_UPGRADE=1` автоматически обновит системные таблицы при смене минорной/мажорной версии поверх тома `mariadb_data`.
- Через **CLI** на хосте:
  ```bash
  sudo ./deploy-services.sh --pull
  ```

---

## 3. Подключение проектов к `mariadb` и `redis` по алиасам

Чтобы любой развёрнутый проект общался с общей базой по DNS-именам `mariadb` и `redis`:

1. **Создайте БД и пользователя** (единожды для нового проекта):
   ```bash
   docker exec mariadb mariadb -u root -p"<MARIADB_ROOT_PASSWORD>" -e "
   CREATE DATABASE IF NOT EXISTS \`<db_name>\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
   CREATE USER IF NOT EXISTS '<db_user>'@'%' IDENTIFIED BY '<db_pass>';
   GRANT ALL PRIVILEGES ON \`<db_name>\`.* TO '<db_user>'@'%';
   FLUSH PRIVILEGES;
   "
   ```
2. **Укажите алиасы в переменных окружения проекта**:
   ```dotenv
   DB_CONNECTION=mariadb
   DB_HOST=mariadb
   DB_PORT=3306
   REDIS_HOST=redis
   REDIS_PORT=6379
   ```
3. **Свяжите проект с сетью БД в OpenShip**:
   - В OpenShip UI подключите сервис/проект к проекту БД (Connected Services) — OpenShip сам добавит контейнер проекта в сеть БД до старта приложения.
   - Либо, если проект деплоится автономно, подключите его контейнер к сети стека БД:
     ```bash
     docker network connect <имя_сети_стека_бд> <имя_контейнера_проекта>
     ```

---

## 4. Деплой проектов без Dockerfile на едином PHP 8.4 (`openship.json`)

Чтобы не писать `Dockerfile` и `docker-compose.yml` в каждом репозитории и переиспользовать один кэшированный образ PHP 8.4 на всём сервере, достаточно одного файла `openship.json` в корне проекта.

### 4.1. Как работает единый PHP-пакет в OpenShip (`runtimeVersion`)

При указании `"runtimeVersion": "8.4"` (или без него, если 8.4 — дефолт платформы) OpenShip автоматически использует стандартную пару образов:

| Назначение | Образ | Зачем нужен |
| :--- | :--- | :--- |
| **Builder (сборка)** | `php:8.4-cli-bookworm` | Временный контейнер этапа сборки: запускает `composer install --no-dev --optimize-autoloader` и проверяет `platform-reqs` (версию PHP и расширения из `composer.json`), чтобы не тащить кэш Composer и утилиты сборки в продакшн. |
| **Runtime (продакшн)** | `dunglas/frankenphp:1-php8.4-bookworm` | Единый общий рабочий образ с FrankenPHP (Caddy + встроенный PHP 8.4). Переиспользуется между всеми проектами и сервисом `phpmyadmin`. |

> [!TIP]
> **Если вы хотите вообще не собирать зависимости на сервере**: закоммитьте собранные `vendor/` (и `public/build/`) в артефакт деплоя или соберите их заранее в CI, а этап Build в OpenShip отключите. Тогда временный `php:8.4-cli-bookworm` вообще не запускается, и все проекты сразу стартуют на одном общем `dunglas/frankenphp:1-php8.4-bookworm`.

### 4.2. Эталонный `openship.json` для Laravel-проекта

```json
{
  "$schema": "https://openship.io/openship.schema.json",
  "framework": "laravel",
  "runtimeVersion": "8.4",
  "optimize": true,
  "installCommand": "composer install --no-dev --optimize-autoloader",
  "buildCommand": "npm ci && npm run build",
  "releaseCommands": [
    "php artisan migrate --force"
  ],
  "startCommand": "SERVER_NAME=\":$PORT\" exec frankenphp run --config /etc/frankenphp/Caddyfile --adapter caddyfile",
  "port": 80,
  "volumes": ["storage"],
  "domains": ["app.example.com"],
  "roles": [
    {
      "name": "queue",
      "kind": "worker",
      "command": "exec php artisan queue:work --sleep=3 --tries=3",
      "replicas": 1,
      "stopGracePeriod": "90s"
    },
    {
      "name": "scheduler",
      "kind": "scheduler",
      "command": "exec php artisan schedule:work",
      "stopGracePeriod": "10s",
      "singleton": true
    }
  ],
  "env": {
    "APP_ENV": "production",
    "APP_DEBUG": "false",
    "DB_CONNECTION": "mariadb",
    "DB_HOST": "mariadb",
    "DB_PORT": "3306",
    "REDIS_CLIENT": "phpredis",
    "REDIS_HOST": "redis",
    "REDIS_PORT": "6379",
    "CACHE_STORE": "redis",
    "SESSION_DRIVER": "redis",
    "QUEUE_CONNECTION": "redis"
  }
}
```

### 4.3. Ключевые правила `openship.json`

1. **`"optimize": true`** вместо вызова `php artisan optimize` в `buildCommand` или `releaseCommands`:
   - `config:cache` замораживает переменные окружения (`env()`). При запуске через `"optimize": true` прогрев происходит **при старте контейнера**, когда OpenShip уже передал реальные секреты (`DB_PASSWORD`, `APP_KEY`, `REDIS_PASSWORD`).
2. **`"releaseCommands": ["php artisan migrate --force"]`**:
   - Выполняется один раз перед переключением трафика во временном контейнере с доступом к сети БД. Если миграция падает с ошибкой, деплой останавливается, а старая версия сайта продолжает обслуживать пользователей.
3. **`"roles"` для воркеров и крона**:
   - Используют **тот же самый образ**, те же переменные окружения (без `PORT`) и тот же том `storage`, подключаясь к сети БД до запуска процесса.
   - Обязательно используйте `exec` перед командой (`exec php artisan queue:work`), чтобы сигнал остановки `SIGTERM` доходил до PHP-процесса при обновлении.

---

## 5. Как обновлять проекты при смене версии PHP (8.5+)

### 5.1. Обновление прикладных проектов (`openship.json`)

1. **Если `runtimeVersion` НЕ указан в `openship.json` (опущен)**:
   - Проект использует управляемый дефолт OpenShip. Как только OpenShip обновит версию PHP по умолчанию, обычный **Redeploy** переведёт проект на новую версию автоматически.
2. **Если `runtimeVersion` зафиксирован явно (`"8.4"`)**:
   - Когда выйдет поддержка PHP 8.5 в OpenShip, обновите значение в `openship.json`:
     ```json
     "runtimeVersion": "8.5"
     ```
     (или переключите версию в UI проекта: **Build settings → Runtime version**).
   - Сделайте `git push` или нажмите **Redeploy**.
3. **Гарантия безопасности и отката**:
   - На этапе сборки OpenShip запускает `composer check-platform-reqs` в реальном образе новой версии PHP. Если код или пакеты в `composer.json` не поддерживают PHP 8.5, сборка упадёт **до активации**, а рабочий контейнер на PHP 8.4 продолжит работу без простоя.
   - При необходимости отката OpenShip хранит снимок образа предыдущего релиза — **Rollback** мгновенно вернёт проект на PHP 8.4 без потери данных в `storage/` и MariaDB.

### 5.2. Обновление PHP для `phpMyAdmin`

Версия PHP для `phpmyadmin` вынесена в переменную `PHP_VERSION` (по умолчанию `8.4`). Для перехода на `8.5` достаточно:
1. Изменить `PHP_VERSION=8.5` в переменных проекта `OpenShip-deploy` в OpenShip UI (или в `.env`).
2. Нажать **Redeploy** (или выполнить `sudo ./deploy-services.sh --pull` при локальном запуске).
3. Тома `mariadb_data`, `redis_data` и `pma_data` при этом полностью сохраняются.
