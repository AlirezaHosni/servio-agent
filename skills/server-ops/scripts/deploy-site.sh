#!/usr/bin/env bash
# deploy-site.sh: deploy a site from git.
#
#   bash run.sh <host> deploy-site.sh <domain> [branch] [repository]
#   bash run.sh web1 deploy-site.sh shop.example.com main git@github.com:acme/shop.git
#
# The repository is needed on the first deploy only; later deploys reuse the site's git remote.
# The branch defaults to the branch deployed last time, or "main".
#
#   1. as root: check the site folder and its deploy key exist; read the PHP version from nginx
#   2. as servio: fetch the branch with the site's deploy key, check it out
#   3. as servio: run the deploy steps in the site folder: the repo's own .servio/deploy.sh if
#      it has one, otherwise the default Laravel steps below
#   4. as root: reload PHP-FPM (clears OPcache, so PHP runs the NEW code)
#   5. print SERVIO_COMMIT=<hash>, the commit that is now live (the last line)
#
# Steps 2 and 3 run as servio, not root: the files must belong to the user PHP-FPM runs as, and
# the deploy steps run code from the repository, so they get the least power that works.
# In-place deploy: the site is briefly a mix of old and new files while it updates.
# Ported from Servio's DeploySite recipe.

main() {
    local domain="${1:-}" branch="${2:-}" repository="${3:-}"
    [ -n "$domain" ] || die "Usage: deploy-site.sh <domain> [branch] [repository]"
    validate_domain "$domain"

    local dir deploy_key settings php_version script_file
    dir="$(site_dir "$domain")"
    deploy_key="$(deploy_key_path "$domain")"

    step "Checking the site"
    require_root
    [ -d "$dir" ] || die "$dir doesn't exist. Run create-site.sh first."
    [ -f "$deploy_key" ] || die "The deploy key for $domain is missing. Run create-site.sh again to create it."
    settings="$(read_site_settings "$domain")"
    php_version="${settings#* }"

    if [ -z "$repository" ] && [ -d "$dir/.git" ]; then
        repository="$(runuser -u "$SITE_USER" -- git -C "$dir" remote get-url origin 2>/dev/null || true)"
    fi
    [ -n "$repository" ] || die "First deploy of $domain: pass the repository, e.g. git@github.com:owner/repo.git"
    validate_repository "$repository"

    if [ -z "$branch" ] && [ -d "$dir/.git" ]; then
        branch="$(runuser -u "$SITE_USER" -- git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    fi
    [ -n "$branch" ] && [ "$branch" != "HEAD" ] || branch="main"
    validate_branch "$branch"
    echo "OK: $repository ($branch), PHP $php_version"

    # The default steps are saved to a temporary file owned by servio, run from there, and
    # deleted when this script ends (trap ... EXIT runs even after a failure).
    script_file="$(mktemp /tmp/servio-deploy.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$script_file'" EXIT
    cat > "$script_file" <<'DEPLOY'
# Runs as the servio user, inside the site's folder, after the new code is checked out.
# Any command that fails stops the deploy.
composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader

if [ -f artisan ] && [ -f .env ]; then
    php artisan migrate --force
    php artisan optimize
elif [ -f artisan ]; then
    echo "No .env file yet: skipped migrations and caching. Add .env to the site folder, then deploy again."
fi
DEPLOY
    chown "$SITE_USER:$SITE_USER" "$script_file"

    step "Fetching $branch from $repository"
    # Everything git does runs AS servio (runuser -u), with the site's own deploy key.
    #   IdentitiesOnly: use only this key.  accept-new: trust the git host's key the first time
    #   and pin it in ~/.ssh/known_hosts (Trust On First Use).
    export GIT_SSH_COMMAND="ssh -i $deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    # The git part runs in a NEW bash (as servio): only exported variables reach it.
    export SITE_DIR="$dir" REPOSITORY="$repository" BRANCH="$branch"
    cd "$dir"
    runuser -u "$SITE_USER" -- bash -euo pipefail <<'GIT'
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
git log -1 --format='Now at %h (%an, %ar)'
GIT

    step "Running the deploy steps"
    if [ -f "$dir/.servio/deploy.sh" ]; then
        echo "Using the repository's .servio/deploy.sh"
        runuser -u "$SITE_USER" -- bash -euo pipefail "$dir/.servio/deploy.sh"
    else
        echo "Using the default Laravel steps (add .servio/deploy.sh to the repo to change them)"
        runuser -u "$SITE_USER" -- bash -euo pipefail "$script_file"
    fi

    step "Reloading PHP $php_version-FPM"
    # OPcache keeps compiled PHP in memory: without this, PHP could keep running old code.
    systemctl reload "php$php_version-fpm"

    step "Done"
    echo "SERVIO_COMMIT=$(runuser -u "$SITE_USER" -- git -C "$dir" rev-parse HEAD)"
}

main "$@" < /dev/null
