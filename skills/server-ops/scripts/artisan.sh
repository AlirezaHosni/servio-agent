#!/usr/bin/env bash
# artisan.sh: run one Laravel command from an allow-list (item 20).
#
#   bash run.sh <host> artisan.sh <domain> <command> [--dry-run]
#
#   migrate         migrate --force (the dry run shows `migrate:status`: what would run)
#   optimize        optimize            optimize:clear   clear every cache
#   config:cache    route:cache         view:cache
#   queue:restart   workers finish their job, then restart with the current code
#   storage:link    public/storage -> storage/app/public
#   down            maintenance mode (503 for visitors)     up   back online
#
# Never anything else: no tinker (runs any code), no db:wipe / migrate:fresh / migrate:rollback
# (lose data), no free-form arguments. As the site's user, in the live release, with the site's
# PHP version. The output is masked like everything else.

ALLOWED_ARTISAN="migrate optimize optimize:clear config:cache route:cache view:cache queue:restart storage:link down up"

main() {
    local domain="${1:-}" command="${2:-}" cur user
    [ -n "$domain" ] && [ -n "$command" ] || die_input "Usage: artisan.sh <domain> <command>. Allowed: $ALLOWED_ARTISAN"
    validate_domain "$domain"
    case " $ALLOWED_ARTISAN " in
        *" $command "*) ;;
        *) die_refused "'$command' isn't on the allow-list ($ALLOWED_ARTISAN)." ;;
    esac
    begin_change "$domain" "$@"

    require_root
    read_site_settings "$domain"
    user="$(site_user "$domain")"
    cur="$(site_current "$domain")"
    [ -f "$cur/artisan" ] || die_state "The live release of $domain isn't a Laravel app (no artisan)."
    [ -f "$cur/.env" ] || die_state "$domain has no shared/.env yet: create it first (artisan needs it)."
    lock_site "$domain"

    # The one command line, built here from the allow-list (never from free text).
    local args=("$command")
    [ "$command" != "migrate" ] || args+=(--force)

    if dry_run; then
        step "Would run: php$SITE_PHP artisan ${args[*]} (as $user, in the live release)"
        if [ "$command" = "migrate" ]; then
            step "Migrations (Pending = would run now)"
            artisan_as_site "$domain" migrate:status --no-ansi || true
        fi
        step "Done (dry run): nothing was changed"
        return 0
    fi

    step "php$SITE_PHP artisan ${args[*]}"
    artisan_as_site "$domain" "${args[@]}" --no-ansi
    case "$command" in
        down) echo "Visitors now see the maintenance page (503). Undo: artisan.sh $domain up" ;;
        up)   echo "$domain is back online." ;;
    esac
}

artisan_as_site() {
    local domain="$1"; shift
    (cd "$(site_current "$domain")" && runuser -u "$(site_user "$domain")" -- \
        env HOME="$(site_home "$domain")" "/usr/bin/php$SITE_PHP" artisan "$@")
}

servio_run "$@"
