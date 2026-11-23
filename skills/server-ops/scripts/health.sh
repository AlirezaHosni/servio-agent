#!/usr/bin/env bash
# health.sh: is this server (and one site) healthy, and if not, why? READ-ONLY: changes nothing.
#
#   bash run.sh <host> health.sh               # the server: load, memory, disk, inodes, failed
#                                              # services, OOM kills, firewall and open ports
#   bash run.sh <host> health.sh <domain>      # the same, plus "why is my site down?" for one site
#
# Items 4 (server health), 10 (firewall status) and 57 (why is my site down). Every check is
# PASS / WARN / FAIL / NOT ASSESSED (lib.sh), then "Likely cause" names the runbook to follow
# (runbooks/ in the plugin) when the signs match a known problem: 502, disk full, out of memory,
# high load.
#
# Exit 0 when the report ran, even if it found problems: finding them is the point. Problems are
# in the report, not in the exit code (a FAIL here is not "the script failed").
#
# Never reads .env or keys. Log lines it prints (nginx error log) go through the server-side
# masking like all output; only counts are taken from access logs.

# Where things are read from. Variables so tests can point them at fake files.
PROC_DIR="/proc"
NGINX_LOG_DIR="/var/log/nginx"
PHP_LOG_DIR="/var/log"

# What the checks found, for diagnose(). 1 = seen.
DIAG_DISK=0 DIAG_INODES=0 DIAG_OOM=0 DIAG_MEMORY=0 DIAG_LOAD=0
DIAG_POOL_DOWN=0 DIAG_MAX_CHILDREN=0 DIAG_SITE_STATUS="" DIAG_FAILED_SERVICES=0

main() {
    local domain="${1:-}"
    [ -z "$domain" ] || validate_domain "$domain"
    require_root

    step "Server health"
    check_load "$PROC_DIR/loadavg" "$(nproc 2>/dev/null || echo 1)"
    check_memory "$PROC_DIR/meminfo"
    check_disks
    check_failed_services
    check_oom_kills
    top_memory

    step "Firewall and open ports"
    firewall_report

    if [ -n "$domain" ]; then
        step "Site $domain"
        site_checks "$domain"
    fi

    step "Summary"
    check_summary || true
    diagnose
}

# ---------------------------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------------------------

# check_load <loadavg file> <cpus>. The 5-minute load against the number of CPUs: load = how many
# processes want a CPU at once, so 4.0 on 4 CPUs is "fully busy", 8.0 is "twice too much".
check_load() {
    local file="$1" cpus="$2" l1 l5 l15
    if [ ! -r "$file" ]; then check_na "load" "can't read $file"; return; fi
    read -r l1 l5 l15 _ < "$file"
    [[ "$cpus" =~ ^[0-9]+$ && "$cpus" -gt 0 ]] || cpus=1
    if awk -v l="$l5" -v c="$cpus" 'BEGIN { exit !(l > 2 * c) }'; then
        DIAG_LOAD=1; check_fail "load" "$l1 $l5 $l15 on $cpus CPUs (more than twice what the CPUs can do)"
    elif awk -v l="$l5" -v c="$cpus" 'BEGIN { exit !(l > c) }'; then
        DIAG_LOAD=1; check_warn "load" "$l1 $l5 $l15 on $cpus CPUs (busier than the CPUs can keep up with)"
    else
        check_pass "load" "$l1 $l5 $l15 on $cpus CPUs"
    fi
}

# check_memory <meminfo file>. MemAvailable, not MemFree: Linux uses free memory as file cache,
# so "free" is always low; "available" is what programs can still get.
check_memory() {
    local file="$1" total avail swap_total swap_free pct swap_used
    if [ ! -r "$file" ]; then check_na "memory" "can't read $file"; return; fi
    total="$(awk '/^MemTotal:/ {print $2}' "$file")"
    avail="$(awk '/^MemAvailable:/ {print $2}' "$file")"
    swap_total="$(awk '/^SwapTotal:/ {print $2}' "$file")"
    swap_free="$(awk '/^SwapFree:/ {print $2}' "$file")"
    if ! [[ "$total" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ && "$total" -gt 0 ]]; then
        check_na "memory" "unexpected $file"; return
    fi
    pct=$((avail * 100 / total))
    swap_used=$(( (${swap_total:-0} - ${swap_free:-0}) / 1024 ))
    local detail="$((avail / 1024)) MB available of $((total / 1024)) MB ($pct%), swap used ${swap_used} MB"
    if [ "$pct" -lt 5 ]; then DIAG_MEMORY=1; check_fail "memory" "$detail"
    elif [ "$pct" -lt 15 ]; then DIAG_MEMORY=1; check_warn "memory" "$detail"
    else check_pass "memory" "$detail"; fi
}

# check_usage <what> <df -P style output>: one line per filesystem, "<use%> <mount>".
# 85% is a warning, 95% a failure (MySQL, logs and uploads stop working before 100%).
check_usage() {
    local what="$1" pct mount any=0
    while read -r pct mount; do
        pct="${pct%\%}"
        [[ "$pct" =~ ^[0-9]+$ ]] || continue
        [[ "$mount" =~ ^/[A-Za-z0-9._/-]{0,100}$ ]] || mount="(a mount with an unusual name)"
        any=1
        if [ "$pct" -ge 95 ]; then
            [ "$what" = "inodes" ] && DIAG_INODES=1 || DIAG_DISK=1
            check_fail "$what $mount" "$pct% used"
        elif [ "$pct" -ge 85 ]; then
            check_warn "$what $mount" "$pct% used"
        else
            check_pass "$what $mount" "$pct% used"
        fi
    done
    [ "$any" -eq 1 ] || check_na "$what" "no filesystem found"
}

# Disk space AND inodes: a disk can be "full" with gigabytes free when millions of small files
# (sessions, cache) used up every inode. Real disks only (no tmpfs, snaps, containers).
check_disks() {
    local skip=(-x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs)
    # < <(...), not a pipe: a function at the end of a pipe runs in a subshell, and the counts
    # and DIAG_* it sets would be lost.
    check_usage "disk" < <(df -P "${skip[@]}" 2>/dev/null | awk 'NR > 1 {print $5, $6}' || true)
    # A file system without inodes (btrfs) shows "-": skipped by check_usage.
    check_usage "inodes" < <(df -Pi "${skip[@]}" 2>/dev/null | awk 'NR > 1 {print $5, $6}' || true)
}

check_failed_services() {
    local failed
    if ! command -v systemctl >/dev/null 2>&1; then check_na "services" "no systemctl"; return; fi
    failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' \
        | grep -E '^[A-Za-z0-9@._:-]{1,100}$' | tr '\n' ' ' || true)"
    if [ -n "$failed" ]; then
        DIAG_FAILED_SERVICES=1; check_fail "services" "failed: ${failed% }"
    else
        check_pass "services" "none failed"
    fi
}

# The kernel kills a process when memory runs out (the "OOM killer"). PHP-FPM workers and MySQL
# are the usual victims, and a killed PHP-FPM is a 502 for its sites.
check_oom_kills() {
    local log
    if command -v journalctl >/dev/null 2>&1; then
        log="$(journalctl -k --since "24 hours ago" --no-pager -q 2>/dev/null || true)"
    else
        log="$(dmesg 2>/dev/null || true)"
    fi
    count_oom_kills "$log"
}

# count_oom_kills <kernel log text>: separate so tests can feed a sample.
count_oom_kills() {
    local names count
    count="$(printf '%s\n' "$1" | grep -cE 'Killed process [0-9]+' || true)"
    if [ "${count:-0}" -gt 0 ]; then
        names="$(printf '%s\n' "$1" | grep -oE 'Killed process [0-9]+ \([A-Za-z0-9._:-]{1,30}\)' \
            | sed -E 's/.*\((.*)\)/\1/' | sort | uniq -c | awk '{print $2 " x" $1}' | tr '\n' ' ')"
        DIAG_OOM=1
        check_fail "out of memory" "the kernel killed $count process(es) in the last 24 h: ${names% }"
    else
        check_pass "out of memory" "no processes killed in the last 24 h"
    fi
}

# The 5 programs using the most memory (names only, never their command lines: those can hold
# passwords).
top_memory() {
    echo "  Most memory used by:"
    ps -eo rss=,comm= --sort=-rss 2>/dev/null | head -n 5 | while read -r rss comm; do
        [[ "$comm" =~ ^[A-Za-z0-9._:/@-]{1,30}$ ]] || comm="(unusual name)"
        printf '    %6s MB  %s\n' "$((rss / 1024))" "$comm"
    done || true
}

# ---------------------------------------------------------------------------------------------
# Firewall (item 10): the rules UFW has, and the ports something is really listening on. The two
# can differ: a port can be open in UFW with nothing behind it, or (worse) a program can listen
# on all interfaces while the firewall is off.
# ---------------------------------------------------------------------------------------------
firewall_report() {
    if command -v ufw >/dev/null 2>&1; then
        local status
        status="$(ufw status verbose 2>/dev/null || true)"
        if printf '%s\n' "$status" | grep -q '^Status: active'; then
            check_pass "firewall" "UFW active"
        else
            check_warn "firewall" "UFW installed but not active"
        fi
        printf '%s\n' "$status" | grep -E '^(Default:|[0-9A-Za-z/ ,()]+ +(ALLOW|DENY|LIMIT|REJECT))' \
            | sed 's/^/    /' | head -n 40 || true
    else
        check_na "firewall" "ufw not installed"
    fi

    echo "  Listening ports (address:port  program):"
    if command -v ss >/dev/null 2>&1; then
        ss -Hltnup 2>/dev/null | listening_ports || true
    else
        echo "    (ss not available)"
    fi
}

# listening_ports: reads `ss -Hltnup` output, prints "proto  address:port  program  scope".
# "everyone" = listening on all interfaces (0.0.0.0, [::], *), reachable from the internet unless
# the firewall blocks it; "this server" = 127.0.0.1 / ::1 only.
ADDR_PATTERN='^[][0-9A-Fa-f.:*%a-z]{1,60}$'
listening_ports() {
    local proto state recvq sendq local_addr peer users prog scope
    while read -r proto state recvq sendq local_addr peer users; do
        prog="$(printf '%s' "$users" | grep -oE '\(\("[A-Za-z0-9._:-]{1,30}"' | head -n 1 | tr -d '("' || true)"
        [ -n "$prog" ] || prog="?"
        case "$local_addr" in
            127.*|\[::1\]:*|::1:*) scope="this server" ;;
            0.0.0.0:*|\*:*|\[::\]:*|:::*) scope="everyone" ;;
            *) scope="one address" ;;
        esac
        [[ "$local_addr" =~ $ADDR_PATTERN ]] || local_addr="(unusual)"
        printf '    %-4s %-28s %-16s %s\n' "$proto" "$local_addr" "$prog" "$scope"
    done | sort -u
}

# ---------------------------------------------------------------------------------------------
# One site (item 57)
# ---------------------------------------------------------------------------------------------
site_checks() {
    local domain="$1" file php user scheme cert
    file="$(nginx_enabled "$domain")"
    [ -e "$file" ] || die_state "$domain isn't enabled in nginx on this server (inventory lists the sites)."
    user="$(site_user "$domain")"
    php="$(grep -oE 'unix:/run/php/php[0-9]+\.[0-9]+-fpm(-[a-z0-9_]+)?\.sock' "$file" | head -n 1 \
        | sed -E 's#.*/php([0-9]+\.[0-9]+)-fpm.*#\1#' || true)"

    # What a visitor gets.
    scheme="http"; cert="$(certificate_path "$domain")"
    [ -f "$cert" ] && grep -q "listen 443" "$file" && scheme="https"
    site_status "$domain" "$scheme"
    DIAG_SITE_STATUS="$SITE_STATUS"
    case "$SITE_STATUS" in
        2??|3??) check_pass "site answers" "$scheme $SITE_STATUS" ;;
        4??)     check_warn "site answers" "$scheme $SITE_STATUS (the home page is missing or forbidden)" ;;
        000)     check_fail "site answers" "no answer over $scheme (nginx down, or a certificate problem)" ;;
        *)       check_fail "site answers" "$scheme $SITE_STATUS" ;;
    esac

    # nginx itself.
    if systemctl is-active --quiet nginx 2>/dev/null; then check_pass "nginx" "running"
    else check_fail "nginx" "not running"; fi

    # The site's PHP pool: the FPM service for its version, and its own socket.
    if [ -z "$php" ]; then
        check_na "php" "no PHP socket in the nginx config (a static site?)"
    else
        if systemctl is-active --quiet "php$php-fpm" 2>/dev/null; then check_pass "php$php-fpm" "running"
        else DIAG_POOL_DOWN=1; check_fail "php$php-fpm" "not running"; fi
        if [ -S "$(pool_socket "$domain" "$php")" ]; then check_pass "site's PHP pool" "socket is there"
        elif [ -f "$(pool_file "$domain" "$php")" ]; then DIAG_POOL_DOWN=1; check_fail "site's PHP pool" "configured, but no socket (the pool isn't running)"
        else check_na "site's PHP pool" "no pool of its own (a hand-made config?)"; fi
        count_max_children "$PHP_LOG_DIR/php$php-fpm.log" "$user"
    fi

    count_5xx "$NGINX_LOG_DIR/$domain-access.log"
    recent_errors "$NGINX_LOG_DIR/$domain-error.log"
}

# count_max_children <fpm log> <pool>. "server reached pm.max_children setting" = every PHP
# worker of the pool was busy and requests had to wait (slow pages, then 502/504).
count_max_children() {
    local log="$1" pool="$2" count last
    if [ ! -r "$log" ]; then check_na "PHP workers busy" "no $log"; return; fi
    count="$(grep -cF "[pool $pool] server reached pm.max_children" "$log" || true)"
    if [ "${count:-0}" -gt 0 ]; then
        last="$(grep -F "[pool $pool] server reached pm.max_children" "$log" | tail -n 1 \
            | grep -oE '^\[[0-9A-Za-z: -]{1,30}\]' || true)"
        DIAG_MAX_CHILDREN=1
        check_warn "PHP workers busy" "all workers were busy $count time(s) (last ${last:-unknown}); see PHP-FPM sizing"
    else
        check_pass "PHP workers busy" "never all busy (in the current log)"
    fi
}

# count_5xx <access log>: the last 5000 requests, server errors by code. Only counts: request
# lines can hold tokens in query strings.
count_5xx() {
    local log="$1" summary total
    if [ ! -r "$log" ]; then check_na "server errors (5xx)" "no $log"; return; fi
    # Default "combined" format: the status is field 9.
    summary="$(tail -n 5000 "$log" | awk '$9 ~ /^5[0-9][0-9]$/ { n[$9]++; t++ } END { for (c in n) printf "%s x%d ", c, n[c]; if (t) printf "(total %d)", t }')"
    total="$(tail -n 5000 "$log" | wc -l | tr -d ' ')"
    if [ -n "$summary" ]; then
        check_warn "server errors (5xx)" "$summary in the last $total requests"
    else
        check_pass "server errors (5xx)" "none in the last $total requests"
    fi
}

# recent_errors <error log>: the last 5 lines, cut to 300 characters (masked like all output).
recent_errors() {
    local log="$1"
    [ -r "$log" ] || return 0
    [ -s "$log" ] || return 0
    echo "  Last nginx errors for this site:"
    tail -n 5 "$log" | cut -c1-300 | sed 's/^/    /'
}

# ---------------------------------------------------------------------------------------------
# What the signs point to. Order matters: the root cause first (a full disk or no memory causes
# the 502, not the other way round).
# ---------------------------------------------------------------------------------------------
diagnose() {
    local found=0
    echo
    echo "Likely cause:"
    if [ "$DIAG_DISK" -eq 1 ] || [ "$DIAG_INODES" -eq 1 ]; then
        found=1; echo "  - Disk full$([ "$DIAG_INODES" -eq 1 ] && echo ' (inodes: too many small files)'). Runbook: runbooks/disk-full.md"
    fi
    if [ "$DIAG_OOM" -eq 1 ] || [ "$DIAG_MEMORY" -eq 1 ]; then
        found=1; echo "  - Out of memory$([ "$DIAG_OOM" -eq 1 ] && echo ': the kernel killed processes'). Runbook: runbooks/out-of-memory.md"
    fi
    case "$DIAG_SITE_STATUS" in
        502|504)
            found=1
            if [ "$DIAG_POOL_DOWN" -eq 1 ]; then
                echo "  - $DIAG_SITE_STATUS because the site's PHP isn't running. Runbook: runbooks/502-bad-gateway.md"
            elif [ "$DIAG_MAX_CHILDREN" -eq 1 ]; then
                echo "  - $DIAG_SITE_STATUS because all PHP workers are busy. Runbook: runbooks/502-bad-gateway.md"
            else
                echo "  - $DIAG_SITE_STATUS: nginx can't get an answer from PHP. Runbook: runbooks/502-bad-gateway.md"
            fi ;;
    esac
    if [ "$DIAG_LOAD" -eq 1 ]; then
        found=1; echo "  - High load: more work than the CPUs can do. Runbook: runbooks/high-load.md"
    fi
    if [ "$DIAG_FAILED_SERVICES" -eq 1 ] && [ "$found" -eq 0 ]; then
        found=1; echo "  - A service has failed (above): read its log (logs.sh) before restarting it."
    fi
    [ "$found" -eq 1 ] || echo "  - Nothing matched a known problem."
}

servio_run "$@"
