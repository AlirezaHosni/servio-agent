#!/usr/bin/env bash
# workers.sh: a site's queue workers, Horizon, Reverb and scheduler (item 21, decision 2).
#
#   bash run.sh <host> workers.sh <domain> queue [queues] [processes] [--dry-run]
#   bash run.sh <host> workers.sh <domain> horizon      [--dry-run]
#   bash run.sh <host> workers.sh <domain> reverb       [--dry-run]
#   bash run.sh <host> workers.sh <domain> scheduler    [--dry-run]
#   bash run.sh <host> workers.sh <domain> remove <queue|horizon|reverb|scheduler> [--dry-run]
#
#   queue      Supervisor runs `queue:work --queue=<queues>` (comma list, default "default"),
#              <processes> copies (1-8, default 1). Run again to change queues or processes
#   horizon    Supervisor runs `horizon` (it manages its own queue processes)
#   reverb     Supervisor runs `reverb:start` on 127.0.0.1:8080 (nginx proxying of the
#              websocket isn't set up yet: a person adds that location for now)
#   scheduler  a cron line runs `schedule:run` every minute (+ log rotation for its log)
#   remove     stops it and removes its config
#
# What to run comes from the project check (SERVIO_PLAN_WORKERS / SCHEDULER lines of
# project-check.sh or the deploy). All programs run as the site's user, from `current`, with the
# site's PHP version; logs go to shared/storage/logs/<name>.log (size-limited).
# Configs this script didn't write (no "Managed by Servio" line) are never overwritten.

main() {
    local domain="${1:-}" what="${2:-}" a3="${3:-}" a4="${4:-}"
    [ -n "$domain" ] && [ -n "$what" ] || die_input "Usage: workers.sh <domain> queue|horizon|reverb|scheduler|remove ..."
    validate_domain "$domain"
    local queues="default" procs=1 kind=""
    case "$what" in
        queue)
            [ -z "$a3" ] || queues="$a3"
            [ -z "$a4" ] || procs="$a4"
            [[ "$queues" =~ ^[A-Za-z0-9_.-]{1,40}(,[A-Za-z0-9_.-]{1,40}){0,9}$ ]] \
                || die_input "Queues: a comma list of names, e.g. high,emails,default."
            [[ "$procs" =~ ^[1-9]$ ]] && [ "$procs" -le "$MAX_PROCESSES" ] || die_input "Processes: 1 to $MAX_PROCESSES."
            kind="worker" ;;
        horizon|reverb) kind="$what" ;;
        scheduler) kind="scheduler" ;;
        remove)
            case "$a3" in
                queue) kind="worker" ;;
                horizon|reverb|scheduler) kind="$a3" ;;
                *) die_input "remove what? queue, horizon, reverb or scheduler." ;;
            esac ;;
        *) die_input "Unknown '$what': queue, horizon, reverb, scheduler or remove." ;;
    esac
    begin_change "$domain" "$@"

    step "Checking the site"
    require_root
    id "$(site_user "$domain")" >/dev/null 2>&1 || die_state "No site user for $domain: create the site first."
    read_site_settings "$domain"
    [ -L "$(site_current "$domain")" ] || die_state "$domain has no release folders yet (create-site.sh, then deploy)."
    if [ "$what" != "remove" ] && [ ! -f "$(site_current "$domain")/artisan" ]; then
        die_state "The live release of $domain isn't a Laravel app (no artisan): deploy it first."
    fi
    lock_site "$domain"
    echo "Now: $(site_worker_status "$domain" | tr '\n' ' ')$(site_has_scheduler "$domain" && echo ' scheduler on' || echo ' scheduler off')"

    if [ "$what" = "remove" ]; then
        remove_part "$domain" "$kind"
    elif [ "$kind" = "scheduler" ]; then
        step "Scheduler: schedule:run every minute"
        require_managed_or_absent "$(scheduler_file "$domain")"
        scheduler_cron "$domain" "$SITE_PHP" | write_file "$(scheduler_file "$domain")" 644 root:root
        logrotate_config "$domain" | write_file "$(logrotate_file "$domain")" 644 root:root
    else
        require_cmd supervisorctl "Supervisor isn't installed: run provision-server.sh again."
        step "Supervisor program $(site_user "$domain")-$kind"
        require_managed_or_absent "$(worker_conf "$domain" "$kind")"
        worker_program "$domain" "$SITE_PHP" "$kind" "$queues" "$procs" | write_file "$(worker_conf "$domain" "$kind")" 644 root:root
        # reread: load changed configs; update: start new programs, restart changed ones, stop removed ones.
        run supervisorctl reread
        run supervisorctl update
        [ "$kind" != "reverb" ] || echo "Note: Reverb listens on 127.0.0.1:8080; nginx doesn't proxy websockets to it yet."
    fi

    if dry_run; then
        step "Done (dry run): nothing was changed"
        return 0
    fi

    step "Checking the result"
    check_result "$domain" "$what" "$kind" "$procs"
    check_summary || die "Not everything is running (see above). Look at logs.sh $domain laravel and the worker log."
}

# require_managed_or_absent <file>: never overwrite a config a person wrote by hand.
require_managed_or_absent() {
    [ ! -e "$1" ] && return 0
    grep -qF "$MANAGED_HEADER" "$1" || die_refused "$1 exists but wasn't written by Servio. Not touching it."
}

remove_part() {
    local domain="$1" kind="$2" file
    if [ "$kind" = "scheduler" ]; then
        step "Removing the scheduler"
        file="$(scheduler_file "$domain")"
        [ -e "$file" ] || { echo "None (from servio-agent)."; return 0; }
        require_managed_or_absent "$file"
        run rm -f "$file" "$(logrotate_file "$domain")"
        return 0
    fi
    step "Removing $(site_user "$domain")-$kind"
    file="$(worker_conf "$domain" "$kind")"
    [ -e "$file" ] || { echo "None."; return 0; }
    require_managed_or_absent "$file"
    run rm -f "$file"
    # update stops a program whose config is gone (a worker finishes its job first: stopwaitsecs).
    run supervisorctl reread
    run supervisorctl update
}

check_result() {
    local domain="$1" what="$2" kind="$3" procs="$4" status running
    if [ "$kind" = "scheduler" ]; then
        if [ "$what" = "remove" ]; then
            [ ! -e "$(scheduler_file "$domain")" ] && check_pass "scheduler removed" || check_fail "scheduler removed"
        else
            site_has_scheduler "$domain" && check_pass "scheduler" "cron runs schedule:run every minute" || check_fail "scheduler"
        fi
        return 0
    fi
    # startsecs=1: give the processes a moment to start (or to fail and show it).
    sleep 3
    status="$(site_worker_status "$domain" | grep -F "$(site_user "$domain")-$kind:" || true)"
    if [ "$what" = "remove" ]; then
        [ -z "$status" ] && check_pass "$kind stopped and removed" || check_fail "$kind still in Supervisor" "$status"
        return 0
    fi
    running="$(printf '%s\n' "$status" | grep -c ' RUNNING$' || true)"
    if [ "$running" -eq "$procs" ]; then
        check_pass "$kind running" "$running process(es)"
    else
        check_fail "$kind running" "$running of $procs running: $(printf '%s' "$status" | tr '\n' ' ')"
    fi
}

servio_run "$@"
