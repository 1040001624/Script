#!/bin/bash
# ==============================================================================
# 脚本名称: backup_sys_config.sh
# 描述: 手动执行 - 打包核心环境配置（.env / cron / rclone）并上传至坚果云
# ==============================================================================

set -euo pipefail

# 核心配置
BACKUP_DIR="/home/docker/vaultwarden/cli"
REMOTE="jianguoyun:vaultwarden"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
DATE=$(date +%F)

echo "=== ⏳ 开始打包系统核心配置文件 ==="
CONFIG_BACKUP_FILE="system-config-snapshot-$DATE.tar.gz"
CONFIG_LOCAL_PATH="$BACKUP_DIR/$CONFIG_BACKUP_FILE"

# 1. 临时导出当前用户的 crontab 任务
crontab -l > "$BACKUP_DIR/crontab.cron" 2>/dev/null || echo "# No crontab data" > "$BACKUP_DIR/crontab.cron"

# 2. 将所有配置文件安全打包
# 包含：.env, crontab.cron, 两个备份脚本自身, 以及 rclone.conf
tar -czf "$CONFIG_LOCAL_PATH" \
    -C "$BACKUP_DIR" .env crontab.cron vaultwarden-backup.sh $(basename "$0") \
    -C "$(dirname "$RCLONE_CONFIG")" $(basename "$RCLONE_CONFIG")

# 3. 清理临时文件
rm -f "$BACKUP_DIR/crontab.cron"
echo "✅ 1. 本地打包成功: $CONFIG_LOCAL_PATH"

# 4. 上传至坚果云
echo "=== ⏳ 正在通过 rclone 上传至坚果云 ==="
if ! command -v rclone &> /dev/null; then
    echo "❌ 错误: 未检测到 rclone 命令"
    exit 1
fi

rclone copy "$CONFIG_LOCAL_PATH" "$REMOTE" --config "$RCLONE_CONFIG"
echo "✅ 2. 云端同步成功！已安全存储至坚果云 ($REMOTE)"

# 5. 清理本地打包文件，保持宿主机干净
rm -f "$CONFIG_LOCAL_PATH"

echo "🎉 [恭喜] 系统环境快照已成功上传！下次重装系统可直接使用此备份一键还原。"
