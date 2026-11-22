#!/usr/bin/env bash
# delete-site.sh: delete a site from its server: nginx config, certificate, logs, deploy key
# and the site's whole folder.
#
#   bash run.sh <host> delete-site.sh <domain> <domain-typed-again>
#
# DESTRUCTIVE: `rm -rf` on the site's folder can't be undone. So:
#   - the second argument must be the domain again, exactly as the user typed it in chat
#   - the domain is validated again here (it builds the path)
#   - a hand-made nginx config (no "# Managed by Servio" line) is refused
#   - the path is re-checked right before deleting: exactly /home/servio/<something>, never
#     /home/servio itself, never empty
#   - nginx stops serving the site first, so no request hits half-deleted files
# Safe to run again: every step works when its target is already gone.
# Ported from Servio's DeleteSite recipe.

main() {
    local domain="${1:-}" confirm="${2:-}"
    [ -n "$domain" ] && [ -n "$confirm" ] || die "Usage: delete-site.sh <domain> <domain-typed-again>"
    validate_domain "$domain"
    [ "$domain" = "$confirm" ] || die "The confirmation '$confirm' doesn't match '$domain'. Nothing was deleted."

    local dir deploy_key
    dir="$(site_dir "$domain")"
    deploy_key="$(deploy_key_path "$domain")"

    require_root
    require_managed_config "$domain"

    step "Removing the nginx config for $domain"
    rm -f "$(nginx_enabled "$domain")" "$(nginx_available "$domain")" "$(nginx_available "$domain").previous"
    if nginx -t; then
        systemctl reload nginx
    else
        # Not caused by removing a file: another config is broken. Don't reload into it.
        die "nginx -t fails because of ANOTHER config. Not reloading; fix that config first."
    fi

    # After the nginx config is gone: nginx must not point at certificate files we delete.
    step "Removing the SSL certificate"
    if command -v certbot >/dev/null 2>&1 && [ -d "/etc/letsencrypt/live/$domain" ]; then
        certbot delete --non-interactive --cert-name "$domain"
    else
        echo "None."
    fi

    step "Removing the logs and the deploy key"
    rm -f "/var/log/nginx/$domain-access.log"* "/var/log/nginx/$domain-error.log"*
    rm -f "$deploy_key" "$deploy_key.pub"
    echo "Also remove the deploy key from the repository's settings (GitHub: Settings > Deploy keys)."

    step "Deleting $dir"
    # Last line of defence before rm -rf: the path must be one folder directly inside
    # $SITES_HOME. Never empty, never $SITES_HOME itself, never anything else.
    case "$dir" in
        "$SITES_HOME"/*/*|"$SITES_HOME"/|"$SITES_HOME") die "Refusing to delete '$dir'." ;;
        "$SITES_HOME"/?*) ;;
        *) die "Refusing to delete '$dir'." ;;
    esac
    rm -rf -- "$dir"

    step "Done"
    echo "$domain is gone from this server."
}

main "$@" < /dev/null
