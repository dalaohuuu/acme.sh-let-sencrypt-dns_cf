#!/usr/bin/env bash
# 用法：
#   sudo bash rclone_onedrive_backup.sh '<TOKEN_JSON>' '<DRIVE_ID>' 'HH:MM'

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "❌ 请使用 sudo"
  exit 1
fi

if [[ $# -ne 3 ]]; then
  echo "用法：sudo bash $0 '<TOKEN_JSON>' '<DRIVE_ID>' '03:03'"
  exit 1
fi

TOKEN_JSON="$1"
DRIVE_ID="$2"
BACKUP_TIME="$3"

REMOTE="onedrive"
CONF_DIR="/root/.config/rclone"
CONF_FILE="${CONF_DIR}/rclone.conf"
BACKUP_SCRIPT="/usr/local/bin/vps_rclone_backup.sh"
LOG_FILE="/var/log/vps_rclone_backup.log"

mkdir -p "$CONF_DIR"

#############################################
# 安装 rclone
#############################################
if ! command -v rclone >/dev/null 2>&1; then
  apt update && apt install -y rclone
fi

#############################################
# 写入 rclone 配置
#############################################
cat > "$CONF_FILE" <<EOF
[$REMOTE]
type = onedrive
token = ${TOKEN_JSON}
drive_type = personal
drive_id = ${DRIVE_ID}
EOF

chmod 600 "$CONF_FILE"
export RCLONE_CONFIG="$CONF_FILE"

#############################################
# 创建真正执行备份的脚本
#############################################
cat > "$BACKUP_SCRIPT" <<"EOF"
#!/usr/bin/env bash
set -euo pipefail

REMOTE="onedrive"
HOST="$(hostname)"
DEST="${REMOTE}:/vps_backup目录/${HOST}/"

echo "==> 正在同步备份到 $DEST"

# 1. nginx
rclone sync /etc/nginx "${DEST}nginx" --create-empty-src-dirs

# 2. fail2ban
rclone sync /etc/fail2ban "${DEST}fail2ban" --create-empty-src-dirs

# 3. 3x-ui
rclone copy /etc/x-ui/x-ui.db "${DEST}xui/x-ui.db" --create-empty-src-dirs
rclone copy /usr/local/x-ui/bin/config.json "${DEST}xui/config.json" --create-empty-src-dirs

# 4. SSL 证书：整目录备份
if [[ -d "/root/cert" ]]; then
  rclone sync /root/cert "${DEST}root_cert" --create-empty-src-dirs
else
  echo "⚠️ 未找到 /root/cert，跳过证书备份"
fi

echo "✅ 同步备份完成！"
EOF

chmod +x "$BACKUP_SCRIPT"

#############################################
# 写入 cron
#############################################
sed -i "/vps_rclone_backup.sh/d
