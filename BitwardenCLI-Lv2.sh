#!/bin/bash

# ==============================================================================
# 脚本名称: vaultwarden-backup.sh
# 描述: 自动化备份 Vaultwarden 凭据至本地目录
# ==============================================================================

# 报错即退出，遇到未定义变量即退出
set -euo pipefail

# ----------------- 1. 配置参数 -----------------
VAULT_URL="${VAULT_URL:-https://b.920109.xyz}"
BACKUP_DIR="${BACKUP_DIR:-/home/docker/vaultwarden/cli}"
DATE=$(date +%F)

# 确保备份目录存在
mkdir -p "$BACKUP_DIR"

# ----------------- 2. 检查并安装环境 -----------------
if ! command -v bw &> /dev/null; then
    echo "=== Bitwarden CLI 未安装，正在尝试安装... ==="
    sudo apt update && sudo apt install -y nodejs npm
    sudo npm install -g @bitwarden/cli
fi

# ----------------- 3. 配置服务器地址 (已修复报错) -----------------
echo "=== 正在检查并重置登录状态 ==="
# 强制注销当前会话，避免 "Logout required" 报错
bw logout || true

echo "=== 配置 Vaultwarden 服务器地址 ==="
bw config server "$VAULT_URL"

# ----------------- 4. 身份验证与解锁 -----------------
if [ -z "${BW_CLIENTID:-}" ] || [ -z "${BW_CLIENTSECRET:-}" ] || [ -z "${BW_PASSWORD:-}" ]; then
    echo "❌ 错误: 请先设置环境变量 BW_CLIENTID, BW_CLIENTSECRET 和 BW_PASSWORD"
    exit 1
fi

echo "=== 正在登录 Vaultwarden (API Key) ==="
export BW_CLIENTID="$BW_CLIENTID"
export BW_CLIENTSECRET="$BW_CLIENTSECRET"
bw login --apikey --nointeraction > /dev/null

echo "=== 正在解锁密码库 ==="
BW_SESSION=$(bw unlock "$BW_PASSWORD" --raw)
export BW_SESSION

echo "=== 正在同步数据 ==="
bw sync

# ----------------- 5. 执行导出备份 -----------------
echo "=== 开始备份密码库 ==="

# 备份 1: JSON 加密导出 (带日期)
bw export --format encrypted_json --password "$BW_PASSWORD" --output "$BACKUP_DIR/vaultwarden-mi-$DATE.json"
echo "✅ 已生成加密备份: $BACKUP_DIR/vaultwarden-mi-$DATE.json"

# 备份 2: JSON 明文导出 (带日期)
bw export --format json --output "$BACKUP_DIR/vaultwarden-open-$DATE.json"
echo "✅ 已生成明文备份: $BACKUP_DIR/vaultwarden-open-$DATE.json"

 ----------------- 6. 本地与云端清理及同步 -----------------
echo "=== 正在清理本地旧备份 (保留最新 3 份) ==="
cd "$BACKUP_DIR"
ls -t vaultwarden-mi-*.json 2>/dev/null | tail -n +4 | xargs -I {} rm -f {} || true
ls -t vaultwarden-open-*.json 2>/dev/null | tail -n +4 | xargs -I {} rm -f {} || true

if [ -z "$JANGUOYUN_USER" ] || [ -z "$JANGUOYUN_PASS" ]; then
    echo "⚠️ 警告: 未检测到坚果云凭据，跳过云端备份流程"
else
    FILE_NAME=$(basename "$LOCAL_ENC_FILE")
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "$JANGUOYUN_USER:$JANGUOYUN_PASS" -X PUT -T "$LOCAL_ENC_FILE" "$WEBDAV_URL$FILE_NAME")
    
    if [ "$HTTP_CODE" -eq 201 ] || [ "$HTTP_CODE" -eq 204 ]; then
        echo "✅ 加密文件已成功同步至坚果云"
        REMOTE_FILES=$(curl -s -u "$JANGUOYUN_USER:$JANGUOYUN_PASS" -X PROPFIND -H "Depth: 1" "$WEBDAV_URL" | \
            grep -oE "vaultwarden-mi-[0-9]{4}-[0-9]{2}-[0-9]{2}\.json" | sort -u)
        FILE_COUNT=$(echo "$REMOTE_FILES" | grep -c "$" || echo 0)
        
        if [ "$FILE_COUNT" -gt 7 ]; then
            DELETE_COUNT=$((FILE_COUNT - 7))
            echo "$REMOTE_FILES" | head -n "$DELETE_COUNT" | while read -r OLD_FILE; do
                curl -s -u "$JANGUOYUN_USER:$JANGUOYUN_PASS" -X DELETE "$WEBDAV_URL$OLD_FILE" > /dev/null
            done
        fi
        echo "✅ 坚果云盘旧备份清理完成，已保留最新 7 份"
    else
        echo "❌ 错误: 上传至坚果云失败，HTTP 状态码为: $HTTP_CODE"
    fi
fi


# ----------------- 7. 登出清理会话 -----------------
echo "=== 正在注销会话 ==="
bw logout

echo "🎉 所有备份任务已成功完成！"
