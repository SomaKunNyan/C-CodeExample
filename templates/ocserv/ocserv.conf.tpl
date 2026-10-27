# =============================================================================
#  ocserv — OpenConnect VPN Server (протокол AnyConnect/OpenConnect)
#  Сгенерировано scripts/03-install-vpn.sh из templates/ocserv/ocserv.conf.tpl
#  Не редактируйте вручную на сервере — правьте шаблон и перезапускайте скрипт.
#
#  Транспорт:
#    * управляющий канал + данные: TLS 1.3/1.2 поверх TCP/443 (обычный HTTPS);
#    * быстрый канал данных: DTLS 1.2 поверх UDP/443 (если UDP доступен).
#  Если UDP блокируется по пути, трафик автоматически идёт через TCP/443 —
#  соединение не рвётся, а для DPI это выглядит как обычный HTTPS.
# =============================================================================

# --- Аутентификация ----------------------------------------------------------
${OCSERV_AUTH_LINE}

# --- Сеть / порты -------------------------------------------------------------
tcp-port = 443
udp-port = 443

# Привилегии, изоляция
run-as-user = ocserv
run-as-group = ocserv
socket-file = /run/ocserv-socket
chroot-dir = /var/lib/ocserv
# Каждый worker (один на клиента) изолирован seccomp-фильтром.
isolate-workers = true

# --- TLS ---------------------------------------------------------------------
server-cert = /etc/letsencrypt/live/${VPN_DOMAIN}/fullchain.pem
server-key  = /etc/letsencrypt/live/${VPN_DOMAIN}/privkey.pem

# Только TLS 1.3 и TLS 1.2, только AEAD-шифры (AES-GCM / ChaCha20-Poly1305),
# только обмен ключами с PFS (ECDHE), без RSA key exchange, без CBC и SHA1.
tls-priorities = "NORMAL:%SERVER_PRECEDENCE:-VERS-ALL:+VERS-TLS1.3:+VERS-TLS1.2:+VERS-DTLS1.2:-RSA:-DHE-RSA:-AES-128-CBC:-AES-256-CBC:-CAMELLIA-128-CBC:-CAMELLIA-256-CBC:-3DES-CBC:-AES-128-CCM:-AES-256-CCM:-ARCFOUR-128:-SHA1:-MD5:-SIGN-RSA-SHA1:-SIGN-ECDSA-SHA1"

# Совместимость с Cisco Secure Client (AnyConnect) — без неё он не подключится.
# Опция подразумевает dtls-legacy = true, но устаревшие DTLS-шифры (CBC/SHA1)
# всё равно отсечены tls-priorities выше: современный клиент договорится о
# DTLS 1.2 + AES-GCM, а очень старый — уйдёт в TLS 1.2/1.3 поверх TCP.
# Если используются только клиенты OpenConnect — можно поставить false.
cisco-client-compat = true

# --- Защита от перебора ------------------------------------------------------
auth-timeout = 120
min-reauth-time = 300
max-ban-score = 80
ban-reset-time = 1200
ban-points-wrong-password = 10
ban-points-connection = 1
rate-limit-ms = 100

# --- Стабильность соединения -------------------------------------------------
# Клиент шлёт keepalive каждые 30 с — NAT-сессии у провайдеров не протухают.
keepalive = 30
# Dead Peer Detection: обнаружение «мёртвого» канала.
dpd = 60
mobile-dpd = 300
# Если DTLS (UDP) молчит дольше 25 с — данные идут через TLS (TCP).
switch-to-tcp-timeout = 25
# Автоподбор MTU в DTLS — меньше фрагментации и потерь.
try-mtu-discovery = true
mtu = ${VPN_MTU}

# Переподключение без повторного ввода пароля/OTP при смене сети
# (Wi-Fi -> LTE, смена IP): cookie сессии живёт 5 минут после обрыва
# и переживает перезапуск ocserv.
cookie-timeout = 300
persistent-cookies = true
deny-roaming = false

# Клиент получает один и тот же IP при переподключении.
predictable-ips = true
ping-leases = false

# Плавный дренаж при перезапуске/обновлении.
server-drain-ms = 2000

# --- Масштаб ------------------------------------------------------------------
max-clients = ${MAX_CLIENTS}
max-same-clients = ${MAX_SAME_CLIENTS}

# --- Маскировка под обычный веб-сервер ---------------------------------------
${OCSERV_CAMOUFLAGE_LINES}

# --- Адресация клиентов -------------------------------------------------------
device = vpns
ipv4-network = ${VPN_NET4}
${OCSERV_IPV6_LINES}

# Весь трафик клиента — в туннель (full tunnel), DNS — только через VPN.
route = default

# Исключения из туннеля (split exclude): сети, к которым клиент ходит напрямую.
# Блок между маркерами генерирует scripts/update-split-routes.sh из списка
# доменов (split-exclude.txt). Не редактируйте вручную — правки пропадут.
# >>> split-exclude
# <<< split-exclude

tunnel-all-dns = true
dns = ${VPN_GW4}

# Не отдаём клиентам доступ к служебным сетям самого сервера / ДЦ.
# (Дополнительно это enforced в nftables, см. /etc/nftables.conf.)

# --- Служебное -----------------------------------------------------------------
use-occtl = true
pid-file = /run/ocserv.pid
log-level = 1
server-stats-reset-time = 604800
stats-report-time = 360

# Сертификат перечитывается по SIGHUP без разрыва сессий:
#   systemctl reload ocserv   (вызывается deploy-hook'ом certbot)
