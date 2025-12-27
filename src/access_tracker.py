#!/usr/bin/env python3
"""
アクセストラッキングモジュール

Sambaの監査ログをリアルタイムで監視し、最終アクセス時刻を記録する。
"""

import json
import logging
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional


class AccessTracker:
    """
    アクセス追跡クラス

    最終アクセス時刻をJSON形式で永続化し、経過日数を計算する。
    """

    def __init__(self, state_file: str = '/var/lib/nas-monitor/last_access.json'):
        """
        アクセストラッカーを初期化

        Args:
            state_file: 状態ファイルのパス
        """
        self.state_file = Path(state_file)
        self.logger = logging.getLogger(__name__)

        # 状態ファイルのディレクトリを作成
        self.state_file.parent.mkdir(parents=True, exist_ok=True)

    def get_last_access(self) -> Optional[datetime]:
        """
        最終アクセス時刻を取得

        Returns:
            最終アクセス時刻（datetime）、存在しない場合はNone
        """
        if not self.state_file.exists():
            return None

        try:
            with open(self.state_file, 'r') as f:
                data = json.load(f)
                return datetime.fromisoformat(data['last_access'])
        except (json.JSONDecodeError, KeyError, ValueError) as e:
            self.logger.error(f"Failed to read last access time: {e}")
            return None

    def update_access(self, access_time: Optional[datetime] = None):
        """
        アクセス時刻を更新

        Args:
            access_time: 記録する時刻（Noneの場合は現在時刻）
        """
        if access_time is None:
            access_time = datetime.now()

        data = {
            'last_access': access_time.isoformat(),
            'timestamp': int(access_time.timestamp()),
            'updated_at': datetime.now().isoformat()
        }

        try:
            # アトミック書き込み
            temp_file = self.state_file.with_suffix('.tmp')
            with open(temp_file, 'w') as f:
                json.dump(data, f, indent=2)
            temp_file.replace(self.state_file)

            self.logger.info(f"Updated last access time: {access_time.isoformat()}")
        except Exception as e:
            self.logger.error(f"Failed to update access time: {e}")
            raise

    def days_since_last_access(self) -> Optional[int]:
        """
        最終アクセスからの経過日数を計算

        Returns:
            経過日数（int）、アクセス履歴がない場合はNone
        """
        last_access = self.get_last_access()
        if last_access is None:
            return None

        delta = datetime.now() - last_access
        return delta.days

    def hours_since_last_access(self) -> Optional[float]:
        """
        最終アクセスからの経過時間（時間単位）を計算

        Returns:
            経過時間（float）、アクセス履歴がない場合はNone
        """
        last_access = self.get_last_access()
        if last_access is None:
            return None

        delta = datetime.now() - last_access
        return delta.total_seconds() / 3600

    def get_deletion_date(self, inactivity_days: int = 30) -> Optional[datetime]:
        """
        データ削除予定日時を計算

        Args:
            inactivity_days: 非アクティブ期間（日数）

        Returns:
            削除予定日時、アクセス履歴がない場合はNone
        """
        last_access = self.get_last_access()
        if last_access is None:
            return None

        return last_access + timedelta(days=inactivity_days)

    def should_send_warning(
        self,
        warning_day: int,
        notification_state: dict
    ) -> bool:
        """
        指定された警告日に通知すべきかチェック

        Args:
            warning_day: 警告日（例：23日目）
            notification_state: 通知状態辞書

        Returns:
            通知すべき場合True
        """
        days = self.days_since_last_access()
        if days is None:
            return False

        # まだ警告日に到達していない
        if days < warning_day:
            return False

        # 既に次の警告日を過ぎている（送信済みとみなす）
        if days > warning_day:
            return False

        # この警告日で既に送信済みかチェック
        warning_key = f"warning_{warning_day}"
        if notification_state.get(warning_key, {}).get('sent', False):
            return False

        return True

    def reset(self):
        """
        アクセス履歴をリセット（初期化）

        現在時刻でアクセス履歴を初期化する。
        """
        self.update_access()
        self.logger.info("Access history reset")

    def delete_state_file(self):
        """状態ファイルを削除"""
        if self.state_file.exists():
            self.state_file.unlink()
            self.logger.info("State file deleted")
