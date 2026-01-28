#!/bin/sh

# Configurações de Caminhos
OPENVPN_DIR="/etc/openvpn/server"
PKI_DIR="$OPENVPN_DIR/pki"
CLIENT_CONFIG_DIR="$HOME/ovpn-clients"
PACMAN_CONF="/etc/pacman.conf"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf "Erro: Este script exige privilégios de root.\n"
        exit 1
    fi
}

# --- 1. INSTALAÇÃO E TRAVA DE VERSÃO ---
install_deps() {
    printf "\n>>> Instalando OpenVPN e OpenSSL...\n"
    pacman -Sy --needed --noconfirm openvpn openssl curl

    # Adiciona a trava no pacman.conf se não existir
    if ! grep -q "^IgnorePkg.*openvpn" "$PACMAN_CONF"; then
        printf ">>> Aplicando trava de atualização para o OpenVPN no pacman.conf...\n"
        # Remove o comentário da linha IgnorePkg se estiver comentada
        sed -i 's/^#IgnorePkg/IgnorePkg/' "$PACMAN_CONF"
        # Adiciona o openvpn à lista de ignorados
        sed -i '/^IgnorePkg/ s/$/ openvpn/' "$PACMAN_CONF"
    fi
}

# --- 2. INFRAESTRUTURA SSL ---
setup_pki() {
    printf "\n>>> Configurando a PKI...\n"
    mkdir -p "$PKI_DIR" && chmod 700 "$PKI_DIR"
    cd "$PKI_DIR" || exit

    openssl genrsa -out ca.key 4096
    openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -subj "/CN=VPN-CA"
    openssl genrsa -out server.key 2048
    openssl req -new -key server.key -out server.csr -subj "/CN=server"
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650
    openssl dhparam -out dh.pem 2048

    printf "Gerando chave TLS-Auth (ta.key)...\n"
    openvpn --genkey secret ta.key
}

# --- 3. CONFIGURAÇÃO DO SERVIDOR ---
configure_server() {
    printf "\n>>> Gerando server.conf...\n"
    printf "Informe a porta UDP (Padrão 1194): "
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
cipher AES-256-GCM
persist-key
persist-tun
user nobody
group nobody
verb 3
plugin /usr/lib/openvpn/plugins/openvpn-plugin-auth-pam.so login
EOF

    echo 1 > /proc/sys/net/ipv4/ip_forward
    printf "net.ipv4.ip_forward=1\n" > /etc/sysctl.d/99-openvpn.conf
}

# --- 4. FIREWALL ---
setup_firewall() {
    printf "\n>>> Configurando Firewall...\n"
    ext_if=$(ip route | grep default | awk '{print $5}')
    port=$(grep "^port" "$OPENVPN_DIR/server.conf" | awk '{print $2}')

    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$ext_if" -j MASQUERADE
    iptables -I INPUT -p udp --dport "${port:-1194}" -j ACCEPT
}

# --- 5. OPÇÃO ESPECÍFICA: USUÁRIO + CERTIFICADO ---
manage_user() {
    printf "\n>>> Nome do novo usuário VPN: "
    read -r username
    [ -z "$username" ] && return

    if ! id "$username" >/dev/null 2>&1; then
        useradd -M -s /usr/bin/nologin "$username"
        printf "Defina a SENHA para o usuário '$username':\n"
        passwd "$username"
    fi

    cd "$PKI_DIR" || exit
    openssl genrsa -out "${username}.key" 2048
    openssl req -new -key "${username}.key" -out "${username}.csr" -subj "/CN=${username}"
    openssl x509 -req -in "${username}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -out "${username}.crt" -days 3650

    mkdir -p "$CLIENT_CONFIG_DIR"
    remote_ip=$(curl -s https://ifconfig.me)
    port=$(grep "^port" "$OPENVPN_DIR/server.conf" | awk '{print $2}')

    cat <<EOF > "$CLIENT_CONFIG_DIR/${username}.ovpn"
client
dev tun
proto udp
remote $remote_ip ${port:-1194}
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
    printf "\nArquivo gerado em: $CLIENT_CONFIG_DIR/${username}.ovpn\n"
}

# --- 6. REVERSÃO ---
revert() {
    printf "\nDeseja reverter as configurações (limpar PKI, conf e destravar pacman)? (s/n): "
    read -r confirm
    if [ "$confirm" = "s" ]; then
        systemctl stop openvpn-server@server
        rm -rf "$PKI_DIR"
        rm -f "$OPENVPN_DIR/server.conf"
        rm -f /etc/sysctl.d/99-openvpn.conf
        
        # Remove o openvpn do IgnorePkg no pacman.conf
        sed -i '/^IgnorePkg/ s/ openvpn//' "$PACMAN_CONF"
        
        printf "Reversão concluída. O OpenVPN foi destravado no pacman.\n"
    fi
}

# --- MENU PRINCIPAL ---
check_root
while true; do
    printf "\n1) Instalação Completa (Instala + Trava Pacman + Configura)\n"
    printf "2) Criar Usuário + Gerar Certificados\n"
    printf "3) Reverter Configurações\n"
    printf "4) Sair\n"
    printf "Escolha: "
    read -r opt
    case $opt in
        1) 
            install_deps; setup_pki; configure_server; setup_firewall
            systemctl enable --now openvpn-server@server
            printf "\n>>> Servidor pronto e protegido contra atualizações automáticas.\n"
            ;;
        2) manage_user ;;
        3) revert ;;
        4) exit 0 ;;
    esac
done
