#!/bin/bash
CFG=/etc/ssh/sshd_config
backup(){ cp -a "$CFG" "$CFG.bak.$(date +%F-%H%M%S)"; }
restart_ssh(){
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
}
set_opt(){
  key="$1"; val="$2"
  grep -q "^#\?$key" "$CFG" && sed -i "s/^#\?$key.*/$key $val/" "$CFG" || echo "$key $val" >> "$CFG"
}
while true; do
clear
echo "==== Debian SSH 管理 ===="
echo "1. 开启密码登录"
echo "2. 关闭密码登录"
echo "3. 开启 Root 密码登录"
echo "4. 禁止 Root 密码登录(仅密钥)"
echo "5. 查看SSH配置"
echo "6. 查看最近登录"
echo "7. 重启SSH"
echo "0. 退出"

backup
case $c in
1) set_opt PasswordAuthentication yes; restart_ssh;;
2) set_opt PasswordAuthentication no; restart_ssh;;
3) set_opt PermitRootLogin yes; set_opt PasswordAuthentication yes; restart_ssh;;
4) set_opt PermitRootLogin prohibit-password; restart_ssh;;
5) sshd -T | egrep 'passwordauthentication|permitrootlogin|pubkeyauthentication'; read -n1;;
6) last | head -20; read -n1;;
7) restart_ssh;;
0) exit 0;;
*) echo "无效"; sleep 1;;
esac
done
