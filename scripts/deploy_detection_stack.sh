#!/usr/bin/env bash
set -euo pipefail

# deploy_detection_stack.sh
#
# Deploys:
#   - kernel/sysctl hardening baseline
#   - fail2ban (Cedarville-style ssh jail defaults)
#   - AIDE file integrity monitoring
#   - auditd rules for critical files/actions
#   - Lynis
#
# Targets: Ubuntu / Debian / Kali / Rocky / RHEL-family
#
# Optional env vars:
#   DO_UPDATE=yes
#   SSH_PORT=22
#   F2B_MAXRETRY=3
#   F2B_BANTIME=3600
#   F2B_FINDTIME=600
#   F2B_IGNOREIP="127.0.0.1/8 ::1 10.9.5.0/24"
#   AIDE_CRON_SCHEDULE="*/10 * * * *"
#   ENABLE_WEB_JAILS=yes
#   AIDE_EXTRA_PATHS="/srv /data"
#   HARDEN_SHM=yes
#
# Notes:
#   - AIDE and auditd are complementary.
#   - This script avoids touching sshd_config and host firewall rules.
#   - Cedarville's public repo currently provides fail2ban deployment,
#     auditing, and a tmux watchdog. The AIDE/auditd pieces here are custom
#     but follow the same competition-oriented style.

SSH_PORT="${SSH_PORT:-22}"
F2B_MAXRETRY="${F2B_MAXRETRY:-3}"
F2B_BANTIME="${F2B_BANTIME:-3600}"
F2B_FINDTIME="${F2B_FINDTIME:-600}"
F2B_IGNOREIP="${F2B_IGNOREIP:-127.0.0.1/8 ::1}"
AIDE_CRON_SCHEDULE="${AIDE_CRON_SCHEDULE:-*/10 * * * *}"
ENABLE_WEB_JAILS="${ENABLE_WEB_JAILS:-no}"
DO_UPDATE="${DO_UPDATE:-no}"
AIDE_EXTRA_PATHS="${AIDE_EXTRA_PATHS:-}"
HARDEN_SHM="${HARDEN_SHM:-no}"

TS="$(date +%Y%m%d_%H%M%S)"
HOST="$(hostname 2>/dev/null || echo unknown)"
BACKUP_DIR="/root/detection-stack-backup-${HOST}-${TS}"
LOG="${BACKUP_DIR}/deploy.log"
mkdir -p "$BACKUP_DIR"

log() {
  echo "[*] $*" | tee -a "$LOG"
}

warn() {
  echo "[!] $*" | tee -a "$LOG"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "[!] Run as root"
    exit 1
  fi
}

detect_os() {
  OS_FAMILY="unknown"
  OS_NAME="unknown"
  PKG_INSTALL=""
  PKG_UPDATE=""
  PKG_QUERY=""

  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME="${PRETTY_NAME:-unknown}"
    case "${ID_LIKE:-$ID}" in
      *debian*|*ubuntu*|debian|ubuntu|kali)
        OS_FAMILY="debian"
        PKG_INSTALL="apt-get install -y"
        PKG_UPDATE="apt-get update -y"
        PKG_QUERY="dpkg -s"
        ;;
      *rhel*|*fedora*|rocky|rhel|centos|fedora)
        OS_FAMILY="rhel"
        if have dnf; then
          PKG_INSTALL="dnf install -y"
          PKG_UPDATE="dnf makecache"
        else
          PKG_INSTALL="yum install -y"
          PKG_UPDATE="yum makecache"
        fi
        PKG_QUERY="rpm -q"
        ;;
    esac
  fi

  log "Detected OS: $OS_NAME ($OS_FAMILY)"
  if [[ "$OS_FAMILY" == "unknown" ]]; then
    warn "Unsupported OS family"
    exit 1
  fi
}

backup_file() {
  local f="$1"
  if [[ -e "$f" ]]; then
    mkdir -p "$BACKUP_DIR$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR$f"
  fi
}

backup_paths() {
  log "Backing up relevant files"
  backup_file /etc/sysctl.conf
  backup_file /etc/aide/aide.conf
  backup_file /etc/fail2ban/jail.conf
  backup_file /etc/fail2ban/jail.local
  backup_file /etc/audit/auditd.conf
  backup_file /etc/audit/rules.d/audit.rules
  backup_file /etc/audit/rules.d/99-blue-team.rules
  backup_file /etc/cron.d/aide-check
  backup_file /etc/cron.d/aide-integrity
  backup_file /etc/cron.d/aide-blue
  backup_file /etc/os-release
  backup_file /etc/fstab
  backup_file /etc/modprobe.d/99-blue-hardening.conf
  backup_file /etc/security/limits.d/99-auditd.conf
  mkdir -p "$BACKUP_DIR/state"
  systemctl list-unit-files > "$BACKUP_DIR/state/unit-files.txt" 2>/dev/null || true
  systemctl list-timers --all > "$BACKUP_DIR/state/timers.txt" 2>/dev/null || true
}

maybe_update() {
  if [[ "$DO_UPDATE" == "yes" ]]; then
    log "Updating package metadata"
    eval "$PKG_UPDATE" | tee -a "$LOG"
  fi
}

install_packages() {
  log "Installing packages"
  if [[ "$OS_FAMILY" == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    eval "$PKG_UPDATE" >> "$LOG" 2>&1 || true
    eval "$PKG_INSTALL fail2ban aide auditd lynis curl ca-certificates" | tee -a "$LOG"
  else
    if ! rpm -q epel-release >/dev/null 2>&1; then
      eval "$PKG_INSTALL epel-release" | tee -a "$LOG" || true
    fi
    eval "$PKG_UPDATE" >> "$LOG" 2>&1 || true
    eval "$PKG_INSTALL fail2ban aide audit lynis curl ca-certificates" | tee -a "$LOG"
  fi
}

apply_sysctl_hardening() {
  log "Applying kernel/sysctl hardening baseline"
  local sysctl_file="/etc/sysctl.d/99-blue-detection-hardening.conf"
  backup_file "$sysctl_file"
  cat > "$sysctl_file" <<'SYSCTL_EOF'
# blue team kernel hardening baseline
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
kernel.perf_event_paranoid = 3
kernel.core_uses_pid = 1
kernel.sysrq = 0
kernel.modules_disabled = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
vm.mmap_min_addr = 65536
SYSCTL_EOF

  local modprobe_file="/etc/modprobe.d/99-blue-hardening.conf"
  backup_file "$modprobe_file"
  cat > "$modprobe_file" <<'MODPROBE_EOF'
# Disable uncommon filesystems often abused for staging or lateral movement.
install cramfs /bin/false
install freevxfs /bin/false
install jffs2 /bin/false
install hfs /bin/false
install hfsplus /bin/false
install squashfs /bin/false
install udf /bin/false
MODPROBE_EOF

  sysctl --system | tee -a "$LOG"
}

maybe_harden_shm() {
  if [[ "$HARDEN_SHM" != "yes" ]]; then
    log "Skipping shared-memory mount hardening; set HARDEN_SHM=yes to enable /dev/shm noexec,nosuid,nodev"
    return
  fi

  if ! grep -qE '[[:space:]]/dev/shm[[:space:]]' /proc/mounts 2>/dev/null; then
    warn "/dev/shm is not mounted; skipping shared-memory hardening"
    return
  fi

  if grep -qE '^[[:space:]]*[^#]+[[:space:]]+/run/shm[[:space:]]+tmpfs[[:space:]]+' /etc/fstab 2>/dev/null; then
    warn "Legacy /run/shm entry found in /etc/fstab; leaving it unchanged to avoid mount conflicts"
    return
  fi

  if grep -qE '^[[:space:]]*[^#]+[[:space:]]+/dev/shm[[:space:]]+tmpfs[[:space:]]+' /etc/fstab 2>/dev/null; then
    local dev_shm_entry
    dev_shm_entry="$(grep -E '^[[:space:]]*[^#]+[[:space:]]+/dev/shm[[:space:]]+tmpfs[[:space:]]+' /etc/fstab 2>/dev/null | head -n 1 || true)"
    if [[ "$dev_shm_entry" == *noexec* && "$dev_shm_entry" == *nosuid* && "$dev_shm_entry" == *nodev* ]]; then
      log "/dev/shm entry in /etc/fstab already includes noexec,nosuid,nodev"
    else
      warn "Existing /dev/shm entry found in /etc/fstab; not rewriting it automatically"
    fi
  else
    echo 'tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0' >> /etc/fstab
    log "Added /dev/shm noexec,nosuid,nodev mount to /etc/fstab"
  fi

  if mount -o remount,noexec,nosuid,nodev /dev/shm >> "$LOG" 2>&1; then
    log "Remounted /dev/shm with noexec,nosuid,nodev"
  else
    warn "Could not remount /dev/shm; check $LOG"
  fi
}

configure_fail2ban() {
  log "Configuring fail2ban"
  mkdir -p /etc/fail2ban
  local auth_log apache_error apache_access nginx_error
  auth_log=$(test -f /var/log/auth.log && echo /var/log/auth.log || echo /var/log/secure)
  apache_error=$(test -f /var/log/apache2/error.log && echo /var/log/apache2/error.log || echo /var/log/httpd/error_log)
  apache_access=$(test -f /var/log/apache2/access.log && echo /var/log/apache2/access.log || echo /var/log/httpd/access_log)
  nginx_error=$(test -f /var/log/nginx/error.log && echo /var/log/nginx/error.log || echo /var/log/nginx/error.log)

  cat > /etc/fail2ban/jail.local <<EOF2
[DEFAULT]
bantime = ${F2B_BANTIME}
findtime = ${F2B_FINDTIME}
maxretry = ${F2B_MAXRETRY}
ignoreip = ${F2B_IGNOREIP}

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = ${auth_log}
maxretry = ${F2B_MAXRETRY}
bantime = ${F2B_BANTIME}
findtime = ${F2B_FINDTIME}

[apache-auth]
enabled = false
port = http,https
filter = apache-auth
logpath = ${apache_error}
maxretry = 6

[apache-badbots]
enabled = false
port = http,https
filter = apache-badbots
logpath = ${apache_access}
maxretry = 2

[nginx-http-auth]
enabled = false
port = http,https
filter = nginx-http-auth
logpath = ${nginx_error}
maxretry = 6
EOF2

  if [[ "$ENABLE_WEB_JAILS" == "yes" ]]; then
    sed -i 's/^enabled = false/enabled = true/' /etc/fail2ban/jail.local
    sed -i '0,/\[sshd\]/{s/enabled = true/enabled = true/}' /etc/fail2ban/jail.local
  fi

  if [[ ! -f /var/log/auth.log && ! -f /var/log/secure ]]; then
    sed -i 's/^\[sshd\]/[sshd]\nbackend = systemd/' /etc/fail2ban/jail.local
  fi

  log "fail2ban ignoreip: ${F2B_IGNOREIP}"
  systemctl enable --now fail2ban
  sleep 2
  fail2ban-client status | tee -a "$LOG" || true
}

configure_aide() {
  log "Configuring AIDE"
  local aide_conf="/etc/aide/aide.conf"
  if [[ ! -f "$aide_conf" ]]; then
    warn "AIDE config not found after install"
    return
  fi

  backup_file "$aide_conf"
  cp "$aide_conf" "${aide_conf}.dist.${TS}" || true

  cat > "$aide_conf" <<'AIDE_EOF'
@@define DBDIR /var/lib/aide
@@define LOGDIR /var/log/aide

database=file:@@{DBDIR}/aide.db.gz
database_out=file:@@{DBDIR}/aide.db.new.gz
gzip_dbout=yes
verbose=5
report_url=file:@@{LOGDIR}/aide-report.log
report_url=stdout

NORMAL = p+i+n+u+g+s+m+c+sha256
DIR = p+i+n+u+g
PERMS = p+u+g+acl+xattrs
LOG = p+u+g+n+S
DATAONLY = p+n+u+g+s+sha256

!/dev
!/proc
!/run
!/sys
!/tmp
!/var/tmp
!/var/cache

/bin            NORMAL
/sbin           NORMAL
/usr/bin        NORMAL
/usr/sbin       NORMAL
/usr/lib        NORMAL
/usr/lib64      NORMAL
/etc            NORMAL
/boot           NORMAL
/root           PERMS
/var/www        DATAONLY
/var/spool/cron NORMAL
/etc/cron.d     NORMAL
/etc/systemd/system NORMAL
/etc/ssh        NORMAL
/etc/sudoers    NORMAL
/etc/sudoers.d  NORMAL
/etc/passwd     NORMAL
/etc/group      NORMAL
/etc/shadow     NORMAL
/etc/gshadow    NORMAL
/var/log        LOG
AIDE_EOF

  if [[ -n "$AIDE_EXTRA_PATHS" ]]; then
    for p in $AIDE_EXTRA_PATHS; do
      echo "$p DATAONLY" >> "$aide_conf"
    done
  fi

  mkdir -p /var/log/aide
  chmod 700 /var/log/aide

  log "Initializing AIDE baseline (this may take time)"
  if aide --init >> "$LOG" 2>&1; then
    if [[ -f /var/lib/aide/aide.db.new.gz ]]; then
      cp /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
    elif [[ -f /var/lib/aide/aide.db.new ]]; then
      cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
    fi
  else
    warn "AIDE init reported errors; check $LOG"
  fi

  cat > /usr/local/bin/aide-check-blue.sh <<'AIDECHK'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p /var/log/aide
LOGFILE=/var/log/aide/aide-check.log
{
  echo "===== $(date) ====="
  aide --check
  echo
} >> "$LOGFILE" 2>&1
AIDECHK
  chmod 750 /usr/local/bin/aide-check-blue.sh

  cat > /etc/cron.d/aide-blue <<EOF2
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${AIDE_CRON_SCHEDULE} root /usr/local/bin/aide-check-blue.sh
EOF2
}

configure_auditd() {
  log "Configuring auditd"
  mkdir -p /etc/audit/rules.d
  local rules_file="/etc/audit/rules.d/99-blue-team.rules"
  backup_file "$rules_file"

  cat > "$rules_file" <<'AUDIT_EOF'
## blue team audit rules
-D
-b 8192
-f 1

# Identity and auth files
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity

# Sudo and privilege escalation
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d -p wa -k sudoers
-a always,exit -F arch=b64 -S execve -F euid=0 -k rootcmd
-a always,exit -F arch=b32 -S execve -F euid=0 -k rootcmd

# SSH and remote access
-w /etc/ssh/sshd_config -p wa -k ssh
-w /etc/ssh/sshd_config.d -p wa -k ssh
-w /root/.ssh -p wa -k ssh
-w /home -p wa -k ssh_home

# Persistence
-w /etc/crontab -p wa -k cron
-w /etc/cron.d -p wa -k cron
-w /etc/cron.daily -p wa -k cron
-w /etc/cron.hourly -p wa -k cron
-w /etc/cron.weekly -p wa -k cron
-w /etc/cron.monthly -p wa -k cron
-w /var/spool/cron -p wa -k cron
-w /etc/systemd/system -p wa -k systemd
-w /usr/lib/systemd/system -p wa -k systemd
-w /lib/systemd/system -p wa -k systemd
-w /etc/rc.local -p wa -k rc_local

# Web content / staging / modules
-w /var/www -p wa -k web
-w /tmp -p wa -k tmpwrite
-w /var/tmp -p wa -k tmpwrite
-w /dev/shm -p wa -k tmpwrite
-w /etc/ld.so.preload -p wa -k preload
-w /sbin/insmod -p x -k module
-w /sbin/rmmod -p x -k module
-w /sbin/modprobe -p x -k module
-w /usr/bin/kmod -p x -k module

# Sensitive admin commands
-w /usr/sbin/useradd -p x -k usermgmt
-w /usr/sbin/userdel -p x -k usermgmt
-w /usr/sbin/usermod -p x -k usermgmt
-w /usr/bin/passwd -p x -k passwd
-w /usr/bin/chsh -p x -k passwd
-w /usr/bin/chfn -p x -k passwd
-w /usr/bin/chage -p x -k passwd
-w /usr/bin/su -p x -k priv_esc
-w /usr/bin/sudo -p x -k priv_esc
-w /usr/bin/ssh -p x -k remote_exec
-w /usr/bin/scp -p x -k remote_exec
-w /usr/bin/sftp -p x -k remote_exec
-w /usr/bin/curl -p x -k nettools
-w /usr/bin/wget -p x -k nettools
-w /usr/bin/nc -p x -k nettools
-w /usr/bin/ncat -p x -k nettools
-w /usr/bin/socat -p x -k nettools
AUDIT_EOF

  if have augenrules; then
    augenrules --load | tee -a "$LOG" || true
  fi
  systemctl enable --now auditd
  sleep 2
  auditctl -s | tee -a "$LOG" || true
}

configure_lynis() {
  log "Checking Lynis installation"
  if ! have lynis; then
    warn "Lynis binary not found after install"
    return
  fi
  lynis show version 2>/dev/null | tee -a "$LOG" || lynis --version 2>/dev/null | tee -a "$LOG" || true
}

post_status() {
  log "Deployment complete"
  {
    echo
    echo "===== SUMMARY ====="
    echo "Backups: $BACKUP_DIR"
    echo
    echo "fail2ban:"
    fail2ban-client status 2>/dev/null || true
    echo
    echo "auditd:"
    auditctl -s 2>/dev/null || true
    echo
    echo "AIDE DB:"
    ls /var/lib/aide/aide.db* 2>/dev/null || true
    echo
    echo "Lynis:"
    command -v lynis 2>/dev/null || true
  } | tee -a "$LOG"

  echo
  echo "Run these next:"
  echo "  sudo lynis audit system"
  echo "  sudo fail2ban-client status sshd"
  echo "  sudo ausearch -k ssh -ts recent"
  echo "  sudo ausearch -k sudoers -ts recent"
  echo "  sudo aide --check"
  echo "  sudo tail -f /var/log/aide/aide-check.log"
}

main() {
  require_root
  detect_os
  backup_paths
  maybe_update
  install_packages
  apply_sysctl_hardening
  maybe_harden_shm
  configure_fail2ban
  configure_aide
  configure_auditd
  configure_lynis
  post_status
}

main "$@"
