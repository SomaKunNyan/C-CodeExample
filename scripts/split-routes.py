#!/usr/bin/env python3
"""Превращает список доменов/сетей в строки `no-route = ...` для ocserv.

Вызывается из update-split-routes.sh. Домены разрешаются через тот же
резолвер, что и у VPN-клиентов (unbound на сервере), поэтому клиенты получают
те же адреса, что исключены из туннеля. Адреса, увиденные за последние
--keep-days дней, сохраняются в --state: CDN часто меняют IP, и без этого
исключение «мигало» бы между обновлениями.

Строки — в stdout, отчёт — в stderr.
Коды возврата: 0 — успех, 2 — превышен лимит маршрутов, 1 — прочие ошибки.
"""

import argparse
import ipaddress
import json
import os
import re
import subprocess
import sys
import tempfile
import time

DOMAIN_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$")


def warn(msg):
    print(f"[!] {msg}", file=sys.stderr)


def parse_list(path):
    """Возвращает (домены, сети). Формат: одна запись на строку, # — комментарий."""
    domains, nets = [], []
    with open(path, encoding="utf-8-sig") as f:
        for lineno, raw in enumerate(f, 1):
            entry = raw.split("#", 1)[0].strip().lower().rstrip(".")
            if not entry:
                continue
            try:
                nets.append(ipaddress.ip_network(entry, strict=False))
                continue
            except ValueError:
                pass
            if entry.startswith("*."):
                warn(f"строка {lineno}: маски не поддерживаются, беру только {entry[2:]} "
                     "(поддомены перечислите отдельно)")
                entry = entry[2:]
            entry = entry.encode("idna").decode("ascii") if not entry.isascii() else entry
            if DOMAIN_RE.match(entry):
                domains.append(entry)
            else:
                warn(f"строка {lineno}: не домен и не сеть, пропускаю: {raw.strip()!r}")
    return sorted(set(domains)), nets


def resolve(name, rtype, resolver):
    cmd = ["dig", "+short", "+time=2", "+tries=2", rtype, name]
    if resolver:
        cmd.append(f"@{resolver}")
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=15, check=False).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    ips = []
    for line in out.splitlines():
        try:
            ips.append(ipaddress.ip_address(line.strip()))
        except ValueError:
            pass  # CNAME и прочие нерелевантные строки ответа
    return ips


def load_state(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(path, state):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--resolver", default="127.0.0.1")
    ap.add_argument("--v4-prefix", type=int, default=24)
    ap.add_argument("--v6-prefix", type=int, default=48)
    ap.add_argument("--keep-days", type=float, default=7)
    ap.add_argument("--max-routes", type=int, default=200)
    ap.add_argument("--ipv6", action="store_true", help="исключать и IPv6-адреса")
    ap.add_argument("--protect", action="append", default=[],
                    help="сети, которые нельзя исключать (пул VPN и т.п.)")
    args = ap.parse_args()

    domains, nets = parse_list(args.list)
    protect = [ipaddress.ip_network(p, strict=False) for p in args.protect if p]

    now = time.time()
    ttl = args.keep_days * 86400
    old = load_state(args.state)
    state = {}
    rtypes = ["A", "AAAA"] if args.ipv6 else ["A"]

    for d in domains:
        seen = {ip: ts for ip, ts in old.get(d, {}).items() if now - ts < ttl}
        fresh = [ip for t in rtypes for ip in resolve(d, t, args.resolver)]
        if not fresh:
            warn(f"{d}: не разрешается" + (f", использую {len(seen)} адрес(ов) из кэша" if seen else ""))
        for ip in fresh:
            seen[str(ip)] = now
        state[d] = seen

    save_state(args.state, state)

    candidates = list(nets)
    for d, seen in state.items():
        for ip in map(ipaddress.ip_address, seen):
            if ip.version == 6 and not args.ipv6:
                continue
            prefix = args.v4_prefix if ip.version == 4 else args.v6_prefix
            candidates.append(ipaddress.ip_network(f"{ip}/{prefix}", strict=False))

    result = {4: [], 6: []}
    for n in candidates:
        if n.version == 6 and not args.ipv6:
            warn(f"{n}: IPv6 в туннеле выключен (VPN_NET6 пуст) — исключение не нужно, пропускаю")
            continue
        if not n.is_global:
            warn(f"{n}: не публичная сеть — пропускаю")
            continue
        if n.prefixlen == 0:
            warn(f"{n}: исключение всего интернета — пропускаю")
            continue
        if any(n.overlaps(p) for p in protect):
            warn(f"{n}: пересекается с защищённой сетью — пропускаю")
            continue
        result[n.version].append(n)

    routes = []
    for v in (4, 6):
        routes += ipaddress.collapse_addresses(result[v])

    print(f"[+] доменов: {len(domains)}, сетей из списка: {len(nets)}, маршрутов после "
          f"склейки: {len(routes)} (лимит {args.max_routes})", file=sys.stderr)
    if len(routes) > args.max_routes:
        warn("слишком много маршрутов: клиенты могут их не принять. Сократите список "
             "или уменьшите SPLIT_V4_PREFIX (например, до 22).")
        return 2

    for n in routes:
        print(f"no-route = {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
