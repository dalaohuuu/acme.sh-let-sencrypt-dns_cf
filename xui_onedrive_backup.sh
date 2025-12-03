#!/bin/bash
set -e

########################################
# 参数：TG_BOT_TOKEN TG_CHAT_ID [HH.MM]
########################################
TG_BOT_TOKEN="${1:-$TG_BOT_TOKEN}"
TG_CHAT_ID="${2:-$TG_CHAT_ID}"
TIME_INPUT="$3"   # 用户输入样例：3.3 → 3 3 * * *

if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    echo "用法:"
    echo "  $0 <TG_BOT_TOKEN> <TG_CHAT_ID> [HH.MM]"
    echo
    echo "示例（只执行一次备份）:"
    echo "  $0 123456:ABCDEF 987654321"
    echo
    echo "示例（每天 03:03 自动备份）:"
    echo "  $0 123456:ABCDEF 987654321 3.3"
    exit 1
fi

notify() {
    local MESSAGE="$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d text="$(hostname) - ${MESSAGE}" >/dev/null
}

trap 'notify "⚠️ OneDrive 备份失败，请检查 VPS。"' ERR

########################################
# 如果用户输入了类似 3.3 的时间，则转换成 cron 表达式
########################################
CRON_SCHEDULE=""
if [ -n "$TIME_INPUT" ]; then
    # 校验格式：必须包含一个 "."
    if [[ "$TIME_INPUT" != *"."* ]]; then
        echo "时间格式错误！请输入 HH.MM 例如：3.3 表示 03:03"
        exit 1
    fi

    HOUR="${TIME_INPUT%%.*}"
    MIN="${TIME_INPUT##*.}"

    # 防止输入奇怪值
    if ! [[ "$HOUR" =~ ^[0-9]+$ ]] || ! [[ "$MIN" =~ ^[0-9]+$ ]]; then
        echo "时间格式错误，只能包含数字和一个 ."
        exit 1
    fi

    # 转换为 cron 格式：MIN HOUR * * *
    CRON_SCHEDULE="$MIN $HOUR * * *"
fi

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

cp "$DB_FILE" "$TMP_DIR"/
cp "$CONF_FILE" "$TMP_DIR"/

if [ -d "$CERT_DIR" ]; then
    cp -a "${CERT_DIR}/." "$TMP_DIR/cert/"
fi

rclone sync "$TMP_DIR" "$REMOTE_DIR" --create-empty-src-dirs

rm -rf "$TMP_DIR"

notify "✅ OneDrive 备份完成，备份文件存储于 /xui_backup/$HOST_ID/。"

########################################
# 写入 crontab（如果用户提供了 HH.MM）
########################################
if [ -n "$CRON_SCHEDULE" ]; then
    SCRIPT_PATH="$(readlink -f "$0")"

    # 把 token 和 chat_id 当参数传给脚本（不会再在前面加 TG_BOT_TOKEN=... 这种前缀）
    CRON_CMD="$SCRIPT_PATH $TG_BOT_TOKEN $TG_CHAT_ID"

    LOG_FILE="/var/log/xui_onedrive_backup.log"

    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" ; echo "$CRON_SCHEDULE $CRON_CMD >>$LOG_FILE 2>&1") | crontab -

    echo "定时任务已设置： $CRON_SCHEDULE"
    notify "⏰ 自动备份已启用：每天 $TIME_INPUT（cron: $CRON_SCHEDULE）"
fi
