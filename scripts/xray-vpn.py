#!/usr/bin/env python3
"""Генератор конфигураций Xray (VLESS + REALITY + XTLS Vision).

Хранилище (по умолчанию /etc/xray):
    keys.json   — ключи REALITY (privateKey, publicKey) и shortIds сервера
    users.json  — пользователи: name, id (UUID), enabled, created
    config.json — конфигурация сервера (генерируется командой `server`)

Параметры сервера берутся из переменных окружения (их экспортирует lib.sh
из config.env): XRAY_PORT, REALITY_DEST, REALITY_SERVER_NAMES, VPN_DOMAIN,
WAN_IPV4, WAN_IPV6, BLOCK_BITTORRENT, XRAY_ACCESS_LOG, XRAY_API_PORT,
CLIENT_FINGERPRINT, SPLIT_EXCLUDE_FILE, CLIENT_DIRECT_RU.

Команды:
    server                      конфиг сервера -> stdout
    users                       список пользователей (TSV: name enabled created id)
    add NAME UUID               добавить пользователя
    set NAME enabled|disabled   включить/выключить
    del NAME                    удалить
    link NAME                   ссылка vless:// для клиента
    client-config NAME          полный JSON-конфиг клиента Xray с исключениями
    list                        таблица: пользователи, трафик, онлайн и IP (через API Xray)
"""

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


# --------------------------------------------------------------------------- #
def build_server():
    k = keys()
    port = int(env("XRAY_PORT", "443"))
    clients = [
        {"id": u["id"], "email": u["name"], "flow": "xtls-rprx-vision"}
        for u in users() if u.get("enabled", True)
    ]

    # Клиентам VPN нельзя ходить на адреса самого сервера (иначе они попадут
    # на SSH/unbound в обход firewall). Частные сети Xray блокирует для VLESS
    # сам (встроенное правило freedom), здесь добавляем публичные IP сервера.
    own_ips = [f"{ip}/32" for ip in env("WAN_IPV4", "").split() if ip]
    own_ips += [f"{ip}/128" for ip in env("WAN_IPV6", "").split() if ip]
    final_rules = [{"action": "block", "network": "tcp", "port": "25"}]
    if own_ips:
        final_rules.insert(0, {"action": "block", "ip": own_ips})

    rules = []
    if env("BLOCK_BITTORRENT", "yes") == "yes":
        rules.append({"protocol": ["bittorrent"], "outboundTag": "block"})

    target_strategy = "UseIP" if env("WAN_IPV6", "") else "UseIPv4"

    return {
        "log": {
            "loglevel": "warning",
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
                    "network": "raw",
                    "security": "reality",
                    "realitySettings": {
                        "show": False,
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
        ],
        "outbounds": [
            {
                "tag": "direct",
                "protocol": "freedom",
                "settings": {"targetStrategy": target_strategy, "finalRules": final_rules},
            },
            {"tag": "block", "protocol": "blackhole"},
        ],
        "routing": {"domainStrategy": "AsIs", "rules": rules},
    }


def client_params(u):
    k = keys()
    host = env("VPN_DOMAIN") or env("WAN_IPV4", required=True)
    return {
        "host": host,
        "port": int(env("XRAY_PORT", "443")),
        "id": u["id"],
        "sni": server_names()[0],
        "pbk": k["publicKey"],
        "sid": k["shortIds"][0],
        "fp": env("CLIENT_FINGERPRINT", "chrome"),
    }


def build_link(u):
    p = client_params(u)
    host = f"[{p['host']}]" if ":" in p["host"] else p["host"]
    q = urllib.parse.urlencode({
        "encryption": "none",
        "flow": "xtls-rprx-vision",
        "security": "reality",
        "sni": p["sni"],
        "fp": p["fp"],
        "pbk": p["pbk"],
        "sid": p["sid"],
        "type": "tcp",
        "headerType": "none",
    })
    tag = urllib.parse.quote(f"{u['name']}@{p['host']}")
    return f"vless://{p['id']}@{host}:{p['port']}?{q}#{tag}"


def build_client(u):
    p = client_params(u)
    domains, nets = split_list()
    rules = [{"ip": ["geoip:private"], "outboundTag": "direct"}]
    if domains:
        # "domain:" = домен и все его поддомены.
        rules.append({"domain": [f"domain:{d}" for d in domains], "outboundTag": "direct"})
    if nets:
        rules.append({"ip": nets, "outboundTag": "direct"})
    if env("CLIENT_DIRECT_RU", "no") == "yes":
        rules.append({"domain": ["geosite:category-ru", "domain:ru", "domain:xn--p1ai"],
                      "outboundTag": "direct"})
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
                    "users": [{"id": p["id"], "encryption": "none", "flow": "xtls-rprx-vision"}],
                }]},
                "streamSettings": {
                    "network": "raw",
                    "security": "reality",
                    "realitySettings": {
                        "serverName": p["sni"], "fingerprint": p["fp"],
                        "publicKey": p["pbk"], "shortId": p["sid"], "spiderX": "/",
                    },
                },
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
        print(build_link(find(args[0])))
    elif cmd == "list":
        print_table()
    elif cmd == "client-config":
        print(json.dumps(build_client(find(args[0])), indent=2, ensure_ascii=False))
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
