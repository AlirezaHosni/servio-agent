# servio-agent

A Claude Code plugin that does Ploi-like server work over SSH, straight from the agent app:
list what runs on a server, provision a fresh Ubuntu server, create a Laravel site, deploy it
from git, give it HTTPS, and delete it. There's no panel in between: Claude runs a small set of
reviewed bash scripts on your servers through your own SSH setup.

The scripts are ported from [Servio](https://github.com/AlirezaHosni/Servio)'s recipes and use
the same server layout, so a server set up with this plugin can be adopted by Servio later.

> **Status: v0.1.0, not yet tested against a real server.** Syntax, input checks, the nginx
> config renderer and the secrets hook are tested locally (`tests/`). Try it on a throwaway
> server before you use it on a live one.

## What it can do

| Ask Claude… | Script | Changes the server? |
|---|---|---|
| "What's running on web1?" | `inventory.sh` | No (read-only) |
| "Provision web1 with PHP 8.4" | `provision-server.sh` | Yes: installs nginx, PHP-FPM, Composer, a firewall |
| "Create shop.example.com on web1" | `create-site.sh` | Yes: site folder, nginx config, deploy key |
| "Deploy shop.example.com from main" | `deploy-site.sh` | Yes: git fetch + checkout, composer, migrations |
| "Give shop.example.com HTTPS" | `issue-certificate.sh` | Yes: Let's Encrypt certificate, HTTPS nginx config |
| "Delete shop.example.com" | `delete-site.sh` | Yes, and it can't be undone |

Inventory shows per site: web root, PHP version, HTTPS and certificate expiry, the deployed
commit and branch, the Laravel version (from `composer.lock`) and whether a `.env` file exists.

**It can't** (yet): databases, queue workers, cron jobs, zero-downtime deploys, rollbacks,
metrics, non-Ubuntu servers or Ubuntu 26.04. It doesn't edit `.env` files, ever: you do that.

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
- **A hook backs up the most important rule.** `hooks/block-secrets.sh` runs before every Bash
  command in Claude Code and blocks commands that mention private keys (anywhere) or `.env`
  files on a server (in `ssh`/`scp`/`rsync` commands). Your *local* `.env` in your own projects
  isn't blocked.
- **No keys in this repo or in the chat.** Servers are reached through the host aliases in your
  `~/.ssh/config` and the keys in your SSH agent.

## Trade-offs (read before rolling it out)

This is the quick version ("approach A"). Servio as a central panel ("approach B") fixes most
of these later; the plugin will then talk to Servio instead of SSHing directly.

- **Root SSH access on every laptop.** Everyone who uses the plugin has an SSH key that can
  `sudo` on the servers. When someone leaves the team, remove their key from every server
  (`~/.ssh/authorized_keys`) and rotate any shared key.
- **No shared inventory or locks.** Each teammate's Claude sees the servers fresh each time.
  Two people can deploy the same site at the same moment, and nothing stops them.
- **No central audit log.** What ran is in each person's Claude session history and the servers'
  `auth.log`, not in one place.
- **The rules are advice; only a few are enforced.** The skill's rules (ask first, don't
  improvise) are instructions to the model. The scripts enforce input checks and the delete
  confirmation; the hook enforces the secrets rule for obvious commands. A determined
  workaround (base64, a script file) gets past a text-matching hook. Keep Claude Code's
  permission prompts on for Bash.
- **Codex gets the skill but not the hook.** See below.

## Requirements

- Claude Code (with Git Bash on Windows, which Claude Code needs anyway)
- `ssh` with an SSH agent holding your key, and a `Host` alias per server in `~/.ssh/config`
- Servers: Ubuntu 22.04 or 24.04 LTS; your SSH user is root or has **passwordless sudo**
- You've connected to each server by hand once (so its host key is known): the scripts never
  answer SSH prompts

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
skills/server-ops/scripts/        run.sh (local runner), lib.sh (shared), one script per action
hooks/hooks.json                  PreToolUse hook on Bash
hooks/block-secrets.sh            blocks .env and private-key reads
tests/                            local tests (no server needed)
```

`run.sh` runs on your laptop: it checks the host alias and arguments, then sends `lib.sh` and
the chosen script over SSH: `cat lib.sh <script> | ssh <host> 'sudo -n bash -s' -- <args>`.

## Tests

```bash
bash tests/test-scripts.sh   # syntax, validators, nginx config, run.sh refusals
bash tests/test-hook.sh      # the hook blocks .env / key reads and allows normal commands
claude plugin validate .
```

## Server layout (shared with Servio)

- user `servio` owns every site and runs PHP-FPM; nginx (`www-data`) is in the `servio` group
- site: `/home/servio/<domain>`, web root `/home/servio/<domain>/<web-dir>`
- deploy key: `/home/servio/.ssh/deploy_<domain>` (+ `.pub`)
- nginx: `/etc/nginx/sites-available/<domain>`, first line `# Managed by Servio`
- certificates: `/etc/letsencrypt/live/<domain>/`, renewed by `certbot.timer`
- custom deploy steps: put `.servio/deploy.sh` in the repository (runs as `servio` in the site
  folder); otherwise `composer install`, `artisan migrate --force` and `artisan optimize`
