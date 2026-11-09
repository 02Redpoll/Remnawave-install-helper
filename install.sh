#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/opt/remnanode"
NODE_V2_VERSION="2.8.0"
NODE_V3_VERSION="latest"
SITE_NAME="api-selfsteel"
WEB_ROOT="/var/www/html"

log()  { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }
trap 'die "Ошибка в строке $LINENO. Установка остановлена."' ERR

require_root() {
    [[ ${EUID} -eq 0 ]] || die "Запустите скрипт от root или через sudo."
    [[ -r /dev/tty ]] || die "Нужен интерактивный терминал."
    exec </dev/tty
}

install_docker() {
    log "Устанавливаю Docker..."
    curl -fsSL https://get.docker.com | sh
    command -v docker >/dev/null && docker compose version >/dev/null || die "Docker/Compose не установился."
    systemctl enable --now docker
}

valid_ip() {
    python3 - "$1" <<'PY'
import ipaddress,sys
try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PY
}

valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

ask_panel_ip() {
    local ip
    while :; do
        read -r -p "Публичный IP Remnawave Panel (обязательно): " ip
        if valid_ip "$ip"; then PANEL_IP="$ip"; return; fi
        warn "Укажите один корректный IPv4 или IPv6 адрес (без CIDR)."
    done
}

ask_port() {
    local p
    while :; do
        read -r -p "NODE_PORT [2222]: " p
        NODE_PORT=${p:-2222}
        valid_port "$NODE_PORT" && return
        warn "Порт должен быть числом от 1 до 65535."
    done
}

configure_firewall() {
    local v4_allow="" v6_allow=""
    if [[ $PANEL_IP == *:* ]]; then v6_allow="-s $PANEL_IP"; else v4_allow="-s $PANEL_IP"; fi
    command -v iptables >/dev/null 2>&1 || { apt-get update -y; DEBIAN_FRONTEND=noninteractive apt-get install -y iptables; }
    command -v ip6tables >/dev/null 2>&1 || { apt-get update -y; DEBIAN_FRONTEND=noninteractive apt-get install -y iptables; }

    # Dedicated chains avoid rewriting the host's existing firewall configuration.
    # The input jumps are placed first so an older broad ACCEPT cannot bypass the restriction.
    cat > /usr/local/sbin/remnanode-firewall <<EOF
#!/usr/bin/env bash
set -e
iptables -N REMNANODE_NODE 2>/dev/null || true
iptables -F REMNANODE_NODE
iptables -A REMNANODE_NODE -p tcp ${v4_allow:+$v4_allow }--dport ${NODE_PORT} -j ACCEPT
iptables -A REMNANODE_NODE -p tcp --dport ${NODE_PORT} -j DROP
iptables -C INPUT -j REMNANODE_NODE 2>/dev/null || iptables -I INPUT 1 -j REMNANODE_NODE
ip6tables -N REMNANODE_NODE 2>/dev/null || true
ip6tables -F REMNANODE_NODE
ip6tables -A REMNANODE_NODE -p tcp ${v6_allow:+$v6_allow }--dport ${NODE_PORT} -j ACCEPT
ip6tables -A REMNANODE_NODE -p tcp --dport ${NODE_PORT} -j DROP
ip6tables -C INPUT -j REMNANODE_NODE 2>/dev/null || ip6tables -I INPUT 1 -j REMNANODE_NODE
EOF
    chmod 700 /usr/local/sbin/remnanode-firewall
    cat > /etc/systemd/system/remnanode-firewall.service <<'EOF'
[Unit]
Description=Restrict Remnawave Node port by panel IP
After=network-pre.target
Before=docker.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/remnanode-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    /usr/local/sbin/remnanode-firewall
    systemctl daemon-reload
    systemctl enable --now remnanode-firewall.service
    log "iptables/ip6tables ограничивают TCP/$NODE_PORT адресом $PANEL_IP; правила восстанавливаются при загрузке."
}

write_compose() {
    cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:${NODE_VERSION}
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY="${SECRET_KEY}"
    volumes:
      - '/etc/letsencrypt:/etc/letsencrypt:ro'
      - /dev/shm:/dev/shm
EOF
    chmod 600 "$INSTALL_DIR/docker-compose.yml"
}

install_node() {
    local raw major answer
    ask_panel_ip
    echo "Версия Remnawave Panel: 2) 2.x (Node 2.8.0)  3) 3.x (Node latest)"
    while :; do
        read -r -p "Введите 2 или 3: " raw
        case "${raw,,}" in 2|2.*) major=2; break;; 3|3.*) major=3; break;; *) warn "Укажите версию 2.x или 3.x.";; esac
    done
    NODE_VERSION=$NODE_V2_VERSION
    [[ $major == 3 ]] && NODE_VERSION=$NODE_V3_VERSION
    ask_port
    echo "SECRET_KEY возьмите из Remnawave Panel → Nodes → Management → Copy docker-compose.yml."
    while :; do read -r -s -p "SECRET_KEY: " SECRET_KEY; echo; [[ -n $SECRET_KEY ]] && break; warn "Ключ не может быть пустым."; done

    mkdir -p "$INSTALL_DIR"
    if [[ -f $INSTALL_DIR/docker-compose.yml ]]; then
        read -r -p "Compose уже существует. Создать резервную копию и заменить? [y/N]: " answer
        [[ ${answer,,} == y || ${answer,,} == yes ]] || die "Установка отменена."
        cp -a "$INSTALL_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml.backup.$(date +%Y%m%d-%H%M%S)"
    fi

    command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 || install_docker
    configure_firewall
    write_compose
    (cd "$INSTALL_DIR" && docker compose config >/dev/null && docker compose pull && docker compose up -d)
    log "Нода запущена; порт $NODE_PORT доступен только с IP $PANEL_IP по правилам UFW."
    warn "Проверьте также внешний firewall/панель управления VPS: разрешите TCP/$NODE_PORT только с $PANEL_IP."
    echo "Статус: cd $INSTALL_DIR && docker compose ps"
    echo "Логи:   cd $INSTALL_DIR && docker compose logs -f -t"
}

install_selfsteel() {
    local domain email template cert_dir site_available site_enabled
    site_available="/etc/nginx/sites-available/$SITE_NAME"
    site_enabled="/etc/nginx/sites-enabled/$SITE_NAME"
    read -r -p "Домен SelfSteel: " domain
    [[ $domain =~ ^[a-zA-Z0-9.-]+$ && $domain != .* && $domain != *..* ]] || die "Некорректный домен."
    read -r -p "Email для Certbot: " email
    [[ $email == *@*.* ]] || die "Укажите корректный email."
    echo "Шаблон: 1) Forbidden (403)  2) OK"
    while :; do read -r -p "Введите 1 или 2: " template; [[ $template == 1 || $template == 2 ]] && break; warn "Укажите 1 или 2."; done

    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do warn "apt/dpkg занят, жду..."; sleep 5; done
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx-extras certbot
    systemctl stop nginx 2>/dev/null || true
    if ss -ltnp | grep -qE '(^|:)80[[:space:]]'; then ss -ltnp | grep -E '(^|:)80[[:space:]]' || true; die "Порт 80 занят; освободите его для получения сертификата."; fi
    certbot certonly --standalone -d "$domain" --non-interactive --agree-tos -m "$email" --keep-until-expiring
    cert_dir="/etc/letsencrypt/live/$domain"
    [[ -f $cert_dir/fullchain.pem && -f $cert_dir/privkey.pem ]] || die "Сертификат не найден."
    mkdir -p "$WEB_ROOT"
    cat > "$WEB_ROOT/selfsteel-forbidden.html" <<EOF
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>403 Forbidden</title></head><body><h1>Forbidden</h1><p>You don't have permission to access this resource.</p><hr><address>Apache/2.4.58 (Ubuntu) Server at ${domain} Port 443</address></body></html>
EOF
    printf 'ok\n' > "$WEB_ROOT/selfsteel-ok.html"
    chmod 644 "$WEB_ROOT/selfsteel-forbidden.html" "$WEB_ROOT/selfsteel-ok.html"
    # Plain HTTP is redirected by the browser to the public HTTPS endpoint for this domain.
    cat > "/etc/nginx/sites-available/${SITE_NAME}-http-redirect" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://${domain}\$request_uri;
}
EOF
    ln -sfn "/etc/nginx/sites-available/${SITE_NAME}-http-redirect" "/etc/nginx/sites-enabled/${SITE_NAME}-http-redirect"
    if [[ $template == 1 ]]; then
        cat > "$site_available" <<EOF
server {
    listen 127.0.0.1:2443 ssl http2 proxy_protocol default_server;
    server_name ${domain};
    root ${WEB_ROOT}; index index.html; server_tokens off;
    ssl_certificate "${cert_dir}/fullchain.pem";
    ssl_certificate_key "${cert_dir}/privkey.pem";
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m; ssl_session_timeout 1d;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    error_page 403 /selfsteel-forbidden.html;
    location = /selfsteel-forbidden.html { internal; }
    location / { return 403; }
}
EOF
    else
        cat > "$site_available" <<EOF
server {
    listen 127.0.0.1:2443 ssl http2 proxy_protocol default_server;
    server_name ${domain};
    root ${WEB_ROOT}; index selfsteel-ok.html; server_tokens off;
    ssl_certificate "${cert_dir}/fullchain.pem";
    ssl_certificate_key "${cert_dir}/privkey.pem";
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m; ssl_session_timeout 1d;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    location / { try_files \$uri /selfsteel-ok.html; }
}
EOF
    fi
    ln -sfn "$site_available" "$site_enabled"
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl enable nginx
    systemctl restart nginx
    log "SelfSteel настроен: $domain, TLS-сертификат $cert_dir, локальный listen 127.0.0.1:2443."
    warn "Конфигурация ожидает reverse proxy, который передаёт PROXY protocol. Для прямого доступа nginx на 2443 не предназначен."
}

enable_bbr() {
    local congestion available
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true) == bbr ]]; then
        log "BBR уже включён. Ничего не меняю."
        return 0
    fi
    if ! modprobe tcp_bbr 2>/dev/null; then
        warn "Не удалось загрузить tcp_bbr; проверяю, возможно модуль уже встроен в ядро."
    fi
    congestion=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if ! grep -qw bbr <<<"$congestion"; then
        die "Текущее ядро не поддерживает BBR (доступно: ${congestion:-не определено}). Установите ядро с поддержкой BBR и повторите."
    fi
    available=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)

    cat > /etc/sysctl.d/99-redwave-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system >/dev/null

    [[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]] || die "Ядро не применило BBR."
    [[ $(sysctl -n net.core.default_qdisc) == fq ]] || die "Не удалось установить fq qdisc."
    log "BBR включён с qdisc fq и сохранён в /etc/sysctl.d/99-redwave-bbr.conf."
    echo "Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo "Default qdisc:      $(sysctl -n net.core.default_qdisc)"
}

main() {
    require_root
    local source_path
    source_path=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
    if [[ -n $source_path && -f $source_path && $source_path != /usr/local/bin/redwave ]]; then
        install -m 755 "$source_path" /usr/local/bin/redwave
        log "Команда redwave установлена в /usr/local/bin/redwave. Её можно запустить командой redwave."
    elif [[ $source_path == /usr/local/bin/redwave ]]; then
        chmod 755 /usr/local/bin/redwave
    else
        warn "Скрипт запущен из потока и не может установить себя. Сохраните его в файл и запустите этот файл от root."
    fi
    command -v apt-get >/dev/null 2>&1 || die "Поддерживаются Debian/Ubuntu с apt-get."
    command -v python3 >/dev/null 2>&1 || { apt-get update -y; DEBIAN_FRONTEND=noninteractive apt-get install -y python3; }
    local choice key
    while :; do
        echo
        echo "========================================="
        echo "                 redwave"
        echo "========================================="
        echo "1) Установить Remnawave Node"
        echo "2) Установить SelfSteel"
        echo "3) Установить оба компонента"
        echo "4) Включить BBR вместо cubic (сохранить после перезагрузки)"
        echo "0) Выход"
        while :; do
            read -r -p "Выберите пункт 0-4: " choice
            [[ $choice == 0 || $choice == 1 || $choice == 2 || $choice == 3 || $choice == 4 ]] && break
            warn "Выберите пункт 0-4."
        done
        [[ $choice == 0 ]] && break
        case "$choice" in
            1) install_node;;
            2) install_selfsteel;;
            3) install_node; install_selfsteel;;
            4) enable_bbr;;
        esac
        echo
        read -r -n 1 -s -p "Нажмите пробел, чтобы вернуться в меню . . ." key
        echo
        while [[ $key != ' ' ]]; do
            read -r -n 1 -s key
        done
    done
}

main "$@"
