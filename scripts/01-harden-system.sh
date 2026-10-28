#!/usr/bin/env bash
# =============================================================================
#  Шаг 1. Первоначальная настройка безопасности Debian.
#   - обновление системы и автообновления безопасности;
#   - администратор с sudo и входом только по SSH-ключу;
#   - усиление SSH, sysctl, журналирования, аудита;
#   - fail2ban, AppArmor, синхронизация времени.
#  Безопасно запускать повторно.
# =============================================================================
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require_root
require_debian
load_config

[[ ${ADMIN_SSH_PUBKEY} =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh.com|ssh-rsa|ecdsa-sha2-nistp[0-9]+)\ [A-Za-z0-9+/=]{40,} ]] \
    || die "ADMIN_SSH_PUBKEY не похож на публичный SSH-ключ. Без него вы потеряете доступ к серверу."

# --- 1. Обновление системы ---------------------------------------------------
log "Обновление пакетов"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y -o Dpkg::Options::=--force-confold full-upgrade

log "Установка базовых пакетов безопасности"
apt_install sudo ca-certificates curl gnupg openssh-server \
    nftables fail2ban python3-systemd \
    unattended-upgrades apt-listchanges needrestart debsums \
    auditd audispd-plugins apparmor apparmor-utils \
    chrony libpam-pwquality gettext-base \
    lynis ethtool irqbalance htop iftop jq

# --- 2. Время: UTC + chrony (важно для TLS, REALITY и логов) -------------------
log "Часовой пояс UTC, синхронизация времени (chrony)"
timedatectl set-timezone UTC
systemctl enable --now chrony

# --- 3. Администратор ---------------------------------------------------------
if ! id "${ADMIN_USER}" >/dev/null 2>&1; then
    log "Создаю пользователя ${ADMIN_USER}"
    adduser --disabled-password --gecos "" "${ADMIN_USER}"
fi
usermod -aG sudo "${ADMIN_USER}"

admin_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
install -d -m 0700 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "${admin_home}/.ssh"
auth_keys="${admin_home}/.ssh/authorized_keys"
touch "${auth_keys}"
grep -qxF "${ADMIN_SSH_PUBKEY}" "${auth_keys}" || printf '%s\n' "${ADMIN_SSH_PUBKEY}" >> "${auth_keys}"
chown "${ADMIN_USER}:${ADMIN_USER}" "${auth_keys}"
chmod 0600 "${auth_keys}"

# sudo по паролю: при входе по ключу пароль нужен для повышения привилегий.
if ! passwd -S "${ADMIN_USER}" | awk '{exit ($2=="P")?0:1}'; then
    warn "У ${ADMIN_USER} нет пароля — задайте его сейчас (нужен для sudo):"
    passwd "${ADMIN_USER}"
fi

cat > /etc/sudoers.d/90-hardening <<'EOF'
Defaults use_pty
Defaults logfile="/var/log/sudo.log"
Defaults timestamp_timeout=5
Defaults passwd_tries=3
EOF
chmod 0440 /etc/sudoers.d/90-hardening
visudo -cq

# Блокируем пароль root: вход только через sudo.
passwd -l root >/dev/null

# --- 4. Политика паролей, umask, core dumps ---------------------------------
log "Политика паролей и ограничения"
install -d /etc/security/pwquality.conf.d
cat > /etc/security/pwquality.conf.d/90-hardening.conf <<'EOF'
minlen = 14
minclass = 3
maxrepeat = 3
dictcheck = 1
enforce_for_root
EOF
sed -ri 's/^UMASK\s+.*/UMASK\t\t027/' /etc/login.defs
cat > /etc/security/limits.d/90-nocore.conf <<'EOF'
* hard core 0
EOF
install -d /etc/systemd/coredump.conf.d
printf '[Coredump]\nStorage=none\nProcessSizeMax=0\n' > /etc/systemd/coredump.conf.d/90-disable.conf

# --- 5. SSH ---------------------------------------------------------------------
log "Усиление SSH (порт ${SSH_PORT}, только ключи, без root)"
supported_kex="$(ssh -Q kex)"
SSH_KEX=""
for k in mlkem768x25519-sha256 sntrup761x25519-sha512 sntrup761x25519-sha512@openssh.com \
         curve25519-sha256 curve25519-sha256@libssh.org; do
    grep -qxF "$k" <<<"${supported_kex}" && SSH_KEX+="${SSH_KEX:+,}$k"
done
SSH_EXTRA="# PerSourcePenalties не поддерживается этой версией OpenSSH"
if sshd -T -o PerSourcePenalties=yes >/dev/null 2>&1; then
    SSH_EXTRA="PerSourcePenalties yes"
fi
export SSH_KEX SSH_EXTRA

# Ключ ed25519 хоста; слабые (DSA/ECDSA) не используем.
[[ -f /etc/ssh/ssh_host_ed25519_key ]] || ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/ssh_host_ed25519_key
# Удаляем слабые модули DH (< 3072 бит), если используется DH-GEX.
if [[ -f /etc/ssh/moduli ]]; then
    backup_file /etc/ssh/moduli
    awk '$5 >= 3071' /etc/ssh/moduli > /etc/ssh/moduli.safe && mv /etc/ssh/moduli.safe /etc/ssh/moduli
fi

install_file "${TEMPLATES_DIR}/ssh/issue.net" /etc/issue.net
render "${TEMPLATES_DIR}/ssh/10-hardening.conf.tpl" /etc/ssh/sshd_config.d/10-hardening.conf 0600 \
    SSH_PORT ADMIN_USER SSH_KEX SSH_EXTRA

# Debian 12+: sshd может запускаться через ssh.socket — тогда порт задаётся в
# сокете, а не в sshd_config. Переключаемся на классический ssh.service.
if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    systemctl disable --now ssh.socket
    systemctl enable ssh.service
fi

sshd -t || die "sshd -t: конфигурация SSH некорректна, не перезапускаю sshd."
systemctl restart ssh
warn "SSH теперь на порту ${SSH_PORT}. НЕ закрывайте текущую сессию, пока не проверите"
warn "вход в новом окне:  ssh -p ${SSH_PORT} ${ADMIN_USER}@<IP-сервера>"

# --- 6. sysctl ---------------------------------------------------------------
log "Усиление параметров ядра (sysctl)"
install_file "${TEMPLATES_DIR}/sysctl/90-hardening.conf" /etc/sysctl.d/90-hardening.conf
sysctl --system >/dev/null

# --- 7. Автообновления безопасности ------------------------------------------
log "Автоматическая установка обновлений безопасности"
install_file "${TEMPLATES_DIR}/apt/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
install_file "${TEMPLATES_DIR}/apt/52unattended-upgrades-local" /etc/apt/apt.conf.d/52unattended-upgrades-local
systemctl enable --now unattended-upgrades
# needrestart: автоматически перезапускать службы после обновления библиотек.
install -d /etc/needrestart/conf.d
echo "\$nrconf{restart} = 'a';" > /etc/needrestart/conf.d/90-auto.conf

# --- 8. Журналы и аудит ------------------------------------------------------
log "journald (постоянное хранение, ротация) и auditd"
install_file "${TEMPLATES_DIR}/journald/50-vpn.conf" /etc/systemd/journald.conf.d/50-vpn.conf
systemctl restart systemd-journald
install_file "${TEMPLATES_DIR}/audit/50-vpn-hardening.rules" /etc/audit/rules.d/50-vpn-hardening.rules 0640
# Сбой аудита не должен прерывать остальной hardening (fail2ban, AppArmor...).
systemctl enable auditd || warn "auditd: не удалось включить автозапуск"
if systemctl restart auditd && augenrules --load >/dev/null; then
    log "  auditd: загружено правил: $(auditctl -l | grep -vc '^No rules')"
else
    warn "auditd не запустился или правила не загрузились — продолжаю без него."
    warn "  Диагностика: systemctl --failed; journalctl -b -u auditd -u audit-rules --no-pager"
fi

# --- 9. fail2ban -------------------------------------------------------------
log "fail2ban для SSH"
F2B_IGNORE="${SSH_ALLOW_FROM}"
export F2B_IGNORE
render "${TEMPLATES_DIR}/fail2ban/sshd.local.tpl" /etc/fail2ban/jail.d/sshd.local 0644 F2B_IGNORE SSH_PORT
systemctl enable fail2ban
systemctl restart fail2ban

# --- 10. AppArmor и лишние службы --------------------------------------------
log "AppArmor и отключение ненужных служб"
systemctl enable --now apparmor
for svc in avahi-daemon cups rpcbind exim4 bluetooth ModemManager; do
    if systemctl list-unit-files "${svc}.service" | grep -q "^${svc}\.service"; then
        systemctl disable --now "${svc}.service" || true
        log "  отключено: ${svc}"
    fi
done

# Загрузка редких сетевых протоколов и файловых систем запрещена.
cat > /etc/modprobe.d/90-hardening.conf <<'EOF'
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
install cramfs /bin/false
install freevxfs /bin/false
install hfs /bin/false
install hfsplus /bin/false
install jffs2 /bin/false
install udf /bin/false
install usb-storage /bin/false
EOF

log "Готово. Рекомендуется: lynis audit system — для независимой проверки."
