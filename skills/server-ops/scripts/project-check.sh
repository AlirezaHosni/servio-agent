#!/usr/bin/env bash
# project-check.sh: what does the code about to be deployed need, and does the server have it?
# (items 11-12). READ-ONLY for the site: nothing in it changes.
#
#   bash run.sh <host> project-check.sh <domain> [branch] [repository]
#
# Branch and repository default to what the site deploys now (like deploy-site.sh).
#
#   1. as the site's user: a shallow clone of the branch's newest commit into the site's tmp
#      folder, with no working files (only git's own data); deleted when the script ends
#   2. read the commit, never run it: composer.json/.lock, package.json, the queue names in the
#      code, the scheduler, Horizon / Reverb / Octane / Pulse, a Dockerfile
#   3. compare with the server: PHP version and extensions, Redis, Node.js, the site's workers
#      (Supervisor) and scheduler (cron), QUEUE_CONNECTION
#
# From .env only these plain, non-secret values are read, as the site's user: QUEUE_CONNECTION
# (and the other keys in ENV_KEYS_ALLOWED, lib.sh). Everything read from the repository is
# checked against a pattern before it's printed: it's written by anyone who can push.
#
# Ends with SERVIO_PLAN_* lines (workers, scheduler, build) that the deploy and workers scripts use.

main() {
    local domain="${1:-}" branch="${2:-}" repository="${3:-}"
    [ -n "$domain" ] || die_input "Usage: project-check.sh <domain> [branch] [repository]"
    validate_domain "$domain"
    [ -z "$branch" ] || validate_branch "$branch"
    [ -z "$repository" ] || validate_repository "$repository"
    require_root

    local user
    user="$(site_user "$domain")"
    id "$user" >/dev/null 2>&1 || die_state "No site user $user: $domain isn't set up on this server."
    [ -f "$(deploy_key_path "$domain")" ] || die_state "The deploy key for $domain is missing (create-site.sh makes it)."
    read_site_settings "$domain"

    # Defaults: what the live release was deployed from (its .servio-release).
    read_release "$(site_releases "$domain")/$(current_release "$domain")"
    [ -n "$repository" ] || repository="$REL_REPOSITORY"
    [ -n "$repository" ] || die_input "Not deployed yet: pass the repository, e.g. git@github.com:owner/repo.git"
    validate_repository "$repository"
    [ -n "$branch" ] || branch="${REL_BRANCH:-main}"
    validate_branch "$branch"

    step "Reading $branch of $repository"
    project_clone "$domain" "$repository" "$branch"
    echo "commit: $PROJECT_COMMIT"
    project_plan "$PROJECT_GIT" "$PROJECT_COMMIT" "$user"

    step "What the project needs"
    print_plan

    step "Plan vs server (PHP $SITE_PHP)"
    plan_vs_server "$domain" "$SITE_PHP"
    check_summary || true
}

servio_run "$@"
