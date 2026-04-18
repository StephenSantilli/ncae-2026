#!/bin/bash
set -euo pipefail

# ==========================================
# CHANGE THESE AT COMP START
# ==========================================
REMOTE_USER="blueteam"
REMOTE_HOST="192.168.12.5"
BACKUP_NAME="web"
# ==========================================

BACKUP_ROOT="/srv/backups/${BACKUP_NAME}/latest"
STAGE_NGINX_DIR="/home/${REMOTE_USER}/restore_staging/nginx"
STAGE_WWW_DIR="/home/${REMOTE_USER}/restore_staging/www"

log() {
    echo "[*] $1"
}

warn() {
    echo "[!] $1" >&2
}

main() {
    log "Target: ${REMOTE_HOST}"
    log "Using backup: ${BACKUP_ROOT}"

    if [ ! -d "${BACKUP_ROOT}" ]; then
        warn "Backup root not found: ${BACKUP_ROOT}"
        exit 1
    fi

    # Restore /var/www if possible, otherwise stage it
    if [ -d "${BACKUP_ROOT}/var/www" ]; then
        log "Attempting /var/www restore..."

        if rsync -av --delete \
            "${BACKUP_ROOT}/var/www/" \
            "${REMOTE_USER}@${REMOTE_HOST}:/var/www/"; then

            log "Direct restore of /var/www succeeded"

        else
            warn "Direct restore failed — staging web files instead"
            ssh "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '${STAGE_WWW_DIR}'"

            rsync -av --delete \
                "${BACKUP_ROOT}/var/www/" \
                "${REMOTE_USER}@${REMOTE_HOST}:${STAGE_WWW_DIR}/"

            warn "Web files staged at: ${STAGE_WWW_DIR}"
        fi
    else
        warn "No /var/www in backup"
    fi

    # Restore user home
    if [ -d "${BACKUP_ROOT}/home/${REMOTE_USER}" ]; then
        log "Restoring /home/${REMOTE_USER}..."
        rsync -av \
            "${BACKUP_ROOT}/home/${REMOTE_USER}/" \
            "${REMOTE_USER}@${REMOTE_HOST}:/home/${REMOTE_USER}/"
    else
        warn "No /home/${REMOTE_USER} in backup"
    fi

    # Restore /etc/nginx if possible, otherwise stage it
    if [ -d "${BACKUP_ROOT}/etc/nginx" ]; then
        log "Attempting /etc/nginx restore..."

        if rsync -av \
            "${BACKUP_ROOT}/etc/nginx/" \
            "${REMOTE_USER}@${REMOTE_HOST}:/etc/nginx/"; then

            log "Nginx config restored successfully"

        else
            warn "Direct restore failed — staging nginx config instead"
            ssh "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '${STAGE_NGINX_DIR}'"

            rsync -av --delete \
                "${BACKUP_ROOT}/etc/nginx/" \
                "${REMOTE_USER}@${REMOTE_HOST}:${STAGE_NGINX_DIR}/"

            warn "Nginx config staged at: ${STAGE_NGINX_DIR}"
        fi
    else
        warn "No /etc/nginx in backup"
    fi

    log "Restore complete"
}
main "$@"
