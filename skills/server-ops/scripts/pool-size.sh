#!/usr/bin/env bash
# pool-size.sh: set how many PHP workers a site's pool may run at once (item 59).
#
#   bash run.sh <host> pool-size.sh <domain> <max-children> [--dry-run]     (1-100)
#
# The number comes from php-sizing.sh (read-only): it measures what a worker really uses and how
# many fit in memory. This script only applies it: rewrites the site's pool with the new
# pm.max_children, tests it with php-fpm -t (undone if PHP rejects it), reloads that PHP
# version (running requests finish), and checks the pool is up. The value is kept by every later
# re-render (create-site, change-php).

main() {
    local domain="${1:-}" n="${2:-}"
    [ -n "$domain" ] && [ -n "$n" ] || die_input "Usage: pool-size.sh <domain> <max-children>"
    validate_domain "$domain"
    [[ "$n" =~ ^[1-9][0-9]?$|^100$ ]] || die_input "max-children must be 1 to 100."
    begin_change "$domain" "$@"

    require_root
    read_site_settings "$domain"
    [ -f "$(pool_file "$domain" "$SITE_PHP")" ] || die_state "$domain has no pool of its own (create-site.sh makes it)."
    lock_site "$domain"
    local old
    old="$(current_max_children "$domain")"
    echo "PHP $SITE_PHP pool of $domain: pm.max_children $old -> $n"
    [ "$old" != "$n" ] || { echo "Already $n. Nothing to do."; return 0; }

    # Every pool on the server together, after the change (php-sizing.sh compares it with memory).
    local f total=0 v
    for f in "$PHP_ETC_DIR"/*/fpm/pool.d/*.conf; do
        [ -f "$f" ] || continue
        [ "$f" = "$(pool_file "$domain" "$SITE_PHP")" ] && { total=$((total + n)); continue; }
        v="$(sed -n 's/^\s*pm\.max_children\s*=\s*\([0-9]*\)\s*$/\1/p' "$f" | tail -n 1)"
        [[ "$v" =~ ^[0-9]+$ ]] && total=$((total + v))
    done
    echo "All pools on this server together could then run $total workers (php-sizing.sh: how many fit)."

    step "Writing the pool"
    POOL_MAX_CHILDREN="$n"
    apply_pool_config "$domain" "$SITE_PHP"

    if dry_run; then
        step "Done (dry run): nothing was changed"
        return 0
    fi

    step "Checking the result"
    grep -qx "pm.max_children = $n" "$(pool_file "$domain" "$SITE_PHP")" && check_pass "pool file" "pm.max_children = $n" || check_fail "pool file"
    [ -S "$(pool_socket "$domain" "$SITE_PHP")" ] && check_pass "pool running" || check_fail "pool running" "no socket"
    check_summary || die "The pool isn't right (see above)."
}

servio_run "$@"
