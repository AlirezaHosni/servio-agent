#!/usr/bin/env bash
# lib.sh: shared helpers, sent to the server IN FRONT OF every script by run.sh.
#
# Ported from Servio (app/Recipes/Recipe.php, app/Rules/Domain.php, app/Services/Sites/NginxConfig.php).
# The server conventions are the same as Servio's, so a server set up by this plugin can be
# adopted by Servio later:
#   - every site has its OWN Linux user (decision 6, "website isolation"), named from the domain:
#     shop.example.com -> s_shopexamplecom_3f2a1b (see site_user)
#   - a site lives in /home/<user>/<domain>, its deploy key in /home/<user>/.ssh/deploy_key
#   - every site has its own PHP-FPM pool running as its user, with its own socket
#   - nginx configs start with "# Managed by Servio" (we never overwrite a config without it)
#
# Never run this file on its own. run.sh sends: a few SERVIO_* lines, this file, the script.
# Every script ends with `servio_run "$@"`, which is defined at the bottom of this file.

#   set -E           the ERR trap also fires inside functions and $(...)
#   set -e           stop at the first failing command (instead of carrying on broken)
#   set -u           using an unset variable is an error (a typo can't become "")
#   set -o pipefail  `a | b` fails if `a` fails (not only if `b` does)
set -Eeuo pipefail

# Never wait for input (item 44). Nobody can answer a question or press "q" in a pager:
# with `ssh -T` a waiting command would just hang until a timeout.
#   DEBIAN_FRONTEND  apt never asks a question     NEEDRESTART_MODE  restart services automatically
#   *PAGER=cat       systemctl, git, journalctl print instead of opening a pager
#   GIT_TERMINAL_PROMPT=0  git fails instead of asking for a username
#   COMPOSER_NO_INTERACTION=1  composer never asks
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
export PAGER=cat SYSTEMD_PAGER=cat GIT_PAGER=cat SYSTEMD_COLORS=0
export GIT_TERMINAL_PROMPT=0 COMPOSER_NO_INTERACTION=1

# Set by run.sh in the lines above this file. Defaults are for tests that load lib.sh directly.
: "${SERVIO_SCRIPT_NAME:=unknown}" "${SERVIO_SCRIPT_SHA256:=unknown}"
: "${SERVIO_PLUGIN_VERSION:=unknown}" "${SERVIO_APPROVAL:=fresh}" "${SERVIO_JOB_MODE:=follow}"

HOME_BASE="/home"                # site users' home folders: /home/<user>
PHP_ETC_DIR="/etc/php"           # PHP's config: /etc/php/<version>/fpm/pool.d/<user>.conf
PHP_VERSIONS="8.3 8.4 8.5"
UBUNTU_VERSIONS="22.04 24.04"
ACME_ROOT="/var/www/letsencrypt"
# Where nginx and certbot keep their files (variables so tests can point them at a fake server).
NGINX_DIR="/etc/nginx"
LETSENCRYPT_DIR="/etc/letsencrypt"
MANAGED_HEADER="# Managed by Servio"
ACTION_LOG="/var/log/servio-agent.log"
LOGROTATE_FILE="/etc/logrotate.d/servio-agent"
LOCK_DIR="/run/lock/servio-agent"

# ---------------------------------------------------------------------------------------------
# Exit codes (item 50). The same number always means the same thing, so Claude can explain a
# failure correctly without guessing from the text.
#   0 done
#   1 failed            a command failed (the message says which one)
#   2 wrong input       a domain, branch, version... didn't pass its check; nothing was changed
#   3 wrong state       the server isn't ready for this (not provisioned, site missing...)
#   4 refused           a confirmation was missing or wrong, or a safety rule said no
#   5 missing tool      something the script needs isn't installed
# run.sh adds 6: could not connect to the server (ssh failed, or the host key is unknown/changed).
# ---------------------------------------------------------------------------------------------
EXIT_FAILED=1 EXIT_INPUT=2 EXIT_STATE=3 EXIT_REFUSED=4 EXIT_MISSING=5

step() { echo; echo "==> $*"; }
die()         { echo "ERROR: $*" >&2; exit "$EXIT_FAILED"; }
die_input()   { echo "ERROR (wrong input): $*" >&2; exit "$EXIT_INPUT"; }
die_state()   { echo "ERROR (server not ready): $*" >&2; exit "$EXIT_STATE"; }
die_refused() { echo "REFUSED: $*" >&2; exit "$EXIT_REFUSED"; }
die_missing() { echo "ERROR (missing tool): $*" >&2; exit "$EXIT_MISSING"; }

# Any command that fails without our own die_*: say which one, and exit 1 (never a code that
# would look like "wrong input" just because a program happened to return 2).
on_error() {
    echo "ERROR: a command failed (exit $1): $2" >&2
    exit "$EXIT_FAILED"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die_state "This must run as root (connected as: $(whoami)). Use run.sh, it adds sudo."
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die_missing "'$1' isn't installed on this server${2:+ ($2)}."
}

# ---------------------------------------------------------------------------------------------
# Dry run (item 48). `run.sh <host> <script> --dry-run ...` runs every check but changes nothing:
# each change goes through run() or write_file(), which only PRINT what they would do. So the
# "what will change" you approve comes from the script itself, not from Claude's summary.
# ---------------------------------------------------------------------------------------------
DRY_RUN=0
dry_run() { [ "$DRY_RUN" -eq 1 ]; }

# run <command> [args...]: run it, or print it in a dry run. Only for plain commands: anything
# with a pipe or a redirect is written as a function or uses write_file.
run() {
    if dry_run; then
        printf '[dry-run] would run:'
        printf ' %q' "$@"
        echo
        return 0
    fi
    "$@"
}

# ---------------------------------------------------------------------------------------------
# Safe file changes (item 51). write_file <path> <mode> <owner:group>, content on stdin:
#   - written to a temporary file in the same folder, then moved into place in one step, so the
#     file is never half-written (a reader sees the old or the new version, nothing in between)
#   - the old version is kept as <file>.bak-<time> (the 3 newest are kept), so a change can be
#     undone by hand too
#   - never writes through a symlink (it could point anywhere, e.g. /etc/shadow)
#   - in a dry run: prints whether it would create the file, change it (with a diff) or leave it
# ---------------------------------------------------------------------------------------------
write_file() {
    local path="$1" mode="$2" owner="$3" dir tmp
    [ ! -L "$path" ] || die_refused "$path is a symlink; not writing through it."
    dir="$(dirname "$path")"

    if dry_run; then
        tmp="$(mktemp)"
        cat > "$tmp"
        if [ -f "$path" ] && cmp -s "$path" "$tmp"; then
            echo "[dry-run] $path: unchanged"
        elif [ -f "$path" ]; then
            echo "[dry-run] would change $path:"
            diff -u "$path" "$tmp" | sed 's/^/    /' || true
        else
            echo "[dry-run] would create $path ($(wc -l < "$tmp") lines, mode $mode, owner $owner)"
        fi
        rm -f "$tmp"
        return 0
    fi

    [ -d "$dir" ] || die_state "Folder $dir doesn't exist."
    tmp="$(mktemp "$dir/.servio-tmp.XXXXXX")"
    cat > "$tmp"
    if [ -f "$path" ] && cmp -s "$path" "$tmp"; then
        rm -f "$tmp"            # nothing to do: same content
        return 0
    fi
    if [ -f "$path" ]; then
        cp -p "$path" "$path.bak-$(date +%Y%m%d%H%M%S)"
        prune_backups "$path" 3
    fi
    chmod "$mode" "$tmp"
    chown "$owner" "$tmp"
    mv -fT "$tmp" "$path"
}

# Keep only the newest $2 "<file>.bak-*" copies.
prune_backups() {
    local old
    # The names sort by time (YYYYmmddHHMMSS), so the oldest come first.
    while IFS= read -r old; do
        rm -f -- "$old"
    done < <(ls -1 "$1".bak-* 2>/dev/null | sort | head -n -"$2")
}

# ---------------------------------------------------------------------------------------------
# Four results, never a fake pass (item 49). Checks report PASS, WARN, FAIL or NOT ASSESSED;
# a check that couldn't run (tool missing, no permission) is NOT ASSESSED, never PASS.
# ---------------------------------------------------------------------------------------------
CHECK_PASS=0 CHECK_WARN=0 CHECK_FAIL=0 CHECK_NA=0
check_pass() { CHECK_PASS=$((CHECK_PASS + 1)); echo "  PASS          $1${2:+: $2}"; }
check_warn() { CHECK_WARN=$((CHECK_WARN + 1)); echo "  WARN          $1${2:+: $2}"; }
check_fail() { CHECK_FAIL=$((CHECK_FAIL + 1)); echo "  FAIL          $1${2:+: $2}"; }
check_na()   { CHECK_NA=$((CHECK_NA + 1));     echo "  NOT ASSESSED  $1${2:+: $2}"; }

# Print the summary line; return 1 if anything FAILED (the caller decides what that means).
check_summary() {
    echo "  Result: $CHECK_PASS passed, $CHECK_WARN warnings, $CHECK_FAIL failed, $CHECK_NA not assessed"
    [ "$CHECK_FAIL" -eq 0 ]
}

# ---------------------------------------------------------------------------------------------
# Check the result, not the exit code (item 52): ask nginx ON THIS SERVER for the site, the way a
# visitor would (curl --resolve sends the request to 127.0.0.1 but with the real domain name,
# so nginx picks the right site and HTTPS checks the real certificate).
# site_status <domain> <http|https> sets SITE_STATUS (the HTTP status code, "000" = no answer
# or, for https, a certificate that doesn't match) and SITE_BODY (the start of the page).
# Globals, not "echo and capture": $(...) runs in a subshell and would lose SITE_BODY.
# ---------------------------------------------------------------------------------------------
SITE_STATUS="" SITE_BODY=""
site_status() {
    local domain="$1" scheme="$2" port=80 body
    [ "$scheme" = "https" ] && port=443
    body="$(mktemp)"
    SITE_STATUS="$(curl -sS -o "$body" -w '%{http_code}' --max-time 15 \
        --resolve "$domain:$port:127.0.0.1" "$scheme://$domain/" 2>/dev/null || true)"
    [ -n "$SITE_STATUS" ] || SITE_STATUS="000"
    SITE_BODY="$(head -c 20000 "$body")"
    rm -f "$body"
}

# ---------------------------------------------------------------------------------------------
# Secrets masked in everything the server prints (item 68), as a backstop: the scripts never
# print secrets on purpose, but a program's error message might (a database URL with a password,
# a token in a git error). Runs ON THE SERVER, so nothing secret ever travels to the laptop.
# perl is part of every Ubuntu install (perl-base is "essential").
#   - private key blocks                    -> one line "[private key hidden]"
#   - user:password@ in URLs                -> user:***@
#   - Bearer tokens, password=/token=/...   -> ***
#   - known token shapes (sk-, ghp_, AKIA, JWT, Slack)
#   - long random-looking strings (32+ chars with lower case, upper case AND digits; a "/" ends
#     a string, so file paths are never hidden)
# Public SSH keys (SERVIO_DEPLOY_KEY=..., "ssh-ed25519 AAAA...") are meant to be shown: kept.
# Hex strings (commit ids, SHA-256) have no upper case, so they are kept too.
# ---------------------------------------------------------------------------------------------
MASK_PERL='
BEGIN { $| = 1 }
if (/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/) { $in_key = 1; print "[private key hidden]\n"; next }
if ($in_key) { $in_key = 0 if /-----END [A-Z0-9 ]*PRIVATE KEY-----/; next }
if (/^SERVIO_DEPLOY_KEY=/ || /^\s*(ssh-(ed25519|rsa|dss)|ecdsa-sha2-\S+) [A-Za-z0-9+\/=]+/) { print; next }
s{(://[^\s:/@]+:)[^\s@/]+@}{$1***@}g;
s{\b(Bearer\s+)[A-Za-z0-9._~+/=-]+}{$1***}gi;
s{\b([A-Za-z0-9_.-]*(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|app_key)[A-Za-z0-9_.-]*\s*[=:]\s*)("[^"]*"|\x27[^\x27]*\x27|\S+)}{$1***}gi;
s{\b(sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})\b}{***}g;
s{\b(eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})}{***}g;
s{(?<![A-Za-z0-9+_-])([A-Za-z0-9+_-]{32,}={0,2})(?![A-Za-z0-9+_=-])}{ my $t = $1; ($t =~ /[a-z]/ && $t =~ /[A-Z]/ && $t =~ /[0-9]/) ? "***" : $t }ge;
print;
'
mask_output() { perl -ne "$MASK_PERL"; }

# ---------------------------------------------------------------------------------------------
# Exit hooks: cleanups that must run however the script ends (temporary files, the action log).
# One EXIT trap runs them all, so scripts never overwrite each other's `trap ... EXIT`.
# ---------------------------------------------------------------------------------------------
EXIT_HOOKS=()
SERVIO_RC=0
add_exit_hook() { EXIT_HOOKS+=("$1"); }
run_exit_hooks() {
    SERVIO_RC=$?
    local hook
    for hook in "${EXIT_HOOKS[@]+"${EXIT_HOOKS[@]}"}"; do
        eval "$hook" || true
    done
}

# ---------------------------------------------------------------------------------------------
# Action log on the server (item 40). Every CHANGE script calls begin_change at its start; when
# it ends, one line is appended to /var/log/servio-agent.log:
#   time, who (the SSH user behind sudo), "via servio-agent", plugin version, script, the
#   SHA-256 of exactly what ran, fresh OK or remembered approval, site, arguments, result, time.
# Dry runs change nothing, so they aren't logged. The log is rotated weekly, kept a year.
# ---------------------------------------------------------------------------------------------
LOG_SITE="-" LOG_ARGS="" LOG_START=0
begin_change() {
    LOG_SITE="$1"; shift
    LOG_ARGS="$(printf '%q ' "$@")"
    LOG_START="$(date +%s)"
    dry_run || add_exit_hook write_action_log
}

write_action_log() {
    local result="ok"
    case "$SERVIO_RC" in
        0) result="ok" ;; 2) result="wrong-input" ;; 3) result="server-not-ready" ;;
        4) result="refused" ;; 5) result="missing-tool" ;; *) result="failed" ;;
    esac
    if [ ! -f "$ACTION_LOG" ]; then
        install -m 640 -o root -g adm /dev/null "$ACTION_LOG"
    fi
    if [ ! -f "$LOGROTATE_FILE" ]; then
        printf '%s\n' "$ACTION_LOG {" "    weekly" "    rotate 52" "    compress" "    missingok" \
            "    notifempty" "    create 0640 root adm" "}" > "$LOGROTATE_FILE"
    fi
    printf '%s user=%s via=servio-agent version=%s script=%s sha256=%s approval=%s site=%s args=[%s] result=%s exit=%s duration=%ss\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SUDO_USER:-root}" "$SERVIO_PLUGIN_VERSION" \
        "$SERVIO_SCRIPT_NAME" "$SERVIO_SCRIPT_SHA256" "$SERVIO_APPROVAL" "$LOG_SITE" \
        "${LOG_ARGS% }" "$result" "$SERVIO_RC" "$(( $(date +%s) - LOG_START ))" >> "$ACTION_LOG"
}

# ---------------------------------------------------------------------------------------------
# One change at a time per site (item 69). flock on /run/lock/servio-agent/<domain>.lock: a
# second change on the same site stops at once and says who is running the first one. The lock
# belongs to this process, so it is released however the script ends (even if it's killed).
# ---------------------------------------------------------------------------------------------
lock_site() {
    local domain="$1" file="$LOCK_DIR/$1.lock"
    if dry_run; then
        if [ -f "$file" ] && ! flock -n "$file" true 2>/dev/null; then
            echo "[dry-run] note: another change is running on $domain right now ($(cat "$file"))."
        fi
        return 0
    fi
    install -d -m 700 "$LOCK_DIR"
    # Append mode: opening the file must not erase the current holder's note before we hold it.
    exec 9>>"$file"
    if ! flock -n 9; then
        die_state "Another change is running on $domain ($(cat "$file")). Wait for it to finish, then try again."
    fi
    printf '%s by %s since %s\n' "$SERVIO_SCRIPT_NAME" "${SUDO_USER:-root}" "$(date -u +%H:%M:%SZ)" > "$file"
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
        || die_input "Invalid domain '$d'. Use a lowercase domain like example.com (no http://, paths or spaces)."
}

# A relative folder inside the site: "public", "web", "dist/public". No "." or ".." parts.
validate_web_dir() {
    local w="$1"
    [[ "$w" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || die_input "Invalid web directory '$w'."
    case "/$w/" in */./*|*/../*) die_input "Invalid web directory '$w' (no . or .. parts)." ;; esac
}

# An allow-list, not "looks like a version": this string ends up in package names.
validate_php() {
    case " $PHP_VERSIONS " in
        *" $1 "*) ;;
        *) die_input "Unsupported PHP version '$1'. Use one of: $PHP_VERSIONS." ;;
    esac
}

# git@github.com:owner/repo.git  or  https://github.com/owner/repo(.git)
validate_repository() {
    local r="$1" path
    [[ "$r" =~ ^(git@[a-z0-9.-]+:|https://[a-z0-9.-]+(:[0-9]{1,5})?/)[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] \
        || die_input "Invalid repository '$r'. Use git@github.com:owner/repo.git or https://github.com/owner/repo."
    path="${r#*:}"; path="${path#//*/}"
    case "$path" in -*) die_input "Invalid repository '$r'." ;; esac
}

# A git branch: no spaces, no "..", no "//", can't start with "-" (it would read as an option).
validate_branch() {
    local b="$1"
    [[ "$b" =~ ^[A-Za-z0-9._/-]{1,100}$ ]] || die_input "Invalid branch '$b'."
    case "$b" in -*|/*|.*|*/|*.|*..*|*//*|*.lock) die_input "Invalid branch '$b'." ;; esac
}

# Let's Encrypt only issues for domains anyone on the internet can look up.
validate_public_domain() {
    case "${1##*.}" in
        test|example|invalid|localhost|local|internal|lan|home|corp)
            die_input "'$1' uses a private TLD and can't get a public certificate." ;;
    esac
}

# ---------------------------------------------------------------------------------------------
# The site layout (decision 6): one Linux user per site, so a hacked site can't read the others'
# files or .env. The user's name comes FROM THE DOMAIN, always the same way, so every script can
# work it out without a database:
#   s_  + the domain's letters and digits (first 16)  + _ + the first 6 hex of its SHA-256
#   shop.example.com  ->  s_shopexamplecom_3f2a1b       (the hash keeps similar domains apart:
#   shop-example.com  ->  s_shopexamplecom_9c0d4e        same letters, different user)
# Max 2 + 16 + 1 + 6 = 25 characters (Linux allows 32), always starts with a letter.
# ---------------------------------------------------------------------------------------------
SITE_USER_PATTERN='^s_[a-z0-9]{0,16}_[0-9a-f]{6}$'
site_user() {
    local slug hash
    slug="$(printf '%s' "$1" | tr -cd 'a-z0-9' | cut -c1-16)"
    hash="$(printf '%s' "$1" | sha256sum | cut -c1-6)"
    echo "s_${slug}_${hash}"
}
site_home() { echo "$HOME_BASE/$(site_user "$1")"; }
site_dir() { echo "$(site_home "$1")/$1"; }
deploy_key_path() { echo "$(site_home "$1")/.ssh/deploy_key"; }
# The site's PHP-FPM pool ($1 domain, $2 PHP version): its config file and its socket.
pool_file() { echo "$PHP_ETC_DIR/$2/fpm/pool.d/$(site_user "$1").conf"; }
pool_socket() { echo "/run/php/php$2-fpm-$(site_user "$1").sock"; }
nginx_available() { echo "$NGINX_DIR/sites-available/$1"; }
nginx_enabled() { echo "$NGINX_DIR/sites-enabled/$1"; }
certificate_path() { echo "$LETSENCRYPT_DIR/live/$1/fullchain.pem"; }

# Refuse to touch an nginx config a human (or another tool) wrote: only ours start with the header.
require_managed_config() {
    local file
    file="$(nginx_available "$1")"
    if [ -f "$file" ] && ! head -n 1 "$file" | grep -qF "$MANAGED_HEADER"; then
        die_refused "$file exists but wasn't written by Servio (no '$MANAGED_HEADER' line). Not touching it."
    fi
}

# Read a site's web directory and PHP version back from its nginx config (the server is the
# source of truth: there is no database). Sets SITE_WEB_DIR and SITE_PHP, both validated.
# Not "echo and capture": a die inside $(...) would only end the subshell and lose its exit code.
SITE_WEB_DIR="" SITE_PHP=""
read_site_settings() {
    local domain="$1" file root dir
    file="$(nginx_available "$domain")"
    dir="$(site_dir "$domain")"
    [ -f "$file" ] || die_state "No nginx config for $domain at $file. Create the site first."
    require_managed_config "$domain"
    root="$(awk -v prefix="$dir/" '$1 == "root" && index($2, prefix) == 1 { sub(/;$/, "", $2); print $2; exit }' "$file")"
    [ -n "$root" ] || die_state "Couldn't find the site's root line in $file (or it isn't in $dir)."
    SITE_WEB_DIR="${root#"$dir/"}"
    # The site's own pool socket: /run/php/php<version>-fpm-<user>.sock
    SITE_PHP="$(grep -oE 'unix:/run/php/php[0-9]+\.[0-9]+-fpm-[a-z0-9_]+\.sock' "$file" | head -n 1 | sed -E 's#.*/php([0-9]+\.[0-9]+)-fpm-.*#\1#' || true)"
    validate_web_dir "$SITE_WEB_DIR"
    validate_php "$SITE_PHP"
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
        fastcgi_pass unix:$(pool_socket "$1" "$3");
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
    local live="$LETSENCRYPT_DIR/live/$1"
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

# Put a new config in place, test it, and undo it if nginx rejects it, so one site's mistake
# never takes nginx (and every other site) down. $1 domain, $2 the new config file.
apply_nginx_config() {
    local available enabled old
    available="$(nginx_available "$1")"
    enabled="$(nginx_enabled "$1")"

    if dry_run; then
        write_file "$available" 644 root:root < "$2"
        echo "[dry-run] would enable it, test it with nginx -t (undone if nginx rejects it) and reload nginx"
        return 0
    fi

    # Keep the old config (a re-run) so a broken new one can be undone.
    old=""
    if [ -f "$available" ]; then
        old="$(mktemp)"
        cp -p "$available" "$old"
    fi
    write_file "$available" 644 root:root < "$2"
    ln -sfn "$available" "$enabled"

    if ! nginx -t 2>&1; then
        echo "nginx rejected the config. Undoing it, so the other sites keep working." >&2
        if [ -n "$old" ]; then
            cp -p "$old" "$available"
            rm -f "$old"
        else
            rm -f "$enabled" "$available"
        fi
        die "nginx -t failed for the new $1 config (the previous state is back)."
    fi
    [ -z "$old" ] || rm -f "$old"
    # reload, not restart: nginx re-reads its configs without dropping open connections.
    systemctl reload nginx
}

# ---------------------------------------------------------------------------------------------
# The site's PHP-FPM pool, in ONE place (like the nginx config). $1 domain, $2 PHP version.
#   - runs as the site's own user and group: PHP can read and write the site's files, and
#     nothing of any other site
#   - its own socket; nginx (www-data) may talk to it (listen.owner / listen.group)
#   - pm = ondemand: no PHP process runs until a request comes, and idle ones stop after 10 s,
#     so many small sites cost almost no memory. pm.max_children caps it (sizing: v0.6)
#   - its own temp folder for uploads, temp files and sessions, never a shared /tmp
#   - security.limit_extensions: only .php files are ever executed
# ---------------------------------------------------------------------------------------------
php_pool_config() {
    local user home
    user="$(site_user "$1")"
    home="$(site_home "$1")"
    cat <<POOL
; $MANAGED_HEADER. The PHP-FPM pool of $1. Changes made by hand are overwritten.
[$user]
user = $user
group = $user
listen = $(pool_socket "$1" "$2")
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 10s
pm.max_requests = 500

php_admin_value[upload_tmp_dir] = $home/tmp
php_admin_value[sys_temp_dir] = $home/tmp
php_admin_value[session.save_path] = $home/tmp
security.limit_extensions = .php
POOL
}

# Put the pool in place, test it with php-fpm -t, undo it if PHP rejects it, then reload that
# PHP version (a reload starts the new pool without stopping the other sites' requests).
apply_pool_config() {
    local domain="$1" php="$2" file new old=""
    file="$(pool_file "$domain" "$php")"
    new="$(mktemp)"
    php_pool_config "$domain" "$php" > "$new"
    if dry_run; then
        write_file "$file" 644 root:root < "$new"
        echo "[dry-run] would test it with php-fpm$php -t (undone if PHP rejects it) and reload PHP $php-FPM"
        rm -f "$new"
        return 0
    fi
    if [ -f "$file" ]; then old="$(mktemp)"; cp -p "$file" "$old"; fi
    write_file "$file" 644 root:root < "$new"
    rm -f "$new"
    if ! "php-fpm$php" -t 2>&1; then
        echo "PHP-FPM rejected the pool. Undoing it, so the other sites keep working." >&2
        if [ -n "$old" ]; then cp -p "$old" "$file"; rm -f "$old"; else rm -f "$file"; fi
        die "php-fpm$php -t failed for $domain's pool (the previous state is back)."
    fi
    [ -z "$old" ] || rm -f "$old"
    systemctl reload "php$php-fpm"
}

# PHP versions that have a pool file for this site (normally exactly one).
site_pool_versions() {
    local v found=""
    for v in $PHP_VERSIONS; do
        [ -f "$(pool_file "$1" "$v")" ] && found="$found $v"
    done
    echo "${found# }"
}

# ---------------------------------------------------------------------------------------------
# Long jobs that survive a dropped connection (item 45).
#
# provision-server, deploy-site and issue-certificate can take minutes. If they ran inside the
# SSH session, a laptop going to sleep would kill them halfway. So run.sh sends them as a JOB:
#   servio_launch_job <args> <<'SERVIO_JOB_<random>'
#   ...the SERVIO_* lines, lib.sh and the script...
#   SERVIO_JOB_<random>
# servio_launch_job saves that to /var/lib/servio-agent/jobs/<id>/script.sh and starts it with
# systemd-run, as its own systemd unit (servio-job-<id>): it keeps running whatever happens to
# the SSH connection. Its output goes to jobs/<id>/output.log, its exit code to jobs/<id>/exit-code.
#   follow  (default) print the output live until the job ends, then exit with its exit code
#   detach  print the job id and return at once; read it later with job-status.sh
# Without systemd (e.g. a test container) the job runs in the foreground, and says so.
# ---------------------------------------------------------------------------------------------
JOBS_DIR="/var/lib/servio-agent/jobs"
JOB_ID_PATTERN='^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$'

valid_job_id() { [[ "$1" =~ $JOB_ID_PATTERN ]]; }
has_systemd() { [ -d /run/systemd/system ]; }

# job_state <id>: running | finished | stopped (no exit code and no longer running) | unknown
job_state() {
    local dir="$JOBS_DIR/$1"
    if [ ! -d "$dir" ]; then echo unknown
    elif [ -f "$dir/exit-code" ]; then echo finished
    elif systemctl is-active --quiet "servio-job-$1" 2>/dev/null; then echo running
    elif [ -f "$dir/foreground" ] && [ -f "$dir/pid" ] && kill -0 "$(cat "$dir/pid")" 2>/dev/null; then echo running
    else echo stopped
    fi
}

# job_output <id> <offset>: print the output from byte <offset> on, and set JOB_OFFSET to the end.
# Progress bars redraw one line with \r: only the last version of such a line is kept.
JOB_OFFSET=0
job_output() {
    local file="$JOBS_DIR/$1/output.log" offset="$2" size
    size="$(stat -c %s "$file" 2>/dev/null || echo 0)"
    if [ "$size" -gt "$offset" ]; then
        tail -c +"$((offset + 1))" "$file" | head -c "$((size - offset))" | perl -pe 's/^.*\r(?=[^\n])//'
    fi
    JOB_OFFSET="$size"
}

servio_launch_job() {
    local mode="$SERVIO_JOB_MODE" id dir rc state
    require_root
    id="$(date -u +%Y%m%d-%H%M%S)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
    dir="$JOBS_DIR/$id"
    mkdir -p "$dir"
    chmod 700 "$JOBS_DIR" "$dir"
    # Old jobs: kept 7 days, then removed.
    find "$JOBS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 -name '20*' -exec rm -rf {} + 2>/dev/null || true

    cat > "$dir/script.sh"                     # the heredoc: SERVIO_* lines, lib.sh, the script
    printf '%s\n' "script=$SERVIO_SCRIPT_NAME" "user=${SUDO_USER:-root}" "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$dir/meta"
    : > "$dir/output.log"
    chmod 600 "$dir/script.sh" "$dir/meta" "$dir/output.log"

    # The job runs `bash script.sh <args>`, then writes its exit code. Arguments are passed as
    # separate words (no shell string), and were checked by run.sh and are checked again by the
    # script itself.
    local runner='bash "$1/script.sh" "${@:2}"; echo $? > "$1/exit-code"'
    local sudo_user="${SUDO_USER:-root}"
    [[ "$sudo_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || sudo_user=root

    if has_systemd; then
        systemd-run --quiet --collect --unit="servio-job-$id" \
            --description="servio-agent $SERVIO_SCRIPT_NAME" \
            --setenv=SUDO_USER="$sudo_user" \
            -p StandardOutput="append:$dir/output.log" -p StandardError="append:$dir/output.log" \
            /bin/bash -c "$runner" _ "$dir" "$@"
        echo "SERVIO_JOB_ID=$id"
        echo "Started as a job: it keeps running even if this connection drops."
    else
        echo "SERVIO_JOB_ID=$id"
        echo "No systemd here: running in the foreground (a dropped connection would stop it)."
        touch "$dir/foreground"
        SUDO_USER="$sudo_user" bash -c "$runner" _ "$dir" "$@" >> "$dir/output.log" 2>&1 &
        echo "$!" > "$dir/pid"
        mode="follow"               # nothing would keep a detached job alive without systemd
    fi

    if [ "$mode" = "detach" ]; then
        echo "Read it with: run.sh <host> job-status.sh $id"
        return 0
    fi

    # follow: print new output every 2 seconds until the job ends.
    JOB_OFFSET=0
    while :; do
        job_output "$id" "$JOB_OFFSET"
        state="$(job_state "$id")"
        [ "$state" = "running" ] || break
        sleep 2
    done
    job_output "$id" "$JOB_OFFSET"
    if [ "$state" = "finished" ]; then
        rc="$(cat "$dir/exit-code")"
        [[ "$rc" =~ ^[0-9]+$ ]] || rc="$EXIT_FAILED"
        exit "$rc"
    fi
    echo "The job stopped without an exit code (stopped by hand, or the server restarted)." >&2
    exit "$EXIT_FAILED"
}

# ---------------------------------------------------------------------------------------------
# servio_run: the last line of every script (`servio_run "$@"`).
#   - takes --dry-run out of the arguments (it may be anywhere) and sets DRY_RUN
#   - runs main with stdin from /dev/null: with `bash -s`, bash reads the script itself from
#     stdin, and any command that reads stdin (apt, git, ssh) would eat the rest of the script
#   - sends everything main prints (stdout and stderr) through mask_output
#   - keeps main's exit code (PIPESTATUS[0]: the code of the first command in the pipe)
# The { ...; } runs in a subshell (it is part of a pipe), so the traps are set INSIDE it:
# a subshell doesn't inherit the parent's EXIT trap.
# ---------------------------------------------------------------------------------------------
servio_run() {
    local args=() arg
    for arg in "$@"; do
        if [ "$arg" = "--dry-run" ]; then DRY_RUN=1; else args+=("$arg"); fi
    done
    {
        trap run_exit_hooks EXIT
        trap 'on_error $? "$BASH_COMMAND"' ERR
        dry_run && echo "DRY RUN: nothing on the server will be changed."
        main "${args[@]+"${args[@]}"}"
    } < /dev/null 2>&1 | mask_output
    exit "${PIPESTATUS[0]}"
}
