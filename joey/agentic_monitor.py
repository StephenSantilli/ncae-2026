# agentic_monitor.py - Main AI agent with Claude tool use
import os
import time
import json
from anthropic import Anthropic
from dotenv import load_dotenv
from ssh_tools import CompetitionSSH
from discord_poster import DiscordPoster

load_dotenv()

class AgenticMonitor:
    """
    Agentic AI that monitors competition machine, detects issues,
    and provides exact fix commands using Claude's tool use.
    """
    
    def __init__(self):
        self.ssh = CompetitionSSH()
        self.discord = DiscordPoster()
        self.claude = Anthropic(api_key=os.getenv("ANTHROPIC_API_KEY"))
        
        # State tracking (from exhaustive analysis)
        self.previous_state = {}
        self.restart_count = 0
        self.missing_file_count = 0
        self.known_good_configs = {}
        
        # Auto-fix settings
        self.auto_restart = os.getenv("AUTO_RESTART_SERVICES", "true").lower() == "true"
        self.auto_create_files = os.getenv("AUTO_CREATE_FILES", "true").lower() == "true"
        self.auto_remove_backdoors = os.getenv("AUTO_REMOVE_BACKDOOR_USERS", "true").lower() == "true"
        
    def define_tools(self):
        """Define tools Claude can use - based on your previous issues"""
        return [
            {
                "name": "read_smb_config",
                "description": "Reads /etc/samba/smb.conf AND checks for include directives (Issue #1 - always check includes!). Returns both main and included config files.",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "check_smb_status",
                "description": "Complete SMB diagnostic: processes, ports (445,139), shares (checks if [files] exists), testparm validation. Use this FIRST when troubleshooting SMB (Issue #14).",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "read_smb_logs",
                "description": "Read SMB log file to see errors, authentication failures, and recent activity",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "lines": {
                            "type": "number",
                            "description": "Number of lines to read from end of log",
                            "default": 50
                        }
                    },
                    "required": []
                }
            },
            {
                "name": "read_ssh_config",
                "description": "Reads /etc/ssh/sshd_config (with 'd' - the SERVER config, not client config). Issue #9.",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "check_ssh_status",
                "description": "Complete SSH diagnostic: processes, port 22 listening (flags if 2222 instead - Issue #7), config syntax test",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "read_auth_logs",
                "description": "Read SSH authentication logs for failed logins, attacks",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "lines": {
                            "type": "number",
                            "description": "Number of lines to read",
                            "default": 50
                        }
                    },
                    "required": []
                }
            },
            {
                "name": "list_files",
                "description": "List files in directory with permissions and ownership. Essential for checking /mnt/files for missing .data files.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "directory": {
                            "type": "string",
                            "description": "Directory path to list",
                            "default": "/mnt/files"
                        }
                    },
                    "required": ["directory"]
                }
            },
            {
                "name": "check_recent_changes",
                "description": "Find files modified in last N minutes. CRITICAL for detecting red team tampering with configs. Issue #15.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "minutes": {
                            "type": "number",
                            "description": "How many minutes back to check",
                            "default": 10
                        }
                    },
                    "required": []
                }
            },
            {
                "name": "check_suspicious_users",
                "description": "Detect backdoor users, check /etc/sudoers.d/ for NOPASSWD entries. From your previous experience with blackteam/redteam users.",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "check_malicious_traps",
                "description": "Detect PROMPT_COMMAND math problems, bash wrapper functions, malicious aliases. Issue #5 - math problem trap.",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "check_cron_backdoors",
                "description": "Check all crontabs for malicious scheduled tasks",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "find_suid_binaries",
                "description": "Find SUID binaries for privilege escalation detection",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "restart_smb",
                "description": "Auto-restart SMB services (smbd + nmbd). Only use if SMB is confirmed down.",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "restart_ssh",
                "description": "Auto-restart SSH service. Only use if SSH is confirmed down.",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "create_file",
                "description": "Create missing file in /mnt/files (typically .data files from scoreboard errors). Issue #2 pattern.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "filepath": {
                            "type": "string",
                            "description": "Full path to file to create"
                        },
                        "content": {
                            "type": "string",
                            "description": "File content",
                            "default": "scoring data"
                        }
                    },
                    "required": ["filepath"]
                }
            },
            {
                "name": "backup_config",
                "description": "Backup a config file before editing. Issue #27 - ALWAYS backup first.",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "filepath": {
                            "type": "string",
                            "description": "File to backup"
                        }
                    },
                    "required": ["filepath"]
                }
            }
        ]
    
    def execute_tool(self, tool_name, tool_input):
        """Execute a tool called by Claude"""
        
        # Map tool names to SSH methods
        tool_map = {
            "read_smb_config": lambda: self.ssh.read_smb_config(),
            "check_smb_status": lambda: self.ssh.check_smb_status(),
            "read_smb_logs": lambda: self.ssh.read_smb_logs(tool_input.get("lines", 50)),
            "read_ssh_config": lambda: self.ssh.read_ssh_config(),
            "check_ssh_status": lambda: self.ssh.check_ssh_status(),
            "read_auth_logs": lambda: self.ssh.read_auth_logs(tool_input.get("lines", 50)),
            "list_files": lambda: self.ssh.list_files(tool_input.get("directory", "/mnt/files")),
            "check_recent_changes": lambda: self.ssh.check_recent_changes(tool_input.get("minutes", 10)),
            "check_suspicious_users": lambda: self.ssh.check_suspicious_users(),
            "check_malicious_traps": lambda: self.ssh.check_malicious_traps(),
            "check_cron_backdoors": lambda: self.ssh.check_cron_backdoors(),
            "find_suid_binaries": lambda: self.ssh.find_suid_binaries(),
            "restart_smb": lambda: self.ssh.restart_smb() if self.auto_restart else "Auto-restart disabled",
            "restart_ssh": lambda: self.ssh.restart_ssh() if self.auto_restart else "Auto-restart disabled",
            "create_file": lambda: self.ssh.create_file(tool_input.get("filepath"), tool_input.get("content", "scoring data")) if self.auto_create_files else "Auto-create disabled",
            "backup_config": lambda: self.ssh.backup_config(tool_input.get("filepath"))
        }
        
        if tool_name in tool_map:
            return tool_map[tool_name]()
        else:
            return f"Unknown tool: {tool_name}"
    
    def run_agentic_scan(self):
        """
        Main agentic loop - Claude decides what tools to use based on situation.
        Implements all 30 issues from exhaustive analysis.
        """
        
        # Build context from previous scans
        context_notes = []
        if self.restart_count >= 3:
            context_notes.append(f"STATE: Restart requested {self.restart_count}x - offer script (Issue #3)")
        if self.missing_file_count >= 2:
            context_notes.append(f"STATE: {self.missing_file_count} missing files - batch creation needed (Issue #2)")
        
        context_injection = "\n".join(context_notes) if context_notes else ""
        
        # Initial message to Claude
        initial_prompt = f"""You are monitoring a CyberGames competition machine defending SMB and SSH services.

CRITICAL BEHAVIORS FROM PREVIOUS ISSUES:
- Issue #1: ALWAYS check for include directives in configs (grep -i include)
- Issue #2: After 2nd missing file, batch create instead of individual
- Issue #3: After 3rd restart, offer script instead of manual commands  
- Issue #14: SMB troubleshooting order: share exists? → running? → listening? → files? → permissions? → config valid?
- Issue #7: SSH must be on port 22, flag if on 2222
- Issue #27: ALWAYS backup before editing configs

{context_injection}

Your task:
1. Check if SMB and SSH are healthy
2. If issues found, use tools to diagnose deeply
3. Detect red team tampering (recent config changes, backdoor users, malicious traps)
4. Provide EXACT fix commands with backup + verification steps
5. Auto-fix safe issues (restart services, create files) - you have permission
6. ASK before editing configs or removing users

Available tools: {[tool["name"] for tool in self.define_tools()]}

Start with a quick health check of both services."""

        messages = [{"role": "user", "content": initial_prompt}]
        
        # Agentic loop - let Claude use tools until it's done
        while True:
            response = self.claude.messages.create(
                model="claude-sonnet-4-20250514",
                max_tokens=4000,
                tools=self.define_tools(),
                messages=messages
            )
            
            # Check if Claude wants to use tools
            if response.stop_reason == "tool_use":
                # Extract tool calls
                tool_results = []
                for block in response.content:
                    if block.type == "tool_use":
                        tool_name = block.name
                        tool_input = block.input
                        
                        print(f"🔧 Claude calling tool: {tool_name}")
                        
                        # Execute tool via SSH
                        result = self.execute_tool(tool_name, tool_input)
                        
                        # Track patterns
                        if "restart" in tool_name.lower():
                            self.restart_count += 1
                        if "create_file" in tool_name:
                            self.missing_file_count += 1
                        
                        tool_results.append({
                            "type": "tool_result",
                            "tool_use_id": block.id,
                            "content": result
                        })
                
                # Continue conversation with tool results
                messages.append({"role": "assistant", "content": response.content})
                messages.append({"role": "user", "content": tool_results})
                
            else:
                # Claude is done, extract final analysis
                final_text = ""
                for block in response.content:
                    if hasattr(block, 'text'):
                        final_text += block.text
                
                return final_text
    
    def continuous_monitor(self):
        """Continuous monitoring loop - runs every 30 seconds"""
        
        interval = int(os.getenv("SCAN_INTERVAL", 30))
        
        self.discord.send_startup_message()
        
        print(f"🤖 Starting continuous monitoring (every {interval}s)")
        print(f"🔐 SSH: {os.getenv('COMPETITION_USER')}@{os.getenv('COMPETITION_IP')}")
        print(f"🎯 Team: {os.getenv('TEAM_NAME')}")
        print(f"⚙️  Auto-restart: {self.auto_restart}")
        print(f"📁 Auto-create files: {self.auto_create_files}")
        
        scan_count = 0
        
        while True:
            scan_count += 1
            print(f"\n{'='*60}")
            print(f"SCAN #{scan_count} at {time.strftime('%H:%M:%S')}")
            print(f"{'='*60}")
            
            try:
                # Run agentic analysis
                analysis = self.run_agentic_scan()
                
                # Determine severity
                if "🔴 CRITICAL" in analysis or "DOWN" in analysis:
                    severity = "critical"
                elif "🟡 WARNING" in analysis or "⚠️" in analysis:
                    severity = "warning"
                elif "🔴" not in analysis and ("🟢" in analysis or "OK" in analysis):
                    severity = "success"
                else:
                    severity = "info"
                
                # Post to Discord
                self.discord.post_analysis(analysis, severity, scan_count)
                
                print(f"✅ Scan complete, posted to Discord")
                
            except Exception as e:
                error_msg = f"⚠️ **Scan #{scan_count} failed**\n```{str(e)}```"
                self.discord.post_analysis(error_msg, "warning", scan_count)
                print(f"❌ Error: {e}")
            
            # Wait for next scan
            print(f"💤 Sleeping {interval}s until next scan...")
            time.sleep(interval)


if __name__ == "__main__":
    monitor = AgenticMonitor()
    monitor.continuous_monitor()