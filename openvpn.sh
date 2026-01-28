#!/bin/sh

# Configurações de Caminhos e Variáveis
OPENVPN_DIR="/etc/openvpn/server"
PKI_DIR="$OPENVPN_DIR/pki"
CLIENT_CONFIG_DIR="$HOME/ovpn-clients"
PACMAN_CONF="/etc/pacman.conf"

# Função para garantir privilégios de root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf "Erro: Este script precisa ser executado como root (sudo).\n"
        exit 1
    fi
}

# --- 1. INSTALAÇÃO E TRAVA DE VERSÃO ---
install_dependencies() {
    printf "\n>>> Instalando dependências e aplicando trava no pacman.conf...\n"
    pacman -Sy --needed --noconfirm openvpn openssl curl

    # Adiciona openvpn ao IgnorePkg para evitar quebras em atualizações futuras
    if ! grep -q "^IgnorePkg.*openvpn" "$PACMAN_CONF"; then
        sed -i 's/^#IgnorePkg/IgnorePkg/' "$PACMAN_CONF"
        sed -i '/^IgnorePkg/ s/$/ openvpn/' "$PACMAN_CONF"
        printf "[OK] OpenVPN travado para atualizações manuais.\n"
    fi
}

# --- 2. INFRAESTRUTURA SSL (PKI) ---
setup_pki() {
    printf "\n>>> Configurando a Infraestrutura de Chaves (PKI)...\n"
    mkdir -p "$PKI_DIR"
    
    # Ajuste de permissão: root é dono, grupo 'nobody' pode ler os certificados
    chown -R root:nobody "$PKI_DIR"
    chmod 750 "$PKI_DIR"
    
    cd "$PKI_DIR" || exit

    # Geração da CA e Certificados do Servidor
    openssl genrsa -out ca.key 4096
    openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -subj "/CN=VPN-CA"
    openssl genrsa -out server.key 2048
    openssl req -new -key server.key -out server.csr -subj "/CN=server"
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650
    openssl dhparam -out dh.pem 2048

    # Nova sintaxe OpenVPN 2.6+: 'secret' sem os traços '--'
    printf "Gerando chave TLS-Auth (ta.key)...\n"
    openvpn --genkey secret ta.key
    
    # Garante que os arquivos sejam legíveis pelo serviço OpenVPN
    chmod 640 "$PKI_DIR"/*
}

# --- 3. CONFIGURAÇÃO DO SERVIDOR ---
configure_server() {
    printf "\n>>> Gerando arquivo de configuração do servidor...\n"
    printf "Informe a porta UDP desejada (Padrão 1194): "
    read -r vpn_port
    vpn_port=${vpn_port:-1194}

    cat <<EOF > "$OPENVPN_DIR/server.conf"
port $vpn_port
proto udp
dev tun
ca $PKI_DIR/ca.crt
cert $PKI_DIR/server.crt
key $PKI_DIR/server.key
dh $PKI_DIR/dh.pem
tls-auth $PKI_DIR/ta.key 0
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
cipher AES-256-GCM
persist-key
persist-tun
user nobody
group nobody
# Status log no /run para evitar erros de permissão de escrita em /etc
status /run/openvpn-server-status.log
verb 3
explicit-exit-notify 1
plugin /usr/lib/openvpn/plugins/openvpn-plugin-auth-pam.so login
EOF

    # Habilitar IP Forwarding no Kernel
    echo 1 > /proc/sys/net/ipv4/ip_forward
    printf "net.ipv4.ip_forward=1\n" > /etc/sysctl.d/99-openvpn.conf
    sysctl -p /etc/sysctl.d/99-openvpn.conf
}

# --- 4. FIREWALL (IPTABLES) ---
setup_firewall() {
    printf "\n>>> Configurando regras de Firewall...\n"
    ext_if=$(ip route | grep default | awk '{print $5}')
    port=$(grep "^port" "$OPENVPN_DIR/server.conf" | awk '{print $2}')

    iptables -
