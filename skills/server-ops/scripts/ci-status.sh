#!/usr/bin/env bash
# ci-status.sh: did GitHub's checks (CI) pass for a commit? Runs on YOUR LAPTOP (item 8).
# READ-ONLY: it only asks GitHub, through your own `gh` login.
#
#   bash ci-status.sh <repository> <commit>
#   bash ci-status.sh git@github.com:acme/shop.git 3f2a1b4c...
#   bash ci-status.sh acme/shop 3f2a1b4
#
# Use it after a deploy's dry run: it prints the commit that would go live. Two kinds of
# results are read: check runs (GitHub Actions and most CI apps) and commit statuses (older CI).
# Ends with SERVIO_CI=passed | failed | pending | none.
#
# Needs the GitHub CLI (`gh`), logged in (`gh auth status`). It never changes anything: only
# `gh api` GET requests. Names of checks come from the repository's workflows (anyone who can
# push writes them), so only plain characters are printed.
#
# Exit codes: 0 asked (whatever the result), 2 wrong input, 3 gh not logged in, 5 gh missing.
set -euo pipefail

repo="${1:-}" commit="${2:-}"
[ -n "$repo" ] && [ -n "$commit" ] || { echo "Usage: bash ci-status.sh <repository> <commit>" >&2; exit 2; }

# git@github.com:owner/repo(.git) | https://github.com/owner/repo(.git) | owner/repo
case "$repo" in
    git@github.com:*) repo="${repo#git@github.com:}" ;;
    https://github.com/*) repo="${repo#https://github.com/}" ;;
    *://*|*@*:*) echo "Only GitHub repositories can be checked (this is '$repo')." >&2; exit 2 ;;
esac
repo="${repo%.git}"
if ! [[ "$repo" =~ ^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$ ]] || [[ "$repo" == -* ]]; then
    echo "Invalid repository '$1'." >&2; exit 2
fi
[[ "$commit" =~ ^[0-9a-f]{7,40}$ ]] || { echo "Invalid commit '$commit' (a hex hash)." >&2; exit 2; }

command -v gh >/dev/null 2>&1 || { echo "The GitHub CLI (gh) isn't installed: https://cli.github.com" >&2; exit 5; }
gh auth status >/dev/null 2>&1 || { echo "gh isn't logged in: run 'gh auth login' yourself." >&2; exit 3; }

# "-" last in the set: in the middle, tr would read it as a range.
clean() { LC_ALL=C tr -cd 'A-Za-z0-9 ._:/()+\t\n-' | cut -c1-120; }

echo "Checks for $repo at ${commit:0:12}:"
runs="$(gh api "repos/$repo/commits/$commit/check-runs?per_page=100" \
    --jq '.check_runs[] | [.name, .status, (.conclusion // "-")] | @tsv' 2>/dev/null | clean || true)"
statuses="$(gh api "repos/$repo/commits/$commit/status" \
    --jq '.statuses[] | [.context, .state] | @tsv' 2>/dev/null | clean || true)"

summarise() {
    # Reads "name<TAB>status<TAB>conclusion" (check runs) or "name<TAB>state" (statuses).
    awk -F'\t' '
        NF == 3 { s = ($2 != "completed") ? "pending" : ($3 ~ /^(success|neutral|skipped)$/ ? "passed" : "failed") }
        NF == 2 { s = ($2 == "success") ? "passed" : ($2 == "pending" ? "pending" : "failed") }
        NF >= 2 { printf "  %-8s %s\n", s, $1; seen[s] = 1; n++ }
        END {
            if (!n) { print "  (no checks reported for this commit)"; r = "none" }
            else if (seen["failed"]) r = "failed"; else if (seen["pending"]) r = "pending"; else r = "passed"
            print "SERVIO_CI=" r
        }'
}
printf '%s\n%s\n' "$runs" "$statuses" | { grep -v '^$' || true; } | summarise
