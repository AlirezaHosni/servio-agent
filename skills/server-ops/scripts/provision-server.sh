#!/usr/bin/env bash
# provision-server.sh: turn a fresh Ubuntu 22.04/24.04 server into one that hosts PHP sites.
#
#   bash run.sh <host> provision-server.sh [php-version] [--dry-run]   (default 8.4; 8.3, 8.4 or 8.5)
#
# Installs nginx, PHP-FPM (from the ondrej PPA), Composer, git, a firewall (UFW), and the
# `servio` user that owns every site and runs PHP-FPM. Ported from Servio's ProvisionServer.
# Then checks the result: nginx and PHP-FPM running, the firewall on with SSH allowed (item 52).
#
# --dry-run: checks the server (Ubuntu version, SSH port) and lists what would be installed or
# changed; installs nothing.
#
# Safe to run again: every step checks first or is harmless when repeated. If it fails halfway
# (network, apt lock...), fix the cause and run it again.

main() {
    local php_version="${1:-8.4}"
    validate_php "$php_version"
    begin_change "server" "$@"

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
    # A server-wide change: one at a time (the same lock mechanism as sites, named "server").
    lock_site "server"

    step "Installing base packages"
    apt_get update
    apt_get install software-properties-common ca-certificates curl git unzip ufw

    step "Adding the ondrej/php package source"
    if ! grep -rqs "ondrej/php" /etc/apt/sources.list.d/; then
        run add-apt-repository -y ppa:ondrej/php
    else
        echo "Already added."
    fi
    apt_get update

    step "Installing nginx and PHP $php_version"
    apt_get install nginx \
        "php$php_version-fpm" "php$php_version-cli" "php$php_version-mysql" "php$php_version-sqlite3" \
        "php$php_version-mbstring" "php$php_version-xml" "php$php_version-curl" "php$php_version-zip" \
        "php$php_version-bcmath" "php$php_version-intl" "php$php_version-gd"
    # `php` on the command line = this version (the PPA may have installed others).
    run update-alternatives --set php "/usr/bin/php$php_version"

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

    step "Creating the $SITE_USER user (owns all sites)"
    if id "$SITE_USER" >/dev/null 2>&1; then
        echo "Already exists."
    else
        run useradd --create-home --shell /bin/bash "$SITE_USER"
    fi
    # nginx runs as www-data and must read the sites' static files in /home/servio (a 750
    # folder): putting it in the servio group gives it read access, nothing more.
    run usermod -aG "$SITE_USER" www-data

    step "Running PHP-FPM as $SITE_USER"
    # PHP then owns the same files as the user who deploys them (no permission fights).
    # listen.owner stays www-data, so nginx can still talk to the PHP-FPM socket.
    local pool="/etc/php/$php_version/fpm/pool.d/www.conf"
    run sed -i -E "s/^user = .*/user = $SITE_USER/; s/^group = .*/group = $SITE_USER/" "$pool"
    run systemctl enable "php$php_version-fpm"
    run systemctl restart "php$php_version-fpm"

    step "Starting nginx"
    if ! dry_run; then nginx -t 2>&1; fi
    run systemctl enable nginx
    run systemctl restart nginx

    step "Firewall: allow SSH (port $ssh_ports), HTTP and HTTPS, block the rest"
    # SSH FIRST. Enabling UFW without it would lock everyone out.
    local port
    for port in $ssh_ports; do run ufw allow "$port/tcp"; done
    run ufw allow 80/tcp
    run ufw allow 443/tcp
    run ufw --force enable

    if dry_run; then
        step "Done (dry run): nothing was installed or changed"
        return 0
    fi

    step "Checking the result"
    if systemctl is-active --quiet nginx; then check_pass "nginx running"; else check_fail "nginx running"; fi
    if systemctl is-active --quiet "php$php_version-fpm"; then check_pass "PHP $php_version-FPM running"; else check_fail "PHP $php_version-FPM running"; fi
    if ufw status | grep -q "^Status: active"; then check_pass "firewall on"; else check_fail "firewall on"; fi
    for port in $ssh_ports; do
        if ufw status | grep -qE "^$port/tcp[[:space:]]+ALLOW"; then
            check_pass "SSH port $port allowed"
        else
            check_fail "SSH port $port allowed" "you could be locked out: allow it before closing this session"
        fi
    done
    if COMPOSER_ALLOW_SUPERUSER=1 composer --version >/dev/null 2>&1; then check_pass "Composer works"; else check_fail "Composer works"; fi
    check_summary || die "Provisioning finished, but something isn't right (see above)."

    step "Done"
    nginx -v 2>&1
    php -v | head -n 1
    COMPOSER_ALLOW_SUPERUSER=1 composer --version
}

servio_run "$@"
