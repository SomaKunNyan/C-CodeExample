# vpn-https-debian

VPN-сервер на **Xray: VLESS + REALITY** (транспорт **XHTTP** или **XTLS Vision**) на TCP/443 для **Debian 12/13**,
с первоначальной настройкой безопасности ОС и тюнингом под сеть до **40 Гбит/с**.
Проект содержит скрипты автоматической установки, шаблоны конфигураций и пошаговую документацию.

| Что | Чем |
|---|---|
| VPN-протокол | **VLESS**, сервер [Xray-core](https://github.com/XTLS/Xray-core); транспорт **XHTTP** (HTTP/2-запросы, по умолчанию) или **XTLS Vision** (`XRAY_TRANSPORT`) |
| Транспорт | **REALITY**: TLS 1.3 на TCP/443 с SNI и сертификатом настоящего постороннего сайта, отпечаток Chrome |
| Шифрование | TLS 1.3 (x25519 / X25519MLKEM768, AES-GCM / ChaCha20-Poly1305), PFS |
| Скрытность | без ключа клиента сервер неотличим от сайта-маскировки — и для сканеров, и для активных проверок DPI; можно маскироваться под чужой сайт или под **свой сайт-заглушку** (`REALITY_SELF_SITE`) |
| Сертификат / домен | не нужны (домен — по желанию, для удобной смены IP) |
| Пользователи | UUID на пользователя, ссылки `vless://` и QR-коды, блокировка/перевыпуск, трафик и онлайн по каждому |
| Исключения | сайты мимо VPN — по доменам, на стороне клиента (`split-exclude.txt`, «регион Россия» в Hiddify) |
| Hardening ОС | SSH только по ключам, nftables default-deny, fail2ban, auditd, AppArmor, sysctl, автообновления |
| Изоляция | Xray без root, песочница systemd; клиентам закрыт доступ к сети ДЦ и к самому серверу; SMTP/BitTorrent заблокированы |
| 40G | BBR + fq, буферы, conntrack, RSS-очереди NIC, ring buffers; Vision + splice — мало CPU на гигабит |

## Архитектура

```
 Клиент (v2rayNG, Hiddify,                    VPS / сервер в ДЦ
 Streisand, v2rayN...)          ┌──────────────────────────────────────────────┐
        │  TCP/443, TLS 1.3     │ nftables: открыты только 443 и SSH           │
        │  SNI = сайт-маскировка│                                              │
        └──────────────────────▶│ Xray (пользователь xray, песочница systemd)  │
                                │  ├ метка REALITY верна → VLESS → сайты ──────┼──▶ Интернет
   Сканер / проверка DPI ──────▶│  └ нет метки → прозрачно на настоящий сайт   │
                                │ unbound 127.0.0.1 (DNS, DNSSEC)              │
                                └──────────────────────────────────────────────┘
```

## Быстрый старт

> Подробно — в [`docs/`](docs). Перед запуском прочитайте
> [01 — первоначальная настройка безопасности](docs/01-security-baseline.md)
> и раздел «Выбор сайта для маскировки» в [02](docs/02-vpn-server.md).

1. **Загрузите проект на сервер** и заполните конфигурацию:
   ```bash
   git clone <URL этого репозитория> /opt/vpn-https-debian
   cd /opt/vpn-https-debian
   cp config.env.example config.env
   nano config.env      # WAN_IF, SSH-ключ администратора, REALITY_DEST
   ```
2. **Запустите установку** (не закрывайте текущую SSH-сессию до проверки входа в новой):
   ```bash
   sudo ./install.sh
   ```
   Или по шагам:
   ```bash
   sudo ./scripts/01-harden-system.sh     # безопасность ОС
   sudo ./scripts/02-firewall.sh          # nftables (с автооткатом через 60 c)
   sudo ./scripts/03-install-vpn.sh       # Xray VLESS + REALITY, unbound
   sudo ./scripts/04-tune-performance.sh  # тюнинг сети
   ```
3. **Создайте пользователя** — получите ссылку `vless://` и QR-код:
   ```bash
   sudo ./scripts/vpn-user.sh add ivan
   ```
4. **Подключитесь** — импортируйте ссылку в приложение (см. [04 — клиенты](docs/04-clients.md)).
5. **Проверка:** `sudo ./scripts/healthcheck.sh`, затем `sudo reboot` в удобное время.

### Переход с прежней версии проекта (OpenConnect / ocserv)

```bash
cd /opt/vpn-https-debian && git pull
nano config.env                       # добавьте REALITY_DEST (см. config.env.example)
sudo ./scripts/02-firewall.sh         # новые правила: только TCP/443 и SSH, без NAT
sudo ./scripts/03-install-vpn.sh      # остановит ocserv и установит Xray
sudo apt purge ocserv certbot         # по желанию, после проверки
```
Пользователей нужно создать заново (`vpn-user.sh add`) — у VLESS другая модель доступа.

## Структура проекта

```
├── install.sh                     # полная установка (шаги 01–04)
├── config.env.example             # все параметры проекта
├── split-exclude.example.txt      # пример списка сайтов мимо VPN (для клиентских конфигов)
├── scripts/
│   ├── lib.sh                     # общие функции
│   ├── 01-harden-system.sh        # hardening Debian
│   ├── 02-firewall.sh             # nftables, применение с откатом
│   ├── 03-install-vpn.sh          # Xray (проверка SHA-256), ключи REALITY, unbound
│   ├── self-site.sh               # свой сайт-заглушка для REALITY: nginx + Let's Encrypt
│   ├── 04-tune-performance.sh     # sysctl, NIC, CPU
│   ├── vpn-user.sh                # пользователи: ссылки, QR, блокировка, статистика
│   ├── xray-vpn.py                # генератор конфигов сервера/клиентов и ссылок
│   ├── vpn-nic-tune               # тюнинг NIC (запускается systemd при загрузке)
│   └── healthcheck.sh             # проверка состояния (код возврата для мониторинга)
├── templates/                     # шаблоны конфигураций (nftables, sshd, sysctl, systemd, nginx, ...)
│   └── site/                      # страницы сайта-заглушки (index, 404, robots.txt)
└── docs/
    ├── 01-security-baseline.md    # первоначальная настройка безопасности
    ├── 02-vpn-server.md           # Xray VLESS + REALITY: как работает, установка, пользователи
    ├── 03-performance-40g.md      # производительность
    ├── 04-clients.md              # приложения для всех платформ
    ├── 05-operations.md           # мониторинг, обновления, смена IP, бэкап, инциденты
    └── 06-split-tunneling.md      # сайты мимо VPN
```

## Проверка

Скрипты проверяются `shellcheck`; конфигурации nftables и unbound — `nft -c` и `unbound-checkconf`.
Конфигурацию Xray скрипт проверяет на сервере (`xray run -test`) **до** применения. Скрипты
идемпотентны: повторный запуск безопасен, перезаписываемые файлы сохраняются в
`/var/backups/vpn-https-debian/`.
