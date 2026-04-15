# Syracuse University's NCAE Invitational 2026 Scripts

## [ssh-setup.sh](/scripts/ssh-setup.sh)
SSH setup script adapted from CedarvilleCyber - https://github.com/CedarvilleCyber/Cyber-Games/blob/main/scripts/01_ssh_lockdown.sh.

Sets up user accounts and SSH. Before running, make sure the scoring key and users are correct to avoid losing points.

On Ubuntu, you may need to run this first:
```
sudo mkdir -p /run/sshd
sudo chmod 755 /run/sshd
sudo sshd -t -f /etc/ssh/sshd_config
sudo systemctl restart ssh
```

Then, to make and run the script:
```
vi ssh.sh
chmod +x ssh.sh
sudo ssh.sh
```

## [health.sh](/scripts/health.sh)
Quick script to give a health check on a machine. Also provides further commands for investigation.

## [ssh-mikrotik.rsc](/scripts/ssh-mikrotik.rsc)
MikroTik SSH setup script. Simply adds our team keys to the `blueteam` user.