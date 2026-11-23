# Disk full (space or inodes)

## Problem
Uploads fail, MySQL stops, logs stop, deploys fail with "No space left on device".
`health.sh` shows `disk /` or `inodes /` at 95%+.

## Cause
- **Space:** big log files (nginx, `storage/logs/laravel.log` without daily rotation), old
  backups, apt cache, Docker images.
- **Inodes:** millions of small files: file-based sessions or cache in `storage/framework`,
  mail queues. The disk shows free GB but nothing can be created.

## Fix
1. Find what's big (a person, on the server; read-only):
   `sudo du -xh --max-depth=2 / 2>/dev/null | sort -h | tail -20`
   For inodes: `sudo du -x --inodes --max-depth=3 /home | sort -n | tail -20`
2. Usual safe cleanups: `sudo apt-get clean`, `sudo journalctl --vacuum-size=200M`, delete old
   rotated logs (`*.gz`). Laravel: set `LOG_CHANNEL=daily`; sessions/cache in Redis or the database.
3. Never delete files in a site you don't understand: ask first.
4. Then `health.sh` again.

## Commands
```bash
bash run.sh <host> health.sh
```
