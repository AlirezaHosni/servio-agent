#!/usr/bin/env bash
# backup-files.sh: a site's uploaded files, archived, compressed and ENCRYPTED, written to stdout
# (item 64). Only backup.sh on the laptop runs it, like backup-db.sh.
#
#   (backup.sh runs)  run.sh <host> backup-files.sh <domain> <age-recipient> [more recipients]
#
# What: shared/storage/app (Laravel's uploads: public disk and private files). Not the code
# (it's in git), not logs, cache or sessions (they rebuild themselves), not .env (you keep that
# yourself; a backup file is no place for secrets).
# How: tar | gzip | age -r <recipient>: encrypted on the server for your laptop's public key.
# Symlinks are stored as links (never followed): a link to /etc can't pull system files in.

main() {
    local domain="${1:-}"; shift || true
    [ -n "$domain" ] && [ "$#" -ge 1 ] || die_input "Usage: backup-files.sh <domain> <age-recipient>..."
    validate_domain "$domain"
    local r recipients=()
    for r in "$@"; do
        [[ "$r" =~ ^age1[a-z0-9]{50,70}$ ]] || die_input "Not an age public key: '$r' (they start with age1)."
        recipients+=(-r "$r")
    done
    require_root
    require_cmd age "apt-get install age (provision-server.sh installs it)"
    local storage
    storage="$(site_shared "$domain")/storage"
    [ -d "$storage/app" ] && [ ! -L "$storage/app" ] || die_state "No $storage/app (not created with release folders?)."

    say "Archiving $storage/app ($(du -sh "$storage/app" 2>/dev/null | cut -f1), $(find "$storage/app" -type f | wc -l | tr -d ' ') files), compressed, encrypted..."
    # --one-file-system: never wander into another mounted disk.
    tar --create --gzip --one-file-system --directory "$storage" app | age "${recipients[@]}"
    say "Done: files of $domain."
}

servio_run_stream "$@"
