#!/bin/sh

# Configurações de Caminhos (Padrão Arch Linux)
OVPN_DIR="/etc/openvpn/server"
PKI_DIR="$OVPN_DIR/pki"
CLIENT_DIR="$HOME/ovpn-clients"
PACMAN_CONF="/etc/pacman.conf"

# Função para verificar root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf "Erro: Execute este script como root (sudo).\n"
        exit 1
    fi
}

# --- 1. INSTALAÇÃO E TRAVA NO PACMAN ---
install_pkgs() {
    printf "\n>>> Instalando OpenVPN e OpenSSL...\n"
    pacman -Sy --needed --noconfirm openvpn openssl curl

    if ! grep -q "^IgnorePkg.*openvpn" "$PACMAN_CONF"; then
        printf ">>> Travando versão do OpenVPN no pacman.conf...\n"
        sed -i 's/^#IgnorePkg/IgnorePkg/' "$PACMAN_CONF"
        sed -i '/^IgnorePkg/ s/$/ openvpn/' "$PACMAN_CONF"
    fi
}

# --- 2. INFRAESTRUTURA SSL (CORREÇÃO DE PERMISSÕES) ---
setup_pki() {
    printf "\n>>> Configurando a PKI (SSL)...\n"
    mkdir -p "$PKI_DIR"
    # O segredo do erro 13: o usuário 'nobody' precisa de permissão de leitura e execução na pasta
    chown -R root:nobody "$PKI_DIR"
    chmod 750 "$PKI_DIR"

    cd "$PKI_DIR" || exit

    # Geração dos certificados
    openssl genrsa -out ca.key 4096
    openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -subj "/CN=Arch-VPN-CA"
    openssl genrsa -out server.key 2048
    openssl req -new -key server.key -out server.csr -subj "/CN=server"
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650
    openssl dhparam -out dh.pem 2048

    # Correção da sintaxe para OpenVPN 2.6+
    openvpn --genkey secret ta.key
    
    # Garante que o grupo nobody consiga ler os arquivos gerados
    chmod 640 "$PKI_DIR"/*
}

# --- 3. CONFIGURAÇÃO DO SERVIDOR ---
configure_server() {
    printf "\n>>> Gerando arquivo de configuração...\n"
    printf "Defina a porta UDP (Padrão 1194): "
    read -r port
    port=${port:-1194}

    # Bloco de configuração (Heredoc corrigido sem espaços na margem)
cat <<EOF > "$OVPN_DIR/server.conf"
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

    # Ativar roteamento no kernel
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

# --- 5. CRIAÇÃO INTERATIVA DE USUÁRIO + CERTIFICADO ---
create_user() {
    printf "\n>>> Nome do usuário VPN: "
    read -r username
    [ -z "$username" ] && return

    # Adiciona usuário ao sistema (PAM)
    if ! id "$username" >/dev/null 2>&1; then
        useradd -M -s /usr/bin/nologin "$username"
        printf "Defina a SENHA para o usuário '$username':\n"
        passwd "$username"
    fi

    # Gera certificados do cliente
    cd "$PKI_DIR" || exit
    openssl genrsa -out "${username}.key" 2048
    openssl req -new -key "${username}.key" -out "${username}.csr" -subj "/CN=${username}"
    openssl x509 -req -in "${username}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -out "${username}.crt" -days 3650

    # Gera arquivo .ovpn final
    mkdir -p "$CLIENT_DIR"
    remote_ip=$(curl -s https://ifconfig.me)

cat <<EOF > "$CLIENT_DIR/${username}.ovpn"
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
    printf "\n[SUCESSO] Arquivo gerado em: $CLIENT_DIR/${username}.ovpn\n"
}

# --- 6. REVERSÃO ---
revert() {
    printf "\nRemover TUDO (menos binários)? (s/n): "
    read -r confirm
    if [ "$confirm" = "s" ]; then
        systemctl stop openvpn-server@server
        rm -rf "$PKI_DIR"
        rm -f "$OVPN_DIR/server.conf"
        rm -f /etc/sysctl.d/99-openvpn.conf
        sed -i '/^IgnorePkg/ s/ openvpn//' "$PACMAN_CONF"
        printf "Configurações e certificados removidos.\n"
    fi
}

# --- MENU ---
check_root
while true; do
    printf "\n1) Instalação Completa (Server)\n2) Criar Usuário + SSL (Interativo)\n3) Reverter Configurações\n4) Sair\nOpção: "
    read -r opt
    case $opt in
        1) install_pkgs; setup_pki; configure_server; setup_firewall
           systemctl daemon-reload
           systemctl enable --now openvpn-server@server
           sleep 2
           if ! systemctl is-active --quiet openvpn-server@server; then
               printf "\n[ERRO] O serviço falhou. Verifique: journalctl -u openvpn-server@server\n"
           else
               printf "\n[PRONTO] Servidor rodando com sucesso!\n"
           fi ;;
        2) create_user ;;
        3) revert ;;
        4) exit 0 ;;
    esac
done
