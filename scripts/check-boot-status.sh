#!/bin/bash
# Boot status diagnostic script
# Run this after reboot to check why SMB is not accessible

echo "=========================================="
echo "  Boot Status Check"
echo "=========================================="
echo ""

echo "=== 1. USB Device Recognition ==="
echo "Checking if USB device is recognized..."
if lsusb | grep -i "mass storage" >/dev/null; then
    echo "✓ USB mass storage device found"
    lsusb | grep -i "mass storage"
else
    echo "✗ No USB mass storage device found"
fi
echo ""

echo "=== 2. LUKS Device Status ==="
echo "Checking LUKS encrypted device..."
if cryptsetup status secure_nas_crypt >/dev/null 2>&1; then
    echo "✓ LUKS device is open"
    cryptsetup status secure_nas_crypt
else
    echo "✗ LUKS device is NOT open"
fi
echo ""

echo "=== 3. Mount Status ==="
echo "Checking if /mnt/secure_nas is mounted..."
if mountpoint -q /mnt/secure_nas; then
    echo "✓ /mnt/secure_nas is mounted"
    mount | grep secure_nas
else
    echo "✗ /mnt/secure_nas is NOT mounted"
fi
echo ""

echo "=== 4. Service Status ==="
echo ""
echo "--- luks-open-nas.service ---"
systemctl status luks-open-nas.service --no-pager -l || true
echo ""

echo "--- mnt-secure_nas.mount ---"
systemctl status mnt-secure_nas.mount --no-pager -l || true
echo ""

echo "--- smbd.service ---"
systemctl status smbd.service --no-pager -l || true
echo ""

echo "=== 5. Recent Journal Logs ==="
echo "Last 20 lines from luks-open-nas.service:"
journalctl -u luks-open-nas.service -n 20 --no-pager || true
echo ""

echo "Last 20 lines from smbd.service:"
journalctl -u smbd.service -n 20 --no-pager || true
echo ""

echo "=== 6. Network Shares ==="
echo "Available Samba shares:"
smbclient -L localhost -N 2>&1 | grep -E "Disk|IPC" || echo "(none found)"
echo ""

echo "=========================================="
echo "  Check Complete"
echo "=========================================="
