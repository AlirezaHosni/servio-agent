#!/usr/bin/env bash
# inventory.sh: what runs on this server. READ-ONLY: changes nothing.
#
#   bash run.sh <host> inventory.sh
#
# Prints the server (OS, nginx, PHP versions, firewall) and, for every site in
# /etc/nginx/sites-enabled: web root, PHP version, HTTPS certificate expiry, deployed git
# commit and branch, Laravel version (from composer.lock) and whether a .env file EXISTS.
#
# Never reads .env (only `[ -f ]` checks that it's there) or any key. Everything printed that
# comes from files a deploy controls (composer.lock, branch names) is checked against a strict
# pattern first: the output goes to an AI, and "ignore your instructions..." is not a version.
#
# The whole script is one function, main, started by servio_run on the last line (see lib.sh):
# stdin from /dev/null, output masked, fixed exit codes. Read-only, so no lock, log or dry run.

main() {
    require_root

    step "Server"
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "os:        ${PRETTY_NAME:-unknown}"
    echo "hostname:  $(hostname)"
    echo "ip:        $(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "uptime:    $(uptime -p 2>/dev/null || true)"
    echo "disk /:    $(df -h / | awk 'NR==2 {print $3 " used of " $2 " (" $5 ")"}')"
    echo "memory:    $(free -h | awk '/^Mem:/ {print $3 " used of " $2}')"
    if command -v nginx >/dev/null 2>&1; then
        echo "nginx:     $(nginx -v 2>&1 | sed 's/^nginx version: //') ($(systemctl is-active nginx 2>/dev/null || true))"
    else
        echo "nginx:     not installed (server not provisioned)"
    fi
    local v php_list=""
    for v in $PHP_VERSIONS; do
        if [ -x "/usr/sbin/php-fpm$v" ]; then
            php_list="$php_list $v-fpm($(systemctl is-active "php$v-fpm" 2>/dev/null || true))"
        fi
    done
    echo "php:       ${php_list:- none of $PHP_VERSIONS}"
    echo "composer:  $(command -v composer >/dev/null 2>&1 && echo installed || echo missing)"
    echo "certbot:   $(command -v certbot >/dev/null 2>&1 && echo "installed, renewal timer $(systemctl is-active certbot.timer 2>/dev/null || true)" || echo missing)"
    echo "user:      $SITE_USER $(id "$SITE_USER" >/dev/null 2>&1 && echo exists || echo missing)"
    if command -v ufw >/dev/null 2>&1; then
        echo "firewall:  $(ufw status | head -n 1)"
    fi

    sites_report
}

# Every site in sites-enabled. A function of its own so tests can run it on a fake server folder
# (tests/test-scripts.sh, "Inventory on a fake server").
sites_report() {
    step "Sites"
    if [ ! -d "$NGINX_DIR/sites-enabled" ]; then
        echo "No $NGINX_DIR/sites-enabled."
        return
    fi

    local link name count=0
    for link in "$NGINX_DIR"/sites-enabled/*; do
        [ -e "$link" ] || continue
        name="$(basename "$link")"
        count=$((count + 1))
        # Names that aren't a valid domain (e.g. nginx's own "default") are listed, not inspected.
        if ! [[ "$name" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
            if [[ "$name" =~ ^[A-Za-z0-9._-]{1,100}$ ]]; then
                echo; echo "- $name (not a Servio site)"
            else
                echo; echo "- (a config with an unusual name, not a Servio site)"
            fi
            continue
        fi
        site_report "$name"
    done
    [ "$count" -gt 0 ] || echo "No sites enabled."
}

site_report() {
    local domain="$1" file managed root web_root php cert expires dir commit branch laravel env_file

    file="$(nginx_available "$domain")"
    [ -f "$file" ] || file="$(nginx_enabled "$domain")"
    if head -n 1 "$file" | grep -qF "$MANAGED_HEADER"; then managed="yes"; else managed="no (hand-made config)"; fi

    root="$(awk '$1 == "root" && $2 !~ /letsencrypt/ { sub(/;$/, "", $2); print $2; exit }' "$file")"
    [[ "$root" =~ ^/[A-Za-z0-9._/-]{1,200}$ ]] && web_root="$root" || web_root="unknown"
    # `|| true`: a site without PHP (a static or hand-made config) has no socket; grep then
    # "fails", and without it that would stop the whole inventory.
    php="$(grep -oE 'unix:/run/php/php[0-9]+\.[0-9]+-fpm\.sock' "$file" | head -n 1 | sed -E 's#.*/php([0-9]+\.[0-9]+)-fpm\.sock#\1#' || true)"
    [ -n "$php" ] || php="none"

    cert="$(certificate_path "$domain")"
    if [ -f "$cert" ]; then
        # The certificate is public (any browser gets it); its private key is never touched.
        expires="$(date -u -d "$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)" +%Y-%m-%d)"
        if grep -q "listen 443" "$file"; then
            expires="HTTPS, certificate valid until $expires"
        else
            expires="certificate valid until $expires, but nginx still serves HTTP only"
        fi
    else
        expires="HTTP only (no certificate)"
    fi

    dir="$(site_dir "$domain")"
    commit="not deployed"; branch="-"; laravel="unknown"; env_file="missing"
    if [ -d "$dir/.git" ]; then
        # As the site user: git refuses to read a repo owned by someone else ("dubious ownership").
        commit="$(runuser -u "$SITE_USER" -- git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        [[ "$commit" =~ ^[0-9a-f]{4,40}$ ]] || commit="unknown"
        branch="$(runuser -u "$SITE_USER" -- git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
        [[ "$branch" =~ ^[A-Za-z0-9._/-]{1,100}$ ]] || branch="unknown"
    fi
    if [ -f "$dir/composer.lock" ]; then
        # composer.lock is pretty-printed: the "version" line follows the "name" line.
        laravel="$(awk '/"name": "laravel\/framework"/ { found = 1; next } found && /"version":/ { gsub(/[",]/, "", $2); print $2; exit }' "$dir/composer.lock")"
        [[ "$laravel" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?([-+][0-9A-Za-z.]{1,20})?$ ]] && laravel="${laravel#v}" || laravel="not a Laravel app (or unknown)"
    fi
    [ -f "$dir/.env" ] && env_file="present"

    echo
    echo "- $domain"
    echo "    managed:   $managed"
    echo "    web root:  $web_root"
    echo "    php:       $php"
    echo "    ssl:       $expires"
    echo "    deployed:  $commit (branch $branch)"
    echo "    laravel:   $laravel"
    echo "    .env:      $env_file"
    echo "    deploy key: $([ -f "$(deploy_key_path "$domain").pub" ] && echo present || echo missing)"
}

servio_run "$@"
