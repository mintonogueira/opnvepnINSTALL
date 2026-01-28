#!/bin/sh

# Caminhos Oficiais (Arch Wiki)
OPENVPN_DIR="/etc/openvpn/server"
PKI_DIR="$OPENVPN_DIR/pki"
CLIENT_DIR="$HOME/ovpn-clients"
PACMAN_CONF="/etc/pacman.conf"

# Verificação de privilégios
if [ "$(id -u)" -ne 0 ]; then
    printf "Erro: Este script deve ser executado como root (sudo).\n"
    exit 1
fi

# --- 1. DEPENDÊNCIAS E TRAVA (PACMAN.CONF) ---
setup_dependencies() {
    printf "\n>>> Instalando OpenVPN e OpenSSL...\n"
    pacman -Sy --needed --noconfirm openvpn openssl curl

    if ! grep -q "^IgnorePkg.*openvpn" "$PACMAN_CONF"; then
        printf ">>> Aplicando trava de atualização (IgnorePkg) no pacman.conf...\n"
        sed -i 's/^#IgnorePkg/IgnorePkg/' "$PACMAN_CONF"
        sed -i '/^IgnorePkg/ s/$/ openvpn/' "$PACMAN_CONF"
    fi
}

# --- 2. INFRAESTRUTURA SSL (CONFORME OPENSSL/OVPN COMMUNITY) ---
setup_pki() {
    printf "\n>>> Configurando PKI e Permissões de Sistema...\n"
    
    # Criar pasta e ajustar permissões para que o grupo 'nobody' possa entrar (750)
    mkdir -p "$PKI_DIR"
    chown root:nobody "$PKI_DIR"
    chmod 750 "$PKI_DIR"

    cd "$PKI_DIR" || exit

    # Gerar CA, Certificado e Chave do Servidor
    openssl genrsa -out ca.key 4096
    openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -subj "/CN=ArchVPN-CA"
    openssl genrsa -out server.key 2048
    openssl req -new -key server.key -out server.csr -subj "/CN=server"
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650
    openssl dhparam -out dh.pem 2048

    # Gerar chave TLS-Auth (Sintaxe OpenVPN 2.6+)
    openvpn --genkey secret ta.key
    
    # Ajustar arquivos para leitura pelo grupo 'nobody' (640)
    chmod 640 "$PKI_DIR"/*
}

# --- 3. CONFIGURAÇÃO DO SERVIDOR (CONFORME ARCH WIKI) ---
configure_server() {
    printf "\n>>> Gerando server.conf (PAM + SSL)...\n"
    printf "Informe a porta UDP desejada (Padrão 1194): "
    read -r vpn_port
    vpn_port=${vpn_port:-1194}

# Nota: O EOF deve estar obrigatoriamente na margem esquerda (coluna 0)
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
# Plugin PAM para autenticação de usuário do Arch Linux
plugin /usr/lib/openvpn/plugins/openvpn-plugin-auth-pam.so login
EOF

    # Ativar IP Forwarding
    printf "net.ipv4.ip_forward=1\n" > /etc/sysctl.d/99-openvpn.conf
    sysctl -p /etc/sysctl.d/99-openvpn.conf
}

# --- 4. FIREWALL (IPTABLES - ARCH WIKI) ---
setup_firewall() {
    printf "\n>>> Configurando Firewall e NAT...\n"
    ext_if=$(ip route | grep default | awk '{print $5}')
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$ext_if" -j MASQUERADE
    iptables -I INPUT -p udp --dport "${vpn_port:-1194}" -j ACCEPT
}

# --- 5. GESTÃO DE USUÁRIO (SSL + SISTEMA) ---
manage_user() {
    printf "\n>>> Nome do usuário para a VPN: "
    read -r username
    [ -z "$username" ] && return

    # Criar usuário sem shell para autenticação PAM
    if ! id "$username" >/dev/null 2>&1; then
        useradd -M -s /usr/bin/nologin "$username"
        printf "Defina a senha para o login VPN de '$username':\n"
        passwd "$username"
    fi

    cd "$PKI_DIR" || exit
    openssl genrsa -out "${username}.key" 2048
    openssl req -new -key "${username}.key" -out "${username}.csr" -subj "/CN=${username}"
    openssl x509 -req -in "${username}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -out "${username}.crt" -days 3650

    mkdir -p "$CLIENT_DIR"
    remote_ip=$(curl -s https://ifconfig.me)

cat <<EOF > "$CLIENT_DIR/${username}.ovpn"
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
verb 3
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
    printf "\n[PRONTO] Arquivo gerado: $CLIENT_DIR/${username}.ovpn\n"
}

# --- MENU PRINCIPAL ---
while true; do
    printf "\n==========================================\n"
    printf "   OPENVPN MANAGER (ARCH/COMMUNITY)\n"
    printf "==========================================\n"
    printf "1) Instalação Completa (Servidor + Firewall)\n"
    printf "2) Criar Usuário VPN (SSL + Senha)\n"
    printf "3) Reverter Tudo (Limpar Chaves e Conf)\n"
    printf "4) Sair\n"
    printf "Escolha uma opção: "
    read -r opt

    case $opt in
        1) 
            setup_dependencies; setup_pki; configure_server; setup_firewall
            systemctl daemon-reload
            systemctl enable --now openvpn-server@server
            sleep 2
            if ! systemctl is-active --quiet openvpn-server@server; then
                printf "\n[ERRO] Serviço falhou. Verificando logs:\n"
                journalctl -u openvpn-server@server --no-pager -n 20
            else
                printf "\n[SUCESSO] Servidor OpenVPN ativo!\n"
            fi
            ;;
        2) manage_user ;;
        3) 
            systemctl stop openvpn-server@server
            rm -rf "$PKI_DIR"
            rm -f "$OPENVPN_DIR/server.conf"
            sed -i '/^IgnorePkg/ s/ openvpn//' "$PACMAN_CONF"
            printf "Reversão concluída.\n"
            ;;
        4) exit 0 ;;
    esac
done
