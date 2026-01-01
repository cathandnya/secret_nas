#!/bin/bash
# Mount state diagnostic script

echo "=== Mount Point Status ==="
mountpoint -q /mnt/secure_nas && echo "MOUNTED" || echo "NOT MOUNTED"
echo ""

echo "=== Current Mounts ==="
mount | grep secure_nas || echo "(none)"
echo ""

echo "=== Systemd Mount Unit Status ==="
systemctl status mnt-secure_nas.mount --no-pager 2>/dev/null || echo "(unit not found)"
echo ""

echo "=== Fstab Entry ==="
grep secure_nas /etc/fstab 2>/dev/null || echo "(not found)"
echo ""

echo "=== Device Mapper Status ==="
dmsetup info secure_nas_crypt 2>/dev/null || echo "(not found)"
echo ""

echo "=== LUKS Device Status ==="
cryptsetup status secure_nas_crypt 2>/dev/null || echo "(not active)"
echo ""

echo "=== LUKS Service Status ==="
systemctl status luks-open-nas.service --no-pager
echo ""

echo "=== Processes Using Mount Point ==="
fuser -vm /mnt/secure_nas 2>&1 || echo "(no processes)"
