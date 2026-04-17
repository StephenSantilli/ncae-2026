# connection_watchdog.py - Monitors SSH connection every 5s
import time
import threading
from dotenv import load_dotenv
import os

load_dotenv()

class ConnectionWatchdog:
    """
    Monitors SSH connection health every 5 seconds.
    Auto-reconnects if dropped.
    Alerts Discord on status changes.
    Pauses main agent while reconnecting.
    NO TOKEN USAGE.
    """
    
    def __init__(self, ssh_client, discord_poster):
        self.ssh = ssh_client
        self.discord = discord_poster
        self.interval = int(os.getenv("CONNECTION_CHECK_INTERVAL", 5))
        
        self.connection_ok = False
        self.reconnecting = False
        self.agent_should_pause = False
        
        self.consecutive_failures = 0
        self.total_reconnects = 0
        
    def start(self):
        """Start watchdog in background thread"""
        thread = threading.Thread(target=self._monitor_loop, daemon=True)
        thread.start()
        print(f"🔌 Connection watchdog started (checking every {self.interval}s)")
    
    def _monitor_loop(self):
        """Main monitoring loop"""
        while True:
            try:
                # Quick connection test
                is_connected = self.ssh.check_connection()
                
                # Connection state changed
                if is_connected and not self.connection_ok:
                    # RESTORED
                    self.connection_ok = True
                    self.reconnecting = False
                    self.agent_should_pause = False
                    self.consecutive_failures = 0
                    
                    self.discord.post_connection_alert(
                        f"🟢 **Connection RESTORED**\nTotal reconnects this session: {self.total_reconnects}",
                        "success"
                    )
                    print(f"✅ Connection restored at {time.strftime('%H:%M:%S')}")
                
                elif not is_connected and self.connection_ok:
                    # LOST
                    self.connection_ok = False
                    self.consecutive_failures += 1
                    
                    self.discord.post_connection_alert(
                        f"🔴 **Connection LOST**\nAttempting auto-reconnect...",
                        "critical"
                    )
                    print(f"❌ Connection lost at {time.strftime('%H:%M:%S')}")
                    
                    # Trigger reconnect
                    self._attempt_reconnect()
                
                elif not is_connected:
                    # STILL DOWN
                    self.consecutive_failures += 1
                    
                    if self.consecutive_failures % 6 == 0:  # Every 30s (6 * 5s)
                        self.discord.post_connection_alert(
                            f"⚠️ Still disconnected ({self.consecutive_failures * 5}s)...",
                            "warning"
                        )
                    
                    self._attempt_reconnect()
                
            except Exception as e:
                print(f"Watchdog error: {e}")
            
            time.sleep(self.interval)
    
    def _attempt_reconnect(self):
        """Attempt to reconnect (pauses main agent)"""
        if self.reconnecting:
            return  # Already trying
        
        self.reconnecting = True
        self.agent_should_pause = True  # Signal main agent to pause
        
        try:
            print(f"🔄 Attempting reconnect at {time.strftime('%H:%M:%S')}")
            self.ssh.cleanup()
            self.ssh.connect()
            
            self.connection_ok = True
            self.reconnecting = False
            self.agent_should_pause = False
            self.total_reconnects += 1
            
            print(f"✅ Reconnected successfully")
            
        except Exception as e:
            print(f"❌ Reconnect failed: {e}")
            self.reconnecting = False
            # Will retry in 5 seconds