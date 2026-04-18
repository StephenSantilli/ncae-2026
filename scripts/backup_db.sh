#!/bin/bash

set -euo pipefail

# =========================
# CONFIG
# =========================
DB_SERVER="192.168.12.7"                     # CHANGE FOR COMP: DB server IP/hostname
DB_NAME="ncae"                            # CHANGE FOR COMP: PostgreSQL database name
BACKUP_DIR="$HOME/backupscripts/backups"  # CHANGE FOR COMP: where backups should be stored

STAMP=$(date +%F_%H-%M-%S)
BACKUP_FILE="${BACKUP_DIR}/${DB_NAME}_${STAMP}.sql"

mkdir -p "$BACKUP_DIR"

echo "[*] Starting backup of ${DB_NAME} from ${DB_SERVER}"

# Prompt locally so the password is visible to the user.
read -s -p "[*] Enter sudo password for ${DB_SERVER}: " SUDOPASS
echo

# Run pg_dump remotely as postgres and save locally.
ssh "$DB_SERVER" "echo '$SUDOPASS' | sudo -S -u postgres pg_dump '$DB_NAME'" > "$BACKUP_FILE"

# Clear password variable from shell memory.
unset SUDOPASS

# Basic validation: file exists and is not empty.
if [ ! -s "$BACKUP_FILE" ]; then
    echo "[!] Backup failed or file is empty: $BACKUP_FILE"
    exit 1
fi

# Check whether this looks like a PostgreSQL dump.
if ! head -n 5 "$BACKUP_FILE" | grep -q "PostgreSQL database dump"; then
    echo "[!] Backup file does not look like a valid PostgreSQL dump"
    exit 1
fi

# Compress and hash the backup.
gzip -f "$BACKUP_FILE"
sha256sum "${BACKUP_FILE}.gz" > "${BACKUP_FILE}.gz.sha256"

echo "[+] Backup saved to ${BACKUP_FILE}.gz"
echo "[+] Hash saved to ${BACKUP_FILE}.gz.sha256"

# Optional warning if the dump contains no actual tables.
if ! zcat "${BACKUP_FILE}.gz" | grep -q "CREATE TABLE"; then
    echo "[!] WARNING: Backup contains no CREATE TABLE statements."
    echo "[!] This usually means the database is empty or the wrong DB was dumped."
fi
