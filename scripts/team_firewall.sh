#!/usr/bin/env bash
set -euo pipefail

# team_firewall.sh
# Conservative host firewall for team-LAN Linux boxes.
# Default is PREVIEW ONLY. To apply rules, run with APPLY=yes.
# Prefers nftables and avoids touching hosts already managed by ufw/firewalld
# unless FORCE=yes.
#
# Example:
#   sudo TEAM_SUBNET=10.9.5.0/24 COMP_SUBNET=10.9.3.0/24 APPLY=yes ./team_firewall.sh
#   sudo APPLY=yes ALLOW_SSH_FROM_COMP=yes BACKUP_BOX_IP=10.9.5.50 ./team_firewall.sh
#   sudo APPLY=yes REQUIRED_TCP_PORTS="25 110 143 993 995" ./team_firewall.sh

APPLY="${APPLY:-no}"
FORCE="${FORCE:-no}"
TEAM_SUBNET="${TEAM_SUBNET:-10.9.5.0/24}"
COMP_SUBNET="${COMP_SUBNET:-10.9.3.0/24}"
ALLOW_SSH_FROM_COMP="${ALLOW_SSH_FROM_COMP:-no}"
BACKUP_BOX_IP="${BACKUP_BOX_IP:-}"
PASSIVE_FTP_RANGE="${PASSIVE_FTP_RANGE:-50000-50100}"
EXTRA_TCP_PORTS="${EXTRA_TCP_PORTS:-}"
EXTRA_UDP_PORTS="${EXTRA_UDP_PORTS:-}"
REQUIRED_TCP_PORTS="${REQUIRED_TCP_PORTS:-}"
REQUIRED_UDP_PORTS="${REQUIRED_UDP_PORTS:-}"
NFT_TABLE="${NFT_TABLE:-bluehost}"

have() { command -v "$1" >/dev/null 2>&1; }
need_root() { [[ "$(id -u)" -eq 0 ]] || { echo "[!] Run as root"; exit 1; }; }
log() { echo "[*] $*"; }
warn() { echo "[!] $*"; }
port_listen_tcp() { ss -tlnH 2>/dev/null | awk '{print $4}' | grep -Eo '([0-9]+)$' | sort -un; }
port_listen_udp() { ss -ulnH 2>/dev/null | awk '{print $5}' | grep -Eo '([0-9]+)$' | sort -un; }
has_tcp() { port_listen_tcp | grep -qx "$1"; }
has_udp() { port_listen_udp | grep -qx "$1"; }
in_list() {
  local needle="$1"
  shift || true
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}
add_tcp() {
  local item="$1"
  in_list "$item" "${TCP_ALLOW[@]}" || TCP_ALLOW+=("$item")
}
add_udp() {
  local item="$1"
  in_list "$item" "${UDP_ALLOW[@]}" || UDP_ALLOW+=("$item")
}
add_tcp_for_team_and_comp() {
  local port="$1"
  add_tcp "team:${port}"
  add_tcp "comp:${port}"
}
add_udp_for_team_and_comp() {
  local port="$1"
  add_udp "team:${port}"
  add_udp "comp:${port}"
}
warn_if_not_listening_tcp() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  has_tcp "$port" || warn "Required TCP port ${port} is not currently listening; adding rule anyway"
}
warn_if_not_listening_udp() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  has_udp "$port" || warn "Required UDP port ${port} is not currently listening; adding rule anyway"
}

need_root

if (systemctl is-active ufw >/dev/null 2>&1 || systemctl is-active firewalld >/dev/null 2>&1) && [[ "$FORCE" != "yes" ]]; then
  warn "ufw or firewalld is active. Refusing to apply direct nftables rules unless FORCE=yes."
  APPLY=no
fi

if ! have nft; then
  echo "[!] nft command not found; install nftables first"
  exit 1
fi

TCP_ALLOW=()
UDP_ALLOW=()

# Always useful from team LAN; SSH from comp LAN is optional.
if has_tcp 22; then
  add_tcp "team:22"
  [[ "$ALLOW_SSH_FROM_COMP" == "yes" ]] && add_tcp "comp:22"
fi

# DNS
if has_tcp 53; then add_tcp_for_team_and_comp 53; fi
if has_udp 53; then add_udp_for_team_and_comp 53; fi

# Web
for p in 80 443 8080 8443; do
  if has_tcp "$p"; then add_tcp_for_team_and_comp "$p"; fi
done

# PostgreSQL / MySQL / MariaDB
for p in 5432 3306; do
  if has_tcp "$p"; then add_tcp_for_team_and_comp "$p"; fi
done

# FTP control/data + passive range (if control port is listening)
if has_tcp 21 || has_tcp 20; then
  add_tcp_for_team_and_comp 20
  add_tcp_for_team_and_comp 21
  add_tcp_for_team_and_comp "${PASSIVE_FTP_RANGE}"
fi
if has_tcp 990; then add_tcp_for_team_and_comp 990; fi

# SMB/CIFS
for p in 139 445; do
  if has_tcp "$p"; then add_tcp_for_team_and_comp "$p"; fi
done
for p in 137 138; do
  if has_udp "$p"; then add_udp_for_team_and_comp "$p"; fi
done

# Backup-ish ports if present
for p in 873 2049 111; do
  if has_tcp "$p"; then
    if [[ -n "$BACKUP_BOX_IP" ]]; then
      add_tcp "backup:$p"
    else
      add_tcp "team:$p"
    fi
  fi
  if has_udp "$p"; then
    if [[ -n "$BACKUP_BOX_IP" ]]; then
      add_udp "backup:$p"
    else
      add_udp "team:$p"
    fi
  fi
done

for p in $REQUIRED_TCP_PORTS; do
  warn_if_not_listening_tcp "$p"
  add_tcp_for_team_and_comp "$p"
done
for p in $REQUIRED_UDP_PORTS; do
  warn_if_not_listening_udp "$p"
  add_udp_for_team_and_comp "$p"
done

for p in $EXTRA_TCP_PORTS; do add_tcp_for_team_and_comp "$p"; done
for p in $EXTRA_UDP_PORTS; do add_udp_for_team_and_comp "$p"; done

echo
log "Previewing allowed inbound rules"
printf '  %-10s %s\n' "scope" "port"
for x in "${TCP_ALLOW[@]}"; do printf '  %-10s %s/tcp\n' "${x%%:*}" "${x#*:}"; done
for x in "${UDP_ALLOW[@]}"; do printf '  %-10s %s/udp\n' "${x%%:*}" "${x#*:}"; done

if [[ -n "$REQUIRED_TCP_PORTS" || -n "$REQUIRED_UDP_PORTS" ]]; then
  echo
  log "Required ports added even if not currently listening"
  [[ -n "$REQUIRED_TCP_PORTS" ]] && echo "  TCP: $REQUIRED_TCP_PORTS"
  [[ -n "$REQUIRED_UDP_PORTS" ]] && echo "  UDP: $REQUIRED_UDP_PORTS"
fi

echo
log "Default policy if applied:"
echo "  - allow loopback"
echo "  - allow established,related"
echo "  - allow ICMP/ICMPv6"
echo "  - allow listed service ports from team/comp scopes"
echo "  - drop all other inbound"
echo "  - allow all outbound"

if [[ "$APPLY" != "yes" ]]; then
  warn "Preview only. Re-run with APPLY=yes to install nftables rules."
  exit 0
fi

mkdir -p /root/firewall-backups
nft list ruleset > "/root/firewall-backups/nft-before-${NFT_TABLE}-$(date +%Y%m%d_%H%M%S).conf" 2>/dev/null || true

RULES_FILE="/etc/nftables.d/${NFT_TABLE}.nft"
mkdir -p /etc/nftables.d

{
  echo "table inet ${NFT_TABLE} {"
  echo "  chain input {"
  echo "    type filter hook input priority 0; policy drop;"
  echo "    iif lo accept"
  echo "    ct state established,related accept"
  echo "    ip protocol icmp accept"
  echo "    ip6 nexthdr ipv6-icmp accept"

  for x in "${TCP_ALLOW[@]}"; do
    scope="${x%%:*}"; port="${x#*:}"
    case "$scope" in
      team) src="$TEAM_SUBNET" ;;
      comp) src="$COMP_SUBNET" ;;
      backup) src="$BACKUP_BOX_IP/32" ;;
      *) continue ;;
    esac
    if [[ "$port" == *-* ]]; then
      start="${port%-*}"; end="${port#*-}"
      echo "    ip saddr ${src} tcp dport ${start}-${end} accept"
    else
      echo "    ip saddr ${src} tcp dport ${port} accept"
    fi
  done

  for x in "${UDP_ALLOW[@]}"; do
    scope="${x%%:*}"; port="${x#*:}"
    case "$scope" in
      team) src="$TEAM_SUBNET" ;;
      comp) src="$COMP_SUBNET" ;;
      backup) src="$BACKUP_BOX_IP/32" ;;
      *) continue ;;
    esac
    if [[ "$port" == *-* ]]; then
      start="${port%-*}"; end="${port#*-}"
      echo "    ip saddr ${src} udp dport ${start}-${end} accept"
    else
      echo "    ip saddr ${src} udp dport ${port} accept"
    fi
  done

  echo "  }"
  echo "  chain forward { type filter hook forward priority 0; policy drop; }"
  echo "  chain output { type filter hook output priority 0; policy accept; }"
  echo "}"
} > "$RULES_FILE"

# Ensure nftables main file includes our rules.
if [[ ! -f /etc/nftables.conf ]]; then
  cat > /etc/nftables.conf <<MAIN
#!/usr/sbin/nft -f
flush ruleset
include "/etc/nftables.d/*.nft"
MAIN
elif ! grep -q '/etc/nftables.d/\*.nft' /etc/nftables.conf; then
  cp -a /etc/nftables.conf "/etc/nftables.conf.bak.$(date +%s)"
  printf '\ninclude "/etc/nftables.d/*.nft"\n' >> /etc/nftables.conf
fi

nft -f /etc/nftables.conf
systemctl enable --now nftables >/dev/null 2>&1 || true

log "Applied nftables rules from $RULES_FILE"
log "Current ruleset for table ${NFT_TABLE}:"
nft list table inet "$NFT_TABLE"
