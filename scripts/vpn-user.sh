#!/usr/bin/env bash
# =============================================================================
#  Управление пользователями VPN (Xray VLESS + REALITY).
#    vpn-user.sh add <user>            — создать и показать ссылку + QR-код
#    vpn-user.sh link <user>           — снова показать ссылку + QR-код
#    vpn-user.sh client-config <user> [cdn] — JSON-конфиг Xray для клиента (с исключениями)
#    vpn-user.sh reset <user>          — новый UUID (старая ссылка перестанет работать)
#    vpn-user.sh lock <user>           — заблокировать (сразу отключает)
#    vpn-user.sh unlock <user>         — разблокировать
#    vpn-user.sh del <user>            — удалить
#    vpn-user.sh list                  — пользователи, трафик, кто онлайн и с каких IP
#    vpn-user.sh selftest <user> [cdn] — подключиться к серверу с ключами пользователя
#                                        прямо с сервера (проверка без телефона и сети);
#                                        cdn — через CDN (полный путь CDN -> сервер)
# =============================================================================
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require_root
load_config
require_reality

usage() { sed -n '3,14p' "$0" | sed 's/^#  \{0,1\}//'; exit 1; }

check_name() {
    [[ ${1:-} =~ ^[a-z][a-z0-9._-]{1,31}$ ]] || die "Имя: латиница в нижнем регистре, цифры . _ - (2–32 символа)."
}

show_link() {
    local link variant title
    for variant in "" ${CDN_ENABLE/#yes/cdn}; do
        [[ $variant == no ]] && continue
        link="$(xray_py link "$1" ${variant:+"$variant"})"
        title="REALITY — напрямую на сервер"
        [[ $variant == cdn ]] && title="CDN (${CDN_DOMAIN}) — запасной вариант, если прямое подключение режется"
        echo
        log "Ссылка для ${1}: ${title}"
        echo
        echo "${link}"
        echo
        qrencode -t ANSIUTF8 "${link}"
    done
    warn "Ссылка = доступ к VPN. Передавайте её только владельцу, по защищённому каналу."
}

cmd=${1:-}; user=${2:-}
case "$cmd" in
    add)
        check_name "$user"
        xray_py add "$user" "$("${XRAY_BIN}" uuid)"
        xray_apply
        show_link "$user"
        ;;
    link)
        check_name "$user"; show_link "$user"
        ;;
    client-config)
        check_name "$user"; xray_py client-config "$user" ${3:+"$3"}
        ;;
    reset)
        check_name "$user"
        xray_py del "$user"
        xray_py add "$user" "$("${XRAY_BIN}" uuid)"
        xray_apply
        show_link "$user"
        ;;
    lock)
        check_name "$user"; xray_py set "$user" disabled; xray_apply
        log "${user} заблокирован."
        ;;
    unlock)
        check_name "$user"; xray_py set "$user" enabled; xray_apply
        log "${user} разблокирован."
        ;;
    del)
        check_name "$user"; xray_py del "$user"; xray_apply
        log "${user} удалён."
        ;;
    list)
        XRAY_BIN="${XRAY_BIN}" xray_py list
        ;;
    selftest)
        # Настоящий клиент Xray с параметрами из ссылки пользователя подключается к
        # серверу через 127.0.0.1 и открывает сайт. Успех = сервер, ключи, SNI и
        # shortId в порядке; значит, проблема в клиентском приложении или в сети.
        check_name "$user"
        variant="${3:-}"
        [[ -z $variant || $variant == cdn ]] || die "selftest <user> [cdn]"
        [[ $variant != cdn || ${CDN_ENABLE} == yes ]] || die "CDN не включён (CDN_ENABLE)."
        work="$(mktemp -d)"
        trap 'kill "${pid:-}" 2>/dev/null; rm -rf "${work}"' EXIT
        # Прямой вариант — к 127.0.0.1 (проверка сервера); CDN — по настоящему адресу
        # через CDN (проверка всей цепочки CDN -> 443 -> nginx -> Xray).
        addr_filter='.outbounds[0].settings.vnext[0].address = "127.0.0.1" |'
        [[ $variant == cdn ]] && addr_filter=""
        xray_py client-config "$user" ${variant:+"$variant"} | jq "
            ${addr_filter}
            .inbounds = [{\"tag\":\"socks\",\"listen\":\"127.0.0.1\",\"port\":10899,\"protocol\":\"socks\"}]
            | .routing.rules = []
            | .log.loglevel = \"debug\"" > "${work}/client.json"
        "${XRAY_BIN}" run -config "${work}/client.json" > "${work}/client.log" 2>&1 &
        pid=$!
        sleep 2
        if ip="$(curl -s --max-time 15 -x socks5h://127.0.0.1:10899 https://ifconfig.me)" && [[ -n $ip ]]; then
            log "Самопроверка пройдена: через VPN виден IP ${ip}."
            log "Сервер и ключи в порядке — ищите причину в клиенте (настройки, TLS-трюки) или в сети."
        else
            warn "Самопроверка НЕ пройдена. Журнал клиента:"
            grep -Ei 'reality|error|fail|warn|xhttp|tls' "${work}/client.log" | tail -n 20
            warn "Журнал сервера: journalctl -u xray -n 50 --no-pager"
            exit 1
        fi
        ;;
    *) usage ;;
esac
