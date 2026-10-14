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
  local url=$1 rest authority host port path

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
      # scp-like: [user@]host:path. A bracketed IPv6 host holds colons of its own, so the
      # split cannot be at the first one — git takes `git@[fd00::1]:srv/app.git` and
      # connects to fd00::1, and refusing it would leave a configured repository inert.
      case $url in
        '['*|*'@['*)
          case $url in
            *']:'*) ;;
            *) return 1 ;;
          esac
          authority=${url%%']:'*}']'
          path=${url#*']:'}
          ;;
        *)
          authority=${url%%:*}
          path=${url#*:}
          ;;
      esac
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
  # Split the authority into host and port the way RFC 3986 does, which means noticing
  # that an IPv6 host is a bracketed literal full of colons: splitting on the first colon
  # would refuse `ssh://git@[fd00::1]/srv/app.git`, a URL git is perfectly happy with, and
  # a configured repository that went silently inert is worse than any of this.
  # The brackets are URL syntax, not part of the host, so they are dropped. Note that two
  # spellings of one IPv6 address (fd00::1, fd00:0:0:0:0:0:0:1) give two identities: a split,
  # never a collision, and not worth normalising an address in shell for.
  case $authority in
    '['*)
      case $authority in
        *']'*) ;;
        *) return 1 ;;
      esac
      host=${authority%%']'*}
      host=${host#'['}
      port=${authority#*']'}
      case $port in
        '') ;;
        :*) port=${port#:} ;;
        *) return 1 ;;
      esac
      ;;
    *:*) host=${authority%%:*}; port=${authority#*:} ;;
    *) host=$authority; port= ;;
  esac
    # What follows the colon is a port: digits, or nothing at all (`host:` is a legal
  # authority, and curl takes it). Anything else means the authority ended early — an
  # unencoded / in a password does that — and the tail of the secret is now posing as a
  # host. Refusing is the answer, not publishing half a credential as an identity.
  case $port in
    '') ;;
    *[!0-9]*) return 1 ;;
  esac
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

# ola_profile_traversable <root> <relative id> → 1 when a level that exists cannot be
# entered. Inside a directory with no execute bit, every test on a file reads false: a
# profile could be sitting there unseen, and falling through would be the one thing the
# precedence forbids. So "cannot tell" has to mean "give up", not "it is not there".
ola_profile_traversable() {
  local base=$1 rest=$2 part
  [ -d "$base" ] || return 0
  [ -x "$base" ] || return 1
  while [ -n "$rest" ]; do
    part=${rest%%/*}
    case $rest in
      */*) rest=${rest#*/} ;;
      *) rest= ;;
    esac
    base=$base/$part
    [ -d "$base" ] || return 0
    [ -x "$base" ] || return 1
  done
  return 0
}

# ola_profile_path [dir] → the profile file in use.
ola_profile_path() {
  local dir=${1:-$PWD} home=${HOME:-} top id candidate root
  root=$home/.claude/workflow-profiles
  # Resolving a remote costs three subprocesses. Someone who has never written a discreet
  # profile should not pay them on every PreToolUse, so the cheap test comes first.
  # Inside a directory that cannot be entered, even [ -d ] on the root below reads false,
  # so the two levels above are tested first: "cannot tell" has to mean "give up" with no
  # exception, including when the accident is above the profiles directory.
  if [ -n "$home" ]; then
    ola_profile_traversable "$home" ".claude/workflow-profiles" || return 1
  fi
  if [ -n "$home" ] && [ -d "$root" ] && id=$(ola_profile_id "$dir"); then
    ola_profile_traversable "$root" "$id" || return 1
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

# ola_profile_candidates [dir] → every path a profile may occupy, in precedence order, one
# per line as `<scope> <path>`, whether the file is there or not.
#
# This exists for whoever has to *write* a profile: `ola_profile_path` answers nothing until
# one exists, so a caller creating the first one would have to restate the layout — and a
# second copy of "where a user-scope profile lives" is how an init command writes to a path
# the resolver does not read. The scope is part of the answer because it is the decision:
# `user` is yours and wins, `project` is the repository's and is committed with it.
#
# Nothing here tests the filesystem. A candidate is where a profile *would* go, which is a
# question with an answer even when the directory does not exist yet — that is the whole
# point of asking it. Which candidate actually applies stays `ola_profile_path`'s to say,
# and `tests/profile.test.sh` holds the two together: a path that resolver returns and this
# one never names would be a layout known in two places and agreed in one.
ola_profile_candidates() {
  local dir=${1:-$PWD} home=${HOME:-} id top
  if [ -n "$home" ] && id=$(ola_profile_id "$dir"); then
    printf 'user %s\n' "$home/.claude/workflow-profiles/$id/profile.json"
  fi
  if top=$(ola_profile_toplevel "$dir"); then
    printf 'project %s\n' "$top/.claude/workflow.json"
  fi
}

# ola_profile_dir [dir] → the directory holding the profile. In discreet mode this is also
# where the agents keep their memory (runs/<slug>/).
ola_profile_dir() {
  local file
  file=$(ola_profile_path "${1:-$PWD}") || return 1
  printf '%s\n' "${file%/*}"
}

# ola_profile_readable <file> → 0 when the file holds a JSON object.
# jq exits 0 on an empty input, so every reader has to check for itself: "empty, and
# successfully" is the one answer a caller must never get out of a broken profile. A
# truncated write would otherwise read as zero required checks, or as no protected branch.
# An object, not merely a value: the schema says `"type": "object"`, and a profile holding
# `[1,2]` or `"hello"` must not read as an object that happens to be missing every key —
# that is how a caller's default gets handed out for a file nobody can use.
# What a usable profile is, written once, as a jq program every reader starts with. It
# yields the profile object, or nothing at all.
#
# Both halves matter. jq evaluates its program once per input value and reports on the
# last, so a type test alone accepts a file holding two concatenated objects — what a `>>`
# written where a `>` was meant leaves behind. `limit(2; inputs)` stops at the second
# value, so the gate costs the same on a huge file as on a small one.
#
# It is a shared constant rather than a function each reader calls, so that each read is
# still one jq and the gate is literally the same text everywhere. That is the point:
# three of the defects found in review were a reader deciding for itself what a usable
# profile is, and twice a fix reached some readers and not all — the last one a `mode`
# answering `integrated` out of a file every other reader refused. A decision that exists
# in one place cannot be half-fixed.
#
# `ola_profile_validate` is the one documented exception: it has to see JSON of the wrong
# type in order to say so usefully.
# It fails with `halt_error` rather than yielding nothing, because `jq -e` reports a
# legitimate `false` the same way it reports no output at all: a profile key whose value is
# `false` must not read as an unusable profile.
#
# The signal is 7, and the "no such key" signal below is 6, to stay clear of the codes jq
# reserves for itself: 3 is a compile error and 4 is `-e` with no output. Sharing a code
# would make a broken jq program indistinguishable from an answer — and `get` is the one
# reader that turns one of its answers into "use the caller's default", so a typo in the
# program would hand out defaults on a perfectly good profile.
#
# `limit/2` and `halt_error/1` are jq 1.5 and later; tests/run.sh checks that.
OLA_PROFILE_GATE='[limit(2; inputs)]
  | if length == 1 and (.[0] | type) == "object" then .[0] else halt_error(7) end'

ola_profile_readable() {
  jq -n "$OLA_PROFILE_GATE" "$1" >/dev/null 2>&1
}

# ola_profile_holds_json <file> → 0 when the file holds exactly one JSON value, of any
# type. `jq empty` would accept an empty file, and `jq -e .` would reject a file holding
# `null` or `false`, so neither answers the question on its own.
# This is what `validate` needs: for valid JSON of the wrong type, the schema interpreter
# says "expected object, got array", which is far more useful than "not valid JSON".
# Every readable profile holds one JSON value, so this is the weaker of the two tests and
# must stay that way: a value that get would serve must never come out of a file this
# refuses.
ola_profile_holds_json() {
  jq -n -e '[limit(2; inputs)] | length == 1' "$1" >/dev/null 2>&1
}

# ola_profile_mode [dir] → integrated | discreet.
# A profile that cannot be read, or whose mode is not one of the two, is treated as
# discreet: the restrictive mode is the only safe guess about a project's intentions.
# The two names are also in the schema's enum; tests/profile.test.sh fails if they drift.
ola_profile_mode() {
  local file mode
  file=$(ola_profile_path "${1:-$PWD}") || return 1
  mode=$(jq -r -n "$OLA_PROFILE_GATE
    | if (.mode | type) == \"string\" then .mode else \"\" end" "$file" 2>/dev/null)
  case $mode in
    integrated|discreet) printf '%s\n' "$mode" ;;
    *) printf 'discreet\n' ;;
  esac
}

# ola_profile_get_state <dotted.key> [dir] [slot] → one value, and three statuses.
# The long name is deliberate: this is the primitive, and it is the dangerous door.
# Status: 0 a value, 3 the profile is fine but holds no such key, 1 no usable profile.
# Use ola_profile_get unless you are implementing the default policy itself — the one
# caller written after this distinction existed collapsed it in two lines, and a truncated
# profile then announced a base branch the project did not have.
ola_profile_get_state() {
  local key=$1 dir=${2:-$PWD} slot=${3:-} file out
  local status=0
  [ -n "$key" ] || return 2
  file=$(ola_profile_path "$dir") || return 1
  # The gate and the read are one jq, so an unusable profile cannot be read at all: it
  # produces no output, jq exits non-zero, and no default may stand in.
  # `try`, because indexing through a scalar (get base_branch.x) raises rather than
  # yielding null, and on a readable profile that still only means "no such key".
  out=$(jq -r -n --arg key "$key" "$OLA_PROFILE_GATE"'
    | (try getpath($key | split(".")) catch null)
    | if . == null then halt_error(6)
      elif type == "array" and (map(type == "object" or type == "array") | any | not) then .[]
      elif type == "object" or type == "array" then tojson
      else .
      end' "$file" 2>/dev/null) || status=$?
  case $status in
    0) ;;
    6) return 3 ;;
    *) return 1 ;;
  esac
  if [ -n "$slot" ]; then
    out=${out//\{slot\}/$slot}
  fi
  printf '%s\n' "$out"
}

# ola_profile_get <dotted.key> [dir] [slot] [default] → one value, or nothing.
# The whole default policy, in the name every caller reaches for first:
#   - a value           → printed, status 0
#   - no such key, a default given → the default, status 0
#   - no such key, no default      → status 1, nothing printed
#   - no usable profile            → status 1, nothing printed
# The last two are indistinguishable on purpose. A caller cannot tell "absent" from
# "unreadable", so it cannot invent a value for either: inventing requires passing a
# default, which is a deliberate act at the call site. {slot} applies to a default too,
# since a default is a value like any other.
#
# So read status 1 as **"I do not know"**, never as "nothing is declared". The difference
# matters most where a rule list is read: `rules=$(ola_profile_get commands) || rules=""`
# gives the same empty answer for a project that declares no command rules and for a
# profile nobody can parse — and then concludes "no rules, allow everything" on the broken
# one. Check the profile is usable **once**, at the entry of whatever you are writing
# (`ola_profile_readable`, or refuse what `ola_profile_path` refuses), and after that an
# empty answer means empty. Do not re-derive that check at each read; do not skip it.
ola_profile_get() {
  local key=$1 dir=${2:-$PWD} slot=${3:-} default=${4:-} status out
  # `|| status=$?` and not a bare assignment followed by `$?`: under `set -e` an assignment
  # whose command substitution fails kills the shell **before** the next line runs. The
  # guard is the first caller to use `set -e`, and the symptom was every command in the
  # session blocked by the fail-closed trap — a library that is only safe without `set -e`
  # is a library that cannot be used by the one caller that must fail closed.
  status=0
  out=$(ola_profile_get_state "$key" "$dir" "$slot") || status=$?
  case $status in
    0) printf '%s\n' "$out"; return 0 ;;
    3) [ $# -ge 4 ] || return 1
       printf '%s\n' "${default//\{slot\}/$slot}"
       return 0 ;;
    *) return 1 ;;
  esac
}

# ola_profile_has <dotted.key> [dir] → 0 when the profile holds that key.
# For a caller that needs to say which values are its own defaults rather than the
# project's. It answers "present" and "not present" and nothing else, so call it only once
# the profile is known readable — ola_profile_readable, or ola_profile_get on any key.
ola_profile_has() {
  ola_profile_get_state "$1" "${2:-$PWD}" "" >/dev/null 2>&1
}

# ola_profile_validate [file] → every problem found, one per line on stderr.
ola_profile_validate() {
  local file=${1:-} problems
  if [ -z "$file" ]; then
    file=$(ola_profile_path "$PWD") || { echo "no profile found" >&2; return 1; }
  fi
  [ -f "$file" ] || { echo "$file: no such file" >&2; return 1; }
  if ! ola_profile_holds_json "$file"; then
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
