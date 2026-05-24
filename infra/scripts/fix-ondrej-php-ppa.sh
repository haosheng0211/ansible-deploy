#!/usr/bin/env bash
# =============================================================================
# fix-ondrej-php-ppa.sh
#
# 修復 Ubuntu 20.04 上 ondrej/php PPA 簽章驗證問題。
# Apt 2.x 在某些情況下不認 apt-key adv 加進去的金鑰（即使顯示 imported），
# 導致 InRelease 抓得到但 Packages 不下載，apt-cache 找不到 php8.2-fpm。
#
# 解法：把 key 轉成獨立 keyring 檔放在 /etc/apt/keyrings/，
# 並在 sources.list.d 的 list 檔用 signed-by 顯式綁定。
#
# 使用：以 root 執行
#   bash infra/scripts/fix-ondrej-php-ppa.sh
# =============================================================================

set -euo pipefail

ONDREJ_KEY_ID="4F4EA0AAE5267A6C"
KEYRING="/etc/apt/keyrings/ondrej-php.gpg"
LIST_FILE="/etc/apt/sources.list.d/ppa_ondrej_php_focal.list"
TMP_KEYRING="/tmp/ondrej-import.gpg"

if [[ "$EUID" -ne 0 ]]; then
    echo "✗ 請以 root 執行（或 sudo bash $0）"
    exit 1
fi

echo ">>> 1. 確認 gnupg / ca-certificates"
apt-get install -y gnupg ca-certificates >/dev/null

echo ">>> 2. 從 keyserver 抓 ondrej PPA signing key（$ONDREJ_KEY_ID）"
rm -f "$TMP_KEYRING" "${TMP_KEYRING}~"
gpg --no-default-keyring \
    --keyring "$TMP_KEYRING" \
    --keyserver keyserver.ubuntu.com \
    --recv-keys "$ONDREJ_KEY_ID"

echo ">>> 3. 匯出成 dearmored keyring → $KEYRING"
mkdir -p /etc/apt/keyrings
gpg --no-default-keyring \
    --keyring "$TMP_KEYRING" \
    --export "$ONDREJ_KEY_ID" \
  | gpg --dearmor > "$KEYRING"
rm -f "$TMP_KEYRING" "${TMP_KEYRING}~"
ls -la "$KEYRING"

echo ">>> 4. 改寫 list 檔（顯式 signed-by）→ $LIST_FILE"
cat > "$LIST_FILE" <<EOF
deb [signed-by=$KEYRING] http://ppa.launchpad.net/ondrej/php/ubuntu focal main
EOF
cat "$LIST_FILE"

echo ">>> 5. 清舊 apt 快取並重抓 metadata"
rm -rf /var/lib/apt/lists/ppa.launchpad.net_ondrej*
apt-get update

echo ">>> 6. 驗證 php8.2-fpm 可用"
if apt-cache policy php8.2-fpm 2>/dev/null | grep -qE "Candidate: [0-9]"; then
    echo "✓ php8.2-fpm 可安裝"
    apt-cache policy php8.2-fpm
    echo
    echo "============================================================"
    echo "完成。現在可重跑 playbook："
    echo "  cd /root/ansible-deploy/infra"
    echo "  ansible-playbook playbooks/setup-server.yml -i inventory/local.ini"
    echo "============================================================"
else
    echo "✗ 仍然找不到 php8.2-fpm，貼以下輸出回來再判斷："
    echo "---"
    apt-cache policy php8.2-fpm || true
    echo "---"
    ls /var/lib/apt/lists/ | grep ondrej || echo "(沒有 ondrej 相關 list 檔)"
    exit 1
fi
