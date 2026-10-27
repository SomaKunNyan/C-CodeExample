# /etc/ssh/sshd_config.d/10-hardening.conf
# Сгенерировано scripts/01-harden-system.sh. В OpenSSH действует ПЕРВОЕ
# найденное значение, а этот drop-in подключается в начале sshd_config,
# поэтому настройки ниже имеют приоритет над основным файлом.

Port ${SSH_PORT}
AddressFamily any

# --- Аутентификация: только ключи, root запрещён ---
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AuthenticationMethods publickey
UsePAM yes
AllowUsers ${ADMIN_USER}

# --- Ограничения перебора ---
LoginGraceTime 20
MaxAuthTries 3
MaxSessions 4
MaxStartups 10:30:60
${SSH_EXTRA}

# --- Криптография: только современные алгоритмы ---
# Список строится скриптом из того, что поддерживает установленный OpenSSH:
# mlkem768x25519 / sntrup761x25519 — постквантовые гибридные KEX + curve25519.
KexAlgorithms ${SSH_KEX}
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256
PubkeyAcceptedAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,sk-ssh-ed25519@openssh.com,rsa-sha2-512,rsa-sha2-256
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

# --- Лишние возможности выключены ---
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no

# --- Обрыв «мёртвых» сессий ---
ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive no

LogLevel VERBOSE
Banner /etc/issue.net
