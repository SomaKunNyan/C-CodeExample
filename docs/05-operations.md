# 05. Эксплуатация

## Ежедневно / автоматически

| Что | Как |
|---|---|
| Обновления безопасности | `unattended-upgrades` (ежедневно), `needrestart` перезапускает службы |
| Продление сертификата | `certbot.timer` + reload ocserv без разрыва сессий |
| Защита от перебора | ocserv `max-ban-score` (VPN), fail2ban (SSH) |
| Аудит | auditd, journald (90 дней) |

## Мониторинг

`scripts/healthcheck.sh` возвращает код `0`/`1` — его удобно вызывать из любой системы мониторинга
(Zabbix `system.run`, Nagios/Icinga check, cron + почта):

```cron
*/5 * * * * root /opt/vpn-https-debian/scripts/healthcheck.sh >/var/log/vpn-health.log 2>&1 || logger -p user.err "VPN healthcheck FAILED"
```

Что ещё стоит собирать (например, node_exporter + Prometheus):
* трафик и pps на `WAN_IF`, ошибки/дропы NIC (`ethtool -S`);
* загрузка CPU по ядрам (softirq!);
* `nf_conntrack_count / nf_conntrack_max`;
* число клиентов: `occtl -j show users | jq length`;
* срок действия сертификата;
* внешняя проверка доступности TCP/443 и UDP/443 из другой сети.

Полезные команды:
```bash
sudo occtl show status               # аптайм, сессии, баны
sudo occtl show users                # кто подключён, IP, трафик
sudo occtl show user ivan
sudo occtl disconnect user ivan
sudo occtl show ip bans
sudo journalctl -u ocserv --since -1h
sudo ausearch -k ocserv -i           # кто менял конфигурацию VPN
sudo fail2ban-client status sshd
```

## Изменение конфигурации

Не редактируйте файлы на сервере вручную — правьте `config.env` или шаблоны в `templates/`,
затем перезапустите нужный шаг (скрипты идемпотентны, старые версии сохраняются в
`/var/backups/vpn-https-debian/`):
```bash
sudo ./scripts/03-install-vpn.sh     # ocserv/unbound
sudo ./scripts/02-firewall.sh        # nftables
```
Изменения, не требующие перезапуска ocserv (маршруты, DNS для новых сессий, сертификат):
`sudo systemctl reload ocserv`. Изменение сети/портов — `restart` (клиенты переподключатся
автоматически по cookie).

## Обновление ядра и перезагрузка

1. Проверить, нужна ли перезагрузка: `sudo needrestart -k` или наличие `/run/reboot-required`.
2. В окно обслуживания: предупредить пользователей → `sudo reboot`.
3. После загрузки: `sudo ./scripts/healthcheck.sh`.

Клиенты OpenConnect/Cisco переподключатся сами (сессионный cookie переживает перезапуск благодаря
`persistent-cookies`, если перезагрузка уложилась в `cookie-timeout`; иначе — повторный вход).

## Переход на новую версию Debian

Рекомендуемый путь — **новый сервер** (blue/green): развернуть проект на свежем Debian, перенести
резервную копию, переключить DNS-запись, через сутки вывести старый сервер. Обновление «на месте»
(`apt full-upgrade` со сменой codename) возможно, но рискованнее для удалённой машины.

## Резервное копирование

Достаточно сохранить:
```bash
sudo tar czf vpn-backup-$(date +%F).tar.gz \
  /etc/ocserv /etc/letsencrypt /etc/nftables.conf /etc/unbound/unbound.conf.d \
  /opt/vpn-https-debian/config.env
sudo gpg --symmetric --cipher-algo AES256 vpn-backup-*.tar.gz && sudo shred -u vpn-backup-*.tar.gz
```
Архив содержит **секреты** (ключ TLS, хеши паролей, TOTP-ключи) — храните только зашифрованным,
вне сервера. Восстановление: развернуть проект (шаги 01–04), распаковать архив поверх,
`systemctl restart ocserv`.

## Реагирование на инциденты

| Событие | Действия |
|---|---|
| Скомпрометирована учётная запись VPN | `vpn-user.sh lock <user>` (немедленное отключение), `vpn-user.sh otp` + `passwd`, анализ `journalctl -u ocserv | grep <user>` |
| Утечка ключа TLS | `certbot revoke --cert-name vpn.example.com --reason keycompromise`, удалить и выпустить заново (`03-install-vpn.sh`), сменить `CAMOUFLAGE_SECRET` |
| Подозрение на взлом сервера | изолировать (оставить доступ только через IPMI), снять образ диска/памяти для анализа, развернуть **новый** сервер из проекта и бэкапа, сменить все пароли/TOTP/ключи |
| DDoS на 443 | включить anti-DDoS хостера; ocserv ограничивает частоту (`rate-limit-ms`) и банит; при необходимости — временно `SSH_ALLOW_FROM` и whitelisting в nftables |

## Периодически (раз в квартал)

- [ ] `sudo lynis audit system` — сравнить hardening index с прошлым
- [ ] внешняя проверка TLS (`testssl.sh vpn.example.com`)
- [ ] `nmap` снаружи — открыты только ожидаемые порты
- [ ] ревизия пользователей VPN: `vpn-user.sh list`, удалить уволенных/неактивных
- [ ] ревизия `authorized_keys` администраторов
- [ ] проверка восстановления из резервной копии
- [ ] `debsums -s` — целостность файлов пакетов
