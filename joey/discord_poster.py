# discord_poster.py - Multi-tier Discord output
import requests
from datetime import datetime
import os
from dotenv import load_dotenv

load_dotenv()

class DiscordPoster:
    """
    Posts to Discord with three-tier output:
    1. Glance view (always) - Status Grid
    2. Issues found (only if issues exist)
    3. Full diagnostic (detailed, collapsed)
    """
    
    def __init__(self):
        self.webhook_url = os.getenv("DISCORD_WEBHOOK_URL")
        self.team_name = os.getenv("TEAM_NAME")
        
        self.color_map = {
            "critical": 0xFF0000,   # Red
            "warning":  0xFFA500,   # Orange  
            "info":     0x0000FF,   # Blue
            "success":  0x00FF00    # Green
        }
    
    def post_glance_view(self, smb_status, ssh_status, port_445, port_22, file_count):
        """
        Tier 1: Glance view (Option A format)
        Example: 🟢 SMB ✅ | SSH ✅ | Ports: ✅445 ✅22 | Files: 6
        """
        smb_icon = "✅" if smb_status else "❌"
        ssh_icon = "✅" if ssh_status else "❌"
        p445_icon = "✅" if port_445 else "❌"
        p22_icon = "✅" if port_22 else "❌"
        
        # Overall color
        if not smb_status or not ssh_status:
            overall = "🔴"
            color = self.color_map["critical"]
        elif not port_445 or not port_22:
            overall = "🟡"
            color = self.color_map["warning"]
        else:
            overall = "🟢"
            color = self.color_map["success"]
        
        message = f"{overall} SMB {smb_icon} | SSH {ssh_icon} | Ports: {p445_icon}445 {p22_icon}22 | Files: {file_count}"
        
        self._send_embed(
            title=f"📊 {self.team_name} - Glance",
            description=f"```{message}```",
            color=color
        )
    
    def post_issues_summary(self, issues_list, actions_taken):
        """
        Tier 2: Medium detail - only posts if issues exist
        """
        if not issues_list and not actions_taken:
            return  # No issues, skip this tier
        
        message = "**Issues Detected:**\n"
        
        for issue in issues_list:
            message += f"{issue}\n"
        
        if actions_taken:
            message += f"\n**🔧 Auto-Fixes Applied:**\n{actions_taken}"
        
        color = self.color_map["critical"] if any("🔴" in i for i in issues_list) else self.color_map["warning"]
        
        self._send_embed(
            title=f"⚠️ {self.team_name} - Issues",
            description=message[:4000],
            color=color
        )
    
    def post_full_diagnostic(self, claude_analysis, scan_number, tools_used):
        """
        Tier 3: Full detailed analysis from Claude
        """
        # Add metadata
        analysis_with_meta = f"**Scan #{scan_number}** | Tools: {len(tools_used)}\n\n{claude_analysis}"
        
        self._send_embed(
            title=f"🤖 {self.team_name} - Full Analysis #{scan_number}",
            description=analysis_with_meta[:4000],
            color=self.color_map["info"]
        )
    
    def post_connection_alert(self, message, severity):
        """Alert for connection status changes"""
        self._send_embed(
            title="🔌 Connection Status",
            description=message,
            color=self.color_map[severity]
        )
    
    def post_startup_message(self):
        """Initial startup notification"""
        message = """✅ **Agentic AI Monitor ONLINE**

**Configuration:**
🤖 Claude Sonnet 4.6 with tool use
🔍 Scanning every 30 seconds
🔌 Connection watchdog every 5 seconds
🛡️ Auto-fix Tier 1 attacks: ENABLED
📊 Scoreboard scraping: ENABLED

**Auto-Fix Capabilities:**
✅ Restart crashed services
✅ Fix SSH port 2222→22
✅ Remove PROMPT_COMMAND traps
✅ Create missing files
✅ Remove backdoor users
✅ Clean sudoers.d exploits
✅ Fix config errors

**Monitoring:** SMB + SSH
**Target:** Competition machine via jumphost

Ready to defend! 🚀"""
        
        self._send_embed(
            title=f"🟢 {self.team_name} Defense System Started",
            description=message,
            color=self.color_map["success"]
        )
    
    def _send_embed(self, title, description, color):
        """Send Discord webhook embed"""
        try:
            embed = {
                "embeds": [{
                    "title": title,
                    "description": description,
                    "color": color,
                    "timestamp": datetime.utcnow().isoformat()
                }]
            }
            
            response = requests.post(self.webhook_url, json=embed, timeout=5)
            response.raise_for_status()
            
        except Exception as e:
            print(f"Discord post failed: {e}")