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

# This unit ships as a template: setup.sh substitutes the real LUKS UUID into
# __LUKS_UUID__ at install time. Copying the template verbatim would write the
# placeholder back, and ExecStartPre would then test a path that cannot exist -
# the volume stays locked from the next boot on. Carry the installed UUID over,
# the same way the udev rule is handled in step 6.
if [ -f "$SCRIPT_DIR/systemd/luks-open-nas.service" ]; then
    INSTALLED_LUKS_UUID=$(grep -oP '/dev/disk/by-uuid/\K[0-9a-fA-F-]{36}' \
        /etc/systemd/system/luks-open-nas.service 2>/dev/null | head -1 || echo "")

    if [ -z "$INSTALLED_LUKS_UUID" ]; then
        # Fall back to the running device so a host already holding the
        # placeholder is repaired rather than left broken.
        INSTALLED_LUKS_UUID=$(cryptsetup luksUUID /dev/mapper/secure_nas_crypt 2>/dev/null || echo "")
        [ -z "$INSTALLED_LUKS_UUID" ] && INSTALLED_LUKS_UUID=$(grep -oP 'ID_FS_UUID=="\K[^"]+' \
            /etc/udev/rules.d/99-luks-usb.rules 2>/dev/null | head -1 || echo "")
    fi

    if [ -n "$INSTALLED_LUKS_UUID" ] && [ "$INSTALLED_LUKS_UUID" != "__LUKS_UUID__" ]; then
        NEW_UNIT=$(mktemp)
        sed "s/__LUKS_UUID__/$INSTALLED_LUKS_UUID/g" \
            "$SCRIPT_DIR/systemd/luks-open-nas.service" > "$NEW_UNIT"
        if ! cmp -s "$NEW_UNIT" /etc/systemd/system/luks-open-nas.service; then
            cp "$NEW_UNIT" /etc/systemd/system/luks-open-nas.service
            log_info "✓ luks-open-nas.service updated (UUID preserved: $INSTALLED_LUKS_UUID)"
            SERVICES_UPDATED=true
        else
            log_info "luks-open-nas.service already up to date"
        fi
        rm -f "$NEW_UNIT"
    else
        log_warn "Could not determine the LUKS UUID; leaving luks-open-nas.service untouched"
        log_warn "  Overwriting it would restore the __LUKS_UUID__ placeholder and"
        log_warn "  the encrypted volume would fail to unlock on the next boot."
    fi
fi

# NOTE: setup.sh installs this unit as smbd.service (it replaces the distro's
# own smbd.service), so it must be compared and copied under that name. Copying
# it to smbd-wait-mount.service instead leaves an orphan file that nothing reads
# and silently keeps the running smbd.service stale.
if [ -f "$SCRIPT_DIR/systemd/smbd-wait-mount.service" ]; then
    if ! cmp -s "$SCRIPT_DIR/systemd/smbd-wait-mount.service" /etc/systemd/system/smbd.service; then
        cp "$SCRIPT_DIR/systemd/smbd-wait-mount.service" /etc/systemd/system/smbd.service
        log_info "✓ smbd.service updated"
        SERVICES_UPDATED=true
    else
        log_info "smbd.service already up to date"
    fi
    # Remove the orphan left behind by older versions of this script
    rm -f /etc/systemd/system/smbd-wait-mount.service
fi

if [ -f "$SCRIPT_DIR/systemd/luks-close-nas.service" ]; then
    if ! cmp -s "$SCRIPT_DIR/systemd/luks-close-nas.service" /etc/systemd/system/luks-close-nas.service; then
        cp "$SCRIPT_DIR/systemd/luks-close-nas.service" /etc/systemd/system/
        log_info "✓ luks-close-nas.service updated"
        SERVICES_UPDATED=true
    else
        log_info "luks-close-nas.service already up to date"
    fi
fi

# Reload systemd if services were updated
if [ "$SERVICES_UPDATED" = true ]; then
    systemctl daemon-reload
    log_info "✓ systemd daemon reloaded"
fi

log_step "4. Checking dependencies..."

# Ensure samba-vfs-modules is installed (required for iOS 18+ compatibility)
if ! dpkg -l | grep -q samba-vfs-modules; then
    log_info "Installing samba-vfs-modules (required for iOS 18+ write access)..."
    apt-get update
    apt-get install -y samba-vfs-modules
    log_info "✓ samba-vfs-modules installed"
else
    log_info "samba-vfs-modules already installed"
fi

log_step "5. Updating Samba configuration..."

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
            # Preserve existing share name
            EXISTING_SHARE_NAME=$(grep -oP '^\[\K[^\]]+' /etc/samba/smb.conf | grep -v global | head -1)
            if [ -n "$EXISTING_SHARE_NAME" ] && [ "$EXISTING_SHARE_NAME" != "secure_share" ]; then
                log_info "Preserving existing share name: $EXISTING_SHARE_NAME"
                sed "s/\[secure_share\]/[$EXISTING_SHARE_NAME]/" "$SCRIPT_DIR/config/smb.conf.template" > /etc/samba/smb.conf
            else
                cp "$SCRIPT_DIR/config/smb.conf.template" /etc/samba/smb.conf
            fi
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

log_step "6. Updating udev rules..."

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

log_step "7. Fixing Samba audit log ownership and rotation..."

# 既存インストールにも監査ログの修正を反映する。
#
# ここが抜けていると、update.sh を実行しても直るのは monitor.py だけになり、
# 所有者の問題 (rsyslog が書き込めない) と logrotate 未設定 (無制限に肥大) は
# 新規インストールにしか効かない。既存環境こそ壊れている可能性が高いので、
# ここで揃える。
#
# monitor.py は同じ update.sh の実行で既に更新されているため、logrotate を
# 配置してもローテーション検知は効いている状態になる。順序は安全。
if [ -f /var/log/samba/audit.log ]; then
    # rsyslog の実行ユーザーを設定から判定する
    SYSLOG_USER=$(awk '/^\$PrivDropToUser/{print $2}' /etc/rsyslog.conf 2>/dev/null | tail -1)
    if [ -z "$SYSLOG_USER" ] && id -u syslog >/dev/null 2>&1; then
        SYSLOG_USER="syslog"
    fi

    if [ -n "$SYSLOG_USER" ] && id -u "$SYSLOG_USER" >/dev/null 2>&1; then
        SYSLOG_GROUP="adm"
        getent group "$SYSLOG_GROUP" >/dev/null 2>&1 || SYSLOG_GROUP=$(id -gn "$SYSLOG_USER")
        CURRENT_OWNER=$(stat -c '%U' /var/log/samba/audit.log 2>/dev/null || echo "")
        if [ "$CURRENT_OWNER" != "$SYSLOG_USER" ]; then
            chown "$SYSLOG_USER:$SYSLOG_GROUP" /var/log/samba/audit.log
            chmod 640 /var/log/samba/audit.log
            systemctl restart rsyslog 2>/dev/null || true
            log_info "✓ Audit log owner fixed: $CURRENT_OWNER -> $SYSLOG_USER:$SYSLOG_GROUP"
            log_warn "  rsyslog could not write to the audit log until now."
            log_warn "  Access tracking was likely not working. Verify last_access updates."
        else
            log_info "✓ Audit log owner is already correct ($SYSLOG_USER)"
        fi
    else
        log_warn "Could not determine rsyslog user; leaving audit log ownership as is"
        SYSLOG_USER="root"; SYSLOG_GROUP="adm"
    fi

    # logrotate 設定
    if [ -f "$SCRIPT_DIR/config/logrotate-samba-audit" ]; then
        if [ -f /etc/logrotate.d/samba-audit ]; then
            log_info "✓ logrotate config already installed"
        else
            sed "s|__LOG_OWNER__|${SYSLOG_USER:-root} ${SYSLOG_GROUP:-adm}|" \
                "$SCRIPT_DIR/config/logrotate-samba-audit" > /etc/logrotate.d/samba-audit
            chmod 644 /etc/logrotate.d/samba-audit
            log_info "✓ logrotate config installed: /etc/logrotate.d/samba-audit"
        fi
    fi
else
    log_info "Samba audit log not found, skipping"
fi

log_step "8. Updating scripts..."

# Update scripts if they exist
if [ -d "$SCRIPT_DIR/scripts" ] && [ -d "/opt/nas-monitor/scripts" ]; then
    cp "$SCRIPT_DIR"/scripts/*.sh /opt/nas-monitor/scripts/ 2>/dev/null || true
    chmod +x /opt/nas-monitor/scripts/*.sh 2>/dev/null || true
    log_info "✓ Scripts updated"
fi

log_step "9. Restarting services..."

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
