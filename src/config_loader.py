#!/usr/bin/env python3
"""
設定ファイル読み込みモジュール

JSON形式の設定ファイルを読み込み、デフォルト値を提供する。
"""

import json
import logging
from pathlib import Path
from typing import Any, Dict, List, Optional


class ConfigLoader:
    """設定ファイルローダー"""

    DEFAULT_CONFIG = {
        'mount_point': '/mnt/secure_nas',
        'device': None,  # 必須項目
        'keyfile': '/root/.nas-keyfile',
        'inactivity_days': 30,
        'warning_days': [23, 27, 29],
        'state_file': '/var/lib/nas-monitor/last_access.json',
        'notification_state_file': '/var/lib/nas-monitor/notification_state.json',
        'reboot_after_wipe': True,
        'notification': {
            'enabled': False,
            'method': 'email',
            'email': {
                'to': '',
                'from': '',
                'smtp_server': 'smtp.gmail.com',
                'smtp_port': 587,
                'username': '',
                'password': '',
                'use_tls': True
            }
        }
    }

    def __init__(self, config_file: str = '/etc/nas-monitor/config.json'):
        """
        設定ローダーを初期化

        Args:
            config_file: 設定ファイルのパス
        """
        self.config_file = Path(config_file)
        self.logger = logging.getLogger(__name__)
        self.config = self._load_config()

    def _load_config(self) -> Dict[str, Any]:
        """
        設定ファイルを読み込む

        Returns:
            設定辞書
        """
        # デフォルト設定をコピー
        config = self.DEFAULT_CONFIG.copy()

        # 設定ファイルが存在する場合は読み込み
        if self.config_file.exists():
            try:
                with open(self.config_file, 'r') as f:
                    user_config = json.load(f)

                # デフォルト設定に上書き
                config.update(user_config)

                # notification設定は深くマージ
                if 'notification' in user_config:
                    config['notification'].update(user_config['notification'])
                    if 'email' in user_config.get('notification', {}):
                        config['notification']['email'].update(
                            user_config['notification']['email']
                        )

                self.logger.info(f"Loaded configuration from {self.config_file}")
            except json.JSONDecodeError as e:
                self.logger.error(f"Failed to parse config file: {e}")
                self.logger.warning("Using default configuration")
            except Exception as e:
                self.logger.error(f"Failed to load config file: {e}")
                self.logger.warning("Using default configuration")
        else:
            self.logger.warning(
                f"Config file not found: {self.config_file}, using defaults"
            )

        return config

    def get(self, key: str, default: Any = None) -> Any:
        """
        設定値を取得

        Args:
            key: 設定キー
            default: デフォルト値

        Returns:
            設定値
        """
        return self.config.get(key, default)

    def get_notification_config(self) -> Dict[str, Any]:
        """通知設定を取得"""
        return self.config.get('notification', {})

    def get_email_config(self) -> Dict[str, Any]:
        """メール設定を取得"""
        return self.config.get('notification', {}).get('email', {})

    def is_notification_enabled(self) -> bool:
        """通知が有効かどうか"""
        return self.config.get('notification', {}).get('enabled', False)

    def get_warning_days(self) -> List[int]:
        """警告日のリストを取得"""
        return self.config.get('warning_days', [23, 27, 29])

    def validate(self) -> bool:
        """
        設定の妥当性をチェック

        Returns:
            設定が妥当な場合True
        """
        errors = []

        # 必須項目チェック
        if not self.config.get('device'):
            errors.append("Device path is not configured")

        # 通知設定チェック
        if self.is_notification_enabled():
            email_config = self.get_email_config()
            required_fields = ['to', 'from', 'smtp_server', 'username', 'password']
            for field in required_fields:
                if not email_config.get(field):
                    errors.append(f"Email configuration missing: {field}")

        # 警告日チェック
        inactivity_days = self.config.get('inactivity_days', 30)
        warning_days = self.get_warning_days()
        for day in warning_days:
            if day >= inactivity_days:
                errors.append(
                    f"Warning day {day} must be less than inactivity_days {inactivity_days}"
                )

        if errors:
            for error in errors:
                self.logger.error(f"Configuration error: {error}")
            return False

        return True

    def save_example_config(self, output_path: str = '/etc/nas-monitor/config.example.json'):
        """
        設定ファイルの例を保存

        Args:
            output_path: 出力先パス
        """
        example_config = {
            "mount_point": "/mnt/secure_nas",
            "device": "/dev/sda",
            "keyfile": "/root/.nas-keyfile",
            "inactivity_days": 30,
            "warning_days": [23, 27, 29],
            "state_file": "/var/lib/nas-monitor/last_access.json",
            "notification_state_file": "/var/lib/nas-monitor/notification_state.json",
            "reboot_after_wipe": True,
            "notification": {
                "enabled": True,
                "method": "email",
                "email": {
                    "to": "user@example.com",
                    "from": "raspberrypi@example.com",
                    "smtp_server": "smtp.gmail.com",
                    "smtp_port": 587,
                    "username": "your-email@gmail.com",
                    "password": "your-app-specific-password",
                    "use_tls": True
                }
            }
        }

        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)

        with open(output_path, 'w') as f:
            json.dump(example_config, f, indent=2)

        self.logger.info(f"Example config saved to {output_path}")
