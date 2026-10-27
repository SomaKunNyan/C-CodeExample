# /etc/systemd/system/vpn-split-routes.service
[Unit]
Description=Update VPN split-exclude routes from domain list
After=network-online.target unbound.service ocserv.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${PROJECT_DIR}/scripts/update-split-routes.sh
