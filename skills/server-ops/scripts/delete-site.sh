#!/usr/bin/env bash
# delete-site.sh: delete a site from its server: nginx config, certificate, logs, its PHP-FPM
# pool, and its Linux user with its whole home folder (the site's files, deploy key, temp files).
#
#   bash run.sh <host> delete-site.sh <domain> <domain-typed-again> [--dry-run]
#
# DESTRUCTIVE: removing the site's user removes /home/<user> for good. So:
#   - the second argument must be the domain again, exactly as the user typed it in chat
#   - the domain is validated again here (it builds the user name and the path)
#   - a hand-made nginx config (no "# Managed by Servio" line) is refused
#   - before ANYTHING is removed, the user and its home are checked: the name must look like a
#     site user (s_<letters>_<6 hex>), and the system must say its home is exactly
#     /home/<that user>. Never another user, never /home itself
#   - nginx stops serving the site first, then its PHP pool stops, so no request hits
#     half-deleted files
#   - --dry-run lists everything that would go (with the folder's size) and deletes nothing
# Safe to run again: every step works when its target is already gone.
# Ported from Servio's DeleteSite recipe.

main() {
    local domain="${1:-}" confirm="${2:-}"
    [ -n "$domain" ] && [ -n "$confirm" ] || die_input "Usage: delete-site.sh <domain> <domain-typed-again>"
    validate_domain "$domain"
    [ "$domain" = "$confirm" ] || die_refused "The confirmation '$confirm' doesn't match '$domain'. Nothing was deleted."
    begin_change "$domain" "$@"

    local user home available versions v real_home
    user="$(site_user "$domain")"
    home="$(site_home "$domain")"
    available="$(nginx_available "$domain")"

    require_root
    require_managed_config "$domain"

    # Last line of defence, checked BEFORE anything is removed.
    [[ "$user" =~ $SITE_USER_PATTERN ]] || die_refused "'$user' doesn't look like a site user. Not deleting anything."
    [ "$home" = "$HOME_BASE/$user" ] || die_refused "Unexpected home folder '$home'. Not deleting anything."
    if id "$user" >/dev/null 2>&1; then
        real_home="$(getent passwd "$user" | cut -d: -f6)"
        [ "$real_home" = "$home" ] || die_refused "The system says $user's home is '$real_home', not '$home'. Not deleting anything."
    fi
    versions="$(site_pool_versions "$domain")"
    lock_site "$domain"

    if dry_run; then
        step "What would be deleted"
        echo "  nginx config:  $( [ -f "$available" ] && echo "$available (and its backups)" || echo none)"
        echo "  certificate:   $( [ -d "$LETSENCRYPT_DIR/live/$domain" ] && echo "$LETSENCRYPT_DIR/live/$domain" || echo none)"
        echo "  PHP-FPM pool:  $( [ -n "$versions" ] && echo "PHP $versions ($(pool_file "$domain" "${versions%% *}"))" || echo none)"
        echo "  workers:       $(site_worker_status "$domain" | awk '{print $1}' | sed 's/:.*//' | sort -u | tr '\n' ' ')$( [ -f "$(scheduler_file "$domain")" ] && echo "+ the scheduler (cron)")"
        echo "  logs:          /var/log/nginx/$domain-*.log*"
        echo "  site user:     $( id "$user" >/dev/null 2>&1 && echo "$user" || echo "none ($user doesn't exist)")"
        echo "  its home:      $( [ -d "$home" ] && echo "$home ($(du -sh "$home" 2>/dev/null | cut -f1)): the site, .env, uploads, SQLite files, the deploy key" || echo none)"
        echo "  MySQL databases are NOT touched."
        step "Done (dry run): nothing was deleted"
        return 0
    fi

    step "Removing the nginx config for $domain"
    rm -f "$(nginx_enabled "$domain")" "$available" "$available".bak-* "$available.previous"
    if nginx -t 2>&1; then
        systemctl reload nginx
    else
        # Not caused by removing a file: another config is broken. Don't reload into it.
        die_state "nginx -t fails because of ANOTHER config. Not reloading; fix that config first."
    fi

    # After the nginx config is gone: nginx must not point at certificate files we delete.
    step "Removing the SSL certificate"
    if command -v certbot >/dev/null 2>&1 && [ -d "$LETSENCRYPT_DIR/live/$domain" ]; then
        certbot delete --non-interactive --cert-name "$domain"
    else
        echo "None."
    fi

    step "Removing the site's PHP-FPM pool"
    if [ -z "$versions" ]; then
        echo "None."
    fi
    for v in $versions; do
        rm -f "$(pool_file "$domain" "$v")" "$(pool_file "$domain" "$v")".bak-*
        # The pool's processes stop with the reload (the other sites' pools keep running).
        systemctl reload "php$v-fpm"
        echo "PHP $v: pool removed."
    done

    # Before the user goes: Supervisor would keep restarting its workers, and cron would keep
    # starting its scheduler, as a user that no longer exists.
    step "Removing the site's workers and scheduler"
    local kind removed=0
    for kind in $WORKER_KINDS; do
        if [ -f "$(worker_conf "$domain" "$kind")" ]; then rm -f "$(worker_conf "$domain" "$kind")"; removed=1; fi
    done
    if [ "$removed" -eq 1 ] && command -v supervisorctl >/dev/null 2>&1; then
        supervisorctl reread >/dev/null 2>&1 || true
        supervisorctl update 2>&1 || true
    fi
    rm -f "$(scheduler_file "$domain")" "$(logrotate_file "$domain")"
    [ "$removed" -eq 1 ] && echo "Workers removed." || echo "No workers."

    step "Removing the logs"
    rm -f "/var/log/nginx/$domain-access.log"* "/var/log/nginx/$domain-error.log"*

    step "Removing the site's user $user and its home $home"
    if id "$user" >/dev/null 2>&1; then
        # Anything still running as the site's user (a stuck deploy, a worker) would block userdel.
        pkill -KILL -u "$user" 2>/dev/null || true
        # --remove: the home folder goes too (the site, .env, uploads, the deploy key). The
        # user's own group goes with it, and with it nginx's membership of that group.
        userdel --remove "$user" 2>&1 || die "userdel failed for $user (see above)."
    else
        echo "No user $user."
    fi
    # A home left behind (userdel failed halfway, or a re-run): the same checks as above
    # (pattern, exactly /home/<user>) were made before anything was removed.
    if [ -d "$home" ]; then rm -rf -- "$home"; fi
    echo "Also remove the deploy key from the repository's settings (GitHub: Settings > Deploy keys)."

    step "Checking the result"
    if nginx -T 2>/dev/null | grep -qE "server_name[[:space:]]+$domain;"; then
        check_fail "nginx no longer serves $domain" "a server block for it is still loaded"
    else
        check_pass "nginx no longer serves $domain"
    fi
    if id "$user" >/dev/null 2>&1; then check_fail "site user removed" "$user still exists"; else check_pass "site user removed"; fi
    if [ -e "$home" ]; then check_fail "site files removed" "$home still exists"; else check_pass "site files removed"; fi
    if [ -n "$(site_pool_versions "$domain")" ]; then check_fail "PHP pool removed"; else check_pass "PHP pool removed"; fi
    if [ -e "$LETSENCRYPT_DIR/live/$domain" ]; then check_fail "certificate removed"; else check_pass "certificate removed"; fi
    check_summary || die "Something was left behind (see above)."

    step "Done"
    echo "$domain is gone from this server."
}

servio_run "$@"
