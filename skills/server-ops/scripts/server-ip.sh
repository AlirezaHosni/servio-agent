#!/usr/bin/env bash
# server-ip.sh: this server's public addresses (read-only; item 80). dns.sh on the laptop uses
# them for the A and AAAA records.
#
#   bash run.sh <host> server-ip.sh
#
# Prints SERVIO_IPV4=<address> and, when the server has a public IPv6 address,
# SERVIO_IPV6=<address>. IPv4: the first public address on a network interface; behind NAT
# (some clouds give the server only a private address) it asks Cloudflare's trace page how the
# server is seen from outside. IPv6: the first global address that isn't private (fc00::/7) or
# temporary (privacy addresses change).

IPV4_PATTERN='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
IPV6_PATTERN='^[0-9a-f:]{3,39}$'

main() {
    [ "$#" -eq 0 ] || die_input "Usage: server-ip.sh (no arguments)"
    local v4 v6
    v4="$(public_ipv4)"
    v6="$(public_ipv6)"
    [[ "$v4" =~ $IPV4_PATTERN ]] || die_state "Couldn't find this server's public IPv4 address."
    echo "Public IPv4: $v4"
    if [[ "$v6" =~ $IPV6_PATTERN ]]; then echo "Public IPv6: $v6"; else echo "Public IPv6: none"; v6=""; fi
    echo "SERVIO_IPV4=$v4"
    [ -z "$v6" ] || echo "SERVIO_IPV6=$v6"
}

# is_private_ipv4 <address>: 10/8, 172.16/12, 192.168/16, 100.64/10 (carrier NAT), 127/8, 169.254/16.
is_private_ipv4() {
    local a b
    IFS=. read -r a b _ <<< "$1"
    [ "$a" = 10 ] || [ "$a" = 127 ] || { [ "$a" = 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } \
        || { [ "$a" = 192 ] && [ "$b" = 168 ]; } || { [ "$a" = 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; } \
        || { [ "$a" = 169 ] && [ "$b" = 254 ]; }
}

public_ipv4() {
    local ip
    while read -r ip; do
        [[ "$ip" =~ $IPV4_PATTERN ]] || continue
        is_private_ipv4 "$ip" && continue
        echo "$ip"; return 0
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{ split($4, a, "/"); print a[1] }')
    # Behind NAT: how the server is seen from outside.
    ip="$(curl -4 -sS --max-time 10 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -n 1 || true)"
    [[ "$ip" =~ $IPV4_PATTERN ]] && ! is_private_ipv4 "$ip" && echo "$ip"
    return 0
}

public_ipv6() {
    ip -6 -o addr show scope global 2>/dev/null \
        | grep -vE ' (temporary|deprecated|tentative)( |$)' \
        | awk '{ split($4, a, "/"); print tolower(a[1]) }' \
        | grep -vE '^f[cd]' | head -n 1 || true
}

servio_run "$@"
