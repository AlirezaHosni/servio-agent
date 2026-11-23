#!/usr/bin/env bash
# fix-permissions.sh: put a site's file owners and permissions back the way they should be
# (item 26). For the usual "Permission denied" errors: a file created by root (a command run
# with sudo), a storage/ folder PHP can't write to, a .env readable by others.
#
#   bash run.sh <host> fix-permissions.sh <domain> [--dry-run]
#
# What "right" means (decision 6: one Linux user per site):
#   - everything in /home/<user>/<domain> belongs to the site's user and group
#   - the user can read and write; its group (where nginx is) can read; others nothing.
#     Execute bits are kept where they were (vendor/bin tools stay runnable)
#   - storage/ and bootstrap/cache/ can be written by the user (Laravel writes there)
#   - .env: only the site's user (600). Its CONTENT is never read
# Free-form chmod/chown is never needed: this script is the one place that sets them.
#
# --dry-run: counts what's wrong (files with another owner, files others can read, .env mode)
# and changes nothing.

main() {
    local domain="${1:-}"
    [ -n "$domain" ] || die_input "Usage: fix-permissions.sh <domain>"
    validate_domain "$domain"
    begin_change "$domain" "$@"

    local user dir wrong_owner world_readable env_mode d
    user="$(site_user "$domain")"
    dir="$(site_dir "$domain")"

    step "Checking the site"
    require_root
    id "$user" >/dev/null 2>&1 || die_state "No site user $user: $domain isn't set up on this server (create-site.sh)."
    [ -d "$dir" ] || die_state "$dir doesn't exist. Run create-site.sh first."
    lock_site "$domain"

    # find -printf only prints names and counts, never contents.
    wrong_owner="$(find "$dir" \( ! -user "$user" -o ! -group "$user" \) -printf '.' 2>/dev/null | wc -c)"
    world_readable="$(find "$dir" -perm /o+rwx -printf '.' 2>/dev/null | wc -c)"
    env_mode="$( [ -f "$dir/.env" ] && stat -c %a "$dir/.env" || echo none)"
    echo "Files or folders not owned by $user: $wrong_owner"
    echo "Files or folders others can access:   $world_readable"
    echo ".env mode:                             $env_mode (should be 600)"

    step "Fixing owners and permissions"
    run chown -R "$user:$user" "$dir"
    # u+rwX: the user reads and writes, X = execute only on folders and already-executable files.
    # g+rX, g-w: the group (nginx) reads, never writes.   o-rwx: other users nothing.
    run chmod -R u+rwX,g+rX,g-w,o-rwx "$dir"
    for d in storage bootstrap/cache; do
        if [ -d "$dir/$d" ]; then run chmod -R u+rwX "$dir/$d"; fi
    done
    if [ -f "$dir/.env" ]; then run chmod 600 "$dir/.env"; fi

    if dry_run; then
        step "Done (dry run): nothing was changed"
        return 0
    fi

    step "Checking the result"
    wrong_owner="$(find "$dir" \( ! -user "$user" -o ! -group "$user" \) -printf '.' 2>/dev/null | wc -c)"
    world_readable="$(find "$dir" -perm /o+rwx -printf '.' 2>/dev/null | wc -c)"
    if [ "$wrong_owner" -eq 0 ]; then check_pass "everything belongs to $user"; else check_fail "everything belongs to $user" "$wrong_owner left"; fi
    if [ "$world_readable" -eq 0 ]; then check_pass "nothing open to other users"; else check_fail "nothing open to other users" "$world_readable left"; fi
    for d in storage bootstrap/cache; do
        if [ -d "$dir/$d" ]; then
            if runuser -u "$user" -- test -w "$dir/$d"; then check_pass "$d writable by the site"; else check_fail "$d writable by the site"; fi
        fi
    done
    if [ -f "$dir/.env" ]; then
        if [ "$(stat -c %a "$dir/.env")" = "600" ]; then check_pass ".env only readable by the site"; else check_fail ".env mode"; fi
    else
        check_na ".env" "there is none yet"
    fi
    check_summary || die "Some permissions are still wrong (see above)."
}

servio_run "$@"
