#!/usr/bin/env bash
# reboot.sh: reboot a server, then check everything came back (item 74).
#
#   bash run.sh <host> reboot.sh now <typed-host-alias> [--dry-run]
#   bash run.sh <host> reboot.sh check
#
# now: every site on the server is down for a minute or two, so the user types the host alias
#   back (run.sh checks it matches the server it's sending to). Before rebooting, what runs is
#   saved (/var/lib/servio-agent/before-reboot: services and running workers). The reboot
#   starts 5 seconds later, so this connection ends cleanly first.
# check: after the server is back, compares with what ran before: every service and worker that
#   was running must run again. Anything that didn't come back is a FAIL.

STATE_FILE="/var/lib/servio-agent/before-reboot"

main() {
    local action="${1:-}"
    [[ "$action" =~ ^(now|check)$ ]] || die_input "Usage: reboot.sh now <typed-host-alias> | reboot.sh check"
    begin_change "server" "$@"
    require_root

    if [ "$action" = "check" ]; then
        check_after
        return 0
    fi
    # The typed alias is compared with the real one by run.sh (only the laptop knows the alias).
    [ -n "${2:-}" ] || die_input "Type the host alias back: reboot.sh now <host-alias>"
    lock_site "server"
    step "What runs now (saved, to compare after the reboot)"
    local snapshot
    snapshot="$(running_now)"
    printf '%s\n' "$snapshot" | sed 's/^/  /'
    if dry_run; then
        echo "[dry-run] would save this to $STATE_FILE and reboot in 5 seconds"
        step "Done (dry run): nothing was changed"
        return 0
    fi
    install -d -m 700 "$(dirname "$STATE_FILE")"
    printf '%s\n' "$snapshot" > "$STATE_FILE"
    step "Rebooting in 5 seconds"
    systemd-run --on-active=5 /bin/systemctl reboot >/dev/null
    echo "The server is going down. In 1-3 minutes: run.sh <host> reboot.sh check"
}

# running_now: "service <name>" and "worker <program>" lines for what runs.
running_now() {
    local s v
    for s in nginx mysql mariadb redis-server supervisor fail2ban cron $(for v in $PHP_VERSIONS; do echo "php$v-fpm"; done); do
        systemctl is-active --quiet "$s" 2>/dev/null && echo "service $s"
    done
    if command -v supervisorctl >/dev/null 2>&1; then
        supervisorctl status 2>/dev/null | awk '$2 == "RUNNING" { print "worker " $1 }' | grep -E '^worker [A-Za-z0-9_:.-]{1,100}$' || true
    fi
    return 0
}

check_after() {
    step "After the reboot"
    echo "up since: $(uptime -s 2>/dev/null || true)"
    if [ ! -f "$STATE_FILE" ]; then
        check_na "compare" "no saved state from before the reboot (rebooted another way?)"
    else
        local kind name now
        now="$(running_now)"
        while read -r kind name; do
            [ -n "$name" ] || continue
            if printf '%s\n' "$now" | grep -qxF "$kind $name"; then check_pass "$kind $name" "running again"
            else check_fail "$kind $name" "was running before the reboot, isn't now"; fi
        done < "$STATE_FILE"
    fi
    [ ! -f /var/run/reboot-required ] && check_pass "no reboot pending" || check_warn "reboot still pending" "packages updated after this boot"
    check_summary || echo "Something didn't come back: health.sh, then logs.sh server syslog."
}

servio_run "$@"
