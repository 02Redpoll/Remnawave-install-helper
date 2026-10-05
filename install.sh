#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/opt/remnanode"
CONTAINER_NAME="remnanode"

# privet
NODE_V2_VERSION="2.8.0"
NODE_V3_VERSION="latest"

log()  { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

trap 'die "Ошибка в строке $LINENO. Установка остановлена."' ERR

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Запустите скрипт от root или через sudo."
    fi

    if [[ -r /dev/tty ]]; then
        exec </dev/tty
    else
        die "Интерактивный терминал (/dev/tty) недоступен."
    fi
}

install_docker() {
    log "Docker не найден. Устанавливаю Docker официальным скриптом..."
    curl -fsSL https://get.docker.com | sh

    if ! command -v docker >/dev/null 2>&1; then
        die "Docker не установился."
    fi

    if ! docker compose version >/dev/null 2>&1; then
        die "Docker Compose plugin не найден после установки Docker."
    fi

    systemctl enable --now docker 2>/dev/null || true
    log "Docker установлен: $(docker --version)"
    log "Docker Compose: $(docker compose version)"
}

validate_port() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
    return 0
}

normalize_panel_major() {
    local input="${1,,}"
    case "$input" in
        2|2.x|2.x.x|2.*)
            printf '2'
            ;;
        3|3.x|3.x.x|3.*)
            printf '3'
            ;;
        *)
            return 1
            ;;
    esac
}

backup_existing_compose() {
    local compose_file="$INSTALL_DIR/docker-compose.yml"
    if [[ -f "$compose_file" ]]; then
        local backup="${compose_file}.backup.$(date +%Y%m%d-%H%M%S)"
        cp -a "$compose_file" "$backup"
        chmod 600 "$backup"
        log "Старый docker-compose.yml сохранён: $backup"
    fi
}

write_compose_v2() {
    local image="$1"
    local node_port="$2"
    local secret="$3"

    cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: $image
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=$node_port
      - SECRET_KEY="$secret"
    volumes:
      - '/etc/letsencrypt:/etc/letsencrypt:ro'
      - /dev/shm:/dev/shm
EOF
}

write_compose_v3() {
    local image="$1"
    local node_port="$2"
    local secret="$3"

    cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: $image
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=$node_port
      - SECRET_KEY="$secret"
    volumes:
      - '/etc/letsencrypt:/etc/letsencrypt:ro'
      - /dev/shm:/dev/shm      
EOF
}

main() {
    require_root "$@"

    printf '\n'
    printf '\033[1;36m=========================================\033[0m\n'
    printf '\033[1;36m     Remnawave Node Installer\033[0m\n'
    printf '\033[1;36m=========================================\033[0m\n\n'

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        log "Docker уже установлен: $(docker --version)"
        log "Docker Compose: $(docker compose version)"
        systemctl enable --now docker 2>/dev/null || true
    else
        install_docker
    fi

    echo
    echo "Какая у вас версия Remnawave Panel?"
    echo "  2) Panel 2.x.x  -> Node 2.8.0"
    echo "  3) Panel 3.x.x  -> Node 3.x.x"
    echo

    local raw_major panel_major
    while true; do
        read -r -p "Введите 2 или 3 : " raw_major
        if panel_major="$(normalize_panel_major "$raw_major")"; then
            break
        fi
        warn "Нужно указать версию панели 2.x.x или 3.x.x."
    done

    local node_version image
    if [[ "$panel_major" == "2" ]]; then
        node_version="$NODE_V2_VERSION"
    else
        node_version="$NODE_V3_VERSION"
    fi
    image="remnawave/node:${node_version}"

    echo
    log "Будет установлено: $image"

    local node_port
    while true; do
        read -r -p "NODE_PORT [2222]: " node_port
        node_port="${node_port:-2222}"

        if validate_port "$node_port"; then
            break
        fi
        warn "Порт должен быть числом от 1 до 65535."
    done

    echo
    warn "SECRET_KEY нужно брать из Remnawave Panel → Nodes → Management → созданная нода → Copy docker-compose.yml."
    echo "Ключ будет сохранён локально в $INSTALL_DIR/docker-compose.yml с правами 600."
    echo

    local secret
    while true; do
        read -r -s -p "SECRET_KEY: " secret
        echo
        if [[ -n "$secret" ]]; then
            break
        fi
        warn "SECRET_KEY не может быть пустым."
    done

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    if [[ -f docker-compose.yml ]]; then
        echo
        warn "В $INSTALL_DIR уже есть docker-compose.yml."
        local answer
        read -r -p "Сделать резервную копию и заменить его? [y/N]: " answer
        case "${answer,,}" in
            y|yes)
                backup_existing_compose
                ;;
            *)
                die "Установка отменена, существующий docker-compose.yml не изменён."
                ;;
        esac
    fi

    if [[ "$panel_major" == "2" ]]; then
        write_compose_v2 "$image" "$node_port" "$secret"
    else
        write_compose_v3 "$image" "$node_port" "$secret"
    fi

    chmod 600 "$INSTALL_DIR/docker-compose.yml"

    log "Проверяю docker-compose.yml..."
    docker compose config >/dev/null

    log "Скачиваю образ $image..."
    docker compose pull

    log "Запускаю Remnawave Node..."
    docker compose up -d

    echo
    log "Контейнер запущен."
    docker compose ps

    echo
    log "Последние логи:"
    docker compose logs --tail=50 --timestamps

    echo
    printf '\033[1;32m=========================================\033[0m\n'
    printf '\033[1;32m Node установлен\033[0m\n'
    printf '\033[1;32m=========================================\033[0m\n'
    echo "Папка:       $INSTALL_DIR"
    echo "Node image:  $image"
    echo "NODE_PORT:   $node_port"
    echo
    echo "Проверка статуса:"
    echo "  cd $INSTALL_DIR && docker compose ps"
    echo
    echo "Просмотр логов:"
    echo "  cd $INSTALL_DIR && docker compose logs -f -t"
    echo
    warn "Откройте NODE_PORT в firewall только для IP вашего Remnawave Panel."
}

main "$@"
