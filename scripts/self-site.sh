#!/usr/bin/env bash
# =============================================================================
#  Собственный сайт-заглушка для REALITY (REALITY_SELF_SITE="yes").
#   - nginx: порт 80 — Let's Encrypt (HTTP-01) и редирект на HTTPS;
#            127.0.0.1:SELF_SITE_PORT — сайт с TLS 1.3 + HTTP/2 (снаружи недоступен);
#   - сертификат Let's Encrypt (ECDSA P-256) для VPN_DOMAIN, автопродление;
#   - REALITY маскируется под этот сайт: SNI = VPN_DOMAIN, который действительно
#     указывает на этот сервер, а без ключа клиента посетитель видит этот сайт.
#  Вызывается из 03-install-vpn.sh; можно запускать и отдельно (идемпотентно).
# =============================================================================
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require_root
require_debian
load_config
require_reality

[[ ${REALITY_SELF_SITE} == yes ]] || die "REALITY_SELF_SITE не равен \"yes\" — свой сайт не нужен."
[[ -n ${ACME_EMAIL} ]] || die "Задайте ACME_EMAIL в ${CONFIG_FILE} (уведомления Let's Encrypt)."

apt_install nginx certbot bind9-dnsutils gettext-base

# --- 1. Проверки: DNS и порт 80 ------------------------------------------------
resolved="$(dig +short A "${VPN_DOMAIN}" @1.1.1.1 | grep -E '^[0-9.]+$' | head -n1 || true)"
if [[ -n ${PUBLIC_IPV4} && ${resolved} != "${PUBLIC_IPV4}" ]]; then
    die "${VPN_DOMAIN} указывает на '${resolved:-ничего}', а публичный IP сервера ${PUBLIC_IPV4}. Исправьте A-запись — без неё не будет сертификата."
fi
if [[ ${CDN_ENABLE} == yes ]]; then
    # CDN-домен должен указывать на адреса CDN, а не на сервер: CNAME на адрес ресурса
    # (Gcore: cl-xxxx.gcdn.co) или A-запись с оранжевым облаком (Cloudflare).
    cdn_ip="$(dig +short A "${CDN_DOMAIN}" @1.1.1.1 | grep -E '^[0-9.]+$' | head -n1 || true)"
    [[ -n ${cdn_ip} ]] || die "${CDN_DOMAIN} не разрешается. Gcore: CNAME ${CDN_DOMAIN%%.*} -> адрес CDN-ресурса (cl-....gcdn.co); Cloudflare: A ${CDN_DOMAIN%%.*} -> ${PUBLIC_IPV4:-IP сервера}, оранжевое облако. См. docs/07-cdn.md."
    [[ ${cdn_ip} != "${PUBLIC_IPV4}" ]] \
        || die "${CDN_DOMAIN} указывает прямо на сервер (${cdn_ip}), а не на CDN: Gcore — запись должна быть CNAME на адрес ресурса; Cloudflare — включите оранжевое облако."
    log "${CDN_DOMAIN} -> ${cdn_ip} ($(dig +short CNAME "${CDN_DOMAIN}" @1.1.1.1 | head -n1 || true))"
fi
if systemctl is-active --quiet nftables && ! nft list chain inet filter input 2>/dev/null | grep -q 'tcp dport 80 accept'; then
    die "Порт 80 закрыт в nftables. Сначала: sudo ./scripts/02-firewall.sh (при REALITY_SELF_SITE=\"yes\" он откроет 80)."
fi

# --- 2. Содержимое сайта -------------------------------------------------------
SITE_TITLE="${SITE_TITLE:-$(python3 -c 'import sys; d=sys.argv[1].split(".")[0]; print(d[:1].upper()+d[1:])' "${VPN_DOMAIN}")}"
SITE_YEAR="$(date +%Y)"
export SITE_TITLE SITE_YEAR
install -d -m 0755 /var/www/vpn-site /var/www/acme
for f in index.html 404.html robots.txt; do
    render "${TEMPLATES_DIR}/site/${f}" "/var/www/vpn-site/${f}" 0644 SITE_TITLE SITE_YEAR VPN_DOMAIN
done

# --- 3. nginx: сначала только порт 80 (для выпуска сертификата) ---------------
rm -f /etc/nginx/sites-enabled/default
# IPv6-слушатель — только если IPv6 в системе включён (иначе nginx не стартует).
NGINX_LISTEN_V6=""
if [[ -f /proc/net/if_inet6 && $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1) == 0 ]]; then
    NGINX_LISTEN_V6="    listen [::]:80 default_server;"
fi
export NGINX_LISTEN_V6
render "${TEMPLATES_DIR}/nginx/site-http.conf.tpl" /etc/nginx/sites-available/vpn-site-http.conf 0644 \
    VPN_DOMAIN NGINX_LISTEN_V6
ln -sf /etc/nginx/sites-available/vpn-site-http.conf /etc/nginx/sites-enabled/vpn-site-http.conf
nginx -t 2>/dev/null || { nginx -t; die "nginx -t: ошибка конфигурации"; }
systemctl enable nginx
systemctl reload-or-restart nginx

# --- 4. Сертификат Let's Encrypt ----------------------------------------------
# Один сертификат на основной домен и (если включён CDN) на CDN-домен. CDN-домен в
# сертификате сервера нужен Cloudflare в режиме Full (strict). Проверка Let's Encrypt
# для CDN-домена идёт через CDN, и некоторые CDN (Gcore выпускает свой сертификат тем
# же способом) её не пропускают — тогда сертификат выпускается только на основной домен.
cert_file="/etc/letsencrypt/live/${VPN_DOMAIN}/fullchain.pem"
cert_has() {
    [[ -f ${cert_file} ]] && openssl x509 -noout -ext subjectAltName -in "${cert_file}" 2>/dev/null | grep -q "DNS:${1}\b"
}
# issue_cert <домен>... — 1, если не прошла пробная проверка (staging, не расходует лимиты).
issue_cert() {
    local args=(certonly --webroot -w /var/www/acme --non-interactive --agree-tos --expand
                --cert-name "${VPN_DOMAIN}" -m "${ACME_EMAIL}"
                --key-type ecdsa --elliptic-curve secp256r1) d
    for d in "$@"; do args+=(-d "$d"); done
    log "Пробный выпуск сертификата (Let's Encrypt staging): $*"
    certbot "${args[@]}" --dry-run || return 1
    log "Выпуск сертификата: $*"
    certbot "${args[@]}" || die "Сертификат не выпущен (см. вывод certbot выше)."
}
if ! cert_has "${VPN_DOMAIN}" || { [[ ${CDN_ENABLE} == yes ]] && ! cert_has "${CDN_DOMAIN}"; }; then
    if [[ ${CDN_ENABLE} == yes ]] && issue_cert "${VPN_DOMAIN}" "${CDN_DOMAIN}"; then
        :
    else
        if [[ ${CDN_ENABLE} == yes ]]; then
            warn "Let's Encrypt не проверил ${CDN_DOMAIN} через CDN — сертификат сервера будет только на ${VPN_DOMAIN}."
            warn "  Gcore это не мешает. Cloudflare в режиме Full (strict) ответит ошибкой 526: выключите на время"
            warn "  SSL/TLS -> Edge Certificates -> «Always Use HTTPS» и запустите скрипт снова."
        fi
        cert_has "${VPN_DOMAIN}" || issue_cert "${VPN_DOMAIN}" \
            || die "Проверка домена ${VPN_DOMAIN} не прошла: A-запись -> ${PUBLIC_IPV4:-IP сервера} и доступность порта 80 снаружи (firewall хостера)."
    fi
fi
install -d /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
systemctl enable --now certbot.timer

# --- 5. nginx: сайт на 127.0.0.1 с TLS 1.3 + HTTP/2 ------------------------------
# HTTP/2: в nginx >= 1.25.1 — директива "http2 on;", раньше (Debian 12) — "listen ... http2".
nginx_ver="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
if [[ "$(printf '%s\n1.25.1\n' "${nginx_ver}" | sort -V | head -n1)" == 1.25.1 ]]; then
    NGINX_LISTEN_H2="" NGINX_H2_DIRECTIVE="    http2 on;"
else
    NGINX_LISTEN_H2=" http2" NGINX_H2_DIRECTIVE=""
fi
# Постквантовый обмен ключами — если его поддерживает OpenSSL (3.5+), как у современных сайтов.
if openssl list -kem-algorithms 2>/dev/null | grep -qi 'X25519MLKEM768'; then
    NGINX_ECDH_CURVES="X25519MLKEM768:X25519:prime256v1:secp384r1"
else
    NGINX_ECDH_CURVES="X25519:prime256v1:secp384r1"
fi
export NGINX_LISTEN_H2 NGINX_H2_DIRECTIVE NGINX_ECDH_CURVES
render "${TEMPLATES_DIR}/nginx/site-tls.conf.tpl" /etc/nginx/sites-available/vpn-site-tls.conf 0644 \
    VPN_DOMAIN SELF_SITE_PORT NGINX_LISTEN_H2 NGINX_H2_DIRECTIVE NGINX_ECDH_CURVES
ln -sf /etc/nginx/sites-available/vpn-site-tls.conf /etc/nginx/sites-enabled/vpn-site-tls.conf

# Вход через CDN: виртуальный хост CDN_DOMAIN, секретный путь -> Xray (vless-cdn).
if [[ ${CDN_ENABLE} == yes ]]; then
    CDN_PATH="$(python3 "${PROJECT_DIR}/scripts/xray-vpn.py" cdn-path)"
    export CDN_PATH
    render "${TEMPLATES_DIR}/nginx/cdn.conf.tpl" /etc/nginx/sites-available/vpn-cdn.conf 0644 \
        VPN_DOMAIN CDN_DOMAIN CDN_PATH CDN_XRAY_PORT SELF_SITE_PORT NGINX_LISTEN_H2 NGINX_H2_DIRECTIVE NGINX_ECDH_CURVES
    ln -sf /etc/nginx/sites-available/vpn-cdn.conf /etc/nginx/sites-enabled/vpn-cdn.conf
else
    rm -f /etc/nginx/sites-enabled/vpn-cdn.conf
fi
nginx -t 2>/dev/null || { nginx -t; die "nginx -t: ошибка конфигурации"; }
systemctl reload nginx

code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code} HTTP/%{http_version}' --max-time 10 --http2 \
        --resolve "${VPN_DOMAIN}:${SELF_SITE_PORT}:127.0.0.1" "https://${VPN_DOMAIN}:${SELF_SITE_PORT}/" || true)"
[[ ${code} == "200 HTTP/2" ]] || die "Сайт-заглушка не отвечает как ожидалось: '${code}' (нужно '200 HTTP/2')."
log "Сайт-заглушка ${VPN_DOMAIN} работает (${code}, ${NGINX_ECDH_CURVES%%:*})."
if [[ ${CDN_ENABLE} == yes ]]; then
    code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 10 \
            --resolve "${CDN_DOMAIN}:${SELF_SITE_PORT}:127.0.0.1" "https://${CDN_DOMAIN}:${SELF_SITE_PORT}/" || true)"
    [[ ${code} == 200 ]] || die "Виртуальный хост ${CDN_DOMAIN} не отвечает: '${code}'."
    log "Вход через CDN: https://${CDN_DOMAIN}${CDN_PATH} -> Xray 127.0.0.1:${CDN_XRAY_PORT}"
fi
