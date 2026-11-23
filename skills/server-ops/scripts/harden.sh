#!/usr/bin/env bash
# harden.sh: lock a server down, one step at a time (item 53). Each step is checked before the
# next, so nobody is locked out.
#
#   bash run.sh <host> harden.sh ssh      [--dry-run]   key-only SSH (with an automatic UNDO)
#   bash run.sh <host> harden.sh confirm                keep the SSH change (from a NEW connection)
#   bash run.sh <host> harden.sh fail2ban [--dry-run]   ban addresses that keep failing to log in
#   bash run.sh <host> harden.sh php      [--dry-run]   expose_php and display_errors off
# (automatic security updates: updates.sh auto)
#
# ssh: writes /etc/ssh/sshd_config.d/00-servio.conf. "00": sshd uses the FIRST value it reads,
#   and Ubuntu's cloud images ship 50-cloud-init.conf with `PasswordAuthentication yes`.
#     PasswordAuthentication no, KbdInteractiveAuthentication no, PermitEmptyPasswords no,
#     MaxAuthTries 3, PermitRootLogin no (or prohibit-password if YOU connect as root: key only)
#   Checked first: the user you connect as has a key in authorized_keys. Tested with sshd -t,
#   then reloaded (connections already open stay). Then an UNDO is armed: in 5 minutes the file
#   is removed and sshd reloaded again, UNLESS `harden.sh confirm` arrives first. confirm runs
#   over a NEW SSH connection, so it arriving proves key login still works. If it can't, the
#   undo puts the old settings back by itself.
#   The SSH port is never changed (on Ubuntu 24.04 that also needs ssh.socket: easy to lock out).
# php: /etc/php/<v>/fpm/conf.d/99-servio.ini for every PHP version. NOT disable_functions with
#   exec/proc_open/popen: Laravel and Symfony need them.

SSHD_DROPIN="/etc/ssh/sshd_config.d/00-servio.conf"
REVERT_UNIT="servio-ssh-undo"
REVERT_SECONDS=300

main() {
    local action="${1:-}"
    [[ "$action" =~ ^(ssh|confirm|fail2ban|php)$ ]] || die_input "Usage: harden.sh ssh|confirm|fail2ban|php"
    begin_change "server" "$@"
    require_root
    lock_site "server"
    case "$action" in
        ssh) harden_ssh ;;
        confirm) confirm_ssh ;;
        fail2ban) harden_fail2ban ;;
        php) harden_php ;;
    esac
}

# sshd_dropin <ssh user>: the settings. Root login: key only for a root user, off otherwise.
sshd_dropin() {
    local root_login="no"
    [ "$1" != "root" ] || root_login="prohibit-password"
    cat <<SSHD
# $MANAGED_HEADER (harden.sh). Read FIRST of sshd_config.d, so these values win.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
PermitRootLogin $root_login
SSHD
}

harden_ssh() {
    local who home keys
    who="${SUDO_USER:-root}"
    [[ "$who" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die_state "Unexpected SSH user name."
    home="$(getent passwd "$who" | cut -d: -f6)"
    keys="$(grep -cE '^(ssh-|ecdsa-|sk-)' "$home/.ssh/authorized_keys" 2>/dev/null || true)"
    step "Checking you won't be locked out"
    echo "You connect as: $who"
    [ "${keys:-0}" -ge 1 ] || die_refused "$who has no key in $home/.ssh/authorized_keys: turning passwords off would lock them out."
    echo "$who has $keys key(s) in authorized_keys."
    grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
        || die_state "sshd_config doesn't include sshd_config.d/*.conf: the settings wouldn't apply. Not changing anything."
    [ "$who" != "root" ] || echo "Note: you connect as root, so root login stays allowed with a KEY only (prohibit-password)."

    step "Writing $SSHD_DROPIN"
    sshd_dropin "$who" | write_file "$SSHD_DROPIN" 600 root:root
    if dry_run; then
        echo "[dry-run] would test with sshd -t, reload sshd, and arm the undo ($REVERT_SECONDS s) until 'harden.sh confirm'"
        step "Done (dry run): nothing was changed"
        return 0
    fi
    if ! sshd -t 2>&1; then
        rm -f "$SSHD_DROPIN"
        die "sshd -t rejected the settings: removed again, nothing changed."
    fi
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
    # The undo: its own systemd unit, so it runs even after this connection is gone.
    systemctl stop "$REVERT_UNIT.timer" 2>/dev/null || true
    systemctl reset-failed "$REVERT_UNIT.timer" "$REVERT_UNIT.service" 2>/dev/null || true
    systemd-run --unit "$REVERT_UNIT" --on-active="$REVERT_SECONDS" \
        /bin/sh -c "rm -f '$SSHD_DROPIN'; systemctl reload ssh || systemctl reload sshd" >/dev/null
    step "Checking the result"
    sshd -T 2>/dev/null | grep -qx 'passwordauthentication no' && check_pass "password login" "off" || check_fail "password login" "still on"
    check_summary || true
    echo
    echo "NOW, within $((REVERT_SECONDS / 60)) minutes, from a NEW connection: run.sh <host> harden.sh confirm"
    echo "If that can't connect, the change undoes itself at $(date -u -d "+$REVERT_SECONDS seconds" +%H:%M:%SZ)."
    echo "SERVIO_CONFIRM_BEFORE=$(date -u -d "+$REVERT_SECONDS seconds" +%Y-%m-%dT%H:%M:%SZ)"
}

confirm_ssh() {
    step "Keeping the SSH settings"
    if systemctl is-active --quiet "$REVERT_UNIT.timer" 2>/dev/null; then
        systemctl stop "$REVERT_UNIT.timer"
        check_pass "undo cancelled" "this new connection proves key login works; $SSHD_DROPIN stays"
    elif [ -f "$SSHD_DROPIN" ]; then
        check_pass "nothing pending" "$SSHD_DROPIN is in place"
    else
        check_warn "nothing to confirm" "the undo already ran (or ssh was never hardened): run harden.sh ssh again"
    fi
    check_summary || true
}

harden_fail2ban() {
    step "fail2ban for SSH"
    if dry_run; then
        command -v fail2ban-client >/dev/null 2>&1 || echo "[dry-run] would install fail2ban"
    else
        command -v fail2ban-client >/dev/null 2>&1 || apt-get -o DPkg::Lock::Timeout=600 -y install fail2ban
    fi
    # backend = systemd: reads sshd's journal (works without /var/log/auth.log too).
    # 5 failures in 10 minutes = banned for an hour. Your own address is never banned while
    # you use a key: only FAILED logins count.
    printf '%s\n' "# $MANAGED_HEADER (harden.sh)" "[sshd]" "enabled = true" "backend = systemd" \
        "maxretry = 5" "findtime = 10m" "bantime = 1h" | write_file /etc/fail2ban/jail.d/servio.conf 644 root:root
    dry_run && { step "Done (dry run): nothing was changed"; return 0; }
    systemctl enable --now fail2ban
    systemctl restart fail2ban
    sleep 2
    step "Checking the result"
    fail2ban-client status sshd >/dev/null 2>&1 && check_pass "fail2ban sshd jail" "active" || check_fail "fail2ban sshd jail" "not active"
    check_summary || die "fail2ban isn't running the sshd jail (see above)."
}

harden_php() {
    local v any=0
    for v in $PHP_VERSIONS; do
        [ -x "/usr/sbin/php-fpm$v" ] || continue
        any=1
        step "PHP $v-FPM"
        printf '%s\n' "; $MANAGED_HEADER (harden.sh). Safe for Laravel: no disable_functions." \
            "expose_php = Off" "display_errors = Off" "log_errors = On" \
            | write_file "$PHP_ETC_DIR/$v/fpm/conf.d/99-servio.ini" 644 root:root
        if ! dry_run; then
            "php-fpm$v" -t 2>&1 || { rm -f "$PHP_ETC_DIR/$v/fpm/conf.d/99-servio.ini"; die "php-fpm$v -t failed: removed again."; }
            systemctl reload "php$v-fpm"
        fi
    done
    [ "$any" -eq 1 ] || die_state "No PHP-FPM installed."
    dry_run && { step "Done (dry run): nothing was changed"; return 0; }
    step "Checking the result"
    for v in $PHP_VERSIONS; do
        [ -x "/usr/sbin/php-fpm$v" ] || continue
        "php-fpm$v" -i 2>/dev/null | grep -q '^expose_php => Off' && check_pass "PHP $v expose_php" "Off" || check_fail "PHP $v expose_php"
        "php-fpm$v" -i 2>/dev/null | grep -qE '^display_errors => (Off|STDOUT => Off)|^display_errors => Off' && check_pass "PHP $v display_errors" "Off" || check_fail "PHP $v display_errors"
    done
    check_summary || die "Some PHP settings aren't applied (see above)."
}

servio_run "$@"
