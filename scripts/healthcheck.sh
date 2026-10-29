#!/usr/bin/env bash
# =============================================================================
#  Проверка состояния сервера: службы, порты, REALITY, firewall, нагрузка.
#  Код возврата 0 = всё в порядке, 1 = есть проблемы (удобно для мониторинга).
# =============================================================================
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
trap - ERR
set +e

require_root
load_config

fail=0
ok()  { printf '  %s[OK]%s   %s\n' "$c_grn" "$c_rst" "$*"; }
bad() { printf '  %s[FAIL]%s %s\n' "$c_red" "$c_rst" "$*"; fail=1; }
chk() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

echo "== Службы"
for s in xray unbound nftables fail2ban ssh auditd chrony unattended-upgrades; do
    chk "$s активна" systemctl is-active --quiet "$s"
done

echo "== Порты"
chk "TCP/${XRAY_PORT} (Xray) слушается"  bash -c "ss -Htln 'sport = :${XRAY_PORT}' | grep -q ."
chk "SSH на порту ${SSH_PORT}"            bash -c "ss -Htln 'sport = :${SSH_PORT}' | grep -q ."
chk "API Xray только на localhost"        bash -c "ss -Htln 'sport = :${XRAY_API_PORT}' | grep -q '127.0.0.1:'"

echo "== REALITY"
chk "конфигурация Xray валидна" "${XRAY_BIN}" run -test -config "${XRAY_STORE}/config.json"
if [[ -n ${REALITY_DEST} || ${REALITY_SELF_SITE} == yes ]]; then
    require_reality
    dest_host="${REALITY_SNI}"
    # Без ключа клиента сервер должен вести себя как сайт-маскировка:
    # отдавать его настоящий сертификат по TLS 1.3.
    proto="$(timeout 5 openssl s_client -connect "127.0.0.1:${XRAY_PORT}" -servername "${dest_host}" </dev/null 2>/dev/null \
             | awk -F': *' '/Protocol *:/{print $2; exit}')"
    if [[ $proto == TLSv1.3 ]]; then ok "без ключа сервер выглядит как ${dest_host} (TLS 1.3)"
    else bad "TLS-рукопожатие с маскировкой ${dest_host}: '${proto:-нет ответа}'"; fi
    if [[ ${REALITY_SELF_SITE} == yes ]]; then
        chk "nginx (сайт-заглушка) активен" systemctl is-active --quiet nginx
        chk "сайт-заглушка отвечает по HTTP/2" bash -c "[[ \$(curl -s --noproxy '*' -o /dev/null -w '%{http_code} %{http_version}' --http2 --max-time 10 \
            --resolve '${dest_host}:${SELF_SITE_PORT}:127.0.0.1' 'https://${dest_host}:${SELF_SITE_PORT}/') == '200 2' ]]"
        cert="/etc/letsencrypt/live/${VPN_DOMAIN}/fullchain.pem"
        if [[ -f $cert ]]; then
            days=$(( ( $(date -d "$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))
            if (( days > 14 )); then ok "сертификат ${VPN_DOMAIN}: ещё ${days} дн."; else bad "сертификат ${VPN_DOMAIN} истекает через ${days} дн."; fi
        else
            bad "нет сертификата ${cert}"
        fi
    else
        chk "сайт-маскировка ${dest_host} доступен с сервера" \
            timeout 10 curl -s -o /dev/null --http2 "https://${dest_host}/"
        if [[ ${REALITY_MIRROR_PORTS} == yes ]]; then
            # IP сайта вписан в правила при запуске 02-firewall.sh — сверяем с текущим.
            mirror_host="${REALITY_DEST%:*}"
            cur_ip="$(getent ahostsv4 "${mirror_host}" | awk '{print $1}' | sort -u)"
            nft_ip="$(nft list table ip vpn_mirror 2>/dev/null | grep -oE 'dnat to [0-9.]+' | head -n1 | awk '{print $3}')"
            if [[ -z ${nft_ip} ]]; then bad "зеркало портов не загружено (запустите 02-firewall.sh)"
            elif grep -qx "${nft_ip}" <<<"${cur_ip}"; then ok "зеркало TCP/80, UDP/${XRAY_PORT} -> ${mirror_host} (${nft_ip})"
            else bad "IP ${mirror_host} сменился (${nft_ip} -> $(xargs <<<"${cur_ip}")): перезапустите 02-firewall.sh"; fi
        fi
    fi
fi

if [[ ${CDN_ENABLE} == yes ]]; then
    echo "== CDN (${CDN_DOMAIN})"
    chk "вход Xray для CDN слушает 127.0.0.1:${CDN_XRAY_PORT}" bash -c "ss -Htln 'sport = :${CDN_XRAY_PORT}' | grep -q '127.0.0.1:'"
    # Полный путь: интернет -> Cloudflare -> 443 -> REALITY (чужой SNI) -> nginx.
    chk "https://${CDN_DOMAIN}/ открывается через CDN" \
        bash -c "[[ \$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 'https://${CDN_DOMAIN}/') == 200 ]]"
fi

echo "== Сеть"
chk "BBR"                         bash -c "[[ \$(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]]"
chk "политика input = drop"       bash -c "nft list chain inet filter input | grep -q 'policy drop'"
if [[ ${REALITY_MIRROR_PORTS} == yes ]]; then
    chk "forward: политика drop"  bash -c "nft list chain inet filter forward | grep -q 'policy drop'"
else
    chk "маршрутизация выключена" bash -c "[[ \$(sysctl -n net.ipv4.ip_forward) == 0 ]]"
fi
ct=$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo 0)
ctmax=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 1)
if (( ct * 100 / ctmax < 80 )); then ok "conntrack: ${ct}/${ctmax}"; else bad "conntrack заполнен: ${ct}/${ctmax}"; fi
drops=$(ethtool -S "${WAN_IF}" 2>/dev/null | awk '/(rx_missed|rx_no_buffer|rx_dropped|discard)/{s+=$2} END{print s+0}')
ok "NIC ${WAN_IF}: потерянных пакетов (счётчики драйвера) = ${drops}"

echo "== DNS"
chk "unbound резолвит (DNSSEC)" bash -c "dig +short +dnssec @127.0.0.1 debian.org A | grep -q ."

echo "== VPN"
total=$(xray_py users 2>/dev/null | wc -l)
online=$("${XRAY_BIN}" api statsgetallonlineusers "--server=127.0.0.1:${XRAY_API_PORT}" 2>/dev/null \
         | jq -r '(.users // []) | length' 2>/dev/null || echo "?")
ok "пользователей: ${total}, онлайн сейчас: ${online}"

exit $fail
