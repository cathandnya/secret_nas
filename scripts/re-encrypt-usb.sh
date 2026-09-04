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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

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

# ステップ1.5: SDカード上のゴーストファイルを削除
log_info "Step 1.5: Cleaning up ghost files on SD card..."
if [ "$(ls -A "$MOUNT_POINT" 2>/dev/null)" ]; then
    log_warn "Found ghost files in unmounted mount point, removing..."
    rm -rf "$MOUNT_POINT"/*
    rm -rf "$MOUNT_POINT"/.[!.]*  # 隠しファイルも削除（. と .. は除外）
    log_info "✓ Ghost files removed"
else
    log_info "✓ No ghost files found"
fi

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

# ステップ7.5: LUKS UUID を埋め込んだ unit / udev ルールを再生成
# luksFormat で UUID が変わるため、__LUKS_UUID__ を展開してインストールされた
# luks-open-nas.service と 99-luks-usb.rules も更新しないと、次回起動時に
# 古い UUID を参照して解錠に失敗する（デバイスは開いたままなので、この
# スクリプトの実行中は問題が表面化しない）
log_info "Step 7.5: Updating unit and udev rule with the new LUKS UUID..."
if [ -f "$REPO_DIR/systemd/luks-open-nas.service" ]; then
    sed "s/__LUKS_UUID__/$LUKS_UUID/g" "$REPO_DIR/systemd/luks-open-nas.service" \
        > /etc/systemd/system/luks-open-nas.service
    log_info "✓ luks-open-nas.service updated"
else
    log_warn "Template not found: $REPO_DIR/systemd/luks-open-nas.service"
    log_warn "  /etc/systemd/system/luks-open-nas.service still holds the OLD UUID"
fi

if [ -f "$REPO_DIR/udev/99-luks-usb.rules" ]; then
    sed "s/__LUKS_UUID__/$LUKS_UUID/g" "$REPO_DIR/udev/99-luks-usb.rules" \
        > /etc/udev/rules.d/99-luks-usb.rules
    udevadm control --reload-rules
    udevadm trigger
    log_info "✓ 99-luks-usb.rules updated"
else
    log_warn "Template not found: $REPO_DIR/udev/99-luks-usb.rules"
    log_warn "  /etc/udev/rules.d/99-luks-usb.rules still holds the OLD UUID"
fi

systemctl daemon-reload

# ステップ8: /etc/fstab 更新
log_info "Step 8: Updating /etc/fstab..."
FS_UUID=$(blkid -s UUID -o value "/dev/mapper/$LUKS_NAME")
log_info "Filesystem UUID: $FS_UUID"

# 既存のエントリを削除して新しく追加
sed -i "\|$MOUNT_POINT|d" /etc/fstab
echo "UUID=$FS_UUID $MOUNT_POINT ext4 defaults,nofail,x-systemd.requires=luks-open-nas.service,x-systemd.after=luks-open-nas.service,x-systemd.wants=smbd.service 0 2" >> /etc/fstab
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
