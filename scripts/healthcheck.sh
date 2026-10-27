#!/usr/bin/env bash
# =============================================================================
#  Проверка состояния сервера: службы, порты, сертификат, firewall, нагрузка.
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
for s in ocserv unbound nftables fail2ban ssh auditd chrony unattended-upgrades; do
    chk "$s активна" systemctl is-active --quiet "$s"
done

echo "== Порты"
chk "TCP/443 (TLS) слушается"   bash -c "ss -Htln 'sport = :443' | grep -q ."
chk "UDP/443 (DTLS) слушается"  bash -c "ss -Huln 'sport = :443' | grep -q ."
chk "SSH на порту ${SSH_PORT}"  bash -c "ss -Htln 'sport = :${SSH_PORT}' | grep -q ."

echo "== TLS"
cert="/etc/letsencrypt/live/${VPN_DOMAIN}/fullchain.pem"
if [[ -f $cert ]]; then
    end="$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)"
    days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
    if (( days > 14 )); then ok "сертификат действителен ещё ${days} дн."; else bad "сертификат истекает через ${days} дн."; fi
else
    bad "сертификат не найден: $cert"
fi
proto="$(timeout 5 openssl s_client -connect "127.0.0.1:443" -servername "${VPN_DOMAIN}" </dev/null 2>/dev/null | awk -F': *' '/Protocol *:/{print $2; exit}')"
if [[ $proto == TLSv1.3 ]]; then ok "TLS-рукопожатие: ${proto}"; else bad "TLS-рукопожатие: '${proto:-нет ответа}'"; fi
chk "TLS 1.1 отвергается" bash -c "! timeout 5 openssl s_client -connect 127.0.0.1:443 -tls1_1 </dev/null 2>/dev/null | grep -q 'Cipher is [A-Z]'"

echo "== Сеть"
chk "IP forwarding включён"       bash -c "[[ \$(sysctl -n net.ipv4.ip_forward) == 1 ]]"
chk "BBR"                          bash -c "[[ \$(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]]"
chk "NAT для ${VPN_NET4}"          bash -c "nft list table ip nat | grep -q '${VPN_NET4}'"
chk "политика input = drop"        bash -c "nft list chain inet filter input | grep -q 'policy drop'"
ct=$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo 0)
ctmax=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 1)
if (( ct * 100 / ctmax < 80 )); then ok "conntrack: ${ct}/${ctmax}"; else bad "conntrack заполнен: ${ct}/${ctmax}"; fi
drops=$(ethtool -S "${WAN_IF}" 2>/dev/null | awk '/(rx_missed|rx_no_buffer|rx_dropped|discard)/{s+=$2} END{print s+0}')
ok "NIC ${WAN_IF}: потерянных пакетов (счётчики драйвера) = ${drops}"

echo "== DNS для клиентов"
chk "unbound резолвит и валидирует DNSSEC" bash -c "dig +short +dnssec @127.0.0.1 debian.org A | grep -q ."

echo "== VPN"
users=$(occtl -j show users 2>/dev/null | jq length 2>/dev/null || echo "?")
ok "подключено пользователей: ${users}"
occtl show status 2>/dev/null | grep -E 'Up since|Active sessions|Total sessions|Server PID' | sed 's/^/        /'

exit $fail
