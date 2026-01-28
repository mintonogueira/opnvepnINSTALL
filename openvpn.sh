#!/bin/sh

# Caminhos e Variáveis
OPENVPN_DIR="/etc/openvpn/server"
PKI_DIR="$OPENVPN_DIR/pki"
CLIENT_DIR="$HOME/ovpn-clients"
PACMAN_CONF="/etc/pacman.conf"

# 1. Verificação de Privilégios
if [ "$(id -u)" -ne 0 ]; then
    printf "Erro: Execute este script como root (sudo).\n"
    exit 1
fi

# --- FUNÇÃO DE INSTALAÇÃO E TRAVA ---
setup_dependencies() {
    printf "\n>>> Instalando dependências e travando atualizações...\n"
    pacman -Sy --needed --noconfirm openvpn openssl curl

    # Garante que o OpenVPN não seja atualizado automaticamente para evitar quebras
    if ! grep -q "^IgnorePkg.*openvpn" "$PACMAN_CONF"; then
        sed -i 's/^#IgnorePkg/IgnorePkg/' "$PACMAN_CONF"
        sed -i "/^IgnorePkg/ s/$/ openvpn/" "$PACMAN_CONF"
        printf "[OK] Atualização do OpenVPN travada no pacman.conf.\n"
    fi
}

# --- FUNÇÃO DE PKI (SSL) ---
setup_pki() {
    printf "\n>>> Configurando a PKI (Permissões 750 para o usuário 'nobody')...\n"
    # Recria o diretório para garantir limpeza
    rm -rf "$PKI_DIR"
    mkdir -p "$PKI_DIR"
    chown root:nobody "$PKI_DIR"
    chmod 750 "$PKI_DIR"

    cd "$PKI_DIR" || exit

    # Geração dos Certificados
    openssl genrsa -out ca.key 4096
    openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -subj "/CN=ArchVPN-CA"
    openssl genrsa -out server.key 2048
    openssl req -new -key server.key -out server.csr -subj "/CN=server"
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650
    openssl dhparam -out dh.pem 2048

    # Sintaxe OpenVPN 2.6+
    openvpn --genkey secret ta.key
    chmod 640 "$PKI_DIR"/*
}

# --- FUNÇÃO DE CONFIGURAÇÃO (REESCREVE ARQUIVOS) ---
configure_server() {
    printf "\n>>> Reescrevendo arquivos de configuração...\n"
    printf "Porta UDP (Padrão 1194): "
    read -r port
    port=${port:-1194}

# Heredoc alinhado à esquerda para evitar erros de sintaxe
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

    # IPv4 Forwarding (Reescreve o arquivo de sysctl)
    printf "net.ipv4.ip_forward=1\n" > /etc/sysctl.d/99-openvpn.conf
    sysctl -p /etc/sysctl.d/99-openvpn.conf
}

# --- FUNÇÃO DE FIREWALL ---
setup_firewall() {
    printf "\n>>> Configurando NAT e Firewall (iptables)...\n"
    ext_if=$(ip route | grep default | awk '{print $5}')
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$ext_if" -j MASQUERADE
    iptables -I INPUT -p udp --dport "${port:-1194}" -j ACCEPT
}

# --- GESTÃO INTERATIVA DE USUÁRIOS ---
manage_user() {
    printf "\n>>> Nome do usuário VPN: "
    read -r username
    [ -z "$username" ] && return

    # PAM: Cria usuário de sistema sem acesso ao shell
    if ! id "$username" >/dev/null 2>&1; then
        useradd -M -s /usr/bin/nologin "$username"
        printf "Defina a SENHA para '$username' (usada no login):\n"
        passwd "$username"
    fi

    # SSL: Gera chaves do cliente
    cd "$PKI_DIR" || exit
    openssl genrsa -out "${username}.key" 2048
    openssl req -new -key "${username}.key" -out "${username}.csr" -subj "/CN=${username}"
    openssl x509 -req -in "${username}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -out "${username}.crt" -days 3650

    # Gera arquivo .ovpn reescrevendo o anterior se existir
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
    printf "\n[OK] Cliente pronto: $CLIENT_DIR/${username}.ovpn\n"
}

# --- REVERSÃO ---
revert() {
    printf "\nRemover certificados e configurações? (s/n): "
    read -r confirm
    if [ "$confirm" = "s" ]; then
        systemctl stop openvpn-server@server
        rm -rf "$PKI_DIR"
        rm -f "$OPENVPN_DIR/server.conf"
        sed -i '/^IgnorePkg/ s/ openvpn//' "$PACMAN_CONF"
        printf "Limpeza concluída. Pacman destravado.\n"
    fi
}

# --- MENU ---
while true; do
    printf "\n1) Instalação Completa (Reescrever Tudo)\n2) Gerar Usuário (SSL + Senha)\n3) Reverter Configurações\n4) Sair\nEscolha: "
    read -r opt
    case $opt in
        1) setup_dependencies; setup_pki; configure_server; setup_firewall
           systemctl daemon-reload
           systemctl enable --now openvpn-server@server
           sleep 2
           if ! systemctl is-active --quiet openvpn-server@server; then
               printf "\n[ERRO] Falha ao iniciar. Logs:\n"
               journalctl -u openvpn-server@server --no-pager -n 10
           else
               printf "\n[SUCESSO] Servidor pronto para uso!\n"
           fi ;;
        2) manage_user ;;
        3) revert ;;
        4) exit 0 ;;
    esac
done
