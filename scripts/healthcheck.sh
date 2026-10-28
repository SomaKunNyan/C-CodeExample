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
if [[ -n ${REALITY_DEST} ]]; then
    dest_host="${REALITY_DEST%:*}"
    # Без ключа клиента сервер должен вести себя как сайт-маскировка:
    # отдавать его настоящий сертификат по TLS 1.3.
    proto="$(timeout 5 openssl s_client -connect "127.0.0.1:${XRAY_PORT}" -servername "${dest_host}" </dev/null 2>/dev/null \
             | awk -F': *' '/Protocol *:/{print $2; exit}')"
    if [[ $proto == TLSv1.3 ]]; then ok "без ключа сервер выглядит как ${dest_host} (TLS 1.3)"
    else bad "TLS-рукопожатие с маскировкой ${dest_host}: '${proto:-нет ответа}'"; fi
    chk "сайт-маскировка ${dest_host} доступен с сервера" \
        timeout 10 curl -s -o /dev/null --http2 "https://${dest_host}/"
fi

echo "== Сеть"
chk "BBR"                         bash -c "[[ \$(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]]"
chk "политика input = drop"       bash -c "nft list chain inet filter input | grep -q 'policy drop'"
chk "маршрутизация выключена"     bash -c "[[ \$(sysctl -n net.ipv4.ip_forward) == 0 ]]"
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
