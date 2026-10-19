# Where the GitHub tokens of each role live, and how they are read. Sourced, never run.
#
# GitHub enforces the roles here, not a reading of the command line. Every agent works with
# the **base** token, which can neither merge nor write a commit status: GitHub refuses
# both with a 403, however the command is spelled — `gh`, `gh api`, an alias, `eval`, a
# script. Two commands, in one exact form each, get a stronger token (hooks/elevate.sh):
#
#   merge   the coordinator's `gh pr merge`        Contents: write
#   review  the pr-reviewer's review status        Commit statuses: write
#
# When anything goes wrong, nobody gains a right, they lose one: a form the hook does not
# recognise runs with the base token and gets a 403. The guard this replaces had to read
# every spelling of every shell to stop the same commands, and each missed spelling let a
# merge through.
#
# The tokens are fine-grained PATs, kept in the macOS keychain under one account, one
# service per kind. They are never written to a file and never put in the text of a command.

# shellcheck disable=SC2034
#   Read by the files that source this one.
OLA_TOKEN_ACCOUNT=ola-workflow
# shellcheck disable=SC2034
OLA_TOKEN_KINDS="base merge review"

# What each token may do, as the query string GitHub's creation form accepts. The single
# source: the setup command builds its URLs from it and the README copies it.
ola_token_permissions() { # ola_token_permissions <kind>
  case $1 in
    base)   echo 'metadata=read&contents=read&pull_requests=write&issues=write&statuses=read&actions=read' ;;
    merge)  echo 'metadata=read&contents=write&pull_requests=write' ;;
    review) echo 'metadata=read&statuses=write' ;;
    *) return 1 ;;
  esac
}

ola_token_service() { printf 'ola-workflow-%s' "$1"; }

# ola_token_read <kind> → the token on stdout, or 1 when there is none. An empty answer is
# a missing token: `GH_TOKEN=` empty makes gh fall back to the human's own login, which
# is the one outcome this file exists to prevent.
ola_token_read() {
  local token
  command -v security >/dev/null 2>&1 || return 1
  token=$(security find-generic-password -s "$(ola_token_service "$1")" \
            -a "$OLA_TOKEN_ACCOUNT" -w 2>/dev/null) || return 1
  [ -n "$token" ] || return 1
  printf '%s' "$token"
}

# The line the SessionStart hook writes to CLAUDE_ENV_FILE, which Claude Code sources
# before each Bash command, subagents included (measured on 2.1.302). It looks the token up
# each time rather than writing it into the file, so the secret stays in the keychain.
# With no token it exports a value GitHub rejects (401), never an empty one.
# shellcheck disable=SC2016
#   The $ are for the shell that sources the line, not for this one.
ola_token_env_line() {
  printf 'export GH_TOKEN="$(security find-generic-password -s %s -a %s -w 2>/dev/null)"; ' \
    "$(ola_token_service base)" "$OLA_TOKEN_ACCOUNT"
  printf '[ -n "$GH_TOKEN" ] || export GH_TOKEN=ola-workflow-has-no-base-token\n'
}
