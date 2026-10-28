#!/usr/bin/env bash
# Общие функции для скриптов проекта. Подключается через `source`.
# shellcheck shell=bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES_DIR="${PROJECT_DIR}/templates"
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_DIR}/config.env}"
BACKUP_DIR="/var/backups/vpn-https-debian"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_rst=$'\e[0m'

log()  { printf '%s[+]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

trap 'die "Ошибка в строке ${LINENO}: ${BASH_COMMAND}"' ERR

require_root() {
    [[ ${EUID} -eq 0 ]] || die "Запустите от root (sudo $0)."
}

require_debian() {
    [[ -r /etc/os-release ]] || die "Не найден /etc/os-release."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == debian ]] || die "Поддерживается только Debian (обнаружено: ${ID:-?})."
    case "${VERSION_ID:-}" in
        12|13) ;;
        *) warn "Проверено на Debian 12/13, у вас ${VERSION_ID:-?}. Продолжаю на свой риск." ;;
    esac
}

load_config() {
    [[ -r ${CONFIG_FILE} ]] || die "Нет ${CONFIG_FILE}. Выполните: cp config.env.example config.env и отредактируйте."
    # Убираем \r: config.env мог быть отредактирован в Windows.
    # shellcheck disable=SC1090
    . <(tr -d '\r' < "${CONFIG_FILE}")

    : "${WAN_IF:?}" "${ADMIN_USER:?}" "${SSH_PORT:?}"
    : "${ADMIN_SSH_PUBKEY:=}" "${SSH_ALLOW_FROM:=}" "${VPN_DOMAIN:=}" "${WAN_IPV4:=}" "${WAN_IPV6:=}"
    : "${XRAY_VERSION:=latest}" "${XRAY_PORT:=443}" "${XRAY_API_PORT:=10085}"
    : "${REALITY_DEST:=}" "${REALITY_SERVER_NAMES:=}" "${CLIENT_FINGERPRINT:=chrome}"
    : "${BLOCK_BITTORRENT:=yes}" "${XRAY_ACCESS_LOG:=no}" "${CLIENT_DIRECT_RU:=no}"
    : "${SPLIT_EXCLUDE_FILE:=${PROJECT_DIR}/split-exclude.txt}"

    ip link show dev "${WAN_IF}" >/dev/null 2>&1 \
        || die "Интерфейс WAN_IF=$(printf '%q' "${WAN_IF}") не найден (невидимые символы видны как \$'...\\NNN'). Доступные: $(ip -br link | awk '{print $1}' | xargs)"

    if [[ -z ${WAN_IPV4} ]]; then
        WAN_IPV4="$(ip -4 -o addr show dev "${WAN_IF}" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)"
        [[ -n ${WAN_IPV4} ]] || die "Не удалось определить IPv4 на ${WAN_IF}; задайте WAN_IPV4."
    fi
    if [[ -z ${WAN_IPV6} ]]; then
        WAN_IPV6="$(ip -6 -o addr show dev "${WAN_IF}" scope global -deprecated 2>/dev/null \
                    | grep -v temporary | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
    fi
    export VPN_DOMAIN WAN_IF WAN_IPV4 WAN_IPV6 ADMIN_USER SSH_PORT XRAY_VERSION XRAY_PORT \
           XRAY_API_PORT REALITY_DEST REALITY_SERVER_NAMES CLIENT_FINGERPRINT BLOCK_BITTORRENT \
           XRAY_ACCESS_LOG CLIENT_DIRECT_RU SPLIT_EXCLUDE_FILE
}

# Резервная копия файла перед перезаписью.
backup_file() {
    local f=$1
    [[ -e $f ]] || return 0
    install -d -m 0700 "${BACKUP_DIR}"
    cp -a "$f" "${BACKUP_DIR}/$(basename "$f").$(date +%Y%m%d-%H%M%S)"
}

# Подставляет в шаблон ТОЛЬКО перечисленные переменные (остальные $ не трогает).
# render <template> <dest> <mode> VAR1 VAR2 ...
render() {
    local tpl=$1 dest=$2 mode=$3; shift 3
    local vars="" v
    for v in "$@"; do vars+="\${${v}} "; done
    backup_file "$dest"
    install -d "$(dirname "$dest")"
    envsubst "$vars" < "$tpl" > "${dest}.new"
    chmod "$mode" "${dest}.new"
    mv -f "${dest}.new" "$dest"
}

# Копирует статический файл из templates/ с бэкапом.
install_file() {
    local src=$1 dest=$2 mode=${3:-0644}
    backup_file "$dest"
    install -D -m "$mode" "$src" "$dest"
}

# Параметры REALITY нужны только шагу 03 и управлению пользователями.
require_reality() {
    [[ -n ${REALITY_DEST} ]] || die "Задайте REALITY_DEST в ${CONFIG_FILE} (см. docs/02-vpn-server.md, «Выбор сайта для маскировки»)."
    [[ ${REALITY_DEST} == *:* ]] || REALITY_DEST="${REALITY_DEST}:443"
    export REALITY_DEST
}

XRAY_BIN=/usr/local/bin/xray
XRAY_STORE=/etc/xray
export XRAY_STORE

xray_py() { python3 "${PROJECT_DIR}/scripts/xray-vpn.py" "$@"; }

# Пересобрать config.json из users.json/keys.json, проверить и перезапустить Xray.
xray_apply() {
    local tmp
    tmp="$(mktemp --suffix=.json)"   # Xray определяет формат по расширению
    xray_py server > "$tmp"
    if ! "${XRAY_BIN}" run -test -config "$tmp" >/dev/null 2>&1; then
        "${XRAY_BIN}" run -test -config "$tmp" || true
        rm -f "$tmp"
        die "xray -test отверг новую конфигурацию — оставляю прежнюю."
    fi
    backup_file "${XRAY_STORE}/config.json"
    install -m 0640 -o root -g xray "$tmp" "${XRAY_STORE}/config.json"
    rm -f "$tmp"
    if systemctl is-enabled --quiet xray 2>/dev/null; then
        systemctl restart xray
    fi
}

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}
