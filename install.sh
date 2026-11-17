#!/usr/bin/env bash
set -Eeuo pipefail

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/kuhbsgeop/kljsadasdajdl/main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/3xui-selfhost-kit}"

# Default REALITY dest/SNI rotation list: each node gets a different
# high-traffic site (dest is "<site>:443", SNI is the site) so nodes do not
# share one fingerprint. Keep in sync with n6j0p/apply-presets.sh.
DEFAULT_REALITY_DEST_SITES="www.cloudflare.com,www.microsoft.com,www.apple.com,www.amazon.com,www.github.com,www.bing.com,www.adobe.com,www.mozilla.org,www.ubuntu.com,www.oracle.com"

INSTALL_ENV_OVERRIDE_KEYS=(
  PANEL_PORT PANEL_LISTEN_IP WEB_BASE_PATH
  DOMAIN_NAMES SERVER_ALIASES SERVER_ADDR DOMAIN_NODE_MODE DOMAIN_PORT_MODE DOMAIN_PORT_START DOMAIN_PORT_STEP
  RECREATE_ON_DOMAIN_UPDATE RECREATE_MANAGED_INBOUNDS
  ENABLE_ACME ACME_EMAIL ACME_SERVER ACME_FALLBACK_SERVER REQUIRE_DOMAIN_ORIGIN PUBLIC_IPV4 PUBLIC_IPV6 STRICT_DOMAIN_CERT USE_DOMAIN_FOR_LINKS HTTPS_SITE_ENABLE HTTPS_HTTP_MODE SITE_HTTPS_PORT AUTO_ENABLE_TROJAN
  ENABLE_TROJAN ENABLE_SHADOWSOCKS ENABLE_HYSTERIA ENABLE_AMAZON_GLOBAL
  AMAZON_GLOBAL_TOKEN AMAZON_GLOBAL_NODE_NAME AMAZON_GLOBAL_GROUP_NAME AMAZON_GLOBAL_TUN_MTU AMAZON_GLOBAL_PUBLIC_ORIGIN
  REALITY_PORT REALITY_DEST_SITES REALITY_TARGET REALITY_SERVER_NAMES REALITY_SPIDER_X REALITY_MIN_CLIENT_VERSION
  TLS_SERVER_NAME TLS_CERT_FILE TLS_KEY_FILE
  TROJAN_PORT SHADOWSOCKS_PORT HYSTERIA_PORT
  ENABLE_DOKODEMO DOKODEMO_LISTEN DOKODEMO_PORT DOKODEMO_TARGET_ADDRESS DOKODEMO_TARGET_PORT
  DOKODEMO_NETWORK DOKODEMO_FOLLOW_REDIRECT DOKODEMO_TPROXY DOKODEMO_FORWARDS
  ENABLE_ADSPOWER_PROXY ADSPOWER_PROXY_REMARK ADSPOWER_PROXY_LISTEN ADSPOWER_PROXY_PORT
  ADSPOWER_PROXY_USER ADSPOWER_PROXY_PASS ADSPOWER_PROXY_UDP
  ENABLE_SUBCONVERTER SUBSCRIPTION_EXPAND_ALIASES
  ENABLE_RUSTDESK RUSTDESK_IMAGE RUSTDESK_DATA_DIR RUSTDESK_SERVER
  XUI_BUILTIN_SUB_ENABLE XUI_BUILTIN_ALL_NODES XUI_BUILTIN_JSON_ENABLE XUI_BUILTIN_CLASH_ENABLE
  ENABLE_PROTOCOL_GUARD PROTOCOL_GUARD_ACTION SAFE_PROTOCOLS REQUIRE_SECURE_TRANSPORT
  ENABLE_SSH_HARDENING ENABLE_FAIL2BAN ENABLE_UNATTENDED_UPGRADES
)

for key in "${INSTALL_ENV_OVERRIDE_KEYS[@]}"; do
  if [ "${!key+x}" = "x" ]; then
    printf -v "__install_override_${key}" '%s' "${!key}"
  fi
done

log() { printf '[3xui-kit] %s\n' "$*"; }
die() { printf '[3xui-kit] ERROR: %s\n' "$*" >&2; exit 1; }

random_hex() {
  openssl rand -hex "${1:-12}"
}

random_password() {
  openssl rand -base64 36 | tr -d '\n' | tr '/+' 'Aa' | cut -c1-32
}

random_port() {
  local hex
  hex="$(openssl rand -hex 2)"
  printf '%d' $((20000 + 0x${hex} % 30000))
}

set_env_var() {
  local key="$1"
  local value="$2"
  if [ "$key" = "DOKODEMO_FORWARDS" ]; then
    value="'$(printf '%s' "$value" | sed "s/'/'\\\\''/g")'"
  fi
  local env_file="${3:-.env}"
  local tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    $0 ~ "^" k "=" { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$env_file" > "$tmp"
  mv "$tmp" "$env_file"
  chmod 600 "$env_file"
}

env_has_key() {
  local key="$1"
  local env_file="${2:-.env}"
  grep -q "^${key}=" "$env_file" 2>/dev/null
}

env_value() {
  local key="$1"
  local env_file="${2:-.env}"
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$env_file" 2>/dev/null || true
}

ensure_env_var() {
  local key="$1"
  local value="$2"
  local env_file="${3:-.env}"
  env_has_key "$key" "$env_file" || set_env_var "$key" "$value" "$env_file"
}

has_install_override() {
  local key="$1"
  local override_name="__install_override_${key}"
  [ "${!override_name+x}" = "x" ]
}

install_override_value() {
  local key="$1"
  local override_name="__install_override_${key}"
  printf '%s' "${!override_name}"
}

expand_domain_separators() {
  printf '%s\n' "$@" \
    | sed -E 's/\.((com|net|org|icu|shop|xyz|top|site|online|io|co|me|app|dev|info|biz|cc|vip|club|store|cloud|live|pro|link|one|fun|work|world|today|life|tech|space|website|email|art|ai|us|uk|cn|hk|tw|jp|kr|de|fr|ca|au|in))\.((www|api|cdn|mail|m|h5|pay|panel|sub)\.)/.\1,\3/g'
}

first_domain() {
  expand_domain_separators "$1" | tr ',，;； ' '\n' | awk 'NF { print; exit }'
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

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_list_lines() {
  printf '%s' "$1" | tr ',，;； ' '\n' | awk 'NF && !seen[$0]++'
}

domain_node_values_for_ports() {
  local values
  if truthy "${DOMAIN_NODE_MODE:-1}"; then
    values="${SERVER_ALIASES:-${DOMAIN_NAMES:-${SERVER_ADDR:-}}}"
  else
    values="${SERVER_ADDR:-}"
  fi
  normalize_list_lines "$values"
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

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "Please run as root, for example: curl -fsSL ${REPO_RAW_BASE}/install.sh | sudo bash"
  fi
}

install_pkg() {
  local pkgs=("$@")
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${pkgs[@]}"
  else
    die "No supported package manager found. Install curl, openssl, jq, tar, and Docker manually."
  fi
}

ensure_base_tools() {
  local missing=()
  for bin in curl openssl jq tar; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Installing base tools: ${missing[*]}"
    install_pkg "${missing[@]}"
  fi
  command -v sed >/dev/null 2>&1 || die "sed is missing."
  command -v awk >/dev/null 2>&1 || die "awk is missing."
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now docker || true
    fi
    return
  fi

  if [ "${INSTALL_DOCKER:-1}" != "1" ]; then
    die "Docker or Docker Compose plugin is missing. Set INSTALL_DOCKER=1 or install Docker first."
  fi

  log "Installing Docker with Docker's official convenience installer."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker || true
  fi

  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is still unavailable after Docker install."
}

# True when the given authorized_keys file holds at least one plausible key
# (key type followed by a base64 blob; option prefixes are tolerated).
user_has_ssh_key() {
  local keys_file="$1"
  [ -s "$keys_file" ] || return 1
  grep -qE '(^|[[:space:]])(ssh|ecdsa|sk-ssh)-[A-Za-z0-9-]+(@[A-Za-z0-9.-]+)?[[:space:]]+[A-Za-z0-9+/=]{20,}' "$keys_file" 2>/dev/null
}

harden_ssh() {
  if [ "${ENABLE_SSH_HARDENING:-1}" != "1" ]; then
    log "SSH hardening is disabled (ENABLE_SSH_HARDENING=${ENABLE_SSH_HARDENING})."
    return 0
  fi
  if ! command -v sshd >/dev/null 2>&1 && [ ! -f /etc/ssh/sshd_config ]; then
    log "sshd is not installed; skipping SSH hardening."
    return 0
  fi

  local ssh_dir="${SSH_CONFIG_DIR:-/etc/ssh}"
  local conf_dir="${ssh_dir}/sshd_config.d"
  local conf_file="${conf_dir}/00-3xui-hardening.conf"
  local sshd_config="${ssh_dir}/sshd_config"

  mkdir -p "$conf_dir"

  # Only disable password login when someone can still get in with a key.
  # Otherwise a password-only install would lock its owner out.
  # ROOT_AUTHORIZED_KEYS is a test hook; it defaults to the real path.
  local root_keys="${ROOT_AUTHORIZED_KEYS:-/root/.ssh/authorized_keys}"
  local has_key=0
  if user_has_ssh_key "$root_keys"; then
    has_key=1
  elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && user_has_ssh_key "/home/${SUDO_USER}/.ssh/authorized_keys"; then
    has_key=1
  fi

  local backup=""
  if [ -f "$conf_file" ]; then
    backup="${conf_file}.bak"
    cp -p "$conf_file" "$backup"
  fi

  {
    echo "# Managed by 3x-ui selfhost kit (install.sh harden_ssh)."
    echo "# Key-only SSH login; see SECURITY.md."
    echo "PubkeyAuthentication yes"
    echo "MaxAuthTries 3"
    echo "LoginGraceTime 30"
    if [ "$has_key" = "1" ]; then
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
      echo "PermitRootLogin prohibit-password"
    fi
  } > "$conf_file"
  chmod 644 "$conf_file"

  # sshd only reads the drop-in when the main config includes it (Debian 12+
  # and Ubuntu 22.04+ do by default). Add the include at the top when missing
  # so our settings win (sshd uses the first value it sees).
  local sshd_config_backed_up=0
  if [ -f "$sshd_config" ] && ! grep -qE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "$sshd_config"; then
    cp -p "$sshd_config" "${sshd_config}.bak-3xui-kit"
    sshd_config_backed_up=1
    local tmp_config
    tmp_config="$(mktemp)"
    {
      echo "Include ${conf_dir}/*.conf"
      cat "$sshd_config"
    } > "$tmp_config"
    mv "$tmp_config" "$sshd_config"
    log "Added sshd_config.d include to ${sshd_config} (backup: ${sshd_config}.bak-3xui-kit)."
  fi

  if command -v sshd >/dev/null 2>&1; then
    if ! sshd -t 2>/dev/null; then
      log "sshd -t failed after writing ${conf_file}; restoring previous state."
      if [ -n "$backup" ]; then
        mv "$backup" "$conf_file"
      else
        rm -f "$conf_file"
      fi
      if [ "$sshd_config_backed_up" = "1" ]; then
        mv "${sshd_config}.bak-3xui-kit" "$sshd_config"
      fi
      return 0
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || log "Could not reload sshd; restart it manually to apply SSH hardening."
  fi

  if [ "$has_key" = "1" ]; then
    log "SSH hardened: key-only login, max 3 auth tries, 30s grace time."
  else
    log "WARNING: No SSH public key found for root; password login was NOT disabled."
    log "WARNING: Add your public key to /root/.ssh/authorized_keys, verify key login in a second session, then re-run the installer to disable password login."
  fi
}

install_fail2ban() {
  if [ "${ENABLE_FAIL2BAN:-1}" != "1" ]; then
    log "fail2ban is disabled (ENABLE_FAIL2BAN=${ENABLE_FAIL2BAN})."
    return 0
  fi
  if ! command -v ufw >/dev/null 2>&1; then
    log "fail2ban skipped: ufw is not installed (the sshd jail bans through ufw)."
    return 0
  fi
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    if ! command -v apt-get >/dev/null 2>&1 && ! command -v dnf >/dev/null 2>&1 && ! command -v yum >/dev/null 2>&1 && ! command -v apk >/dev/null 2>&1; then
      log "fail2ban skipped: no supported package manager found."
      return 0
    fi
    log "Installing fail2ban."
    if ! install_pkg fail2ban; then
      log "fail2ban install failed; continuing without it."
      return 0
    fi
  fi

  local jail_dir="${FAIL2BAN_JAIL_DIR:-/etc/fail2ban/jail.d}"
  mkdir -p "$jail_dir"
  cat > "${jail_dir}/3xui-kit-sshd.conf" <<'EOF'
# Managed by 3x-ui selfhost kit (install.sh install_fail2ban).
[sshd]
enabled = true
backend = systemd
banaction = ufw
maxretry = 5
bantime = 1h
findtime = 10m
EOF

  if ! fail2ban-client -t >/dev/null 2>&1; then
    log "fail2ban config test failed; removing the kit jail and continuing without it."
    rm -f "${jail_dir}/3xui-kit-sshd.conf"
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now fail2ban >/dev/null 2>&1 || log "fail2ban installed but could not be started; check: systemctl status fail2ban"
  fi
  if fail2ban-client status sshd >/dev/null 2>&1; then
    log "fail2ban is running with the sshd jail (ufw ban, 5 failures in 10 min -> 1h ban)."
  else
    log "fail2ban sshd jail is not active yet; check: fail2ban-client status"
  fi
}

enable_unattended_upgrades() {
  if [ "${ENABLE_UNATTENDED_UPGRADES:-1}" != "1" ]; then
    log "Unattended upgrades are disabled (ENABLE_UNATTENDED_UPGRADES=${ENABLE_UNATTENDED_UPGRADES})."
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    log "Unattended upgrades skipped: not an apt-based system."
    return 0
  fi
  if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    log "Installing unattended-upgrades."
    if ! install_pkg unattended-upgrades; then
      log "unattended-upgrades install failed; continuing without it."
      return 0
    fi
  fi
  local auto_upgrades_file="${APT_AUTO_UPGRADES_FILE:-/etc/apt/apt.conf.d/20auto-upgrades}"
  mkdir -p "$(dirname "$auto_upgrades_file")"
  cat > "$auto_upgrades_file" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  log "Unattended security updates enabled (APT::Periodic::Unattended-Upgrade)."
}

harden_file_permissions() {
  cd "$INSTALL_DIR"
  if [ -f .env ]; then
    chmod 600 .env
  fi
  if [ -f data/db/x-ui.db ]; then
    chmod 600 data/db/x-ui.db
    chmod 600 data/db/x-ui.db-shm data/db/x-ui.db-wal 2>/dev/null || true
    log "Panel database permissions set to 600."
  fi
  local rustdesk_dir="${RUSTDESK_DATA_DIR:-/opt/rustdesk-server/data}"
  if [ -d "$rustdesk_dir" ]; then
    chmod 600 "$rustdesk_dir"/*.sqlite3 "$rustdesk_dir"/*.sqlite3-shm "$rustdesk_dir"/*.sqlite3-wal 2>/dev/null || true
  fi
}

run_security_check() {
  # The connector push cannot carry file modes, so a raw checkout may hold
  # this script without the executable bit; make it executable here.
  chmod +x "${INSTALL_DIR}/scripts/security-check.sh" 2>/dev/null || true
  if [ -x "${INSTALL_DIR}/scripts/security-check.sh" ]; then
    log "Running post-install security self-check."
    if (cd "$INSTALL_DIR" && ./scripts/security-check.sh); then
      log "Security self-check passed."
    else
      log "WARNING: Security self-check reported failures; review the lines above."
      log "WARNING: Re-run any time with: cd ${INSTALL_DIR} && ./scripts/manage.sh security-check"
    fi
  else
    log "Security self-check script is missing; skipping."
  fi
}

repo_source_path() {
  case "$1" in
    scripts/*) printf 'n6j0p/%s' "${1#scripts/}" ;;
    site/*) printf 'k4q8c/%s' "${1#site/}" ;;
    caddy/*) printf 'a9f2x/%s' "${1#caddy/}" ;;
    subconfig-api/*) printf 'u3t7w/%s' "${1#subconfig-api/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

download_file() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"
  curl -fsSL "${REPO_RAW_BASE}/$(repo_source_path "$src")" -o "$dst"
}

download_project() {
  log "Installing kit files into ${INSTALL_DIR}"
  mkdir -p "$INSTALL_DIR"

  local files=(
    "one-click.sh"
    "compose.yaml"
    "scripts/manage.sh"
    "scripts/apply-presets.sh"
    "scripts/domain-cert.sh"
    "scripts/subscription.sh"
    "scripts/xui-builtin-subscription.sh"
    "scripts/mask-site.sh"
    "scripts/protocol-guard.sh"
    "scripts/security-check.sh"
    "scripts/open-ports.sh"
    "scripts/amazon-global.sh"
    "scripts/amazon-global.py"
    "scripts/rustdesk.sh"
    "scripts/network-check.sh"
    "scripts/reconcile.sh"
    "scripts/safe-update.sh"
    "scripts/subconfig-api.py"
    "subconfig-api/Dockerfile"
    "subconfig-api/requirements.txt"
    "scripts/start-services.sh"
    "scripts/menu.sh"
    "caddy/Caddyfile"
    "site/index.html"
    "site/forward/index.html"
    "site/sub/config/3.5.yaml"
    "README.md"
    "SECURITY.md"
  )

  for f in "${files[@]}"; do
    if [ "$f" = "site/sub/config/3.5.yaml" ] && [ -s "${INSTALL_DIR}/${f}" ]; then
      log "Preserving uploaded subscription rules: ${INSTALL_DIR}/${f}"
      continue
    fi
    download_file "$f" "${INSTALL_DIR}/${f}"
  done

  chmod +x "${INSTALL_DIR}/one-click.sh" "${INSTALL_DIR}/scripts/"*.sh
}

install_cli_shortcut() {
  mkdir -p /usr/local/bin
  ln -sf "${INSTALL_DIR}/scripts/menu.sh" /usr/local/bin/3xui-kit
  ln -sf "${INSTALL_DIR}/scripts/menu.sh" /usr/local/bin/x-ui
  chmod +x "${INSTALL_DIR}/scripts/menu.sh"
}

configure_firewall_ports() {
  if [ "${CONFIGURE_FIREWALL:-1}" != "1" ]; then
    return
  fi

  local ports=(
    "22/tcp"
    "80/tcp"
  )
  local reality_port
  while IFS= read -r reality_port; do
    [ -n "$reality_port" ] && ports+=("${reality_port}/tcp")
  done < <(domain_reality_ports)

  if [ "${PANEL_LISTEN_IP:-127.0.0.1}" = "0.0.0.0" ]; then
    ports+=("${PANEL_PORT:-2053}/tcp")
  fi
  if [ "${ENABLE_SHADOWSOCKS:-0}" = "1" ]; then
    ports+=("${SHADOWSOCKS_PORT:-8388}/tcp" "${SHADOWSOCKS_PORT:-8388}/udp")
  fi
  if truthy "${ENABLE_ADSPOWER_PROXY:-0}"; then
    case "${ADSPOWER_PROXY_LISTEN:-0.0.0.0}" in
      127.0.0.1|localhost|::1) ;;
      *) ports+=("${ADSPOWER_PROXY_PORT:-31081}/tcp") ;;
    esac
  fi
  if [ "${ENABLE_TROJAN:-0}" = "1" ]; then
    local trojan_port
    while IFS= read -r trojan_port; do
      [ -n "$trojan_port" ] && ports+=("${trojan_port}/tcp")
    done < <(domain_trojan_ports)
  fi
  if [ "${ENABLE_HYSTERIA:-0}" = "1" ]; then
    ports+=("${HYSTERIA_PORT:-8443}/udp")
  fi
  if [ -n "${DOKODEMO_FORWARDS:-}" ]; then
    local entry port _target _target_port network listen
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      IFS=',' read -r port _target _target_port network listen _rest <<< "$entry"
      listen="${listen:-127.0.0.1}"
      network="${network:-tcp}"
      if [ "$listen" = "127.0.0.1" ] || [ "$listen" = "localhost" ]; then
        continue
      fi
      [ -n "$port" ] || continue
      case "$network" in
        tcp) ports+=("${port}/tcp") ;;
        udp) ports+=("${port}/udp") ;;
        *) ports+=("${port}/tcp" "${port}/udp") ;;
      esac
    done < <(printf '%s\n' "$DOKODEMO_FORWARDS" | tr ';' '\n')
  fi
  if [ "${ENABLE_DOKODEMO:-0}" = "1" ] && [ "${DOKODEMO_LISTEN:-127.0.0.1}" != "127.0.0.1" ] && [ "${DOKODEMO_LISTEN:-127.0.0.1}" != "localhost" ]; then
    case "${DOKODEMO_NETWORK:-tcp}" in
      tcp) ports+=("${DOKODEMO_PORT:-18080}/tcp") ;;
      udp) ports+=("${DOKODEMO_PORT:-18080}/udp") ;;
      *) ports+=("${DOKODEMO_PORT:-18080}/tcp" "${DOKODEMO_PORT:-18080}/udp") ;;
    esac
  fi

  if command -v ufw >/dev/null 2>&1; then
    # Never lock out the SSH session running the installer: allow the
    # effective sshd port in addition to 22 before enabling the firewall.
    local sshd_port
    sshd_port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
    if [ -n "${sshd_port:-}" ] && [ "$sshd_port" != "22" ]; then
      ports+=("${sshd_port}/tcp")
    fi
    local p
    for p in "${ports[@]}"; do
      ufw allow "$p" >/dev/null 2>&1 || true
    done
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true
    if ufw status 2>/dev/null | head -n 1 | grep -qi "Status: active"; then
      log "Firewall enabled with ufw (default deny incoming): ${ports[*]}"
    else
      log "WARNING: ufw rules were added but ufw is NOT active; the firewall is not enforcing."
      log "WARNING: Enable it manually with: sudo ufw enable (after confirming SSH port ${sshd_port:-22} is allowed)."
    fi
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
    log "No ufw/firewalld detected; make sure ports are allowed by your VPS firewall: ${ports[*]}"
  fi
}

generate_mask_site() {
  if [ "${ENABLE_MASK_SITE:-1}" != "1" ]; then
    return
  fi

  (cd "$INSTALL_DIR" && ./scripts/mask-site.sh)
}

start_mask_site() {
  if [ "${ENABLE_MASK_SITE:-1}" != "1" ]; then
    return
  fi
  cd "$INSTALL_DIR"
  if docker compose --profile site up -d caddy-site; then
    log "Masquerade static site is running on port 80."
  else
    log "Masquerade site did not start. Port 80 may already be in use."
  fi
}

configure_domains() {
  load_env
  if [ "${ENABLE_ACME:-0}" != "1" ] || [ -z "${DOMAIN_NAMES:-}" ]; then
    return
  fi
  log "Configuring domain certificates: ${DOMAIN_NAMES}"
  if ! (cd "$INSTALL_DIR" && AUTO_ENABLE_TROJAN="${AUTO_ENABLE_TROJAN:-0}" ./scripts/domain-cert.sh --auto); then
    if [ "${STRICT_DOMAIN_CERT:-0}" = "1" ]; then
      die "Domain HTTPS setup failed in strict mode. Fix DNS/certificate coverage for every DOMAIN_NAMES entry, then rerun the one-click command."
    fi
    log "Domain certificate automation did not fully complete. You can retry later with: x-ui -> domain/cert menu"
  fi
  load_env
}

configure_subscription() {
  load_env
  if [ "${ENABLE_SUBCONVERTER:-1}" != "1" ]; then
    return
  fi
  log "Configuring subscription converter web UI."
  if ! (cd "$INSTALL_DIR" && ./scripts/subscription.sh); then
    log "Subscription converter setup did not fully complete. Retry later with: x-ui -> subscription menu"
  fi
}

configure_amazon_global() {
  load_env
  if [ "${ENABLE_AMAZON_GLOBAL:-0}" != "1" ]; then
    return
  fi
  log "Creating the dedicated Amazon residential-IP forced-global subscription."
  (cd "$INSTALL_DIR" && ./scripts/amazon-global.sh install)
  load_env
}

configure_xui_builtin_subscription() {
  load_env
  if [ "${XUI_BUILTIN_SUB_ENABLE:-1}" != "1" ]; then
    return
  fi
  if [ "${HTTPS_SITE_ENABLE:-0}" != "1" ]; then
    log "Skipping 3x-ui built-in public subscription URI until HTTPS site is enabled."
    return
  fi
  log "Configuring 3x-ui built-in subscription behind HTTPS reverse proxy."
  if ! (cd "$INSTALL_DIR" && ./scripts/xui-builtin-subscription.sh); then
    log "3x-ui built-in subscription setup did not fully complete. Retry later with: cd ${INSTALL_DIR} && ./scripts/manage.sh xui-subscription"
  fi
  load_env
}

configure_protocol_guard() {
  load_env
  if [ "${ENABLE_PROTOCOL_GUARD:-1}" != "1" ]; then
    return
  fi
  log "Disabling unsafe inbound protocols if any exist."
  if ! (cd "$INSTALL_DIR" && ./scripts/protocol-guard.sh); then
    log "Protocol guard did not fully complete. Retry later with: cd ${INSTALL_DIR} && ./scripts/manage.sh protocol-guard"
  fi
}

install_systemd_autostart() {
  if [ "${ENABLE_SYSTEMD_AUTOSTART:-1}" != "1" ]; then
    return
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    log "systemd not found; Docker restart policy remains enabled."
    return
  fi
  if ! systemctl list-unit-files >/dev/null 2>&1; then
    log "systemd is not running; Docker restart policy remains enabled."
    return
  fi

  local docker_bin
  docker_bin="$(command -v docker)"
  cat > /etc/systemd/system/3xui-kit.service <<EOF
[Unit]
Description=3x-ui selfhost kit
Wants=network-online.target docker.service
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/env bash ${INSTALL_DIR}/scripts/start-services.sh
ExecStop=${docker_bin} compose --profile rustdesk stop 3xui subconverter subconfig-api caddy-site caddy-https hbbs hbbr
RemainAfterExit=yes
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF

  # Containers are already started by compose_up. Starting the oneshot unit here
  # repeats Docker startup and can block the installer indefinitely.
  systemctl daemon-reload
  systemctl enable 3xui-kit.service
  log "Boot autostart enabled without restarting the running services: 3xui-kit.service"
}

public_ip() {
  curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true
}

tty_available() {
  # Permission tests are not enough: /dev/tty can be readable/writable yet
  # fail to open (ENXIO) when there is no controlling terminal (CI,
  # containers, cron). Actually try opening it.
  (exec 9<> /dev/tty) 2>/dev/null
}

tty_print() {
  printf '%s\n' "$*" > /dev/tty 2>/dev/null || printf '%s\n' "$*"
}

tty_prompt() {
  local prompt="$1"
  local default="${2:-}"
  local answer
  if ! tty_available; then
    printf '%s' "$default"
    return 0
  fi
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" > /dev/tty 2>/dev/null || true
  else
    printf '%s: ' "$prompt" > /dev/tty 2>/dev/null || true
  fi
  IFS= read -r answer < /dev/tty || answer=""
  printf '%s' "${answer:-$default}"
}

tty_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local suffix answer
  if [ "$default" = "y" ]; then
    suffix="Y/n"
  else
    suffix="y/N"
  fi
  answer="$(tty_prompt "${prompt} (${suffix})" "")"
  answer="${answer:-$default}"
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

run_config_wizard() {
  if [ "${CONFIG_WIZARD:-1}" != "1" ] || [ -f "${INSTALL_DIR}/.env" ] || ! tty_available; then
    return
  fi

  local detected_addr bind_choice target server_names chain_addr chain_port domains acme_email default_panel_port
  detected_addr="$(public_ip)"
  default_panel_port="${PANEL_PORT:-$(random_port)}"

  tty_print ""
  tty_print "============================================================"
  tty_print "  3x-ui self-host setup"
  tty_print "============================================================"
  tty_print "Press Enter to accept the safe default shown in brackets."
  tty_print ""

  SERVER_ADDR="${SERVER_ADDR:-$(tty_prompt "Server public IP or domain for client links" "${detected_addr}")}"

  domains="$(tty_prompt "Domains for HTTPS certificate, comma-separated, optional" "${DOMAIN_NAMES:-}")"
  if [ -n "$domains" ]; then
    DOMAIN_NAMES="${DOMAIN_NAMES:-$domains}"
    TLS_SERVER_NAME="${TLS_SERVER_NAME:-${domains%%,*}}"
    if tty_yes_no "Use the first domain for panel/client display instead of IP?" "y"; then
      SERVER_ADDR="${domains%%,*}"
    fi
    ENABLE_ACME=1
    acme_email="$(tty_prompt "ACME email for certificate renewal notices" "${ACME_EMAIL:-admin@${domains%%,*}}")"
    ACME_EMAIL="${ACME_EMAIL:-$acme_email}"
    if tty_yes_no "Enable Trojan TLS automatically after certificate is issued?" "n"; then
      ENABLE_TROJAN=1
      AUTO_ENABLE_TROJAN=1
    fi
    if tty_yes_no "Enable HTTPS masquerade site on 443? This moves VLESS REALITY to 8443" "y"; then
      HTTPS_SITE_ENABLE=1
      HTTPS_HTTP_MODE=redirect
    else
      HTTPS_SITE_ENABLE=0
      HTTPS_HTTP_MODE=reject
    fi
  fi

  tty_print ""
  tty_print "Panel exposure:"
  tty_print "  1) Safe: bind panel to 127.0.0.1 for local-only access"
  tty_print "  2) Public: bind panel to 0.0.0.0"
  bind_choice="$(tty_prompt "Choose panel exposure" "1")"
  if [ "$bind_choice" = "2" ]; then
    PANEL_LISTEN_IP="${PANEL_LISTEN_IP:-0.0.0.0}"
  else
    PANEL_LISTEN_IP="${PANEL_LISTEN_IP:-127.0.0.1}"
  fi

  PANEL_PORT="${PANEL_PORT:-$(tty_prompt "Panel port" "$default_panel_port")}"
  WEB_BASE_PATH="${WEB_BASE_PATH:-$(tty_prompt "Panel random path, without leading slash" "p$(random_hex 9)")}"
  REALITY_PORT="${REALITY_PORT:-$(tty_prompt "VLESS REALITY public port" "443")}"
  dest_sites="$(tty_prompt "REALITY dest sites, comma-separated (one per node, rotated)" "${REALITY_DEST_SITES:-$DEFAULT_REALITY_DEST_SITES}")"
  REALITY_DEST_SITES="${REALITY_DEST_SITES:-$dest_sites}"

  if tty_yes_no "Enable Hysteria2 now? It needs a real TLS certificate for best security" "n"; then
    ENABLE_HYSTERIA=1
    HYSTERIA_PORT="${HYSTERIA_PORT:-$(tty_prompt "Hysteria2 UDP port" "8443")}"
    TLS_CERT_FILE="${TLS_CERT_FILE:-$(tty_prompt "TLS cert path inside container/host, e.g. /root/cert/fullchain.pem" "${TLS_CERT_FILE:-}")}"
    TLS_KEY_FILE="${TLS_KEY_FILE:-$(tty_prompt "TLS key path inside container/host, e.g. /root/cert/privkey.pem" "${TLS_KEY_FILE:-}")}"
  fi

  if tty_yes_no "Enable Trojan WS TLS now? It needs a real TLS certificate for best security" "n"; then
    ENABLE_TROJAN=1
    TROJAN_PORT="${TROJAN_PORT:-$(tty_prompt "Trojan TCP port" "9443")}"
    TLS_CERT_FILE="${TLS_CERT_FILE:-$(tty_prompt "TLS cert path inside container/host" "${TLS_CERT_FILE:-}")}"
    TLS_KEY_FILE="${TLS_KEY_FILE:-$(tty_prompt "TLS key path inside container/host" "${TLS_KEY_FILE:-}")}"
  fi

  if tty_yes_no "Enable Shadowsocks 2022 now? (not recommended: easier to fingerprint than REALITY)" "n"; then
    ENABLE_SHADOWSOCKS=1
    SHADOWSOCKS_PORT="${SHADOWSOCKS_PORT:-$(tty_prompt "Shadowsocks TCP/UDP port" "8388")}"
  else
    ENABLE_SHADOWSOCKS=0
  fi

  if tty_yes_no "Configure chain proxy outbound now?" "n"; then
    CHAIN_ENABLED=1
    CHAIN_MODE="${CHAIN_MODE:-$(tty_prompt "Chain mode: manual or all" "manual")}"
    CHAIN_TYPE="${CHAIN_TYPE:-$(tty_prompt "Chain type: socks, http, or trojan" "socks")}"
    chain_addr="$(tty_prompt "Chain proxy address" "${CHAIN_ADDRESS:-}")"
    chain_port="$(tty_prompt "Chain proxy port" "${CHAIN_PORT:-}")"
    CHAIN_ADDRESS="${CHAIN_ADDRESS:-$chain_addr}"
    CHAIN_PORT="${CHAIN_PORT:-$chain_port}"
    CHAIN_USER="${CHAIN_USER:-$(tty_prompt "Chain username, optional" "${CHAIN_USER:-}")}"
    CHAIN_PASS="${CHAIN_PASS:-$(tty_prompt "Chain password, optional" "${CHAIN_PASS:-}")}"
  fi

  tty_print ""
  tty_print "Configuration captured. Installing now..."
  tty_print "============================================================"
  tty_print ""
}

apply_existing_env_overrides() {
  cd "$INSTALL_DIR"
  [ -f .env ] || return 0

  local key value domains primary all_nodes_sub_id default_sub_id server_addr_default
  local old_domains old_https old_use_domain old_aliases old_server_addr old_tls_server_name old_domain_values
  local requested_domains requested_aliases merged_domains selected_server_addr selected_tls_server_name
  old_domains="$(env_value DOMAIN_NAMES)"
  old_https="$(env_value HTTPS_SITE_ENABLE)"
  old_use_domain="$(env_value USE_DOMAIN_FOR_LINKS)"
  old_aliases="$(env_value SERVER_ALIASES)"
  old_server_addr="$(env_value SERVER_ADDR)"
  old_tls_server_name="$(env_value TLS_SERVER_NAME)"
  old_domain_values="$(domain_values_without_ips "$old_domains" "$old_aliases" "$old_server_addr" "$old_tls_server_name")"

  for key in "${INSTALL_ENV_OVERRIDE_KEYS[@]}"; do
    if has_install_override "$key"; then
      value="$(install_override_value "$key")"
      set_env_var "$key" "$value"
      log "Applied install override to existing .env: ${key}"
    fi
  done

  if has_install_override DOMAIN_NAMES; then
    requested_domains="$(install_override_value DOMAIN_NAMES)"
    requested_aliases="$(
      if has_install_override SERVER_ALIASES; then
        install_override_value SERVER_ALIASES
      else
        printf '%s' "$requested_domains"
      fi
    )"
    domains="$requested_domains"
    primary="$(first_domain "$domains")"
    if [ -n "$domains" ]; then
      merged_domains="$(domain_values_without_ips "$old_domains" "$old_aliases" "$old_server_addr" "$old_tls_server_name" "$requested_domains" "$requested_aliases")"
      [ -n "$merged_domains" ] || merged_domains="$requested_domains"
      domains="$merged_domains"
      primary="$(first_domain "$domains")"
      set_env_var DOMAIN_NAMES "$domains"
      set_env_var SERVER_ALIASES "$domains"
      if [ -n "$primary" ]; then
        selected_server_addr="$primary"
        if ! contains_ipv4_value "$old_server_addr" && [ -n "$old_server_addr" ]; then
          selected_server_addr="$old_server_addr"
        fi
        if has_install_override SERVER_ADDR; then
          selected_server_addr="$(install_override_value SERVER_ADDR)"
          [ -n "$selected_server_addr" ] || selected_server_addr="$primary"
        fi
        set_env_var SERVER_ADDR "$selected_server_addr"

        selected_tls_server_name="$selected_server_addr"
        if ! contains_ipv4_value "$old_tls_server_name" && [ -n "$old_tls_server_name" ]; then
          selected_tls_server_name="$old_tls_server_name"
        fi
        if has_install_override TLS_SERVER_NAME; then
          selected_tls_server_name="$(install_override_value TLS_SERVER_NAME)"
          [ -n "$selected_tls_server_name" ] || selected_tls_server_name="$selected_server_addr"
        fi
        if contains_ipv4_value "$selected_tls_server_name"; then
          selected_tls_server_name="$selected_server_addr"
        fi
        if contains_ipv4_value "$selected_tls_server_name"; then
          selected_tls_server_name="$primary"
        fi
        set_env_var TLS_SERVER_NAME "$selected_tls_server_name"
      fi
      has_install_override ENABLE_ACME || set_env_var ENABLE_ACME "1"
      has_install_override STRICT_DOMAIN_CERT || set_env_var STRICT_DOMAIN_CERT "0"
      has_install_override USE_DOMAIN_FOR_LINKS || set_env_var USE_DOMAIN_FOR_LINKS "1"
      has_install_override HTTPS_SITE_ENABLE || set_env_var HTTPS_SITE_ENABLE "1"
      has_install_override HTTPS_HTTP_MODE || set_env_var HTTPS_HTTP_MODE "redirect"
      has_install_override AUTO_ENABLE_TROJAN || set_env_var AUTO_ENABLE_TROJAN "0"
      has_install_override ENABLE_TROJAN || set_env_var ENABLE_TROJAN "1"
      has_install_override ENABLE_SUBCONVERTER || set_env_var ENABLE_SUBCONVERTER "1"
      has_install_override SUBSCRIPTION_EXPAND_ALIASES || set_env_var SUBSCRIPTION_EXPAND_ALIASES "1"
      has_install_override DOMAIN_NODE_MODE || set_env_var DOMAIN_NODE_MODE "1"
      has_install_override RECREATE_ON_DOMAIN_UPDATE || set_env_var RECREATE_ON_DOMAIN_UPDATE "0"
      has_install_override RECREATE_MANAGED_INBOUNDS || set_env_var RECREATE_MANAGED_INBOUNDS "1"
      has_install_override ENABLE_PROTOCOL_GUARD || set_env_var ENABLE_PROTOCOL_GUARD "1"
      has_install_override PROTOCOL_GUARD_ACTION || set_env_var PROTOCOL_GUARD_ACTION "disable"
      has_install_override REQUIRE_SECURE_TRANSPORT || set_env_var REQUIRE_SECURE_TRANSPORT "1"
      has_install_override XUI_BUILTIN_SUB_ENABLE || set_env_var XUI_BUILTIN_SUB_ENABLE "1"
      has_install_override XUI_BUILTIN_ALL_NODES || set_env_var XUI_BUILTIN_ALL_NODES "1"
      if [ "${RECREATE_MANAGED_INBOUNDS+x}" != "x" ]; then
        if [ -z "$old_domain_values" ] || [ "$old_https" != "1" ] || [ "$old_use_domain" != "1" ]; then
          RECREATE_MANAGED_INBOUNDS=1
          export RECREATE_MANAGED_INBOUNDS
          log "Domain migration detected; managed inbounds will be rebuilt to remove old IP/HTTP nodes."
        fi
      fi
      log "Domain one-click mode enabled for existing install: ${domains}"
    fi
  fi

  ensure_env_var ENABLE_SUBCONVERTER "1"
  ensure_env_var SUBSCRIPTION_EXPAND_ALIASES "1"
  ensure_env_var PUBLIC_LINK_REFRESH_INTERVAL "60"
  ensure_env_var DOMAIN_NODE_MODE "1"
  ensure_env_var DOMAIN_PORT_MODE "1"
  ensure_env_var DOMAIN_PORT_STEP "1"
  ensure_env_var RECREATE_ON_DOMAIN_UPDATE "0"
  ensure_env_var XUI_BUILTIN_SUB_ENABLE "1"
  ensure_env_var XUI_BUILTIN_ALL_NODES "1"

  ensure_env_var COMPOSE_PROJECT_NAME "3xui_selfhost"
  ensure_env_var XUI_IMAGE "ghcr.io/mhsanaei/3x-ui:latest"
  ensure_env_var XUI_CONTAINER "3xui"
  ensure_env_var PANEL_PORT "$(random_port)"
  ensure_env_var PANEL_LISTEN_IP "127.0.0.1"
  ensure_env_var PANEL_USERNAME "admin_$(random_hex 4)"
  ensure_env_var PANEL_PASSWORD "$(random_password)"
  ensure_env_var WEB_BASE_PATH "p$(random_hex 9)"
  server_addr_default="$(public_ip)"
  ensure_env_var SERVER_ADDR "${server_addr_default:-127.0.0.1}"
  ensure_env_var REALITY_PORT "443"
  ensure_env_var REALITY_TARGET "www.cloudflare.com:443"
  ensure_env_var REALITY_SERVER_NAMES "www.cloudflare.com,cloudflare.com"
  ensure_env_var REALITY_DEST_SITES "$DEFAULT_REALITY_DEST_SITES"
  ensure_env_var REALITY_SPIDER_X "/"
  ensure_env_var REALITY_MIN_CLIENT_VERSION "1.8.2"
  ensure_env_var ENABLE_PRESETS "1"
  ensure_env_var ENABLE_AMAZON_GLOBAL "0"
  ensure_env_var AMAZON_GLOBAL_TOKEN ""
  ensure_env_var AMAZON_GLOBAL_NODE_NAME "Amazon住宅全局节点"
  ensure_env_var AMAZON_GLOBAL_GROUP_NAME "Amazon住宅IP全局代理"
  ensure_env_var AMAZON_GLOBAL_TUN_MTU "1400"
  ensure_env_var ENABLE_SHADOWSOCKS "0"
  ensure_env_var SHADOWSOCKS_PORT "8388"
  ensure_env_var TROJAN_PORT "9443"
  ensure_env_var HYSTERIA_PORT "8443"
  ensure_env_var ENABLE_ADSPOWER_PROXY "0"
  ensure_env_var ADSPOWER_PROXY_PORT "31081"
  ensure_env_var ADSPOWER_PROXY_REMARK "auto-adspower-mixed-$(env_value ADSPOWER_PROXY_PORT)"
  ensure_env_var ADSPOWER_PROXY_LISTEN "0.0.0.0"
  ensure_env_var ADSPOWER_PROXY_USER "u$(random_hex 4)"
  ensure_env_var ADSPOWER_PROXY_PASS "$(random_password)"
  ensure_env_var ADSPOWER_PROXY_UDP "0"
  ensure_env_var SAFE_PROTOCOLS "vless,trojan,shadowsocks,wireguard,hysteria,tunnel"
  ensure_env_var PROTOCOL_GUARD_ACTION "disable"
  ensure_env_var ENABLE_PROTOCOL_GUARD "1"
  ensure_env_var ENABLE_SSH_HARDENING "1"
  ensure_env_var ENABLE_FAIL2BAN "1"
  ensure_env_var ENABLE_UNATTENDED_UPGRADES "1"
  ensure_env_var SITE_HTTP_PORT "80"
  ensure_env_var ENABLE_MASK_SITE "1"
  ensure_env_var SUBCONVERTER_IMAGE "tindy2013/subconverter:latest"
  ensure_env_var SUBCONVERTER_PORT "25500"
  ensure_env_var ENABLE_SUB_CONFIG_EDITOR "1"
  ensure_env_var SUB_CONFIG_PORT "27880"
  ensure_env_var XUI_API_BASE "http://127.0.0.1:$(awk -F= '$1=="PANEL_PORT"{print $2; exit}' .env)/$(awk -F= '$1=="WEB_BASE_PATH"{print $2; exit}' .env)"
  ensure_env_var XUI_BUILTIN_SUB_LISTEN "127.0.0.1"
  ensure_env_var XUI_BUILTIN_SUB_PORT "2096"
  ensure_env_var XUI_BUILTIN_SUB_PATH "/xui-sub-$(random_hex 6)/"
  ensure_env_var XUI_BUILTIN_JSON_ENABLE "0"
  ensure_env_var XUI_BUILTIN_JSON_PATH "/xui-json-$(random_hex 6)/"
  ensure_env_var XUI_BUILTIN_CLASH_ENABLE "0"
  ensure_env_var XUI_BUILTIN_CLASH_PATH "/xui-clash-$(random_hex 6)/"

  all_nodes_sub_id="$(awk -F= '$1=="ALL_NODES_SUB_ID"{print $2; exit}' .env)"
  default_sub_id="$(awk -F= '$1=="DEFAULT_SUB_ID"{print $2; exit}' .env)"
  if [ -z "$all_nodes_sub_id" ]; then
    all_nodes_sub_id="${default_sub_id:-$(random_hex 8)}"
    set_env_var ALL_NODES_SUB_ID "$all_nodes_sub_id"
  fi
  if [ -z "$default_sub_id" ]; then
    set_env_var DEFAULT_SUB_ID "$all_nodes_sub_id"
  fi
}

write_env() {
  cd "$INSTALL_DIR"
  if [ -f .env ]; then
    log "Keeping existing .env and applying explicit one-click overrides."
    apply_existing_env_overrides
    return
  fi

  local base_path default_addr first_configured_domain server_addr_default enable_acme_default strict_domain_default use_domain_default https_site_default https_http_default all_nodes_sub_id default_sub_id
  local adspower_proxy_port_default adspower_proxy_user_default adspower_proxy_pass_default adspower_proxy_remark_default
  base_path="${WEB_BASE_PATH:-p$(random_hex 9)}"
  base_path="${base_path#/}"
  default_addr="$(public_ip)"
  first_configured_domain="$(first_domain "${DOMAIN_NAMES:-}")"
  server_addr_default="$default_addr"
  enable_acme_default="${ENABLE_ACME:-0}"
  strict_domain_default="${STRICT_DOMAIN_CERT:-0}"
  use_domain_default="${USE_DOMAIN_FOR_LINKS:-1}"
  https_site_default="${HTTPS_SITE_ENABLE:-0}"
  https_http_default="${HTTPS_HTTP_MODE:-reject}"
  if [ -n "$first_configured_domain" ]; then
    server_addr_default="$first_configured_domain"
    if [ "${ENABLE_ACME+x}" != "x" ]; then
      enable_acme_default=1
    fi
    if [ "${USE_DOMAIN_FOR_LINKS+x}" != "x" ]; then
      use_domain_default=1
    fi
    if [ "${HTTPS_SITE_ENABLE+x}" != "x" ]; then
      https_site_default=1
    fi
    if [ "${HTTPS_HTTP_MODE+x}" != "x" ]; then
      https_http_default=redirect
    fi
  fi
  all_nodes_sub_id="${ALL_NODES_SUB_ID:-${DEFAULT_SUB_ID:-$(random_hex 8)}}"
  default_sub_id="${DEFAULT_SUB_ID:-$all_nodes_sub_id}"
  adspower_proxy_port_default="${ADSPOWER_PROXY_PORT:-31081}"
  adspower_proxy_user_default="${ADSPOWER_PROXY_USER:-u$(random_hex 4)}"
  adspower_proxy_pass_default="${ADSPOWER_PROXY_PASS:-$(random_password)}"
  adspower_proxy_remark_default="${ADSPOWER_PROXY_REMARK:-auto-adspower-mixed-${adspower_proxy_port_default}}"

  cat > .env <<EOF
COMPOSE_PROJECT_NAME=3xui_selfhost
XUI_IMAGE=${XUI_IMAGE:-ghcr.io/mhsanaei/3x-ui:latest}
XUI_CONTAINER=${XUI_CONTAINER:-3xui}

PANEL_PORT=${PANEL_PORT:-$(random_port)}
PANEL_LISTEN_IP=${PANEL_LISTEN_IP:-127.0.0.1}
PANEL_USERNAME=${PANEL_USERNAME:-admin_$(random_hex 4)}
PANEL_PASSWORD=${PANEL_PASSWORD:-$(random_password)}
WEB_BASE_PATH=${base_path}

SERVER_ADDR=${SERVER_ADDR:-${server_addr_default}}
REALITY_PORT=${REALITY_PORT:-443}
REALITY_TARGET=${REALITY_TARGET:-www.cloudflare.com:443}
REALITY_SERVER_NAMES=${REALITY_SERVER_NAMES:-www.cloudflare.com,cloudflare.com}
REALITY_DEST_SITES=${REALITY_DEST_SITES:-$DEFAULT_REALITY_DEST_SITES}
REALITY_SPIDER_X=${REALITY_SPIDER_X:-/}
REALITY_MIN_CLIENT_VERSION=${REALITY_MIN_CLIENT_VERSION:-1.8.2}

ENABLE_PRESETS=${ENABLE_PRESETS:-1}
ENABLE_AMAZON_GLOBAL=${ENABLE_AMAZON_GLOBAL:-0}
AMAZON_GLOBAL_TOKEN=${AMAZON_GLOBAL_TOKEN:-}
AMAZON_GLOBAL_NODE_NAME=${AMAZON_GLOBAL_NODE_NAME:-Amazon住宅全局节点}
AMAZON_GLOBAL_GROUP_NAME=${AMAZON_GLOBAL_GROUP_NAME:-Amazon住宅IP全局代理}
AMAZON_GLOBAL_TUN_MTU=${AMAZON_GLOBAL_TUN_MTU:-1400}
AMAZON_GLOBAL_PUBLIC_ORIGIN=${AMAZON_GLOBAL_PUBLIC_ORIGIN:-}
ALL_NODES_SUB_ID=${all_nodes_sub_id}
DEFAULT_SUB_ID=${default_sub_id}
ENABLE_HYSTERIA=${ENABLE_HYSTERIA:-0}
ENABLE_TROJAN=${ENABLE_TROJAN:-0}
ENABLE_SHADOWSOCKS=${ENABLE_SHADOWSOCKS:-0}
ALLOW_SELF_SIGNED_TLS=${ALLOW_SELF_SIGNED_TLS:-0}
TLS_CERT_FILE=${TLS_CERT_FILE:-}
TLS_KEY_FILE=${TLS_KEY_FILE:-}
TLS_SERVER_NAME=${TLS_SERVER_NAME:-}
HYSTERIA_PORT=${HYSTERIA_PORT:-8443}
TROJAN_PORT=${TROJAN_PORT:-9443}
SHADOWSOCKS_PORT=${SHADOWSOCKS_PORT:-8388}
ENABLE_DOKODEMO=${ENABLE_DOKODEMO:-0}
DOKODEMO_LISTEN=${DOKODEMO_LISTEN:-127.0.0.1}
DOKODEMO_PORT=${DOKODEMO_PORT:-18080}
DOKODEMO_TARGET_ADDRESS=${DOKODEMO_TARGET_ADDRESS:-127.0.0.1}
DOKODEMO_TARGET_PORT=${DOKODEMO_TARGET_PORT:-80}
DOKODEMO_NETWORK=${DOKODEMO_NETWORK:-tcp}
DOKODEMO_FOLLOW_REDIRECT=${DOKODEMO_FOLLOW_REDIRECT:-0}
DOKODEMO_TPROXY=${DOKODEMO_TPROXY:-off}
DOKODEMO_FORWARDS=
ENABLE_ADSPOWER_PROXY=${ENABLE_ADSPOWER_PROXY:-0}
ADSPOWER_PROXY_REMARK=${adspower_proxy_remark_default}
ADSPOWER_PROXY_LISTEN=${ADSPOWER_PROXY_LISTEN:-0.0.0.0}
ADSPOWER_PROXY_PORT=${adspower_proxy_port_default}
ADSPOWER_PROXY_USER=${adspower_proxy_user_default}
ADSPOWER_PROXY_PASS=${adspower_proxy_pass_default}
ADSPOWER_PROXY_UDP=${ADSPOWER_PROXY_UDP:-0}
SAFE_PROTOCOLS=${SAFE_PROTOCOLS:-vless,trojan,shadowsocks,wireguard,hysteria,tunnel}
PROTOCOL_GUARD_ACTION=${PROTOCOL_GUARD_ACTION:-disable}
ENABLE_PROTOCOL_GUARD=${ENABLE_PROTOCOL_GUARD:-1}
REQUIRE_SECURE_TRANSPORT=${REQUIRE_SECURE_TRANSPORT:-1}
ENABLE_SSH_HARDENING=${ENABLE_SSH_HARDENING:-1}
ENABLE_FAIL2BAN=${ENABLE_FAIL2BAN:-1}
ENABLE_UNATTENDED_UPGRADES=${ENABLE_UNATTENDED_UPGRADES:-1}

CHAIN_ENABLED=${CHAIN_ENABLED:-0}
CHAIN_MODE=${CHAIN_MODE:-manual}
CHAIN_TYPE=${CHAIN_TYPE:-socks}
CHAIN_ADDRESS=${CHAIN_ADDRESS:-}
CHAIN_PORT=${CHAIN_PORT:-}
CHAIN_USER=${CHAIN_USER:-}
CHAIN_PASS=${CHAIN_PASS:-}
CHAIN_SERVER_NAME=${CHAIN_SERVER_NAME:-}
CHAIN_ALLOW_INSECURE=${CHAIN_ALLOW_INSECURE:-0}

SITE_HTTP_PORT=${SITE_HTTP_PORT:-80}
ENABLE_MASK_SITE=${ENABLE_MASK_SITE:-1}
DOMAIN_NAMES=${DOMAIN_NAMES:-}
ENABLE_ACME=${enable_acme_default}
ACME_EMAIL=${ACME_EMAIL:-}
ACME_SERVER=${ACME_SERVER:-letsencrypt}
ACME_FALLBACK_SERVER=${ACME_FALLBACK_SERVER:-zerossl}
REQUIRE_DOMAIN_ORIGIN=${REQUIRE_DOMAIN_ORIGIN:-1}
PUBLIC_IPV4=${PUBLIC_IPV4:-}
PUBLIC_IPV6=${PUBLIC_IPV6:-}
STRICT_DOMAIN_CERT=${strict_domain_default}
USE_DOMAIN_FOR_LINKS=${use_domain_default}
AUTO_ENABLE_TROJAN=${AUTO_ENABLE_TROJAN:-0}
HTTPS_SITE_ENABLE=${https_site_default}
HTTPS_HTTP_MODE=${https_http_default}
SITE_HTTPS_PORT=${SITE_HTTPS_PORT:-443}
ENABLE_SUBCONVERTER=${ENABLE_SUBCONVERTER:-1}
SUBCONVERTER_IMAGE=${SUBCONVERTER_IMAGE:-tindy2013/subconverter:latest}
SUBCONVERTER_PORT=${SUBCONVERTER_PORT:-25500}
SUBSCRIPTION_TOKEN=${SUBSCRIPTION_TOKEN:-}
ENABLE_SUB_CONFIG_EDITOR=${ENABLE_SUB_CONFIG_EDITOR:-1}
SUB_CONFIG_PORT=${SUB_CONFIG_PORT:-27880}
SUB_CONFIG_ADMIN_TOKEN=${SUB_CONFIG_ADMIN_TOKEN:-}
SERVER_ALIASES=${SERVER_ALIASES:-${DOMAIN_NAMES:-${SERVER_ADDR:-${server_addr_default}}}}
SUBSCRIPTION_EXPAND_ALIASES=${SUBSCRIPTION_EXPAND_ALIASES:-1}
PUBLIC_LINK_REFRESH_INTERVAL=${PUBLIC_LINK_REFRESH_INTERVAL:-60}
DOMAIN_NODE_MODE=${DOMAIN_NODE_MODE:-1}
DOMAIN_PORT_MODE=${DOMAIN_PORT_MODE:-1}
DOMAIN_PORT_START=${DOMAIN_PORT_START:-}
DOMAIN_PORT_STEP=${DOMAIN_PORT_STEP:-1}
RECREATE_ON_DOMAIN_UPDATE=${RECREATE_ON_DOMAIN_UPDATE:-0}
RECREATE_MANAGED_INBOUNDS=${RECREATE_MANAGED_INBOUNDS:-0}
XUI_API_BASE=${XUI_API_BASE:-http://127.0.0.1:${PANEL_PORT:-2053}/${base_path}}
XUI_API_TOKEN=${XUI_API_TOKEN:-}
XUI_BUILTIN_SUB_ENABLE=${XUI_BUILTIN_SUB_ENABLE:-1}
XUI_BUILTIN_SUB_LISTEN=${XUI_BUILTIN_SUB_LISTEN:-127.0.0.1}
XUI_BUILTIN_SUB_PORT=${XUI_BUILTIN_SUB_PORT:-2096}
XUI_BUILTIN_SUB_PATH=${XUI_BUILTIN_SUB_PATH:-/xui-sub-$(random_hex 6)/}
XUI_BUILTIN_ALL_NODES=${XUI_BUILTIN_ALL_NODES:-1}
XUI_BUILTIN_JSON_ENABLE=${XUI_BUILTIN_JSON_ENABLE:-0}
XUI_BUILTIN_JSON_PATH=${XUI_BUILTIN_JSON_PATH:-/xui-json-$(random_hex 6)/}
XUI_BUILTIN_CLASH_ENABLE=${XUI_BUILTIN_CLASH_ENABLE:-0}
XUI_BUILTIN_CLASH_PATH=${XUI_BUILTIN_CLASH_PATH:-/xui-clash-$(random_hex 6)/}
ENABLE_RUSTDESK=${ENABLE_RUSTDESK:-1}
RUSTDESK_IMAGE=${RUSTDESK_IMAGE:-rustdesk/rustdesk-server:1.1.16}
RUSTDESK_DATA_DIR=${RUSTDESK_DATA_DIR:-/opt/rustdesk-server/data}
RUSTDESK_SERVER=${RUSTDESK_SERVER:-${SERVER_ADDR:-${server_addr_default}}}
EOF
  chmod 600 .env
  set_env_var DOKODEMO_FORWARDS "${DOKODEMO_FORWARDS:-}"
}

compose_up() {
  cd "$INSTALL_DIR"
  remove_orphan_compose_containers
  log "Pulling latest official 3x-ui image and starting service."
  docker compose pull 3xui
  docker compose up -d 3xui
}

remove_orphan_compose_containers() {
  local expected_project="${COMPOSE_PROJECT_NAME:-3xui_selfhost}"
  local entries=(
    "${XUI_CONTAINER:-3xui}:3xui"
    "${SUBCONVERTER_CONTAINER:-3xui_subconverter}:subconverter"
    "${SUB_CONFIG_API_CONTAINER:-3xui_subconfig_api}:subconfig-api"
    "${CADDY_CONTAINER:-3xui_site}:caddy-site"
    "${CADDY_HTTPS_CONTAINER:-3xui_https_site}:caddy-https"
  )
  local entry name service project_label service_label
  for entry in "${entries[@]}"; do
    name="${entry%%:*}"
    service="${entry#*:}"
    docker inspect "$name" >/dev/null 2>&1 || continue
    project_label="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)"
    service_label="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$name" 2>/dev/null || true)"
    if [ "$project_label" = "$expected_project" ] && [ "$service_label" = "$service" ]; then
      continue
    fi
    log "Removing orphan/conflicting container ${name} before compose up."
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
}

load_env() {
  set -a
  # shellcheck disable=SC1091
  . "${INSTALL_DIR}/.env"
  set +a
}

wait_panel_db() {
  local i
  for i in $(seq 1 60); do
    if docker exec "${XUI_CONTAINER:-3xui}" /app/x-ui setting -show true >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "3x-ui did not become ready in time. Check: cd ${INSTALL_DIR} && docker compose logs 3xui"
}

wait_panel_http() {
  load_env
  local base_path="${WEB_BASE_PATH:-panel}"
  local url="http://127.0.0.1:${PANEL_PORT:-2053}/${base_path#/}/"
  local i
  log "Waiting for panel web endpoint: ${url}"
  for i in $(seq 1 90); do
    if curl -sS --max-time 2 -o /dev/null "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  log "Panel web endpoint did not answer yet; continuing so credentials can be shown."
  return 1
}

configure_panel() {
  load_env
  local path_no_slash="${WEB_BASE_PATH:-panel}"
  path_no_slash="${path_no_slash#/}"
  log "Hardening panel login, base path, and listen IP."
  docker exec "${XUI_CONTAINER:-3xui}" /app/x-ui setting \
    -port "${PANEL_PORT:-2053}" \
    -listenIP "${PANEL_LISTEN_IP:-127.0.0.1}" \
    -username "${PANEL_USERNAME:-admin}" \
    -password "${PANEL_PASSWORD:-$(random_password)}" \
    -webBasePath "$path_no_slash" >/dev/null
  docker restart "${XUI_CONTAINER:-3xui}" >/dev/null
  wait_panel_db
  wait_panel_http || true
}

write_install_summary() {
  load_env
  local summary="${INSTALL_DIR}/runtime/install-summary.txt"
  local public_panel_url="http://${SERVER_ADDR:-your-server}:${PANEL_PORT:-2053}/${WEB_BASE_PATH:-panel}/"
  local local_panel_url="http://127.0.0.1:${PANEL_PORT:-2053}/${WEB_BASE_PATH:-panel}/"
  local access_label="Direct panel URL"
  local access_url="$public_panel_url"
  local access_note="Panel is reachable directly from the public address above."
  local panel_urls="${INSTALL_DIR}/runtime/panel-public-urls.txt"
  local reality_ports trojan_ports
  reality_ports="$(domain_reality_ports | awk 'NF && !seen[$0]++ { printf "%s%s/tcp", sep, $0; sep=", " }')"
  trojan_ports="$(domain_trojan_ports | awk 'NF && !seen[$0]++ { printf "%s%s/tcp", sep, $0; sep=", " }')"
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    public_panel_url="https://${SERVER_ADDR:-your-server}/${WEB_BASE_PATH:-panel}/"
    access_url="$public_panel_url"
    access_note="Domain HTTPS mode is enabled; open the panel directly with the domain URL."
  elif [ "${PANEL_LISTEN_IP:-127.0.0.1}" = "0.0.0.0" ] || [ "${PANEL_LISTEN_IP:-127.0.0.1}" = "::" ]; then
    access_url="$public_panel_url"
    access_note="Public IP HTTP mode is enabled; open the panel directly with the IP URL."
  else
    access_label="Local-only panel URL"
    access_url="$local_panel_url"
    access_note="Panel is bound to localhost. Change PANEL_LISTEN_IP to 0.0.0.0 or enable domain HTTPS mode for direct public access."
  fi
  mkdir -p "${INSTALL_DIR}/runtime"
  chmod 700 "${INSTALL_DIR}/runtime"
  : > "$panel_urls"
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && [ -n "${DOMAIN_NAMES:-}" ]; then
    printf '%s' "$DOMAIN_NAMES" | tr ',，;； ' '\n' | awk 'NF && !seen[$0]++' | while IFS= read -r domain; do
      printf 'https://%s/%s/\n' "$domain" "${WEB_BASE_PATH:-panel}" >> "$panel_urls"
    done
  else
    printf '%s\n' "$public_panel_url" > "$panel_urls"
  fi
  chmod 600 "$panel_urls"
  cat > "$summary" <<EOF
3x-ui self-host kit installed.

1) Install dir
  ${INSTALL_DIR}

2) Visual panel
  Panel bind: ${PANEL_LISTEN_IP:-127.0.0.1}:${PANEL_PORT:-2053}
  Panel path: /${WEB_BASE_PATH:-panel}/
  Username:   ${PANEL_USERNAME:-unknown}
  Password:   ${PANEL_PASSWORD:-unknown}

3) How to open the panel
  ${access_label}:
    ${access_url}
  Access mode:
    ${access_note}
  All configured domain panel URLs:
    ${panel_urls}

4) Client config links
  Script-generated main links:
    ${INSTALL_DIR}/runtime/client-links.txt

  3x-ui panel-rendered links:
    ${INSTALL_DIR}/runtime/panel-all-links.txt

  Print them:
    cd ${INSTALL_DIR}
    ./scripts/manage.sh links

5) Default protocol
  VLESS + TCP/Raw + XTLS Vision + REALITY
  Port: ${REALITY_PORT:-443}
  Reality dest sites (one per node, rotated in order; dest is site:443, SNI is the site):
$(printf '%s' "${REALITY_DEST_SITES:-$DEFAULT_REALITY_DEST_SITES}" | tr ',' '\n' | sed 's/^/    /')
  Per-node dest (nodes created by this install):
$(if [ -s "${INSTALL_DIR}/runtime/reality-dest-sites.txt" ]; then awk '{ printf "    %s (port %s): %s\n", $1, $2, $3 }' "${INSTALL_DIR}/runtime/reality-dest-sites.txt"; else echo "    (no new REALITY nodes created; existing nodes keep their dest)"; fi)
  Reality minimum client version: ${REALITY_MIN_CLIENT_VERSION:-1.8.2} (Mihomo compatible)

  Node security model (REALITY is the primary protocol):
  - VLESS + REALITY is the default node: its TLS handshake is indistinguishable
    from a real visit to the dest site, and non-REALITY traffic is forwarded to
    that site, so probes see a normal website.
  - Trojan (WS + TLS) is the backup for clients without REALITY support; its
    WebSocket handshake is easier to fingerprint. Non-Trojan traffic falls back
    to the masquerade site on :80. Trojan auto-enable after certificate
    issuance is OFF by default (opt in with AUTO_ENABLE_TROJAN=1).
  - The AdsPower SOCKS5 proxy (plaintext, no encryption) is OFF by default;
    enable it only if you need it for a fingerprint browser.
  - Shadowsocks-2022 is OFF by default (its traffic pattern is the easiest to
    fingerprint); enable it only if you need it.
  - Hysteria2 (QUIC + TLS 1.3) is an optional second protocol for UDP transport
    diversity; it is OFF by default.
  - VMess and plaintext (no TLS/REALITY) nodes are never generated; the
    protocol guard disables them if they appear.
  - REALITY on port 443 is the recommended next step (stealthiest); it needs
    the panel/site to move off Caddy :443 first, so it is not in this install.

6) AdsPower fingerprint browser proxy
  Enabled: ${ENABLE_ADSPOWER_PROXY:-0}
  3X-UI inbound protocol: mixed
  AdsPower proxy type: Socks5
  Host: ${SERVER_ADDR:-your-server}
  Port: ${ADSPOWER_PROXY_PORT:-31081}
  Username: ${ADSPOWER_PROXY_USER:-not generated yet}
  Password: ${ADSPOWER_PROXY_PASS:-not generated yet}
  Config file:
    ${INSTALL_DIR}/runtime/adspower-proxy.txt
  Test from your computer:
    curl --socks5-hostname '${ADSPOWER_PROXY_USER:-user}:${ADSPOWER_PROXY_PASS:-pass}@${SERVER_ADDR:-your-server}:${ADSPOWER_PROXY_PORT:-31081}' https://api.ipify.org

7) Configure from command line
  Edit environment:
    nano ${INSTALL_DIR}/.env

  Re-apply protocol presets:
    cd ${INSTALL_DIR}
    ./scripts/manage.sh apply-presets

  Enable Hysteria2 with a real cert:
    TLS_CERT_FILE=/root/cert/fullchain.pem TLS_KEY_FILE=/root/cert/privkey.pem ENABLE_HYSTERIA=1 ./scripts/apply-presets.sh

  Enable Trojan WS TLS with a real cert:
    TLS_CERT_FILE=/root/cert/fullchain.pem TLS_KEY_FILE=/root/cert/privkey.pem ENABLE_TROJAN=1 ./scripts/apply-presets.sh

  Enable Shadowsocks 2022:
    ENABLE_SHADOWSOCKS=1 ./scripts/apply-presets.sh

  Add a chain proxy outbound and route all traffic through it:
    CHAIN_ENABLED=1 CHAIN_MODE=all CHAIN_TYPE=socks CHAIN_ADDRESS=1.2.3.4 CHAIN_PORT=1080 ./scripts/apply-presets.sh

  Add an upstream Trojan outbound:
    CHAIN_ENABLED=1 CHAIN_MODE=all CHAIN_TYPE=trojan CHAIN_ADDRESS=upstream.example.com CHAIN_PORT=443 CHAIN_PASS=trojan-password CHAIN_SERVER_NAME=upstream.example.com ./scripts/apply-presets.sh

  Add a dokodemo-door forwarding inbound (3X-UI protocol name: tunnel):
    ENABLE_DOKODEMO=1 DOKODEMO_LISTEN=127.0.0.1 DOKODEMO_PORT=18080 DOKODEMO_TARGET_ADDRESS=127.0.0.1 DOKODEMO_TARGET_PORT=80 DOKODEMO_NETWORK=tcp ./scripts/apply-presets.sh

  Add multiple port-forward nodes in one command:
    DOKODEMO_FORWARDS='27677,api.example.com,9999,tcp,0.0.0.0;27678,127.0.0.1,8080,tcp,0.0.0.0' ./scripts/apply-presets.sh

  Add or update a port forward from the command line:
    ./scripts/manage.sh forward 27677 127.0.0.1 9999 tcp 0.0.0.0

  Refresh AdsPower / fingerprint browser proxy:
    ./scripts/manage.sh adspower-proxy

8) Manage
  cd ${INSTALL_DIR}
  x-ui
  3xui-kit
  ./scripts/manage.sh menu
  ./scripts/manage.sh status
  ./scripts/manage.sh update
  ./scripts/manage.sh backup

9) Firewall reminder
  Public: open ${reality_ports:-${REALITY_PORT:-443}/tcp} for VLESS REALITY.
  Public: open ${trojan_ports:-${TROJAN_PORT:-9443}/tcp} for Trojan WS TLS when Trojan is enabled.
  Public: open ${ADSPOWER_PROXY_PORT:-31081}/tcp for AdsPower Socks5 when ENABLE_ADSPOWER_PROXY=1 and ADSPOWER_PROXY_LISTEN is public.
  Private: keep ${PANEL_PORT:-2053}/tcp closed to public internet when PANEL_LISTEN_IP=127.0.0.1.

10) Autostart
  Docker container restart policy: unless-stopped
  systemd service: 3xui-kit.service
  Check status:
    systemctl status 3xui-kit.service --no-pager

11) Domains and HTTPS
  Domains: ${DOMAIN_NAMES:-not configured}
  ACME auto renew: ${ENABLE_ACME:-0}
  HTTPS masquerade site: ${HTTPS_SITE_ENABLE:-0}
  HTTP mode after certificate: ${HTTPS_HTTP_MODE:-reject}
  TLS cert in container: ${TLS_CERT_FILE:-not configured}

12) Subscription converter
  Web UI:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/sub/' "${SERVER_ADDR:-your-server}" || printf 'http://%s:%s/sub/' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}")
  Forward web UI:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/forward/' "${SERVER_ADDR:-your-server}" || printf 'http://%s:%s/forward/' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}")
  Forward web UI with token auto-filled:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/forward/#token=%s' "${SERVER_ADDR:-your-server}" "${SUB_CONFIG_ADMIN_TOKEN:-token}" || printf 'http://%s:%s/forward/#token=%s' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}" "${SUB_CONFIG_ADMIN_TOKEN:-token}")
  Local node subscription:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/subscriptions/%s.txt' "${SERVER_ADDR:-your-server}" "${SUBSCRIPTION_TOKEN:-token}" || printf 'http://%s:%s/subscriptions/%s.txt' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}" "${SUBSCRIPTION_TOKEN:-token}")
  Base64 subscription for subconverter:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/subscriptions/%s.b64' "${SERVER_ADDR:-your-server}" "${SUBSCRIPTION_TOKEN:-token}" || printf 'http://%s:%s/subscriptions/%s.b64' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}" "${SUBSCRIPTION_TOKEN:-token}")
  Clash 3.5.yaml rendered subscription:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/subconfig-api/render/clash?token=%s' "${SERVER_ADDR:-your-server}" "${SUBSCRIPTION_TOKEN:-token}" || printf 'http://%s:%s/subconfig-api/render/clash?token=%s' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}" "${SUBSCRIPTION_TOKEN:-token}")
  Default local conversion config:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/sub/config/3.5.yaml' "${SERVER_ADDR:-your-server}" || printf 'http://%s:%s/sub/config/3.5.yaml' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}")
  Rules editor:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/sub/' "${SERVER_ADDR:-your-server}" || printf 'http://%s:%s/sub/' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}")
  Rules editor token:
    ${SUB_CONFIG_ADMIN_TOKEN:-not generated yet}
  Forward editor token:
    ${SUB_CONFIG_ADMIN_TOKEN:-not generated yet}
  Backend image:
    ${SUBCONVERTER_IMAGE:-tindy2013/subconverter:latest}
  Note:
    If HTTPS_SITE_ENABLE=0 and HTTPS_HTTP_MODE=reject, public /sub/ is intentionally blocked after certificate setup. Enable the HTTPS site from x-ui to use /sub/ over TLS.

13) 3X-UI built-in subscription
  Listen:
    ${XUI_BUILTIN_SUB_LISTEN:-127.0.0.1}:${XUI_BUILTIN_SUB_PORT:-2096}
  All nodes subId:
    ${ALL_NODES_SUB_ID:-${DEFAULT_SUB_ID:-not generated yet}}
  Reverse proxy URI:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s%s' "${SERVER_ADDR:-your-server}" "${XUI_BUILTIN_SUB_PATH:-/xui-sub/}" || printf 'local-only until HTTPS is enabled')
  JSON URI:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s%s' "${SERVER_ADDR:-your-server}" "${XUI_BUILTIN_JSON_PATH:-/xui-json/}" || printf 'local-only until HTTPS is enabled')
  Clash URI:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s%s' "${SERVER_ADDR:-your-server}" "${XUI_BUILTIN_CLASH_PATH:-/xui-clash/}" || printf 'local-only until HTTPS is enabled')

14) RustDesk Server OSS
  Enabled: ${ENABLE_RUSTDESK:-1}
  Client configuration:
    ${INSTALL_DIR}/runtime/rustdesk-server.txt
  Manage:
    ${INSTALL_DIR}/scripts/manage.sh rustdesk status

15) Amazon residential-IP forced-global node
  Enabled: ${ENABLE_AMAZON_GLOBAL:-0}
  Android mode: Rule
  Subscription URL:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/subscriptions/%s.yaml' "${SERVER_ADDR:-your-server}" "${AMAZON_GLOBAL_TOKEN:-not-generated}" || printf 'http://%s:%s/subscriptions/%s.yaml' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}" "${AMAZON_GLOBAL_TOKEN:-not-generated}")
  Local handoff record:
    ${INSTALL_DIR}/runtime/amazon-global.txt

16) Security hardening checklist
  Applied automatically by the installer:
    - SSH key-only login (only when a root public key was present at install time)
    - fail2ban sshd jail (ufw ban, 5 failures in 10 min -> 1h ban)
    - unattended security updates
    - UFW enabled with default-deny incoming
    - .env and panel database permissions set to 600
    - container core dumps disabled
  Still needs you:
    - Enable two-factor authentication in the 3x-ui panel (panel settings).
    - Verify SSH key login works in a second session before closing this one.
    - If you created a public (0.0.0.0) tunnel forward, remember it has no
      authentication: anyone on the internet can use it. Prefer 127.0.0.1
      unless the forward is meant to be public.
  Re-check any time:
    cd ${INSTALL_DIR}
    ./scripts/manage.sh security-check
EOF
  chmod 600 "$summary"
}

print_install_summary() {
  load_env
  local summary="${INSTALL_DIR}/runtime/install-summary.txt"
  echo
  echo "============================================================"
  echo "  3x-ui deployment complete"
  echo "============================================================"
  cat "$summary"
  echo
  echo "Generated links:"
  if [ -s "${INSTALL_DIR}/runtime/client-links.txt" ]; then
    sed -n '1,120p' "${INSTALL_DIR}/runtime/client-links.txt"
  else
    echo "  No client links generated yet."
  fi
  echo "============================================================"
}

main() {
  need_root
  ensure_base_tools
  run_config_wizard
  ensure_docker
  download_project
  install_cli_shortcut
  write_env
  load_env
  generate_mask_site
  configure_firewall_ports
  harden_ssh
  install_fail2ban
  enable_unattended_upgrades
  compose_up
  if [ "${ENABLE_RUSTDESK:-1}" = "1" ]; then
    log "Installing RustDesk Server OSS."
    (cd "$INSTALL_DIR" && ./scripts/rustdesk.sh install)
  fi
  install_systemd_autostart
  wait_panel_db
  configure_panel
  harden_file_permissions
  start_mask_site
  configure_domains

  if [ "${ENABLE_PRESETS:-1}" = "1" ]; then
    log "Applying protocol presets."
    if ! (cd "$INSTALL_DIR" && ./scripts/apply-presets.sh); then
      log "Protocol presets were not fully applied. The panel credentials will still be printed below."
      log "After the panel is reachable, run: cd ${INSTALL_DIR} && ./scripts/manage.sh apply-presets"
    fi
  fi

  configure_protocol_guard
  configure_xui_builtin_subscription
  configure_subscription
  configure_amazon_global

  write_install_summary
  print_install_summary
  run_security_check
  if [ "${MENU_AFTER_INSTALL:-1}" = "1" ] && tty_available; then
    log "Opening terminal menu. You can run it later with: 3xui-kit"
    "${INSTALL_DIR}/scripts/menu.sh"
  fi
}

main "$@"
