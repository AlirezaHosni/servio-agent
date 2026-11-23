#!/usr/bin/env bash
# domains.sh: more names for a site, and the www redirect (item 14).
#
#   bash run.sh <host> domains.sh <domain> add <name> [--dry-run]       serve <name> too
#   bash run.sh <host> domains.sh <domain> remove <name> [--dry-run]
#   bash run.sh <host> domains.sh <domain> www on|off [--dry-run]       www.<domain> -> <domain> (301)
#
# The names live in the site's nginx config (`# servio-aliases:` / `# servio-www:` lines). The
# config is re-rendered, tested with nginx -t and undone if nginx rejects it.
#
# HTTPS: the certificate covers only the names it was issued for. After adding a name to an
# HTTPS site, run issue-certificate.sh <domain> again: it checks every name points here, then
# extends the certificate (--expand). Until then the new name shows a certificate warning, so
# point its DNS here first. Removing a name doesn't shrink the certificate (harmless).

MAX_ALIASES=10

main() {
    local domain="${1:-}" action="${2:-}" name="${3:-}"
    [ -n "$domain" ] && [ -n "$action" ] || die_input "Usage: domains.sh <domain> add|remove <name> | www on|off"
    validate_domain "$domain"
    case "$action" in
        add|remove)
            [ -n "$name" ] || die_input "Which name? domains.sh $domain $action <name>"
            validate_domain "$name"
            [ "$name" != "$domain" ] || die_input "$name is the site's main domain."
            [ "$name" != "www.$domain" ] || die_input "For www.$domain use: domains.sh $domain www on (a redirect)." ;;
        www) [[ "$name" =~ ^(on|off)$ ]] || die_input "domains.sh $domain www on|off" ;;
        *) die_input "Unknown '$action': add, remove or www." ;;
    esac
    begin_change "$domain" "$@"

    step "Checking the site"
    require_root
    read_site_settings "$domain"           # also reads the current names (read_site_meta)
    lock_site "$domain"
    echo "Now: $(site_names "$domain")${SITE_WWW:+ (+ $SITE_WWW -> $domain)}"

    case "$action" in
        add)
            case " $SITE_ALIASES " in *" $name "*) echo "$name is already served."; return 0 ;; esac
            [ "$(wc -w <<< "$SITE_ALIASES")" -lt "$MAX_ALIASES" ] || die_refused "$domain has $MAX_ALIASES extra names already."
            other_site_with "$name" "$domain"
            SITE_ALIASES="${SITE_ALIASES:+$SITE_ALIASES }$name" ;;
        remove)
            case " $SITE_ALIASES " in *" $name "*) ;; *) echo "$name isn't one of its names."; return 0 ;; esac
            # `|| true`: removing the last extra name leaves nothing, which grep reports as "no match".
            SITE_ALIASES="$(printf '%s\n' $SITE_ALIASES | grep -vx "$name" | tr '\n' ' ' || true)"; SITE_ALIASES="${SITE_ALIASES% }" ;;
        www)
            if [ "$name" = "on" ]; then other_site_with "www.$domain" "$domain"; SITE_WWW="www.$domain"; else SITE_WWW=""; fi ;;
    esac

    step "The nginx config with: $(site_names "$domain")${SITE_WWW:+ (+ $SITE_WWW -> $domain)}"
    local new_config
    new_config="$(mktemp)"; add_exit_hook "rm -f '$new_config'"
    nginx_current_config "$domain" "$SITE_ROOT" "$SITE_PHP" > "$new_config"
    apply_nginx_config "$domain" "$new_config"

    if dry_run; then
        step "Done (dry run): nothing was changed"
        return 0
    fi

    step "Checking the result"
    local n
    for n in $(certificate_names "$domain"); do
        site_status "$n" http
        [ "$SITE_STATUS" != "000" ] && check_pass "nginx answers for $n" "status $SITE_STATUS" || check_fail "nginx answers for $n"
    done
    check_summary || die "nginx doesn't answer for every name (see above)."
    if [ -f "$(certificate_path "$domain")" ] && [ "$action" != "remove" ] && ! { [ "$action" = www ] && [ "$name" = off ]; }; then
        echo "HTTPS: run issue-certificate.sh $domain now to add the new name to the certificate (DNS must point here first)."
    fi
}

# other_site_with <name> <this domain>: refuse a name another site's config already serves.
other_site_with() {
    local f
    for f in "$NGINX_DIR"/sites-enabled/*; do
        [ -e "$f" ] || continue
        [ "$(basename "$f")" != "$2" ] || continue
        if grep -qE "server_name[^;]*[[:space:]]$(printf '%s' "$1" | sed 's/\./\\./g')([[:space:];]|$)" "$f"; then
            die_refused "$1 is already served by $(basename "$f" | tr -cd 'a-z0-9.-'). Remove it there first."
        fi
    done
}

servio_run "$@"
