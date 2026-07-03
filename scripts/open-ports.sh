#!/usr/bin/env bash
set -Eeuo pipefail

DRY_RUN=0
DEFAULT_NETWORK="${DEFAULT_NETWORK:-tcp}"
FIREWALL_BACKEND="${FIREWALL_BACKEND:-}"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/open-ports.sh [--dry-run] [-p tcp|udp|tcp,udp] <ports...>

Examples:
  ./scripts/open-ports.sh 80 443 8443-8450
  ./scripts/open-ports.sh 8388/tcp 8388/udp 30000-30100/udp
  ./scripts/open-ports.sh -p tcp,udp 10000,10001,10010-10020

Port formats:
  443              Open 443 with the default protocol, tcp unless -p is set
  443/tcp          Open TCP
  443/udp          Open UDP
  443/both         Open TCP and UDP
  30000-30100/tcp  Open a port range

Environment:
  FIREWALL_BACKEND=ufw|firewalld|iptables  Force a backend
  DEFAULT_NETWORK=tcp|udp|tcp,udp          Default protocol for bare ports
EOF
}

log() {
  printf '[open-ports] %s\n' "$*"
}

die() {
  printf '[open-ports] ERROR: %s\n' "$*" >&2
  exit 1
}

normalize_network() {
  local network="${1:-tcp}"
  network="$(printf '%s' "$network" | tr '[:upper:]' '[:lower:]')"
  network="${network//+/,}"
  case "$network" in
    tcp|udp) printf '%s' "$network" ;;
    both|all|tcp,udp|udp,tcp) printf 'tcp,udp' ;;
    *) die "Network must be tcp, udp, tcp,udp, or both: ${network}" ;;
  esac
}

validate_port_number() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid port: ${port}"
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "Port out of range: ${port}"
}

validate_port_expr() {
  local expr="$1"
  local start end
  if [[ "$expr" =~ ^[0-9]+$ ]]; then
    validate_port_number "$expr"
    return
  fi
  if [[ "$expr" =~ ^[0-9]+-[0-9]+$ ]]; then
    start="${expr%-*}"
    end="${expr#*-}"
    validate_port_number "$start"
    validate_port_number "$end"
    [ "$start" -le "$end" ] || die "Invalid port range: ${expr}"
    return
  fi
  die "Invalid port expression: ${expr}"
}

port_expr_for_ufw() {
  local expr="$1"
  printf '%s' "${expr/-/:}"
}

port_expr_for_iptables() {
  local expr="$1"
  printf '%s' "${expr/-/:}"
}

RULE_PORTS=()
RULE_PROTOS=()

add_rule() {
  local port_expr="$1"
  local proto="$2"
  local i
  for i in "${!RULE_PORTS[@]}"; do
    if [ "${RULE_PORTS[$i]}" = "$port_expr" ] && [ "${RULE_PROTOS[$i]}" = "$proto" ]; then
      return
    fi
  done
  RULE_PORTS+=("$port_expr")
  RULE_PROTOS+=("$proto")
}

split_input_specs() {
  local input="$*"
  input="${input//\/tcp,udp/\/both}"
  input="${input//\/udp,tcp/\/both}"
  input="${input//:tcp,udp/:both}"
  input="${input//:udp,tcp/:both}"
  input="${input//，/,}"
  input="${input//；/;}"
  printf '%s\n' "$input" | tr ' ,;' '\n' | awk 'NF'
}

parse_spec() {
  local spec="$1"
  local port_expr network proto

  case "$spec" in
    */*)
      port_expr="${spec%%/*}"
      network="${spec#*/}"
      ;;
    *:tcp|*:udp|*:both|*:all|*:tcp+udp|*:udp+tcp)
      port_expr="${spec%:*}"
      network="${spec##*:}"
      ;;
    *)
      port_expr="$spec"
      network="$DEFAULT_NETWORK"
      ;;
  esac

  validate_port_expr "$port_expr"
  network="$(normalize_network "$network")"
  case "$network" in
    tcp,udp)
      add_rule "$port_expr" tcp
      add_rule "$port_expr" udp
      ;;
    *)
      add_rule "$port_expr" "$network"
      ;;
  esac
}

detect_backend() {
  if [ -n "$FIREWALL_BACKEND" ]; then
    printf '%s' "$FIREWALL_BACKEND"
    return
  fi
  if command -v ufw >/dev/null 2>&1; then
    printf 'ufw'
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    printf 'firewalld'
  elif command -v iptables >/dev/null 2>&1; then
    printf 'iptables'
  else
    printf 'none'
  fi
}

require_root_unless_dry_run() {
  if [ "$DRY_RUN" = "1" ]; then
    return
  fi
  [ "$(id -u)" -eq 0 ] || die "Please run as root, for example: sudo ./scripts/manage.sh open-ports 443 8443-8450"
}

run_or_print() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '  DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

open_with_ufw() {
  local i port_expr proto ufw_expr status
  for i in "${!RULE_PORTS[@]}"; do
    port_expr="${RULE_PORTS[$i]}"
    proto="${RULE_PROTOS[$i]}"
    ufw_expr="$(port_expr_for_ufw "$port_expr")"
    run_or_print ufw allow "${ufw_expr}/${proto}"
  done
  status="$(ufw status 2>/dev/null | head -1 || true)"
  if printf '%s' "$status" | grep -qi inactive; then
    log "ufw rules were added, but ufw is inactive. Run 'sudo ufw enable' only if you intend to enforce ufw."
  fi
}

open_with_firewalld() {
  local i port_expr proto
  for i in "${!RULE_PORTS[@]}"; do
    port_expr="${RULE_PORTS[$i]}"
    proto="${RULE_PROTOS[$i]}"
    run_or_print firewall-cmd --permanent --add-port="${port_expr}/${proto}"
  done
  run_or_print firewall-cmd --reload
}

open_with_iptables() {
  local i port_expr proto ipt_expr
  for i in "${!RULE_PORTS[@]}"; do
    port_expr="${RULE_PORTS[$i]}"
    proto="${RULE_PROTOS[$i]}"
    ipt_expr="$(port_expr_for_iptables "$port_expr")"
    if [ "$DRY_RUN" = "1" ]; then
      run_or_print iptables -C INPUT -p "$proto" --dport "$ipt_expr" -j ACCEPT
      run_or_print iptables -I INPUT -p "$proto" --dport "$ipt_expr" -j ACCEPT
    elif ! iptables -C INPUT -p "$proto" --dport "$ipt_expr" -j ACCEPT >/dev/null 2>&1; then
      iptables -I INPUT -p "$proto" --dport "$ipt_expr" -j ACCEPT
    fi
  done
  log "iptables rules are runtime rules. Install iptables-persistent or save your rules if this server relies on iptables after reboot."
}

print_rules() {
  local i
  log "Ports to open:"
  for i in "${!RULE_PORTS[@]}"; do
    printf '  - %s/%s\n' "${RULE_PORTS[$i]}" "${RULE_PROTOS[$i]}"
  done
}

main() {
  local args=()
  local specs spec backend
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      -p|--protocol|--network)
        shift
        [ "$#" -gt 0 ] || die "Missing protocol after ${1:-option}"
        DEFAULT_NETWORK="$(normalize_network "$1")"
        ;;
      --)
        shift
        args+=("$@")
        break
        ;;
      *)
        args+=("$1")
        ;;
    esac
    shift
  done

  if [ "${#args[@]}" -eq 0 ]; then
    if [ -r /dev/tty ]; then
      printf 'Enter ports to open, for example 80,443,8443-8450,8388/udp: ' > /dev/tty
      IFS= read -r specs < /dev/tty || specs=""
      [ -n "$specs" ] || die "No ports provided."
      args=("$specs")
    else
      usage
      exit 1
    fi
  fi

  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    parse_spec "$spec"
  done < <(split_input_specs "${args[@]}")

  [ "${#RULE_PORTS[@]}" -gt 0 ] || die "No valid ports provided."
  print_rules
  require_root_unless_dry_run

  backend="$(detect_backend)"
  case "$backend" in
    ufw) open_with_ufw ;;
    firewalld) open_with_firewalld ;;
    iptables) open_with_iptables ;;
    none)
      log "No ufw/firewalld/iptables detected. Open these ports in your VPS firewall/security group:"
      print_rules
      return 0
      ;;
    *) die "Unsupported FIREWALL_BACKEND: ${backend}" ;;
  esac

  log "Done. Also confirm the same ports are allowed in your cloud provider security group if one is enabled."
}

main "$@"
