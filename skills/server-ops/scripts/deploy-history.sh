#!/usr/bin/env bash
# deploy-history.sh: a site's past deploys and rollbacks (item 72). READ-ONLY.
#
#   bash run.sh <host> deploy-history.sh <domain> [count]       # default 10, at most 50
#
# Three sources, each checked line by line:
#   1. the action log (/var/log/servio-agent.log): every deploy and rollback through
#      servio-agent: when, who, result, how long
#   2. the releases on disk: name, commit, branch, who deployed it, which one is live
#      (rollback-site.sh can go back to any of these)
#   3. the deploy jobs still on the server (kept 7 days): their id, to read a deploy's full
#      output again with job-status.sh <id>

MAX_COUNT=50

main() {
    local domain="${1:-}" count="${2:-10}"
    [ -n "$domain" ] || die_input "Usage: deploy-history.sh <domain> [count]"
    validate_domain "$domain"
    [[ "$count" =~ ^[0-9]{1,3}$ && "$count" -ge 1 ]] || die_input "count must be a number from 1 to $MAX_COUNT."
    [ "$count" -le "$MAX_COUNT" ] || count="$MAX_COUNT"
    require_root

    step "Deploys and rollbacks of $domain (action log, newest last)"
    history_from_log "$domain" "$ACTION_LOG" "$count"

    step "Releases on the server (oldest first)"
    releases_report "$domain"

    step "Deploy jobs still on the server (full output: job-status.sh <id>)"
    deploy_jobs "$domain" "$JOBS_DIR"
}

# history_from_log <domain> <log> <n>: deploys and rollbacks of this site, the last n.
history_from_log() {
    local domain="$1" log="$2" n="$3" lines
    if [ ! -r "$log" ]; then echo "  No action log yet."; return 0; fi
    lines="$(grep -E ' script=(deploy-site|rollback-site)\.sh ' "$log" | grep -F " site=$domain " | tail -n "$n" || true)"
    if [ -z "$lines" ]; then echo "  None through servio-agent yet."; return 0; fi
    printf '%s\n' "$lines" | perl -ne '
        my ($t) = /^(\S+)/; my ($u) = / user=(\S+)/; my ($s) = / script=(deploy|rollback)-site\.sh/;
        my ($r) = / result=(\S+)/; my ($d) = / duration=(\S+)/; my ($a) = / args=\[([^\]]*)\]/;
        my @f = map { defined && /^[A-Za-z0-9._:+-]{1,40}$/ ? $_ : "?" } $t, $s, $u, $r, $d;
        my @args = grep { /^[A-Za-z0-9._:\/@+-]{1,100}$/ } split / /, ($a // "");
        shift @args;                                   # the domain itself
        printf "  %s  %-8s by %-12s %-12s %6s  %s\n", @f, join(" ", @args);
    '
}

# releases_report <domain>: every release with its .servio-release; the live one marked.
releases_report() {
    local domain="$1" live name any=0
    live="$(current_release "$domain")"
    for name in $(release_names "$domain"); do
        any=1
        if [ "$name" = "00000000-000000-placeholder" ]; then
            printf '  %s %s  (the placeholder page from create-site)\n' "$([ "$name" = "$live" ] && echo '*' || echo ' ')" "$name"
            continue
        fi
        read_release "$(site_releases "$domain")/$name"
        printf '  %s %s  %s  %-20s by %-12s %s\n' "$([ "$name" = "$live" ] && echo '*' || echo ' ')" "$name" \
            "${REL_COMMIT:0:7}" "${REL_BRANCH:-?}" "${REL_BY:-?}" "${REL_TIME:-?}"
    done
    [ "$any" -eq 1 ] && echo "  (* = live)" || echo "  No releases (not created with v0.5 release folders)."
}

# deploy_jobs <domain> <jobs dir>: deploy jobs of this site, newest first.
deploy_jobs() {
    local domain="$1" jobs="$2" id any=0
    [ -d "$jobs" ] || { echo "  none"; return 0; }
    for id in $(ls -1 "$jobs" 2>/dev/null | sort -r); do
        valid_job_id "$id" || continue
        grep -qx "script=deploy-site.sh" "$jobs/$id/meta" 2>/dev/null || continue
        grep -qx "site=$domain" "$jobs/$id/meta" 2>/dev/null || continue
        any=1
        printf '  %s  %-9s exit=%s\n' "$id" "$(job_state "$id")" "$(cat "$jobs/$id/exit-code" 2>/dev/null | tr -cd '0-9' || echo -)"
    done
    [ "$any" -eq 1 ] || echo "  none (jobs are kept 7 days)"
}

servio_run "$@"
