# Out of memory

## Problem
`health.sh` shows "the kernel killed N process(es)" or memory below 15% available. Sites give 502,
MySQL restarts, queue workers vanish.

## Cause
More memory is wanted than the server has. Usual reasons: too many PHP workers
(`pm.max_children` × memory per worker > what's free), a memory-hungry job or import, MySQL's
buffer pool set too large, no swap at all.

## Fix
1. `health.sh` lists what was killed and the 5 biggest programs: that's the suspect.
2. PHP: PHP-FPM sizing (item 58) measures real worker memory and recommends `pm.max_children`.
3. A small server with no swap: a 1-2 GB swap file turns sudden kills into slowness (a change,
   v0.6 harden; a person can do it now).
4. A one-off job: run it with a memory limit, or at a quiet time.
5. Then `health.sh` again.

## Commands
```bash
bash run.sh <host> health.sh <domain>
```
