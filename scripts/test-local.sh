#!/bin/bash
#
# ローカル環境（Mac/Linux）でSecret NASの動作確認を行うスクリプト
# 実際のUSBデバイスの代わりにループバックデバイスを使用
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

# ルート権限チェック
if [[ $EUID -ne 0 ]]; then
   log_error "このスクリプトは root 権限で実行してください（sudo ./scripts/test-local.sh）"
   exit 1
fi

echo ""
echo "=========================================="
echo "  Secret NAS ローカルテスト"
echo "=========================================="
echo ""
log_warn "このスクリプトは、USBデバイスの代わりにループバックデバイスを使用します"
echo ""

# テスト用ディレクトリ
TEST_DIR="./test-local"
LOOP_FILE="$TEST_DIR/virtual-usb.img"
LOOP_DEVICE=""
MOUNT_POINT="$TEST_DIR/mount"
LUKS_NAME="test_nas_crypt"
KEYFILE="$TEST_DIR/test-keyfile"

mkdir -p "$TEST_DIR"
mkdir -p "$MOUNT_POINT"

# クリーンアップ関数
cleanup() {
    log_step "クリーンアップ中..."

    # アンマウント
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi

    # LUKS クローズ
    if [ -e "/dev/mapper/$LUKS_NAME" ]; then
        cryptsetup close "$LUKS_NAME" 2>/dev/null || true
    fi

    # ループデバイス解放
    if [ ! -z "$LOOP_DEVICE" ] && [ -e "$LOOP_DEVICE" ]; then
        losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    fi
}

trap cleanup EXIT

log_step "1. 仮想USBイメージ作成（100MB）..."
dd if=/dev/zero of="$LOOP_FILE" bs=1M count=100 status=progress

log_step "2. ループバックデバイスとして設定..."
LOOP_DEVICE=$(losetup -f --show "$LOOP_FILE")
log_info "ループバックデバイス: $LOOP_DEVICE"

log_step "3. LUKS暗号化フォーマット..."
# キーファイル生成
dd if=/dev/urandom of="$KEYFILE" bs=4096 count=1 2>/dev/null
chmod 600 "$KEYFILE"

# LUKS暗号化
cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 256 \
    --hash sha256 \
    --iter-time 2000 \
    "$LOOP_DEVICE" \
    "$KEYFILE"

log_info "✓ LUKS暗号化完了"

log_step "4. LUKS デバイスを開く..."
cryptsetup open --key-file="$KEYFILE" "$LOOP_DEVICE" "$LUKS_NAME"
log_info "✓ /dev/mapper/$LUKS_NAME が作成されました"

log_step "5. ext4ファイルシステム作成..."
mkfs.ext4 -F "/dev/mapper/$LUKS_NAME" >/dev/null
log_info "✓ ファイルシステム作成完了"

log_step "6. マウント..."
mount "/dev/mapper/$LUKS_NAME" "$MOUNT_POINT"
log_info "✓ $MOUNT_POINT にマウントしました"

log_step "7. テストファイル書き込み..."
echo "Secret NAS Test Data" > "$MOUNT_POINT/test.txt"
chmod 644 "$MOUNT_POINT/test.txt"
log_info "✓ テストファイル作成完了"

log_step "8. 暗号化デバイス情報表示..."
echo ""
cryptsetup status "$LUKS_NAME"
echo ""

log_step "9. セキュア消去のテスト（dry-run）..."
cd "$(dirname "$0")/.."
python3 src/secure_wipe.py \
    --device "$LOOP_DEVICE" \
    --keyfile "$KEYFILE" \
    --mount-point "$MOUNT_POINT" \
    --dry-run

echo ""
log_info "=========================================="
log_info "  テスト結果"
log_info "=========================================="
log_info "✓ LUKS暗号化が正常に動作しました"
log_info "✓ ファイルシステムのマウントに成功しました"
log_info "✓ セキュア消去の安全性チェックに合格しました"
echo ""
log_info "実際に暗号化キーを削除してテストする場合:"
echo ""
echo -e "  ${YELLOW}sudo python3 src/secure_wipe.py \\${NC}"
echo -e "    ${YELLOW}--device $LOOP_DEVICE \\${NC}"
echo -e "    ${YELLOW}--keyfile $KEYFILE \\${NC}"
echo -e "    ${YELLOW}--mount-point $MOUNT_POINT${NC}"
echo ""
log_warn "注: 実行すると $KEYFILE が削除され、データが復元不可能になります"
echo ""
