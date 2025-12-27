#!/bin/bash
#
# Docker環境でSecret NASの完全統合テストを実行
# セットアップから動作確認まで一貫してテスト
#

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_test() { echo -e "${CYAN}[TEST]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

TESTS_PASSED=0
TESTS_FAILED=0

echo ""
echo "=========================================="
echo "  Secret NAS 統合テスト (Docker)"
echo "=========================================="
echo ""

# Docker確認
if ! command -v docker &> /dev/null; then
    log_error "Docker がインストールされていません"
    exit 1
fi

# プロジェクトルートに移動
cd "$(dirname "$0")/.."

cleanup() {
    log_info "クリーンアップ中..."
    docker-compose down -v 2>/dev/null || true
}

trap cleanup EXIT

log_step "1. Docker環境を構築..."
docker-compose build --quiet

log_step "2. コンテナを起動..."
docker-compose up -d

log_step "3. システムの初期化を待機..."
sleep 8

# コンテナが起動しているか確認
if ! docker-compose ps | grep -q "Up"; then
    log_error "コンテナの起動に失敗しました"
    docker-compose logs
    exit 1
fi

echo ""
log_info "✓ テスト環境が準備できました"
echo ""

# テスト1: ファイル構造確認
log_test "Test 1: ファイル構造確認"
docker-compose exec -T secret-nas bash -c "
cd /home/pi/secret_nas
if [ -f setup.sh ] && [ -f README.md ] && [ -d src ] && [ -d config ] && [ -d systemd ]; then
    echo 'PASS: すべての必須ファイルが存在します'
    exit 0
else
    echo 'FAIL: 一部のファイルが見つかりません'
    exit 1
fi
" && TESTS_PASSED=$((TESTS_PASSED + 1)) || TESTS_FAILED=$((TESTS_FAILED + 1))

echo ""

# テスト2: Pythonモジュールインポート
log_test "Test 2: Pythonモジュールインポート"
docker-compose exec -T secret-nas bash -c "
cd /home/pi/secret_nas
python3 -c '
import sys
sys.path.insert(0, \"src\")

try:
    from config_loader import ConfigLoader
    from access_tracker import AccessTracker
    from secure_wipe import SecureWiper
    from notifier import EmailNotifier
    from logger import setup_logging
    from monitor import NASMonitor
    print(\"PASS: すべてのモジュールがインポート可能です\")
except ImportError as e:
    print(f\"FAIL: インポートエラー: {e}\")
    exit(1)
'
" && TESTS_PASSED=$((TESTS_PASSED + 1)) || TESTS_FAILED=$((TESTS_FAILED + 1))

echo ""

# テスト3: 設定ローダーのテスト
log_test "Test 3: ConfigLoader 動作確認"
docker-compose exec -T secret-nas bash -c "
cd /home/pi/secret_nas

# テスト用設定ファイル作成
cat > /tmp/test-config.json <<EOF
{
  \"mount_point\": \"/mnt/test\",
  \"device\": \"/dev/test\",
  \"keyfile\": \"/tmp/test-key\",
  \"inactivity_days\": 30,
  \"warning_days\": [23, 27, 29],
  \"notification\": {
    \"enabled\": false
  }
}
EOF

python3 -c '
import sys
sys.path.insert(0, \"src\")
from config_loader import ConfigLoader

config = ConfigLoader(\"/tmp/test-config.json\")
if config.validate():
    print(\"PASS: 設定ファイルの読み込みと検証が成功しました\")
    days = config.get(\"inactivity_days\")
    warnings = config.get_warning_days()
    print(f\"  - Inactivity days: {days}\")
    print(f\"  - Warning days: {warnings}\")
    exit(0)
else:
    print(\"FAIL: 設定ファイルの検証に失敗しました\")
    exit(1)
'
" && TESTS_PASSED=$((TESTS_PASSED + 1)) || TESTS_FAILED=$((TESTS_FAILED + 1))

echo ""

# テスト4: アクセストラッカーのテスト
log_test "Test 4: AccessTracker 動作確認"
docker-compose exec -T secret-nas bash -c "
cd /home/pi/secret_nas

python3 -c '
import sys
sys.path.insert(0, \"src\")
from access_tracker import AccessTracker
from datetime import datetime, timedelta

tracker = AccessTracker(\"/tmp/test-access.json\")

# 新規アクセス記録
tracker.update_access()
days = tracker.days_since_last_access()

if days == 0:
    print(\"PASS: アクセス記録が正常に動作しています\")
    print(f\"  - 最終アクセスからの経過: {days} 日\")
    exit(0)
else:
    print(f\"FAIL: 期待値 0日、実際 {days}日\")
    exit(1)
'
" && TESTS_PASSED=$((TESTS_PASSED + 1)) || TESTS_FAILED=$((TESTS_FAILED + 1))

echo ""

# テスト5: セキュアワイパーの初期化テスト
log_test "Test 5: SecureWiper 初期化確認"
docker-compose exec -T secret-nas bash -c "
cd /home/pi/secret_nas

# ダミーキーファイル作成
dd if=/dev/urandom of=/tmp/test-keyfile bs=1024 count=1 2>/dev/null
mkdir -p /tmp/test-mount

python3 -c '
import sys
sys.path.insert(0, \"src\")
from secure_wipe import SecureWiper

try:
    wiper = SecureWiper(
        device=\"/dev/null\",
        keyfile=\"/tmp/test-keyfile\",
        mount_point=\"/tmp/test-mount\"
    )
    print(\"PASS: SecureWiper が正常に初期化されました\")
    exit(0)
except Exception as e:
    print(f\"FAIL: SecureWiper の初期化に失敗: {e}\")
    exit(1)
'
" && TESTS_PASSED=$((TESTS_PASSED + 1)) || TESTS_FAILED=$((TESTS_FAILED + 1))

echo ""

# テスト6: 通知システムの初期化テスト
log_test "Test 6: EmailNotifier 初期化確認"
docker-compose exec -T secret-nas bash -c "
cd /home/pi/secret_nas

python3 -c '
import sys
sys.path.insert(0, \"src\")
from notifier import EmailNotifier

email_config = {
    \"to\": \"test@example.com\",
    \"from\": \"nas@example.com\",
    \"smtp_server\": \"smtp.gmail.com\",
    \"smtp_port\": 587,
    \"username\": \"test@example.com\",
    \"password\": \"dummy-password\",
    \"use_tls\": True
}

notifier = EmailNotifier(email_config, \"/tmp/test-notification.json\")

if notifier.email_config[\"to\"] == \"test@example.com\":
    print(\"PASS: EmailNotifier が正常に初期化されました\")
    exit(0)
else:
    print(\"FAIL: EmailNotifier の設定が正しくありません\")
    exit(1)
'
" && TESTS_PASSED=$((TESTS_PASSED + 1)) || TESTS_FAILED=$((TESTS_FAILED + 1))

echo ""

# テスト7: スクリプト構文チェック
log_test "Test 7: シェルスクリプト構文チェック"
docker-compose exec -T secret-nas bash -c "
cd /home/pi/secret_nas

errors=0

bash -n setup.sh || errors=\$((errors + 1))
bash -n scripts/quick-test.sh || errors=\$((errors + 1))
bash -n scripts/test-all.sh || errors=\$((errors + 1))

if [ \$errors -eq 0 ]; then
    echo 'PASS: すべてのスクリプトの構文は正しいです'
    exit 0
else
    echo \"FAIL: \$errors 個のスクリプトに構文エラーがあります\"
    exit 1
fi
" && TESTS_PASSED=$((TESTS_PASSED + 1)) || TESTS_FAILED=$((TESTS_FAILED + 1))

echo ""

# テスト8: systemdサービスファイル構文チェック
log_test "Test 8: systemdサービスファイル構文チェック"
docker-compose exec -T secret-nas bash -c "
cd /home/pi/secret_nas

if systemd-analyze verify systemd/nas-monitor.service 2>&1 | grep -qi 'error'; then
    echo 'FAIL: systemdサービスファイルにエラーがあります'
    exit 1
else
    echo 'PASS: systemdサービスファイルは正常です'
    exit 0
fi
" && TESTS_PASSED=$((TESTS_PASSED + 1)) || TESTS_FAILED=$((TESTS_FAILED + 1))

echo ""

# 結果サマリー
echo ""
echo "=========================================="
echo "  テスト結果サマリー"
echo "=========================================="
echo -e "${GREEN}合格:${NC} $TESTS_PASSED"
echo -e "${RED}失敗:${NC} $TESTS_FAILED"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ すべてのテストに合格しました！${NC}"
    echo ""
    log_info "Docker環境での統合テストが完了しました"
    echo ""
    log_info "次のステップ: Raspberry Piへのデプロイ"
    echo -e "  ${YELLOW}./deploy.sh${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}✗ いくつかのテストが失敗しました${NC}"
    echo ""
    log_error "問題を修正してから再度テストしてください"
    exit 1
fi
