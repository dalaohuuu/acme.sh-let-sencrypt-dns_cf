#!/usr/bin/env bash
# 完全自动安装 rclone + 配置 OneDrive + 每日自动备份
# 用法：
#   sudo bash setup_rclone_onedrive_backup.sh '<TOKEN_JSON>' 'HH:MM'

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "请使用 sudo 运行"
  exit 1
fi

if [[ $# -ne 2 ]]; then
  echo "用法: sudo bash $0 '<TOKEN_JSON>' '03:30'"
  exit 1
fi

TOKEN_JSON="$1"
BACKUP_TIME="$2"

if [[ ! "$BACKUP_TIME" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
  echo "时间格式错误，应为 HH:MM"
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
# 写入 rclone 配置（强制覆盖）
##############################

cat > "$CONF_FILE" <<EOF
[$REMOTE_NAME]
type = onedrive
token = $TOKEN_JSON
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

# 备份内容
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
  echo "无可备份文件，退出"
  exit 1
fi

tar -czf "${TMP}/${ARCHIVE}" "${EXIST[@]}"

rclone copy "${TMP}/${ARCHIVE}" "$REMOTE_DIR" --create-empty-src-dirs

rm -rf "$TMP"
echo "备份完成：$ARCHIVE"
EOF

chmod +x "$BACKUP_SCRIPT"

##############################
# 写入 cron（覆盖旧项）
##############################

touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

sed -i "/vps_rclone_backup.sh/d" /etc/crontab

echo "${CRON_M} ${CRON_H} * * * root ${BACKUP_SCRIPT} >> ${LOG_FILE} 2>&1" >> /etc/crontab

echo "部署完成！可执行手动备份："
echo "  sudo $BACKUP_SCRIPT"
