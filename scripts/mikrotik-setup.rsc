# =========================
# EDIT THESE VARIABLES
# =========================

:local WANIF "ether1"
:local LANIF "ether2"

:local WANIP "10.9.5.2"
:local LANSUBNET "172.20.0.0/24"

:local JUMPHOSTIP "10.9.3.1"
:local COMPDNS "10.9.3.12"

:local WEBIP "172.20.0.5"
:local DNSIP "172.20.0.12"
:local DBIP  "172.20.0.7"

# set to scorer IP if you want DB restricted, otherwise leave "0.0.0.0/0"
:local DBALLOWEDSRC "0.0.0.0/0"

# =========================
# SSH KEYS
# Note this will lockout the target account from SSHing with a password.
# =========================

:local targetUser "blueteam"

:local keys {
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID3isB2xfJ8Klk2GZHXPq699gh8dCIwDvhFjU1GonxKe Stephen";
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBtUBWZMnEF/clcQg/kJ42ool6Yw/JtgCLc36Tig1PLM Jason";
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4RbWnc1YAy7gjtaHBkL/OU52fLtGZrJ6uEhwP26p8N Livia";
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJsZSonubQYKp2xXCEvSERHMCN9fdnTNWDqDWXOvgi04 Joey";
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEUwIR1bKaaBqkInrlJQScngmMetLpFKlhjXBWnF3Npi Terry";
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAKe1dqPrh1GrtXRYnX3Db5iU0h+Zozb74OsNlS9pBDu Siddharth";
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHhKOl5a+tFVypJlhdVXpUS1uo8m+vJ0bqPlvcPVNUGT Belizaire";
}

:foreach k in=$keys do={
    /user ssh-keys add user=$targetUser key=$k
}

# =========================
# SERVICES
# =========================

/ip service disable telnet
/ip service disable ftp
/ip service disable www
/ip service disable www-ssl
/ip service disable api
/ip service disable api-ssl

/ip service set winbox address=$LANSUBNET
/ip service set ssh address="$LANSUBNET,$JUMPHOSTIP"

/tool mac-server set allowed-interface-list=none
/tool mac-server mac-winbox set allowed-interface-list=none
/ip neighbor discovery-settings set discover-interface-list=none

/ip ssh set forwarding-enabled=both ciphers=auto always-allow-password-login=no strong-crypto=yes host-key-size=2048 host-key-type=rsa

/ip dns set servers=$COMPDNS

# =========================
# FIREWALL FILTER
# =========================

/ip firewall filter add chain=input action=accept connection-state=established,related comment="allow established,related to router"
/ip firewall filter add chain=input action=drop connection-state=invalid comment="drop invalid to router"
/ip firewall filter add chain=input action=accept protocol=icmp in-interface=$LANIF src-address=$LANSUBNET comment="allow ping to router from LAN"
/ip firewall filter add chain=input action=accept protocol=icmp in-interface=$WANIF comment="allow ping to router from WAN"
/ip firewall filter add chain=input action=accept protocol=tcp src-address=$LANSUBNET in-interface=$LANIF dst-port=22 comment="allow SSH to router from LAN"
/ip firewall filter add chain=input action=accept protocol=tcp src-address=$JUMPHOSTIP in-interface=$WANIF dst-port=22 comment="allow SSH to router from jumphost"
/ip firewall filter add chain=input action=drop in-interface=$WANIF comment="drop WAN access to router"

/ip firewall filter add chain=forward action=accept connection-state=established,related comment="allow established,related"
/ip firewall filter add chain=forward action=drop connection-state=invalid comment="drop invalid"

/ip firewall filter add chain=forward action=accept protocol=tcp in-interface=$WANIF out-interface=$LANIF dst-address=$WEBIP dst-port=80,443 connection-state=new comment="allow WAN to web server http/https"
/ip firewall filter add chain=forward action=accept protocol=udp in-interface=$WANIF out-interface=$LANIF dst-address=$DNSIP dst-port=53 connection-state=new comment="allow WAN to DNS server UDP"
/ip firewall filter add chain=forward action=accept protocol=tcp in-interface=$WANIF out-interface=$LANIF dst-address=$DNSIP dst-port=53 connection-state=new comment="allow WAN to DNS server TCP"
/ip firewall filter add chain=forward action=accept protocol=tcp src-address=$DBALLOWEDSRC in-interface=$WANIF out-interface=$LANIF dst-address=$DBIP dst-port=3306 connection-state=new comment="allow WAN to DB server"
/ip firewall filter add chain=forward action=accept protocol=tcp src-address=$JUMPHOSTIP in-interface=$WANIF out-interface=$LANIF dst-port=22 connection-state=new comment="allow SSH from jumphost to LAN"

/ip firewall filter add chain=forward action=accept protocol=icmp src-address=$LANSUBNET in-interface=$LANIF out-interface=$WANIF comment="allow team LAN outbound ICMP"
/ip firewall filter add chain=forward action=accept protocol=tcp src-address=$LANSUBNET in-interface=$LANIF out-interface=$WANIF dst-port=53,80,443 connection-state=new comment="allow team LAN outbound TCP DNS/web"
/ip firewall filter add chain=forward action=accept protocol=udp src-address=$LANSUBNET in-interface=$LANIF out-interface=$WANIF dst-port=53,123 connection-state=new comment="allow team LAN outbound UDP DNS/NTP"

/ip firewall filter add chain=forward action=drop src-address=$LANSUBNET in-interface=$LANIF out-interface=$WANIF connection-state=new comment="drop other new outbound from team LAN"
/ip firewall filter add chain=forward action=drop protocol=tcp in-interface=$WANIF out-interface=$LANIF dst-port=22 connection-state=new comment="drop other WAN to LAN SSH"
/ip firewall filter add chain=forward action=drop in-interface=$WANIF out-interface=$LANIF connection-state=new comment="drop other new WAN to LAN"

# =========================
# NAT
# =========================

/ip firewall nat add chain=srcnat action=masquerade out-interface=$WANIF comment="masquerade LAN out WAN"

/ip firewall nat add chain=dstnat action=dst-nat protocol=tcp in-interface=$WANIF dst-address=$WANIP dst-port=80 to-addresses=$WEBIP to-ports=80 comment="forward HTTP to web server"
/ip firewall nat add chain=dstnat action=dst-nat protocol=tcp in-interface=$WANIF dst-address=$WANIP dst-port=443 to-addresses=$WEBIP to-ports=443 comment="forward HTTPS to web server"

/ip firewall nat add chain=dstnat action=dst-nat protocol=udp in-interface=$WANIF dst-address=$WANIP dst-port=53 to-addresses=$DNSIP to-ports=53 comment="forward DNS UDP to DNS server"
/ip firewall nat add chain=dstnat action=dst-nat protocol=tcp in-interface=$WANIF dst-address=$WANIP dst-port=53 to-addresses=$DNSIP to-ports=53 comment="forward DNS TCP to DNS server"

/ip firewall nat add chain=dstnat action=dst-nat protocol=tcp src-address=$DBALLOWEDSRC in-interface=$WANIF dst-address=$WANIP dst-port=3306 to-addresses=$DBIP to-ports=3306 comment="forward MySQL to DB server"

/export file=postsetup-export
/system backup save name=postsetup-backup
/system history print1