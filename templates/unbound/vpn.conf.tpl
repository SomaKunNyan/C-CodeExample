# /etc/unbound/unbound.conf.d/vpn.conf
# Локальный рекурсивный DNS-резолвер для Xray: домены, к которым обращаются
# клиенты VPN, разрешаются на сервере без сторонних DNS-сервисов, с DNSSEC.
# Слушает только localhost — снаружи недоступен.
server:
    interface: 127.0.0.1
    interface: ::1
    port: 53
    access-control: 0.0.0.0/0 refuse
    access-control: ::0/0 refuse
    access-control: 127.0.0.0/8 allow
    access-control: ::1/128 allow

    # Производительность.
    num-threads: ${UNBOUND_THREADS}
    so-reuseport: yes
    msg-cache-slabs: ${UNBOUND_SLABS}
    rrset-cache-slabs: ${UNBOUND_SLABS}
    infra-cache-slabs: ${UNBOUND_SLABS}
    key-cache-slabs: ${UNBOUND_SLABS}
    msg-cache-size: 128m
    rrset-cache-size: 256m
    outgoing-range: 8192
    num-queries-per-thread: 4096
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
    harden-algo-downgrade: yes
    use-caps-for-id: no
    val-clean-additional: yes
    minimal-responses: yes

    verbosity: 1
