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
        read -r -p "Публичный IP Remnawave Panel (Enter — без ограничения по IP): " ip
        if [[ -z $ip ]]; then PANEL_IP=""; return; fi
        if valid_ip "$ip"; then PANEL_IP="$ip"; return; fi
        warn "Укажите корректный IPv4/IPv6 или оставьте поле пустым."
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

remove_node_iptables_rules() {
    systemctl disable --now remnanode-firewall.service >/dev/null 2>&1 || true
    local fw
    for fw in iptables ip6tables; do
        command -v "$fw" >/dev/null 2>&1 || continue
        while "$fw" -C INPUT -j REMNANODE_NODE 2>/dev/null; do
            "$fw" -D INPUT -j REMNANODE_NODE
        done
        "$fw" -F REMNANODE_NODE 2>/dev/null || true
        "$fw" -X REMNANODE_NODE 2>/dev/null || true
    done
    rm -f /etc/systemd/system/remnanode-firewall.service /usr/local/sbin/remnanode-firewall
    systemctl daemon-reload
}

configure_firewall() {
    local firewall_choice v4_rules="" v6_rules=""
    echo "Firewall для порта ноды:"
    echo "1) iptables"
    echo "2) UFW"
    while :; do
        read -r -p "Выберите 1 или 2: " firewall_choice
        [[ $firewall_choice == 1 || $firewall_choice == 2 ]] && break
        warn "Введите 1 или 2."
    done

    if [[ $firewall_choice == 2 ]]; then
        remove_node_iptables_rules
        if ! command -v ufw >/dev/null 2>&1; then
            apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
        fi
        if ! ufw status | grep -q '^Status: active'; then
            ufw allow 22/tcp || true
            if [[ -n "${SSH_CONNECTION:-}" ]]; then
                local ssh_port
                ssh_port=$(awk '{print $4}' <<<"$SSH_CONNECTION")
                if valid_port "$ssh_port"; then ufw allow "${ssh_port}/tcp"; fi
            fi
            ufw --force enable
        fi
        if [[ -n $PANEL_IP ]]; then
            ufw prepend allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp
            ufw insert 2 deny "$NODE_PORT/tcp"
            log "UFW разрешает TCP/$NODE_PORT только с $PANEL_IP."
        else
            ufw prepend allow "$NODE_PORT/tcp"
            log "IP не указан: UFW открывает TCP/$NODE_PORT для всех адресов."
        fi
        ufw reload
        return 0
    fi

    if [[ -n $PANEL_IP ]]; then
        remove_node_iptables_rules
        if [[ $PANEL_IP == *:* ]]; then
            v4_rules="iptables -A REMNANODE_NODE -p tcp --dport $NODE_PORT -j DROP"
            v6_rules="ip6tables -A REMNANODE_NODE -s $PANEL_IP -p tcp --dport $NODE_PORT -j ACCEPT
ip6tables -A REMNANODE_NODE -p tcp --dport $NODE_PORT -j DROP"
        else
            v4_rules="iptables -A REMNANODE_NODE -s $PANEL_IP -p tcp --dport $NODE_PORT -j ACCEPT
iptables -A REMNANODE_NODE -p tcp --dport $NODE_PORT -j DROP"
            v6_rules="ip6tables -A REMNANODE_NODE -p tcp --dport $NODE_PORT -j DROP"
        fi
    else
        remove_node_iptables_rules
        log "IP не указан: фильтр порта ноды не устанавливается."
        return 0
    fi

    command -v iptables >/dev/null 2>&1 || { apt-get update -y; DEBIAN_FRONTEND=noninteractive apt-get install -y iptables; }
    command -v ip6tables >/dev/null 2>&1 || { apt-get update -y; DEBIAN_FRONTEND=noninteractive apt-get install -y iptables; }

    # Dedicated chains avoid rewriting the host's existing firewall configuration.
    # The input jumps are placed first so an older broad ACCEPT cannot bypass the restriction.
    cat > /usr/local/sbin/remnanode-firewall <<EOF
#!/usr/bin/env bash
set -e
iptables -N REMNANODE_NODE 2>/dev/null || true
iptables -F REMNANODE_NODE
${v4_rules}
iptables -C INPUT -j REMNANODE_NODE 2>/dev/null || iptables -I INPUT 1 -j REMNANODE_NODE
ip6tables -N REMNANODE_NODE 2>/dev/null || true
ip6tables -F REMNANODE_NODE
${v6_rules}
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
    log "iptables/ip6tables разрешают TCP/$NODE_PORT только с $PANEL_IP; правила восстанавливаются при загрузке."
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
    echo "Версия Remnawave Panel:"
    echo "1) Panel 2.x (Node 2.8.0)"
    echo "2) Panel 3.x (Node latest)"
    while :; do
        read -r -p "Введите 1 или 2: " raw
        case "$raw" in 1) major=2; break;; 2) major=3; break;; *) warn "Введите 1 или 2.";; esac
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
    log "Нода запущена."
    if [[ -n $PANEL_IP ]]; then
        warn "Проверьте внешний firewall VPS: TCP/$NODE_PORT должен быть разрешён с $PANEL_IP."
    else
        warn "IP не ограничен: TCP/$NODE_PORT открыт для любых адресов согласно выбранному режиму firewall."
    fi
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
    # HTTP redirect and the local SelfSteel listener share one site configuration.
    if [[ $template == 1 ]]; then
        cat > "$site_available" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    return 301 https://${domain}\$request_uri;
}

update_selfsteel() {
    local site="/etc/nginx/sites-available/$SITE_NAME" domain backup temp
    [[ -f $site ]] || { warn "Конфиг $site не найден. Сначала установите SelfSteel."; return; }
    domain=$(awk '/^[[:space:]]*server_name[[:space:]]/ {gsub(/;/,"",$2); print $2; exit}' "$site")
    [[ $domain =~ ^[a-zA-Z0-9.-]+$ && $domain != .* && $domain != *..* ]] || { warn "Не удалось определить домен из конфига."; return; }
    if grep -Eq '^[[:space:]]*listen[[:space:]]+(\[::\]:|0\.0\.0\.0:)?80([[:space:];]|$)' "$site"; then
        log "В конфиге уже есть listener на порту 80; конфиг оставлен без изменений."
        return
    fi
    grep -Eq '^[[:space:]]*listen[[:space:]]+127\.0\.0\.1:2443([[:space:];]|$)' "$site" || { warn "Не найден listener SelfSteel на 127.0.0.1:2443."; return; }
    backup="${site}.backup.$(date +%Y%m%d-%H%M%S)"
    cp -p "$site" "$backup"
    temp=$(mktemp "${site}.XXXXXX")
    cat > "$temp" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    return 301 https://${domain}\$request_uri;
}

EOF
    cat "$site" >> "$temp"
    chmod --reference="$site" "$temp"
    chown --reference="$site" "$temp"
    mv -f "$temp" "$site"
    if ! nginx -t; then
        cp -p "$backup" "$site"
        warn "Проверка Nginx не прошла; восстановлена резервная копия $backup."
        return
    fi
    if ! systemctl reload nginx; then
        cp -p "$backup" "$site"
        warn "Не удалось перезагрузить Nginx; конфиг восстановлен из $backup."
        return
    fi
    log "SelfSteel обновлён: HTTP перенаправляется на https://$domain. Резервная копия: $backup"
}

server {
    listen 127.0.0.1:2443 ssl http2 proxy_protocol default_server;
    server_name ${domain};
    root ${WEB_ROOT};
    index index.html;

    server_tokens off;

    ssl_certificate "/etc/letsencrypt/live/${domain}/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/${domain}/privkey.pem";

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;

    error_page 403 /selfsteel-forbidden.html;

    location = /selfsteel-forbidden.html {
        internal;
    }

    location / {
        return 403;
    }
}
EOF
    else
        cat > "$site_available" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    return 301 https://${domain}\$request_uri;
}

server {
    listen 127.0.0.1:2443 ssl http2 proxy_protocol default_server;
    server_name ${domain};
    root ${WEB_ROOT};
    index selfsteel-ok.html;

    server_tokens off;

    ssl_certificate "/etc/letsencrypt/live/${domain}/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/${domain}/privkey.pem";

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;

    location / {
        try_files \$uri /selfsteel-ok.html;
    }
}
EOF
    fi
    ln -sfn "$site_available" "$site_enabled"
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl enable nginx
    systemctl restart nginx
    log "SelfSteel настроен: $domain, HTTP :80 → HTTPS :443, локальный listen 127.0.0.1:2443."
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

ssh_apply() {
    local file=/etc/ssh/sshd_config.d/00-redwave.conf backup
    mkdir -p /etc/ssh/sshd_config.d
    backup=$(mktemp)
    [[ ! -f $file ]] || cp -p "$file" "$backup"
    printf '%s\n' "$1" > "$file"
    if ! sshd -t; then
        if [[ -s $backup ]]; then cp -p "$backup" "$file"; else rm -f "$file"; fi
        rm -f "$backup"
        warn "Ошибка конфигурации SSH; изменения отменены."
        return 1
    fi
    rm -f "$backup"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
}

ssh_key_add() {
    local user account_dir key tmp old
    read -r -p "Пользователь SSH [root]: " user
    user=${user:-root}
    account_dir=$(getent passwd "$user" | cut -d: -f6)
    [[ -n $account_dir && -d $account_dir ]] || { warn "Пользователь не найден."; return; }
    read -r -p "Вставьте публичный SSH-ключ: " key
    tmp=$(mktemp); printf '%s\n' "$key" > "$tmp"
    if ! ssh-keygen -lf "$tmp"; then rm -f "$tmp"; warn "Некорректный публичный ключ."; return; fi
    install -d -m 700 -o "$user" "$account_dir/.ssh"
    touch "$account_dir/.ssh/authorized_keys"
    grep -qxF "$key" "$account_dir/.ssh/authorized_keys" || cat "$tmp" >> "$account_dir/.ssh/authorized_keys"
    rm -f "$tmp"
    chown "$user" "$account_dir/.ssh/authorized_keys"
    chmod 600 "$account_dir/.ssh/authorized_keys"
    if ! sshd -T -C "user=$user,host=localhost,addr=127.0.0.1" | grep -qx 'pubkeyauthentication yes'; then
        old=$(cat /etc/ssh/sshd_config.d/00-redwave.conf 2>/dev/null || true)
        old=$(printf '%s\n' "$old" | sed '/^[[:space:]]*PubkeyAuthentication /Id')
        ssh_apply "$old
PubkeyAuthentication yes" || return
        sshd -T -C "user=$user,host=localhost,addr=127.0.0.1" | grep -qx 'pubkeyauthentication yes' || { warn "Другая настройка SSH блокирует вход по ключу."; return; }
    fi
    log "Ключ добавлен. Проверьте вход в отдельной SSH-сессии."
}

ssh_settings() {
    local action user answer current port old
    echo "1) Добавить публичный ключ"
    echo "2) Отключить вход по паролю"
    echo "3) Изменить порт SSH"
    read -r -p "Выбор: " action
    case "$action" in
        1) ssh_key_add ;;
        2)
            read -r -p "Пользователь, для которого проверен вход по ключу [root]: " user
            user=${user:-root}
            current=$(getent passwd "$user" | cut -d: -f6)
            [[ -n $current && -s $current/.ssh/authorized_keys ]] || { warn "Нет файла с ключом для $user."; return; }
            sshd -T -C "user=$user,host=localhost,addr=127.0.0.1" | grep -qx 'pubkeyauthentication yes' || { warn "Вход по ключу не включён для $user."; return; }
            warn "Сначала проверьте вход по ключу в отдельной SSH-сессии, не закрывая текущую."
            read -r -p "Вы уже успешно вошли по ключу? Введите yes: " answer
            [[ $answer == yes ]] || return
            old=$(cat /etc/ssh/sshd_config.d/00-redwave.conf 2>/dev/null || true)
            old=$(printf '%s\n' "$old" | sed '/^[[:space:]]*PasswordAuthentication /Id; /^[[:space:]]*KbdInteractiveAuthentication /Id')
            ssh_apply "$old
PasswordAuthentication no
KbdInteractiveAuthentication no"
            ;;
        3)
            if systemctl is-active --quiet ssh.socket; then warn "Обнаружен ssh.socket; измените его порт отдельно."; return; fi
            read -r -p "Новый порт SSH: " port
            valid_port "$port" || { warn "Некорректный порт."; return; }
            if ss -ltnH "sport = :$port" | grep -q .; then warn "Порт уже занят."; return; fi
            if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then ufw allow "$port/tcp"; fi
            old=$(cat /etc/ssh/sshd_config.d/00-redwave.conf 2>/dev/null || true)
            old=$(printf '%s\n' "$old" | sed '/^[[:space:]]*Port /Id')
            ssh_apply "$old
Port $port"
            warn "Проверьте вход на порт $port в отдельной сессии; откройте его также в firewall провайдера."
            ;;
        *) warn "Неизвестный пункт." ;;
    esac
}

aes_menu() {
    local choice
    echo "1) Включить AES-NI"
    echo "2) Проверить AES-NI"
    read -r -p "Выбор: " choice
    case "$choice" in
        1|2)
            if grep -qw aes /proc/cpuinfo; then
                log "AES-NI доступен ОС; приложения используют его автоматически при поддержке."
            else
                warn "AES-NI не доступен ОС. Включите его в BIOS или настройках виртуальной машины/у провайдера."
            fi ;;
        *) warn "Неизвестный пункт." ;;
    esac
}

source_ip_menu() {
    local -a addresses routes words filtered
    local i choice ip route word skip
    mapfile -t addresses < <(ip -o -4 addr show scope global | awk '{print $4 " " $2}')
    mapfile -t routes < <(ip -4 route show default)
    ((${#addresses[@]} > 0 && ${#routes[@]} == 1)) || { warn "Нужны IPv4-адрес и один маршрут по умолчанию."; return; }
    for i in "${!addresses[@]}"; do printf '%s) %s\n' "$((i+1))" "${addresses[$i]}"; done
    read -r -p "Выберите исходящий IPv4: " choice
    [[ $choice =~ ^[0-9]{1,3}$ ]] && ((10#$choice >= 1 && 10#$choice <= ${#addresses[@]})) || { warn "Некорректный выбор."; return; }
    ip=${addresses[$((10#$choice-1))]%% *}; ip=${ip%/*}
    read -r -a words <<< "${routes[0]}"
    filtered=(); skip=0
    for word in "${words[@]}"; do
        if ((skip)); then skip=0; continue; fi
        if [[ $word == src ]]; then skip=1; continue; fi
        filtered+=("$word")
    done
    [[ " ${routes[0]} " == *" dev ${addresses[$((10#$choice-1))]##* } "* ]] || { warn "Адрес не принадлежит интерфейсу маршрута по умолчанию."; return; }
    ip -4 route replace "${filtered[@]}" src "$ip" || { warn "Не удалось изменить маршрут."; return; }
    mkdir -p /usr/local/sbin
    printf '#!/bin/bash\nip -4 route replace ' > /usr/local/sbin/redwave-source-ip
    printf '%q ' "${filtered[@]}" src "$ip" >> /usr/local/sbin/redwave-source-ip
    printf '\n' >> /usr/local/sbin/redwave-source-ip
    chmod 700 /usr/local/sbin/redwave-source-ip
    cat > /etc/systemd/system/redwave-source-ip.service <<'EOF'
[Unit]
Description=Redwave preferred IPv4 source
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/redwave-source-ip
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable redwave-source-ip.service
    log "Предпочитаемый исходящий IPv4: $ip. Проверьте ip route get 1.1.1.1."
}

utilities_menu() {
    local choice key
    while :; do
        echo "1) Установить и настроить firewall для порта ноды"
        echo "2) Управление SSH"
        echo "3) AES-NI"
        echo "4) Исходящий IPv4"
        echo "5) Включить BBR"
        echo "0) Назад"
        read -r -p "Выбор: " choice
        case "$choice" in
            1) ask_panel_ip; ask_port; configure_firewall ;;
            2) ssh_settings ;;
            3) aes_menu ;;
            4) source_ip_menu ;;
            5) enable_bbr ;;
            0) return ;;
            *) warn "Неизвестный пункт." ;;
        esac
        read -r -p "Нажмите Enter, чтобы вернуться в утилиты . . ." key
    done
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
        local script_url="https://raw.githubusercontent.com/02Redpoll/Remnawave-install-helper/main/install.sh"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$script_url" -o /usr/local/bin/redwave && chmod 755 /usr/local/bin/redwave && log "Команда redwave установлена в /usr/local/bin/redwave."
        elif command -v wget >/dev/null 2>&1; then
            wget -qO /usr/local/bin/redwave "$script_url" && chmod 755 /usr/local/bin/redwave && log "Команда redwave установлена в /usr/local/bin/redwave."
        else
            die "Для установки команды redwave нужен curl или wget."
        fi
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
        echo "3) Обновить SelfSteel"
        echo "4) Установить оба компонента"
        echo "5) Утилиты"
        echo "0) Выход"
        while :; do
            read -r -p "Выберите пункт 0-5: " choice
            [[ $choice == 0 || $choice == 1 || $choice == 2 || $choice == 3 || $choice == 4 || $choice == 5 ]] && break
            warn "Выберите пункт 0-5."
        done
        [[ $choice == 0 ]] && break
        case "$choice" in
            1) install_node;;
            2) install_selfsteel;;
            3) update_selfsteel;;
            4) install_node; install_selfsteel;;
            5) utilities_menu;;
        esac
        echo
        read -r -p "Нажмите Enter, чтобы вернуться в меню . . ." key
    done
}

main "$@"
