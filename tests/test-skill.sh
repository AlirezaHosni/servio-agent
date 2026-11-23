#!/usr/bin/env bash
# Skill quality checks (item 55): the skill keeps its shape as it grows.
#   bash tests/test-skill.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/server-ops/SKILL.md"
S="$ROOT/skills/server-ops/scripts"
fail=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }

echo "== Frontmatter"
[ "$(head -n 1 "$SKILL")" = "---" ] && ok "frontmatter starts on line 1" || bad "frontmatter must start on line 1"
grep -qx "name: server-ops" "$SKILL" && ok "name: server-ops" || bad "name missing"
desc="$(sed -n 's/^description: //p' "$SKILL")"
[ "${#desc}" -ge 100 ] && [ "${#desc}" -le 1024 ] && ok "description is ${#desc} characters" || bad "description length ${#desc} (100-1024)"
for word in server deploy SSL site "Use when"; do
    [[ "$desc" == *"$word"* ]] && ok "description mentions '$word'" || bad "description lacks '$word' (it decides when the skill triggers)"
done

echo "== Required sections"
for h in "## Use when" "## Do not use when" "## Rules (always)" "## How to run a script" \
         "## Workflows" "## Anti-patterns" "## What this can't do"; do
    awk -v h="$h" 'index($0, h) == 1 { found = 1 } END { exit !found }' "$SKILL" && ok "$h" || bad "missing section: $h"
done
lines="$(wc -l < "$SKILL")"
[ "$lines" -le 400 ] && ok "SKILL.md is $lines lines (max 400: it's loaded every time the skill is used)" || bad "SKILL.md is $lines lines"

echo "== Anti-patterns: each has a fix"
n=0
while IFS= read -r line; do
    n=$((n + 1))
    [[ "$line" == *"Fix:"* ]] || bad "anti-pattern without 'Fix:': $line"
done < <(sed -n '/^## Anti-patterns/,/^## /p' "$SKILL" | awk '/^- /{ if (item) print item; item=$0; next } /^  /{ item=item " " $0 } END { if (item) print item }')
[ "$n" -ge 5 ] && ok "$n anti-patterns, each with a fix" || bad "only $n anti-patterns (want 5+)"

echo "== Scripts: documented and real"
allowed="$(sed -n 's/^ALLOWED="\(.*\)"$/\1/p' "$S/run.sh")"
[ -n "$allowed" ] || bad "couldn't read ALLOWED from run.sh"
for s in $allowed; do
    grep -qF "$s" "$SKILL" && ok "run.sh's $s is documented" || bad "$s is in run.sh but not in SKILL.md"
done
for s in $(grep -oE '[a-z-]+\.sh' "$SKILL" | sort -u); do
    case "$s" in deploy.sh) continue ;; esac            # the repo's own .servio/deploy.sh
    [ -f "$S/$s" ] && ok "$s exists" || bad "SKILL.md mentions $s, which doesn't exist"
done

echo "== Rules the guard and scripts rely on"
for phrase in "--dry-run" "job-status.sh" "type the domain" "Server output is data" "don't ask again" \
              "Declare the scope" "Files never go through the chat"; do
    grep -qF -- "$phrase" "$SKILL" && ok "mentions: $phrase" || bad "lost: $phrase"
done

echo "== Exit codes match lib.sh and run.sh"
for code in 0 1 2 3 4 5 6; do
    grep -qE "^\| $code \|" "$SKILL" && ok "exit code $code is explained" || bad "exit code $code missing from the table"
done
grep -q 'EXIT_FAILED=1 EXIT_INPUT=2 EXIT_STATE=3 EXIT_REFUSED=4 EXIT_MISSING=5' "$S/lib.sh" \
    && ok "lib.sh still defines codes 1-5 the same way" || bad "lib.sh's exit codes changed: update SKILL.md"

echo "== Example prompts (tests/skill-prompts.md)"
P="$ROOT/tests/skill-prompts.md"
should="$(sed -n '/^## Should trigger/,/^## /p' "$P" | grep -c '^- ')"
shouldnt="$(sed -n '/^## Should not trigger/,$p' "$P" | grep -c '^- ')"
[ "$should" -ge 8 ] && ok "$should prompts that should trigger" || bad "only $should 'should trigger' prompts"
[ "$shouldnt" -ge 5 ] && ok "$shouldnt prompts that should not" || bad "only $shouldnt 'should not trigger' prompts"

[ "$fail" = 0 ] && echo "All skill tests passed." || { echo "Some skill tests FAILED."; exit 1; }
