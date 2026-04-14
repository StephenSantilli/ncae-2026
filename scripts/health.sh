#!/usr/bin/env bash
set -u

have() {
    command -v "$1" >/dev/null 2>&1
}

print_header() {
    echo
    echo "== $1 =="
}

run_quiet() {
    "$@" 2>/dev/null
}

SUDO=""
if have sudo && sudo -n true 2>/dev/null; then
    SUDO="sudo"
fi

HOST="$(hostname 2>/dev/null || echo unknown)"
FQDN="$(hostname -f 2>/dev/null || echo unknown)"
USER_NOW="$(whoami 2>/dev/null || echo unknown)"

print_header "SYSTEM"
echo "Host:      $HOST"
echo "FQDN:      $FQDN"
echo "User:      $USER_NOW"
echo "Time:      $(date)"
echo "Kernel:    $(uname -srmo 2>/dev/null)"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "OS:        ${PRETTY_NAME:-unknown}"
fi

echo "Uptime:    $(uptime -p 2>/dev/null || uptime 2>/dev/null || echo unknown)"

print_header "NETWORK"
echo "Addresses:"
ip -brief addr 2>/dev/null | sed 's/^/  /'

echo
echo "Routes:"
ip route 2>/dev/null | sed 's/^/  /'

GW="$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')"
if [[ -n "${GW:-}" ]]; then
    echo
    echo "Default gateway: $GW"
    if have ping; then
        if ping -c 1 -W 1 "$GW" >/dev/null 2>&1; then
            echo "Gateway ping:    OK"
        else
            echo "Gateway ping:    FAIL"
        fi
    fi
fi

if have resolvectl; then
    DNS_SERVERS="$(resolvectl status 2>/dev/null | awk '/DNS Servers:/ {for (i=3;i<=NF;i++) print $i}' | xargs)"
    echo "DNS servers:     ${DNS_SERVERS:-unknown}"
elif [[ -f /etc/resolv.conf ]]; then
    DNS_SERVERS="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | xargs)"
    echo "DNS servers:     ${DNS_SERVERS:-unknown}"
fi

print_header "LISTENING PORTS"
if have ss; then
    ss -tulpn 2>/dev/null | awk 'NR==1 || /LISTEN|UNCONN/' | sed 's/^/  /'
else
    echo "  ss not available"
fi

print_header "FAILED SERVICES"
if have systemctl; then
    FAILED_UNITS="$(systemctl --failed --no-legend 2>/dev/null)"
    if [[ -n "${FAILED_UNITS:-}" ]]; then
        echo "$FAILED_UNITS" | sed 's/^/  /'
    else
        echo "  None"
    fi
else
    echo "  systemctl not available"
fi

print_header "USERS / ADMINS"
echo "Current admin groups:"
getent group sudo 2>/dev/null | sed 's/^/  /' || true
getent group wheel 2>/dev/null | sed 's/^/  /' || true

echo
echo "Recently logged in:"
last -a 2>/dev/null | head -10 | sed 's/^/  /' || echo "  unavailable"

print_header "SSH"
if [[ -f /etc/ssh/sshd_config ]]; then
    echo "Relevant sshd settings:"
    grep -h -Ei '^[[:space:]]*(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|usepam|allowusers|allowgroups|denyusers|denygroups|authorizedkeyscommand|authorizedkeysfile|port)[[:space:]]+' \
        /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | sed 's/^/  /'
else
    echo "  sshd_config not found"
fi

print_header "CRON / TIMERS"
if have systemctl; then
    echo "Active timers:"
    systemctl list-timers --all --no-pager 2>/dev/null | head -15 | sed 's/^/  /'
fi

echo
echo "Cron directories:"
find /etc/cron* -maxdepth 2 -type f 2>/dev/null | sort | head -20 | sed 's/^/  /'

print_header "DISK / MEMORY"
echo "Disk:"
df -h 2>/dev/null | sed 's/^/  /'

echo
echo "Memory:"
free -h 2>/dev/null | sed 's/^/  /' || echo "  free not available"

print_header "SUSPICIOUS QUICK HITS"
echo "Interesting files under /tmp /var/tmp /opt /var/www:"
find /tmp /var/tmp /opt /var/www -maxdepth 2 2>/dev/null | head -30 | sed 's/^/  /'

echo
echo "SSH dirs under /home:"
find /home -maxdepth 3 -path '*/.ssh*' 2>/dev/null | sed 's/^/  /'

print_header "JOURNAL ERRORS"
if have journalctl; then
    $SUDO journalctl -p 3 -xb --no-pager 2>/dev/null | tail -20 | sed 's/^/  /'
else
    echo "  journalctl not available"
fi

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