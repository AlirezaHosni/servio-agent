#!/usr/bin/env bash
# provision-server.sh: turn a fresh Ubuntu 22.04/24.04 server into one that hosts PHP sites.
#
#   bash run.sh <host> provision-server.sh [default-php] [more-php...] [mysql] [redis] [--dry-run]
#   bash run.sh web1 provision-server.sh 8.4            one PHP version (8.3, 8.4 or 8.5)
#   bash run.sh web1 provision-server.sh 8.4 8.3        8.4 is the default, 8.3 installed too
#   bash run.sh web1 provision-server.sh 8.4 mysql redis   + MySQL 8 and Redis (v0.6; also later)
#
# Installs nginx, PHP-FPM (from the ondrej PPA) in every version asked for, Composer, Node.js, git,
# Supervisor (it runs queue workers later) and a firewall (UFW). Ported from Servio's ProvisionServer.
# Sites are NOT run by a shared user any more: create-site.sh gives each site its own Linux user
# and PHP-FPM pool (decision 6). Each PHP version's default "www" pool is set to start no
# process until it's used, so an unused version costs no memory.
# Then checks the result: nginx, every PHP-FPM version and Supervisor running, the firewall on
# with SSH allowed (item 52).
#
# Run it again with another version (provision-server.sh 8.4 8.5) to add that version later.
# --dry-run: checks the server (Ubuntu version, SSH port) and lists what would be installed or
# changed; installs nothing.
#
# Safe to run again: every step checks first or is harmless when repeated. If it fails halfway
# (network, apt lock...), fix the cause and run it again.

main() {
    local default_php="${1:-8.4}" versions v with_mysql=0 with_redis=0
    validate_php "$default_php"
    versions="$default_php"
    shift || true
    # After the PHP versions: optional services, by name (mysql, redis).
    for v in "$@"; do
        case "$v" in
            mysql) with_mysql=1 ;;
            redis) with_redis=1 ;;
            *) validate_php "$v"
               case " $versions " in *" $v "*) ;; *) versions="$versions $v" ;; esac ;;
        esac
    done
    begin_change "server" "$default_php" "$@"

    # apt waits up to 10 minutes for the dpkg lock instead of failing at once: a fresh cloud
    # server often runs unattended-upgrades in its first minutes.
    apt_get() { run apt-get -o DPkg::Lock::Timeout=600 -y "$@"; }

    step "Checking the server"
    require_root
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] || die_state "Only Ubuntu is supported (this is: ${PRETTY_NAME:-unknown})."
    # Is VERSION_ID one of the words in $UBUNTU_VERSIONS? The spaces around both sides make
    # "24.04" match only the whole word (and an empty VERSION_ID match nothing).
    # Not 26.04 yet: the ondrej Launchpad PPA doesn't carry it.
    case " $UBUNTU_VERSIONS " in
        *" ${VERSION_ID:-} "*) ;;
        *) die_state "Ubuntu ${VERSION_ID:-unknown} isn't supported yet. Use one of: $UBUNTU_VERSIONS (LTS)." ;;
    esac
    echo "$PRETTY_NAME"

    # The SSH port(s) the firewall MUST keep open. Read from sshd's own effective config, BEFORE
    # anything is installed: if we can't tell, we stop here, not after locking everyone out.
    local ssh_ports
    ssh_ports="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -u | tr '\n' ' ' || true)"
    [[ "$ssh_ports" =~ ^([0-9]{1,5}\ )+$ ]] || die_state "Couldn't read the SSH port from 'sshd -T'. Not touching the firewall."
    echo "SSH listens on port(s): $ssh_ports"
    echo "PHP: $versions (default $default_php)"
    # A server-wide change: one at a time (the same lock mechanism as sites, named "server").
    lock_site "server"

    step "Installing base packages"
    apt_get update
    apt_get install software-properties-common ca-certificates curl git unzip ufw supervisor gnupg age

    step "Adding the ondrej/php package source"
    if ! grep -rqs "ondrej/php" /etc/apt/sources.list.d/; then
        run add-apt-repository -y ppa:ondrej/php
    else
        echo "Already added."
    fi
    apt_get update

    step "Installing nginx and PHP $versions"
    local packages=(nginx)
    for v in $versions; do
        packages+=("php$v-fpm" "php$v-cli" "php$v-mysql" "php$v-sqlite3" "php$v-mbstring" "php$v-xml"
                   "php$v-curl" "php$v-zip" "php$v-bcmath" "php$v-intl" "php$v-gd")
    done
    apt_get install "${packages[@]}"
    # `php` on the command line = the default version (several may be installed).
    run update-alternatives --set php "/usr/bin/php$default_php"

    step "Installing Composer"
    if command -v composer >/dev/null 2>&1; then
        echo "Already installed."
    elif dry_run; then
        echo "[dry-run] would download the Composer installer, check its SHA-384 and install it"
    else
        # Check the installer's SHA-384 against the one Composer publishes, so a tampered
        # download is never executed as root.
        local expected actual
        expected="$(curl -fsSL https://composer.github.io/installer.sig)"
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        actual="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
        if [ "$expected" != "$actual" ]; then
            rm -f /tmp/composer-setup.php
            die_refused "The Composer installer's checksum doesn't match. Not installing."
        fi
        php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
        rm -f /tmp/composer-setup.php
    fi

    step "Installing Node.js $NODE_MAJOR (for frontend builds: npm run build)"
    # Ubuntu's own nodejs is too old for Vite (22.04: Node 12, 24.04: Node 18). NodeSource's apt
    # source, with its signing key in /etc/apt/keyrings: apt checks every package against it.
    # (Not `curl ... | bash`: nothing downloaded is executed.)
    local node_major
    node_major="$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || true)"
    if [[ "$node_major" =~ ^[0-9]+$ ]] && [ "$node_major" -ge "$NODE_MAJOR" ]; then
        echo "Already installed: Node $(node -v)."
    elif dry_run; then
        echo "[dry-run] would add NodeSource's apt source (node_$NODE_MAJOR.x, signed) and install nodejs"
    else
        install -d -m 755 /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" \
            | write_file /etc/apt/sources.list.d/nodesource.list 644 root:root
        apt_get update
        apt_get install nodejs
    fi

    step "PHP-FPM: the default pools use no memory until needed"
    # Every site gets its own pool (create-site.sh). PHP-FPM refuses to start with NO pool at
    # all, so each version keeps its default "www" pool, but switched to "ondemand": it starts
    # no process until a request comes, and nginx never sends it any.
    for v in $versions; do
        run sed -i -E 's/^pm = .*/pm = ondemand/' "$PHP_ETC_DIR/$v/fpm/pool.d/www.conf"
        run systemctl enable "php$v-fpm"
        run systemctl restart "php$v-fpm"
    done

    step "Supervisor (it will run the sites' queue workers)"
    run systemctl enable --now supervisor

    if [ "$with_mysql" -eq 1 ]; then
        step "MySQL 8 (Ubuntu's package)"
        # Ubuntu's MySQL listens on 127.0.0.1 only and lets the OS root user in through its socket
        # (auth_socket): scripts run `mysql` as root with no password anywhere. Sites get their
        # own users and passwords (database.sh).
        apt_get install mysql-server
        run systemctl enable --now mysql
    fi
    if [ "$with_redis" -eq 1 ]; then
        step "Redis"
        # Ubuntu's Redis listens on 127.0.0.1 and ::1 with protected mode on: nothing from outside.
        apt_get install redis-server
        run systemctl enable --now redis-server
    fi

    step "Starting nginx"
    # The sites' access-log format with the request time (traffic.sh reads it).
    ensure_log_format
    # Real visitor addresses for sites proxied through Cloudflare (dns.sh).
    ensure_cloudflare_realip
    if ! dry_run; then nginx -t 2>&1; fi
    run systemctl enable nginx
    run systemctl restart nginx

    step "Firewall: SSH (port $ssh_ports, rate-limited), HTTP and HTTPS, block the rest"
    # SSH FIRST. Enabling UFW without it would lock everyone out.
    # `limit` instead of `allow`: an address that opens 6+ SSH connections within 30 seconds is
    # blocked for a while (slows down password guessing). Normal use, scripts included, stays
    # well below that.
    local port
    for port in $ssh_ports; do run ufw limit "$port/tcp"; done
    run ufw allow 80/tcp
    run ufw allow 443/tcp
    run ufw --force enable

    if dry_run; then
        step "Done (dry run): nothing was installed or changed"
        return 0
    fi

    step "Checking the result"
    if systemctl is-active --quiet nginx; then check_pass "nginx running"; else check_fail "nginx running"; fi
    for v in $versions; do
        if systemctl is-active --quiet "php$v-fpm"; then check_pass "PHP $v-FPM running"; else check_fail "PHP $v-FPM running"; fi
    done
    if systemctl is-active --quiet supervisor; then check_pass "Supervisor running"; else check_fail "Supervisor running"; fi
    if ufw status | grep -q "^Status: active"; then check_pass "firewall on"; else check_fail "firewall on"; fi
    for port in $ssh_ports; do
        if ufw status | grep -qE "^$port/tcp[[:space:]]+(LIMIT|ALLOW)"; then
            check_pass "SSH port $port open (rate-limited)"
        else
            check_fail "SSH port $port open" "you could be locked out: allow it before closing this session"
        fi
    done
    if COMPOSER_ALLOW_SUPERUSER=1 composer --version >/dev/null 2>&1; then check_pass "Composer works"; else check_fail "Composer works"; fi
    if npm --version >/dev/null 2>&1; then check_pass "Node.js and npm work" "$(node -v)"; else check_fail "Node.js and npm work"; fi
    # Databases must answer, and only on this server (security-check checks the same ports).
    local listen
    if [ "$with_mysql" -eq 1 ]; then
        if systemctl is-active --quiet mysql && mysql -e 'SELECT 1' >/dev/null 2>&1; then check_pass "MySQL running" "$(mysql -N -e 'SELECT VERSION()' 2>/dev/null)"; else check_fail "MySQL running"; fi
        listen="$(ss -Hltn 2>/dev/null | awk '$4 ~ /:3306$/ { print $4 }' | tr '\n' ' ')"
        if [ -n "$listen" ] && ! printf '%s' "$listen" | grep -qE '(^| )(0\.0\.0\.0|\*|\[::\]):3306'; then check_pass "MySQL only on this server" "$listen"; else check_fail "MySQL only on this server" "${listen:-not listening}"; fi
    fi
    if [ "$with_redis" -eq 1 ]; then
        if [ "$(redis-cli ping 2>/dev/null)" = "PONG" ]; then check_pass "Redis running"; else check_fail "Redis running"; fi
        listen="$(ss -Hltn 2>/dev/null | awk '$4 ~ /:6379$/ { print $4 }' | tr '\n' ' ')"
        if [ -n "$listen" ] && ! printf '%s' "$listen" | grep -qE '(^| )(0\.0\.0\.0|\*|\[::\]):6379'; then check_pass "Redis only on this server" "$listen"; else check_fail "Redis only on this server" "${listen:-not listening}"; fi
    fi
    check_summary || die "Provisioning finished, but something isn't right (see above)."

    step "Done"
    nginx -v 2>&1
    php -v | head -n 1
    COMPOSER_ALLOW_SUPERUSER=1 composer --version
}

servio_run "$@"
