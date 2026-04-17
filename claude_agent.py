# claude_agent.py - FULLY AUTONOMOUS VERSION (COMPLETE)
from anthropic import Anthropic
import os
from dotenv import load_dotenv
from attack_patterns import KNOWN_ATTACKS
import time
import re

load_dotenv()

class ClaudeAgent:
    """Autonomous agent - detects and FIXES without asking"""
    
    def __init__(self, ssh_tools, auto_fixer):
        self.claude = Anthropic(api_key=os.getenv("ANTHROPIC_API_KEY"))
        self.ssh = ssh_tools
        self.auto_fixer = auto_fixer
        
        self.previous_snapshot = None
        self.restart_count = 0
        self.missing_file_count = 0
        self.scan_count = 0
        self.fixes_this_session = []
    
    def define_tools_for_claude(self):
        """Define all tools Claude can call"""
        return [
            {
                "name": "quick_health_check",
                "description": "Fast SMB/SSH/port check",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "check_smb_status",
                "description": "Full SMB diagnostic: processes, ports, shares, config",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "check_ssh_status",
                "description": "Full SSH diagnostic: processes, port (flags if 2222), config test",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "read_smb_config",
                "description": "Read SMB configs, checks include directives",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "read_ssh_config",
                "description": "Read /etc/ssh/sshd_config",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "check_recent_changes",
                "description": "Find files modified in last N minutes - detects red team tampering",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "minutes": {
                            "type": "number",
                            "default": 5
                        }
                    },
                    "required": []
                }
            },
            {
                "name": "check_suspicious_users",
                "description": "Detect backdoor users, NOPASSWD sudo",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "check_malicious_traps",
                "description": "Detect PROMPT_COMMAND math traps, bash wrappers",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": []
                }
            },
            {
                "name": "list_files",
                "description": "List files in directory",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "directory": {
                            "type": "string",
                            "default": "/mnt/files"
                        }
                    },
                    "required": []
                }
            },
            {
                "name": "read_smb_logs",
                "description": "Read SMB error logs",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "lines": {
                            "type": "number",
                            "default": 50
                        }
                    },
                    "required": []
                }
            },
            {
                "name": "read_auth_logs",
                "description": "Read SSH authentication logs",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "lines": {
                            "type": "number",
                            "default": 50
                        }
                    },
                    "required": []
                }
            }
        ]
    
    def analyze_and_fix(self, scoreboard_data=None):
        """
        AUTONOMOUS mode: Analyze + Fix in one pass.
        Returns (report_for_discord, fixes_executed, severity)
        """
        
        print(f"  🤖 Starting autonomous analysis...")
        
        # Step 1: Quick health check (no AI, just SSH)
        try:
            health = self.ssh.quick_health_check()
        except Exception as e:
            return f"❌ Health check failed: {e}", [], "critical"
        
        # Step 2: IMMEDIATE auto-fixes based on health check
        immediate_fixes = self._auto_fix_from_health_check(health)
        
        # Step 3: Check if deep analysis needed
        has_issues = self._has_issues(health)
        
        if has_issues or self.scan_count == 0:
            print(f"  🧠 Running Claude deep analysis...")
            
            prompt = f"""Autonomous monitoring - Syracuse University CyberGames.

HEALTH CHECK:
{health}

{f'SCOREBOARD: {scoreboard_data}' if scoreboard_data else ''}

FIXES ALREADY AUTO-EXECUTED:
{chr(10).join(immediate_fixes) if immediate_fixes else 'None'}

TASK: Use tools to investigate any remaining issues. I auto-execute fixes as you discover them.

Known attacks: SSH port 2222, PROMPT_COMMAND traps, backdoor users, NOPASSWD, map to guest errors, missing [files] share.

Be CONCISE."""

            analysis, claude_fixes = self._run_claude_with_auto_fix(prompt)
            all_fixes = immediate_fixes + claude_fixes
            
        else:
            analysis = "🟢 **All services healthy**"
            all_fixes = immediate_fixes
        
        # Determine severity
        if "🔴" in analysis or "CRITICAL" in analysis:
            severity = "critical"
        elif "🟡" in analysis or all_fixes:
            severity = "warning"
        else:
            severity = "success"
        
        self.scan_count += 1
        
        return analysis, all_fixes, severity
    
    def _auto_fix_from_health_check(self, health_data):
        """Execute immediate fixes based on quick health check"""
        fixes = []
        
        try:
            # SMB down?
            if "smbd" not in health_data:
                print("    🚨 SMB down - fixing NOW")
                self.ssh.restart_smb()
                fixes.append("✅ Restarted SMB")
                self.restart_count += 1
            
            # SSH on wrong port?
            if ":2222" in health_data:
                print("    🚨 SSH port 2222 - fixing NOW")
                self.ssh.fix_ssh_port()
                fixes.append("✅ Fixed SSH port 2222→22")
            
            # Port 445 not listening but smbd running?
            if "smbd" in health_data and ":445" not in health_data:
                print("    🚨 SMB running but port 445 down - restarting")
                self.ssh.restart_smb()
                fixes.append("✅ SMB restarted (port issue)")
                
        except Exception as e:
            fixes.append(f"❌ Auto-fix error: {e}")
        
        return fixes
    
    def _run_claude_with_auto_fix(self, prompt):
        """Run Claude with tools, auto-fixing as issues found"""
        
        messages = [{"role": "user", "content": prompt}]
        fixes_during_analysis = []
        
        for iteration in range(10):
            try:
                response = self.claude.messages.create(
                    model="claude-sonnet-4-20250514",
                    max_tokens=3000,
                    tools=self.define_tools_for_claude(),
                    messages=messages
                )
                
                if response.stop_reason == "tool_use":
                    tool_results = []
                    
                    for block in response.content:
                        if block.type == "tool_use":
                            tool_name = block.name
                            tool_input = block.input
                            
                            print(f"    🔧 Tool: {tool_name}")
                            
                            # Execute tool
                            result = self._execute_tool(tool_name, tool_input)
                            
                            # Auto-fix based on result
                            fixes = self._scan_and_fix(result, tool_name)
                            if fixes:
                                fixes_during_analysis.extend(fixes)
                                result = f"{result}\n\n🔧 AUTO-FIXED:\n" + "\n".join(fixes)
                            
                            tool_results.append({
                                "type": "tool_result",
                                "tool_use_id": block.id,
                                "content": result[:8000]
                            })
                    
                    messages.append({"role": "assistant", "content": response.content})
                    messages.append({"role": "user", "content": tool_results})
                    
                else:
                    # Done
                    analysis = ""
                    for block in response.content:
                        if hasattr(block, 'text'):
                            analysis += block.text
                    
                    return analysis, fixes_during_analysis
                    
            except Exception as e:
                return f"❌ Analysis error: {e}", fixes_during_analysis
        
        return "Analysis reached max iterations", fixes_during_analysis
    
    def _execute_tool(self, tool_name, tool_input):
        """Execute SSH tool"""
        tools = {
            "quick_health_check": lambda: self.ssh.quick_health_check(),
            "check_smb_status": lambda: self.ssh.check_smb_status(),
            "check_ssh_status": lambda: self.ssh.check_ssh_status(),
            "read_smb_config": lambda: self.ssh.read_smb_config(),
            "read_ssh_config": lambda: self.ssh.read_ssh_config(),
            "check_recent_changes": lambda: self.ssh.check_recent_changes(tool_input.get("minutes", 5)),
            "check_suspicious_users": lambda: self.ssh.check_suspicious_users(),
            "check_malicious_traps": lambda: self.ssh.check_malicious_traps(),
            "list_files": lambda: self.ssh.list_files(tool_input.get("directory", "/mnt/files")),
            "read_smb_logs": lambda: self.ssh.read_smb_logs(tool_input.get("lines", 50)),
            "read_auth_logs": lambda: self.ssh.read_auth_logs(tool_input.get("lines", 50))
        }
        
        if tool_name in tools:
            return tools[tool_name]()
        return f"Unknown tool: {tool_name}"
    
    def _scan_and_fix(self, tool_result, tool_name):
        """Detect issues and FIX THEM immediately"""
        fixes = []
        
        try:
            # SSH port 2222
            if ":2222" in tool_result and "sshd" in tool_result:
                print("      🚨 Executing: Fix SSH port")
                self.ssh.fix_ssh_port()
                fixes.append("✅ Fixed SSH port 2222→22")
            
            # SMB down
            if "NOT running" in tool_result and "smbd" in tool_name.lower():
                print("      🚨 Executing: Restart SMB")
                self.ssh.restart_smb()
                fixes.append("✅ Restarted SMB")
                self.restart_count += 1
            
            # Backdoor users
            for user in ["blackteam", "redteam", "hacker", "attacker"]:
                if user in tool_result.lower() and "/home/" in tool_result:
                    print(f"      🚨 Executing: Remove {user}")
                    self.ssh.remove_backdoor_user(user)
                    fixes.append(f"✅ Removed {user}")
            
            # NOPASSWD
            if "NOPASSWD" in tool_result and "sudoers" in tool_result.lower():
                print("      🚨 Executing: Clean sudoers")
                self.ssh.remove_sudoers_d()
                fixes.append("✅ Removed NOPASSWD")
            
            # PROMPT_COMMAND
            if "PROMPT_COMMAND" in tool_result and "RANDOM" in tool_result:
                print("      🚨 Executing: Remove math trap")
                self.ssh.remove_prompt_trap()
                fixes.append("✅ Removed PROMPT_COMMAND trap")
            
            # [files] share missing
            if tool_name == "check_smb_status" and "files" not in tool_result.lower():
                print("      🚨 Executing: Restore [files] share")
                self.ssh.restore_files_share()
                fixes.append("✅ Restored [files] share")
            
            # map to guest error
            if "map to guest found in service section" in tool_result.lower():
                print("      🚨 Executing: Fix map to guest")
                self.ssh.fix_map_to_guest()
                fixes.append("✅ Fixed map to guest location")
                
        except Exception as e:
            fixes.append(f"❌ Fix execution error: {e}")
        
        return fixes
    
    def _has_issues(self, health_data):
        """Check if health data shows problems"""
        issues = [
            "NOT running" in health_data,
            ":445" not in health_data,
            ":22 " not in health_data,
            "smbd" not in health_data,
            "sshd" not in health_data,
            ":2222" in health_data  # Wrong port
        ]
        return any(issues)
    
    def _determine_severity(self, analysis, fixes):
        """Determine alert color"""
        if "🔴" in analysis or "CRITICAL" in analysis or "DOWN" in analysis:
            return "critical"
        elif "🟡" in analysis or fixes:
            return "warning"
        else:
            return "success"