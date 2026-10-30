# /etc/nginx/sites-available/vpn-cdn.conf — сгенерировано scripts/self-site.sh (CDN_ENABLE=yes)
# Cloudflare подключается к серверу на 443 с SNI = CDN-домен. REALITY не узнаёт это имя
# и прозрачно передаёт соединение сюда (на сайт-заглушку). Секретный путь XHTTP уходит
# во вход Xray "vless-cdn", остальное — обычный сайт.
server {
    listen 127.0.0.1:${SELF_SITE_PORT} ssl${NGINX_LISTEN_H2};
${NGINX_H2_DIRECTIVE}
    server_name ${CDN_DOMAIN};
    server_tokens off;

    ssl_certificate     /etc/letsencrypt/live/${VPN_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${VPN_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ecdh_curve ${NGINX_ECDH_CURVES};
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    root /var/www/vpn-site;
    index index.html;
    error_page 404 /404.html;

    # XHTTP (packet-up): серия коротких POST и потоковый GET. Без буферизации и
    # ограничений на размер тела — иначе nginx задержит или оборвёт поток.
    location ${CDN_PATH} {
        proxy_pass http://127.0.0.1:${CDN_XRAY_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Connection "";
        proxy_set_header X-Forwarded-For $http_cf_connecting_ip;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    # Продление Let's Encrypt при включённом в Cloudflare «Always Use HTTPS»: проверка
    # по http:// получает редирект на https:// и приходит сюда через CDN.
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
        default_type text/plain;
    }

    location / {
        try_files $uri $uri/ =404;
    }
    location = /404.html {
        internal;
    }
}
