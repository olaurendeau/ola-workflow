#!/usr/bin/env bash
# with-token.sh <forge> <kind> <command…> — runs the command with that forge's token of that
# kind, in the variable that forge's tool reads: GH_TOKEN for github.
#
# hooks/elevate.sh puts this in front of the two commands that need more than the base
# token. It never falls back: with no token it stops before running anything, because the
# command would otherwise run with whatever token the session holds and fail in a way
# that names the wrong cause. A forge it does not know — gitlab has no token to lend yet —
# stops it the same way: nothing runs, and nothing is exported.
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

[ $# -ge 3 ] || { echo "usage: with-token.sh <forge> <kind> <command…>" >&2; exit 2; }
forge=$1 kind=$2
shift 2

case $forge in
  github)
    # shellcheck source=hooks/lib/github-tokens.sh
    . "$SELF_DIR/github-tokens.sh"
    if ! token=$(ola_token_read "$kind"); then
      echo "ola-workflow: there is no '$kind' token in the keychain, so this command was not run. The human runs: ola-workflow-tokens setup $kind" >&2
      exit 3
    fi
    GH_TOKEN=$token exec "$@" ;;
  *)
    echo "ola-workflow: no token is lent for the forge '$forge', so this command was not run." >&2
    exit 2 ;;
esac
