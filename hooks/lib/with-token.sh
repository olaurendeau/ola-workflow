#!/usr/bin/env bash
# with-token.sh <kind> <command…> — runs the command with that kind's token as GH_TOKEN.
#
# hooks/elevate.sh puts this in front of the two commands that need more than the base
# token. It never falls back: with no token it stops before running anything, because the
# command would otherwise run with whatever GH_TOKEN the session holds and fail in a way
# that names the wrong cause.
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=hooks/lib/github-tokens.sh
. "$SELF_DIR/github-tokens.sh"

kind=${1:-}
[ $# -ge 2 ] || { echo "usage: with-token.sh <kind> <command…>" >&2; exit 2; }
shift

if ! token=$(ola_token_read "$kind"); then
  echo "ola-workflow: there is no '$kind' token in the keychain, so this command was not run. The human runs: ola-workflow-tokens setup $kind" >&2
  exit 3
fi
GH_TOKEN=$token exec "$@"
