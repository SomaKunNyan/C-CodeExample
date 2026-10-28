# /etc/systemd/system/vpn-nic-tuning.service
# Настройка 40G-сетевой карты при каждой загрузке (ethtool не сохраняет
# параметры между перезагрузками).
[Unit]
Description=Tune 40G NIC (${WAN_IF}) for VPN forwarding
After=network-pre.target
Before=network.target xray.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/vpn-nic-tune ${WAN_IF}

[Install]
WantedBy=multi-user.target
