#!/usr/bin/env bash
# run.sh: run one of the bundled scripts on a server, over your own SSH setup.
#
#   bash run.sh <host-alias> <script> [args...] [--dry-run]
#   bash run.sh web1 inventory.sh
#   bash run.sh web1 create-site.sh shop.example.com public 8.4 --dry-run
#
# What it does, on YOUR laptop:
#   1. checks the host alias, the script name (allow-list) and every argument (safe characters)
#   2. builds what the server runs: a few SERVIO_* lines (which script, its SHA-256, the plugin
#      version, for the server's action log), then lib.sh, then the script
#   3. sends it over SSH and runs it as root:  ... | ssh <host-alias> 'sudo -n bash -s' -- <args>
#
# Exit codes: the script's own (0 done, 1 failed, 2 wrong input, 3 server not ready, 4 refused,
# 5 missing tool; see lib.sh), plus 6 = could not connect (or the server's identity is unknown
# or has CHANGED).
#
# The host alias comes from your ~/.ssh/config, and the key from your SSH agent. No key,
# password or IP address lives in this plugin or in the chat.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_JSON="$SCRIPTS_DIR/../../../.claude-plugin/plugin.json"
ALLOWED="inventory.sh provision-server.sh create-site.sh deploy-site.sh issue-certificate.sh delete-site.sh fix-permissions.sh job-status.sh job-stop.sh"
# Long scripts run as a job on the server (item 45): a dropped connection doesn't stop them.
LONG="provision-server.sh deploy-site.sh issue-certificate.sh"

usage() {
    echo "Usage: bash run.sh <host-alias> <script> [args...] [--dry-run] [--detach]" >&2
    echo "Scripts: $ALLOWED" >&2
    exit 2
}

[ "$#" -ge 2 ] || usage
HOST="$1"; SCRIPT="$2"; shift 2

# --detach is for run.sh itself (start the job, print its id, return); --dry-run goes on to
# the script. A dry run changes nothing and is quick, so it never runs as a job.
JOB_MODE="follow" DRY=0 ARGS=()
for arg in "$@"; do
    case "$arg" in
        --detach) JOB_MODE="detach" ;;
        --dry-run) DRY=1; ARGS+=("$arg") ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

# A host alias from ~/.ssh/config: letters, digits, dot, dash, underscore, and it can't start
# with "-". "-oProxyCommand=..." would otherwise be read by ssh as an OPTION and run a command
# on this laptop. (user@host is allowed too, for a server without an alias.)
if ! [[ "$HOST" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*(@[A-Za-z0-9_][A-Za-z0-9._-]*)?$ ]]; then
    echo "Invalid host alias '$HOST'. Use a Host name from your ~/.ssh/config." >&2
    exit 2
fi

case " $ALLOWED " in
    *" $SCRIPT "*) ;;
    *) echo "Unknown script '$SCRIPT'." >&2; usage ;;
esac

# ssh joins the arguments into ONE string that the server's shell splits again, so a space or
# a ";" in an argument would become a second word or a second command ON THE SERVER. Allow only
# characters that domains, folders, versions, branches and git URLs need; the server-side
# scripts then check each value against its exact pattern.
for arg in "$@"; do
    if ! [[ "$arg" =~ ^[A-Za-z0-9._:/@+-]+$ ]]; then
        echo "Refusing argument '$arg': only letters, digits and . _ : / @ + - are allowed." >&2
        exit 2
    fi
done

# What the server runs. sed strips Windows line endings (CR), in case the repo was checked out
# with CRLF: bash on the server would fail with "$'\r': command not found".
build_payload() {
    sed 's/\r$//' "$SCRIPTS_DIR/lib.sh" "$SCRIPTS_DIR/$SCRIPT"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# The values below go into the script as code, so each must match a strict pattern first.
SCRIPT_SHA="$(build_payload | sha256_of)"
VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN_JSON" 2>/dev/null | head -n 1)"
[[ "$SCRIPT_SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "Couldn't compute the script's SHA-256." >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]] || VERSION="unknown"

# ssh's own messages (and sudo's) go to a temp file and are shown after the run, so a connection
# problem can be explained in plain words. The scripts' output streams live as before.
SSH_ERR="$(mktemp)"
trap 'rm -f "$SSH_ERR"' EXIT

#   -T                    no terminal: we pipe a script, nobody types
#   BatchMode=yes         never ask for a password or passphrase (an agent can't type it); fail
#   StrictHostKeyChecking=yes  never accept an unknown or changed server key silently (item 36):
#                         an unknown server needs one manual `ssh <alias>` first; a CHANGED key
#                         may mean someone is impersonating the server
#   ConnectTimeout=15     don't hang on a server that's down
#   sudo -n               "non-interactive": fail instead of waiting for a sudo password
#   bash -s -- args       read the script from stdin, $1.. = args
header() {
    printf "SERVIO_SCRIPT_NAME='%s'\n" "$SCRIPT"
    printf "SERVIO_SCRIPT_SHA256='%s'\n" "$SCRIPT_SHA"
    printf "SERVIO_PLUGIN_VERSION='%s'\n" "$VERSION"
    printf "SERVIO_APPROVAL='fresh'\n"
    printf "SERVIO_JOB_MODE='%s'\n" "$JOB_MODE"
}

# A long script (not a dry run) is wrapped as a job: lib.sh, then servio_launch_job with the
# real script in a quoted heredoc (bash expands nothing inside it). The end marker is random,
# and checked not to appear in the script, so the heredoc can't end early. Checked HERE, before
# the pipe: an `exit` inside the pipe would only stop the left side, after part of it was sent.
AS_JOB=0 MARKER=""
if [ "$DRY" -eq 0 ] && [[ " $LONG " == *" $SCRIPT "* ]]; then
    AS_JOB=1
    MARKER="SERVIO_JOB_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    if build_payload | grep -qF "$MARKER"; then
        echo "The script contains the job marker (that should never happen); not sending it." >&2
        exit 1
    fi
fi

payload() {
    header
    if [ "$AS_JOB" -eq 0 ]; then
        build_payload
        return
    fi
    sed 's/\r$//' "$SCRIPTS_DIR/lib.sh"
    printf 'servio_launch_job "$@" <<'"'"'%s'"'"'\n' "$MARKER"
    header
    build_payload
    printf '%s\n' "$MARKER"
}

set +e
payload | ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 \
    "$HOST" 'sudo -n bash -s' -- "$@" 2>"$SSH_ERR"
rc=$?
set -e
# The scripts send their own errors to stdout (servio_run), so this holds ssh's and sudo's.
cat "$SSH_ERR" >&2

if [ "$rc" -eq 255 ]; then
    if grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED" "$SSH_ERR"; then
        echo "STOPPED: the identity (host key) of '$HOST' has CHANGED since you last connected." >&2
        echo "This happens after a server is rebuilt, but it can also mean someone is impersonating it." >&2
        echo "Check with whoever runs the server before continuing. Nothing was run." >&2
    elif grep -qE "Host key verification failed|No .* host key is known" "$SSH_ERR"; then
        echo "STOPPED: '$HOST' isn't known yet. Connect once by hand (ssh $HOST), check and accept its key, then try again." >&2
    else
        echo "Couldn't connect to '$HOST' (see ssh's message above). Nothing was run." >&2
    fi
    exit 6
fi
if [ "$rc" -eq 1 ] && grep -q "sudo: a password is required" "$SSH_ERR"; then
    echo "The SSH user on '$HOST' needs passwordless sudo (or use root). Nothing was run." >&2
    exit 3
fi
exit "$rc"
