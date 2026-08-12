#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

[ -f .env ] || { echo ".env not found. Run install.sh first." >&2; exit 1; }

REQUESTED_DOMAIN_NAMES="${REQUESTED_DOMAIN_NAMES:-}"

set -a
# shellcheck disable=SC1091
. ./.env
set +a

XUI_CONTAINER="${XUI_CONTAINER:-3xui}"
SITE_HTTP_PORT="${SITE_HTTP_PORT:-80}"
SITE_HTTPS_PORT="${SITE_HTTPS_PORT:-443}"
AUTO_ENABLE_TROJAN="${AUTO_ENABLE_TROJAN:-1}"
HTTPS_SITE_ENABLE="${HTTPS_SITE_ENABLE:-0}"
HTTPS_HTTP_MODE="${HTTPS_HTTP_MODE:-reject}"
STRICT_DOMAIN_CERT="${STRICT_DOMAIN_CERT:-0}"
DOMAIN_NODE_MODE="${DOMAIN_NODE_MODE:-1}"
DOMAIN_PORT_MODE="${DOMAIN_PORT_MODE:-1}"
DOMAIN_PORT_START="${DOMAIN_PORT_START:-}"
DOMAIN_PORT_STEP="${DOMAIN_PORT_STEP:-1}"
ACME_SERVER="${ACME_SERVER:-letsencrypt}"
ACME_FALLBACK_SERVER="${ACME_FALLBACK_SERVER:-zerossl}"
REQUIRE_DOMAIN_ORIGIN="${REQUIRE_DOMAIN_ORIGIN:-1}"
PUBLIC_IPV4="${PUBLIC_IPV4:-}"
PUBLIC_IPV6="${PUBLIC_IPV6:-}"
DETECTED_PUBLIC_IPV4=""
DETECTED_PUBLIC_IPV6=""
PUBLIC_IPV4_CHECKED=0
PUBLIC_IPV6_CHECKED=0
REQUESTED_DOMAIN_NAMES="${REQUESTED_DOMAIN_NAMES:-}"

green=$'\033[0;32m'
cyan=$'\033[0;36m'
yellow=$'\033[1;33m'
red=$'\033[0;31m'
plain=$'\033[0m'

log() { printf '[domain-cert] %s\n' "$*"; }

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

random_port() {
  local hex
  hex="$(openssl rand -hex 2)"
  printf '%d' $((20000 + 0x${hex} % 30000))
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

expand_domain_separators() {
  printf '%s\n' "$@" \
    | sed -E 's/\.((com|net|org|icu|shop|xyz|top|site|online|io|co|me|app|dev|info|biz|cc|vip|club|store|cloud|live|pro|link|one|fun|work|world|today|life|tech|space|website|email|art|ai|us|uk|cn|hk|tw|jp|kr|de|fr|ca|au|in))\.((www|api|cdn|mail|m|h5|pay|panel|sub)\.)/.\1,\3/g'
}

normalize_domains() {
  expand_domain_separators "$1" | tr ',，;； ' '\n' | awk 'NF && !seen[$0]++ { printf "%s%s", sep, $0; sep="," }'
}

contains_ipv4_value() {
  expand_domain_separators "$1" | tr ',，;； ' '\n' | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

domain_values_without_ips() {
  expand_domain_separators "$@" \
    | tr ',，;； ' '\n' \
    | awk '
      NF && $0 !~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ && $0 !~ /^[0-9A-Fa-f:]+$/ && !seen[$0]++ {
        printf "%s%s", sep, $0
        sep=","
      }
    '
}

first_domain() {
  normalize_domains "$1" | awk -F',' '{print $1}'
}

domain_in_list() {
  local domain="$1"
  local domains="$2"
  printf ',%s,' "$domains" | grep -F ",${domain}," >/dev/null
}

domain_list_difference() {
  local source="$1"
  local exclude="$2"
  local domain_parts=() d result="" sep=""

  IFS=',' read -r -a domain_parts <<< "$source"
  for d in "${domain_parts[@]}"; do
    [ -n "$d" ] || continue
    if ! domain_in_list "$d" "$exclude"; then
      result="${result}${sep}${d}"
      sep=","
    fi
  done
  printf '%s' "$result"
}

domain_has_dns() {
  local domain="$1"
  [ -n "$domain" ] || return 1
  if command -v dig >/dev/null 2>&1; then
    [ -n "$(dig +short A "$domain" | awk 'NF {print; exit}')" ] && return 0
    [ -n "$(dig +short AAAA "$domain" | awk 'NF {print; exit}')" ] && return 0
    return 1
  fi
  getent ahosts "$domain" >/dev/null 2>&1
}

detect_public_ipv4() {
  [ -n "$PUBLIC_IPV4" ] && { printf '%s' "$PUBLIC_IPV4"; return; }
  if [ "$PUBLIC_IPV4_CHECKED" = "1" ]; then
    printf '%s' "$DETECTED_PUBLIC_IPV4"
    return
  fi
  PUBLIC_IPV4_CHECKED=1
  DETECTED_PUBLIC_IPV4="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  printf '%s' "$DETECTED_PUBLIC_IPV4"
}

detect_public_ipv6() {
  [ -n "$PUBLIC_IPV6" ] && { printf '%s' "$PUBLIC_IPV6"; return; }
  if [ "$PUBLIC_IPV6_CHECKED" = "1" ]; then
    printf '%s' "$DETECTED_PUBLIC_IPV6"
    return
  fi
  PUBLIC_IPV6_CHECKED=1
  DETECTED_PUBLIC_IPV6="$(curl -6 -fsS --max-time 6 https://api64.ipify.org 2>/dev/null || true)"
  printf '%s' "$DETECTED_PUBLIC_IPV6"
}

resolve_domain_a() {
  local domain="$1"
  if command -v dig >/dev/null 2>&1; then
    dig +short A "$domain" | awk 'NF'
  else
    getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | awk 'NF && !seen[$0]++'
  fi
}

resolve_domain_aaaa() {
  local domain="$1"
  if command -v dig >/dev/null 2>&1; then
    dig +short AAAA "$domain" | awk 'NF'
  else
    getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | awk 'NF && !seen[$0]++'
  fi
}

contains_line() {
  local needle="$1"
  grep -Fxq "$needle"
}

domain_points_to_origin() {
  local domain="$1"
  local ipv4 ipv6 a_records aaaa_records
  truthy "$REQUIRE_DOMAIN_ORIGIN" || return 0
  ipv4="$(detect_public_ipv4)"
  a_records="$(resolve_domain_a "$domain" || true)"
  if [ -n "$ipv4" ] && printf '%s\n' "$a_records" | contains_line "$ipv4"; then
    return 0
  fi
  ipv6="$(detect_public_ipv6)"
  [ -n "$ipv4$ipv6" ] || return 0
  aaaa_records="$(resolve_domain_aaaa "$domain" || true)"
  if [ -n "$ipv6" ] && printf '%s\n' "$aaaa_records" | contains_line "$ipv6"; then
    return 0
  fi
  log "Skipping ${domain}: DNS does not point to this VPS. A=${a_records:-none} AAAA=${aaaa_records:-none} expected IPv4=${ipv4:-none} IPv6=${ipv6:-none}. Use DNS-only/direct records for proxy nodes." >&2
  return 1
}

acme_ready_domains() {
  local domains="$1"
  local domain_parts=() d result="" sep=""

  IFS=',' read -r -a domain_parts <<< "$domains"
  for d in "${domain_parts[@]}"; do
    [ -n "$d" ] || continue
    if ! domain_has_dns "$d"; then
      log "Skipping ${d} for this certificate request: DNS A/AAAA record not found." >&2
    elif domain_points_to_origin "$d"; then
      result="${result}${sep}${d}"
      sep=","
    fi
  done
  printf '%s' "$result"
}

prompt() {
  local label="$1"
  local default="${2:-}"
  local answer
  if [ -n "$default" ]; then
    read -r -p "${label} [${default}]: " answer </dev/tty || answer=""
  else
    read -r -p "${label}: " answer </dev/tty || answer=""
  fi
  printf '%s' "${answer:-$default}"
}

yes_no() {
  local label="$1"
  local default="${2:-y}"
  local suffix answer
  if [ "$default" = "y" ]; then
    suffix="Y/n"
  else
    suffix="y/N"
  fi
  answer="$(prompt "${label} (${suffix})" "")"
  answer="${answer:-$default}"
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

write_mask_page() {
  local primary="$1"
  if [ -x ./scripts/mask-site.sh ]; then
    MASK_SITE_BRAND="${MASK_SITE_BRAND:-Hearthline Goods}" ./scripts/mask-site.sh
  else
    mkdir -p site
    printf '<!doctype html><title>%s</title><h1>%s</h1>\n' "${primary:-Service}" "${primary:-Service}" > site/index.html
  fi
}

normalize_uri_path() {
  local path="$1"
  [ -n "$path" ] || return 1
  case "$path" in /*) : ;; *) path="/$path" ;; esac
  case "$path" in */) : ;; *) path="$path/" ;; esac
  printf '%s' "$path"
}

xui_builtin_sub_caddy_block() {
  [ "${XUI_BUILTIN_SUB_ENABLE:-1}" = "1" ] || return 0
  [ -n "${XUI_BUILTIN_SUB_PATH:-}" ] || return 0
  [ -n "${XUI_BUILTIN_JSON_PATH:-}" ] || return 0
  [ -n "${XUI_BUILTIN_CLASH_PATH:-}" ] || return 0

  local sub_path json_path clash_path port
  sub_path="$(normalize_uri_path "$XUI_BUILTIN_SUB_PATH")"
  json_path="$(normalize_uri_path "$XUI_BUILTIN_JSON_PATH")"
  clash_path="$(normalize_uri_path "$XUI_BUILTIN_CLASH_PATH")"
  port="${XUI_BUILTIN_SUB_PORT:-2096}"

  cat <<EOF
	# 3xui builtin subscription start
	@xuiBuiltinSubBase path ${sub_path%/} ${sub_path} ${json_path%/} ${json_path} ${clash_path%/} ${clash_path}
	redir @xuiBuiltinSubBase /sub/ 308
	@xuiBuiltinSub path ${sub_path%/}/* ${json_path%/}/* ${clash_path%/}/*
	handle @xuiBuiltinSub {
		reverse_proxy 127.0.0.1:${port}
	}
	# 3xui builtin subscription end
EOF
}

write_caddyfile() {
  mkdir -p caddy
  local panel_path="${WEB_BASE_PATH:-panel}"
  local xui_sub_block
  panel_path="${panel_path#/}"
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && [ -z "${TLS_CERT_FILE:-}" ]; then
    adopt_existing_primary_cert "${TLS_SERVER_NAME:-${SERVER_ADDR:-}}" "${DOMAIN_NAMES:-}" || true
  fi
  xui_sub_block="$(xui_builtin_sub_caddy_block)"
  if [ "${TLS_CERT_FILE:-}" != "" ] && [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    cat > caddy/Caddyfile <<EOF
:80 {
	redir https://{host}{uri} 308
}

:127.0.0.1:${CADDY_FALLBACK_PORT:-8443} {
	tls /cert/domains/fullchain.pem /cert/domains/privkey.pem
	@panelRoot path /${panel_path}
	redir @panelRoot /${panel_path}/ 308
	@panelPath path /${panel_path}/*
	handle @panelPath {
		reverse_proxy 127.0.0.1:${PANEL_PORT:-2053}
	}
${xui_sub_block}
	handle_path /subconverter/* {
		reverse_proxy 127.0.0.1:${SUBCONVERTER_PORT:-25500}
	}
	handle_path /subconfig-api/* {
		reverse_proxy 127.0.0.1:${SUB_CONFIG_PORT:-27880}
	}
	@yamlConfig path /sub/config/*.yaml /sub/config/*.yml
	handle @yamlConfig {
		header {
			Content-Type "text/yaml; charset=utf-8"
			defer
		}
		root * /usr/share/caddy
		file_server
	}
	root * /usr/share/caddy
	file_server
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		Referrer-Policy no-referrer
		X-Frame-Options DENY
	}
}
EOF
  elif [ "${TLS_CERT_FILE:-}" != "" ] && [ "${HTTPS_HTTP_MODE:-reject}" = "reject" ]; then
    cat > caddy/Caddyfile <<'EOF'
:80 {
	respond "HTTPS is required." 403
	header {
		X-Content-Type-Options nosniff
		Referrer-Policy no-referrer
		X-Frame-Options DENY
	}
}
EOF
  else
    cat > caddy/Caddyfile <<'EOF'
:80 {
	handle_path /subconverter/* {
		reverse_proxy 127.0.0.1:${SUBCONVERTER_PORT:-25500}
	}
	handle_path /subconfig-api/* {
		reverse_proxy 127.0.0.1:${SUB_CONFIG_PORT:-27880}
	}
	@yamlConfig path /sub/config/*.yaml /sub/config/*.yml
	handle @yamlConfig {
		header {
			Content-Type "text/yaml; charset=utf-8"
			defer
		}
		root * /usr/share/caddy
		file_server
	}
	root * /usr/share/caddy
	file_server
	header {
		X-Content-Type-Options nosniff
		Referrer-Policy no-referrer
		X-Frame-Options DENY
	}
}
EOF
  fi
}

start_mask_site() {
  write_caddyfile
  if [ "${TLS_CERT_FILE:-}" != "" ] && [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    docker compose --profile site stop caddy-site >/dev/null 2>&1 || true
    docker compose --profile https-site up -d --force-recreate caddy-https
  else
    docker compose --profile https-site stop caddy-https >/dev/null 2>&1 || true
    docker compose --profile site up -d --force-recreate caddy-site
  fi
}

acme_bin() {
  if [ -x "$HOME/.acme.sh/acme.sh" ]; then
    printf '%s' "$HOME/.acme.sh/acme.sh"
  elif command -v acme.sh >/dev/null 2>&1; then
    command -v acme.sh
  else
    return 1
  fi
}

install_acme() {
  if acme_bin >/dev/null 2>&1; then
    return
  fi
  local email="${ACME_EMAIL:-}"
  if [ -z "$email" ]; then
    email="admin@$(first_domain "$DOMAIN_NAMES")"
  fi
  log "Installing official acme.sh from upstream."
  curl -fsSL https://get.acme.sh | sh -s email="$email"
}

issue_cert() {
  local domains="$1"
  local primary="$2"
  local acme domain_args=() domain_parts=() d server servers issue_ok acme_fullchain email

  install_acme
  acme="$(acme_bin)"
  email="${ACME_EMAIL:-admin@${primary}}"

  IFS=',' read -r -a domain_parts <<< "$domains"
  for d in "${domain_parts[@]}"; do
    [ -n "$d" ] && domain_args+=(-d "$d")
  done

  mkdir -p data/cert/domains
  servers="$(
    printf '%s\n' "${ACME_SERVER:-letsencrypt}" "${ACME_FALLBACK_SERVER:-}" \
      | tr ',，;； ' '\n' \
      | awk 'NF && !seen[$0]++'
  )"

  while IFS= read -r server; do
    [ -n "$server" ] || continue
    "$acme" --set-default-ca --server "$server" >/dev/null 2>&1 || true
    "$acme" --register-account --server "$server" -m "$email" >/dev/null 2>&1 || true
    log "Issuing certificate for: ${domains} (CA: ${server})"
    issue_ok=1
    if ! "$acme" --issue --server "$server" --webroot "$ROOT_DIR/site" "${domain_args[@]}" --keylength ec-256; then
      log "Certificate issue/renewal failed on ${server}; trying to install an existing certificate or another CA."
    else
      issue_ok=0
    fi
    acme_fullchain="$HOME/.acme.sh/${primary}_ecc/fullchain.cer"
    if [ "$issue_ok" != "0" ] && [ ! -s "$acme_fullchain" ]; then
      log "No existing acme.sh certificate file for ${primary}; skipping install-cert for ${server}."
      continue
    fi
    if ! "$acme" --install-cert -d "$primary" --ecc \
      --fullchain-file "$ROOT_DIR/data/cert/domains/fullchain.pem" \
      --key-file "$ROOT_DIR/data/cert/domains/privkey.pem" \
      --reloadcmd "cd $ROOT_DIR && docker restart $XUI_CONTAINER >/dev/null 2>&1 || true"; then
      log "Could not install certificate for ${primary} from ${server}."
      continue
    fi

    [ -s "$ROOT_DIR/data/cert/domains/fullchain.pem" ] || { log "Installed certificate file is missing."; continue; }
    [ -s "$ROOT_DIR/data/cert/domains/privkey.pem" ] || { log "Installed private key file is missing."; continue; }

    if ! cert_covers_domains "$domains"; then
      log "Installed certificate from ${server} does not cover every requested domain: ${domains}"
      continue
    fi

    set_env_var TLS_CERT_FILE "/root/cert/domains/fullchain.pem"
    set_env_var TLS_KEY_FILE "/root/cert/domains/privkey.pem"
    set_env_var TLS_SERVER_NAME "$primary"
    set_env_var ENABLE_ACME "1"
    set_env_var ACME_SERVER "$server"

    TLS_CERT_FILE="/root/cert/domains/fullchain.pem"
    TLS_KEY_FILE="/root/cert/domains/privkey.pem"
    TLS_SERVER_NAME="$primary"
    ACME_SERVER="$server"
    return 0
  done <<< "$servers"

  log "No ACME CA produced a certificate covering: ${domains}"
  return 1
}

cert_covers_domains() {
  local domains="$1"
  local cert="$ROOT_DIR/data/cert/domains/fullchain.pem"
  local sans d domain_parts=()

  [ -s "$cert" ] || return 1
  command -v openssl >/dev/null 2>&1 || return 1
  sans="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null || true)"
  [ -n "$sans" ] || return 1

  IFS=',' read -r -a domain_parts <<< "$domains"
  for d in "${domain_parts[@]}"; do
    [ -n "$d" ] || continue
    printf '%s\n' "$sans" | grep -F "DNS:${d}" >/dev/null || return 1
  done
  return 0
}

cert_covers_domain() {
  local domain="$1"
  local cert="$ROOT_DIR/data/cert/domains/fullchain.pem"
  local sans

  [ -n "$domain" ] || return 1
  [ -s "$cert" ] || return 1
  command -v openssl >/dev/null 2>&1 || return 1
  sans="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null || true)"
  [ -n "$sans" ] || return 1
  printf '%s\n' "$sans" | grep -F "DNS:${domain}" >/dev/null
}

cert_covered_domains_from_list() {
  local domains="$1"
  local domain_parts=() d result="" sep=""

  IFS=',' read -r -a domain_parts <<< "$domains"
  for d in "${domain_parts[@]}"; do
    [ -n "$d" ] || continue
    if cert_covers_domain "$d"; then
      result="${result}${sep}${d}"
      sep=","
    fi
  done
  printf '%s' "$result"
}

use_existing_cert() {
  local primary="$1"
  set_env_var TLS_CERT_FILE "/root/cert/domains/fullchain.pem"
  set_env_var TLS_KEY_FILE "/root/cert/domains/privkey.pem"
  set_env_var TLS_SERVER_NAME "$primary"
  set_env_var ENABLE_ACME "1"

  TLS_CERT_FILE="/root/cert/domains/fullchain.pem"
  TLS_KEY_FILE="/root/cert/domains/privkey.pem"
  TLS_SERVER_NAME="$primary"
}

adopt_existing_primary_cert() {
  local primary="$1"
  local domains="$2"

  [ -s "$ROOT_DIR/data/cert/domains/fullchain.pem" ] || return 1
  [ -s "$ROOT_DIR/data/cert/domains/privkey.pem" ] || return 1
  cert_covers_domain "$primary" || return 1
  use_existing_cert "$primary"
  if ! cert_covers_domains "$domains"; then
    log "Existing certificate covers primary ${primary}, but not every configured domain."
    log "Panel and /sub/ on ${primary} can work now; fix DNS for the other domains, then rerun x-ui option 10 or 16."
  fi
}

configure_firewall_ports() {
  if [ "${CONFIGURE_FIREWALL:-1}" != "1" ]; then
    return
  fi

  local ports=(
    "22/tcp"
    "${SITE_HTTP_PORT:-80}/tcp"
  )
  local reality_port
  while IFS= read -r reality_port; do
    [ -n "$reality_port" ] && ports+=("${reality_port}/tcp")
  done < <(domain_reality_ports)

  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    ports+=("${SITE_HTTPS_PORT:-443}/tcp")
  fi
  if [ "${ENABLE_TROJAN:-0}" = "1" ] || [ "${AUTO_ENABLE_TROJAN:-1}" = "1" ]; then
    local trojan_port
    while IFS= read -r trojan_port; do
      [ -n "$trojan_port" ] && ports+=("${trojan_port}/tcp")
    done < <(domain_trojan_ports)
  fi
  if [ "${ENABLE_SHADOWSOCKS:-1}" = "1" ]; then
    ports+=("${SHADOWSOCKS_PORT:-8388}/tcp" "${SHADOWSOCKS_PORT:-8388}/udp")
  fi
  if [ "${ENABLE_HYSTERIA:-0}" = "1" ]; then
    ports+=("${HYSTERIA_PORT:-8443}/udp")
  fi

  if command -v ufw >/dev/null 2>&1; then
    local p
    for p in "${ports[@]}"; do
      ufw allow "$p" >/dev/null 2>&1 || true
    done
    if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
      ufw delete allow "${PANEL_PORT:-2053}/tcp" >/dev/null 2>&1 || true
      ufw deny "${PANEL_PORT:-2053}/tcp" >/dev/null 2>&1 || true
    fi
    log "Firewall rules ensured with ufw: ${ports[*]}"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    local p proto port
    for p in "${ports[@]}"; do
      port="${p%/*}"
      proto="${p#*/}"
      firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
    log "Firewall rules ensured with firewalld: ${ports[*]}"
  else
    log "No ufw/firewalld detected; make sure these ports are allowed by your VPS firewall: ${ports[*]}"
  fi
}

domain_node_values_for_ports() {
  local values
  if truthy "${DOMAIN_NODE_MODE:-1}"; then
    values="${SERVER_ALIASES:-${DOMAIN_NAMES:-${SERVER_ADDR:-}}}"
  else
    values="${SERVER_ADDR:-}"
  fi
  printf '%s' "$values" | tr ',，;； ' '\n' | awk 'NF && !seen[$0]++'
}

domain_reality_ports() {
  local count base step i
  if ! truthy "${DOMAIN_PORT_MODE:-1}"; then
    printf '%s\n' "${REALITY_PORT:-443}"
    return
  fi
  count="$(domain_node_values_for_ports | awk 'NF { count++ } END { print count + 0 }')"
  [ "$count" -gt 0 ] || count=1
  base="${DOMAIN_PORT_START:-${REALITY_PORT:-443}}"
  step="${DOMAIN_PORT_STEP:-1}"
  [[ "$base" =~ ^[0-9]+$ ]] || base="${REALITY_PORT:-443}"
  [[ "$step" =~ ^[0-9]+$ ]] || step=1
  [ "$step" -ge 1 ] || step=1
  for ((i = 0; i < count; i++)); do
    printf '%d\n' $((base + i * step))
  done
}

domain_trojan_ports() {
  local count base step i
  if ! truthy "${DOMAIN_PORT_MODE:-1}"; then
    printf '%s\n' "${TROJAN_PORT:-9443}"
    return
  fi
  count="$(domain_node_values_for_ports | awk 'NF { count++ } END { print count + 0 }')"
  [ "$count" -gt 0 ] || count=1
  base="${TROJAN_PORT:-9443}"
  step="${DOMAIN_PORT_STEP:-1}"
  [[ "$base" =~ ^[0-9]+$ ]] || base="${TROJAN_PORT:-9443}"
  [[ "$step" =~ ^[0-9]+$ ]] || step=1
  [ "$step" -ge 1 ] || step=1
  for ((i = 0; i < count; i++)); do
    printf '%d\n' $((base + i * step))
  done
}

web_origin() {
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    if [ "${SITE_HTTPS_PORT:-443}" = "443" ]; then
      printf 'https://%s' "$1"
    else
      printf 'https://%s:%s' "$1" "${SITE_HTTPS_PORT:-443}"
    fi
  else
    if [ "${SITE_HTTP_PORT:-80}" = "80" ]; then
      printf 'http://%s' "$1"
    else
      printf 'http://%s:%s' "$1" "${SITE_HTTP_PORT:-80}"
    fi
  fi
}

secure_panel_for_https() {
  if [ "${HTTPS_SITE_ENABLE:-0}" != "1" ]; then
    return
  fi
  if [ "${AUTO_RANDOMIZE_DEFAULT_PANEL_PORT:-1}" = "1" ] && [ "${PANEL_PORT:-2053}" = "2053" ]; then
    PANEL_PORT="$(random_port)"
    set_env_var PANEL_PORT "$PANEL_PORT"
    log "Changed default panel port 2053 to random local port ${PANEL_PORT}."
  fi
  set_env_var PANEL_LISTEN_IP "127.0.0.1"
  PANEL_LISTEN_IP="127.0.0.1"
  if docker inspect "$XUI_CONTAINER" >/dev/null 2>&1; then
    docker exec "$XUI_CONTAINER" /app/x-ui setting \
      -port "${PANEL_PORT:-2053}" \
      -listenIP "127.0.0.1" \
      -username "${PANEL_USERNAME:-admin}" \
      -password "${PANEL_PASSWORD:-}" \
      -webBasePath "${WEB_BASE_PATH#/}" >/dev/null || true
    docker restart "$XUI_CONTAINER" >/dev/null || true
    sleep 5
  fi
}

main() {
  local domains="${REQUESTED_DOMAIN_NAMES:-${DOMAIN_NAMES:-}}"
  local primary email cert_domains cert_primary
  local old_domains="${DOMAIN_NAMES:-}"
  local old_aliases="${SERVER_ALIASES:-}"
  local old_server_addr="${SERVER_ADDR:-}"
  local old_tls_server_name="${TLS_SERVER_NAME:-}"
  local old_pending_domains="${PENDING_DOMAIN_NAMES:-}"
  local old_https="${HTTPS_SITE_ENABLE:-0}"
  local old_use_domain="${USE_DOMAIN_FOR_LINKS:-1}"
  local old_domain_values merged_domains default_domains
  local active_domains pending_domains covered_domains

  if [ "${1:-}" != "--auto" ]; then
    echo "${cyan}域名 / HTTPS 证书自动配置${plain}"
    default_domains="$(domain_values_without_ips "${DOMAIN_NAMES:-}" "${PENDING_DOMAIN_NAMES:-}")"
    domains="$(prompt "请输入新增域名或完整域名列表，可多个，用逗号或空格分隔" "${default_domains:-$domains}")"
  fi

  domains="$(normalize_domains "$domains")"
  if [ -z "$domains" ]; then
    echo "${yellow}未配置域名，已跳过。${plain}"
    return 0
  fi

  old_domain_values="$(domain_values_without_ips "$old_domains" "$old_aliases" "$old_server_addr" "$old_tls_server_name" "$old_pending_domains")"
  merged_domains="$(domain_values_without_ips "$old_domains" "$old_aliases" "$old_server_addr" "$old_tls_server_name" "$old_pending_domains" "$domains")"
  [ -n "$merged_domains" ] && domains="$merged_domains"

  primary="$(first_domain "$domains")"
  email="${ACME_EMAIL:-admin@${primary}}"
  cert_domains="$(acme_ready_domains "$domains")"
  if [ -n "$cert_domains" ]; then
    cert_primary="$(first_domain "$cert_domains")"
    if ! domain_in_list "$primary" "$cert_domains"; then
      log "Primary domain ${primary} has no DNS A/AAAA record yet; certificate will be requested for ${cert_primary} instead."
    fi
  else
    cert_primary="$primary"
    log "No configured domain currently has DNS A/AAAA records. HTTPS certificate request will be skipped."
  fi
  if truthy "$STRICT_DOMAIN_CERT" && [ "$cert_domains" != "$domains" ]; then
    log "STRICT_DOMAIN_CERT=1 requires every configured domain to have DNS A/AAAA before HTTPS is enabled."
    log "Configured domains: ${domains}"
    log "DNS-ready domains: ${cert_domains:-none}"
    return 1
  fi

  DOMAIN_NAMES="$domains"
  SERVER_ALIASES="$domains"
  TLS_SERVER_NAME="$cert_primary"
  if [ "${USE_DOMAIN_FOR_LINKS:-1}" = "1" ]; then
    SERVER_ADDR="$primary"
  fi
  # Reality intentionally owns public 443. Caddy is bound to the private
  # fallback port and Xray forwards ordinary HTTPS to it.
  set_env_var REALITY_PORT "443"
  REALITY_PORT="443"
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    set_env_var CADDY_FALLBACK_PORT "8443"
  fi
  set_env_var DOMAIN_PORT_MODE "${DOMAIN_PORT_MODE:-1}"
  set_env_var DOMAIN_PORT_STEP "${DOMAIN_PORT_STEP:-1}"
  DOMAIN_PORT_MODE="${DOMAIN_PORT_MODE:-1}"
  DOMAIN_PORT_STEP="${DOMAIN_PORT_STEP:-1}"
  if truthy "${RECREATE_ON_DOMAIN_UPDATE:-0}"; then
    RECREATE_MANAGED_INBOUNDS=1
    export RECREATE_MANAGED_INBOUNDS
    log "Domain update will rebuild all managed domain inbounds."
  fi
  if [ "${RECREATE_MANAGED_INBOUNDS+x}" != "x" ]; then
    if [ -z "$old_domain_values" ] || [ "$old_https" != "1" ] || [ "$old_use_domain" != "1" ] || contains_ipv4_value "$old_aliases" || contains_ipv4_value "$old_server_addr"; then
      RECREATE_MANAGED_INBOUNDS=1
      export RECREATE_MANAGED_INBOUNDS
      log "Domain migration detected; managed inbounds will be rebuilt to remove old IP/HTTP nodes."
    fi
  fi

  if [ "${1:-}" != "--auto" ]; then
    email="$(prompt "ACME 续期通知邮箱" "$email")"
  fi
  set_env_var ACME_EMAIL "$email"
  ACME_EMAIL="$email"

  write_mask_page "$primary"

  if [ "${ENABLE_ACME:-1}" = "1" ] && [ -n "$cert_domains" ]; then
    if [ "$cert_domains" != "$domains" ]; then
      log "Certificate request domain list after DNS filtering: ${cert_domains}"
      log "Fix DNS for skipped domains, then rerun x-ui option 10 or 16 to add them."
    fi
    if cert_covers_domains "$cert_domains"; then
      log "Existing certificate already covers: ${cert_domains}"
      use_existing_cert "$cert_primary"
    else
      if ! issue_cert "$cert_domains" "$cert_primary"; then
        local best_domains="" candidate_domains candidate_primary d domain_parts=()
        log "Full certificate request did not cover all DNS-ready domains; retrying best-effort by domain."
        best_domains="$(cert_covered_domains_from_list "$cert_domains")"
        IFS=',' read -r -a domain_parts <<< "$cert_domains"
        for d in "${domain_parts[@]}"; do
          [ -n "$d" ] || continue
          domain_in_list "$d" "$best_domains" && continue
          candidate_domains="$(domain_values_without_ips "$best_domains" "$d")"
          candidate_primary="$(first_domain "$candidate_domains")"
          if cert_covers_domains "$candidate_domains" || issue_cert "$candidate_domains" "$candidate_primary"; then
            if cert_covers_domains "$candidate_domains"; then
              best_domains="$candidate_domains"
              cert_primary="$candidate_primary"
              log "Certificate now covers: ${best_domains}"
            else
              log "Skipping ${d}: certificate was issued/installed but SAN coverage did not include it."
            fi
          else
            log "Skipping ${d}: certificate request failed; continuing with other domains."
          fi
        done
        if [ -n "$best_domains" ]; then
          cert_domains="$best_domains"
          cert_primary="$(first_domain "$cert_domains")"
          use_existing_cert "$cert_primary"
        elif ! adopt_existing_primary_cert "$cert_primary" "$cert_domains"; then
          truthy "$STRICT_DOMAIN_CERT" && return 1
        fi
      fi
    fi
  fi

  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && [ -z "${TLS_CERT_FILE:-}" ]; then
    if ! adopt_existing_primary_cert "$cert_primary" "${cert_domains:-$domains}"; then
      truthy "$STRICT_DOMAIN_CERT" && return 1
    fi
  fi

  active_domains="$domains"
  pending_domains=""
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    if cert_covers_domains "$domains"; then
      active_domains="$domains"
    else
      covered_domains="$(cert_covered_domains_from_list "$domains")"
      if truthy "$STRICT_DOMAIN_CERT"; then
        log "STRICT_DOMAIN_CERT=1 requires the installed certificate to cover every configured domain."
        log "Fix DNS/proxy records for all domains, then rerun the one-click command."
        return 1
      fi
      if [ -n "$covered_domains" ]; then
        active_domains="$covered_domains"
        pending_domains="$(domain_list_difference "$domains" "$active_domains")"
        log "Certificate does not cover every requested domain yet."
        log "Active HTTPS domains: ${active_domains}"
        log "Pending domains skipped for now: ${pending_domains}"
        log "Fix DNS/proxy records for pending domains, then rerun x-ui option 10 or the domain one-click command."
      else
        log "No installed certificate covers the requested domains. HTTPS would be red, so no domain/node changes were activated."
        log "Fix DNS/proxy records and rerun x-ui option 10 or the domain one-click command."
        set_env_var PENDING_DOMAIN_NAMES "$domains"
        PENDING_DOMAIN_NAMES="$domains"
        set_env_var HTTPS_SITE_ENABLE "$old_https"
        HTTPS_SITE_ENABLE="$old_https"
        set_env_var USE_DOMAIN_FOR_LINKS "$old_use_domain"
        USE_DOMAIN_FOR_LINKS="$old_use_domain"
        return 1
      fi
    fi
  fi

  domains="$active_domains"
  primary="$(first_domain "$domains")"
  cert_primary="$primary"
  set_env_var DOMAIN_NAMES "$domains"
  set_env_var SERVER_ALIASES "$domains"
  set_env_var TLS_SERVER_NAME "$cert_primary"
  if [ "${USE_DOMAIN_FOR_LINKS:-1}" = "1" ]; then
    set_env_var SERVER_ADDR "$primary"
  fi
  DOMAIN_NAMES="$domains"
  SERVER_ALIASES="$domains"
  TLS_SERVER_NAME="$cert_primary"
  if [ "${USE_DOMAIN_FOR_LINKS:-1}" = "1" ]; then
    SERVER_ADDR="$primary"
  fi
  set_env_var PENDING_DOMAIN_NAMES "$pending_domains"
  PENDING_DOMAIN_NAMES="$pending_domains"

  if [ "$AUTO_ENABLE_TROJAN" = "1" ]; then
    set_env_var ENABLE_TROJAN "1"
    ENABLE_TROJAN="1"
  fi

  configure_firewall_ports
  secure_panel_for_https

  if [ "${APPLY_AFTER_DOMAIN:-1}" = "1" ] && docker inspect "$XUI_CONTAINER" >/dev/null 2>&1; then
    ENABLE_TROJAN="${ENABLE_TROJAN:-0}" RECREATE_MANAGED_INBOUNDS="${RECREATE_MANAGED_INBOUNDS:-0}" ./scripts/apply-presets.sh || true
  fi
  if [ "${ENABLE_PROTOCOL_GUARD:-1}" = "1" ] && [ -x ./scripts/protocol-guard.sh ] && docker inspect "$XUI_CONTAINER" >/dev/null 2>&1; then
    PROTOCOL_GUARD_ACTION="${PROTOCOL_GUARD_ACTION:-disable}" ./scripts/protocol-guard.sh || true
  fi
  if [ "${RECREATE_MANAGED_INBOUNDS:-0}" = "1" ]; then
    set_env_var RECREATE_MANAGED_INBOUNDS "0"
    RECREATE_MANAGED_INBOUNDS=0
  fi

  start_mask_site

  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && [ -x ./scripts/xui-builtin-subscription.sh ]; then
    ./scripts/xui-builtin-subscription.sh || true
  fi
  if [ -x ./scripts/subscription.sh ]; then
    ./scripts/subscription.sh || true
  fi

  echo
  echo "${green}域名配置完成:${plain}"
  echo "  域名: ${domains}"
  echo "  主域名: ${primary}"
  echo "  Web入口: $(web_origin "$primary")/"
  echo "  VLESS Reality端口: $(domain_reality_ports | awk 'NF && !seen[$0]++ { printf "%s%s", sep, $0; sep=", " }')"
  if [ "${ENABLE_TROJAN:-0}" = "1" ] || [ "${AUTO_ENABLE_TROJAN:-1}" = "1" ]; then
    echo "  Trojan WS TLS端口: $(domain_trojan_ports | awk 'NF && !seen[$0]++ { printf "%s%s", sep, $0; sep=", " }')"
  fi
  echo "  订阅转换: $(web_origin "$primary")/sub/"
  if [ -n "${XUI_BUILTIN_SUB_PATH:-}" ]; then
    echo "  3X-UI内置订阅: $(web_origin "$primary")${XUI_BUILTIN_SUB_PATH}"
  fi
  if [ -n "$pending_domains" ]; then
    echo "  待补证书域名: ${pending_domains}"
  fi
  echo "  HTTP模式: ${HTTPS_HTTP_MODE:-reject}"
  echo "  证书: ${ROOT_DIR}/data/cert/domains/fullchain.pem"
  echo "  私钥: ${ROOT_DIR}/data/cert/domains/privkey.pem"
  echo "  自动续期: acme.sh cron"
}

main "$@"
