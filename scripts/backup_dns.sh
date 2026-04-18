#!/bin/bash

set -euo pipefail

# =========================
# CONFIG
# =========================
DNS_SERVER="172.20.0.20"                    # CHANGE FOR COMP: DNS server IP/hostname
BACKUP_DIR="$HOME/backupscripts/backups"    # CHANGE FOR COMP: local backup directory
DNS_CONF="/etc/named.conf"                  # CHANGE FOR COMP: main named config path
DNS_DIR="/var/named"                        # CHANGE FOR COMP: zone/data directory

STAMP=$(date +%F_%H-%M-%S)
BACKUP_FILE="${BACKUP_DIR}/dns_${STAMP}.tar.gz"

mkdir -p "$BACKUP_DIR"

echo "[*] Starting DNS backup from ${DNS_SERVER}"
read -s -p "[*] Enter sudo password for ${DNS_SERVER}: " SUDOPASS
echo

# Create archive remotely and stream it back locally.
ssh "$DNS_SERVER" "echo '$SUDOPASS' | sudo -S tar -czf - '$DNS_CONF' '$DNS_DIR' 2>/dev/null" > "$BACKUP_FILE"

unset SUDOPASS

if [ ! -s "$BACKUP_FILE" ]; then
    echo "[!] Backup failed or file is empty: $BACKUP_FILE"
    exit 1
fi

sha256sum "$BACKUP_FILE" > "${BACKUP_FILE}.sha256"

echo "[+] Backup saved to $BACKUP_FILE"
echo "[+] Hash saved to ${BACKUP_FILE}.sha256"

echo "[*] Archive preview:"
tar -tzf "$BACKUP_FILE" | head -n 20
