# 02. Развёртывание VPN-сервера поверх HTTPS — весь процесс

## 1. Как это работает

ocserv реализует протокол **OpenConnect** (совместим с Cisco AnyConnect). Подключение проходит так:

1. Клиент устанавливает **TLS 1.3**-соединение с `vpn.example.com:443` (TCP) и проверяет сертификат
   Let's Encrypt — так же, как браузер.
2. Внутри TLS — обычный HTTP: `POST /` с логином, паролем и TOTP-кодом. Сервер выдаёт
   сессионный cookie.
3. Клиент отправляет `CONNECT /CSCOVPNSESSION` — HTTPS-соединение превращается в туннель
   (CSTP), сервер передаёт IP-адрес, маршруты, DNS, MTU.
4. Параллельно поднимается **DTLS 1.2** по UDP/443 с ключами, выведенными из того же TLS-сеанса.
   Пока DTLS работает, данные идут по нему (UDP — нет проблемы «TCP поверх TCP», выше скорость).
5. Если UDP/443 заблокирован или пропал (нет ответа 25 с), данные **автоматически** продолжают идти
   через TLS/TCP. Пользователь этого не замечает.

```
Клиент ──TCP/443── TLS 1.3 ── HTTP auth ── CONNECT ──▶ CSTP-туннель (резерв, всегда есть)
       ──UDP/443── DTLS 1.2 (AES-GCM) ───────────────▶ основной канал данных
```

### Модель безопасности ocserv

| Процесс | Привилегии | Роль |
|---|---|---|
| `ocserv-main` | root | принимает соединения, создаёт tun-устройства |
| `ocserv-sm` (sec-mod) | root, отдельный процесс | хранит **приватный ключ TLS**, проверяет пароли/OTP. Worker'ы никогда не видят ключ |
| worker (по одному на клиента) | `ocserv`, chroot `/var/lib/ocserv`, **seccomp** | разбор протокола клиента. Компрометация одного worker'а не даёт доступа ни к ключу, ни к другим клиентам |

Дополнительно systemd-песочница (`templates/systemd/ocserv-override.conf`): `ProtectSystem=full`,
`ProtectHome`, `PrivateTmp`, `ProtectKernel*`, автоматический перезапуск при сбое.

## 2. Подготовка

* Выполнен [01 — базовая безопасность](01-security-baseline.md) и firewall (`02-firewall.sh`).
* DNS: `vpn.example.com` → IP сервера (`dig +short vpn.example.com`).
* Порты 80/tcp, 443/tcp, 443/udp открыты (в т.ч. во внешнем firewall хостера).
* В `config.env` заданы `VPN_NET4` / `VPN_GW4` (пул клиентов — не пересекающийся с сетями ДЦ и
  типичными домашними сетями; по умолчанию `10.88.0.0/16`), `VPN_NET6`, `ENABLE_OTP`.

## 3. Установка — `03-install-vpn.sh`

```bash
sudo ./scripts/03-install-vpn.sh
```

### 3.1. Пакеты
`ocserv certbot unbound dns-root-data oathtool qrencode gnutls-bin`. Модули ядра `tun`,
`nf_conntrack`, `tcp_bbr` загружаются заранее (`/etc/modules-load.d/vpn.conf`) — ocserv работает
в песочнице и загрузить их не сможет.

### 3.2. TLS-сертификат
```bash
certbot certonly --standalone --preferred-challenges http \
  --key-type ecdsa --elliptic-curve secp256r1 -d vpn.example.com -m admin@example.com --agree-tos
```
* **ECDSA P-256** — рукопожатие в разы дешевле RSA-2048/4096 по CPU (важно при массовых
  переподключениях), безопасность эквивалентна RSA-3072.
* Публично доверенный сертификат: клиенты проверяют его штатно, не нужно раздавать CA/отпечатки,
  MITM невозможен без компрометации CA.
* Автопродление — `certbot.timer` (дважды в сутки). Deploy-hook
  `/etc/letsencrypt/renewal-hooks/deploy/ocserv-reload.sh` выполняет `systemctl reload ocserv`
  (SIGHUP) — новый сертификат подхватывается **без разрыва** активных сессий.
* Проверка продления: `sudo certbot renew --dry-run`.

### 3.3. Конфигурация `/etc/ocserv/ocserv.conf`

Генерируется из `templates/ocserv/ocserv.conf.tpl` и проверяется `ocserv -t` до перезапуска.
Ключевые решения:

**Шифрование**
```
tls-priorities = "NORMAL:%SERVER_PRECEDENCE:-VERS-ALL:+VERS-TLS1.3:+VERS-TLS1.2:+VERS-DTLS1.2:
                  -RSA:-DHE-RSA:-AES-128-CBC:-AES-256-CBC:-CAMELLIA-...:-3DES-CBC:-AES-128-CCM:-AES-256-CCM:
                  -ARCFOUR-128:-SHA1:-MD5:-SIGN-RSA-SHA1:-SIGN-ECDSA-SHA1"
```
Итоговый набор (проверено `gnutls-cli -l --priority ...`):

| Протокол | Наборы |
|---|---|
| TLS 1.3 | `TLS_AES_256_GCM_SHA384`, `TLS_CHACHA20_POLY1305_SHA256`, `TLS_AES_128_GCM_SHA256` |
| TLS 1.2 / DTLS 1.2 | `ECDHE-ECDSA-AES-256-GCM`, `ECDHE-ECDSA-CHACHA20-POLY1305`, `ECDHE-ECDSA-AES-128-GCM` |

Только AEAD, только PFS (ECDHE, X25519/P-256), без CBC, SHA1, RSA key exchange. TLS ≤ 1.1 отвергается.

**Аутентификация и защита от перебора**
```
auth = "plain[passwd=/etc/ocserv/ocpasswd,otp=/etc/ocserv/users.oath]"
max-ban-score = 80              # 8 неверных паролей → бан IP
ban-reset-time = 1200           # на 20 минут
auth-timeout = 120
min-reauth-time = 300
```
Пароли хранятся как SHA-512-crypt. Второй фактор — **TOTP** (RFC 6238, 30 с, 6 цифр), секреты
в `/etc/ocserv/users.oath` (только root, `0600`). liboath запоминает последний использованный код —
повторное использование перехваченного кода невозможно.

> Альтернатива для организаций: `auth = "radius[...]"` (FreeIPA/AD через RADIUS) или
> `auth = "certificate"` (клиентские сертификаты, в т.ч. на смарт-картах). Шаблон легко адаптировать.

**Маскировка (camouflage)**
```
camouflage = true
camouflage_secret = "<CAMOUFLAGE_SECRET>"
```
Без секрета в URL сервер отвечает как обычный веб-сервер (HTTP 401/404). Сканеры и активные
пробы DPI не видят VPN — только HTTPS-сайт с валидным сертификатом. Клиенты подключаются к
`https://vpn.example.com/?<секрет>`. Секрет генерируется автоматически и сохраняется в `config.env`.

**Стабильность соединения**

| Параметр | Значение | Эффект |
|---|---|---|
| `keepalive` | 30 | клиент шлёт keepalive, NAT-сессии операторов не истекают |
| `dpd` / `mobile-dpd` | 60 / 300 | обнаружение «мёртвого» канала (мобильным — реже, экономия батареи) |
| `switch-to-tcp-timeout` | 25 | UDP молчит — переход на TLS/TCP без разрыва |
| `try-mtu-discovery` | true | DTLS подбирает MTU — нет фрагментации и «чёрных дыр» |
| `mtu` | 1420 | безопасно для DTLS поверх Ethernet/PPPoE/LTE |
| `cookie-timeout` + `persistent-cookies` | 300 / true | после обрыва (смена Wi-Fi→LTE, перезапуск ocserv) клиент переподключается **без пароля и OTP** в течение 5 минут |
| `deny-roaming` | false | смена IP клиента не рвёт сессию |
| `predictable-ips` | true | клиент получает тот же адрес после переподключения |
| `server-drain-ms` | 2000 | плавное завершение при перезапуске |
| MSS clamping (nftables) | `rt mtu` | TCP внутри туннеля не упирается в MTU — сайты не «зависают» |

**Маршрутизация и DNS**
```
route = default          # весь трафик клиента — в туннель (IPv4 и IPv6)
tunnel-all-dns = true    # все DNS-запросы — только через VPN
dns = 10.88.0.1          # unbound на сервере
ipv6-network = fd88:88::/48
```
IPv6 в туннеле включён намеренно: если сервер не выдаёт клиенту IPv6, трафик к IPv6-сайтам
может уйти мимо VPN (IPv6-утечка). С NAT66 весь трафик клиента идёт через туннель.

**Масштаб:** `max-clients = 4096`, `max-same-clients = 3` (одна учётка — не более 3 устройств),
`isolate-workers = true`.

### 3.4. DNS-резолвер unbound
`/etc/unbound/unbound.conf.d/vpn.conf`: рекурсивный резолвер, отвечает **только** клиентам VPN
(`access-control`) и только через туннель (nftables). DNSSEC-валидация, QNAME-minimisation,
защита от DNS-rebinding (`private-address`), ограничение частоты запросов (`ip-ratelimit`),
кэш 768 МБ, prefetch. Число потоков подбирается по числу CPU.

Почему свой резолвер, а не 1.1.1.1/8.8.8.8: запросы клиентов не видит третья сторона, кэш
на сервере — быстрее, работает DNSSEC, нет зависимости от внешнего сервиса.

### 3.5. Запуск
```bash
systemctl daemon-reload
systemctl enable --now unbound ocserv
systemctl status ocserv
journalctl -u ocserv -f
```

## 4. Пользователи

```bash
sudo ./scripts/vpn-user.sh add ivan      # пароль + QR-код TOTP в терминале
sudo ./scripts/vpn-user.sh list          # пользователи и активные сессии
sudo ./scripts/vpn-user.sh otp ivan      # новый TOTP (утерян телефон)
sudo ./scripts/vpn-user.sh passwd ivan
sudo ./scripts/vpn-user.sh lock ivan     # блокировка + немедленное отключение
sudo ./scripts/vpn-user.sh del ivan
```
Внутри используются штатные `ocpasswd` и `occtl`. QR-код содержит `otpauth://totp/...` —
сканируется Google Authenticator, Aegis, FreeOTP, 1Password, Bitwarden и др.

Передавайте пользователю пароль и QR-код **разными каналами** (например, пароль — лично/по телефону,
QR — показать на экране при встрече или через защищённый мессенджер с самоуничтожением).

## 5. Проверка

На сервере:
```bash
sudo ./scripts/healthcheck.sh
sudo occtl show status
sudo occtl show users
openssl s_client -connect vpn.example.com:443 -tls1_3 </dev/null 2>/dev/null | grep -E 'Protocol|Cipher'
```

Снаружи:
```bash
# Без секрета — выглядит как обычный сайт:
curl -sI https://vpn.example.com/
# Внешняя оценка TLS (testssl.sh):
./testssl.sh --quiet vpn.example.com
```

С клиента Linux:
```bash
sudo openconnect --protocol=anyconnect "https://vpn.example.com/?<секрет>" -u ivan
# В выводе должно быть: "Established DTLS connection (using GnuTLS). Ciphersuite (DTLS1.2)-(ECDHE-ECDSA)-(AES-256-GCM)."
curl -4 https://ifconfig.me    # = публичный IP сервера
curl -6 https://ifconfig.me    # = IPv6 сервера (или ошибка, если у сервера нет IPv6) — но НЕ ваш домашний
```
Утечки DNS: https://dnsleaktest.com — должен быть виден только IP сервера.

## 6. Частые проблемы

| Симптом | Причина / решение |
|---|---|
| certbot: `Timeout during connect` | не открыт TCP/80 (во внешнем firewall) или A-запись указывает не туда |
| Клиент: `Failed to connect ... SSL connection failure` | проверьте URL с секретом camouflage; `journalctl -u ocserv` |
| Подключается, но нет DTLS (`DTLS handshake failed`) | UDP/443 блокируется по пути/хостером. VPN работает через TCP, но медленнее; откройте UDP/443 |
| Подключается, но сайты не открываются | `sysctl net.ipv4.ip_forward` = 1? `nft list table ip nat` — есть SNAT? верный `WAN_IF`? |
| Часть сайтов «висит» | MTU: уменьшите `VPN_MTU` до 1380/1300 и перезапустите шаг 03 |
| `TOTP неверный` | время на сервере (`chronyc tracking`) и на телефоне; код действует 30 с |
| `Your IP is banned` | `occtl show ip bans`, снять: `occtl unban ip <IP>` |
