#!/usr/bin/env bash
# restore-db.sh: restore a site's MySQL database from a backup (item 32). DESTRUCTIVE in `live`
# mode. Only restore.sh on the laptop runs it: it takes a fresh backup first, decrypts the chosen
# backup ON THE LAPTOP and sends the dump (gzip) after this script on the same SSH stream.
#
#   (restore.sh runs)  run.sh <host> restore-db.sh <domain> new  <typed-domain>
#                      run.sh <host> restore-db.sh <domain> live <typed-domain>
#
#   new   import into a NEW database <db>_restored_<time>; the live data isn't touched. Look at it,
#         then restore again with `live` (or keep it as a copy). Drop it when done.
#   live  import into a temporary database first (a broken or partial dump stops HERE, before the
#         live data is touched), then swap: ONE `RENAME TABLE` statement moves every live table out
#         and every restored table in (atomic: requests see the old tables or the new ones), then
#         the old tables are dropped. Grants stay (they're on the database name).
#
# Limits: tables only are swapped in `live` mode (Laravel apps don't use views, stored
# procedures or events as a rule); they come along in `new` mode. The typed domain must match
# (the user types it in chat), as for delete-site.

main() {
    local domain="${1:-}" mode="${2:-}" typed="${3:-}"
    [ -n "$domain" ] || die_input "Usage: restore-db.sh <domain> new|live <typed-domain>"
    validate_domain "$domain"
    [[ "$mode" =~ ^(new|live)$ ]] || die_input "Mode: new (a separate database) or live (replace the site's data)."
    [ "$typed" = "$domain" ] || die_refused "The typed domain '$typed' doesn't match $domain. Nothing was restored."
    begin_change "$domain" "$@"

    require_root
    require_cmd mysql "MySQL isn't installed here."
    id "$(site_user "$domain")" >/dev/null 2>&1 || die_state "No site user for $domain."
    local db stamp target tables
    env_value "$(site_env "$domain")" DB_DATABASE "$(site_user "$domain")"; db="${ENV_VALUE:-$(site_user "$domain")}"
    [[ "$db" =~ ^[A-Za-z0-9_]{1,40}$ ]] || die_state "Unexpected database name in shared/.env."
    [ "$(sql_value "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$db'")" = 1 ] \
        || die_state "No database '$db' (database.sh $domain create makes it)."
    lock_site "$domain"
    stamp="$(date -u +%Y%m%d%H%M%S)"
    tables="$(sql_value "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$db'")"
    echo "Live database: $db ($tables tables)"

    if dry_run; then
        step "What would happen"
        if [ "$mode" = new ]; then
            echo "  import the backup into a NEW database ${db}_restored_$stamp; $db is not touched"
        else
            echo "  import the backup into ${db}_tmp_$stamp, check it, then swap its tables with $db's in one"
            echo "  RENAME TABLE, drop the old tables. $db's current data is REPLACED (restore.sh backs it up first)."
        fi
        step "Done (dry run): nothing was changed"
        return 0
    fi

    [ "$mode" = new ] && target="${db}_restored_$stamp" || target="${db}_tmp_$stamp"
    step "Importing the backup into $target"
    sql_exec "CREATE DATABASE \`$target\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
    # If anything below fails, the temporary database goes (the live one was never touched).
    [ "$mode" = new ] || add_exit_hook "[ \"\$SERVIO_RC\" -eq 0 ] || mysql -e 'DROP DATABASE IF EXISTS \`$target\`' 2>/dev/null"
    # The data on stdin is the gzip'ed dump; gzip checks its own checksum at the end, so a cut-off
    # transfer fails here (pipefail), not with half a database.
    gzip -dc | mysql "$target"
    local new_tables
    new_tables="$(sql_value "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$target' AND TABLE_TYPE = 'BASE TABLE'")"
    [ "$new_tables" -gt 0 ] || die "The backup had no tables. Nothing was changed in $db."
    echo "Imported: $new_tables tables, about $(sql_value "SELECT COALESCE(SUM(TABLE_ROWS),0) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$target'") rows."

    if [ "$mode" = new ]; then
        step "Done"
        echo "The backup is in the database $target. $db wasn't changed."
        echo "Look at it (as MySQL root on the server), then restore with 'live', or drop it when you're done."
        echo "SERVIO_RESTORED_DATABASE=$target"
        return 0
    fi

    step "Swapping the restored tables into $db (one atomic RENAME TABLE)"
    local old="${db}_old_$stamp" renames
    sql_exec "CREATE DATABASE \`$old\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
    renames="$(swap_statement "$db" "$target" "$old")"
    sql_exec "SET FOREIGN_KEY_CHECKS = 0; $renames"
    echo "Swapped."

    step "Cleaning up"
    sql_exec "DROP DATABASE \`$target\`; DROP DATABASE \`$old\`"
    echo "Old tables dropped (the fresh backup restore.sh made just before is your way back)."

    step "Checking the result"
    tables="$(sql_value "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$db' AND TABLE_TYPE = 'BASE TABLE'")"
    [ "$tables" = "$new_tables" ] && check_pass "$db has the restored tables" "$tables" || check_fail "$db tables" "$tables, expected $new_tables"
    read_site_settings "$domain"
    if health_check "$domain"; then check_pass "site answers" "$HEALTH_DETAIL"; else check_warn "site answers" "$HEALTH_DETAIL (the code may need a migration: artisan.sh $domain migrate)"; fi
    check_summary || die "The restore finished but $db doesn't look right (see above)."
}

sql_value() { mysql -N -e "$1"; }
sql_exec()  { mysql -e "$1"; }

# swap_statement <live db> <restored db> <old db>: ONE RENAME TABLE moving every live table to
# <old> and every restored table into <live>. Names come from information_schema and are quoted.
swap_statement() {
    local live="$1" new="$2" old="$3" parts="" t
    while read -r t; do
        [ -n "$t" ] || continue
        [[ "$t" =~ ^[A-Za-z0-9_$]{1,64}$ ]] || die "Unexpected table name in $live."
        parts="$parts, \`$live\`.\`$t\` TO \`$old\`.\`$t\`"
    done < <(sql_value "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$live' AND TABLE_TYPE = 'BASE TABLE'")
    while read -r t; do
        [ -n "$t" ] || continue
        [[ "$t" =~ ^[A-Za-z0-9_$]{1,64}$ ]] || die "Unexpected table name in the backup."
        parts="$parts, \`$new\`.\`$t\` TO \`$live\`.\`$t\`"
    done < <(sql_value "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$new' AND TABLE_TYPE = 'BASE TABLE'")
    echo "RENAME TABLE ${parts#, };"
}

servio_run_input "$@"
