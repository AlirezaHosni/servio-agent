#!/usr/bin/env bash
# site-files.sh: list a site's folders and files: names, sizes, owners, modes, dates (item 9).
# READ-ONLY: changes nothing, and NEVER shows a file's content.
#
#   bash run.sh <host> site-files.sh <domain> [folder] [depth]
#   bash run.sh <host> site-files.sh shop.example.com                     # the top level
#   bash run.sh <host> site-files.sh shop.example.com storage/logs 2
#
#   folder  inside the site (like "storage/logs"); default: the site's folder itself
#   depth   how deep to go, 1 to 3 (default 1). At most 300 entries are listed.
#
# Left out of the listing: .env files (.env, .env.production, .env.example too: it often holds
# real values), private keys and certificates
# (*.key, *.pem, id_*, deploy_key), and the inside of .git, vendor and node_modules (their total
# size is shown instead). The folder can't leave the site: no "..", and a folder that is a
# symlink pointing outside the site is refused.
#
# File names are chosen by whoever deployed or uploaded them, and the output goes to an AI: a
# name with unusual characters is shown as "(unusual name)".

MAX_ENTRIES=300

main() {
    local domain="${1:-}" folder="${2:-.}" depth="${3:-1}"
    [ -n "$domain" ] || die_input "Usage: site-files.sh <domain> [folder] [depth]"
    validate_domain "$domain"
    [ "$folder" = "." ] || validate_web_dir "$folder"
    [[ "$depth" =~ ^[1-3]$ ]] || die_input "depth must be 1, 2 or 3."
    require_root

    local dir target real_dir real_target
    dir="$(site_dir "$domain")"
    [ -d "$dir" ] || die_state "$dir doesn't exist: $domain isn't set up on this server."
    target="$dir/$folder"; [ "$folder" = "." ] && target="$dir"
    [ -e "$target" ] || die_state "No folder $folder in $domain."
    # Where it REALLY is (symlinks resolved) must still be inside the site.
    real_dir="$(realpath -e "$dir")"
    real_target="$(realpath -e "$target")"
    case "$real_target/" in
        "$real_dir"/*) ;;
        *) die_refused "$folder leads outside the site (a symlink?): not listing it." ;;
    esac
    [ -d "$real_target" ] || die_input "$folder is a file, not a folder."

    step "Files of $domain$([ "$folder" = "." ] || echo " in $folder") (depth $depth)"
    echo "mode       owner                  size  modified          name"
    list_files "$real_target" "$depth"
}

# list_files <folder> <depth>. find -printf prints only metadata (never contents). -P: symlinks
# are listed, never followed.
list_files() {
    local top="$1" depth="$2"
    find -P "$top" -mindepth 1 -maxdepth "$depth" \
        \( -name .git -o -name vendor -o -name node_modules \) -prune -printf '%M\t%u\t%s\t%TY-%Tm-%Td %TH:%TM\t%P\t1\n' \
        -o \( -name '.env' -o -name '.env.*' -o -name '*.key' -o -name '*.pem' -o -name 'id_*' -o -name 'deploy_key*' -o -name '*.p12' -o -name '*.pfx' \) -printf 'HIDDEN\n' \
        -o -printf '%M\t%u\t%s\t%TY-%Tm-%Td %TH:%TM\t%P\t0\n' 2>/dev/null \
    | format_entries "$top"
}

# format_entries <folder>: reads find's lines; prints a table. Separate so tests can feed lines.
format_entries() {
    local top="$1" mode owner size time name pruned count=0 hidden=0 shown
    while IFS=$'\t' read -r mode owner size time name pruned; do
        if [ "$mode" = "HIDDEN" ]; then hidden=$((hidden + 1)); continue; fi
        count=$((count + 1))
        [ "$count" -le "$MAX_ENTRIES" ] || continue
        [[ "$name" =~ ^[A-Za-z0-9._@+=,-]+(/[A-Za-z0-9._@+=,-]+)*$ ]] || name="(unusual name)"
        [[ "$owner" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || owner="?"
        [[ "$time" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] || time="?"
        [[ "$mode" =~ ^[-dlcbps][-rwxsStT]{9}$ ]] || mode="?"
        if [ "$pruned" = "1" ] && [ "${mode:0:1}" = "d" ]; then
            # vendor, node_modules, .git: their total, not their thousands of files.
            size="$(du -sb "$top/$name" 2>/dev/null | cut -f1 || echo 0)"
            name="$name/ (contents not listed)"
        elif [ "${mode:0:1}" = "d" ]; then
            name="$name/"
        fi
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        printf '%s  %-18s %8s  %s  %s\n' "$mode" "$owner" "$(human_size "$size")" "$time" "$name"
    done
    shown=$count; [ "$shown" -le "$MAX_ENTRIES" ] || shown=$MAX_ENTRIES
    echo
    echo "$shown of $count entries shown$([ "$hidden" -gt 0 ] && echo "; $hidden secret file(s) (.env, keys) left out on purpose")."
}

human_size() {
    local b="$1"
    if [ "$b" -ge 1073741824 ]; then echo "$((b / 1073741824))G"
    elif [ "$b" -ge 1048576 ]; then echo "$((b / 1048576))M"
    elif [ "$b" -ge 1024 ]; then echo "$((b / 1024))K"
    else echo "${b}B"; fi
}

servio_run "$@"
