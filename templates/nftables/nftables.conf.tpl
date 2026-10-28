#!/usr/sbin/nft -f
# =============================================================================
#  nftables — межсетевой экран VPN-сервера (Xray VLESS + REALITY)
#  Сгенерировано scripts/02-firewall.sh из templates/nftables/nftables.conf.tpl
#  Политика: всё входящее и транзитное ЗАПРЕЩЕНО, кроме явно разрешённого.
#
#  Xray — прокси: трафик клиентов он сам открывает к сайтам с адреса сервера,
#  поэтому маршрутизация (forward) и NAT не нужны и полностью запрещены.
# =============================================================================

flush ruleset

table inet filter {

    # Динамический набор для ограничения частоты новых SSH-подключений.
    set ssh_meter4 {
        type ipv4_addr
        size 65535
        flags dynamic, timeout
        timeout 1m
    }
    set ssh_meter6 {
        type ipv6_addr
        size 65535
        flags dynamic, timeout
        timeout 1m
    }

    chain input {
        type filter hook input priority filter; policy drop;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

        # --- ICMP: нужен для PMTU discovery (без него «зависают» соединения) ---
        ip protocol icmp icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
        ip protocol icmp icmp type echo-request limit rate 50/second burst 100 packets accept
        ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept
        ip6 nexthdr icmpv6 icmpv6 type echo-request limit rate 50/second burst 100 packets accept

        # --- VPN: Xray VLESS + REALITY (TLS 1.3 поверх TCP) ---
        tcp dport ${XRAY_PORT} accept

        # --- SSH ---
${NFT_SSH_RULES}
        # Всё остальное — в лог (с ограничением частоты) и drop.
        limit rate 10/second burst 20 packets log prefix "nft-in-drop: " level info
        counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
