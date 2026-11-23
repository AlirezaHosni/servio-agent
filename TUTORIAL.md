# Tutorial: your first site with servio-agent

This takes you from nothing to a Laravel site on HTTPS, with Claude doing the server work.
About 20 minutes, most of it waiting for installs and DNS.

You need: Claude Code, a fresh **Ubuntu 22.04 or 24.04** server you can SSH into, a domain
whose DNS you can change, and a Laravel app in a git repository (GitHub in the examples).

## 1. Install the plugin

In Claude Code:

```text
/plugin marketplace add AlirezaHosni/servio-agent
/plugin install servio-agent@servio
/reload-plugins
```

Check it's there: `/plugin` lists `servio-agent` as enabled.

## 2. Set up SSH so Claude can reach the server

Claude never sees your keys. It runs `ssh <alias>`, and your own SSH config and agent do the rest.

**a. A key in your SSH agent.** If you don't have a key yet:

```bash
ssh-keygen -t ed25519 -C "you@laptop"
```

Load it into the agent (it asks for the passphrase once, then remembers it):
- macOS: `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`
- Linux: `ssh-add ~/.ssh/id_ed25519`
- Windows (PowerShell as admin, once): `Get-Service ssh-agent | Set-Service -StartupType Automatic; Start-Service ssh-agent`, then `ssh-add $HOME\.ssh\id_ed25519`

Your public key (`id_ed25519.pub`) must be in the server's `~/.ssh/authorized_keys` (your
hosting provider usually asks for it when you create the server).

**b. An alias in `~/.ssh/config`** (on Windows: `C:\Users\<you>\.ssh\config`):

```sshconfig
Host web1
    HostName 203.0.113.10      # the server's IP
    User root                  # or a user with passwordless sudo
    Port 22
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

`web1` is the name you'll use with Claude. Pick any name; one `Host` block per server.

**c. Connect once by hand**, to accept the server's host key (the scripts never answer prompts):

```bash
ssh web1 'sudo -n true && echo sudo works'
```

You should see `sudo works`. If it asks for a password, the user needs passwordless sudo (or
use `root`).

## 3. First run: look before you touch

Ask Claude:

> What's running on web1?

Claude runs the read-only inventory (`run.sh web1 inventory.sh`) and summarises: OS, nginx,
PHP, firewall, sites. On a fresh server nginx shows "not installed".

## 4. Provision the server

> Provision web1 with PHP 8.4.

Claude first shows a dry run (what it would install), then asks for your OK. Say yes. It installs
nginx, PHP 8.4, Composer, git and Supervisor, and turns on a firewall that allows only SSH
(rate-limited), HTTP and HTTPS. It takes a few minutes and runs as a job on the server, so it
keeps going even if your laptop sleeps. Safe to run again if it fails halfway.

Need another PHP version too? "Provision web1 with PHP 8.4 and 8.3": 8.4 is the default, and each
site can choose either.

## 5. Create the site

> Create shop.example.com on web1.

Claude asks what's missing (web directory: `public` for Laravel; PHP version), shows a dry run,
and waits for your OK. The site gets **its own Linux user**, named from the domain, and its own
PHP pool, so it can't read your other sites' files. Afterwards it shows lines like:

```
Site user: s_shopexamplecom_3f2a1b (PHP 8.4)
SERVIO_DEPLOY_KEY=ssh-ed25519 AAAA... servio-deploy@shop.example.com
```

That's the **public** half of the site's deploy key (the private half never leaves the server).
Add it to your repository: GitHub, repo, **Settings, Deploy keys, Add deploy key**, paste it,
leave "Allow write access" **off**.

Now point the domain at the server: in your DNS, an **A record** for `shop.example.com` with
the server's IP. Visiting `http://shop.example.com` shows a "This site is set up" page once DNS
has updated.

## 6. Deploy

> Deploy shop.example.com from main, repository git@github.com:acme/shop.git

Claude first shows a dry run: the commits that would go live, what the project needs
(PHP extensions, workers, a frontend build) and whether the server has it. After your OK it
builds a new **release folder** while the old one keeps serving (`composer install`, `npm run
build` if your project has one), switches to it in one step, checks the site answers (and
switches back if it doesn't). On the very first deploy you'll see:

> No .env yet (shared/.env): skipped migrations and caching.

That's on purpose: **Claude never writes or reads `.env` files.** Create it yourself, as the
site's user (inventory shows it, e.g. `s_shopexamplecom_3f2a1b`):

```bash
ssh web1
U=s_shopexamplecom_3f2a1b                                   # the site's user
sudo -u $U nano /home/$U/shop.example.com/shared/.env       # paste your settings, save
cd /home/$U/shop.example.com/current
sudo -u $U php artisan key:generate                         # if APP_KEY is empty
```

Then ask Claude to "fix permissions for shop.example.com" (it makes `.env` readable only by the
site), and to deploy again: now migrations and `artisan optimize` run too.

Later deploys are just "deploy shop.example.com": the repository and branch are remembered on
the server (in the live release). Want different deploy steps? Add `.servio/deploy.sh` to your
repository. Visitors never see a half-updated site, and a deploy that breaks the site is
switched back by itself. Migrations run before the switch and are not undone, so write them so
the previous release can still run.

### Queue workers and the scheduler

The deploy's project check tells you what the code needs: which queues have no worker, and
whether the scheduler runs. Then:

> Set up the workers and the scheduler for shop.example.com.

Claude shows the Supervisor program (and the cron line) it would write, then adds them after your
OK. They run as the site's user, restart by themselves after every deploy, and log to
`shared/storage/logs/`. "Run the migrations" or "clear the caches" work the same way, from a
fixed list of artisan commands.

### Something broke after a deploy?

> Roll back shop.example.com.

Claude shows the release it would go back to and the migrations that stay in the database (a
rollback never undoes them), then switches back in an instant after your OK. "Who deployed
shop.example.com?" lists past deploys, rollbacks and the releases on the server.

### Link the project, check CI

Inside your Laravel project folder:

> Link this project to shop.example.com on web1.

Claude writes `.servio.json` (host alias, domain, branch: no secrets). Commit it, and from then
on "deploy this" in that folder knows the target; Claude still says it and asks first. With the
GitHub CLI installed and logged in (`gh auth login`), the deploy's dry run also tells you
whether CI passed for the commit that would go live.

## 7. HTTPS

> Give shop.example.com HTTPS.

After your OK, Claude installs certbot, checks that `http://shop.example.com` really reaches
this server (if not, it tells you what the DNS says and stops, without wasting a Let's
Encrypt attempt), gets the certificate, and switches the site to HTTPS. Renewal is automatic.

### More names, www, and suspending

> Add shop.example.org to shop.example.com, and redirect www to it.

Point the new names' DNS at the server first. If the site has HTTPS, Claude then reissues the
certificate so it covers every name. "Suspend shop.example.com" shows visitors a "temporarily
unavailable" page (the app isn't touched); "resume" brings it back.

## 8. Check it

> What's running on web1?

You'll see the site with HTTPS, the certificate's expiry date, the deployed commit, the Laravel
version, and `.env: present`.

## 9. Keep an eye on it

All of these are read-only: Claude runs them without asking.

> Is web1 healthy?

Load, memory, disk **and inodes**, failed services, processes killed for lack of memory, the
firewall and open ports. Each line is PASS / WARN / FAIL / NOT ASSESSED.

> shop.example.com shows 502, why?

The same plus the site: its answer, its PHP pool, "all workers busy", recent 5xx errors and
nginx errors. It ends with **Likely cause** and a runbook from `runbooks/` to follow.

> Show me the Laravel errors of shop.example.com. / Who logged in to web1 today?

The end of a log (50 lines, at most 500), secrets masked on the server.

> Who's hammering shop.example.com right now?

The last hour of traffic: status codes, top addresses and paths, scanner probes (`/wp-login.php`,
`/.env`), the busiest minute.

> Is web1 secure?

SSH settings, firewall and fail2ban, databases open to the internet, PHP settings, certificates,
accounts, `.env` permissions, `APP_DEBUG`, `composer audit`, Docker ports. Fixing what it finds
is a separate change (planned for v0.6); for now it tells you what and why.

> Tell me about shop.example.com. / How many PHP workers fit on web1?

`site-details` (live commit, last deploys, deploy key, configs) and `php-sizing` (run it while
the sites have traffic: idle pools have no workers to measure).

When a problem is fixed, Claude offers to **save it as a runbook** in `runbooks/`: commit it and
open a pull request so the team has it next time.

## Deleting a site

> Delete shop.example.com from web1.

Claude lists what will be removed (nginx config, certificate, logs, deploy key and the whole
site folder, `.env` and uploads included) and asks you to **type the domain**. Only then does
it run. Remove the deploy key from GitHub afterwards. MySQL databases are not touched.

## When something goes wrong

| You see | It means | Fix |
|---|---|---|
| `Permission denied (publickey)` connecting to `web1` | your key isn't in the agent or on the server | `ssh-add -l` should list it; check `authorized_keys` |
| `Host key verification failed` | first connection, host key unknown | run `ssh web1` by hand once and accept |
| `sudo: a password is required` | user lacks passwordless sudo | use `root`, or add a `NOPASSWD` sudoers rule |
| `Permission denied (publickey)` during deploy, from git | the deploy key isn't on the repository | add the `SERVIO_DEPLOY_KEY` line as a deploy key |
| Laravel: `Permission denied` on `storage/logs` or `bootstrap/cache` | a file was created by another user (often root, via `sudo`) | ask Claude to "fix permissions for <domain>" |
| `Connection refused` right after several connections | the firewall rate-limits SSH (6+ connections in 30 seconds) | wait 30 seconds; for many quick connections, turn on `ControlMaster auto` + `ControlPersist 60s` for that host in `~/.ssh/config` (one connection is reused) |
| `http://… doesn't reach this server yet` | DNS not pointing here (yet) | fix the A record, wait, try again |
| `servio-agent: … touches a .env file` (denied) | the guard stopped a command touching a secret | expected; do that part yourself |
| `isn't supported yet` | not Ubuntu 22.04/24.04 | use a supported server |
| php-sizing: `no PHP workers running right now` | pools start workers only on requests | run it again while the sites have traffic |
| security-check: `composer audit … NOT ASSESSED` | the server can't reach packagist.org | check outgoing internet, or use `no-audit` |
| health: `NOT ASSESSED` lines | a tool or log isn't there (e.g. no ufw) | expected on unprovisioned servers; never read as PASS |

When a teammate leaves: remove their public key from `~/.ssh/authorized_keys` on every server.
