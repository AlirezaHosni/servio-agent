#!/usr/bin/env bash
# php-sizing.sh: how many PHP workers this server's memory allows (item 58). READ-ONLY.
#
#   bash run.sh <host> php-sizing.sh [domain]
#
# Every site has its own PHP-FPM pool, and pm.max_children caps its workers (decision 6: 5 by
# default). Too high, and a traffic spike starts more workers than memory holds: the kernel kills
# them (502s). Too low, and requests queue ("server reached pm.max_children"). This measures:
#
#   1. memory per PHP worker: the 90th PERCENTILE of the running workers' memory (RSS), not the
#      average: the heavy requests are the ones that run the server out of memory
#   2. memory for PHP: total RAM, minus what everything else uses now (MySQL, Redis, nginx...),
#      minus 10% headroom
#   3. the budget: how many workers fit, against the sum of every pool's pm.max_children
#
# Then a recommendation for each pool (or the one site): WARN when the pools together can use
# more memory than there is. Applying a new value is item 59 (v0.6); this only reports.
#
# pm = ondemand pools have no workers when idle: measure while the sites have traffic. With fewer
# than 3 workers of a pool running, the server-wide figure is used for it.

PROC_DIR="/proc"
HEADROOM_PCT=10

main() {
    local domain="${1:-}"
    [ -z "$domain" ] || validate_domain "$domain"
    require_root

    local total_kb php_rss_lines other_kb
    total_kb="$(awk '/^MemTotal:/ {print $2}' "$PROC_DIR/meminfo")"
    [[ "$total_kb" =~ ^[0-9]+$ ]] || die "Couldn't read the memory size."
    # "<rss kb> <pool name>" for every PHP-FPM worker ("php-fpm: pool <name>"); the master
    # process ("php-fpm: master process") is counted with the rest.
    php_rss_lines="$(ps -eo rss=,args= 2>/dev/null | awk '$2 == "php-fpm:" && $3 == "pool" { print $1, $4 }' || true)"
    other_kb="$(ps -eo rss=,args= 2>/dev/null | awk '!($2 == "php-fpm:" && $3 == "pool") { s += $1 } END { print s + 0 }')"

    step "Memory"
    sizing_report "$total_kb" "$other_kb" "$php_rss_lines" "$(pool_limits)" "$([ -n "$domain" ] && site_user "$domain")"
}

# pool_limits: "<pool name> <pm.max_children> <php version>" for every pool on the server.
pool_limits() {
    local f v n name
    for f in "$PHP_ETC_DIR"/*/fpm/pool.d/*.conf; do
        [ -f "$f" ] || continue
        v="$(basename "$(dirname "$(dirname "$(dirname "$f")")")")"
        name="$(sed -n 's/^\[\([A-Za-z0-9_.-]*\)\]\s*$/\1/p' "$f" | head -n 1)"
        n="$(sed -n 's/^\s*pm\.max_children\s*=\s*\([0-9]*\)\s*$/\1/p' "$f" | tail -n 1)"
        [ -n "$name" ] && [[ "$n" =~ ^[0-9]+$ ]] && echo "$name $n $v"
    done
}

# percentile90 <numbers, one per line>: nearest-rank 90th percentile (0 when there are none).
percentile90() {
    sort -n | awk '{ a[NR] = $1 } END { if (NR == 0) { print 0; exit } i = int(NR * 0.9 + 0.999999); if (i < 1) i = 1; if (i > NR) i = NR; print a[i] }'
}

# sizing_report <total kb> <other kb> <"rss pool" lines> <"pool max version" lines> [only pool]
# Pure arithmetic on what it's given, so tests can feed numbers.
sizing_report() {
    local total="$1" other="$2" rss_lines="$3" limits="$4" only="${5:-}"
    local headroom php_mem p90 workers budget sum_max pool max ver n pool_p90 rec name

    headroom=$((total * HEADROOM_PCT / 100))
    php_mem=$((total - other - headroom))
    [ "$php_mem" -gt 0 ] || php_mem=0
    p90="$(printf '%s\n' "$rss_lines" | awk 'NF == 2 { print $1 }' | percentile90)"
    workers="$(printf '%s\n' "$rss_lines" | awk 'NF == 2' | wc -l | tr -d ' ')"

    echo "total memory:          $((total / 1024)) MB"
    echo "used by everything else: $((other / 1024)) MB (MySQL, Redis, nginx, the system...)"
    echo "kept free (${HEADROOM_PCT}%):        $((headroom / 1024)) MB"
    echo "left for PHP workers:  $((php_mem / 1024)) MB"
    if [ "$p90" -eq 0 ]; then
        check_na "memory per PHP worker" "no PHP workers running right now (ondemand pools start them on requests): measure while the sites have traffic"
        return 0
    fi
    echo "memory per PHP worker: $((p90 / 1024)) MB (90th percentile of $workers running workers)"
    budget=$((php_mem / p90))
    sum_max="$(printf '%s\n' "$limits" | awk 'NF == 3 { s += $2 } END { print s + 0 }')"
    echo "workers that fit:      $budget"
    echo "pools allow together:  $sum_max (the sum of every pool's pm.max_children)"
    echo
    if [ "$sum_max" -le "$budget" ]; then
        check_pass "all pools together" "$sum_max workers at most, $budget fit"
    else
        check_warn "all pools together" "up to $sum_max workers, only $budget fit: a traffic spike on several sites can run the server out of memory"
    fi

    step "Pools"
    while read -r pool max ver; do
        [ -n "$pool" ] || continue
        [ -z "$only" ] || [ "$pool" = "$only" ] || continue
        [[ "$pool" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || continue
        n="$(printf '%s\n' "$rss_lines" | awk -v p="$pool" '$2 == p' | wc -l | tr -d ' ')"
        if [ "$n" -ge 3 ]; then
            pool_p90="$(printf '%s\n' "$rss_lines" | awk -v p="$pool" '$2 == p { print $1 }' | percentile90)"
        else
            pool_p90="$p90"
        fi
        # This pool's share: what's left when the OTHER pools use their maximum, at least 2.
        rec=$(( (php_mem - (sum_max - max) * p90) / pool_p90 ))
        [ "$rec" -ge 2 ] || rec=2
        name="$pool (PHP $ver)"
        if [ "$max" -gt "$rec" ]; then
            check_warn "$name" "pm.max_children $max, $n running, ~$((pool_p90 / 1024)) MB each: recommend $rec or less"
        else
            check_pass "$name" "pm.max_children $max, $n running, ~$((pool_p90 / 1024)) MB each: fits (up to $rec)"
        fi
    done <<< "$limits"
    echo
    echo "Applying a new pm.max_children is a change (item 59, v0.6). Before raising it, check"
    echo "health.sh <domain> for 'all workers busy': if workers are never all busy, more won't help."
}

servio_run "$@"
