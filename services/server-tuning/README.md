# OpenShip Worker VPS Tuning

Скрипт оптимизации Ubuntu 24.04 / 22.04 LTS под высокие нагрузки, OpenShip Edge и FrankenPHP (низкий TTFB, HTTP/3, тюнинг сокетов и памяти).

> **Примечание:** Установка Docker намеренно не выполняется — скрипт готовит ОС, ядро, сеть, лимиты и фаервол.

---

## Быстрый запуск

### В 1 команду (удаленный сервер):
```bash
curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/services/server-tuning/tune.sh | sudo bash
```

### Из локального репозитория:
```bash
sudo ./services/server-tuning/tune.sh
```

### Неинтерактивно / Проверка:
```bash
sudo ./services/server-tuning/tune.sh --non-interactive
./services/server-tuning/tune.sh --dry-run
```

---

## Что настраивает скрипт

1. **Docker Runtime & Контейнеры**:
   - `userland-proxy: false` — отключен `docker-proxy`, прямое iptables-проксирование (экономия RAM на порт).
   - `storage-driver: overlay2`, `cgroupdriver=systemd`, `live-restore: true`.
   - Лимит логов контейнеров: `5m` (максимум 2 файла).
   - Еженедельный таймер очистки `docker-prune.timer` (удаление dangling образов и кеша билдера без сброса volumes).
   - Разрешен bridge forwarding в UFW (`DEFAULT_FORWARD_POLICY="ACCEPT"`), модули `br_netfilter` и `overlay`.
2. **FrankenPHP & Низкий TTFB (`/etc/sysctl.d/99-openship-worker.conf`)**:
   - `tcp_fastopen = 3` (минус 1 RTT на хэндшейк), `tcp_slow_start_after_idle = 0` (нет троттлинга keep-alive).
   - TCP BBR (`default_qdisc = fq`, `tcp_congestion_control = bbr`).
   - Быстрый оборот портов: `tcp_tw_reuse = 1`, `tcp_fin_timeout = 15`, диапазон портов `1024 65535`.
   - Динамические сокет-буферы (4MB при RAM < 2GB, 16MB при RAM ≥ 2GB) + UDP буферы под HTTP/3 QUIC.
   - Сброс грязных страниц: `vm.dirty_ratio = 10..15`, `vm.dirty_background_ratio = 3..5`.
   - Тюнинг Conntrack NAT контейнеров: `nf_conntrack_max = 262144`, таймаут `established = 600s`.
   - ARP таблица: пороги `1024 / 2048 / 4096` для множества `veth` интерфейсов.
   - Память под MariaDB и Redis: `vm.overcommit_memory = 1`, `vm.max_map_count = 262144`, `min_free_kbytes`.
3. **Transparent HugePages & Диск**:
   - THP = `never` (персистентно через systemd) — нет скачков latency и фрагментации RAM в базах данных.
   - `noatime` в `/etc/fstab` (устранение лишних записей при чтении файлов) + I/O scheduler `none mq-deadline` для NVMe/SSD.
4. **CPU Governor**:
   - Перевод процессора в режим `performance` (устранение задержек масштабирования частоты, персистентно через systemd).
5. **Лимиты и очистка памяти**:
   - `nofile 65535` и `nproc 65535` для root и всех пользователей (`/etc/security/limits.d/99-openship-worker.conf`).
   - Отключение фоновых сервисов (`cloud-init`, `snapd`, `multipathd` и др. — освобождает 100-150MB RAM).
   - Перенос `apt-daily` таймеров на ночь (03:30). Ограничение journald (50MB при < 2GB RAM).
6. **Swap (Гибридный zRAM + Swapfile)**:
   - zRAM (lz4, 50% RAM, priority 100) — сжатие в оперативной памяти.
   - Дисковый swapfile (priority 10) как резервный буфер при сильных пиках.
7. **Безопасность (UFW & Fail2ban)**:
   - Открыты порты: SSH (дефолт 22), `80/tcp` (HTTP), `443/tcp` и `443/udp` (HTTP/3 QUIC).
8. **Проверка и удаление Apache**:
   - Автоматический поиск и очистка `apache2` пакетов и конфигураций, предотвращающий конфликты за порты 80 и 443.
9. **Интерактивный выбор программного стека**:
   - `1) Нативный LEMP (Nginx + MariaDB + Redis + PHP-FPM + site-cli)`: Полноценный производительный стек с Nginx (Brotli, headers-more), MariaDB 11, Redis, PHP-FPM с расширениями для CMS (OpenCart, WordPress, Laravel) и утилитой `site-cli`.
   - `2) Раздельный выбор пакетов`: Гранулярная установка отдельных пакетов (номерами `1,2,4,6` или пошагово [Y/n]):
     - `[1] Nginx` (веб-сервер + Brotli + HTTP/3 + тюнинг)
     - `[2] MariaDB` (сервер и клиент БД)
     - `[3] Redis` (in-memory кэш)
     - `[4] PHP-FPM` (PHP 8.x + CMS модули)
     - `[5] Docker` (Docker Engine + Compose v2)
     - `[6] site-cli` (CLI-утилита `/usr/local/bin/site-cli`)
   - `3) Docker стек (Docker Engine + Docker Compose v2)`: Только Docker-окружение для контейнеров.
   - `4) Пропустить установку ПО`: Только системный тюнинг VPS без пакетов стека.

---

## Параметры запуска

| Флаг | Описание |
|---|---|
| `--non-interactive` | Применить настройки без диалоговых окон (из `.env` или дефолты) |
| `--dry-run` | Проверить совместимость и параметры без изменения системы |
| `--purge-apache` | Автоматически остановить и удалить Apache (apache2) при обнаружении |
| `--stack=CHOICE` | Выбор стека: `lemp`/`native`, `custom`, `docker`, `none` |
| `--install-stack` | Алиас для `--stack=lemp` (Nginx, MariaDB, Redis, PHP-FPM, site-cli) |
| `--skip-stack` | Алиас для `--stack=none` (пропустить установку стека) |
| `--with-nginx / --without-nginx` | Установить / пропустить Nginx |
| `--with-mariadb / --without-mariadb` | Установить / пропустить MariaDB |
| `--with-redis / --without-redis` | Установить / пропустить Redis |
| `--with-php / --without-php` | Установить / пропустить PHP-FPM |
| `--with-docker / --without-docker` | Установить / пропустить Docker & Compose |
| `--with-site-cli / --without-site-cli` | Установить / пропустить site-cli |
| `--ssh-port=PORT` | Указать кастомный SSH-порт (дефолт `22`) |
| `--swap-size=GB` | Указать размер swapfile в гигабайтах |
| `--admin-user=USER` | Создать отдельного sudo-администратора |
| `--skip-packages` | Пропустить `apt update / upgrade` |
| `--skip-swap` | Пропустить настройку swap |
| `--skip-sysctl` | Пропустить тюнинг ядра и sysctl |
| `--skip-ufw` | Пропустить настройку фаервола UFW |
| `--skip-ssh` | Пропустить перенастройку SSH |
| `--help` | Справка |

