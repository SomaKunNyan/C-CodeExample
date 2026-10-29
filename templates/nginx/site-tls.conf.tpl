# /etc/nginx/sites-available/vpn-site-tls.conf — сгенерировано scripts/self-site.sh
# Сайт-заглушка для REALITY. Слушает ТОЛЬКО 127.0.0.1: снаружи на 443 отвечает Xray,
# который прозрачно отдаёт этот сайт всем, кто не является клиентом VPN.
server {
    listen 127.0.0.1:${SELF_SITE_PORT} ssl${NGINX_LISTEN_H2};
${NGINX_H2_DIRECTIVE}
    server_name ${VPN_DOMAIN};
    server_tokens off;

    ssl_certificate     /etc/letsencrypt/live/${VPN_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${VPN_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ecdh_curve ${NGINX_ECDH_CURVES};
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    root /var/www/vpn-site;
    index index.html;
    error_page 404 /404.html;

    location / {
        try_files $uri $uri/ =404;
    }
    location = /404.html {
        internal;
    }
}
