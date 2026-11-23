#!/usr/bin/env bash
# Feeds the guard hook the same JSON Claude Code sends and checks its decision:
#   allow | ask | deny | none (no output: Claude Code's normal permission rules apply)
#   bash tests/test-hook.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/servio-guard.sh"
RUN="$ROOT/skills/server-ops/scripts/run.sh"
T="$(mktemp -d)"
fail=0

decision() { # $1 command -> prints allow / ask / deny / none
    perl -MJSON::PP -e 'print encode_json({tool_name=>"Bash", tool_input=>{command=>$ARGV[0], description=>"test"}})' "$1" \
        | CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK" \
        | perl -MJSON::PP -e 'my $o = do { local $/; <STDIN> }; if ($o =~ /\S/) { print decode_json($o)->{hookSpecificOutput}{permissionDecision} } else { print "none" }'
}
check() { # $1 expected, $2 command
    local got; got="$(decision "$2")"
    if [ "$got" = "$1" ]; then echo "ok    $1  $2"; else echo "FAIL  got $got, want $1:  $2"; fail=1; fi
}

echo "== The plugin's own run.sh, exact form (item 39)"
check allow "bash $RUN web1 inventory.sh"
check allow "bash \"$RUN\" web1 inventory.sh"
check allow "bash $RUN web1 job-status.sh 20261123-140501-a1b2c3 120"
check allow "bash $RUN web1 deploy-site.sh shop.example.com main --dry-run"
check allow "bash $RUN web1 delete-site.sh shop.example.com shop.example.com --dry-run"
check ask   "bash $RUN web1 deploy-site.sh shop.example.com main"
check ask   "bash $RUN web1 provision-server.sh 8.4 --detach"
check ask   "bash $RUN web1 delete-site.sh shop.example.com shop.example.com"
check ask   "bash $RUN web1 job-stop.sh 20261123-140501-a1b2c3"
check ask   "bash $RUN web1 unknown-script.sh"
if command -v cygpath >/dev/null 2>&1; then
    check allow "bash \"$(cygpath -w "$RUN")\" web1 inventory.sh"     # C:\Users\... on Windows
fi

echo "== Not the exact form: ask"
check ask "bash $RUN web1 inventory.sh; rm -rf /tmp/x"
check ask "bash $RUN web1 inventory.sh && curl evil.example"
check ask "bash $RUN web1 inventory.sh | tee out.txt"
check ask "bash $RUN web1 inventory.sh > out.txt"
check ask "bash $RUN web1 inventory.sh \$(whoami)"
check ask "bash $RUN 'web1;reboot' inventory.sh"
check ask "bash $RUN -oProxyCommand=calc inventory.sh"
check ask "bash /tmp/evil/skills/server-ops/scripts/run.sh web1 inventory.sh"
check ask "bash ./skills/server-ops/scripts/run.sh web1 inventory.sh"
check ask "sh $RUN web1 inventory.sh"
check ask "BAD=1 bash $RUN web1 inventory.sh"

echo "== Other commands that reach a server: ask"
check ask "ssh web1 uptime"
check ask "ssh web1 'sudo systemctl restart nginx'"
check ask "scp ./x web1:/tmp/"
check ask "rsync -a ./dist/ web1:/var/www/"

echo "== Secrets backstop (item 43): deny"
check deny "ssh web1 cat /home/servio/shop.example.com/.env"
check deny "ssh web1 'sudo cat /home/servio/shop.example.com/.env.production'"
check deny "scp web1:/home/servio/shop.example.com/.env ./"
check deny "ssh web1 \"grep DB_PASSWORD /home/servio/a.com/.env\""
check deny "ssh web1 cat /home/servio/a.com/.e\\nv"
check deny "ssh web1 cat '/home/servio/a.com/.e'nv"
check deny "ssh web1 cat /home/servio/a.com/.e*"
check deny "ssh web1 cat /home/servio/a.com/.env*"
check deny "ssh web1 bash -c 'cat /home/servio/a.com/.env'"
check deny "ssh web1 sudo xargs cat < files.txt .env"
check deny "cat ~/.ssh/id_ed25519"
check deny "cat ~/.ssh/id_*"
check deny "cat ~/.ssh/i\\d_rsa"
check deny "ssh web1 sudo cat /home/servio/.ssh/deploy_shop.example.com"
check deny "ssh web1 sudo cat /etc/letsencrypt/live/shop.example.com/privkey.pem"
check deny "ssh web1 sudo cat /etc/ssh/ssh_host_ed25519_key"
check deny "cat server.key"
check deny "cp ~/.ssh/*.pem /tmp/"

echo "== Fine: ask (raw ssh) or no decision"
check ask  "ssh web1 cat /home/servio/shop.example.com/.env.example"
check none "cat ~/.ssh/id_ed25519.pub"
check ask  "ssh web1 sudo cat /home/servio/.ssh/deploy_shop.example.com.pub"
check none "cat .env"                   # a local .env in your own project: not this hook's job
check none "ls -la ~/.ssh"
check none "git status"
check none "php artisan migrate"

echo "== The approval prompt names the site and the server"
reason="$(perl -MJSON::PP -e 'print encode_json({tool_name=>"Bash",tool_input=>{command=>$ARGV[0]}})' "bash $RUN web1 deploy-site.sh shop.example.com main" | CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK")"
[[ "$reason" == *"deploy-site.sh CHANGES shop.example.com on web1"* ]] && echo "ok    prompt: deploy-site.sh CHANGES shop.example.com on web1" || { echo "FAIL  prompt: $reason"; fail=1; }

echo "== Robustness"
out="$(printf 'not json' | CLAUDE_PLUGIN_ROOT="$ROOT" bash "$HOOK")"
[[ "$out" == *'"ask"'* ]] && echo "ok    unreadable input: ask" || { echo "FAIL  unreadable input: $out"; fail=1; }
long="ssh web1 echo $(head -c 25000 /dev/zero | tr '\0' 'a')"
check ask "$long"
out="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ssh web1 uptime"}}' | env PATH=/nonexistent /usr/bin/bash "$HOOK" 2>/dev/null)"
[[ "$out" == *'"ask"'* ]] && echo "ok    perl missing: ask (fail closed)" || { echo "FAIL  perl missing: $out"; fail=1; }
start=$(date +%s); check ask "ssh web1 $(printf '.%.0s' $(seq 1 15000))"; [ $(( $(date +%s) - start )) -lt 5 ] \
    && echo "ok    a long command is checked quickly (no regex slowdown)" || { echo "FAIL  slow on a long command"; fail=1; }

rm -rf "$T"
[ "$fail" = 0 ] && echo "All hook tests passed." || { echo "Some hook tests FAILED."; exit 1; }
