#!/usr/bin/env bash
# =============================================================================
#  Управление пользователями VPN.
#    vpn-user.sh add <user>      — создать (пароль + TOTP с QR-кодом)
#    vpn-user.sh passwd <user>   — сменить пароль
#    vpn-user.sh otp <user>      — перевыпустить TOTP (потерян телефон)
#    vpn-user.sh lock <user>     — заблокировать и отключить
#    vpn-user.sh unlock <user>   — разблокировать
#    vpn-user.sh del <user>      — удалить и отключить
#    vpn-user.sh list            — все пользователи и активные сессии
# =============================================================================
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require_root
load_config

PASSWD_FILE=/etc/ocserv/ocpasswd
OATH_FILE=/etc/ocserv/users.oath

usage() { sed -n '3,11p' "$0" | sed 's/^#  \{0,1\}//'; exit 1; }

check_name() {
    [[ ${1:-} =~ ^[a-z][a-z0-9._-]{1,31}$ ]] || die "Имя: латиница в нижнем регистре, цифры . _ - (2–32 символа)."
}

user_exists() { grep -q "^$1:" "${PASSWD_FILE}"; }

new_otp() {
    local user=$1 tmp hex b32 uri
    tmp="$(mktemp)"
    head -c 20 /dev/urandom > "$tmp"
    hex="$(od -An -tx1 "$tmp" | tr -d ' \n')"
    b32="$(base32 < "$tmp" | tr -d '=\n')"
    rm -f "$tmp"

    # Формат liboath: HOTP/T30/6 = TOTP, шаг 30 с, 6 цифр.
    sed -i "/^HOTP\/T30\/6[[:space:]]\+${user}[[:space:]]/d" "${OATH_FILE}"
    printf 'HOTP/T30/6\t%s\t-\t%s\n' "$user" "$hex" >> "${OATH_FILE}"
    chmod 0600 "${OATH_FILE}"

    uri="otpauth://totp/VPN:${user}@${VPN_DOMAIN}?secret=${b32}&issuer=VPN-${VPN_DOMAIN}&digits=6&period=30"
    echo
    log "Отсканируйте QR-код в Google Authenticator / Aegis / FreeOTP:"
    qrencode -t ANSIUTF8 "$uri"
    echo "Или введите ключ вручную: ${b32}"
    echo
    warn "Ключ показывается один раз. Не сохраняйте снимок экрана в общих местах."
}

disconnect() { occtl disconnect user "$1" >/dev/null 2>&1 || true; }

cmd=${1:-}; user=${2:-}
case "$cmd" in
    add)
        check_name "$user"
        user_exists "$user" && die "Пользователь ${user} уже существует."
        log "Пароль для ${user} (минимум 14 символов, лучше — сгенерированный):"
        ocpasswd -c "${PASSWD_FILE}" "$user"
        [[ ${ENABLE_OTP} == yes ]] && new_otp "$user"
        echo "Подключение: https://${VPN_DOMAIN}/?${CAMOUFLAGE_SECRET}"
        ;;
    passwd)
        check_name "$user"; user_exists "$user" || die "Нет пользователя ${user}."
        ocpasswd -c "${PASSWD_FILE}" "$user"
        ;;
    otp)
        check_name "$user"; user_exists "$user" || die "Нет пользователя ${user}."
        new_otp "$user"; disconnect "$user"
        ;;
    lock)
        check_name "$user"; ocpasswd -c "${PASSWD_FILE}" -l "$user"; disconnect "$user"
        log "${user} заблокирован."
        ;;
    unlock)
        check_name "$user"; ocpasswd -c "${PASSWD_FILE}" -u "$user"
        log "${user} разблокирован."
        ;;
    del)
        check_name "$user"
        ocpasswd -c "${PASSWD_FILE}" -d "$user"
        sed -i "/^HOTP\/T30\/6[[:space:]]\+${user}[[:space:]]/d" "${OATH_FILE}"
        disconnect "$user"
        log "${user} удалён."
        ;;
    list)
        echo "== Пользователи (! = заблокирован) =="
        cut -d: -f1,3 "${PASSWD_FILE}" | awk -F: '{print ($2 ~ /^!/ ? "! " : "  ") $1}'
        echo
        echo "== Активные сессии =="
        occtl show users
        ;;
    *) usage ;;
esac
