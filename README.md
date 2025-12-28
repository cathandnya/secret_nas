# Secret NAS

Raspberry Pi Zero WH向けの自動消去機能付きセキュアNASシステム

> 📁 **ディレクトリ構造とデプロイ方法**: 詳細は [STRUCTURE.md](STRUCTURE.md) を参照

## 概要

Secret NASは、一定期間（デフォルト30日間）アクセスがない場合に自動的にデータを完全消去するネットワークストレージシステムです。

### 主な機能

- **LUKS暗号化**: USB外付けストレージ全体をAES-256で暗号化
- **自動消去**: 設定可能な日数（デフォルト30日）アクセスなしで暗号化キーを削除（データ復元不可能）
- **段階的警告**: 消去の7日前、3日前、1日前にメール通知（日数に応じて自動調整）
- **高速消去**: キーファイル削除のみ（大容量でも数秒で完了）
- **物理的盗難対策**: USBを取り外しても暗号化されているため読めない

### 技術スタック

- **OS**: Raspberry Pi OS (Debian-based)
- **暗号化**: LUKS (dm-crypt)
- **NAS**: Samba (SMB/CIFS)
- **監視**: Python 3 + systemd
- **通知**: SMTP (Gmail対応)

## 必要なもの

### ハードウェア

- Raspberry Pi Zero WH（または他のRaspberry Pi）
- microSDカード（16GB以上推奨）
- USB外付けストレージ（USB HDD/SSD/メモリ）
- 電源アダプタ
- （オプション）ネットワーク接続（Wi-Fi または USB-Ethernet）

### ソフトウェア

- Raspberry Pi OS Lite（最新版）
- インターネット接続（セットアップ時）

## セットアップ

### 1. Raspberry Pi OSのインストール

1. Raspberry Pi Imagerで microSD カードに Raspberry Pi OS Lite を書き込む
2. SSH を有効化（`/boot/ssh` ファイルを作成）
3. Wi-Fi 設定（`/boot/wpa_supplicant.conf` を設定）
4. Raspberry Pi を起動

### 2. Secret NASのインストール

#### 方法1: デプロイパッケージを使う（最も推奨） ⭐

```bash
# 開発マシンで、デプロイパッケージを作成
cd /path/to/secret_nas
./deploy.sh

# Raspberry Piに転送（約20KB）
scp secret_nas_deploy.tar.gz pi@pi.local:~/

# Raspberry PiにSSHでログイン
ssh pi@pi.local

# 展開してセットアップ
mkdir -p ~/secret_nas
tar -xzf secret_nas_deploy.tar.gz -C ~/secret_nas
cd ~/secret_nas
sudo ./setup.sh
```

**メリット**:
- 必要なファイルのみをパッケージング（約20KB）
- テストファイルやDocker関連ファイルを除外
- 転送が高速

#### 方法2: 必要なファイルのみ直接転送

```bash
# 開発マシン（Mac/Linux）で、必要なファイルのみ転送
cd /path/to/secret_nas
scp -r setup.sh src config systemd scripts README.md pi@pi.local:~/secret_nas/

# Raspberry PiにSSHでログイン
ssh pi@pi.local

# セットアップスクリプトを実行（root権限必要）
cd ~/secret_nas
sudo ./setup.sh
```

#### 方法3: USBメモリ経由

```bash
# 開発マシンで、デプロイパッケージをUSBメモリにコピー
./deploy.sh
cp secret_nas_deploy.tar.gz /Volumes/USB_DRIVE/

# Raspberry PiでUSBメモリをマウント
ssh pi@pi.local
lsblk
sudo mkdir -p /mnt/usb
sudo mount /dev/sda1 /mnt/usb

# ホームディレクトリにコピーして展開
cp /mnt/usb/secret_nas_deploy.tar.gz ~/
mkdir -p ~/secret_nas
tar -xzf secret_nas_deploy.tar.gz -C ~/secret_nas
cd ~/secret_nas
sudo ./setup.sh
```

#### 方法4: Gitリポジトリから（オプション）

```bash
# SSH でログイン
ssh pi@pi.local

# リポジトリをクローン
git clone https://github.com/cathandnya/secret_nas.git
cd secret_nas

# セットアップスクリプトを実行
sudo ./setup.sh
```

### 3. セットアップ中の対話

セットアップスクリプトは以下の情報を対話的に尋ねます：

1. **USBデバイスの選択**: 暗号化するUSBストレージ
2. **NASユーザー名**: Sambaアクセス用のユーザー名
3. **Sambaパスワード**: ネットワークアクセス用のパスワード
4. **削除までの日数**: データ自動削除までの非アクティブ期間（デフォルト: 30日）
   - 入力した日数に応じて警告日が自動計算されます
   - 例: 30日 → 23, 27, 29日目に警告
   - 例: 14日 → 7, 11, 13日目に警告
   - 例: 7日 → 1, 4, 6日目に警告
5. **メール通知設定**（オプション）:
   - 受信メールアドレス
   - 送信メールアドレス
   - SMTPサーバー（Gmail: `smtp.gmail.com`）
   - SMTPポート（587）
   - SMTPユーザー名
   - SMTPパスワード（Gmailの場合はアプリパスワード）

### 4. Gmail アプリパスワードの取得（メール通知を使う場合）

1. [Google アカウント](https://myaccount.google.com/)にアクセス
2. セキュリティ > 2段階認証プロセス を有効化
3. セキュリティ > アプリパスワード で新しいパスワードを生成
4. 生成されたパスワードをセットアップ時に入力

## 使用方法

### NASへのアクセス

#### Windows

```
# ホスト名が raspberrypi の場合
\\raspberrypi\secure_share

# ホスト名が pi の場合
\\pi\secure_share
```

エクスプローラーのアドレスバーに入力し、ユーザー名とパスワードを入力

#### Mac

```
# ホスト名が raspberrypi の場合
smb://raspberrypi.local/secure_share

# ホスト名が pi の場合
smb://pi.local/secure_share
```

Finder > 移動 > サーバへ接続 で上記アドレスを入力

#### Linux

```bash
# ホスト名が raspberrypi の場合
smb://raspberrypi.local/secure_share

# ホスト名が pi の場合
smb://pi.local/secure_share

# コマンドラインで（ホスト名に応じて変更）
smbclient //raspberrypi/secure_share -U username
smbclient //pi/secure_share -U username
```

### 監視サービスの管理

```bash
# サービス状態確認
sudo systemctl status nas-monitor

# ログ確認（リアルタイム）
sudo journalctl -u nas-monitor -f

# 最終アクセス時刻確認
sudo cat /var/lib/nas-monitor/last_access.json

# サービス再起動
sudo systemctl restart nas-monitor

# サービス停止
sudo systemctl stop nas-monitor

# サービス開始
sudo systemctl start nas-monitor
```

### 設定変更

#### 削除日数を変更する

運用中に削除期間を変更したい場合、設定ファイルを編集します。

**手順**:

1. 設定ファイルを編集:
```bash
sudo nano /etc/nas-monitor/config.json
```

2. `inactivity_days` と `warning_days` を変更:

設定ファイルの例: `/etc/nas-monitor/config.json`

```json
{
  "mount_point": "/mnt/secure_nas",
  "device": "/dev/sda",
  "keyfile": "/root/.nas-keyfile",
  "inactivity_days": 30,
  "warning_days": [23, 27, 29],
  "notification": {
    "enabled": true,
    "method": "email",
    "email": {
      "to": "user@example.com",
      "from": "raspberrypi@example.com",
      "smtp_server": "smtp.gmail.com",
      "smtp_port": 587,
      "username": "your-email@gmail.com",
      "password": "your-app-password",
      "use_tls": true
    }
  }
}
```

3. サービスを再起動（設定を反映）:
```bash
sudo systemctl restart nas-monitor
```

4. 設定が反映されたか確認:
```bash
sudo journalctl -u nas-monitor -n 20
```

#### 削除期間のカスタマイズ例

- **14日で削除する場合**:
  ```json
  "inactivity_days": 14,
  "warning_days": [7, 11, 13]
  ```

- **60日で削除する場合**:
  ```json
  "inactivity_days": 60,
  "warning_days": [53, 57, 59]
  ```

- **7日で削除する場合**（短期間）:
  ```json
  "inactivity_days": 7,
  "warning_days": [3, 6]
  ```

- **2日で削除する場合**（超短期）:
  ```json
  "inactivity_days": 2,
  "warning_days": [1]
  ```

**重要な注意点**:
- `warning_days` は `inactivity_days` より小さい値を設定してください
- 警告日数の推奨値:
  - 8日以上: `[N-7, N-3, N-1]`
  - 4-7日: `[N/2, N-1]`
  - 2-3日: 自動調整
- 設定変更は即座に反映されますが、**既存の最終アクセス時刻は保持されます**
- 例: 20日経過後に30日→60日に変更した場合、あと40日で削除されます（合計60日）

## テスト方法

### ローカル開発環境でのテスト

Raspberry Piの実機がなくても、以下の方法でローカルでテストできます：

#### 方法1: Dockerコンテナ（最も簡単・推奨）

**A. 自動テスト（推奨・最速）** ⭐

```bash
# すべてのテストを自動実行
cd ~/secret_nas
./scripts/test-in-docker.sh
```

このスクリプトは自動的に：
- Dockerコンテナをビルド・起動
- Pythonモジュール単体テスト実行
- インストール確認テスト実行
- スクリプト構文チェック実行
- テスト完了後にコンテナを停止

**B. 統合テスト（詳細確認）**

```bash
# 完全な統合テスト（8項目）
cd ~/secret_nas
./scripts/test-integration-docker.sh
```

テスト項目：
1. ファイル構造確認
2. Pythonモジュールインポート
3. ConfigLoader動作確認
4. AccessTracker動作確認
5. SecureWiper初期化確認
6. EmailNotifier初期化確認
7. シェルスクリプト構文チェック
8. systemdサービスファイル構文チェック

**C. 手動テスト**

```bash
# Dockerでテスト環境を起動
cd ~/secret_nas
./scripts/test-docker.sh

# または手動で：
docker-compose up -d
docker-compose exec secret-nas bash

# コンテナ内でセットアップ
cd /home/pi/secret_nas
sudo ./setup.sh

# コンテナを停止
docker-compose down
```

**メリット**:
- 実機に近い環境で動作確認可能
- systemd、Samba、LUKSすべてテスト可能
- ホストOSに影響なし
- CI/CD統合が容易

#### 方法2: Pythonモジュール単体テスト（root権限不要）

```bash
# コア機能のみをテスト（最速）
cd ~/secret_nas
./scripts/test-modules.sh
```

出力例：
```
==========================================
  Secret NAS モジュールテスト
==========================================

[TEST] 1. ConfigLoader テスト
[PASS] ConfigLoader が正常に動作しました

[TEST] 2. AccessTracker テスト
[PASS] AccessTracker が正常に動作しました

[TEST] 3. EmailNotifier テスト（設定のみ）
[PASS] EmailNotifier の初期化に成功しました

[TEST] 4. SecureWiper テスト（dry-run）
[PASS] SecureWiper の初期化に成功しました

[TEST] 5. Logger テスト
[PASS] Logger が正常に動作しました

==========================================
  テスト結果サマリー
==========================================
合格: 5
失敗: 0

すべてのモジュールテストに合格しました！
```

#### 方法3: ローカルループバックデバイス（Linux/Mac）

```bash
# LUKS暗号化を実際にテスト（root権限必要）
cd ~/secret_nas
sudo ./scripts/test-local.sh
```

このスクリプトは：
- 仮想USBイメージ（100MB）を作成
- LUKS暗号化フォーマット
- マウント・アンマウントテスト
- セキュア消去のdry-runテスト

---

### 自動テストスクリプト（推奨）

#### クイックテスト（基本確認）

```bash
cd ~/secret_nas
sudo ./scripts/quick-test.sh
```

出力例：
```
Secret NAS クイックテスト
=========================

監視サービス: 実行中
ストレージ: マウント済み
暗号化: 有効
Samba: 実行中
最終アクセス: 0 日前
エラー (24h): なし

詳細テスト: sudo ./scripts/test-all.sh
```

#### 完全テスト（全機能確認）

```bash
cd ~/secret_nas
sudo ./scripts/test-all.sh
```

このスクリプトは以下を自動的にテストします：
1. インストール確認
2. 設定の妥当性チェック
3. systemdサービス確認
4. ストレージマウント確認
5. LUKS暗号化確認
6. Samba動作確認
7. アクセストラッキング確認
8. セキュア消去の安全性チェック（dry-run）
9. メール通知設定確認（オプション）
10. ログ出力確認

出力例：
```
==========================================
  Secret NAS 統合テストスイート
==========================================

[TEST] 1. インストール確認
[PASS] インストールディレクトリが存在します
[PASS] 監視デーモンが存在します
[PASS] 設定ファイルが存在します

...

==========================================
  テスト結果サマリー
==========================================
合格: 15
失敗: 0
スキップ: 0

すべてのテストに合格しました！
```

---

### 手動テスト（個別確認）

#### 1. メール通知のテスト

```bash
cd /opt/nas-monitor

# SMTP接続テスト（送信なし）
sudo python3 src/notifier.py \
  --to your-email@example.com \
  --from raspberrypi@example.com \
  --smtp-server smtp.gmail.com \
  --smtp-port 587 \
  --username your-email@gmail.com \
  --password your-app-password \
  --test-only

# テストメール送信
sudo python3 src/notifier.py \
  --to your-email@example.com \
  --from raspberrypi@example.com \
  --smtp-server smtp.gmail.com \
  --smtp-port 587 \
  --username your-email@gmail.com \
  --password your-app-password
```

### 2. セキュア消去の安全性チェック（実際には消去しない）

```bash
cd /opt/nas-monitor

# ドライランモード（安全チェックのみ実行）
sudo python3 src/secure_wipe.py \
  --device /dev/sda \
  --keyfile /root/.nas-keyfile \
  --mount-point /mnt/secure_nas \
  --dry-run
```

成功すれば以下のように表示されます：
```
✓ All safety checks passed
  Device: /dev/sda
  Keyfile: /root/.nas-keyfile
  Mount point: /mnt/secure_nas
```

### 3. アクセストラッキングのテスト

```bash
cd /opt/nas-monitor

# 現在の状態を確認
sudo cat /var/lib/nas-monitor/last_access.json

# NASにアクセスしてファイルを開く（Windows/Mac/Linuxから）
# その後、再度確認
sudo cat /var/lib/nas-monitor/last_access.json

# 経過日数を手動で確認
sudo python3 -c "
import sys
sys.path.insert(0, '/opt/nas-monitor/src')
from access_tracker import AccessTracker
tracker = AccessTracker()
days = tracker.days_since_last_access()
print(f'Days since last access: {days}')
"
```

### 4. 監視デーモンの動作確認

```bash
# リアルタイムログ監視
sudo journalctl -u nas-monitor -f

# 別のターミナルでNASにアクセスし、ログに表示されるか確認
# 以下のようなログが出れば正常動作中：
# nas-monitor: Access detected: ...
# nas-monitor: Updated last access time: ...
```

### 5. タイマーリセットのテスト

```bash
# 現在の経過日数確認
sudo cat /var/lib/nas-monitor/last_access.json

# NASにアクセス（任意のファイルを開く）

# 数秒待ってから再確認（last_accessが更新されているはず）
sudo cat /var/lib/nas-monitor/last_access.json

# 通知状態もリセットされているか確認
sudo cat /var/lib/nas-monitor/notification_state.json
# ファイルが削除されているか、内容が空ならリセット成功
```

### 6. 警告日のシミュレーション（開発・テスト用）

**注意: 本番環境では実行しないでください**

```bash
# 設定を一時的に変更してテスト
sudo systemctl stop nas-monitor

# テスト用設定（5日で消去、3日目に警告）
sudo tee /etc/nas-monitor/config.test.json > /dev/null <<'EOF'
{
  "mount_point": "/mnt/secure_nas",
  "device": "/dev/sda",
  "keyfile": "/root/.nas-keyfile",
  "inactivity_days": 5,
  "warning_days": [3, 4],
  "state_file": "/var/lib/nas-monitor/last_access.json",
  "notification_state_file": "/var/lib/nas-monitor/notification_state.json",
  "shutdown_after_wipe": false,
  "notification": {
    "enabled": true,
    "method": "email",
    "email": {
      "to": "your-email@example.com",
      "from": "raspberrypi@example.com",
      "smtp_server": "smtp.gmail.com",
      "smtp_port": 587,
      "username": "your-email@gmail.com",
      "password": "your-app-password",
      "use_tls": true
    }
  }
}
EOF

# 最終アクセス時刻を3日前に設定
sudo python3 -c "
import json
from datetime import datetime, timedelta
from pathlib import Path

state_file = Path('/var/lib/nas-monitor/last_access.json')
past_time = datetime.now() - timedelta(days=3)

data = {
    'last_access': past_time.isoformat(),
    'timestamp': int(past_time.timestamp()),
    'updated_at': datetime.now().isoformat()
}

with open(state_file, 'w') as f:
    json.dump(data, f, indent=2)

print(f'Set last access to: {past_time}')
"

# テスト設定でデーモンを起動
cd /opt/nas-monitor
sudo python3 src/monitor.py --config /etc/nas-monitor/config.test.json

# 警告メールが送信されるか確認
# Ctrl+C で停止

# 元に戻す
sudo systemctl start nas-monitor
```

### 7. 完全な統合テスト

```bash
# 1. サービス起動確認
sudo systemctl status nas-monitor

# 2. NASアクセス可能確認
smbclient //localhost/secure_share -U username

# 3. ログ確認
sudo journalctl -u nas-monitor -n 50

# 4. 設定確認
sudo python3 -c "
import sys
sys.path.insert(0, '/opt/nas-monitor/src')
from config_loader import ConfigLoader
config = ConfigLoader()
if config.validate():
    print('✓ Configuration is valid')
else:
    print('✗ Configuration has errors')
"

# 5. アクセス追跡確認
ls -la /var/lib/nas-monitor/

# すべて正常なら以下のファイルが存在：
# - last_access.json
# - notification_state.json (通知有効時)
```

### 8. Samba接続テスト

```bash
# ローカルホストから接続テスト
smbclient -L localhost -U username

# 共有フォルダにアクセス
smbclient //localhost/secure_share -U username
# パスワード入力後、以下のコマンドでテスト:
# smb: \> ls
# smb: \> put testfile.txt
# smb: \> get testfile.txt
# smb: \> exit
```

## セキュリティの仕組み

### LUKS暗号化

1. USB全体がAES-256で暗号化
2. 暗号化キーは `/root/.nas-keyfile` に保存（SDカード上）
3. 起動時に自動的にキーファイルで復号化
4. 別のPCに接続してもキーなしでは読めない

### 自動消去

1. Sambaアクセスログをリアルタイム監視
2. アクセス検出時に最終アクセス時刻を更新
3. 6時間ごとに経過日数をチェック
4. 30日間アクセスなし → キーファイルを `shred` で完全削除
5. キー削除後、USBは永久に復号不可能

### 段階的通知

通知タイミングは削除期間に応じて自動調整されます：

**30日で削除する場合**（デフォルト）:
- **23日目**: 「警告: あと7日でデータ消去されます」
- **27日目**: 「緊急警告: あと3日でデータ消去されます」
- **29日目**: 「最終警告: 明日データが消去されます」
- **30日目**: 自動消去実行

**14日で削除する場合**:
- **7日目**: 「警告: あと7日でデータ消去されます」
- **11日目**: 「緊急警告: あと3日でデータ消去されます」
- **13日目**: 「最終警告: 明日データが消去されます」
- **14日目**: 自動消去実行

**7日で削除する場合**:
- **1日目**: 「警告: あと6日でデータ消去されます」
- **4日目**: 「緊急警告: あと3日でデータ消去されます」
- **6日目**: 「最終警告: 明日データが消去されます」
- **7日目**: 自動消去実行

## トラブルシューティング

### NASにアクセスできない

```bash
# Sambaサービスの状態確認
sudo systemctl status smbd

# ファイアウォール確認（必要に応じて無効化）
sudo ufw status
sudo ufw allow samba

# ネットワーク接続確認
ping raspberrypi.local
```

### メール通知が届かない

```bash
# 通知テスト
cd /opt/nas-monitor
python3 src/notifier.py \
  --to your-email@example.com \
  --from raspberrypi@example.com \
  --smtp-server smtp.gmail.com \
  --smtp-port 587 \
  --username your-email@gmail.com \
  --password your-app-password \
  --test-only
```

### 監視サービスが起動しない

```bash
# 詳細ログ確認
sudo journalctl -u nas-monitor -n 100

# 設定ファイル確認
sudo cat /etc/nas-monitor/config.json

# 手動起動してエラー確認
cd /opt/nas-monitor
sudo python3 src/monitor.py --config /etc/nas-monitor/config.json
```

### USBが認識されない

```bash
# デバイス確認
lsblk
sudo fdisk -l

# LUKS デバイス確認
sudo cryptsetup status secure_nas_crypt

# 手動マウント
sudo cryptsetup open --key-file /root/.nas-keyfile /dev/sda secure_nas_crypt
sudo mount /dev/mapper/secure_nas_crypt /mnt/secure_nas
```

## 緊急時の操作

### タイマーをリセット（データ保持）

NASに任意のファイルをアクセスするだけで自動的にリセットされます。
または手動でリセット：

```bash
sudo systemctl restart nas-monitor
```

### 手動でデータ消去

```bash
# 監視サービス停止
sudo systemctl stop nas-monitor

# 手動消去実行（要注意！復元不可能）
cd /opt/nas-monitor
sudo python3 src/secure_wipe.py \
  --device /dev/sda \
  --keyfile /root/.nas-keyfile \
  --mount-point /mnt/secure_nas
```

### キーファイルのバックアップ

万が一SDカードが壊れた場合に備えて、キーファイルをバックアップできます：

```bash
# バックアップ作成（安全な場所に保管）
sudo cp /root/.nas-keyfile /path/to/safe/location/nas-keyfile.backup

# 復元
sudo cp /path/to/safe/location/nas-keyfile.backup /root/.nas-keyfile
sudo chmod 600 /root/.nas-keyfile
```

**警告**: バックアップを作成すると、セキュリティが低下します。バックアップは物理的に安全な場所（別の暗号化USBなど）に保管してください。

## アンインストール

```bash
# 監視サービス停止・無効化
sudo systemctl stop nas-monitor
sudo systemctl disable nas-monitor

# サービスファイル削除
sudo rm /etc/systemd/system/nas-monitor.service
sudo systemctl daemon-reload

# インストールファイル削除
sudo rm -rf /opt/nas-monitor
sudo rm -rf /etc/nas-monitor
sudo rm -rf /var/lib/nas-monitor

# Samba設定を元に戻す
sudo cp /etc/samba/smb.conf.backup.* /etc/samba/smb.conf
sudo systemctl restart smbd

# LUKS デバイスをクローズ
sudo umount /mnt/secure_nas
sudo cryptsetup close secure_nas_crypt

# /etc/fstab と /etc/crypttab から該当行を削除
sudo vi /etc/fstab
sudo vi /etc/crypttab
```

## パフォーマンス最適化（Pi Zero WH）

Secret NASは Raspberry Pi Zero WH の限られたリソース（512MB RAM、1GHz CPU）でも動作するよう最適化されています：

- Samba最大接続数: 10
- 監視デーモンメモリ制限: 50MB
- CPU使用率制限: 20%
- チェック間隔: 6時間
- ログレベル: 最小限

より高速なパフォーマンスが必要な場合は、Raspberry Pi 3/4 を使用してください。

## ライセンス

MIT License

## 免責事項

このソフトウェアは、データを自動的に完全削除します。一度削除されたデータは復元できません。使用は自己責任で行ってください。作者は、データ損失やその他の損害について一切の責任を負いません。
