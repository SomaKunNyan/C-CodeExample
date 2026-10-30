#!/usr/bin/env bash
# =============================================================================
#  Шаг 2. Межсетевой экран nftables (default deny): наружу только SSH и Xray.
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
else
    warn "SSH_ALLOW_FROM пуст: SSH доступен из интернета (rate-limit + fail2ban)."
    NFT_SSH_RULES+="$(ssh_rule_open)"$'\n'
fi

# Порт 80 — только для своего сайта-заглушки (Let's Encrypt + редирект на HTTPS).
NFT_HTTP_RULES=""
if [[ ${REALITY_SELF_SITE} == yes ]]; then
    NFT_HTTP_RULES="        tcp dport 80 accept"
fi
# --- Зеркало портов сайта маскировки (REALITY_MIRROR_PORTS) ----------------------
# У настоящего сайта открыты TCP/80 (редирект на HTTPS) и UDP/443 (HTTP/3), а у
# сервера, который под него маскируется, без этого они закрыты — заметное
# отличие для сканера. Пересылаем эти порты на сам сайт: снаружи сервер
# отвечает на них так же, как оригинал.
NFT_FORWARD_RULES="" NFT_MIRROR_TABLE="" MIRROR_IP=""
if [[ ${REALITY_MIRROR_PORTS} == yes ]]; then
    require_reality
    mirror_host="${REALITY_DEST%:*}" mirror_port="${REALITY_DEST##*:}"
    if [[ ${mirror_host} =~ ^[0-9.]+$ ]]; then
        MIRROR_IP="${mirror_host}"
    else
        MIRROR_IP="$(getent ahostsv4 "${mirror_host}" | awk '{print $1; exit}')"
    fi
    is_global_ip "${MIRROR_IP}" \
        || die "REALITY_MIRROR_PORTS: не удалось получить публичный IPv4 ${mirror_host} (получено: '${MIRROR_IP}')."
    log "Зеркало портов: TCP/80 и UDP/${XRAY_PORT} -> ${mirror_host} (${MIRROR_IP})"
    NFT_FORWARD_RULES="        # Только соединения, перенаправленные таблицей vpn_mirror; новые — с лимитом на адрес.
        iifname \"${WAN_IF}\" oifname \"${WAN_IF}\" ct status dnat ct state established,related accept
        iifname \"${WAN_IF}\" oifname \"${WAN_IF}\" ct status dnat ct state new add @mirror_meter4 { ip saddr limit rate 30/second burst 60 packets } accept"
    NFT_MIRROR_TABLE="# Зеркало портов сайта маскировки ${mirror_host} (REALITY_MIRROR_PORTS=\"yes\").
# IP сайта зафиксирован при генерации: если он сменится — перезапустите 02-firewall.sh.
table ip vpn_mirror {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname \"${WAN_IF}\" tcp dport 80 dnat to ${MIRROR_IP}:80
        iifname \"${WAN_IF}\" udp dport ${XRAY_PORT} dnat to ${MIRROR_IP}:${mirror_port}
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname \"${WAN_IF}\" ct status dnat masquerade
    }
}"
fi
# Вход VLESS Encryption без TLS (ENC_ENABLE) — отдельный TCP-порт.
NFT_ENC_RULES=""
if [[ ${ENC_ENABLE} == yes ]]; then
    NFT_ENC_RULES="        tcp dport ${ENC_PORT} accept"
fi
export NFT_SSH_RULES NFT_HTTP_RULES NFT_FORWARD_RULES NFT_MIRROR_TABLE NFT_ENC_RULES

# --- Генерация и проверка --------------------------------------------------------
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
envsubst '${XRAY_PORT} ${NFT_SSH_RULES} ${NFT_HTTP_RULES} ${NFT_FORWARD_RULES} ${NFT_MIRROR_TABLE} ${NFT_ENC_RULES}' \
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

# Маршрутизация клиентам не нужна (Xray — прокси). IPv4 forwarding включается только
# для зеркала портов; что именно пересылать, ограничивает цепочка forward (policy drop).
rm -f /etc/sysctl.d/91-vpn-forward.conf /etc/sysctl.d/91-no-forward.conf
fwd=0
[[ ${REALITY_MIRROR_PORTS} == yes ]] && fwd=1
printf 'net.ipv4.ip_forward = %s\nnet.ipv6.conf.all.forwarding = 0\n' "${fwd}" > /etc/sysctl.d/91-forward.conf
sysctl -p /etc/sysctl.d/91-forward.conf >/dev/null

# fail2ban создаёт свои таблицы в nftables — после flush ruleset перезапускаем.
systemctl is-active --quiet fail2ban && systemctl restart fail2ban

log "Firewall активен: $(nft list ruleset | grep -c 'accept') разрешающих правил."
