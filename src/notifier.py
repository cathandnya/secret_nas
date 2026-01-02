#!/usr/bin/env python3
"""
通知モジュール

メールで段階的な警告通知を送信する。
"""

import json
import logging
import smtplib
import socket
from datetime import datetime
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from pathlib import Path
from typing import Dict, Optional


class EmailNotifier:
    """
    メール通知クラス

    SMTP経由で警告メールを送信する。
    """

    def __init__(
        self,
        email_config: Dict[str, any],
        state_file: str = '/var/lib/nas-monitor/notification_state.json',
        share_name: str = 'secure_share'
    ):
        """
        初期化

        Args:
            email_config: メール設定辞書
            state_file: 通知状態ファイルパス
            share_name: SMB共有名
        """
        self.email_config = email_config
        self.state_file = Path(state_file)
        self.share_name = share_name
        self.logger = logging.getLogger(__name__)

        # 状態ファイルのディレクトリを作成
        self.state_file.parent.mkdir(parents=True, exist_ok=True)

    def _load_notification_state(self) -> Dict:
        """
        通知状態を読み込む

        Returns:
            通知状態辞書
        """
        if not self.state_file.exists():
            return {}

        try:
            with open(self.state_file, 'r') as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError) as e:
            self.logger.error(f"Failed to load notification state: {e}")
            return {}

    def _save_notification_state(self, state: Dict):
        """
        通知状態を保存

        Args:
            state: 通知状態辞書
        """
        try:
            # アトミック書き込み
            temp_file = self.state_file.with_suffix('.tmp')
            with open(temp_file, 'w') as f:
                json.dump(state, f, indent=2)
            temp_file.replace(self.state_file)

            self.logger.debug(f"Saved notification state: {state}")
        except Exception as e:
            self.logger.error(f"Failed to save notification state: {e}")

    def _get_hostname(self) -> str:
        """ホスト名を取得"""
        try:
            return socket.gethostname()
        except Exception:
            return 'raspberrypi'

    def _create_warning_message(
        self,
        days_elapsed: int,
        days_remaining: int,
        deletion_date: datetime
    ) -> str:
        """
        警告メッセージを生成

        Args:
            days_elapsed: 経過日数
            days_remaining: 残り日数
            deletion_date: 削除予定日時

        Returns:
            メール本文（テキスト）
        """
        hostname = self._get_hostname()

        if days_remaining <= 1:
            urgency = "最終警告"
            warning_level = "CRITICAL"
        elif days_remaining <= 3:
            urgency = "緊急警告"
            warning_level = "URGENT"
        else:
            urgency = "警告"
            warning_level = "WARNING"

        message = f"""こんにちは、

Secret NAS システムから自動通知です。

{urgency}: データ削除が近づいています

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  警告レベル: {warning_level}
  最終アクセス: {days_elapsed}日前
  残り期間: あと{days_remaining}日
  削除予定日時: {deletion_date.strftime('%Y年%m月%d日 %H:%M:%S')}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

あと{days_remaining}日間アクセスがない場合、すべてのデータが自動的に
完全削除されます。暗号化キーが削除されるため、復元は不可能です。

【データを保持したい場合】
今すぐNASにアクセスしてください。アクセスするとタイマーが
リセットされ、再び30日間の猶予が与えられます。

【アクセス方法】
  ホスト: {hostname}.local (または {hostname})
  共有名: {self.share_name}

  Windows: \\\\{hostname}.local\\{self.share_name}
  Mac: Finder > 移動 > サーバへ接続 > smb://{hostname}.local/{self.share_name}
  Linux: smb://{hostname}.local/{self.share_name}

【重要】
データを削除したい場合は、何もする必要はありません。
予定日時になると自動的に削除されます。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

このメールはSecret NASシステムから自動送信されています。
返信しないでください。

Secret NAS - Raspberry Pi
"""
        return message

    def _create_subject(self, days_remaining: int) -> str:
        """
        件名を生成

        Args:
            days_remaining: 残り日数

        Returns:
            メール件名
        """
        if days_remaining <= 1:
            return f"[最終警告] Secret NAS データ削除まであと{days_remaining}日"
        elif days_remaining <= 3:
            return f"[緊急] Secret NAS データ削除まであと{days_remaining}日"
        else:
            return f"[警告] Secret NAS データ削除まであと{days_remaining}日"

    def send_warning(
        self,
        warning_day: int,
        days_elapsed: int,
        inactivity_days: int,
        deletion_date: datetime
    ) -> bool:
        """
        警告メールを送信

        Args:
            warning_day: 警告日（例: 23）
            days_elapsed: 経過日数
            inactivity_days: 非アクティブ期間（例: 30）
            deletion_date: 削除予定日時

        Returns:
            送信成功した場合True
        """
        # 既に送信済みかチェック
        state = self._load_notification_state()
        warning_key = f"warning_{warning_day}"

        if state.get(warning_key, {}).get('sent', False):
            self.logger.info(f"Warning for day {warning_day} already sent, skipping")
            return True

        days_remaining = inactivity_days - days_elapsed

        # メッセージ作成
        subject = self._create_subject(days_remaining)
        body = self._create_warning_message(days_elapsed, days_remaining, deletion_date)

        # メール送信
        success = self._send_email(subject, body)

        # 送信状態を記録
        if success:
            state[warning_key] = {
                'sent': True,
                'sent_at': datetime.now().isoformat(),
                'days_elapsed': days_elapsed,
                'days_remaining': days_remaining
            }
            self._save_notification_state(state)

        return success

    def send_wipe_complete_notification(self, days_elapsed: int, last_access: datetime) -> bool:
        """
        削除完了通知メールを送信

        Args:
            days_elapsed: 最終アクセスからの経過日数
            last_access: 最終アクセス日時

        Returns:
            送信成功した場合True
        """
        hostname = self._get_hostname()

        subject = "[完了] Secret NAS データが削除されました"

        body = f"""こんにちは、

Secret NASシステムから自動通知です。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  データ削除が完了しました
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

非アクティブ期間が削除閾値に達したため、すべてのデータが
安全に削除されました。

【削除情報】
  ホスト名: {hostname}
  最終アクセス: {last_access.strftime('%Y年%m月%d日 %H:%M:%S')}
  経過日数: {days_elapsed}日
  削除実行日時: {datetime.now().strftime('%Y年%m月%d日 %H:%M:%S')}

【削除方法】
  LUKS暗号化キーファイルを完全削除しました。
  暗号化されたデータは残っていますが、キーがないため
  永久に復号できません。データ復旧は不可能です。

【次のステップ】
  NASを再度使用したい場合は、以下の手順でセットアップしてください：
  1. Raspberry Piにログイン
  2. setup.shスクリプトを再実行
  3. 新しい暗号化キーで初期化

このメールはSecret NASシステムから自動送信されています。
返信しないでください。

Secret NAS - Raspberry Pi
"""

        # メール送信
        success = self._send_email(subject, body)

        if success:
            self.logger.info("Wipe complete notification sent successfully")
        else:
            self.logger.error("Failed to send wipe complete notification")

        return success

    def send_deletion_cancelled_notification(self) -> bool:
        """
        削除キャンセル通知メールを送信
        （警告送信後にアクセスがあった場合）

        Returns:
            送信成功した場合True
        """
        hostname = self._get_hostname()

        subject = "[解除] Secret NAS データ削除がキャンセルされました"

        body = f"""こんにちは、

Secret NASシステムから自動通知です。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  データ削除がキャンセルされました
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

NASへのアクセスを検出したため、削除予定をキャンセルしました。
以前送信した警告は無効となり、タイマーがリセットされました。

【現在の状態】
  ホスト名: {hostname}
  アクセス検出日時: {datetime.now().strftime('%Y年%m月%d日 %H:%M:%S')}
  タイマー: リセット完了

【次回の削除予定】
  本日から再び非アクティブ期間のカウントが開始されます。
  設定された期間（デフォルト30日）アクセスがない場合、
  再度警告メールが送信され、最終的にデータが削除されます。

【NASアクセス情報】
  Windows: \\\\{hostname}\\{self.share_name}
  Mac/Linux: smb://{hostname}.local/{self.share_name}

データは安全に保持されています。引き続きご利用ください。

このメールはSecret NASシステムから自動送信されています。
返信しないでください。

Secret NAS - Raspberry Pi
"""

        # メール送信
        success = self._send_email(subject, body)

        if success:
            self.logger.info("Deletion cancelled notification sent successfully")
        else:
            self.logger.error("Failed to send deletion cancelled notification")

        return success

    def _send_email(self, subject: str, body: str) -> bool:
        """
        実際にメールを送信

        Args:
            subject: 件名
            body: 本文

        Returns:
            送信成功した場合True
        """
        to_addr = self.email_config.get('to')
        from_addr = self.email_config.get('from')
        smtp_server = self.email_config.get('smtp_server')
        smtp_port = self.email_config.get('smtp_port', 587)
        username = self.email_config.get('username')
        password = self.email_config.get('password')
        use_tls = self.email_config.get('use_tls', True)

        if not all([to_addr, from_addr, smtp_server, username, password]):
            self.logger.error("Email configuration is incomplete")
            return False

        try:
            # MIMEメッセージ作成
            msg = MIMEMultipart('alternative')
            msg['Subject'] = subject
            msg['From'] = from_addr
            msg['To'] = to_addr

            # テキストパート
            text_part = MIMEText(body, 'plain', 'utf-8')
            msg.attach(text_part)

            # SMTP接続
            self.logger.info(f"Connecting to SMTP server: {smtp_server}:{smtp_port}")

            if use_tls:
                # TLS接続
                server = smtplib.SMTP(smtp_server, smtp_port, timeout=30)
                server.starttls()
            else:
                # 非TLS接続
                server = smtplib.SMTP(smtp_server, smtp_port, timeout=30)

            # ログイン
            server.login(username, password)

            # メール送信
            server.send_message(msg)
            server.quit()

            self.logger.info(f"Email sent successfully to {to_addr}")
            return True

        except smtplib.SMTPAuthenticationError as e:
            self.logger.error(f"SMTP authentication failed: {e}")
            return False
        except smtplib.SMTPException as e:
            self.logger.error(f"SMTP error occurred: {e}")
            return False
        except Exception as e:
            self.logger.error(f"Failed to send email: {e}")
            return False

    def reset_notification_state(self):
        """通知状態をリセット（アクセスがあった時）"""
        if self.state_file.exists():
            self.state_file.unlink()
            self.logger.info("Notification state reset")

    def test_connection(self) -> bool:
        """
        SMTP接続をテスト

        Returns:
            接続成功した場合True
        """
        smtp_server = self.email_config.get('smtp_server')
        smtp_port = self.email_config.get('smtp_port', 587)
        username = self.email_config.get('username')
        password = self.email_config.get('password')
        use_tls = self.email_config.get('use_tls', True)

        try:
            self.logger.info(f"Testing SMTP connection to {smtp_server}:{smtp_port}")

            if use_tls:
                server = smtplib.SMTP(smtp_server, smtp_port, timeout=30)
                server.starttls()
            else:
                server = smtplib.SMTP(smtp_server, smtp_port, timeout=30)

            server.login(username, password)
            server.quit()

            self.logger.info("SMTP connection test successful")
            return True

        except Exception as e:
            self.logger.error(f"SMTP connection test failed: {e}")
            return False


if __name__ == '__main__':
    """テスト用エントリーポイント"""
    import argparse

    parser = argparse.ArgumentParser(description='Email Notifier Test')
    parser.add_argument('--to', required=True, help='Recipient email address')
    parser.add_argument('--from', dest='from_addr', required=True, help='Sender email address')
    parser.add_argument('--smtp-server', default='smtp.gmail.com', help='SMTP server')
    parser.add_argument('--smtp-port', type=int, default=587, help='SMTP port')
    parser.add_argument('--username', required=True, help='SMTP username')
    parser.add_argument('--password', required=True, help='SMTP password')
    parser.add_argument('--test-only', action='store_true', help='Test connection only')

    args = parser.parse_args()

    # ロギング設定
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )

    email_config = {
        'to': args.to,
        'from': args.from_addr,
        'smtp_server': args.smtp_server,
        'smtp_port': args.smtp_port,
        'username': args.username,
        'password': args.password,
        'use_tls': True
    }

    notifier = EmailNotifier(email_config)

    if args.test_only:
        if notifier.test_connection():
            print("✓ SMTP connection successful")
        else:
            print("✗ SMTP connection failed")
    else:
        # テストメール送信
        deletion_date = datetime.now().replace(hour=23, minute=59, second=59)
        success = notifier.send_warning(
            warning_day=23,
            days_elapsed=23,
            inactivity_days=30,
            deletion_date=deletion_date
        )
        if success:
            print("✓ Test email sent successfully")
        else:
            print("✗ Failed to send test email")
