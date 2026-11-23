#!/usr/bin/env bash
# alert-webhook.sh: send the alerts webhook URL to a server (item 76). Runs on YOUR LAPTOP.
#
#   bash alert-webhook.sh <host> [--dry-run]
#
# The URL is a secret: anyone who has it can post to your channel. So it never goes through the
# chat. YOU put it in a file on this laptop, once, and this script sends it on the SSH stream:
#   ~/.config/servio/alert-webhook.txt   (or $SERVIO_ALERT_WEBHOOK), one line, mode 600
# One of:
#   https://hooks.slack.com/services/...                       Slack: an "incoming webhook"
#   https://discord.com/api/webhooks/<id>/<token>              Discord: channel > Integrations
#   https://api.telegram.org/bot<token>/sendMessage?chat_id=<numeric id>   Telegram: a bot
# The same file can serve every server. Then: run.sh <host> alerts.sh on.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE="${SERVIO_ALERT_WEBHOOK:-$HOME/.config/servio/alert-webhook.txt}"
HOST_RE='^[A-Za-z0-9_][A-Za-z0-9._-]{0,62}$'
# The same pattern the server checks (alerts.sh).
WEBHOOK_PATTERN='^https://(hooks\.slack\.com/services/[A-Za-z0-9_/-]{10,200}|(discord|discordapp)\.com/api/webhooks/[0-9]{5,30}/[A-Za-z0-9_-]{20,100}|api\.telegram\.org/bot[0-9]{5,15}:[A-Za-z0-9_-]{20,60}/sendMessage\?chat_id=-?[0-9]{1,20})$'

DRY=0 ARGS=()
for a in "$@"; do [ "$a" = "--dry-run" ] && DRY=1 || ARGS+=("$a"); done
set -- "${ARGS[@]+"${ARGS[@]}"}"
host="${1:-}"
[[ "$host" =~ $HOST_RE ]] && [ "$#" -eq 1 ] || { echo "Usage: bash alert-webhook.sh <host> [--dry-run]" >&2; exit 2; }

[ -f "$FILE" ] || { echo "No webhook file at $FILE. Create it yourself (one line: the webhook URL), mode 600; don't paste the URL in the chat." >&2; exit 3; }
url="$(head -n 1 "$FILE" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
# Never print the URL, not even in an error.
[[ "$url" =~ $WEBHOOK_PATTERN ]] || { echo "The first line of $FILE isn't a Slack, Discord or Telegram webhook URL (see the top of alert-webhook.sh). Nothing was sent." >&2; exit 2; }
case "$url" in *hooks.slack.com*) kind=Slack ;; *api.telegram.org*) kind=Telegram ;; *) kind=Discord ;; esac
echo "Found a $kind webhook in $FILE (not shown)."

if [ "$DRY" -eq 1 ]; then
    exec bash "$SCRIPTS_DIR/run.sh" "$host" alerts.sh webhook --dry-run < /dev/null
fi
printf '%s\n' "$url" | SERVIO_STREAM_FROM_FILE=1 bash "$SCRIPTS_DIR/run.sh" "$host" alerts.sh webhook
