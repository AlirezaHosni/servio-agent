#!/usr/bin/env bash
# job-stop.sh: stop a running long job (provision, deploy, SSL). A CHANGE: needs your OK.
#
#   bash run.sh <host> job-stop.sh <job-id> [--dry-run]
#
# Stops the job's systemd unit, which ends every process it started (composer, git, apt...).
# Careful: a job stopped halfway can leave things half done (a deploy with half the new files,
# apt in the middle of an install). Check the state afterwards with inventory.sh, and run the
# job again (every script is safe to run again) or fix by hand.

main() {
    local id="${1:-}" state
    [ -n "$id" ] || die_input "Usage: job-stop.sh <job-id>"
    valid_job_id "$id" || die_input "Invalid job id '$id' (it looks like 20261123-140501-a1b2c3)."
    begin_change "job:$id" "$@"
    require_root

    state="$(job_state "$id")"
    [ "$state" = "running" ] || die_state "Job $id isn't running (state: $state). Nothing to stop."

    step "Stopping job $id ($(sed -n 's/^script=//p' "$JOBS_DIR/$id/meta"))"
    if [ -f "$JOBS_DIR/$id/foreground" ]; then
        run kill "$(cat "$JOBS_DIR/$id/pid")"
    else
        run systemctl stop "servio-job-$id"
    fi
    dry_run && return 0

    step "Checking the result"
    sleep 1
    state="$(job_state "$id")"
    if [ "$state" != "running" ]; then check_pass "job stopped" "state: $state"; else check_fail "job stopped" "still running"; fi
    check_summary || die "The job is still running."
    echo "Stopped. It may have left things half done: check with inventory.sh before running it again."
}

servio_run "$@"
