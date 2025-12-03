#!/bin/bash
set -e

########################################
# Telegram 配置：参数优先，其次环境变量
########################################
TG_BOT_TOKEN="${1:-$TG_BOT_TOKEN}"
TG_CHAT_ID="${2:-$TG_CHAT_ID}"

if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    echo "用法:"
    echo "  $0 <TG_BOT_TOKEN> <TG_CHAT_ID>"
    echo "或:"
    echo "  TG_BOT_TOKEN=xxx TG_CHAT_ID=yyy $0"
    exit 1
fi

notify() {
    local MESSAGE="$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d text="$(hostname) - ${MESSAGE}" >/dev/null
}

# 失败时通知
trap 'notify "⚠️ OneDrive 备份失败，请检查 VPS。"' ERR

########################################
# 备份配置
########################################
REMOTE_NAME="onedrive"
REMOTE_BASE_DIR="xui_backup"

HOST_ID="${HOSTNAME:-$(hostname)}"
HOST_ID_CLEAN=$(echo "$HOST_ID" | tr ' /' '__')
REMOTE_DIR="${REMOTE_NAME}:${REMOTE_BASE_DIR}/${HOST_ID_CLEAN}"
TMP_DIR="/tmp/xui_backup_${HOST_ID_CLEAN}"

DB_FILE="/etc/x-ui/x-ui.db"
CONF_FILE="/usr/local/x-ui/bin/config.json"
CERT_DIR="/root/cert"

########################################
# 执行备份
########################################
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
mkdir -p "$TMP_DIR/cert"

# 拷贝核心文件
cp "$DB_FILE" "$TMP_DIR"/
cp "$CONF_FILE" "$TMP_DIR"/

# 拷贝证书目录（如果存在）
if [ -d "$CERT_DIR" ]; then
    cp -a "${CERT_DIR}/." "$TMP_DIR/cert/"
fi

# 同步到 OneDrive
rclone sync "$TMP_DIR" "$REMOTE_DIR" --create-empty-src-dirs

# 清理临时目录
rm -rf "$TMP_DIR"

notify "✅ OneDrive 备份完成，备份文件存储于 /xui_backup/$HOST_ID/。"
