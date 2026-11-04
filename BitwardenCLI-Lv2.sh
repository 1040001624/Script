#!/bin/bash

# ==============================================================================
# 脚本名称: vaultwarden-backup.sh
# 描述: Vaultwarden 凭据自动化备份 (本地留 3 份，坚果云通过 rclone 留 7 份)
# 扩展: 增加 Telegram 机器人自动化通知功能
# ==============================================================================

set -euo pipefail

# ----------------- 1. 核心生产配置 -----------------
CONTAINER="vaultwarden"
VAULT_URL="${VAULT_URL:-https://920109.xyz}"
BACKUP_DIR="/home/docker/vaultwarden/cli"
REMOTE="jianguoyun:vaultwarden"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
DATE=$(date +%F)

# [新增] Telegram 配置 (建议通过环境变量注入，或直接填在下方)
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"  # 例如: "123456789:ABCdefGhIJKlmNoPQRsTUVwxyZ"
TG_CHAT_ID="${TG_CHAT_ID:-}"      # 例如: "987654321" 或 "-100123456789"

mkdir -p "$BACKUP_DIR"

# ----------------- 1.5 TG 推送核心函数 -----------------
send_tg_notification() {
    local message="$1"
    # 如果未配置 Token 或 Chat ID，则静默跳过，不影响主脚本运行
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        return 0
    fi
    
    # 异步推送，防止因网络抖动导致主脚本长时间阻塞
    (
        curl -s -X POST "https://telegram.org{TG_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "text=${message}" \
            -d "parse_mode=Markdown" \
            > /dev/null 2>&1 || true
    ) &
}

# 捕获全局异常，确保脚本意外中断时能收到警报
error_trap() {
    local exit_code=$?
    local line_number=$1
    if [ $exit_code -ne 0 ]; then
        local err_msg="❌ *Vaultwarden 备份任务失败*
━━━━━━━━━━━━━━━━━━━━
📅 *时间:* \`$(date '+%Y-%m-%d %H:%M:%S')\`
⚠️ *错误代码:* \`${exit_code}\`
📍 *错误行号:* \`第 ${line_number} 行\`
🔔 *提示:* 请登录服务器检查日志排查问题。"
        send_tg_notification "$err_msg"
    fi
}
trap 'error_trap $LINENO' ERR

# ----------------- 2. 环境依赖检查 -----------------
if ! command -v rclone &> /dev/null; then
    echo "❌ 错误: 宿主机未检测到 rclone，请先安装并在 $RCLONE_CONFIG 配置好坚果云"
    exit 1
fi

if [ ! -f "$RCLONE_CONFIG" ]; then
    echo "❌ 错误: 未在指定路径找到 rclone 配置文件: $RCLONE_CONFIG"
    exit 1
fi

if ! command -v bw &> /dev/null; then
    echo "=== 宿主机 Bitwarden CLI 未安装，正在拉取纯二进制版... ==="
    TMP_DIR=$(mktemp -d)
    FETCH_CMD=$(command -v curl >/dev/null && echo "curl -Lso" || echo "wget -qO")
    
    echo "⏳ 正在下载官方 Linux 独立版二进制..."
    $FETCH_CMD "$TMP_DIR/bw-linux.zip" "https://bitwarden.com"
    
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

bw export --format encrypted_json --password "$BW_PASSWORD" --output "$LOCAL_ENC_FILE"
echo "✅ 已生成通用加密备份: $LOCAL_ENC_FILE"

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

# 初始化上传状态变量用于 TG 通报
UPLOAD_STATUS="ℹ️ 未知状态"

if echo "$RCLONE_OUTPUT" | grep -qi -E "identical|skipped"; then
    UPLOAD_STATUS="ℹ️ 云端已存在今日相同的备份，已智能跳过上传。"
    echo "ℹ️  提示: 坚果云端已存在今日相同的备份文件，rclone 已智能跳过重复上传。"
elif echo "$RCLONE_OUTPUT" | grep -q "Transferred: *[1-9]"; then
    UPLOAD_STATUS="🚀 检测到新数据，今日加密备份已成功同步至坚果云！"
    echo "🎉 成功: 检测到新文件或数据变动，今日加密备份已成功上传至坚果云！"
else
    UPLOAD_STATUS="✅ 同步检查完成（云端文件状态与本地保持一致）。"
    echo "✅ 同步检查完成（云端文件状态与本地保持一致）。"
fi

# ----------------- 6. 本地与云端数据留存清理 -----------------
echo "=== 正在清理本地旧备份 (保留最新 3 天) ==="
find "$BACKUP_DIR" -name "vaultwarden-mi-*.json" -mtime +3 -exec rm -f {} \;
find "$BACKUP_DIR" -name "vaultwarden-open-*.json" -mtime +3 -exec rm -f {} \;
echo "✅ 本地旧备份清理完成"

echo "=== 正在清理坚果云旧备份 (保留最新 7 份) ==="
REMOTE_FILES=$(rclone lsf "$REMOTE" --config "$RCLONE_CONFIG" --include "vaultwarden-mi-*.json" --files-only --max-depth 1 | sort)

CLEANUP_STATUS="✅ 远端备份数量正常，未触发清理"
if [ -n "$REMOTE_FILES" ]; then
    FILE_COUNT=$(echo "$REMOTE_FILES" | wc -l)
    if [ "$FILE_COUNT" -gt 7 ]; then
        DELETE_COUNT=$((FILE_COUNT - 7))
        echo "⏳ 远端历史旧备份超额，正在精准计算并批量清理 ${DELETE_COUNT} 份..."
        
        echo "$REMOTE_FILES" | head -n "$DELETE_COUNT" | rclone delete --config "$RCLONE_CONFIG" --files-from - "$REMOTE"
        CLEANUP_STATUS="♻️ 远端历史备份超额，已自动精准清理 \`${DELETE_COUNT}\` 份旧数据"
    fi
fi
echo "✅ 坚果云盘旧备份清理完成，当前保持最新 7 份"

# ----------------- 7. 推送成功报告 -----------------
SUCCESS_MSG="🔑 *Vaultwarden 备份成功报告*
━━━━━━━━━━━━━━━━━━━━
📅 *时间:* \`$(date '+%Y-%m-%d %H:%M:%S')\`
📂 *本地文件:* \`${BACKUP_FILE}\`
☁️ *云端同步:* ${UPLOAD_STATUS}
🧹 *云端清理:* ${CLEANUP_STATUS}
🎉 *状态:* 策略执行完毕，数据安全。"

send_tg_notification "$SUCCESS_MSG"

# 销毁敏感内存变量
unset BW_SESSION BW_PASSWORD BW_CLIENTID BW_CLIENTSECRET
