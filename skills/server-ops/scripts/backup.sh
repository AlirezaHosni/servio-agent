#!/usr/bin/env bash
# backup.sh: back up a site's database or uploaded files INTO A FILE ON YOUR LAPTOP (items 19,
# 64, decision 5). Runs on your laptop.
#
#   bash backup.sh <host> <domain> db       # MySQL database   -> …-db-<time>.sql.gz.age
#   bash backup.sh <host> <domain> files    # uploads (storage/app) -> …-files-<time>.tar.gz.age
#   bash backup.sh list [<host> [<domain>]] # what's there (names, sizes, dates)
#
# Where: ~/ServioBackups/<host>/<domain>/ (or $SERVIO_BACKUP_DIR).
# Encrypted ON THE SERVER with age, for the public keys in ~/ServioBackups/recipients.txt (one
# `age1…` per line: yours, and a teammate's if they should be able to open it too). Only a
# private key opens a backup; it never leaves its laptop. Set up once:
#     age-keygen -o ~/.config/servio/age-key.txt        # your private key: keep it safe
#     age-keygen -y ~/.config/servio/age-key.txt >> ~/ServioBackups/recipients.txt
#
# The data goes from the server straight into the file: Claude sees only the file's name, size and
# SHA-256 (item 84). A half-written file is never kept (written as .part, renamed when complete).
# Kept: the newest backup of each of the last 7 days, 4 weeks and 3 months (decision 5); older
# ones of the same site and kind are deleted.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${SERVIO_BACKUP_DIR:-$HOME/ServioBackups}"
RECIPIENTS_FILE="$BASE/recipients.txt"
HOST_RE='^[A-Za-z0-9_][A-Za-z0-9._-]{0,62}$'
DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
FILE_RE='^[a-z0-9.-]+-(db|files)-[0-9]{8}-[0-9]{6}\.(sql|tar)\.gz\.age$'
KEEP_DAYS=7 KEEP_WEEKS=4 KEEP_MONTHS=3

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
size_of() { wc -c < "$1" | tr -d ' '; }

# keep_list <names newest first>: the backups to keep (newest per day for 7 days, per ISO week for
# 4 weeks, per month for 3 months). Pure: names in, names out (tests feed it names).
keep_list() {
    perl -e '
        use strict; my ($kd, $kw, $km) = @ARGV[0..2]; my (%d, %w, %m, %keep);
        sub days { my ($y,$mo,$da) = @_; $y -= $mo <= 2; my $e = int($y/400); my $yoe = $y - $e*400;
            my $doy = int((153*($mo + ($mo > 2 ? -3 : 9)) + 2)/5) + $da - 1; return $e*146097 + $yoe*365 + int($yoe/4) - int($yoe/100) + $doy; }
        while (my $n = <STDIN>) { chomp $n; my ($y,$mo,$da) = $n =~ /-(\d{4})(\d\d)(\d\d)-\d{6}\./ or next;
            my $day = "$y$mo$da"; my $week = int((days($y,$mo,$da) + 3) / 7); my $month = "$y$mo";
            if (!exists $d{$day} && keys %d < $kd) { $d{$day} = 1; $keep{$n} = 1 }
            if (!exists $w{$week} && keys %w < $kw) { $w{$week} = 1; $keep{$n} = 1 }
            if (!exists $m{$month} && keys %m < $km) { $m{$month} = 1; $keep{$n} = 1 }
        }
        print "$_\n" for sort keys %keep;
    ' "$KEEP_DAYS" "$KEEP_WEEKS" "$KEEP_MONTHS"
}

prune() {
    local dir="$1" kind="$2" names keep f
    names="$(ls -1 "$dir" 2>/dev/null | grep -E "$FILE_RE" | grep -- "-$kind-" | sort -r || true)"
    [ -n "$names" ] || return 0
    keep="$(printf '%s\n' "$names" | keep_list)"
    for f in $names; do
        printf '%s\n' "$keep" | grep -qxF "$f" && continue
        rm -f -- "$dir/$f"
        echo "Removed old backup $f"
    done
}

list_backups() {
    local root="$BASE" f
    [ -z "${1:-}" ] || { [[ "$1" =~ $HOST_RE ]] || { echo "Invalid host." >&2; exit 2; }; root="$root/$1"; }
    [ -z "${2:-}" ] || { [[ "$2" =~ $DOMAIN_RE ]] || { echo "Invalid domain." >&2; exit 2; }; root="$root/$2"; }
    [ -d "$root" ] || { echo "No backups in $root yet."; return 0; }
    find "$root" -type f -name '*.age' | sort | while read -r f; do
        [[ "$(basename "$f")" =~ $FILE_RE ]] || continue
        printf '%10s  %s\n' "$(size_of "$f")" "${f#"$BASE"/}"
    done
}

[ "${1:-}" != "list" ] || { shift; list_backups "$@"; exit 0; }

host="${1:-}" domain="${2:-}" kind="${3:-}"
[[ "$host" =~ $HOST_RE ]] && [[ "$domain" =~ $DOMAIN_RE ]] && [[ "$kind" =~ ^(db|files)$ ]] \
    || { echo "Usage: bash backup.sh <host> <domain> db|files   |   bash backup.sh list [host [domain]]" >&2; exit 2; }

[ -f "$RECIPIENTS_FILE" ] || {
    echo "No $RECIPIENTS_FILE: backups are encrypted for the age public keys listed there. Set up once:" >&2
    echo "  age-keygen -o ~/.config/servio/age-key.txt && age-keygen -y ~/.config/servio/age-key.txt >> $RECIPIENTS_FILE" >&2
    exit 3
}
recipients=()
while read -r line; do
    line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d ' \r\t')"
    [ -n "$line" ] || continue
    [[ "$line" =~ ^age1[a-z0-9]{50,70}$ ]] || { echo "$RECIPIENTS_FILE has a line that isn't an age public key." >&2; exit 2; }
    recipients+=("$line")
done < "$RECIPIENTS_FILE"
[ "${#recipients[@]}" -ge 1 ] || { echo "$RECIPIENTS_FILE has no keys." >&2; exit 3; }

dir="$BASE/$host/$domain"
mkdir -p "$dir"
chmod 700 "$BASE" "$BASE/$host" "$dir" 2>/dev/null || true
ext="sql"; [ "$kind" = "db" ] || ext="tar"
name="$domain-$kind-$(date -u +%Y%m%d-%H%M%S).$ext.gz.age"
part="$dir/$name.part"
trap 'rm -f "$part"' EXIT

echo "Backing up the $([ "$kind" = db ] && echo database || echo uploaded files) of $domain on $host, encrypted for ${#recipients[@]} key(s)..."
set +e
SERVIO_STREAM_TO_FILE=1 bash "$SCRIPTS_DIR/run.sh" "$host" "backup-$kind.sh" "$domain" "${recipients[@]}" > "$part"
rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "The backup failed (exit $rc, see above). Nothing was kept." >&2; exit "$rc"; }

# Proof it's a complete age file, not an empty or truncated one: the age header, and a size.
size="$(size_of "$part")"
head -c 21 "$part" | grep -q '^age-encryption.org/v1' || { echo "What came back isn't an age-encrypted file. Nothing was kept." >&2; exit 1; }
[ "$size" -gt 200 ] || { echo "The backup is suspiciously small ($size bytes). Nothing was kept." >&2; exit 1; }
mv "$part" "$dir/$name"
chmod 600 "$dir/$name" 2>/dev/null || true
trap - EXIT

echo "Saved: ${dir/#$HOME/~}/$name"
echo "Size: $size bytes"
echo "SHA-256: $(sha256_of "$dir/$name")"
prune "$dir" "$kind"
echo "SERVIO_BACKUP=$dir/$name"
