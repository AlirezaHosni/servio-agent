#!/usr/bin/env bash
# project-link.sh: link a Laravel project folder to its server and site (item 75). Runs on YOUR
# LAPTOP, in the project folder.
#
#   bash project-link.sh show   [folder]                      # read .servio.json (default: .)
#   bash project-link.sh create <host-alias> <domain> [branch] [folder]
#
# .servio.json holds only names: no secrets, safe to commit, so the whole team gets it:
#   { "host": "web1", "domain": "shop.example.com", "branch": "main" }
# With it, "deploy" or "show the logs" inside the project folder knows the target. Claude still
# says the host and domain and asks before any change.
#
# The file is in a repository anyone with push access can change, so `show` checks every value
# against the same patterns run.sh and the server use, and prints only checked values:
#   SERVIO_LINK_HOST=web1  SERVIO_LINK_DOMAIN=shop.example.com  SERVIO_LINK_BRANCH=main
# Exit codes: 0 ok, 2 wrong input or an invalid file, 3 no .servio.json, 4 refused (exists).
set -euo pipefail

HOST_RE='^[A-Za-z0-9_][A-Za-z0-9._-]{0,62}$'
DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
BRANCH_RE='^[A-Za-z0-9._/-]{1,100}$'

valid_branch() {
    [[ "$1" =~ $BRANCH_RE ]] || return 1
    case "$1" in -*|/*|.*|*/|*.|*..*|*//*|*.lock) return 1 ;; esac
}

action="${1:-}"
case "$action" in
    show)
        dir="${2:-.}"
        file="$dir/.servio.json"
        [ -f "$file" ] || { echo "No .servio.json in $dir: this folder isn't linked (project-link.sh create ...)." >&2; exit 3; }
        # JSON::PP is part of perl (the guard hook uses it too). Unknown keys are ignored.
        values="$(perl -MJSON::PP -e '
            local $/; my $j = eval { JSON::PP::decode_json(<STDIN>) };
            ref $j eq "HASH" or do { print "INVALID\n"; exit 0 };
            for my $k (qw(host domain branch)) { my $v = $j->{$k}; print "$k\t", (defined $v && !ref $v ? $v : ""), "\n" }
        ' < "$file")"
        [ "$values" != "INVALID" ] || { echo ".servio.json isn't a JSON object." >&2; exit 2; }
        host="$(printf '%s\n' "$values" | awk -F'\t' '$1 == "host" { print $2 }')"
        domain="$(printf '%s\n' "$values" | awk -F'\t' '$1 == "domain" { print $2 }')"
        branch="$(printf '%s\n' "$values" | awk -F'\t' '$1 == "branch" { print $2 }')"
        [[ "$host" =~ $HOST_RE ]] || { echo ".servio.json: \"host\" must be a Host alias from ~/.ssh/config." >&2; exit 2; }
        [[ "$domain" =~ $DOMAIN_RE ]] || { echo ".servio.json: \"domain\" isn't a valid domain." >&2; exit 2; }
        if [ -n "$branch" ] && ! valid_branch "$branch"; then echo ".servio.json: \"branch\" isn't a valid branch name." >&2; exit 2; fi
        echo "SERVIO_LINK_HOST=$host"
        echo "SERVIO_LINK_DOMAIN=$domain"
        [ -z "$branch" ] || echo "SERVIO_LINK_BRANCH=$branch"
        ;;
    create)
        host="${2:-}" domain="${3:-}" branch="${4:-}" dir="${5:-.}"
        [[ "$host" =~ $HOST_RE ]] || { echo "Usage: project-link.sh create <host-alias> <domain> [branch] [folder]" >&2; exit 2; }
        [[ "$domain" =~ $DOMAIN_RE ]] || { echo "Invalid domain '$domain'." >&2; exit 2; }
        if [ -n "$branch" ] && ! valid_branch "$branch"; then echo "Invalid branch '$branch'." >&2; exit 2; fi
        [ -d "$dir" ] || { echo "No folder $dir." >&2; exit 2; }
        file="$dir/.servio.json"
        [ ! -e "$file" ] || { echo "$file exists already: edit it, or delete it first." >&2; exit 4; }
        if [ -n "$branch" ]; then
            printf '{\n    "host": "%s",\n    "domain": "%s",\n    "branch": "%s"\n}\n' "$host" "$domain" "$branch" > "$file"
        else
            printf '{\n    "host": "%s",\n    "domain": "%s"\n}\n' "$host" "$domain" > "$file"
        fi
        echo "Wrote $file (no secrets in it: commit it so the team shares the link)."
        ;;
    *)
        echo "Usage: project-link.sh show [folder] | create <host-alias> <domain> [branch] [folder]" >&2
        exit 2 ;;
esac
