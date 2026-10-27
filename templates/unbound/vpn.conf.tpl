# /etc/unbound/unbound.conf.d/vpn.conf
# Рекурсивный DNS-резолвер только для VPN-клиентов: DNS-запросы не уходят
# к провайдеру клиента (нет DNS-утечек), DNSSEC-валидация включена.
server:
    interface: 0.0.0.0
    interface: ::0
    # Туннельные интерфейсы vpnsN появляются динамически — отвечаем с того
    # адреса, на который пришёл запрос.
    interface-automatic: yes
    port: 53

    access-control: 0.0.0.0/0 refuse
    access-control: ::0/0 refuse
    access-control: 127.0.0.0/8 allow
    access-control: ::1/128 allow
    access-control: ${VPN_NET4} allow
${UNBOUND_ACL6}

    # Производительность (масштаб — тысячи клиентов).
    num-threads: ${UNBOUND_THREADS}
    so-reuseport: yes
    msg-cache-slabs: ${UNBOUND_SLABS}
    rrset-cache-slabs: ${UNBOUND_SLABS}
    infra-cache-slabs: ${UNBOUND_SLABS}
    key-cache-slabs: ${UNBOUND_SLABS}
    msg-cache-size: 256m
    rrset-cache-size: 512m
    outgoing-range: 8192
    num-queries-per-thread: 4096
    so-rcvbuf: 8m
    so-sndbuf: 8m
    prefetch: yes
    prefetch-key: yes
    serve-expired: yes
    serve-expired-ttl: 3600

    # Приватность и защита.
    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes
    aggressive-nsec: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-below-nxdomain: yes
    harden-referral-path: no
    harden-algo-downgrade: yes
    use-caps-for-id: no
    val-clean-additional: yes
    deny-any: yes
    minimal-responses: yes
    # Защита от DNS-rebinding: публичные имена не могут указывать на частные адреса.
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: 100.64.0.0/10
    private-address: fd00::/8
    private-address: fe80::/10
    # Ограничение частоты запросов с одного клиента (защита от злоупотреблений).
    ip-ratelimit: 500

    verbosity: 1
    log-servfail: yes
