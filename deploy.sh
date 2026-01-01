#!/bin/bash
#
# Secret NAS デプロイスクリプト
# Raspberry Piへのデプロイに必要なファイルのみをパッケージング
#

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

DEPLOY_DIR="deploy"
ARCHIVE_NAME="secret_nas_deploy.tar.gz"

echo ""
echo "=========================================="
echo "  Secret NAS デプロイパッケージ作成"
echo "=========================================="
echo ""

# 既存のdeployディレクトリを削除
if [ -d "$DEPLOY_DIR" ]; then
    rm -rf "$DEPLOY_DIR"
fi

log_step "1. デプロイディレクトリ作成..."
mkdir -p "$DEPLOY_DIR"

log_step "2. 必要なファイルをコピー..."

# ルートファイル
cp setup.sh "$DEPLOY_DIR/"
cp README.md "$DEPLOY_DIR/"

# ソースコード
mkdir -p "$DEPLOY_DIR/src"
cp src/*.py "$DEPLOY_DIR/src/"

# 設定テンプレート
mkdir -p "$DEPLOY_DIR/config"
cp config/smb.conf.template "$DEPLOY_DIR/config/"

# systemdユニット
mkdir -p "$DEPLOY_DIR/systemd"
cp systemd/nas-monitor.service "$DEPLOY_DIR/systemd/"
cp systemd/luks-open-nas.service "$DEPLOY_DIR/systemd/"
cp systemd/smbd-wait-mount.service "$DEPLOY_DIR/systemd/"
cp systemd/mnt-secure_nas-cleanup.service "$DEPLOY_DIR/systemd/"

# Raspberry Pi用テストスクリプトのみ
mkdir -p "$DEPLOY_DIR/scripts"
cp scripts/quick-test.sh "$DEPLOY_DIR/scripts/"
cp scripts/test-all.sh "$DEPLOY_DIR/scripts/"
cp scripts/force-wipe-test.sh "$DEPLOY_DIR/scripts/"

# ライセンスやドキュメント（もしあれば）
if [ -f "LICENSE" ]; then
    cp LICENSE "$DEPLOY_DIR/"
fi

log_step "3. デプロイパッケージの内容確認..."
echo ""
tree "$DEPLOY_DIR" 2>/dev/null || find "$DEPLOY_DIR" -type f | sort
echo ""

log_step "4. アーカイブ作成..."
tar -czf "$ARCHIVE_NAME" -C "$DEPLOY_DIR" .

ARCHIVE_SIZE=$(du -h "$ARCHIVE_NAME" | cut -f1)
log_info "✓ デプロイパッケージ作成完了: $ARCHIVE_NAME ($ARCHIVE_SIZE)"

echo ""
echo "=========================================="
echo "  デプロイ方法"
echo "=========================================="
echo ""
log_info "1. Raspberry Piにファイルを転送:"
echo ""
echo -e "  ${YELLOW}scp $ARCHIVE_NAME pi@pi.local:~/${NC}"
echo ""
log_info "2. Raspberry PiにSSH接続:"
echo ""
echo -e "  ${YELLOW}ssh pi@pi.local${NC}"
echo ""
log_info "3. Raspberry Pi上で展開してセットアップ:"
echo ""
echo -e "  ${YELLOW}mkdir -p ~/secret_nas${NC}"
echo -e "  ${YELLOW}tar -xzf $ARCHIVE_NAME -C ~/secret_nas${NC}"
echo -e "  ${YELLOW}cd ~/secret_nas${NC}"
echo -e "  ${YELLOW}sudo ./setup.sh${NC}"
echo ""
