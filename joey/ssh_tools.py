# ssh_tools.py - SSH tool library with auto-fix capabilities
import paramiko
import os
import time
from dotenv import load_dotenv

load_dotenv()

class CompetitionSSH:
    """SSH interface to competition machine via jumphost with auto-reconnect"""
    
    def __init__(self):
        self.jumphost_ip = os.getenv("JUMPHOST_IP")
        self.jumphost_port = int(os.getenv("JUMPHOST_PORT"))
        self.jumphost_user = os.getenv("JUMPHOST_USER")
        self.jumphost_password = os.getenv("JUMPHOST_PASSWORD")
        
        self.target_ip = os.getenv("COMPETITION_IP")
        self.target_user = os.getenv("COMPETITION_USER")
        self.target_password = os.getenv("COMPETITION_PASSWORD")
        
        # Connection state
        self.jump_client = None
        self.target_client = None
        self.connected = False
        self.last_connection_attempt = 0
        
    def connect(self):
        """Establish SSH connection through jumphost"""
        try:
            # Rate limit connection attempts (max once per 2 seconds)
            now = time.time()
            if now - self.last_connection_attempt < 2:
                time.sleep(2 - (now - self.last_connection_attempt))
            self.last_connection_attempt = time.time()
            
            # Connect to jumphost
            self.jump_client = paramiko.SSHClient()
            self.jump_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            self.jump_client.connect(
                self.jumphost_ip,
                port=self.jumphost_port,
                username=self.jumphost_user,
                password=self.jumphost_password,
                timeout=10
            )
            
            # Create tunnel
            jump_transport = self.jump_client.get_transport()
            dest_addr = (self.target_ip, 22)
            jump_channel = jump_transport.open_channel("direct-tcpip", dest_addr, ('', 0))
            
            # Connect to target
            self.target_client = paramiko.SSHClient()
            self.target_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            self.target_client.connect(
                self.target_ip,
                username=self.target_user,
                password=self.target_password,
                sock=jump_channel,
                timeout=10
            )
            
            self.connected = True
            return True
            
        except Exception as e:
            self.connected = False
            self.cleanup()
            raise Exception(f"SSH connection failed: {str(e)}")
    
    def cleanup(self):
        """Close all SSH connections"""
        try:
            if self.target_client:
                self.target_client.close()
            if self.jump_client:
                self.jump_client.close()
        except:
            pass
        self.connected = False
    
    def run_command(self, command, use_sudo=False):
        """Execute command on competition machine with auto-reconnect"""
        if use_sudo and not command.startswith("sudo "):
            command = f"sudo {command}"
        
        max_retries = 3
        for attempt in range(max_retries):
            try:
                if not self.connected or not self.target_client:
                    self.connect()
                
                stdin, stdout, stderr = self.target_client.exec_command(command, timeout=30)
                output = stdout.read().decode('utf-8', errors='ignore')
                error = stderr.read().decode('utf-8', errors='ignore')
                
                return output if output else error
                
            except Exception as e:
                self.cleanup()
                if attempt < max_retries - 1:
                    time.sleep(2)
                    continue
                return f"SSH Error after {max_retries} attempts: {str(e)}"
    
    def check_connection(self):
        """Quick connection test (for 5s watchdog)"""
        try:
            if not self.connected or not self.target_client:
                return False
            
            # Quick test - very fast
            stdin, stdout, stderr = self.target_client.exec_command("echo OK", timeout=3)
            result = stdout.read().decode('utf-8', errors='ignore').strip()
            return result == "OK"
        except:
            return False
    
    # ═══════════════════════════════════════════════════════════
    # DIAGNOSTIC TOOLS (Read-only)
    # ═══════════════════════════════════════════════════════════
    
    def quick_health_check(self):
        """Fast health check - used every scan"""
        cmd = """
echo "=== SERVICES ==="
ps aux | grep -E 'smbd|nmbd|sshd' | grep -v grep
echo -e "\\n=== PORTS ==="
ss -tulpn | grep -E '445|139|22'
echo -e "\\n=== SHARES ==="
timeout 5 smbclient -L localhost -N 2>&1 | grep -E 'Sharename|files|IPC' || echo "smbclient timeout/error"
echo -e "\\n=== FILES ==="
ls /mnt/files/*.data 2>/dev/null | wc -l
"""
        return self.run_command(cmd)
    
    def read_smb_config(self):
        """Read SMB configs - ALWAYS checks includes (Issue #1)"""
        cmd = """
echo "=== /etc/samba/smb.conf ==="
cat /etc/samba/smb.conf 2>/dev/null || echo "File not found"
echo -e "\\n=== INCLUDE CHECK ==="
grep -i 'include' /etc/samba/smb.conf 2>/dev/null || echo "No includes"
echo -e "\\n=== /etc/samba.d/smb.conf ==="
cat /etc/samba.d/smb.conf 2>/dev/null || echo "File not found"
"""
        return self.run_command(cmd)
    
    def check_smb_status(self):
        """Full SMB diagnostic (Issue #14 order)"""
        cmd = """
echo "=== 1. SHARE EXISTS? ==="
timeout 5 smbclient -L localhost -N 2>&1 | grep files || echo "[files] share NOT found"
echo -e "\\n=== 2. SERVICE RUNNING? ==="
ps aux | grep smbd | grep -v grep || echo "smbd NOT running"
echo -e "\\n=== 3. LISTENING? ==="
ss -tulpn | grep ':445' || echo "Port 445 NOT listening"
echo -e "\\n=== 4. FILES EXIST? ==="
ls -la /mnt/files/ 2>&1
echo -e "\\n=== 5. PERMISSIONS? ==="
ls -ld /mnt/files 2>&1
echo -e "\\n=== 6. CONFIG VALID? ==="
testparm -s 2>&1 | head -30
"""
        return self.run_command(cmd)
    
    def read_smb_logs(self, lines=50):
        return self.run_command(f"tail -{lines} /var/log/samba/log.smbd 2>/dev/null")
    
    def read_ssh_config(self):
        """Read SSH SERVER config (Issue #9)"""
        return self.run_command("cat /etc/ssh/sshd_config 2>/dev/null")
    
    def check_ssh_status(self):
        """Full SSH diagnostic (Issue #7 order)"""
        cmd = """
echo "=== 1. SERVICE RUNNING? ==="
ps aux | grep sshd | grep -v grep || echo "sshd NOT running"
echo -e "\\n=== 2. PORT 22? ==="
ss -tulpn | grep sshd
echo -e "\\n=== 3. CONFIG VALID? ==="
sshd -t 2>&1
"""
        return self.run_command(cmd)
    
    def read_auth_logs(self, lines=50):
        return self.run_command(f"tail -{lines} /var/log/auth.log 2>/dev/null")
    
    def list_files(self, directory="/mnt/files"):
        return self.run_command(f"ls -la {directory} 2>&1")
    
    def check_recent_changes(self, minutes=10):
        """Detect red team file modifications (Issue #15)"""
        cmd = f"""
echo "=== FILES MODIFIED IN LAST {minutes} MINUTES ==="
find /etc /root -type f -mmin -{minutes} 2>/dev/null | while read f; do
    echo "$f ($(stat -c '%y' "$f"))"
done
"""
        return self.run_command(cmd)
    
    def check_suspicious_users(self):
        """Detect backdoor users (from previous competition)"""
        cmd = """
echo "=== USERS WITH LOGIN SHELLS ==="
cat /etc/passwd | grep -v 'nologin\\|false'
echo -e "\\n=== SUDOERS.D ENTRIES ==="
ls -la /etc/sudoers.d/ 2>&1
cat /etc/sudoers.d/* 2>/dev/null
echo -e "\\n=== NOPASSWD CHECK ==="
grep -r NOPASSWD /etc/sudoers /etc/sudoers.d/ 2>/dev/null || echo "None found"
"""
        return self.run_command(cmd)
    
    def check_malicious_traps(self):
        """Detect PROMPT_COMMAND and bash wrappers (Issue #5)"""
        cmd = """
echo "=== PROMPT_COMMAND CHECK ==="
grep -r 'PROMPT_COMMAND' /root/.bashrc /etc/bash.bashrc /etc/profile 2>/dev/null || echo "None found"
echo -e "\\n=== BASH FUNCTIONS/ALIASES ==="
grep -E 'function|alias' /root/.bashrc /etc/bash.bashrc 2>/dev/null | head -20 || echo "None found"
echo -e "\\n=== CURRENT PROMPT_COMMAND ==="
echo \$PROMPT_COMMAND
"""
        return self.run_command(cmd)
    
    def check_cron_backdoors(self):
        cmd = """
echo "=== USER CRONTABS ==="
crontab -l 2>/dev/null || echo "No user crontab"
echo -e "\\n=== SYSTEM CRON ==="
cat /etc/crontab 2>/dev/null
echo -e "\\n=== CRON.D ==="
ls -la /etc/cron.d/ 2>&1
cat /etc/cron.d/* 2>/dev/null | head -20
"""
        return self.run_command(cmd)
    
    def find_suid_binaries(self):
        return self.run_command("find / -perm -4000 -type f 2>/dev/null | head -30")
    
    # ═══════════════════════════════════════════════════════════
    # AUTO-FIX ACTIONS (Tier 1 - Immediate)
    # ═══════════════════════════════════════════════════════════
    
    def restart_smb(self):
        """Auto-restart SMB (Tier 1)"""
        cmd = """
sudo killall -9 smbd nmbd 2>/dev/null
sleep 1
sudo /usr/sbin/smbd -D
sudo /usr/sbin/nmbd -D
sleep 1
ps aux | grep smbd | grep -v grep && echo "✓ SMB restarted" || echo "✗ SMB FAILED"
ss -tulpn | grep -E '445|139'
"""
        return self.run_command(cmd)
    
    def restart_ssh(self):
        """Auto-restart SSH (Tier 1) - CAREFUL: might disconnect us"""
        cmd = """
sudo killall sshd 2>/dev/null
sleep 1
sudo /usr/sbin/sshd
sleep 1
ps aux | grep sshd | grep -v grep && echo "✓ SSH restarted" || echo "✗ SSH FAILED"
ss -tulpn | grep ':22'
"""
        return self.run_command(cmd)
    
    def fix_ssh_port(self):
        """Fix SSH port 2222→22 (Tier 1, Issue #7)"""
        cmd = """
# Backup first (Issue #27)
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%s)
# Fix port
sudo sed -i 's/^Port 2222/Port 22/' /etc/ssh/sshd_config
sudo sed -i 's/^#Port 22/Port 22/' /etc/ssh/sshd_config
# Verify change
grep '^Port' /etc/ssh/sshd_config
# Restart (careful!)
sudo killall sshd; sudo /usr/sbin/sshd
sleep 2
ss -tulpn | grep sshd
"""
        return self.run_command(cmd)
    
    def remove_prompt_trap(self):
        """Remove PROMPT_COMMAND math trap (Tier 1, Issue #5)"""
        cmd = """
# Remove from all common locations
sudo sed -i '/PROMPT_COMMAND/d' /root/.bashrc
sudo sed -i '/PROMPT_COMMAND/d' /etc/bash.bashrc  
sudo sed -i '/PROMPT_COMMAND/d' /etc/profile
# Remove malicious functions
sudo sed -i '/function.*sudo/,/^}/d' /root/.bashrc
sudo sed -i '/function.*sudo/,/^}/d' /etc/bash.bashrc
echo "✓ PROMPT_COMMAND traps removed"
"""
        return self.run_command(cmd)
    
    def create_missing_file(self, filename, content="scoring data"):
        """Create missing .data file (Tier 1, Issue #2)"""
        filepath = f"/mnt/files/{filename}"
        cmd = f"""
sudo mkdir -p /mnt/files
echo '{content}' | sudo tee {filepath} > /dev/null
sudo chmod 644 {filepath}
ls -la {filepath}
"""
        return self.run_command(cmd)
    
    def batch_create_files(self, filenames):
        """Create multiple files at once (Issue #2 solution)"""
        files_str = " ".join(filenames)
        cmd = f"""
sudo mkdir -p /mnt/files
for file in {files_str}; do
    echo 'scoring data' | sudo tee /mnt/files/${{file}}.data > /dev/null
    sudo chmod 644 /mnt/files/${{file}}.data
done
ls -la /mnt/files/*.data 2>/dev/null | wc -l
"""
        return self.run_command(cmd)
    
    def remove_sudoers_d(self):
        """Remove NOPASSWD backdoors (Tier 1)"""
        cmd = """
# Backup first
sudo tar -czf /root/sudoers.d.backup.$(date +%s).tar.gz /etc/sudoers.d/ 2>/dev/null
# Remove all sudoers.d files
sudo rm -rf /etc/sudoers.d/*
# Remove NOPASSWD from main sudoers
sudo sed -i '/NOPASSWD/d' /etc/sudoers
echo "✓ sudoers.d cleaned"
grep -r NOPASSWD /etc/sudoers /etc/sudoers.d/ 2>/dev/null || echo "✓ No NOPASSWD entries remain"
"""
        return self.run_command(cmd)
    
    def remove_backdoor_user(self, username):
        """Remove backdoor user (Tier 1)"""
        cmd = f"""
# Kill all processes
sudo pkill -9 -u {username} 2>/dev/null
# Remove user
sudo userdel -r {username} 2>/dev/null
# Verify
id {username} 2>&1 | grep -q "no such user" && echo "✓ {username} removed" || echo "✗ {username} still exists"
"""
        return self.run_command(cmd)
    
    def fix_map_to_guest(self):
        """Fix map to guest in wrong section (Tier 1, Issue #1)"""
        cmd = """
# Backup both files
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.backup.$(date +%s)
sudo cp /etc/samba.d/smb.conf /etc/samba.d/smb.conf.backup.$(date +%s) 2>/dev/null

# Remove from included file
sudo sed -i '/map to guest/d' /etc/samba.d/smb.conf 2>/dev/null

# Ensure it's ONLY in [global] in main file
sudo sed -i '/^\\[global\\]/,/^\\[/{
    /map to guest/!b
    d
}' /etc/samba/smb.conf

# Add to [global] if missing
grep -q 'map to guest' /etc/samba/smb.conf || sudo sed -i '/^\\[global\\]/a\\   map to guest = Bad User' /etc/samba/smb.conf

# Restart
sudo killall -9 smbd nmbd
sudo /usr/sbin/smbd -D
sudo /usr/sbin/nmbd -D

# Verify
testparm -s 2>&1 | grep -i 'map to guest'
"""
        return self.run_command(cmd)
    
    def restore_files_share(self):
        """Restore [files] share if missing (Tier 1, Issue #14)"""
        cmd = """
# Check if exists
if ! grep -q '^\\[files\\]' /etc/samba/smb.conf; then
    # Backup
    sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.backup.$(date +%s)
    
    # Add [files] share
    sudo tee -a /etc/samba/smb.conf > /dev/null << 'EOF'

[files]
   comment = Scoring Directories
   path = /mnt/files
   browseable = No
   read only = Yes
   guest ok = Yes
   writeable = No
EOF
    
    # Create directory
    sudo mkdir -p /mnt/files
    sudo chmod 755 /mnt/files
    
    # Restart SMB
    sudo killall -9 smbd nmbd
    sudo /usr/sbin/smbd -D
    sudo /usr/sbin/nmbd -D
    
    echo "✓ [files] share restored"
else
    echo "✓ [files] share already exists"
fi

# Verify
timeout 5 smbclient -L localhost -N 2>&1 | grep files
"""
        return self.run_command(cmd)
    
    def fix_crypto_policies(self):
        """Fix corrupted crypto-policies (Tier 1, Issue #15)"""
        cmd = """
if [ -f /etc/crypto-policies/back-ends/openssh.config ]; then
    # Backup
    sudo cp /etc/crypto-policies/back-ends/openssh.config /etc/crypto-policies/back-ends/openssh.config.broken
    # Remove
    sudo rm /etc/crypto-policies/back-ends/openssh.config
    echo "✓ Removed broken crypto-policies"
    # Restart SSH
    sudo killall sshd
    sudo /usr/sbin/sshd
else
    echo "✓ No crypto-policies file"
fi
"""
        return self.run_command(cmd)