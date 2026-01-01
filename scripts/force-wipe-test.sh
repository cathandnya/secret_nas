#!/bin/bash
#
# Force Wipe Test Script
# Set last access date to the past to immediately trigger deletion test
#
# Usage:
#   sudo ./scripts/force-wipe-test.sh [days]
#
# Examples:
#   sudo ./scripts/force-wipe-test.sh 31  # Set to 31 days ago (default deletion after 30 days)
#   sudo ./scripts/force-wipe-test.sh 8   # Set to 8 days ago (warning email at 7 days)
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

STATE_FILE="/var/lib/nas-monitor/last_access.json"
DAYS_AGO=${1:-31}

echo ""
echo "=========================================="
echo "  Force Wipe Test Script"
echo "=========================================="
echo ""

# Check root permissions
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root"
    echo "Usage: sudo $0 [days]"
    exit 1
fi

# Check arguments
if ! [[ "$DAYS_AGO" =~ ^[0-9]+$ ]]; then
    log_error "Argument must be a positive integer"
    echo "Usage: sudo $0 [days]"
    exit 1
fi

log_step "1. Checking current state..."

# Check config file
CONFIG_FILE="/etc/nas-monitor/config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Config file not found: $CONFIG_FILE"
    log_info "Please run setup.sh first"
    exit 1
fi

# Get deletion days
INACTIVITY_DAYS=$(jq -r '.inactivity_days' "$CONFIG_FILE" 2>/dev/null || echo "30")
log_info "Configured deletion days: $INACTIVITY_DAYS days"

# Get warning days
WARNING_DAYS=$(jq -r '.warning_days[]' "$CONFIG_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
if [ -n "$WARNING_DAYS" ]; then
    log_info "Warning email days: $WARNING_DAYS days before deletion"
fi

echo ""

# Check state file
if [ -f "$STATE_FILE" ]; then
    CURRENT_ACCESS=$(jq -r '.last_access' "$STATE_FILE" 2>/dev/null || echo "unknown")
    log_info "Current last access time: $CURRENT_ACCESS"
else
    log_warn "State file does not exist: $STATE_FILE"
fi

echo ""
log_step "2. Setting last access date to $DAYS_AGO days ago..."

# Calculate past date (ISO 8601 format, offset-naive without Z suffix)
# access_tracker.py compares with datetime.now() (offset-naive), so no Z suffix
PAST_DATE=$(date -d "$DAYS_AGO days ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || \
            date -v-${DAYS_AGO}d '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)

if [ -z "$PAST_DATE" ]; then
    log_error "Failed to calculate date"
    exit 1
fi

log_info "Setting date to: $PAST_DATE"

# Create state file directory
mkdir -p "$(dirname "$STATE_FILE")"

# Write state file
cat > "$STATE_FILE" <<EOF
{
  "last_access": "$PAST_DATE"
}
EOF

chmod 644 "$STATE_FILE"
log_info "✓ State file updated successfully"

echo ""
log_step "3. Expected behavior..."

ELAPSED_DAYS=$DAYS_AGO

if [ "$ELAPSED_DAYS" -ge "$INACTIVITY_DAYS" ]; then
    log_error "⚠️  Deletion criteria met!"
    log_warn "Data will be deleted on next check (within 1 hour)"
    echo ""
    log_warn "Deletion process:"
    log_warn "  - Keyfile (/root/.nas-keyfile) will be shredded completely"
    log_warn "  - LUKS header will be erased with cryptsetup erase"
    log_warn "  - Data on USB will be PERMANENTLY UNRECOVERABLE"
elif [ -n "$WARNING_DAYS" ]; then
    # Check warning days
    for WARNING_DAY in $(echo "$WARNING_DAYS" | tr ',' ' '); do
        if [ "$ELAPSED_DAYS" -ge "$WARNING_DAY" ]; then
            log_warn "⚠️  Warning email criteria met"
            log_info "Warning email will be sent on next check"
            break
        fi
    done
else
    log_info "Deletion/warning criteria not yet met"
    REMAINING=$((INACTIVITY_DAYS - ELAPSED_DAYS))
    log_info "Days until deletion: $REMAINING days"
fi

echo ""
log_step "4. Restarting nas-monitor service to trigger deletion test..."

log_info "Restarting service (deletion process will execute immediately)"
systemctl restart nas-monitor

sleep 2

log_info "Checking deletion logs..."
echo ""
journalctl -u nas-monitor -n 50 --no-pager | grep -E "WIPE|delete|shred|LUKS" || log_warn "Deletion logs not yet available"

echo ""
log_step "5. Monitoring deletion process..."

echo ""
log_info "[Real-time Log Monitoring]"
echo "  Monitor logs in real-time with:"
echo -e "     ${YELLOW}sudo journalctl -u nas-monitor -f${NC}"
echo ""

log_info "[To Cancel Deletion]"
echo "  Access Samba to update last access time, or"
echo "  Delete state file and restart service:"
echo -e "     ${YELLOW}sudo rm -f $STATE_FILE${NC}"
echo -e "     ${YELLOW}sudo systemctl restart nas-monitor${NC}"
echo ""

log_info "[Cleanup After Test]"
echo "  After deletion, re-setup USB with:"
echo -e "     ${YELLOW}sudo ./scripts/re-encrypt-usb.sh${NC}"
echo ""

log_warn "⚠️  WARNING: Do not use this script in production"
log_warn "       Data may be actually deleted"
echo ""
