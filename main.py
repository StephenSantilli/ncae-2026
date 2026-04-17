# main.py - Main orchestrator for agentic defense system
import time
import threading
from dotenv import load_dotenv
import os

from ssh_tools import CompetitionSSH
from claude_agent import ClaudeAgent
from auto_fixer import AutoFixer
from discord_poster import DiscordPoster
from connection_watchdog import ConnectionWatchdog
from scoreboard_scraper import ScoreboardScraper
from hardening import PreemptiveHardening

load_dotenv()

class AgenticDefenseSystem:
    """
    Complete agentic AI defense system for NCAE CyberGames.
    
    Architecture:
    - Thread 1: Connection watchdog (5s)
    - Thread 2: Claude agent (30s)
    - Thread 3: Scoreboard scraper (60s)
    - Main thread: Coordination
    """
    
    def __init__(self):
        print("🚀 Initializing Agentic Defense System...")
        print(f"🎯 Team: {os.getenv('TEAM_NAME')}")
        print(f"🖥️  Target: {os.getenv('COMPETITION_USER')}@{os.getenv('COMPETITION_IP')}")
        print(f"📡 Jumphost: {os.getenv('JUMPHOST_USER')}@{os.getenv('JUMPHOST_IP')}")
        
        # Initialize components
        self.ssh = CompetitionSSH()
        self.discord = DiscordPoster()
        self.auto_fixer = AutoFixer(self.ssh)
        self.agent = ClaudeAgent(self.ssh, self.auto_fixer)
        self.watchdog = ConnectionWatchdog(self.ssh, self.discord)
        self.scoreboard = ScoreboardScraper()
        self.hardening = PreemptiveHardening(self.ssh)
        
        # State
        self.agent_paused = False
        self.scan_interval = int(os.getenv("AGENT_SCAN_INTERVAL", 30))
        self.scoreboard_interval = int(os.getenv("SCOREBOARD_CHECK_INTERVAL", 60))
        
    def start(self):
        """Start all monitoring components"""
        print("\n" + "="*60)
        print("STARTING DEFENSE SYSTEM")
        print("="*60)
        
        # Step 1: Test SSH connection
        print("\n1️⃣ Testing SSH connection...")
        try:
            self.ssh.connect()
            print("   ✅ SSH connection established")
        except Exception as e:
            print(f"   ❌ SSH connection failed: {e}")
            print("   Fix your .env credentials and try again")
            return
        
        # Step 2: Send startup message to Discord
        print("\n2️⃣ Notifying Discord...")
        self.discord.post_startup_message()
        print("   ✅ Discord notified")
        
        # Step 3: Run pre-emptive hardening
        print("\n3️⃣ Running pre-emptive hardening...")
        hardening_results = self.hardening.run_all_hardening()
        for result in hardening_results:
            print(f"   {result}")
        
        # Step 4: Start connection watchdog
        print("\n4️⃣ Starting connection watchdog...")
        self.watchdog.start()
        print(f"   ✅ Watchdog active (checking every {os.getenv('CONNECTION_CHECK_INTERVAL')}s)")
        
        # Step 5: Start scoreboard scraper
        print("\n5️⃣ Starting scoreboard scraper...")
        scoreboard_thread = threading.Thread(target=self._scoreboard_loop, daemon=True)
        scoreboard_thread.start()
        print(f"   ✅ Scoreboard scraper active (every {self.scoreboard_interval}s)")
        
        # Step 6: Start main agent loop
        print("\n6️⃣ Starting Claude agentic monitor...")
        print(f"   ✅ Agent active (scanning every {self.scan_interval}s)")
        print("\n" + "="*60)
        print("ALL SYSTEMS OPERATIONAL")
        print("="*60 + "\n")
        
        # Main agent loop
        self._agent_loop()
    
    def _agent_loop(self):
        """Main Claude agent scanning loop"""
        scan_count = 0
        
        while True:
            # Check if watchdog wants us to pause
            if self.watchdog.agent_should_pause:
                print("⏸️  Agent paused - connection reconnecting...")
                time.sleep(2)
                continue
            
            scan_count += 1
            print(f"\n{'─'*60}")
            print(f"🔍 SCAN #{scan_count} at {time.strftime('%H:%M:%S')}")
            print(f"{'─'*60}")
            
            try:
                # Quick health check first (fast, no AI)
                health_data = self.ssh.quick_health_check()
                
                # Parse for glance view
                smb_up = "smbd" in health_data
                ssh_up = "sshd" in health_data
                port_445 = ":445" in health_data
                port_22 = ":22" in health_data
                file_count = self._extract_file_count(health_data)
                
                # Post glance view (Tier 1 - always)
                self.discord.post_glance_view(smb_up, ssh_up, port_445, port_22, file_count)
                
                # Decide if deep analysis needed
                needs_deep_analysis = not smb_up or not ssh_up or not port_445 or not port_22
                
                if needs_deep_analysis or scan_count == 1:
                    # Run full Claude analysis with tools
                    print("  🤖 Running deep Claude analysis...")
                    
                    analysis, actions, severity = self.agent.analyze_and_fix(
                        scoreboard_data=getattr(self, '_last_scoreboard_data', None)
                    )
                    
                    # Post issues summary (Tier 2 - only if issues)
                    issues_found = self._extract_issues(analysis)
                    if issues_found or actions:
                        self.discord.post_issues_summary(issues_found, actions)
                    
                    # Post full diagnostic (Tier 3 - detailed)
                    self.discord.post_full_diagnostic(analysis, scan_count, tools_used=[])
                    
                    print(f"  ✅ Analysis complete | Severity: {severity}")
                    
                else:
                    print("  ✅ All services healthy - skipping deep analysis")
                
            except Exception as e:
                print(f"  ❌ Scan error: {e}")
                self.discord.post_issues_summary([f"🔴 Scan failed: {str(e)}"], "")
            
            # Wait for next scan
            print(f"  💤 Next scan in {self.scan_interval}s...")
            time.sleep(self.scan_interval)
    
    def _scoreboard_loop(self):
        """Separate thread for scoreboard scraping"""
        time.sleep(10)  # Wait for initial setup
        
        while True:
            try:
                scoreboard_data = self.scoreboard.get_service_status()
                self._last_scoreboard_data = scoreboard_data
                
                # Check for discrepancies between scoreboard and actual state
                # (e.g., scoreboard says DOWN but service is running)
                
            except Exception as e:
                print(f"Scoreboard scrape error: {e}")
            
            time.sleep(self.scoreboard_interval)
    
    def _extract_file_count(self, health_data):
        """Extract file count from health check output"""
        try:
            for line in health_data.split('\n'):
                if line.strip().isdigit():
                    return int(line.strip())
        except:
            pass
        return 0
    
    def _extract_issues(self, analysis):
        """Extract issue list from Claude's analysis"""
        issues = []
        for line in analysis.split('\n'):
            if line.strip().startswith('🔴') or line.strip().startswith('🟡'):
                issues.append(line.strip())
        return issues


if __name__ == "__main__":
    system = AgenticDefenseSystem()
    system.start()