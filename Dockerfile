# Secret NAS テスト用Dockerfile
# Debian-based環境でRaspberry Pi OS相当の環境を構築

FROM debian:bookworm

# 基本パッケージのインストール
RUN apt-get update && apt-get install -y \
    sudo \
    systemd \
    samba \
    rsyslog \
    python3 \
    python3-pip \
    cryptsetup \
    parted \
    util-linux \
    coreutils \
    lsb-release \
    procps \
    && rm -rf /var/lib/apt/lists/*

# テスト用ユーザー作成
RUN useradd -m -s /bin/bash pi && \
    echo "pi:raspberry" | chpasswd && \
    usermod -aG sudo pi && \
    echo "pi ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# 作業ディレクトリ
WORKDIR /home/pi

# プロジェクトファイルをコピー
COPY --chown=pi:pi . /home/pi/secret_nas/

# systemd用の設定
ENV container=docker
STOPSIGNAL SIGRTMIN+3

# systemdを起動
CMD ["/lib/systemd/systemd"]
