#!/usr/bin/env bash
# Ensure a managed subscription short link exists (rules + DNS) and print it.
# Idempotent: reuses MANAGED_SHORT_LINK_ID from .env when set; otherwise
# creates one via the local subconfig-api and persists the id to .env and
# runtime/managed-short-link.txt. Prints the full URL on stdout.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

web_origin() {
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    if [ "${SITE_HTTPS_PORT:-443}" = "443" ]; then
      printf 'https://%s' "$SERVER_ADDR"
    else
      printf 'https://%s:%s' "$SERVER_ADDR" "$SITE_HTTPS_PORT"
    fi
  else
    if [ "${SITE_HTTP_PORT:-80}" = "80" ]; then
      printf 'http://%s' "$SERVER_ADDR"
    else
      printf 'http://%s:%s' "$SERVER_ADDR" "$SITE_HTTP_PORT"
    fi
  fi
}

print_url() {
  printf '%s/subconfig-api/s/%s\n' "$(web_origin)" "$1"
}

set_env_var() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if [ -f .env ]; then
    awk -v k="$key" -v v="$value" '
      BEGIN { done = 0 }
      $0 ~ "^" k "=" { print k "=" v; done = 1; next }
      { print }
      END { if (!done) print k "=" v }
    ' .env > "$tmp" && mv "$tmp" .env
  else
    printf '%s=%s\n' "$key" "$value" > .env
  fi
}

SHORT_ID="${MANAGED_SHORT_LINK_ID:-}"
if [ -n "$SHORT_ID" ]; then
  print_url "$SHORT_ID"
  exit 0
fi

if [ -z "${SUBSCRIPTION_TOKEN:-}" ]; then
  echo "managed-short-link: SUBSCRIPTION_TOKEN is not set in .env; cannot create a short link." >&2
  exit 1
fi
if [ -z "${SERVER_ADDR:-}" ]; then
  echo "managed-short-link: SERVER_ADDR is not set in .env; cannot build the short-link URL." >&2
  exit 1
fi

API_BASE="http://127.0.0.1:${SUB_CONFIG_PORT:-27880}"
RESP="$(curl -fsS -m 15 -X POST -H "Content-Type: application/json" -d '{"managed": true}' "${API_BASE}/shorten?token=${SUBSCRIPTION_TOKEN}" 2>/dev/null)" || {
  echo "managed-short-link: subconfig-api is not reachable at ${API_BASE}; is the subscription service running?" >&2
  exit 1
}
SHORT_ID="$(printf '%s' "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id','') if d.get('success') else '')" 2>/dev/null)" || SHORT_ID=""
if [ -z "$SHORT_ID" ]; then
  echo "managed-short-link: subconfig-api did not return a short-link id: $RESP" >&2
  exit 1
fi

set_env_var MANAGED_SHORT_LINK_ID "$SHORT_ID"
mkdir -p runtime
printf '%s\n' "$SHORT_ID" > runtime/managed-short-link.txt
chmod 600 runtime/managed-short-link.txt
print_url "$SHORT_ID"
