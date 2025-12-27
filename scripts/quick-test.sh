#!/bin/bash
#
# Secret NAS クイックテストスクリプト
#
# 基本的な動作確認のみを素早く実行
#

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo "Secret NAS クイックテスト"
echo "========================="
echo ""

# サービス状態
echo -n "監視サービス: "
if systemctl is-active nas-monitor >/dev/null 2>&1; then
    echo -e "${GREEN}実行中${NC}"
else
    echo -e "${RED}停止中${NC}"
fi

# ストレージ
echo -n "ストレージ: "
if mountpoint -q /mnt/secure_nas 2>/dev/null; then
    echo -e "${GREEN}マウント済み${NC}"
else
    echo -e "${RED}未マウント${NC}"
fi

# LUKS
echo -n "暗号化: "
if cryptsetup status secure_nas_crypt >/dev/null 2>&1; then
    echo -e "${GREEN}有効${NC}"
else
    echo -e "${RED}無効${NC}"
fi

# Samba
echo -n "Samba: "
if systemctl is-active smbd >/dev/null 2>&1; then
    echo -e "${GREEN}実行中${NC}"
else
    echo -e "${RED}停止中${NC}"
fi

# 最終アクセス
echo -n "最終アクセス: "
if [ -f /var/lib/nas-monitor/last_access.json ]; then
    days=$(sudo python3 -c "
import sys, json
sys.path.insert(0, '/opt/nas-monitor/src')
from access_tracker import AccessTracker
tracker = AccessTracker()
days = tracker.days_since_last_access()
print(days if days is not None else 'なし')
" 2>/dev/null)
    echo -e "${YELLOW}${days} 日前${NC}"
else
    echo -e "${YELLOW}記録なし${NC}"
fi

# エラーログ
echo -n "エラー (24h): "
error_count=$(sudo journalctl -u nas-monitor --since "24 hours ago" -p err 2>/dev/null | wc -l)
if [ "$error_count" -eq 0 ]; then
    echo -e "${GREEN}なし${NC}"
else
    echo -e "${RED}${error_count} 件${NC}"
fi

echo ""
echo "詳細テスト: sudo ./scripts/test-all.sh"
echo ""
