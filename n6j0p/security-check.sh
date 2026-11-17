#!/usr/bin/env bash
# security-check.sh - read-only security self-check for a 3x-ui selfhost kit install.
#
# Prints one PASS/WARN/FAIL/SKIP/INFO line per check plus a summary. Exits 1
# when any FAIL is present, 0 otherwise (WARN and INFO do not affect the exit
# code; INFO is a note about a possible improvement, not a problem).
#
# This script never modifies anything: it only reads config files, queries
# sshd/ufw/fail2ban/docker status, and opens the panel database read-only.
# Credential values are never printed; database checks only report counts.
#
# Usage:
#   ./scripts/security-check.sh            # check this install
#   ./scripts/manage.sh security-check     # same, via the management script
#
# Test hooks (environment overrides, all optional):
#   KIT_DIR, SSH_CONFIG_DIR, FAIL2BAN_JAIL_DIR, APT_DIR, APT_AUTO_UPGRADES_FILE
set -uo pipefail

KIT_DIR="${KIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SSH_CONFIG_DIR="${SSH_CONFIG_DIR:-/etc/ssh}"
FAIL2BAN_JAIL_DIR="${FAIL2BAN_JAIL_DIR:-/etc/fail2ban/jail.d}"
APT_DIR="${APT_DIR:-/etc/apt}"
APT_AUTO_UPGRADES_FILE="${APT_AUTO_UPGRADES_FILE:-/etc/apt/apt.conf.d/20auto-upgrades}"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
INFO_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '[PASS] %s\n' "$*"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '[WARN] %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[FAIL] %s\n' "$*"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); printf '[SKIP] %s\n' "$*"; }
info() { INFO_COUNT=$((INFO_COUNT + 1)); printf '[INFO] %s\n' "$*"; }

# Read one KEY=value from .env without sourcing it (no code execution).
env_value() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$KIT_DIR/.env" 2>/dev/null || true
}

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || echo "unknown"
}

# --- firewall state (captured once) ---
UFW_AVAILABLE=0
UFW_STATUS_TEXT=""
UFW_STATE="missing"
if command -v ufw >/dev/null 2>&1; then
  UFW_AVAILABLE=1
  UFW_STATUS_TEXT="$(ufw status 2>/dev/null || true)"
  case "$(printf '%s' "$UFW_STATUS_TEXT" | head -n 1)" in
    *"Status: active"*) UFW_STATE="active" ;;
    *) UFW_STATE="inactive" ;;
  esac
fi

# ufw_allows_port <port> [proto]: true when ufw has an ALLOW rule for the port.
ufw_allows_port() {
  local port="$1" proto="${2:-tcp}"
  [ "$UFW_AVAILABLE" = "1" ] || return 1
  printf '%s' "$UFW_STATUS_TEXT" | awk -v p="${port}/${proto}" \
    '$1 == p && ($2 == "ALLOW" || $3 == "ALLOW") { found=1 } END { exit !found }'
}

check_ssh() {
  if ! command -v sshd >/dev/null 2>&1; then
    skip "ssh: sshd is not installed; nothing to check"
    return
  fi
  local eff
  eff="$(sshd -T 2>/dev/null || true)"
  if [ -z "$eff" ]; then
    skip "ssh: could not read effective sshd config (sshd -T failed)"
    return
  fi
  local val
  val="$(printf '%s' "$eff" | awk '$1 == "passwordauthentication" { print tolower($2); exit }')"
  case "$val" in
    no) pass "ssh: password authentication is off" ;;
    *) warn "ssh: password authentication is on (SSH_PASSWORD_AUTH=1 default; use a strong password and keep fail2ban running)" ;;
  esac
  val="$(printf '%s' "$eff" | awk '$1 == "kbdinteractiveauthentication" { print tolower($2); exit }')"
  case "$val" in
    no) pass "ssh: keyboard-interactive authentication is off" ;;
    *) fail "ssh: keyboard-interactive authentication is still on (kbdinteractiveauthentication=${val:-unknown})" ;;
  esac
  val="$(printf '%s' "$eff" | awk '$1 == "permitrootlogin" { print tolower($2); exit }')"
  case "$val" in
    prohibit-password|without-password|forced-commands-only)
      pass "ssh: root login is key-only (permitrootlogin=$val)"
      ;;
    no)
      pass "ssh: root login is disabled (permitrootlogin=no)"
      ;;
    *) warn "ssh: root password login is allowed (permitrootlogin=${val:-unknown}; use a strong root password)" ;;
  esac
  val="$(printf '%s' "$eff" | awk '$1 == "pubkeyauthentication" { print tolower($2); exit }')"
  case "$val" in
    yes) pass "ssh: public key authentication is on" ;;
    *) warn "ssh: public key authentication is off (pubkeyauthentication=${val:-unknown}); key login will not work" ;;
  esac
  val="$(printf '%s' "$eff" | awk '$1 == "maxauthtries" { print $2; exit }')"
  if [ -n "$val" ] && [ "$val" -le 5 ] 2>/dev/null; then
    pass "ssh: max auth tries is $val"
  else
    warn "ssh: max auth tries is ${val:-unknown} (recommended 5 or fewer)"
  fi
  val="$(printf '%s' "$eff" | awk '$1 == "logingracetime" { print $2; exit }')"
  if [ -n "$val" ] && [ "$val" -le 120 ] 2>/dev/null; then
    pass "ssh: login grace time is ${val}s"
  else
    warn "ssh: login grace time is ${val:-unknown} (recommended 120s or less)"
  fi
}

check_firewall() {
  if [ "$UFW_AVAILABLE" != "1" ]; then
    skip "firewall: ufw is not installed; firewall state not verified (check your VPS security group)"
    return
  fi
  if [ "$UFW_STATE" != "active" ]; then
    fail "firewall: ufw is installed but not active (status: ${UFW_STATE})"
    return
  fi
  pass "firewall: ufw is active"
  local panel_port sub_port panel_listen https_site
  panel_port="$(env_value PANEL_PORT)"
  sub_port="$(env_value XUI_BUILTIN_SUB_PORT)"
  panel_listen="$(env_value PANEL_LISTEN_IP)"
  https_site="$(env_value HTTPS_SITE_ENABLE)"
  panel_port="${panel_port:-2053}"
  sub_port="${sub_port:-2096}"
  panel_listen="${panel_listen:-0.0.0.0}"
  if ufw_allows_port "$sub_port" tcp; then
    if [ "${https_site:-0}" = "1" ]; then
      fail "firewall: built-in subscription port ${sub_port}/tcp is allowed (it must stay local-only; Caddy is the public path)"
    else
      warn "firewall: built-in subscription port ${sub_port}/tcp is publicly allowed (no domain for Caddy proxy; HTTP, unencrypted)"
    fi
  else
    pass "firewall: built-in subscription port ${sub_port}/tcp is not publicly allowed"
  fi
  if ufw_allows_port "$panel_port" tcp; then
    case "$panel_listen" in
      127.0.0.1|localhost|::1)
        fail "firewall: panel port ${panel_port}/tcp is allowed but the panel binds ${panel_listen} (remove the rule)"
        ;;
      *)
        warn "firewall: panel port ${panel_port}/tcp is publicly allowed (panel binds ${panel_listen}; prefer domain HTTPS)"
        ;;
    esac
  else
    pass "firewall: panel port ${panel_port}/tcp is not publicly allowed"
  fi
}

check_file_permissions() {
  local mode
  mode="$(file_mode "$KIT_DIR/.env")"
  if [ "$mode" = "600" ]; then
    pass "files: .env permissions are 600"
  else
    fail "files: .env permissions are ${mode} (must be 600)"
  fi
  if [ -f "$KIT_DIR/data/db/x-ui.db" ]; then
    mode="$(file_mode "$KIT_DIR/data/db/x-ui.db")"
    if [ "$mode" = "600" ]; then
      pass "files: x-ui.db permissions are 600"
    else
      fail "files: x-ui.db permissions are ${mode} (must be 600; it holds node credentials)"
    fi
  else
    skip "files: x-ui.db not found yet (panel may not have started)"
  fi
}

check_env_tokens() {
  local value feature
  value="$(env_value PANEL_PASSWORD)"
  if [ -z "$value" ]; then
    fail "tokens: PANEL_PASSWORD is empty in .env"
  elif [ "${#value}" -lt 12 ]; then
    warn "tokens: PANEL_PASSWORD is shorter than 12 characters"
  else
    pass "tokens: PANEL_PASSWORD is set"
  fi
  feature="$(env_value ENABLE_SUBCONVERTER)"
  if [ "${feature:-1}" = "1" ]; then
    value="$(env_value SUBSCRIPTION_TOKEN)"
    if [ -z "$value" ]; then
      fail "tokens: SUBSCRIPTION_TOKEN is empty in .env (subconverter is enabled)"
    else
      pass "tokens: SUBSCRIPTION_TOKEN is set"
    fi
  else
    skip "tokens: subconverter is disabled; SUBSCRIPTION_TOKEN not required"
  fi
  feature="$(env_value ENABLE_SUB_CONFIG_EDITOR)"
  if [ "${feature:-1}" = "1" ]; then
    value="$(env_value SUB_CONFIG_ADMIN_TOKEN)"
    if [ -z "$value" ]; then
      fail "tokens: SUB_CONFIG_ADMIN_TOKEN is empty in .env (config editor is enabled)"
    else
      pass "tokens: SUB_CONFIG_ADMIN_TOKEN is set"
    fi
    # Empty XUI_API_TOKEN breaks the editor's panel API calls; it does not
    # expose anything (the panel API rejects unauthenticated requests), so
    # it is a WARN, not a FAIL.
    value="$(env_value XUI_API_TOKEN)"
    if [ -z "$value" ]; then
      warn "tokens: XUI_API_TOKEN is empty in .env (config editor cannot authenticate to the panel API)"
    else
      pass "tokens: XUI_API_TOKEN is set"
    fi
  else
    skip "tokens: config editor is disabled; SUB_CONFIG_ADMIN_TOKEN not required"
  fi
  feature="$(env_value ENABLE_AMAZON_GLOBAL)"
  if [ "${feature:-0}" = "1" ]; then
    value="$(env_value AMAZON_GLOBAL_TOKEN)"
    if [ -z "$value" ]; then
      fail "tokens: AMAZON_GLOBAL_TOKEN is empty in .env (Amazon global is enabled)"
    else
      pass "tokens: AMAZON_GLOBAL_TOKEN is set"
    fi
  else
    skip "tokens: Amazon global is disabled; AMAZON_GLOBAL_TOKEN not required"
  fi
}

check_panel_db() {
  local db="$KIT_DIR/data/db/x-ui.db"
  if [ ! -f "$db" ]; then
    skip "nodes: x-ui.db not found yet (presets may not have run)"
    skip "panel-2fa: x-ui.db not found yet"
    skip "tunnels: x-ui.db not found yet"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    skip "nodes: python3 is not installed; credential checks need python3"
    skip "panel-2fa: python3 is not installed"
    skip "tunnels: python3 is not installed"
    return
  fi
  local report
  report="$(DB_PATH="$db" python3 - <<'PYEOF' 2>/dev/null || echo "DB_ERROR=1"
import json
import os
import sqlite3

db = os.environ["DB_PATH"]
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
cur = con.cursor()

vless_ids = []
trojan_passwords = []
empty_creds = 0
empty_reality_keys = 0
reality_bad = 0
reality_mismatch = 0
reality_total = 0
reality_non443 = 0
reality_pairs = set()
vmess_count = 0
plaintext_count = 0

try:
    rows = cur.execute(
        "select protocol, port, listen, settings, stream_settings"
        " from inbounds where enable=1"
    ).fetchall()
except Exception:
    rows = []

for protocol, port, listen, settings, stream in rows:
    try:
        s = json.loads(settings) if settings else {}
    except Exception:
        s = {}
    try:
        st = json.loads(stream) if stream else {}
    except Exception:
        st = {}
    if not isinstance(s, dict):
        s = {}
    if not isinstance(st, dict):
        st = {}
    if protocol == "vless":
        for client in s.get("clients", []) or []:
            cid = client.get("id", "") if isinstance(client, dict) else ""
            if not cid:
                empty_creds += 1
            else:
                vless_ids.append(cid)
        sec = st.get("security") or ""
        if sec == "reality":
            reality_total += 1
            reality = st.get("realitySettings", {}) or {}
            # Xray stores the fallback destination as "target"; older configs
            # used "dest". Either key counts.
            target = reality.get("target") or reality.get("dest") or ""
            server_names = reality.get("serverNames") or []
            short_ids = reality.get("shortIds") or []
            if not reality.get("privateKey"):
                empty_reality_keys += 1
            if not target or not server_names or not short_ids:
                reality_bad += 1
            else:
                target_host = str(target).split(":")[0].strip().lower()
                first_sni = str(server_names[0]).strip().lower()
                reality_pairs.add((target, first_sni))
                if target_host and first_sni and target_host != first_sni:
                    reality_mismatch += 1
            if str(port) != "443":
                reality_non443 += 1
        elif sec != "tls":
            # VLESS with no TLS/Reality is plaintext on the wire.
            plaintext_count += 1
    elif protocol == "trojan":
        for client in s.get("clients", []) or []:
            pw = client.get("password", "") if isinstance(client, dict) else ""
            if not pw:
                empty_creds += 1
            else:
                trojan_passwords.append(pw)
        if (st.get("security") or "") not in ("tls", "reality"):
            plaintext_count += 1
    elif protocol == "vmess":
        vmess_count += 1
    elif protocol == "shadowsocks":
        if not s.get("password"):
            empty_creds += 1
    elif protocol == "tunnel":
        print(f"TUNNEL port={port} listen={listen or ''}")

dup_vless = len(vless_ids) - len(set(vless_ids))
dup_trojan = len(trojan_passwords) - len(set(trojan_passwords))

print(f"EMPTY_CREDS={empty_creds}")
print(f"DUP_VLESS={dup_vless}")
print(f"DUP_TROJAN={dup_trojan}")
print(f"EMPTY_REALITY_KEYS={empty_reality_keys}")
print(f"VLESS_CLIENTS={len(vless_ids)}")
print(f"TROJAN_CLIENTS={len(trojan_passwords)}")
print(f"REALITY_BAD={reality_bad}")
print(f"REALITY_MISMATCH={reality_mismatch}")
print(f"REALITY_TOTAL={reality_total}")
print(f"REALITY_NON443={reality_non443}")
print(f"REALITY_ALL_SAME={1 if reality_total >= 2 and len(reality_pairs) == 1 else 0}")
print(f"VMESS_COUNT={vmess_count}")
print(f"PLAINTEXT_COUNT={plaintext_count}")

try:
    row = cur.execute(
        "select value from settings where key='twoFactorEnable'"
    ).fetchone()
    print(f"TWOFACTOR={row[0] if row else ''}")
except Exception:
    print("TWOFACTOR=")
PYEOF
)"
  if printf '%s' "$report" | grep -q "DB_ERROR=1"; then
    skip "nodes: could not read x-ui.db (locked or unreadable)"
    skip "panel-2fa: could not read x-ui.db"
    skip "tunnels: could not read x-ui.db"
    return
  fi
  local empty_creds dup_vless dup_trojan empty_reality twofactor
  empty_creds="$(printf '%s' "$report" | awk -F= '$1 == "EMPTY_CREDS" { print $2 }')"
  dup_vless="$(printf '%s' "$report" | awk -F= '$1 == "DUP_VLESS" { print $2 }')"
  dup_trojan="$(printf '%s' "$report" | awk -F= '$1 == "DUP_TROJAN" { print $2 }')"
  empty_reality="$(printf '%s' "$report" | awk -F= '$1 == "EMPTY_REALITY_KEYS" { print $2 }')"
  twofactor="$(printf '%s' "$report" | awk -F= '$1 == "TWOFACTOR" { print $2 }')"
  if [ "${empty_creds:-0}" != "0" ]; then
    fail "nodes: ${empty_creds} node credential(s) are empty"
  elif [ "${dup_vless:-0}" != "0" ] || [ "${dup_trojan:-0}" != "0" ]; then
    fail "nodes: duplicate credentials found (vless=${dup_vless:-0}, trojan=${dup_trojan:-0}); each node must have its own"
  elif [ "${empty_reality:-0}" != "0" ]; then
    fail "nodes: ${empty_reality} REALITY inbound(s) have an empty private key"
  else
    pass "nodes: no empty or duplicate node credentials"
  fi
  local reality_bad reality_mismatch reality_total reality_non443 reality_all_same vmess_count plaintext_count
  reality_bad="$(printf '%s' "$report" | awk -F= '$1 == "REALITY_BAD" { print $2 }')"
  reality_mismatch="$(printf '%s' "$report" | awk -F= '$1 == "REALITY_MISMATCH" { print $2 }')"
  reality_total="$(printf '%s' "$report" | awk -F= '$1 == "REALITY_TOTAL" { print $2 }')"
  reality_non443="$(printf '%s' "$report" | awk -F= '$1 == "REALITY_NON443" { print $2 }')"
  reality_all_same="$(printf '%s' "$report" | awk -F= '$1 == "REALITY_ALL_SAME" { print $2 }')"
  vmess_count="$(printf '%s' "$report" | awk -F= '$1 == "VMESS_COUNT" { print $2 }')"
  plaintext_count="$(printf '%s' "$report" | awk -F= '$1 == "PLAINTEXT_COUNT" { print $2 }')"
  if [ "${reality_total:-0}" = "0" ]; then
    skip "nodes: no REALITY inbound found"
  elif [ "${reality_bad:-0}" != "0" ]; then
    fail "nodes: ${reality_bad} REALITY inbound(s) are missing dest, serverNames or shortId (they cannot hide as real TLS)"
  else
    pass "nodes: all ${reality_total} REALITY inbound(s) have dest, serverNames and shortId"
  fi
  if [ "${reality_mismatch:-0}" != "0" ]; then
    warn "nodes: ${reality_mismatch} REALITY inbound(s) have a dest host that does not match the first serverName (SNI); the handshake looks inconsistent to a prober"
  fi
  if [ "${reality_all_same:-0}" != "0" ]; then
    warn "nodes: all ${reality_total} REALITY inbound(s) share the same dest/serverNames (rotate dest sites per node so they do not share one fingerprint; recreate nodes to apply)"
  fi
  if [ "${vmess_count:-0}" != "0" ]; then
    fail "nodes: ${vmess_count} VMess inbound(s) are enabled (VMess is deprecated and easy to fingerprint; remove them)"
  else
    pass "nodes: no VMess inbound is enabled"
  fi
  if [ "${plaintext_count:-0}" != "0" ]; then
    fail "nodes: ${plaintext_count} VLESS/Trojan inbound(s) run without TLS or REALITY (plaintext on the wire)"
  else
    pass "nodes: every VLESS/Trojan inbound uses TLS or REALITY"
  fi
  if [ "${reality_non443:-0}" != "0" ]; then
    info "nodes: ${reality_non443} of ${reality_total:-0} REALITY inbound(s) listen on non-443 ports (443 with fallback to the masquerade site is the stealthiest setup; see HANDOFF.md)"
  fi
  case "$twofactor" in
    true|1)
      pass "panel-2fa: two-factor authentication is enabled"
      ;;
    *)
      warn "panel-2fa: two-factor authentication is not enabled (turn it on in the panel)"
      ;;
  esac
  local tunnel_found=0 tunnel_line tport tlisten
  while IFS= read -r tunnel_line; do
    [ -n "$tunnel_line" ] || continue
    tport="$(printf '%s' "$tunnel_line" | sed -n 's/^TUNNEL port=\([0-9]*\) listen=.*/\1/p')"
    tlisten="$(printf '%s' "$tunnel_line" | sed -n 's/^TUNNEL port=[0-9]* listen=\(.*\)/\1/p')"
    case "$tlisten" in
      ""|"0.0.0.0"|"::")
        if ufw_allows_port "$tport" tcp || [ "$UFW_STATE" = "inactive" ]; then
          warn "tunnels: tunnel on ${tlisten:-0.0.0.0}:${tport} is public and reachable (unauthenticated forwarder; anyone can use it)"
          tunnel_found=1
        fi
        ;;
    esac
  done < <(printf '%s' "$report" | grep "^TUNNEL " || true)
  if [ "$tunnel_found" = "0" ]; then
    pass "tunnels: no public unauthenticated tunnel is reachable"
  fi
}

check_fail2ban() {
  local feature
  feature="$(env_value ENABLE_FAIL2BAN)"
  if [ "${feature:-1}" != "1" ]; then
    skip "fail2ban: disabled in .env (ENABLE_FAIL2BAN=${feature})"
    return
  fi
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    warn "fail2ban: enabled in .env but fail2ban is not installed"
    return
  fi
  if fail2ban-client ping >/dev/null 2>&1; then
    if fail2ban-client status sshd >/dev/null 2>&1; then
      pass "fail2ban: running with the sshd jail"
    else
      warn "fail2ban: running but the sshd jail is missing"
    fi
  else
    warn "fail2ban: enabled in .env but the service is not running"
  fi
}

check_unattended_upgrades() {
  local feature
  feature="$(env_value ENABLE_UNATTENDED_UPGRADES)"
  if [ "${feature:-1}" != "1" ]; then
    skip "auto-updates: disabled in .env (ENABLE_UNATTENDED_UPGRADES=${feature})"
    return
  fi
  if [ ! -d "$APT_DIR" ]; then
    skip "auto-updates: not an apt-based system"
    return
  fi
  if [ -f "$APT_AUTO_UPGRADES_FILE" ] && grep -Eq '^\s*APT::Periodic::Unattended-Upgrade\s+"1"\s*;' "$APT_AUTO_UPGRADES_FILE"; then
    pass "auto-updates: unattended-upgrades is enabled (security updates)"
  else
    warn "auto-updates: unattended-upgrades is not enabled (install it to auto-apply security updates)"
  fi
}

check_containers() {
  if ! command -v docker >/dev/null 2>&1; then
    skip "containers: docker is not installed"
    return
  fi
  local names privileged=0 name priv
  names="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
  if [ -z "$names" ]; then
    skip "containers: no running containers found"
    return
  fi
  for name in $names; do
    priv="$(docker inspect -f '{{.HostConfig.Privileged}}' "$name" 2>/dev/null || true)"
    if [ "$priv" = "true" ]; then
      privileged=$((privileged + 1))
    fi
  done
  if [ "$privileged" -gt 0 ]; then
    fail "containers: ${privileged} container(s) run privileged"
  else
    pass "containers: no privileged containers"
  fi
}

main() {
  if [ ! -f "$KIT_DIR/.env" ]; then
    printf '[FAIL] .env not found in %s; run install.sh first.\n' "$KIT_DIR" >&2
    exit 2
  fi
  printf 'security-check: %s\n' "$KIT_DIR"
  check_ssh
  check_firewall
  check_file_permissions
  check_env_tokens
  check_panel_db
  check_fail2ban
  check_unattended_upgrades
  check_containers
  printf 'security-check: %d passed, %d warnings, %d failed, %d skipped, %d info\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$INFO_COUNT"
  if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
  fi
  exit 0
}

main "$@"
