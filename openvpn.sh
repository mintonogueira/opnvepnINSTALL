#!/bin/sh

# Caminhos Oficiais (Arch Linux)
OPENVPN_DIR="/etc/openvpn/server"
PKI_DIR="$OPENVPN_DIR/pki"
CLIENT_DIR="$HOME/ovpn-clients"
PACMAN_CONF="/etc/pacman.conf"

# Verificação de privilégios
if [ "$(id -u)" -ne 0 ]; then
    printf "Erro: Este script deve ser executado como root (sudo).\n"
    exit 1
fi

# --- 1. INSTALAÇÃO E TRAVA (PACMAN.CONF) ---
setup_deps() {
    printf "\n>>> Instalando OpenVPN e OpenSSL...\n"
    pacman -Sy --needed --noconfirm openvpn openssl curl

    if ! grep -q "^IgnorePkg.*openvpn" "$PACMAN_CONF"; then
        printf ">>> Travando atualizações do OpenVPN no pacman.conf...\n"
        sed -i 's/^#IgnorePkg/IgnorePkg/' "$PACMAN_CONF"
        sed -i "/^IgnorePkg/ s/$/ openvpn/" "$PACMAN_CONF"
    fi
}

# --- 2. INFRAESTRUTURA SSL (CORREÇÃO DE PERMISSÕES) ---
setup_pki() {
    printf "\n>>> Configurando PKI com permissões para o usuário 'nobody'...\n"
    mkdir -p "$PKI_DIR"
    
    # O segredo: o grupo 'nobody' precisa entrar e ler a pasta
    chown root:nobody "$PKI_DIR"
    chmod 750 "$PKI_DIR"

    cd "$PKI_DIR" || exit

    openssl genrsa -out ca.key 4096
    openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -subj "/CN=ArchVPN-CA"
    openssl genrsa -out server.key 2048
    openssl req -new -key server.key -out server.csr -subj "/CN=server"
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650
    openssl dhparam -out dh.pem 2048

    # Sintaxe OpenVPN 2.6+ (sem '--' antes de secret)
    openvpn --genkey secret ta.key
    
    # Garante que os arquivos sejam legíveis pelo grupo nobody
    chmod 640 "$PKI_DIR"/*
}

# --- 3. CONFIGURAÇÃO DO SERVIDOR (CORREÇÃO DE HEREDOC) ---
setup_config() {
    printf "\n>>> Gerando server.conf...\n"
    printf "Porta UDP (1194): "
    read -r port
    port=${port:-1194}

# O delimitador 'EOF' abaixo DEVE estar na margem esquerda (coluna 0)
cat <<EOF > "$OPENVPN_DIR/server.conf"
port $port
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

    echo 1 > /proc/sys/net/ipv4/ip_forward
    printf "net.ipv4.ip_forward=1\n" > /etc/sysctl.d/99-openvpn.conf
    sysctl -p /etc/sysctl.d/99-openvpn.conf
}

# --- 4. FIREWALL (IPTABLES) ---
setup_firewall() {
    printf "\n>>> Configurando Firewall...\n"
    ext_if=$(ip route | grep default | awk '{print $5}')
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$ext_if" -j MASQUERADE
    iptables -I INPUT -p udp --dport "${port:-1194}" -j ACCEPT
}

# --- 5. GESTÃO DE USUÁRIOS (SSL + SENHA) ---
create_user() {
    printf "\n>>> Nome do usuário: "
    read -r user
    [ -z "$user" ] && return

    # Criação do usuário para PAM
    if ! id "$user" >/dev/null 2>&1; then
        useradd -M -s /usr/bin/nologin "$user"
        printf "Defina a senha para '$user':\n"
        passwd "$user"
    fi

    # Certificados
    cd "$PKI_DIR" || exit
    openssl genrsa -out "${user}.key" 2048
    openssl req -new -key "${user}.key" -out "${user}.csr" -subj "/CN=${user}"
    openssl x509 -req -in "${user}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -out "${user}.crt" -days 3650

    mkdir -p "$CLIENT_DIR"
    ip=$(curl -s https://ifconfig.me)

cat <<EOF > "$CLIENT_DIR/${user}.ovpn"
client
dev tun
proto udp
remote $ip ${port:-1194}
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
$(cat "${user}.crt")
</cert>
<key>
$(cat "${user}.key")
</key>
<tls-auth>
$(cat ta.key)
</tls-auth>
EOF
    printf "\n[OK] Arquivo gerado: $CLIENT_DIR/${user}.ovpn\n"
}

# --- MENU ---
while true; do
    printf "\n1) Instalação Completa\n2) Criar Usuário + SSL\n3) Reverter\n4) Sair\nOpção: "
    read -r opt
    case $opt in
        1) setup_deps; setup_pki; setup_config; setup_firewall
           systemctl daemon-reload
           systemctl enable --now openvpn-server@server
           sleep 2
           if ! systemctl is-active --quiet openvpn-server@server; then
               printf "\n[ERRO] Falha ao iniciar. Logs:\n"
               journalctl -u openvpn-server@server --no-pager -n 20
           else
               printf "\n[SUCESSO] Servidor OpenVPN Ativo!\n"
           fi ;;
        2) create_user ;;
        3) systemctl stop openvpn-server@server; rm -rf "$PKI_DIR"; sed -i '/^IgnorePkg/ s/ openvpn//' "$PACMAN_CONF"; printf "Limpeza concluída.\n" ;;
        4) exit 0 ;;
    esac
done
