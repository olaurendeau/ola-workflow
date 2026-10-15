# A scratch directory, or nothing at all. Sourced by every script here that makes one.
#
# This exists because the idiom it replaces can delete the repository.
#
#   WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ola-x.XXXXXX")" && pwd -P)
#   trap 'rm -rf "$WORK"' EXIT
#
# When `mktemp -d` fails — a $TMPDIR that does not exist, or is not writable — the inner
# substitution is empty, `cd ""` succeeds and stays put, `pwd -P` answers the *current*
# directory, and the trap erases it. Exit status 0. It happened: a review worktree was wiped
# mid-review by `make measure`, and the script reported success.
#
# It is the same shape as the defects this repository keeps finding — a command that fails
# and is read as a result — in its most expensive form, so the answer is a function rather
# than five corrected copies.
#
# It **sets a variable** instead of printing one, and that is the point: inside
# `WORK=$(ola_scratch x)` an `exit 2` would end only the substitution's subshell, the caller
# would carry on with an empty WORK, and we would be back where we started.

ola_scratch() { # ola_scratch <name> → sets OLA_SCRATCH to a fresh directory, or exits 2
  local name=$1 root=${TMPDIR:-/tmp} dir
  dir=$(mktemp -d "$root/ola-$name.XXXXXX") || {
    echo "${0##*/}: cannot create a temporary directory under $root" >&2
    exit 2
  }
  [ -n "$dir" ] && [ -d "$dir" ] || {
    echo "${0##*/}: mktemp answered no usable directory under $root" >&2
    exit 2
  }
  # Resolved, because macOS hands back a symlink while git reports physical paths — and then
  # checked again, because resolving is another command that can answer something else.
  dir=$(cd "$dir" && pwd -P) || {
    echo "${0##*/}: cannot enter the temporary directory $dir" >&2
    exit 2
  }
  case ${dir##*/} in
    ola-"$name".??????) ;;
    *)
      echo "${0##*/}: refusing to use $dir as scratch — it is not a directory I just made" >&2
      exit 2
      ;;
  esac
  # shellcheck disable=SC2034
  #   Unused *here*, and that is the point: this file is sourced, and the variable is the
  #   caller's answer. A function that printed it instead could not refuse — see the top.
  OLA_SCRATCH=$dir
}
