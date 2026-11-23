#!/usr/bin/env bash
# change-php.sh: move a site to another PHP version (item 23, decision 1).
#
#   bash run.sh <host> change-php.sh <domain> <version> [--dry-run]       (8.3, 8.4 or 8.5)
#
# The version must be installed on the server already (provision-server.sh <default> <more>):
# installing PHP is a server change of its own. Then:
#   1. FIRST, with the new PHP: `composer check-platform-reqs` in the live release (the PHP
#      version and extensions composer.lock needs). Stop here if it fails: nothing changed
#   2. the site's pool for the new version (same size), tested with php-fpm -t
#   3. nginx pointed at the new pool's socket, tested with nginx -t
#   4. health check; if it fails: nginx back to the old pool, stop (the old pool still runs)
#   5. the site's workers and scheduler re-written to use the new php binary, restarted
#   6. the old pool removed, the old PHP version reloaded
# Deploys use the new version from then on (they read it from nginx).

main() {
    local domain="${1:-}" new="${2:-}"
    [ -n "$domain" ] && [ -n "$new" ] || die_input "Usage: change-php.sh <domain> <version>"
    validate_domain "$domain"
    validate_php "$new"
    begin_change "$domain" "$@"

    require_root
    read_site_settings "$domain"
    local old="$SITE_PHP" user cur
    user="$(site_user "$domain")"; cur="$(site_current "$domain")"
    [ "$old" != "$new" ] || { echo "$domain already runs PHP $new."; return 0; }
    command -v "php-fpm$new" >/dev/null 2>&1 \
        || die_state "PHP $new isn't installed on this server. Install it first: provision-server.sh <default-php> ... $new (repeat the versions it has)."
    lock_site "$domain"
    echo "$domain: PHP $old -> $new"

    step "Does the project run on PHP $new? (composer check-platform-reqs)"
    if [ -f "$cur/composer.lock" ]; then
        if ! (cd "$cur" && runuser -u "$user" -- env HOME="$(site_home "$domain")" COMPOSER_NO_INTERACTION=1 \
                "/usr/bin/php$new" /usr/local/bin/composer check-platform-reqs --no-dev --no-ansi 2>&1); then
            die_state "The project's requirements aren't met with PHP $new (see above: the PHP version or an extension). Nothing was changed."
        fi
        echo "OK: PHP $new and its extensions meet composer.lock."
    else
        echo "No composer.lock in the live release: nothing to check (not deployed yet, or not a Composer project)."
    fi

    step "The site's PHP $new pool"
    apply_pool_config "$domain" "$new"

    step "nginx -> PHP $new"
    local new_config
    new_config="$(mktemp)"; add_exit_hook "rm -f '$new_config'"
    nginx_current_config "$domain" "$SITE_ROOT" "$new" > "$new_config"
    apply_nginx_config "$domain" "$new_config"

    if dry_run; then
        step "Then"
        echo "  health check; on failure nginx goes back to PHP $old"
        echo "  workers and scheduler re-written for php$new, the PHP $old pool removed"
        step "Done (dry run): nothing was changed"
        return 0
    fi

    step "Checking the site on PHP $new"
    if health_check "$domain"; then
        check_pass "health check" "$HEALTH_DETAIL"
    else
        check_fail "health check" "$HEALTH_DETAIL"
        nginx_current_config "$domain" "$SITE_ROOT" "$old" > "$new_config"
        apply_nginx_config "$domain" "$new_config"
        rm -f "$(pool_file "$domain" "$new")"; systemctl reload "php$new-fpm"
        die "The site fails on PHP $new: nginx is back on PHP $old. Look at logs.sh $domain laravel."
    fi
    SITE_PHP="$new"

    step "Workers and scheduler -> php$new"
    rewrite_workers "$domain" "$new"

    step "Removing the PHP $old pool"
    rm -f "$(pool_file "$domain" "$old")" "$(pool_file "$domain" "$old")".bak-*
    systemctl reload "php$old-fpm"
    [ ! -f "$(pool_file "$domain" "$old")" ] && check_pass "old pool removed" || check_fail "old pool removed"
    [ -S "$(pool_socket "$domain" "$new")" ] && check_pass "PHP $new pool running" || check_fail "PHP $new pool running"
    check_summary || die "Switched to PHP $new, but something isn't right (see above)."
    echo "SERVIO_PHP=$new"
}

# rewrite_workers <domain> <php>: the site's Supervisor programs and cron line name the php binary:
# write them again with the new one, keeping queues and process counts.
rewrite_workers() {
    local domain="$1" php="$2" kind conf queues procs changed=0
    for kind in $WORKER_KINDS; do
        conf="$(worker_conf "$domain" "$kind")"
        [ -f "$conf" ] && grep -qF "$MANAGED_HEADER" "$conf" || continue
        queues="$(grep -oE -- '--queue=[A-Za-z0-9_.,-]+' "$conf" | head -n 1 | cut -d= -f2 || true)"
        procs="$(sed -n 's/^numprocs=\([0-9]*\)$/\1/p' "$conf" | head -n 1)"
        worker_program "$domain" "$php" "$kind" "${queues:-default}" "${procs:-1}" | write_file "$conf" 644 root:root
        changed=1
    done
    if [ "$changed" -eq 1 ]; then
        supervisorctl reread >/dev/null && supervisorctl update
        echo "Workers restarted on php$php."
    else
        echo "No workers."
    fi
    if [ -f "$(scheduler_file "$domain")" ] && grep -qF "$MANAGED_HEADER" "$(scheduler_file "$domain")"; then
        scheduler_cron "$domain" "$php" | write_file "$(scheduler_file "$domain")" 644 root:root
        echo "Scheduler now runs php$php."
    fi
    return 0
}

servio_run "$@"
