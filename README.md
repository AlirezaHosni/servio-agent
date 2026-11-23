# servio-agent

A Claude Code plugin that does Ploi-like server work over SSH, straight from the agent app:
list what runs on a server, check its health and security, read logs, find out why a site is
down, provision a fresh Ubuntu server, create a Laravel site, deploy it from git, give it HTTPS,
and delete it. There's no panel in between: Claude runs a small set of
reviewed bash scripts on your servers through your own SSH setup.

The scripts are ported from [Servio](https://github.com/AlirezaHosni/Servio)'s recipes and use
the same server layout, so a server set up with this plugin can be adopted by Servio later.

> **Status: v0.7.0, not yet tested against a real server.** The scripts' building blocks, the
> inventory (on a fake server folder), long jobs, run.sh (with a fake ssh), the guard and the
> skill are tested locally and in CI (`tests/`, `.github/workflows/ci.yml`). Try it on a
> throwaway server before you use it on a live one.

## What it can do

| Ask Claude… | Script | Changes the server? |
|---|---|---|
| "What's running on web1?" | `inventory.sh` | No (read-only) |
| "Is web1 healthy?" / "Why is shop.example.com down?" | `health.sh [domain]` | No |
| "Show the Laravel errors of shop.example.com" / "Who logged in to web1?" | `logs.sh` | No |
| "Who's hammering shop.example.com?" | `traffic.sh <domain> [minutes]` | No |
| "Tell me about shop.example.com" / "Show its deploy key" | `site-details.sh <domain>` | No |
| "What's in storage/logs?" | `site-files.sh <domain> [folder] [depth]` | No (names only, never contents) |
| "Is web1 secure?" | `security-check.sh [no-audit]` | No |
| "How many PHP workers fit on web1?" | `php-sizing.sh [domain]` | No |
| "Provision web1 with PHP 8.4" | `provision-server.sh <php> [more] [mysql] [redis]` | Yes: installs nginx, PHP-FPM, Composer, Node.js, a firewall; MySQL 8 and Redis when asked |
| "Create shop.example.com on web1" | `create-site.sh` | Yes: site folder, nginx config, deploy key |
| "What does the shop project need?" | `project-check.sh <domain> [branch] [repo]` | No |
| "Deploy shop.example.com from main" | `deploy-site.sh` | Yes: a new release folder (composer, npm build, migrations), an instant switch, a health check that switches back on failure, worker restart |
| "Roll back shop.example.com" | `rollback-site.sh <domain> [release]` | Yes: switches back to an older release (instant; migrations are not undone) |
| "Who deployed shop.example.com?" | `deploy-history.sh <domain> [count]` | No |
| "Run 2 workers for the emails queue" / "Turn on the scheduler" | `workers.sh <domain> queue\|horizon\|reverb\|scheduler\|remove` | Yes: Supervisor programs / a cron line, as the site's user |
| "Run the migrations" | `artisan.sh <domain> <command>` (allow-list) | Yes |
| "Restart PHP 8.4" | `restart-service.sh <service>` | Yes: nginx and PHP are reloaded (no dropped requests) |
| "Add shop.example.org" / "Redirect www" | `domains.sh <domain> add\|remove <name>` / `www on\|off` | Yes: nginx config (then issue-certificate.sh extends HTTPS) |
| "Suspend shop.example.com" | `suspend-site.sh <domain> suspend\|resume` | Yes: nginx shows a 503 page, the app isn't touched |
| "Did CI pass for what I'm deploying?" | `ci-status.sh <repo> <commit>` (on your laptop, needs `gh`) | No: reads GitHub's checks |
| "Link this project to shop.example.com on web1" | `project-link.sh create\|show` (on your laptop) | Writes `.servio.json` in the project (no secrets) |
| "Create a database for shop.example.com" | `database.sh <domain> create` | Yes: MySQL database + user, password made on the server and written to `shared/.env` (never shown) |
| "Back up shop.example.com" | `backup.sh <host> <domain> db\|files` (on your laptop) | No: dumps or archives on the server, encrypted with age, saved to `~/ServioBackups/` (7 daily, 4 weekly, 3 monthly) |
| "Restore yesterday's backup of shop.example.com" | `restore.sh <host> <domain> <file> new\|live <typed-domain>` (on your laptop) | `new`: a separate database; `live`: replaces the data (fresh backup first, atomic swap, typed domain) |
| "Move shop.example.com to PHP 8.5" | `change-php.sh <domain> <version>` | Yes: checks composer requirements first, switches pool, nginx, workers; switches back on failure |
| "Give it 10 PHP workers" | `pool-size.sh <domain> <max-children>` | Yes: the pool's `pm.max_children` |
| "Update web1" / "Turn on security updates" | `updates.sh upgrade\|auto` | Yes: apt upgrade (keeps configs, checks services); daily security updates, no auto reboot |
| "Harden web2" | `harden.sh ssh\|confirm\|fail2ban\|php` | Yes: key-only SSH with an automatic undo until confirmed, fail2ban, safe PHP settings |
| "Reboot web1" | `reboot.sh now <typed-host>` / `check` | Yes: every site goes down briefly; checks everything came back |
| "Send alerts from web1 to our Slack" | `alert-webhook.sh <host>` (on your laptop), then `alerts.sh on\|off\|test\|status` | Yes: a 10-minute timer on the server posts to Slack, Discord or Telegram when a problem appears or clears (URL read from a file, never the chat) |
| "Point shop.example.com at web1 in Cloudflare" | `dns.sh <host> set\|show\|remove <name>` (on your laptop) | Yes: A (and AAAA) records, proxied by default; the token is read from a file, never the chat |
| "Give shop.example.com HTTPS" | `issue-certificate.sh` | Yes: Let's Encrypt certificate, HTTPS nginx config |
| "Fix the permissions of shop.example.com" | `fix-permissions.sh <domain>` | Yes: files owned by the site user, `storage` and `bootstrap/cache` writable, `.env` 600 |
| "Delete shop.example.com" | `delete-site.sh` | Yes, and it can't be undone |

Inventory shows per site: web root, PHP version, HTTPS and certificate expiry, the deployed
commit and branch, the Laravel version (from `composer.lock`) and whether a `.env` file exists,
and ends with a **Problems** list (certificates expiring soon, a pool not running, sites never
deployed, failed services, a full disk). `health.sh` ends with **Likely cause** and names a
runbook from `runbooks/`.

**It can't** (yet): databases, queue workers, cron jobs, zero-downtime deploys, rollbacks,
restarting services, metrics over time, non-Ubuntu servers or Ubuntu 26.04. It doesn't edit `.env` files, ever: you do that.

## How it stays safe

- **Your OK first.** The skill tells Claude to run inventory (read-only) first, show you the
  exact command, and wait for your "yes" before anything that changes a server. Deleting a site
  needs you to type the domain; the script itself refuses if what you typed doesn't match.
- **Only reviewed scripts.** Claude is told to use the bundled scripts, not improvise bash.
  Each script validates its inputs (domain, folder, PHP version allow-list, branch, git URL),
  stops at the first error (`set -euo pipefail`), and is safe to run again.
- **nginx never goes down for everyone.** Every config change runs `nginx -t` and is undone if
  it fails. Configs without the `# Managed by Servio` line (hand-made) are never touched.
- **Let's Encrypt is asked only when it will work.** The SSL script first checks that the domain
  reaches the server, so a DNS mistake doesn't burn Let's Encrypt's 5-failures-per-hour limit.
- **Secrets stay on the server.** Deploy keys are made on the server and only the public half
  is printed. Certificates' private keys never leave it. Claude never reads `.env` files.
- **A guard hook decides by proof, not by guessing.** `hooks/servio-guard.pl` runs before every
  Bash command in Claude Code:
  - **allows without a prompt** only the plugin's **own** `run.sh` in its exact form with a
    read-only script (inventory, job status) or a `--dry-run`
  - **asks** before every change script (naming the site and the server), before `run.sh` used
    in any other form, and before raw `ssh`/`scp`/`rsync` to a server
  - **denies** commands that mention private keys (anywhere) or `.env` files on a server, also
    when hidden with backslashes, quotes or wildcards (`.e\nv`, `".e"nv`, `.e*`, `id_*`)
  Normal commands in your own projects get no decision (your local `.env` isn't blocked).
  There are no settings: built for a small team, where every change simply asks.
- **Every change can be previewed.** `--dry-run` runs all the checks and prints exactly what would
  change (file diffs included) without changing anything. The guard allows dry runs without a
  prompt, so you approve a change after seeing its dry run.
- **Long jobs survive a dropped connection.** Provision, deploy and SSL run as a systemd job on
  the server; `job-status.sh` reads their output later, `job-stop.sh` stops one.
- **Every server keeps a record.** Each change appends a line to `/var/log/servio-agent.log` on
  that server (who, which script and its SHA-256, which site, the result), and one change at a
  time runs per site (a lock).
- **No keys in this repo or in the chat.** Servers are reached through the host aliases in your
  `~/.ssh/config` and the keys in your SSH agent.

## Trade-offs (read before rolling it out)

This is the quick version ("approach A"). Servio as a central panel ("approach B") fixes most
of these later; the plugin will then talk to Servio instead of SSHing directly.

- **Root SSH access on every laptop.** Everyone who uses the plugin has an SSH key that can
  `sudo` on the servers. When someone leaves the team, remove their key from every server
  (`~/.ssh/authorized_keys`) and rotate any shared key.
- **No shared inventory.** Each teammate's Claude sees the servers fresh each time. The lock on
  each server stops two changes on the same site at once, but there's no shared list of servers.
- **No central audit log.** Each server has its own log of changes; there's no single place that
  shows everything across servers.
- **Only some rules are enforced.** The guard enforces what it can prove (only reviewed
  read-only scripts run without a prompt; secrets are denied), and the scripts enforce input
  checks and the delete confirmation. Other rules (read-only first, no improvising) are
  instructions to the model. Raw `ssh` is only *asked*, not blocked, and an encoded workaround (base64, a script file) can still hide a secret read from the
  text checks: read what you approve. Keep Claude Code's permission prompts on for Bash.
- **Codex gets the skill but not the hook.** See below.

## Requirements

- Claude Code (with Git Bash on Windows, which Claude Code needs anyway)
- `ssh` with an SSH agent holding your key, and a `Host` alias per server in `~/.ssh/config`
- Servers: Ubuntu 22.04 or 24.04 LTS; your SSH user is root or has **passwordless sudo**
- You've connected to each server by hand once (so its host key is known): the scripts never
  answer SSH prompts
- For backups: [age](https://github.com/FiloSottile/age) on your laptop and a key pair (`age-keygen`); its public key in `~/ServioBackups/recipients.txt`
- Optional: the GitHub CLI (`gh`, logged in with `gh auth login`) to see CI results before a
  deploy (`ci-status.sh`, read-only)

## Install

```text
/plugin marketplace add AlirezaHosni/servio-agent
/plugin install servio-agent@servio
```

Or from a local clone: `/plugin marketplace add C:/path/to/servio-agent`. Then restart Claude
Code or run `/reload-plugins`. Updates: `/plugin marketplace update servio`.

The step-by-step first run (SSH config, inventory, create site, deploy, SSL) is in
[TUTORIAL.md](TUTORIAL.md).

### Codex

Codex reads the same `SKILL.md` format. Copy (or symlink) `skills/server-ops` into
`~/.agents/skills/server-ops` (or a repo's `.agents/skills/`). Codex has no equivalent of the
plugin hook, so there the secrets rule is advice only.

## Layout

```
.claude-plugin/plugin.json        the plugin
.claude-plugin/marketplace.json   this repo is also its own marketplace
skills/server-ops/SKILL.md        when to use it, the rules, the workflows
skills/server-ops/references/     longer workflows the skill reads only when needed (data, backups, restore)
skills/server-ops/scripts/        run.sh (local runner), lib.sh (shared), one script per action,
                                  job-status.sh / job-stop.sh for long jobs
                                  ci-status.sh / project-link.sh run on your laptop, not the server
runbooks/                         short notes: Problem, Cause, Fix, Commands (health.sh names them)
hooks/hooks.json                  PreToolUse hook on Bash
hooks/servio-guard.pl             the guard: allow / ask / deny (servio-guard.sh starts it)
tests/                            local tests (no server needed)
```

`run.sh` runs on your laptop: it checks the host alias and arguments, then sends a few
`SERVIO_*` lines (script name, its SHA-256, the plugin version), `lib.sh` and the chosen script
over SSH: `… | ssh <host> 'sudo -n bash -s' -- <args>`. Long scripts are wrapped as a job.

Exit codes: 0 done, 1 failed, 2 wrong input, 3 server not ready, 4 refused, 5 missing tool,
6 could not connect (or the server's host key is unknown or has **changed**).

## Tests

```bash
bash tests/test-scripts.sh   # syntax, validators, nginx config, lib.sh building blocks, jobs, run.sh (fake ssh)
bash tests/test-hook.sh      # the guard's allow / ask / deny decisions
bash tests/test-skill.sh     # the skill keeps its sections, its rules and its exit-code table
claude plugin validate .
```

`tests/skill-prompts.md` lists prompts that should and shouldn't trigger the skill: try them in
a session with the plugin installed after changing the skill's description.

## Server layout (shared with Servio)

- **one Linux user per site** ("website isolation"), named from the domain:
  `shop.example.com` → `s_shopexamplecom_3f2a1b` (`s_` + up to 16 letters/digits + 6 hex of
  the domain's SHA-256). One site can't read another's files or `.env`. Inventory shows each
  site's user
- site: `/home/<user>/<domain>` with **release folders** (v0.5): each deploy is
  `releases/<time>-<commit>/` (git archive, no `.git`), `shared/.env` and `shared/storage/` are
  linked into every release, `current` → the live release (switched in one atomic rename).
  nginx's web root is `/home/<user>/<domain>/current/<web-dir>`. The last 5 releases are kept.
  Its own temp folder `/home/<user>/tmp`; homes are `750`, nginx (`www-data`) reads public
  files through each site's group
- PHP-FPM: one pool per site, `/etc/php/<version>/fpm/pool.d/<user>.conf`, running as the site's
  user, socket `/run/php/php<version>-fpm-<user>.sock`, `pm = ondemand` (no memory while idle).
  A server can have several PHP versions; each site uses one
- deploy key: `/home/<user>/.ssh/deploy_key` (+ `.pub`)
- nginx: `/etc/nginx/sites-available/<domain>`, first line `# Managed by Servio`
- certificates: `/etc/letsencrypt/live/<domain>/`, renewed by `certbot.timer`
- Supervisor is installed (it will run queue workers)
- custom deploy steps: put `.servio/deploy.sh` in the repository (runs as the site's user in the
  site folder); otherwise `composer install`, `artisan migrate --force` and `artisan optimize`
