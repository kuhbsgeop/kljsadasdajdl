#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

log() { printf '[amazon-global] %s\n' "$*" >&2; }
die() { printf '[amazon-global] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./scripts/amazon-global.sh [install|refresh|print|--dry-run]

Creates one Android Clash/Mihomo subscription that explicitly sends Amazon
services and every other connection through the generated VLESS REALITY node.
Keep the Android client in Rule mode; do not use Clash's built-in Global mode.
EOF
}

set_env_var() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  if [ -f .env ]; then
    awk -v k="$key" -v v="$value" '
      BEGIN { done = 0 }
      $0 ~ "^" k "=" { print k "=" v; done = 1; next }
      { print }
      END { if (!done) print k "=" v }
    ' .env > "$tmp"
  else
    printf '%s=%s\n' "$key" "$value" > "$tmp"
  fi
  mv "$tmp" .env
  chmod 600 .env
}

load_env() {
  if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
  fi
}

find_reality_link() {
  local file
  if [ -n "${AMAZON_GLOBAL_SOURCE_LINK:-}" ]; then
    printf '%s\n' "$AMAZON_GLOBAL_SOURCE_LINK"
    return 0
  fi
  for file in runtime/panel-all-links.txt runtime/client-links.txt; do
    [ -s "$file" ] || continue
    awk '/^vless:\/\// && /security=reality/ { print; exit }' "$file"
  done | awk 'NF { print; exit }'
}

public_origin() {
  if [ -n "${AMAZON_GLOBAL_PUBLIC_ORIGIN:-}" ]; then
    printf '%s' "${AMAZON_GLOBAL_PUBLIC_ORIGIN%/}"
  elif [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    if [ "${SITE_HTTPS_PORT:-443}" = "443" ]; then
      printf 'https://%s' "${SERVER_ADDR:-your-server}"
    else
      printf 'https://%s:%s' "${SERVER_ADDR:-your-server}" "${SITE_HTTPS_PORT}"
    fi
  elif [ "${SITE_HTTP_PORT:-80}" = "80" ]; then
    printf 'http://%s' "${SERVER_ADDR:-your-server}"
  else
    printf 'http://%s:%s' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT}"
  fi
}

ensure_source_link() {
  local link
  link="$(find_reality_link)"
  if [ -n "$link" ]; then
    printf '%s' "$link"
    return 0
  fi

  log "No generated VLESS REALITY link found; applying protocol presets first."
  ENABLE_PRESETS=1 ./scripts/apply-presets.sh
  link="$(find_reality_link)"
  [ -n "$link" ] || die "No VLESS REALITY link was generated. Run ./scripts/manage.sh apply-presets and retry."
  printf '%s' "$link"
}

start_static_site() {
  command -v docker >/dev/null 2>&1 || return 0
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    docker compose --profile https-site up -d caddy-https >/dev/null
  else
    docker compose --profile site up -d caddy-site >/dev/null
  fi
}

render_subscription() {
  local source_link token output node_name group_name mtu url summary
  source_link="$(ensure_source_link)"
  token="${AMAZON_GLOBAL_TOKEN:-$(openssl rand -hex 16)}"
  node_name="${AMAZON_GLOBAL_NODE_NAME:-Amazon住宅全局节点}"
  group_name="${AMAZON_GLOBAL_GROUP_NAME:-Amazon住宅IP全局代理}"
  mtu="${AMAZON_GLOBAL_TUN_MTU:-1400}"
  output="site/subscriptions/${token}.yaml"

  python3 ./scripts/amazon-global.py \
    --link "$source_link" \
    --output "$output" \
    --node-name "$node_name" \
    --group-name "$group_name" \
    --mtu "$mtu"
  chmod 644 "$output"

  set_env_var ENABLE_AMAZON_GLOBAL "1"
  set_env_var AMAZON_GLOBAL_TOKEN "$token"
  set_env_var AMAZON_GLOBAL_NODE_NAME "$node_name"
  set_env_var AMAZON_GLOBAL_GROUP_NAME "$group_name"
  set_env_var AMAZON_GLOBAL_TUN_MTU "$mtu"
  load_env
  start_static_site

  url="$(public_origin)/subscriptions/${token}.yaml"
  mkdir -p runtime
  chmod 700 runtime
  summary="runtime/amazon-global.txt"
  cat > "$summary" <<EOF
Amazon residential-IP forced-global node

Subscription URL:
  ${url}

Client mode:
  Rule

Node:
  ${node_name}

Behavior:
  Amazon/Seller Central/AWS/Prime Video rules -> ${group_name}
  MATCH for every other service -> ${group_name}
  DNS follows rules through the node; only proxy-server bootstrap DNS is direct.
  IPv6 is disabled and Android TUN MTU is ${mtu}.

Sensitive source VLESS link:
  ${source_link}
EOF
  chmod 600 "$summary"

  printf '%s\n' "Amazon residential-IP global subscription ready:"
  printf '  %s\n' "$url"
  printf '%s\n' "Android mode: Rule (the config itself forces all traffic through the node)"
}

dry_run() {
  local source_link
  source_link="${AMAZON_GLOBAL_SOURCE_LINK:-vless://11111111-1111-4111-8111-111111111111@203.0.113.10:443?type=tcp&security=reality&pbk=examplePublicKey&fp=chrome&sni=www.cloudflare.com&sid=0123456789abcdef&spx=%2F&flow=xtls-rprx-vision#dry-run}"
  python3 ./scripts/amazon-global.py \
    --link "$source_link" \
    --output - \
    --node-name "${AMAZON_GLOBAL_NODE_NAME:-Amazon住宅全局节点}" \
    --group-name "${AMAZON_GLOBAL_GROUP_NAME:-Amazon住宅IP全局代理}" \
    --mtu "${AMAZON_GLOBAL_TUN_MTU:-1400}"
}

main() {
  local command="${1:-install}"
  load_env
  case "$command" in
    install|refresh)
      [ "$(id -u)" -eq 0 ] || die "Run as root: sudo ./scripts/manage.sh amazon-global"
      render_subscription
      ;;
    print)
      [ -s runtime/amazon-global.txt ] || die "No Amazon global subscription has been generated yet."
      cat runtime/amazon-global.txt
      ;;
    --dry-run|dry-run)
      dry_run
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
