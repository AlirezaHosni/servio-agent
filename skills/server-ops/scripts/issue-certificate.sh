#!/usr/bin/env bash
# issue-certificate.sh: give a site HTTPS with a free Let's Encrypt certificate.
#
#   bash run.sh <host> issue-certificate.sh <domain>
#
#   1. install certbot (if missing) and its renewal timer
#   2. make port 80 answer Let's Encrypt's check (/.well-known/acme-challenge/)
#   3. SELF-CHECK: put a random file there and fetch it through the domain. If the domain
#      doesn't reach this server, stop here, before asking Let's Encrypt (it allows only a
#      few failed attempts per hour)
#   4. `certbot certonly --webroot`: certbot only gets the certificate, it does NOT edit nginx.
#      lib.sh owns the nginx config, so the two never fight over it
#   5. switch the nginx config to HTTPS (HTTP redirects to it), tested with `nginx -t`
#   6. print the expiry date as SERVIO_CERTIFICATE_EXPIRES=... (the last line)
#
# The certificate's private key is created by certbot ON the server and stays there. Renewal
# is certbot's systemd timer (twice a day, ~30 days before expiry, then reloads nginx).
# Safe to run again: with a valid certificate, certbot keeps it (--keep-until-expiring).
# Ported from Servio's IssueCertificate recipe.

main() {
    local domain="${1:-}"
    [ -n "$domain" ] || die "Usage: issue-certificate.sh <domain>"
    validate_domain "$domain"
    validate_public_domain "$domain"

    # Not `local`: CHALLENGE is read by the EXIT trap, which runs after main has returned.
    local settings web_dir php_version web_root live http_config https_config token got expires
    CHALLENGE=""
    step "Checking the site"
    require_root
    settings="$(read_site_settings "$domain")"
    web_dir="${settings% *}"
    php_version="${settings#* }"
    web_root="$(site_dir "$domain")/$web_dir"
    live="/etc/letsencrypt/live/$domain"
    echo "OK: $(nginx_available "$domain") (web root $web_root, PHP $php_version)"

    # Both configs are written to temporary files first, then put in place one at a time by
    # apply_nginx_config. Whatever happens, the temporary files and the self-check file go.
    http_config="$(mktemp)"; https_config="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$http_config' '$https_config'"' ${CHALLENGE:+"$CHALLENGE"}' EXIT
    nginx_http_config "$domain" "$web_root" "$php_version" > "$http_config"
    nginx_https_config "$domain" "$web_root" "$php_version" > "$https_config"

    step "Installing certbot"
    if command -v certbot >/dev/null 2>&1; then
        echo "Already installed: $(certbot --version 2>&1)"
    else
        apt-get -o DPkg::Lock::Timeout=600 -y install certbot
    fi
    # The Ubuntu package renews with a systemd timer (twice a day). Make sure it's on.
    systemctl enable --now certbot.timer
    echo "Renewal timer: $(systemctl is-active certbot.timer)"

    step "Letting Let's Encrypt reach /.well-known/acme-challenge/"
    install -d -m 755 "$ACME_ROOT/.well-known/acme-challenge"
    if [ -f "$live/fullchain.pem" ]; then
        # A certificate exists already: keep serving HTTPS (its port 80 block answers the check too).
        apply_nginx_config "$domain" "$https_config"
    else
        apply_nginx_config "$domain" "$http_config"
    fi
    echo "OK"

    step "Checking that http://$domain reaches this server"
    # Done BEFORE asking Let's Encrypt: it allows only 5 failed checks per domain per hour, and
    # its error ("connection refused", "unauthorized") explains less than this does.
    token="servio-check-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    CHALLENGE="$ACME_ROOT/.well-known/acme-challenge/$token"
    echo "$token" > "$CHALLENGE"
    got="$(curl -fsS --max-time 15 "http://$domain/.well-known/acme-challenge/$token" 2>&1 || true)"
    if [ "$got" != "$token" ]; then
        echo "http://$domain doesn't reach this server yet, so Let's Encrypt couldn't check it either." >&2
        echo "  curl said:        ${got:-nothing}" >&2
        echo "  $domain points to: $(getent ahosts "$domain" | awk '{print $1}' | sort -u | tr '\n' ' ')" >&2
        echo "  this server is:   $(hostname -I)" >&2
        die "Add an A record for $domain with this server's IP, wait until DNS shows it, then try again."
    fi
    echo "OK: the domain points here."

    step "Requesting the certificate from Let's Encrypt"
    # certonly --webroot: get the certificate only; nginx is configured by lib.sh, not certbot.
    # --cert-name: a fixed folder name, /etc/letsencrypt/live/<domain>/ (no "-0001" copies).
    # --deploy-hook: saved with the certificate, so every future renewal reloads nginx too.
    # --register-unsafely-without-email: no personal data leaves the laptop; renewal is automatic.
    certbot certonly --webroot -w "$ACME_ROOT" \
        -d "$domain" --cert-name "$domain" \
        --non-interactive --agree-tos --register-unsafely-without-email \
        --keep-until-expiring \
        --deploy-hook "systemctl reload nginx"

    step "Switching $domain to HTTPS"
    apply_nginx_config "$domain" "$https_config"
    echo "https://$domain is served with the certificate; http:// redirects to it."

    expires="$(date -u -d "$(openssl x509 -enddate -noout -in "$live/fullchain.pem" | cut -d= -f2)" +%Y-%m-%dT%H:%M:%SZ)"
    echo "Valid until $expires. certbot renews it automatically about 30 days before."
    echo "SERVIO_CERTIFICATE_EXPIRES=$expires"
}

main "$@" < /dev/null
