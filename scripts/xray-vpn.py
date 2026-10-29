#!/usr/bin/env python3
"""Генератор конфигураций Xray (VLESS + REALITY + XTLS Vision).

Хранилище (по умолчанию /etc/xray):
    keys.json   — ключи REALITY (privateKey, publicKey) и shortIds сервера
    users.json  — пользователи: name, id (UUID), enabled, created
    config.json — конфигурация сервера (генерируется командой `server`)

Параметры сервера берутся из переменных окружения (их экспортирует lib.sh
из config.env): XRAY_PORT, REALITY_DEST, REALITY_SERVER_NAMES, VPN_DOMAIN,
WAN_IPV4, WAN_IPV6, BLOCK_BITTORRENT, XRAY_ACCESS_LOG, XRAY_LOGLEVEL, XRAY_API_PORT,
CLIENT_FINGERPRINT, SPLIT_EXCLUDE_FILE, CLIENT_DIRECT_RU, SERVER_BLOCK_RU, PUBLIC_IPV4, LINK_ADDRESS,
XRAY_TRANSPORT (xhttp | vision), XHTTP_PATH, XHTTP_MODE,
CDN_ENABLE, CDN_DOMAIN, CDN_XRAY_PORT, CDN_PATH.

Команды:
    server                      конфиг сервера -> stdout
    users                       список пользователей (TSV: name enabled created id)
    add NAME UUID               добавить пользователя
    set NAME enabled|disabled   включить/выключить
    del NAME                    удалить
    link NAME [cdn]             ссылка vless:// для клиента (cdn — вариант через CDN)
    client-config NAME [cdn]    полный JSON-конфиг клиента Xray с исключениями
    list                        таблица: пользователи, трафик, онлайн и IP (через API Xray)
"""

import hashlib
import ipaddress
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse

STORE = os.environ.get("XRAY_STORE", "/etc/xray")
KEYS = os.path.join(STORE, "keys.json")
USERS = os.path.join(STORE, "users.json")
NAME_RE = re.compile(r"^[a-z][a-z0-9._-]{1,31}$")
# Российские сайты: база geosite и зоны .ru, .su, .рф (xn--p1ai).
RU_DOMAINS = ["geosite:category-ru", "domain:ru", "domain:su", "domain:xn--p1ai"]


def die(msg):
    print(f"[x] {msg}", file=sys.stderr)
    sys.exit(1)


def env(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and not v:
        die(f"не задан {name} (config.env)")
    return v


def load(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def save(path, data, mode=0o600):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def users():
    return load(USERS, {"users": []})["users"]


def find(name):
    for u in users():
        if u["name"] == name:
            return u
    die(f"нет пользователя {name}")


def keys():
    k = load(KEYS, None)
    if not k:
        die(f"нет {KEYS}: сначала запустите scripts/03-install-vpn.sh")
    return k


def server_names():
    names = env("REALITY_SERVER_NAMES") or env("REALITY_DEST", required=True).rsplit(":", 1)[0]
    return names.split()


def split_list():
    """Записи split-exclude.txt -> (домены, сети) для клиентской маршрутизации."""
    path = env("SPLIT_EXCLUDE_FILE", "")
    domains, nets = [], []
    if not path or not os.path.exists(path):
        return domains, nets
    with open(path, encoding="utf-8-sig") as f:
        for raw in f:
            entry = raw.split("#", 1)[0].strip().lower().rstrip(".")
            if not entry:
                continue
            try:
                nets.append(str(ipaddress.ip_network(entry, strict=False)))
                continue
            except ValueError:
                pass
            entry = entry.removeprefix("*.")
            if not entry.isascii():
                entry = entry.encode("idna").decode("ascii")
            domains.append(entry)
    return sorted(set(domains)), nets


def transport():
    t = env("XRAY_TRANSPORT", "xhttp")
    if t not in ("xhttp", "vision"):
        die(f'XRAY_TRANSPORT="{t}": допустимо "xhttp" или "vision"')
    return t


def flow():
    # XTLS Vision работает только поверх «голого» TCP (RAW) с REALITY/TLS;
    # с XHTTP сервер отвергает его ("XTLS only supports TLS and REALITY directly").
    return "xtls-rprx-vision" if transport() == "vision" else ""


def xhttp_path():
    """Путь XHTTP: из XHTTP_PATH или стабильный, выведенный из ключа сервера."""
    p = env("XHTTP_PATH", "")
    if not p:
        p = "/" + hashlib.sha256((keys()["publicKey"] + "/xhttp").encode()).hexdigest()[:16]
    return p if p.startswith("/") else "/" + p


def cdn_enabled():
    return env("CDN_ENABLE", "no") == "yes"


def cdn_path():
    """Путь XHTTP для входа через CDN (отдельный от прямого)."""
    p = env("CDN_PATH", "")
    if not p:
        p = "/" + hashlib.sha256((keys()["publicKey"] + "/cdn").encode()).hexdigest()[:16]
    return p if p.startswith("/") else "/" + p


def stream_base():
    """Транспортная часть streamSettings (без security), общая для сервера и клиента."""
    if transport() == "xhttp":
        return {"network": "xhttp", "xhttpSettings": {"path": xhttp_path(), "mode": "auto"}}
    return {"network": "raw"}


# --------------------------------------------------------------------------- #
def build_server():
    k = keys()
    port = int(env("XRAY_PORT", "443"))
    clients = [
        {"id": u["id"], "email": u["name"], "flow": flow()}
        for u in users() if u.get("enabled", True)
    ]

    # Клиентам VPN нельзя ходить на адреса самого сервера (иначе они попадут
    # на SSH/unbound в обход firewall). Частные сети Xray блокирует для VLESS
    # сам (встроенное правило freedom), здесь добавляем публичные IP сервера.
    own_ips = sorted({f"{ip}/32" for ip in (env("WAN_IPV4", ""), env("PUBLIC_IPV4", "")) if ip})
    own_ips += [f"{ip}/128" for ip in env("WAN_IPV6", "").split() if ip]
    final_rules = [{"action": "block", "network": "tcp", "port": "25"}]
    if own_ips:
        final_rules.insert(0, {"action": "block", "ip": own_ips})

    rules = []
    if env("BLOCK_BITTORRENT", "yes") == "yes":
        rules.append({"protocol": ["bittorrent"], "outboundTag": "block"})
    if env("SERVER_BLOCK_RU", "yes") == "yes":
        # Российские сайты клиент должен открывать напрямую (CLIENT_DIRECT_RU / регион
        # «Россия» в приложении). Трафик РФ -> VPS -> рунет дважды пересекает границу
        # и выдаёт прокси, поэтому сервер его не пропускает: ошибка в настройках
        # клиента проявится сразу, а не «засветит» сервер.
        rules.append({"domain": RU_DOMAINS, "outboundTag": "block"})
        rules.append({"ip": ["geoip:ru"], "outboundTag": "block"})

    target_strategy = "UseIP" if env("WAN_IPV6", "") else "UseIPv4"

    return {
        "log": {
            # debug/info — для диагностики подключений (ошибки REALITY видны только там).
            "loglevel": env("XRAY_LOGLEVEL", "warning"),
            # Журнал доступа = история посещённых сайтов. По умолчанию выключен.
            "access": "" if env("XRAY_ACCESS_LOG", "no") == "yes" else "none",
        },
        "api": {
            "tag": "api",
            "listen": f"127.0.0.1:{env('XRAY_API_PORT', '10085')}",
            "services": ["StatsService", "HandlerService", "LoggerService"],
        },
        "stats": {},
        "policy": {
            "levels": {
                "0": {
                    "handshake": 4,
                    "connIdle": 300,
                    "statsUserUplink": True,
                    "statsUserDownlink": True,
                    "statsUserOnline": True,
                }
            },
            "system": {"statsInboundUplink": True, "statsInboundDownlink": True},
        },
        # Домены, к которым обращаются клиенты, резолвит локальный unbound.
        "dns": {"servers": ["127.0.0.1"], "queryStrategy": target_strategy},
        "inbounds": [
            {
                "tag": "vless-reality",
                "port": port,
                "protocol": "vless",
                "settings": {"clients": clients, "decryption": "none"},
                "streamSettings": {
                    **stream_base(),
                    "security": "reality",
                    "realitySettings": {
                        # Подробности проверки REALITY (SNI, shortId, ключ) — в журнал;
                        # только при XRAY_LOGLEVEL=debug.
                        "show": env("XRAY_LOGLEVEL", "warning") == "debug",
                        "target": env("REALITY_DEST", required=True),
                        "xver": 0,
                        "serverNames": server_names(),
                        "privateKey": k["privateKey"],
                        "shortIds": k["shortIds"],
                    },
                    "sockopt": {"tcpFastOpen": True},
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls", "quic"],
                    "routeOnly": True,
                },
            }
        ] + ([cdn_inbound(clients)] if cdn_enabled() else []),
        "outbounds": [
            {
                "tag": "direct",
                "protocol": "freedom",
                "settings": {"finalRules": final_rules},
                # В Xray v26 стратегия разрешения имён для freedom задаётся в sockopt
                # (freedom.domainStrategy / targetStrategy устарели).
                "streamSettings": {"sockopt": {"domainStrategy": target_strategy}},
            },
            {"tag": "block", "protocol": "blackhole"},
        ],
        "routing": {"domainStrategy": "AsIs", "rules": rules},
    }


def cdn_inbound(clients):
    """Вход для трафика через CDN: Cloudflare -> 443 (REALITY не узнаёт SNI CDN-домена
    и передаёт соединение сайту-заглушке) -> nginx (TLS, CDN_DOMAIN) -> этот вход.
    Без TLS и только на 127.0.0.1: шифрование до сервера обеспечивают CDN и nginx."""
    return {
        "tag": "vless-cdn",
        "listen": "127.0.0.1",
        "port": int(env("CDN_XRAY_PORT", "10444")),
        "protocol": "vless",
        # Vision работает только поверх RAW — здесь XHTTP, поэтому flow пустой.
        "settings": {"clients": [dict(c, flow="") for c in clients], "decryption": "none"},
        "streamSettings": {
            "network": "xhttp",
            "xhttpSettings": {"path": cdn_path(), "mode": "auto"},
            "security": "none",
        },
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": True},
    }


def cdn_params(u):
    d = env("CDN_DOMAIN") or die("CDN_ENABLE=yes, но CDN_DOMAIN не задан (config.env)")
    return {"host": d, "port": 443, "id": u["id"], "sni": d,
            "fp": env("CLIENT_FINGERPRINT", "chrome")}


def client_params(u):
    k = keys()
    if env("LINK_ADDRESS", "ip") == "domain":
        host = env("VPN_DOMAIN") or die("LINK_ADDRESS=domain, но VPN_DOMAIN не задан (config.env)")
    else:
        host = env("PUBLIC_IPV4") or env("WAN_IPV4", required=True)
        if not ipaddress.ip_address(host).is_global:
            die(f"адрес сервера {host} — внутренний (VPS за NAT хостера), а публичный определить "
                "не удалось. Впишите его в config.env: PUBLIC_IPV4=\"x.x.x.x\"")
    return {
        "host": host,
        "port": int(env("XRAY_PORT", "443")),
        "id": u["id"],
        "sni": server_names()[0],
        "pbk": k["publicKey"],
        "sid": k["shortIds"][0],
        "fp": env("CLIENT_FINGERPRINT", "chrome"),
    }


def build_link(u, variant=""):
    if variant == "cdn":
        p = cdn_params(u)
        # Через CDN: обычный TLS к узлу Cloudflare (SNI = CDN-домен), XHTTP packet-up —
        # CDN пересылает отдельные HTTP-запросы и не любит длинные потоковые загрузки.
        q = urllib.parse.urlencode({
            "security": "tls", "sni": p["sni"], "fp": p["fp"], "alpn": "h2,http/1.1",
            "type": "xhttp", "host": p["host"], "path": cdn_path(), "mode": "packet-up",
        }, quote_via=urllib.parse.quote)
        tag = urllib.parse.quote(f"{u['name']}@{p['host']} (CDN)")
        return f"vless://{p['id']}@{p['host']}:{p['port']}?{q}#{tag}"
    p = client_params(u)
    host = f"[{p['host']}]" if ":" in p["host"] else p["host"]
    # "encryption" и "headerType" не указываем: по стандарту ссылок VLESS
    # по умолчанию это "none", а клиенты на sing-box (Hiddify, NekoBox, Karing)
    # переносят "encryption" в свой конфиг и падают с "unknown field".
    params = {
        "security": "reality",
        "sni": p["sni"],
        "fp": p["fp"],
        "pbk": p["pbk"],
        "sid": p["sid"],
    }
    if transport() == "xhttp":
        # Режим выбирает клиент; сервер ("auto") принимает любой.
        params.update({"type": "xhttp", "path": xhttp_path(), "mode": env("XHTTP_MODE", "auto")})
    else:
        params.update({"type": "tcp", "flow": flow()})
    q = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    tag = urllib.parse.quote(f"{u['name']}@{p['host']}")
    return f"vless://{p['id']}@{host}:{p['port']}?{q}#{tag}"


def client_stream_base():
    s = stream_base()
    if transport() == "xhttp":
        s["xhttpSettings"]["mode"] = env("XHTTP_MODE", "auto")
    return s


def build_client(u, variant=""):
    if variant == "cdn":
        c = cdn_params(u)
        proxy_stream = {
            "network": "xhttp",
            "xhttpSettings": {"host": c["host"], "path": cdn_path(), "mode": "packet-up"},
            "security": "tls",
            "tlsSettings": {"serverName": c["sni"], "fingerprint": c["fp"], "alpn": ["h2", "http/1.1"]},
        }
        p = {"host": c["host"], "port": c["port"], "id": c["id"]}
        user_flow = ""
    else:
        p = client_params(u)
        proxy_stream = {
            **client_stream_base(),
            "security": "reality",
            "realitySettings": {
                "serverName": p["sni"], "fingerprint": p["fp"],
                "publicKey": p["pbk"], "shortId": p["sid"], "spiderX": "/",
            },
        }
        user_flow = flow()
    domains, nets = split_list()
    rules = [{"ip": ["geoip:private"], "outboundTag": "direct"}]
    if domains:
        # "domain:" = домен и все его поддомены.
        rules.append({"domain": [f"domain:{d}" for d in domains], "outboundTag": "direct"})
    if nets:
        rules.append({"ip": nets, "outboundTag": "direct"})
    if env("CLIENT_DIRECT_RU", "yes") == "yes":
        rules.append({"domain": RU_DOMAINS, "outboundTag": "direct"})
        rules.append({"ip": ["geoip:ru"], "outboundTag": "direct"})

    return {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {"tag": "socks", "listen": "127.0.0.1", "port": 10808, "protocol": "socks",
             "settings": {"udp": True},
             "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": True}},
            {"tag": "http", "listen": "127.0.0.1", "port": 10809, "protocol": "http",
             "sniffing": {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": True}},
        ],
        "outbounds": [
            {
                "tag": "proxy",
                "protocol": "vless",
                "settings": {"vnext": [{
                    "address": p["host"], "port": p["port"],
                    "users": [{"id": p["id"], "encryption": "none", "flow": user_flow}],
                }]},
                "streamSettings": proxy_stream,
            },
            {"tag": "direct", "protocol": "freedom"},
            {"tag": "block", "protocol": "blackhole"},
        ],
        "routing": {"domainStrategy": "IPIfNonMatch", "rules": rules},
    }


def xray_api(*args):
    """Вызов `xray api ...`; при ошибке (Xray не запущен) — пустой dict."""
    cmd = [env("XRAY_BIN", "/usr/local/bin/xray"), "api", *args,
           f"--server=127.0.0.1:{env('XRAY_API_PORT', '10085')}"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=10, check=True).stdout
        return json.loads(out or "{}")
    except (OSError, subprocess.SubprocessError, ValueError):
        return {}


def human(n):
    n = float(n)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024


def print_table():
    stats = {s["name"]: int(s.get("value", 0)) for s in xray_api("statsquery", "-pattern", "user>>>").get("stat", [])}
    online = set(xray_api("statsgetallonlineusers").get("users", []))
    rows = [("ПОЛЬЗОВАТЕЛЬ", "АКТИВЕН", "СОЗДАН", "СКАЧАНО", "ОТПРАВЛЕНО", "ОНЛАЙН (IP)")]
    for u in users():
        n = u["name"]
        ips = "-"
        if f"user>>>{n}>>>online" in online:
            found = sorted(xray_api("statsonlineiplist", "-email", n).get("ips", {}))
            ips = "да" + (f" ({', '.join(found)})" if found else "")
        rows.append((
            n,
            "да" if u.get("enabled", True) else "нет",
            time.strftime("%Y-%m-%d", time.localtime(u.get("created", 0))),
            human(stats.get(f"user>>>{n}>>>traffic>>>downlink", 0)),
            human(stats.get(f"user>>>{n}>>>traffic>>>uplink", 0)),
            ips,
        ))
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    for r in rows:
        print("  ".join(c.ljust(w) for c, w in zip(r, widths)).rstrip())
    print("\nТрафик — с момента последнего перезапуска Xray.")


# --------------------------------------------------------------------------- #
def main(argv):
    if not argv:
        print(__doc__)
        return 1
    cmd, args = argv[0], argv[1:]
    if cmd == "server":
        print(json.dumps(build_server(), indent=2, ensure_ascii=False))
    elif cmd == "users":
        for u in users():
            created = time.strftime("%Y-%m-%d", time.localtime(u.get("created", 0)))
            print(f"{u['name']}\t{'yes' if u.get('enabled', True) else 'no'}\t{created}\t{u['id']}")
    elif cmd == "add":
        name, uid = args
        if not NAME_RE.match(name):
            die("имя: латиница в нижнем регистре, цифры . _ - (2–32 символа)")
        data = load(USERS, {"users": []})
        if any(u["name"] == name for u in data["users"]):
            die(f"пользователь {name} уже существует")
        data["users"].append({"name": name, "id": uid, "enabled": True, "created": int(time.time())})
        save(USERS, data)
    elif cmd == "set":
        name, state = args
        data = load(USERS, {"users": []})
        for u in data["users"]:
            if u["name"] == name:
                u["enabled"] = state == "enabled"
                save(USERS, data)
                break
        else:
            die(f"нет пользователя {name}")
    elif cmd == "del":
        name = args[0]
        data = load(USERS, {"users": []})
        before = len(data["users"])
        data["users"] = [u for u in data["users"] if u["name"] != name]
        if len(data["users"]) == before:
            die(f"нет пользователя {name}")
        save(USERS, data)
    elif cmd == "link":
        print(build_link(find(args[0]), args[1] if len(args) > 1 else ""))
    elif cmd == "cdn-path":
        print(cdn_path())
    elif cmd == "list":
        print_table()
    elif cmd == "client-config":
        print(json.dumps(build_client(find(args[0]), args[1] if len(args) > 1 else ""),
                         indent=2, ensure_ascii=False))
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
