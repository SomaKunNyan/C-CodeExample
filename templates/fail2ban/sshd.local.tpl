# /etc/fail2ban/jail.d/sshd.local
[DEFAULT]
backend   = systemd
banaction = nftables-multiport
banaction_allports = nftables-allports
# Не баним сети администраторов.
ignoreip  = 127.0.0.1/8 ::1 ${F2B_IGNORE}

[sshd]
enabled  = true
port     = ${SSH_PORT}
mode     = aggressive
maxretry = 3
findtime = 10m
bantime  = 1h
# Повторные нарушители — бан растёт экспоненциально (до 1 недели).
bantime.increment = true
bantime.maxtime   = 1w

[recidive]
enabled  = true
backend  = auto
logpath  = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime  = 1w
findtime = 1d
maxretry = 5
