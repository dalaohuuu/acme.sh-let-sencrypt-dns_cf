#!/usr/bin/env bash
# 安装 rclone + 配置 OneDrive + 每日定时备份
# 适用系统：Ubuntu / Debian 系列
# 使用方法：
#   sudo bash setup_rclone_onedrive_backup.sh '<RCLONE_ONEDRIVE_TOKEN_JSON>' 'HH:MM'
#
# 示例：
#   sudo bash setup_rclone_onedrive_backup.sh '{"access_token":"xxx","expiry":"2025-01-01T00:00:00Z"}' '03:30'
#
# 注意：
#   1. 请用单引号包住 JSON token，避免被 shell 解释。
#   2. 备份目录：onedrive:/vps_backup目录/$(hostname)/

set -euo pipefail

########################
# 参数 & 基本检查
########################

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行本脚本：sudo bash $0 ..."
  exit 1
fi

if [[ $# -ne 2 ]]; then
  echo "用法：sudo bash $0 '<RCLONE_ONEDRIVE_TOKEN_JSON>' 'HH:MM'"
  exit 1
fi

RCLONE_TOKEN="$1"
BACKUP_TIME="$2"  # 例如 03:30

if [[ ! "$BACKUP_TIME" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
  echo "备份时间格式错误，应为 HH:MM (24小时制)，例如 03:30"
  exit 1
fi

CRON_HOUR="${BACKUP_TIME%:*}"
CRON_MIN="${BACKUP_TIME#*:}"

RCLONE_REMOTE_NAME="onedrive"
BACKUP_SCRIPT_PATH="/usr/local/bin/vps_rclone_backup.sh"
LOG_FILE="/var/log/vps_rclone_backup.log"

########################
# 安装 rclone
########################

echo "==> 安装 rclone（如果尚未安装）..."

if ! command -v rclone >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y rclone
  else
    echo "找不到 apt-get，请根据你的系统手动安装 rclone 后再运行本脚本。"
    exit 1
  fi
else
  echo "rclone 已安装，跳过安装步骤。"
fi

########################
# 配置 rclone OneDrive 远程
########################

echo "==> 配置 rclone OneDrive 远程：$RCLONE_REMOTE_NAME"

RCLONE_CONFIG_DIR="/root/.config/rclone"
RCLONE_CONFIG_FILE="$RCLONE_CONFIG_DIR/rclone.conf"
mkdir -p "$RCLONE_CONFIG_DIR"

export RCLONE_CONFIG="$RCLONE_CONFIG_FILE"

# 检查是否已存在同名 remote
if rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE_NAME}:"; then
  echo "rclone 远程 ${RCLONE_REMOTE_NAME} 已存在，将覆盖其 token。"

  # 简单做法：删除旧的该远程配置，由 rclone 再创建
  # 更精细的做法是用 sed 编辑，这里为了简单直接删除重建
  tmp_conf="${RCLONE_CONFIG_FILE}.tmp"
  touch "$tmp_conf"
  if [[ -f "$RCLONE_CONFIG_FILE" ]]; then
    awk -v name="$RCLONE_REMOTE_NAME" '
      BEGIN{skip=0}
      /^\[.*\]$/ {
        # 检查是否新小节
        if ($0 == "[" name "]") {
          skip=1
          next
        } else {
          skip=0
        }
      }
      skip==0 {print}
    ' "$RCLONE_CONFIG_FILE" > "$tmp_conf"
    mv "$tmp_conf" "$RCLONE_CONFIG_FILE"
  fi
fi

# 使用非交互方式创建 onedrive 远程
# 注意：这里只使用 token，drive_id / drive_type 让 rclone 自动发现
rclone config create "$RCLONE_REMOTE_NAME" onedrive token="$RCLONE_TOKEN" --non-interactive

echo "rclone 远程 ${RCLONE_REMOTE_NAME} 配置完成。"

########################
# 创建备份脚本
########################

echo "==> 创建备份脚本：$BACKUP_SCRIPT_PATH"

cat > "$BACKUP_SCRIPT_PATH" <<"EOF"
#!/usr/bin/env bash
# 使用 rclone 将关键配置打包并上传到 OneDrive
set -euo pipefail

RCLONE_REMOTE_NAME="onedrive"
HOSTNAME="$(hostname)"
REMOTE_DIR="${RCLONE_REMOTE_NAME}:/vps_backup目录/${HOSTNAME}/"

TIMESTAMP="$(date +%F_%H-%M-%S)"
TMP_DIR="/tmp/vps_backup_${TIMESTAMP}"
ARCHIVE_NAME="${HOSTNAME}_${TIMESTAMP}.tar.gz"
ARCHIVE_PATH="${TMP_DIR}/${ARCHIVE_NAME}"

mkdir -p "$TMP_DIR"

echo "==> 开始打包备份：$ARCHIVE_PATH"

# 需要备份的文件/目录
TO_BACKUP=(
  "/etc/nginx"
  "/etc/fail2ban"
  "/etc/x-ui/x-ui.db"
  "/usr/local/x-ui/bin/config.json"
)

# 检测存在的路径，防止 tar 因为空而报错
EXISTING=()
for p in "${TO_BACKUP[@]}"; do
  if [[ -e "$p" ]]; then
    EXISTING+=("$p")
  else
    echo "警告：路径不存在，跳过：$p"
  fi
done

if [[ ${#EXISTING[@]} -eq 0 ]]; then
  echo "错误：没有任何需要备份的文件/目录存在，退出。"
  exit 1
fi

# 打包
tar -czf "$ARCHIVE_PATH" --ignore-failed-read "${EXISTING[@]}"

echo "==> 打包完成，上传到 OneDrive：$REMOTE_DIR"

# 上传到 OneDrive
rclone copy "$ARCHIVE_PATH" "$REMOTE_DIR" --create-empty-src-dirs

echo "==> 上传完成：$ARCHIVE_NAME"

# 清理临时目录
rm -rf "$TMP_DIR"

echo "==> 备份完成。"
EOF

chmod +x "$BACKUP_SCRIPT_PATH"

########################
# 配置 cron 定时任务
########################

echo "==> 配置每日定时任务（cron）：每天 ${BACKUP_TIME} 执行备份"

# 确保日志文件存在
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

CRON_LINE="${CRON_MIN} ${CRON_HOUR} * * * root ${BACKUP_SCRIPT_PATH} >> ${LOG_FILE} 2>&1"

# 防止重复添加：先删掉旧的同类行，再追加
if [[ -f /etc/crontab ]]; then
  tmp_cron="/tmp/crontab_system.tmp"
  grep -v "vps_rclone_backup.sh" /etc/crontab > "$tmp_cron" || true
  mv "$tmp_cron" /etc/crontab
fi

echo "$CRON_LINE" >> /etc/crontab

echo "==> 配置完成！"
echo "日志文件：$LOG_FILE"
echo "你可以手动测试备份：sudo $BACKUP_SCRIPT_PATH"
