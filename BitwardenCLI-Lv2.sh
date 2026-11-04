#!/bin/bash

# ==============================================================================
# 脚本名称: vaultwarden-backup.sh
# 描述: Vaultwarden 凭据自动化备份 (本地留 3 份，坚果云通过 rclone 留 7 份)
#       集成 Qmsg 酱通知推送
# ==============================================================================

set -euo pipefail

# ----------------- 0. 加载 .env 环境变量 -----------------
# 自动寻找脚本同目录下的 .env 文件并加载
ENV_FILE="$(dirname "$0")/.env"
if [ -f "$ENV_FILE" ]; then
    echo "--- 正在加载 .env 配置文件 ---"
    # 开启自动导出变量功能
    set -a
    # 使用 allexport 兼容的干净方式安全加载，过滤注释与空行，确保有空格的注释绝不报错
    source <(grep -v '^[[:space:]]*#' "$ENV_FILE" | grep -v '^[[:space:]]*$')
    # 关闭自动导出变量功能，恢复系统默认
    set +a
else
    echo "⚠️ 警告: 未找到 .env 配置文件，将尝试读取系统环境变量"
fi

# ----------------- 1. 核心生产配置 -----------------
CONTAINER="vaultwarden"
VAULT_URL="${VAULT_URL:-https://b.920109.xyz}"
BACKUP_DIR="/home/docker/vaultwarden/cli"
REMOTE="jianguoyun:vaultwarden"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
DATE=$(date +%F)

# Qmsg 酱推送配置 (从 .env 中读取，若无则留空)
QMSG_KEY="${QMSG_KEY:-}"
QMSG_TYPE="${QMSG_TYPE:-send}" # 可选 send(好友) 或 group(群)

mkdir -p "$BACKUP_DIR"

# ----------------- 额外函数：Qmsg 推送 -----------------
push_to_qmsg() {
    local msg="$1"
    if [ -z "$QMSG_KEY" ]; then
        echo "ℹ️  提示: 未配置 Qmsg酱 TOKEN (QMSG_KEY)，跳过推送。"
        return 0
    fi
    echo "⏳ 正在通过 Qmsg 酱推送状态..."
    # 使用 curl 异步静默推送
    curl -s -X POST "https://zendee.cn{QMSG_TYPE}/${QMSG_KEY}" \
        -d "msg=${msg}" > /dev/null || echo "⚠️ Qmsg 酱推送失败"
}

# 捕获脚本异常错误，实现失败时推送
error_trap() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        push_to_qmsg "❌ Vaultwarden 备份失败！今日 ($DATE) 脚本在执行过程中报错退出，请登录服务器检查日志。"
    fi
}
trap error_trap EXIT

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

# 检查 Bitwarden CLI
if ! command -v bw &> /dev/null; then
    echo "=== 宿主机 Bitwarden CLI 未安装，正在拉取纯二进制版... ==="
    TMP_DIR=$(mktemp -d)
    
    FETCH_CMD=$(command -v curl >/dev/null && echo "curl -Lso" || echo "wget -qO")
    
    echo "⏳ 正在下载官方 Linux 独立版二进制..."
    $FETCH_CMD "$TMP_DIR/bw-linux.zip" "https://vault.bitwarden.com/download/?app=cli&platform=linux"
    
    if command -v unzip &> /dev/null; then
        unzip -q "$TMP_DIR/bw-linux.zip" -d "$TMP_DIR"
    elif command -v python3 &> /dev/null; then
        python3 -m zipfile -e "$TMP_DIR/bw-linux.zip" "$TMP_DIR"
    else
        sudo apt-get update -qq && sudo apt-get install -y -qq unzip
        unzip -q "$TMP_DIR/bw-linux.zip" -d "$TMP_DIR"
    fi
    
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

# 1. 密码保护型加密导出
bw export --format encrypted_json --password "$BW_PASSWORD" --output "$LOCAL_ENC_FILE"
echo "✅ 已生成通用加密备份: $LOCAL_ENC_FILE"

# 2. 明文 JSON 备份
bw export --format json --output "$BACKUP_DIR/vaultwarden-open-$DATE.json"
echo "✅ 已生成明文备份: $BACKUP_DIR/vaultwarden-open-$DATE.json"

bw logout

# ----------------- 5. 使用 Rclone 上传至坚果云 -----------------
echo "=== 正在通过 rclone 上传加密备份至坚果云 ==="

RCLONE_OUTPUT=$(rclone copy "$BACKUP_DIR/$BACKUP_FILE" "$REMOTE" \
    --config "$RCLONE_CONFIG" \
    --retries 3 \
    --low-level-retries 10 \
    --contimeout 30s \
    --timeout 5m \
    --stats-one-line \
    -v 2>&1 || true)

echo "$RCLONE_OUTPUT" | grep -E "Transferred:|Elapsed" || true

# 初始化推送文本
PUSH_MSG=""

if echo "$RCLONE_OUTPUT" | grep -qiE "identical|skipped"; then
    echo "ℹ️  提示: 坚果云端已存在今日相同的备份文件，rclone 已智能跳过重复上传。"
    PUSH_MSG="ℹ️ Vaultwarden备份提醒：云端已存在今日相同备份，已智能跳过上传。本地与云端数据保持一致。"
elif echo "$RCLONE_OUTPUT" | grep -q "Transferred: *[1-9]"; then
    echo "🎉 成功: 检测到新文件或数据变动，今日加密备份已成功上传至坚果云！"
    PUSH_MSG="🎉 Vaultwarden备份成功！今日加密备份已成功同步至坚果云盘。"
else
    echo "✅ 同步检查完成（云端文件状态与本地保持一致）。"
    PUSH_MSG="✅ Vaultwarden备份提醒：同步检查完成，云端文件状态与本地保持一致。"
fi

# ----------------- 6. 本地与云端数据留存清理 -----------------
echo "=== 正在清理本地旧备份 (保留最新 3 天) ==="
find "$BACKUP_DIR" -name "vaultwarden-mi-*.json" -mtime +3 -exec rm -f {} \;
find "$BACKUP_DIR" -name "vaultwarden-open-*.json" -mtime +3 -exec rm -f {} \;
echo "✅ 本地旧备份清理完成"

echo "=== 正在清理坚果云旧备份 (保留最新 7 份) ==="
REMOTE_FILES=$(rclone lsf "$REMOTE" --config "$RCLONE_CONFIG" --include "vaultwarden-mi-*.json" --files-only --max-depth 1 | sort)

if [ -n "$REMOTE_FILES" ]; then
    FILE_COUNT=$(echo "$REMOTE_FILES" | wc -l)
    if [ "$FILE_COUNT" -gt 7 ]; then
        DELETE_COUNT=$((FILE_COUNT - 7))
        echo "⏳ 远端历史旧备份超额，正在精准计算并批量清理 ${DELETE_COUNT} 份..."
        echo "$REMOTE_FILES" | head -n "$DELETE_COUNT" | rclone delete --config "$RCLONE_CONFIG" --files-from - "$REMOTE"
        PUSH_MSG="${PUSH_MSG} 远端旧数据清理完成，已精准完成历史超额留存清理。"
    fi
fi
echo "✅ 坚果云盘旧备份清理完成，当前保持最新 7 份"

# 执行成功推送
push_to_qmsg "$PUSH_MSG"

# 正常退出，解除错误捕获
trap - EXIT

# 销毁敏感内存变量
unset BW_SESSION BW_PASSWORD BW_CLIENTID BW_CLIENTSECRET QMSG_KEY QMSG_TYPE
