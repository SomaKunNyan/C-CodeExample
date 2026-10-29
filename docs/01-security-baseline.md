# 01. Первоначальная настройка безопасности Debian

Этот документ описывает **весь процесс** подготовки нового сервера в дата-центре: что сделать руками
до запуска скриптов, что делает `scripts/01-harden-system.sh` и `scripts/02-firewall.sh`, и как проверить
результат. Каждое действие скрипта можно выполнить и вручную — команды приведены.

---

## 0. До установки ОС (на стороне дата-центра)

| # | Действие | Зачем |
|---|---|---|
| 0.1 | Смените пароль по умолчанию **IPMI / iDRAC / iLO**, обновите прошивку BMC | BMC — полный доступ к серверу в обход ОС |
| 0.2 | Подключите BMC только к **сети управления** (out-of-band), не к публичной | Уязвимости BMC — частая точка входа |
| 0.3 | Включите **UEFI Secure Boot**, задайте пароль на BIOS/UEFI | Защита от загрузки чужой ОС/буткитов |
| 0.4 | Отключите в BIOS неиспользуемые устройства (USB-загрузка, лишние порты) | Меньше поверхность атаки |
| 0.5 | Для 40G: профиль **Performance** в BIOS (глубокие C-states выключены, Turbo включён), энергосбережение PCIe (ASPM) выключено | Стабильная задержка, нет «засыпания» ядер под нагрузкой |
| 0.6 | Убедитесь, что NIC стоит в слоте **PCIe 3.0 x8 / 4.0 x8+** и на NUMA-узле с основными ядрами | 40G требует ≥ 5 ГБ/с по шине |

## 1. Установка Debian

1. Скачайте **netinst ISO** Debian 13 (или 12) только с `https://www.debian.org/` и проверьте подпись:
   ```bash
   sha512sum -c SHA512SUMS --ignore-missing
   gpg --keyserver keyring.debian.org --recv-keys 0x988021A964E6EA7D
   gpg --verify SHA512SUMS.sign SHA512SUMS
   ```
2. При установке выберите **минимум**: только *SSH server* и *standard system utilities*
   (без графики, без web-сервера, без печати).
3. Разметка диска — рекомендуется отдельные разделы (или LVM-тома):

   | Раздел | Опции монтирования |
   |---|---|
   | `/` | defaults |
   | `/var/log` (≥ 20 ГБ) | `nodev,nosuid,noexec` — переполнение логов не положит систему |
   | `/var/log/audit` (≥ 5 ГБ) | `nodev,nosuid,noexec` |
   | `/tmp` | `tmpfs` с `nodev,nosuid,noexec` |
   | swap | по необходимости |

   Шифрование диска (LUKS) — по политике компании. Для сервера в ДЦ без удалённой разблокировки
   (dropbear-initramfs/Tang) оно усложняет перезагрузки; ключи TLS и пароли VPN в любом случае
   доступны только root.
4. Задайте сложный пароль root (он будет заблокирован скриптом позже) и **не создавайте**
   обычного пользователя с паролем-«по умолчанию».

## 2. Подготовка на рабочей станции администратора

```bash
# Ключ SSH — только ed25519 (или аппаратный ключ FIDO2: -t ed25519-sk)
ssh-keygen -t ed25519 -a 100 -C "admin@workstation" -f ~/.ssh/vpn_admin
cat ~/.ssh/vpn_admin.pub      # -> в ADMIN_SSH_PUBKEY в config.env
```

Создайте DNS-записи: `A vpn.example.com → <IPv4 сервера>` (и `AAAA`, если есть IPv6).
Без корректной A-записи Let's Encrypt не выдаст сертификат.

## 3. Первый вход и загрузка проекта

```bash
ssh root@<IP>                         # единственный раз под root
apt-get update && apt-get install -y git
git clone <URL репозитория> /opt/vpn-https-debian
cd /opt/vpn-https-debian
cp config.env.example config.env && chmod 600 config.env
nano config.env
```

Обязательно заполните: `WAN_IF` (`ip route get 1.1.1.1`), `ADMIN_USER`, `REALITY_DEST`,
`ADMIN_SSH_PUBKEY`, `SSH_PORT`. Настоятельно рекомендуется `SSH_ALLOW_FROM` — список IP/сетей
администраторов (офис, bastion, сеть управления ДЦ).

> ⚠️ **Правило безопасной работы с удалённым сервером:** держите открытой текущую сессию (или консоль
> IPMI) и проверяйте каждый шаг, связанный с SSH или firewall, **в новой сессии**. Скрипт firewall
> откатывает правила, если вы не подтвердите доступ за 60 секунд.

## 4. Что делает `01-harden-system.sh` — по шагам

### 4.1. Обновления
```bash
apt-get update && apt-get full-upgrade -y
```
Устанавливаются: `nftables fail2ban unattended-upgrades needrestart auditd apparmor chrony
libpam-pwquality debsums lynis` и утилиты.

### 4.2. Время
`timedatectl set-timezone UTC` и `chrony`. Точное время критично: TLS, **REALITY**
(клиент с сильно расходящимися часами не подключится), сопоставление логов при расследовании.

### 4.3. Администратор вместо root
* Создаётся `ADMIN_USER`, добавляется в группу `sudo`, ключ из `ADMIN_SSH_PUBKEY` → `~/.ssh/authorized_keys`.
* Запрашивается пароль администратора — он нужен для `sudo` (вход по ключу, повышение — по паролю:
  украденного ключа недостаточно для root).
* `sudo` журналирует все команды в `/var/log/sudo.log`, работает через pty, тайм-аут 5 минут.
* Пароль root блокируется: `passwd -l root`.

### 4.4. Пароли и ограничения
* `pwquality`: длина ≥ 14, ≥ 3 классов символов, проверка по словарю.
* `UMASK 027` — новые файлы не читаются «всеми».
* Core dumps отключены (в дампе процесса могут оказаться ключи TLS).

### 4.5. SSH (`/etc/ssh/sshd_config.d/10-hardening.conf`)

| Параметр | Значение | Зачем |
|---|---|---|
| `Port` | `SSH_PORT` (2222) | меньше автоматического шума в логах |
| `PermitRootLogin` | `no` | только через `ADMIN_USER` + sudo |
| `PasswordAuthentication`, `KbdInteractiveAuthentication` | `no` | перебор паролей невозможен |
| `AuthenticationMethods` | `publickey` | только ключи |
| `AllowUsers` | `ADMIN_USER` | никакой другой аккаунт не войдёт |
| `MaxAuthTries` / `LoginGraceTime` | 3 / 20 с | ограничение перебора |
| `PerSourcePenalties` | `yes` (OpenSSH ≥ 9.8, Debian 13) | встроенная задержка для атакующих адресов |
| `KexAlgorithms` | mlkem768x25519, sntrup761x25519, curve25519 | **постквантовый** гибридный обмен ключами |
| `Ciphers` / `MACs` | chacha20-poly1305, AES-GCM / ETM-SHA2 | только современная криптография |
| `X11/Agent/TcpForwarding`, `PermitTunnel` | `no` | SSH нельзя использовать как прокси |

Скрипт сам определяет, какие алгоритмы поддерживает установленный OpenSSH (Debian 12 — 9.2,
Debian 13 — 10.x), и проверяет конфигурацию `sshd -t` **до** перезапуска. Из `/etc/ssh/moduli`
удаляются группы DH < 3072 бит, хост-ключ — ed25519.

**Проверка — в новом окне:**
```bash
ssh -p 2222 -i ~/.ssh/vpn_admin sysadmin@<IP>
sudo -v
ssh -p 2222 root@<IP>                            # должно быть: Permission denied
ssh -p 2222 -o PubkeyAuthentication=no sysadmin@<IP>   # должно быть: Permission denied
```

### 4.6. Ядро (`/etc/sysctl.d/90-hardening.conf`)
* `kptr_restrict=2`, `dmesg_restrict=1`, `yama.ptrace_scope=2`, `unprivileged_bpf_disabled=1`,
  `kexec_load_disabled=1` — усложнение эксплуатации уязвимостей ядра и локального повышения прав.
* Защита ссылок/FIFO в общих каталогах (`fs.protected_*`).
* Сеть: запрет ICMP-redirect и source routing, `rp_filter=2` (антиспуфинг в loose-режиме — строгий
  режим ломает асимметричную маршрутизацию в ДЦ), SYN cookies, логирование «марсианских» пакетов.
* Модули редких протоколов (`dccp`, `sctp`, `rds`, `tipc`) и ФС, а также `usb-storage` запрещены
  к загрузке — по ним регулярно находят уязвимости.

### 4.7. Автообновления безопасности
* `unattended-upgrades` ставит обновления из `Debian-Security` и `-updates` ежедневно.
* `needrestart` автоматически перезапускает службы, использующие обновлённые библиотеки
  (например, OpenSSL → unbound). Xray — статический бинарник, его обновляет шаг 03 (см. [05](05-operations.md)).
* **Автоперезагрузка выключена**: обновления ядра применяются перезагрузкой в окно обслуживания
  (см. [05-operations](05-operations.md)).

### 4.8. Журналы и аудит
* `journald`: постоянное хранение, сжатие, лимит 2 ГБ, хранение 90 дней.
* `auditd` с правилами `templates/audit/50-vpn-hardening.rules`: изменения учётных записей, sudoers,
  SSH, **firewall**, загрузка модулей ядра, смена времени, команды от root, запущенные пользователями.
  Правила для **конфигурации Xray, его бинарника и DNS** (`60-vpn-xray.rules`) ставит шаг 03,
  когда эти каталоги уже созданы: auditd отвергает наблюдение за несуществующим каталогом.
  Поиск: `ausearch -k xray -i`.

### 4.9. fail2ban
* Jail `sshd` (backend systemd, действие nftables): 3 ошибки за 10 мин → бан на 1 час, повторные
  нарушители — экспоненциальный рост до 1 недели; jail `recidive` — бан на неделю на все порты.
* Подбирать что-либо у VPN бессмысленно: без 128-битного UUID и ключа REALITY сервер ведёт себя
  как обычный сайт-маскировка (см. [02](02-vpn-server.md)).

### 4.10. AppArmor и лишние службы
AppArmor включён; если присутствуют — отключаются `avahi`, `cups`, `rpcbind`, `exim4`, `bluetooth`,
`ModemManager`. Посмотреть, что слушает сеть: `ss -tulpn`. В итоге наружу должны смотреть только
SSH и 443/tcp.

## 5. Межсетевой экран — `02-firewall.sh`

Политика **default deny** для входящего и транзитного трафика (`/etc/nftables.conf`):

| Цепочка | Разрешено |
|---|---|
| `input` | loopback; established/related; ICMP (нужен для PMTU — без него «зависают» соединения); **TCP/443** (Xray); TCP/80 — только при своём сайте-заглушке (`REALITY_SELF_SITE`); SSH — с `SSH_ALLOW_FROM`, либо всем, но не чаще 6 новых подключений в минуту с адреса |
| `forward` | **ничего**: Xray — прокси, он сам открывает соединения к сайтам с адреса сервера, маршрутизация и NAT не нужны (`ip_forward = 0`) |

Доступ клиентов VPN к частным сетям (внутренняя сеть ДЦ, `10/8`, `192.168/16`, `127/8`...) и к
публичным адресам самого сервера (SSH, DNS) запрещён в самом Xray (`finalRules` в
`/etc/xray/config.json`) — иначе клиент мог бы попасть на SSH «изнутри», в обход `SSH_ALLOW_FROM`.

Отброшенные пакеты логируются с ограничением частоты (`journalctl -k | grep nft-`).

**Защита от потери доступа:** скрипт проверяет синтаксис (`nft -c`), применяет правила и ждёт
подтверждения `yes` 60 секунд. Нет подтверждения — восстанавливаются прежние правила.

**Если хостер предоставляет внешний (сетевой) firewall / anti-DDoS** — разрешите там те же порты:
`TCP 443` и `TCP SSH_PORT`.

## 6. Проверка результата

```bash
sudo ss -tulpn                       # слушаются только ожидаемые порты
sudo nft list ruleset | less
sudo fail2ban-client status sshd
sudo auditctl -l | head
sudo lynis audit system --quick      # независимый аудит; цель — Hardening index ≥ 80
sudo ./scripts/healthcheck.sh
```

С внешней машины:
```bash
nmap -Pn -p- --min-rate 2000 <IP>          # открыты только 443 и SSH_PORT
curl -sI --resolve <REALITY_DEST>:443:<IP> https://<REALITY_DEST>/   # ответ настоящего сайта-маскировки
```

## 7. Чек-лист

- [ ] BMC/IPMI в сети управления, пароль сменён, прошивка обновлена
- [ ] ISO Debian проверен по подписи, установлен минимальный набор
- [ ] Вход только по ключу под `ADMIN_USER`, root по SSH запрещён, пароль root заблокирован
- [ ] `SSH_ALLOW_FROM` ограничен сетями администраторов
- [ ] nftables: default drop, наружу только 443/SSH
- [ ] fail2ban, auditd, AppArmor, chrony, unattended-upgrades активны
- [ ] Время синхронизировано (`chronyc tracking`)
- [ ] `lynis` пройден, замечания разобраны
- [ ] Резервная копия `/etc/xray`, `config.env` сделана (см. [05](05-operations.md))
