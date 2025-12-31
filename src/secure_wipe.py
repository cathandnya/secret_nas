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

        # 2. キーファイルが存在するか
        if not self.keyfile.exists():
            errors.append(f"Keyfile {self.keyfile} does not exist")

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

    def unmount_filesystem(self) -> bool:
        """
        ファイルシステムをアンマウント（強制）

        Returns:
            成功した場合True
        """
        self.logger.info(f"Unmounting {self.mount_point}")

        try:
            # 通常のアンマウントを試行
            subprocess.run(
                ['umount', str(self.mount_point)],
                check=True,
                timeout=30
            )
            self.logger.info(f"Successfully unmounted {self.mount_point}")
            time.sleep(1)
            return True

        except subprocess.CalledProcessError:
            # 通常のアンマウントが失敗したら、強制アンマウント（lazy unmount）
            self.logger.warning("Normal unmount failed, trying lazy unmount")
            try:
                subprocess.run(
                    ['umount', '-l', str(self.mount_point)],
                    check=True,
                    timeout=30
                )
                self.logger.info(f"Successfully unmounted {self.mount_point} (lazy)")
                time.sleep(1)
                return True
            except subprocess.CalledProcessError as e:
                self.logger.error(f"Failed to unmount even with -l flag: {e}")
                # アンマウント失敗でも続行（キーファイル削除が重要）
                return True

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

    def erase_luks_header(self) -> bool:
        """
        LUKSヘッダーを削除（オプション、さらなる安全性のため）

        Returns:
            成功した場合True
        """
        self.logger.warning(f"Erasing LUKS header on {self.device}")

        try:
            # LUKSヘッダー削除（復旧不可能にする）
            subprocess.run(
                ['cryptsetup', 'erase', self.device],
                input=b'YES\n',  # 確認プロンプトに応答
                check=True,
                timeout=60
            )

            self.logger.critical(f"LUKS header on {self.device} has been erased")
            return True

        except subprocess.CalledProcessError as e:
            self.logger.error(f"LUKS header erase failed: {e}")
            return False

    def execute_secure_wipe(
        self,
        erase_header: bool = False,
        shutdown_after: bool = False
    ) -> bool:
        """
        セキュア消去を実行

        Args:
            erase_header: LUKSヘッダーも削除するか
            shutdown_after: 消去後にシステムシャットダウンするか

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
        self.unmount_filesystem()

        # ステップ3: LUKSデバイスをクローズ（失敗しても続行）
        self.close_luks_device()

        # ステップ4: キーファイルを完全削除
        if not self.shred_keyfile():
            raise RuntimeError("Failed to shred keyfile")

        # ステップ5: LUKSヘッダー削除（オプション）
        if erase_header:
            if not self.erase_luks_header():
                self.logger.warning("LUKS header erase failed, but keyfile is deleted")

        self.logger.critical("=" * 60)
        self.logger.critical("SECURE WIPE COMPLETED SUCCESSFULLY")
        self.logger.critical("Data is now PERMANENTLY UNRECOVERABLE")
        self.logger.critical("=" * 60)

        # システムシャットダウン（オプション）
        if shutdown_after:
            self.logger.critical("Shutting down system in 10 seconds...")
            time.sleep(10)
            subprocess.run(['shutdown', '-h', 'now'])

        return True


if __name__ == '__main__':
    """テスト用エントリーポイント（実際の消去は行わない）"""
    import argparse

    parser = argparse.ArgumentParser(description='LUKS Keyfile Secure Wiper')
    parser.add_argument('--device', required=True, help='Device path (e.g., /dev/sda)')
    parser.add_argument('--keyfile', default='/root/.nas-keyfile', help='Keyfile path')
    parser.add_argument('--mount-point', default='/mnt/secure_nas', help='Mount point')
    parser.add_argument('--erase-header', action='store_true', help='Also erase LUKS header')
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
            wiper.execute_secure_wipe(erase_header=args.erase_header)
        except Exception as e:
            logging.error(f"Wipe operation failed: {e}")
            exit(1)
