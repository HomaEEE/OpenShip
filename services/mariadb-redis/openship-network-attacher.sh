#!/usr/bin/env bash
# ==============================================================================
# OpenShip Network Attacher
# Automatically attaches newly created/started OpenShip containers
# to the shared 'openship' Docker network for automatic DNS resolution.
# ==============================================================================

set -Eeuo pipefail

NETWORK="${OPENSHIP_NETWORK:-openship-mariadb}"

# Wait until Docker daemon is ready
until docker info >/dev/null 2>&1; do
    sleep 2
done

# If OPENSHIP_NETWORK was not explicitly passed and default openship-mariadb does not exist,
# but 'openship' does, use 'openship'
if [[ -z "${OPENSHIP_NETWORK:-}" ]] && ! docker network inspect "$NETWORK" >/dev/null 2>&1 && docker network inspect "openship" >/dev/null 2>&1; then
    NETWORK="openship"
fi

# Wait until target network exists
until docker network inspect "$NETWORK" >/dev/null 2>&1; do
    sleep 2
done

echo "[openship-attacher] Started. Watching containers for network: ${NETWORK}"

attach_container() {
    local cid="$1"
    local cname="$2"

    [[ -z "$cid" || -z "$cname" ]] && return 0

    # Match containers with OpenShip naming convention (openship-* or openship_*)
    if [[ ! "$cname" =~ ^openship[-_] ]]; then
        return 0
    fi

    # Skip if already connected
    if docker inspect "$cid" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null | grep -q "\"${NETWORK}\""; then
        return 0
    fi

    echo "[openship-attacher] Connecting ${cname} (${cid:0:12}) to ${NETWORK}..."
    docker network connect "$NETWORK" "$cid" 2>/dev/null || true
}

# 1. Attach any existing OpenShip containers on service startup
for cid in $(docker ps -a -q --filter "name=openship-" 2>/dev/null || true); do
    cname="$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')"
    attach_container "$cid" "$cname"
done

# 2. Real-time event listener for container creation and start
# Catching 'create' attaches network BEFORE container starts so DNS is ready at boot
docker events --filter 'type=container' --filter 'event=create' --filter 'event=start' --format '{{.ID}} {{.Actor.Attributes.name}}' 2>/dev/null | while read -r cid cname; do
    attach_container "$cid" "$cname"
done

