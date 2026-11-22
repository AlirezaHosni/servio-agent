#!/usr/bin/env bash
# Feeds the hook the same JSON Claude Code sends and checks it blocks (exit 2) or allows (exit 0).
#   bash tests/test-hook.sh
set -uo pipefail
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/block-secrets.sh"
fail=0

check() { # $1 expected exit code, $2 command
    local json got
    # Build the JSON like Claude Code does (quotes and backslashes escaped).
    json="$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    json="{\"session_id\":\"t\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$json\",\"description\":\"test\"}}"
    printf '%s' "$json" | bash "$HOOK" 2>/dev/null
    got=$?
    if [ "$got" = "$1" ]; then echo "ok    ($got) $2"; else echo "FAIL  (got $got, want $1) $2"; fail=1; fi
}

echo "Must block (2):"
check 2 'ssh web1 cat /home/servio/shop.example.com/.env'
check 2 "ssh web1 'sudo cat /home/servio/shop.example.com/.env.production'"
check 2 'scp web1:/home/servio/shop.example.com/.env ./'
check 2 'ssh web1 "grep DB_PASSWORD /home/servio/a.com/.env"'
check 2 'cat ~/.ssh/id_ed25519'
check 2 'ssh web1 sudo cat /home/servio/.ssh/deploy_shop.example.com'
check 2 'ssh web1 sudo cat /etc/letsencrypt/live/shop.example.com/privkey.pem'
check 2 'ssh web1 sudo cat /etc/ssh/ssh_host_ed25519_key'
check 2 'cat server.key'

echo "Must allow (0):"
check 0 'bash skills/server-ops/scripts/run.sh web1 inventory.sh'
check 0 'bash skills/server-ops/scripts/run.sh web1 deploy-site.sh shop.example.com main'
check 0 'cat ~/.ssh/id_ed25519.pub'
check 0 'ssh web1 sudo cat /home/servio/.ssh/deploy_shop.example.com.pub'
check 0 'ssh web1 cat /home/servio/shop.example.com/.env.example'
check 0 'cat .env'                     # a local .env in your own project: not this hook's job
check 0 'ls -la ~/.ssh'
check 0 'git status'

[ "$fail" = 0 ] && echo "All hook tests passed." || { echo "Some hook tests FAILED."; exit 1; }
