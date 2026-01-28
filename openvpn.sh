#!/bin/sh

# Configurações de Caminhos (Padrões Arch Linux)
OPENVPN_DIR="/etc/openvpn/server"
PKI_DIR="$OPENVPN_DIR/pki"
CLIENT_CONFIG_DIR="$HOME/ovpn-clients"
PACMAN_CONF="/etc/pacman.conf"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf "Erro: Requer privilégios de root (sudo).\n"
        exit 1
    fi
}

# --- 1. INSTALAÇÃO E LOCK DE VERSÃO ---
install_dependencies() {
    printf "\n>>> Instalando OpenVPN e OpenSSL...\n"
    pacman -Sy --needed --noconfirm openvpn openssl curl

    if ! grep -q "^IgnorePkg.*openvpn" "$PACMAN_CONF"; then
        printf ">>> Aplicando trava de atualização no pacman.conf...\n"
        sed -i 's/^#IgnorePkg/IgnorePkg/' "$PACMAN_CONF"
        sed -i '/^IgnorePkg/ s/$/ openvpn/' "$PACMAN_CONF"
    fi
}

# --- 2. INFRAESTRUTURA SSL (SOLUÇÃO DO ERRNO 13) ---
setup_pki() {
    printf "\n>>> Configurando PKI com padrões de segurança do Arch...\n"
    mkdir -p "$PKI_DIR"
    
    # O segredo: o grupo 'nobody' precisa de permissão 750 para acessar a pasta
    chown root:nobody "$PKI_DIR"
    chmod 750 "$PKI_DIR"
    
    cd "$PKI_DIR" || exit

    # Geração dos certificados via OpenSSL
    openssl genrsa -out ca.key 4096
    openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -subj "/CN=ArchVPN-CA"
    openssl genrsa -out server.key 2048
    openssl req -new -key server.key -out server.csr -subj "/CN=server"
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650
    openssl dhparam -out dh.pem 2048

    # Sintaxe OpenVPN 2.6+ (sem os traços iniciais em secret)
    openvpn --genkey secret ta.key
    
    # Garante que o grupo 'nobody' leia os arquivos (chmod 640)
    chmod 640 "$PKI_DIR"/*
}

# --- 3. CONFIGURAÇÃO DO SERVIDOR (CORREÇÃO DE HEREDOC) ---
configure_server() {
    printf "\n>>> Gerando server.conf...\n"
    printf "Porta UDP (Padrão 1194): "
    read -r vpn_port
    vpn_port=${vpn_port:-1194}

    # O EOF deve estar obrigatoriamente na coluna 0 (sem espaços antes)
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
cipher AES-256-GCM
persist-key
persist-tun
user nobody
group nobody
status /run/openvpn-status.log
verb 3
explicit-exit-notify 1
plugin /usr/lib/openvpn/plugins/openvpn-plugin-auth-pam.so login
EOF

    # Habilitar Forwarding conforme Arch Wiki
    echo 1 > /proc/sys/net/ipv4/ip_forward
    printf "net.ipv4.ip_forward=1\n" > /etc/sysctl.d/99-openvpn.conf
    sysctl -p /etc/sysctl.d/99-openvpn.conf
}

# --- 4. FIREWALL (IPTABLES) ---
setup_firewall() {
    printf "\n>>> Configurando regras de NAT e Firewall...\n"
    ext_if=$(ip route | grep default | awk '{print $5}')
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$ext_if" -j MASQUERADE
    iptables -I INPUT -p udp --dport "${vpn_port:-1194}" -j ACCEPT
}

# --- 5. GESTÃO DE USUÁRIO (SSL + PAM) ---
manage_user() {
    printf "\n>>> Nome do usuário VPN: "
    read -r username
    [ -z "$username" ] && return

    if ! id "$username" >/dev/null 2>&1; then
        useradd -M -s /usr/bin/nologin "$username"
        printf "Defina a SENHA para '$username' (usada no login PAM):\n"
        passwd "$username"
    fi

    cd "$PKI_DIR" || exit
    openssl genrsa -out "${username}.key" 2048
    openssl req -new -key "${username}.key" -out "${username}.csr" -subj "/CN=${username}"
    openssl x509 -req -in "${username}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -out "${username}.crt" -days 3650

    mkdir -p "$CLIENT_CONFIG_DIR"
    remote_ip=$(curl -s https://ifconfig.me)

cat <<EOF > "$CLIENT_CONFIG_DIR/${username}.ovpn"
client
dev tun
proto udp
remote $remote_ip ${vpn_port:-1194}
resolv-retry infinite
nobind
remote-cert-tls server
cipher AES-256-GCM
auth-user-pass
key-direction 1
<ca>
$(cat ca.crt)
</ca>
<cert>
$(cat "${username}.crt")
</cert>
<key>
$(cat "${username}.key")
</key>
<tls-auth>
$(cat ta.key)
</tls-auth>
EOF
    printf "\n[OK] Arquivo gerado: $CLIENT_CONFIG_DIR/${username}.ovpn\n"
}

# --- 6. REVERSÃO ---
revert_all() {
    printf "\nConfirmar limpeza total das configurações? (s/n): "
    read -r confirm
    if [ "$confirm" = "s" ]; then
        systemctl stop openvpn-server@server
        rm -rf "$PKI_DIR"
        rm -f "$OPENVPN_DIR/server.conf"
        sed -i '/^IgnorePkg/ s/ openvpn//' "$PACMAN_CONF"
        printf "Configurações removidas e pacman destravado.\n"
    fi
}

# --- MENU ---
check_root
while true; do
    printf "\n1) Instalação Completa\n2) Criar Usuário + SSL\n3) Reverter\n4) Sair\nOpção: "
    read -r opt
    case $opt in
        1) install_dependencies; setup_pki; configure_server; setup_firewall
           systemctl daemon-reload
           systemctl enable --now openvpn-server@server
           sleep 2
           if ! systemctl is-active --quiet openvpn-server@server; then
               printf "\n[ERRO] Serviço falhou. Logs:\n"
               journalctl -u openvpn-server@server --no-pager -n 20
           else
               printf "\n[SUCESSO] Servidor OpenVPN Ativo!\n"
           fi ;;
        2) manage_user ;;
        3) revert_all ;;
        4) exit 0 ;;
    esac
done
