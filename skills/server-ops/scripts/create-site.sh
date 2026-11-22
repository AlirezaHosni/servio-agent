#!/usr/bin/env bash
# create-site.sh: create a site on a provisioned server.
#
#   bash run.sh <host> create-site.sh <domain> [web-dir] [php-version]
#   bash run.sh web1 create-site.sh shop.example.com public 8.4      (defaults: public, 8.4)
#
#   1. the site's folder and web root, owned by servio
#   2. a placeholder page (only if the web root is empty: never overwrite a deployed site)
#   3. the nginx config (HTTPS if the site already has a certificate), enabled, tested with
#      `nginx -t`, then nginx reloaded. If `nginx -t` fails, the change is undone, so nginx
#      keeps running with the configs it had: one broken site never takes down the others
#   4. the site's deploy key, made ON THE SERVER. Only the public half is printed, as
#      SERVIO_DEPLOY_KEY=ssh-ed25519 ...: add it to the repository as a read-only deploy key
#
# Safe to run again (it rewrites the nginx config and keeps the files and the key).
# Ported from Servio's CreateSite recipe.

main() {
    local domain="${1:-}" web_dir="${2:-public}" php_version="${3:-8.4}"
    [ -n "$domain" ] || die "Usage: create-site.sh <domain> [web-dir] [php-version]"
    validate_domain "$domain"
    validate_web_dir "$web_dir"
    validate_php "$php_version"

    local dir web_root deploy_key new_config
    dir="$(site_dir "$domain")"
    web_root="$dir/$web_dir"
    deploy_key="$(deploy_key_path "$domain")"

    step "Checking the server"
    require_root
    if ! id "$SITE_USER" >/dev/null 2>&1 || ! command -v nginx >/dev/null 2>&1; then
        die "This server isn't provisioned (no $SITE_USER user or no nginx). Run provision-server.sh first."
    fi
    if [ ! -S "/run/php/php$php_version-fpm.sock" ]; then
        die "PHP $php_version-FPM isn't running on this server (no socket at /run/php/php$php_version-fpm.sock)."
    fi
    require_managed_config "$domain"
    echo "OK: $SITE_USER, nginx and PHP $php_version-FPM are there."

    step "Creating $dir"
    # -d = make directories (like mkdir -p), with owner, group and permissions in one go.
    install -d -o "$SITE_USER" -g "$SITE_USER" -m 750 "$dir" "$web_root"

    # A placeholder page, ONLY if the web root is empty: never overwrite a deployed site.
    if [ -z "$(ls -A "$web_root")" ]; then
        cat > "$web_root/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Coming soon</title></head>
<body style="margin:0;min-height:100vh;display:grid;place-items:center;background:#09090b;color:#e4e4e7;font-family:system-ui,sans-serif">
<div style="text-align:center"><p style="font-size:2rem;margin:0">&#9650;</p><h1 style="font-weight:600">This site is set up</h1><p style="color:#a1a1aa">Created by Servio. Deploy your code to replace this page.</p></div>
</body>
</html>
HTML
        chown "$SITE_USER:$SITE_USER" "$web_root/index.html"
        echo "Placeholder page created."
    else
        echo "The web root isn't empty: leaving its files alone."
    fi

    step "Writing the nginx config, enabling it and testing nginx"
    new_config="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$new_config'" EXIT
    nginx_current_config "$domain" "$web_root" "$php_version" > "$new_config"
    apply_nginx_config "$domain" "$new_config"
    if [ -f "$(certificate_path "$domain")" ]; then
        echo "https://$domain is served from $web_root"
    else
        echo "http://$domain is served from $web_root"
        echo "Point the domain's DNS (an A record) at this server's IP to reach it."
    fi

    step "Deploy key"
    # One key per site, not one per server: GitHub allows a deploy key on only ONE repository,
    # and a leaked key then exposes one repo, not all of them.
    install -d -o "$SITE_USER" -g "$SITE_USER" -m 700 "$(dirname "$deploy_key")"
    if [ -f "$deploy_key" ]; then
        echo "Already exists."
    else
        # runuser: create it AS servio, so servio owns it (ssh refuses keys others can read).
        runuser -u "$SITE_USER" -- ssh-keygen -q -t ed25519 -N '' -C "servio-deploy@$domain" -f "$deploy_key"
        echo "Created (the private half stays on this server)."
    fi
    echo "Add this PUBLIC key to the repository as a read-only deploy key (GitHub: Settings > Deploy keys):"
    echo "SERVIO_DEPLOY_KEY=$(cat "$deploy_key.pub")"
}

main "$@" < /dev/null
