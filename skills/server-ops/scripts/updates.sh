#!/usr/bin/env bash
# updates.sh: server package updates (item 25).
#
#   bash run.sh <host> updates.sh upgrade [--dry-run]   # the dry run lists what would be updated
#   bash run.sh <host> updates.sh auto    [--dry-run]   # automatic SECURITY updates on (daily)
#
# upgrade: `apt-get upgrade --with-new-pkgs` (new dependencies like a new kernel may be added;
#   nothing is removed), keeping every config file we or you changed (--force-confold). Then the
#   services are checked, and whether a reboot is needed (/var/run/reboot-required) is reported.
#   It never reboots: that's reboot.sh, with you typing the host back.
# auto: unattended-upgrades installs security updates every day. Automatic REBOOT stays OFF
#   (written explicitly): a kernel update then waits for a reboot you choose.
# The dry run refreshes apt's package lists (`apt-get update`: only the lists, nothing installed)
# so the list of updates is current.
# Composer packages are never updated on a server: update locally, commit composer.lock, deploy.

AUTO_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
NOREBOOT_FILE="/etc/apt/apt.conf.d/52servio-no-reboot"

main() {
    local action="${1:-}"
    [[ "$action" =~ ^(upgrade|auto)$ ]] || die_input "Usage: updates.sh upgrade|auto"
    begin_change "server" "$@"
    require_root
    lock_site "server"
    apt_get() { apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -y "$@"; }

    if [ "$action" = "auto" ]; then
        step "Automatic security updates"
        if dry_run; then
            echo "[dry-run] would install unattended-upgrades (if missing) and write $AUTO_FILE and $NOREBOOT_FILE"
        else
            command -v unattended-upgrade >/dev/null 2>&1 || apt_get install unattended-upgrades
        fi
        printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "1";' \
            | write_file "$AUTO_FILE" 644 root:root
        printf '%s\n' "// $MANAGED_HEADER. Security updates install by themselves; reboots stay yours (reboot.sh)." \
            'Unattended-Upgrade::Automatic-Reboot "false";' | write_file "$NOREBOOT_FILE" 644 root:root
        dry_run && { step "Done (dry run): nothing was changed"; return 0; }
        step "Checking the result"
        grep -q 'Unattended-Upgrade "1"' "$AUTO_FILE" && check_pass "automatic security updates" "on, daily" || check_fail "automatic security updates"
        systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null && check_pass "apt-daily-upgrade.timer" "enabled" || check_warn "apt-daily-upgrade.timer" "not enabled"
        check_summary || die "Automatic updates aren't set up right (see above)."
        return 0
    fi

    step "Refreshing the package lists (apt-get update)"
    apt-get -o DPkg::Lock::Timeout=600 update -qq
    local pending security
    # -s: simulate. "Inst <package> [<old>] (<new> <origin>)" lines.
    pending="$(apt-get -s -o Dpkg::Options::=--force-confold upgrade --with-new-pkgs 2>/dev/null | awk '/^Inst /' || true)"
    security="$(printf '%s\n' "$pending" | grep -c -- '-security' || true)"
    step "Updates: $(printf '%s\n' "$pending" | grep -c '^Inst' || true) package(s), $security from security"
    printf '%s\n' "$pending" | awk '/^Inst / { gsub(/[\[\]()]/, ""); printf "  %-36s %s -> %s\n", $2, $3, $4 }' | head -n 100

    if dry_run; then
        [ -z "$pending" ] || echo "[dry-run] would install these, keeping changed config files, then check the services"
        step "Done (dry run): nothing was installed"
        return 0
    fi
    [ -n "$pending" ] || { echo "Nothing to update."; reboot_note; return 0; }

    local before
    before="$(services_up)"
    step "Upgrading"
    apt_get upgrade --with-new-pkgs

    step "Checking the result"
    local s
    for s in $before; do
        systemctl is-active --quiet "$s" && check_pass "$s running" || check_fail "$s running" "it was before the update"
    done
    reboot_note
    check_summary || die "Updated, but a service that was running isn't now (see above): logs.sh server syslog."
}

# services_up: the services that matter that run now (checked again after the update).
services_up() {
    local s out=""
    for s in nginx mysql mariadb redis-server supervisor $(for v in $PHP_VERSIONS; do echo "php$v-fpm"; done); do
        systemctl is-active --quiet "$s" 2>/dev/null && out="$out $s"
    done
    echo "$out"
}

reboot_note() {
    if [ -f /var/run/reboot-required ]; then
        check_warn "reboot needed" "for: $(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null | tr -cd 'a-z0-9 .+-' | cut -c1-200). Plan it: reboot.sh"
    else
        check_pass "no reboot needed"
    fi
}

servio_run "$@"
