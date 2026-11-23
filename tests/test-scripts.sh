#!/usr/bin/env bash
# Local checks that need no server: syntax of every script, the input validators, the nginx
# config renderer, the lib.sh building blocks (exit codes, dry run, safe writes, masking, log,
# lock, long jobs), and run.sh (what it sends, its refusals, connection errors) with a fake ssh.
#   bash tests/test-scripts.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/skills/server-ops/scripts"
fail=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }
# On a laptop some tests can't run (Windows has no flock or symlinks): say so. In CI (Linux) a
# skipped test is a failure, so nothing is ever silently left untested.
skip() { if [ -n "${CI:-}" ]; then bad "skipped in CI: $*"; else echo "skip  $*"; fi; }

echo "== Syntax (bash -n), alone and as the server sees it (lib.sh + script)"
for f in "$S"/*.sh "$ROOT"/hooks/*.sh; do bash -n "$f" && ok "bash -n $(basename "$f")" || bad "bash -n $f"; done
perl -c "$ROOT/hooks/servio-guard.pl" >/dev/null 2>&1 && ok "perl -c servio-guard.pl" || bad "perl -c servio-guard.pl"
for s in inventory provision-server create-site deploy-site issue-certificate delete-site fix-permissions job-status job-stop; do
    cat "$S/lib.sh" "$S/$s.sh" | bash -n && ok "lib.sh + $s.sh" || bad "lib.sh + $s.sh"
done

echo "== Validators (a subshell per check: die() exits)"
accept() { (source "$S/lib.sh"; "$1" "$2") >/dev/null 2>&1 && ok "$1 accepts '$2'" || bad "$1 should accept '$2'"; }
reject() { (source "$S/lib.sh"; "$1" "$2") >/dev/null 2>&1 && bad "$1 should reject '$2'" || ok "$1 rejects '$2'"; }

accept validate_domain example.com
accept validate_domain app.shop-1.co.uk
reject validate_domain Example.com
reject validate_domain 'example.com;reboot'
reject validate_domain ../etc
reject validate_domain -bad.com
reject validate_domain 'a.b'
reject validate_domain 'example.com/x'
accept validate_web_dir public
accept validate_web_dir dist/public
reject validate_web_dir ../x
reject validate_web_dir public/..
reject validate_web_dir ./public
reject validate_web_dir /abs
accept validate_php 8.4
reject validate_php 8.2
reject validate_php '8.4 && reboot'
accept validate_repository git@github.com:acme/shop.git
accept validate_repository https://github.com/acme/shop
accept validate_repository https://git.example.com:8443/acme/shop.git
reject validate_repository 'git@github.com:-oProxyCommand=x'
reject validate_repository 'https://github.com/-acme/shop'
reject validate_repository 'file:///etc/passwd'
reject validate_repository 'ext::sh -c reboot'
accept validate_branch main
accept validate_branch feature/x-1
reject validate_branch -f
reject validate_branch a..b
reject validate_branch foo.lock
reject validate_branch 'a b'
reject validate_public_domain shop.test
accept validate_public_domain shop.example.com

echo "== Site layout: one Linux user per site (decision 6)"
su_of() { (source "$S/lib.sh"; site_user "$1"); }
u="$(su_of shop.example.com)"
[[ "$u" =~ ^s_[a-z0-9]{0,16}_[0-9a-f]{6}$ ]] && ok "site user looks like s_<letters>_<6 hex>: $u" || bad "site user '$u'"
[ "$u" = "$(su_of shop.example.com)" ] && ok "the same domain always gives the same user" || bad "site_user isn't stable"
[ "$u" != "$(su_of shop-example.com)" ] && ok "look-alike domains get different users ($(su_of shop-example.com))" || bad "shop.example.com and shop-example.com share a user"
long="$(su_of a-very-long-subdomain-name.example.co.uk)"
[ "${#long}" -le 32 ] && [[ "$long" =~ ^s_ ]] && ok "long domains stay within Linux's 32 characters (${#long}: $long)" || bad "long site user '$long'"
[[ "$(su_of 1st.example.com)" =~ ^s_1st ]] && ok "a domain starting with a digit still gives a valid name (starts with 's_')" || bad "digit domain"
layout="$(source "$S/lib.sh"; site_dir shop.example.com; deploy_key_path shop.example.com; pool_file shop.example.com 8.4; pool_socket shop.example.com 8.4)"
for want in "/home/$u/shop.example.com" "/home/$u/.ssh/deploy_key" "/etc/php/8.4/fpm/pool.d/$u.conf" "/run/php/php8.4-fpm-$u.sock"; do
    [[ "$layout" == *"$want"* ]] && ok "layout: $want" || bad "layout lacks $want: $layout"
done

echo "== PHP-FPM pool renderer"
pool="$(source "$S/lib.sh"; php_pool_config shop.example.com 8.4)"
for want in "[$u]" "user = $u" "group = $u" "listen = /run/php/php8.4-fpm-$u.sock" "listen.owner = www-data" \
            "listen.mode = 0660" "pm = ondemand" "pm.max_children = 5" "php_admin_value[upload_tmp_dir] = /home/$u/tmp" \
            "php_admin_value[session.save_path] = /home/$u/tmp" "security.limit_extensions = .php" "Managed by Servio"; do
    printf '%s\n' "$pool" | grep -qF -- "$want" && ok "pool has: $want" || bad "pool missing: $want"
done
! printf '%s\n' "$pool" | grep -qE '^user = (root|www-data|servio)$' && ok "the pool never runs as root, www-data or a shared user" || bad "pool runs as a shared user"

echo "== nginx config renderer"
cfg="$(source "$S/lib.sh"; nginx_https_config shop.example.com "/home/$u/shop.example.com/public" 8.4)"
for want in '# Managed by Servio' 'server_name shop.example.com;' "root /home/$u/shop.example.com/public;" \
            "fastcgi_pass unix:/run/php/php8.4-fpm-$u.sock;" 'try_files $uri $uri/ /index.php?$query_string;' \
            'return 301 https://$host$request_uri;' 'location ~ ^/index\.php(/|$) {' \
            'fastcgi_split_path_info ^(.+\.php)(/.*)$;' 'fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;' \
            'ssl_certificate_key /etc/letsencrypt/live/shop.example.com/privkey.pem;' 'root /var/www/letsencrypt;' \
            'location ~ /\.(?!well-known).* {'; do
    printf '%s\n' "$cfg" | grep -qF -- "$want" && ok "https has: $want" || bad "https missing: $want"
done
[ "$(printf '%s\n' "$cfg" | grep -c '{')" = "$(printf '%s\n' "$cfg" | grep -c '}')" ] && ok "https braces balance" || bad "https braces don't balance"
http="$(source "$S/lib.sh"; nginx_http_config shop.example.com "/home/$u/shop.example.com/public" 8.4)"
printf '%s\n' "$http" | grep -q 'listen 443' && bad "http config has 443" || ok "http config has no 443"

echo "== read_site_settings reads web dir + PHP back from a rendered config"
tmp="$(mktemp -d)"
got="$(source "$S/lib.sh"; nginx_available() { echo "$tmp/$1"; }
       nginx_http_config shop.example.com "$(site_dir shop.example.com)/dist/public" 8.3 > "$tmp/shop.example.com"
       read_site_settings shop.example.com; echo "$SITE_WEB_DIR $SITE_PHP")"
[ "$got" = "dist/public 8.3" ] && ok "read back web dir and PHP from the site's own pool socket: $got" || bad "read back '$got'"
(source "$S/lib.sh"; nginx_available() { echo "$tmp/$1"; }
 nginx_http_config other.example.com "$(site_dir shop.example.com)/public" 8.4 > "$tmp/other.example.com"
 read_site_settings other.example.com) >/dev/null 2>&1
[ $? = 3 ] && ok "a root outside the site's own folder is refused (exit 3)" || bad "root outside the site's folder accepted"
(source "$S/lib.sh"; nginx_available() { echo "$tmp/$1"; }
 echo "server { root /var/www; }" > "$tmp/hand.example.com"
 read_site_settings hand.example.com) >/dev/null 2>&1
[ $? = 4 ] && ok "hand-made config refused (exit 4)" || bad "hand-made config should be refused with exit 4"
rm -rf "$tmp"

# A tiny script run the way the server runs it: lib.sh + script through `bash -s`.
T="$(mktemp -d)"
as_server() { # $1 = script body (defines main); rest = args. Prints output; returns the exit code.
    printf '%s\nservio_run "$@"\n' "$1" > "$T/s.sh"; shift
    cat "$S/lib.sh" "$T/s.sh" | bash -s -- "$@" 2>&1
}
expect_exit() { # $1 expected code, $2 label, $3 body, rest args
    local want="$1" label="$2" body="$3"; shift 3
    as_server "$body" "$@" > "$T/out"; local got=$?
    [ "$got" = "$want" ] && ok "exit $want: $label" || { bad "$label: exit $got, want $want"; sed 's/^/        /' "$T/out"; }
}

echo "== Exit codes (item 50)"
expect_exit 0 "done"                'main() { echo hi; }'
expect_exit 2 "wrong input"         'main() { validate_domain "Bad.com"; }'
expect_exit 3 "server not ready"    'main() { die_state "not provisioned"; }'
expect_exit 4 "refused"             'main() { die_refused "no"; }'
expect_exit 5 "missing tool"        'main() { require_cmd no-such-tool-xyz; }'
expect_exit 1 "a failing command"   'main() { false; echo never; }'
expect_exit 1 "a command that returns 2 is still 1, not 'wrong input'" 'main() { grep -q x /nonexistent/file; }'
expect_exit 3 "die inside a function called from main" 'f() { die_state x; }; main() { f; echo never; }'
out="$(as_server 'main() { false; }')"
[[ "$out" == *"a command failed (exit 1): false"* ]] && ok "a failing command is named in the error" || bad "failing command not named: $out"

echo "== Dry run (item 48)"
out="$(as_server 'main() { run touch /root/should-not-exist; echo "args=$*"; }' a --dry-run b)"
[[ "$out" == *"[dry-run] would run: touch /root/should-not-exist"* ]] && ok "run() only prints in a dry run" || bad "run() in dry run: $out"
[[ "$out" == *"args=a b"* ]] && ok "--dry-run is taken out of the arguments, wherever it is" || bad "args with --dry-run: $out"
[[ "$out" == *"DRY RUN: nothing on the server will be changed."* ]] && ok "a dry run says so first" || bad "no dry-run banner"
out="$(as_server 'main() { run echo really-ran; }')"
[[ "$out" == *"really-ran"* && "$out" != *"[dry-run]"* ]] && ok "run() runs without --dry-run" || bad "run() normal: $out"

echo "== Safe file changes (item 51)"
me="$(id -u):$(id -g)"
d="$T/files"; mkdir -p "$d"
(source "$S/lib.sh"; echo one | write_file "$d/f" 644 "$me") && [ "$(cat "$d/f")" = "one" ] && ok "write_file creates a file" || bad "write_file create"
(source "$S/lib.sh"; echo two | write_file "$d/f" 644 "$me") && [ "$(cat "$d/f")" = "two" ] && ls "$d"/f.bak-* >/dev/null 2>&1 \
    && ok "write_file replaces it and keeps a .bak copy" || bad "write_file replace/backup"
[ -z "$(ls -A "$d" | grep servio-tmp)" ] && ok "no temporary file left behind" || bad "temp file left in $d"
before="$(ls "$d" | wc -l)"
(source "$S/lib.sh"; echo two | write_file "$d/f" 644 "$me")
[ "$(ls "$d" | wc -l)" = "$before" ] && ok "same content: no new backup" || bad "unchanged write made a backup"
for i in 1 2 3 4 5; do touch "$d/f.bak-2026010100000$i"; done
(source "$S/lib.sh"; prune_backups "$d/f" 3)
[ "$(ls "$d"/f.bak-* | wc -l)" = 3 ] && ok "only the 3 newest backups are kept" || bad "prune_backups kept $(ls "$d"/f.bak-* | wc -l)"
out="$(source "$S/lib.sh"; DRY_RUN=1; echo three | write_file "$d/f" 644 "$me")"
[ "$(cat "$d/f")" = "two" ] && [[ "$out" == *"would change $d/f"* && "$out" == *"+three"* ]] \
    && ok "dry run shows a diff and changes nothing" || bad "write_file dry run: $out"
out="$(source "$S/lib.sh"; DRY_RUN=1; echo x | write_file "$d/new" 644 "$me")"
[ ! -e "$d/new" ] && [[ "$out" == *"would create $d/new"* ]] && ok "dry run of a new file creates nothing" || bad "dry run new file: $out"
if ln -s "$d/f" "$d/link" 2>/dev/null && [ -L "$d/link" ]; then
    (source "$S/lib.sh"; echo y | write_file "$d/link" 644 "$me") >/dev/null 2>&1
    [ $? = 4 ] && [ "$(cat "$d/f")" = "two" ] && ok "never writes through a symlink (exit 4)" || bad "wrote through a symlink"
else
    skip "symlink test (this system can't make symlinks)"
fi

echo "== Exit hooks run however the script ends"
out="$(as_server 'main() { add_exit_hook "echo cleanup-1"; add_exit_hook "echo cleanup-2"; die_refused stop; }')"
[[ "$out" == *"cleanup-1"*"cleanup-2"* ]] && ok "all hooks run after a die" || bad "hooks: $out"

echo "== Four results (item 49)"
out="$(as_server 'main() { check_pass a; check_warn b w; check_na c "no tool"; check_summary && echo SUMMARY-OK; check_fail d; check_summary || echo SUMMARY-FAILED; }')"
[[ "$out" == *"NOT ASSESSED  c: no tool"* ]] && ok "NOT ASSESSED is its own result" || bad "check_na: $out"
[[ "$out" == *"SUMMARY-OK"* && "$out" == *"1 failed"* && "$out" == *"SUMMARY-FAILED"* ]] \
    && ok "summary fails only when something FAILED" || bad "check_summary: $out"

echo "== Secrets masked in all output (item 68)"
mask() { printf '%s\n' "$1" | (source "$S/lib.sh"; mask_output); }
masked() { local got; got="$(mask "$1")"; [[ "$got" == *"$2"* && "$got" != *"$3"* ]] && ok "masks: $1" || bad "mask '$1' gave '$got'"; }
kept()   { local got; got="$(mask "$1")"; [ "$got" = "$1" ] && ok "keeps: $1" || bad "should keep '$1', gave '$got'"; }
masked "mysql://app:S3cr3t@db/x" "app:***@" "S3cr3t"
masked "DB_PASSWORD=hunter2" "DB_PASSWORD=***" "hunter2"
masked 'MAIL_PASSWORD: "a b c"' "MAIL_PASSWORD: ***" "a b c"
masked "APP_KEY=base64:abcdefgh" "APP_KEY=***" "abcdefgh"
masked "Authorization: Bearer abc.def" "Bearer ***" "abc.def"
masked "token sk-ABCDEFGHIJKLMNOPQRSTUVWX" "***" "sk-ABCD"
masked "ghp_abcdefghijklmnopqrstuvwxyz0123" "***" "ghp_"
masked "AKIAABCDEFGHIJKLMNOP" "***" "AKIA"
masked "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdefghijkl" "***" "eyJhbGci"
masked "random Q2x9ZkPq7LmN4sT8vW1yB6cD3eF5gH0jK" "random ***" "Q2x9"
kept "SERVIO_DEPLOY_KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl servio-deploy@shop.example.com"
kept "SERVIO_COMMIT=3f2a9c1b7e4d5f60718293a4b5c6d7e8f9012345"
kept "/home/s_shopexamplecom_951623/shop.example.com/releases/20261123120000-3f2a9c1"
kept "no passwords here: tokens are fine"
got="$(printf '%s\n' before "-----BEGIN OPENSSH PRIVATE KEY-----" b3BlbnNzaC1rZXktdjE "-----END OPENSSH PRIVATE KEY-----" after | (source "$S/lib.sh"; mask_output))"
[ "$got" = "$(printf '%s\n' before "[private key hidden]" after)" ] && ok "masks a whole private key block" || bad "key block: $got"
out="$(as_server 'main() { echo "DB_PASSWORD=hunter2"; echo "PASS=x" >&2; }')"
[[ "$out" != *hunter2* ]] && ok "servio_run masks everything a script prints" || bad "servio_run didn't mask: $out"

echo "== Action log line (item 40)"
out="$(source "$S/lib.sh"; ACTION_LOG="$T/action.log"; LOGROTATE_FILE="$T/logrotate"; SERVIO_SCRIPT_NAME=create-site.sh SERVIO_SCRIPT_SHA256=abc123 \
       SERVIO_PLUGIN_VERSION=0.2.0; install() { :; }; begin_change shop.example.com shop.example.com public 8.4
       SERVIO_RC=0; write_action_log 2>/dev/null; cat "$ACTION_LOG")"
for want in "via=servio-agent" "version=0.2.0" "script=create-site.sh" "sha256=abc123" "approval=fresh" \
            "site=shop.example.com" "args=[shop.example.com public 8.4]" "result=ok" "exit=0"; do
    [[ "$out" == *"$want"* ]] && ok "log has $want" || bad "log line lacks $want: $out"
done
out="$(source "$S/lib.sh"; ACTION_LOG="$T/a2.log"; install() { :; }; DRY_RUN=1; begin_change x.example.com; echo "${EXIT_HOOKS[*]-none}")"
[[ "$out" != *write_action_log* ]] && ok "dry runs are not logged" || bad "dry run registered the log hook"

echo "== Site lock (item 69)"
if command -v flock >/dev/null 2>&1; then
    # Not `lock_site … && ( … ); echo`: with set -e (from lib.sh), a failing LAST command of an
    # && list ends the subshell before the echo. `|| echo` keeps going and still sees the code.
    out="$(source "$S/lib.sh"; LOCK_DIR="$T/locks"; install() { mkdir -p "${@: -1}"; }; SERVIO_SCRIPT_NAME=deploy-site.sh
           lock_site shop.example.com
           ( lock_site shop.example.com ) 2>&1 || echo "second=$?")"
    [[ "$out" == *"Another change is running on shop.example.com (deploy-site.sh by"* && "$out" == *"second=3"* ]] \
        && ok "a second change on the same site stops (exit 3) and says who holds it" || bad "lock: $out"
else
    skip "site lock test: no flock here (runs on Linux and in CI)"
fi

echo "== Inventory on a fake server (item 56: fixtures in tests/fixtures/inventory)"
F="$ROOT/tests/fixtures/inventory"
srv="$T/srv"
# The new layout (v0.3): /home/<site user>/<domain>. lib.sh works out the paths, pointed at $srv.
lay() { (source "$S/lib.sh"; HOME_BASE="$srv/home"; PHP_ETC_DIR="$srv/etc/php"; "$@"); }
shop_dir="$(lay site_dir shop.example.com)"; evil_dir="$(lay site_dir evil.example.com)"
mkdir -p "$srv/etc/nginx/sites-available" "$srv/etc/nginx/sites-enabled" \
    "$(dirname "$(lay deploy_key_path shop.example.com)")" "$(dirname "$(lay pool_file shop.example.com 8.4)")"
# shop.example.com: managed, HTTPS, deployed from git, Laravel, .env present, deploy key, a pool.
(source "$S/lib.sh"; LETSENCRYPT_DIR="$srv/etc/letsencrypt"
 nginx_https_config shop.example.com "$shop_dir/public" 8.4) > "$srv/etc/nginx/sites-available/shop.example.com"
mkdir -p "$shop_dir/public" "$srv/etc/letsencrypt/live/shop.example.com"
cp "$F/shop.composer.lock" "$shop_dir/composer.lock"
touch "$shop_dir/.env" "$(lay deploy_key_path shop.example.com).pub"
lay php_pool_config shop.example.com 8.4 > "$(lay pool_file shop.example.com 8.4)"
( cd "$shop_dir" && git init -q -b main && git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init )
# Git Bash turns arguments that look like paths into Windows paths for native programs like
# openssl: "/CN=…" would become "C:/Program Files/Git/CN=…". Exclude only that argument (file
# paths must still be converted). Linux ignores this variable.
MSYS2_ARG_CONV_EXCL="/CN=" openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=shop.example.com" \
    -keyout "$T/test-only.key" -out "$srv/etc/letsencrypt/live/shop.example.com/fullchain.pem" >/dev/null 2>&1
# evil.example.com: managed, HTTP only, a composer.lock that tries to give the AI instructions.
(source "$S/lib.sh"; nginx_http_config evil.example.com "$evil_dir/public" 8.3) > "$srv/etc/nginx/sites-available/evil.example.com"
mkdir -p "$evil_dir"; cp "$F/evil.composer.lock" "$evil_dir/composer.lock"
# static.example.com: hand-made, no PHP at all. "default": nginx's own, not a Servio site.
cp "$F/handmade.nginx.conf" "$srv/etc/nginx/sites-available/static.example.com"
echo "server {}" > "$srv/etc/nginx/sites-available/default"
for f in shop.example.com evil.example.com static.example.com default; do      # copies: Windows has no symlinks
    cp "$srv/etc/nginx/sites-available/$f" "$srv/etc/nginx/sites-enabled/$f"
done
inv="$(source "$S/lib.sh"; source <(sed '/^servio_run "\$@"$/d' "$S/inventory.sh")
       NGINX_DIR="$srv/etc/nginx"; LETSENCRYPT_DIR="$srv/etc/letsencrypt"; HOME_BASE="$srv/home"; PHP_ETC_DIR="$srv/etc/php"
       runuser() { shift 3; "$@"; }                    # runuser -u <user> -- cmd  ->  cmd
       id() { [ "$1" = "$(site_user shop.example.com)" ]; }   # only shop.example.com's user exists
       sites_report 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "inventory's site report runs to the end (exit 0)" || bad "sites_report exit $rc: $inv"
section() { printf '%s\n' "$inv" | sed -n "/^- $1\$/,/^\$/p"; }
shop="$(section shop.example.com)"
for want in "managed:   yes" "user:      $(lay site_user shop.example.com)" "php:       8.4 (pool: PHP 8.4, configured but NOT running)" "ssl:       HTTPS, certificate valid until" "(branch main)" "laravel:   13.2.1" ".env:      present" "deploy key: present"; do
    [[ "$shop" == *"$want"* ]] && ok "shop.example.com: $want" || bad "shop.example.com lacks '$want': $shop"
done
[[ "$shop" =~ deployed:\ +[0-9a-f]{7} ]] && ok "shop.example.com: deployed commit shown as a short hash" || bad "no commit hash: $shop"
evil="$(section evil.example.com)"
[[ "$evil" == *"laravel:   not a Laravel app (or unknown)"* && "$evil" != *IGNORE* ]] \
    && ok "evil.example.com: an injected 'version' never reaches the output" || bad "injection got through: $evil"
[[ "$evil" == *"ssl:       HTTP only (no certificate)"* && "$evil" == *".env:      missing"* && "$evil" == *"deployed:  not deployed"* \
   && "$evil" == *"user:      none (no site user"* && "$evil" == *"(pool: none)"* ]] \
    && ok "evil.example.com: HTTP only, no .env, not deployed, no site user, no pool" || bad "evil.example.com: $evil"
static="$(section static.example.com)"
[[ "$static" == *"managed:   no (hand-made config)"* && "$static" == *"php:       none"* ]] \
    && ok "static.example.com: hand-made, no PHP (and the inventory didn't stop on it)" || bad "static.example.com: $static"
[[ "$inv" == *"- default (not a Servio site)"* ]] && ok "nginx's 'default' is listed, not inspected" || bad "default: $inv"
[[ "$inv" != *"ERROR"* ]] && ok "no errors in the report" || bad "errors in report: $inv"

echo "== run.sh: what it sends, and how it reports connection problems (fake ssh)"
mkdir -p "$T/bin"
cat > "$T/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
# Fake ssh: saves its arguments and what it was sent; behaves as told by FAKE_SSH.
printf '%s\n' "$@" > "$FAKE_DIR/args"; cat > "$FAKE_DIR/payload"
case "${FAKE_SSH:-ok}" in
    ok) echo "remote ran"; exit 0 ;;
    changed) echo "@@@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@@@" >&2; exit 255 ;;
    unknown) echo "Host key verification failed." >&2; exit 255 ;;
    down) echo "ssh: connect to host web1 port 22: Connection timed out" >&2; exit 255 ;;
    sudo) echo "sudo: a password is required" >&2; exit 1 ;;
    code3) exit 3 ;;
esac
FAKE
chmod +x "$T/bin/ssh"
fake_run() { FAKE_DIR="$T" PATH="$T/bin:$PATH" bash "$S/run.sh" "$@" > "$T/run.out" 2>&1; }
FAKE_SSH=ok fake_run web1 create-site.sh shop.example.com public 8.4 --dry-run; rc=$?
[ "$rc" = 0 ] && ok "run.sh passes the script's exit code (0)" || bad "run.sh ok exit $rc"
grep -qx -- "StrictHostKeyChecking=yes" "$T/args" && ok "ssh gets StrictHostKeyChecking=yes (item 36)" || bad "no StrictHostKeyChecking=yes: $(tr '\n' ' ' < "$T/args")"
grep -qx -- "BatchMode=yes" "$T/args" && ok "ssh gets BatchMode=yes" || bad "no BatchMode=yes"
grep -qx -- "--dry-run" "$T/args" && ok "--dry-run reaches the server" || bad "--dry-run not passed"
head -n 4 "$T/payload" | grep -q "^SERVIO_SCRIPT_NAME='create-site.sh'$" && ok "payload starts with the script name" || bad "payload header: $(head -4 "$T/payload")"
sha="$(sed -n "s/^SERVIO_SCRIPT_SHA256='\(.*\)'$/\1/p" "$T/payload")"
[ "$sha" = "$(tail -n +6 "$T/payload" | sha256sum | cut -d" " -f1)" ] && ok "SHA-256 in the header matches exactly what was sent" || bad "sha mismatch: $sha"
grep -q "^SERVIO_PLUGIN_VERSION='[0-9]" "$T/payload" && ok "plugin version is sent" || bad "no plugin version"
grep -q $'\r' "$T/payload" && bad "payload contains CR characters" || ok "payload has no Windows line endings"
FAKE_SSH=changed fake_run web1 inventory.sh; rc=$?
[ "$rc" = 6 ] && grep -q "has CHANGED" "$T/run.out" && ok "changed host key: exit 6 and a clear STOP message" || bad "changed key: rc=$rc $(cat "$T/run.out")"
FAKE_SSH=unknown fake_run web1 inventory.sh; rc=$?
[ "$rc" = 6 ] && grep -q "isn't known yet" "$T/run.out" && ok "unknown host: exit 6, says to connect by hand once" || bad "unknown host: rc=$rc"
FAKE_SSH=down fake_run web1 inventory.sh; rc=$?
[ "$rc" = 6 ] && grep -q "Couldn't connect" "$T/run.out" && ok "server down: exit 6" || bad "down: rc=$rc"
FAKE_SSH=sudo fake_run web1 inventory.sh; rc=$?
[ "$rc" = 3 ] && grep -q "passwordless sudo" "$T/run.out" && ok "sudo needs a password: exit 3, explained" || bad "sudo: rc=$rc"
FAKE_SSH=code3 fake_run web1 inventory.sh; rc=$?
[ "$rc" = 3 ] && ok "the script's own exit code comes through (3)" || bad "code3: rc=$rc"

echo "== Long jobs (item 45), in the foreground fallback (no systemd in tests)"
stub='require_root() { :; }; has_systemd() { false; }; JOBS_DIR='"$T"'/jobs'
{ cat "$S/lib.sh"; echo "$stub"; echo "SERVIO_SCRIPT_NAME=deploy-site.sh"; echo "servio_launch_job a b <<'M1'"
  cat "$S/lib.sh"; echo 'main() { echo "job args: $*"; printf "step 10%%\rstep 50%%\rstep 100%%\n"; echo "DB_PASSWORD=hunter2"; sleep 3; echo after-sleep; die_state "pretend"; }'
  echo 'servio_run "$@"'; echo M1; } | bash -s > "$T/job.out" 2>&1; rc=$?
[ "$rc" = 3 ] && ok "follow mode exits with the job's own exit code (3)" || bad "job exit $rc: $(cat "$T/job.out")"
grep -q "^job args: a b$" "$T/job.out" && grep -q "^after-sleep$" "$T/job.out" && ok "follow mode prints the job's output live, to the end" || bad "job output: $(cat "$T/job.out")"
grep -qx "step 100%" "$T/job.out" && ! grep -q "step 10%" "$T/job.out" && ok "progress bars collapse to their last line" || bad "progress: $(grep step "$T/job.out")"
! grep -q hunter2 "$T/job.out" && ok "a job's output is masked too" || bad "job output not masked"
id="$(ls "$T/jobs" | head -n 1)"
[[ "$id" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$ ]] && ok "job id looks like 20261123-140501-a1b2c3: $id" || bad "job id '$id'"
jstatus() { { cat "$S/lib.sh"; echo "$stub"; cat "$S/job-status.sh"; } | bash -s -- "$@" 2>&1; }
out="$(jstatus "$id" 0)"
[[ "$out" == *"SERVIO_JOB_STATE=finished"* && "$out" == *"SERVIO_JOB_EXIT=3"* && "$out" == *"after-sleep"* ]] \
    && ok "job-status: state, exit code and output" || bad "job-status: $out"
off="$(printf '%s\n' "$out" | sed -n 's/^SERVIO_JOB_OFFSET=//p')"
out="$(jstatus "$id" "$off")"
[[ "$out" != *"after-sleep"* && "$out" == *"SERVIO_JOB_OFFSET=$off"* ]] && ok "job-status from an offset prints only new output" || bad "offset: $out"
out="$(jstatus)"
[[ "$out" == *"$id  deploy-site.sh"*"finished"* ]] && ok "job-status without an id lists recent jobs" || bad "job list: $out"
jstatus "x;rm" >/dev/null; [ $? = 2 ] && ok "job-status refuses a bad job id (exit 2)" || bad "bad job id accepted"
jstatus 20991231-235959-abcdef >/dev/null; [ $? = 3 ] && ok "job-status: unknown job is exit 3" || bad "unknown job"

echo "== run.sh wraps long scripts as jobs"
FAKE_SSH=ok fake_run web1 deploy-site.sh shop.example.com main
grep -q '^servio_launch_job "\$@" <<'"'"'SERVIO_JOB_[0-9a-f]\{16\}'"'"'$' "$T/payload" && ok "deploy is sent as a job (heredoc with a random marker)" || bad "deploy not wrapped: $(grep -n launch "$T/payload")"
marker="$(sed -n "s/^servio_launch_job \"\$@\" <<'\(SERVIO_JOB_[0-9a-f]*\)'$/\1/p" "$T/payload")"
[ "$(tail -n 1 "$T/payload")" = "$marker" ] && [ "$(grep -c "$marker" "$T/payload")" = 2 ] && ok "the marker appears only to open and close the heredoc" || bad "marker use"
grep -q "^SERVIO_JOB_MODE='follow'$" "$T/payload" && ok "follow mode by default" || bad "no follow mode"
FAKE_SSH=ok fake_run web1 provision-server.sh 8.4 --detach
grep -q "^SERVIO_JOB_MODE='detach'$" "$T/payload" && ok "--detach sets detach mode" || bad "no detach mode"
! grep -qx -- "--detach" "$T/args" && ok "--detach is for run.sh only, not sent to the script" || bad "--detach was passed on"
launcher='^servio_launch_job "\$@" <<'   # single quotes: $@ must stay literal, not expand here
FAKE_SSH=ok fake_run web1 deploy-site.sh shop.example.com --dry-run
! grep -q "$launcher" "$T/payload" && ok "a dry run is never a job" || bad "dry run was wrapped as a job"
FAKE_SSH=ok fake_run web1 create-site.sh shop.example.com
! grep -q "$launcher" "$T/payload" && ok "short scripts (create-site) run directly" || bad "create-site was wrapped"
FAKE_SSH=ok fake_run web1 deploy-site.sh shop.example.com
grep -q "$launcher" "$T/payload" && ok "(the same check does see a real job)" || bad "launcher check can't see a job"

echo "== run.sh refuses bad input before any ssh (exit 2)"
refuse() { FAKE_DIR="$T" PATH="$T/bin:$PATH" bash "$S/run.sh" "$@" >/dev/null 2>&1; local rc=$?
           [ "$rc" = 2 ] && ok "run.sh refuses: $*" || bad "run.sh should refuse ($rc): $*"; }
rm -f "$T/args"
refuse '-oProxyCommand=calc' inventory.sh
refuse web1 'rm.sh'
refuse web1 ../lib.sh
refuse web1 create-site.sh 'shop.com;reboot'
refuse web1 create-site.sh 'shop.com public' 8.4
refuse web1 deploy-site.sh 'shop.com' '$(reboot)'
refuse web1
[ ! -e "$T/args" ] && ok "ssh was never called for refused input" || bad "ssh was called for refused input"

rm -rf "$T"
[ "$fail" = 0 ] && echo "All script tests passed." || { echo "Some script tests FAILED."; exit 1; }
