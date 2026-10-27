# 04. Подключение клиентов

Пользователь получает от администратора:
* **адрес:** `https://vpn.example.com/?<CAMOUFLAGE_SECRET>` (адрес вместе с секретом);
* **логин и пароль;**
* **QR-код TOTP** — отсканировать в Google Authenticator / Aegis / FreeOTP / Bitwarden.

При подключении вводятся пароль, затем — 6-значный код из приложения.

> Если какой-то клиент не принимает адрес с `/?секрет`, используйте клиент на базе OpenConnect
> (поддерживает camouflage полностью) или отключите маскировку на сервере
> (`camouflage = false`) — шифрование и безопасность от этого не меняются, только скрытность.

## Linux

**NetworkManager (графически):**
```bash
sudo apt install network-manager-openconnect-gnome     # GNOME; для KDE: plasma-nm уже умеет
```
Настройки → Сеть → VPN → «+» → *Multi-protocol VPN client (openconnect)* → протокол
*Cisco AnyConnect or openconnect* → шлюз `https://vpn.example.com/?<секрет>`.

**Командная строка:**
```bash
sudo apt install openconnect
sudo openconnect --protocol=anyconnect -u ivan "https://vpn.example.com/?<секрет>"
```
Фоновый режим: добавьте `-b`, отключение — `sudo pkill -SIGINT openconnect`.

## Windows

* **OpenConnect-GUI** (https://gui.openconnect-vpn.net/) — открытый клиент. New profile →
  Gateway: `https://vpn.example.com/?<секрет>` → Connect.
* **Cisco Secure Client (AnyConnect)** — если уже используется в организации. Адрес:
  `vpn.example.com/?<секрет>`.

## macOS

* **OpenConnect-GUI** или `brew install openconnect` + `sudo openconnect ...` как в Linux.
* **Cisco Secure Client**.

## Android

* **Cisco Secure Client** (Google Play) или открытый **OpenConnect** (F-Droid,
  «OpenConnect for Android» / ics-openconnect). Новое подключение → адрес сервера с секретом.

## iOS / iPadOS

* **Cisco Secure Client** (App Store). Connections → Add VPN Connection → Server Address:
  `vpn.example.com/?<секрет>`.

## Проверка на клиенте

1. https://ifconfig.me — показывает IP сервера.
2. https://dnsleaktest.com (Extended test) — только IP сервера / ДЦ.
3. https://test-ipv6.com — нет вашего домашнего IPv6.
4. Linux: `openconnect` пишет в лог `Established DTLS connection ... AES-256-GCM` — работает
   быстрый канал. Если такой строки нет — UDP/443 блокируется по пути, работает резервный TLS-канал.

## Рекомендации пользователям

* Устанавливайте клиенты только из официальных источников.
* Не передавайте пароль и коды TOTP никому, включая «администраторов» в мессенджерах.
* Потерян телефон с TOTP — сообщите администратору: `vpn-user.sh otp <user>` выдаст новый ключ,
  старый перестанет работать.
