#!/bin/bash
set -euo pipefail

# ==========================================
# CHANGE THESE AT COMP START
# ==========================================
REMOTE_USER="blueteam"
REMOTE_HOST="172.20.0.5"
BACKUP_NAME="web"
# ==========================================

BACKUP_BASE="/srv/backups"
BACKUP_ROOT="${BACKUP_BASE}/${BACKUP_NAME}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SNAPSHOT_DIR="${BACKUP_ROOT}/${TIMESTAMP}"

log() {
    echo "[*] $1"
}

warn() {
    echo "[!] $1" >&2
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[!] Missing command: $1" >&2
        exit 1
    }
}

lock_snapshot() {
    local dir="$1"

    sudo chown -R root:root "$dir"
    sudo chmod -R a-w "$dir"
    sudo find "$dir" -type d -exec chmod 755 {} \;
    sudo find "$dir" -type f -exec chmod 444 {} \;

    if command -v chattr >/dev/null 2>&1; then
        sudo chattr -R +i "$dir" || warn "Could not set immutable flag"
    fi
}
main() {
    require_cmd ssh
    require_cmd rsync
    require_cmd mkdir
    require_cmd find
    require_cmd sha256sum

    sudo mkdir -p "${SNAPSHOT_DIR}"
    sudo chown -R "$USER:$USER" "${BACKUP_ROOT}"

    log "Target: ${REMOTE_HOST}"
    log "Snapshot: ${SNAPSHOT_DIR}"

    log "Backing up /var/www..."
    mkdir -p "${SNAPSHOT_DIR}/var"
    rsync -av "${REMOTE_USER}@${REMOTE_HOST}:/var/www" "${SNAPSHOT_DIR}/var/"

    log "Backing up /etc/nginx..."
    mkdir -p "${SNAPSHOT_DIR}/etc"
    rsync -av "${REMOTE_USER}@${REMOTE_HOST}:/etc/nginx" "${SNAPSHOT_DIR}/etc/"

    log "Backing up /home/${REMOTE_USER}..."
    mkdir -p "${SNAPSHOT_DIR}/home"
    rsync -av "${REMOTE_USER}@${REMOTE_HOST}:/home/${REMOTE_USER}" "${SNAPSHOT_DIR}/home/"

    log "Creating checksum manifest..."
    (
        cd "${SNAPSHOT_DIR}"
        find . -type f ! -name "SHA256SUMS" -exec sha256sum {} \; | sort > SHA256SUMS
    )                                                                       
    log "Locking snapshot..."
    lock_snapshot "${SNAPSHOT_DIR}"

    log "Updating latest symlink..."
    sudo ln -sfn "${SNAPSHOT_DIR}" "${BACKUP_ROOT}/latest"

    log "Backup complete."
    log "Snapshot saved to: ${SNAPSHOT_DIR}"
    log "Latest symlink: ${BACKUP_ROOT}/latest"
}

main "$@"
