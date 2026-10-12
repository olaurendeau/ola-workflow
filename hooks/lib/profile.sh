# shellcheck shell=bash
# Finds and reads the profile of the project the session is working on.
#
# Two places, in this order:
#   1. $HOME/.claude/workflow-profiles/<host>/<owner>/<repo>/profile.json   yours
#   2. <git toplevel>/.claude/workflow.json                                the project's
# Where the file lives says who owns it; the `mode` key inside says how to behave.
# The identity in (1) comes from `git remote get-url upstream || origin`, so a fork is
# known by the repository it contributes to, and a worktree resolves like its checkout.
#
# The user's own profile wins over a file committed in the repository, because the two are
# not equally trusted: a third-party repository must not be able to turn the discreet
# profile you chose for it into an integrated one, and thereby grant itself writes to the
# forge and allowances on commands. One that is there but unusable still wins, and the
# resolution gives up: falling through would be the way back in for the file it distrusts.
#
# Nothing found means nothing found: every function returns 1 and prints nothing, and the
# caller decides. The guard stays inert, which is what keeps this plugin invisible in a
# project that has not opted in. No function may abort a shell that sourced it, so every
# variable that can be unset is read defensively: the guard will source this file.
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

# A path component that is empty, `.`, `..` or holds a slash is never a name.
ola_profile_component_ok() {
  case $1 in
    ''|.|..|*/*) return 1 ;;
  esac
  return 0
}

# ola_profile_url_id <url> → <host>/<owner>/<repo>, the profile directory of a remote.
# Handles scp-like (git@host:owner/repo.git), ssh://, https:// with credentials and a
# port, git://, file:// and plain paths, and GitLab subgroups (the owner may hold slashes).
#
# A remote URL is the only project-controlled value that becomes a filesystem path, so
# this is a security boundary. Two rules carry it: credentials are dropped from the
# authority and never from the path, so a password containing `@` cannot be mistaken for
# a host and leak into a directory name; and no component may be empty, `.` or `..`.
ola_profile_url_id() {
  local url=$1 rest authority host path

  [ -n "$url" ] || return 1

  # file:// has no host: it is a path with a scheme in front.
  case $url in
    file://*) url=${url#file://} ;;
  esac

  case $url in
    *://*)
      rest=${url#*://}
      authority=${rest%%/*}
      case $rest in
        */*) path=${rest#*/} ;;
        *) path= ;;
      esac
      ;;
    /*|./*|../*|~*)
      # A local path has no host: name the profile after the directory it points at. Two
      # clones sharing a basename share a profile, which is the cost of having no
      # canonical identity to key on.
      path=${url%/}
      case $path in
        */.git) return 1 ;;
        *.git) path=${path%.git} ;;
      esac
      path=${path##*/}
      ola_profile_component_ok "$path" || return 1
      printf 'local/%s\n' "$path"
      return 0
      ;;
    *:*)
      # scp-like: [user@]host:path
      authority=${url%%:*}
      path=${url#*:}
      path=${path#/}
      ;;
    *)
      return 1
      ;;
  esac

  # Everything after the LAST @ of the authority. Shortest-match here would leave the
  # tail of a password containing @ standing in for the host.
  case $authority in
    *@*) authority=${authority##*@} ;;
  esac
  # An unencoded / in the userinfo ends the authority too early, so a password holding one
  # leaves its tail posing as a host: `https://user:tok/en@host/o/r` would read as
  # `user/en@host/o/r`. Such a URL is invalid per RFC 3986 and git cannot use it either,
  # but the answer is to refuse it, not to publish half a secret as an identity. What
  # follows the colon of an authority is a port, so it is digits or nothing.
  case $authority in
    *:*)
      case ${authority#*:} in
        ''|*[!0-9]*) return 1 ;;
      esac
      ;;
  esac
  host=${authority%%:*}
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')

  path=${path%/}
  case $path in
    */.git) return 1 ;;
    *.git) path=${path%.git} ;;
  esac

  [ -n "$path" ] || return 1
  ola_profile_component_ok "$host" || return 1
  # One pattern rather than a loop over $path: no word splitting, no globbing against the
  # current directory, and a leading, medial or trailing bad component is caught alike.
  case /$path/ in
    */../*|*/./*|*//*) return 1 ;;
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
  local dir=${1:-$PWD} home=${HOME:-} top id candidate root
  root=$home/.claude/workflow-profiles
  # Resolving a remote costs three subprocesses. Someone who has never written a discreet
  # profile should not pay them on every PreToolUse, so the cheap test comes first.
  if [ -n "$home" ] && [ -d "$root" ] && id=$(ola_profile_id "$dir"); then
    candidate=$root/$id/profile.json
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    # Something is there and is not a regular file: a directory, a broken symlink. Giving
    # up is the only answer that keeps the precedence meaningful — falling through would
    # hand the last word back to the file the repository ships.
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
      return 1
    fi
  fi
  if top=$(ola_profile_toplevel "$dir"); then
    candidate=$top/.claude/workflow.json
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  return 1
}

# ola_profile_dir [dir] → the directory holding the profile. In discreet mode this is also
# where the agents keep their memory (runs/<slug>/).
ola_profile_dir() {
  local file
  file=$(ola_profile_path "${1:-$PWD}") || return 1
  printf '%s\n' "${file%/*}"
}

# ola_profile_readable <file> → 0 when the file holds a JSON value.
# jq exits 0 on an empty input, so every reader has to check for itself: "empty, and
# successfully" is the one answer a caller must never get out of a broken profile. A
# truncated write would otherwise read as zero required checks, or as no protected branch.
ola_profile_readable() {
  jq -e . "$1" >/dev/null 2>&1
}

# ola_profile_mode [dir] → integrated | discreet.
# A profile that cannot be read, or whose mode is not one of the two, is treated as
# discreet: the restrictive mode is the only safe guess about a project's intentions.
# The two names are also in the schema's enum; tests/profile.test.sh fails if they drift.
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
# Status: 0 a value, 3 the profile is fine but holds no such key (a caller may substitute
# a default), 1 no usable profile at all (a caller must not).
ola_profile_get() {
  local key=$1 dir=${2:-$PWD} slot=${3:-} file out status
  [ -n "$key" ] || return 2
  file=$(ola_profile_path "$dir") || return 1
  ola_profile_readable "$file" || return 1
  # `try`, because indexing through a scalar (get base_branch.x) raises rather than
  # yielding null, and on a readable profile that still only means "no such key".
  out=$(jq -r --arg key "$key" '
    (try getpath($key | split(".")) catch null)
    | if . == null then halt_error(3)
      elif type == "array" and (map(type == "object" or type == "array") | any | not) then .[]
      elif type == "object" or type == "array" then tojson
      else .
      end' "$file" 2>/dev/null)
  status=$?
  case $status in
    0) ;;
    3) return 3 ;;
    *) return 1 ;;
  esac
  if [ -n "$slot" ]; then
    out=${out//\{slot\}/$slot}
  fi
  printf '%s\n' "$out"
}

# ola_profile_validate [file] → every problem found, one per line on stderr.
ola_profile_validate() {
  local file=${1:-} problems
  if [ -z "$file" ]; then
    file=$(ola_profile_path "$PWD") || { echo "no profile found" >&2; return 1; }
  fi
  [ -f "$file" ] || { echo "$file: no such file" >&2; return 1; }
  if ! ola_profile_readable "$file"; then
    echo "$file: not valid JSON" >&2
    return 1
  fi
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
