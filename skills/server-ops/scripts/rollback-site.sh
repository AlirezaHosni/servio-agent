#!/usr/bin/env bash
# rollback-site.sh: put the previous release back live (item 16).
#
#   bash run.sh <host> rollback-site.sh <domain> [release] [--dry-run]
#   bash run.sh web1 rollback-site.sh shop.example.com                      # the one before current
#   bash run.sh web1 rollback-site.sh shop.example.com 20261120-100000-abc1234
#
# Instant: nothing is rebuilt. The release is already on disk (the last 5 are kept), so it's:
#   1. switch `current` to it in one step, reload PHP-FPM (OPcache)
#   2. health check (/up or /); if it fails, switch back to where it was and stop
#   3. restart the workers (they keep the old code in memory)
#
# Database migrations are NOT undone: the release goes back, the database doesn't. The dry run
# lists the migrations the live release has that the target doesn't: their tables or columns
# stay. Most of the time that's fine (old code ignores new columns); a dropped or renamed column
# is not, and needs a person.
#
# The release rolled back from is kept (it's newer than the target, so it stays among the 5).

main() {
    local domain="${1:-}" target="${2:-}"
    [ -n "$domain" ] || die_input "Usage: rollback-site.sh <domain> [release]"
    validate_domain "$domain"
    if [ -n "$target" ] && ! [[ "$target" =~ $RELEASE_PATTERN ]]; then
        die_input "Invalid release '$target' (it looks like 20261120-100000-abc1234; deploy-history.sh lists them)."
    fi
    begin_change "$domain" "$@"

    local dir live migrations
    dir="$(site_dir "$domain")"

    step "Checking the site"
    require_root
    [ -d "$dir/releases" ] || die_state "$dir has no release folders (not created with v0.5, or not created at all)."
    read_site_settings "$domain"
    live="$(current_release "$domain")"
    [ -n "$live" ] || die_state "Nothing is live on $domain (no current release)."
    [ -n "$target" ] || target="$(previous_release "$domain")"
    [ -n "$target" ] || die_state "There is no release before $live to go back to."
    [ "$target" != "$live" ] || die_input "$target is already live."
    [ -d "$dir/releases/$target" ] || die_state "No release $target on this server (deploy-history.sh lists them)."
    [ "$target" != "00000000-000000-placeholder" ] || die_refused "That's the placeholder page from create-site, not a deploy."
    lock_site "$domain"

    step "Rolling back $domain"
    describe_release "live now " "$dir/releases/$live"
    describe_release "go back to" "$dir/releases/$target"

    step "Migrations that stay (the database is not rolled back)"
    migrations="$(migrations_only_in "$dir/releases/$live" "$dir/releases/$target")"
    if [ -n "$migrations" ]; then
        printf '%s\n' "$migrations" | sed 's/^/  /'
        echo "  The live release ran these; the target doesn't know them. Their changes stay in the database."
    else
        echo "  none: both releases have the same migrations"
    fi

    if dry_run; then
        step "What would happen"
        echo "  switch current: $live -> $target, reload PHP $SITE_PHP-FPM"
        echo "  health check /up (or /); if it fails, switch back to $live"
        echo "  restart the workers"
        step "Done (dry run): nothing was changed"
        return 0
    fi

    step "Switching to $target"
    switch_current "$domain" "$target"
    systemctl reload "php$SITE_PHP-fpm"

    step "Checking the result"
    if health_check "$domain"; then
        check_pass "health check" "$HEALTH_DETAIL"
    else
        check_fail "health check" "$HEALTH_DETAIL"
        switch_current "$domain" "$live"
        systemctl reload "php$SITE_PHP-fpm"
        die "$target failed its health check too: switched back to $live. Look at logs.sh $domain laravel."
    fi

    step "Restarting workers (they keep old code in memory)"
    restart_workers "$domain"
    check_summary || true

    step "Done"
    echo "SERVIO_RELEASE=$target"
    read_release "$dir/releases/$target"
    echo "SERVIO_COMMIT=${REL_COMMIT:-unknown}"
}

# describe_release <label> <release folder>: one line from its .servio-release.
describe_release() {
    read_release "$2"
    echo "  $1: $(basename "$2")  commit ${REL_COMMIT:0:7} (${REL_BRANCH:-?}), deployed ${REL_TIME:-?} by ${REL_BY:-?}"
}

# migrations_only_in <release A> <release B>: migration files A has and B doesn't (names only,
# checked: they come from the repository).
migrations_only_in() {
    local a="$1/database/migrations" b="$2/database/migrations" f
    [ -d "$a" ] || return 0
    for f in "$a"/*.php; do
        [ -f "$f" ] || continue
        f="$(basename "$f")"
        [ -f "$b/$f" ] && continue
        [[ "$f" =~ ^[A-Za-z0-9_.-]{1,120}$ ]] && echo "$f" || echo "(a migration with an unusual name)"
    done
}

servio_run "$@"
