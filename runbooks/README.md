# Runbooks

Short notes on problems we've had and how we fixed them (item 46). Before troubleshooting, the
skill searches this folder first (`grep -ril <word> runbooks/`). `health.sh` names one of these
when its checks match a known problem.

Add one after a problem is fixed **and verified** ("save this as a runbook"). Keep the four
headings. Only what really happened; **no secrets, IP addresses or customer data**. New notes
reach the team through git, reviewed like code.

| File | When |
|---|---|
| [502-bad-gateway.md](502-bad-gateway.md) | the site shows 502 or 504 |
| [disk-full.md](disk-full.md) | a disk or its inodes are 95%+ used |
| [out-of-memory.md](out-of-memory.md) | the kernel killed processes, or memory is almost gone |
| [high-load.md](high-load.md) | load is above the number of CPUs |
