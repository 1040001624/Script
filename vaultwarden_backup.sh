#!/bin/bash

# ================= 自我保存持久化逻辑 =================
LOCAL_SCRIPT_PATH="/root/vaultwarden_backup.sh"

# 检测是否为首次远程运行，自动保存到本地
if [ "${BASH_SOURCE[0]:-$0}" != "$LOCAL_SCRIPT_PATH" ]; then
    echo "检测到远程/首次运行，正在将脚本自动保存到本地: $LOCAL_SCRIPT_PATH ..."
    cat "$0" > "$LOCAL_SCRIPT_PATH"
    chmod +x "$LOCAL_SCRIPT_PATH"
    echo "保存成功！之后您可以通过命令: bash $LOCAL_SCRIPT_PATH 随时运行。"
fi
# ===================================================

# Vaultwarden 自动安全备份脚本
set -Eeuo pipefail

CONTAINER="vaultwarden"
DATA_DIR="/home/docker/vaultwarden/data"
BACKUP_DIR="/home/docker/vaultwarden/backup"
REMOTE="jianguoyun:vaultwarden"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"

DATE=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_FILE="vaultwarden_${DATE}.tar.gz"
CONTAINER_STOPPED_BY_SCRIPT=false

echo "=============================="
echo "开始 Vaultwarden 备份: ${DATE}"
echo "=============================="

# 异常退出与正常退出的安全恢复钩子
cleanup() {
    if [ "$CONTAINER_STOPPED_BY_SCRIPT" = true ]; then
        echo "正在重新启动 Vaultwarden..."
        docker start "$CONTAINER" >/dev/null 2>&1 || echo "警告: 容器启动失败，请手动检查。"
    fi
}
trap cleanup EXIT

# 1. 停止容器逻辑
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "停止 Vaultwarden 容器..."
    docker stop "$CONTAINER" >/dev/null
    CONTAINER_STOPPED_BY_SCRIPT=true
else
    echo "Vaultwarden 容器当前未运行，跳过停止步骤。"
fi

# 2. 创建本地备份
mkdir -p "$BACKUP_DIR"
echo "正在打包数据..."
tar -czf "$BACKUP_DIR/$BACKUP_FILE" -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")"

# 3. 安全删除本地旧备份（保留最新的3个）
echo "清理本地旧备份，只保留3份..."
find "$BACKUP_DIR" -maxdepth 1 -type f -name "vaultwarden_*.tar.gz" -printf '%T@ %p\n' | sort -rn | tail -n +4 | cut -d' ' -f2- | xargs -I {} rm -f "{}"

# 4. 上传至坚果云
echo "上传至坚果云..."
rclone copy "$BACKUP_DIR/$BACKUP_FILE" "$REMOTE" --config "$RCLONE_CONFIG"

# 5. 安全清理坚果云旧备份（保留最新的7份）
echo "清理坚果云旧备份，只保留7份..."
CLOUD_FILES_RAW=$(rclone lsjson "$REMOTE" --files-only --config "$RCLONE_CONFIG" | jq -r '.[] | "\(.ModTime)#\(.Path)"' 2>/dev/null | sort -r || rclone lsf "$REMOTE" --files-only --format "tp" --config "$RCLONE_CONFIG" | sed -E 's/^([0-9: -]+)[[:space:]]+(.*)$/\1#\2/' | sort -r)
COUNT=$(echo "$CLOUD_FILES_RAW" | grep -v '^$' | wc -l || echo 0)

if [ "$COUNT" -gt 7 ]; then
    echo "$CLOUD_FILES_RAW" | tail -n +8 | cut -d'#' -f2- | while read -r file; do
        [ -z "$file" ] && continue
        echo "正在删除云端旧备份: $file"
        rclone deletefile "$REMOTE/$file" --config "$RCLONE_CONFIG"
    done
else
    echo "云端备份数量 ($COUNT) 未超过7份，无需清理。"
fi

echo "=============================="
echo "备份成功完成"
echo "=============================="
