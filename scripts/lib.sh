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

    : "${VPN_DOMAIN:?}" "${ACME_EMAIL:?}" "${WAN_IF:?}" "${ADMIN_USER:?}"
    : "${SSH_PORT:?}" "${VPN_NET4:?}" "${VPN_GW4:?}" "${MAX_CLIENTS:?}"
    : "${MAX_SAME_CLIENTS:?}" "${VPN_MTU:?}"
    : "${ADMIN_SSH_PUBKEY:=}" "${SSH_ALLOW_FROM:=}" "${SSH_FROM_VPN:=yes}"
    : "${VPN_NET6:=}" "${WAN_IPV4:=}" "${ENABLE_OTP:=yes}" "${CAMOUFLAGE_SECRET:=}"
    : "${SPLIT_EXCLUDE_FILE:=${PROJECT_DIR}/split-exclude.txt}" "${SPLIT_V4_PREFIX:=24}"
    : "${SPLIT_V6_PREFIX:=48}" "${SPLIT_KEEP_DAYS:=7}" "${SPLIT_MAX_ROUTES:=200}"
    # Только если не задан вовсе: пустое значение в config.env отключает пересылку.
    : "${SPLIT_DNS_FORWARDERS=77.88.8.8 77.88.8.1}"

    [[ ${VPN_DOMAIN} != vpn.example.com ]] || die "Задайте VPN_DOMAIN в ${CONFIG_FILE}."
    ip link show dev "${WAN_IF}" >/dev/null 2>&1 \
        || die "Интерфейс WAN_IF=$(printf '%q' "${WAN_IF}") не найден (невидимые символы видны как \$'...\\NNN'). Доступные: $(ip -br link | awk '{print $1}' | xargs)"

    if [[ -z ${WAN_IPV4} ]]; then
        WAN_IPV4="$(ip -4 -o addr show dev "${WAN_IF}" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)"
        [[ -n ${WAN_IPV4} ]] || die "Не удалось определить IPv4 на ${WAN_IF}; задайте WAN_IPV4."
    fi
    export VPN_DOMAIN ACME_EMAIL WAN_IF WAN_IPV4 ADMIN_USER SSH_PORT VPN_NET4 VPN_GW4 \
           VPN_NET6 MAX_CLIENTS MAX_SAME_CLIENTS VPN_MTU ENABLE_OTP CAMOUFLAGE_SECRET
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

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}
