# shellcheck shell=bash
# Finds and reads the profile of the project the session is working on.
#
# Two places, in this order:
#   1. <git toplevel>/.claude/workflow.json                           integrated mode
#   2. $HOME/.claude/workflow-profiles/<host>/<owner>/<repo>/profile.json   discreet mode
# The identity in (2) comes from `git remote get-url upstream || origin`, so a fork is
# known by the repository it contributes to, and a worktree resolves like its checkout.
#
# Nothing found means nothing found: every function returns 1 and prints nothing, and the
# caller decides. The guard stays inert, which is what keeps this plugin invisible in a
# project that has not opted in.
#
# jq and perl only, and nothing that needs bash 4: the host runs bash 3.2.

OLA_PROFILE_LIB_DIR=${OLA_PROFILE_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
OLA_PROFILE_SCHEMA=${OLA_PROFILE_SCHEMA:-$OLA_PROFILE_LIB_DIR/../../schema/profile.schema.json}
OLA_PROFILE_VALIDATOR=${OLA_PROFILE_VALIDATOR:-$OLA_PROFILE_LIB_DIR/profile-validate.jq}

# ola_profile_toplevel [dir] → the working tree root, or 1 outside a repository.
ola_profile_toplevel() {
  git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null
}

# ola_profile_remote_url [dir] → upstream if it exists, else origin.
ola_profile_remote_url() {
  local dir=${1:-$PWD} remote
  for remote in upstream origin; do
    if git -C "$dir" remote get-url "$remote" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# ola_profile_url_id <url> → <host>/<owner>/<repo>, the profile directory of a remote.
# Handles scp-like (git@host:owner/repo.git), ssh://, https:// with credentials and port,
# git://, file:// and plain paths, and GitLab subgroups (owner may hold slashes).
ola_profile_url_id() {
  local url=$1 rest host path component
  [ -n "$url" ] || return 1

  # file:// has no host, so it is a path with a scheme in front.
  case $url in
    file://*) url=${url#file://} ;;
  esac

  case $url in
    *://*)
      rest=${url#*://}
      # Strip credentials, but only when the @ sits before the first slash.
      case ${rest%%/*} in
        *@*) rest=${rest#*@} ;;
      esac
      ;;
    /*|./*|../*|~*)
      # A local path has no host: name it after the directory it points at.
      path=${url%/}
      path=${path%.git}
      printf 'local/%s\n' "${path##*/}"
      return 0
      ;;
    *:*)
      rest=${url#*@}
      rest=${rest/:/\/}
      ;;
    *)
      return 1
      ;;
  esac

  host=${rest%%/*}
  host=${host%%:*}
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  path=${rest#*/}
  path=${path%/}
  path=${path%.git}
  path=${path#/}

  [ -n "$host" ] && [ -n "$path" ] && [ "$path" != "$host" ] || return 1

  # A remote URL is attacker-adjacent data: it must not be able to walk out of the
  # profiles directory, nor hide a profile behind an empty path component.
  local IFS=/
  for component in $path; do
    case $component in
      ''|.|..) return 1 ;;
    esac
  done
  case $host in
    ''|.|..) return 1 ;;
  esac

  printf '%s/%s\n' "$host" "$path"
}

# ola_profile_id [dir] → the identity used for the discreet profile directory.
ola_profile_id() {
  local url
  url=$(ola_profile_remote_url "${1:-$PWD}") || return 1
  ola_profile_url_id "$url"
}

# ola_profile_path [dir] → the profile file in use.
ola_profile_path() {
  local dir=${1:-$PWD} top id candidate
  if top=$(ola_profile_toplevel "$dir"); then
    candidate=$top/.claude/workflow.json
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  id=$(ola_profile_id "$dir") || return 1
  candidate=$HOME/.claude/workflow-profiles/$id/profile.json
  [ -f "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

# ola_profile_dir [dir] → the directory holding the profile. In discreet mode this is also
# where the agents keep their memory (runs/<slug>/).
ola_profile_dir() {
  local file
  file=$(ola_profile_path "${1:-$PWD}") || return 1
  printf '%s\n' "${file%/*}"
}

# ola_profile_mode [dir] → integrated | discreet.
# A profile that cannot be read, or whose mode is not one of the two, is treated as
# discreet: the restrictive mode is the only safe guess about a project's intentions.
ola_profile_mode() {
  local file mode
  file=$(ola_profile_path "${1:-$PWD}") || return 1
  mode=$(jq -r 'if (.mode | type) == "string" then .mode else "" end' "$file" 2>/dev/null)
  case $mode in
    integrated|discreet) printf '%s\n' "$mode" ;;
    *) printf 'discreet\n' ;;
  esac
}

# ola_profile_get <dotted.key> [dir] [slot] → one value.
# A scalar prints raw, an array of scalars prints one item per line, anything else prints
# as compact JSON. {slot} in the value is replaced when a slot is given.
ola_profile_get() {
  local key=$1 dir=${2:-$PWD} slot=${3:-} file out
  [ -n "$key" ] || return 2
  file=$(ola_profile_path "$dir") || return 1
  out=$(jq -r --arg key "$key" '
    getpath($key | split("."))
    | if . == null then halt_error(3)
      elif type == "array" and (map(type == "object" or type == "array") | any | not) then .[]
      elif type == "object" or type == "array" then tojson
      else .
      end' "$file" 2>/dev/null) || return 1
  if [ -n "$slot" ]; then
    out=${out//\{slot\}/$slot}
  fi
  printf '%s\n' "$out"
}

# ola_profile_validate [file] → every problem found, one per line.
ola_profile_validate() {
  local file=${1:-}
  if [ -z "$file" ]; then
    file=$(ola_profile_path "$PWD") || { echo "no profile found" >&2; return 1; }
  fi
  [ -f "$file" ] || { echo "$file: no such file" >&2; return 1; }
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "$file: not valid JSON" >&2
    return 1
  fi
  local problems
  problems=$(jq -r --slurpfile schema "$OLA_PROFILE_SCHEMA" \
    -f "$OLA_PROFILE_VALIDATOR" "$file" 2>&1) || {
    echo "$file: the validator failed: $problems" >&2
    return 1
  }
  if [ -n "$problems" ]; then
    printf '%s\n' "$problems" >&2
    return 1
  fi
  return 0
}
