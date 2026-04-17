# scoreboard_scraper.py - Scrapes NCAE scoreboard for service status
import requests
from bs4 import BeautifulSoup
import os
from dotenv import load_dotenv
import time

load_dotenv()

class ScoreboardScraper:
    """
    Scrapes NCAE CyberGames scoreboard to get service status.
    Requires login credentials.
    """
    
    def __init__(self):
        self.url = os.getenv("SCOREBOARD_URL")
        self.username = os.getenv("SCOREBOARD_USERNAME")
        self.password = os.getenv("SCOREBOARD_PASSWORD")
        self.session = requests.Session()
        self.logged_in = False
        
    def login(self):
        """Login to scoreboard"""
        try:
            # Most scoreboards use a login form
            # Try to find login page first
            login_url = self.url.replace('/scoreboard', '/login')
            
            # Get login page to find CSRF token if needed
            response = self.session.get(login_url, timeout=10)
            
            # Simple login attempt
            login_data = {
                'username': self.username,
                'password': self.password
            }
            
            response = self.session.post(login_url, data=login_data, timeout=10)
            
            # Check if login worked (scoreboard URL should be accessible)
            scoreboard_check = self.session.get(self.url, timeout=10)
            
            if scoreboard_check.status_code == 200 and 'logout' in scoreboard_check.text.lower():
                self.logged_in = True
                print("✅ Scoreboard login successful")
                return True
            else:
                print("⚠️ Scoreboard login may have failed")
                return False
                
        except Exception as e:
            print(f"Scoreboard login error: {e}")
            return False
    
    def get_service_status(self):
        """
        Scrape scoreboard for service status.
        Returns dict: {"SMB Read": "UP", "SMB Write": "DOWN", ...}
        """
        if not self.logged_in:
            self.login()
        
        try:
            response = self.session.get(self.url, timeout=10)
            soup = BeautifulSoup(response.text, 'html.parser')
            
            # Parse service status
            # Format depends on actual scoreboard HTML
            # Common patterns:
            services = {}
            
            # Try to find service status elements
            # Look for checkmarks, X marks, UP/DOWN text
            status_elements = soup.find_all(['div', 'td', 'span'], class_=lambda x: x and ('service' in x.lower() or 'status' in x.lower()))
            
            for elem in status_elements:
                text = elem.get_text(strip=True)
                
                # Extract service name and status
                if any(svc in text for svc in ['SMB', 'SSH', 'Read', 'Write', 'Login']):
                    # Determine if UP or DOWN
                    is_up = any(indicator in text for indicator in ['✓', '✅', 'UP', 'success', 'green'])
                    is_down = any(indicator in text for indicator in ['✗', '❌', 'DOWN', 'fail', 'red'])
                    
                    status = "UP" if is_up else "DOWN" if is_down else "UNKNOWN"
                    services[text] = status
            
            # If parsing failed, return raw HTML snippet for debugging
            if not services:
                return {"_raw_html": response.text[:1000]}
            
            return services
            
        except Exception as e:
            return {"error": str(e)}
    
    def get_debug_info(self):
        """Get detailed scoreboard debug info (errors, messages)"""
        if not self.logged_in:
            self.login()
        
        try:
            response = self.session.get(self.url, timeout=10)
            soup = BeautifulSoup(response.text, 'html.parser')
            
            # Look for error messages or debug info
            errors = soup.find_all(['div', 'span'], class_=lambda x: x and 'error' in x.lower())
            
            error_messages = []
            for err in errors:
                error_messages.append(err.get_text(strip=True))
            
            return {"errors": error_messages, "raw_html_sample": response.text[:2000]}
            
        except Exception as e:
            return {"error": str(e)}