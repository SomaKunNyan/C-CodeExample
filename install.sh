#!/usr/bin/env bash
# =============================================================================
#  Полная установка: hardening -> firewall -> VPN -> тюнинг 40G.
#  Каждый шаг можно запускать и отдельно (scripts/0X-*.sh).
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")"

[[ ${EUID} -eq 0 ]] || { echo "Запустите от root: sudo ./install.sh"; exit 1; }
[[ -f config.env ]] || { echo "Сначала: cp config.env.example config.env && nano config.env"; exit 1; }

chmod 0600 config.env
for step in scripts/01-harden-system.sh scripts/02-firewall.sh \
            scripts/03-install-vpn.sh scripts/04-tune-performance.sh; do
    echo
    echo "================  ${step}  ================"
    bash "${step}"
done

echo
bash scripts/healthcheck.sh || true
echo
echo "Установка завершена. Перезагрузите сервер в удобное время: sudo reboot"
