#!/usr/bin/env bash
# =============================================================================
#  Управление пользователями VPN (Xray VLESS + REALITY).
#    vpn-user.sh add <user>            — создать и показать ссылку + QR-код
#    vpn-user.sh link <user> [вариант] — снова показать ссылки + QR-коды (все включённые
#                                        или одну: cdn, enc, mask, frag)
#    vpn-user.sh client-config <user> [вариант] — JSON-конфиг Xray для клиента (с исключениями)
#    vpn-user.sh reset <user>          — новый UUID (старая ссылка перестанет работать)
#    vpn-user.sh lock <user>           — заблокировать (сразу отключает)
#    vpn-user.sh unlock <user>         — разблокировать
#    vpn-user.sh del <user>            — удалить
#    vpn-user.sh list                  — пользователи, трафик, кто онлайн и с каких IP
#    vpn-user.sh selftest <user> [вариант] — подключиться к серверу с ключами
#                                        пользователя прямо с сервера (проверка без
#                                        телефона и сети); cdn — через CDN (полный путь
#                                        CDN -> сервер); enc — VLESS Encryption без TLS;
#                                        mask — REALITY в маске; frag — с фрагментацией
# =============================================================================
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require_root
load_config
require_reality

usage() { sed -n '3,14p' "$0" | sed 's/^#  \{0,1\}//'; exit 1; }

NGINX_ACCESS_LOG=/var/log/nginx/access.log

# Подсказка по журналу клиента для типичных ошибок настройки CDN.
# cdn_hint <журнал клиента> <первая строка access.log nginx, записанная во время теста>
cdn_hint() {
    local logf=$1 from=${2:-1} code path hits
    code="$(grep -oE '(unexpected status|bad status code:|response code:) *[0-9]{3}' "$logf" | grep -oE '[0-9]{3}$' | tail -n1 || true)"
    if grep -q 'redirects' "$logf"; then
        warn "Подсказка: CDN обращается к серверу по HTTP (порт 80), а nginx отвечает редиректом на"
        warn "  https://${VPN_DOMAIN}/ — получается петля. В CDN-ресурсе: протокол получения данных с источника"
        warn "  HTTPS, порт 443 (Cloudflare: SSL/TLS = Full (strict), не Flexible)."
    elif grep -qiE 'x509|certificate' "$logf"; then
        warn "Подсказка: у CDN нет действующего сертификата на ${CDN_DOMAIN} — выпустите его в настройках CDN-ресурса."
    elif [[ $code == 404 ]]; then
        warn "Подсказка: 404 — запрос дошёл до сервера, но не на вход VPN. В CDN-ресурсе заголовок Host"
        warn "  (Gcore: «Переопределение заголовка Host») должен быть ${CDN_DOMAIN}."
    elif [[ $code =~ ^(5[0-9][0-9])$ ]]; then
        warn "Подсказка: ${code} — CDN не получил ответа от сервера: источник ${PUBLIC_IPV4:-IP сервера}, HTTPS, порт 443;"
        warn "  на сервере: ss -tlnp | grep ${CDN_XRAY_PORT}; ресурс CDN может ещё активироваться."
    elif [[ $code =~ ^4 ]]; then
        warn "Подсказка: ${code} — CDN отклоняет запрос: проверьте, что разрешены методы GET и POST и выключены WAF/лимиты."
    fi
    # Кто ответил ошибкой: если запросов с секретным путём нет в журнале nginx, до сервера
    # они не дошли — ответ даёт сам CDN.
    [[ -n $code && -r ${NGINX_ACCESS_LOG} ]] || return 0
    path="$(xray_py cdn-path)"
    hits="$(tail -n +"${from}" "${NGINX_ACCESS_LOG}" | grep -F " ${path}" || true)"
    if [[ -z $hits ]]; then
        warn "  Запросы к ${path} до сервера НЕ дошли (их нет в ${NGINX_ACCESS_LOG}): ответ ${code} даёт сам CDN."
        warn "  В CDN-ресурсе: разрешённые методы (GET, POST), WAF/защита, ограничения по странам/IP/Referer/User-Agent,"
        warn "  тип контента (динамический, не «только статика»); затем очистите кэш ресурса (Purge all)."
    else
        warn "  Запросы дошли до сервера, ответы nginx (последние):"
        tail -n 5 <<<"$hits" >&2
    fi
}

check_name() {
    [[ ${1:-} =~ ^[a-z][a-z0-9._-]{1,31}$ ]] || die "Имя: латиница в нижнем регистре, цифры . _ - (2–32 символа)."
}

# show_link <user> [вариант] — без варианта: все включённые входы.
show_link() {
    local link variant title variants=("")
    if [[ -n ${2:-} ]]; then
        variants=("$2")
    else
        [[ ${CDN_ENABLE} == yes ]] && variants+=(cdn)
        [[ ${ENC_ENABLE} == yes ]] && variants+=(enc)
        [[ ${MASK_ENABLE} == yes ]] && variants+=(mask)
    fi
    for variant in "${variants[@]}"; do
        link="$(xray_py link "$1" ${variant:+"$variant"})"
        case "$variant" in
            cdn) title="CDN (${CDN_DOMAIN}) — запасной вариант, если прямое подключение режется" ;;
            enc) title="VLESS Encryption без TLS (порт ${ENC_PORT}) — эксперимент, только клиенты на ядре Xray" ;;
            mask) title="REALITY в маске sudoku (порт ${MASK_PORT}) — эксперимент, нужен клиент с finalmask (v2rayNG 2.3.14+)" ;;
            frag) title="REALITY с фрагментацией ClientHello — эксперимент, нужен клиент с finalmask (v2rayNG 2.3.14+)" ;;
            *)   title="REALITY — напрямую на сервер" ;;
        esac
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
        check_name "$user"; show_link "$user" "${3:-}"
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
        [[ $variant =~ ^(|cdn|enc|mask|frag)$ ]] || die "selftest <user> [cdn|enc|mask|frag]"
        work="$(mktemp -d)"
        trap 'kill "${pid:-}" 2>/dev/null; rm -rf "${work}"' EXIT
        # Прямые варианты — к 127.0.0.1 (проверка сервера); CDN — по настоящему адресу
        # через CDN (проверка всей цепочки CDN -> 443 -> nginx -> Xray).
        addr_filter='.outbounds[0].settings.vnext[0].address = "127.0.0.1" |'
        [[ $variant == cdn ]] && addr_filter=""
        xray_py client-config "$user" ${variant:+"$variant"} | jq "
            ${addr_filter}
            .inbounds = [{\"tag\":\"socks\",\"listen\":\"127.0.0.1\",\"port\":10899,\"protocol\":\"socks\"}]
            | .routing.rules = []
            | .log.loglevel = \"debug\"" > "${work}/client.json"
        ngx_from=$(( $(wc -l < "${NGINX_ACCESS_LOG}" 2>/dev/null || echo 0) + 1 ))
        "${XRAY_BIN}" run -config "${work}/client.json" > "${work}/client.log" 2>&1 &
        pid=$!
        sleep 2
        if ip="$(curl -s --max-time 15 -x socks5h://127.0.0.1:10899 https://ifconfig.me)" && [[ -n $ip ]]; then
            log "Самопроверка пройдена: через VPN виден IP ${ip}."
            log "Сервер и ключи в порядке — ищите причину в клиенте (настройки, TLS-трюки) или в сети."
        else
            warn "Самопроверка НЕ пройдена. Журнал клиента:"
            grep -Ei 'reality|error|fail|warn|xhttp|tls' "${work}/client.log" | tail -n 20
            [[ $variant == cdn ]] && cdn_hint "${work}/client.log" "${ngx_from}"
            warn "Журнал сервера: journalctl -u xray -n 50 --no-pager"
            exit 1
        fi
        ;;
    *) usage ;;
esac
