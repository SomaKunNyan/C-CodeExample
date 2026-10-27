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

if [[ -s ${SPLIT_EXCLUDE_FILE} ]]; then
    # Резолвим через unbound — тот же DNS, что у VPN-клиентов.
    resolver=127.0.0.1
    dig +short +time=2 +tries=1 debian.org @127.0.0.1 >/dev/null 2>&1 || resolver=""

    py_args=(--list "${SPLIT_EXCLUDE_FILE}" --state "${STATE_FILE}"
             --resolver "${resolver}" --v4-prefix "${SPLIT_V4_PREFIX}"
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
