#!/usr/bin/env bash
# suspend-site.sh: take a site offline with a "temporarily unavailable" page, or bring it back
# (item 77).
#
#   bash run.sh <host> suspend-site.sh <domain> suspend [--dry-run]
#   bash run.sh <host> suspend-site.sh <domain> resume  [--dry-run]
#
# nginx itself answers every request with status 503 and a small page: the app isn't touched,
# so it works even when the app is broken (unlike `artisan down`, which needs a working app).
# 503 tells search engines "come back later", not "gone". Certificate renewal keeps working
# (/.well-known/acme-challenge/ stays reachable). Workers and the scheduler keep running: stop
# them with workers.sh if they should stop too.

main() {
    local domain="${1:-}" action="${2:-}"
    [ -n "$domain" ] || die_input "Usage: suspend-site.sh <domain> suspend|resume"
    validate_domain "$domain"
    [[ "$action" =~ ^(suspend|resume)$ ]] || die_input "suspend-site.sh $domain suspend|resume"
    begin_change "$domain" "$@"

    step "Checking the site"
    require_root
    read_site_settings "$domain"
    lock_site "$domain"
    if [ "$action" = "suspend" ] && [ "$SITE_SUSPENDED" -eq 1 ]; then echo "Already suspended."; return 0; fi
    if [ "$action" = "resume" ] && [ "$SITE_SUSPENDED" -eq 0 ]; then echo "Not suspended."; return 0; fi

    if [ "$action" = "suspend" ]; then
        step "The page visitors will see"
        run install -d -m 755 "$SUSPENDED_ROOT"
        suspended_page | write_file "$SUSPENDED_ROOT/suspended.html" 644 root:root
        SITE_SUSPENDED=1
    else
        SITE_SUSPENDED=0
    fi

    step "The nginx config ($( [ "$action" = suspend ] && echo "503 for every request" || echo "serving the site again"))"
    local new_config
    new_config="$(mktemp)"; add_exit_hook "rm -f '$new_config'"
    nginx_current_config "$domain" "$SITE_ROOT" "$SITE_PHP" > "$new_config"
    apply_nginx_config "$domain" "$new_config"

    if dry_run; then
        step "Done (dry run): nothing was changed"
        return 0
    fi

    step "Checking the result"
    local scheme=http
    [ -f "$(certificate_path "$domain")" ] && scheme=https
    site_status "$domain" "$scheme"
    if [ "$action" = "suspend" ]; then
        [ "$SITE_STATUS" = "503" ] && [[ "$SITE_BODY" == *"temporarily unavailable"* ]] \
            && check_pass "$domain shows the suspended page" "503" || check_fail "$domain shows the suspended page" "status $SITE_STATUS"
    else
        health_check "$domain" && check_pass "$domain is back" "$HEALTH_DETAIL" || check_fail "$domain is back" "$HEALTH_DETAIL"
    fi
    check_summary || die "The site isn't in the expected state (see above)."
}

# One static page for every suspended site: nothing site-specific, no app involved.
suspended_page() {
    cat <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Temporarily unavailable</title></head>
<body style="margin:0;min-height:100vh;display:grid;place-items:center;background:#09090b;color:#e4e4e7;font-family:system-ui,sans-serif">
<div style="text-align:center"><h1 style="font-weight:600">This site is temporarily unavailable</h1><p style="color:#a1a1aa">Please try again later.</p></div>
</body>
</html>
HTML
}

servio_run "$@"
