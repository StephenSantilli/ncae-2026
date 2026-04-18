# Scripts Guide

## Recommended Order

If you are standing up or recovering a Linux box during the competition, use this order:

1. Get console access or a VM snapshot first.
2. Run `health.sh` to understand the box before changing it.
3. Run `audit.sh` without aggressive flags to collect findings and backups.
4. Edit and run `ssh-setup.sh` only after confirming scoring users, your team keys, and allowed users.
5. Run `deploy_detection_stack.sh` after SSH is stable.
6. Run `detection_watchdog.sh` to watch the detection stack.
7. Run `team_firewall.sh` in preview mode first, then apply only after reviewing ports and subnets.

## Linux Host Scripts

### `health.sh`

Purpose:

- Fast read-only health check
- Lists system state, routes, listening ports, failed services, timers, SSH settings, and follow-up commands

When to use it:

- First look on any unfamiliar host
- Quick re-check after making changes

Download and run:

```bash
curl -L -O https://raw.githubusercontent.com/StephenSantilli/ncae-2026/main/scripts/health.sh
chmod +x health.sh
./health.sh
```

Notes:

- This script is safe to run as a normal user, though `sudo` available on the box will improve log visibility.
- Use this before touching SSH, firewall, or detections so you know what the machine is already doing.

### `audit.sh`

Purpose:

- Mixed audit and light hardening script
- Takes backups into `/root/hardening-backup-<host>-<timestamp>`
- Reviews users, sudoers, cron, timers, shell init files, services, suspicious processes, and logs
- Can optionally lock users or remove `.ssh` directories, but those flags are intentionally off by default

Important note:

- The root repo README currently mentions `harden.sh`.
- In this scripts folder, `audit.sh` is the practical replacement for that role.

Recommended first run:

```bash
curl -L -O https://raw.githubusercontent.com/StephenSantilli/ncae-2026/main/scripts/audit.sh
chmod +x audit.sh
sudo ./audit.sh
```

Aggressive options:

```bash
sudo LOCK_UNKNOWN_USERS=yes ./audit.sh
sudo REMOVE_UNKNOWN_SSH=yes ./audit.sh
sudo DO_UPDATE=yes ./audit.sh
```

Use those flags only after reviewing:

- real scoring users
- app/service accounts
- any service account with a real shell
- whether local `.ssh` keys are needed for service workflows

My advice:

- Safe default: run `sudo ./audit.sh` first, read the report, then make surgical fixes.
- Do not jump straight to `LOCK_UNKNOWN_USERS=yes` unless you already know exactly which local users the image needs.

### `ssh-setup.sh`

Purpose:

- Creates or updates `blueteam`
- Sets passwords for `root` and `blueteam`
- Rewrites `sshd_config`
- Restricts SSH to an allowlist
- Deploys scoring key to scoring users
- Deploys team keys to `blueteam`
- Cleans sudoers and disables extra SSH config drop-ins

This is the highest-risk host script in the folder. Treat it like a controlled access change, not a generic hardening step.

Before you run it:

1. Open the script and verify `TEAM_KEYS`.
2. Verify `SCORING_USERS`.
3. Verify `ALLOWED_USERS`.
4. Confirm the box does not need password SSH for any legitimate scoring or admin workflow.
5. Make sure you have console access or a snapshot in case SSH fails.

Download and review:

```bash
curl -L -O https://raw.githubusercontent.com/StephenSantilli/ncae-2026/main/scripts/ssh-setup.sh
chmod +x ssh-setup.sh
less ssh-setup.sh
```

Ubuntu prep from the root README:

```bash
sudo mkdir -p /run/sshd
sudo chmod 755 /run/sshd
sudo sshd -t -f /etc/ssh/sshd_config
sudo systemctl restart ssh
```

Run it interactively:

```bash
sudo ./ssh-setup.sh
```

Or set passwords through environment variables:

```bash
sudo ROOT_PASSWORD='change-me-now' BLUETEAM_PASSWORD='change-me-now' ./ssh-setup.sh
```

What this script assumes:

- You want key-only SSH
- `blueteam` should be your durable admin entry point
- The scoring usernames listed in the script are correct
- Non-protected user accounts are fair game to lock down

Pushback:

- Do not run this untouched on a host with mystery service accounts, custom SSH include files you still need, or any uncertainty around scoring usernames.
- If you are not sure, use `health.sh` and `audit.sh` first and edit this script before execution.

### `deploy_detection_stack.sh`

Purpose:

- Installs and configures `fail2ban`
- Installs and initializes AIDE
- Loads auditd rules for key files and admin activity
- Applies a kernel/sysctl hardening baseline
- Verifies Lynis is installed

When to use it:

- After SSH is stable
- After you know the box is functionally serving whatever it needs to serve

Download and run:

```bash
curl -L -O https://raw.githubusercontent.com/StephenSantilli/ncae-2026/main/scripts/deploy_detection_stack.sh
chmod +x deploy_detection_stack.sh
sudo ./deploy_detection_stack.sh
```

Useful variants:

```bash
sudo DO_UPDATE=yes ./deploy_detection_stack.sh
sudo SSH_PORT=22 F2B_MAXRETRY=5 F2B_BANTIME=900 F2B_FINDTIME=600 ./deploy_detection_stack.sh
sudo F2B_IGNOREIP="127.0.0.1/8 ::1 10.9.5.0/24" ./deploy_detection_stack.sh
sudo ENABLE_WEB_JAILS=yes ./deploy_detection_stack.sh
sudo AIDE_EXTRA_PATHS="/srv /data" ./deploy_detection_stack.sh
sudo HARDEN_SHM=yes ./deploy_detection_stack.sh
```

Operator notes:

- AIDE creates a baseline of the current box state. If the box is already compromised, you will bless that state.
- `fail2ban` is helpful, but careless settings can ban your own team or a shared NAT source.
- Set `F2B_IGNOREIP` for your team subnet, jump box, or other trusted admin sources before relying on default Fail2ban settings.
- The auditd rules are broad enough to be useful fast, but they replace prior custom rules in `/etc/audit/rules.d` for the loaded ruleset.
- Shared-memory mount hardening is now opt-in with `HARDEN_SHM=yes`. That is deliberate: persistent `/dev/shm` changes can break edge-case apps, so the script does not force them by default.

After running:

```bash
sudo fail2ban-client status sshd
sudo ausearch -k ssh -ts recent
sudo ausearch -k sudoers -ts recent
sudo aide --check
sudo tail -f /var/log/aide/aide-check.log
sudo lynis audit system
```

### `detection_watchdog.sh`

Purpose:

- Read-only dashboard for `fail2ban`, `auditd`, AIDE, and Lynis
- Supports single-shot output, loop mode, and a tmux dashboard mode

Download and run once:

```bash
curl -L -O https://raw.githubusercontent.com/StephenSantilli/ncae-2026/main/scripts/detection_watchdog.sh
chmod +x detection_watchdog.sh
sudo ./detection_watchdog.sh
```

Watch mode:

```bash
sudo WATCH=yes INTERVAL=20 ./detection_watchdog.sh
```

Dashboard mode:

```bash
sudo DASHBOARD=yes INTERVAL=20 ./detection_watchdog.sh
```

Notes:

- `DASHBOARD=yes` works best on a box with `tmux` and `watch` installed.
- This script does not modify the host. It is safe to use as a monitoring helper.

### `team_firewall.sh`

Purpose:

- Conservative host firewall for Linux systems using `nftables`
- Detects currently listening ports and builds allow rules around those
- Defaults to preview mode so you can inspect the generated policy before enforcing it

This script is useful, but you should treat it as a policy generator, not an oracle.

Before you run it:

1. Confirm the team subnet and competition subnet.
2. Confirm whether SSH from the competition subnet is required.
3. Confirm any scoring services that are not currently listening yet.
4. Confirm whether the box is already managed by `ufw`, `firewalld`, or custom `nftables`.

Download:

```bash
curl -L -O https://raw.githubusercontent.com/StephenSantilli/ncae-2026/main/scripts/team_firewall.sh
chmod +x team_firewall.sh
```

Preview first:

```bash
sudo TEAM_SUBNET=10.9.5.0/24 COMP_SUBNET=10.9.3.0/24 ./team_firewall.sh
```

Apply after review:

```bash
sudo TEAM_SUBNET=10.9.5.0/24 COMP_SUBNET=10.9.3.0/24 APPLY=yes ./team_firewall.sh
```

Useful options:

```bash
sudo APPLY=yes ALLOW_SSH_FROM_COMP=yes ./team_firewall.sh
sudo APPLY=yes BACKUP_BOX_IP=10.9.5.50 ./team_firewall.sh
sudo APPLY=yes REQUIRED_TCP_PORTS="25 110 143 993 995" ./team_firewall.sh
sudo APPLY=yes REQUIRED_UDP_PORTS="123 161" ./team_firewall.sh
sudo APPLY=yes EXTRA_TCP_PORTS="25 110 143 993 995 3389" ./team_firewall.sh
sudo APPLY=yes EXTRA_UDP_PORTS="123 161 500 4500" ./team_firewall.sh
```

My advice:

- Always preview.
- Prefer `REQUIRED_TCP_PORTS` and `REQUIRED_UDP_PORTS` for known scoring ports that must stay reachable even if the service is not listening yet.
- If a service matters for scoring, explicitly add it with `EXTRA_TCP_PORTS` or `EXTRA_UDP_PORTS` rather than trusting auto-detection alone.
- Keep a console session open while applying firewall changes.

## Router Script

### `mikrotik-setup.rsc`

Purpose:

- Sets up the router after initial interface and address configuration

Prep from the root README:

```text
/user add name=blueteam group=full password="abc123"
/user disable admin

/interface print
# add both interfaces to ip address
/ip address add
# add default route
/ip route add dst-address=0.0.0.0/0 gateway=10.9.0.1 comment="default route"
# Then check if the correct routes got added
/ip route print
```

Before importing:

1. Open the `.rsc` file.
2. Set the variables for your actual environment.
3. Confirm interface names, addresses, and upstream gateway.

Suggested flow:

```text
/import file-name=mikrotik-setup.rsc
```

Use the router script only after the base interface and routing work is correct. Bad assumptions on interface names will waste time fast.

## Competition Safety Rules

- Keep console or hypervisor access before changing SSH or firewall rules.
- Snapshot before `ssh-setup.sh` or aggressive user-locking.
- Run `health.sh` and a plain `audit.sh` first on every fresh host.
- Do not trust auto-detection for scoring ports. Verify the service list yourself.
- Do not blindly bless an AIDE baseline on a box you have not inspected.
- Re-run `health.sh`, `detection_watchdog.sh`, and manual service checks after every major change.

## Quick Fetch Commands

```bash
curl -L -O https://raw.githubusercontent.com/StephenSantilli/ncae-2026/main/scripts/health.sh
curl -L -O https://raw.githubusercontent.com/StephenSantilli/ncae-2026/main/scripts/audit.sh
curl -L -O https://raw.githubusercontent.com/StephenSantilli/ncae-2026/main/scripts/ssh-setup.sh
curl -L -O https://raw.githubusercontent.com/StephenSantilli/ncae-2026/main/scripts/deploy_detection_stack.sh
curl -L -O https://raw.githubusercontent.com/StephenSantilli/ncae-2026/main/scripts/detection_watchdog.sh
curl -L -O https://raw.githubusercontent.com/StephenSantilli/ncae-2026/main/scripts/team_firewall.sh
```
