#!/bin/bash
# Re-encrypt USB storage after wipe test
# This script re-encrypts /dev/sda without changing other configurations

set -e

# 色付きログ出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Root権限チェック
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

USB_DEVICE="/dev/sda"
LUKS_NAME="secure_nas_crypt"
MOUNT_POINT="/mnt/secure_nas"
KEYFILE="/root/.nas-keyfile"

echo "========================================"
echo "  USB Re-encryption Script"
echo "========================================"
echo ""
log_warn "WARNING: This will ERASE ALL DATA on $USB_DEVICE"
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    log_info "Aborted by user"
    exit 0
fi

# ステップ1: 既存のマウントを解除
log_info "Step 1: Unmounting existing mounts..."
umount "$MOUNT_POINT" 2>/dev/null || true
cryptsetup close "$LUKS_NAME" 2>/dev/null || true
log_info "✓ Unmounted"

# ステップ2: デバイス確認
log_info "Step 2: Checking device..."
if [ ! -b "$USB_DEVICE" ]; then
    log_error "Device $USB_DEVICE not found"
    exit 1
fi
log_info "✓ Device found: $USB_DEVICE"

# ステップ3: 新しいキーファイル生成
log_info "Step 3: Generating new keyfile..."
dd if=/dev/urandom of="$KEYFILE" bs=4096 count=1 status=none
chmod 600 "$KEYFILE"
log_info "✓ Keyfile created: $KEYFILE"

# ステップ4: LUKS暗号化
log_info "Step 4: Encrypting device with LUKS..."
log_warn "This may take a few minutes..."

# LUKSフォーマット（既存のヘッダーがあっても上書き）
cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 256 \
    --hash sha256 \
    --key-file "$KEYFILE" \
    --batch-mode \
    "$USB_DEVICE"

log_info "✓ LUKS encryption completed"

# ステップ5: LUKS開く
log_info "Step 5: Opening encrypted device..."
cryptsetup open "$USB_DEVICE" "$LUKS_NAME" --key-file "$KEYFILE"
log_info "✓ Opened as /dev/mapper/$LUKS_NAME"

# ステップ6: ファイルシステム作成
log_info "Step 6: Creating ext4 filesystem..."
mkfs.ext4 -F "/dev/mapper/$LUKS_NAME"
log_info "✓ Filesystem created"

# ステップ7: /etc/crypttab 更新
log_info "Step 7: Updating /etc/crypttab..."
LUKS_UUID=$(cryptsetup luksUUID "$USB_DEVICE")
log_info "LUKS UUID: $LUKS_UUID"

# 既存のエントリを削除して新しく追加
sed -i "/$LUKS_NAME/d" /etc/crypttab
echo "$LUKS_NAME UUID=$LUKS_UUID $KEYFILE luks" >> /etc/crypttab
log_info "✓ /etc/crypttab updated"

# ステップ8: /etc/fstab 更新
log_info "Step 8: Updating /etc/fstab..."
FS_UUID=$(blkid -s UUID -o value "/dev/mapper/$LUKS_NAME")
log_info "Filesystem UUID: $FS_UUID"

# 既存のエントリを削除して新しく追加
sed -i "\|$MOUNT_POINT|d" /etc/fstab
echo "UUID=$FS_UUID $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
log_info "✓ /etc/fstab updated"

# ステップ9: マウント
log_info "Step 9: Mounting encrypted filesystem..."
mount "/dev/mapper/$LUKS_NAME" "$MOUNT_POINT"
log_info "✓ Mounted at $MOUNT_POINT"

# ステップ10: 権限設定
log_info "Step 10: Setting permissions..."
chown root:nasusers "$MOUNT_POINT"
chmod 770 "$MOUNT_POINT"
log_info "✓ Permissions set"

# ステップ11: 状態ファイルリセット
log_info "Step 11: Resetting monitor state..."
rm -f /var/lib/nas-monitor/last_access.json
rm -f /var/lib/nas-monitor/notification_state.json
log_info "✓ State files removed"

# ステップ12: サービス再起動
log_info "Step 12: Restarting services..."
systemctl restart nas-monitor
systemctl restart smbd
log_info "✓ Services restarted"

echo ""
echo "========================================"
echo "  ✓ USB Re-encryption Complete!"
echo "========================================"
echo ""
log_info "Device: $USB_DEVICE"
log_info "LUKS UUID: $LUKS_UUID"
log_info "Filesystem UUID: $FS_UUID"
log_info "Mount point: $MOUNT_POINT"
echo ""
log_info "You can now test the NAS functionality"
echo ""
