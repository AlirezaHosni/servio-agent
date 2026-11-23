#!/usr/bin/env bash
# create-site.sh: create a site on a provisioned server.
#
#   bash run.sh <host> create-site.sh <domain> [web-dir] [php-version] [--dry-run]
#   bash run.sh web1 create-site.sh shop.example.com public 8.4      (defaults: public, 8.4)
#
#   1. the site's OWN Linux user (decision 6), named from the domain (s_shopexamplecom_3f2a1b),
#      with a private home folder /home/<user>; nginx may read its public files through the
#      site's group, other sites can't read anything
#   2. the site's folder /home/<user>/<domain> in the release layout (v0.5, lib.sh): releases/,
#      shared/storage (Laravel's folders), and `current` pointing at a placeholder release with a
#      "This site is set up" page. If `current` exists already, it's left alone: never overwrite
#      a deployed site
#   3. the site's own PHP-FPM pool, running as its user, tested with `php-fpm -t`
#   4. the nginx config (HTTPS if the site already has a certificate) pointing at that pool,
#      tested with `nginx -t`. If a test fails, that change is undone, so the other sites keep
#      working
#   5. the site's deploy key, made ON THE SERVER as the site's user. Only the public half is
#      printed, as SERVIO_DEPLOY_KEY=ssh-ed25519 ...: add it to the repository as a read-only key
#   6. checks the result: the pool is up and nginx really serves the site (item 52)
#
# Safe to run again (it rewrites the pool and nginx configs and keeps the files and the key).
# Changing an existing site's PHP version is a different job (item 23): refused here.
# Ported from Servio's CreateSite recipe.

main() {
    local domain="${1:-}" web_dir="${2:-public}" php_version="${3:-8.4}"
    [ -n "$domain" ] || die_input "Usage: create-site.sh <domain> [web-dir] [php-version]"
    validate_domain "$domain"
    validate_web_dir "$web_dir"
    validate_php "$php_version"
    begin_change "$domain" "$@"

    local user home dir web_root deploy_key new_config existing placeholder=0
    user="$(site_user "$domain")"
    home="$(site_home "$domain")"
    dir="$(site_dir "$domain")"
    # nginx serves the release `current` points at (v0.5 release folders).
    web_root="$dir/current/$web_dir"
    deploy_key="$(deploy_key_path "$domain")"

    step "Checking the server"
    require_root
    command -v nginx >/dev/null 2>&1 || die_state "This server isn't provisioned (no nginx). Run provision-server.sh first."
    command -v "php-fpm$php_version" >/dev/null 2>&1 \
        || die_state "PHP $php_version isn't installed on this server. Install it with provision-server.sh (e.g. provision-server.sh 8.4 $php_version)."
    require_managed_config "$domain"
    if is_in_place_site "$domain"; then
        die_refused "$dir is a v0.3 in-place checkout (it has .git). Release folders need a fresh site: delete it (delete-site.sh) and create it again."
    fi
    existing="$(site_pool_versions "$domain")"
    if [ -n "$existing" ] && [ "$existing" != "$php_version" ]; then
        die_refused "$domain already runs PHP $existing. Changing a site's PHP version is a separate step (not in this script)."
    fi
    if [ -f "$(pool_file "$domain" "$php_version")" ] && ! grep -qF "$MANAGED_HEADER" "$(pool_file "$domain" "$php_version")"; then
        die_refused "$(pool_file "$domain" "$php_version") exists but wasn't written by Servio. Not touching it."
    fi
    lock_site "$domain"
    echo "OK: nginx and PHP $php_version are there. Site user: $user"

    step "The site's user: $user"
    if id "$user" >/dev/null 2>&1; then
        echo "Already exists."
    else
        # Its own group too (Ubuntu's default), no password: nobody logs in as it, scripts use runuser.
        run useradd --create-home --home-dir "$home" --shell /bin/bash --comment "servio site $domain" "$user"
    fi
    # 750: the user and its group (where nginx is) can enter, other site users can't.
    run chmod 750 "$home"
    # nginx (www-data) reads the site's static files through the site's group, nothing more.
    run usermod -aG "$user" www-data

    step "Creating $dir (release folders)"
    # 750: the user and its group (nginx) can enter. tmp: the site's own temp folder (uploads,
    # sessions), never a shared /tmp. shared/storage: Laravel's storage, the same in every release.
    local d placeholder_release="00000000-000000-placeholder"
    run install -d -o "$user" -g "$user" -m 750 "$dir" "$dir/releases" "$dir/shared" "$dir/shared/storage"
    for d in $LARAVEL_STORAGE_DIRS; do
        run install -d -o "$user" -g "$user" -m 750 "$dir/shared/storage/$d"
    done
    run install -d -o "$user" -g "$user" -m 700 "$home/tmp"

    # A placeholder release, ONLY if nothing is live yet: never replace a deployed site.
    if [ -L "$dir/current" ]; then
        echo "Already live: $(current_release "$domain" || true). Leaving it alone."
    else
        placeholder=1
        run install -d -o "$user" -g "$user" -m 750 "$dir/releases/$placeholder_release" "$dir/releases/$placeholder_release/$web_dir"
        write_file "$dir/releases/$placeholder_release/$web_dir/index.html" 640 "$user:$user" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Coming soon</title></head>
<body style="margin:0;min-height:100vh;display:grid;place-items:center;background:#09090b;color:#e4e4e7;font-family:system-ui,sans-serif">
<div style="text-align:center"><p style="font-size:2rem;margin:0">&#9650;</p><h1 style="font-weight:600">This site is set up</h1><p style="color:#a1a1aa">Created by Servio. Deploy your code to replace this page.</p></div>
</body>
</html>
HTML
        if dry_run; then
            echo "[dry-run] would point current -> releases/$placeholder_release"
        else
            switch_current "$domain" "$placeholder_release"
            echo "Placeholder page created; current -> releases/$placeholder_release"
        fi
    fi

    step "The site's PHP $php_version-FPM pool"
    apply_pool_config "$domain" "$php_version"

    step "Writing the nginx config, enabling it and testing nginx"
    new_config="$(mktemp)"
    add_exit_hook "rm -f '$new_config'"
    read_site_meta "$domain"          # keep extra names, www and suspended state on a re-run
    nginx_current_config "$domain" "$web_root" "$php_version" > "$new_config"
    apply_nginx_config "$domain" "$new_config"

    step "Deploy key"
    # One key per site: GitHub allows a deploy key on only ONE repository, and a leaked key then
    # exposes one repo, not all of them.
    run install -d -o "$user" -g "$user" -m 700 "$home/.ssh"
    if [ -f "$deploy_key" ]; then
        echo "Already exists."
    else
        # runuser: create it AS the site's user, so it owns it (ssh refuses keys others can read).
        run runuser -u "$user" -- ssh-keygen -q -t ed25519 -N '' -C "servio-deploy@$domain" -f "$deploy_key"
        dry_run || echo "Created (the private half stays on this server)."
    fi

    if dry_run; then
        step "Done (dry run): nothing was changed"
        return 0
    fi

    step "Checking the result"
    # ondemand pools start no process until a request: the socket is what shows the pool is up.
    if [ -S "$(pool_socket "$domain" "$php_version")" ]; then
        check_pass "PHP pool up" "$(pool_socket "$domain" "$php_version")"
    else
        check_fail "PHP pool up" "no socket at $(pool_socket "$domain" "$php_version")"
    fi
    if [ -f "$(certificate_path "$domain")" ]; then
        site_status "$domain" https
        if [ "$SITE_STATUS" != "000" ] && [ "$SITE_STATUS" -lt 500 ]; then
            check_pass "https://$domain answers" "status $SITE_STATUS, certificate valid for the name"
        else
            check_fail "https://$domain answers" "status $SITE_STATUS"
        fi
    else
        site_status "$domain" http
        if [ "$placeholder" -eq 1 ] && [ "$SITE_STATUS" = "200" ] && [[ "$SITE_BODY" == *"This site is set up"* ]]; then
            check_pass "nginx serves http://$domain" "the placeholder page"
        elif [ "$placeholder" -eq 0 ] && [ "$SITE_STATUS" != "000" ] && [ "$SITE_STATUS" -lt 500 ]; then
            check_pass "nginx serves http://$domain" "status $SITE_STATUS"
        else
            check_fail "nginx serves http://$domain" "status $SITE_STATUS"
        fi
    fi
    check_summary || die "The site was set up but doesn't answer as expected (see above)."

    if [ -f "$(certificate_path "$domain")" ]; then
        echo "https://$domain is served from $web_root"
    else
        echo "http://$domain is served from $web_root"
        echo "Point the domain's DNS (an A record) at this server's IP to reach it."
    fi
    echo "Site user: $user (PHP $php_version)"
    echo "Add this PUBLIC key to the repository as a read-only deploy key (GitHub: Settings > Deploy keys):"
    echo "SERVIO_DEPLOY_KEY=$(cat "$deploy_key.pub")"
}

servio_run "$@"
