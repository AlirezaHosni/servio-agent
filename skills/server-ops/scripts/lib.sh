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
NODE_MAJOR=22                          # Node.js LTS installed by provision (Vite needs 20+)

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
    local domain="$1" scheme="$2" path="${3:-/}" port=80 body
    [ "$scheme" = "https" ] && port=443
    body="$(mktemp)"
    SITE_STATUS="$(curl -sS -o "$body" -w '%{http_code}' --max-time 15 \
        --resolve "$domain:$port:127.0.0.1" "$scheme://$domain$path" 2>/dev/null || true)"
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

# ---------------------------------------------------------------------------------------------
# Release folders (v0.5, item 15). A site's folder:
#   /home/<user>/<domain>/
#     (no repo here: each deploy reads the branch from a temporary clone, then git archive)
#     releases/<time>-<hash>/ one folder per deploy, built before it goes live (kept: the last 5)
#     shared/.env            the same in every release (symlinked in)
#     shared/storage/        uploads, logs, sessions, cache: the same in every release
#     current -> releases/…  what nginx serves: switched in one step (a symlink rename)
# Each release has .servio-release: commit, branch, repository, when, who (read by inventory,
# site-details, rollback). nginx's root is current/<web dir>.
# ---------------------------------------------------------------------------------------------
site_releases() { echo "$(site_dir "$1")/releases"; }
site_shared()   { echo "$(site_dir "$1")/shared"; }
site_current()  { echo "$(site_dir "$1")/current"; }
site_env()      { echo "$(site_shared "$1")/.env"; }
RELEASE_PATTERN='^[0-9]{8}-[0-9]{6}-[0-9a-z]{1,12}$'
# The folders Laravel needs in storage/ (a new shared/storage starts with these).
LARAVEL_STORAGE_DIRS="app/public framework/cache/data framework/sessions framework/views framework/testing logs"

# release_names <domain>: the releases, oldest first (names sort by time). Only valid names.
release_names() {
    local d
    for d in "$(site_releases "$1")"/*/; do
        [ -d "$d" ] || continue
        d="$(basename "$d")"
        [[ "$d" =~ $RELEASE_PATTERN ]] && echo "$d"
    done
}

# current_release <domain>: the name of the release `current` points at, or empty.
current_release() {
    local target
    target="$(readlink "$(site_current "$1")" 2>/dev/null || true)"
    target="$(basename "$target")"
    [[ "$target" =~ $RELEASE_PATTERN ]] && echo "$target"
    return 0
}

# previous_release <domain>: the newest release OLDER than the live one (names sort by time),
# never the placeholder. Empty when there is none.
previous_release() {
    local live name prev=""
    live="$(current_release "$1")"
    for name in $(release_names "$1"); do
        [ "$name" != "00000000-000000-placeholder" ] || continue
        if [[ "$name" < "$live" ]]; then prev="$name"; fi
    done
    echo "$prev"
}

# read_release <release folder>: sets REL_COMMIT, REL_BRANCH, REL_REPOSITORY, REL_TIME, REL_BY
# from its .servio-release, every value checked (empty when missing or odd).
REL_COMMIT="" REL_BRANCH="" REL_REPOSITORY="" REL_TIME="" REL_BY=""
read_release() {
    local file="$1/.servio-release" key value
    REL_COMMIT="" REL_BRANCH="" REL_REPOSITORY="" REL_TIME="" REL_BY=""
    [ -f "$file" ] && [ ! -L "$file" ] || return 0
    while IFS='=' read -r key value; do
        case "$key" in
            commit)     [[ "$value" =~ ^[0-9a-f]{40}$ ]] && REL_COMMIT="$value" ;;
            branch)     [[ "$value" =~ ^[A-Za-z0-9._/-]{1,100}$ ]] && REL_BRANCH="$value" ;;
            repository) [[ "$value" =~ ^(git@[a-z0-9.-]+:|https://[a-z0-9.-]+(:[0-9]{1,5})?/)[A-Za-z0-9._/-]{1,200}$ ]] && REL_REPOSITORY="$value" ;;
            deployed)   [[ "$value" =~ ^[0-9T:Z-]{20}$ ]] && REL_TIME="$value" ;;
            by)         [[ "$value" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && REL_BY="$value" ;;
        esac
    done < "$file"
    return 0
}

# The in-place layout of v0.3 (a git checkout right in the site folder) isn't deployed into:
# that site is recreated instead (nothing ran v0.3 on a real server).
is_in_place_site() { [ -d "$(site_dir "$1")/.git" ]; }

# switch_current <domain> <release name>: point `current` at a release in ONE step. A symlink
# can't be changed in place: make a new one next to it, then rename it over the old (rename is
# atomic: every request sees either the old or the new release, never a mix).
switch_current() {
    local domain="$1" name="$2" user dir
    user="$(site_user "$domain")"; dir="$(site_dir "$domain")"
    [[ "$name" =~ $RELEASE_PATTERN ]] && [ -d "$dir/releases/$name" ] || die "No release $name."
    run runuser -u "$user" -- ln -sfn "releases/$name" "$dir/current.servio-new"
    run runuser -u "$user" -- mv -T "$dir/current.servio-new" "$dir/current"
}

# The access-log format with the request time (item 14, for traffic.sh): the usual "combined"
# format plus the seconds the request took. In nginx's http{} block (conf.d), once per server.
LOG_FORMAT_FILE="servio-log-format.conf"
ensure_log_format() {
    local file="$NGINX_DIR/conf.d/$LOG_FORMAT_FILE"
    [ -f "$file" ] && return 0
    write_file "$file" 644 root:root <<'NGINX'
# Managed by Servio. The access-log format of Servio's sites: "combined" plus the request time.
log_format servio_timed '$remote_addr - $remote_user [$time_local] "$request" $status '
                        '$body_bytes_sent "$http_referer" "$http_user_agent" $request_time';
NGINX
}

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
SITE_WEB_DIR="" SITE_PHP="" SITE_ROOT=""
read_site_settings() {
    local domain="$1" file root dir
    file="$(nginx_available "$domain")"
    dir="$(site_dir "$domain")"
    [ -f "$file" ] || die_state "No nginx config for $domain at $file. Create the site first."
    require_managed_config "$domain"
    root="$(awk -v prefix="$dir/" '$1 == "root" && index($2, prefix) == 1 { sub(/;$/, "", $2); print $2; exit }' "$file")"
    [ -n "$root" ] || die_state "Couldn't find the site's root line in $file (or it isn't in $dir)."
    SITE_WEB_DIR="${root#"$dir/"}"
    # Release layout (v0.5): the root is <site>/current/<web dir>.
    SITE_WEB_DIR="${SITE_WEB_DIR#current/}"
    SITE_ROOT="$root"   # the full root as nginx has it (re-rendering a config keeps it)
    read_site_meta "$domain"
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

    access_log /var/log/nginx/$1-access.log servio_timed;
    error_log  /var/log/nginx/$1-error.log;

NGINX
}

# ---------------------------------------------------------------------------------------------
# A site's names and state, kept IN its nginx config (there is no database), as comment lines
# right under the managed header, and read back before every re-render so no script drops them:
#   # servio-aliases: shop.example.org shop2.example.com   more names, served the same (item 14)
#   # servio-www: www.shop.example.com                     redirected (301) to the main domain
#   # servio-suspended: yes                                every request gets a 503 page (item 77)
# ---------------------------------------------------------------------------------------------
SITE_ALIASES="" SITE_WWW="" SITE_SUSPENDED=0
SUSPENDED_ROOT="/var/www/servio-suspended"
DOMAIN_PATTERN='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'

# read_site_meta <domain>: set the three globals from the site's config (empty if none).
read_site_meta() {
    local file name line aliases=""
    SITE_ALIASES="" SITE_WWW="" SITE_SUSPENDED=0
    file="$(nginx_available "$1")"
    [ -f "$file" ] || return 0
    line="$(sed -n 's/^# servio-aliases: //p' "$file" | head -n 1)"
    for name in $line; do
        [[ "$name" =~ $DOMAIN_PATTERN ]] && [ "$name" != "$1" ] && aliases="$aliases $name"
    done
    SITE_ALIASES="${aliases# }"
    line="$(sed -n 's/^# servio-www: //p' "$file" | head -n 1)"
    [ "$line" = "www.$1" ] && SITE_WWW="$line"
    grep -qx '# servio-suspended: yes' "$file" && SITE_SUSPENDED=1
    return 0
}

nginx_meta_lines() {
    [ -z "$SITE_ALIASES" ] || echo "# servio-aliases: $SITE_ALIASES"
    [ -z "$SITE_WWW" ] || echo "# servio-www: $SITE_WWW"
    [ "$SITE_SUSPENDED" -eq 0 ] || echo "# servio-suspended: yes"
    return 0
}

# site_names <domain>: the names that serve the site (main + aliases).
site_names() { echo "$1${SITE_ALIASES:+ $SITE_ALIASES}"; }
# certificate_names <domain>: every name the certificate must cover (+ the www redirect).
certificate_names() { echo "$(site_names "$1")${SITE_WWW:+ $SITE_WWW}"; }

# The page a suspended site shows (status 503: search engines come back later).
nginx_suspended_block() {
    cat <<NGINX

    # Suspended (suspend-site.sh): the app isn't touched; nginx answers every request itself.
    root $SUSPENDED_ROOT;
    error_page 503 /suspended.html;
    location = /suspended.html { internal; }
    location / {
        return 503;
    }

    access_log /var/log/nginx/$1-access.log servio_timed;
    error_log  /var/log/nginx/$1-error.log;
NGINX
}

# The served part: the site, or the suspended page.
nginx_served_block() {
    if [ "$SITE_SUSPENDED" -eq 1 ]; then nginx_suspended_block "$1"; else nginx_site_block "$@"; fi
}

# $1 domain, $2 web root, $3 PHP version
nginx_http_config() {
    echo "$MANAGED_HEADER. Changes made by hand are overwritten when the site is updated."
    nginx_meta_lines
    echo "server {"
    echo "    listen 80;"
    echo "    listen [::]:80;"
    echo "    server_name $(site_names "$1");"
    nginx_acme_block
    nginx_served_block "$1" "$2" "$3"
    echo "}"
    if [ -n "$SITE_WWW" ]; then
        echo
        echo "# $SITE_WWW -> $1 (the certificate check still reaches it)."
        echo "server {"
        echo "    listen 80;"
        echo "    listen [::]:80;"
        echo "    server_name $SITE_WWW;"
        nginx_acme_block
        echo "    location / {"
        echo "        return 301 http://$1\$request_uri;"
        echo "    }"
        echo "}"
    fi
}

# $1 domain, $2 web root, $3 PHP version
nginx_https_config() {
    local live="$LETSENCRYPT_DIR/live/$1"
    echo "$MANAGED_HEADER. Changes made by hand are overwritten when the site is updated."
    nginx_meta_lines
    echo "# Port 80: Let's Encrypt's checks (first issue and renewals), and a redirect to HTTPS."
    echo "server {"
    echo "    listen 80;"
    echo "    listen [::]:80;"
    echo "    server_name $(certificate_names "$1");"
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
    echo "    server_name $(site_names "$1");"
    echo
    echo "    # Made by certbot. The private key never leaves this server."
    echo "    ssl_certificate     $live/fullchain.pem;"
    echo "    ssl_certificate_key $live/privkey.pem;"
    echo "    ssl_protocols TLSv1.2 TLSv1.3;"
    nginx_served_block "$1" "$2" "$3"
    echo "}"
    if [ -n "$SITE_WWW" ]; then
        echo
        echo "# $SITE_WWW -> $1 (same certificate: it covers both names)."
        echo "server {"
        echo "    listen 443 ssl http2;"
        echo "    listen [::]:443 ssl http2;"
        echo "    server_name $SITE_WWW;"
        echo "    ssl_certificate     $live/fullchain.pem;"
        echo "    ssl_certificate_key $live/privkey.pem;"
        echo "    ssl_protocols TLSv1.2 TLSv1.3;"
        echo "    location / {"
        echo "        return 301 https://$1\$request_uri;"
        echo "    }"
        echo "}"
    fi
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
    # The config uses the servio_timed log format: it must exist before nginx -t.
    ensure_log_format

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
#     so many small sites cost almost no memory. pm.max_children caps it (pool-size.sh)
#   - its own temp folder for uploads, temp files and sessions, never a shared /tmp
#   - security.limit_extensions: only .php files are ever executed
# ---------------------------------------------------------------------------------------------
# pm.max_children: POOL_MAX_CHILDREN when a script sets it (pool-size.sh), else what the site's
# pool has now (in ANY PHP version: changing the version keeps it), else 5. So re-running
# create-site never resets a size someone chose.
POOL_MAX_CHILDREN=""
current_max_children() {
    local v n
    for v in $PHP_VERSIONS; do
        # `|| true`: no pool for this version is normal (sed then fails, and set -e would stop here).
        n="$(sed -n 's/^pm\.max_children = \([0-9]*\)$/\1/p' "$(pool_file "$1" "$v")" 2>/dev/null | head -n 1 || true)"
        if [[ "$n" =~ ^[1-9][0-9]{0,2}$ ]]; then echo "$n"; return 0; fi
    done
    echo 5
}

php_pool_config() {
    local user home max_children
    user="$(site_user "$1")"
    home="$(site_home "$1")"
    max_children="${POOL_MAX_CHILDREN:-$(current_max_children "$1")}"
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
pm.max_children = $max_children
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
# The project check (items 11-12): what does the code about to be deployed NEED, and does the
# server have it? Used by project-check.sh, and by deploy-site.sh before it switches.
#
# It reads the commit, never runs it: files are read with `git show <commit>:<file>` and searched
# with `git grep <commit>`, from a temporary shallow clone (no working files, deleted at the end)
# or the site's own repository. Nothing in the live site changes.
# ---------------------------------------------------------------------------------------------
SUPERVISOR_DIR="/etc/supervisor/conf.d"

# The non-secret .env keys a script may read (rule 35). Values are checked: plain words only.
ENV_KEYS_ALLOWED="QUEUE_CONNECTION DB_CONNECTION CACHE_STORE SESSION_DRIVER DB_DATABASE DB_USERNAME"

# git as the site's user, with the site's deploy key (only exported variables reach runuser).
site_git_env() {
    export GIT_SSH_COMMAND="ssh -i $(deploy_key_path "$1") -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o UserKnownHostsFile=$(site_home "$1")/.ssh/known_hosts"
}

# env_value <env file> <KEY> <user>: the value of one allowed key, read as the site's user, or
# empty. Never a key outside ENV_KEYS_ALLOWED, never a value that isn't a plain word.
ENV_VALUE=""
env_value() {
    local file="$1" key="$2" user="$3" v
    ENV_VALUE=""
    case " $ENV_KEYS_ALLOWED " in *" $key "*) ;; *) die "env_value: $key is not an allowed key." ;; esac
    [ -f "$file" ] && [ ! -L "$file" ] || return 0
    v="$(runuser -u "$user" -- grep -E "^\s*$key\s*=" "$file" 2>/dev/null | tail -n 1 \
        | sed -E 's/^[^=]*=\s*//; s/\s+#.*$//; s/\s+$//; s/^["'\'']//; s/["'\'']$//' || true)"
    [[ "$v" =~ ^[a-z0-9_-]{1,64}$ ]] && ENV_VALUE="$v"
    return 0
}

# env_set <domain> <KEY=value lines on stdin>: set those keys in the site's shared/.env, keep every
# other line as it is. For values the SERVER made (a generated password): they're never printed,
# never on a command line (only stdin), and the file is never shown as a diff, not even in a dry
# run (write_file would). Written next to the old one, then renamed: owner the site user, 600.
env_set() {
    local domain="$1" env user new
    env="$(site_env "$domain")"; user="$(site_user "$domain")"
    [ ! -L "$env" ] || die_refused "$env is a symlink: not writing secrets through it."
    new="$(mktemp "$(dirname "$env")/.env.servio-new.XXXXXX")"
    add_exit_hook "rm -f '$new'"
    chmod 600 "$new"
    # perl: the new KEY=value lines (stdin) replace the same keys in the old file, in place;
    # keys that weren't there are added at the end. Values aren't interpreted (no shell).
    perl -e '
        my ($old) = @ARGV; my (@set, %new);
        while (my $l = <STDIN>) { chomp $l; next unless $l =~ /^([A-Z][A-Z0-9_]*)=/; push @set, $1 unless exists $new{$1}; $new{$1} = $l; }
        my @out; my %done;
        if (open my $fh, "<", $old) { while (my $l = <$fh>) { chomp $l;
            if ($l =~ /^\s*([A-Z][A-Z0-9_]*)\s*=/ && exists $new{$1}) { push @out, $new{$1} unless $done{$1}++; } else { push @out, $l } } }
        for (@set) { push @out, $new{$_} unless $done{$_} }
        print "$_\n" for @out;
    ' "$env" > "$new"
    chown "$user:$user" "$new"
    mv -f "$new" "$env"
    return 0
}

# project_clone <domain> <repository> <branch>: a shallow clone with no working files, as the
# site's user, in its own tmp folder. Sets PROJECT_GIT and PROJECT_COMMIT; removed on exit.
PROJECT_GIT="" PROJECT_COMMIT=""
project_clone() {
    local domain="$1" repository="$2" branch="$3" depth="${4:-1}" user tmp
    user="$(site_user "$domain")"
    site_git_env "$domain"
    tmp="$(runuser -u "$user" -- mktemp -d "$(site_home "$domain")/tmp/servio-check.XXXXXX")"
    add_exit_hook "rm -rf '$tmp'"
    runuser -u "$user" --preserve-environment -- env HOME="$(site_home "$domain")" \
        git clone -q --bare --depth "$depth" --single-branch --branch "$branch" -- "$repository" "$tmp/repo.git" 2>&1 | tail -n 3 || true
    [ -f "$tmp/repo.git/HEAD" ] || die_state "Couldn't fetch $branch from $repository (is the deploy key added to the repository?)."
    PROJECT_GIT="$tmp/repo.git"
    PROJECT_COMMIT="$(runuser -u "$user" -- git -C "$PROJECT_GIT" rev-parse HEAD)"
    [[ "$PROJECT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "Unexpected commit id from git."
}

# The plan: what the commit needs. Globals, all checked against patterns (they come from the repo).
PLAN_LARAVEL="" PLAN_PHP="" PLAN_EXTENSIONS="" PLAN_HORIZON=0 PLAN_REVERB=0 PLAN_OCTANE=0
PLAN_PULSE=0 PLAN_QUEUES="" PLAN_SCHEDULER=0 PLAN_BUILD=0 PLAN_DOCKER=0 PLAN_COMPOSER_OK=1

# project_plan <git dir> <commit> <user>
project_plan() {
    local git="$1" commit="$2" user="$3" lines line queues
    pgit() { runuser -u "$user" -- git -C "$git" "$@"; }

    # composer.json / composer.lock / package.json: parsed by perl's JSON::PP (part of perl).
    lines="$( { pgit show "$commit:composer.json" 2>/dev/null || echo '{}'; echo; echo '----SERVIO----';
                pgit show "$commit:composer.lock" 2>/dev/null || echo '{}'; echo; echo '----SERVIO----';
                pgit show "$commit:package.json" 2>/dev/null || echo '{}'; } | perl -e '
        use strict; use warnings;
        my $ok = eval { require JSON::PP; 1 }; unless ($ok) { print "nojson\n"; exit 0 }
        local $/; my @parts = split /\n----SERVIO----\n/, <STDIN>;
        my @j = map { my $d = eval { JSON::PP::decode_json($_) }; ref $d eq "HASH" ? $d : {} } @parts;
        my $req = $j[0]{require} || {};
        print "php $req->{php}\n" if defined $req->{php} && !ref $req->{php};
        for (sort keys %$req) { print "ext $1\n" if /^ext-(.+)$/; print "pkg $_\n" if m{^laravel/}; }
        for my $p (@{ $j[1]{packages} || [] }) { next unless ref $p eq "HASH" && defined $p->{name};
            print "pkg $p->{name}\n" if $p->{name} =~ m{^laravel/};
            print "laravel $p->{version}\n" if $p->{name} eq "laravel/framework" && defined $p->{version}; }
        my $s = $j[2]{scripts} || {}; print "build\n" if ref $s eq "HASH" && defined $s->{build};
    ' || true)"
    [ "$lines" != "nojson" ] || PLAN_COMPOSER_OK=0
    while IFS= read -r line; do
        case "$line" in
            "php "*)     [[ "${line#php }" =~ ^[0-9.*^~\<\>=|,\ -]{1,60}$ ]] && PLAN_PHP="${line#php }" ;;
            "ext "*)     [[ "${line#ext }" =~ ^[a-z0-9_-]{1,40}$ ]] && PLAN_EXTENSIONS="$PLAN_EXTENSIONS ${line#ext }" ;;
            "laravel "*) [[ "${line#laravel }" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] && PLAN_LARAVEL="${line#laravel }" && PLAN_LARAVEL="${PLAN_LARAVEL#v}" ;;
            "pkg laravel/horizon") PLAN_HORIZON=1 ;;
            "pkg laravel/reverb")  PLAN_REVERB=1 ;;
            "pkg laravel/octane")  PLAN_OCTANE=1 ;;
            "pkg laravel/pulse")   PLAN_PULSE=1 ;;
            build) PLAN_BUILD=1 ;;
        esac
    done <<< "$lines"
    PLAN_EXTENSIONS="$(printf '%s\n' $PLAN_EXTENSIONS | sort -u | tr '\n' ' ')"; PLAN_EXTENSIONS="${PLAN_EXTENSIONS% }"

    # Queue names used in the code: onQueue('x'), allOnQueue('x'), pushOn('x'), public $queue = 'x'.
    queues="$(pgit grep -hE '(onQueue|allOnQueue|pushOn)\(|[$]queue[[:space:]]*=' "$commit" -- app config routes 2>/dev/null \
        | perl -ne 'while (/(?:onQueue|allOnQueue|pushOn)\(\s*[\x27"]([A-Za-z0-9_.-]{1,40})[\x27"]/g) { print "$1\n" }
                    print "$1\n" if /\$queue\s*=\s*[\x27"]([A-Za-z0-9_.-]{1,40})[\x27"]/' \
        | grep -vx default | sort -u | tr '\n' ',' || true)"
    PLAN_QUEUES="${queues}default"

    # The scheduler: Laravel 11+ (routes/console.php, bootstrap/app.php) and 10 (Console/Kernel.php).
    if pgit grep -qE "Schedule::|->(everyMinute|everyTwoMinutes|everyFiveMinutes|everyTenMinutes|everyFifteenMinutes|everyThirtyMinutes|hourly|hourlyAt|daily|dailyAt|twiceDaily|weekly|weeklyOn|monthly|cron)\(|withSchedule" \
            "$commit" -- routes/console.php bootstrap/app.php app/Console/Kernel.php 2>/dev/null; then
        PLAN_SCHEDULER=1
    fi
    if pgit ls-tree --name-only "$commit" 2>/dev/null | grep -qx Dockerfile \
       && pgit ls-tree --name-only "$commit" 2>/dev/null | grep -qE '^(compose|docker-compose)\.ya?ml$'; then
        PLAN_DOCKER=1
    fi
    return 0
}

# php_satisfies <version like 8.4.3> <composer constraint like "^8.2|^8.3" or ">=8.1 <9">.
php_satisfies() {
    perl -e '
        my ($v, $c) = @ARGV;
        sub n { my @p = split /\./, shift; push @p, 0 while @p < 3; $p[0] * 1e6 + $p[1] * 1e3 + $p[2] }
        sub one { my ($op, $x) = @_; my $V = n($v);
            if ($x =~ /\*/) { (my $b = $x) =~ s/\.?\*.*//; my @b = split /\./, $b; my @w = split /\./, $v;
                for my $i (0 .. $#b) { return 0 unless defined $w[$i] && $w[$i] == $b[$i] } return 1 }
            my $X = n($x); my @x = split /\./, $x;
            return $V >= $X && $V < ($x[0] + 1) * 1e6 if $op eq "^" && $x[0] > 0;
            return $V >= $X && $V < n(@x >= 3 ? "$x[0].".($x[1] + 1) : ($x[0] + 1)) if $op eq "~";
            return $V >= $X if $op eq ">="; return $V > $X if $op eq ">";
            return $V <= $X if $op eq "<="; return $V < $X if $op eq "<";
            return $V != $X if $op eq "!=";
            return $V >= $X && $V < n(@x >= 3 ? $x : @x == 2 ? "$x[0].".($x[1] + 1) : ($x[0] + 1)); }
        for my $alt (split /\s*\|\|?\s*/, $c) {
            my $all = 1;
            for my $part (split /[\s,]+/, $alt) { next unless length $part;
                my ($op, $x) = $part =~ /^(\^|~|>=|<=|>|<|!=|=)?v?([0-9][0-9.*]*)$/ or do { $all = 0; last };
                $all = 0, last unless one($op // "", $x); }
            exit 0 if $all; }
        exit 1;
    ' "$1" "$2"
}

# plan_vs_server <domain> <php version>: compare the plan with the server (item 12). PASS/WARN/FAIL.
plan_vs_server() {
    local domain="$1" php="$2" user full have missing="" ext queue_conn workers listening q missing_q="" node_major
    user="$(site_user "$domain")"

    full="$("php$php" -r 'echo PHP_VERSION;' 2>/dev/null || true)"
    if [ -z "$PLAN_PHP" ]; then check_na "PHP version" "composer.json doesn't say"
    elif [ -z "$full" ]; then check_na "PHP version" "php$php isn't installed"
    elif php_satisfies "$full" "$PLAN_PHP"; then check_pass "PHP version" "the site runs $full, the project needs $PLAN_PHP"
    else check_fail "PHP version" "the site runs $full, the project needs $PLAN_PHP (change the site's PHP version first)"; fi

    if [ -n "$PLAN_EXTENSIONS" ]; then
        have="$("php$php" -m 2>/dev/null | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9\n' || true)"
        for ext in $PLAN_EXTENSIONS; do
            printf '%s\n' "$have" | grep -qx "$(printf '%s' "$ext" | tr -cd 'a-z0-9')" || missing="$missing $ext"
        done
        [ -z "$missing" ] && check_pass "PHP extensions" "$PLAN_EXTENSIONS" \
            || check_fail "PHP extensions" "missing for PHP $php:$missing (install php$php-<name>)"
    fi

    env_value "$(site_env "$domain")" QUEUE_CONNECTION "$user"; queue_conn="$ENV_VALUE"
    [ -n "$queue_conn" ] || queue_conn="unknown"
    if [ "$queue_conn" = "redis" ] || [ "$PLAN_HORIZON" -eq 1 ]; then
        if command -v redis-server >/dev/null 2>&1 && systemctl is-active --quiet redis-server 2>/dev/null; then
            check_pass "Redis" "running"
        else
            check_fail "Redis" "needed ($([ "$PLAN_HORIZON" -eq 1 ] && echo Horizon || echo "QUEUE_CONNECTION=redis")) but not running"
        fi
    fi

    # Workers: what Supervisor runs for this site (our programs: $SUPERVISOR_DIR/<user>-*.conf).
    workers="$(cat "$SUPERVISOR_DIR/$user"-*.conf 2>/dev/null | grep -E '^command=' || true)"
    if [ "$queue_conn" = "sync" ]; then
        check_pass "queue workers" "QUEUE_CONNECTION=sync: jobs run inside the request, no worker needed"
    elif [ "$PLAN_HORIZON" -eq 1 ]; then
        printf '%s\n' "$workers" | grep -q 'artisan horizon' && check_pass "queue workers" "Horizon runs" \
            || check_warn "queue workers" "the project uses Horizon but it doesn't run (workers: workers.sh)"
    else
        # `|| true`: no worker at all is a normal answer, not an error that should stop the script.
        listening="$(printf '%s\n' "$workers" | grep -oE -- '--queue=[A-Za-z0-9_.,-]+' | cut -d= -f2 | tr ',' '\n' | sort -u || true)"
        if [ -z "$listening" ] && printf '%s\n' "$workers" | grep -q 'queue:work'; then listening="default"; fi
        for q in $(printf '%s' "$PLAN_QUEUES" | tr ',' ' '); do
            printf '%s\n' "$listening" | grep -qx "$q" || missing_q="$missing_q $q"
        done
        if [ -z "$missing_q" ]; then check_pass "queue workers" "queues $PLAN_QUEUES have a worker"
        else check_warn "queue workers" "no worker listens to:$missing_q (QUEUE_CONNECTION=$queue_conn; workers: workers.sh)"; fi
    fi
    if [ "$PLAN_REVERB" -eq 1 ]; then
        printf '%s\n' "$workers" | grep -q 'artisan reverb:start' && check_pass "reverb" "runs" \
            || check_warn "reverb" "the project uses Laravel Reverb but it doesn't run (workers.sh)"
    fi
    if [ "$PLAN_OCTANE" -eq 1 ]; then
        check_warn "octane" "the project includes Laravel Octane; this site runs on PHP-FPM (Octane isn't supported yet)"
    fi

    if [ "$PLAN_SCHEDULER" -eq 1 ]; then
        site_has_scheduler "$domain" && check_pass "scheduler" "cron runs schedule:run" \
            || check_warn "scheduler" "the project has scheduled tasks but no cron runs them (scheduler: workers.sh)"
    fi

    if [ "$PLAN_BUILD" -eq 1 ]; then
        node_major="$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || true)"
        if ! [[ "$node_major" =~ ^[0-9]+$ ]]; then check_fail "Node.js" "the project builds its frontend (npm run build) but Node.js isn't installed (provision-server.sh installs it)"
        elif [ "$node_major" -lt 20 ]; then check_warn "Node.js" "v$node_major: Vite 6+ needs Node 20 or newer"
        else check_pass "Node.js" "v$node_major"; fi
    fi
    [ "$PLAN_DOCKER" -eq 0 ] || check_warn "Docker" "the repository has a Dockerfile and a compose file; this site runs natively (Docker mode comes in v0.8)"
    [ "$PLAN_COMPOSER_OK" -eq 1 ] || check_na "composer.json" "perl's JSON::PP is missing on the server"
    return 0
}

# print_plan: the plan in words, then SERVIO_PLAN_* lines for scripts and the AI to read.
print_plan() {
    local workers="none"
    if [ "$PLAN_HORIZON" -eq 1 ]; then workers="horizon (queues from config/horizon.php)"
    else workers="queue:work --queue=$PLAN_QUEUES"; fi
    local others=""
    [ "$PLAN_REVERB" -eq 0 ] || others="$others reverb"
    [ "$PLAN_OCTANE" -eq 0 ] || others="$others octane"
    [ "$PLAN_PULSE" -eq 0 ] || others="$others pulse"
    echo "laravel:    ${PLAN_LARAVEL:-not a Laravel app (or unknown)}"
    echo "php needs:  ${PLAN_PHP:-not said}"
    echo "extensions: ${PLAN_EXTENSIONS:-none listed}"
    echo "workers:    $workers"
    echo "scheduler:  $([ "$PLAN_SCHEDULER" -eq 1 ] && echo yes || echo no)"
    echo "also runs:  ${others:- nothing else}"
    echo "frontend:   $([ "$PLAN_BUILD" -eq 1 ] && echo "npm ci && npm run build" || echo "no build step")"
    echo "docker:     $([ "$PLAN_DOCKER" -eq 1 ] && echo "Dockerfile + compose file found" || echo no)"
    echo "SERVIO_PLAN_WORKERS=$([ "$PLAN_HORIZON" -eq 1 ] && echo horizon || echo "queue:$PLAN_QUEUES")"
    echo "SERVIO_PLAN_SCHEDULER=$PLAN_SCHEDULER"
    echo "SERVIO_PLAN_BUILD=$PLAN_BUILD"
    echo "SERVIO_PLAN_EXTRA=${others# }"
}

# ---------------------------------------------------------------------------------------------
# Deploy helpers (item 15): what changes, is the new release healthy, which releases to keep.
# ---------------------------------------------------------------------------------------------

# commits_between <git dir> <live commit> <new commit> <user>: one line per commit, newest first:
# short hash, date, author, subject. Subjects are written by anyone who can push: only plain
# characters are kept and lines are cut, and the caller prints them as data.
commits_between() {
    local git="$1" live="$2" new="$3" user="$4"
    if [ -z "$live" ]; then echo "  (nothing deployed yet: first deploy)"; return 0; fi
    if [ "$live" = "$new" ]; then echo "  (no new commits: the same commit is live)"; return 0; fi
    if ! runuser -u "$user" -- git -C "$git" cat-file -e "$live^{commit}" 2>/dev/null; then
        echo "  (the live commit isn't in the last 50 commits of this branch: more than 50 new commits, or another branch's history)"
        return 0
    fi
    runuser -u "$user" -- git -C "$git" log --no-merges --format='%h %cs %an: %s' "$live..$new" 2>/dev/null \
        | head -n 50 | LC_ALL=C tr -cd 'A-Za-z0-9 .,:;()#/@+_=\-\n' | cut -c1-100 | sed 's/^/  /' || true
}

# health_check <domain>: after the switch, ask the site like a visitor would. Laravel 11+ has a
# health route /up; otherwise the home page. A pass needs BOTH a good status (2xx/3xx) and a body
# without an error page in it: Laravel can answer 200 with "Whoops" when debug is on, or a
# cached error view. Sets HEALTH_DETAIL; returns 1 on failure.
HEALTH_DETAIL=""
HEALTH_ERROR_PATTERN='Whoops|Server Error|SQLSTATE|Fatal error|Parse error|Uncaught [A-Za-z\\]*Exception'
health_check() {
    local domain="$1" scheme=http path="/up"
    # A suspended site answers 503 on purpose: nothing to check (the new code is in place for
    # when it's resumed; suspend-site.sh resume runs this check then).
    if [ "$SITE_SUSPENDED" -eq 1 ]; then
        HEALTH_DETAIL="skipped: $domain is suspended (nginx shows the 503 page)"
        return 0
    fi
    [ -f "$(certificate_path "$domain")" ] && scheme=https
    site_status "$domain" "$scheme" "$path"
    if [ "$SITE_STATUS" = "404" ]; then path="/"; site_status "$domain" "$scheme" "$path"; fi
    HEALTH_DETAIL="$scheme://$domain$path: status $SITE_STATUS"
    case "$SITE_STATUS" in
        2??|3??) ;;
        000) HEALTH_DETAIL="$scheme://$domain$path: no answer"; return 1 ;;
        *) return 1 ;;
    esac
    if printf '%s' "$SITE_BODY" | grep -qE "$HEALTH_ERROR_PATTERN"; then
        HEALTH_DETAIL="$HEALTH_DETAIL, but the page shows an error"
        return 1
    fi
    return 0
}

# releases_to_delete <keep> <current> <previous> <names oldest first…>: the old releases to
# remove: everything but the newest <keep>, and never the current or the previous one.
releases_to_delete() {
    local keep="$1" current="$2" previous="$3"; shift 3
    local total=$# i=0 name
    for name in "$@"; do
        i=$((i + 1))
        [ $((total - i)) -ge "$keep" ] || continue      # one of the newest <keep>
        [ "$name" != "$current" ] && [ "$name" != "$previous" ] || continue
        echo "$name"
    done
}

# prune_releases <domain> <previous>: keep the last 5 (and current, previous).
KEEP_RELEASES=5
prune_releases() {
    local domain="$1" previous="$2" current name dir
    current="$(current_release "$domain")"
    dir="$(site_releases "$domain")"
    # shellcheck disable=SC2046
    for name in $(releases_to_delete "$KEEP_RELEASES" "$current" "$previous" $(release_names "$domain")); do
        [[ "$name" =~ $RELEASE_PATTERN ]] && [ -d "$dir/$name" ] && [ ! -L "$dir/$name" ] || continue
        run rm -rf -- "${dir:?}/$name"
        echo "Removed old release $name"
    done
}

# restart_workers <domain>: after the live code changed (deploy, rollback). Graceful: a worker
# finishes its current job, then exits; Supervisor starts it again with the new code. Which
# commands apply is read from the LIVE release's composer.lock (Horizon, Reverb). Needs SITE_PHP.
restart_workers() {
    local domain="$1" user cur lock
    user="$(site_user "$domain")"; cur="$(site_current "$domain")"; lock="$cur/composer.lock"
    if [ ! -f "$cur/artisan" ] || [ ! -f "$cur/.env" ]; then echo "Not a Laravel app with .env: nothing to restart."; return 0; fi
    php_as_site() { (cd "$cur" && runuser -u "$user" -- env HOME="$(site_home "$domain")" "php$SITE_PHP" artisan "$@"); }
    if php_as_site queue:restart; then check_pass "queue workers told to restart"; else check_warn "queue:restart" "failed (no cache store?)"; fi
    if grep -q '"name": "laravel/horizon"' "$lock" 2>/dev/null; then
        if php_as_site horizon:terminate; then check_pass "Horizon restarting"; else check_warn "horizon:terminate" "failed"; fi
    fi
    if grep -q '"name": "laravel/reverb"' "$lock" 2>/dev/null; then
        if php_as_site reverb:restart; then check_pass "Reverb restarting"; else check_warn "reverb:restart" "failed"; fi
    fi
    return 0
}

# ---------------------------------------------------------------------------------------------
# Workers and scheduler (item 21, decision 2). Everything for a site is named after its user:
#   Supervisor programs  $SUPERVISOR_DIR/<user>-worker.conf   queue:work (N processes)
#                        $SUPERVISOR_DIR/<user>-horizon.conf  horizon
#                        $SUPERVISOR_DIR/<user>-reverb.conf   reverb:start
#   scheduler            $CRON_DIR/servio-<user>               * * * * * schedule:run
#   log rotation         $LOGROTATE_DIR/servio-<user>          scheduler.log (Supervisor rotates
#                                                              its own logs: maxbytes/backups)
# Every program runs AS THE SITE'S USER, from `current` (a worker started after a deploy runs
# the new release), with the site's PHP version, and logs into shared/storage/logs.
# ---------------------------------------------------------------------------------------------
CRON_DIR="/etc/cron.d"
LOGROTATE_DIR="/etc/logrotate.d"
WORKER_KINDS="worker horizon reverb"
MAX_PROCESSES=8

worker_conf()    { echo "$SUPERVISOR_DIR/$(site_user "$1")-$2.conf"; }
scheduler_file() { echo "$CRON_DIR/servio-$(site_user "$1")"; }     # cron.d names: no dots
logrotate_file() { echo "$LOGROTATE_DIR/servio-$(site_user "$1")"; }

# worker_program <domain> <php> <kind> [queues] [processes]: one Supervisor program.
worker_program() {
    local domain="$1" php="$2" kind="$3" queues="${4:-default}" procs="${5:-1}" user cur logs command stopwait=60
    user="$(site_user "$domain")"; cur="$(site_current "$domain")"; logs="$(site_shared "$domain")/storage/logs"
    case "$kind" in
        # --max-time: each worker exits after an hour and Supervisor starts a fresh one (a slow
        # memory leak in app code never grows for days). --tries: a failing job isn't retried forever.
        worker)  command="/usr/bin/php$php $cur/artisan queue:work --queue=$queues --sleep=3 --tries=3 --max-time=3600" ;;
        # Horizon finishes running jobs before it stops: give it time.
        horizon) command="/usr/bin/php$php $cur/artisan horizon"; procs=1; stopwait=3600 ;;
        reverb)  command="/usr/bin/php$php $cur/artisan reverb:start --host=127.0.0.1 --port=8080"; procs=1 ;;
        *) die "worker_program: unknown kind $kind" ;;
    esac
    cat <<CONF
; $MANAGED_HEADER. $kind of $domain. Changes made by hand are overwritten (workers.sh).
[program:$user-$kind]
command=$command
directory=$cur
user=$user
environment=HOME="$(site_home "$domain")"
numprocs=$procs
process_name=%(program_name)s_%(process_num)02d
autostart=true
autorestart=true
startsecs=1
stopwaitsecs=$stopwait
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=$logs/$kind.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
CONF
}

# scheduler_cron <domain> <php>: Laravel's scheduler, every minute, as the site's user.
scheduler_cron() {
    local domain="$1" php="$2"
    cat <<CRON
# $MANAGED_HEADER. Laravel's scheduler for $1 (workers.sh). Changes made by hand are overwritten.
SHELL=/bin/sh
PATH=/usr/local/bin:/usr/bin:/bin
* * * * * $(site_user "$domain") cd $(site_current "$domain") && /usr/bin/php$php artisan schedule:run >> $(site_shared "$domain")/storage/logs/scheduler.log 2>&1
CRON
}

# logrotate_config <domain>: the scheduler's log (Supervisor's logs rotate themselves).
logrotate_config() {
    local user
    user="$(site_user "$1")"
    cat <<ROTATE
# $MANAGED_HEADER. Log rotation for $1.
$(site_shared "$1")/storage/logs/scheduler.log {
    su $user $user
    weekly
    rotate 4
    maxsize 10M
    compress
    missingok
    notifempty
    copytruncate
}
ROTATE
}

# site_has_scheduler <domain>: a cron line runs schedule:run for the site (ours, or the user's own).
site_has_scheduler() {
    grep -qs 'schedule:run' "$(scheduler_file "$1")" && return 0
    crontab -l -u "$(site_user "$1")" 2>/dev/null | grep -q 'schedule:run'
}

# site_worker_status <domain>: "name STATE" lines from supervisorctl for the site's programs.
site_worker_status() {
    command -v supervisorctl >/dev/null 2>&1 || return 0
    supervisorctl status 2>/dev/null | awk -v u="$(site_user "$1")-" 'index($1, u) == 1 { print $1, $2 }' \
        | grep -E '^[a-z0-9_:-]{1,100} [A-Z]{1,20}$' || true
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
    # site=: the domain the job works on (the first argument, when it is one), for deploy history.
    local job_site="server"
    if [[ "${1:-}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then job_site="$1"; fi
    printf '%s\n' "script=$SERVIO_SCRIPT_NAME" "user=${SUDO_USER:-root}" "site=$job_site" "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$dir/meta"
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
# servio_run_stream: for scripts whose stdout is DATA (backups): stdout goes out untouched (it is
# already encrypted with age, so there is nothing to mask, and masking would corrupt binary),
# every message goes to stderr, which IS masked. Only backup.sh on the laptop runs these, with
# stdout going into a file, never into the chat (run.sh refuses them otherwise).
say() { echo "$*" >&2; }
servio_run_stream() {
    exec 2> >(mask_output >&2)
    trap run_exit_hooks EXIT
    trap 'on_error $? "$BASH_COMMAND" >&2' ERR
    main "$@" < /dev/null
}

# servio_run_input: like servio_run, but main's stdin is DATA that follows the script on the same
# SSH stream (restore: the decrypted dump, sent by restore.sh on the laptop). bash reads a script
# from a pipe one byte at a time, so everything after this line is still there for main to read.
# The output is masked as usual. MUST be the very last line of the script.
servio_run_input() {
    local args=() arg
    for arg in "$@"; do
        if [ "$arg" = "--dry-run" ]; then DRY_RUN=1; else args+=("$arg"); fi
    done
    {
        trap run_exit_hooks EXIT
        trap 'on_error $? "$BASH_COMMAND"' ERR
        dry_run && echo "DRY RUN: nothing on the server will be changed."
        main "${args[@]+"${args[@]}"}"
    } 2>&1 | mask_output
    exit "${PIPESTATUS[0]}"
}

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
