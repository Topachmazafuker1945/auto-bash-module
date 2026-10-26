#!/bin/bash

# ==============================================================================
# Полный скрипт автоматизации 1 модуля Демо-экзамена 2027 (Debian 13)
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "❌ Ошибка: Скрипт необходимо запускать от имени root (sudo su -)."
  exit 1
fi

echo "======================================================"
echo " Добро пожаловать в скрипт настройки 1 модуля 2027"
echo "======================================================"

echo "Выберите устройство, которое вы настраиваете:"
select ROLE in "ISP" "HQ-RTR" "HQ-SRV" "HQ-CLI" "BR-RTR" "BR-FW" "BR-SRV" "Выход"; do
    case $ROLE in
        "ISP"|"HQ-RTR"|"HQ-SRV"|"HQ-CLI"|"BR-RTR"|"BR-FW"|"BR-SRV" ) break;;
        "Выход" ) exit 0;;
    esac
done

echo ">>> Выбрано устройство: $ROLE"

# ==============================================================================
# ОБЩАЯ БАЗОВАЯ НАСТРОЙКА ДЛЯ ВСЕХ УСТРОЙСТВ
# ==============================================================================

echo "[*] Отключение CD-ROM репозитория..."
sed -i 's/^deb cdrom:/#deb cdrom:/g' /etc/apt/sources.list
cat << 'EOF' > /etc/apt/sources.list
deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware
EOF

echo "[*] Настройка часового пояса (Asia/Krasnoyarsk)..."
timedatectl set-timezone Asia/Krasnoyarsk

if [[ "$ROLE" == *"RTR"* || "$ROLE" == "ISP" || "$ROLE" == "BR-FW" ]]; then
    echo "[*] Включение IP-форвардинга..."
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/sysctl.conf
    sysctl --system > /dev/null
fi

# Функция для создания базового файла nftables
create_nft_base() {
cat << 'EOF' > /etc/nftables.conf
#!/usr/sbin/nft -f
flush ruleset

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        meta l4proto { gre, ipip, ospf } counter return
        masquerade
    }
}

table inet filter {
    chain input { type filter hook input priority filter; policy accept; }
    chain forward { type filter hook forward priority filter; policy accept; }
    chain output { type filter hook output priority filter; policy accept; }
}
EOF
}

# Создание пользователей
if [[ "$ROLE" == "HQ-SRV" || "$ROLE" == "BR-SRV" ]]; then
    echo "[*] Создание пользователя sshuser (UID 2027)..."
    useradd -m -u 2027 -s /bin/bash sshuser || true
    echo "sshuser:P@ssw0rd" | chpasswd
    usermod -aG sudo sshuser
    echo "sshuser ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/sshuser
elif [[ "$ROLE" == "HQ-RTR" || "$ROLE" == "BR-RTR" ]]; then
    echo "[*] Создание пользователя net_admin..."
    useradd -m -s /bin/bash net_admin || true
    echo "net_admin:P@ssw0rd" | chpasswd
    usermod -aG sudo net_admin
    echo "net_admin ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/net_admin
fi

# ==============================================================================
# ИНДИВИДУАЛЬНАЯ НАСТРОЙКА ДЛЯ КАЖДОГО УСТРОЙСТВА
# ==============================================================================

# --- ISP ---
if [ "$ROLE" == "ISP" ]; then
    hostnamectl set-hostname isp.au-team.irpo
    cat << 'EOF' > /etc/network/interfaces
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback

auto ens3
iface ens3 inet dhcp

auto ens4
iface ens4 inet static
    address 172.16.1.1/28

auto ens5
iface ens5 inet static
    address 172.16.2.1/28

post-up nft -f /etc/nftables.conf
EOF
    create_nft_base
    systemctl restart networking

# --- HQ-RTR ---
elif [ "$ROLE" == "HQ-RTR" ]; then
    hostnamectl set-hostname hq-rtr.au-team.irpo
    
    echo "[*] Установка openvswitch-switch..."
    apt update && apt install -y openvswitch-switch > /dev/null 2>&1
    systemctl enable --now openvswitch-switch > /dev/null 2>&1
    
    echo "[*] Настройка OVS (VLAN 100, 200, 999)..."
    ovs-vsctl add-br hq-sw || true
    ovs-vsctl add-port hq-sw ens4 tag=100 || true
    ovs-vsctl add-port hq-sw ens5 tag=200 || true
    ovs-vsctl add-port hq-sw ens6 tag=999 || true
    ovs-vsctl add-port hq-sw vlan100 tag=100 -- set interface vlan100 type=internal || true
    ovs-vsctl add-port hq-sw vlan200 tag=200 -- set interface vlan200 type=internal || true
    ovs-vsctl add-port hq-sw vlan999 tag=999 -- set interface vlan999 type=internal || true

    cat << 'EOF' > /etc/network/interfaces
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback

auto ens3
iface ens3 inet static
    address 172.16.1.2/28
    gateway 172.16.1.1

auto vlan100
iface vlan100 inet static
    address 192.168.100.1/27

auto vlan200
iface vlan200 inet static
    address 192.168.200.1/28

auto vlan999
iface vlan999 inet static
    address 192.168.99.1/29

# GRE Tunnel
auto gre0
iface gre0 inet static
    address 10.10.10.1/30
    pre-up ip tunnel add gre0 mode gre local 172.16.1.2 remote 172.16.2.2 ttl 64
    post-up ip link set gre0 up
    post-down ip tunnel del gre0

post-up nft -f /etc/nftables.conf
post-up ip link set hq-sw up
EOF
    create_nft_base
    
    echo "[*] Установка FRR..."
    apt install -y frr > /dev/null 2>&1
    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    systemctl enable --now frr
    systemctl restart networking

# --- HQ-SRV ---
elif [ "$ROLE" == "HQ-SRV" ]; then
    hostnamectl set-hostname hq-srv.au-team.irpo
    cat << 'EOF' > /etc/network/interfaces
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback

auto ens3
iface ens3 inet static
    address 192.168.100.2/27
    gateway 192.168.100.1
EOF
    systemctl restart networking

# --- HQ-CLI ---
elif [ "$ROLE" == "HQ-CLI" ]; then
    hostnamectl set-hostname hq-cli.au-team.irpo
    cat << 'EOF' > /etc/network/interfaces
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback

auto ens3
iface ens3 inet dhcp
EOF
    systemctl restart networking

# --- BR-RTR ---
elif [ "$ROLE" == "BR-RTR" ]; then
    hostnamectl set-hostname br-rtr.au-team.irpo
    cat << 'EOF' > /etc/network/interfaces
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback

auto ens3
iface ens3 inet static
    address 172.16.2.2/28
    gateway 172.16.2.1

auto ens4
iface ens4 inet static
    address 172.16.10.1/30

# GRE Tunnel
auto gre0
iface gre0 inet static
    address 10.10.10.2/30
    pre-up ip tunnel add gre0 mode gre local 172.16.2.2 remote 172.16.1.2 ttl 64
    post-up ip link set gre0 up
    post-down ip tunnel del gre0

post-up nft -f /etc/nftables.conf
EOF
    create_nft_base

    echo "[*] Установка FRR..."
    apt install -y frr > /dev/null 2>&1
    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    systemctl enable --now frr
    systemctl restart networking

# --- BR-FW ---
elif [ "$ROLE" == "BR-FW" ]; then
    hostnamectl set-hostname br-fw.au-team.irpo
    cat << 'EOF' > /etc/network/interfaces
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback

auto ens3
iface ens3 inet static
    address 172.16.10.2/30
    gateway 172.16.10.1

auto ens4
iface ens4 inet static
    address 172.16.20.1/28

post-up nft -f /etc/nftables.conf
EOF
    create_nft_base

    echo "[*] Установка FRR..."
    apt install -y frr > /dev/null 2>&1
    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    systemctl enable --now frr
    systemctl restart networking

# --- BR-SRV ---
elif [ "$ROLE" == "BR-SRV" ]; then
    hostnamectl set-hostname br-srv.au-team.irpo
    cat << 'EOF' > /etc/network/interfaces
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback

auto ens3
iface ens3 inet static
    address 172.16.20.2/28
    gateway 172.16.20.1
EOF
    systemctl restart networking
fi

# ==============================================================================
# НАСТРОЙКА ДОПОЛНИТЕЛЬНЫХ СЛУЖБ
# ==============================================================================

if [ "$ROLE" == "HQ-SRV" ] || [ "$ROLE" == "BR-SRV" ]; then
    echo "[*] Установка и настройка SSH..."
    apt update && apt install -y openssh-server > /dev/null 2>&1
    sed -i 's/#Port 22/Port 2027/' /etc/ssh/sshd_config
    sed -i '/AllowUsers/d' /etc/ssh/sshd_config
    sed -i '/MaxAuthTries/d' /etc/ssh/sshd_config
    sed -i '/Banner/d' /etc/ssh/sshd_config
    echo "AllowUsers sshuser" >> /etc/ssh/sshd_config
    echo "MaxAuthTries 2" >> /etc/ssh/sshd_config
    echo "Banner /etc/ssh_banner" >> /etc/ssh/sshd_config
    
    cat << 'EOF' > /etc/ssh_banner
*************************
*                       *
* Authorized access only *
*                       *
*************************
EOF
    systemctl restart ssh
fi

if [ "$ROLE" == "HQ-RTR" ]; then
    echo "[*] Настройка DHCP-сервера..."
    apt update && apt install -y isc-dhcp-server > /dev/null 2>&1
    sed -i 's/INTERFACESv4=""/INTERFACESv4="vlan200"/' /etc/default/isc-dhcp-server
    
    cat << 'EOF' > /etc/dhcp/dhcpd.conf
option domain-name "au-team.irpo";
option domain-name-servers 192.168.100.2;
default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet 192.168.200.0 netmask 255.255.255.240 {
    range 192.168.200.2 192.168.200.14;
    option routers 192.168.200.1;
}
EOF
    systemctl restart isc-dhcp-server
fi

if [ "$ROLE" == "HQ-SRV" ]; then
    echo "[*] Настройка DNS (dnsmasq)..."
    apt update && apt install -y dnsmasq > /dev/null 2>&1
    systemctl stop systemd-resolved || true
    systemctl disable systemd-resolved || true
    rm -f /etc/resolv.conf
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    
    cat << 'EOF' > /etc/dnsmasq.conf
interface=ens3
domain=au-team.irpo
server=8.8.8.8
listen-address=192.168.100.2
no-resolv
no-hosts

address=/hq-rtr.au-team.irpo/192.168.100.1
ptr-record=1.100.168.192.in-addr.arpa,hq-rtr.au-team.irpo
address=/hq-srv.au-team.irpo/192.168.100.2
ptr-record=2.100.168.192.in-addr.arpa,hq-srv.au-team.irpo
address=/hq-cli.au-team.irpo/192.168.200.3
ptr-record=3.200.168.192.in-addr.arpa,hq-cli.au-team.irpo
address=/br-rtr.au-team.irpo/172.16.10.1
address=/br-fw.au-team.irpo/172.16.20.1
ptr-record=1.20.16.172.in-addr.arpa,br-fw.au-team.irpo
address=/br-srv.au-team.irpo/172.16.20.2
ptr-record=2.20.16.172.in-addr.arpa,br-srv.au-team.irpo
EOF
    systemctl restart dnsmasq
fi

# Смена resolv.conf для всех, кроме ISP и HQ-SRV
if [[ "$ROLE" != "ISP" && "$ROLE" != "HQ-SRV" ]]; then
    echo "[*] Настройка DNS-клиента (192.168.100.2)..."
    rm -f /etc/resolv.conf
    echo "nameserver 192.168.100.2" > /etc/resolv.conf
fi

echo "======================================================"
echo " ✅ Базовая настройка $ROLE завершена!"
echo " ⚠️  ВАЖНО: для настройки OSPF (FRR) запустите vtysh вручную"
echo " (команды есть в вашем гайде, стр. 26-27)"
echo " После проверки конфигурации рекомендуется выполнить: reboot"
echo "======================================================"
