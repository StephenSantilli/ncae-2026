#!/bin/bash

set -euo pipefail

# =========================
# CONFIG
# =========================
DNS_SERVER="192.168.12.5"                    # CHANGE FOR COMP: DNS server IP/hostname
SERVICE_NAME="named"                        # CHANGE FOR COMP: service name (named or bind9)
BACKUP_DIR="$HOME/backupscripts/backups"    # CHANGE FOR COMP: local backup directory

if [ $# -gt 1 ]; then
    echo "Usage: $0 [optional path to dns_backup.tar.gz]"
    exit 1
fi

if [ $# -eq 1 ]; then
    INPUT_FILE="$1"
else
    INPUT_FILE=$(ls -t "$BACKUP_DIR"/dns_*.tar.gz 2>/dev/null | head -n 1 || true)
    if [ -z "$INPUT_FILE" ]; then
        echo "[!] No DNS backups found in $BACKUP_DIR"
        exit 1
    fi
    echo "[*] No backup file specified, using latest: $INPUT_FILE"
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "[!] File not found: $INPUT_FILE"
    exit 1
fi

read -s -p "[*] Enter sudo password for ${DNS_SERVER}: " SUDOPASS
echo

BASENAME=$(basename "$INPUT_FILE")
REMOTE_FILE="/tmp/$BASENAME"

echo "[*] Copying backup to ${DNS_SERVER}:${REMOTE_FILE}"
cat "$INPUT_FILE" | ssh "$DNS_SERVER" "cat > '$REMOTE_FILE'"

echo "[*] Restoring DNS files on ${DNS_SERVER}"
ssh "$DNS_SERVER" "echo '$SUDOPASS' | sudo -S bash -c 'tar -xzf \"$REMOTE_FILE\" -C / && rm -f \"$REMOTE_FILE\"'"

echo "[*] Validating named configuration"
ssh "$DNS_SERVER" "echo '$SUDOPASS' | sudo -S named-checkconf /etc/named.conf"

echo "[*] Restarting DNS service"
ssh "$DNS_SERVER" "echo '$SUDOPASS' | sudo -S systemctl restart '$SERVICE_NAME'"

unset SUDOPASS

echo "[+] DNS restore finished"
