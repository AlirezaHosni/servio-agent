# 502 / 504 Bad Gateway

## Problem
The site shows "502 Bad Gateway" (or 504 Gateway Timeout). nginx is up but got no answer from PHP.

## Cause
In order of how often we see it:
1. The PHP-FPM service for the site's version is stopped, or was killed for memory
   (`health.sh` shows "out of memory" too: follow [out-of-memory.md](out-of-memory.md) first).
2. The site's own pool isn't running (no socket): its config was rejected by `php-fpm -t`.
3. All PHP workers are busy ("server reached pm.max_children"): slow requests or too much traffic.
4. 504 only: a request ran longer than nginx waits (a slow query, an external API).

## Fix
1. `bash run.sh <host> health.sh <domain>`: read which of the above it reports.
2. Service stopped: restarting it is a change (v0.5, item 22). Until then a person runs
   `sudo systemctl restart php<version>-fpm` and then health again.
3. Pool not running: `bash run.sh <host> create-site.sh <domain> --dry-run` shows the pool it
   would write; running it for real rewrites the pool and tests it.
4. Workers busy: find the slow pages (traffic summary, logs) before raising `pm.max_children`
   (PHP-FPM sizing says how high memory allows).

## Commands
```bash
bash run.sh <host> health.sh <domain>
bash run.sh <host> inventory.sh          # pool: "configured but NOT running"?
```
