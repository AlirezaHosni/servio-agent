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

Claude shows the command and asks for your OK. Say yes. It installs nginx, PHP 8.4, Composer,
git, creates the `servio` user and turns on a firewall that allows only SSH, HTTP and HTTPS.
It takes a few minutes. Safe to run again if it fails halfway.

## 5. Create the site

> Create shop.example.com on web1.

Claude asks what's missing (web directory: `public` for Laravel; PHP version), shows the
command, and waits for your OK. Afterwards it shows a line like:

```
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

After your OK, Claude fetches the branch onto the server, runs `composer install`, and reloads
PHP. On the very first deploy you'll see:

> No .env file yet: skipped migrations and caching.

That's on purpose: **Claude never writes or reads `.env` files.** Create it yourself:

```bash
ssh web1
sudo -u servio nano /home/servio/shop.example.com/.env    # paste your settings, save
sudo -u servio php /home/servio/shop.example.com/artisan key:generate   # if APP_KEY is empty
```

Then ask Claude to deploy again: now migrations and `artisan optimize` run too.

Later deploys are just "deploy shop.example.com": the repository and branch are remembered on
the server. Want different deploy steps? Add `.servio/deploy.sh` to your repository.

## 7. HTTPS

> Give shop.example.com HTTPS.

After your OK, Claude installs certbot, checks that `http://shop.example.com` really reaches
this server (if not, it tells you what the DNS says and stops, without wasting a Let's
Encrypt attempt), gets the certificate, and switches the site to HTTPS. Renewal is automatic.

## 8. Check it

> What's running on web1?

You'll see the site with HTTPS, the certificate's expiry date, the deployed commit, the Laravel
version, and `.env: present`.

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
| `http://… doesn't reach this server yet` | DNS not pointing here (yet) | fix the A record, wait, try again |
| `Blocked by servio-agent: …` | the hook stopped a command touching a secret | expected; do that part yourself |
| `isn't supported yet` | not Ubuntu 22.04/24.04 | use a supported server |

When a teammate leaves: remove their public key from `~/.ssh/authorized_keys` on every server.
