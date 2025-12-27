#!/bin/bash
#
# Docker環境でSecret NASの全テストを自動実行
#

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo ""
echo "=========================================="
echo "  Secret NAS Docker自動テスト"
echo "=========================================="
echo ""

# Docker確認
if ! command -v docker &> /dev/null; then
    log_error "Docker がインストールされていません"
    exit 1
fi

# プロジェクトルートに移動
cd "$(dirname "$0")/.."

log_step "1. Dockerイメージをビルド..."
docker-compose build

log_step "2. コンテナを起動..."
docker-compose up -d

log_step "3. コンテナの起動を待機..."
sleep 5

# コンテナが起動しているか確認
if ! docker-compose ps | grep -q "Up"; then
    log_error "コンテナの起動に失敗しました"
    docker-compose logs
    docker-compose down
    exit 1
fi

log_info "✓ コンテナが起動しました"
echo ""

log_step "4. Pythonモジュール単体テストを実行..."
echo ""
docker-compose exec -T secret-nas bash -c "
cd /home/pi/secret_nas
./scripts/test-modules.sh
" || {
    log_error "モジュールテストに失敗しました"
    docker-compose down
    exit 1
}

echo ""
log_info "✓ Pythonモジュールテストに合格しました"
echo ""

log_step "5. インストール確認テスト..."
echo ""
docker-compose exec -T secret-nas bash -c "
cd /home/pi/secret_nas

# Python依存関係確認
python3 -c 'import sys; sys.path.insert(0, \"src\"); from config_loader import ConfigLoader; print(\"✓ config_loader\")' || exit 1
python3 -c 'import sys; sys.path.insert(0, \"src\"); from access_tracker import AccessTracker; print(\"✓ access_tracker\")' || exit 1
python3 -c 'import sys; sys.path.insert(0, \"src\"); from secure_wipe import SecureWiper; print(\"✓ secure_wipe\")' || exit 1
python3 -c 'import sys; sys.path.insert(0, \"src\"); from notifier import EmailNotifier; print(\"✓ notifier\")' || exit 1
python3 -c 'import sys; sys.path.insert(0, \"src\"); from logger import setup_logging; print(\"✓ logger\")' || exit 1
python3 -c 'import sys; sys.path.insert(0, \"src\"); from monitor import NASMonitor; print(\"✓ monitor\")' || exit 1

echo \"\"
echo \"すべてのモジュールがインポート可能です\"
" || {
    log_error "モジュールインポートテストに失敗しました"
    docker-compose down
    exit 1
}

echo ""
log_info "✓ すべてのモジュールが正常にインポートできました"
echo ""

log_step "6. セットアップスクリプトの構文チェック..."
docker-compose exec -T secret-nas bash -c "
cd /home/pi/secret_nas
bash -n setup.sh && echo '✓ setup.sh の構文は正しいです'
" || {
    log_error "setup.sh に構文エラーがあります"
    docker-compose down
    exit 1
}

echo ""
log_step "7. 設定テンプレートの確認..."
docker-compose exec -T secret-nas bash -c "
cd /home/pi/secret_nas
if [ -f config/smb.conf.template ]; then
    echo '✓ Samba設定テンプレートが存在します'
else
    echo '✗ Samba設定テンプレートが見つかりません'
    exit 1
fi

if [ -f systemd/nas-monitor.service ]; then
    echo '✓ systemdサービスファイルが存在します'
else
    echo '✗ systemdサービスファイルが見つかりません'
    exit 1
fi
" || {
    log_error "設定ファイルの確認に失敗しました"
    docker-compose down
    exit 1
}

echo ""
log_step "8. テストスクリプトの構文チェック..."
docker-compose exec -T secret-nas bash -c "
cd /home/pi/secret_nas
bash -n scripts/quick-test.sh && echo '✓ quick-test.sh'
bash -n scripts/test-all.sh && echo '✓ test-all.sh'
" || {
    log_error "テストスクリプトに構文エラーがあります"
    docker-compose down
    exit 1
}

echo ""
log_step "9. コンテナを停止..."
docker-compose down

echo ""
echo "=========================================="
echo "  テスト結果: すべて成功 ✓"
echo "=========================================="
echo ""
log_info "Docker環境でのテストが完了しました"
echo ""
log_info "次のステップ:"
echo ""
echo "  1. デプロイパッケージ作成:"
echo -e "     ${YELLOW}./deploy.sh${NC}"
echo ""
echo "  2. Raspberry Piに転送:"
echo -e "     ${YELLOW}scp secret_nas_deploy.tar.gz pi@pi.local:~/${NC}"
echo ""
echo "  3. Raspberry Piでセットアップ:"
echo -e "     ${YELLOW}ssh pi@pi.local${NC}"
echo -e "     ${YELLOW}mkdir -p ~/secret_nas${NC}"
echo -e "     ${YELLOW}tar -xzf secret_nas_deploy.tar.gz -C ~/secret_nas${NC}"
echo -e "     ${YELLOW}cd ~/secret_nas${NC}"
echo -e "     ${YELLOW}sudo ./setup.sh${NC}"
echo ""
