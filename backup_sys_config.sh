#!/bin/bash
# ==============================================================================
# 脚本名称: backup_sys_config.sh
# 描述: 支持 GitHub 远程一键执行 - 打包核心环境配置并上传至坚果云
# ==============================================================================

set -euo pipefail

# 核心配置
BACKUP_DIR="/home/docker/vaultwarden/cli"
REMOTE="jianguoyun:vaultwarden"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
DATE=$(date +%F)

# 确保本地备份目录存在（防止重装系统后因目录不存在而报错）
mkdir -p "$BACKUP_DIR"

echo "=== ⏳ 开始打包系统核心配置文件 ==="
CONFIG_BACKUP_FILE="system-config-snapshot-$DATE.tar.gz"
CONFIG_LOCAL_PATH="$BACKUP_DIR/$CONFIG_BACKUP_FILE"

# 1. 临时导出当前用户的 crontab 任务
crontab -l > "$BACKUP_DIR/crontab.cron" 2>/dev/null || echo "# No crontab data" > "$BACKUP_DIR/crontab.cron"

# 2. 安全打包：动态检查文件是否存在，避免 tar 报错
TAR_LIST=()

# 自动检测并加入存在的核心文件（已加入 run_daily_backup.sh）
for file in ".env" "crontab.cron" "vaultwarden-backup.sh" "run_daily_backup.sh" "backup_sys_config.sh"; do
    if [ -f "$BACKUP_DIR/$file" ]; then
        TAR_LIST+=("$file")
    fi
done

# 执行打包命令（仅打包存在的文件，并同时安全带上 rclone.conf）
tar -czf "$CONFIG_LOCAL_PATH" \
    -C "$BACKUP_DIR" "${TAR_LIST[@]}" \
    -C "$(dirname "$RCLONE_CONFIG")" "$(basename "$RCLONE_CONFIG")"

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

echo "🎉 [恭喜] 系统环境快照已成功上传！"
