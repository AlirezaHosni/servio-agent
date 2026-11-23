#!/usr/bin/env bash
# dns.sh: a site's DNS records in Cloudflare (item 80). Runs on YOUR LAPTOP.
#
#   bash dns.sh <host> show   <name>
#   bash dns.sh <host> set    <name> [--dns-only] [--move] [--dry-run]
#   bash dns.sh <host> remove <name> <typed-name> [--dry-run]
#
# set: an A record for the server's public IPv4 and, if the server has IPv6, an AAAA record,
#   PROXIED through Cloudflare by default (--dns-only: straight to the server). The server's
#   addresses come from the server itself (server-ip.sh). A name that already points somewhere
#   ELSE is refused unless --move: that would move a live site's visitors to this server.
#   A CNAME on the name is always refused (change it in Cloudflare yourself).
# show: the name's records, which ones point to this server, and the zone's SSL mode.
# remove: deletes the A / AAAA records that point to THIS server (others are left and listed).
#   You type the name back, as for delete-site.
#
# The Cloudflare API token is a SECRET: it never goes through the chat or Claude's environment.
# You create it yourself and put it in a file on this laptop (one line, chmod 600):
#   ~/.config/servio/cloudflare-token.txt   (or $SERVIO_CLOUDFLARE_TOKEN)
# Create it in Cloudflare: My Profile > API Tokens > Create Token > "Edit zone DNS" template,
# limited to your zones, with these permissions: Zone > DNS > Edit, Zone > Zone > Read, and
# (optional, for the SSL mode check) Zone > Zone Settings > Read.
# curl gets the token from a config on stdin (-K -), never on its command line.
#
# Proxied records and HTTPS: Cloudflare's SSL mode must be "Full (strict)" once the site has
# its certificate. "Flexible" + the site's http-to-https redirect = a redirect loop. This script
# reads the mode and warns; it never changes it (the setting is for the whole zone).
#
# Exit codes: 0 done, 1 failed, 2 wrong input, 3 not ready (no token, no permission),
# 4 refused, 5 missing tool, 6 couldn't reach Cloudflare or the server.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_FILE="${SERVIO_CLOUDFLARE_TOKEN:-$HOME/.config/servio/cloudflare-token.txt}"
API="https://api.cloudflare.com/client/v4"
HOST_RE='^[A-Za-z0-9_][A-Za-z0-9._-]{0,62}$'
NAME_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
ID_RE='^[0-9a-f]{32}$'
IPV4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
IPV6_RE='^[0-9a-f:]{3,39}$'

DRY=0 PROXIED=true MOVE=0 ARGS=()
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --dns-only) PROXIED=false ;;
        --move) MOVE=1 ;;
        *) ARGS+=("$a") ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"
host="${1:-}" action="${2:-}" name="${3:-}" typed="${4:-}"
usage() { echo "Usage: bash dns.sh <host> show|set|remove <name> [typed-name] [--dns-only] [--move] [--dry-run]" >&2; exit 2; }
[[ "$host" =~ $HOST_RE ]] && [[ "$action" =~ ^(show|set|remove)$ ]] && [[ "$name" =~ $NAME_RE ]] || usage
if [ "$action" = remove ]; then
    [ "$typed" = "$name" ] || { echo "Type the name back to remove its records: dns.sh $host remove $name $name. Nothing was changed." >&2; exit 4; }
fi

command -v curl >/dev/null 2>&1 || { echo "curl isn't installed on this laptop." >&2; exit 5; }
perl -MJSON::PP -e1 2>/dev/null || { echo "perl with JSON::PP is needed on this laptop (Git for Windows has it)." >&2; exit 5; }
[ -f "$TOKEN_FILE" ] || { echo "No Cloudflare token file at $TOKEN_FILE. Create it yourself (one line: the API token), chmod 600; don't paste the token in the chat. See the top of dns.sh for its permissions." >&2; exit 3; }
TOKEN="$(head -n 1 "$TOKEN_FILE" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
# Never print the token, not even in an error.
[[ "$TOKEN" =~ ^[A-Za-z0-9_-]{30,80}$ ]] || { echo "The first line of $TOKEN_FILE doesn't look like a Cloudflare API token. Nothing was sent." >&2; exit 3; }

pass() { echo "  PASS          $1${2:+: $2}"; }
warn() { echo "  WARN          $1${2:+: $2}"; }
na()   { echo "  NOT ASSESSED  $1${2:+: $2}"; }

# cf <method> <path> [json]: one API call; the answer lands in CF_OUT. The token goes to curl in
# a config on stdin, so it isn't on any command line.
CF_OUT=""
cf() {
    local method="$1" path="$2" data="${3:-}" extra=()
    [ -z "$data" ] || extra=(--data "$data")
    CF_OUT="$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" \
        | curl -sS --max-time 20 -K - -X "$method" -H 'Content-Type: application/json' \
            "${extra[@]+"${extra[@]}"}" "$API$path" 2>/dev/null)" \
        || { echo "Couldn't reach Cloudflare's API." >&2; exit 6; }
}
# json <perl expression on $d>: read CF_OUT (the decoded answer is $d).
json() { printf '%s' "$CF_OUT" | perl -MJSON::PP -0777 -ne 'my $d = eval { decode_json($_) } or exit 3; '"$1"; }
# cf_check: stop with Cloudflare's own error messages (they never contain the token).
cf_check() {
    local rc=0 msg
    msg="$(json 'exit 0 if $d->{success}; print join("; ", map { "$_->{code}: $_->{message}" } @{$d->{errors} || []}); exit 1')" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$rc" -eq 3 ] && { echo "Cloudflare's answer couldn't be read." >&2; exit 1; }
    echo "Cloudflare said: ${msg:-an error}" >&2
    case "$msg" in
        *9109*|*10000*|*Authentication*|*permission*|*Unauthorized*) echo "Check the token's permissions (see the top of dns.sh)." >&2; exit 3 ;;
    esac
    exit 1
}

# The server's public addresses, from the server itself.
IPV4="" IPV6=""
server_addresses() {
    local out rc=0
    out="$(bash "$SCRIPTS_DIR/run.sh" "$host" server-ip.sh)" || rc=$?
    [ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; echo "Couldn't get $host's addresses." >&2; exit "$rc"; }
    IPV4="$(printf '%s\n' "$out" | sed -n 's/^SERVIO_IPV4=//p' | head -n 1)"
    IPV6="$(printf '%s\n' "$out" | sed -n 's/^SERVIO_IPV6=//p' | head -n 1)"
    [[ "$IPV4" =~ $IPV4_RE ]] || { echo "$host didn't report a public IPv4 address." >&2; exit 1; }
    [[ "$IPV6" =~ $IPV6_RE ]] || IPV6=""
}

# The zone: the longest parent of the name that is a zone in this Cloudflare account.
ZONE_ID="" ZONE_NAME=""
find_zone() {
    local z="$name" id
    while [[ "$z" == *.* ]]; do
        cf GET "/zones?name=$z"
        cf_check
        id="$(json 'print $d->{result}[0]{id} // ""')"
        if [[ "$id" =~ $ID_RE ]]; then ZONE_ID="$id"; ZONE_NAME="$z"; return 0; fi
        z="${z#*.}"
    done
    echo "No Cloudflare zone for $name in this account (or the token can't see it)." >&2
    exit 3
}

# RECORDS: "<id> <type> <content> <proxied>" per record on the name.
RECORDS=""
read_records() {
    cf GET "/zones/$ZONE_ID/dns_records?name=$name&per_page=100"
    cf_check
    RECORDS="$(json 'for my $r (@{$d->{result}}) { print join(" ", $r->{id}, $r->{type}, lc $r->{content}, ($r->{proxied} ? "true" : "false")), "\n" }')"
    # Everything we act on later must look right.
    local id type content proxied
    while read -r id type content proxied; do
        [ -n "$id" ] || continue
        [[ "$id" =~ $ID_RE && "$type" =~ ^[A-Z]{1,10}$ ]] || { echo "Unexpected record from Cloudflare." >&2; exit 1; }
    done <<< "$RECORDS"
}
records_of() { printf '%s\n' "$RECORDS" | awk -v t="$1" '$2 == t'; }

ssl_mode() {
    cf GET "/zones/$ZONE_ID/settings/ssl"
    local mode
    mode="$(json 'print $d->{success} ? $d->{result}{value} : ""' || true)"
    case "$mode" in
        strict) pass "SSL mode of $ZONE_NAME" "Full (strict)" ;;
        full) warn "SSL mode of $ZONE_NAME" "Full: works, but Full (strict) also checks the server's certificate (set it in Cloudflare > SSL/TLS)" ;;
        flexible) warn "SSL mode of $ZONE_NAME" "Flexible: with the site's http-to-https redirect that's a REDIRECT LOOP. Set Full (strict) in Cloudflare > SSL/TLS once the certificate is issued" ;;
        off) warn "SSL mode of $ZONE_NAME" "Off: visitors get no HTTPS through Cloudflare. Set Full (strict) once the certificate is issued" ;;
        *) na "SSL mode of $ZONE_NAME" "the token can't read zone settings (optional: Zone > Zone Settings > Read)" ;;
    esac
}

show_records() {
    if [ -z "$RECORDS" ]; then echo "  (no records for $name)"; return 0; fi
    local id type content proxied mark
    while read -r id type content proxied; do
        [ -n "$id" ] || continue
        mark=""
        [ "$content" = "$IPV4" ] || [ "$content" = "$IPV6" ] && mark="  <- this server"
        echo "  $type $name -> $content (proxied: $proxied)$mark"
    done <<< "$RECORDS"
}

# PLAN: one line per change, "create|update|delete <type> <content-or-id> ..."
PLAN=()
plan_type() {
    local type="$1" want="$2" lines n id t content proxied
    lines="$(records_of "$type")"
    n="$(printf '%s' "$lines" | grep -c . || true)"
    if [ -z "$want" ]; then
        # No address of this kind on the server (no IPv6): a record pointing elsewhere would
        # send those visitors elsewhere.
        [ "$n" -eq 0 ] && return 0
        if [ "$MOVE" -eq 1 ]; then
            while read -r id t content proxied; do PLAN+=("delete $type $id $content"); done <<< "$lines"
        else
            echo "REFUSED: $name has $type record(s) ($(printf '%s\n' "$lines" | awk '{print $3}' | tr '\n' ' ')) but $host has no such address: those visitors would go elsewhere. Run again with --move to delete them, or change them in Cloudflare." >&2
            exit 4
        fi
        return 0
    fi
    if [ "$n" -eq 0 ]; then PLAN+=("create $type $want"); return 0; fi
    if [ "$n" -gt 1 ]; then
        echo "REFUSED: $name has $n $type records (set up by hand?). Change them in Cloudflare yourself." >&2
        exit 4
    fi
    read -r id t content proxied <<< "$lines"
    if [ "$content" = "$want" ]; then
        [ "$proxied" = "$PROXIED" ] || PLAN+=("update $type $id $want")
        return 0
    fi
    if [ "$MOVE" -eq 0 ]; then
        echo "REFUSED: $type $name already points to $content, not $host ($want). That may be a live site elsewhere: changing it moves its visitors to $host. If that's what you want, run again with --move." >&2
        exit 4
    fi
    PLAN+=("update $type $id $want")
}

record_json() {
    printf '{"type":"%s","name":"%s","content":"%s","ttl":1,"proxied":%s,"comment":"servio-agent: %s"}' "$1" "$name" "$2" "$PROXIED" "$host"
}

do_set() {
    if printf '%s\n' "$RECORDS" | awk '$2 == "CNAME"' | grep -q .; then
        echo "REFUSED: $name is a CNAME in Cloudflare. Remove or change it there yourself first." >&2
        exit 4
    fi
    plan_type A "$IPV4"
    plan_type AAAA "$IPV6"
    echo
    echo "==> Changes (proxied: $PROXIED)"
    if [ "${#PLAN[@]}" -eq 0 ]; then
        echo "  none: $name already points to $host"
    else
        local p
        for p in "${PLAN[@]}"; do
            set -- $p
            case "$1" in
                create) echo "  create $2 $name -> $3" ;;
                update) echo "  update $2 $name -> $4 (proxied: $PROXIED)" ;;
                delete) echo "  delete $2 $name -> $4" ;;
            esac
        done
    fi
    if [ "$DRY" -eq 1 ]; then echo; echo "==> Done (dry run): nothing was changed"; return 0; fi
    local p
    for p in "${PLAN[@]+"${PLAN[@]}"}"; do
        set -- $p
        case "$1" in
            create) cf POST "/zones/$ZONE_ID/dns_records" "$(record_json "$2" "$3")" ;;
            update) cf PATCH "/zones/$ZONE_ID/dns_records/$3" "$(record_json "$2" "$4")" ;;
            delete) cf DELETE "/zones/$ZONE_ID/dns_records/$3" ;;
        esac
        cf_check
    done
    echo
    echo "==> Checking the result"
    read_records
    local fails=0
    if records_of A | awk -v ip="$IPV4" -v p="$PROXIED" '$3 == ip && $4 == p' | grep -q .; then pass "A $name" "$IPV4"; else warn "A $name" "not as expected"; fails=1; fi
    if [ -n "$IPV6" ]; then
        if records_of AAAA | awk -v ip="$IPV6" -v p="$PROXIED" '$3 == ip && $4 == p' | grep -q .; then pass "AAAA $name" "$IPV6"; else warn "AAAA $name" "not as expected"; fails=1; fi
    fi
    [ "$PROXIED" = false ] || ssl_mode
    echo
    if [ "$PROXIED" = true ]; then
        echo "Proxied: visitors reach Cloudflare, which forwards to $host. Next: issue-certificate.sh for $name."
        echo "If its check says http://$name doesn't reach the server, Cloudflare's 'Always Use HTTPS' is"
        echo "redirecting Let's Encrypt: turn it off until the certificate exists, or use --dns-only first."
    else
        echo "DNS only: $name points straight to $host. Next: issue-certificate.sh for $name."
    fi
    [ "$fails" -eq 0 ] || exit 1
}

do_remove() {
    local id type content proxied doomed=() kept=0
    while read -r id type content proxied; do
        [ -n "$id" ] || continue
        if [[ "$type" =~ ^(A|AAAA)$ ]] && { [ "$content" = "$IPV4" ] || { [ -n "$IPV6" ] && [ "$content" = "$IPV6" ]; }; }; then
            doomed+=("$id $type $content")
        else
            kept=1
        fi
    done <<< "$RECORDS"
    echo
    echo "==> Records to delete (pointing to $host)"
    if [ "${#doomed[@]}" -eq 0 ]; then echo "  none"; else printf '  %s\n' "${doomed[@]}" | awk '{ print "  delete " $2 " '"$name"' -> " $3 }'; fi
    [ "$kept" -eq 0 ] || echo "  (other records on $name don't point to $host: left as they are)"
    if [ "$DRY" -eq 1 ]; then echo; echo "==> Done (dry run): nothing was changed"; return 0; fi
    local d
    for d in "${doomed[@]+"${doomed[@]}"}"; do
        cf DELETE "/zones/$ZONE_ID/dns_records/${d%% *}"
        cf_check
    done
    echo
    echo "==> Done: ${#doomed[@]} record(s) deleted."
}

echo "Cloudflare token: found in $TOKEN_FILE (not shown)."
server_addresses
echo "$host: IPv4 $IPV4${IPV6:+, IPv6 $IPV6}"
find_zone
echo "Zone: $ZONE_NAME"
read_records
echo
echo "==> $name now"
show_records
case "$action" in
    show) echo; echo "==> HTTPS through Cloudflare"; ssl_mode ;;
    set) do_set ;;
    remove) do_remove ;;
esac
