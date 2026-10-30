#!/usr/bin/env bash
# =============================================================================
#  Шаг 3. VPN-сервер Xray: VLESS + REALITY + XTLS Vision (TCP/443)
#   - Xray с официального GitHub (проверка SHA-256), отдельный пользователь
#     xray, песочница systemd;
#   - ключи REALITY (x25519) и shortId генерируются один раз;
#   - проверка сайта для маскировки (REALITY_DEST): TLS 1.3 + HTTP/2;
#   - локальный DNS-резолвер unbound (DNSSEC) для запросов клиентов.
#  Безопасно запускать повторно: ключи и пользователи сохраняются.
# =============================================================================
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require_root
require_debian
load_config
require_reality

log "Установка зависимостей"
apt-get update
apt_install curl unzip ca-certificates openssl unbound dns-root-data \
    qrencode jq python3 bind9-dnsutils gettext-base
modprobe tcp_bbr 2>/dev/null || true

# --- 1. Xray ------------------------------------------------------------------
case "$(uname -m)" in
    x86_64)  asset=Xray-linux-64.zip ;;
    aarch64) asset=Xray-linux-arm64-v8a.zip ;;
    *) die "Архитектура $(uname -m) не поддерживается скриптом." ;;
esac

version="${XRAY_VERSION}"
if [[ ${version} == latest ]]; then
    version="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/XTLS/Xray-core/releases/latest | sed 's#.*/tag/##')"
    [[ ${version} == v* ]] || die "Не удалось узнать последнюю версию Xray; задайте XRAY_VERSION (например, v26.10.21)."
fi

installed="$("${XRAY_BIN}" version 2>/dev/null | awk 'NR==1{print "v"$2}' || true)"
if [[ ${installed} == "${version}" ]]; then
    log "Xray ${version} уже установлен"
else
    log "Установка Xray ${version} (${asset})"
    work="$(mktemp -d)"
    trap 'rm -rf "${work}"' EXIT
    base="https://github.com/XTLS/Xray-core/releases/download/${version}"
    curl -fsSL --retry 3 -o "${work}/${asset}" "${base}/${asset}"
    curl -fsSL --retry 3 -o "${work}/${asset}.dgst" "${base}/${asset}.dgst"
    expected="$(grep -E '^SHA(2-)?256=' "${work}/${asset}.dgst" | awk '{print $2}' | head -n1)"
    actual="$(sha256sum "${work}/${asset}" | awk '{print $1}')"
    [[ -n ${expected} && ${expected} == "${actual}" ]] \
        || die "Контрольная сумма ${asset} не совпала (ожидалось ${expected:-?}, получено ${actual})."
    unzip -q -o "${work}/${asset}" -d "${work}/x"
    install -m 0755 "${work}/x/xray" "${XRAY_BIN}"
    install -d -m 0755 /usr/local/share/xray
    install -m 0644 "${work}/x/geoip.dat" "${work}/x/geosite.dat" /usr/local/share/xray/
    log "Установлен: $("${XRAY_BIN}" version | head -n1)"
fi

getent group xray >/dev/null || groupadd --system xray
getent passwd xray >/dev/null || useradd --system --gid xray --no-create-home \
    --home-dir /nonexistent --shell /usr/sbin/nologin xray
install -d -m 0750 -o root -g xray "${XRAY_STORE}"

# --- 2. Ключи REALITY ---------------------------------------------------------
if [[ ! -s ${XRAY_STORE}/keys.json ]]; then
    log "Генерация ключей REALITY (x25519) и shortId"
    keyout="$("${XRAY_BIN}" x25519)"
    priv="$(awk -F': *' '/^PrivateKey/{print $2}' <<<"${keyout}")"
    # Новые версии называют публичный ключ «Password (PublicKey)», старые — «Public key».
    pub="$(awk -F': *' '/^(Password|Public)/{print $2}' <<<"${keyout}" | head -n1)"
    [[ -n ${priv} && -n ${pub} ]] || die "Не удалось разобрать вывод 'xray x25519': ${keyout}"
    sid="$(openssl rand -hex 8)"
    umask 077
    jq -n --arg priv "${priv}" --arg pub "${pub}" --arg sid "${sid}" \
        '{privateKey: $priv, publicKey: $pub, shortIds: [$sid]}' > "${XRAY_STORE}/keys.json"
    umask 022
fi
# Ключи VLESS Encryption (ENC_ENABLE): пара X25519 из `xray vlessenc` — сервер
# аутентифицируется ей, обмен ключами сессии — ML-KEM-768 + X25519 (постквантовый).
if [[ ${ENC_ENABLE} == yes ]] && ! jq -e '.encServerKey and .encClientKey' "${XRAY_STORE}/keys.json" >/dev/null; then
    log "Генерация ключей VLESS Encryption"
    encout="$("${XRAY_BIN}" vlessenc 2>&1)" \
        || die "Эта версия Xray не умеет VLESS Encryption ('xray vlessenc'); обновите Xray (XRAY_VERSION=\"latest\")."
    # Первая пара в выводе — аутентификация X25519 (короткий ключ для ссылки).
    dec="$(grep -m1 '"decryption"' <<<"${encout}" | sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/')"
    enc="$(grep -m1 '"encryption"' <<<"${encout}" | sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/')"
    srv="${dec##*.}" cli="${enc##*.}"
    [[ ${#srv} == 43 && ${#cli} == 43 ]] || die "Не удалось разобрать вывод 'xray vlessenc': ${encout}"
    tmpk="$(mktemp "${XRAY_STORE}/keys.XXXXXX")"
    jq --arg s "${srv}" --arg c "${cli}" '. + {encServerKey: $s, encClientKey: $c}' \
        "${XRAY_STORE}/keys.json" > "${tmpk}"
    mv -f "${tmpk}" "${XRAY_STORE}/keys.json"
fi
[[ -s ${XRAY_STORE}/users.json ]] || echo '{"users": []}' > "${XRAY_STORE}/users.json"
chmod 0600 "${XRAY_STORE}/keys.json" "${XRAY_STORE}/users.json"

# --- 3. Сайт для маскировки ---------------------------------------------------
if [[ ${REALITY_SELF_SITE} == yes ]]; then
    log "Свой сайт-заглушка ${VPN_DOMAIN} (nginx + Let's Encrypt)"
    bash "${PROJECT_DIR}/scripts/self-site.sh"
fi

dest_host="${REALITY_DEST%:*}" dest_port="${REALITY_DEST##*:}"
log "Проверка сайта для маскировки: ${REALITY_SNI} (${REALITY_DEST})"
if [[ ${dest_host} =~ ^[0-9.]+$ ]]; then
    # Цель задана IP-адресом (свой сайт на 127.0.0.1): подключаемся к нему с SNI = REALITY_SNI.
    ping_out="$("${XRAY_BIN}" tls ping -ip "${dest_host}" "${REALITY_SNI}:${dest_port}" 2>&1 || true)"
    curl_target=(--noproxy '*' --resolve "${REALITY_SNI}:${dest_port}:${dest_host}" "https://${REALITY_SNI}:${dest_port}/")
else
    ping_out="$("${XRAY_BIN}" tls ping "${dest_host}:${dest_port}" 2>&1 || true)"
    curl_target=("https://${dest_host}:${dest_port}/")
fi
dest_host="${REALITY_SNI}"
if ! grep -q 'TLS Version:[[:space:]]*TLS 1.3' <<<"${ping_out}"; then
    echo "${ping_out}" | tail -n 15
    die "${dest_host} не отвечает по TLS 1.3 — выберите другой сайт (см. docs/02-vpn-server.md)."
fi
h2="$(curl -s -o /dev/null --max-time 10 --http2 -w '%{http_version}' "${curl_target[@]}" || true)"
if [[ ${h2} != 2 ]]; then
    # XHTTP поверх REALITY идёт по HTTP/2: сайт-маскировка обязан его поддерживать.
    [[ ${XRAY_TRANSPORT} == xhttp ]] \
        && die "${dest_host} не отвечает по HTTP/2 (ответ: '${h2}'), а для XHTTP это обязательно — выберите другой REALITY_DEST."
    warn "${dest_host} не отвечает по HTTP/2 (ответ: '${h2}'). Лучше выбрать сайт с HTTP/2."
fi
grep -q 'Post-Quantum key exchange:[[:space:]]*true' <<<"${ping_out}" \
    || warn "${dest_host} не поддерживает X25519MLKEM768 — клиенту с fp=chrome это не мешает, но сайт с PQ правдоподобнее."
log "  ${dest_host}: TLS 1.3, HTTP/${h2:-?}"

# --- 4. DNS-резолвер для Xray ---------------------------------------------------
log "unbound (локальный DNS, DNSSEC)"
cpus="$(nproc)"
UNBOUND_THREADS=$(( cpus >= 16 ? 4 : (cpus >= 4 ? 2 : 1) ))
UNBOUND_SLABS=$(( UNBOUND_THREADS * 2 ))
export UNBOUND_THREADS UNBOUND_SLABS
rm -f /etc/unbound/unbound.conf.d/split-exclude-forward.conf   # от старой версии проекта
render "${TEMPLATES_DIR}/unbound/vpn.conf.tpl" /etc/unbound/unbound.conf.d/vpn.conf 0644 \
    UNBOUND_THREADS UNBOUND_SLABS
unbound-checkconf >/dev/null || die "unbound-checkconf: ошибка конфигурации"
systemctl enable unbound
systemctl restart unbound

# Прежняя версия проекта (ocserv) занимает порт 443 — останавливаем до запуска Xray.
if systemctl list-unit-files ocserv.service 2>/dev/null | grep -q '^ocserv\.service'; then
    warn "Найден ocserv от прежней версии проекта — останавливаю и отключаю."
    systemctl disable --now ocserv vpn-split-routes.timer 2>/dev/null || true
fi

# --- 5. Конфигурация и запуск Xray --------------------------------------------
log "Конфигурация Xray"
install_file "${TEMPLATES_DIR}/systemd/xray.service" /etc/systemd/system/xray.service
systemctl daemon-reload
xray_apply
systemctl enable xray
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || { journalctl -u xray -n 50 --no-pager; die "Xray не запустился"; }

# Аудит изменений конфигурации VPN (каталоги уже существуют).
if [[ -d /etc/audit/rules.d ]]; then
    rm -f /etc/audit/rules.d/60-vpn-ocserv.rules   # от старой версии проекта
    install_file "${TEMPLATES_DIR}/audit/60-vpn-xray.rules" /etc/audit/rules.d/60-vpn-xray.rules 0640
    augenrules --load >/dev/null || warn "augenrules: правила аудита VPN не загрузились (auditctl -l)"
fi

log "VPN-сервер запущен: VLESS + REALITY (${XRAY_TRANSPORT}) на ${PUBLIC_IPV4:-${WAN_IPV4}}:${XRAY_PORT}, маскировка под ${dest_host}"
[[ ${CDN_ENABLE} == yes ]] && log "Вход через CDN: ${CDN_DOMAIN} -> CDN -> 443 -> nginx -> Xray 127.0.0.1:${CDN_XRAY_PORT}"
if [[ ${ENC_ENABLE} == yes ]]; then
    log "Вход VLESS Encryption без TLS (${ENC_MODE}): TCP/${ENC_PORT}"
    nft list chain inet filter input 2>/dev/null | grep -q "tcp dport ${ENC_PORT} accept" \
        || warn "Порт ${ENC_PORT} закрыт в nftables — выполните: sudo ./scripts/02-firewall.sh"
fi
log "Добавьте пользователя: sudo ./scripts/vpn-user.sh add <имя>"
