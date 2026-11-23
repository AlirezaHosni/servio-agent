#!/usr/bin/env bash
# issue-certificate.sh: give a site HTTPS with a free Let's Encrypt certificate.
#
#   bash run.sh <host> issue-certificate.sh <domain> [--dry-run]
#
#   1. install certbot (if missing) and its renewal timer
#   2. make port 80 answer Let's Encrypt's check (/.well-known/acme-challenge/)
#   3. SELF-CHECK: put a random file there and fetch it through the domain. If the domain
#      doesn't reach this server, stop here, before asking Let's Encrypt (it allows only a
#      few failed attempts per hour)
#   4. `certbot certonly --webroot`: certbot only gets the certificate, it does NOT edit nginx.
#      lib.sh owns the nginx config, so the two never fight over it
#   5. switch the nginx config to HTTPS (HTTP redirects to it), tested with `nginx -t`
#   6. check the result: https:// answers with a certificate valid for the domain, http://
#      redirects to it (item 52)
#   7. print the expiry date as SERVIO_CERTIFICATE_EXPIRES=... (the last line)
#
# --dry-run: shows where the domain points and what this server's addresses are, and the
# nginx config change (as a diff). Asks Let's Encrypt nothing, changes nothing.
#
# The certificate's private key is created by certbot ON the server and stays there. Renewal
# is certbot's systemd timer (twice a day, ~30 days before expiry, then reloads nginx).
# Safe to run again: with a valid certificate, certbot keeps it (--keep-until-expiring).
# Ported from Servio's IssueCertificate recipe.

main() {
    local domain="${1:-}"
    [ -n "$domain" ] || die_input "Usage: issue-certificate.sh <domain>"
    validate_domain "$domain"
    validate_public_domain "$domain"
    begin_change "$domain" "$@"

    local web_root live http_config https_config token challenge got expires names name
    step "Checking the site"
    require_root
    read_site_settings "$domain"
    web_root="$SITE_ROOT"
    live="$LETSENCRYPT_DIR/live/$domain"
    # The main domain, its extra names and the www redirect (domains.sh): all on one certificate.
    names="$(certificate_names "$domain")"
    for name in $names; do validate_public_domain "$name"; done
    lock_site "$domain"
    echo "OK: $(nginx_available "$domain") (web root $web_root, PHP $SITE_PHP)"

    # Both configs are written to temporary files first, then put in place one at a time by
    # apply_nginx_config. Whatever happens, the temporary files go (exit hook).
    http_config="$(mktemp)"; https_config="$(mktemp)"
    add_exit_hook "rm -f '$http_config' '$https_config'"
    nginx_http_config "$domain" "$web_root" "$SITE_PHP" > "$http_config"
    nginx_https_config "$domain" "$web_root" "$SITE_PHP" > "$https_config"

    if dry_run; then
        step "Where $domain points"
        for name in $names; do
            echo "  $name points to: $(getent ahosts "$name" | awk '{print $1}' | sort -u | tr '\n' ' ')"
        done
        echo "  this server is:    $(hostname -I)"
        echo "  (the real run checks this properly before asking Let's Encrypt)"
        step "certbot"
        if command -v certbot >/dev/null 2>&1; then
            echo "  installed: $(certbot --version 2>&1)"
        else
            echo "[dry-run] would install certbot and turn on its renewal timer"
        fi
        if [ -f "$live/fullchain.pem" ]; then
            echo "  a certificate exists already (certbot keeps it unless it expires within 30 days)"
        else
            echo "[dry-run] would ask Let's Encrypt for a certificate for $domain"
        fi
        step "The nginx config after the switch to HTTPS"
        apply_nginx_config "$domain" "$https_config"
        step "Done (dry run): nothing was changed"
        return 0
    fi

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

    step "Checking that every name reaches this server: $names"
    # Done BEFORE asking Let's Encrypt: it allows only 5 failed checks per domain per hour, and
    # its error ("connection refused", "unauthorized") explains less than this does.
    # Every name on the certificate is checked: one name that doesn't point here fails them all.
    token="servio-check-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    challenge="$ACME_ROOT/.well-known/acme-challenge/$token"
    add_exit_hook "rm -f '$challenge'"
    echo "$token" > "$challenge"
    for name in $names; do
        got="$(curl -fsS --max-time 15 "http://$name/.well-known/acme-challenge/$token" 2>&1 || true)"
        if [ "$got" != "$token" ]; then
            echo "http://$name doesn't reach this server yet, so Let's Encrypt couldn't check it either." >&2
            echo "  curl said:        ${got:-nothing}" >&2
            echo "  $name points to: $(getent ahosts "$name" | awk '{print $1}' | sort -u | tr '\n' ' ')" >&2
            echo "  this server is:   $(hostname -I)" >&2
            die_state "Add an A record for $name with this server's IP, wait until DNS shows it, then try again (or remove that name: domains.sh)."
        fi
        echo "OK: $name points here."
    done

    step "Requesting the certificate from Let's Encrypt"
    # certonly --webroot: get the certificate only; nginx is configured by lib.sh, not certbot.
    # --cert-name: a fixed folder name, /etc/letsencrypt/live/<domain>/ (no "-0001" copies).
    # --deploy-hook: saved with the certificate, so every future renewal reloads nginx too.
    # --register-unsafely-without-email: no personal data leaves the laptop; renewal is automatic.
    # One -d per name (the main domain first). --expand: when names were added, replace the
    # certificate with one covering all of them (otherwise --keep-until-expiring keeps the old).
    local d_args=()
    for name in $names; do d_args+=(-d "$name"); done
    certbot certonly --webroot -w "$ACME_ROOT" \
        "${d_args[@]}" --cert-name "$domain" --expand \
        --non-interactive --agree-tos --register-unsafely-without-email \
        --keep-until-expiring \
        --deploy-hook "systemctl reload nginx"

    step "Switching $domain to HTTPS"
    apply_nginx_config "$domain" "$https_config"

    step "Checking the result"
    # https: curl checks the certificate against the domain name (status 000 = no answer or a
    # certificate that doesn't match).
    site_status "$domain" https
    if [ "$SITE_STATUS" != "000" ] && [ "$SITE_STATUS" -lt 500 ]; then
        check_pass "https://$domain answers with a valid certificate" "status $SITE_STATUS"
    else
        check_fail "https://$domain answers with a valid certificate" "status $SITE_STATUS"
    fi
    site_status "$domain" http
    if [ "$SITE_STATUS" = "301" ]; then
        check_pass "http://$domain redirects to https"
    else
        check_fail "http://$domain redirects to https" "status $SITE_STATUS"
    fi
    check_summary || die "The certificate was issued but HTTPS doesn't work as expected (see above)."

    expires="$(date -u -d "$(openssl x509 -enddate -noout -in "$live/fullchain.pem" | cut -d= -f2)" +%Y-%m-%dT%H:%M:%SZ)"
    echo "https://$domain is served with the certificate; http:// redirects to it."
    echo "Valid until $expires. certbot renews it automatically about 30 days before."
    echo "SERVIO_CERTIFICATE_EXPIRES=$expires"
}

servio_run "$@"
