# Tutorial: your first site with servio-agent

This takes you from nothing to a Laravel site on HTTPS, with Claude doing the server work.
About 20 minutes, most of it waiting for installs and DNS.

You need: Claude Code, a fresh **Ubuntu 22.04, 24.04 or 26.04** server you can SSH into, a domain
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

Claude never sees your keys, the server's address or its user. It only runs `ssh <alias>`
(always with `BatchMode=yes`: ssh may never stop to ask a question), and your own SSH config does
the rest. Do everything in this section yourself, in your own terminal, not through Claude.

**a. A key ssh can use without asking.** Pick one:

- **You make the key.** On your laptop (never on the server: a private key should be created
  where it's used, so it's never copied over the network):

  ```bash
  ssh-keygen -t ed25519 -f ~/.ssh/servio-key -C "you@laptop"
  ```

  Put the public half (`servio-key.pub`) in the server's `~/.ssh/authorized_keys`: paste it into
  your provider's "SSH keys" field when you create the server, or, for a server you can reach
  with a password:

  ```bash
  cat ~/.ssh/servio-key.pub | ssh root@203.0.113.10 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
  ```

- **Your provider made the key** and you downloaded it (often a `.pem` file). Keep the name and
  the extension, move it into your `.ssh` folder (e.g. `~/.ssh/servio-test.pem`); the provider has
  already put its public half on the server. `ssh-keygen -l -f ~/.ssh/servio-test.pem` shows its
  type (RSA, ED25519...): all of them work.

**Passphrase or not.** A key with a passphrase works only if an SSH agent already holds it,
because the scripts never type it:
- macOS: `ssh-add --apple-use-keychain ~/.ssh/servio-key`
- Linux: `ssh-add ~/.ssh/servio-key` (in a session whose agent Claude Code also uses)
- **Windows: Claude Code runs Git Bash, and Git Bash's ssh does NOT use Windows' own ssh-agent
  service.** The simple way is a key **without a passphrase**, used only for these servers and
  locked to your user (below). Check with step d either way.

On Windows, lock the private key to your user, or ssh refuses it as "unprotected":

```powershell
icacls $HOME\.ssh\servio-key /inheritance:r /grant:r "${env:USERNAME}:R"
```

**b. An alias in `~/.ssh/config`.** On Windows that's `C:\Users\<you>\.ssh\config`; open it with
`notepad $HOME\.ssh\config`. The file has **no extension**: if Notepad saves `config.txt`, rename
it (`Rename-Item $HOME\.ssh\config.txt config`), or save with the type "All files" and the name
in quotes, `"config"`.

```sshconfig
Host web1
    HostName 203.0.113.10      # the server's IP
    User root                  # or a user with passwordless sudo (some providers use "ubuntu")
    Port 22
    IdentityFile ~/.ssh/servio-key    # or ~/.ssh/servio-test.pem
    IdentitiesOnly yes
```

`web1` is the name you'll use with Claude. Pick any name; one `Host` block per server.

**c. Connect once by hand**, to accept the server's host key (the scripts never answer prompts):

```bash
ssh web1 'sudo -n true && echo sudo works'
```

The first time, ssh says the authenticity of the host "can't be established" and shows a
`SHA256:...` fingerprint. That's normal for a new server. If you can, compare it first: your
provider's panel may show it, or run `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` in the
provider's **web console**. Then type `yes`. From now on ssh checks it on every connection, and
the scripts stop if it ever changes.

You should see `sudo works`. If it asks for a password, the user needs passwordless sudo (or
use `root`).

**d. Check it works the way the scripts connect** (no questions, through Git Bash on Windows):

```bash
bash -c "ssh -o BatchMode=yes web1 'echo OK'"
```

`OK` means Claude can reach the server. "Permission denied" means ssh can't use the key without
help (a passphrase and no agent, a wrong `IdentityFile`, or the public key isn't on the server).

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

Need a database or Redis? "Provision web1 with PHP 8.4, MySQL and Redis" adds MySQL and Redis,
both listening only on the server itself. MySQL's admin login works only as root on the server
(no admin password exists anywhere). On Ubuntu 26.04 you get MySQL 8.4 and **Valkey** instead
of Redis (Ubuntu no longer ships Redis): it speaks the same protocol on the same port, so
Laravel's `redis` settings, queues and Horizon work unchanged.

PHP comes from packages.sury.org. A server set up before v0.8 used the old ondrej/php PPA,
which is frozen (no more security updates): inventory and "Is web1 secure?" point it out, and
provisioning again with the server's PHP versions moves it over.

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

### DNS on Cloudflare?

Claude can make the records for you. Once, create an API token in Cloudflare (My Profile, API
Tokens, template **Edit zone DNS**, only your zones; add Zone > Zone > Read, and Zone > Zone
Settings > Read if you want the SSL mode checked) and save it on your laptop, never in the chat:

```bash
mkdir -p ~/.config/servio
nano ~/.config/servio/cloudflare-token.txt   # one line: the token
chmod 600 ~/.config/servio/cloudflare-token.txt
```

> Point shop.example.com at web1 in Cloudflare.

It asks web1 for its addresses and makes an A record (and AAAA if the server has IPv6),
**proxied** through Cloudflare. A name that already points somewhere else is refused unless you
say to move it. After the certificate, set Cloudflare's SSL/TLS mode to **Full (strict)**:
"Flexible" plus the site's redirect to https makes a redirect loop. The server logs your
visitors' real addresses, not Cloudflare's.

### A database for the site

> Create a MySQL database for shop.example.com.

A database and a user, both named after the site's Linux user, allowed on that database only.
The password is made **on the server** and written straight into the site's `shared/.env`
(`DB_*` lines): it's never shown, not to you and not to Claude. Safe to ask again.

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

### Backups

Once, on your laptop: install [age](https://github.com/FiloSottile/age), then

```bash
mkdir -p ~/.config/servio ~/ServioBackups
age-keygen -o ~/.config/servio/age-key.txt          # your PRIVATE key: back it up somewhere safe
age-keygen -y ~/.config/servio/age-key.txt >> ~/ServioBackups/recipients.txt
```

> Back up the database of shop.example.com.

The server encrypts the backup for your public key; it arrives in
`~/ServioBackups/web1/shop.example.com/`. Without the private key nobody can open it, not even
someone who breaks into the server or your backup folder. "Back up the files" does the same for
uploads. Old backups are cleaned up (7 daily, 4 weekly, 3 monthly).

> Restore yesterday's database backup of shop.example.com.

Claude lists your backups, suggests restoring into a **new** database first (the site isn't
touched), and for a **live** restore asks you to type the domain. A live restore takes a fresh
backup first, imports into a temporary database, and only then swaps it in.

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
is a separate change, with its own OK: see "Look after the server" below.

> Tell me about shop.example.com. / How many PHP workers fit on web1?

`site-details` (live commit, last deploys, deploy key, configs) and `php-sizing` (run it while
the sites have traffic: idle pools have no workers to measure).

When a problem is fixed, Claude offers to **save it as a runbook** in `runbooks/`: commit it and
open a pull request so the team has it next time.

### Alerts: the server tells you

Nobody is chatting at 3 a.m., so a server can check itself. Once, on your laptop, put your
webhook URL in a file (don't paste it into the chat: anyone with it can post to your channel):

```bash
mkdir -p ~/.config/servio
nano ~/.config/servio/alert-webhook.txt   # one line: the Slack, Discord or Telegram webhook URL
chmod 600 ~/.config/servio/alert-webhook.txt
```

> Send alerts from web1 to our Slack.

Claude sends the URL from that file to the server (`alert-webhook.sh`, it shows only "a Slack
webhook"), turns alerts on, and offers a test message. Every 10 minutes the server checks full
disks, low memory, failed services, crashed workers, certificates about to expire and whether
each site answers. You get a message when a problem **appears**, when it's **fixed**, and once a
day while it lasts. A server can't tell you it is itself down: for that, use an outside uptime
service too.

## 10. Look after the server

> Move shop.example.com to PHP 8.5.

The version must be installed on the server first (provision). Claude first checks that the
project's `composer.lock` accepts the new version and has its extensions; then the site switches
pools, nginx, workers and scheduler. If the site doesn't answer afterwards, it switches back.

> Give shop.example.com 10 PHP workers.

Sets the pool's `pm.max_children`. Ask "How many PHP workers fit on web1?" first, while the sites
have traffic: more workers than memory allows makes everything slower, not faster.

> Update the packages on web1. / Turn on security updates.

A dry run lists every update first. The upgrade keeps your changed config files, checks that
every service still runs, and tells you if a reboot is needed: it never reboots by itself.
Automatic **security** updates run daily, with automatic reboot off.

> Harden web2.

One step at a time: key-only SSH, fail2ban, safe PHP settings. After the SSH step the server
**undoes it by itself in 5 minutes** unless Claude confirms over a new connection, so a mistake
can't lock you out. Try it on a throwaway server first.

> Reboot web1 tonight.

Claude asks you to type `web1` back (every site goes down for a minute or two), then checks that
every service and worker that ran before is running again.

## Deleting a site

> Delete shop.example.com from web1.

Claude lists what will be removed (nginx config, certificate, logs, deploy key and the whole
site folder, `.env` and uploads included) and asks you to **type the domain**. Only then does
it run. Remove the deploy key from GitHub afterwards. MySQL databases are not touched.

## When something goes wrong

| You see | It means | Fix |
|---|---|---|
| `Permission denied (publickey)` connecting to `web1` | ssh can't use your key without asking, or it isn't on the server | run step 2d; a key with a passphrase needs an agent (on Windows, Git Bash's ssh doesn't use Windows' ssh-agent: use a key without a passphrase); check `IdentityFile` and `authorized_keys` |
| `UNPROTECTED PRIVATE KEY FILE` (Windows) | the key file can be read by other users | `icacls` command in step 2a |
| `Host key verification failed` | first connection, host key unknown | run `ssh web1` by hand once and accept |
| `sudo: a password is required` | user lacks passwordless sudo | use `root`, or add a `NOPASSWD` sudoers rule |
| `Permission denied (publickey)` during deploy, from git | the deploy key isn't on the repository | add the `SERVIO_DEPLOY_KEY` line as a deploy key |
| Laravel: `Permission denied` on `storage/logs` or `bootstrap/cache` | a file was created by another user (often root, via `sudo`) | ask Claude to "fix permissions for <domain>" |
| `Connection refused` right after several connections | the firewall rate-limits SSH (6+ connections in 30 seconds) | wait 30 seconds; for many quick connections, turn on `ControlMaster auto` + `ControlPersist 60s` for that host in `~/.ssh/config` (one connection is reused) |
| `http://… doesn't reach this server yet` | DNS not pointing here (yet) | fix the A record, wait, try again |
| `… is proxied through Cloudflare` (SSL) | Cloudflare's "Always Use HTTPS" redirects Let's Encrypt | turn it off until the certificate exists, or `dns.sh … --dns-only` first |
| Cloudflare: "too many redirects" | SSL mode Flexible | Cloudflare > SSL/TLS > Full (strict) |
| `servio-agent: … touches a .env file` (denied) | the guard stopped a command touching a secret | expected; do that part yourself |
| `isn't supported yet` | not Ubuntu 22.04, 24.04 or 26.04 | use a supported server |
| `still uses the old ondrej/php PPA` | server set up before v0.8 | provision again with its PHP versions (dry run first) |
| php-sizing: `no PHP workers running right now` | pools start workers only on requests | run it again while the sites have traffic |
| security-check: `composer audit … NOT ASSESSED` | the server can't reach packagist.org | check outgoing internet, or use `no-audit` |
| health: `NOT ASSESSED` lines | a tool or log isn't there (e.g. no ufw) | expected on unprovisioned servers; never read as PASS |

When a teammate leaves: remove their public key from `~/.ssh/authorized_keys` on every server.
