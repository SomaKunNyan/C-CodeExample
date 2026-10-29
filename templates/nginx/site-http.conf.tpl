# /etc/nginx/sites-available/vpn-site-http.conf — сгенерировано scripts/self-site.sh
# Порт 80: проверка Let's Encrypt (HTTP-01) и перенаправление на HTTPS, как у обычного сайта.
server {
    listen 80 default_server;
${NGINX_LISTEN_V6}
    server_name _;
    server_tokens off;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
        default_type text/plain;
    }
    location / {
        return 301 https://${VPN_DOMAIN}$request_uri;
    }
}
