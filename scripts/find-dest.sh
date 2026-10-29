#!/usr/bin/env bash
# =============================================================================
#  Подбор сайта для маскировки REALITY (REALITY_DEST).
#    find-dest.sh check <домен>...       — проверить кандидатов с сервера
#    find-dest.sh check -f <файл>        — то же, из файла: список доменов или
#                                          out.csv от RealiTLScanner
#    find-dest.sh scan [CIDR] [минут]    — найти сайты по соседству с сервером
#                                          (RealiTLScanner, по умолчанию /24
#                                          сервера, 10 минут) и проверить их
#  Проверяется: TLS 1.3, HTTP/2, X25519MLKEM768, нет CDN, нет редиректа на
#  другой домен, OCSP stapling, задержка от сервера. Сайт должен быть
#  доступен из РФ — это проверьте из своей сети сами.
# =============================================================================
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage() { sed -n '3,12p' "$0" | sed 's/^#  \{0,1\}//'; exit 1; }

# Домены из файла: CSV RealiTLScanner (столбец CERT_DOMAIN) или по одному в строке.
# Из wildcard-сертификата (*.example.fi) берём сам домен.
read_candidates() {
    python3 -I - "$1" <<'EOF'
import csv, sys
rows = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
seen = []
if rows and rows[0].startswith("IP,ORIGIN"):
    for r in csv.DictReader(rows):
        seen.append(r.get("CERT_DOMAIN", ""))
else:
    seen = [r.split("#")[0] for r in rows]
out = []
for d in seen:
    d = d.strip().lower().removeprefix("*.").rstrip(".")
    if d and "." in d and " " not in d and d not in out:
        out.append(d)
print("\n".join(out))
EOF
}

# Одна строка таблицы: verdict ms domain ip tls h2 pq ocsp note
check_one() {
    local d=$1 ip ping sni tls=- h2=- pq=- ocsp=- note="" verdict=OK ms=-
    ip="$(getent ahostsv4 "$d" | awk '{print $1; exit}' || true)"
    if ! is_global_ip "$ip"; then
        printf 'BAD\t-\t%s\t-\t-\t-\t-\t-\tне резолвится\n' "$d"; return
    fi

    ping="$(timeout 15 "${XRAY_BIN}" tls ping "$d" 2>&1 || true)"
    sni="$(sed -n '/Pinging with SNI/,$p' <<<"$ping")"
    if grep -q 'Handshake succeeded' <<<"$sni"; then
        tls="$(awk -F': *' '/^TLS Version/{print $2; exit}' <<<"$sni" | tr -d ' ')"
        grep -q 'Post-Quantum key exchange:[[:space:]]*true' <<<"$sni" && pq=yes || pq=no
    else
        tls=fail
    fi

    local out code ver tc redir hdrs
    out="$(curl -s --noproxy '*' --http2 --max-time 10 -o /dev/null -D - \
        -w '\n@@ %{http_version} %{http_code} %{time_connect} %{redirect_url}' "https://${d}/" 2>/dev/null || true)"
    read -r _ ver code tc redir < <(grep '^@@' <<<"$out" || echo "@@ - - - -")
    hdrs="$(grep -v '^@@' <<<"$out" | tr '[:upper:]' '[:lower:]' || true)"
    h2=$([[ $ver == 2 ]] && echo yes || echo no)
    # time_connect — время установки TCP с сервера: замена ping (ICMP часто закрыт).
    if [[ $tc =~ ^[0-9.]+$ ]] && awk -v t="$tc" 'BEGIN{exit !(t>0)}'; then
        ms="$(awk -v t="$tc" 'BEGIN{printf "%d", t*1000}')"
    fi

    timeout 10 openssl s_client -connect "${ip}:443" -servername "$d" -status </dev/null 2>/dev/null \
        | grep -q 'OCSP Response Status: successful' && ocsp=yes || ocsp=no

    if [[ $tls != "TLS1.3" ]]; then verdict=BAD; note+="нет TLS 1.3; "; fi
    if [[ $h2 != yes ]]; then
        [[ ${XRAY_TRANSPORT:-xhttp} == xhttp ]] && verdict=BAD
        note+="нет HTTP/2; "
    fi
    if grep -qE '^(server: *(cloudflare|akamai|cloudfront|fastly|ddos-guard|qrator))|^(cf-ray|x-amz-cf-id|x-akamai|x-fastly|x-served-by: *cache)' <<<"$hdrs"; then
        verdict=BAD; note+="за CDN; "
    fi
    if [[ $code == 3* && -n $redir && $redir != - ]]; then
        local rhost="${redir#*://}"; rhost="${rhost%%/*}"; rhost="${rhost%%:*}"
        if [[ ${rhost,,} != "${d}" ]]; then
            verdict=BAD; note+="редирект на ${rhost} (проверьте его самого); "
        fi
    elif [[ $code != 2* ]]; then
        [[ $verdict == OK ]] && verdict=WARN
        note+="ответ ${code:--}; "
    fi
    if [[ -n ${PUBLIC_IPV4:-} && ${ip%.*} == "${PUBLIC_IPV4%.*}" ]]; then note+="соседняя /24; "; fi
    [[ $pq == yes ]] || { [[ $verdict == OK ]] && verdict=WARN; note+="без X25519MLKEM768; "; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$verdict" "$ms" "$d" "$ip" "$tls" "$h2" "$pq" "$ocsp" "${note%; }"
}

check_all() {
    (( $# )) || die "Нет кандидатов для проверки."
    [[ -x ${XRAY_BIN} ]] || die "Нет ${XRAY_BIN}: сначала выполните 03-install-vpn.sh."
    log "Проверка кандидатов: $#"
    local d rows=""
    for d in "$@"; do
        printf '  %s\n' "$d" >&2
        rows+="$(check_one "$d")"$'\n'
    done
    # OK, затем WARN, затем BAD; внутри — по задержке.
    rows="$(sed '/^$/d' <<<"$rows" | awk -F'\t' '{o=($1=="OK")?0:($1=="WARN")?1:2; m=($2=="-")?99999:$2; print o"\t"m"\t"$0}' \
            | sort -t$'\t' -k1,1n -k2,2n | cut -f3-)"
    echo
    { printf 'ИТОГ\tмс\tДОМЕН\tIP\tTLS\tH2\tPQ\tOCSP\tЗАМЕЧАНИЯ\n'; echo "$rows"; } \
        | if command -v column >/dev/null; then LC_ALL=C.UTF-8 column -t -s $'\t'; else cat; fi
    local best
    best="$(awk -F'\t' '$1=="OK"{print $3; exit}' <<<"$rows")"
    echo
    if [[ -n $best ]]; then
        log "Лучший кандидат: REALITY_DEST=\"${best}:443\""
        log "Откройте https://${best}/ из своей сети в РФ: сайт должен открываться без ошибок."
        log "Затем впишите в config.env и выполните 03-install-vpn.sh (при REALITY_MIRROR_PORTS — и 02-firewall.sh)."
    else
        warn "Подходящих сайтов нет. Попробуйте другие домены или режим scan."
    fi
}

# RealiTLScanner — из последнего релиза XTLS на GitHub.
get_scanner() {
    local dir=$1 pattern url
    case "$(uname -m)" in
        x86_64)  pattern='linux-(64|amd64)$' ;;
        aarch64) pattern='linux-arm64(-v8a)?$' ;;
        *) die "Архитектура $(uname -m) не поддерживается." ;;
    esac
    url="$(curl -fsSL https://api.github.com/repos/XTLS/RealiTLScanner/releases/latest \
           | jq -r '.assets[].browser_download_url' | grep -E "${pattern}" | head -n1 || true)"
    [[ -n $url ]] || die "Не нашёл сборку RealiTLScanner для $(uname -m) в релизах github.com/XTLS/RealiTLScanner."
    log "Загрузка ${url##*/}"
    curl -fsSL --retry 3 -o "${dir}/RealiTLScanner" "$url"
    chmod 0755 "${dir}/RealiTLScanner"
}

scan() {
    local cidr=${1:-} minutes=${2:-10} work
    require_root
    load_config
    apt_install curl jq python3 openssl util-linux
    [[ -n $cidr ]] || cidr="${PUBLIC_IPV4%.*}.0/24"
    [[ $minutes =~ ^[0-9]+$ ]] || die "Длительность — число минут."

    warn "Сканирование ${cidr} (порт 443) ПРЯМО С СЕРВЕРА."
    warn "Хостер может принять это за сканирование сети и прислать жалобу или ограничить VPS,"
    warn "а для наблюдателя массовые TLS-подключения с IP сервера выглядят странно."
    warn "Безопаснее запустить RealiTLScanner на своём компьютере (не через VPN):"
    warn "  RealiTLScanner -addr ${cidr} -thread 4 -timeout 5 -out out.csv"
    warn "и проверить результат здесь: find-dest.sh check -f out.csv"
    read -r -p "Всё равно сканировать с сервера? Введите 'yes': " ans
    [[ $ans == yes ]] || die "Отменено."

    work="$(mktemp -d)"
    trap 'rm -rf "${work}"' EXIT
    get_scanner "$work"
    chown nobody "$work"
    log "Сканирование ${cidr}, не дольше ${minutes} мин. (Ctrl+C — остановить и проверить найденное)"
    # Сканер — сторонний бинарник без опубликованных контрольных сумм: запускаем
    # от nobody во временном каталоге.
    trap ':' INT     # Ctrl+C останавливает только сканер, найденное проверяется
    ( cd "$work" && timeout --foreground "${minutes}m" \
        setpriv --reuid=nobody --regid=nogroup --clear-groups --no-new-privs \
        ./RealiTLScanner -addr "$cidr" -port 443 -thread 4 -timeout 5 -out out.csv ) || true
    trap - INT
    [[ -s ${work}/out.csv ]] || die "Сканер ничего не сохранил."
    mapfile -t cands < <(read_candidates "${work}/out.csv")
    log "Найдено доменов с TLS 1.3 + HTTP/2: ${#cands[@]}"
    check_all "${cands[@]}"
}

cmd=${1:-}; shift || true
case "$cmd" in
    check)
        if [[ ${1:-} == -f ]]; then
            [[ -r ${2:-} ]] || die "Нет файла ${2:-}."
            mapfile -t cands < <(read_candidates "$2")
        else
            cands=("$@")
        fi
        # Из config.env (если есть) нужны только PUBLIC_IPV4 (пометка «соседняя /24»)
        # и XRAY_TRANSPORT (для xhttp HTTP/2 обязателен).
        if [[ -r ${CONFIG_FILE} ]]; then
            eval "$( (load_config; printf 'PUBLIC_IPV4=%q XRAY_TRANSPORT=%q\n' "${PUBLIC_IPV4}" "${XRAY_TRANSPORT}") 2>/dev/null || true)"
        fi
        check_all "${cands[@]}"
        ;;
    scan) scan "$@" ;;
    *) usage ;;
esac
