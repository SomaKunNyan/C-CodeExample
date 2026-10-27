# vpn-https-debian

VPN-сервер поверх **HTTPS** для **Debian 12/13**, рассчитанный на размещение в дата-центре с сетью **40 Гбит/с**.
Проект содержит скрипты автоматической установки, шаблоны конфигураций и пошаговую документацию —
от первого входа на «голый» сервер до эксплуатации.

| Что | Чем |
|---|---|
| VPN-протокол | **OpenConnect / AnyConnect** — сервер [ocserv](https://ocserv.openconnect-vpn.net/) |
| Транспорт | **TLS 1.3** поверх TCP/443 (обычный HTTPS) + **DTLS 1.2** поверх UDP/443 (быстрый канал) |
| Шифрование | только AEAD: AES-256/128-GCM, ChaCha20-Poly1305; обмен ключами ECDHE (PFS) |
| Сертификат | Let's Encrypt, ECDSA P-256, автопродление без разрыва сессий |
| Аутентификация | пароль + **TOTP** (Google Authenticator, Aegis, FreeOTP), защита от перебора |
| Скрытность | режим *camouflage*: без секрета в URL сервер выглядит как обычный веб-сайт |
| DNS клиентов | собственный резолвер unbound с DNSSEC — без DNS-утечек |
| Firewall | nftables, default-deny, SNAT, MSS clamping, изоляция клиентов |
| Hardening ОС | SSH только по ключам, fail2ban, auditd, AppArmor, sysctl, автообновления безопасности |
| 40G | BBR + fq, буферы, conntrack, RSS-очереди NIC, ring buffers, UDP GRO forwarding |

## Почему ocserv (OpenConnect)

* **Это действительно HTTPS.** Клиент открывает TLS-соединение на порт 443, проходит HTTP-аутентификацию
  и получает туннель внутри того же TLS-соединения. Для сетевого оборудования и DPI это неотличимо
  от обычного веб-трафика — работает там, где UDP-VPN (WireGuard, IPsec) заблокированы.
* **Стабильность.** Данные идут по DTLS/UDP (без проблемы «TCP поверх TCP»), а если UDP режется по пути —
  автоматически переключаются на TLS/TCP без разрыва сессии. Keepalive, DPD, восстановление сессии
  по cookie при смене сети (Wi-Fi → LTE) без повторного ввода пароля.
* **Зрелость и безопасность.** Каждый клиент обслуживается отдельным непривилегированным процессом
  в chroot с seccomp-фильтром; ключи хранит отдельный процесс `sec-mod`.
* **Клиенты на всех платформах:** OpenConnect (Linux, Windows, macOS, Android), Cisco Secure Client
  (Windows, macOS, iOS, Android).

## Архитектура

```
                Интернет                                    Дата-центр (40G)
 ┌──────────┐                                  ┌───────────────────────────────────────────┐
 │ Клиент   │  TLS 1.3   TCP/443 (управление,  │  enp65s0f0 (40G NIC, RSS, ring buffers)   │
 │OpenConnect│═══════════ резервный канал) ═════▶│        │                                 │
 │ / Cisco  │  DTLS 1.2  UDP/443 (данные)       │   nftables: default drop, notrack UDP/443 │
 │ Secure   │═══════════════════════════════════▶│        │                                 │
 └──────────┘                                  │   ocserv  (main + sec-mod + worker/клиент)│
                                                │        │  vpns0..N (tun)                  │
                                                │        ├──▶ unbound :53 (DNS, DNSSEC)     │
                                                │        └──▶ forward ─▶ SNAT ─▶ Интернет   │
                                                └───────────────────────────────────────────┘
```

## Быстрый старт

> Подробно каждый шаг описан в [`docs/`](docs). Перед запуском обязательно прочитайте
> [01 — первоначальная настройка безопасности](docs/01-security-baseline.md).

1. **DNS:** создайте A-запись (и AAAA при наличии IPv6) `vpn.example.com → IP сервера`.
2. **Скопируйте проект на сервер** и заполните конфигурацию:
   ```bash
   apt-get update && apt-get install -y git
   git clone <URL этого репозитория> /opt/vpn-https-debian
   cd /opt/vpn-https-debian
   cp config.env.example config.env
   nano config.env           # домен, e-mail, интерфейс, SSH-ключ администратора
   ```
3. **Запустите установку** (из консоли/IPMI или SSH-сессии, которую вы НЕ закроете до проверки):
   ```bash
   sudo ./install.sh
   ```
   Или по шагам:
   ```bash
   sudo ./scripts/01-harden-system.sh     # безопасность ОС
   sudo ./scripts/02-firewall.sh          # nftables (с автооткатом через 60 c)
   sudo ./scripts/03-install-vpn.sh       # ocserv + Let's Encrypt + unbound
   sudo ./scripts/04-tune-performance.sh  # тюнинг под 40G
   ```
4. **Создайте пользователя VPN** (пароль + QR-код для TOTP):
   ```bash
   sudo ./scripts/vpn-user.sh add ivan
   ```
5. **Подключитесь** клиентом к `https://vpn.example.com/?<CAMOUFLAGE_SECRET>`
   (см. [04 — клиенты](docs/04-clients.md)).
6. **Проверка:** `sudo ./scripts/healthcheck.sh`, затем `sudo reboot` в удобное время.

## Структура проекта

```
├── install.sh                     # полная установка (шаги 01–04)
├── config.env.example             # все параметры проекта
├── scripts/
│   ├── lib.sh                     # общие функции
│   ├── 01-harden-system.sh        # hardening Debian
│   ├── 02-firewall.sh             # nftables + NAT, применение с откатом
│   ├── 03-install-vpn.sh          # ocserv, сертификат, DNS
│   ├── 04-tune-performance.sh     # sysctl, NIC, CPU под 40G
│   ├── vpn-nic-tune               # тюнинг NIC (запускается systemd при загрузке)
│   ├── vpn-user.sh                # управление пользователями VPN
│   └── healthcheck.sh             # проверка состояния (код возврата для мониторинга)
├── templates/                     # шаблоны конфигураций (ocserv, nftables, sshd, sysctl, ...)
└── docs/
    ├── 01-security-baseline.md    # первоначальная настройка безопасности
    ├── 02-vpn-server.md           # развёртывание VPN — весь процесс
    ├── 03-performance-40g.md      # производительность на 40 Гбит/с
    ├── 04-clients.md              # настройка клиентов
    └── 05-operations.md           # эксплуатация, мониторинг, обновления, диагностика
```

## Проверено

Сгенерированные конфигурации проверяются штатными валидаторами: `ocserv -t`, `nft -c`, `unbound-checkconf`,
`sshd -t`; скрипты — `shellcheck`. Скрипты идемпотентны: повторный запуск безопасен, перезаписываемые
файлы сохраняются в `/var/backups/vpn-https-debian/`.
