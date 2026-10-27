#!/usr/bin/env bash
# =============================================================================
#  Шаг 3. VPN-сервер ocserv (OpenConnect) поверх HTTPS (TLS 1.3 / DTLS 1.2)
#   - сертификат Let's Encrypt (ECDSA P-256) с автопродлением без разрыва сессий;
#   - аутентификация: пароль + TOTP (опционально);
#   - маскировка под обычный веб-сервер;
#   - собственный DNS-резолвер unbound для клиентов (без DNS-утечек).
# =============================================================================
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require_root
require_debian
load_config

log "Установка ocserv, certbot, unbound, oathtool"
apt-get update
apt_install ocserv certbot unbound dns-root-data oathtool qrencode gnutls-bin bind9-dnsutils jq gettext-base

# Модули ядра заранее: ocserv работает в песочнице и сам их не загрузит.
printf 'tun\nnf_conntrack\ntcp_bbr\n' > /etc/modules-load.d/vpn.conf
modprobe -a tun nf_conntrack tcp_bbr

# --- 1. Проверка DNS-записи --------------------------------------------------
resolved="$(getent ahostsv4 "${VPN_DOMAIN}" | awk '{print $1; exit}' || true)"
if [[ ${resolved} != "${WAN_IPV4}" ]]; then
    warn "${VPN_DOMAIN} указывает на '${resolved:-ничего}', а IP сервера ${WAN_IPV4}."
    warn "Let's Encrypt не выдаст сертификат, пока A-запись не исправлена."
    [[ -t 0 ]] && { read -r -p "Продолжить всё равно? [y/N] " a; [[ $a == [yY] ]] || exit 1; }
fi

# --- 2. TLS-сертификат --------------------------------------------------------
systemctl stop ocserv 2>/dev/null || true

if [[ ! -f /etc/letsencrypt/live/${VPN_DOMAIN}/fullchain.pem ]]; then
    log "Выпуск сертификата Let's Encrypt для ${VPN_DOMAIN} (ECDSA P-256)"
    certbot certonly --standalone --preferred-challenges http \
        --non-interactive --agree-tos -m "${ACME_EMAIL}" \
        --key-type ecdsa --elliptic-curve secp256r1 \
        -d "${VPN_DOMAIN}"
else
    log "Сертификат для ${VPN_DOMAIN} уже есть"
fi

# После продления — мягкая перезагрузка ocserv (SIGHUP): сессии не рвутся.
install -d /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/ocserv-reload.sh <<'EOF'
#!/bin/sh
systemctl reload ocserv
EOF
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/ocserv-reload.sh
systemctl enable --now certbot.timer

# --- 3. Конфигурация ocserv -------------------------------------------------
log "Конфигурация ocserv"
install -d -m 0750 /etc/ocserv
for f in ocpasswd users.oath; do
    [[ -f /etc/ocserv/$f ]] || install -m 0600 /dev/null "/etc/ocserv/$f"
    chmod 0600 "/etc/ocserv/$f"
done

if [[ ${ENABLE_OTP} == yes ]]; then
    OCSERV_AUTH_LINE='auth = "plain[passwd=/etc/ocserv/ocpasswd,otp=/etc/ocserv/users.oath]"'
else
    OCSERV_AUTH_LINE='auth = "plain[passwd=/etc/ocserv/ocpasswd]"'
fi

if [[ -z ${CAMOUFLAGE_SECRET} ]]; then
    CAMOUFLAGE_SECRET="$(openssl rand -hex 16)"
    sed -i "s/^CAMOUFLAGE_SECRET=.*/CAMOUFLAGE_SECRET=\"${CAMOUFLAGE_SECRET}\"/" "${CONFIG_FILE}"
    log "Сгенерирован CAMOUFLAGE_SECRET и сохранён в ${CONFIG_FILE}"
fi
OCSERV_CAMOUFLAGE_LINES="camouflage = true
camouflage_secret = \"${CAMOUFLAGE_SECRET}\"
camouflage_realm = \"Restricted Content\""

if [[ -n ${VPN_NET6} ]]; then
    OCSERV_IPV6_LINES="ipv6-network = ${VPN_NET6}
ipv6-subnet-prefix = 128"
else
    OCSERV_IPV6_LINES="# IPv6 в туннеле отключён (VPN_NET6 пуст)"
fi
export OCSERV_AUTH_LINE OCSERV_CAMOUFLAGE_LINES OCSERV_IPV6_LINES

render "${TEMPLATES_DIR}/ocserv/ocserv.conf.tpl" /etc/ocserv/ocserv.conf 0600 \
    VPN_DOMAIN VPN_NET4 VPN_GW4 MAX_CLIENTS MAX_SAME_CLIENTS VPN_MTU \
    OCSERV_AUTH_LINE OCSERV_CAMOUFLAGE_LINES OCSERV_IPV6_LINES
ocserv -t -c /etc/ocserv/ocserv.conf >/dev/null || die "ocserv -t: ошибка в /etc/ocserv/ocserv.conf"

install_file "${TEMPLATES_DIR}/systemd/ocserv-override.conf" /etc/systemd/system/ocserv.service.d/override.conf

# Аудит изменений конфигурации VPN и сертификатов (каталоги уже существуют).
if [[ -d /etc/audit/rules.d ]]; then
    install_file "${TEMPLATES_DIR}/audit/60-vpn-ocserv.rules" /etc/audit/rules.d/60-vpn-ocserv.rules 0640
    augenrules --load >/dev/null || warn "augenrules: правила аудита VPN не загрузились (auditctl -l)"
fi

# --- 4. DNS-резолвер для клиентов -----------------------------------------------
log "unbound (DNS для VPN-клиентов, DNSSEC)"
cpus="$(nproc)"
UNBOUND_THREADS=$(( cpus >= 32 ? 8 : (cpus >= 8 ? 4 : (cpus >= 2 ? 2 : 1)) ))
UNBOUND_SLABS=$(( UNBOUND_THREADS * 2 ))
UNBOUND_ACL6=""
[[ -n ${VPN_NET6} ]] && UNBOUND_ACL6="    access-control: ${VPN_NET6} allow"
export UNBOUND_THREADS UNBOUND_SLABS UNBOUND_ACL6
render "${TEMPLATES_DIR}/unbound/vpn.conf.tpl" /etc/unbound/unbound.conf.d/vpn.conf 0644 \
    VPN_NET4 UNBOUND_ACL6 UNBOUND_THREADS UNBOUND_SLABS
unbound-checkconf >/dev/null || die "unbound-checkconf: ошибка конфигурации"

# --- 5. Запуск ----------------------------------------------------------------
systemctl daemon-reload
systemctl enable unbound ocserv
systemctl restart unbound

# Исключения из туннеля по списку доменов (split-exclude.txt) + ежедневный таймер.
log "Исключения из туннеля (split exclude)"
bash "${PROJECT_DIR}/scripts/update-split-routes.sh" --no-reload \
    || warn "Исключения не применены — VPN работает в режиме «весь трафик в туннель»."
export PROJECT_DIR
render "${TEMPLATES_DIR}/systemd/vpn-split-routes.service.tpl" /etc/systemd/system/vpn-split-routes.service 0644 PROJECT_DIR
install_file "${TEMPLATES_DIR}/systemd/vpn-split-routes.timer" /etc/systemd/system/vpn-split-routes.timer
systemctl daemon-reload
systemctl enable --now vpn-split-routes.timer

systemctl restart ocserv
sleep 2
systemctl is-active --quiet ocserv || { journalctl -u ocserv -n 50 --no-pager; die "ocserv не запустился"; }

log "VPN-сервер запущен."
log "Адрес для клиентов:  https://${VPN_DOMAIN}/?${CAMOUFLAGE_SECRET}"
log "Добавьте пользователя: sudo ./scripts/vpn-user.sh add <имя>"
