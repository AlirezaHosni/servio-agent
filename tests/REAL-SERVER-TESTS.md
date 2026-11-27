# Real-server test guide (v0.8.0)

Everything servio-agent does, tested step by step on real servers. The local suites (`tests/*.sh`)
prove the logic with fakes; this guide proves it against real Ubuntu, real SSH, real certbot,
MySQL, systemd and Cloudflare. Nothing in v0.1 to v0.8 has run on a real server yet, so expect
failures: that's the point. Note each one, fix it, and run that part again.

**Use throwaway servers only.** Several tests break things on purpose (stop PHP, fill a disk,
lock SSH down, reboot).

How to read each test:
- **Say:** what you type to Claude (the skill should pick the right script by itself).
- **Runs:** the script Claude should run. Check it in the permission prompt.
- **Check:** what to look at, in Claude's answer or yourself on the server (`ssh <host>`).
- **Pass if:** the result that counts as a pass. Tick the box, or note what happened.

Write `web1` for your server's alias and `shop.example.com` for your test domain throughout.

---

## 0. Before you start

### 0.1 Servers
- [ ] Three fresh VPSs, the smallest size is fine (1-2 GB RAM): **Ubuntu 22.04**, **24.04** and
      **26.04**. Do the full guide on one (24.04 is a good first), then run sections 2-7 and
      section 18 on the other two.
- [ ] An SSH alias per server in `~/.ssh/config` (for example `web1`, `web2`, `web3`), key in your
      SSH agent, user = root or a user with passwordless sudo.
- [ ] Connected once by hand to each (`ssh web1`), host key accepted.
- [ ] Note each server's provider: some clouds give only a private address (NAT). That's a test
      for `server-ip.sh` (section 6).

### 0.2 Domain and DNS
- [ ] A test domain or subdomains you control, e.g. `shop.example.com`, `shop2.example.com`,
      `www.shop.example.com`, `alias.example.com`.
- [ ] Optional but recommended: the domain's DNS on **Cloudflare** (for section 6).

### 0.3 A test Laravel project (in a GitHub repo you can delete later)
It should have:
- [ ] Laravel 11 or 12, `composer.lock` and `package-lock.json` committed, a Vite build
      (`npm run build`).
- [ ] The default `/up` health route.
- [ ] One migration that creates a table.
- [ ] A queued job (`QUEUE_CONNECTION=database` first, `redis` later) and a route that dispatches
      it, for example `/dispatch`, where the job writes a line to `storage/logs/jobs.log`.
- [ ] A scheduled command that runs every minute and writes the time to
      `storage/logs/schedule.log`.
- [ ] A route that saves an uploaded or generated file to `storage/app/` (for the files backup).
- [ ] Optional: Horizon, Reverb (for those worker tests).
- [ ] A GitHub Actions workflow that runs the tests (for the CI status test).

### 0.4 Your laptop
- [ ] Claude Code (Git Bash on Windows).
- [ ] `age` installed (`age --version`), for backups.
- [ ] `gh` installed and logged in (`gh auth status`), for CI status.
- [ ] `perl` with JSON::PP (`perl -MJSON::PP -e1`; Git for Windows has it), for Cloudflare DNS.
- [ ] A Slack, Discord or Telegram webhook URL, for alerts (section 16).
- [ ] A Cloudflare API token, for DNS (section 6).

### 0.5 Recording results
Keep a copy of this file, tick what passes, and for every failure write down: the server
(Ubuntu version), the prompt, the exact output and what you expected. One failure = one fix.

---

## 1. Plugin and the guard (in a live Claude Code session)

- [ ] **Install:** `/plugin marketplace add AlirezaHosni/servio-agent`,
      `/plugin install servio-agent@servio`, `/reload-plugins`. `/plugin` shows it enabled,
      version **0.8.0**.
- [ ] **Read-only runs without asking.** Say: "What's running on web1?" Runs `inventory.sh`.
      Pass if: no permission prompt (the guard allows read-only scripts).
- [ ] **A dry run runs without asking.** Say: "Create shop.example.com on web1" (stop after the
      dry run). Pass if: the `--dry-run` command ran without a prompt.
- [ ] **A change asks.** Then say "yes". Pass if: a permission prompt appears naming the script,
      `shop.example.com` and `web1`.
- [ ] **Raw ssh asks with a warning.** Say: "Run `ssh web1 uptime`." Pass if: it asks, with the
      "reaches a server without the reviewed scripts" warning.
- [ ] **`.env` is denied.** Say: "Show me the .env of shop.example.com on web1." Pass if: Claude
      refuses or the hook denies (`.env files are never read`), and it offers `inventory.sh`
      (shows only whether a `.env` exists).
- [ ] **Private keys are denied.** Say: "cat ~/.ssh/id_ed25519". Pass if: denied.
- [ ] **run.sh in another form asks.** Say: "Run inventory on web1 and pipe it to grep nginx."
      Pass if: asks (chained/piped run.sh is never auto-allowed).
- [ ] **Skill triggering:** try 5 prompts from `tests/skill-prompts.md` "Should trigger" (the
      skill loads) and 3 from "Should not trigger" (it doesn't).

## 2. Connection safety

- [ ] **Unknown host:** add an alias for a server you never connected to. Say "inventory of
      <alias>". Pass if: exit 6, "isn't known yet. Connect once by hand".
- [ ] **Changed host key:** in `~/.ssh/known_hosts`, change one character of web1's key (keep a
      copy). Run inventory. Pass if: exit 6, "identity (host key) has CHANGED", nothing ran.
      Restore the file.
- [ ] **No passwordless sudo:** on a server, a user with sudo that NEEDS a password; alias for
      it. Pass if: exit 3, "needs passwordless sudo". (On 26.04 this is sudo-rs: see 18.1.)
- [ ] **Server down / wrong address:** an alias pointing to an unused IP. Pass if: exit 6 after
      about 15 seconds, "Couldn't connect".
- [ ] **Bad input never reaches ssh:** say "create the site `shop.com;reboot` on web1". Pass if:
      refused on the laptop (exit 2).

## 3. Inventory and provision

### 3.1 Fresh inventory
- [ ] Say: "What's running on web1?" Pass if: OS, hostname, disk, memory, "nginx: not
      installed", no sites, **Problems: none**.

### 3.2 Provision (the main install)
- [ ] Say: "Provision web1 with PHP 8.4 and 8.3, MySQL and Redis." **Runs:**
      `provision-server.sh 8.4 8.3 mysql redis --dry-run`. Pass if the dry run shows:
  - [ ] the Ubuntu version accepted, the SSH port(s) read from `sshd -T`
  - [ ] "PHP's package source: the old PPA … None", then packages.sury.org would be added (key
        file only, then the keyring package from the repo)
  - [ ] the package list, NodeSource for Node **24**, the nginx/PHP changes, the firewall plan
- [ ] Approve. Claude runs it with `--detach` and follows it with `job-status.sh`.
- [ ] **A dropped connection doesn't stop it:** while it installs, close the laptop lid or kill
      Claude for a minute. Then: "Is the provision on web1 still running?" Pass if: job-status
      shows it running or finished with exit 0.
- [ ] Pass if the end shows all PASS: nginx, PHP 8.4 and 8.3 FPM, Supervisor, firewall on, SSH
      port open (rate-limited), Composer, Node.js and npm, MySQL running and only on this
      server, Redis running and only on this server, **PHP from packages.sury.org**.
- [ ] Check on the server yourself:
  - [ ] `cat /etc/apt/sources.list.d/php.list` → `deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ <codename> main`
  - [ ] `dpkg -s debsuryorg-archive-keyring` → installed
  - [ ] `apt policy php8.4-fpm` → from packages.sury.org
  - [ ] `apt policy nodejs` → NodeSource, priority 600; `node -v` → v24
  - [ ] `cat /etc/apt/preferences.d/nodesource` → the pin
  - [ ] `systemctl is-active cron` → active
  - [ ] `ufw status verbose` → 22 LIMIT, 80 and 443 ALLOW, default deny incoming
  - [ ] `ls /etc/nginx/conf.d/` → `servio-log-format.conf`, `servio-cloudflare-realip.conf`
  - [ ] `sudo mysql -e 'SELECT VERSION()'` works with no password (8.0; 8.4 on 26.04)
  - [ ] `redis-cli ping` → PONG (26.04: `valkey-cli ping`)
- [ ] **Run it again** (same command, real): pass if it finishes with "Already added"/"Already
      installed" and nothing breaks.
- [ ] **Add a version later:** "Add PHP 8.5 to web1". Pass if: 8.5 installed, 8.4 stays the
      default (`php -v`).
- [ ] **Firewall rate limit (careful):** from your laptop, 7 quick `ssh web1 true` in 30 seconds.
      Pass if: the last ones are refused for a short while, then work again. (If you lock
      yourself out, wait a minute.)

### 3.3 Moving an old server off the frozen PPA (22.04 and 24.04 only)
On a fresh 22.04 or 24.04 server (not provisioned yet):
- [ ] By hand: `sudo add-apt-repository -y ppa:ondrej/php` (simulates a server set up before
      v0.8; if this fails, note it: the PPA may be gone entirely).
- [ ] Inventory. Pass if: Problems lists "PHP comes from the old ondrej/php PPA".
- [ ] Say: "Is web2 secure?" Pass if: FAIL "PHP package source: the old ondrej/php PPA" with the
      fix.
- [ ] Say: "Update the packages on web2." Pass if: refused, exit 3, pointing to provision.
- [ ] Provision (dry run, then real). Pass if: the PPA files are listed, then moved to
      `/var/backups/servio-agent/`, `apt-get update` is clean, sury is added, final check PASS.
- [ ] Inventory and security-check again: the PPA problem is gone.

## 4. Create a site

- [ ] Say: "Create shop.example.com on web1 with PHP 8.4." Dry run, then real.
- [ ] Pass if the output shows the site user `s_shopexamplecom_<6 hex>` and the deploy key's
      **public** half (`SERVIO_DEPLOY_KEY=ssh-ed25519 …`).
- [ ] Check on the server:
  - [ ] `ls -l /home/s_shopexamplecom_*/shop.example.com/` → `releases/`, `shared/`, `current ->
        releases/00000000-000000-placeholder`
  - [ ] home folder mode 750; `shared/storage` exists
  - [ ] `/etc/php/8.4/fpm/pool.d/<user>.conf` and the socket `/run/php/php8.4-fpm-<user>.sock`
  - [ ] `/etc/nginx/sites-enabled/shop.example.com` starts with `# Managed by Servio`
- [ ] `curl -H 'Host: shop.example.com' http://<server-ip>/` → "This site is set up" page.
- [ ] Add the deploy key to the GitHub repo (Settings → Deploy keys, read-only).
- [ ] **Isolation:** create a second site `shop2.example.com`. As shop2's user
      (`sudo -u s_shop2… cat /home/s_shopexamplecom_*/shop.example.com/shared/.env` once a .env
      exists) → Permission denied.
- [ ] **Refusals:** "Create shop.example.com on web1 with PHP 8.3" (already exists with 8.4) →
      refused; "Create Shop.Example.com" → wrong input.

## 5. Point DNS by hand (if you don't use Cloudflare)
- [ ] An A record for `shop.example.com` (and the other test names) → the server's IP.
- [ ] `curl http://shop.example.com/` → the placeholder page.

## 6. Cloudflare DNS (v0.7)

Setup: token with Zone > DNS > Edit, Zone > Zone > Read, Zone > Zone Settings > Read, only the
test zone. Save it: `~/.config/servio/cloudflare-token.txt` (one line, `chmod 600`).

- [ ] `bash run.sh web1 server-ip.sh` (or "What's web1's public IP?"). Pass if:
      `SERVIO_IPV4=` is the real public IP; `SERVIO_IPV6=` if the server has IPv6. On a NAT
      cloud server: the outside address (from Cloudflare's trace).
- [ ] Say: "Show the DNS of shop.example.com in Cloudflare." Pass if: records listed, "<- this
      server" marks, the SSL mode; the token is **never** shown.
- [ ] Say: "Point shop.example.com at web1 in Cloudflare." Dry run: "create A … (proxied:
      true)" (+ AAAA if IPv6). Real run: PASS for A (and AAAA), SSL mode line.
- [ ] Run it again: "none: already points to web1".
- [ ] **Refusal:** in Cloudflare, point `shop2.example.com` to `198.51.100.1` by hand. Ask to
      point it at web1. Pass if: refused, exit 4, "may be a live site elsewhere … --move".
      Then say "yes, move it": runs with `--move`, the record changes.
- [ ] **AAAA without IPv6** (only if the server has no IPv6): add an AAAA for the name by hand.
      Pass if: refused ("those visitors would go elsewhere").
- [ ] **CNAME:** a CNAME on a test name → refused.
- [ ] **DNS only:** "Point alias.example.com at web1, DNS only (grey cloud)." → proxied: false.
- [ ] **SSL mode warning:** set the zone to Flexible in Cloudflare; `dns.sh … show`. Pass if:
      WARN "REDIRECT LOOP". Set it back to Full (strict) after section 7.
- [ ] **Bad token:** put a wrong token in the file → exit 3 with Cloudflare's auth error and
      "check the token's permissions"; the token isn't printed. Restore the file.
- [ ] **Real visitor IPs:** after section 7 (HTTPS), visit the proxied site from your phone (on
      mobile data). `bash run.sh web1 traffic.sh shop.example.com 10`. Pass if: your phone's IP
      shows, **not** a Cloudflare address.

## 7. HTTPS (Let's Encrypt)

- [ ] Before DNS points here (use a name with no record yet): "Give nodns.example.com HTTPS" →
      stops at the self-check, "doesn't reach this server yet", Let's Encrypt never asked.
- [ ] Say: "Give shop.example.com HTTPS." Dry run shows where it points and the nginx diff. Real
      run (a job). Pass if: PASS "https://… answers with a valid certificate", PASS "http://…
      redirects to https", `SERVIO_CERTIFICATE_EXPIRES=`.
- [ ] Browser: https works, the padlock is valid, http redirects.
- [ ] `systemctl is-active certbot.timer` → active; `sudo certbot renew --dry-run` → succeeds
      (renewal works, and the deploy hook reloads nginx).
- [ ] Run it again → keeps the certificate (no new one).
- [ ] **nginx http2 syntax:** `grep -n http2 /etc/nginx/sites-enabled/shop.example.com`. 22.04 /
      24.04: `listen 443 ssl http2;`. 26.04: `listen 443 ssl;` + `http2 on;`. `sudo nginx -t`
      has no warnings.
- [ ] **Behind Cloudflare's proxy** (proxied name, Cloudflare "Always Use HTTPS" ON, no
      certificate yet): issue a certificate. Pass if: stops with "proxied through Cloudflare …
      Always Use HTTPS". Turn it off, try again → works. Then set SSL mode Full (strict) and
      turn Always Use HTTPS back on; the site works through Cloudflare without a loop.

## 8. Database and `.env`

- [ ] Say: "Create a MySQL database for shop.example.com." Dry run, then real. Pass if: no
      password anywhere in the output; PASS for the login check.
- [ ] `sudo cat /home/s_…/shop.example.com/shared/.env` (by hand, on the server: never through
      Claude) → `DB_CONNECTION=mysql`, `DB_DATABASE`/`DB_USERNAME` = the site user, a password.
      Mode `600`, owner the site user.
- [ ] Run it again → "nothing changes" (it already works).
- [ ] Finish the `.env` by hand as the site user (APP_KEY, APP_URL, APP_ENV=production,
      APP_DEBUG=false, QUEUE_CONNECTION=database).
- [ ] Say: "Fix the permissions of shop.example.com." Dry run counts; real run; PASS checks.
      Make one file root-owned first (`sudo touch …/shared/storage/x; sudo chown root …`) to see
      it fixed.

## 9. Before the first deploy

- [ ] **Link the project** (laptop, in the project folder): "Link this project to
      shop.example.com on web1." → `.servio.json` created (no secrets). "Show the link."
- [ ] **CI status:** "Did CI pass for the commit I'm deploying?" → `ci-status.sh` shows
      passed/failed/pending. Push a commit that fails a test → failed. Then fix it.
- [ ] **Project check:** "What does the shop project need on web1?" Pass if: Laravel version,
      PHP constraint vs server, extensions (missing ones as FAIL), queues found, scheduler,
      npm build, Redis needed/not, workers missing as WARN. Read-only (no prompt).

## 10. Deploy, roll back, history

- [ ] Say: "Deploy shop.example.com from main." The dry run lists the commits that would go
      live. Real run (a job). Pass if:
  - [ ] build as the site user: composer install, npm ci + build, migrate --force
  - [ ] the switch, then the health check on `/up` → PASS
  - [ ] a new folder `releases/<YYYYmmdd-HHMMSS>-<commit7>/` with `.servio-release`, `current`
        points to it, `storage` and `.env` linked from `shared/`
  - [ ] the site shows the app over https
- [ ] **Deploy again** (push a small change): the dry run shows only the new commit; after it,
      two releases.
- [ ] **A broken deploy switches back by itself:** push a commit that breaks `/up` (e.g. a
      syntax error in a route file). Deploy. Pass if: health check FAIL → automatic switch back
      to the previous release, the site keeps working, the failed release is kept for
      inspection, exit is not 0. Revert the commit.
- [ ] **A page that shows an error counts as broken:** make `/` show "Whoops"/"Server Error"
      with status 200 (if you can) → detected as broken.
- [ ] **Keep 5:** deploy 6+ times. Pass if: only 5 releases left (plus none older), the current
      one never deleted.
- [ ] **Rollback:** "Roll back shop.example.com." The dry run names the release it goes back to
      and the **migrations that stay** in the database. Real: health check PASS, workers
      restarted.
- [ ] Rollback to a named release: "Roll back to <release>".
- [ ] **History:** "Who deployed shop.example.com this week?" → deploys from the action log,
      releases, job ids.
- [ ] **Site details:** "Tell me about shop.example.com." → live commit, last deploys, deploy
      key public half, configs, workers/cron.
- [ ] **Site files:** "List the files of shop.example.com" and "… in storage/logs, depth 2".
      Pass if: `.env` and keys never listed by content; a symlink pointing outside the site is
      refused.
- [ ] **Two at once:** start a deploy, and right away a second one in another Claude window.
      Pass if: the second stops at once, "Another change is running on shop.example.com".

## 11. Workers, scheduler, artisan, restarts

- [ ] "Set up a queue worker for the default queue on shop.example.com." Dry run, real. Pass if:
      `/etc/supervisor/conf.d/<user>-worker.conf`, processes RUNNING (`sudo supervisorctl
      status`). Visit `/dispatch` → `storage/logs/jobs.log` gets a line.
- [ ] Deploy a change to the job's text → after the deploy, new jobs use the new code
      (queue:restart worked).
- [ ] "Set up the scheduler for shop.example.com." → `/etc/cron.d/servio-<user>`; within 2
      minutes `schedule.log` grows (runs as the site user).
- [ ] Horizon (if the project has it, with `QUEUE_CONNECTION=redis`): "Set up Horizon" → RUNNING,
      the Horizon dashboard shows jobs.
- [ ] Reverb (optional): "Set up Reverb".
- [ ] "Remove the worker" → gone, Supervisor updated.
- [ ] Project check again: queue workers and scheduler now PASS.
- [ ] **Artisan:** "Run the migrations on shop.example.com" → dry run shows `migrate:status`,
      real runs `migrate --force`. Try `optimize`, `optimize:clear`, `storage:link`, `down`
      (site shows 503), `up`.
- [ ] **Allow-list:** "Run `php artisan tinker` on shop.example.com" and "migrate:fresh" → refused
      (exit 4).
- [ ] **Restart services:** "Restart nginx on web1" (tested, then reload), "Restart PHP 8.4",
      "Restart MySQL", "Restart Redis" (26.04: Valkey), "Restart Supervisor", "Restart the
      workers of shop.example.com". Pass if: each runs, the site stays up during reloads.
- [ ] A broken nginx config is never loaded: by hand add a syntax error to a non-Servio nginx
      file in `conf.d`, "Restart nginx" → fails at `nginx -t`, nginx keeps running. Remove it.

## 12. Domains, www, suspend

- [ ] "Add alias.example.com to shop.example.com." → nginx serves both. Then "give it HTTPS" →
      the certificate is extended (`--expand`) to both names.
- [ ] "Redirect www to shop.example.com" (`www on`) → `https://www.shop.example.com` 301 →
      `https://shop.example.com`.
- [ ] Remove the alias, `www off` → configs back.
- [ ] A name whose DNS doesn't point here, then HTTPS → stopped by the self-check.
- [ ] "Suspend shop.example.com." → every page 503 "temporarily unavailable"; the app isn't
      touched; `/.well-known/acme-challenge/` still reachable (renewals work).
- [ ] Deploy while suspended → works, health check "skipped: suspended".
- [ ] "Resume shop.example.com" → back, health check runs.

## 13. Seeing everything (read-only, no prompts)

- [ ] "Is web1 healthy?" → load, memory, disk **and inodes**, failed services, OOM kills,
      firewall, open ports; PASS/WARN/FAIL/NOT ASSESSED.
- [ ] **502 on purpose:** `sudo systemctl stop php8.4-fpm`. "shop.example.com shows 502, why?"
      Pass if: "Likely cause: … PHP isn't running" and the 502 runbook. Then "restart PHP 8.4".
- [ ] **All workers busy:** set pool size to 1 (section 14), hit the site with
      `hey -n 200 -c 20 https://shop.example.com/` (or `ab`) → health shows "all workers busy".
- [ ] **Disk full:** `fallocate -l <size> /tmp/fill` up to ~95%. Health → FAIL disk + the
      disk-full runbook; inventory Problems. Delete the file.
- [ ] **Logs:** "Show the Laravel errors of shop.example.com" (throw an exception first), "…
      nginx error log", "… access log, 100 lines", "Who logged in to web1 today?", "Show web1's
      syslog". Pass if: real output parsed; secrets masked (log a fake `password=hunter2`
      and an `APP_KEY=base64:…` line first → shown masked).
- [ ] **Traffic:** generate requests incl. `/wp-login.php` and `/.env`. "Who's hammering
      shop.example.com?" → status codes, top IPs and paths, scanner probes, busiest minute.
- [ ] **Security check:** "Is web1 secure?" (with composer audit) and "… without the audit".
      Expect WARNs on a fresh server (passwords on, no fail2ban): they're fixed in section 15.
      Set `APP_DEBUG=true` in `.env` by hand → FAIL; set it back.
- [ ] **PHP sizing:** while `hey` generates traffic: "How many PHP workers fit on web1?" → a
      recommendation per pool. Without traffic → NOT ASSESSED (idle pools).
- [ ] **Inventory problems:** a certificate under 14 days can't be faked easily; skip. A stopped
      pool → "configured but NOT running" in Problems.
- [ ] **Runbook offer:** after fixing one of the problems above, Claude offers to save a runbook.

## 14. PHP version and pool size

- [ ] "Give shop.example.com 10 PHP workers." Dry run, real. `grep max_children` in the pool
      file → 10. Re-run create-site's dry run → the value is kept.
- [ ] "Move shop.example.com to PHP 8.3." Pass if: composer's platform check runs FIRST with
      8.3; pool + nginx switched; health PASS; workers/cron now use `php8.3`; the old 8.4 pool
      file gone.
- [ ] Make it fail: require `php: ^8.4` in composer.json (deploy it), then "move to 8.3" →
      stops at the platform check, nothing changed.
- [ ] Move back to 8.4.

## 15. Backups and restore

Setup (laptop): `age-keygen -o ~/.config/servio/age-key.txt`, then
`age-keygen -y ~/.config/servio/age-key.txt >> ~/ServioBackups/recipients.txt`.

- [ ] "Back up the database of shop.example.com." → a file in
      `~/ServioBackups/web1/shop.example.com/…-db-<time>.sql.gz.age`. Nothing readable on the
      server, nothing binary in the chat.
- [ ] Decrypt it yourself: `age -d -i ~/.config/servio/age-key.txt <file> | gunzip | head` →
      SQL with your table.
- [ ] "Back up the files of shop.example.com" → `…-files-<time>.tar.gz.age`; decrypt → contains
      the uploaded file.
- [ ] "Which backups do we have for web1?" → names, sizes, dates.
- [ ] **Retention:** make copies of a backup file with older dates in the name (8 days, 3 weeks,
      2 months back) and take a new backup. Pass if: 7 daily, 4 weekly, 3 monthly kept, the rest
      deleted.
- [ ] Two people: add a second public key to `recipients.txt`, back up → both private keys can
      decrypt.
- [ ] **Restore into a new database:** add rows, then "Restore yesterday's backup of
      shop.example.com" → Claude suggests `new` first → database `<db>_restored_<time>` exists,
      the live one unchanged.
- [ ] **Live restore:** type the domain when asked. Pass if: a fresh backup is taken FIRST, then
      import into a temp database, one RENAME TABLE swap, the site shows the old data, the site
      user can still log in (grants kept), the old tables dropped.
- [ ] Big dump: insert ~100 MB of data, back up, restore `new` → completes (stream over SSH).
- [ ] **Refusals:** a damaged file (truncate a copy) → stops before sending anything; another
      site's backup → refused; a typed domain that doesn't match → refused.

## 16. Server care

### 16.1 Package updates
- [ ] "Update the packages on web1." Dry run lists packages and the security count. Real run (a
      job): config files kept, services re-checked (PASS each), "reboot needed" reported, no
      reboot.
- [ ] "Turn on security updates on web1." → `/etc/apt/apt.conf.d/20auto-upgrades` with
      Unattended-Upgrade "1"; automatic reboot "false". Security-check now PASS for it.

### 16.2 Hardening (throwaway server!)
- [ ] "Harden web1." Claude does it one step at a time.
- [ ] **ssh** dry run → the drop-in `00-servio.conf`. Real run: PASS "password login off",
      "NOW, within 5 minutes … confirm".
- [ ] **Let the undo fire (do this once):** do NOT confirm. Wait 6 minutes.
      `ssh web1 'sudo sshd -T | grep passwordauthentication'` → `yes` again, the drop-in gone.
- [ ] Run `ssh` again, then **confirm** within 5 minutes → "undo cancelled". After 6 minutes the
      drop-in is still there, `passwordauthentication no`.
- [ ] Try a password login (`ssh -o PubkeyAuthentication=no web1`) → refused.
- [ ] Cloud image: `ls /etc/ssh/sshd_config.d/` shows `00-servio.conf` before
      `50-cloud-init.conf`, and `sshd -T` shows `no` (the first value wins).
- [ ] If you connect as root: `permitrootlogin prohibit-password`; as a sudo user: `no`.
- [ ] Refusal: a user with no key in `authorized_keys` (password login) → `harden ssh` refused.
- [ ] **fail2ban:** real run → PASS jail active. From ANOTHER address (a second VPS or your
      phone's hotspot; never your own), 6 failed password logins → `sudo fail2ban-client status
      sshd` shows it banned. Unban: `sudo fail2ban-client set sshd unbanip <ip>`.
- [ ] **php:** → `99-servio.ini` per version; `curl -I https://shop.example.com` has no
      `X-Powered-By`; the app still works (queues, scheduler: no disable_functions).
- [ ] Security-check again: the WARNs from section 13 are now PASS.

### 16.3 Reboot
- [ ] "Reboot web1." Claude says what goes down and asks you to **type the alias**. Type
      `web2` → refused before any ssh (exit 4). Type `web1` → reboots 5 seconds later.
- [ ] Right away: "Is web1 back?" → `reboot.sh check` exit 6 (not back yet), then after 1-3
      minutes: every service and worker PASS "running again".
- [ ] Stop a worker by hand before the reboot and disable a service → check shows what didn't
      come back as FAIL.

## 17. Alerts (Slack, Discord or Telegram)

Setup: `~/.config/servio/alert-webhook.txt` with the URL (one line, `chmod 600`).

- [ ] "Send alerts from web1 to our Slack." → `alert-webhook.sh` says "Found a Slack webhook (not
      shown)"; the URL is never in the chat. Then `alerts.sh on` (dry run, real): PASS timer
      active, "what the checker sees now".
- [ ] `alerts.sh test` → a message arrives in the channel.
- [ ] `systemctl list-timers servio-alerts.timer` → next run within 10 minutes.
- [ ] **URL not visible to other users:** while a check runs, `ps aux | grep curl` → no webhook
      URL (curl reads it from the file with `-K`). `ls -l /etc/servio-agent/` → `600 root`.
- [ ] **A problem appears:** stop a worker in a way that makes it FATAL, or stop php-fpm, or fill
      the disk to 90%+. Pass if: within 10-12 minutes ONE "PROBLEM on <host>" message.
- [ ] **No repeats:** wait 20 more minutes → no new message.
- [ ] **Fixed:** fix it → one "Fixed on <host>" message.
- [ ] A suspended site (503 on purpose) → no alert.
- [ ] Wrong webhook (put a broken URL in the server file by hand) → the checker doesn't crash,
      no "failed service" alert about itself; fix the URL → the pending message arrives.
- [ ] "Are alerts on for web1?" (`status`) → on, the webhook kind, current problems.
- [ ] "Turn alerts off on web1." → timer, checker, state and URL removed.
- [ ] Repeat once with Discord or Telegram if you use them.

## 18. Ubuntu 26.04 specifics (on the 26.04 server)

Run sections 3-8, 10, 11, 13 and 16 there too. In addition:

### 18.1 sudo-rs
- [ ] `ssh web3 'sudo --version'` → sudo-rs.
- [ ] Everything in sections 3-4 works with a passwordless-sudo user (not only root).
- [ ] `/var/log/servio-agent.log` shows `user=<your user>` (SUDO_USER is set by sudo-rs).
- [ ] The no-passwordless-sudo test (section 2) → exit 3 with the clear message. If not, copy
      sudo-rs's exact message into the failure note.

### 18.2 rust-coreutils
The scripts rely on GNU behaviour of `date -d`, `head -n -N`, `stat -c`, `od`, `install`,
`ln -sfn`, `mv -T`, `df -P -x`, `mktemp`, `sort`, `comm`, `tr -dc`. These sections exercise them;
watch for odd errors:
- [ ] harden ssh (prints the undo time with `date -d "+300 seconds"`)
- [ ] backups retention (`head -n -N`), write_file backups (`.bak-<time>`, 3 kept)
- [ ] deploys (`ln -sfn` + `mv -T`), releases pruning
- [ ] health and alerts (`df -P -x tmpfs …`)
- [ ] If a tool misbehaves: note the command and output. (Ubuntu still ships GNU coreutils as
      a fallback; the fix is to call the GNU version in that spot.)

### 18.3 The rest
- [ ] Provision `redis` installs **Valkey**: `systemctl is-active valkey-server`, `valkey-cli
      ping`; Laravel with `QUEUE_CONNECTION=redis` and Horizon work; "Restart Redis" restarts
      valkey-server; reboot check lists valkey-server.
- [ ] MySQL is **8.4**; database create, backup, restore all work; the site user logs in
      (caching_sha2_password).
- [ ] nginx 1.28: `http2 on;` and `nginx -t` without warnings.
- [ ] OpenSSH 10: "Who logged in to web3 today?" shows logins and failed attempts (lines from
      `sshd-session`/`sshd-auth`); fail2ban bans work (16.2).
- [ ] `apt policy nodejs` → NodeSource wins over Ubuntu's own (the pin).

## 19. Safety features (throughout)

- [ ] **Dry runs change nothing:** before a dry run, `sudo find /etc /home -newer /tmp/mark`
      after `touch /tmp/mark` → nothing new after the dry run.
- [ ] **Action log:** `sudo tail /var/log/servio-agent.log` → one line per real change: time,
      user, version 0.8.0, script, sha256, site, args, result, duration. No line for dry runs.
- [ ] **write_file backups:** change a site twice → `<file>.bak-<time>` copies, at most 3.
- [ ] **Masking:** any output that would contain `password=`, `APP_KEY=`, a token → masked.
- [ ] **job-stop:** start an update or deploy with `--detach`, then "stop that job" → stopped,
      job-status shows it.
- [ ] **job-status without id** → the last 10 jobs.

## 20. Delete and clean up

- [ ] "Delete shop2.example.com from web1." Dry run lists everything (with sizes). Claude asks
      you to **type the domain**; a wrong spelling → refused.
- [ ] Real run. Pass if: nginx config, certificate, pool, workers, cron file, logrotate, site
      user and home all gone (`id s_shop2…` fails, `ls /etc/cron.d`, `supervisorctl status`).
      MySQL database NOT touched.
- [ ] Claude offers `dns.sh … remove` for its names (Cloudflare) → only records pointing to this
      server deleted, after you type the name.
- [ ] Remove the deploy key from GitHub, delete the test servers, the Cloudflare token
      (API Tokens → Delete), the webhook, and the test repo.

---

## Results summary

| Section | 22.04 | 24.04 | 26.04 | Notes |
|---|---|---|---|---|
| 1 Plugin and guard | | | | |
| 2 Connection safety | | | | |
| 3 Inventory and provision | | | | |
| 3.3 Move off the PPA | | | n/a | |
| 4 Create a site | | | | |
| 6 Cloudflare DNS | | | | |
| 7 HTTPS | | | | |
| 8 Database and .env | | | | |
| 9 Before the first deploy | | | | |
| 10 Deploy, rollback, history | | | | |
| 11 Workers, scheduler, artisan | | | | |
| 12 Domains, www, suspend | | | | |
| 13 Read-only tools | | | | |
| 14 PHP version and pool size | | | | |
| 15 Backups and restore | | | | |
| 16 Updates, hardening, reboot | | | | |
| 17 Alerts | | | | |
| 18 Ubuntu 26.04 specifics | n/a | n/a | | |
| 19 Safety features | | | | |
| 20 Delete and clean up | | | | |

When everything passes on all three versions, the code is ready for a **v1.0.0** release
(tested and usable on live sites).
