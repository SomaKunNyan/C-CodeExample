#!/usr/bin/env bash
# =============================================================================
#  Шаг 2. Межсетевой экран nftables (default deny) + NAT для VPN.
#  Применение с автоматическим откатом: если в течение 60 секунд не
#  подтвердить, что SSH работает, — восстанавливаются прежние правила.
# =============================================================================
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require_root
require_debian
load_config

apt_install nftables gettext-base

# --- Правила SSH ---------------------------------------------------------------
# Открытый всем SSH: не более 6 новых подключений в минуту с одного адреса.
ssh_rule_open() {
    printf '        tcp dport %s ct state new add @ssh_meter4 { ip saddr limit rate 6/minute burst 4 packets } accept\n' "${SSH_PORT}"
    printf '        tcp dport %s ct state new add @ssh_meter6 { ip6 saddr limit rate 6/minute burst 4 packets } accept\n' "${SSH_PORT}"
}

NFT_SSH_RULES=""
if [[ -n ${SSH_ALLOW_FROM} ]]; then
    v4="" v6=""
    for n in ${SSH_ALLOW_FROM}; do
        if [[ $n == *:* ]]; then v6+="${v6:+, }$n"; else v4+="${v4:+, }$n"; fi
    done
    [[ -n $v4 ]] && NFT_SSH_RULES+="        ip saddr { ${v4} } tcp dport ${SSH_PORT} accept"$'\n'
    [[ -n $v6 ]] && NFT_SSH_RULES+="        ip6 saddr { ${v6} } tcp dport ${SSH_PORT} accept"$'\n'
    [[ ${SSH_FROM_VPN} == yes ]] && NFT_SSH_RULES+="        iifname \"vpns*\" ip saddr ${VPN_NET4} tcp dport ${SSH_PORT} accept"$'\n'
else
    warn "SSH_ALLOW_FROM пуст: SSH доступен из интернета (rate-limit + fail2ban)."
    NFT_SSH_RULES+="$(ssh_rule_open)"$'\n'
fi

# --- IPv6 внутри туннеля --------------------------------------------------------
NFT_INPUT6_DNS="" NFT_FORWARD6="" NFT_NAT6=""
if [[ -n ${VPN_NET6} ]]; then
    NFT_INPUT6_DNS="        iifname \"vpns*\" ip6 saddr ${VPN_NET6} meta l4proto { tcp, udp } th dport 53 accept"
    NFT_FORWARD6="        iifname \"vpns*\" oifname \"${WAN_IF}\" ip6 saddr ${VPN_NET6} accept"
    NFT_NAT6="table ip6 nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname \"${WAN_IF}\" ip6 saddr ${VPN_NET6} masquerade
    }
}"
fi
export NFT_SSH_RULES NFT_INPUT6_DNS NFT_FORWARD6 NFT_NAT6

# --- Генерация и проверка --------------------------------------------------------
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
envsubst '${WAN_IF} ${WAN_IPV4} ${VPN_NET4} ${NFT_SSH_RULES} ${NFT_INPUT6_DNS} ${NFT_FORWARD6} ${NFT_NAT6}' \
    < "${TEMPLATES_DIR}/nftables/nftables.conf.tpl" > "$tmp"
nft -c -f "$tmp" || die "Синтаксическая ошибка в сгенерированных правилах ($tmp)."

# --- Применение с откатом -------------------------------------------------------
backup_file /etc/nftables.conf
saved="$(mktemp)"
nft list ruleset > "$saved"

log "Применяю новые правила nftables"
nft -f "$tmp"

if [[ -t 0 ]]; then
    warn "Откройте НОВУЮ SSH-сессию (порт ${SSH_PORT}) и убедитесь, что вход работает."
    if read -r -t 60 -p "Введите 'yes' в течение 60 секунд для подтверждения: " ans && [[ $ans == yes ]]; then
        log "Подтверждено."
    else
        warn "Нет подтверждения — откатываю правила."
        nft flush ruleset
        nft -f "$saved"
        rm -f "$saved"
        die "Правила откатаны. Проверьте SSH_PORT / SSH_ALLOW_FROM в config.env."
    fi
else
    warn "Неинтерактивный запуск: подтверждение пропущено."
fi
rm -f "$saved"

install -m 0600 "$tmp" /etc/nftables.conf
systemctl enable nftables
systemctl restart nftables

# IP forwarding — нужен для маршрутизации трафика клиентов.
{
    echo "net.ipv4.ip_forward = 1"
    if [[ -n ${VPN_NET6} ]]; then
        echo "net.ipv6.conf.all.forwarding = 1"
        # При forwarding=1 ядро игнорирует Router Advertisement; если IPv6 на
        # WAN получен через SLAAC — сохраняем его.
        echo "net.ipv6.conf.${WAN_IF}.accept_ra = 2"
    fi
} > /etc/sysctl.d/91-vpn-forward.conf
sysctl -p /etc/sysctl.d/91-vpn-forward.conf >/dev/null

# fail2ban создаёт свои таблицы в nftables — после flush ruleset перезапускаем.
systemctl is-active --quiet fail2ban && systemctl restart fail2ban

log "Firewall активен: $(nft list ruleset | grep -c 'accept') разрешающих правил."
