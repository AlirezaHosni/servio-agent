#!/usr/bin/env bash
# inventory.sh: what runs on this server. READ-ONLY: changes nothing.
#
#   bash run.sh <host> inventory.sh
#
# Prints the server (OS, nginx, PHP versions, firewall) and, for every site in
# /etc/nginx/sites-enabled: web root, PHP version, HTTPS certificate expiry, deployed git
# commit and branch, Laravel version (from composer.lock) and whether a .env file EXISTS.
#
# Ends with "Problems" (item 3): certificates expiring within 14 days, a PHP pool that isn't
# running, a missing site user, a Laravel site without .env, sites never deployed, failed services,
# a disk 90%+ full. For the details and a likely cause: health.sh.
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
    echo "supervisor: $(command -v supervisord >/dev/null 2>&1 && systemctl is-active supervisor 2>/dev/null || echo missing)"
    if command -v ufw >/dev/null 2>&1; then
        echo "firewall:  $(ufw status | head -n 1)"
    fi

    local failed disk_pct
    failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}'         | grep -E '^[A-Za-z0-9@._:-]{1,100}$' | tr '
' ' ' || true)"
    [ -z "$failed" ] || problem "server: failed services: ${failed% }"
    disk_pct="$(df -P / | awk 'NR==2 {sub(/%/, "", $5); print $5}')"
    [[ "$disk_pct" =~ ^[0-9]+$ ]] && [ "$disk_pct" -ge 90 ] && problem "server: disk / is $disk_pct% full"

    sites_report
    problems_report
}

# Problems found along the way, printed together at the end (item 3).
PROBLEMS=()
problem() { PROBLEMS+=("$1"); }
problems_report() {
    step "Problems"
    if [ "${#PROBLEMS[@]}" -eq 0 ]; then
        echo "None found."
    else
        printf -- '- %s
' "${PROBLEMS[@]}"
        echo "(details and likely cause: health.sh [domain])"
    fi
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
    local domain="$1" file managed root web_root php cert expires days dir commit branch laravel env_file user user_state pool

    file="$(nginx_available "$domain")"
    [ -f "$file" ] || file="$(nginx_enabled "$domain")"
    if head -n 1 "$file" | grep -qF "$MANAGED_HEADER"; then managed="yes"; else managed="no (hand-made config)"; fi

    root="$(awk '$1 == "root" && $2 !~ /letsencrypt/ { sub(/;$/, "", $2); print $2; exit }' "$file")"
    [[ "$root" =~ ^/[A-Za-z0-9._/-]{1,200}$ ]] && web_root="$root" || web_root="unknown"
    # `|| true`: a site without PHP (a static or hand-made config) has no socket; grep then
    # "fails", and without it that would stop the whole inventory.
    # The socket is the site's own pool (php8.4-fpm-<user>.sock) or, in a hand-made config, a
    # shared one (php8.4-fpm.sock).
    php="$(grep -oE 'unix:/run/php/php[0-9]+\.[0-9]+-fpm(-[a-z0-9_]+)?\.sock' "$file" | head -n 1 | sed -E 's#.*/php([0-9]+\.[0-9]+)-fpm.*#\1#' || true)"
    [ -n "$php" ] || php="none"

    # The site's own Linux user and PHP-FPM pool (decision 6).
    user="$(site_user "$domain")"
    if id "$user" >/dev/null 2>&1; then user_state="$user"; else user_state="none (no site user $user)"; fi
    pool="none"
    if [ "$php" != "none" ] && [ -f "$(pool_file "$domain" "$php")" ]; then
        if [ -S "$(pool_socket "$domain" "$php")" ]; then pool="PHP $php, up"; else pool="PHP $php, configured but NOT running"; fi
    fi

    cert="$(certificate_path "$domain")"
    if [ -f "$cert" ]; then
        # The certificate is public (any browser gets it); its private key is never touched.
        expires="$(date -u -d "$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)" +%Y-%m-%d)"
        days="$(( ($(date -u -d "$expires" +%s) - $(date -u +%s)) / 86400 ))"
        if [ "$days" -lt 0 ]; then problem "$domain: certificate EXPIRED on $expires"
        elif [ "$days" -lt 14 ]; then problem "$domain: certificate expires in $days days ($expires): is renewal working?"; fi
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
    # Release layout (v0.5): what `current` points at, and its .servio-release.
    local release live
    release="$(current_release "$domain")"
    live="$(site_current "$domain")"
    if [ -n "$release" ] && [ "$release" != "00000000-000000-placeholder" ]; then
        read_release "$(site_releases "$domain")/$release"
        commit="${REL_COMMIT:0:7}"; [ -n "$commit" ] || commit="unknown"
        branch="${REL_BRANCH:-unknown}, release $release"
    fi
    if [ -f "$live/composer.lock" ]; then
        # composer.lock is pretty-printed: the "version" line follows the "name" line.
        laravel="$(awk '/"name": "laravel\/framework"/ { found = 1; next } found && /"version":/ { gsub(/[",]/, "", $2); print $2; exit }' "$live/composer.lock")"
        [[ "$laravel" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?([-+][0-9A-Za-z.]{1,20})?$ ]] && laravel="${laravel#v}" || laravel="not a Laravel app (or unknown)"
    fi
    [ -f "$(site_env "$domain")" ] && env_file="present"
    is_in_place_site "$domain" && problem "$domain: an old in-place checkout (v0.3): recreate it to use release folders"

    if [ "$managed" = "yes" ]; then
        [ "$user_state" = "$user" ] || problem "$domain: no site user $user (made before v0.3, or half deleted?)"
        [[ "$pool" != *"NOT running"* ]] || problem "$domain: its PHP $php pool is configured but NOT running"
        [ "$commit" != "not deployed" ] || problem "$domain: never deployed"
    fi
    [[ "$laravel" =~ ^[0-9] && "$env_file" = "missing" ]] && problem "$domain: a Laravel app without .env"

    echo
    echo "- $domain"
    echo "    managed:   $managed"
    echo "    web root:  $web_root"
    echo "    user:      $user_state"
    echo "    php:       $php (pool: $pool)"
    echo "    ssl:       $expires"
    echo "    deployed:  $commit (branch $branch)"
    echo "    laravel:   $laravel"
    echo "    .env:      $env_file"
    echo "    deploy key: $([ -f "$(deploy_key_path "$domain").pub" ] && echo present || echo missing)"
    # Extra names, www redirect and suspension, from the config's servio-* lines (domains.sh, suspend-site.sh).
    read_site_meta "$domain"
    [ -z "$SITE_ALIASES" ] || echo "    also:      $SITE_ALIASES"
    [ -z "$SITE_WWW" ] || echo "    www:       $SITE_WWW -> $domain"
    if [ "$SITE_SUSPENDED" -eq 1 ]; then echo "    SUSPENDED: visitors see the 503 page (suspend-site.sh resume)"; problem "$domain: suspended"; fi
}

servio_run "$@"
