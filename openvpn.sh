#!/bin/sh

# Configurações de Caminhos Oficiais (Arch Wiki)
OPENVPN_DIR="/etc/openvpn/server"
PKI_DIR="$OPENVPN_DIR/pki"
CLIENT_DIR="$HOME/ovpn-clients"
PACMAN_CONF="/etc/pacman.conf"

# Verificação de root
if [ "$(id -u)" -ne 0 ]; then
    printf "Erro: Requer privilégios de root (sudo).\n"
    exit 1
fi

# --- 1. INSTALAÇÃO E TRAVA NO PACMAN ---
setup_dependencies() {
    printf "\n>>> Instalando OpenVPN e OpenSSL...\n"
    pacman -Sy --needed --noconfirm openvpn openssl curl

    if ! grep -q "^IgnorePkg.*openvpn" "$PACMAN_CONF"; then
        printf ">>> Aplicando IgnorePkg para o OpenVPN no pacman.conf...\n"
        sed -i 's/^#IgnorePkg/IgnorePkg/' "$PACMAN_CONF"
        sed -i "/^IgnorePkg/ s/$/ openvpn/" "$PACMAN_CONF"
    fi
}

# --- 2. PKI E PERMISSÕES (SOLUÇÃO DO ERRNO 13) ---
setup_pki() {
    printf "\n>>> Configurando PKI e Permissões de Sistema...\n"
    mkdir -p "$PKI_DIR"
    
    # AJUSTE CRUCIAL: O grupo 'nobody' precisa entrar na pasta e ler os arquivos
    chown root:nobody "$PKI_DIR"
    chmod 750 "$PKI_DIR"

    cd "$PKI_DIR" || exit
    openssl genrsa -out ca.key 4096
    openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -subj "/CN=ArchVPN-CA"
    openssl genrsa -out server.key 2048
    openssl req -new -key server.key -out server.csr -subj "/CN=server"
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650
    openssl dhparam -out dh.pem 2048

    # CORREÇÃO: Sintaxe OpenVPN 2.6+ (sem os traços iniciais em secret)
    openvpn --genkey secret ta.key
    
    # Permite leitura apenas para root e grupo nobody
    chmod 640 "$PKI_DIR"/*
}

# --- 3. CONFIGURAÇÃO (CORREÇÃO DE HEREDOC/EOF) ---
configure_server() {
    printf "\n>>> Gerando server.conf...\n"
    printf "Porta UDP (Padrão 1194): "
    read -r port
    port=${port:-1194}

# Nota: O delimitador EOF abaixo DEVE estar na margem esquerda (coluna 0)
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
    printf "\n>>> Configurando NAT e Firewall...\n"
    ext_if=$(ip route | grep default | awk '{print $5}')
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$ext_if" -j MASQUERADE
    iptables -I INPUT -p udp --dport "${port:-1194}" -j ACCEPT
}

# --- 5. GESTÃO DE USUÁRIO (SSL + PAM) ---
manage_user() {
    printf "\n>>> Nome do usuário VPN: "
    read -r user
    [ -z "$user" ] && return

    if ! id "$user" >/dev/null 2>&1; then
        useradd -M -s /usr/bin/nologin "$user"
        printf "Defina a senha para '$user' (PAM auth):\n"
        passwd "$user"
    fi

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
    printf "\n1) Instalação Completa\n2) Criar Usuário + SSL\n3) Reverter\n4) Sair\nEscolha: "
    read -r opt
    case $opt in
        1) setup_dependencies; setup_pki; configure_server; setup_firewall
           systemctl daemon-reload
           systemctl enable --now openvpn-server@server
           sleep 2
           if ! systemctl is-active --quiet openvpn-server@server; then
               printf "\n[ERRO] Falha crítica. Exibindo log real:\n"
               journalctl -u openvpn-server@server --no-pager -n 20
           else
               printf "\n[SUCESSO] Servidor OpenVPN em execução!\n"
           fi ;;
        2) manage_user ;;
        3) systemctl stop openvpn-server@server; rm -rf "$PKI_DIR"; sed -i '/^IgnorePkg/ s/ openvpn//' "$PACMAN_CONF"; printf "Limpeza concluída.\n" ;;
        4) exit 0 ;;
    esac
done
