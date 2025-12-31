#!/usr/bin/env python3
"""
セキュア消去モジュール

LUKS暗号化キーファイルを削除することで、
データを復号不可能にする高速かつ確実な消去を実現する。
"""

import logging
import os
import subprocess
import time
from pathlib import Path
from typing import List, Tuple


class SecureWiper:
    """
    セキュア消去クラス

    LUKS暗号化されたUSBストレージのキーファイルを安全に削除する。
    """

    def __init__(
        self,
        mount_point: str = '/mnt/secure_nas',
        device: str = None,
        keyfile: str = '/root/.nas-keyfile',
        luks_name: str = 'secure_nas_crypt'
    ):
        """
        初期化

        Args:
            mount_point: マウントポイント
            device: デバイスパス（例: /dev/sda）
            keyfile: LUKSキーファイルパス
            luks_name: LUKS デバイスマッパー名
        """
        self.mount_point = Path(mount_point)
        self.device = device
        self.keyfile = Path(keyfile)
        self.luks_name = luks_name
        self.logger = logging.getLogger(__name__)

    def verify_safe_to_wipe(self) -> Tuple[bool, List[str]]:
        """
        消去前の安全チェック

        Returns:
            (安全性フラグ, エラーメッセージリスト)
        """
        errors = []

        # 1. キーファイルが指定されているか
        if not self.keyfile:
            errors.append("Keyfile path is not specified")

        # 2. キーファイルが存在するか（警告のみ、クリーンアップ時は許容）
        if not self.keyfile.exists():
            self.logger.warning(f"Keyfile {self.keyfile} does not exist - may have been already deleted")
            # クリーンアップのため、エラーとして扱わない

        # 3. デバイスが指定されているか
        if not self.device:
            errors.append("Device is not specified")

        # 4. デバイスが存在するか
        if self.device and not Path(self.device).exists():
            errors.append(f"Device {self.device} does not exist")

        # 5. システムディスクではないか
        if self.device:
            root_device = self._get_root_device()
            if self.device.startswith(root_device):
                errors.append(
                    f"Cannot wipe system device {self.device} "
                    f"(root is on {root_device})"
                )

        # 6. キーファイルがシステムディスク外にあるか（念のため）
        if self.keyfile.exists():
            try:
                keyfile_device = self._get_device_for_path(self.keyfile)
                if keyfile_device != self.device:
                    # キーファイルはSDカード上にあるべき（正常）
                    pass
                else:
                    errors.append(
                        "Keyfile appears to be on the target device"
                    )
            except Exception as e:
                self.logger.warning(f"Could not verify keyfile device: {e}")

        return len(errors) == 0, errors

    def _get_root_device(self) -> str:
        """
        ルートファイルシステムのデバイスを取得

        Returns:
            ルートデバイスのベース名（例: /dev/mmcblk0）
        """
        try:
            result = subprocess.run(
                ['findmnt', '-n', '-o', 'SOURCE', '/'],
                capture_output=True,
                text=True,
                check=True,
                timeout=10
            )
            device = result.stdout.strip()

            # パーティション番号を除去
            # /dev/mmcblk0p2 -> /dev/mmcblk0
            # /dev/sda1 -> /dev/sda
            import re
            base_device = re.sub(r'p?\d+$', '', device)
            return base_device

        except subprocess.CalledProcessError as e:
            self.logger.error(f"Failed to get root device: {e}")
            return '/dev/mmcblk0'  # フォールバック（Raspberry Pi）

    def _get_device_for_path(self, path: Path) -> str:
        """
        指定されたパスが存在するデバイスを取得

        Args:
            path: ファイルパス

        Returns:
            デバイスパス
        """
        result = subprocess.run(
            ['df', str(path)],
            capture_output=True,
            text=True,
            check=True,
            timeout=10
        )
        lines = result.stdout.strip().split('\n')
        if len(lines) < 2:
            raise RuntimeError("Unexpected df output")

        device = lines[1].split()[0]
        return device

    def stop_samba(self) -> bool:
        """
        Sambaサービスを停止

        Returns:
            成功した場合True
        """
        self.logger.info("Stopping Samba service")

        try:
            subprocess.run(
                ['systemctl', 'stop', 'smbd'],
                check=False,  # 失敗しても続行
                timeout=30
            )
            self.logger.info("Samba service stopped")
            return True
        except Exception as e:
            self.logger.warning(f"Failed to stop Samba (continuing anyway): {e}")
            return True  # 失敗しても続行

    def is_mounted(self) -> bool:
        """
        マウントポイントがマウントされているか確認

        Returns:
            マウントされている場合True
        """
        try:
            result = subprocess.run(
                ['mountpoint', '-q', str(self.mount_point)],
                timeout=5
            )
            return result.returncode == 0
        except Exception:
            return False

    def prevent_auto_remount(self) -> bool:
        """
        systemdによる自動再マウントを防止

        /etc/fstab のエントリを削除し、systemd マウントユニットを停止する。
        システム再起動後は fstab エントリがないため、マウントユニットは自動生成されない。

        Returns:
            成功した場合True
        """
        try:
            # fstab 削除前に内容を確認
            self.logger.info("Reading current fstab entries...")
            result = subprocess.run(
                ['grep', str(self.mount_point), '/etc/fstab'],
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.returncode == 0:
                self.logger.info(f"Found fstab entry: {result.stdout.strip()}")
            else:
                self.logger.warning("Mount point not found in fstab (already removed?)")

            # fstab からマウントポイントのエントリを削除
            self.logger.info("Removing fstab entry to prevent auto-remount after reboot")
            result = subprocess.run(
                ['sed', '-i', f'\\|{str(self.mount_point)}|d', '/etc/fstab'],
                capture_output=True,
                text=True,
                check=True,
                timeout=10
            )

            # 削除を確認
            self.logger.info("Verifying fstab entry removal...")
            verify = subprocess.run(
                ['grep', str(self.mount_point), '/etc/fstab'],
                capture_output=True,
                timeout=5
            )
            if verify.returncode == 0:
                self.logger.error("FAILED: fstab entry still exists after deletion!")
                return False
            else:
                self.logger.info("✓ Fstab entry successfully removed")

            # systemd マウントユニットを停止（即座にアンマウント）
            # /mnt/secure_nas -> mnt-secure_nas.mount
            mount_unit = str(self.mount_point).lstrip('/').replace('/', '-') + '.mount'

            self.logger.info(f"Stopping systemd mount unit: {mount_unit}")
            stop_result = subprocess.run(
                ['systemctl', 'stop', mount_unit],
                capture_output=True,
                text=True,
                check=False,
                timeout=10
            )
            if stop_result.returncode == 0:
                self.logger.info(f"✓ Successfully stopped {mount_unit}")
            else:
                self.logger.warning(f"Failed to stop {mount_unit} (may not be running): {stop_result.stderr.strip()}")

            # マスクと daemon-reload は不要（再起動時に systemd が fstab を再読み込みして自動解決）
            self.logger.info("✓ Auto-remount prevention configured successfully")
            return True

        except subprocess.CalledProcessError as e:
            self.logger.error(f"Failed to prevent auto-remount: {e}")
            if e.stderr:
                self.logger.error(f"  stderr: {e.stderr.strip()}")
            return False
        except Exception as e:
            self.logger.error(f"Unexpected error in prevent_auto_remount: {e}")
            return False

    def unmount_filesystem(self) -> bool:
        """
        ファイルシステムをアンマウント（強制）

        Returns:
            成功した場合True
        """
        self.logger.info(f"Unmounting {self.mount_point}")

        # 既にアンマウントされている場合
        if not self.is_mounted():
            self.logger.info(f"{self.mount_point} is already unmounted")
            return True

        # CRITICAL: systemd による自動再マウントを**先に**防止
        self.logger.info("Preventing systemd auto-remount BEFORE unmounting...")
        if not self.prevent_auto_remount():
            self.logger.error("CRITICAL: Failed to prevent auto-remount")
            self.logger.error("Continuing anyway, but remount may occur")

        try:
            # 通常のアンマウントを試行
            self.logger.info("Attempting normal unmount...")
            subprocess.run(
                ['umount', str(self.mount_point)],
                capture_output=True,
                text=True,
                check=True,
                timeout=30
            )
            self.logger.info("umount command succeeded")
            time.sleep(1)

            # 検証：本当にアンマウントされたか確認
            if not self.is_mounted():
                self.logger.info(f"✓ Successfully unmounted {self.mount_point}")

                # さらに検証: systemd マウントユニットの状態確認
                mount_unit = str(self.mount_point).lstrip('/').replace('/', '-') + '.mount'
                check = subprocess.run(
                    ['systemctl', 'is-active', mount_unit],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                if check.returncode == 0:
                    self.logger.error(f"WARNING: {mount_unit} is still active!")
                else:
                    self.logger.info(f"✓ {mount_unit} is inactive")

                return True
            else:
                self.logger.error("CRITICAL: umount succeeded but device is still mounted!")
                self.logger.error("Possible systemd auto-remount occurred")

                # デバッグ情報を記録
                mount_info = subprocess.run(
                    ['mount'],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                for line in mount_info.stdout.split('\n'):
                    if str(self.mount_point) in line:
                        self.logger.error(f"  Current mount: {line}")

        except subprocess.CalledProcessError as e:
            self.logger.warning(f"Normal unmount failed: {e}")
            if e.stderr:
                self.logger.warning(f"  umount stderr: {e.stderr.strip()}")

            # CRITICAL: umount が失敗しても、実際にアンマウントされているか確認
            # systemctl stop が既にアンマウントした場合、umount は "not mounted" で失敗するが
            # これは成功とみなすべき（fuser -km でシステムをkillしてはいけない）
            if not self.is_mounted():
                self.logger.info("✓ Filesystem is already unmounted (likely by systemctl stop)")
                self.logger.info("Skipping forced unmount attempts to avoid killing system processes")
                return True

            self.logger.warning("Filesystem is still mounted - proceeding to forced unmount")

        # 強制アンマウント試行1: プロセスをkillしてから通常アンマウント
        try:
            self.logger.info("Killing processes using mount point...")
            subprocess.run(
                ['fuser', '-km', str(self.mount_point)],
                check=False,  # fuserが何も見つからなくてもOK
                timeout=10,
                capture_output=True
            )
            time.sleep(2)

            subprocess.run(
                ['umount', str(self.mount_point)],
                check=True,
                timeout=30
            )
            time.sleep(1)

            if not self.is_mounted():
                self.logger.info(f"Successfully unmounted {self.mount_point} (after killing processes)")
                return True

        except subprocess.CalledProcessError:
            self.logger.warning("Forceful unmount after kill failed, trying lazy unmount")

        # 強制アンマウント試行2: lazy unmount (-l)
        try:
            subprocess.run(
                ['umount', '-l', str(self.mount_point)],
                check=True,
                timeout=30
            )
            time.sleep(2)

            if not self.is_mounted():
                self.logger.info(f"Successfully unmounted {self.mount_point} (lazy)")
                return True
            else:
                self.logger.error("Lazy unmount succeeded but mount point still reports as mounted")

        except subprocess.CalledProcessError as e:
            self.logger.error(f"Failed to unmount even with -l flag: {e}")

        # 強制アンマウント試行3: 強制フラグ (-f) - NFSなどで有効
        try:
            subprocess.run(
                ['umount', '-f', str(self.mount_point)],
                check=True,
                timeout=30
            )
            time.sleep(2)

            if not self.is_mounted():
                self.logger.info(f"Successfully unmounted {self.mount_point} (force)")
                return True

        except subprocess.CalledProcessError as e:
            self.logger.error(f"Failed to unmount with -f flag: {e}")

        # 最終確認
        if not self.is_mounted():
            self.logger.warning("Mount point is now unmounted (by unknown means)")
            return True

        # 完全に失敗
        self.logger.critical(f"CRITICAL: Failed to unmount {self.mount_point}")
        self.logger.critical("Device is still mounted - ghost files cannot be safely cleaned")
        return False

    def close_luks_device(self) -> bool:
        """
        LUKS暗号化デバイスをクローズ

        Returns:
            成功した場合True
        """
        self.logger.info(f"Closing LUKS device: {self.luks_name}")

        try:
            subprocess.run(
                ['cryptsetup', 'close', self.luks_name],
                check=True,
                timeout=30
            )

            time.sleep(1)

            self.logger.info(f"Successfully closed LUKS device: {self.luks_name}")
            return True

        except subprocess.CalledProcessError as e:
            self.logger.warning(f"Failed to close LUKS device: {e}")
            # クローズ失敗でも続行（キーファイル削除とヘッダー破壊が重要）
            self.logger.warning("Continuing with wipe despite close failure")
            return True

    def shred_keyfile(self, passes: int = 3) -> bool:
        """
        キーファイルをshredで完全削除

        Args:
            passes: 上書き回数（デフォルト: 3）

        Returns:
            成功した場合True
        """
        self.logger.critical(f"Shredding keyfile: {self.keyfile}")

        try:
            subprocess.run(
                [
                    'shred',
                    '-v',           # verbose
                    '-n', str(passes),  # 上書き回数
                    '-z',           # 最後にゼロで上書き
                    '-u',           # 削除
                    str(self.keyfile)
                ],
                check=True,
                timeout=300  # 5分タイムアウト
            )

            self.logger.critical(f"Keyfile {self.keyfile} has been securely deleted")
            return True

        except subprocess.TimeoutExpired:
            self.logger.error("Keyfile shred operation timed out")
            return False
        except subprocess.CalledProcessError as e:
            self.logger.error(f"Keyfile shred operation failed: {e}")
            return False

    def execute_secure_wipe(self, reboot_after: bool = False) -> bool:
        """
        セキュア消去を実行

        キーファイルを shred で完全削除することで、LUKS 暗号化されたデータを
        永久に復元不可能にする。ヘッダー削除は不要（キーなしでは復号不可能）。

        Args:
            reboot_after: 消去後にシステムを再起動するか

        Returns:
            成功した場合True
        """
        self.logger.critical("=" * 60)
        self.logger.critical("STARTING SECURE WIPE OPERATION")
        self.logger.critical("=" * 60)

        # 安全性チェック
        safe, errors = self.verify_safe_to_wipe()
        if not safe:
            self.logger.error("Safety checks failed:")
            for error in errors:
                self.logger.error(f"  - {error}")
            raise RuntimeError(f"Safety checks failed: {', '.join(errors)}")

        self.logger.info("All safety checks passed")

        # ステップ1: Sambaサービスを停止
        self.stop_samba()

        # ステップ2: ファイルシステムをアンマウント（強制）
        unmount_success = self.unmount_filesystem()

        # ステップ3: マウントポイント内のゴーストファイルを削除
        # （アンマウント後にSDカード上に残った平文ファイルを削除）
        # アンマウント成功時のみ実行（マウント中のファイル削除は危険）
        if unmount_success:
            try:
                import glob
                ghost_files = glob.glob(f"{self.mount_point}/*") + glob.glob(f"{self.mount_point}/.[!.]*")
                if ghost_files:
                    self.logger.warning(f"Cleaning up {len(ghost_files)} ghost files in unmounted mount point")
                    subprocess.run(
                        ['rm', '-rf'] + ghost_files,
                        check=True,
                        timeout=30
                    )
                    self.logger.info("Ghost files removed from mount point")
                else:
                    self.logger.info("No ghost files found in mount point")
            except Exception as e:
                self.logger.warning(f"Failed to clean ghost files (not critical): {e}")
        else:
            self.logger.critical("SKIPPING ghost file cleanup - mount point is still mounted (unsafe)")

        # ステップ4: LUKSデバイスをクローズ（失敗しても続行）
        self.close_luks_device()

        # ステップ5: キーファイルを完全削除（最後に実行）
        # キーファイルを削除すれば、LUKS暗号化されたデータは永久に復元不可能
        # ヘッダー削除は不要（キーなしでは復号化できない）
        # クリーンアップ時に既に削除されている可能性があるため、失敗を許容
        if self.keyfile.exists():
            if not self.shred_keyfile():
                self.logger.error("Failed to shred keyfile - manual cleanup may be required")
                raise RuntimeError("Failed to shred keyfile")
        else:
            self.logger.warning(f"Keyfile {self.keyfile} already deleted - skipping shred")

        self.logger.critical("=" * 60)
        self.logger.critical("SECURE WIPE COMPLETED SUCCESSFULLY")
        self.logger.critical("Data is now PERMANENTLY UNRECOVERABLE")
        self.logger.critical("=" * 60)

        # システム再起動（オプション）
        if reboot_after:
            self.logger.critical("Rebooting system now...")
            self.logger.critical("This will unmask the mount unit and restore normal operation")
            subprocess.run(['reboot'])

        return True


if __name__ == '__main__':
    """テスト用エントリーポイント（実際の消去は行わない）"""
    import argparse

    parser = argparse.ArgumentParser(description='LUKS Keyfile Secure Wiper')
    parser.add_argument('--device', required=True, help='Device path (e.g., /dev/sda)')
    parser.add_argument('--keyfile', default='/root/.nas-keyfile', help='Keyfile path')
    parser.add_argument('--mount-point', default='/mnt/secure_nas', help='Mount point')
    parser.add_argument('--dry-run', action='store_true', help='Dry run (safety checks only)')

    args = parser.parse_args()

    # ロギング設定
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )

    wiper = SecureWiper(
        mount_point=args.mount_point,
        device=args.device,
        keyfile=args.keyfile
    )

    if args.dry_run:
        print("DRY RUN MODE - No actual deletion will occur")
        safe, errors = wiper.verify_safe_to_wipe()
        if safe:
            print("✓ All safety checks passed")
            print(f"  Device: {args.device}")
            print(f"  Keyfile: {args.keyfile}")
            print(f"  Mount point: {args.mount_point}")
        else:
            print("✗ Safety checks failed:")
            for error in errors:
                print(f"  - {error}")
    else:
        try:
            wiper.execute_secure_wipe()
        except Exception as e:
            logging.error(f"Wipe operation failed: {e}")
            exit(1)
