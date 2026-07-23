#!/bin/bash

echo "=== 安装 Bitwarden CLI ==="

apt update
apt install -y nodejs npm curl

npm install -g @bitwarden/cli

echo "=== 创建中文管理工具 ==="

mkdir -p /home/docker/vaultwarden/cli

cat > /home/docker/vaultwarden/cli/bwcn <<'EOF'
#!/bin/bash

while true
do
clear
echo "=========================="
echo " Bitwarden CLI 中文助手 "
echo "=========================="
echo "1. 登录"
echo "2. 状态"
echo "3. 同步"
echo "4. 解锁"
echo "5. 导出JSON"
echo "6. 加密导出"
echo "0. 退出"

read -p "选择: " n

case $n in
1) bw login ;;
2) bw status ;;
3) bw sync ;;
4) bw unlock ;;
5) bw export --format json ;;
6) bw export --format encrypted_json ;;
0) exit ;;
*) echo "错误";;
esac

read -p "回车继续"
done
EOF

chmod +x /home/docker/vaultwarden/cli/bwcn

ln -sf /home/docker/vaultwarden/cli/bwcn /usr/local/bin/bwcn

echo "安装完成"
echo "输入 bwcn 启动中文助手"
