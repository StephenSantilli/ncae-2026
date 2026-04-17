# attack_patterns.py - Known red team tactics from previous competitions
# Based on exhaustive analysis of all 30 issues

KNOWN_ATTACKS = {
    "ssh_port_change": {
        "name": "SSH Port Changed to 2222",
        "detection": lambda data: ":2222" in data and "sshd" in data,
        "severity": "critical",
        "auto_fix": True,
        "fix_command": "sudo sed -i 's/^Port 2222/Port 22/' /etc/ssh/sshd_config; sudo killall sshd; sudo /usr/sbin/sshd",
        "verify": "ss -tulpn | grep ':22 '",
        "occurrences_in_history": 3
    },
    
    "prompt_command_trap": {
        "name": "PROMPT_COMMAND Math Problem Trap",
        "detection": lambda data: "PROMPT_COMMAND" in data and ("RANDOM" in data or "calc" in data.lower()),
        "severity": "critical",
        "auto_fix": True,
        "fix_command": "unset PROMPT_COMMAND; sudo sed -i '/PROMPT_COMMAND/d' /root/.bashrc /etc/bash.bashrc /etc/profile",
        "verify": "echo $PROMPT_COMMAND",
        "occurrences_in_history": 1
    },
    
    "map_to_guest_wrong_section": {
        "name": "map to guest in Service Section",
        "detection": lambda data: "map to guest found in service section" in data.lower(),
        "severity": "high",
        "auto_fix": True,
        "fix_command": """
# Remove from all sections except [global]
sudo sed -i '/^\\[global\\]/,/^\\[/!{/map to guest/d}' /etc/samba/smb.conf
sudo sed -i '/map to guest/d' /etc/samba.d/smb.conf 2>/dev/null
# Add to [global] if not there
sudo grep -q 'map to guest' /etc/samba/smb.conf || sudo sed -i '/^\\[global\\]/a\\   map to guest = Bad User' /etc/samba/smb.conf
sudo killall -9 smbd nmbd; sudo /usr/sbin/smbd -D; sudo /usr/sbin/nmbd -D
""",
        "verify": "testparm -s 2>&1 | grep -i 'map to guest'",
        "occurrences_in_history": 8
    },
    
    "backdoor_users": {
        "name": "Backdoor Users (blackteam, redteam, etc.)",
        "detection": lambda data: any(user in data.lower() for user in ["blackteam", "redteam", "hacker", "attacker"]),
        "severity": "critical",
        "auto_fix": True,
        "fix_command": """
# Remove backdoor users
for user in blackteam redteam blackteam-r hacker attacker; do
    sudo pkill -9 -u $user 2>/dev/null
    sudo userdel -r $user 2>/dev/null
done
""",
        "verify": "cat /etc/passwd | grep -E 'blackteam|redteam|hacker'",
        "occurrences_in_history": 1
    },
    
    "nopasswd_sudo": {
        "name": "NOPASSWD in sudoers.d",
        "detection": lambda data: "NOPASSWD" in data and "sudoers" in data.lower(),
        "severity": "critical",
        "auto_fix": True,
        "fix_command": "sudo rm -rf /etc/sudoers.d/*; sudo sed -i '/NOPASSWD/d' /etc/sudoers",
        "verify": "grep -r NOPASSWD /etc/sudoers /etc/sudoers.d/ 2>/dev/null",
        "occurrences_in_history": 1
    },
    
    "missing_files_share": {
        "name": "[files] Share Missing from SMB Config",
        "detection": lambda data: "files" not in data and "smbclient" in data,
        "severity": "critical",
        "auto_fix": True,
        "fix_command": """
sudo tee -a /etc/samba/smb.conf > /dev/null << 'EOF'

[files]
   comment = Scoring Directories
   path = /mnt/files
   browseable = No
   read only = Yes
   guest ok = Yes
   writeable = No
EOF
sudo killall -9 smbd nmbd; sudo /usr/sbin/smbd -D; sudo /usr/sbin/nmbd -D
""",
        "verify": "smbclient -L localhost -N 2>&1 | grep files",
        "occurrences_in_history": 1
    },
    
    "crypto_policies_corruption": {
        "name": "Crypto-Policies Config Corruption",
        "detection": lambda data: "crypto-policies" in data.lower() and ("bad configuration" in data.lower() or "gssapik" in data.lower()),
        "severity": "high",
        "auto_fix": True,
        "fix_command": "sudo mv /etc/crypto-policies/back-ends/openssh.config /etc/crypto-policies/back-ends/openssh.config.broken; sudo killall sshd; sudo /usr/sbin/sshd",
        "verify": "sshd -t 2>&1",
        "occurrences_in_history": 1
    },
    
    "guest_access_disabled": {
        "name": "Guest Access Incorrectly Disabled",
        "detection": lambda data: "guest ok = No" in data or "map to guest = never" in data,
        "severity": "medium",
        "auto_fix": False,  # Ask first - security tradeoff
        "fix_command": """
# Scoring needs guest READ access
sudo sed -i 's/guest ok = No/guest ok = Yes/' /etc/samba/smb.conf
sudo sed -i 's/read only = No/read only = Yes/' /etc/samba/smb.conf
sudo killall -9 smbd nmbd; sudo /usr/sbin/smbd -D; sudo /usr/sbin/nmbd -D
""",
        "verify": "testparm -s | grep -A5 '\\[files\\]'",
        "occurrences_in_history": 4
    }
}

# Missing file patterns from your history
TWENTY_ONE_PILOTS_SONGS = [
    "addict_with_a_pen",
    "air_catcher", 
    "anathema",
    "at_the_risk_of_feeling_dumb",
    "backslide",
    "car_radio",
    # Add more just in case
    "holding_on_to_you",
    "ode_to_sleep",
    "screen",
    "the_run_and_go",
    "trees",
    "truce",
    "guns_for_hands",
    "lovely",
    "kitchen_sink"
]