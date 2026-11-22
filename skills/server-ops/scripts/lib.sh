#!/usr/bin/env bash
# lib.sh: shared helpers, sent to the server IN FRONT OF every script by run.sh.
#
# Ported from Servio (app/Recipes/Recipe.php, app/Rules/Domain.php, app/Services/Sites/NginxConfig.php).
# The server conventions are the same as Servio's, so a server set up by this plugin can be
# adopted by Servio later:
#   - one Linux user, "servio", owns every site and runs PHP-FPM
#   - a site lives in /home/servio/<domain>, its deploy key in /home/servio/.ssh/deploy_<domain>
#   - nginx configs start with "# Managed by Servio" (we never overwrite a config without it)
#
# Never run this file on its own. run.sh does: cat lib.sh <script> | ssh <host> 'sudo -n bash -s' -- <args>

#   set -e           stop at the first failing command (instead of carrying on broken)
#   set -u           using an unset variable is an error (a typo can't become "")
#   set -o pipefail  `a | b` fails if `a` fails (not only if `b` does)
#   DEBIAN_FRONTEND  apt never stops to ask a question (nobody is there to answer)
#   NEEDRESTART_MODE Ubuntu 22.04+ asks which services to restart after apt: auto
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

SITE_USER="servio"
SITES_HOME="/home/servio"
PHP_VERSIONS="8.3 8.4 8.5"
UBUNTU_VERSIONS="22.04 24.04"
ACME_ROOT="/var/www/letsencrypt"
MANAGED_HEADER="# Managed by Servio"

step() { echo; echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This must run as root (connected as: $(whoami)). Use run.sh, it adds sudo."
}

# ---------------------------------------------------------------------------------------------
# Input validation. Every value below ends up in a path, a file name or a config file, so it is
# checked again HERE, on the server, even though run.sh checked the characters already.
# bash's [[ =~ ]] uses POSIX extended regexes (no lookaheads), so Servio's PCRE patterns are
# split into a regex plus a few plain checks that mean the same thing.
# ---------------------------------------------------------------------------------------------

# A real domain: "example.com", "app.example.co.uk". Lowercase letters, digits, hyphens, dots.
# Same as Servio's Domain::PATTERN: labels of 1-63 chars not starting/ending with "-",
# a letters-only TLD, 4-253 chars in total.
validate_domain() {
    local d="$1"
    [ "${#d}" -ge 4 ] && [ "${#d}" -le 253 ] \
        && [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] \
        || die "Invalid domain '$d'. Use a lowercase domain like example.com (no http://, paths or spaces)."
}

# A relative folder inside the site: "public", "web", "dist/public". No "." or ".." parts.
validate_web_dir() {
    local w="$1"
    [[ "$w" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || die "Invalid web directory '$w'."
    case "/$w/" in */./*|*/../*) die "Invalid web directory '$w' (no . or .. parts)." ;; esac
}

# An allow-list, not "looks like a version": this string ends up in package names.
validate_php() {
    case " $PHP_VERSIONS " in
        *" $1 "*) ;;
        *) die "Unsupported PHP version '$1'. Use one of: $PHP_VERSIONS." ;;
    esac
}

# git@github.com:owner/repo.git  or  https://github.com/owner/repo(.git)
validate_repository() {
    local r="$1" path
    [[ "$r" =~ ^(git@[a-z0-9.-]+:|https://[a-z0-9.-]+(:[0-9]{1,5})?/)[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
        || die "Invalid repository '$r'. Use git@github.com:owner/repo.git or https://github.com/owner/repo."
    path="${r#*:}"; path="${path#//*/}"
    case "$path" in -*) die "Invalid repository '$r'." ;; esac
}

# A git branch: no spaces, no "..", no "//", can't start with "-" (it would read as an option).
validate_branch() {
    local b="$1"
    [[ "$b" =~ ^[A-Za-z0-9._/-]{1,100}$ ]] || die "Invalid branch '$b'."
    case "$b" in -*|/*|.*|*/|*.|*..*|*//*|*.lock) die "Invalid branch '$b'." ;; esac
}

# Let's Encrypt only issues for domains anyone on the internet can look up.
validate_public_domain() {
    case "${1##*.}" in
        test|example|invalid|localhost|local|internal|lan|home|corp)
            die "'$1' uses a private TLD and can't get a public certificate." ;;
    esac
}

site_dir() { echo "$SITES_HOME/$1"; }
deploy_key_path() { echo "$SITES_HOME/.ssh/deploy_$1"; }
nginx_available() { echo "/etc/nginx/sites-available/$1"; }
nginx_enabled() { echo "/etc/nginx/sites-enabled/$1"; }
certificate_path() { echo "/etc/letsencrypt/live/$1/fullchain.pem"; }

# Refuse to touch an nginx config a human (or another tool) wrote: only ours start with the header.
require_managed_config() {
    local file
    file="$(nginx_available "$1")"
    if [ -f "$file" ] && ! head -n 1 "$file" | grep -qF "$MANAGED_HEADER"; then
        die "$file exists but wasn't written by Servio (no '$MANAGED_HEADER' line). Not touching it."
    fi
}

# Read a site's web directory and PHP version back from its nginx config (the server is the
# source of truth: there is no database). Prints "<web_dir> <php_version>", both validated.
read_site_settings() {
    local domain="$1" file root web_dir php
    file="$(nginx_available "$domain")"
    [ -f "$file" ] || die "No nginx config for $domain at $file. Create the site first."
    require_managed_config "$domain"
    root="$(awk -v prefix="$SITES_HOME/$domain/" '$1 == "root" && index($2, prefix) == 1 { sub(/;$/, "", $2); print $2; exit }' "$file")"
    [ -n "$root" ] || die "Couldn't find the site's root line in $file."
    web_dir="${root#"$SITES_HOME/$domain/"}"
    php="$(grep -oE 'unix:/run/php/php[0-9]+\.[0-9]+-fpm\.sock' "$file" | head -n 1 | sed -E 's#.*/php([0-9]+\.[0-9]+)-fpm\.sock#\1#')"
    validate_web_dir "$web_dir"
    validate_php "$php"
    echo "$web_dir $php"
}

# ---------------------------------------------------------------------------------------------
# The nginx config, in ONE place (like Servio's NginxConfig). Two scripts write it:
# create-site.sh and issue-certificate.sh. With two copies, re-running create-site after SSL
# would silently switch a site back to plain HTTP.
#
#   http   one server block on port 80 that serves the site
#   https  port 80 only answers Let's Encrypt's checks and redirects, port 443 serves the site
# In BOTH, port 80 keeps /.well-known/acme-challenge/ reachable: Let's Encrypt checks over plain
# HTTP when the certificate is first issued AND at every renewal.
#
# Unquoted heredocs: $1/$2/$3 are filled in, nginx's own variables are escaped as \$uri.
# Safe because domain, web dir and PHP version were validated to plain characters.
# ---------------------------------------------------------------------------------------------

nginx_acme_block() {
    cat <<NGINX

    # Let's Encrypt fetches http://<domain>/.well-known/acme-challenge/<token> to check
    # that this server controls the domain.
    location ^~ /.well-known/acme-challenge/ {
        root $ACME_ROOT;
        default_type text/plain;
    }

NGINX
}

# $1 domain, $2 web root, $3 PHP version
nginx_site_block() {
    cat <<NGINX

    root $2;

    index index.php index.html;
    charset utf-8;
    client_max_body_size 64m;

    # Real files are served directly; everything else goes to Laravel's front controller.
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    # Only index.php is ever executed, never another .php file someone uploads.
    location ~ ^/index\.php(/|\$) {
        fastcgi_pass unix:/run/php/php$3-fpm.sock;
        fastcgi_split_path_info ^(.+\.php)(/.*)\$;
        include fastcgi_params;
        # \$realpath_root: the real folder behind a symlink (zero-downtime deploys later).
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;
        fastcgi_hide_header X-Powered-By;
    }

    # Hidden files (.env, .git) are never served. .well-known stays reachable.
    location ~ /\.(?!well-known).* {
        deny all;
    }

    access_log /var/log/nginx/$1-access.log;
    error_log  /var/log/nginx/$1-error.log;

NGINX
}

# $1 domain, $2 web root, $3 PHP version
nginx_http_config() {
    echo "$MANAGED_HEADER. Changes made by hand are overwritten when the site is updated."
    echo "server {"
    echo "    listen 80;"
    echo "    listen [::]:80;"
    echo "    server_name $1;"
    nginx_acme_block
    nginx_site_block "$1" "$2" "$3"
    echo "}"
}

# $1 domain, $2 web root, $3 PHP version
nginx_https_config() {
    local live="/etc/letsencrypt/live/$1"
    echo "$MANAGED_HEADER. Changes made by hand are overwritten when the site is updated."
    echo "# Port 80: Let's Encrypt's checks (first issue and renewals), and a redirect to HTTPS."
    echo "server {"
    echo "    listen 80;"
    echo "    listen [::]:80;"
    echo "    server_name $1;"
    nginx_acme_block
    echo "    location / {"
    echo "        return 301 https://\$host\$request_uri;"
    echo "    }"
    echo "}"
    echo
    echo "server {"
    # `listen ... ssl http2`: the syntax Ubuntu's nginx understands (1.18 on 22.04, 1.24 on 24.04).
    echo "    listen 443 ssl http2;"
    echo "    listen [::]:443 ssl http2;"
    echo "    server_name $1;"
    echo
    echo "    # Made by certbot. The private key never leaves this server."
    echo "    ssl_certificate     $live/fullchain.pem;"
    echo "    ssl_certificate_key $live/privkey.pem;"
    echo "    ssl_protocols TLSv1.2 TLSv1.3;"
    nginx_site_block "$1" "$2" "$3"
    echo "}"
}

# The version that matches the server: HTTPS once the site has a certificate, so re-running
# the setup never switches an HTTPS site back to plain HTTP.
nginx_current_config() {
    if [ -f "$(certificate_path "$1")" ]; then
        nginx_https_config "$@"
    else
        nginx_http_config "$@"
    fi
}

# Put a new config file in place, test it, and undo it if nginx rejects it, so one site's
# mistake never takes nginx (and every other site) down. $1 domain, $2 the new config file.
apply_nginx_config() {
    local available enabled
    available="$(nginx_available "$1")"
    enabled="$(nginx_enabled "$1")"
    # Keep the old config (a re-run) so a broken new one can be undone.
    if [ -f "$available" ]; then cp "$available" "$available.previous"; fi
    cp "$2" "$available"
    ln -sfn "$available" "$enabled"

    if ! nginx -t; then
        echo "nginx rejected the config. Undoing it, so the other sites keep working." >&2
        if [ -f "$available.previous" ]; then
            mv "$available.previous" "$available"
        else
            rm -f "$enabled" "$available"
        fi
        exit 1
    fi
    rm -f "$available.previous"
    # reload, not restart: nginx re-reads its configs without dropping open connections.
    systemctl reload nginx
}
