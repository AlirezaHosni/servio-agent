#!/usr/bin/env bash
# delete-site.sh: delete a site from its server: nginx config, certificate, logs, deploy key
# and the site's whole folder.
#
#   bash run.sh <host> delete-site.sh <domain> <domain-typed-again> [--dry-run]
#
# DESTRUCTIVE: `rm -rf` on the site's folder can't be undone. So:
#   - the second argument must be the domain again, exactly as the user typed it in chat
#   - the domain is validated again here (it builds the path)
#   - a hand-made nginx config (no "# Managed by Servio" line) is refused
#   - the path is re-checked right before deleting: exactly /home/servio/<something>, never
#     /home/servio itself, never empty
#   - nginx stops serving the site first, so no request hits half-deleted files
#   - --dry-run lists everything that would go (with the folder's size) and deletes nothing
# Safe to run again: every step works when its target is already gone.
# Ported from Servio's DeleteSite recipe.

main() {
    local domain="${1:-}" confirm="${2:-}"
    [ -n "$domain" ] && [ -n "$confirm" ] || die_input "Usage: delete-site.sh <domain> <domain-typed-again>"
    validate_domain "$domain"
    [ "$domain" = "$confirm" ] || die_refused "The confirmation '$confirm' doesn't match '$domain'. Nothing was deleted."
    begin_change "$domain" "$@"

    local dir deploy_key available
    dir="$(site_dir "$domain")"
    deploy_key="$(deploy_key_path "$domain")"
    available="$(nginx_available "$domain")"

    require_root
    require_managed_config "$domain"

    # Last line of defence before rm -rf, checked BEFORE anything is removed: the path must be
    # one folder directly inside $SITES_HOME. Never empty, never $SITES_HOME itself.
    case "$dir" in
        "$SITES_HOME"/*/*|"$SITES_HOME"/|"$SITES_HOME") die_refused "Refusing to delete '$dir'." ;;
        "$SITES_HOME"/?*) ;;
        *) die_refused "Refusing to delete '$dir'." ;;
    esac
    lock_site "$domain"

    if dry_run; then
        step "What would be deleted"
        echo "  nginx config:  $( [ -f "$available" ] && echo "$available (and its backups)" || echo none)"
        echo "  certificate:   $( [ -d "$LETSENCRYPT_DIR/live/$domain" ] && echo "$LETSENCRYPT_DIR/live/$domain" || echo none)"
        echo "  deploy key:    $( [ -f "$deploy_key" ] && echo "$deploy_key (+ .pub)" || echo none)"
        echo "  logs:          /var/log/nginx/$domain-*.log*"
        echo "  site folder:   $( [ -d "$dir" ] && echo "$dir ($(du -sh "$dir" 2>/dev/null | cut -f1), including .env, uploads and SQLite files)" || echo none)"
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

    step "Removing the logs and the deploy key"
    rm -f "/var/log/nginx/$domain-access.log"* "/var/log/nginx/$domain-error.log"*
    rm -f "$deploy_key" "$deploy_key.pub"
    echo "Also remove the deploy key from the repository's settings (GitHub: Settings > Deploy keys)."

    step "Deleting $dir"
    rm -rf -- "$dir"

    step "Checking the result"
    if nginx -T 2>/dev/null | grep -qE "server_name[[:space:]]+$domain;"; then
        check_fail "nginx no longer serves $domain" "a server block for it is still loaded"
    else
        check_pass "nginx no longer serves $domain"
    fi
    if [ -e "$dir" ]; then check_fail "site folder removed" "$dir still exists"; else check_pass "site folder removed"; fi
    if [ -e "$LETSENCRYPT_DIR/live/$domain" ]; then check_fail "certificate removed"; else check_pass "certificate removed"; fi
    if [ -e "$deploy_key" ]; then check_fail "deploy key removed"; else check_pass "deploy key removed"; fi
    check_summary || die "Something was left behind (see above)."

    step "Done"
    echo "$domain is gone from this server."
}

servio_run "$@"
