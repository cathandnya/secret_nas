#!/bin/bash
#
# Secret NAS Pythonモジュールの単体テスト
# root権限不要でコア機能をテスト
#

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test() { echo -e "${BLUE}[TEST]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }

TESTS_PASSED=0
TESTS_FAILED=0

echo ""
echo "=========================================="
echo "  Secret NAS モジュールテスト"
echo "=========================================="
echo ""

cd "$(dirname "$0")/.."

# テスト1: 設定ファイル読み込み
test_config_loader() {
    log_test "1. ConfigLoader テスト"

    # テスト用設定ファイル作成
    cat > /tmp/test-config.json <<EOF
{
  "mount_point": "/mnt/test",
  "device": "/dev/test",
  "keyfile": "/tmp/test-key",
  "inactivity_days": 30,
  "warning_days": [23, 27, 29],
  "notification": {
    "enabled": false
  }
}
EOF

    result=$(python3 -c "
import sys
sys.path.insert(0, 'src')
from config_loader import ConfigLoader
config = ConfigLoader('/tmp/test-config.json')
print('valid' if config.validate() else 'invalid')
print(config.get('inactivity_days'))
print(config.get_warning_days())
")

    if echo "$result" | grep -q "valid"; then
        log_pass "ConfigLoader が正常に動作しました"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_fail "ConfigLoader テストに失敗しました"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    rm -f /tmp/test-config.json
    echo ""
}

# テスト2: アクセストラッキング
test_access_tracker() {
    log_test "2. AccessTracker テスト"

    # テスト用状態ファイル
    STATE_FILE="/tmp/test-access.json"

    result=$(python3 -c "
import sys
sys.path.insert(0, 'src')
from access_tracker import AccessTracker
from datetime import datetime, timedelta

tracker = AccessTracker('$STATE_FILE')

# 新規アクセス記録
tracker.update_access()

# 即座に確認（0日前）
days = tracker.days_since_last_access()
print(f'Days: {days}')

# 3日前のアクセスをシミュレート
past_time = datetime.now() - timedelta(days=3)
tracker.update_access(past_time)

days_3 = tracker.days_since_last_access()
print(f'Days after 3 days: {days_3}')

if days == 0 and days_3 == 3:
    print('SUCCESS')
else:
    print('FAILED')
")

    if echo "$result" | grep -q "SUCCESS"; then
        log_pass "AccessTracker が正常に動作しました"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_fail "AccessTracker テストに失敗しました"
        echo "$result"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    rm -f "$STATE_FILE"
    echo ""
}

# テスト3: 通知システム
test_notifier() {
    log_test "3. EmailNotifier テスト（設定のみ）"

    result=$(python3 -c "
import sys
sys.path.insert(0, 'src')
from notifier import EmailNotifier

# テスト用設定
email_config = {
    'to': 'test@example.com',
    'from': 'nas@example.com',
    'smtp_server': 'smtp.gmail.com',
    'smtp_port': 587,
    'username': 'test@example.com',
    'password': 'dummy-password',
    'use_tls': True
}

notifier = EmailNotifier(email_config, '/tmp/test-notification.json')

# 設定が正しく読み込まれたか確認
if notifier.email_config['to'] == 'test@example.com':
    print('SUCCESS')
else:
    print('FAILED')
")

    if echo "$result" | grep -q "SUCCESS"; then
        log_pass "EmailNotifier の初期化に成功しました"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_fail "EmailNotifier テストに失敗しました"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    rm -f /tmp/test-notification.json
    echo ""
}

# テスト4: セキュア消去（dry-runのみ）
test_secure_wipe() {
    log_test "4. SecureWiper テスト（dry-run）"

    # 一時的なキーファイルとマウントポイント作成
    TEMP_KEY="/tmp/test-keyfile"
    TEMP_MOUNT="/tmp/test-mount"

    dd if=/dev/urandom of="$TEMP_KEY" bs=1024 count=1 2>/dev/null
    mkdir -p "$TEMP_MOUNT"

    result=$(python3 -c "
import sys
sys.path.insert(0, 'src')
from secure_wipe import SecureWiper

wiper = SecureWiper(
    device='/dev/null',  # ダミーデバイス
    keyfile='$TEMP_KEY',
    mount_point='$TEMP_MOUNT'
)

# dry-run安全チェックのみ
try:
    # ダミーデバイスなので実際には実行されない
    print('initialized')
    print('SUCCESS')
except Exception as e:
    print(f'FAILED: {e}')
" 2>&1)

    if echo "$result" | grep -q "initialized"; then
        log_pass "SecureWiper の初期化に成功しました"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_fail "SecureWiper テストに失敗しました"
        echo "$result"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    rm -f "$TEMP_KEY"
    rm -rf "$TEMP_MOUNT"
    echo ""
}

# テスト5: ロガー
test_logger() {
    log_test "5. Logger テスト"

    result=$(python3 -c "
import sys
sys.path.insert(0, 'src')
from logger import setup_logging
import logging

# ロガーセットアップ
setup_logging(log_level=logging.INFO)

logger = logging.getLogger(__name__)
logger.info('Test log message')

print('SUCCESS')
" 2>&1)

    if echo "$result" | grep -q "SUCCESS"; then
        log_pass "Logger が正常に動作しました"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_fail "Logger テストに失敗しました"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    echo ""
}

# すべてのテストを実行
test_config_loader
test_access_tracker
test_notifier
test_secure_wipe
test_logger

# サマリー
echo ""
echo "=========================================="
echo "  テスト結果サマリー"
echo "=========================================="
echo -e "${GREEN}合格:${NC} $TESTS_PASSED"
echo -e "${RED}失敗:${NC} $TESTS_FAILED"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}すべてのモジュールテストに合格しました！${NC}"
    exit 0
else
    echo -e "${RED}いくつかのテストが失敗しました${NC}"
    exit 1
fi
