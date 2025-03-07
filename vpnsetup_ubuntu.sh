#!/bin/bash

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 权限运行此脚本（使用 sudo）"
  exit 1
fi

# 定义输出目录
OUTPUT_DIR="$PWD/vpn_files"

# 菜单函数
show_menu() {
  clear
  echo "=== VPN 一键管理脚本 ==="
  echo "1. 搭建 VPN"
  echo "2. 移除 VPN"
  echo "3. 查看日志"
  echo "4. 退出"
  echo "===================="
}

# 搭建 VPN 函数
setup_vpn() {
  # 创建输出目录（如果不存在）
  if [ ! -d "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
    chown $SUDO_USER:$SUDO_USER "$OUTPUT_DIR"
  fi

  echo "正在更新系统并安装必要软件（openvpn、easy-rsa、qrencode）..."
  apt update && apt upgrade -y
  apt install -y openvpn easy-rsa qrencode

  echo "设置 Easy-RSA 用于生成证书..."
  make-cadir /etc/openvpn/easy-rsa
  cd /etc/openvpn/easy-rsa

  ./easyrsa init-pki
  ./easyrsa --batch build-ca nopass
  ./easyrsa --batch gen-req server nopass
  ./easyrsa --batch sign-req server server
  ./easyrsa gen-dh
  ./easyrsa --batch gen-req client1 nopass
  ./easyrsa --batch sign-req client client1

  cp pki/ca.crt pki/private/server.key pki/issued/server.crt pki/dh.pem /etc/openvpn/
  cp pki/ca.crt pki/private/client1.key pki/issued/client1.crt /etc/openvpn/

  echo "创建 OpenVPN 服务器配置文件..."
  cat > /etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
keepalive 10 120
cipher AES-256-CBC
persist-key
persist-tun
status openvpn-status.log
verb 3
EOF

  echo "启用 IP 转发..."
  sysctl -w net.ipv4.ip_forward=1
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

  echo "配置防火墙..."
  ufw allow 1194/udp
  ufw allow OpenSSH
  ufw disable
  ufw enable

  echo "启动 OpenVPN 服务..."
  systemctl enable openvpn@server
  systemctl start openvpn@server

  echo "生成客户端配置文件..."
  PUBLIC_IP=$(curl -s ifconfig.me)
  cat > /etc/openvpn/client1.ovpn <<EOF
client
dev tun
proto udp
remote $PUBLIC_IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
ca ca.crt
cert client1.crt
key client1.key
cipher AES-256-CBC
verb 3
EOF

  # 将证书和密钥嵌入到客户端配置文件中
  echo "<ca>" >> /etc/openvpn/client1.ovpn
  cat /etc/openvpn/ca.crt >> /etc/openvpn/client1.ovpn
  echo "</ca>" >> /etc/openvpn/client1.ovpn
  echo "<cert>" >> /etc/openvpn/client1.ovpn
  cat /etc/openvpn/client1.crt >> /etc/openvpn/client1.ovpn
  echo "</cert>" >> /etc/openvpn/client1.ovpn
  echo "<key>" >> /etc/openvpn/client1.ovpn
  cat /etc/openvpn/client1.key >> /etc/openvpn/client1.ovpn
  echo "</key>" >> /etc/openvpn/client1.ovpn

  # 复制客户端文件到输出目录
  cp /etc/openvpn/client1.ovpn "$OUTPUT_DIR/client1.ovpn"
  chown $SUDO_USER:$SUDO_USER "$OUTPUT_DIR/client1.ovpn"

  # 生成二维码图片文件到输出目录
  echo "生成 Shadowrocket 可识别的二维码图片..."
  QR_FILE="$OUTPUT_DIR/client1_qr.png"
  qrencode -o "$QR_FILE" -s 10 "$(cat /etc/openvpn/client1.ovpn)"
  chown $SUDO_USER:$SUDO_USER "$QR_FILE"

  # 在终端展示二维码
  echo "以下是 VPN 配置的二维码（可供 Shadowrocket 扫描）："
  qrencode -t ansiutf8 "$(cat /etc/openvpn/client1.ovpn)"

  echo "VPN 搭建完成！"
  echo "客户端配置文件已保存到 $OUTPUT_DIR/client1.ovpn"
  echo "二维码图片已保存到 $OUTPUT_DIR/client1_qr.png"
  echo "请使用 Shadowrocket 扫描上方二维码或导入 client1.ovpn 文件。"
  echo "按任意键返回菜单..."
  read -n 1
}

# 移除 VPN 函数
remove_vpn() {
  echo "正在移除 VPN..."
  systemctl stop openvpn@server
  systemctl disable openvpn@server
  apt remove -y openvpn easy-rsa qrencode
  rm -rf /etc/openvpn/*
  ufw delete allow 1194/udp
  echo "VPN 已移除！"
  echo "按任意键返回菜单..."
  read -n 1
}

# 查看日志函数
view_logs() {
  if [ -f /etc/openvpn/openvpn-status.log ]; then
    echo "以下是 OpenVPN 日志："
    cat /etc/openvpn/openvpn-status.log
  else
    echo "日志文件不存在，可能是 VPN 未运行或未正确配置。"
  fi
  echo "按任意键返回菜单..."
  read -n 1
}

# 主循环
while true; do
  show_menu
  read -p "请输入选项 (1-4): " choice
  case $choice in
    1)
      setup_vpn
      ;;
    2)
      remove_vpn
      ;;
    3)
      view_logs
      ;;
    4)
      echo "退出脚本..."
      exit 0
      ;;
    *)
      echo "无效选项，请输入 1-4。"
      echo "按任意键继续..."
      read -n 1
      ;;
  esac
done