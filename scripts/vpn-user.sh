#!/usr/bin/env bash
# =============================================================================
#  Управление пользователями VPN (Xray VLESS + REALITY).
#    vpn-user.sh add <user>            — создать и показать ссылку + QR-код
#    vpn-user.sh link <user>           — снова показать ссылку + QR-код
#    vpn-user.sh client-config <user>  — JSON-конфиг Xray для клиента (с исключениями)
#    vpn-user.sh reset <user>          — новый UUID (старая ссылка перестанет работать)
#    vpn-user.sh lock <user>           — заблокировать (сразу отключает)
#    vpn-user.sh unlock <user>         — разблокировать
#    vpn-user.sh del <user>            — удалить
#    vpn-user.sh list                  — пользователи, трафик, кто онлайн и с каких IP
# =============================================================================
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require_root
load_config
require_reality

usage() { sed -n '3,12p' "$0" | sed 's/^#  \{0,1\}//'; exit 1; }

check_name() {
    [[ ${1:-} =~ ^[a-z][a-z0-9._-]{1,31}$ ]] || die "Имя: латиница в нижнем регистре, цифры . _ - (2–32 символа)."
}

show_link() {
    local link
    link="$(xray_py link "$1")"
    echo
    log "Ссылка для клиента ${1} (импорт: «из буфера обмена» или сканированием QR):"
    echo
    echo "${link}"
    echo
    qrencode -t ANSIUTF8 "${link}"
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
        check_name "$user"; xray_py client-config "$user"
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
    *) usage ;;
esac
