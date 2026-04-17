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
sudo ./ssh.sh
```

## [health.sh](/scripts/health.sh)
Quick script to give a health check on a machine. Also provides further commands for investigation.

## [harden.sh](/scripts/harden.sh)
Hardens a machine.

## [mikrotik-setup.rsc](/scripts/mikrotik-setup.rsc)
Sets up the entire router, except for the initial interface/address config.

Do this first:
```
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

Also make sure to set the variables in the script.

# Apps

## PassBoard
https://github.com/stephensantilli/passboard hosted at https://passboard.isclub.syr.edu