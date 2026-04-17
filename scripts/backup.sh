#Repurposed backup script from Cedarville
#!/bin/bash
set -euo pipefail

# =========================
# Config
# =========================
TEAM_NUM="20"
BACKUP_USER="backups"
BACKUP_HOST="192.168.${TEAM_NUM}.15"
REMOTE_BASE_DIR="~/backups"
LOCAL_DIR="/root/backups"
SSH_KEY="/root/backup_key"

# Directories to back up
BACKUP_PATHS=(
  "/etc"
  "/home"
  "/var/log"
  "/lib/systemd"
  "/usr/lib/systemd"
  "/usr/bin"
  "/usr/sbin"
)

# =========================
# Helpers
# =========================
log_msg() {
  echo "[*] $1"
}

err_msg() {
  echo "[!] $1" >&2
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err_msg "You must run this script as root."
    exit 1
  fi
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err_msg "Required command not found: $cmd"
    exit 1
  fi
}

validate_environment() {
  require_root
  require_command rsync
  require_command ssh
  require_command scp
  require_command hostname

  if [ ! -f "$SSH_KEY" ]; then
    err_msg "SSH key not found at $SSH_KEY"
    exit 1
  fi

  chmod 600 "$SSH_KEY"

  mkdir -p "$LOCAL_DIR"
}

dir_short_name() {
  case "$1" in
    /etc) echo "etc" ;;
    /home) echo "home" ;;
    /var/log) echo "var_log" ;;
    /lib/systemd) echo "lib_systemd" ;;
    /usr/lib/systemd) echo "usr_lib_systemd" ;;
    /usr/bin) echo "usr_bin" ;;
    /usr/sbin) echo "usr_sbin" ;;
    *)
      # fallback: turn /path/like/this into path_like_this
      echo "$1" | sed 's#^/##; s#/#_#g'
      ;;
  esac
}

remote_target() {
  local host_name
  host_name="$(hostname)"
  echo "${BACKUP_USER}@${BACKUP_HOST}:${REMOTE_BASE_DIR}/${host_name}"
}

test_ssh() {
  log_msg "Testing SSH access to ${BACKUP_USER}@${BACKUP_HOST}..."
  ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
    "${BACKUP_USER}@${BACKUP_HOST}" "echo connected" >/dev/null
}

ensure_remote_dir() {
  local host_name
  host_name="$(hostname)"
  log_msg "Ensuring remote directory exists..."
  ssh -i "$SSH_KEY" \
    "${BACKUP_USER}@${BACKUP_HOST}" \
    "mkdir -p ${REMOTE_BASE_DIR}/${host_name}"
}

# =========================
# Backup functions
# =========================
local_backup() {
  local src="$1"
  local short_name
  local log_file

  if [ ! -e "$src" ]; then
    err_msg "Source path does not exist: $src"
    return 1
  fi

  short_name="$(dir_short_name "$src")"
  log_file="${LOCAL_DIR}/${short_name}_backup.txt"

  log_msg "Backing up $src locally..."
  rsync -a-bv --delete \
    --log-file="$log_file" \
    "$src" "$LOCAL_DIR/" >/dev/null

  printf "\n\nSEARCHABLE TEXT\n\n\n" >> "$log_file"
}

remote_backup() {
  local log_file
  local remote_dir

  log_file="${LOCAL_DIR}/curr_backup.txt"
  remote_dir="$(remote_target)"

  log_msg "Syncing local backups to remote server..."
  rsync -a-bv --delete \
    --log-file="$log_file" \
    -e "ssh -i $SSH_KEY" \
    "${LOCAL_DIR}/" "${remote_dir}/" >/dev/null

  printf "\n\nSEARCHABLE TEXT\n\n\n" >> "$log_file"

  log_msg "Uploading current run log..."
  scp -i "$SSH_KEY" "$log_file" "${remote_dir}/curr_backup.txt" >/dev/null
}

# =========================
# Main
# =========================
main() {
  validate_environment
  test_ssh
  ensure_remote_dir

  for path in "${BACKUP_PATHS[@]}"; do
    local_backup "$path"
  done

  remote_backup
  log_msg "Backup completed successfully."
}

main "$@"
