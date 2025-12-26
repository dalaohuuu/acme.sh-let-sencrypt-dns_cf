#!/bin/bash
set -e

REMOTE_NAME="onedrive"
HOST_ID="${HOSTNAME:-$(hostname)}"
HOST_ID_CLEAN=$(echo "$HOST_ID" | tr ' /' '__')

# =======================
# 3xui 备份
# =======================
backup_3xui() {
    # onedrive/vpsbackup/3xui/主机名字/
    local REMOTE_DIR="${REMOTE_NAME}:vpsbackup/3xui/${HOST_ID_CLEAN}"
    local TMP_DIR="/tmp/3xui_backup_${HOST_ID_CLEAN}"

    local DB_FILE="/etc/x-ui/x-ui.db"
    local CONF_FILE="/usr/local/x-ui/bin/config.json"
    local CERT_DIR="/root/cert"

    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR/cert"

    cp "$DB_FILE" "$TMP_DIR"/
    cp "$CONF_FILE" "$TMP_DIR"/

    if [ -d "$CERT_DIR" ]; then
        cp -a "${CERT_DIR}/." "$TMP_DIR/cert/"
    fi

    rclone sync "$TMP_DIR" "$REMOTE_DIR" --create-empty-src-dirs
    rm -rf "$TMP_DIR"
}

# =======================
# Docker Compose 应用备份
# =======================
# 用法：backup_compose_app <应用名> <compose目录>
backup_compose_app() {
    local APP_NAME="$1"
    local COMPOSE_DIR="$2"

    if [ -z "$APP_NAME" ] || [ -z "$COMPOSE_DIR" ]; then
        echo "用法：backup_compose_app <app_name> <compose_dir>"
        echo "示例：backup_compose_app sublinkpro /opt/sublinkpro"
        return 1
    fi

    if [ ! -d "$COMPOSE_DIR" ]; then
        echo "compose_dir 不存在：$COMPOSE_DIR"
        return 1
    fi

    # onedrive/vpsbackup/docker/容器应用名/
    local REMOTE_DIR="${REMOTE_NAME}:vpsbackup/docker/${APP_NAME}"
    local TMP_TAR="/tmp/${APP_NAME}_${HOST_ID_CLEAN}_compose_backup.tar.gz"

    # sublinkpro 使用 bind mount（./db ./template ./logs）
    # 打包整个 compose 目录即可完整迁移
    tar -czf "$TMP_TAR" -C "$COMPOSE_DIR" .

    rclone copy "$TMP_TAR" "$REMOTE_DIR" --create-empty-src-dirs
    rm -f "$TMP_TAR"
}

# =======================
# 主流程
# =======================
backup_3xui
backup_compose_app "sublinkpro" "/opt/sublinkpro"
