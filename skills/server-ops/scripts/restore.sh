#!/usr/bin/env bash
# restore.sh: restore a site's database from a backup on your laptop (item 32). Runs on YOUR
# LAPTOP. `live` REPLACES the site's data.
#
#   bash restore.sh <host> <domain> <backup-file> new  <typed-domain> [--dry-run]
#   bash restore.sh <host> <domain> <backup-file> live <typed-domain> [--dry-run]
#
#   new   into a separate new database on the server; the site's data isn't touched
#   live  replace the site's data. A FRESH backup of the current data is taken first
#         (backup.sh); if that fails, nothing is restored
#
# The backup is decrypted HERE with your private key (~/.config/servio/age-key.txt, or
# $SERVIO_AGE_KEY) and the plain dump goes straight into the SSH stream: never to disk, never to
# the chat. Before anything is sent, the file is checked end to end (decrypts, and gzip's own
# checksum is right), so a damaged backup stops here.
# <typed-domain>: the domain as the user typed it in chat; the server refuses if it differs.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY="${SERVIO_AGE_KEY:-$HOME/.config/servio/age-key.txt}"
HOST_RE='^[A-Za-z0-9_][A-Za-z0-9._-]{0,62}$'
DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'

DRY=0 ARGS=()
for a in "$@"; do [ "$a" = "--dry-run" ] && DRY=1 || ARGS+=("$a"); done
set -- "${ARGS[@]+"${ARGS[@]}"}"
host="${1:-}" domain="${2:-}" file="${3:-}" mode="${4:-}" typed="${5:-}"
usage() { echo "Usage: bash restore.sh <host> <domain> <backup-file> new|live <typed-domain> [--dry-run]" >&2; exit 2; }
[[ "$host" =~ $HOST_RE ]] && [[ "$domain" =~ $DOMAIN_RE ]] && [[ "$mode" =~ ^(new|live)$ ]] || usage
[ -n "$file" ] && [ -n "$typed" ] || usage
[ "$typed" = "$domain" ] || { echo "The typed domain '$typed' doesn't match $domain. Nothing was restored." >&2; exit 4; }
[ -f "$file" ] || { echo "No backup file $file (bash backup.sh list $host $domain)." >&2; exit 2; }
base="$(basename "$file")"
[[ "$base" =~ ^(.+)-db-[0-9]{8}-[0-9]{6}\.sql\.gz\.age$ ]] || { echo "$base isn't a database backup (…-db-<time>.sql.gz.age)." >&2; exit 2; }
[ "${BASH_REMATCH[1]}" = "$domain" ] || { echo "$base is a backup of ${BASH_REMATCH[1]}, not $domain. Restoring another site's data is refused." >&2; exit 4; }
command -v age >/dev/null 2>&1 || { echo "age isn't installed on this laptop." >&2; exit 5; }
[ -f "$KEY" ] || { echo "No private key at $KEY (set SERVIO_AGE_KEY if it's elsewhere)." >&2; exit 3; }

echo "Checking the backup (decrypts with your key, gzip checksum)..."
age -d -i "$KEY" "$file" | gzip -t \
    || { echo "The backup can't be decrypted with this key, or it's damaged. Nothing was restored." >&2; exit 1; }
echo "OK: $base"

if [ "$DRY" -eq 1 ]; then
    [ "$mode" = new ] || echo "A fresh backup of the current data would be taken first (backup.sh)."
    exec bash "$SCRIPTS_DIR/run.sh" "$host" restore-db.sh "$domain" "$mode" "$typed" --dry-run < /dev/null
fi

if [ "$mode" = live ]; then
    echo "Taking a fresh backup of the current data first..."
    bash "$SCRIPTS_DIR/backup.sh" "$host" "$domain" db \
        || { echo "The fresh backup failed: NOT restoring (the current data would have no copy)." >&2; exit 1; }
fi

echo "Restoring $base into $domain on $host ($mode)..."
age -d -i "$KEY" "$file" | SERVIO_STREAM_FROM_FILE=1 bash "$SCRIPTS_DIR/run.sh" "$host" restore-db.sh "$domain" "$mode" "$typed"
