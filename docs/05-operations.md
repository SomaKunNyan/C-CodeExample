# 05. Эксплуатация

## Автоматически

| Что | Как |
|---|---|
| Обновления безопасности ОС | `unattended-upgrades` (ежедневно), `needrestart` перезапускает службы |
| Защита SSH | fail2ban, nftables rate-limit |
| Аудит | auditd (`ausearch -k xray -i` — изменения конфигурации VPN), journald 90 дней |

Xray — отдельный бинарник с GitHub, **apt его не обновляет** (см. «Обновление Xray»).

## Кто подключён, трафик

```bash
sudo ./scripts/vpn-user.sh list
```
```
ПОЛЬЗОВАТЕЛЬ  АКТИВЕН  СОЗДАН      СКАЧАНО  ОТПРАВЛЕНО  ОНЛАЙН (IP)
ivan          да       2026-10-28  12.0GiB  310.0MiB    да (198.51.100.7)
petr          нет      2026-10-28  0B       0B          -
```
Трафик считается с последнего перезапуска Xray.

Напрямую через API Xray (слушает только `127.0.0.1:10085`):
```bash
X=/usr/local/bin/xray; S=--server=127.0.0.1:10085
$X api statsgetallonlineusers $S                 # кто онлайн
$X api statsonlineiplist $S -email ivan          # с каких IP подключён ivan
$X api statsquery $S -pattern 'user>>>'          # трафик всех пользователей
$X api statsquery $S -pattern 'user>>>' -reset   # ... и обнулить счётчики (например, раз в месяц)
```

Сервер в целом:
```bash
systemctl status xray
journalctl -u xray --since -1h          # ошибки (уровень warning)
ss -Htn state established '( sport = :443 )' | wc -l    # число TCP-соединений клиентов
iftop -i enp1s0                         # трафик интерфейса
sudo ./scripts/healthcheck.sh           # код возврата 0/1 — для мониторинга
```

**История «кто куда ходил» не пишется**: `XRAY_ACCESS_LOG="no"`. Включение (`yes` в `config.env` +
`03-install-vpn.sh`) записывает в журнал каждое соединение пользователей с адресами сайтов — это
персональные данные; включайте только при необходимости (расследование злоупотреблений) и
предупредите пользователей.

Мониторинг по cron:
```cron
*/5 * * * * root /opt/vpn-https-debian/scripts/healthcheck.sh >/var/log/vpn-health.log 2>&1 || logger -p user.err "VPN healthcheck FAILED"
```

## Изменение конфигурации

Правьте `config.env` и запускайте нужный шаг повторно (идемпотентно, старые файлы — в
`/var/backups/vpn-https-debian/`):
```bash
sudo ./scripts/03-install-vpn.sh     # Xray, REALITY_DEST, unbound
sudo ./scripts/02-firewall.sh        # nftables (порт Xray, SSH)
```
Ключи REALITY и пользователи сохраняются — ссылки у клиентов остаются рабочими. Если поменяли
`REALITY_DEST`/`REALITY_SERVER_NAMES`/`LINK_ADDRESS`/`PUBLIC_IPV4`/`VPN_DOMAIN`/`XRAY_PORT` — у клиентов поменяется ссылка:
раздайте новые (`vpn-user.sh link <имя>`).

## Обновление Xray

```bash
sudo ./scripts/03-install-vpn.sh      # XRAY_VERSION="latest" — поставит новую версию, если вышла
/usr/local/bin/xray version
```
Перед обновлением прочитайте release notes на https://github.com/XTLS/Xray-core/releases —
иногда меняются параметры конфигурации. Скрипт проверяет новый конфиг (`xray run -test`) и
контрольную сумму релиза. Обновляйте раз в 1–2 месяца или сразу при исправлениях безопасности.

## Если IP заблокировали

Признак: из определённых сетей (или из всей страны) соединение с `IP:443` не устанавливается,
хотя из других стран сервер доступен. REALITY здесь не поможет — блокируется адрес. Порядок:

1. Получите новый IP (у хостера — смена адреса, либо новый VPS; у облаков с почасовой оплатой —
   новый сервер за минуту).
2. Перенесите `config.env`, `split-exclude.txt` и резервную копию `/etc/xray` (раздел ниже),
   разверните проект — **ключи и UUID те же, ссылки клиентов не меняются**.
3. По умолчанию ссылки содержат IP (`LINK_ADDRESS="ip"`): раздайте новые ссылки
   (`vpn-user.sh link <имя>`). Если используете `LINK_ADDRESS="domain"` — достаточно поменять
   A-запись `VPN_DOMAIN` (TTL 300), ссылки клиентов останутся прежними.

Домен удобнее при частой смене IP, IP — надёжнее, когда DNS у клиентов отдаёт устаревшие ответы.

## Перезагрузка и обновление ядра

1. Нужна ли: `sudo needrestart -k` или наличие `/run/reboot-required`.
2. В окно обслуживания: `sudo reboot`. Клиенты переподключатся сами.
3. После загрузки: `sudo ./scripts/healthcheck.sh`.

## Резервное копирование

```bash
sudo tar czf vpn-backup-$(date +%F).tar.gz /etc/xray /opt/vpn-https-debian/config.env \
     /opt/vpn-https-debian/split-exclude.txt 2>/dev/null
sudo gpg --symmetric --cipher-algo AES256 vpn-backup-*.tar.gz && sudo shred -u vpn-backup-*.tar.gz
```
В архиве **ключ REALITY и UUID всех пользователей** — храните только зашифрованным и вне сервера.
Восстановление: шаги 01–02, распаковать архив, шаг 03.

## Реагирование на инциденты

| Событие | Действия |
|---|---|
| Утекла ссылка пользователя | `vpn-user.sh reset <имя>` — старая перестаёт работать сразу |
| Утёк `/etc/xray/keys.json` (ключ REALITY) | удалить `keys.json`, запустить `03-install-vpn.sh` (новые ключи), раздать новые ссылки всем |
| Жалоба хостера на трафик (спам, торренты, атаки) | временно `XRAY_ACCESS_LOG="yes"`, найти пользователя, `lock`; затем выключить журнал |
| Подозрение на взлом сервера | изолировать (доступ только через консоль хостера), снять образ диска, развернуть **новый** сервер, сменить ключи REALITY и UUID всех пользователей |

## Периодически (раз в квартал)

- [ ] `sudo lynis audit system` — сравнить hardening index с прошлым
- [ ] `nmap` снаружи — открыты только 443 и SSH
- [ ] сайт-маскировка всё ещё отвечает по TLS 1.3 / HTTP/2 (`healthcheck.sh`)
- [ ] ревизия пользователей VPN: `vpn-user.sh list`, удалить неактивных
- [ ] ревизия `authorized_keys` администраторов
- [ ] проверка восстановления из резервной копии
