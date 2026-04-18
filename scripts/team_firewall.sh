#!/usr/bin/env bash
set -euo pipefail

# team_firewall.sh
# General-purpose UFW helper for competition Linux hosts.
#
# Design goals:
#   - use UFW instead of direct nftables
#   - default to preview mode
#   - avoid subnet-specific assumptions
#   - avoid breaking services by default
#   - only switch to default-deny if explicitly requested
#
# Examples:
#   sudo ./team_firewall.sh
#   sudo APPLY=yes ./team_firewall.sh
#   sudo APPLY=yes REQUIRED_TCP_PORTS="25 110 143 993 995" ./team_firewall.sh
#   sudo APPLY=yes ALLOW_FROM_CIDRS="10.9.5.0/24 10.9.3.0/24" ./team_firewall.sh
#   sudo APPLY=yes LOCKDOWN=yes REQUIRED_TCP_PORTS="22 80 443" ./team_firewall.sh

APPLY="${APPLY:-no}"
FORCE="${FORCE:-no}"
LOCKDOWN="${LOCKDOWN:-no}"
ALLOW_FROM_CIDRS="${ALLOW_FROM_CIDRS:-any}"
REQUIRED_TCP_PORTS="${REQUIRED_TCP_PORTS:-}"
REQUIRED_UDP_PORTS="${REQUIRED_UDP_PORTS:-}"
EXTRA_TCP_PORTS="${EXTRA_TCP_PORTS:-}"
EXTRA_UDP_PORTS="${EXTRA_UDP_PORTS:-}"

have() { command -v "$1" >/dev/null 2>&1; }
need_root() { [[ "$(id -u)" -eq 0 ]] || { echo "[!] Run as root"; exit 1; }; }
log() { echo "[*] $*"; }
warn() { echo "[!] $*"; }

port_listen_tcp() { ss -tlnH 2>/dev/null | awk '{print $4}' | grep -Eo '([0-9]+)$' | sort -un || true; }
port_listen_udp() { ss -ulnH 2>/dev/null | awk '{print $5}' | grep -Eo '([0-9]+)$' | sort -un || true; }

in_list() {
  local needle="$1"
  shift || true
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

add_unique() {
  local value="$1"
  local array_name="$2"
  local current=()
  eval "current=(\"\${${array_name}[@]}\")"
  if ! in_list "$value" "${current[@]}"; then
    eval "${array_name}+=(\"\$value\")"
  fi
}

is_single_port() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

normalize_port_for_ufw() {
  local port="$1"
  echo "${port//-/:}"
}

warn_if_not_listening() {
  local proto="$1"
  local port="$2"
  if ! is_single_port "$port"; then
    return 0
  fi

  if [[ "$proto" == "tcp" ]]; then
    port_listen_tcp | grep -qx "$port" || warn "Required TCP port ${port} is not currently listening; adding rule anyway"
  else
    port_listen_udp | grep -qx "$port" || warn "Required UDP port ${port} is not currently listening; adding rule anyway"
  fi
}

ufw_is_active() {
  ufw status 2>/dev/null | grep -q "^Status: active"
}

ensure_ufw_ready() {
  if ! have ufw; then
    echo "[!] ufw command not found; install ufw first"
    exit 1
  fi

  if systemctl is-active firewalld >/dev/null 2>&1 && [[ "$FORCE" != "yes" ]]; then
    warn "firewalld is active. Refusing to mix firewall managers unless FORCE=yes."
    exit 1
  fi
}

preview_rule() {
  local proto="$1"
  local port="$2"
  local source="$3"
  if [[ "$source" == "any" ]]; then
    printf '  ufw allow %s/%s\n' "$(normalize_port_for_ufw "$port")" "$proto"
  else
    printf '  ufw allow proto %s from %s to any port %s\n' "$proto" "$source" "$(normalize_port_for_ufw "$port")"
  fi
}

apply_rule() {
  local proto="$1"
  local port="$2"
  local source="$3"
  local ufw_port
  ufw_port="$(normalize_port_for_ufw "$port")"

  if [[ "$source" == "any" ]]; then
    ufw allow "${ufw_port}/${proto}" >/dev/null
  else
    ufw allow proto "$proto" from "$source" to any port "$ufw_port" >/dev/null
  fi
}

need_root
ensure_ufw_ready

TCP_PORTS=()
UDP_PORTS=()

while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  add_unique "$p" TCP_PORTS
done < <(port_listen_tcp)

while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  add_unique "$p" UDP_PORTS
done < <(port_listen_udp)

for p in $REQUIRED_TCP_PORTS; do
  warn_if_not_listening tcp "$p"
  add_unique "$p" TCP_PORTS
done
for p in $REQUIRED_UDP_PORTS; do
  warn_if_not_listening udp "$p"
  add_unique "$p" UDP_PORTS
done
for p in $EXTRA_TCP_PORTS; do add_unique "$p" TCP_PORTS; done
for p in $EXTRA_UDP_PORTS; do add_unique "$p" UDP_PORTS; done

SOURCES=()
if [[ "$ALLOW_FROM_CIDRS" == "any" ]]; then
  SOURCES=("any")
else
  for cidr in $ALLOW_FROM_CIDRS; do
    add_unique "$cidr" SOURCES
  done
fi

echo
log "Previewing UFW rules to add"
printf '  %-8s %s\n' "proto" "port"
for p in "${TCP_PORTS[@]}"; do printf '  %-8s %s\n' "tcp" "$p"; done
for p in "${UDP_PORTS[@]}"; do printf '  %-8s %s\n' "udp" "$p"; done

echo
log "Rule source scope"
if [[ "${SOURCES[0]}" == "any" ]]; then
  echo "  - allow from anywhere"
else
  for src in "${SOURCES[@]}"; do
    echo "  - allow from ${src}"
  done
fi

echo
log "Policy behavior if applied"
if ufw_is_active; then
  echo "  - preserve current UFW default policies"
else
  echo "  - enable UFW with default allow incoming"
  echo "  - enable UFW with default allow outgoing"
fi
if [[ "$LOCKDOWN" == "yes" ]]; then
  echo "  - set default deny incoming"
  echo "  - set default allow outgoing"
else
  echo "  - do not switch to default deny unless LOCKDOWN=yes"
fi

echo
log "Commands that will be run"
if ! ufw_is_active; then
  echo "  ufw default allow incoming"
  echo "  ufw default allow outgoing"
  echo "  ufw --force enable"
fi
if [[ "$LOCKDOWN" == "yes" ]]; then
  echo "  ufw default deny incoming"
  echo "  ufw default allow outgoing"
fi
for src in "${SOURCES[@]}"; do
  for p in "${TCP_PORTS[@]}"; do preview_rule tcp "$p" "$src"; done
  for p in "${UDP_PORTS[@]}"; do preview_rule udp "$p" "$src"; done
done

if [[ "$APPLY" != "yes" ]]; then
  warn "Preview only. Re-run with APPLY=yes to apply UFW rules."
  exit 0
fi

mkdir -p /root/firewall-backups
ufw status verbose > "/root/firewall-backups/ufw-status-before-$(date +%Y%m%d_%H%M%S).txt" 2>/dev/null || true
cp -a /etc/ufw "/root/firewall-backups/ufw-etc-$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true

if ! ufw_is_active; then
  warn "UFW is inactive; enabling it with default allow policies first to avoid accidental lockout"
  ufw default allow incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw --force enable >/dev/null
fi

if [[ "$LOCKDOWN" == "yes" ]]; then
  warn "LOCKDOWN=yes set; switching default incoming policy to deny"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
fi

for src in "${SOURCES[@]}"; do
  for p in "${TCP_PORTS[@]}"; do apply_rule tcp "$p" "$src"; done
  for p in "${UDP_PORTS[@]}"; do apply_rule udp "$p" "$src"; done
done

ufw reload >/dev/null || true

log "Applied UFW rules"
ufw status verbose
