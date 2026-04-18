#!/bin/bash

set -euo pipefail

# =========================
# CONFIG
# =========================
DB_SERVER="192.168.12.7"    # CHANGE FOR COMP: DB server IP/hostname
DB_NAME="ncae"            # CHANGE FOR COMP: PostgreSQL database name

if [ $# -ne 1 ]; then
    echo "Usage: $0 /path/to/backup.sql or /path/to/backup.sql.gz"
    exit 1
fi

INPUT_FILE="$1"

if [ ! -f "$INPUT_FILE" ]; then
    echo "[!] File not found: $INPUT_FILE"
    exit 1
fi

read -s -p "[*] Enter sudo password for ${DB_SERVER}: " SUDOPASS
echo

BASENAME=$(basename "$INPUT_FILE")
REMOTE_FILE="/tmp/$BASENAME"

echo "[*] Copying backup to ${DB_SERVER}:${REMOTE_FILE}"
cat "$INPUT_FILE" | ssh "$DB_SERVER" "cat > '$REMOTE_FILE'"

echo "[*] Starting restore on ${DB_SERVER}"

if [[ "$REMOTE_FILE" == *.gz ]]; then
    ssh "$DB_SERVER" "echo '$SUDOPASS' | sudo -S bash -c 'gunzip -c \"$REMOTE_FILE\" | sudo -u postgres psql \"$DB_NAME\"; rm -f \"$REMOTE_FILE\"'"
else
    ssh "$DB_SERVER" "echo '$SUDOPASS' | sudo -S bash -c 'sudo -u postgres psql \"$DB_NAME\" < \"$REMOTE_FILE\"; rm -f \"$REMOTE_FILE\"'"
fi

unset SUDOPASS

echo "[+] Restore finished"
