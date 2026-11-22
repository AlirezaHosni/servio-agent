#!/usr/bin/env bash
# run.sh: run one of the bundled scripts on a server, over your own SSH setup.
#
#   bash run.sh <host-alias> <script> [args...]
#   bash run.sh web1 inventory.sh
#   bash run.sh web1 create-site.sh shop.example.com public 8.4
#
# What it does, on YOUR laptop:
#   1. checks the host alias, the script name (allow-list) and every argument (safe characters)
#   2. sends lib.sh + the script over SSH and runs them as root:
#        cat lib.sh <script> | ssh <host-alias> 'sudo -n bash -s' -- <args>
#
# The host alias comes from your ~/.ssh/config, and the key from your SSH agent. No key,
# password or IP address lives in this plugin or in the chat.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWED="inventory.sh provision-server.sh create-site.sh deploy-site.sh issue-certificate.sh delete-site.sh"

usage() {
    echo "Usage: bash run.sh <host-alias> <script> [args...]" >&2
    echo "Scripts: $ALLOWED" >&2
    exit 64
}

[ "$#" -ge 2 ] || usage
HOST="$1"; SCRIPT="$2"; shift 2

# A host alias from ~/.ssh/config: letters, digits, dot, dash, underscore, and it can't start
# with "-". "-oProxyCommand=..." would otherwise be read by ssh as an OPTION and run a command
# on this laptop. (user@host is allowed too, for a server without an alias.)
if ! [[ "$HOST" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*(@[A-Za-z0-9_][A-Za-z0-9._-]*)?$ ]]; then
    echo "Invalid host alias '$HOST'. Use a Host name from your ~/.ssh/config." >&2
    exit 64
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
        exit 64
    fi
done

# sed strips Windows line endings (CR), in case the repo was checked out with CRLF: bash on
# the server would fail with "$'\r': command not found".
#   -T                    no terminal: we pipe a script, nobody types
#   BatchMode=yes         never ask for a password or passphrase (an agent can't type it);
#                         fail instead. Unknown host keys fail too: ssh in by hand once first
#   ConnectTimeout=15     don't hang on a server that's down
#   sudo -n               "non-interactive": fail instead of waiting for a sudo password
#   bash -s -- args       read the script from stdin, $1.. = args
sed 's/\r$//' "$SCRIPTS_DIR/lib.sh" "$SCRIPTS_DIR/$SCRIPT" \
    | ssh -T -o BatchMode=yes -o ConnectTimeout=15 "$HOST" 'sudo -n bash -s' -- "$@"
