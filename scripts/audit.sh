#!/usr/bin/env bash
set -euo pipefail

# Targets: Ubuntu / Rocky / Kali
#
# Optional env vars:
#   DO_UPDATE=yes
#   LOCK_UNKNOWN_USERS=yes
#   REMOVE_UNKNOWN_SSH=yes
#
# Edit TEAM_ADMIN_USERS before using aggressive flags.

TEAM_ADMIN_USERS=(
  root
  blueteam
)

DISABLE_IF_PRESENT=(
  telnet.socket
  telnet
  ftp
  vsftpd
  tftp
  tftp.socket
  rsh.socket
  rexec.socket
  rlogin.socket
  xinetd
  avahi-daemon
  cups
  rpcbind
)

SUSPICIOUS_NAME_REGEX='telemetry|updater|sync|agent|beacon|persist|healthcheck|backdoor|remote|shell'

TS="$(date +%Y%m%d_%H%M%S)"
HOST="$(hostname 2>/dev/null || echo unknown)"
FQDN="$(hostname -f 2>/dev/null || echo unknown)"
USER_NOW="$(whoami 2>/dev/null || echo unknown)"
BACKUP_DIR="/root/hardening-backup-${HOST}-${TS}"
REPORT="${BACKUP_DIR}/report.txt"

mkdir -p "$BACKUP_DIR"

have() {
    command -v "$1" >/dev/null 2>&1
}

print_header() {
    echo
    echo "== $1 =="
}

log() {
    echo "[*] $*" | tee -a "$REPORT"
}

warn() {
    echo "[!] $*" | tee -a "$REPORT"
}

SUDO=""
if have sudo && sudo -n true 2>/dev/null; then
    SUDO="sudo"
fi

is_allowed_user() {
    local u="$1"
    for a in "${TEAM_ADMIN_USERS[@]}"; do
        [[ "$u" == "$a" ]] && return 0
    done
    return 1
}

backup_file() {
    local f="$1"
    if [[ -e "$f" ]]; then
        mkdir -p "$BACKUP_DIR$(dirname "$f")"
        cp -a "$f" "$BACKUP_DIR$f"
    fi
}

backup_glob_dir() {
    local d="$1"
    if [[ -e "$d" ]]; then
        mkdir -p "$BACKUP_DIR$(dirname "$d")"
        cp -a "$d" "$BACKUP_DIR$d"
    fi
}

detect_os() {
    OS_FAMILY="unknown"
    OS_NAME="unknown"
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME="${PRETTY_NAME:-unknown}"
        case "${ID_LIKE:-$ID}" in
            *debian*|*ubuntu*|debian|ubuntu|kali)
                OS_FAMILY="debian"
                ;;
            *rhel*|*fedora*|rocky|rhel|centos|fedora)
                OS_FAMILY="rhel"
                ;;
        esac
    fi
    log "Detected OS: $OS_NAME ($OS_FAMILY)"
}

preflight() {
    log "Creating backup dir: $BACKUP_DIR"

    backup_file /etc/passwd
    backup_file /etc/shadow
    backup_file /etc/group
    backup_file /etc/gshadow
    backup_file /etc/sudoers
    backup_glob_dir /etc/sudoers.d
    backup_file /etc/crontab
    backup_glob_dir /etc/cron.d
    backup_glob_dir /etc/cron.daily
    backup_glob_dir /etc/cron.hourly
    backup_glob_dir /etc/cron.weekly
    backup_glob_dir /etc/cron.monthly
    backup_glob_dir /etc/systemd/system
    backup_file /etc/rc.local
    backup_file /etc/profile
    backup_file /etc/bash.bashrc
    backup_glob_dir /etc/profile.d
    backup_file /etc/environment
    backup_file /etc/hosts
    backup_file /etc/resolv.conf
    backup_file /etc/ssh/sshd_config
    backup_glob_dir /etc/ssh/sshd_config.d

    if have systemctl; then
        systemctl list-unit-files --state=enabled > "${BACKUP_DIR}/enabled-unit-files.txt" 2>/dev/null || true
        systemctl list-timers --all > "${BACKUP_DIR}/timers.txt" 2>/dev/null || true
        systemctl --failed > "${BACKUP_DIR}/failed-units.txt" 2>/dev/null || true
    fi

    getent passwd > "${BACKUP_DIR}/passwd.getent.txt" || true
    getent group > "${BACKUP_DIR}/group.getent.txt" || true
    crontab -l > "${BACKUP_DIR}/current-user-crontab.txt" 2>/dev/null || true
    if [[ -n "$SUDO" ]]; then
        $SUDO crontab -l > "${BACKUP_DIR}/root-crontab.txt" 2>/dev/null || true
    fi
}

show_system_summary() {
    print_header "SYSTEM"
    echo "Host:      $HOST"
    echo "FQDN:      $FQDN"
    echo "User:      $USER_NOW"
    echo "Time:      $(date)"
    echo "Kernel:    $(uname -srmo 2>/dev/null || uname -a)"
    echo "OS:        ${OS_NAME:-unknown}"
    echo "Uptime:    $(uptime -p 2>/dev/null || uptime 2>/dev/null || echo unknown)"
}

show_network_summary() {
    print_header "NETWORK"
    echo "Addresses:"
    ip -brief addr 2>/dev/null | sed 's/^/  /' || echo "  unavailable"

    echo
    echo "Routes:"
    ip route 2>/dev/null | sed 's/^/  /' || echo "  unavailable"

    local gw
    gw="$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')"
    if [[ -n "${gw:-}" ]]; then
        echo
        echo "Default gateway: $gw"
        if have ping; then
            if ping -c 1 -W 1 "$gw" >/dev/null 2>&1; then
                echo "Gateway ping:    OK"
            else
                echo "Gateway ping:    FAIL"
            fi
        fi
    fi

    if have resolvectl; then
        local dns_servers
        dns_servers="$(resolvectl status 2>/dev/null | awk '/DNS Servers:/ {for (i=3;i<=NF;i++) print $i}' | xargs)"
        echo "DNS servers:     ${dns_servers:-unknown}"
    elif [[ -f /etc/resolv.conf ]]; then
        local dns_servers
        dns_servers="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | xargs)"
        echo "DNS servers:     ${dns_servers:-unknown}"
    fi
}

show_listening_ports() {
    print_header "LISTENING PORTS"
    if have ss; then
        ss -tulpn 2>/dev/null | awk 'NR==1 || /LISTEN|UNCONN/' | sed 's/^/  /'
    else
        echo "  ss not available"
    fi
}

show_failed_services() {
    print_header "FAILED SERVICES"
    if have systemctl; then
        local failed_units
        failed_units="$(systemctl --failed --no-legend 2>/dev/null || true)"
        if [[ -n "${failed_units:-}" ]]; then
            echo "$failed_units" | sed 's/^/  /'
        else
            echo "  None"
        fi
    else
        echo "  systemctl not available"
    fi
}

show_user_admin_summary() {
    print_header "USERS / ADMINS"
    echo "Current admin groups:"
    getent group sudo 2>/dev/null | sed 's/^/  /' || true
    getent group wheel 2>/dev/null | sed 's/^/  /' || true

    echo
    echo "Recently logged in:"
    last -a 2>/dev/null | head -10 | sed 's/^/  /' || echo "  unavailable"

    {
        echo
        echo "===== USERS UID >= 1000 ====="
        awk -F: '$3 >= 1000 && $1 != "nobody" {printf "%-20s uid=%-6s shell=%s\n",$1,$3,$7}' /etc/passwd
        echo
        echo "===== UID 0 USERS ====="
        awk -F: '$3 == 0 {print $1}' /etc/passwd
        echo
        echo "===== ADMIN GROUP MEMBERS ====="
        getent group sudo 2>/dev/null || true
        getent group wheel 2>/dev/null || true
    } >> "$REPORT"
}

show_ssh_summary() {
    print_header "SSH"
    if [[ -f /etc/ssh/sshd_config ]]; then
        echo "Relevant sshd settings:"
        grep -h -Ei '^[[:space:]]*(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|usepam|allowusers|allowgroups|denyusers|denygroups|authorizedkeyscommand|authorizedkeysfile|port)[[:space:]]+' \
            /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | sed 's/^/  /' || echo "  no matching settings found"
    else
        echo "  sshd_config not found"
    fi
}

show_cron_timer_summary() {
    print_header "CRON / TIMERS"
    if have systemctl; then
        echo "Active timers:"
        systemctl list-timers --all --no-pager 2>/dev/null | head -15 | sed 's/^/  /'
    fi

    echo
    echo "Cron directories:"
    find /etc/cron* -maxdepth 2 -type f 2>/dev/null | sort | head -20 | sed 's/^/  /'
}

show_disk_memory_summary() {
    print_header "DISK / MEMORY"
    echo "Disk:"
    df -h 2>/dev/null | sed 's/^/  /'

    echo
    echo "Memory:"
    free -h 2>/dev/null | sed 's/^/  /' || echo "  free not available"
}

show_suspicious_quick_hits() {
    print_header "SUSPICIOUS QUICK HITS"
    echo "Interesting files under /tmp /var/tmp /opt /var/www:"
    find /tmp /var/tmp /opt /var/www -maxdepth 2 2>/dev/null | head -30 | sed 's/^/  /'

    echo
    echo "SSH dirs under /home:"
    find /home -maxdepth 3 -path '*/.ssh*' 2>/dev/null | sed 's/^/  /'
}

show_journal_summary() {
    print_header "JOURNAL ERRORS"
    if have journalctl; then
        ${SUDO:+$SUDO }journalctl -p 3 -xb --no-pager 2>/dev/null | tail -20 | sed 's/^/  /'
    else
        echo "  journalctl not available"
    fi
}

fix_core_permissions() {
    log "Fixing core file permissions"

    chmod 644 /etc/passwd 2>/dev/null || true
    chown root:root /etc/passwd 2>/dev/null || true

    chmod 644 /etc/group 2>/dev/null || true
    chown root:root /etc/group 2>/dev/null || true

    chmod 640 /etc/shadow 2>/dev/null || true
    chown root:shadow /etc/shadow 2>/dev/null || chown root:root /etc/shadow 2>/dev/null || true

    [[ -f /etc/gshadow ]] && chmod 640 /etc/gshadow 2>/dev/null || true
    [[ -f /etc/gshadow ]] && chown root:shadow /etc/gshadow 2>/dev/null || chown root:root /etc/gshadow 2>/dev/null || true

    [[ -f /etc/sudoers ]] && chmod 440 /etc/sudoers 2>/dev/null || true
    [[ -f /etc/sudoers ]] && chown root:root /etc/sudoers 2>/dev/null || true
}

audit_users_and_admins() {
    log "Auditing users and admin groups"

    if [[ "${LOCK_UNKNOWN_USERS:-no}" == "yes" ]]; then
        log "Locking non-allowlisted human users"
        while IFS=: read -r username _ uid _ _ _ shell; do
            [[ "$uid" -lt 1000 ]] && continue
            [[ "$username" == "nobody" ]] && continue
            [[ "$shell" == */nologin || "$shell" == */false ]] && continue

            if ! is_allowed_user "$username"; then
                passwd -l "$username" 2>/dev/null || true
                usermod -s /sbin/nologin "$username" 2>/dev/null || usermod -s /usr/sbin/nologin "$username" 2>/dev/null || true
                warn "Locked user: $username"
            fi
        done < /etc/passwd
    fi
}

cleanup_sudoers_dropins() {
    log "Auditing /etc/sudoers and /etc/sudoers.d"

    if [[ -d /etc/sudoers.d ]]; then
        find /etc/sudoers.d -maxdepth 1 -type f | while read -r f; do
            warn "sudoers.d file present: $f"
            {
                echo
                echo "===== $f ====="
                sed -n '1,200p' "$f"
            } >> "$REPORT" 2>/dev/null || true
        done
    fi
}

audit_cron_and_timers() {
    log "Auditing cron and timers"

    {
        echo
        echo "===== CRON FILES ====="
        find /etc/cron* -maxdepth 2 -type f 2>/dev/null | sort
        echo
        echo "===== ROOT CRONTAB ====="
        crontab -l 2>/dev/null || true
        echo
        echo "===== USER CRONTABS ====="
        for u in $(awk -F: '$3 >= 1000 {print $1}' /etc/passwd); do
            echo "--- $u ---"
            crontab -u "$u" -l 2>/dev/null || true
        done
        echo
        echo "===== SYSTEMD TIMERS ====="
        systemctl list-timers --all --no-pager 2>/dev/null || true
    } >> "$REPORT"

    log "Flagging suspicious cron/timer/unit names"
    grep -RniE "$SUSPICIOUS_NAME_REGEX" /etc/cron* /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system 2>/dev/null | tee -a "$REPORT" || true
}

disable_unneeded_services() {
    log "Disabling common unnecessary services if present"
    for svc in "${DISABLE_IF_PRESENT[@]}"; do
        if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "$svc"; then
            systemctl disable --now "$svc" 2>/dev/null || true
            warn "Disabled service: $svc"
        fi
    done
}

audit_enabled_services() {
    log "Listing enabled services"
    systemctl list-unit-files --state=enabled --no-pager 2>/dev/null | tee -a "$REPORT" || true
}

check_shell_init_files() {
    log "Auditing shell init files for aliases/functions/suspicious commands"
    local files=(
        /etc/profile
        /etc/bash.bashrc
        /etc/environment
        /etc/profile.d/*.sh
        /root/.bashrc
        /root/.profile
        /home/*/.bashrc
        /home/*/.profile
    )

    for f in "${files[@]}"; do
        for real in $f; do
            [[ -f "$real" ]] || continue
            if grep -niE 'alias |function |[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)|curl|wget|nc |ncat|socat|/dev/tcp|python.*socket|perl.*socket|ruby.*socket' "$real" >/dev/null 2>&1; then
                warn "Suspicious shell init content: $real"
                grep -niE 'alias |function |[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)|curl|wget|nc |ncat|socat|/dev/tcp|python.*socket|perl.*socket|ruby.*socket' "$real" | tee -a "$REPORT" || true
            fi
        done
    done
}

audit_interesting_paths() {
    log "Auditing interesting paths"
    {
        echo
        echo "===== /tmp /var/tmp /opt /var/www ====="
        find /tmp /var/tmp /opt /var/www -maxdepth 3 2>/dev/null | sort
        echo
        echo "===== SSH DIRS ====="
        find /root /home -maxdepth 3 -path '*/.ssh*' 2>/dev/null | sort
    } >> "$REPORT"
}

remove_unknown_ssh_dirs() {
    if [[ "${REMOVE_UNKNOWN_SSH:-no}" != "yes" ]]; then
        return
    fi

    log "Removing .ssh directories for non-allowlisted human users"
    for homedir in /home/*; do
        [[ -d "$homedir" ]] || continue
        localuser="$(basename "$homedir")"
        if ! is_allowed_user "$localuser"; then
            rm -rf "$homedir/.ssh"
            warn "Removed .ssh for $localuser"
        fi
    done
}

find_suid_in_writable_areas() {
    log "Finding SUID/SGID files in writable/temp-ish locations"
    find /tmp /var/tmp /dev/shm /opt -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | tee -a "$REPORT" || true
}

find_world_writable() {
    log "Finding world-writable files outside obvious temp areas"
    find / -xdev -type f -perm -0002 \
        ! -path '/proc/*' ! -path '/sys/*' ! -path '/dev/*' \
        ! -path '/tmp/*' ! -path '/var/tmp/*' 2>/dev/null | head -200 | tee -a "$REPORT" || true
}

find_deleted_exec_processes() {
    log "Checking for processes with deleted executables"
    ls -l /proc/*/exe 2>/dev/null | grep '(deleted)' | tee -a "$REPORT" || true
}

find_suspicious_processes() {
    log "Checking for suspicious process patterns"
    ps aux | grep -E 'nc[[:space:]].*-[ec]|ncat[[:space:]]|bash.*\/dev\/tcp|sh.*\/dev\/tcp|python.*socket|perl.*socket|ruby.*socket|socat' | grep -v grep | tee -a "$REPORT" || true
}

show_top_processes() {
    {
        echo
        echo "===== TOP CPU ====="
        ps aux --sort=-%cpu | head -20
        echo
        echo "===== TOP MEM ====="
        ps aux --sort=-%mem | head -20
    } >> "$REPORT"
}

show_logs() {
    if have journalctl; then
        {
            echo
            echo "===== JOURNAL ERRORS ====="
            journalctl -p 3 -xb --no-pager | tail -100
            echo
            echo "===== SSH JOURNAL ====="
            journalctl -u sshd --since '24 hours ago' --no-pager 2>/dev/null | tail -100 || true
            journalctl -u ssh --since '24 hours ago' --no-pager 2>/dev/null | tail -100 || true
        } >> "$REPORT"
    fi
}

optional_updates() {
    if [[ "${DO_UPDATE:-no}" != "yes" ]]; then
        log "Skipping package updates"
        return
    fi

    log "Running package updates"
    if [[ "$OS_FAMILY" == "debian" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get upgrade -y
    elif [[ "$OS_FAMILY" == "rhel" ]]; then
        dnf update -y
    else
        warn "Unknown OS family; skipping updates"
    fi
}

show_followup_commands() {
    print_header "FOLLOW-UP COMMANDS"
    cat <<'EOF'
Processes:
  ps aux --sort=-%cpu | head -30
  ps aux --sort=-%mem | head -30
  ps auxf
  sudo lsof -i -P -n

Systemd:
  systemctl --failed
  systemctl list-unit-files --state=enabled
  systemctl list-timers --all
  systemctl status <service>
  journalctl -u <service> --since "1 hour ago"

Network:
  ss -tulpn
  ip a
  ip r
  ip route get 8.8.8.8
  ping -c 3 <gateway>
  curl -I http://127.0.0.1
  sudo tcpdump -ni any port 22

Users / auth:
  getent passwd
  getent group sudo
  getent group wheel
  last -a | head -20
  lastb -a | head -20
  sudo grep -R . /etc/sudoers /etc/sudoers.d 2>/dev/null
  sudo find /home -maxdepth 3 -path '*/.ssh/*' -ls 2>/dev/null

SSH:
  sudo sshd -T | sort
  sudo journalctl -u sshd --since "24 hours ago"
  sudo ls -la /home/<user>/.ssh
  sudo grep -n '' /home/<user>/.ssh/authorized_keys

Cron / persistence:
  sudo find /etc/cron* -maxdepth 2 -type f -print
  sudo crontab -l
  crontab -l
  sudo find /etc/systemd/system -maxdepth 3 -type f | sort

Suspicious files:
  sudo find /tmp /var/tmp /opt /var/www -maxdepth 3 -ls 2>/dev/null
  sudo find / -xdev -name '*telemetry*' -o -name '*agent*' -o -name '*backup*' 2>/dev/null

Packages / ownership:
  rpm -qf /path/to/file        # Rocky
  dpkg -S /path/to/file       # Ubuntu/Kali
EOF
}

final_summary() {
    log "Hardening complete"
    {
        echo
        echo "===== FINAL SUMMARY ====="
        echo "Backups: $BACKUP_DIR"
        echo
        echo "Review these manually:"
        echo "  - /etc/sudoers and /etc/sudoers.d"
        echo "  - cron files and systemd timers"
        echo "  - listening ports"
        echo "  - suspicious shell init content"
        echo "  - unexpected users / admin group members"
        echo
        echo "Useful follow-up commands are printed in terminal below."
    } | tee -a "$REPORT"
}

main() {
    [[ "$(id -u)" -eq 0 ]] || { echo "[!] Run as root"; exit 1; }

    detect_os
    preflight

    show_system_summary
    show_network_summary
    show_listening_ports
    show_failed_services
    show_user_admin_summary
    show_ssh_summary
    show_cron_timer_summary
    show_disk_memory_summary
    show_suspicious_quick_hits
    show_journal_summary

    fix_core_permissions
    audit_users_and_admins
    cleanup_sudoers_dropins
    audit_cron_and_timers
    disable_unneeded_services
    audit_enabled_services
    check_shell_init_files
    audit_interesting_paths
    remove_unknown_ssh_dirs
    find_suid_in_writable_areas
    find_world_writable
    find_deleted_exec_processes
    find_suspicious_processes
    show_top_processes
    show_logs
    optional_updates
    final_summary
    show_followup_commands
}

main "$@"