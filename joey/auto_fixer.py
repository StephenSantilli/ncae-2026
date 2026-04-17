# auto_fixer.py - Automatic fix execution based on priority
# auto_fixer.py - Automatic fix execution based on priority
import os
import time  
import re   
from dotenv import load_dotenv
from attack_patterns import KNOWN_ATTACKS

load_dotenv()

class AutoFixer:
    """
    Executes auto-fixes based on priority and attack type.
    Tier 1: Fix immediately
    Tier 2: Ask permission (not implemented yet - always fixes for now)
    Tier 3: Report only
    """
    
    def __init__(self, ssh_tools):
        self.ssh = ssh_tools
        
        # Auto-fix settings from .env
        self.auto_restart = os.getenv("AUTO_RESTART_SERVICES", "true").lower() == "true"
        self.auto_create_files = os.getenv("AUTO_CREATE_FILES", "true").lower() == "true"
        self.auto_remove_backdoors = os.getenv("AUTO_REMOVE_BACKDOOR_USERS", "true").lower() == "true"
        self.auto_fix_port = os.getenv("AUTO_FIX_SSH_PORT", "true").lower() == "true"
        self.auto_fix_prompt = os.getenv("AUTO_FIX_PROMPT_TRAP", "true").lower() == "true"
        self.auto_fix_map_guest = os.getenv("AUTO_FIX_MAP_TO_GUEST", "true").lower() == "true"
        self.auto_remove_sudoers = os.getenv("AUTO_REMOVE_SUDOERS_D", "true").lower() == "true"
        
        self.fixes_executed = []
    
    def execute_fix(self, issue_type, data):
        """
        Execute appropriate fix based on issue detected.
        Returns action summary.
        """
        actions = []
        
        # Check each known attack pattern
        for attack_id, attack in KNOWN_ATTACKS.items():
            if attack["detection"](data) and attack["auto_fix"]:
                action = self._execute_attack_fix(attack_id, attack)
                if action:
                    actions.append(action)
        
        # Additional quick fixes
        if "smbd" in data and "NOT running" in data and self.auto_restart:
            actions.append(self._fix_smb_down())
        
        if "sshd" in data and "NOT running" in data and self.auto_restart:
            actions.append(self._fix_ssh_down())
        
        # Missing files detection
        missing_files = self._detect_missing_files(data)
        if missing_files and self.auto_create_files:
            actions.append(self._fix_missing_files(missing_files))
        
        return " | ".join(actions) if actions else "No auto-fixes needed"
    
    def _execute_attack_fix(self, attack_id, attack_info):
        """Execute fix for a known attack"""
        try:
            print(f"    🔧 AUTO-FIXING: {attack_info['name']}")
            
            result = self.ssh.run_command(attack_info["fix_command"])
            
            # Verify fix worked
            verify_result = self.ssh.run_command(attack_info["verify"])
            
            self.fixes_executed.append({
                "attack": attack_id,
                "time": time.time(),
                "success": "error" not in verify_result.lower()
            })
            
            return f"✅ Fixed: {attack_info['name']}"
            
        except Exception as e:
            return f"❌ Fix failed for {attack_info['name']}: {str(e)}"
    
    def _fix_smb_down(self):
        """Auto-restart SMB"""
        print("    🔧 AUTO-FIX: Restarting SMB")
        result = self.ssh.restart_smb()
        return "✅ SMB restarted" if "✓" in result else "❌ SMB restart failed"
    
    def _fix_ssh_down(self):
        """Auto-restart SSH"""
        print("    🔧 AUTO-FIX: Restarting SSH")
        result = self.ssh.restart_ssh()
        return "✅ SSH restarted" if "✓" in result else "❌ SSH restart failed"
    
    def _detect_missing_files(self, data):
        """Parse missing file errors"""
        # Look for common patterns
        missing = []
        
        # Check for "No such file" errors
        if "No such file" in data:
            # Try to extract filename
            matches = re.findall(r'/mnt/files/(\w+\.data)', data)
            missing.extend(matches)
        
        # Check for hex-encoded filenames (Issue #13)
        if "\\x" in data:
            # Scoreboard JSON hex parsing would go here
            pass
        
        return list(set(missing))  # Remove duplicates
    
    def _fix_missing_files(self, filenames):
        """Create missing files"""
        if len(filenames) == 1:
            print(f"    🔧 AUTO-FIX: Creating {filenames[0]}")
            self.ssh.create_missing_file(filenames[0])
            return f"✅ Created {filenames[0]}"
        else:
            print(f"    🔧 AUTO-FIX: Batch creating {len(filenames)} files")
            self.ssh.batch_create_files(filenames)
            return f"✅ Created {len(filenames)} files"