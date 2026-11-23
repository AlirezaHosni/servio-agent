# Data and laptop workflows (server-ops skill)

Read this before creating a database, taking or listing backups, restoring, linking a project,
checking CI or changing Cloudflare DNS. The rules in SKILL.md still apply (dry run first, OK before changes, typed
domain for destructive steps, never read or print secrets).

## Database for a site (MySQL)
1. MySQL must be on the server: inventory / security-check show it. If not:
   `provision-server.sh <php> mysql` (add `redis` for Horizon or Redis queues/cache), dry run
   first. The server's other PHP versions must be repeated (`8.4 8.3 mysql`), or only the first
   stays the default.
2. Dry run: `run.sh <host> database.sh <domain> create --dry-run`: what exists and what it
   would make. Then OK, then without `--dry-run`.
3. It makes a database and user named after the site's Linux user, a password **generated on
   the server**, and writes the `DB_*` lines into `shared/.env`. You never see the password and
   must never ask for it or try to read it: if the user needs it, they read `shared/.env`
   themselves on the server.
4. Then deploy (or `artisan.sh <domain> optimize`) so Laravel reads the new config, and
   `artisan.sh <domain> migrate` if the deploy skipped migrations.

## Backups to the laptop (database and uploads)
Runs on the laptop: `bash ${CLAUDE_PLUGIN_ROOT}/skills/server-ops/scripts/backup.sh <host> <domain> db|files`.
It runs `backup-db.sh` / `backup-files.sh` on the server through run.sh in stream mode (never
call those two yourself: run.sh refuses them). The server dumps (`mysqldump
--single-transaction`, no table locks) or archives `shared/storage/app`, compresses and
**encrypts with age** for the public keys in `~/ServioBackups/recipients.txt`, and the data
goes straight into `~/ServioBackups/<host>/<domain>/<domain>-db|files-<time>.….gz.age`.
- You see only the file name, size and SHA-256: report those. Never `cat`, `head` or open a
  backup file, never decrypt one (restore is its own step).
- No `recipients.txt` (exit 3): explain the one-time setup to the user (`age-keygen`, keep the
  private key safe and off servers) and let them run it; never generate or read their key.
- It keeps the newest backup per day for 7 days, per week for 4 weeks, per month for 3 months.
  `bash backup.sh list [host [domain]]` lists what's there.
- Before anything risky (a big migration, a restore, deleting a site) offer a fresh `db` backup.
- It doesn't change the server (read-only there), so it needs no dry run; still say which
  site and server you're backing up.

## Restore a database (destructive in `live` mode)
Runs on the laptop: `bash ${CLAUDE_PLUGIN_ROOT}/skills/server-ops/scripts/restore.sh <host> <domain> <backup-file> new|live <typed-domain> [--dry-run]`.
It decrypts the backup on the laptop (the user's private key) and streams the dump to
`restore-db.sh` on the server (never call that one yourself: run.sh refuses it).
1. `bash backup.sh list <host> <domain>`: pick the backup with the user (by date).
2. Suggest **`new` first** when they aren't sure: it restores into a separate database
   (`<db>_restored_<time>`) and leaves the site alone; they can check it, then restore `live`.
3. Dry run with `--dry-run` (checks the file decrypts and isn't damaged; shows what happens).
4. For `live`: say plainly that the site's current data is replaced by the backup's (changes
   since that backup are lost; a fresh backup is taken first automatically). Ask the user to
   **type the domain** in chat, and pass exactly what they typed. Never type it for them.
5. Report the result checks. If the site errors afterwards, the code may expect newer tables:
   `artisan.sh <domain> migrate` (dry run first).
Never decrypt a backup any other way, never print its contents, never ask for the private key.

## Laptop helpers: linked projects and CI status
These run on the laptop (plain `bash`, not `run.sh`); both only read, except `create`.
- **Linked project** (`.servio.json` in a Laravel project: host alias, domain, optional branch;
  no secrets, meant to be committed). When the user works inside a project folder and doesn't
  name a server or site, run `bash ${CLAUDE_PLUGIN_ROOT}/skills/server-ops/scripts/project-link.sh show`
  and use its `SERVIO_LINK_*` values. Always say them back ("shop.example.com on web1") before
  any change: the file is in the repository, anyone who can push can change it. Never read
  `.servio.json` any other way. "Link this project to shop.example.com on web1":
  `project-link.sh create web1 shop.example.com [branch]`, then tell the user to commit it.
- **CI status** before a deploy: after the dry run (it prints the newest commit), if the
  repository is on GitHub run `bash ${CLAUDE_PLUGIN_ROOT}/skills/server-ops/scripts/ci-status.sh <repository> <commit>`.
  `SERVIO_CI=failed`: say which checks failed and ask whether to deploy anyway;
  `pending`: offer to wait; `none`: say the repo reports no checks. Exit 5/3 (no `gh` or not
  logged in): skip it and say so; never log in for the user. GitHub is read here only through
  `gh api` GET calls; never anything that changes GitHub.

## Cloudflare DNS (`dns.sh`, on the laptop)
For domains whose DNS is on Cloudflare. Records are PROXIED by default (the team's choice):
visitors reach Cloudflare, which forwards to the server.
1. The API token is a SECRET. **Never ask for it in chat; if the user pastes one, tell them to
   roll it** (Cloudflare: API Tokens > Roll). They create it themselves (template "Edit zone
   DNS", their zones only; permissions Zone > DNS > Edit, Zone > Zone > Read, optional
   Zone > Zone Settings > Read) and save it to `~/.config/servio/cloudflare-token.txt` (one
   line, `chmod 600`). Never `cat` that file.
2. `bash ${CLAUDE_PLUGIN_ROOT}/skills/server-ops/scripts/dns.sh <host> show <name>` (read-only):
   the name's records, which point to this server, and the zone's SSL mode.
3. `dns.sh <host> set <name> --dry-run`, then without `--dry-run` (OK first). One name per run:
   do the main domain, then each extra name and `www.<domain>` if the site has them (inventory
   shows them). A and, if the server has IPv6, AAAA, from the server's own addresses.
   - Refused (exit 4) when the name points ELSEWHERE: a live site may be there. Explain, and use
     `--move` only if the user says so in their own words.
   - `--dns-only` (grey cloud) if the user wants it, or for the first certificate when
     `issue-certificate.sh` says Cloudflare redirects Let's Encrypt to https.
4. Then `issue-certificate.sh`. Afterwards, if `set`/`show` warned about the SSL mode, tell the
   user to set **Full (strict)** in Cloudflare > SSL/TLS (Flexible + the site's https redirect =
   a redirect loop). The script never changes it: it's one setting for the whole zone.
- `dns.sh <host> remove <name> <typed-name>`: deletes only the A/AAAA records pointing to that
  server (after delete-site, or when a name is removed with domains.sh). The user types the name.
- The server logs real visitor addresses behind the proxy (nginx `servio-cloudflare-realip.conf`
  trusts `CF-Connecting-IP` from Cloudflare's ranges only).
