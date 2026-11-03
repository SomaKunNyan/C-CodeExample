#!/usr/bin/env bash
# =============================================================================
#  Cloudflare WARP как выход сервера (WARP_ENABLE="yes").
#    warp.sh            — зарегистрировать бесплатный аккаунт WARP (wgcf), если его ещё нет
#    warp.sh --force    — зарегистрировать новый аккаунт (новый IP выхода)
#    warp.sh test       — проверить выход: временный Xray -> WARP -> cloudflare.com/cdn-cgi/trace
#  Данные аккаунта — в /etc/xray/warp.json (0600). Конфигурацию Xray применяет
#  03-install-vpn.sh.
# =============================================================================
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require_root
require_debian
load_config

WARP_FILE="${XRAY_STORE}/warp.json"

usage() { sed -n '3,8p' "$0" | sed 's/^#  \{0,1\}//'; exit 1; }

# wgcf — из последнего релиза github.com/ViRb3/wgcf; контрольная сумма — из
# файла checksums релиза, если он есть.
get_wgcf() {
    local dir=$1 arch release url sums_url name expected actual
    case "$(uname -m)" in
        x86_64)  arch=linux_amd64 ;;
        aarch64) arch=linux_arm64 ;;
        *) die "Архитектура $(uname -m) не поддерживается." ;;
    esac
    release="$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest)" \
        || die "Не удалось получить список релизов wgcf с GitHub."
    url="$(jq -r --arg a "_${arch}" '.assets[].browser_download_url | select(endswith($a))' <<<"${release}" | head -n1)"
    sums_url="$(jq -r '.assets[].browser_download_url | select(test("checksums"; "i"))' <<<"${release}" | head -n1)"
    [[ -n ${url} ]] || die "В релизе wgcf нет сборки для ${arch}."
    name="${url##*/}"
    log "Загрузка ${name}"
    curl -fsSL --retry 3 -o "${dir}/wgcf" "${url}"
    if [[ -n ${sums_url} ]]; then
        curl -fsSL --retry 3 -o "${dir}/sums" "${sums_url}"
        expected="$(awk -v n="${name}" '$2 == n || $2 == "*"n {print $1}' "${dir}/sums" | head -n1)"
        actual="$(sha256sum "${dir}/wgcf" | awk '{print $1}')"
        [[ -n ${expected} && ${expected} == "${actual}" ]] \
            || die "Контрольная сумма ${name} не совпала (ожидалось ${expected:-?}, получено ${actual})."
        log "  SHA-256 совпадает с ${sums_url##*/}"
    else
        warn "  В релизе нет файла контрольных сумм — wgcf запускается без проверки (от nobody)."
    fi
    chmod 0755 "${dir}/wgcf"
}

register() {
    local work profile account priv pub endpoint mtu id token cid reserved
    [[ -d ${XRAY_STORE} ]] || die "Сначала установите Xray: sudo ./scripts/03-install-vpn.sh"
    apt_install curl jq util-linux
    warn "Регистрируется бесплатный аккаунт Cloudflare WARP: этим вы принимаете условия"
    warn "Cloudflare (https://www.cloudflare.com/application/terms/)."
    work="$(mktemp -d)"
    trap 'rm -rf "${work}"' EXIT
    get_wgcf "${work}"
    chown nobody "${work}"
    # Сторонний бинарник — от nobody во временном каталоге (туда же он пишет файлы).
    ( cd "${work}" && HOME="${work}" setpriv --reuid=nobody --regid=nogroup --clear-groups --no-new-privs \
        sh -c './wgcf register --accept-tos && ./wgcf generate' ) \
        || die "wgcf не смог зарегистрировать аккаунт (см. вывод выше). Повторите позже: у Cloudflare есть лимит регистраций."
    profile="${work}/wgcf-profile.conf" account="${work}/wgcf-account.toml"
    [[ -s ${profile} ]] || die "wgcf не создал ${profile##*/}."

    # Ключи base64 заканчиваются на "=", поэтому значения берём sed, а не awk -F=.
    priv="$(sed -nE 's/^PrivateKey *= *//p' "${profile}" | head -n1)"
    pub="$(sed -nE 's/^PublicKey *= *//p' "${profile}" | head -n1)"
    endpoint="$(sed -nE 's/^Endpoint *= *//p' "${profile}" | head -n1)"
    mtu="$(sed -nE 's/^MTU *= *//p' "${profile}" | head -n1)"
    mapfile -t addrs < <(sed -nE 's/^Address *= *//p' "${profile}" | tr ',' '\n' | tr -d ' ' | sed '/^$/d')
    [[ -n ${priv} && -n ${pub} && -n ${endpoint} && ${#addrs[@]} -gt 0 ]] \
        || die "Не удалось разобрать ${profile##*/}: $(cat "${profile}")"

    # reserved (3 байта client_id) — по возможности: часть узлов WARP без него не пропускает
    # трафик. API неофициальное и может отвечать 403 — тогда без reserved.
    reserved="[]"
    id="$(sed -nE "s/^device_id *= *['\"]?([^'\"]+)['\"]?/\\1/p" "${account}" 2>/dev/null | head -n1)"
    token="$(sed -nE "s/^access_token *= *['\"]?([^'\"]+)['\"]?/\\1/p" "${account}" 2>/dev/null | head -n1)"
    if [[ -n ${id} && -n ${token} ]]; then
        cid="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${token}" \
                   "https://api.cloudflareclient.com/v0a2158/reg/${id}" 2>/dev/null \
               | jq -r '.config.client_id // empty' 2>/dev/null || true)"
        # client_id — base64 от 3 байт; reserved — эти байты числами.
        reserved="[$(printf '%s' "${cid}" | base64 -d 2>/dev/null | od -An -tu1 | xargs | tr ' ' ',')]"
        [[ ${reserved} =~ ^\[[0-9]+,[0-9]+,[0-9]+\]$ ]] || reserved="[]"
    fi
    [[ ${reserved} == "[]" ]] && warn "  reserved (client_id) получить не удалось — работает без него; если test не проходит, см. WARP_RESERVED в config.env."

    backup_file "${WARP_FILE}"
    umask 077
    jq -n --arg priv "${priv}" --arg pub "${pub}" --arg ep "${endpoint}" --arg mtu "${mtu:-1280}" \
          --argjson reserved "${reserved}" --args \
          '{privateKey: $priv, publicKey: $pub, endpoint: $ep, mtu: ($mtu|tonumber),
            addresses: $ARGS.positional, reserved: $reserved}' "${addrs[@]}" > "${WARP_FILE}"
    [[ -s ${account} ]] && install -m 0600 "${account}" "${XRAY_STORE}/warp-account.toml"
    umask 022
    chmod 0600 "${WARP_FILE}"
    log "Аккаунт WARP сохранён: ${WARP_FILE} (адреса в туннеле: ${addrs[*]})"
}

# Временный Xray: SOCKS 127.0.0.1:10898 -> только WARP; через него — cdn-cgi/trace Cloudflare.
test_warp() {
    local work pid out
    [[ -s ${WARP_FILE} ]] || die "Нет ${WARP_FILE}: сначала sudo ./scripts/warp.sh"
    work="$(mktemp -d)"
    trap 'kill "${pid:-}" 2>/dev/null; rm -rf "${work}"' EXIT
    xray_py warp-test-config > "${work}/warp-test.json"
    "${XRAY_BIN}" run -config "${work}/warp-test.json" > "${work}/xray.log" 2>&1 &
    pid=$!
    sleep 3
    if out="$(curl -fsS --max-time 20 -x socks5h://127.0.0.1:10898 https://www.cloudflare.com/cdn-cgi/trace)" \
            && grep -qE '^warp=(on|plus)' <<<"${out}"; then
        log "WARP работает: $(grep -E '^(ip|loc|colo|warp)=' <<<"${out}" | xargs)"
    else
        warn "WARP не отвечает. Ответ: ${out:-нет}"
        grep -Ei 'warning|error|fail|handshake' "${work}/xray.log" | tail -n 15
        warn "Попробуйте: sudo ./scripts/warp.sh --force (новый аккаунт) или задайте WARP_RESERVED в config.env."
        exit 1
    fi
}

case "${1:-}" in
    "")       if [[ -s ${WARP_FILE} ]]; then log "Аккаунт WARP уже есть: ${WARP_FILE} (новый — warp.sh --force)"; else register; fi ;;
    --force)  register ;;
    test)     test_warp ;;
    *)        usage ;;
esac
