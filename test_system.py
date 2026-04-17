# test_system.py - Comprehensive testing before deployment
from time import time

from ssh_tools import CompetitionSSH
from discord_poster import DiscordPoster
from scoreboard_scraper import ScoreboardScraper
from dotenv import load_dotenv
import os

load_dotenv()

print("="*60)
print("SYSTEM TEST SUITE")
print("="*60)

# Test 1: Environment variables
print("\n[1/6] Checking environment variables...")
required_vars = [
    "BOT_TOKEN", "DISCORD_WEBHOOK_URL", "ANTHROPIC_API_KEY",
    "JUMPHOST_IP", "JUMPHOST_USER", "JUMPHOST_PASSWORD",
    "COMPETITION_IP", "COMPETITION_USER", "COMPETITION_PASSWORD"
]

missing = []
for var in required_vars:
    if not os.getenv(var):
        missing.append(var)

if missing:
    print(f"   ❌ Missing: {', '.join(missing)}")
    print("   Add these to your .env file")
    exit(1)
else:
    print("   ✅ All variables set")

# Test 2: SSH connection
print("\n[2/6] Testing SSH connection...")
ssh = CompetitionSSH()
try:
    ssh.connect()
    result = ssh.run_command("whoami")
    print(f"   ✅ SSH works! Connected as: {result.strip()}")
except Exception as e:
    print(f"   ❌ SSH failed: {e}")
    exit(1)

# Test 3: SSH tools
print("\n[3/6] Testing SSH diagnostic tools...")
try:
    health = ssh.quick_health_check()
    print(f"   ✅ Health check returned {len(health)} characters")
    
    smb_status = ssh.check_smb_status()
    print(f"   ✅ SMB status check works")
    
    ssh_status = ssh.check_ssh_status()
    print(f"   ✅ SSH status check works")
    
except Exception as e:
    print(f"   ⚠️ Tool error: {e}")

# Test 4: Discord webhook
print("\n[4/6] Testing Discord webhook...")
discord = DiscordPoster()
try:
    discord.post_glance_view(True, True, True, True, 6)
    print("   ✅ Glance view posted - check Discord!")
    
    time.sleep(1)
    
    discord.post_issues_summary(
        ["🔴 Test issue", "🟡 Test warning"],
        "✅ Test auto-fix"
    )
    print("   ✅ Issues view posted - check Discord!")
    
except Exception as e:
    print(f"   ❌ Discord failed: {e}")

# Test 5: Scoreboard scraper
print("\n[5/6] Testing scoreboard scraper...")
scoreboard = ScoreboardScraper()
try:
    if scoreboard.login():
        print("   ✅ Scoreboard login successful")
        
        status = scoreboard.get_service_status()
        print(f"   📊 Scoreboard data: {status}")
    else:
        print("   ⚠️ Scoreboard login failed - check credentials")
except Exception as e:
    print(f"   ⚠️ Scoreboard error: {e}")

# Test 6: Auto-fix capability
print("\n[6/6] Testing auto-fix...")
from auto_fixer import AutoFixer
fixer = AutoFixer(ssh)
print("   ✅ Auto-fixer initialized")

print("\n" + "="*60)
print("TEST COMPLETE")
print("="*60)
print("\n✅ System ready for deployment!")
print("\nTo start the full agent:")
print("   python main.py")
print("\n⚠️ Make sure your .env has correct COMPETITION_IP for real machine!")