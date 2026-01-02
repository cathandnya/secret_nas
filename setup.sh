#!/bin/bash
#
# Secret NAS Setup Script
#
# Raspberry Pi向けのセキュアなNASシステムをセットアップする。
# USB外付けストレージをLUKS暗号化し、30日間アクセスがなければ
# 自動的にデータを消去する。
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/nas-monitor"
MOUNT_POINT="/mnt/secure_nas"
LUKS_NAME="secure_nas_crypt"
KEYFILE="/root/.nas-keyfile"
USB_DEVICE=""

# カラー出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# ルート権限チェック
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root"
   exit 1
fi

# 既存環境の初期化
cleanup_existing_setup() {
    log_step "Checking existing setup..."

    local services_running=false

    # nas-monitorサービスをチェック
    if systemctl is-active --quiet nas-monitor 2>/dev/null; then
        log_warn "nas-monitor service is currently running"
        services_running=true
    fi

    # Sambaサービスをチェック
    if systemctl is-active --quiet smbd 2>/dev/null; then
        log_warn "Samba service is currently running"
        services_running=true
    fi

    if [ "$services_running" = true ]; then
        echo ""
        log_warn "Existing Secret NAS services are running."
        log_warn "These services will be stopped and reconfigured."
        read -p "Continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_error "Setup aborted by user"
            exit 1
        fi

        # nas-monitorサービスを停止・無効化
        if systemctl is-active --quiet nas-monitor 2>/dev/null; then
            log_info "Stopping nas-monitor service..."
            systemctl stop nas-monitor
        fi

        if systemctl is-enabled --quiet nas-monitor 2>/dev/null; then
            log_info "Disabling nas-monitor service..."
            systemctl disable nas-monitor
        fi

        # Sambaサービスを停止
        if systemctl is-active --quiet smbd 2>/dev/null; then
            log_info "Stopping Samba service..."
            systemctl stop smbd
        fi

        if systemctl is-active --quiet nmbd 2>/dev/null; then
            log_info "Stopping nmbd service..."
            systemctl stop nmbd
        fi

        log_info "Existing services stopped"
    else
        log_info "No existing services found"
    fi
}

# Raspberry Piチェック（オプション）
check_hardware() {
    log_step "Checking hardware..."

    if [ -f /proc/device-tree/model ]; then
        model=$(cat /proc/device-tree/model 2>/dev/null || echo "Unknown")
        log_info "Detected: $model"

        if [[ ! "$model" =~ "Raspberry Pi" ]]; then
            log_warn "This script is optimized for Raspberry Pi"
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    fi
}

# USBデバイス選択
select_usb_device() {
    log_step "Detecting USB storage devices..."

    # ルートデバイスを特定
    root_device=$(findmnt -n -o SOURCE / | sed 's/p\?[0-9]*$//')
    log_info "Root device: $root_device (will be excluded)"

    # USB/外部ストレージデバイスをリスト
    echo ""
    echo "Available storage devices:"
    lsblk -dno NAME,SIZE,TYPE,VENDOR,MODEL | grep -E "disk" | nl
    echo ""

    while true; do
        read -p "Enter device name (e.g., sda) or full path (e.g., /dev/sda): " device_input

        # デバイスパスを正規化
        if [[ "$device_input" =~ ^/dev/ ]]; then
            USB_DEVICE="$device_input"
        else
            USB_DEVICE="/dev/$device_input"
        fi

        # デバイスが存在するかチェック
        if [ ! -b "$USB_DEVICE" ]; then
            log_error "Device $USB_DEVICE does not exist"
            continue
        fi

        # ルートデバイスでないかチェック
        if [[ "$USB_DEVICE" == "$root_device"* ]]; then
            log_error "Cannot use system disk $USB_DEVICE"
            continue
        fi

        break
    done

    log_warn "Selected device: $USB_DEVICE"
    log_warn "ALL DATA ON THIS DEVICE WILL BE ERASED!"

    # 二重確認
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_error "Aborted by user"
        exit 1
    fi

    # マウント状態を確認し、必要ならアンマウント
    log_info "Checking if device is mounted..."

    # デバイスの全パーティションをチェック
    local has_mounted=false
    while IFS= read -r line; do
        local dev_name=$(echo "$line" | awk '{print $1}')
        local mount_point=$(echo "$line" | awk '{print $2}')

        if [ -n "$mount_point" ]; then
            has_mounted=true

            # デバイスパスを構築（マッパーデバイスの場合は /dev/mapper/ を使用）
            local dev_path
            if [[ "$dev_name" == *"mapper/"* ]] || [[ "$dev_name" == "$LUKS_NAME" ]]; then
                dev_path="/dev/mapper/$(basename "$dev_name")"
            else
                dev_path="/dev/$dev_name"
            fi

            log_warn "Unmounting $dev_path from $mount_point"
            umount "$mount_point" 2>/dev/null || umount -l "$mount_point"
        fi
    done < <(lsblk -ln -o NAME,MOUNTPOINT "$USB_DEVICE" 2>/dev/null)

    if [ "$has_mounted" = true ]; then
        log_info "Unmounted all partitions"
    else
        log_info "No mounted partitions found"
    fi

    # LUKS暗号化デバイスがマウントされているかチェック
    if [ -e "/dev/mapper/$LUKS_NAME" ]; then
        log_warn "LUKS device $LUKS_NAME is already open"

        # マウントされているか確認
        if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
            log_warn "Unmounting $MOUNT_POINT"
            umount "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT"
        fi

        # LUKS デバイスをクローズ
        log_warn "Closing LUKS device $LUKS_NAME"
        cryptsetup close "$LUKS_NAME"
    fi

    log_info "Device is ready for encryption"
}

# 依存関係インストール
install_dependencies() {
    log_step "Installing dependencies..."

    apt-get update
    apt-get install -y \
        samba \
        rsyslog \
        python3 \
        python3-pip \
        cryptsetup \
        parted \
        util-linux \
        coreutils

    log_info "Dependencies installed successfully"
}

# LUKS暗号化設定
setup_encryption() {
    log_step "Setting up LUKS encryption..."

    # キーファイル生成
    log_info "Generating random keyfile..."
    dd if=/dev/urandom of="$KEYFILE" bs=4096 count=1
    chmod 600 "$KEYFILE"
    log_info "Keyfile created: $KEYFILE"

    # LUKS暗号化フォーマット
    log_warn "Formatting $USB_DEVICE with LUKS encryption..."
    log_warn "This will ERASE all data on the device!"
    echo ""
    read -p "Continue? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_error "Encryption cancelled by user"
        exit 1
    fi

    echo "YES" | cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 256 \
        --hash sha256 \
        --iter-time 2000 \
        "$USB_DEVICE" \
        "$KEYFILE"

    log_info "LUKS encryption initialized"

    # LUKS デバイスを開く
    log_info "Opening LUKS device..."
    cryptsetup open --key-file="$KEYFILE" "$USB_DEVICE" "$LUKS_NAME"

    # ext4ファイルシステム作成
    log_info "Creating ext4 filesystem..."
    mkfs.ext4 -F "/dev/mapper/$LUKS_NAME"

    log_info "Encryption setup complete"
}

# ストレージマウント設定
setup_storage() {
    log_step "Configuring storage mount..."

    # nasusersグループを先に作成（権限設定に必要）
    groupadd -f nasusers
    log_info "Created nasusers group"

    # マウントポイント作成（既存の古いファイルをクリーンアップ）
    mkdir -p "$MOUNT_POINT"

    # マウントされていないディレクトリ内の古いファイルを削除
    # （過去のテストやインストールで残ったゴーストファイルを除去）
    if [ "$(ls -A "$MOUNT_POINT" 2>/dev/null)" ]; then
        log_info "Cleaning up old files in unmounted mount point..."
        rm -rf "$MOUNT_POINT"/*
        rm -rf "$MOUNT_POINT"/.[!.]*  # 隠しファイルも削除（. と .. は除外）
    fi

    # マウントポイントを読み取り専用に設定（ゴーストファイル防止）
    # マウント後はマウントされたファイルシステムの権限が使われる
    chown root:root "$MOUNT_POINT"
    chmod 555 "$MOUNT_POINT"
    log_info "Mount point set to read-only (will be overridden after mount)"

    # UUIDを取得
    LUKS_UUID=$(cryptsetup luksUUID "$USB_DEVICE")
    FS_UUID=$(blkid -s UUID -o value "/dev/mapper/$LUKS_NAME")

    log_info "LUKS UUID: $LUKS_UUID"
    log_info "Filesystem UUID: $FS_UUID"

    # /etc/fstab設定
    # 既存のマウントポイントエントリを削除してから新しいUUIDで追加
    sed -i "\|$MOUNT_POINT|d" /etc/fstab
    echo "UUID=$FS_UUID $MOUNT_POINT ext4 defaults,nofail,x-systemd.requires=luks-open-nas.service,x-systemd.after=luks-open-nas.service 0 2" >> /etc/fstab
    log_info "Updated /etc/fstab with new UUID"

    # マウント
    mount "$MOUNT_POINT"

    # 権限設定（nasusersグループが存在することを確認済み）
    chown root:nasusers "$MOUNT_POINT"
    chmod 770 "$MOUNT_POINT"

    log_info "Storage mounted at $MOUNT_POINT with correct permissions"
}

# SMB share name configuration
setup_share_name() {
    log_step "Configuring SMB share name..."

    echo ""
    log_info "Configure SMB share name (default: secure_share)"
    log_info "Allowed characters: alphanumeric and underscore (_)"
    echo ""

    while true; do
        read -p "Enter share name (default: secure_share): " share_name_input
        share_name_input=${share_name_input:-secure_share}

        # Validation: alphanumeric and underscore only
        if [[ "$share_name_input" =~ ^[a-zA-Z0-9_]+$ ]]; then
            SHARE_NAME="$share_name_input"
            log_info "Share name: $SHARE_NAME"
            break
        else
            log_error "Invalid share name. Only alphanumeric characters and underscore (_) are allowed"
            echo ""
        fi
    done

    echo ""
}

# Samba設定
setup_samba() {
    log_step "Configuring Samba..."

    # nasusersグループは setup_storage() で既に作成済み

    # ユーザー作成
    echo ""
    read -p "Enter NAS username: " nas_user

    if id "$nas_user" &>/dev/null; then
        log_info "User $nas_user already exists"
        usermod -a -G nasusers "$nas_user"
    else
        useradd -m -G nasusers "$nas_user"
        log_info "User $nas_user created"
    fi

    # Sambaパスワード設定
    echo "Set Samba password for $nas_user:"
    smbpasswd -a "$nas_user"

    # Samba設定ファイルをバックアップ
    if [ -f /etc/samba/smb.conf ]; then
        cp /etc/samba/smb.conf /etc/samba/smb.conf.backup.$(date +%Y%m%d)
    fi

    # Samba設定をコピーして共有名を置換
    sed "s/\[secure_share\]/\[$SHARE_NAME\]/" "$SCRIPT_DIR/config/smb.conf.template" > /etc/samba/smb.conf
    log_info "Configured Samba with share name: $SHARE_NAME"

    # systemd override for Samba (file descriptor limit)
    mkdir -p /etc/systemd/system/smbd.service.d
    cat > /etc/systemd/system/smbd.service.d/override.conf <<EOF
[Service]
LimitNOFILE=16384
EOF

    # rsyslog設定（Samba監査ログ）
    cat > /etc/rsyslog.d/10-samba.conf <<EOF
# Samba audit logs
local5.* /var/log/samba/audit.log
EOF

    # ログディレクトリとファイル作成
    mkdir -p /var/log/samba
    touch /var/log/samba/audit.log
    chmod 644 /var/log/samba/audit.log

    # systemdサービス設定（マウント待機版を使用）
    # デフォルトのsmbd.serviceを無効化
    systemctl disable smbd 2>/dev/null || true
    systemctl stop smbd 2>/dev/null || true

    # マウント待機版のsmbd.serviceをインストール
    cp "$SCRIPT_DIR/systemd/smbd-wait-mount.service" /etc/systemd/system/smbd.service

    # ページキャッシュクリアサービスをインストール（アンマウント時のセキュリティ強化）
    cp "$SCRIPT_DIR/systemd/mnt-secure_nas-cleanup.service" /etc/systemd/system/
    log_info "Installed page cache cleanup service for unmount security"

    # サービス再起動
    systemctl daemon-reload
    systemctl restart rsyslog
    systemctl enable smbd
    systemctl enable mnt-secure_nas-cleanup.service
    # Note: smbd will be started after luks-open-nas.service is installed in setup_monitor()

    log_info "Samba configured successfully (with mount wait and cache cleanup)"
}

# 削除日数設定
setup_inactivity_period() {
    log_step "Configuring inactivity period..."

    echo ""
    log_info "データ自動削除までの非アクティブ期間を設定します"
    echo ""
    read -p "削除までの日数 (default: 30): " inactivity_days
    inactivity_days=${inactivity_days:-30}

    # 数値チェック
    if ! [[ "$inactivity_days" =~ ^[0-9]+$ ]]; then
        log_warn "無効な値です。デフォルト値30日を使用します"
        inactivity_days=30
    fi

    # 警告日の計算（削除日数に応じて調整）
    local warning_days_array=()

    if [ $inactivity_days -le 1 ]; then
        # 1日の場合: 警告なし（すぐに削除）
        warning_days_array=()
        log_warn "警告通知なし（削除期間が短すぎます）"
    elif [ $inactivity_days -eq 2 ]; then
        # 2日の場合: 1日目のみ
        warning_days_array=(1)
    elif [ $inactivity_days -eq 3 ]; then
        # 3日の場合: 1日目と2日目
        warning_days_array=(1 2)
    elif [ $inactivity_days -le 7 ]; then
        # 4-7日の場合: 中間点と最終日前
        local mid=$((inactivity_days / 2))
        local last=$((inactivity_days - 1))
        if [ $mid -eq $last ]; then
            warning_days_array=($mid)
        else
            warning_days_array=($mid $last)
        fi
    else
        # 8日以上: N-7, N-3, N-1
        warning_day_1=$((inactivity_days - 7))
        warning_day_2=$((inactivity_days - 3))
        warning_day_3=$((inactivity_days - 1))
        warning_days_array=($warning_day_1 $warning_day_2 $warning_day_3)
    fi

    # JSON配列形式に変換
    if [ ${#warning_days_array[@]} -eq 0 ]; then
        WARNING_DAYS="[]"
    else
        WARNING_DAYS="[$(IFS=, ; echo "${warning_days_array[*]}")]"
    fi

    log_info "削除までの期間: $inactivity_days 日"
    if [ ${#warning_days_array[@]} -gt 0 ]; then
        log_info "警告日: $(IFS='、' ; echo "${warning_days_array[*]}")日目"
    fi
    echo ""
}

# メール通知設定
setup_notification() {
    log_step "Configuring email notifications..."

    echo ""
    read -p "Enable email notifications? (y/N): " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Email notifications disabled"
        return 0
    fi

    # メール設定入力
    echo ""
    read -p "Recipient email address: " email_to
    read -p "Sender email address: " email_from
    read -p "SMTP server (default: smtp.gmail.com): " smtp_server
    smtp_server=${smtp_server:-smtp.gmail.com}
    read -p "SMTP port (default: 587): " smtp_port
    smtp_port=${smtp_port:-587}
    read -p "SMTP username: " smtp_user
    read -s -p "SMTP password (app-specific password for Gmail): " smtp_pass
    echo ""

    # 設定ファイルに保存（後で上書き）
    NOTIFICATION_CONFIG=$(cat <<EOF
"notification": {
    "enabled": true,
    "method": "email",
    "email": {
      "to": "$email_to",
      "from": "$email_from",
      "smtp_server": "$smtp_server",
      "smtp_port": $smtp_port,
      "username": "$smtp_user",
      "password": "$smtp_pass",
      "use_tls": true
    }
  }
EOF
)

    # テスト送信
    log_info "Testing email configuration..."
    python3 "$SCRIPT_DIR/src/notifier.py" \
        --to "$email_to" \
        --from "$email_from" \
        --smtp-server "$smtp_server" \
        --smtp-port "$smtp_port" \
        --username "$smtp_user" \
        --password "$smtp_pass" \
        --test-only

    if [ $? -eq 0 ]; then
        log_info "Email configuration test successful"
    else
        log_warn "Email configuration test failed"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            NOTIFICATION_CONFIG='  "notification": { "enabled": false }'
        fi
    fi
}

# 監視サービスセットアップ
setup_monitor() {
    log_step "Installing monitoring service..."

    # インストールディレクトリ作成
    mkdir -p "$INSTALL_DIR"

    # ソースファイルをコピー
    cp -r "$SCRIPT_DIR/src" "$INSTALL_DIR/"

    # 状態ディレクトリ作成
    mkdir -p /var/lib/nas-monitor

    # 設定ディレクトリ作成
    mkdir -p /etc/nas-monitor

    # 設定ファイル作成
    if [ -z "$NOTIFICATION_CONFIG" ]; then
        # 通知が無効の場合
        cat > /etc/nas-monitor/config.json <<EOF
{
  "mount_point": "$MOUNT_POINT",
  "device": "$USB_DEVICE",
  "keyfile": "$KEYFILE",
  "share_name": "$SHARE_NAME",
  "inactivity_days": ${inactivity_days:-30},
  "warning_days": ${WARNING_DAYS:-[23, 27, 29]},
  "state_file": "/var/lib/nas-monitor/last_access.json",
  "notification_state_file": "/var/lib/nas-monitor/notification_state.json",
  "reboot_after_wipe": true,
  "notification": {
    "enabled": false
  }
}
EOF
    else
        # 通知が有効の場合
        cat > /etc/nas-monitor/config.json <<EOF
{
  "mount_point": "$MOUNT_POINT",
  "device": "$USB_DEVICE",
  "keyfile": "$KEYFILE",
  "share_name": "$SHARE_NAME",
  "inactivity_days": ${inactivity_days:-30},
  "warning_days": ${WARNING_DAYS:-[23, 27, 29]},
  "state_file": "/var/lib/nas-monitor/last_access.json",
  "notification_state_file": "/var/lib/nas-monitor/notification_state.json",
  "reboot_after_wipe": true,
  $NOTIFICATION_CONFIG
}
EOF
    fi

    # 設定ファイルの権限を厳格に設定（SMTPパスワードが含まれる可能性があるため）
    chmod 600 /etc/nas-monitor/config.json
    chown root:root /etc/nas-monitor/config.json

    # JSON構文チェック
    log_info "Validating JSON configuration..."
    if python3 -c "import json; json.load(open('/etc/nas-monitor/config.json'))" 2>/dev/null; then
        log_info "✓ JSON configuration is valid"
    else
        log_error "JSON configuration validation failed!"
        log_error "The generated config.json has syntax errors"
        echo ""
        log_info "Configuration file content:"
        cat /etc/nas-monitor/config.json
        echo ""
        log_error "Please report this issue at https://github.com/anthropics/claude-code/issues"
        exit 1
    fi

    log_info "Configuration saved to /etc/nas-monitor/config.json (permissions: 600)"

    # udevルールをインストール（USBデバイス接続時に自動的にLUKS解除を開始）
    log_info "Installing udev rule for USB device auto-detection..."
    if [ -n "$LUKS_UUID" ]; then
        sed "s/__LUKS_UUID__/$LUKS_UUID/g" "$SCRIPT_DIR/udev/99-luks-usb.rules" > /etc/udev/rules.d/99-luks-usb.rules
        log_info "✓ udev rule installed with UUID: $LUKS_UUID"
        # udevルールをリロード
        udevadm control --reload-rules
        udevadm trigger
    else
        log_warn "LUKS UUID not set; skipping udev rule installation"
    fi

    # systemdサービスをインストール
    cp "$SCRIPT_DIR/systemd/nas-monitor.service" /etc/systemd/system/
    cp "$SCRIPT_DIR/systemd/luks-close-nas.service" /etc/systemd/system/
    if [ -n "$LUKS_UUID" ]; then
        sed "s/__LUKS_UUID__/$LUKS_UUID/g" "$SCRIPT_DIR/systemd/luks-open-nas.service" > /etc/systemd/system/luks-open-nas.service
    else
        log_warn "LUKS UUID not set; installing default luks-open-nas.service"
        cp "$SCRIPT_DIR/systemd/luks-open-nas.service" /etc/systemd/system/
    fi

    # systemd リロード
    systemctl daemon-reload

    # LUKS自動マウントサービスを有効化（udevからトリガーされる）
    log_info "Enabling LUKS auto-mount service (triggered by udev when USB is connected)..."
    systemctl enable luks-open-nas.service

    # 古い状態ファイルをクリーンアップ（既存インストールからの残存ファイルを削除）
    log_info "Cleaning up old state files from previous installations..."
    rm -f /var/lib/nas-monitor/last_access.json
    rm -f /var/lib/nas-monitor/notification_state.json

    # サービス有効化・起動
    systemctl enable nas-monitor
    systemctl start nas-monitor

    # Start Samba service (now that luks-open-nas.service is installed)
    log_info "Starting Samba service..."
    systemctl restart smbd

    log_info "Monitoring service installed and started"
}

# メイン実行
main() {
    echo ""
    echo "=========================================="
    echo "  Secret NAS Setup"
    echo "  Raspberry Pi"
    echo "=========================================="
    echo ""

    cleanup_existing_setup
    check_hardware
    select_usb_device
    install_dependencies
    setup_encryption
    setup_storage
    setup_share_name
    setup_samba
    setup_inactivity_period
    setup_notification
    setup_monitor

    echo ""
    echo "=========================================="
    echo "  Setup Complete!"
    echo "=========================================="
    echo ""
    log_info "NAS is accessible at:"
    log_info "  \\\\$(hostname)\\$SHARE_NAME"
    log_info "  smb://$(hostname).local/$SHARE_NAME"
    echo ""
    log_info "Monitor service status:"
    log_info "  systemctl status nas-monitor"
    echo ""
    log_warn "IMPORTANT: After ${inactivity_days:-30} days of inactivity, all data will be securely wiped!"
    if [ ! -z "$WARNING_DAYS" ] && [ "$WARNING_DAYS" != "[]" ]; then
        # JSON配列から警告日を抽出して表示
        warning_days_display=$(echo "$WARNING_DAYS" | tr -d '[]')
        log_warn "Warning emails will be sent on days: $warning_days_display"
    fi
    echo ""
}

main "$@"
