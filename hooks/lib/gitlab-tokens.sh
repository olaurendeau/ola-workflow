# shellcheck shell=bash
# Where the GitLab tokens live, and how they are read. Sourced, never run.
#
# Same keychain, same services, same three kinds as GitHub (hooks/lib/github-tokens.sh);
# what changes is the account. A GitLab token is kept under the account
# `gitlab:<host>/<path of the project>`, and read by going **up** from the project to its
# host:
#
#   gitlab:gl.example.com/group/sub/project   a project access token (the agents' bot), or a
#   gitlab:gl.example.com/group/sub           personal access token limited to the project
#   gitlab:gl.example.com/group               a group's
#   gitlab:gl.example.com                     a classic personal access token, good everywhere
#
# The nearest wins. The ascent never leaves the host the project's remote names: a token
# kept for host A is not one of the accounts asked for on host B, and the host is exported
# with the token (GITLAB_HOST) so that glab sends it nowhere else.
#
# What GitLab does not give is what GitHub gives: the roles are not enforced by the
# token's rights, so what this file lends is an identity, not a permission. What that means
# for the roles is for the GitLab token documentation to say (#167). The tokens are never
# written to a file and never put in the text of a command.
#
# Whose token it is depends on the mode: in integrated mode the agents' bot, in discreet mode
# the human's granular token for this project only, read at the project's own account.
#
# Everything in the remote — host and path — is project-controlled text. It reaches the
# line sourced before each Bash command only through `printf %q`, so a quote, a space or a
# `$( )` in a path stays a character of a name.

# shellcheck source=hooks/lib/github-tokens.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/github-tokens.sh"

# What the line exports when no token is found: a value GitLab rejects (401). Never an empty
# one: glab treats an empty GITLAB_TOKEN as unset and falls back to the human's own login,
# which is the one outcome this file exists to prevent.
OLA_GITLAB_NO_TOKEN=ola-workflow-has-no-base-token

# ola_gitlab_id [dir] → <host>/<path> of the project's remote, or 1. A name with a line break
# in it is no name: the accounts are told apart by lines. The ssh-over-443 host of gitlab.com
# is gitlab.com (as in bin/ola-workflow-pr-assets): it serves git, not the API glab calls, and
# the tokens are kept for gitlab.com.
ola_gitlab_id() {
  local id
  id=$(ola_profile_id "${1:-$PWD}") || return 1
  case $id in
    ''|*$'\n'*|*$'\r'*) return 1 ;;
    altssh.gitlab.com|altssh.gitlab.com/*) id=gitlab.com${id#altssh.gitlab.com} ;;
  esac
  printf '%s' "$id"
}

# ola_gitlab_accounts <host/path> → the accounts to ask, one per line, project first.
ola_gitlab_accounts() {
  local path=$1
  while :; do
    printf 'gitlab:%s\n' "$path"
    case $path in
      */*) path=${path%/*} ;;
      *) break ;;
    esac
  done
}

# ola_gitlab_project_account <host/path> → the one account of a token limited to the project.
# Nothing above it: a token kept at a group or at the host is a classic or a group token, and
# is not limited to the project.
ola_gitlab_project_account() {
  printf 'gitlab:%s\n' "$1"
}

# ola_gitlab_token_read <kind> <host/path> → the nearest token on stdout, or 1 when there is
# none. An empty answer is a missing token, as for GitHub.
ola_gitlab_token_read() {
  local account
  while IFS= read -r account; do
    ola_token_read "$1" "$account" && return 0
  done <<EOF
$(ola_gitlab_accounts "$2")
EOF
  return 1
}

# The line the SessionStart hook writes to CLAUDE_ENV_FILE after the GH_TOKEN one, given the
# <host>/<path> of the project (empty when the remote is unknown). Like that one it looks the
# token up each time rather than writing it in, so the secret stays in the keychain. The
# accounts are the ascent above, written as words quoted by `%q`; the loop runs in a
# command substitution so that its variables are not left in the session. With a second
# argument, `project` (discreet mode), the only account is the project's own, with no ascent:
# the line is the same otherwise, and without the argument the output is the integrated one.
# shellcheck disable=SC2016
#   The $ are for the shell that sources the line, not for this one.
ola_gitlab_env_line() {
  local id=${1:-} scope=${2:-} account host
  if [ -z "$id" ]; then
    printf 'export GITLAB_TOKEN=%s\n' "$OLA_GITLAB_NO_TOKEN"
    return 0
  fi
  printf 'export GITLAB_TOKEN="$(for a in'
  while IFS= read -r account; do
    printf ' %q' "$account"
  done <<EOF
$(if [ "$scope" = project ]; then ola_gitlab_project_account "$id"; else ola_gitlab_accounts "$id"; fi)
EOF
  printf '; do t=$(security find-generic-password -s %s -a "$a" -w 2>/dev/null) && [ -n "$t" ] && { printf %%s "$t"; break; }; done)"; ' \
    "$(ola_token_service base)"
  # zsh expands a word that starts with `=` (`==ls` is `/bin/ls`), and `%q` leaves it as is.
  host=$(printf '%q' "${id%%/*}")
  case $host in
    =*) host=\\$host ;;
  esac
  printf '[ -n "$GITLAB_TOKEN" ] || export GITLAB_TOKEN=%s; export GITLAB_HOST=%s\n' \
    "$OLA_GITLAB_NO_TOKEN" "$host"
}
