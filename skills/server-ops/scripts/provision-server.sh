#!/usr/bin/env bash
# provision-server.sh: turn a fresh Ubuntu 22.04/24.04 server into one that hosts PHP sites.
#
#   bash run.sh <host> provision-server.sh [php-version]      (default 8.4; 8.3, 8.4 or 8.5)
#
# Installs nginx, PHP-FPM (from the ondrej PPA), Composer, git, a firewall (UFW), and the
# `servio` user that owns every site and runs PHP-FPM. Ported from Servio's ProvisionServer.
#
# Safe to run again: every step checks first or is harmless when repeated. If it fails halfway
# (network, apt lock...), fix the cause and run it again.

main() {
    local php_version="${1:-8.4}"
    validate_php "$php_version"

    # apt waits up to 10 minutes for the dpkg lock instead of failing at once: a fresh cloud
    # server often runs unattended-upgrades in its first minutes.
    apt_get() { apt-get -o DPkg::Lock::Timeout=600 -y "$@"; }

    step "Checking the server"
    require_root
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] || die "Only Ubuntu is supported (this is: ${PRETTY_NAME:-unknown})."
    # Is VERSION_ID one of the words in $UBUNTU_VERSIONS? The spaces around both sides make
    # "24.04" match only the whole word (and an empty VERSION_ID match nothing).
    # Not 26.04 yet: the ondrej Launchpad PPA doesn't carry it.
    case " $UBUNTU_VERSIONS " in
        *" ${VERSION_ID:-} "*) ;;
        *) die "Ubuntu ${VERSION_ID:-unknown} isn't supported yet. Use one of: $UBUNTU_VERSIONS (LTS)." ;;
    esac
    echo "$PRETTY_NAME"

    # The SSH port(s) the firewall MUST keep open. Read from sshd's own effective config, BEFORE
    # anything is installed: if we can't tell, we stop here, not after locking everyone out.
    local ssh_ports
    ssh_ports="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -u | tr '\n' ' ')"
    [[ "$ssh_ports" =~ ^([0-9]{1,5}\ )+$ ]] || die "Couldn't read the SSH port from 'sshd -T'. Not touching the firewall."
    echo "SSH listens on port(s): $ssh_ports"

    step "Installing base packages"
    apt_get update
    apt_get install software-properties-common ca-certificates curl git unzip ufw

    step "Adding the ondrej/php package source"
    if ! grep -rqs "ondrej/php" /etc/apt/sources.list.d/; then
        add-apt-repository -y ppa:ondrej/php
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
    update-alternatives --set php "/usr/bin/php$php_version"

    step "Installing Composer"
    if command -v composer >/dev/null 2>&1; then
        echo "Already installed."
    else
        # Check the installer's SHA-384 against the one Composer publishes, so a tampered
        # download is never executed as root.
        local expected actual
        expected="$(curl -fsSL https://composer.github.io/installer.sig)"
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        actual="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
        if [ "$expected" != "$actual" ]; then
            rm -f /tmp/composer-setup.php
            die "The Composer installer's checksum doesn't match. Not installing."
        fi
        php /tmp/composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer
        rm -f /tmp/composer-setup.php
    fi

    step "Creating the $SITE_USER user (owns all sites)"
    if id "$SITE_USER" >/dev/null 2>&1; then
        echo "Already exists."
    else
        useradd --create-home --shell /bin/bash "$SITE_USER"
    fi
    # nginx runs as www-data and must read the sites' static files in /home/servio (a 750
    # folder): putting it in the servio group gives it read access, nothing more.
    usermod -aG "$SITE_USER" www-data

    step "Running PHP-FPM as $SITE_USER"
    # PHP then owns the same files as the user who deploys them (no permission fights).
    # listen.owner stays www-data, so nginx can still talk to the PHP-FPM socket.
    local pool="/etc/php/$php_version/fpm/pool.d/www.conf"
    sed -i -E "s/^user = .*/user = $SITE_USER/; s/^group = .*/group = $SITE_USER/" "$pool"
    systemctl enable "php$php_version-fpm"
    systemctl restart "php$php_version-fpm"

    step "Starting nginx"
    nginx -t
    systemctl enable nginx
    systemctl restart nginx

    step "Firewall: allow SSH (port $ssh_ports), HTTP and HTTPS, block the rest"
    # SSH FIRST. Enabling UFW without it would lock everyone out.
    local port
    for port in $ssh_ports; do ufw allow "$port/tcp"; done
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    ufw status verbose

    step "Done"
    nginx -v 2>&1
    php -v | head -n 1
    COMPOSER_ALLOW_SUPERUSER=1 composer --version
}

main "$@" < /dev/null
