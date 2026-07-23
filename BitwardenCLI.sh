#!/bin/bash

# ==============================================================================
# 脚本名称: vaultwarden-backup.sh
# 描述: 自动化备份 Vaultwarden 凭据至本地目录
# 使用说明: 建议配合环境变量或 GitHub Secrets（若在GitHub Actions中使用）
# ==============================================================================

# 报错即退出，遇到未定义变量即退出
set -euo pipefail

# ----------------- 1. 配置参数 (可根据需求修改) -----------------
VAULT_URL="${VAULT_URL:-https://b.920109.xyz}"
BACKUP_DIR="${BACKUP_DIR:-/home/docker/vaultwarden/cli}"
DATE=$(date +%F)

# 确保备份目录存在
mkdir -p "$BACKUP_DIR"

# ----------------- 2. 检查并安装环境 (可选) -----------------
# 如果你只在已配置好环境的服务器上运行，可以注释掉这段
if ! command -v bw &> /dev/null; then
    echo "=== Bitwarden CLI 未安装，正在尝试安装... ==="
    sudo apt update && sudo apt install -y nodejs npm
    sudo npm install -g @bitwarden/cli
fi

# ----------------- 3. 配置服务器地址 -----------------
echo "=== 配置 Vaultwarden 服务器地址 ==="
bw config server "$VAULT_URL"

# ----------------- 4. 身份验证与解锁 -----------------
# 提示：在非交互式/定时任务中，必须提供以下环境变量
if [ -z "${BW_CLIENTID:-}" ] || [ -z "${BW_CLIENTSECRET:-}" ] || [ -z "${BW_PASSWORD:-}" ]; then
    echo "❌ 错误: 请先设置环境变量 BW_CLIENTID, BW_CLIENTSECRET 和 BW_PASSWORD"
    echo "示例: export BW_CLIENTID='...' BW_CLIENTSECRET='...' BW_PASSWORD='...'"
    exit 1
fi

echo "=== 正在登录 Vaultwarden (API Key) ==="
# 使用环境变量自动填充，避免交互式输入
export BW_CLIENTID="$BW_CLIENTID"
export BW_CLIENTSECRET="$BW_CLIENTSECRET"
bw login --apikey --nointeraction > /dev/null

echo "=== 正在解锁密码库 ==="
# bw unlock 会返回一个临时 SESSION KEY，必须捕获它才能进行导出操作
BW_SESSION=$(bw unlock "$BW_PASSWORD" --raw)
export BW_SESSION

echo "=== 正在同步数据 ==="
bw sync

# ----------------- 5. 执行导出备份 -----------------
echo "=== 开始备份密码库 ==="

# 备份 1: JSON 加密导出 (带日期)
bw export --format encrypted_json --output "$BACKUP_DIR/vaultwarden-$DATE.json"
echo "✅ 已生成加密备份: $BACKUP_DIR/vaultwarden-$DATE.json"

# 备份 2: JSON 明文导出 (带日期)
bw export --format json --output "$BACKUP_DIR/backup-$DATE.json"
echo "✅ 已生成明文备份: $BACKUP_DIR/backup-$DATE.json"

# ----------------- 6. 登出清理会话 -----------------
echo "=== 正在注销会话 ==="
bw logout

echo "🎉 所有备份任务已成功完成！"
