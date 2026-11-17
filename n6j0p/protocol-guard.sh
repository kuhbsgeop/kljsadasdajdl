#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

[ -f .env ] || { echo ".env not found. Run install.sh first." >&2; exit 1; }

set -a
# shellcheck disable=SC1091
. ./.env
set +a

XUI_CONTAINER="${XUI_CONTAINER:-3xui}"
PANEL_PORT="${PANEL_PORT:-2053}"
WEB_BASE_PATH="${WEB_BASE_PATH:-panel}"
PROTOCOL_GUARD_ACTION="${PROTOCOL_GUARD_ACTION:-disable}"
SAFE_PROTOCOLS="${SAFE_PROTOCOLS:-vless,trojan,shadowsocks,wireguard,hysteria,tunnel}"
REQUIRE_SECURE_TRANSPORT="${REQUIRE_SECURE_TRANSPORT:-0}"
ENABLE_ADSPOWER_PROXY="${ENABLE_ADSPOWER_PROXY:-1}"
ADSPOWER_PROXY_PORT="${ADSPOWER_PROXY_PORT:-31081}"
ADSPOWER_PROXY_REMARK="${ADSPOWER_PROXY_REMARK:-auto-adspower-mixed-${ADSPOWER_PROXY_PORT}}"

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

api_token() {
  if [ -n "${XUI_API_TOKEN:-}" ]; then
    printf '%s' "$XUI_API_TOKEN"
    return
  fi
  local out token
  out="$(docker exec "$XUI_CONTAINER" /app/x-ui setting -getApiToken true)"
  token="$(printf '%s\n' "$out" | awk '/apiToken:/ {print $2}' | tail -n1)"
  [ -n "$token" ] || { echo "Could not generate 3x-ui API token." >&2; exit 1; }
  printf '%s' "$token"
}

api_base() {
  printf 'http://127.0.0.1:%s/%s' "$PANEL_PORT" "${WEB_BASE_PATH#/}"
}

is_safe_protocol() {
  local protocol="$1"
  printf ',%s,' "$SAFE_PROTOCOLS" | grep -q ",${protocol},"
}

has_secure_transport() {
  local protocol="$1"
  local security="$2"
  case "$protocol" in
    tunnel|dokodemo-door)
      return 0
      ;;
  esac
  case "$security" in
    tls|reality)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_managed_adspower_proxy() {
  local protocol="$1"
  local remark="$2"
  truthy "${ENABLE_ADSPOWER_PROXY:-1}" || return 1
  [ "$protocol" = "mixed" ] || return 1
  case "$remark" in
    "$ADSPOWER_PROXY_REMARK"|auto-adspower-mixed-*) return 0 ;;
    *) return 1 ;;
  esac
}

main() {
  local token base list rows changed id protocol remark enable security reason
  token="$(api_token)"
  base="$(api_base)"
  list="$(curl -fsS --connect-timeout 3 --max-time 30 -H "Authorization: Bearer ${token}" "${base%/}/panel/api/inbounds/list")"
  rows="$(printf '%s' "$list" | jq -r '
    def obj:
      if type == "string" then (fromjson? // {}) else (. // {}) end;
    .obj[]? | [.id, .protocol, .remark, .enable, ((.streamSettings | obj).security // "none")] | @tsv
  ')"
  changed=0

  while IFS=$'\t' read -r id protocol remark enable security; do
    [ -n "$id" ] || continue
    if is_managed_adspower_proxy "$protocol" "$remark"; then
      echo "Keeping managed AdsPower proxy inbound: ${remark} (${protocol}, security=${security}, id=${id})"
      continue
    fi
    reason=""
    if ! is_safe_protocol "$protocol"; then
      reason="unsafe protocol"
    elif truthy "$REQUIRE_SECURE_TRANSPORT" && ! has_secure_transport "$protocol" "$security"; then
      reason="missing tls/reality transport security"
    else
      continue
    fi
    case "$PROTOCOL_GUARD_ACTION" in
      delete)
        echo "Deleting unsafe inbound: ${remark} (${protocol}, security=${security}, id=${id}, reason=${reason})"
        curl -fsS --connect-timeout 3 --max-time 30 -X POST -H "Authorization: Bearer ${token}" \
          "${base%/}/panel/api/inbounds/del/${id}" | jq . || true
        changed=1
        ;;
      disable|*)
        if [ "$enable" = "true" ]; then
          echo "Disabling unsafe inbound: ${remark} (${protocol}, security=${security}, id=${id}, reason=${reason})"
          curl -fsS --connect-timeout 3 --max-time 30 -X POST -H "Authorization: Bearer ${token}" \
            -F enable=false "${base%/}/panel/api/inbounds/setEnable/${id}" | jq . || true
          changed=1
        else
          echo "Already disabled unsafe inbound: ${remark} (${protocol}, security=${security}, id=${id}, reason=${reason})"
        fi
        ;;
    esac
  done <<< "$rows"

  if [ "$changed" = "1" ]; then
    curl -fsS --connect-timeout 3 --max-time 30 -X POST -H "Authorization: Bearer ${token}" \
      "${base%/}/panel/api/server/restartXrayService" | jq . || true
  fi

  echo "Safe protocol allowlist: ${SAFE_PROTOCOLS}"
  echo "Require tls/reality transport security: ${REQUIRE_SECURE_TRANSPORT}"
  echo "Action: ${PROTOCOL_GUARD_ACTION}"
}

main "$@"
