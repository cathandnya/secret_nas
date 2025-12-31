#!/bin/bash
#
# Force Wipe Test Script
# 最終アクセス日を過去に設定して即座に削除をトリガーするテストスクリプト
#
# 使用方法:
#   sudo ./scripts/force-wipe-test.sh [days]
#
# 例:
#   sudo ./scripts/force-wipe-test.sh 31  # 31日前に設定（デフォルト30日で削除）
#   sudo ./scripts/force-wipe-test.sh 8   # 8日前に設定（7日で警告メール送信）
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

STATE_FILE="/var/lib/nas-monitor/last_access.json"
DAYS_AGO=${1:-31}

echo ""
echo "=========================================="
echo "  Force Wipe Test Script"
echo "=========================================="
echo ""

# root権限チェック
if [ "$EUID" -ne 0 ]; then
    log_error "このスクリプトはroot権限で実行する必要があります"
    echo "実行方法: sudo $0 [days]"
    exit 1
fi

# 引数チェック
if ! [[ "$DAYS_AGO" =~ ^[0-9]+$ ]]; then
    log_error "引数は正の整数である必要があります"
    echo "実行方法: sudo $0 [days]"
    exit 1
fi

log_step "1. 現在の状態確認..."

# 設定ファイル確認
CONFIG_FILE="/etc/nas-monitor/config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "設定ファイルが見つかりません: $CONFIG_FILE"
    log_info "先に setup.sh を実行してください"
    exit 1
fi

# 削除日数を取得
INACTIVITY_DAYS=$(jq -r '.inactivity_days' "$CONFIG_FILE" 2>/dev/null || echo "30")
log_info "設定された削除日数: $INACTIVITY_DAYS 日"

# 警告日を取得
WARNING_DAYS=$(jq -r '.warning_days[]' "$CONFIG_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
if [ -n "$WARNING_DAYS" ]; then
    log_info "警告メール送信日: $WARNING_DAYS 日前"
fi

echo ""

# 状態ファイル確認
if [ -f "$STATE_FILE" ]; then
    CURRENT_ACCESS=$(jq -r '.last_access' "$STATE_FILE" 2>/dev/null || echo "unknown")
    log_info "現在の最終アクセス日時: $CURRENT_ACCESS"
else
    log_warn "状態ファイルが存在しません: $STATE_FILE"
fi

echo ""
log_step "2. 最終アクセス日を $DAYS_AGO 日前に設定..."

# 過去の日時を計算（ISO 8601形式）
PAST_DATE=$(date -u -d "$DAYS_AGO days ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
            date -u -v-${DAYS_AGO}d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)

if [ -z "$PAST_DATE" ]; then
    log_error "日付計算に失敗しました"
    exit 1
fi

log_info "設定する日時: $PAST_DATE"

# 状態ファイルディレクトリ作成
mkdir -p "$(dirname "$STATE_FILE")"

# 状態ファイル書き込み
cat > "$STATE_FILE" <<EOF
{
  "last_access": "$PAST_DATE"
}
EOF

chmod 644 "$STATE_FILE"
log_info "✓ 状態ファイル更新完了"

echo ""
log_step "3. 予想される動作..."

ELAPSED_DAYS=$DAYS_AGO

if [ "$ELAPSED_DAYS" -ge "$INACTIVITY_DAYS" ]; then
    log_error "⚠️  削除条件を満たしています！"
    log_warn "次回のチェック（1時間以内）でデータが削除されます"
    echo ""
    log_warn "削除内容:"
    log_warn "  - キーファイル (/root/.nas-keyfile) を shred で完全破壊"
    log_warn "  - LUKSヘッダーを cryptsetup erase で破壊"
    log_warn "  - USB内のデータは永久に復元不可能"
elif [ -n "$WARNING_DAYS" ]; then
    # 警告日チェック
    for WARNING_DAY in $(echo "$WARNING_DAYS" | tr ',' ' '); do
        if [ "$ELAPSED_DAYS" -ge "$WARNING_DAY" ]; then
            log_warn "⚠️  警告メール送信条件を満たしています"
            log_info "次回のチェック時に警告メールが送信されます"
            break
        fi
    done
else
    log_info "まだ削除・警告の条件を満たしていません"
    REMAINING=$((INACTIVITY_DAYS - ELAPSED_DAYS))
    log_info "削除まで残り: $REMAINING 日"
fi

echo ""
log_step "4. 次のアクション..."

echo ""
log_info "【即座に削除をテストする場合】"
echo "  1. nas-monitor サービスを再起動:"
echo -e "     ${YELLOW}sudo systemctl restart nas-monitor${NC}"
echo ""
echo "  2. ログをリアルタイム監視:"
echo -e "     ${YELLOW}sudo journalctl -u nas-monitor -f${NC}"
echo ""

log_info "【削除を中止する場合】"
echo "  1. Sambaにアクセスして最終アクセス日を更新"
echo "  2. または手動で状態ファイルを削除:"
echo -e "     ${YELLOW}sudo rm -f $STATE_FILE${NC}"
echo ""

log_info "【テスト完了後のクリーンアップ】"
echo "  テスト後は以下を実行してUSBを再セットアップ:"
echo -e "     ${YELLOW}sudo ./scripts/re-encrypt-usb.sh${NC}"
echo ""

log_warn "⚠️  注意: このスクリプトは本番環境で使用しないでください"
log_warn "       実際にデータが削除される可能性があります"
echo ""
