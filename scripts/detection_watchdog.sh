#!/usr/bin/env bash
set -euo pipefail

# detection_watchdog.sh
# Read-only status dashboard for:
#   - fail2ban
#   - auditd
#   - AIDE
#   - Lynis
# Optional:
#   WATCH=yes INTERVAL=20 ./detection_watchdog.sh
#   DASHBOARD=yes ./detection_watchdog.sh   # tmux mode if tmux exists

WATCH_MODE="${WATCH:-no}"
DASHBOARD_MODE="${DASHBOARD:-no}"
INTERVAL="${INTERVAL:-20}"
AIDE_LOG="${AIDE_LOG:-/var/log/aide/aide-check.log}"
FAIL2BAN_LOG="${FAIL2BAN_LOG:-/var/log/fail2ban.log}"
MAX_LINES="${MAX_LINES:-12}"

have() { command -v "$1" >/dev/null 2>&1; }
hr() { printf '\n== %s ==\n' "$1"; }
status_line() { printf '%-24s %s\n' "$1" "$2"; }
svc_state() { systemctl is-active "$1" 2>/dev/null || true; }
in_list() {
  local needle="$1"
  shift || true
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}
show_recent_file() {
  local f="$1" n="$2"
  if [[ -f "$f" ]]; then
    tail -n "$n" "$f" 2>/dev/null || true
  else
    echo "(missing: $f)"
  fi
}

show_system() {
  hr "SYSTEM"
  status_line host "$(hostname -f 2>/dev/null || hostname)"
  status_line time "$(date)"
  status_line kernel "$(uname -srmo 2>/dev/null || uname -a)"
  status_line uptime "$(uptime -p 2>/dev/null || uptime 2>/dev/null)"
  echo
  echo "Listening ports:"
  if have ss; then
    ss -tulpn 2>/dev/null | awk 'NR==1 || /LISTEN|UNCONN/' | sed 's/^/  /' | head -n 20
  else
    echo "  ss not available"
  fi
}

show_kernel_hardening() {
  hr "KERNEL HARDENING"
  local keys=(
    kernel.randomize_va_space
    kernel.kptr_restrict
    kernel.dmesg_restrict
    kernel.yama.ptrace_scope
    kernel.unprivileged_bpf_disabled
    kernel.perf_event_paranoid
    fs.suid_dumpable
    net.ipv4.tcp_syncookies
  )
  local k
  for k in "${keys[@]}"; do
    status_line "$k" "$(sysctl -n "$k" 2>/dev/null || echo n/a)"
  done
}

show_fail2ban() {
  hr "FAIL2BAN"
  if ! have fail2ban-client; then
    echo "fail2ban-client not installed"
    return
  fi
  status_line service "$(svc_state fail2ban)"
  fail2ban-client status 2>/dev/null || true
  echo
  if fail2ban-client status sshd >/dev/null 2>&1; then
    echo "sshd jail:"
    fail2ban-client status sshd 2>/dev/null || true
  fi
  echo
  echo "Recent fail2ban log:"
  show_recent_file "$FAIL2BAN_LOG" "$MAX_LINES"
}

show_auditd() {
  hr "AUDITD"
  if ! have auditctl; then
    echo "auditctl not installed"
    return
  fi
  status_line service "$(svc_state auditd)"
  auditctl -s 2>/dev/null || true
  echo
  echo "Loaded watch keys:"
  auditctl -l 2>/dev/null | awk '/ key=/{print $NF}' | sort -u | sed 's/^/  /' || true
  echo
  if have ausearch; then
    local keys=(
      identity
      sudoers
      ssh
      ssh_home
      cron
      systemd
      rc_local
      web
      tmpwrite
      preload
      usermgmt
      passwd
      priv_esc
      remote_exec
      rootcmd
      module
      nettools
    )
    local discovered key
    while IFS= read -r discovered; do
      [[ -n "$discovered" ]] || continue
      in_list "$discovered" "${keys[@]}" || keys+=("$discovered")
    done < <(auditctl -l 2>/dev/null | sed -n 's/.* key=\([^[:space:]]\+\).*/\1/p' | sort -u)

    for key in "${keys[@]}"; do
      echo "-- $key --"
      ausearch -k "$key" -ts recent 2>/dev/null | tail -n 6 || true
    done
  fi
}

show_aide() {
  hr "AIDE"
  if ! have aide; then
    echo "aide not installed"
    return
  fi
  status_line db "$(ls /var/lib/aide/aide.db* 2>/dev/null | xargs -r echo || echo missing)"
  status_line cron "$(grep -R "aide" /etc/cron* 2>/dev/null | head -n 2 | xargs echo || echo none)"
  echo
  echo "Recent AIDE log:"
  show_recent_file "$AIDE_LOG" "$MAX_LINES"
  echo
  echo "Manual commands:"
  echo "  sudo aide --check"
  echo "  sudo aide --init"
}

show_lynis() {
  hr "LYNIS"
  if ! have lynis; then
    echo "lynis not installed"
    return
  fi
  status_line binary "$(command -v lynis)"
  status_line version "$(lynis show version 2>/dev/null || lynis --version 2>/dev/null || echo unknown)"
  echo
  echo "Run this when you want a full local audit:"
  echo "  sudo lynis audit system"
}

run_once() {
  clear || true
  show_system
  show_kernel_hardening
  show_fail2ban
  show_auditd
  show_aide
  show_lynis
}

run_tmux_dashboard() {
  if ! have tmux; then
    echo "tmux not installed; falling back to normal output"
    WATCH=yes run_once
    return
  fi
  local session="blue-detect"
  tmux kill-session -t "$session" 2>/dev/null || true
  tmux new-session -d -s "$session" -n dashboard
  tmux split-window -h -t "$session:0"
  tmux split-window -v -t "$session:0.0"
  tmux split-window -v -t "$session:0.1"

  tmux send-keys -t "$session:0.0" "WATCH=yes INTERVAL=${INTERVAL} bash $0" C-m
  tmux send-keys -t "$session:0.1" "watch -n ${INTERVAL} 'fail2ban-client status sshd 2>/dev/null || fail2ban-client status 2>/dev/null'" C-m
  tmux send-keys -t "$session:0.2" "watch -n ${INTERVAL} 'auditctl -s 2>/dev/null; echo; ausearch -ts recent 2>/dev/null | tail -n 20'" C-m
  tmux send-keys -t "$session:0.3" "watch -n ${INTERVAL} 'tail -n 20 ${AIDE_LOG} 2>/dev/null || true; echo; lynis show version 2>/dev/null || true'" C-m

  tmux select-layout -t "$session:0" tiled >/dev/null 2>&1 || true
  tmux attach -t "$session"
}

if [[ "$DASHBOARD_MODE" == "yes" ]]; then
  run_tmux_dashboard
elif [[ "$WATCH_MODE" == "yes" ]]; then
  while true; do
    run_once
    sleep "$INTERVAL"
  done
else
  run_once
fi
