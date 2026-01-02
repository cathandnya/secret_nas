#!/bin/bash
#
# Secret NAS Update Script
# Updates the system by pulling latest changes from Git and applying them
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "=========================================="
echo "  Secret NAS Update"
echo "=========================================="
echo ""

# Check root permissions
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root"
    echo "Usage: sudo $0"
    exit 1
fi

# Check if running in git repository
if [ ! -d "$SCRIPT_DIR/.git" ]; then
    log_error "Not a git repository. Please install from git clone."
    exit 1
fi

log_step "1. Pulling latest changes from Git..."
cd "$SCRIPT_DIR"

# Stash any local changes (like config.json)
if ! git diff --quiet || ! git diff --cached --quiet; then
    log_warn "Local changes detected - stashing them"
    git stash save "Auto-stash before update $(date '+%Y-%m-%d %H:%M:%S')"
    STASHED=true
else
    STASHED=false
fi

# Pull latest changes
git pull origin main

if [ "$STASHED" = true ]; then
    log_info "Your local config changes were stashed"
    log_info "Run 'git stash pop' to restore them after update"
fi

log_step "2. Updating Python source files..."

# Update source files
if [ -d "/opt/nas-monitor/src" ]; then
    cp -r "$SCRIPT_DIR/src"/* /opt/nas-monitor/src/
    log_info "✓ Source files updated"
else
    log_warn "Source directory not found - skipping"
fi

log_step "3. Updating systemd service files..."

# Update systemd service files
SERVICES_UPDATED=false

if [ -f "$SCRIPT_DIR/systemd/nas-monitor.service" ]; then
    if ! cmp -s "$SCRIPT_DIR/systemd/nas-monitor.service" /etc/systemd/system/nas-monitor.service; then
        cp "$SCRIPT_DIR/systemd/nas-monitor.service" /etc/systemd/system/
        log_info "✓ nas-monitor.service updated"
        SERVICES_UPDATED=true
    else
        log_info "nas-monitor.service already up to date"
    fi
fi

if [ -f "$SCRIPT_DIR/systemd/luks-open-nas.service" ]; then
    if ! cmp -s "$SCRIPT_DIR/systemd/luks-open-nas.service" /etc/systemd/system/luks-open-nas.service; then
        cp "$SCRIPT_DIR/systemd/luks-open-nas.service" /etc/systemd/system/
        log_info "✓ luks-open-nas.service updated"
        SERVICES_UPDATED=true
    else
        log_info "luks-open-nas.service already up to date"
    fi
fi

if [ -f "$SCRIPT_DIR/systemd/smbd-wait-mount.service" ]; then
    if ! cmp -s "$SCRIPT_DIR/systemd/smbd-wait-mount.service" /etc/systemd/system/smbd-wait-mount.service; then
        cp "$SCRIPT_DIR/systemd/smbd-wait-mount.service" /etc/systemd/system/
        log_info "✓ smbd-wait-mount.service updated"
        SERVICES_UPDATED=true
    else
        log_info "smbd-wait-mount.service already up to date"
    fi
fi

# Reload systemd if services were updated
if [ "$SERVICES_UPDATED" = true ]; then
    systemctl daemon-reload
    log_info "✓ systemd daemon reloaded"
fi

log_step "4. Updating Samba configuration..."

# Update Samba config (preserve existing if user modified)
if [ -f "/etc/samba/smb.conf" ] && [ -f "$SCRIPT_DIR/config/smb.conf.template" ]; then
    if ! cmp -s "$SCRIPT_DIR/config/smb.conf.template" /etc/samba/smb.conf; then
        # Backup existing config
        cp /etc/samba/smb.conf /etc/samba/smb.conf.backup.$(date +%Y%m%d-%H%M%S)
        log_info "Backed up existing Samba config"

        # Ask user if they want to update
        log_warn "Samba configuration has been updated in the repository"
        log_warn "Your current config has been backed up to /etc/samba/smb.conf.backup.*"
        read -p "Update Samba config? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            cp "$SCRIPT_DIR/config/smb.conf.template" /etc/samba/smb.conf
            log_info "✓ Samba config updated"
            SAMBA_UPDATED=true
        else
            log_info "Samba config not updated (keeping your version)"
            SAMBA_UPDATED=false
        fi
    else
        log_info "Samba config already up to date"
        SAMBA_UPDATED=false
    fi
else
    SAMBA_UPDATED=false
fi

log_step "5. Updating udev rules..."

# Update udev rules if they exist
if [ -f "$SCRIPT_DIR/udev/99-luks-usb.rules" ] && [ -f "/etc/udev/rules.d/99-luks-usb.rules" ]; then
    # Extract UUID from existing rule
    EXISTING_UUID=$(grep -oP 'ID_FS_UUID=="\K[^"]+' /etc/udev/rules.d/99-luks-usb.rules 2>/dev/null || echo "")

    if [ -n "$EXISTING_UUID" ] && [ "$EXISTING_UUID" != "__LUKS_UUID__" ]; then
        # Update rule with existing UUID
        sed "s/__LUKS_UUID__/$EXISTING_UUID/g" "$SCRIPT_DIR/udev/99-luks-usb.rules" > /etc/udev/rules.d/99-luks-usb.rules
        log_info "✓ udev rule updated (UUID preserved: $EXISTING_UUID)"
        udevadm control --reload-rules
    else
        log_warn "Could not extract UUID from existing rule, skipping udev update"
    fi
else
    log_info "udev rule not found or not installed, skipping"
fi

log_step "6. Updating scripts..."

# Update scripts if they exist
if [ -d "$SCRIPT_DIR/scripts" ] && [ -d "/opt/nas-monitor/scripts" ]; then
    cp "$SCRIPT_DIR"/scripts/*.sh /opt/nas-monitor/scripts/ 2>/dev/null || true
    chmod +x /opt/nas-monitor/scripts/*.sh 2>/dev/null || true
    log_info "✓ Scripts updated"
fi

log_step "7. Restarting services..."

# Restart nas-monitor service
if systemctl is-active --quiet nas-monitor; then
    systemctl restart nas-monitor
    log_info "✓ nas-monitor service restarted"
else
    log_warn "nas-monitor service is not running"
fi

# Restart Samba if config was updated
if [ "$SAMBA_UPDATED" = true ]; then
    if systemctl is-active --quiet smbd; then
        systemctl restart smbd
        log_info "✓ Samba service restarted"
    fi
fi

echo ""
log_info "=========================================="
log_info "  Update completed successfully!"
log_info "=========================================="
echo ""

# Show service status
log_info "Service status:"
systemctl status nas-monitor --no-pager -l | head -n 3 || true
echo ""

# Show recent logs
log_info "Recent logs (last 5 lines):"
journalctl -u nas-monitor -n 5 --no-pager || true
echo ""

log_info "Update complete. Monitor logs with:"
echo "  sudo journalctl -u nas-monitor -f"
echo ""
