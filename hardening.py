# hardening.py - Pre-emptive security hardening based on previous attacks
import os
from dotenv import load_dotenv

load_dotenv()

class PreemptiveHardening:
    """
    Runs security hardening on startup before red team attacks.
    Based on all known attack patterns from previous competitions.
    """
    
    def __init__(self, ssh_tools):
        self.ssh = ssh_tools
        self.enabled = os.getenv("RUN_HARDENING_ON_STARTUP", "true").lower() == "true"
    
    def run_all_hardening(self):
        """Execute all hardening steps"""
        if not self.enabled:
            print("⏭️  Pre-emptive hardening disabled")
            return []
        
        print("🛡️  Running pre-emptive hardening...")
        
        results = []
        results.append(self._harden_ssh())
        results.append(self._harden_smb())
        results.append(self._remove_backdoors())
        results.append(self._create_common_files())
        
        return results
    
    def _harden_ssh(self):
        """SSH hardening based on known attacks"""
        print("  🔒 Hardening SSH...")
        
        cmd = """
# Backup first
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.initial

# Ensure port 22 (Issue #7)
sudo sed -i 's/^Port.*/Port 22/' /etc/ssh/sshd_config
sudo sed -i 's/^#Port 22/Port 22/' /etc/ssh/sshd_config

# Security settings (from exhaustive analysis)
sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

sudo sed -i 's/^PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
sudo sed -i 's/^#PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config

sudo sed -i 's/^MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
sudo sed -i 's/^#MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config

sudo sed -i 's/^X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config
sudo sed -i 's/^#X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config

# Test config
sshd -t 2>&1

# Restart if valid
if sshd -t 2>&1 | grep -q "error"; then
    echo "⚠️ SSH config has errors, not restarting"
else
    sudo killall sshd
    sudo /usr/sbin/sshd
    echo "✓ SSH hardened and restarted"
fi
"""
        result = self.ssh.run_command(cmd)
        return "SSH: " + ("✅ Hardened" if "✓" in result else "⚠️ Partial")
    
    def _harden_smb(self):
        """SMB hardening based on known attacks"""
        print("  🔒 Hardening SMB...")
        
        cmd = """
# Backup first
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.backup.initial 2>/dev/null
sudo cp /etc/samba.d/smb.conf /etc/samba.d/smb.conf.backup.initial 2>/dev/null

# Ensure [global] section has security settings
sudo tee /tmp/smb_hardening.conf > /dev/null << 'SMBCONF'
# Security hardening
min protocol = SMB2
server signing = mandatory
restrict anonymous = 2
map to guest = Bad User
SMBCONF

# Add to [global] if not already there
if ! grep -q 'min protocol = SMB2' /etc/samba/smb.conf 2>/dev/null; then
    sudo sed -i '/^\\[global\\]/r /tmp/smb_hardening.conf' /etc/samba/smb.conf
fi

# Ensure [files] share exists (Issue #14)
if ! grep -q '^\\[files\\]' /etc/samba/smb.conf 2>/dev/null; then
    sudo tee -a /etc/samba/smb.conf > /dev/null << 'FILESCONF'

[files]
   comment = Scoring Directories
   path = /mnt/files
   browseable = No
   read only = Yes
   guest ok = Yes
   writeable = No
FILESCONF
fi

# Create /mnt/files directory
sudo mkdir -p /mnt/files
sudo chmod 755 /mnt/files

# Remove map to guest from included file (Issue #1)
sudo sed -i '/map to guest/d' /etc/samba.d/smb.conf 2>/dev/null

# Test config
testparm -s 2>&1 | head -20

# Restart if valid
if testparm -s 2>&1 | grep -qi "loaded services file ok"; then
    sudo killall -9 smbd nmbd
    sudo /usr/sbin/smbd -D
    sudo /usr/sbin/nmbd -D
    echo "✓ SMB hardened and restarted"
else
    echo "⚠️ SMB config has errors"
fi
"""
        result = self.ssh.run_command(cmd)
        return "SMB: " + ("✅ Hardened" if "✓" in result else "⚠️ Partial")
    
    def _remove_backdoors(self):
        """Remove known backdoor accounts preemptively"""
        print("  🔒 Removing backdoor accounts...")
        
        cmd = """
# Remove common backdoor usernames
for user in blackteam redteam blackteam-r hacker attacker admin; do
    if id "$user" 2>/dev/null; then
        sudo pkill -9 -u $user 2>/dev/null
        sudo userdel -r $user 2>/dev/null
        echo "Removed: $user"
    fi
done

# Clean sudoers.d
if [ -d /etc/sudoers.d ] && [ "$(ls -A /etc/sudoers.d/)" ]; then
    sudo tar -czf /root/sudoers.d.backup.initial.tar.gz /etc/sudoers.d/
    sudo rm -rf /etc/sudoers.d/*
    echo "✓ sudoers.d cleaned"
fi

# Remove NOPASSWD from main sudoers
sudo sed -i '/NOPASSWD/d' /etc/sudoers

echo "✓ Backdoor removal complete"
"""
        result = self.ssh.run_command(cmd)
        return "Backdoors: " + ("✅ Cleaned" if "✓" in result else "⚠️ Partial")
    
    def _create_common_files(self):
        """Pre-create common Twenty One Pilots files (optional - user said wait)"""
        # User said to wait for these, so just ensure directory exists
        print("  📁 Ensuring /mnt/files exists...")
        
        cmd = """
sudo mkdir -p /mnt/files
sudo chmod 755 /mnt/files
ls -ld /mnt/files
"""
        result = self.ssh.run_command(cmd)
        return "Files: " + ("✅ Directory ready" if "drwx" in result else "⚠️ Check failed")