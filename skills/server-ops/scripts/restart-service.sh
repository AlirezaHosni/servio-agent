#!/usr/bin/env bash
# restart-service.sh: restart (or reload) one service (item 22).
#
#   bash run.sh <host> restart-service.sh <service> [--dry-run]
#   bash run.sh <host> restart-service.sh workers <domain> [--dry-run]
#
#   nginx        test the config (nginx -t), then RELOAD: no request is dropped
#   php8.4       (php8.3, php8.5) test (php-fpm -t), then RELOAD: running requests finish
#   mysql        restart (MySQL or MariaDB: whichever is installed)
#   redis        restart
#   supervisor   restart: every site's workers restart with it
#   workers      one site's Supervisor programs (graceful: each finishes its job first)
#
# A reload instead of a restart wherever the program supports it: a restart drops the requests
# in flight, a reload doesn't. A config that fails its test is never loaded: the service keeps
# running on the old one. Before restarting a database, ask: every site using it gets errors
# for a few seconds.

main() {
    local service="${1:-}" domain="${2:-}" unit action test=""
    [ -n "$service" ] || die_input "Usage: restart-service.sh nginx|php8.4|mysql|redis|supervisor|workers <domain>"
    case "$service" in
        nginx) unit="nginx"; action="reload"; test="nginx -t" ;;
        php8.3|php8.4|php8.5) validate_php "${service#php}"; unit="$service-fpm"; action="reload"; test="php-fpm${service#php} -t" ;;
        mysql) unit="mysql"; action="restart" ;;
        redis) unit="redis-server"; action="restart" ;;
        supervisor) unit="supervisor"; action="restart" ;;
        workers)
            [ -n "$domain" ] || die_input "workers needs the domain: restart-service.sh workers <domain>"
            validate_domain "$domain"; unit="(Supervisor programs of $domain)"; action="restart" ;;
        *) die_input "Unknown service '$service': nginx, php8.3/8.4/8.5, mysql, redis, supervisor, workers." ;;
    esac
    begin_change "${domain:-server}" "$@"
    require_root

    if [ "$service" = "mysql" ] && ! systemctl cat mysql >/dev/null 2>&1; then
        systemctl cat mariadb >/dev/null 2>&1 && unit="mariadb" || die_state "Neither MySQL nor MariaDB is installed."
    fi
    if [ "$service" != "workers" ]; then
        systemctl cat "$unit" >/dev/null 2>&1 || die_state "$unit isn't installed on this server."
        echo "$unit is $(systemctl is-active "$unit" 2>/dev/null || true) now."
    fi

    if [ "$service" = "workers" ]; then
        require_cmd supervisorctl
        local programs
        programs="$(site_worker_status "$domain" | awk '{print $1}' | sed 's/:.*//' | sort -u)"
        [ -n "$programs" ] || die_state "$domain has no workers in Supervisor (workers.sh adds them)."
        step "Restarting the workers of $domain: $(printf '%s' "$programs" | tr '\n' ' ')"
        local p
        for p in $programs; do run supervisorctl restart "$p:*"; done
    else
        if [ -n "$test" ]; then
            step "Testing the config: $test"
            if dry_run; then
                echo "[dry-run] would run: $test"
            elif ! $test 2>&1; then
                die_state "The config test failed: NOT reloading (it keeps running on the old config)."
            fi
        fi
        step "${action^} $unit"
        run systemctl "$action" "$unit"
    fi

    if dry_run; then
        step "Done (dry run): nothing was changed"
        return 0
    fi

    step "Checking the result"
    sleep 2
    if [ "$service" = "workers" ]; then
        local bad
        bad="$(site_worker_status "$domain" | grep -v ' RUNNING$' || true)"
        [ -z "$bad" ] && check_pass "workers running" || check_fail "workers running" "$(printf '%s' "$bad" | tr '\n' ' ')"
    else
        systemctl is-active --quiet "$unit" && check_pass "$unit running" || check_fail "$unit running" "$(systemctl is-active "$unit" 2>/dev/null || true)"
    fi
    check_summary || die "$unit isn't running after the $action (see above). Read its log: logs.sh server syslog."
}

servio_run "$@"
