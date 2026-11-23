#!/usr/bin/env bash
# job-status.sh: how a long job is doing (provision, deploy, SSL started with run.sh). READ-ONLY.
#
#   bash run.sh <host> job-status.sh                      the last 10 jobs on this server
#   bash run.sh <host> job-status.sh <job-id> [offset]    one job: state, exit code, new output
#
# With an offset, only the output written since then is printed, so checking every ~30 seconds
# shows each line once. The last lines are always:
#   SERVIO_JOB_STATE=running|finished|stopped|unknown
#   SERVIO_JOB_EXIT=<code>        (only when finished: 0 = success, see the exit codes in lib.sh)
#   SERVIO_JOB_OFFSET=<bytes>     pass this as the offset next time
#
# Use it after a dropped connection or a timeout: check what happened BEFORE running anything
# again (rule 38). A deploy may still be running, or may have finished.

main() {
    local id="${1:-}" offset="${2:-0}" dir state
    require_root

    if [ -z "$id" ]; then
        step "Recent jobs"
        if [ ! -d "$JOBS_DIR" ] || [ -z "$(ls -A "$JOBS_DIR" 2>/dev/null)" ]; then
            echo "  No jobs yet."
            return 0
        fi
        # Newest first. Job ids start with the date and time, so they sort by time.
        for dir in $(ls -1 "$JOBS_DIR" | sort -r | head -n 10); do
            valid_job_id "$dir" || continue
            printf '  %s  %-22s %-9s exit=%-3s by %s\n' "$dir" \
                "$(sed -n 's/^script=//p' "$JOBS_DIR/$dir/meta" 2>/dev/null || true)" \
                "$(job_state "$dir")" "$(cat "$JOBS_DIR/$dir/exit-code" 2>/dev/null || echo -)" \
                "$(sed -n 's/^user=//p' "$JOBS_DIR/$dir/meta" 2>/dev/null || true)"
        done
        return 0
    fi

    valid_job_id "$id" || die_input "Invalid job id '$id' (it looks like 20261123-140501-a1b2c3)."
    [[ "$offset" =~ ^[0-9]{1,12}$ ]] || die_input "Invalid offset '$offset' (a number of bytes)."
    dir="$JOBS_DIR/$id"
    [ -d "$dir" ] || die_state "No job $id on this server (jobs are kept 7 days)."

    state="$(job_state "$id")"
    [ "$offset" -gt 0 ] || sed 's/^/# /' "$dir/meta" 2>/dev/null || true
    job_output "$id" "$offset"
    echo
    echo "SERVIO_JOB_STATE=$state"
    [ "$state" != "finished" ] || echo "SERVIO_JOB_EXIT=$(cat "$dir/exit-code")"
    echo "SERVIO_JOB_OFFSET=$JOB_OFFSET"
}

servio_run "$@"
