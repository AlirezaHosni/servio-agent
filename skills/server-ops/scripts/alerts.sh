#!/usr/bin/env bash
# alerts.sh: the server tells YOU when something breaks (item 76). Opt-in, per server.
#
#   (alert-webhook.sh on your laptop runs)  run.sh <host> alerts.sh webhook   save the URL it sends
#   bash run.sh <host> alerts.sh on     [--dry-run]   install the checker and its 10-minute timer
#   bash run.sh <host> alerts.sh off    [--dry-run]   remove everything (timer, checker, webhook)
#   bash run.sh <host> alerts.sh test                 send a test message now
#   bash run.sh <host> alerts.sh status               on or off, and what the checker sees now
#
# The checker (/usr/local/lib/servio-agent/alert-check.sh, run by servio-alerts.timer every 10
# minutes) looks at: disks 90%+ full, memory under 10% available, failed services, crashed
# workers (FATAL / BACKOFF / EXITED), certificates expiring within 14 days (certbot renews at 30,
# so that means renewal is failing), and every site's answer (no answer or a 5xx; suspended
# sites are skipped). It sends a message when a problem APPEARS, when it CLEARS, and once a day
# while it lasts: not every 10 minutes.
# Backups are not checked here: they live on the laptops (backup.sh list shows their age).
#
# The webhook URL is a SECRET (anyone with it can post to your channel). It never passes through
# the chat: alert-webhook.sh reads it from a file on your laptop and sends it on the SSH stream.
# On the server it's /etc/servio-agent/alert-webhook.curl (root only, 600), read by curl with -K,
# so it's never on a command line (site users can see other processes' command lines).

ALERT_DIR="/etc/servio-agent"
WEBHOOK_FILE="$ALERT_DIR/alert-webhook.curl"
CHECKER="/usr/local/lib/servio-agent/alert-check.sh"
ALERT_STATE="/var/lib/servio-agent/alerts-state"
ALERT_UNIT="servio-alerts"
UNIT_DIR="/etc/systemd/system"
# Slack incoming webhook, Discord webhook, or a Telegram bot's sendMessage with a numeric chat_id.
WEBHOOK_PATTERN='^https://(hooks\.slack\.com/services/[A-Za-z0-9_/-]{10,200}|(discord|discordapp)\.com/api/webhooks/[0-9]{5,30}/[A-Za-z0-9_-]{20,100}|api\.telegram\.org/bot[0-9]{5,15}:[A-Za-z0-9_-]{20,60}/sendMessage\?chat_id=-?[0-9]{1,20})$'

main() {
    local action="${1:-}"
    [[ "$action" =~ ^(webhook|on|off|test|status)$ ]] \
        || die_input "Usage: alerts.sh on|off|test|status (the webhook URL is sent by alert-webhook.sh on your laptop)"
    require_root
    case "$action" in
        status) alerts_status; return 0 ;;
        test) alerts_test; return 0 ;;
    esac
    begin_change "server" "$@"
    lock_site "server"
    case "$action" in
        webhook) save_webhook ;;
        on) alerts_on ;;
        off) alerts_off ;;
    esac
}

# webhook_kind <url or webhook file content>: slack, discord, telegram (or unknown).
webhook_kind() {
    case "$1" in
        *hooks.slack.com/*) echo slack ;;
        *discord.com/api/webhooks/*|*discordapp.com/api/webhooks/*) echo discord ;;
        *api.telegram.org/bot*) echo telegram ;;
        *) echo unknown ;;
    esac
}

save_webhook() {
    step "The webhook URL (sent from your laptop; never shown)"
    if dry_run; then
        echo "[dry-run] would save the URL alert-webhook.sh sends to $WEBHOOK_FILE (mode 600, root only)"
        step "Done (dry run): nothing was changed"
        return 0
    fi
    local url=""
    IFS= read -r url || true
    url="${url%$'\r'}"
    [[ "$url" =~ $WEBHOOK_PATTERN ]] || die_input "That isn't a Slack, Discord or Telegram webhook URL (see alert-webhook.sh). Nothing was saved."
    install -d -m 700 "$ALERT_DIR"
    printf 'url = "%s"\n' "$url" | write_file "$WEBHOOK_FILE" 600 root:root
    check_pass "webhook" "a $(webhook_kind "$url") webhook is saved (root only)"
    url=""
    check_summary || true
    [ -x "$CHECKER" ] && echo "Alerts are on: run.sh <host> alerts.sh test" || echo "Next: run.sh <host> alerts.sh on"
}

alerts_on() {
    if [ ! -f "$WEBHOOK_FILE" ]; then
        dry_run || die_state "No webhook saved yet: run alert-webhook.sh <host> on your laptop first."
        echo "[dry-run] note: no webhook saved yet (alert-webhook.sh <host> first)."
    fi
    step "The checker: $CHECKER"
    dry_run || install -d -m 755 "$(dirname "$CHECKER")" "$(dirname "$ALERT_STATE")"
    alert_checker | write_file "$CHECKER" 755 root:root
    step "The timer: $ALERT_UNIT.timer (every 10 minutes)"
    alert_service | write_file "$UNIT_DIR/$ALERT_UNIT.service" 644 root:root
    alert_timer | write_file "$UNIT_DIR/$ALERT_UNIT.timer" 644 root:root
    if dry_run; then
        echo "[dry-run] would start the timer (first check in 2 minutes) and show what the checker sees now"
        step "Done (dry run): nothing was changed"
        return 0
    fi
    systemctl daemon-reload
    systemctl enable --now "$ALERT_UNIT.timer"
    step "Checking the result"
    systemctl is-active --quiet "$ALERT_UNIT.timer" && check_pass "alerts timer" "active, every 10 minutes" || check_fail "alerts timer" "not active"
    step "What the checker sees now (nothing is sent by this; the timer sends)"
    "$CHECKER" report | sed 's/^/  /' || true
    check_summary || die "The alerts timer isn't running (see above)."
    echo "Send a test message to see it arrive: run.sh <host> alerts.sh test"
}

alerts_off() {
    step "Turning alerts off"
    if [ -f "$UNIT_DIR/$ALERT_UNIT.timer" ]; then
        run systemctl disable --now "$ALERT_UNIT.timer"
    fi
    local f
    for f in "$UNIT_DIR/$ALERT_UNIT.timer" "$UNIT_DIR/$ALERT_UNIT.service" "$CHECKER" "$ALERT_STATE" "$WEBHOOK_FILE"; do
        [ -e "$f" ] && run rm -f "$f"
    done
    run systemctl daemon-reload
    dry_run && { step "Done (dry run): nothing was changed"; return 0; }
    check_pass "alerts" "off; the checker, the timer and the webhook URL are removed"
    check_summary || true
}

alerts_test() {
    [ -x "$CHECKER" ] && [ -f "$WEBHOOK_FILE" ] || die_state "Alerts aren't on here (alerts.sh on)."
    step "Sending a test message"
    if dry_run; then
        echo "[dry-run] would send a test message to the saved $(webhook_kind "$(cat "$WEBHOOK_FILE")") webhook"
        return 0
    fi
    if "$CHECKER" test; then check_pass "test message" "sent: look in your channel"
    else check_fail "test message" "not sent (see above): check the webhook, then alert-webhook.sh again"; fi
    check_summary || die "The test message wasn't sent."
}

alerts_status() {
    step "Alerts on this server"
    if systemctl is-active --quiet "$ALERT_UNIT.timer" 2>/dev/null; then
        check_pass "alerts" "on, every 10 minutes"
    else
        check_warn "alerts" "off (alerts.sh on)"
    fi
    if [ -f "$WEBHOOK_FILE" ]; then check_pass "webhook" "a $(webhook_kind "$(cat "$WEBHOOK_FILE")") webhook is saved"
    else check_warn "webhook" "none saved (alert-webhook.sh <host> on your laptop)"; fi
    if [ -x "$CHECKER" ]; then
        step "What the checker sees now"
        "$CHECKER" report | sed 's/^/  /' || true
    fi
    check_summary || true
}

alert_service() {
    cat <<UNIT
$MANAGED_HEADER (alerts.sh)
[Unit]
Description=servio-agent alerts: check the server, post to the webhook when something changes

[Service]
Type=oneshot
ExecStart=$CHECKER run
Nice=10
UNIT
}

alert_timer() {
    cat <<UNIT
$MANAGED_HEADER (alerts.sh)
[Unit]
Description=servio-agent alerts every 10 minutes

[Timer]
OnActiveSec=2min
OnBootSec=5min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
UNIT
}

# The checker, installed as-is on the server. Quoted heredoc: nothing below is expanded now.
alert_checker() {
    cat <<'CHECKER'
#!/usr/bin/env bash
# Managed by Servio (alerts.sh). Runs every 10 minutes from servio-alerts.timer.
#   alert-check.sh run      check; post when a problem appears, clears, or still exists after a day
#   alert-check.sh report   check and print; post nothing
#   alert-check.sh test     post a test message
set -uo pipefail
export LC_ALL=C
WEBHOOK="${ALERT_WEBHOOK:-/etc/servio-agent/alert-webhook.curl}"
STATE="${ALERT_STATE:-/var/lib/servio-agent/alerts-state}"
NGINX_ENABLED="${ALERT_NGINX_ENABLED:-/etc/nginx/sites-enabled}"
LIVE="${ALERT_LIVE:-/etc/letsencrypt/live}"
DISK_PCT=90 MEM_PCT=10 CERT_DAYS=14 REMIND_SECONDS=86400

# problems: one line per problem. The lines must stay the SAME while a problem lasts (no live
# numbers in them), because "new" and "cleared" are found by comparing with the last run.
problems() {
    df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null \
        | awk -v max="$DISK_PCT" 'NR > 1 { u = $5; sub("%", "", u); if (u + 0 >= max) print "disk " $6 ": " max "% or more full" }'
    awk -v min="$MEM_PCT" '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
        END { if (t > 0 && a * 100 / t < min) print "memory: under " min "% available" }' /proc/meminfo 2>/dev/null
    systemctl --failed --plain --no-legend 2>/dev/null | awk '$1 != "" { print "service failed: " $1 }'
    if command -v supervisorctl >/dev/null 2>&1; then
        supervisorctl status 2>/dev/null | awk '$2 ~ /^(FATAL|BACKOFF|EXITED|UNKNOWN)$/ { print "worker " $1 ": " $2 }'
    fi
    local d name
    for d in "$LIVE"/*/; do
        name="$(basename "$d")"
        [ -f "$d/cert.pem" ] || continue
        openssl x509 -checkend $((CERT_DAYS * 86400)) -noout -in "$d/cert.pem" >/dev/null 2>&1 \
            || echo "certificate $name: expires within $CERT_DAYS days (renewal failing?)"
    done
    site_problems
}

# Every Servio site (not suspended) must answer, asked on this server itself (--resolve).
site_problems() {
    local f domain scheme port code
    for f in "$NGINX_ENABLED"/*; do
        [ -f "$f" ] || continue
        head -n 1 "$f" | grep -q '^# Managed by Servio' || continue
        grep -qx '# servio-suspended: yes' "$f" && continue
        domain="$(basename "$f")"
        [[ "$domain" =~ ^[a-z0-9.-]{1,253}$ ]] || continue
        scheme=http port=80
        [ -f "$LIVE/$domain/fullchain.pem" ] && scheme=https port=443
        code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$domain:$port:127.0.0.1" "$scheme://$domain/" 2>/dev/null)"
        case "$code" in
            000|"") echo "site $domain: no answer" ;;
            5??) echo "site $domain: answers $code" ;;
        esac
    done
}

json_string() { perl -0777 -pe 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g; s/[\x00-\x1f]//g'; }

# payload <kind> <text>: the JSON each service wants (Discord: "content", the others: "text").
payload() {
    local key="text"
    [ "$1" != discord ] || key="content"
    printf '{"%s":"%s"}' "$key" "$(printf '%s' "$2" | head -c 1800 | json_string)"
}

webhook_kind() {
    case "$(cat "$WEBHOOK" 2>/dev/null)" in
        *hooks.slack.com/*) echo slack ;;
        *discord.com/api/webhooks/*|*discordapp.com/api/webhooks/*) echo discord ;;
        *api.telegram.org/bot*) echo telegram ;;
        *) echo unknown ;;
    esac
}

# send <text>: post it. The URL comes from the file (-K), never the command line.
send() {
    [ -f "$WEBHOOK" ] || { echo "no webhook saved" >&2; return 1; }
    local code
    code="$(payload "$(webhook_kind)" "$1" | curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
        -H 'Content-Type: application/json' --data-binary @- -K "$WEBHOOK" 2>/dev/null)" || true
    case "$code" in
        2??) return 0 ;;
        *) echo "the webhook answered ${code:-nothing} (not sent)" >&2; return 1 ;;
    esac
}

host_name() { hostname -f 2>/dev/null || hostname; }

# message <previous problems> <current problems> <seconds since the last post>: what to post
# (empty: nothing). New ones and cleared ones; a reminder once a day while problems last.
message() {
    local prev="$1" now="$2" since="$3" new gone out=""
    new="$(comm -13 <(printf '%s\n' "$prev" | sed '/^$/d' | sort -u) <(printf '%s\n' "$now" | sed '/^$/d' | sort -u))"
    gone="$(comm -23 <(printf '%s\n' "$prev" | sed '/^$/d' | sort -u) <(printf '%s\n' "$now" | sed '/^$/d' | sort -u))"
    [ -z "$new" ] || out="PROBLEM on $(host_name):"$'\n'"$(printf '%s\n' "$new" | sed 's/^/- /')"
    [ -z "$gone" ] || out="${out:+$out$'\n'}Fixed on $(host_name):"$'\n'"$(printf '%s\n' "$gone" | sed 's/^/- /')"
    if [ -z "$out" ] && [ -n "$now" ] && [ "$since" -ge "$REMIND_SECONDS" ]; then
        out="Still a problem on $(host_name):"$'\n'"$(printf '%s\n' "$now" | sed 's/^/- /')"
    fi
    printf '%s' "$out"
}

run_check() {
    local now_s current prev="" last=0 msg tmp
    now_s="$(date +%s)"
    current="$(problems | sort -u)"
    if [ -f "$STATE" ]; then
        last="$(sed -n 's/^#sent //p' "$STATE" | head -n 1)"
        prev="$(grep -v '^#' "$STATE" || true)"
    fi
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    msg="$(message "$prev" "$current" $((now_s - last)))"
    if [ -n "$msg" ]; then
        # Not sent: the state stays, so the next run tries again. Exit 0 anyway: a failed
        # servio-alerts.service would show up as a "failed service" problem of its own.
        send "$msg" || return 0
        last="$now_s"
    fi
    tmp="$(mktemp "$(dirname "$STATE")/.alerts.XXXXXX")"
    { echo "#sent $last"; [ -z "$current" ] || printf '%s\n' "$current"; } > "$tmp"
    mv -f "$tmp" "$STATE"
}

report() {
    local current
    current="$(problems | sort -u)"
    if [ -z "$current" ]; then echo "no problems"; else printf '%s\n' "$current"; fi
}

case "${1:-}" in
    run) run_check ;;
    report) report ;;
    test) send "Test from servio-agent on $(host_name): alerts reach this channel." ;;
    source) ;;   # tests load the functions only
    *) echo "Usage: alert-check.sh run|report|test" >&2; exit 2 ;;
esac
CHECKER
}

servio_run_input "$@"
