#!/usr/bin/env bash
# =============================================================================
#  Шаг 4. Производительность под 40 Гбит/с.
#   - сетевой стек (буферы, BBR, conntrack);
#   - 40G NIC: кольцевые буферы, RSS-очереди, offload'ы (при каждой загрузке);
#   - CPU: governor performance;
#   - лимиты файловых дескрипторов.
# =============================================================================
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require_root
require_debian
load_config

apt_install ethtool linux-cpupower irqbalance gettext-base

# --- Аппаратное ускорение шифрования ------------------------------------------
if grep -qw aes /proc/cpuinfo; then
    log "AES-NI доступен: AES-GCM будет работать аппаратно"
else
    warn "CPU без AES-NI: шифрование будет медленным; клиенты выберут ChaCha20."
fi

# --- sysctl ------------------------------------------------------------------
log "Параметры сетевого стека (BBR, буферы, conntrack)"
modprobe -a nf_conntrack tcp_bbr
printf 'nf_conntrack\ntcp_bbr\n' > /etc/modules-load.d/vpn-perf.conf
# Размер хеш-таблицы conntrack задаётся и параметром модуля (до загрузки).
echo "options nf_conntrack hashsize=1048576" > /etc/modprobe.d/nf_conntrack.conf
install_file "${TEMPLATES_DIR}/sysctl/95-vpn-performance.conf" /etc/sysctl.d/95-vpn-performance.conf
sysctl --system >/dev/null || warn "Часть sysctl не применилась — проверьте: sysctl --system"

# --- Сетевая карта -------------------------------------------------------------
log "Тюнинг NIC ${WAN_IF} (ring buffers, RSS, offloads)"
install -m 0755 "${PROJECT_DIR}/scripts/vpn-nic-tune" /usr/local/sbin/vpn-nic-tune
render "${TEMPLATES_DIR}/systemd/vpn-nic-tuning.service.tpl" /etc/systemd/system/vpn-nic-tuning.service 0644 WAN_IF
systemctl daemon-reload
systemctl enable vpn-nic-tuning.service
systemctl restart vpn-nic-tuning.service
journalctl -u vpn-nic-tuning -n 20 --no-pager -o cat || true

# --- CPU ----------------------------------------------------------------------
log "CPU governor = performance (стабильная задержка, без просадок частоты)"
cat > /etc/systemd/system/cpu-performance.service <<'EOF'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/usr/bin/cpupower frequency-set -g performance

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now cpu-performance.service || true

systemctl enable --now irqbalance

# --- Лимиты -------------------------------------------------------------------
cat > /etc/security/limits.d/90-vpn.conf <<'EOF'
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

log "Готово. Текущее состояние:"
echo "  congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "  qdisc:              $(sysctl -n net.core.default_qdisc)"
echo "  conntrack max:      $(sysctl -n net.netfilter.nf_conntrack_max)"
echo "  NIC channels:       $(ethtool -l "${WAN_IF}" 2>/dev/null | awk '/Current/{f=1} f&&/Combined/{print $2; exit}')"
warn "Для полного применения (hashsize conntrack, ring buffers) рекомендуется перезагрузка."
