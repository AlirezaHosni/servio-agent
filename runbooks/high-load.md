# High load

## Problem
`health.sh` shows load above the number of CPUs: pages are slow, SSH is slow.

## Cause
More work than the CPUs can do: a traffic spike or a bot crawling, a heavy cron job or queue
job, a runaway process. Load also counts processes waiting for the disk, so a slow or full disk
raises it too.

## Fix
1. Look at the 5 busiest programs (`health.sh`) and the time: a cron at that minute?
2. Traffic: the traffic summary shows top IPs and paths (bots, `/wp-login.php` scanners).
   Blocking an IP has no script (firewall rules are a later item): a person does it with
   `ufw`. SSH password guessers are banned by fail2ban (`harden.sh fail2ban`).
3. If it passes by itself in a few minutes, note it and watch; don't restart things blindly.

## Commands
```bash
bash run.sh <host> health.sh
```
