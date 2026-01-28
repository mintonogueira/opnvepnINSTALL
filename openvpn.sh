#!/bin/sh

# Caminhos e Configurações
OVPN_PATH="/etc/openvpn/server"
PKI_PATH="$OVPN_PATH/pki"
CLIENT_EXPORT_DIR="$HOME/vpn-clients"

# Função para garantir permissão de root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf "Erro: Execute este script como root (sudo).\n"
        exit 1
    fi
}

# --- 1. INSTALAÇÃO E DEPENDÊNCIAS ---
install_base() {
    printf "\n>>> Instalando OpenVPN e OpenSSL...\n"
    pacman -Sy --needed --noconfirm openvpn openssl curl
}

# --- 2. CONFIGURAÇÃO DO SERVIDOR (PKI E INFRAESTRUTURA) ---
setup_server_infra() {
    printf "\n>>> Iniciando configuração do Servidor e PKI...\n"
    
    mkdir -p "$PKI_PATH" && chmod 700 "$PKI_PATH"
    cd "$PKI_PATH"

    # Geração da CA e Chaves do Servidor
    printf "Gerando Autoridade de Certificação (CA)...\n"
    openssl genrsa -out ca.key 4096
    openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -subj "/CN=VPN-CA"

    printf "Gerando Chave e Certificado do Servidor...\n"
    openssl genrsa -out server.key 2048
    openssl req -new -key server.key -out server.csr -subj "/CN=server"
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650

    printf "Gerando Parâmetros Diffie-Hellman e TLS-Auth...\n"
    openssl dhparam -out dh.pem 2048
    openvpn --genkey --secret ta.key

    # Configuração do arquivo server.conf
    printf "Defina a porta UDP para a VPN (Padrão 1194): "
    read -r vpn_port
    vpn_port=${vpn_port:-1194}

    cat <<EOF > "$OVPN_PATH/server.conf"
port $vpn_port
proto udp
dev tun
ca $PKI_PATH/ca.crt
cert $PKI_PATH/server.crt
key $PKI_PATH/server.key
dh $PKI_PATH/dh.pem
tls-auth $PKI_PATH/ta.key 0
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
cipher AES-256-GCM
persist-key
persist-tun
user nobody
group nobody
status openvpn-status.log
verb 3
plugin /usr/lib/openvpn/plugins/openvpn-plugin-auth-pam.so login
EOF

    # Ativar Forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward
    printf "net.ipv4.ip_forward=1\n" > /etc/sysctl.d/99-openvpn.conf
}

# --- 3. FIREWALL ---
setup_firewall() {
    printf "\n>>> Configurando Firewall (iptables)...\n"
    # Captura a porta do server.conf se já existir
    current_port=$(grep "^port" "$OVPN_PATH/server.conf" | awk '{print $2}')
    ext_if=$(ip route | grep default | awk '{print $5}')

    iptables -I INPUT -p udp --dport "${current_port:-1194}" -j ACCEPT
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$ext_if" -j MASQUERADE
    
    printf "Portas liberadas e NAT configurado na interface $ext_if.\n"
}

# --- 4. OPÇÃO ESPECÍFICA: CRIAÇÃO DE USUÁRIO + CERTIFICADO ---
manage_user_and_certs() {
    printf "\n--- GESTÃO INTERATIVA DE USUÁRIO ---\n"
    printf "Digite o nome do novo usuário VPN: "
    read -r username

    if [ -z "$username" ]; then
        printf "Nome inválido.\n"
        return
    fi

    # Parte 1: Usuário e Senha no Sistema (PAM)
    if id "$username" >/dev/null 2>&1; then
        printf "Usuário '$username' já existe. Deseja atualizar a senha? (s/n): "
        read -r change_pw
        if [ "$change_pw" = "s" ]; then passwd "$username"; fi
    else
        printf "Criando usuário de sistema (sem acesso ao shell por segurança)...\n"
        useradd -M -s /usr/bin/nologin "$username"
        printf "Defina a senha para '$username':\n"
        passwd "$username"
    fi

    # Parte 2: Certificados SSL
    printf "Gerando certificados SSL para '$username'...\n"
    cd "$PKI_PATH" || exit
    openssl genrsa -out "${username}.key" 2048
    openssl req -new -key "${username}.key" -out "${username}.csr" -subj "/CN=${username}"
    openssl x509 -req -in "${username}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -out "${username}.crt" -days 3650

    # Parte 3: Geração do arquivo .ovpn
    mkdir -p "$CLIENT_EXPORT_DIR"
    remote_ip=$(curl -s https://ifconfig.me)
    port=$(grep "^port" "$OVPN_PATH/server.conf" | awk '{print $2}')

    cat <<EOF > "$CLIENT_EXPORT_DIR/${username}.ovpn"
client
dev tun
proto udp
remote $remote_ip ${port:-1194}
resolv-retry infinite
nobind
persist-key
persist-tun
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
    printf "\n[SUCESSO] Usuário criado e certificado gerado!\n"
    printf "Arquivo de configuração: $CLIENT_EXPORT_DIR/${username}.ovpn\n"
}

# --- 5. REVERSÃO ---
revert_all() {
    printf "\n!!! AVISO: Isso removerá TODOS os certificados e configurações. !!!\n"
    printf "Deseja continuar? (s/n): "
    read -r confirm
    if [ "$confirm" = "s" ]; then
        systemctl stop openvpn-server@server
        systemctl disable openvpn-server@server
        
        # Remove apenas os arquivos de configuração e chaves, mantendo os binários
        rm -rf "$PKI_PATH"
        rm -f "$OVPN_PATH/server.conf"
        rm -f /etc/sysctl.d/99-openvpn.conf
        
        printf "Configurações e certificados removidos. Binários mantidos.\n"
    fi
}

# --- MENU PRINCIPAL ---
check_root

while true; do
    printf "\n==========================================\n"
    printf "      OPENVPN ARCH MANAGER - POSIX\n"
    printf "==========================================\n"
    printf "1) Instalação Completa (Servidor + Firewall)\n"
    printf "2) CRIAR USUÁRIO + GERAR CERTIFICADOS (SSL + Senha)\n"
    printf "3) Reverter Configurações (Limpar Certificados)\n"
    printf "4) Sair\n"
    printf "Escolha uma opção: "
    read -r main_opt

    case $main_opt in
        1) install_base; setup_server_infra; setup_firewall; systemctl enable --now openvpn-server@server ;;
        2) manage_user_and_certs ;;
        3) revert_all ;;
        4) exit 0 ;;
        *) printf "Opção inválida.\n" ;;
    esac
done
