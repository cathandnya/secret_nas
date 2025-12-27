#!/usr/bin/env python3
"""
ロギングユーティリティ

NAS監視システム全体で使用する統一的なログ設定を提供する。
"""

import logging
import sys
from pathlib import Path


def setup_logging(
    log_level=logging.INFO,
    log_file=None,
    log_format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
):
    """
    ロギングをセットアップする

    Args:
        log_level: ログレベル (デフォルト: INFO)
        log_file: ログファイルパス (Noneの場合はstdoutのみ)
        log_format: ログフォーマット文字列
    """
    # ルートロガーを取得
    root_logger = logging.getLogger()
    root_logger.setLevel(log_level)

    # 既存のハンドラをクリア
    root_logger.handlers.clear()

    # フォーマッター作成
    formatter = logging.Formatter(log_format)

    # コンソールハンドラ
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setLevel(log_level)
    console_handler.setFormatter(formatter)
    root_logger.addHandler(console_handler)

    # ファイルハンドラ（指定されている場合）
    if log_file:
        log_path = Path(log_file)
        log_path.parent.mkdir(parents=True, exist_ok=True)

        file_handler = logging.FileHandler(log_file)
        file_handler.setLevel(log_level)
        file_handler.setFormatter(formatter)
        root_logger.addHandler(file_handler)

    return root_logger


def get_logger(name):
    """
    指定された名前のロガーを取得

    Args:
        name: ロガー名（通常は __name__ を使用）

    Returns:
        logging.Logger: 設定済みのロガー
    """
    return logging.getLogger(name)
