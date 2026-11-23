#!/usr/bin/env bash
# servio-guard.sh: starts the real hook, servio-guard.pl (perl reads Claude Code's JSON safely;
# bash can't). perl comes with Git for Windows, macOS and every Linux. If it's missing anyway,
# ask about every Bash command instead of letting anything through unchecked (fail closed).
if command -v perl >/dev/null 2>&1; then
    exec perl "$(dirname "$0")/servio-guard.pl"
fi
cat > /dev/null
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"servio-agent: perl is missing, so this command could not be checked. Review it yourself."}}'
exit 0
