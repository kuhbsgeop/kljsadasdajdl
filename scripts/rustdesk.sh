#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

RUSTDESK_IMAGE="${RUSTDESK_IMAGE:-rustdesk/rustdesk-server:1.1.15}"
RUSTDESK_DATA_DIR="${RUSTDESK_DATA_DIR:-/opt/rustdesk-server/data}"
RUSTDESK_SERVER="${RUSTDESK_SERVER:-${SERVER_ADDR:-}}"

log() { printf '[rustdesk] %s\n' "$*"; }
die() { printf '[rustdesk] ERROR: %s\n' "$*" >&2; exit 1; }

need_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "Run with sudo/root."
}

public_server() {
  if [ -n "$RUSTDESK_SERVER" ] && [ "$RUSTDESK_SERVER" != "your-server" ]; then
    printf '%s' "$RUSTDESK_SERVER"
    return
  fi
  curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'
}

remove_legacy_container() {
  local name="$1" service="$2" compose_service
  docker inspect "$name" >/dev/null 2>&1 || return 0
  compose_service="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$name" 2>/dev/null || true)"
  [ "$compose_service" = "$service" ] && return 0
  log "Adopting existing ${name} container; persistent data remains in ${RUSTDESK_DATA_DIR}."
  docker rm -f "$name" >/dev/null
}

open_firewall() {
  if [ -x ./scripts/open-ports.sh ]; then
    ./scripts/open-ports.sh 21115/tcp 21116/both 21117/tcp 21118/tcp 21119/tcp
  else
    log "Open TCP 21115-21119 and UDP 21116 in the host and cloud firewalls."
  fi
}

write_config() {
  local server key
  server="$(public_server)"
  key="$(cat "${RUSTDESK_DATA_DIR}/id_ed25519.pub" 2>/dev/null || true)"
  mkdir -p runtime
  chmod 700 runtime
  cat > runtime/rustdesk-server.txt <<EOF
RustDesk Server OSS client configuration

ID Server:    ${server}
Relay Server: ${server}
API Server:   (leave blank; OSS has no account API)
Key:          ${key}

Explicit ports if needed:
ID Server:    ${server}:21116
Relay Server: ${server}:21117

Data:         ${RUSTDESK_DATA_DIR}
Image:        ${RUSTDESK_IMAGE}
EOF
  chmod 600 runtime/rustdesk-server.txt
  cat runtime/rustdesk-server.txt
}

install_server() {
  need_root
  command -v docker >/dev/null 2>&1 || die "Docker is required. Run install.sh first."
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is required."
  mkdir -p "$RUSTDESK_DATA_DIR"
  chmod 700 "$RUSTDESK_DATA_DIR"
  remove_legacy_container hbbs hbbs
  remove_legacy_container hbbr hbbr
  open_firewall
  docker compose --profile rustdesk pull hbbs hbbr
  docker compose --profile rustdesk up -d hbbs hbbr

  local i
  for i in $(seq 1 30); do
    if [ -s "${RUSTDESK_DATA_DIR}/id_ed25519.pub" ] \
      && [ "$(docker inspect -f '{{.State.Running}}' hbbs 2>/dev/null || true)" = "true" ] \
      && [ "$(docker inspect -f '{{.State.Running}}' hbbr 2>/dev/null || true)" = "true" ]; then
      write_config
      log "Ready. Also open these ports in the VPS provider security group: TCP 21115-21119, UDP 21116."
      return 0
    fi
    sleep 1
  done
  docker compose --profile rustdesk logs --tail=80 hbbs hbbr || true
  die "RustDesk did not become ready."
}

status_server() {
  docker compose --profile rustdesk ps hbbs hbbr
  echo
  write_config
  echo
  if command -v ss >/dev/null 2>&1; then
    ss -lntup | grep -E '2111[5-9]' || true
  fi
}

case "${1:-install}" in
  install|start) install_server ;;
  status|config) status_server ;;
  restart) need_root; docker compose --profile rustdesk restart hbbs hbbr; status_server ;;
  logs) docker compose --profile rustdesk logs -f --tail=200 hbbs hbbr ;;
  stop) need_root; docker compose --profile rustdesk stop hbbs hbbr ;;
  uninstall)
    need_root
    docker compose --profile rustdesk rm -sf hbbs hbbr
    log "Containers removed. Keys/database retained in ${RUSTDESK_DATA_DIR}."
    ;;
  purge)
    die "Refusing to delete keys automatically. Remove ${RUSTDESK_DATA_DIR} manually only after backup."
    ;;
  *) die "Usage: $0 {install|status|config|restart|logs|stop|uninstall}" ;;
esac
