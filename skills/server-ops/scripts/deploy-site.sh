#!/usr/bin/env bash
# deploy-site.sh: deploy a site from git.
#
#   bash run.sh <host> deploy-site.sh <domain> [branch] [repository] [--dry-run]
#   bash run.sh web1 deploy-site.sh shop.example.com main git@github.com:acme/shop.git
#
# The repository is needed on the first deploy only; later deploys reuse the site's git remote.
# The branch defaults to the branch deployed last time, or "main".
#
#   1. as root: check the site folder and its deploy key exist; read the PHP version from nginx
#   2. as the site's user: fetch the branch with the site's deploy key, check it out
#   3. as the site's user: run the deploy steps in the site folder: the repo's own .servio/deploy.sh if
#      it has one, otherwise the default Laravel steps below
#   4. as root: reload PHP-FPM (clears OPcache, so PHP runs the NEW code)
#   5. check the result: the site answers without a server error (item 52)
#   6. print SERVIO_COMMIT=<hash>, the commit that is now live (the last line)
#
# --dry-run: asks the repository which commit the branch points to and shows it next to the
# commit that is live now; nothing is fetched into the site, nothing runs.
#
# Steps 2 and 3 run as the site's user, not root: the files must belong to the user its PHP-FPM pool
# runs as, and
# the deploy steps run code from the repository, so they get the least power that works.
# In-place deploy: the site is briefly a mix of old and new files while it updates
# (release folders with an instant switch come in v0.5).
# Ported from Servio's DeploySite recipe.

main() {
    local domain="${1:-}" branch="${2:-}" repository="${3:-}"
    [ -n "$domain" ] || die_input "Usage: deploy-site.sh <domain> [branch] [repository]"
    validate_domain "$domain"
    begin_change "$domain" "$@"

    local user dir deploy_key script_file live remote scheme
    user="$(site_user "$domain")"
    dir="$(site_dir "$domain")"
    deploy_key="$(deploy_key_path "$domain")"

    step "Checking the site"
    require_root
    [ -d "$dir" ] || die_state "$dir doesn't exist. Run create-site.sh first."
    [ -f "$deploy_key" ] || die_state "The deploy key for $domain is missing. Run create-site.sh again to create it."
    read_site_settings "$domain"

    if [ -z "$repository" ] && [ -d "$dir/.git" ]; then
        repository="$(runuser -u "$user" -- git -C "$dir" remote get-url origin 2>/dev/null || true)"
    fi
    [ -n "$repository" ] || die_input "First deploy of $domain: pass the repository, e.g. git@github.com:owner/repo.git"
    validate_repository "$repository"

    if [ -z "$branch" ] && [ -d "$dir/.git" ]; then
        branch="$(runuser -u "$user" -- git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    fi
    [ -n "$branch" ] && [ "$branch" != "HEAD" ] || branch="main"
    validate_branch "$branch"
    lock_site "$domain"
    echo "OK: $repository ($branch), PHP $SITE_PHP"

    # Everything git does runs AS the site's user (runuser -u), with the site's own deploy key.
    #   IdentitiesOnly: use only this key.  accept-new: trust the git host's key the first time
    #   and pin it in ~/.ssh/known_hosts (Trust On First Use).
    #   BatchMode: never ask for a passphrase or password, fail instead.
    #   UserKnownHostsFile: the site user's own, also when root's environment is kept (dry run).
    export GIT_SSH_COMMAND="ssh -i $deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o UserKnownHostsFile=$(site_home "$domain")/.ssh/known_hosts"

    if dry_run; then
        step "What would be deployed"
        live="$( [ -d "$dir/.git" ] && runuser -u "$user" -- git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "nothing deployed yet")"
        remote="$(runuser -u "$user" --preserve-environment -- git ls-remote "$repository" "refs/heads/$branch" 2>&1 | head -n 1 || true)"
        if [[ "$remote" =~ ^([0-9a-f]{40})[[:space:]] ]]; then
            remote="${BASH_REMATCH[1]:0:7}"
        else
            remote="unknown (the repository didn't answer: is the deploy key added to it?)"
        fi
        echo "  live now:       $live"
        echo "  would deploy:   $remote ($branch)"
        echo "  deploy steps:   $( [ -f "$dir/.servio/deploy.sh" ] && echo "the repository's .servio/deploy.sh" || echo "the default Laravel steps (composer install, migrate --force, optimize)")"
        echo "  then:           reload PHP $SITE_PHP-FPM, check the site answers"
        step "Done (dry run): nothing was changed"
        return 0
    fi

    # The default steps are saved to a temporary file owned by the site's user, run from there, and
    # deleted when this script ends (the exit hook runs even after a failure).
    # In the site's own temp folder, not the shared /tmp.
    script_file="$(mktemp "$(site_home "$domain")/tmp/servio-deploy.XXXXXX")"
    add_exit_hook "rm -f '$script_file'"
    cat > "$script_file" <<'DEPLOY'
# Runs as the site's user, inside the site's folder, after the new code is checked out.
# Any command that fails stops the deploy.
composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader

if [ -f artisan ] && [ -f .env ]; then
    php artisan migrate --force
    php artisan optimize
elif [ -f artisan ]; then
    echo "No .env file yet: skipped migrations and caching. Add .env to the site folder, then deploy again."
fi
DEPLOY
    chown "$user:$user" "$script_file"

    step "Fetching $branch from $repository"
    # The git part runs in a NEW bash (as the site's user): only exported variables reach it.
    export SITE_DIR="$dir" REPOSITORY="$repository" BRANCH="$branch"
    cd "$dir"
    runuser -u "$user" -- bash -euo pipefail <<'GIT'
if [ ! -d .git ]; then
    git init -q
    git remote add origin "$REPOSITORY"
    echo "New git checkout in $SITE_DIR."
fi
git remote set-url origin "$REPOSITORY"
git fetch --depth=1 origin "$BRANCH"

# The placeholder page create-site.sh made is not part of the repository: remove it.
for page in public/index.html index.html; do
    if grep -qs "Created by Servio" "$page"; then rm -f "$page"; fi
done

# Point the branch at what we fetched and make the files match it exactly.
# Files git doesn't track (.env, storage/, uploads) are left alone.
git checkout -q -f -B "$BRANCH" FETCH_HEAD
git log -1 --format='Now at %h (%ar)'
GIT

    step "Running the deploy steps"
    if [ -f "$dir/.servio/deploy.sh" ]; then
        echo "Using the repository's .servio/deploy.sh"
        runuser -u "$user" -- bash -euo pipefail "$dir/.servio/deploy.sh"
    else
        echo "Using the default Laravel steps (add .servio/deploy.sh to the repo to change them)"
        runuser -u "$user" -- bash -euo pipefail "$script_file"
    fi

    step "Reloading PHP $SITE_PHP-FPM"
    # OPcache keeps compiled PHP in memory: without this, PHP could keep running old code.
    systemctl reload "php$SITE_PHP-fpm"

    step "Checking the result"
    scheme=http
    [ -f "$(certificate_path "$domain")" ] && scheme=https
    site_status "$domain" "$scheme"
    if [ "$SITE_STATUS" = "000" ]; then
        check_fail "$scheme://$domain answers" "no answer"
    elif [ "$SITE_STATUS" -ge 500 ]; then
        check_fail "$scheme://$domain answers" "status $SITE_STATUS (server error: check the Laravel log)"
    else
        check_pass "$scheme://$domain answers" "status $SITE_STATUS"
    fi
    check_summary || die "The new code is live but the site answers with an error (see above)."

    step "Done"
    # Last line on purpose: the commit that is now live.
    echo "SERVIO_COMMIT=$(runuser -u "$user" -- git -C "$dir" rev-parse HEAD)"
}

servio_run "$@"
