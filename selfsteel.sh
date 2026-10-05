#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "[ERROR] Ошибка в строке $LINENO. Установка остановлена."' ERR

SITE_NAME="api-selfsteel"
SITE_AVAILABLE="/etc/nginx/sites-available/${SITE_NAME}"
SITE_ENABLED="/etc/nginx/sites-enabled/${SITE_NAME}"

WEB_ROOT="/var/www/html"

echo "========================================="
echo "SelfSteel Nginx Installer By redpoll"
echo "========================================="
echo

read -r -p "Домен: " DOMAIN </dev/tty

if [[ -z "${DOMAIN}" ]]; then
    echo "[ERROR] Домен не указан."
    exit 1
fi

if [[ ! "${DOMAIN}" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo "[ERROR] Некорректный домен."
    exit 1
fi

echo
echo "[+] Домен SelfSteel: ${DOMAIN}"
echo

if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] Запустите скрипт от root."
    exit 1
fi

read -r -p "Email для Certbot: " EMAIL </dev/tty

if [[ -z "${EMAIL}" ]]; then
    echo "[ERROR] Email не указан."
    exit 1
fi

echo
echo "Выберите шаблон:"
echo "  1) Forbidden — Apache-style 403"
echo "  2) OK        — обычная страница ok"
echo

while true; do
    read -r -p "Введите 1 или 2: " TEMPLATE </dev/tty

    case "${TEMPLATE}" in
        1|2)
            break
            ;;
        *)
            echo "[!] Нужно указать 1 или 2."
            ;;
    esac
done

echo
echo "[+] Проверяю apt/dpkg..."

while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
   || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
   || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    echo "[!] apt/dpkg занят. Жду..."
    sleep 5
done

echo "[+] Обновляю список пакетов..."

apt-get update -y

echo "[+] Устанавливаю Nginx + Certbot..."

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    nginx-extras \
    certbot

echo "[+] Останавливаю Nginx для Certbot..."

systemctl stop nginx || true

if ss -ltnp | grep -qE '(^|:)80[[:space:]]'; then
    echo
    echo "[ERROR] Порт 80 уже занят."
    echo
    ss -ltnp | grep -E '(^|:)80[[:space:]]' || true
    exit 1
fi

echo
echo "[+] Получаю SSL-сертификат для ${DOMAIN}..."

certbot certonly \
    --standalone \
    -d "${DOMAIN}" \
    --non-interactive \
    --agree-tos \
    -m "${EMAIL}" \
    --keep-until-expiring

CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"

if [[ ! -f "${CERT_DIR}/fullchain.pem" ]]; then
    echo "[ERROR] Не найден fullchain.pem"
    exit 1
fi

if [[ ! -f "${CERT_DIR}/privkey.pem" ]]; then
    echo "[ERROR] Не найден privkey.pem"
    exit 1
fi

echo "[+] SSL-сертификат получен."

mkdir -p "${WEB_ROOT}"

cat > "${WEB_ROOT}/selfsteel-forbidden.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>403 Forbidden</title>
</head>
<body>
    <h1>Forbidden</h1>

    <p>You don't have permission to access this resource.</p>

    <hr>

    <address>
        Apache/2.4.58 (Ubuntu) Server at ${DOMAIN} Port 443
    </address>
</body>
</html>
EOF

cat > "${WEB_ROOT}/selfsteel-ok.html" <<EOF
ok
EOF

chmod 644 "${WEB_ROOT}/selfsteel-forbidden.html"
chmod 644 "${WEB_ROOT}/selfsteel-ok.html"

if [[ "${TEMPLATE}" == "1" ]]; then

    echo "[+] Выбран шаблон: Forbidden"

    cat > "${SITE_AVAILABLE}" <<EOF
server {
    listen 127.0.0.1:2443 ssl http2 proxy_protocol default_server;
    server_name ${DOMAIN};

    root ${WEB_ROOT};
    index index.html;

    server_tokens off;

    ssl_certificate "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/${DOMAIN}/privkey.pem";

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

    echo "[+] Выбран шаблон: OK"

    cat > "${SITE_AVAILABLE}" <<EOF
server {
    listen 127.0.0.1:2443 ssl http2 proxy_protocol default_server;
    server_name ${DOMAIN};

    root ${WEB_ROOT};
    index selfsteel-ok.html;

    server_tokens off;

    ssl_certificate "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/${DOMAIN}/privkey.pem";

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;

    location / {
        try_files $uri /selfsteel-ok.html;
    }
}
EOF

fi

echo "[+] Включаю сайт..."

ln -sf "${SITE_AVAILABLE}" "${SITE_ENABLED}"

rm -f /etc/nginx/sites-enabled/default

echo
echo "[+] Проверяю конфигурацию Nginx..."

nginx -t

echo "[+] Запускаю Nginx..."

systemctl enable nginx
systemctl restart nginx

echo
echo "========================================="
echo "          Установка завершена"
echo "========================================="
echo
echo "SelfSteel domain: ${DOMAIN}"
echo
echo "Nginx config:"
echo "${SITE_AVAILABLE}"
echo
echo "SSL:"
echo "${CERT_DIR}"
echo
echo "Listen:"
echo "127.0.0.1:2443"
echo
