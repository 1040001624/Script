#!/bin/bash

set -e

echo ">>> 安装 fastfetch"

apt update
apt install -y curl wget

# 安装 fastfetch
if ! command -v fastfetch >/dev/null 2>&1; then
    bash <(curl -fsSL https://raw.githubusercontent.com/fastfetch-cli/fastfetch/dev/scripts/install.sh)
fi

echo ">>> 导入 fastfetch 配置"

mkdir -p ~/.config/fastfetch

curl -fsSL \
https://raw.githubusercontent.com/1040001624/Script/refs/heads/main/fastfetch/config.jsonc \
-o ~/.config/fastfetch/config.jsonc

echo ">>> 设置 SSH 登录显示"

if ! grep -q "fastfetch" ~/.bashrc; then
cat >> ~/.bashrc <<'EOF'

# fastfetch 登录显示
if [[ $- == *i* ]]; then
    fastfetch
fi

EOF
fi


echo ">>> 完成"
echo "执行 fastfetch 测试："
fastfetch
