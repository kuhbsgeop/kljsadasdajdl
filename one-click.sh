#!/usr/bin/env bash
set -Eeuo pipefail

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/kuhbsgeop/kljsadasdajdl/main}"

log() { printf '[3xui-one-click] %s\n' "$*"; }
die() { printf '[3xui-one-click] ERROR: %s\n' "$*" >&2; exit 1; }

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "Please run as root, for example: curl -fsSL ${REPO_RAW_BASE}/one-click.sh | sudo bash"
  fi
}

validate_domains() {
  local domain label
  local -a domains labels
  [ -n "${DOMAIN_NAMES:-}" ] || return 0
  IFS=',' read -r -a domains <<< "${DOMAIN_NAMES}"
  for domain in "${domains[@]}"; do
    [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" =~ ^[A-Za-z0-9.-]+$ ]] \
      || die "Invalid domain: $domain"
    [[ "$domain" != *..* && "$domain" != .* && "$domain" != *. ]] \
      || die "Invalid domain: $domain"
    [[ ! "$domain" =~ ^[0-9.]+$ ]] || die "Invalid domain: $domain"
    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
      [[ ${#label} -le 63 && "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] \
        || die "Invalid domain label in: $domain"
    done
  done
}

configure_defaults() {
  export CONFIG_WIZARD="${CONFIG_WIZARD:-0}"
  export MENU_AFTER_INSTALL="${MENU_AFTER_INSTALL:-1}"
  export ENABLE_SYSTEMD_AUTOSTART="${ENABLE_SYSTEMD_AUTOSTART:-1}"
  export ENABLE_PRESETS="${ENABLE_PRESETS:-1}"
  export ENABLE_SHADOWSOCKS="${ENABLE_SHADOWSOCKS:-1}"
  export ENABLE_ADSPOWER_PROXY="${ENABLE_ADSPOWER_PROXY:-1}"
  export ENABLE_SUBCONVERTER="${ENABLE_SUBCONVERTER:-1}"
  export ENABLE_SUB_CONFIG_EDITOR="${ENABLE_SUB_CONFIG_EDITOR:-1}"
  export ENABLE_RUSTDESK="${ENABLE_RUSTDESK:-1}"
  export SUBSCRIPTION_EXPAND_ALIASES="${SUBSCRIPTION_EXPAND_ALIASES:-1}"
  export PUBLIC_LINK_REFRESH_INTERVAL="${PUBLIC_LINK_REFRESH_INTERVAL:-60}"
  export XUI_BUILTIN_SUB_ENABLE="${XUI_BUILTIN_SUB_ENABLE:-1}"
  export XUI_BUILTIN_ALL_NODES="${XUI_BUILTIN_ALL_NODES:-1}"
  export ENABLE_PROTOCOL_GUARD="${ENABLE_PROTOCOL_GUARD:-1}"
  export PROTOCOL_GUARD_ACTION="${PROTOCOL_GUARD_ACTION:-disable}"
  export DOMAIN_NODE_MODE="${DOMAIN_NODE_MODE:-1}"
  export DOMAIN_PORT_MODE="${DOMAIN_PORT_MODE:-1}"
  export DOMAIN_PORT_STEP="${DOMAIN_PORT_STEP:-1}"
  export RECREATE_ON_DOMAIN_UPDATE="${RECREATE_ON_DOMAIN_UPDATE:-1}"
  export XUI_IMAGE="${XUI_IMAGE:-ghcr.io/mhsanaei/3x-ui:latest}"

  if [ -n "${DOMAIN_NAMES:-}" ]; then
    export ENABLE_ACME="${ENABLE_ACME:-1}"
    export ACME_SERVER="${ACME_SERVER:-letsencrypt}"
    export ACME_FALLBACK_SERVER="${ACME_FALLBACK_SERVER:-zerossl}"
    export REQUIRE_DOMAIN_ORIGIN="${REQUIRE_DOMAIN_ORIGIN:-1}"
    export STRICT_DOMAIN_CERT="${STRICT_DOMAIN_CERT:-1}"
    export PANEL_LISTEN_IP="${PANEL_LISTEN_IP:-127.0.0.1}"
    export USE_DOMAIN_FOR_LINKS="${USE_DOMAIN_FOR_LINKS:-1}"
    export HTTPS_SITE_ENABLE="${HTTPS_SITE_ENABLE:-1}"
    export HTTPS_HTTP_MODE="${HTTPS_HTTP_MODE:-redirect}"
    export AUTO_ENABLE_TROJAN="${AUTO_ENABLE_TROJAN:-1}"
    export ENABLE_TROJAN="${ENABLE_TROJAN:-1}"
    export REQUIRE_SECURE_TRANSPORT="${REQUIRE_SECURE_TRANSPORT:-1}"
    export RECREATE_MANAGED_INBOUNDS="${RECREATE_MANAGED_INBOUNDS:-1}"
  fi

  # IP is the no-argument fresh-install default; do not overwrite an existing .env.
  if [ -z "${DOMAIN_NAMES:-}" ] && { [ "${PUBLIC_HTTP_PANEL:-0}" = "1" ] || [ ! -f "${INSTALL_DIR:-/opt/3xui-selfhost-kit}/.env" ]; }; then
    export PANEL_LISTEN_IP="${PANEL_LISTEN_IP:-0.0.0.0}"
    export ENABLE_ACME="${ENABLE_ACME:-0}"
    export STRICT_DOMAIN_CERT="${STRICT_DOMAIN_CERT:-0}"
    export USE_DOMAIN_FOR_LINKS="${USE_DOMAIN_FOR_LINKS:-0}"
    export TLS_SERVER_NAME="${TLS_SERVER_NAME:-}"
    export TLS_CERT_FILE="${TLS_CERT_FILE:-}"
    export TLS_KEY_FILE="${TLS_KEY_FILE:-}"
    export HTTPS_SITE_ENABLE="${HTTPS_SITE_ENABLE:-0}"
    export HTTPS_HTTP_MODE="${HTTPS_HTTP_MODE:-allow}"
    export AUTO_ENABLE_TROJAN="${AUTO_ENABLE_TROJAN:-0}"
    export ENABLE_TROJAN="${ENABLE_TROJAN:-0}"
  fi
}

# When the entrypoint is piped from curl, never execute a similarly named
# script found in the caller's working directory with root privileges.
local_project_dir() {
  local source_path="${BASH_SOURCE[0]:-}"
  if [ -n "$source_path" ] && [ "${source_path##*/}" = "one-click.sh" ] && [ -f "$source_path" ]; then
    (cd "$(dirname "$source_path")" && pwd)
  fi
}

run_install() {
  local script_dir local_install tmp
  script_dir="$(local_project_dir)"
  local_install="${script_dir}/install.sh"
  if [ -n "$script_dir" ] && [ -f "$local_install" ]; then
    log "Running local install.sh with one-click defaults."
    exec bash "$local_install"
  fi

  log "Downloading install.sh from ${REPO_RAW_BASE}."
  tmp="$(mktemp)"
  if ! curl -fsSL "${REPO_RAW_BASE}/install.sh" -o "$tmp"; then
    rm -f "$tmp"
    die "Could not download install.sh."
  fi
  exec bash "$tmp"
}

run_update() {
  local script_dir local_update tmp
  script_dir="$(local_project_dir)"
  local_update="${script_dir}/scripts/safe-update.sh"
  if [ -n "$script_dir" ] && [ -f "$local_update" ]; then
    log "Running local safe-update.sh."
    exec bash "$local_update"
  fi

  log "Downloading safe-update.sh from ${REPO_RAW_BASE}."
  tmp="$(mktemp)"
  if ! curl -fsSL "${REPO_RAW_BASE}/n6j0p/safe-update.sh" -o "$tmp"; then
    rm -f "$tmp"
    die "Could not download safe-update.sh."
  fi
  exec bash "$tmp"
}

run_amazon_global() {
  local script_dir installed_dir target component tmp
  script_dir="$(local_project_dir)"
  installed_dir="${INSTALL_DIR:-/opt/3xui-selfhost-kit}"

  for target in "$script_dir" "$installed_dir"; do
    if [ -n "$target" ] && [ -f "${target}/.env" ]; then
      mkdir -p "${target}/scripts"
      log "Refreshing the Amazon residential-IP global command in ${target}."
      for component in amazon-global.sh amazon-global.py; do
        tmp="$(mktemp)"
        if ! curl -fsSL "${REPO_RAW_BASE}/n6j0p/${component}" -o "$tmp"; then
          rm -f "$tmp"
          die "Could not download scripts/${component}."
        fi
        chmod +x "$tmp"
        mv "$tmp" "${target}/scripts/${component}"
      done
      log "Creating or refreshing the Amazon residential-IP global subscription."
      cd "$target"
      exec bash ./scripts/amazon-global.sh install
    fi
  done

  log "No existing installation found; installing the dedicated Amazon global node."
  export ENABLE_AMAZON_GLOBAL=1
  export ENABLE_RUSTDESK=0
  export ENABLE_ADSPOWER_PROXY=0
  export ENABLE_SHADOWSOCKS=0
  export MENU_AFTER_INSTALL=0
  run_install
}

main() {
  local domain=""
  need_root
  case "${1:-install}" in
    install)
      [ "$#" -le 2 ] || die "Only one optional domain argument is supported."
      domain="${2:-}"
      ;;
    update|safe-update)
      configure_defaults
      run_update
      return
      ;;
    amazon-global|amazon|amazon-node)
      configure_defaults
      run_amazon_global
      return
      ;;
    *)
      [ "$#" -eq 1 ] || die "Usage: one-click.sh [domain]"
      domain="$1"
      ;;
  esac

  if [ -n "$domain" ]; then
    [ -z "${DOMAIN_NAMES:-}" ] || die "Specify the domain only once."
    export DOMAIN_NAMES="$domain"
  fi
  validate_domains
  configure_defaults
  run_install
}

main "$@"
