#!/usr/bin/env bash
# database.sh: a MySQL database and user for a site (item 18).
#
#   bash run.sh <host> database.sh <domain> create [--dry-run]
#
# Makes, on the server:
#   - a database and a user both named after the site's Linux user (s_shopexamplecom_951623),
#     utf8mb4, the user allowed on that database only, from this server only ('...'@'localhost')
#   - a random password, generated ON THE SERVER (openssl), passed to MySQL on stdin (never on a
#     command line, where `ps` shows it), written into the site's shared/.env, and NEVER printed
#   - in shared/.env: DB_CONNECTION=mysql, DB_HOST=127.0.0.1, DB_PORT=3306, DB_DATABASE,
#     DB_USERNAME, DB_PASSWORD. Other lines stay as they are; the file is created if missing
#     (only the site user can read it: 600)
#
# Safe to run again: if .env already names this database and user and they work, nothing
# changes. If the user exists but .env doesn't match, a NEW password is set and written (the
# old one is lost on purpose: nobody can see it to keep it).
# MySQL itself: provision-server.sh <php> mysql. The admin login is root through MySQL's
# socket (auth_socket): no admin password exists anywhere.

main() {
    local domain="${1:-}" action="${2:-}"
    [ -n "$domain" ] || die_input "Usage: database.sh <domain> create"
    validate_domain "$domain"
    [ "$action" = "create" ] || die_input "database.sh $domain create   (the only action for now)"
    begin_change "$domain" "$@"

    local user name env have_db have_user env_db env_user
    user="$(site_user "$domain")"
    name="$user"                     # MySQL names: letters, digits, _ ; at most 32 for a user
    env="$(site_env "$domain")"

    step "Checking the server and the site"
    require_root
    require_cmd mysql "MySQL isn't installed: provision-server.sh <php> mysql"
    mysql -e 'SELECT 1' >/dev/null 2>&1 || die_state "Can't log in to MySQL as root through its socket (is it running? is root's auth_socket login changed?)."
    id "$user" >/dev/null 2>&1 || die_state "No site user $user: create the site first."
    [ -d "$(site_shared "$domain")" ] || die_state "$domain has no shared/ folder (create-site.sh adds it)."
    [[ "$name" =~ ^[a-z0-9_]{1,32}$ ]] || die "Unexpected database name '$name'."
    lock_site "$domain"

    have_db="$(mysql -N -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$name'")"
    have_user="$(mysql -N -e "SELECT COUNT(*) FROM mysql.user WHERE user = '$name' AND host = 'localhost'")"
    env_value "$env" DB_DATABASE "$user"; env_db="$ENV_VALUE"
    env_value "$env" DB_USERNAME "$user"; env_user="$ENV_VALUE"
    echo "database $name: $([ "$have_db" = 1 ] && echo exists || echo new)"
    echo "user $name@localhost: $([ "$have_user" = 1 ] && echo exists || echo new)"
    echo "shared/.env: $([ -f "$env" ] && echo "exists$([ -n "$env_db" ] && echo ", DB_DATABASE=$env_db")" || echo "none yet (it will be created with the DB_* lines only)")"

    if [ "$have_db" = 1 ] && [ "$have_user" = 1 ] && [ "$env_db" = "$name" ] && [ "$env_user" = "$name" ] && login_works "$domain"; then
        step "Already set up"
        echo "The database, its user and shared/.env match, and the login works. Nothing to do."
        return 0
    fi

    if dry_run; then
        step "What would happen"
        [ "$have_db" = 1 ] || echo "  create database $name (utf8mb4)"
        echo "  $([ "$have_user" = 1 ] && echo "set a NEW password for" || echo "create") user $name@localhost, allowed on $name only"
        echo "  write DB_CONNECTION, DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME, DB_PASSWORD into shared/.env (values not shown)"
        step "Done (dry run): nothing was changed"
        return 0
    fi

    step "Creating the database and its user"
    local password
    # 32 characters from the server's random source; letters and digits only (no quoting issues).
    password="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-32)"
    [ "${#password}" -eq 32 ] || die "Couldn't generate a password."
    # The SQL goes in on stdin: the password is never an argument of any process.
    mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`$name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$name'@'localhost' IDENTIFIED BY '$password';
ALTER USER '$name'@'localhost' IDENTIFIED BY '$password';
GRANT ALL PRIVILEGES ON \`$name\`.* TO '$name'@'localhost';
FLUSH PRIVILEGES;
SQL
    echo "Database $name and user $name@localhost are ready."

    step "Writing the login into shared/.env (not shown)"
    printf '%s\n' "DB_CONNECTION=mysql" "DB_HOST=127.0.0.1" "DB_PORT=3306" "DB_DATABASE=$name" \
        "DB_USERNAME=$name" "DB_PASSWORD=$password" | env_set "$domain"
    unset password
    echo "Done. Laravel reads it after the next config:cache (deploy, or artisan.sh $domain optimize)."

    step "Checking the result"
    if login_works "$domain"; then check_pass "the site's login works" "$name@localhost, read from shared/.env"
    else check_fail "the site's login works"; fi
    [ "$(stat -c %a "$env")" = "600" ] && [ "$(stat -c %U "$env")" = "$user" ] \
        && check_pass "shared/.env only readable by $user" || check_fail "shared/.env owner/mode" "$(stat -c '%U %a' "$env")"
    check_summary || die "The database was made, but something isn't right (see above)."
}

# login_works <domain>: log in to MySQL with the login IN shared/.env. The password is read into a
# variable (never printed) and handed to mysql in an option file through a pipe (<(...)): never an
# argument, so `ps` can't show it.
login_works() {
    local env u d pw
    env="$(site_env "$1")"
    [ -f "$env" ] && [ ! -L "$env" ] || return 1
    env_value "$env" DB_USERNAME "$(site_user "$1")"; u="$ENV_VALUE"
    env_value "$env" DB_DATABASE "$(site_user "$1")"; d="$ENV_VALUE"
    pw="$(sed -n 's/^[[:space:]]*DB_PASSWORD[[:space:]]*=[[:space:]]*//p' "$env" | tail -n 1 | sed 's/^"//; s/"[[:space:]]*$//')"
    [ -n "$u" ] && [ -n "$d" ] && [ -n "$pw" ] || return 1
    mysql --defaults-extra-file=<(printf '[client]\nuser=%s\npassword="%s"\n' "$u" "$pw") -e 'SELECT 1' "$d" >/dev/null 2>&1
}

servio_run "$@"
