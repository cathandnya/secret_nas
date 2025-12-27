#!/bin/bash
#
# Secret NAS 統合テストスクリプト
#
# 各種機能を順番にテストし、結果を表示する
#

set -e

# カラー出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 結果カウンター
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test() { echo -e "${CYAN}[TEST]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $1"; TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); }

# ルート権限チェック
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (use sudo)"
   exit 1
fi

echo ""
echo "=========================================="
echo "  Secret NAS 統合テストスイート"
echo "=========================================="
echo ""

# テスト1: インストール確認
test_installation() {
    log_test "1. インストール確認"

    if [ -d "/opt/nas-monitor" ]; then
        log_pass "インストールディレクトリが存在します"
    else
        log_fail "インストールディレクトリが見つかりません"
        return 1
    fi

    if [ -f "/opt/nas-monitor/src/monitor.py" ]; then
        log_pass "監視デーモンが存在します"
    else
        log_fail "監視デーモンが見つかりません"
        return 1
    fi

    if [ -f "/etc/nas-monitor/config.json" ]; then
        log_pass "設定ファイルが存在します"
    else
        log_fail "設定ファイルが見つかりません"
        return 1
    fi

    echo ""
}

# テスト2: 設定の妥当性チェック
test_configuration() {
    log_test "2. 設定の妥当性チェック"

    cd /opt/nas-monitor

    result=$(python3 -c "
import sys
sys.path.insert(0, '/opt/nas-monitor/src')
from config_loader import ConfigLoader
config = ConfigLoader()
print('valid' if config.validate() else 'invalid')
" 2>&1)

    if [[ "$result" == *"valid"* ]]; then
        log_pass "設定は有効です"
    else
        log_fail "設定に問題があります: $result"
        return 1
    fi

    echo ""
}

# テスト3: systemdサービス確認
test_systemd_service() {
    log_test "3. systemdサービス確認"

    if systemctl is-enabled nas-monitor >/dev/null 2>&1; then
        log_pass "サービスが有効化されています"
    else
        log_fail "サービスが有効化されていません"
        return 1
    fi

    if systemctl is-active nas-monitor >/dev/null 2>&1; then
        log_pass "サービスが実行中です"
    else
        log_warn "サービスが実行されていません"
        log_info "サービスを起動しています..."
        systemctl start nas-monitor
        sleep 2

        if systemctl is-active nas-monitor >/dev/null 2>&1; then
            log_pass "サービスを起動しました"
        else
            log_fail "サービスの起動に失敗しました"
            journalctl -u nas-monitor -n 20
            return 1
        fi
    fi

    echo ""
}

# テスト4: ストレージマウント確認
test_storage() {
    log_test "4. ストレージマウント確認"

    if mountpoint -q /mnt/secure_nas; then
        log_pass "/mnt/secure_nas がマウントされています"
    else
        log_fail "/mnt/secure_nas がマウントされていません"
        return 1
    fi

    if [ -w /mnt/secure_nas ]; then
        log_pass "ストレージは書き込み可能です"
    else
        log_warn "ストレージが書き込み不可です"
    fi

    echo ""
}

# テスト5: LUKS暗号化確認
test_luks() {
    log_test "5. LUKS暗号化確認"

    if cryptsetup status secure_nas_crypt >/dev/null 2>&1; then
        log_pass "LUKS暗号化デバイスが開いています"

        # LUKS詳細情報
        cipher=$(cryptsetup status secure_nas_crypt | grep cipher | awk '{print $2}')
        log_info "暗号化方式: $cipher"
    else
        log_fail "LUKS暗号化デバイスが開いていません"
        return 1
    fi

    if [ -f /root/.nas-keyfile ]; then
        log_pass "キーファイルが存在します"

        # キーファイルのパーミッション確認
        perm=$(stat -c %a /root/.nas-keyfile 2>/dev/null || stat -f %A /root/.nas-keyfile)
        if [ "$perm" = "600" ]; then
            log_pass "キーファイルのパーミッションが正しいです (600)"
        else
            log_warn "キーファイルのパーミッションが600ではありません: $perm"
        fi
    else
        log_fail "キーファイルが見つかりません"
        return 1
    fi

    echo ""
}

# テスト6: Samba動作確認
test_samba() {
    log_test "6. Samba動作確認"

    if systemctl is-active smbd >/dev/null 2>&1; then
        log_pass "Sambaサービスが実行中です"
    else
        log_fail "Sambaサービスが実行されていません"
        return 1
    fi

    # 共有リスト確認
    if smbclient -L localhost -N 2>&1 | grep -q "secure_share"; then
        log_pass "secure_share共有が公開されています"
    else
        log_warn "secure_share共有が見つかりません"
    fi

    # 監査ログ確認
    if [ -f /var/log/samba/audit.log ]; then
        log_pass "Samba監査ログが存在します"
    else
        log_warn "Samba監査ログが見つかりません"
        log_info "アクセストラッキングが動作しない可能性があります"
    fi

    echo ""
}

# テスト7: アクセストラッキング確認
test_access_tracking() {
    log_test "7. アクセストラッキング確認"

    if [ -f /var/lib/nas-monitor/last_access.json ]; then
        log_pass "アクセス状態ファイルが存在します"

        # 経過日数確認
        cd /opt/nas-monitor
        days=$(python3 -c "
import sys
sys.path.insert(0, '/opt/nas-monitor/src')
from access_tracker import AccessTracker
tracker = AccessTracker()
days = tracker.days_since_last_access()
print(days if days is not None else 'None')
" 2>&1)

        if [[ "$days" != "None" ]]; then
            log_pass "最終アクセスからの経過日数: $days 日"
        else
            log_warn "アクセス履歴がまだありません"
        fi
    else
        log_warn "アクセス状態ファイルがまだ作成されていません"
    fi

    echo ""
}

# テスト8: セキュア消去の安全性チェック
test_secure_wipe_safety() {
    log_test "8. セキュア消去の安全性チェック (dry-run)"

    cd /opt/nas-monitor

    # 設定からデバイス情報を取得
    device=$(python3 -c "
import sys, json
sys.path.insert(0, '/opt/nas-monitor/src')
from config_loader import ConfigLoader
config = ConfigLoader()
print(config.get('device', ''))
")

    if [ -z "$device" ]; then
        log_skip "デバイスが設定されていません"
        echo ""
        return 0
    fi

    # dry-run実行
    output=$(python3 src/secure_wipe.py \
        --device "$device" \
        --keyfile /root/.nas-keyfile \
        --mount-point /mnt/secure_nas \
        --dry-run 2>&1)

    if echo "$output" | grep -q "All safety checks passed"; then
        log_pass "安全性チェックに合格しました"
    else
        log_fail "安全性チェックに失敗しました"
        echo "$output"
        return 1
    fi

    echo ""
}

# テスト9: メール通知設定確認
test_notification() {
    log_test "9. メール通知設定確認"

    cd /opt/nas-monitor

    enabled=$(python3 -c "
import sys
sys.path.insert(0, '/opt/nas-monitor/src')
from config_loader import ConfigLoader
config = ConfigLoader()
print('yes' if config.is_notification_enabled() else 'no')
" 2>&1)

    if [[ "$enabled" == "yes" ]]; then
        log_info "メール通知が有効です"

        read -p "SMTP接続テストを実行しますか？ (y/N): " -n 1 -r
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            email_config=$(python3 -c "
import sys, json
sys.path.insert(0, '/opt/nas-monitor/src')
from config_loader import ConfigLoader
config = ConfigLoader()
email = config.get_email_config()
print(json.dumps(email))
")

            to=$(echo "$email_config" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('to', ''))")
            from=$(echo "$email_config" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('from', ''))")
            smtp_server=$(echo "$email_config" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('smtp_server', ''))")
            smtp_port=$(echo "$email_config" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('smtp_port', ''))")
            username=$(echo "$email_config" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('username', ''))")
            password=$(echo "$email_config" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('password', ''))")

            if python3 src/notifier.py \
                --to "$to" \
                --from "$from" \
                --smtp-server "$smtp_server" \
                --smtp-port "$smtp_port" \
                --username "$username" \
                --password "$password" \
                --test-only 2>&1 | grep -q "successful"; then
                log_pass "SMTP接続テストに成功しました"
            else
                log_fail "SMTP接続テストに失敗しました"
            fi
        else
            log_skip "SMTP接続テストをスキップしました"
        fi
    else
        log_info "メール通知は無効です"
    fi

    echo ""
}

# テスト10: ログ出力確認
test_logging() {
    log_test "10. ログ出力確認"

    # 直近のログを確認
    log_count=$(journalctl -u nas-monitor --since "1 hour ago" 2>/dev/null | wc -l)

    if [ "$log_count" -gt 0 ]; then
        log_pass "監視デーモンのログが出力されています ($log_count 行)"

        # エラーログチェック
        error_count=$(journalctl -u nas-monitor --since "1 hour ago" -p err 2>/dev/null | wc -l)

        if [ "$error_count" -eq 0 ]; then
            log_pass "直近1時間以内にエラーはありません"
        else
            log_warn "直近1時間以内に $error_count 件のエラーがあります"
            log_info "詳細: journalctl -u nas-monitor -p err"
        fi
    else
        log_warn "直近1時間以内のログがありません"
    fi

    echo ""
}

# メイン実行
main() {
    test_installation || true
    test_configuration || true
    test_systemd_service || true
    test_storage || true
    test_luks || true
    test_samba || true
    test_access_tracking || true
    test_secure_wipe_safety || true
    test_notification || true
    test_logging || true

    echo ""
    echo "=========================================="
    echo "  テスト結果サマリー"
    echo "=========================================="
    echo -e "${GREEN}合格:${NC} $TESTS_PASSED"
    echo -e "${RED}失敗:${NC} $TESTS_FAILED"
    echo -e "${YELLOW}スキップ:${NC} $TESTS_SKIPPED"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}すべてのテストに合格しました！${NC}"
        echo ""
        log_info "システムは正常に動作しています"
        log_info ""
        log_info "次のステップ:"
        log_info "  1. NASにアクセスしてファイルを保存"
        log_info "  2. journalctl -u nas-monitor -f でログ監視"
        log_info "  3. sudo cat /var/lib/nas-monitor/last_access.json で状態確認"
        echo ""
        exit 0
    else
        echo -e "${RED}いくつかのテストが失敗しました${NC}"
        echo ""
        log_error "問題を修正してから再度テストしてください"
        log_info "詳細ログ: sudo journalctl -u nas-monitor -n 100"
        echo ""
        exit 1
    fi
}

main "$@"
