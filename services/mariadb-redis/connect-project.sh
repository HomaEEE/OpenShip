#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER="${1:-}"
NET="${2:-}"

if [[ -z "$CONTAINER" ]]; then
    echo "Usage: sudo $0 <app_container_name> [docker_network]"
    exit 1
fi

if [[ -z "$NET" ]]; then
    NET="$(docker inspect openship-mariadb-mariadb --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null | head -n1 || true)"
    [[ -z "$NET" ]] && NET="openship-mariadb"
fi

if ! docker network inspect "$NET" >/dev/null 2>&1; then
    echo "Error: Docker network '$NET' not found." >&2
    exit 1
fi

if docker inspect "$CONTAINER" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null | grep -q "\"$NET\""; then
    echo "Container '$CONTAINER' is already connected to '$NET'."
else
    docker network connect "$NET" "$CONTAINER"
    echo "Connected '$CONTAINER' to '$NET' (mariadb:3306 & redis:6379 are now reachable)."
fi
