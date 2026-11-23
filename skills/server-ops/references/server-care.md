# Server care workflows (server-ops skill)

Read this before updating packages, hardening a server, rebooting it or setting up alerts. The rules in SKILL.md
still apply: dry run first, say what changes, OK in chat before every change.

## Package updates
- `run.sh <host> updates.sh upgrade --dry-run`: refreshes apt's lists and shows every package
  that would update (and how many are security updates). Summarise; mention a kernel or
  database update specially.
- OK, then without `--dry-run` (it runs as a job; follow it like a deploy). It keeps changed
  config files, checks that every service that ran still runs, and says whether a reboot is
  needed. It never reboots.
- `updates.sh auto`: automatic SECURITY updates every day, automatic reboot OFF. Suggest it on
  every server that doesn't have it (security-check shows it).
- Composer packages are never updated on a server: tell the user to update locally, commit
  `composer.lock`, deploy.

## Harden a server
Order, one step at a time, each after its own dry run and OK:
1. **`harden.sh ssh`**: password and keyboard-interactive login off, MaxAuthTries 3, root login
   off (or key-only if the user connects as root). It refuses if the SSH user has no key.
   After it runs, an **undo is armed for 5 minutes**. Immediately (within those minutes) run
   **`harden.sh confirm`**: it goes over a NEW connection, which proves key login still works,
   and cancels the undo. Tell the user to approve `confirm` promptly. If `confirm` can't
   connect (exit 6), do nothing else: wait 5 minutes, the server undoes the change itself,
   then explain.
2. **`harden.sh fail2ban`**: bans an address after 5 failed logins in 10 minutes, for an hour.
3. **`harden.sh php`**: `expose_php` and `display_errors` off for every PHP version (never
   `disable_functions`: Laravel needs exec / proc_open).
4. **`updates.sh auto`** (above).
Then `security-check.sh` to show the result. The SSH port is never changed by these scripts.

## Reboot a server
1. Say what goes down: every site on that server, for a minute or two. Suggest a quiet time.
2. Dry run: `run.sh <host> reboot.sh now <host> --dry-run` (shows what runs now).
3. Ask the user to **type the host alias** in chat; pass exactly what they typed:
   `run.sh <host> reboot.sh now <typed>`. run.sh refuses if it isn't the server it connects to.
4. Wait 1-3 minutes, then `run.sh <host> reboot.sh check` (exit 6 = not back yet: wait and
   try again, a few times). It compares services and workers with before the reboot; report
   anything that didn't come back, then `health.sh`.

## Alerts (opt-in, per server)
The server checks itself every 10 minutes (disks 90%+ full, memory under 10% available, failed
services, crashed workers, certificates expiring within 14 days, each site's answer) and posts to
a Slack, Discord or Telegram webhook when a problem appears, when it clears, and once a day while
it lasts. Backups are NOT checked (they live on the laptops: `backup.sh list`).
1. The webhook URL is a SECRET. **Never ask for it in chat, and if the user pastes one, tell them
   to make a new one** (the pasted one is in the conversation now). The user writes it to
   `~/.config/servio/alert-webhook.txt` themselves (one line, `chmod 600`). Slack: an incoming
   webhook; Discord: channel settings > Integrations > Webhooks; Telegram: a bot, as
   `https://api.telegram.org/bot<token>/sendMessage?chat_id=<numeric id>`.
2. `bash ${CLAUDE_PLUGIN_ROOT}/skills/server-ops/scripts/alert-webhook.sh <host> --dry-run`, then
   without `--dry-run` (OK first): it reads the file on the laptop and sends the URL on the SSH
   stream; only the kind (Slack, Discord, Telegram) is shown. Never `cat` that file.
3. `run.sh <host> alerts.sh on --dry-run`, OK, then `on`: installs the checker and its timer, and
   shows what the checker sees now (nothing is sent by that).
4. `run.sh <host> alerts.sh test`: a test message; ask the user whether it arrived.
- `alerts.sh status`: on or off, which kind of webhook, current problems.
- `alerts.sh off`: removes the timer, the checker and the saved URL.
- Say the limit: a server that is down can't send anything. Suggest an outside uptime check for
  that.
