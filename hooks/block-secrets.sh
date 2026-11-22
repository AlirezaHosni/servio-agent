#!/usr/bin/env bash
# block-secrets.sh: a PreToolUse hook for Claude Code's Bash tool.
#
# Claude Code sends the planned tool call as JSON on stdin, e.g.
#   {"tool_name":"Bash","tool_input":{"command":"ssh web1 cat /home/servio/shop.com/.env", ...}, ...}
# Exit 0 = let it run (the normal permission prompt still applies).
# Exit 2 = block it; what we print on stderr is shown to Claude as the reason.
#
# It blocks:
#   - private keys, ANYWHERE (local or remote): id_rsa / id_ed25519 / id_ecdsa / id_dsa without
#     .pub, Servio deploy keys (deploy_<domain> without .pub), privkey.pem, *.key files,
#     ssh_host_*_key, .pem files under .ssh or letsencrypt
#   - .env files in commands that reach a SERVER (ssh, scp, sftp, rsync, or this plugin's run.sh).
#     .env.example / .env.sample / .env.dist are fine (templates, no secrets).
#     A teammate's LOCAL .env in their own project is not blocked: that's their machine.
#
# This is a guard rail, not a sandbox. It reads the command text, so a determined workaround
# (base64, a script file, a variable) gets past it. The skill's rules say never to try.

input="$(cat)"

# Pull out tool_input.command. jq if it's installed; otherwise sed on the one-line JSON
# (handles \" inside the string). If both fail, check the whole input: blocking a harmless
# command by mistake is better than letting a secret through.
command=""
if command -v jq >/dev/null 2>&1; then
    command="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
fi
if [ -z "$command" ]; then
    command="$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p' | head -n 1)"
fi
[ -n "$command" ] || command="$input"

block() {
    echo "Blocked by servio-agent: $1" >&2
    echo "Never read, print, copy or edit .env files or private keys. Use the bundled scripts (inventory.sh shows whether a .env exists without reading it). If the user needs a secret changed, tell them to do it themselves." >&2
    exit 2
}

# --- Private keys: always ---------------------------------------------------------------------
# (^|[^A-Za-z0-9_]) and ([^A-Za-z0-9_.]|$): a whole file name, so "id_ed25519.pub" doesn't match.
# deploy_<domain> can end in ".pub" and still match the pattern, so every match is listed (-o)
# and the public halves (".pub") are dropped before deciding.
key_name='(^|[^A-Za-z0-9_])(id_(rsa|dsa|ecdsa|ecdsa_sk|ed25519|ed25519_sk)|deploy_[a-z0-9.-]+[a-z]|privkey[0-9]*\.pem|ssh_host_[a-z0-9]+_key|[A-Za-z0-9_-]+\.key)([^A-Za-z0-9_.]|$)'
if printf '%s' "$command" | grep -Eo "$key_name" | grep -Evq '\.pub([^A-Za-z0-9_.]|$)'; then
    block "the command mentions a private key file."
fi
if printf '%s' "$command" | grep -Eq '(\.ssh|letsencrypt)/[^ ]*\.pem'; then
    block "the command mentions a .pem file in .ssh or letsencrypt."
fi

# --- .env on servers ---------------------------------------------------------------------------
remote='(^|[^A-Za-z0-9_-])(ssh|scp|sftp|rsync|run\.sh)([^A-Za-z0-9_-]|$)'
# ".env" as a file name, optionally with a suffix (.env.production), but not the templates.
env_file='(^|[^A-Za-z0-9_])\.env(\.[A-Za-z0-9_-]+)?([^A-Za-z0-9_.-]|$)'
if printf '%s' "$command" | grep -Eq "$remote"; then
    if printf '%s' "$command" | grep -Eo "$env_file" | grep -Evq '\.env\.(example|sample|dist)'; then
        block "the command touches a .env file on a server."
    fi
fi

exit 0
