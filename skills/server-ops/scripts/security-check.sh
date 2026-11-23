#!/usr/bin/env bash
# security-check.sh: how well is this server locked down? (item 7). READ-ONLY: changes nothing.
#
#   bash run.sh <host> security-check.sh             # everything (composer audit needs internet)
#   bash run.sh <host> security-check.sh no-audit    # skip composer audit (faster, offline)
#
# Every item is PASS / WARN / FAIL / NOT ASSESSED (a check that couldn't run is never a PASS),
# then a summary. Exit 0 when the report ran: findings are in the report, not the exit code.
#
#   updates      security updates waiting; automatic security updates on
#   ssh          from `sshd -T` (what sshd REALLY uses, includes and overrides applied): root
#                login, password / keyboard-interactive login, empty passwords, MaxAuthTries
#   firewall     UFW on, incoming denied by default; fail2ban running and its jails
#   databases    MySQL, Redis, Postgres, memcached, MongoDB not listening for everyone
#   php          expose_php, display_errors, session cookie flags AS PHP-FPM USES THEM (the
#                fpm php.ini, not the command line's: a common mistake)
#   certificates days left; the renewal timer on
#   accounts     extra UID 0 accounts; accounts with an empty password
#   permissions  .env files, /etc/shadow, sshd_config, world-writable files in sites
#   sites        composer audit (known vulnerable packages); APP_DEBUG on (yes/no only)
#   docker       container ports published to the internet (Docker bypasses UFW!)
#
# Secrets: .env is never printed. For APP_DEBUG only "on" or "off" comes out; /etc/shadow is only
# tested for EMPTY password fields, and only user names are printed, never hashes.

ETC_DIR="/etc"
DB_PORTS="3306:MySQL 33060:MySQL-X 5432:Postgres 6379:Redis 11211:memcached 27017:MongoDB"

main() {
    local audit=1
    case "${1:-}" in
        "") ;;
        no-audit) audit=0 ;;
        *) die_input "Usage: security-check.sh [no-audit]" ;;
    esac
    require_root

    step "Updates";      check_updates
    step "SSH";          check_ssh "$(sshd -T 2>/dev/null || true)"
    step "Firewall";     check_firewall
    step "Databases";    check_db_ports "$(ss -Hltn 2>/dev/null || true)"
    step "PHP (as PHP-FPM uses it)"; check_php
    step "Certificates"; check_certificates
    step "Accounts";     check_accounts "$ETC_DIR/passwd" "$ETC_DIR/shadow"
    step "Permissions";  check_permissions
    step "Sites";        check_sites "$audit"
    step "Docker";       check_docker

    step "Summary"
    check_summary || true
}

check_updates() {
    local n
    if ! command -v apt >/dev/null 2>&1; then check_na "security updates" "no apt"; return; fi
    # From the local package lists (as fresh as the last `apt update`, which unattended-upgrades runs daily).
    n="$(apt list --upgradable 2>/dev/null | grep -c -- '-security' || true)"
    if [ "${n:-0}" -gt 0 ]; then check_warn "security updates" "$n waiting"
    else check_pass "security updates" "none waiting"; fi
    if grep -qsE '^\s*APT::Periodic::Unattended-Upgrade\s+"1"' "$ETC_DIR"/apt/apt.conf.d/*; then
        check_pass "automatic security updates" "on"
    else
        check_warn "automatic security updates" "off (unattended-upgrades not enabled)"
    fi
}

# check_ssh <sshd -T output>: lower-case "key value" lines.
check_ssh() {
    local t="$1" v
    if [ -z "$t" ]; then check_na "ssh" "sshd -T gave nothing (sshd missing, or its config has an error)"; return; fi
    v="$(printf '%s\n' "$t" | awk '$1 == "permitrootlogin" {print $2}')"
    case "$v" in
        no) check_pass "root login" "no" ;;
        prohibit-password|without-password) check_warn "root login" "with a key only (better: log in as a user with sudo)" ;;
        forced-commands-only) check_pass "root login" "forced commands only" ;;
        yes) check_fail "root login" "allowed, with a password too" ;;
        *) check_na "root login" "unknown value" ;;
    esac
    v="$(printf '%s\n' "$t" | awk '$1 == "passwordauthentication" {print $2}')"
    [ "$v" = "no" ] && check_pass "password login" "off" || check_fail "password login" "on: bots can guess passwords"
    v="$(printf '%s\n' "$t" | awk '$1 == "kbdinteractiveauthentication" || $1 == "challengeresponseauthentication" {print $2; exit}')"
    [ "$v" = "yes" ] && check_warn "keyboard-interactive login" "on (with PAM it can ask for a password even when password login is off)" \
        || check_pass "keyboard-interactive login" "off"
    v="$(printf '%s\n' "$t" | awk '$1 == "permitemptypasswords" {print $2}')"
    [ "$v" = "yes" ] && check_fail "empty passwords" "allowed" || check_pass "empty passwords" "not allowed"
    v="$(printf '%s\n' "$t" | awk '$1 == "maxauthtries" {print $2}')"
    if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -le 6 ]; then check_pass "MaxAuthTries" "$v"
    else check_warn "MaxAuthTries" "${v:-unknown} (6 or less is usual)"; fi
}

check_firewall() {
    local status jails
    if command -v ufw >/dev/null 2>&1; then
        status="$(ufw status verbose 2>/dev/null || true)"
        if printf '%s\n' "$status" | grep -q '^Status: active'; then
            if printf '%s\n' "$status" | grep -qE '^Default: (deny|reject) \(incoming\)'; then
                check_pass "firewall" "on, incoming denied by default"
            else
                check_fail "firewall" "on, but incoming is ALLOWED by default"
            fi
        else
            check_fail "firewall" "UFW is off"
        fi
    else
        check_na "firewall" "ufw not installed"
    fi
    if command -v fail2ban-client >/dev/null 2>&1; then
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            jails="$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:\s*//p' | tr -cd 'A-Za-z0-9_, -' || true)"
            check_pass "fail2ban" "running, jails: ${jails:-none}"
        else
            check_warn "fail2ban" "installed but not running"
        fi
    else
        check_warn "fail2ban" "not installed (bans addresses that keep failing to log in)"
    fi
}

# check_db_ports <ss -Hltn output>: database ports listening on every interface.
check_db_ports() {
    local ss_out="$1" entry port name addrs any=0
    for entry in $DB_PORTS; do
        port="${entry%%:*}"; name="${entry#*:}"
        addrs="$(printf '%s\n' "$ss_out" | awk -v p=":$port" '{ a = $4; if (substr(a, length(a) - length(p) + 1) == p) print a }')"
        [ -n "$addrs" ] || continue
        any=1
        if printf '%s\n' "$addrs" | grep -qE '^(0\.0\.0\.0|\*|\[::\]|::):'; then
            check_fail "$name ($port)" "listening for everyone: bind it to 127.0.0.1"
        elif printf '%s\n' "$addrs" | grep -qvE '^(127\.|\[::1\]|::1:)'; then
            check_warn "$name ($port)" "listening on a non-local address ($(printf '%s' "$addrs" | head -n 1 | tr -cd '0-9a-fA-F.:[]'))"
        else
            check_pass "$name ($port)" "this server only"
        fi
    done
    [ "$any" -eq 1 ] || check_pass "databases" "none listening on known database ports"
}

# The settings PHP-FPM really uses: `php-fpm<v> -i` reads the fpm php.ini (and its conf.d).
check_php() {
    local v info any=0
    for v in $PHP_VERSIONS; do
        [ -x "/usr/sbin/php-fpm$v" ] || continue
        any=1
        info="$("/usr/sbin/php-fpm$v" -i 2>/dev/null || true)"
        php_settings "$v" "$info"
    done
    [ "$any" -eq 1 ] || check_na "php" "no PHP-FPM installed"
}

# php_settings <version> <phpinfo text>.
php_settings() {
    local v="$1" info="$2"
    if [ -z "$info" ]; then check_na "PHP $v" "php-fpm$v -i gave nothing"; return; fi
    setting() { printf '%s\n' "$info" | awk -F' => ' -v k="$1" '$1 == k { print $2; exit }'; }
    [ "$(setting expose_php)" = "Off" ] && check_pass "PHP $v expose_php" "Off" \
        || check_warn "PHP $v expose_php" "On (tells everyone the PHP version)"
    case "$(setting display_errors)" in
        Off|"") check_pass "PHP $v display_errors" "Off" ;;
        *) check_fail "PHP $v display_errors" "On (errors, paths and sometimes secrets shown to visitors)" ;;
    esac
    [ "$(setting session.cookie_httponly)" = "On" ] && check_pass "PHP $v session.cookie_httponly" "On" \
        || check_warn "PHP $v session.cookie_httponly" "Off (Laravel sets its own cookies; matters for plain PHP)"
    [ "$(setting session.use_strict_mode)" = "On" ] && check_pass "PHP $v session.use_strict_mode" "On" \
        || check_warn "PHP $v session.use_strict_mode" "Off (Laravel handles sessions itself; matters for plain PHP)"
}

check_certificates() {
    local cert name end days any=0
    for cert in "$LETSENCRYPT_DIR"/live/*/fullchain.pem; do
        [ -f "$cert" ] || continue
        any=1
        name="$(basename "$(dirname "$cert")")"
        [[ "$name" =~ ^[a-z0-9.-]{1,253}$ ]] || name="(unusual name)"
        end="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)"
        days="$(( ($(date -u -d "$end" +%s 2>/dev/null || echo 0) - $(date -u +%s)) / 86400 ))"
        if [ "$days" -lt 0 ]; then check_fail "certificate $name" "EXPIRED"
        elif [ "$days" -lt 14 ]; then check_fail "certificate $name" "$days days left (renewal isn't working?)"
        elif [ "$days" -lt 21 ]; then check_warn "certificate $name" "$days days left"
        else check_pass "certificate $name" "$days days left"; fi
    done
    [ "$any" -eq 1 ] || { check_na "certificates" "none issued"; return; }
    systemctl is-active --quiet certbot.timer 2>/dev/null && check_pass "renewal timer" "on" \
        || check_fail "renewal timer" "certbot.timer is not active: certificates won't renew"
}

# check_accounts <passwd> <shadow>. Only user NAMES are printed (checked against a pattern).
check_accounts() {
    local passwd="$1" shadow="$2" extra empty
    extra="$(awk -F: '$3 == 0 && $1 != "root" { print $1 }' "$passwd" | grep -E '^[a-z_][a-z0-9_-]{0,31}$' | tr '\n' ' ' || true)"
    [ -z "$extra" ] && check_pass "UID 0 accounts" "root only" || check_fail "UID 0 accounts" "more than root: ${extra% }"
    if [ -r "$shadow" ]; then
        # Field 2 empty = log in with no password at all. ("!" or "*" = locked: fine.)
        empty="$(awk -F: '$2 == "" { print $1 }' "$shadow" | grep -E '^[a-z_][a-z0-9_-]{0,31}$' | tr '\n' ' ' || true)"
        [ -z "$empty" ] && check_pass "empty passwords" "none" || check_fail "empty passwords" "${empty% }"
    else
        check_na "empty passwords" "can't read $shadow"
    fi
}

check_permissions() {
    local mode f dir domain ww bad_env=""
    mode="$(stat -c '%a %G' "$ETC_DIR/shadow" 2>/dev/null || true)"
    case "$mode" in
        "640 shadow"|"600 root"|"640 root"|"0 root") check_pass "/etc/shadow" "$mode" ;;
        "") check_na "/etc/shadow" "missing?" ;;
        *) check_fail "/etc/shadow" "mode/group $mode (should be 640 shadow)" ;;
    esac
    mode="$(stat -c '%a' "$ETC_DIR/ssh/sshd_config" 2>/dev/null || true)"
    if [ -z "$mode" ]; then check_na "sshd_config" "missing?"
    elif [ $((8#$mode & 8#022)) -ne 0 ]; then check_fail "sshd_config" "mode $mode: others can change it"
    else check_pass "sshd_config" "mode $mode"; fi

    for dir in "$HOME_BASE"/s_*/; do
        [ -d "$dir" ] || continue
        for f in "$dir"*/shared/.env; do
            [ -f "$f" ] && [ ! -L "$f" ] || continue
            mode="$(stat -c '%a' "$f")"
            [ $((8#$mode & 8#007)) -eq 0 ] || bad_env="$bad_env $(basename "$(dirname "$(dirname "$f")")")($mode)"
        done
    done
    [ -z "$bad_env" ] && check_pass ".env files" "none readable by others" \
        || check_fail ".env files" "readable by others:$bad_env (run fix-permissions)"

    ww="$(find "$HOME_BASE" -xdev -path "$HOME_BASE/s_*" -perm -o+w ! -type l -printf '.' 2>/dev/null | wc -c)"
    [ "$ww" -eq 0 ] && check_pass "world-writable files in sites" "none" \
        || check_fail "world-writable files in sites" "$ww (any user on the server can change them; run fix-permissions)"
}

# Per site: composer audit (as the site user) and APP_DEBUG.
check_sites() {
    local audit="$1" dir domain user debug result any=0
    for dir in "$HOME_BASE"/s_*/*/; do
        dir="${dir%/}"
        [ -f "$dir/current/artisan" ] || continue
        domain="$(basename "$dir")"
        [[ "$domain" =~ ^[a-z0-9.-]{1,253}$ ]] || continue
        user="$(site_user "$domain")"
        [ "$(basename "$(dirname "$dir")")" = "$user" ] || continue
        any=1
        # APP_DEBUG: only the answer leaves this function, never the line. As the site user.
        if [ -f "$dir/shared/.env" ]; then
            debug="$(runuser -u "$user" -- grep -E '^\s*APP_DEBUG\s*=' "$dir/shared/.env" 2>/dev/null | tail -n 1 \
                | sed -E 's/^[^=]*=\s*//; s/["'\'' ]//g' | tr 'A-Z' 'a-z' || true)"
            case "$debug" in
                true|1|on|yes) check_fail "$domain APP_DEBUG" "on: visitors see error details (and sometimes secrets)" ;;
                *) check_pass "$domain APP_DEBUG" "off" ;;
            esac
        fi
        if [ "$audit" -eq 1 ]; then
            if ! command -v composer >/dev/null 2>&1; then check_na "$domain composer audit" "composer missing"
            elif [ ! -f "$dir/current/composer.lock" ]; then check_na "$domain composer audit" "no composer.lock"
            else
                result="$(cd "$dir/current" && runuser -u "$user" -- env HOME="$(site_home "$domain")" COMPOSER_NO_INTERACTION=1 \
                    timeout 60 composer audit --locked --no-ansi --format=summary 2>&1 || true)"
                audit_result "$domain" "$result"
            fi
        fi
    done
    [ "$any" -eq 1 ] || check_na "sites" "no Laravel sites found"
}

# audit_result <domain> <composer audit output>.
audit_result() {
    local domain="$1" out="$2" n
    n="$(printf '%s\n' "$out" | grep -oE 'Found [0-9]+ security vulnerability advisor' | grep -oE '[0-9]+' | head -n 1 || true)"
    if [ -n "$n" ] && [ "$n" -gt 0 ]; then
        check_fail "$domain composer audit" "$n known vulnerability advisories (composer audit in the project shows which; update the packages)"
    elif printf '%s\n' "$out" | grep -q 'No security vulnerability advisories found'; then
        check_pass "$domain composer audit" "no known vulnerable packages"
    else
        check_na "$domain composer audit" "couldn't run (no internet, or an old composer)"
    fi
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then check_na "docker" "not installed"; return; fi
    docker_ports "$(docker ps --format '{{.Names}}	{{.Ports}}' 2>/dev/null || true)"
}

# docker_ports <"name<TAB>ports" lines>: containers with a port published on every interface.
# Docker writes its own iptables rules, so UFW does NOT block these.
docker_ports() {
    local public
    public="$(printf '%s\n' "$1" | awk -F'\t' '$2 ~ /(0\.0\.0\.0|\[::\]|:::):[0-9]+->/ { print $1 }' \
        | grep -E '^[A-Za-z0-9._-]{1,64}$' | tr '\n' ' ' || true)"
    if [ -n "$public" ]; then
        check_fail "docker ports" "published to everyone (Docker skips UFW): ${public% }. Publish as 127.0.0.1:<port> instead"
    else
        check_pass "docker ports" "none published to everyone"
    fi
}

servio_run "$@"
