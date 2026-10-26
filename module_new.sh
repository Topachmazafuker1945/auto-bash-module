#!/bin/bash

# ==============================================================================
# ИНТЕРАКТИВНЫЙ СКРИПТ ПОШАГОВОЙ НАСТРОЙКИ (Демо-экзамен 2027, Модуль 1)
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "❌ Ошибка: Скрипт необходимо запускать от имени root (sudo su -)."
  exit 1
fi

# --- Выбор роли ---
echo "======================================================"
echo " ВЫБЕРИТЕ УСТРОЙСТВО, КОТОРОЕ НАСТРАИВАЕТЕ:"
echo "======================================================"
select ROLE in "ISP" "HQ-RTR" "HQ-SRV" "HQ-CLI" "BR-RTR" "BR-FW" "BR-SRV" "Выход"; do
    case $ROLE in
        "ISP"|"HQ-RTR"|"HQ-SRV"|"HQ-CLI"|"BR-RTR"|"BR-FW"|"BR-SRV" ) break;;
        "Выход" ) exit 0;;
    esac
done
echo ">>> Выбрано устройство: $ROLE"

# --- Функции для заданий ---
task_1_base() {
    echo "[*] Задание 1: Базовая настройка..."
    sed -i 's/^deb cdrom:/#deb cdrom:/g' /etc/apt/sources.list
    cat << 'EOF' > /etc/apt/sources.list
deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware
EOF
    
    timedatectl set-timezone Asia/Krasnoyarsk
    
    if [[ "$ROLE" == *"RTR"* || "$ROLE" == "ISP" || "$ROLE" == "BR-FW" ]]; then
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/sysctl.conf
        sysctl --system > /dev/null 2>&1
    fi
}

task_2_network() {
    echo "[*] Задание 2: Настройка сети (IP, интерфейсы)..."
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
EOF
    elif [ "$ROLE" == "HQ-RTR" ]; then
        hostnamectl set-hostname hq-rtr.au-team.irpo
        cat << 'EOF' > /etc/network/interfaces
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback
auto ens3
iface ens3 inet static
    address 172.16.1.2/28
    gateway 172.16.1.1
auto ens4
iface ens4 inet static
    address 192.168.100.1/27
auto ens5
iface ens5 inet static
    address 192.168.200.1/28
auto ens6
iface ens6 inet static
    address 192.168.99.1/29
EOF
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
    elif [ "$ROLE" == "HQ-CLI" ]; then
        hostnamectl set-hostname hq-cli.au-team.irpo
        cat << 'EOF' > /etc/network/interfaces
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback
auto ens3
iface ens3 inet dhcp
EOF
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
EOF
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
EOF
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
    fi
    echo "  -> Сеть настроена. Рекомендуется перезагрузить networking: systemctl restart networking"
}

task_3_users() {
    echo "[*] Задание 3: Создание пользователей..."
    if [[ "$ROLE" == "HQ-SRV" || "$ROLE" == "BR-SRV" ]]; then
        useradd -m -u 2027 -s /bin/bash sshuser || true
        echo "sshuser:P@ssw0rd" | chpasswd
        usermod -aG sudo sshuser
        echo "sshuser ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/sshuser
        echo "  -> Пользователь sshuser создан."
    elif [[ "$ROLE" == "HQ-RTR" || "$ROLE" == "BR-RTR" ]]; then
        useradd -m -s /bin/bash net_admin || true
        echo "net_admin:P@ssw0rd" | chpasswd
        usermod -aG sudo net_admin
        echo "net_admin ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/net_admin
        echo "  -> Пользователь net_admin создан."
    else
        echo "  -> Для этого устройства создание пользователей не предусмотрено."
    fi
}

task_4_nat() {
    echo "[*] Задание 4, 8: Настройка NAT (nftables)..."
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
    echo "post-up nft -f /etc/nftables.conf" >> /etc/network/interfaces
    echo "  -> Конфигурация NAT создана и добавлена в interfaces."
}

task_4_vlan() {
    echo "[*] Задание 4: Настройка VLAN (Open vSwitch) на HQ-RTR..."
    if [ "$ROLE" != "HQ-RTR" ]; then echo "  -> Не для этого устройства."; return; fi
    apt update && apt install -y openvswitch-switch > /dev/null 2>&1
    systemctl enable --now openvswitch-switch > /dev/null 2>&1
    ovs-vsctl add-br hq-sw || true
    ovs-vsctl add-port hq-sw ens4 tag=100 || true
    ovs-vsctl add-port hq-sw ens5 tag=200 || true
    ovs-vsctl add-port hq-sw ens6 tag=999 || true
    ovs-vsctl add-port hq-sw vlan100 tag=100 -- set interface vlan100 type=internal || true
    ovs-vsctl add-port hq-sw vlan200 tag=200 -- set interface vlan200 type=internal || true
    ovs-vsctl add-port hq-sw vlan999 tag=999 -- set interface vlan999 type=internal || true
    
    sed -i 's/ens4/vlan100/g; s/ens5/vlan200/g; s/ens6/vlan999/g' /etc/network/interfaces
    echo "post-up ip link set hq-sw up" >> /etc/network/interfaces
    echo "  -> VLAN настроены. В interfaces заменены имена."
}

task_5_ssh() {
    echo "[*] Задание 5: Настройка SSH (порт 2027)..."
    if [[ "$ROLE" != "HQ-SRV" && "$ROLE" != "BR-SRV" ]]; then echo "  -> Не для этого устройства."; return; fi
    apt update && apt install -y openssh-server > /dev/null 2>&1
    sed -i 's/#Port 22/Port 2027/' /etc/ssh/sshd_config
    echo -e "\nAllowUsers sshuser\nMaxAuthTries 2\nBanner /etc/ssh_banner" >> /etc/ssh/sshd_config
    echo -e "*************************\n*                       *\n* Authorized access only *\n*                       *\n*************************" > /etc/ssh_banner
    systemctl restart ssh
    echo "  -> SSH настроен."
}

task_6_gre() {
    echo "[*] Задание 6: Настройка GRE туннеля..."
    if [ "$ROLE" == "HQ-RTR" ]; then
        cat << 'EOF' >> /etc/network/interfaces
auto gre0
iface gre0 inet static
    address 10.10.10.1/30
    pre-up ip tunnel add gre0 mode gre local 172.16.1.2 remote 172.16.2.2 ttl 64
    post-up ip link set gre0 up
    post-down ip tunnel del gre0
EOF
    elif [ "$ROLE" == "BR-RTR" ]; then
        cat << 'EOF' >> /etc/network/interfaces
auto gre0
iface gre0 inet static
    address 10.10.10.2/30
    pre-up ip tunnel add gre0 mode gre local 172.16.2.2 remote 172.16.1.2 ttl 64
    post-up ip link set gre0 up
    post-down ip tunnel del gre0
EOF
    else
        echo "  -> Не для этого устройства."; return
    fi
    echo "  -> GRE добавлен в interfaces."
}

task_7_ospf() {
    echo "[*] Задание 7: Установка и настройка FRR (OSPF)..."
    if [[ "$ROLE" != "HQ-RTR" && "$ROLE" != "BR-RTR" && "$ROLE" != "BR-FW" ]]; then echo "  -> Не для этого устройства."; return; fi
    apt update && apt install -y frr > /dev/null 2>&1
    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    
    if [ "$ROLE" == "HQ-RTR" ]; then
        vtysh -c "conf t" -c "int gre0" -c "ip ospf message-digest-key 1 md5 P@ssw0rd" -c "exit" \
              -c "router ospf" -c "router-id 1.1.1.1" -c "area 0 authentication message-digest" \
              -c "network 10.10.10.0/30 area 0" -c "network 192.168.100.0/27 area 0" \
              -c "network 192.168.200.0/28 area 0" -c "network 192.168.99.0/29 area 0" -c "exit" -c "wr"
    elif [ "$ROLE" == "BR-RTR" ]; then
        vtysh -c "conf t" -c "int gre0" -c "ip ospf message-digest-key 1 md5 P@ssw0rd" -c "exit" \
              -c "int ens4" -c "ip ospf message-digest-key 1 md5 P@ssw0rd" -c "exit" \
              -c "router ospf" -c "router-id 2.2.2.2" -c "area 0 authentication message-digest" \
              -c "network 10.10.10.0/30 area 0" -c "network 172.16.10.0/30 area 0" -c "exit" -c "wr"
    elif [ "$ROLE" == "BR-FW" ]; then
        vtysh -c "conf t" -c "int ens3" -c "ip ospf message-digest-key 1 md5 P@ssw0rd" -c "exit" \
              -c "router ospf" -c "router-id 3.3.3.3" -c "area 0 authentication message-digest" \
              -c "network 172.16.10.0/30 area 0" -c "network 172.16.20.0/28 area 0" -c "exit" -c "wr"
    fi
    systemctl enable --now frr
    echo "  -> OSPF настроен и запущен."
}

task_9_dhcp() {
    echo "[*] Задание 9: Настройка DHCP сервера..."
    if [ "$ROLE" != "HQ-RTR" ]; then echo "  -> Не для этого устройства."; return; fi
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
    echo "  -> DHCP настроен."
}

task_10_dns() {
    echo "[*] Задание 10: Настройка DNS (dnsmasq)..."
    if [ "$ROLE" != "HQ-SRV" ]; then echo "  -> Не для этого устройства."; return; fi
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
    echo "  -> DNS настроен."
}

task_10_clients() {
    echo "[*] Задание 10 (клиенты): Прописываем DNS 192.168.100.2..."
    if [[ "$ROLE" == "ISP" || "$ROLE" == "HQ-SRV" ]]; then echo "  -> Для ISP и HQ-SRV это не требуется."; return; fi
    rm -f /etc/resolv.conf
    echo "nameserver 192.168.100.2" > /etc/resolv.conf
    echo "  -> DNS клиента настроен."
}

# --- Главный цикл меню заданий ---
while true; do
    echo ""
    echo "======================================================"
    echo " УСТРОЙСТВО: $ROLE | ВЫБЕРИТЕ ЗАДАНИЕ ДЛЯ ВЫПОЛНЕНИЯ:"
    echo "======================================================"
    select TASK in \
        "1. Базовая настройка (репы, время, форвардинг)" \
        "2. Настройка сети (IP, интерфейсы)" \
        "3. Создание пользователей" \
        "4. Настройка NAT (nftables)" \
        "4. Настройка VLAN (только HQ-RTR)" \
        "5. Настройка SSH (только SRV)" \
        "6. Настройка GRE туннеля (RTR)" \
        "7. Настройка OSPF (FRR)" \
        "9. Настройка DHCP (HQ-RTR)" \
        "10. Настройка DNS (HQ-SRV)" \
        "10. Настройка DNS-клиента (остальные)" \
        "11. Перезагрузка (reboot)" \
        "Выход"; do
        case $TASK in
            "1. Базовая настройка (репы, время, форвардинг)" ) task_1_base; break;;
            "2. Настройка сети (IP, интерфейсы)" ) task_2_network; break;;
            "3. Создание пользователей" ) task_3_users; break;;
            "4. Настройка NAT (nftables)" ) task_4_nat; break;;
            "4. Настройка VLAN (только HQ-RTR)" ) task_4_vlan; break;;
            "5. Настройка SSH (только SRV)" ) task_5_ssh; break;;
            "6. Настройка GRE туннеля (RTR)" ) task_6_gre; break;;
            "7. Настройка OSPF (FRR)" ) task_7_ospf; break;;
            "9. Настройка DHCP (HQ-RTR)" ) task_9_dhcp; break;;
            "10. Настройка DNS (HQ-SRV)" ) task_10_dns; break;;
            "10. Настройка DNS-клиента (остальные)" ) task_10_clients; break;;
            "11. Перезагрузка (reboot)" ) echo "Перезагрузка..."; reboot;;
            "Выход" ) exit 0;;
        esac
    done
done