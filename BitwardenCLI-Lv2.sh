#!/bin/bash

# ==============================================================================
# 脚本名称: vaultwarden-backup.sh
# 描述: Vaultwarden 凭据自动化备份 (本地留 3 份，坚果云通过 rclone 留 7 份)
# ==============================================================================

set -euo pipefail

# ----------------- 1. 核心生产配置 -----------------
CONTAINER="vaultwarden"
VAULT_URL="${VAULT_URL:-https://b.920109.xyz}"
BACKUP_DIR="/home/docker/vaultwarden/cli"
REMOTE="jianguoyun:vaultwarden"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
DATE=$(date +%F)

mkdir -p "$BACKUP_DIR"

# ----------------- 2. 环境依赖检查 -----------------
# 检查宿主机 rclone
if ! command -v rclone &> /dev/null; then
    echo "❌ 错误: 宿主机未检测到 rclone，请先安装并在 $RCLONE_CONFIG 配置好坚果云"
    exit 1
fi

# 检查宿主机是否有 rclone 配置文件
if [ ! -f "$RCLONE_CONFIG" ]; then
    echo "❌ 错误: 未在指定路径找到 rclone 配置文件: $RCLONE_CONFIG"
    exit 1
fi

# 检查 Bitwarden CLI (优先使用宿主机，若无则自动下载官方最新独立版)
if ! command -v bw &> /dev/null; then
    echo "=== 宿主机 Bitwarden CLI 未安装，正在通过官方二进制方式安装... ==="
    sudo apt update && sudo apt install -y unzip curl
    
    # 创建临时目录下载并解压
    TMP_DIR=$(mktemp -d)
    curl -Lso "$TMP_DIR/bw-linux.zip" "https://vault.bitwarden.com/download/?app=cli&platform=linux"
    unzip -q "$TMP_DIR/bw-linux.zip" -d "$TMP_DIR"
    chmod +x "$TMP_DIR/bw"
    sudo mv "$TMP_DIR/bw" /usr/local/bin/
    rm -rf "$TMP_DIR"
    
    echo "✅ Bitwarden CLI 安装成功，当前版本: $(bw --version)"
fi

# ----------------- 3. 配置服务器地址与登录 -----------------
echo "=== 正在检查并重置登录状态 ==="
bw logout || true
bw config server "$VAULT_URL"

if [ -z "${BW_CLIENTID:-}" ] || [ -z "${BW_CLIENTSECRET:-}" ] || [ -z "${BW_PASSWORD:-}" ]; then
    echo "❌ 错误: 请先设置环境变量 BW_CLIENTID, BW_CLIENTSECRET 和 BW_PASSWORD"
    exit 1
fi

export BW_CLIENTID="$BW_CLIENTID"
export BW_CLIENTSECRET="$BW_CLIENTSECRET"
bw login --apikey --nointeraction > /dev/null

BW_SESSION=$(bw unlock "$BW_PASSWORD" --raw)
export BW_SESSION
bw sync

# ----------------- 4. 执行导出备份 -----------------
echo "=== 开始生成备份文件 ==="
BACKUP_FILE="vaultwarden-mi-$DATE.json"
LOCAL_ENC_FILE="$BACKUP_DIR/$BACKUP_FILE"

# 1. 密码保护型加密导出（支持安全迁移到任何其他账号）
bw export --format encrypted_json --password "$BW_PASSWORD" --output "$LOCAL_ENC_FILE"
echo "✅ 已生成通用加密备份: $LOCAL_ENC_FILE"

# 2. 明文 JSON 备份
bw export --format json --output "$BACKUP_DIR/vaultwarden-open-$DATE.json"
echo "✅ 已生成明文备份: $BACKUP_DIR/vaultwarden-open-$DATE.json"

bw logout

# ----------------- 5. 使用 Rclone 上传至坚果云 -----------------
echo "=== 正在通过 rclone 上传加密备份至坚果云 ==="
rclone copy "$BACKUP_DIR/$BACKUP_FILE" "$REMOTE" --config "$RCLONE_CONFIG"
echo "✅ 加密文件已成功同步至坚果云远端 ($REMOTE)"

# ----------------- 6. 本地与云端数据留存清理 -----------------
echo "=== 正在清理本地旧备份 (保留最新 3 天) ==="
# 使用 find 安全安全清理，规避 ls -t 的滚动覆盖风险
find "$BACKUP_DIR" -name "vaultwarden-mi-*.json" -mtime +3 -exec rm -f {} \;
find "$BACKUP_DIR" -name "vaultwarden-open-*.json" -mtime +3 -exec rm -f {} \;
echo "✅ 本地旧备份清理完成"

echo "=== 正在清理坚果云旧备份 (保留最新 7 份) ==="
# 使用 rclone lsf 获取干净的文件列表（确保没有空行干扰）
REMOTE_FILES=$(rclone lsf "$REMOTE" --config "$RCLONE_CONFIG" --include "vaultwarden-mi-*.json" --files-only | sort)

# 精准计算行数
if [ -n "$REMOTE_FILES" ]; then
    FILE_COUNT=$(echo "$REMOTE_FILES" | wc -l)
    if [ "$FILE_COUNT" -gt 7 ]; then
        DELETE_COUNT=$((FILE_COUNT - 7))
        echo "$REMOTE_FILES" | head -n "$DELETE_COUNT" | while read -r OLD_FILE; do
            if [ -n "$OLD_FILE" ]; then
                echo "⏳ 正在删除远端历史旧备份: $OLD_FILE"
                rclone deletefile "$REMOTE/$OLD_FILE" --config "$RCLONE_CONFIG"
            fi
        done
    fi
fi
echo "✅ 坚果云盘旧备份清理完成，当前保持最新 7 份"

# 销毁敏感内存变量
unset BW_SESSION BW_PASSWORD BW_CLIENTID BW_CLIENTSECRET

