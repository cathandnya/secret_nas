#!/usr/bin/env python3
"""
NAS監視デーモン

Sambaログを監視し、30日間アクセスがない場合にセキュア消去を実行する。
23, 27, 29日目に段階的な警告メールを送信する。
"""

import signal
import sys
import time
import logging
from pathlib import Path

from access_tracker import AccessTracker
from secure_wipe import SecureWiper
from notifier import EmailNotifier
from config_loader import ConfigLoader
from logger import setup_logging


class NASMonitor:
    """
    NAS監視デーモン

    アクセス監視、通知送信、セキュア消去を統合管理する。
    """

    def __init__(self, config_file: str = '/etc/nas-monitor/config.json'):
        """
        初期化

        Args:
            config_file: 設定ファイルパス
        """
        # 設定読み込み
        self.config = ConfigLoader(config_file)

        # 設定の妥当性チェック
        if not self.config.validate():
            raise RuntimeError("Configuration validation failed")

        # ロガー取得
        self.logger = logging.getLogger(__name__)

        # アクセストラッカー
        self.tracker = AccessTracker(
            state_file=self.config.get('state_file')
        )

        # セキュア消去
        self.wiper = SecureWiper(
            mount_point=self.config.get('mount_point'),
            device=self.config.get('device'),
            keyfile=self.config.get('keyfile')
        )

        # 通知
        self.notifier = None
        if self.config.is_notification_enabled():
            self.notifier = EmailNotifier(
                email_config=self.config.get_email_config(),
                state_file=self.config.get('notification_state_file')
            )

        # パラメータ
        self.inactivity_days = self.config.get('inactivity_days', 30)
        self.warning_days = sorted(self.config.get_warning_days())
        self.shutdown_after_wipe = self.config.get('shutdown_after_wipe', False)

        # 実行フラグ
        self.running = True

        # シグナルハンドラ設定
        signal.signal(signal.SIGTERM, self._handle_shutdown)
        signal.signal(signal.SIGINT, self._handle_shutdown)

    def _handle_shutdown(self, signum, frame):
        """グレースフルシャットダウン"""
        self.logger.info(f"Received signal {signum}, shutting down gracefully...")
        self.running = False

    def monitor_samba_log(self, log_file: str = '/var/log/samba/audit.log'):
        """
        Sambaログを監視してアクセスを検出

        Args:
            log_file: Samba監査ログのパス
        """
        log_path = Path(log_file)

        if not log_path.exists():
            self.logger.warning(f"Samba audit log not found: {log_file}")
            self.logger.warning("Access tracking will rely on periodic checks only")
            return

        try:
            with open(log_path, 'r') as f:
                # ファイル末尾に移動
                f.seek(0, 2)

                self.logger.info(f"Monitoring Samba log: {log_file}")

                while self.running:
                    line = f.readline()
                    if line:
                        # アクセスログが記録されたらアクセス時刻を更新
                        # Sambaのfull_auditログには共有名が含まれる
                        if 'secure_share' in line:
                            self.logger.debug(f"Access detected: {line.strip()}")
                            self.tracker.update_access()

                            # 通知状態もリセット
                            if self.notifier:
                                self.notifier.reset_notification_state()
                    else:
                        # 新しい行がない場合は少し待つ
                        time.sleep(1)

        except Exception as e:
            self.logger.error(f"Error monitoring Samba log: {e}")

    def check_and_notify(self):
        """
        非アクティブ期間をチェックし、必要に応じて通知を送信

        Returns:
            消去が必要な場合True
        """
        days = self.tracker.days_since_last_access()

        if days is None:
            self.logger.info("No access history found, initializing...")
            self.tracker.update_access()
            return False

        self.logger.info(f"Days since last access: {days}/{self.inactivity_days}")

        # 削除閾値に達したか
        if days >= self.inactivity_days:
            self.logger.critical(
                f"Inactivity threshold reached ({days} >= {self.inactivity_days})"
            )
            return True

        # 警告通知を送信
        if self.notifier:
            deletion_date = self.tracker.get_deletion_date(self.inactivity_days)

            for warning_day in self.warning_days:
                if days >= warning_day and days < self.inactivity_days:
                    try:
                        success = self.notifier.send_warning(
                            warning_day=warning_day,
                            days_elapsed=days,
                            inactivity_days=self.inactivity_days,
                            deletion_date=deletion_date
                        )
                        if success:
                            self.logger.info(
                                f"Warning notification sent for day {warning_day}"
                            )
                        else:
                            self.logger.error(
                                f"Failed to send warning notification for day {warning_day}"
                            )
                    except Exception as e:
                        self.logger.error(f"Error sending notification: {e}")

        return False

    def execute_wipe(self):
        """セキュア消去を実行"""
        self.logger.critical("=" * 70)
        self.logger.critical("EXECUTING SECURE WIPE")
        self.logger.critical("=" * 70)

        try:
            # 最終確認ログ
            last_access = self.tracker.get_last_access()
            self.logger.critical(f"Last access: {last_access}")
            self.logger.critical(f"Days since last access: {self.tracker.days_since_last_access()}")

            # 消去実行
            self.wiper.execute_secure_wipe(
                erase_header=False,  # キーファイル削除だけで十分
                shutdown_after=self.shutdown_after_wipe
            )

            self.logger.critical("Secure wipe completed successfully")
            self.logger.critical("Data is now PERMANENTLY UNRECOVERABLE")

        except Exception as e:
            self.logger.critical(f"Wipe operation failed: {e}", exc_info=True)
            raise

    def run(self):
        """メインループ"""
        self.logger.info("=" * 70)
        self.logger.info("NAS Monitor starting...")
        self.logger.info(f"Inactivity threshold: {self.inactivity_days} days")
        self.logger.info(f"Warning days: {self.warning_days}")
        self.logger.info(f"Notification enabled: {self.notifier is not None}")
        self.logger.info("=" * 70)

        # 起動時チェック
        self.logger.info("Performing startup check...")
        if self.check_and_notify():
            self.logger.critical("Inactivity threshold already exceeded at startup")
            self.execute_wipe()
            return

        # 定期チェック（6時間ごと）
        check_interval = 6 * 60 * 60  # 6時間
        last_check = time.time()

        # TODO: 本番環境ではSambaログ監視を別スレッドで実行
        # import threading
        # log_thread = threading.Thread(target=self.monitor_samba_log, daemon=True)
        # log_thread.start()

        self.logger.info("Entering main monitoring loop...")

        while self.running:
            current_time = time.time()

            # 定期チェック
            if current_time - last_check >= check_interval:
                self.logger.info("Performing periodic check...")
                if self.check_and_notify():
                    self.execute_wipe()
                    break
                last_check = current_time

            # 1分ごとにループチェック（CPU節約）
            time.sleep(60)

        self.logger.info("NAS Monitor stopped")


def main():
    """エントリーポイント"""
    import argparse

    parser = argparse.ArgumentParser(description='Secret NAS Monitor Daemon')
    parser.add_argument(
        '--config',
        default='/etc/nas-monitor/config.json',
        help='Configuration file path'
    )
    parser.add_argument(
        '--log-level',
        default='INFO',
        choices=['DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'],
        help='Log level'
    )
    parser.add_argument(
        '--log-file',
        help='Log file path (optional, defaults to stdout only)'
    )

    args = parser.parse_args()

    # ロギング設定
    log_level = getattr(logging, args.log_level)
    setup_logging(log_level=log_level, log_file=args.log_file)

    logger = logging.getLogger(__name__)

    try:
        monitor = NASMonitor(config_file=args.config)
        monitor.run()
    except KeyboardInterrupt:
        logger.info("Interrupted by user")
        sys.exit(0)
    except Exception as e:
        logger.critical(f"Fatal error: {e}", exc_info=True)
        sys.exit(1)


if __name__ == '__main__':
    main()
