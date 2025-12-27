#!/bin/bash
#
# Docker環境でSecret NASをテストするスクリプト
#

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

echo ""
echo "=========================================="
echo "  Secret NAS Docker テスト環境"
echo "=========================================="
echo ""

# Docker確認
if ! command -v docker &> /dev/null; then
    echo "Error: Docker がインストールされていません"
    echo "https://www.docker.com/get-started からインストールしてください"
    exit 1
fi

if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null 2>&1; then
    echo "Error: Docker Compose がインストールされていません"
    exit 1
fi

# テストストレージディレクトリ作成
mkdir -p test-storage

log_step "1. Dockerイメージをビルド..."
docker-compose build

log_step "2. コンテナを起動..."
docker-compose up -d

log_step "3. コンテナが起動するまで待機..."
sleep 5

log_step "4. コンテナに接続..."
echo ""
log_info "以下のコマンドでコンテナに入れます:"
echo ""
echo -e "  ${YELLOW}docker-compose exec secret-nas bash${NC}"
echo ""
log_info "コンテナ内でセットアップを実行:"
echo ""
echo -e "  ${YELLOW}cd /home/pi/secret_nas${NC}"
echo -e "  ${YELLOW}sudo ./setup.sh${NC}"
echo ""
log_info "または、以下のコマンドで直接テスト:"
echo ""
echo -e "  ${YELLOW}docker-compose exec secret-nas bash -c 'cd /home/pi/secret_nas && sudo ./scripts/quick-test.sh'${NC}"
echo ""
log_info "コンテナを停止:"
echo ""
echo -e "  ${YELLOW}docker-compose down${NC}"
echo ""
log_info "Sambaへのアクセス（ホストから）:"
echo ""
echo -e "  Windows: ${YELLOW}\\\\localhost\\secure_share${NC}"
echo -e "  Mac/Linux: ${YELLOW}smb://localhost/secure_share${NC}"
echo ""
