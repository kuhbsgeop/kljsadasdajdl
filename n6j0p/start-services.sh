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

# Run a compose up, falling back to starting the existing containers when
# compose cannot create them (e.g. after a reboot Docker's restart policy
# already brought the containers up, so compose up fails with a name
# conflict). Without this fallback the systemd unit reports failed even
# though every service is running.
compose_up_or_start() {
  local containers="$1"
  shift
  if "$@"; then
    return 0
  fi
  echo "[start-services] compose up failed; starting existing container(s): ${containers}" >&2
  local name started=0
  for name in $containers; do
    if docker start "$name" >/dev/null 2>&1; then
      started=1
    fi
  done
  [ "$started" = "1" ]
}

compose_up_or_start "${XUI_CONTAINER:-3xui}" docker compose up -d 3xui

if [ "${ENABLE_RUSTDESK:-1}" = "1" ]; then
  compose_up_or_start "hbbs hbbr" docker compose --profile rustdesk up -d hbbs hbbr
fi

if [ "${ENABLE_SUBCONVERTER:-1}" = "1" ]; then
  compose_up_or_start "${SUBCONVERTER_CONTAINER:-3xui_subconverter}" docker compose up -d subconverter
fi

if [ "${ENABLE_SUB_CONFIG_EDITOR:-1}" = "1" ]; then
  compose_up_or_start "${SUB_CONFIG_API_CONTAINER:-3xui_subconfig_api}" docker compose up -d --force-recreate subconfig-api
fi

if [ "${ENABLE_MASK_SITE:-1}" = "1" ]; then
  if [ -x ./scripts/mask-site.sh ]; then
    ./scripts/mask-site.sh
  fi
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && [ -x ./scripts/xui-builtin-subscription.sh ]; then
    ./scripts/xui-builtin-subscription.sh || true
  fi
  if [ -n "${TLS_CERT_FILE:-}" ] && [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    docker compose --profile site stop caddy-site >/dev/null 2>&1 || true
    compose_up_or_start "${CADDY_HTTPS_CONTAINER:-3xui_https_site}" docker compose --profile https-site up -d caddy-https
  else
    docker compose --profile https-site stop caddy-https >/dev/null 2>&1 || true
    compose_up_or_start "${CADDY_CONTAINER:-3xui_site}" docker compose --profile site up -d caddy-site
  fi
fi
