#!/bin/bash
#
# Mount State Diagnostic Script
# 削除処理後のマウント状態を診断するスクリプト
#
# 使用方法:
#   sudo ./scripts/diagnose-mount.sh
#

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo "=========================================="
echo "  NAS Mount State Diagnostics"
echo "=========================================="
echo ""

echo -e "${BLUE}=== Mount Point Status ===${NC}"
if mountpoint -q /mnt/secure_nas; then
    echo -e "${RED}MOUNTED${NC}"
else
    echo -e "${GREEN}NOT MOUNTED${NC}"
fi
echo ""

echo -e "${BLUE}=== Current Mounts ===${NC}"
if mount | grep -q secure_nas; then
    mount | grep secure_nas
else
    echo "(no mounts found)"
fi
echo ""

echo -e "${BLUE}=== Systemd Mount Unit Status ===${NC}"
systemctl status mnt-secure_nas.mount --no-pager 2>/dev/null || echo "(unit not found or masked)"
echo ""

echo -e "${BLUE}=== Fstab Entry ===${NC}"
if grep -q secure_nas /etc/fstab 2>/dev/null; then
    echo -e "${RED}Found:${NC}"
    grep secure_nas /etc/fstab
else
    echo -e "${GREEN}(not found)${NC}"
fi
echo ""

echo -e "${BLUE}=== Device Mapper Status ===${NC}"
if dmsetup info secure_nas_crypt 2>/dev/null | grep -q "State"; then
    dmsetup info secure_nas_crypt 2>/dev/null
else
    echo -e "${GREEN}(not found)${NC}"
fi
echo ""

echo -e "${BLUE}=== LUKS Device Status ===${NC}"
if cryptsetup status secure_nas_crypt 2>/dev/null; then
    echo -e "${RED}Device is active${NC}"
else
    echo -e "${GREEN}(not active)${NC}"
fi
echo ""

echo -e "${BLUE}=== Processes Using Mount Point ===${NC}"
if fuser -vm /mnt/secure_nas 2>&1 | grep -q "/mnt/secure_nas"; then
    fuser -vm /mnt/secure_nas 2>&1
else
    echo -e "${GREEN}(no processes)${NC}"
fi
echo ""

echo -e "${BLUE}=== Files in Mount Point ===${NC}"
if [ -d "/mnt/secure_nas" ]; then
    FILE_COUNT=$(ls -A /mnt/secure_nas 2>/dev/null | wc -l)
    if [ "$FILE_COUNT" -gt 0 ]; then
        echo -e "${RED}Found $FILE_COUNT files/directories:${NC}"
        ls -la /mnt/secure_nas
    else
        echo -e "${GREEN}(empty directory)${NC}"
    fi
else
    echo "(directory does not exist)"
fi
echo ""

echo "=========================================="
echo "  Diagnostics Complete"
echo "=========================================="
echo ""
