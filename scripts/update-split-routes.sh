#!/usr/bin/env bash
# =============================================================================
#  Обновление исключений из туннеля (split exclude) по списку доменов.
#    update-split-routes.sh              — обновить и перечитать ocserv (reload)
#    update-split-routes.sh --no-reload  — только обновить конфиг (из 03-install-vpn.sh)
#    update-split-routes.sh --show       — показать текущие исключения
#
#  Список: SPLIT_EXCLUDE_FILE (по умолчанию split-exclude.txt в корне проекта).
#  Нет файла или он пуст — исключений нет, весь трафик идёт в туннель.
#  Запускается ежедневно таймером vpn-split-routes.timer.
# =============================================================================
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require_root
load_config

OCSERV_CONF=/etc/ocserv/ocserv.conf
STATE_FILE=/var/lib/vpn-https-debian/split-exclude-state.json
BEGIN_MARK='# >>> split-exclude'
END_MARK='# <<< split-exclude'

count_routes() { grep -c '^no-route' "$1" || true; }

reload=yes
case "${1:-}" in
    --no-reload) reload=no ;;
    --show) sed -n "/^${BEGIN_MARK}/,/^${END_MARK}/p" "${OCSERV_CONF}"; exit 0 ;;
    "") ;;
    *) sed -n '3,11p' "$0" | sed 's/^#  \{0,1\}//'; exit 1 ;;
esac

if ! grep -qxF "${BEGIN_MARK}" "${OCSERV_CONF}" || ! grep -qxF "${END_MARK}" "${OCSERV_CONF}"; then
    die "В ${OCSERV_CONF} нет блока split-exclude. Перезапустите scripts/03-install-vpn.sh."
fi

routes="$(mktemp)"; newconf="$(mktemp)"
trap 'rm -f "$routes" "$newconf"' EXIT

# Пересылка DNS-запросов к доменам из списка на SPLIT_DNS_FORWARDERS.
# Нужна для сервисов, чьи DNS-серверы не отвечают на запросы из страны, где
# стоит VPN-сервер: иначе ни скрипт, ни VPN-клиенты (их DNS — unbound на
# сервере) не смогут разрешить такие домены. forward-first: если форвардеры
# недоступны, unbound резолвит сам.
update_unbound_forward() {
    local conf=/etc/unbound/unbound.conf.d/split-exclude-forward.conf
    local tmp domains d a
    tmp="$(mktemp)"
    {
        echo "# Сгенерировано scripts/update-split-routes.sh — не редактировать вручную."
        if [[ -n ${SPLIT_DNS_FORWARDERS} && -s ${SPLIT_EXCLUDE_FILE} ]]; then
            domains="$(python3 "${PROJECT_DIR}/scripts/split-routes.py" --list "${SPLIT_EXCLUDE_FILE}" \
                       --state /dev/null --print-domains 2>/dev/null)"
            for d in ${domains}; do
                echo "forward-zone:"
                echo "    name: \"${d}.\""
                for a in ${SPLIT_DNS_FORWARDERS}; do echo "    forward-addr: ${a}"; done
                echo "    forward-first: yes"
            done
        fi
    } > "$tmp"

    if cmp -s "$tmp" "$conf"; then rm -f "$tmp"; return 0; fi
    backup_file "$conf"
    install -m 0644 "$tmp" "$conf"; rm -f "$tmp"
    local msg="DNS: домены из списка пересылаются на ${SPLIT_DNS_FORWARDERS}"
    [[ -n ${SPLIT_DNS_FORWARDERS} ]] || msg="DNS: пересылка отключена (SPLIT_DNS_FORWARDERS пуст)"
    if ! unbound-checkconf >/dev/null 2>&1; then
        warn "unbound-checkconf отверг пересылку DNS (проверьте SPLIT_DNS_FORWARDERS) — отключаю её."
        echo "# отключено: ошибка конфигурации, см. unbound-checkconf" > "$conf"
        msg="DNS: пересылка НЕ включена"
    fi
    if systemctl is-active --quiet unbound; then
        systemctl reload unbound
        sleep 1
    fi
    log "$msg"
}

if [[ -d /etc/unbound/unbound.conf.d ]]; then
    update_unbound_forward
fi

if [[ -s ${SPLIT_EXCLUDE_FILE} ]]; then
    # Резолвим через unbound (как VPN-клиенты) и напрямую через форвардеры.
    resolvers=()
    if dig +short +time=2 +tries=1 debian.org @127.0.0.1 >/dev/null 2>&1; then
        resolvers+=(--resolver 127.0.0.1)
    else
        resolvers+=(--resolver system)
    fi
    for a in ${SPLIT_DNS_FORWARDERS}; do resolvers+=(--resolver "$a"); done

    py_args=(--list "${SPLIT_EXCLUDE_FILE}" --state "${STATE_FILE}"
             "${resolvers[@]}" --v4-prefix "${SPLIT_V4_PREFIX}"
             --v6-prefix "${SPLIT_V6_PREFIX}" --keep-days "${SPLIT_KEEP_DAYS}"
             --max-routes "${SPLIT_MAX_ROUTES}" --protect "${VPN_NET4}"
             --protect "${WAN_IPV4}/32")
    [[ -n ${VPN_NET6} ]] && py_args+=(--ipv6 --protect "${VPN_NET6}")

    python3 "${PROJECT_DIR}/scripts/split-routes.py" "${py_args[@]}" > "$routes" \
        || die "Исключения не обновлены, ocserv работает с прежним списком."
else
    log "Список ${SPLIT_EXCLUDE_FILE} пуст или отсутствует — исключений нет."
fi

# Заменяем содержимое блока между маркерами.
awk -v begin="${BEGIN_MARK}" -v end="${END_MARK}" -v f="$routes" '
    $0 == begin { print; while ((getline l < f) > 0) print l; skip = 1; next }
    $0 == end   { skip = 0 }
    !skip       { print }
' "${OCSERV_CONF}" > "$newconf"

if cmp -s "$newconf" "${OCSERV_CONF}"; then
    log "Исключения не изменились ($(count_routes "${OCSERV_CONF}") маршрутов)."
    exit 0
fi

if ! ocserv -t -c "$newconf" >/dev/null 2>&1; then
    install -d -m 0700 "${BACKUP_DIR}"
    install -m 0600 "$newconf" "${BACKUP_DIR}/ocserv.conf.rejected"
    die "ocserv -t отверг новый конфиг — оставляю прежний. Проверьте: ocserv -t -c ${BACKUP_DIR}/ocserv.conf.rejected"
fi

diff <(grep '^no-route' "${OCSERV_CONF}" || true) <(grep '^no-route' "$newconf" || true) \
    | sed -n 's/^< /  - /p; s/^> /  + /p' || true

backup_file "${OCSERV_CONF}"
install -m 0600 "$newconf" "${OCSERV_CONF}"

if [[ $reload == yes ]] && systemctl is-active --quiet ocserv; then
    # SIGHUP: активные сессии не рвутся, новые маршруты клиенты получат
    # при следующем подключении.
    systemctl reload ocserv
fi
log "Исключения обновлены: $(count_routes "${OCSERV_CONF}") маршрутов."
