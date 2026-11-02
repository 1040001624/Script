# 1. 安装解压工具
sudo apt update && sudo apt install -y unzip curl

# 2. 下载官方最新的 Linux 版 CLI
curl -Lso bw-linux.zip "https://vault.bitwarden.com/download/?app=cli&platform=linux"

# 3. 解压并赋予执行权限
unzip bw-linux.zip
chmod +x bw

# 4. 移动到系统全局路径下
sudo mv bw /usr/local/bin/

# 5. 验证安装
bw --version
