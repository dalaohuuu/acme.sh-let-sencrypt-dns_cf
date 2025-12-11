#!/usr/bin/env bash
# 用法：
#   sudo bash rclone_onedrive_backup.sh '<TOKEN_JSON>' '<DRIVE_ID>' 'HH:MM'

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "❌ 请使用 sudo 运行本脚本"
  exit 1
fi

if [[ $# -ne 3 ]]; then
  echo "用法：sudo bash $0 '<TOKEN_JSON>' '<DRIVE_ID>' '03:30'"
  exit 1
fi

TOKEN_JSON="$1"
DRIVE_ID="$2"
BACKUP_TIME="$3"

# 时间检查
if [[ ! "$BACKUP_TIME" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
  echo "❌ 时间格式错误，应为 HH:MM 例如 03:30"
  exit 1
fi

CRON_H="${BACKUP_TIME%:*}"
CRON_M="${BACKUP_TIME#*:}"

REMOTE_NAME="onedrive"
CONF_DIR="/root/.config/rclone"
CONF_FILE="$CONF_DIR/rclone.conf"
BACKUP_SCRIPT="/usr/local/bin/vps_rclone_backup.sh"
LOG_FILE="/var/log/vps_rclone_backup.log"

mkdir -p "$CONF_DIR"

##############################
# 安装 rclone
##############################
if ! command -v rclone >/dev/null 2>&1; then
  apt update && apt install -y rclone
fi

##############################
# 写入 rclone 配置（使用 drive_type & drive_id）
##############################

cat > "$CONF_FILE" <<EOF
[$REMOTE_NAME]
type = onedrive
token = $TOKEN_JSON
drive_type = personal
drive_id = $DRIVE_ID
EOF

chmod 600 "$CONF_FILE"
export RCLONE_CONFIG="$CONF_FILE"

##############################
# 创建备份脚本
##############################

cat > "$BACKUP_SCRIPT" <<"EOF"
#!/usr/bin/env bash
set -euo pipefail

REMOTE="onedrive"
HOST="$(hostname)"
REMOTE_DIR="${REMOTE}:/vps_backup目录/${HOST}/"

TS="$(date +%F_%H-%M-%S)"
TMP="/tmp/vps_backup_${TS}"
ARCHIVE="${HOST}_${TS}.tar.gz"

mkdir -p "$TMP"

FILES=(
  "/etc/nginx"
  "/etc/fail2ban"
  "/etc/x-ui/x-ui.db"
  "/usr/local/x-ui/bin/config.json"
)

EXIST=()
for f in "${FILES[@]}"; do
  [[ -e "$f" ]] && EXIST+=("$f")
done

if [[ ${#EXIST[@]} -eq 0 ]]; then
  echo "❌ 无可备份文件"
  exit 1
fi

tar -czf "${TMP}/${ARCHIVE}" "${EXIST[@]}"

rclone copy "${TMP}/${ARCHIVE}" "$REMOTE_DIR" --create-empty-src-dirs

rm -rf "$TMP"
echo "✅ 备份完成：$ARCHIVE"
EOF

chmod +x "$BACKUP_SCRIPT"

##############################
# 写入 cron
##############################

touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

# 删除旧的 cron
sed -i "/vps_rclone_backup.sh/d" /etc/crontab

# 添加新任务
echo "${CRON_M} ${CRON_H} * * * root ${BACKUP_SCRIPT} >> ${LOG_FILE} 2>&1" >> /etc/crontab

echo "🎉 完成部署！"
echo "手动测试备份：sudo $BACKUP_SCRIPT"
