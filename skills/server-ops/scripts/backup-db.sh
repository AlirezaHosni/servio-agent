#!/usr/bin/env bash
# backup-db.sh: a site's MySQL database, dumped, compressed and ENCRYPTED, written to stdout
# (item 19). Only backup.sh on the laptop runs it (run.sh refuses otherwise): stdout goes into a
# file there, never into the chat.
#
#   (backup.sh runs)  run.sh <host> backup-db.sh <domain> <age-recipient> [more recipients]
#
#   mysqldump --single-transaction  a consistent copy WITHOUT locking the tables (InnoDB):
#                                   the site keeps working while it runs
#             --routines --triggers --events   everything, not just the tables
#   | gzip | age -r <recipient>...  encrypted on the server for your laptop's PUBLIC key: only
#                                   your private key (on the laptop) can open it. Nothing
#                                   readable is ever written to disk or sent
#
# No copy stays on the server. MySQL is read as root through its socket (no password exists).
# The database name comes from shared/.env (DB_DATABASE) or is the site user's name.
# Messages go to stderr (masked); stdout is only the encrypted data.

main() {
    local domain="${1:-}"; shift || true
    [ -n "$domain" ] && [ "$#" -ge 1 ] || die_input "Usage: backup-db.sh <domain> <age-recipient>..."
    validate_domain "$domain"
    local r recipients=()
    for r in "$@"; do
        [[ "$r" =~ ^age1[a-z0-9]{50,70}$ ]] || die_input "Not an age public key: '$r' (they start with age1)."
        recipients+=(-r "$r")
    done
    require_root
    require_cmd mysqldump "MySQL isn't installed here."
    require_cmd age "apt-get install age (provision-server.sh installs it)"
    id "$(site_user "$domain")" >/dev/null 2>&1 || die_state "No site user for $domain."

    local db
    env_value "$(site_env "$domain")" DB_DATABASE "$(site_user "$domain")"; db="${ENV_VALUE:-$(site_user "$domain")}"
    [[ "$db" =~ ^[A-Za-z0-9_]{1,64}$ ]] || die_state "Unexpected database name in shared/.env."
    [ "$(mysql -N -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$db'")" = 1 ] \
        || die_state "No database '$db' on this server (database.sh $domain create makes it)."
    say "Dumping database $db ($(mysql -N -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$db'") tables), compressed, encrypted for $# key(s)..."

    # pipefail (lib.sh): a failing mysqldump fails the whole line, not just a short file.
    mysqldump --single-transaction --quick --routines --triggers --events --no-tablespaces \
        --set-gtid-purged=OFF --default-character-set=utf8mb4 "$db" \
        | gzip -6 | age "${recipients[@]}"
    say "Done: database $db."
}

servio_run_stream "$@"
