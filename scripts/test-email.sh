#!/bin/bash
# Test Email Notification Script for Secret NAS
# This script sends a test email using the configuration from /etc/nas-monitor/config.json

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "  Secret NAS Email Notification Test"
echo "=========================================="
echo ""

# Check if config file exists
if [ ! -f /etc/nas-monitor/config.json ]; then
    echo -e "${RED}✗ Error: Configuration file not found at /etc/nas-monitor/config.json${NC}"
    echo "  Please run setup.sh first to configure email notifications."
    exit 1
fi

echo "Sending test email..."
echo ""

# Send test email using Python
python3 << 'EOF'
import sys
import json
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from datetime import datetime
import socket

try:
    # Load configuration
    with open('/etc/nas-monitor/config.json', 'r') as f:
        config = json.load(f)

    email_config = config['notification']['email']

    # Create email message
    msg = MIMEMultipart()
    msg['From'] = email_config['from']
    msg['To'] = email_config['to']
    msg['Subject'] = '[TEST] Secret NAS Email Notification Test'

    hostname = socket.gethostname()
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    share_name = config.get('share_name', 'secure_share')

    body = f"""
This is a test email from Secret NAS.

If you receive this email, your notification settings are configured correctly.

NAS Information:
  Host: {hostname}
  Share: {share_name}
  Test Time: {timestamp}

Configuration:
  To: {email_config['to']}
  From: {email_config['from']}
  SMTP Server: {email_config['smtp_server']}:{email_config['smtp_port']}
  TLS: {'Enabled' if email_config.get('use_tls', True) else 'Disabled'}

This is an automated test message from Secret NAS monitoring system.
"""

    msg.attach(MIMEText(body, 'plain'))

    # Connect to SMTP server
    server = smtplib.SMTP(email_config['smtp_server'], email_config['smtp_port'])

    if email_config.get('use_tls', True):
        server.starttls()

    # Login
    server.login(email_config['username'], email_config['password'])

    # Send email
    server.send_message(msg)
    server.quit()

    print(f"\033[0;32m✓ Test email sent successfully!\033[0m")
    print(f"  From: {email_config['from']}")
    print(f"  To: {email_config['to']}")
    print(f"  SMTP: {email_config['smtp_server']}:{email_config['smtp_port']}")
    print("")
    print("Please check your inbox to verify the email was delivered.")
    print("")
    print("\033[1;33mNote:\033[0m If you're sending to the same Gmail address as the sender,")
    print("      Gmail may not deliver the email to your inbox.")
    print("      Consider using a different email address for testing.")

except FileNotFoundError:
    print("\033[0;31m✗ Error: Configuration file not found\033[0m", file=sys.stderr)
    sys.exit(1)
except KeyError as e:
    print(f"\033[0;31m✗ Error: Missing configuration key: {e}\033[0m", file=sys.stderr)
    print("  Please check your /etc/nas-monitor/config.json file.", file=sys.stderr)
    sys.exit(1)
except smtplib.SMTPAuthenticationError as e:
    print(f"\033[0;31m✗ Error: SMTP authentication failed\033[0m", file=sys.stderr)
    print(f"  {e}", file=sys.stderr)
    print("  Please check your username and password in the configuration.", file=sys.stderr)
    sys.exit(1)
except smtplib.SMTPException as e:
    print(f"\033[0;31m✗ Error: SMTP error occurred\033[0m", file=sys.stderr)
    print(f"  {e}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"\033[0;31m✗ Error: Failed to send test email\033[0m", file=sys.stderr)
    print(f"  {type(e).__name__}: {e}", file=sys.stderr)
    import traceback
    traceback.print_exc()
    sys.exit(1)
EOF
