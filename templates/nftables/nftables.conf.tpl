#!/usr/sbin/nft -f
# =============================================================================
#  nftables — межсетевой экран VPN-сервера
#  Сгенерировано scripts/02-firewall.sh из templates/nftables/nftables.conf.tpl
#  Политика: всё входящее и транзитное ЗАПРЕЩЕНО, кроме явно разрешённого.
# =============================================================================

flush ruleset

# -----------------------------------------------------------------------------
# raw: DTLS-трафик VPN (UDP/443) не отслеживаем в conntrack.
# На 40G это заметно снижает нагрузку на CPU и исключает переполнение
# таблицы conntrack «мусорными» UDP-пакетами.
# -----------------------------------------------------------------------------
table inet raw {
    chain prerouting {
        type filter hook prerouting priority raw; policy accept;
        iifname "${WAN_IF}" udp dport 443 notrack
    }
    chain output {
        type filter hook output priority raw; policy accept;
        oifname "${WAN_IF}" udp sport 443 notrack
    }
}

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

    # Сети, в которые VPN-клиентам ходить нельзя (внутренняя сеть ДЦ,
    # link-local, CGNAT, multicast и т.п.) — защита от бокового перемещения.
    set blocked_dst4 {
        type ipv4_addr
        flags interval
        elements = {
            0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8,
            169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16,
            198.18.0.0/15, 224.0.0.0/4, 240.0.0.0/4
        }
    }
    set blocked_dst6 {
        type ipv6_addr
        flags interval
        elements = { ::1/128, fc00::/7, fe80::/10, ff00::/8 }
    }

    chain input {
        type filter hook input priority filter; policy drop;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

        # --- ICMP: нужен для PMTU discovery (стабильность при MTU < 1500) ---
        ip protocol icmp icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
        ip protocol icmp icmp type echo-request limit rate 50/second burst 100 packets accept
        ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept
        ip6 nexthdr icmpv6 icmpv6 type echo-request limit rate 50/second burst 100 packets accept

        # --- VPN: TLS (TCP/443) + DTLS (UDP/443) ---
        tcp dport 443 accept
        udp dport 443 accept

        # --- HTTP/80: только для выпуска/продления сертификата Let's Encrypt ---
        tcp dport 80 accept

        # --- DNS для VPN-клиентов (локальный unbound), только из туннеля ---
        iifname "vpns*" ip saddr ${VPN_NET4} meta l4proto { tcp, udp } th dport 53 accept
${NFT_INPUT6_DNS}
        # --- SSH ---
${NFT_SSH_RULES}
        # Всё остальное — в лог (с ограничением частоты) и drop.
        limit rate 10/second burst 20 packets log prefix "nft-in-drop: " level info
        counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;

        # MSS clamping: TCP внутри туннеля не упирается в MTU — нет «зависаний»
        # сайтов из-за потерянных больших пакетов.
        tcp flags syn tcp option maxseg size set rt mtu

        ct state established,related accept
        ct state invalid drop

        # Клиенты не видят друг друга.
        iifname "vpns*" oifname "vpns*" drop
        # Антиспуфинг: из туннеля только адреса пула VPN.
        iifname "vpns*" ip saddr != ${VPN_NET4} drop
        # Нет доступа во внутренние/служебные сети.
        iifname "vpns*" ip daddr @blocked_dst4 drop
        iifname "vpns*" ip6 daddr @blocked_dst6 drop

        # Разрешаем выход клиентов в интернет.
        iifname "vpns*" oifname "${WAN_IF}" ip saddr ${VPN_NET4} accept
${NFT_FORWARD6}
        limit rate 10/second burst 20 packets log prefix "nft-fwd-drop: " level info
        counter drop
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}

# -----------------------------------------------------------------------------
# NAT: SNAT на фиксированный IP (дешевле, чем masquerade, на высоких pps).
# -----------------------------------------------------------------------------
table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "${WAN_IF}" ip saddr ${VPN_NET4} snat to ${WAN_IPV4}
    }
}
${NFT_NAT6}
