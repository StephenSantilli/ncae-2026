# test_connection.py - Verify everything works before full deployment
from ssh_tools import CompetitionSSH
from discord_poster import DiscordPoster
from dotenv import load_dotenv

load_dotenv()

print("🧪 Testing SSH connection...")
ssh = CompetitionSSH()

# Test basic SSH
result = ssh.run_command("whoami")
print(f"✅ SSH works! User: {result.strip()}")

# Test SMB check
print("\n🧪 Testing SMB status tool...")
smb_status = ssh.check_smb_status()
print(smb_status[:500])

# Test Discord
print("\n🧪 Testing Discord webhook...")
discord = DiscordPoster()
discord.post_analysis("🧪 Test message from agent setup", "info")
print("✅ Check your Discord channel!")

print("\n✅ All systems ready! Run: python agentic_monitor.py")