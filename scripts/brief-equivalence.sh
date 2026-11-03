#!/usr/bin/env bash
# Does the brief of this worktree say, byte for byte, what the brief of another revision says?
#
# Usage: scripts/brief-equivalence.sh [<rev>]      (default origin/main; run from the worktree)
#
# The brief used to be one bash script and is becoming templates in brief/. A refactor owes
# one thing: the same output. This renders 14 profiles (C01 to C14) with the brief of the
# worktree it is run from, and with the brief of <rev> extracted by git archive, and compares
# stdout, stderr and the exit status, once in the caller's locale and once in LC_ALL=C: 28
# comparisons. The reference is rendered every time and no expected output is committed, so
# there is nothing here to go stale or to be edited into agreement.
#
# The worktree is found by git, not by where this script sits: whoever reviews a later task
# runs the copy from origin/main against the branch, so that a branch cannot weaken the
# matrix that judges it.
#
# Exit 0: no difference. 1: some. 2: the matrix itself cannot be trusted — <rev> is not an
# ancestor of HEAD (a branch behind would show another pull request's change as its own), a
# case did not render on the <rev> side, or nothing could be set up. A matrix that renders
# nothing is identical to everything, so a case with fewer than 20 lines of stdout on the
# reference side stops it.
#
# No network and no fetch: <rev> has to be known to this repository already.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/scratch.sh
. "$SCRIPT_DIR/scratch.sh"

rev=${1:-origin/main}
top=$(git rev-parse --show-toplevel) || { echo "brief-equivalence: not in a git worktree" >&2; exit 2; }
git rev-parse --verify -q "$rev^{commit}" >/dev/null || { echo "brief-equivalence: no such revision: $rev" >&2; exit 2; }
git merge-base --is-ancestor "$rev" HEAD || {
  echo "brief-equivalence: $rev is not an ancestor of HEAD — catch up with it first, or the" >&2
  echo "difference of another pull request would be read as this one's" >&2
  exit 2
}

ola_scratch brief-equivalence
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT

# The reference: what <rev> holds of the brief and of what it reads.
REF=$WORK/ref
mkdir "$REF"
parts="bin hooks schema"
git cat-file -e "$rev:brief" 2>/dev/null && parts="$parts brief"
# shellcheck disable=SC2086
git archive "$rev" $parts | tar -x -C "$REF" || { echo "brief-equivalence: cannot extract $rev" >&2; exit 2; }

HOME_DIR=$WORK/home
CASES=$WORK/cases
mkdir -p "$HOME_DIR" "$CASES"

# --- The profiles -------------------------------------------------------------------------
# F: every key declared.
read -r -d '' F <<'JSON'
{
  "language": {"human": "fr", "artifacts": "de", "agents": "en"},
  "base_branch": "trunk",
  "check": {"full": "just check", "affected": "just check-affected {slot}", "cleanup": "just clean {slot}"},
  "slots": {"var": "PORT_SLOT", "developers": [1, 2, 3], "reviewer": [8, 9]},
  "pr": {"max_lines": 400, "exclude": ["*.lock", "dist/**"], "title": "free"},
  "merge": {"required_checks": ["lint", "tests"], "review_status": "reviewed",
            "sensitive_paths": [".github/**", "infra/**"], "sensitive_patterns": ["AKIA[0-9A-Z]{16}"]},
  "security": {"paths": ["back/auth/**", "Dockerfile*"]},
  "commands": [{"cmd": "eas", "allow_args": "^build", "reason": "only builds"},
               {"cmd": "make", "deny_args": "deploy"},
               {"cmd": "scalingo", "allow_args": "^logs"}],
  "db_hosts_allowed": ["localhost", "127.0.0.1"],
  "context": {"product": "docs/product.md", "architecture": "docs/architecture.md",
              "review_checklist": "docs/review.md", "security_precedents": "docs/security.md",
              "glossary": "docs/glossary.md", "design": "ui/designs/"},
  "verify_ui": {"kind": "ios-simulator", "up": "make sim-up {slot}", "shot": "make sim-shot"},
  "preview": {"up": "make web-up {slot}", "url": "http://localhost:30{slot}/", "down": "make web-down {slot}"},
  "escalation_extra": ["changing the billing provider", "anything under legal/"]
}
JSON

full() { # full <mode> <github_tokens> → F with those two keys
  printf '%s' "$F" | jq -c --arg m "$1" --arg t "$2" '. + {mode: $m, github_tokens: $t}'
}

# C11: declared empty is not absent, anywhere.
read -r -d '' EMPTIES <<'JSON'
{"mode":"integrated","base_branch":"main","check":{"full":"","affected":"","cleanup":""},"slots":{"developers":[],"reviewer":[]},"pr":{"exclude":[]},"merge":{"required_checks":[],"sensitive_paths":[]},"security":{"paths":[]},"commands":[],"db_hosts_allowed":[],"context":{"design":""},"escalation_extra":[],"verify_ui":{"kind":""},"preview":{"up":"","url":"","down":""}}
JSON

# C12: / & \ {{ %s {slot} $ in values, and allow_args and reason empty, which jq holds true.
read -r -d '' TRAPS <<'JSON'
{"mode":"integrated","base_branch":"rel/1&2","check":{"full":"make A='a&b' B=\\1 C={{x}} D=%s/{slot}","cleanup":"{{#x}}y{{/x}}"},"commands":[{"cmd":"a&b\\c{{d}}","allow_args":""},{"cmd":"e","deny_args":"x","reason":""}],"context":{"product":"docs/{{p}}&.md","design":"de\\sign/"},"verify_ui":{"kind":"playwright","test":"t {{t}}","down":"d"},"escalation_extra":["-n {{name}} & \\0","$HOME/{{/x}}"]}
JSON

# --- The cases ----------------------------------------------------------------------------
IDS=()      # C01 ... C14
SLUGS=()    # integrated-defaults ...
DIRS=()

# mkrepo <code> <slug> [noremote] → a repository with one empty commit, in $REPO_DIR
mkrepo() {
  REPO_DIR=$CASES/$2
  mkdir -p "$REPO_DIR/.claude"
  git -C "$REPO_DIR" -c init.defaultBranch=main init -q
  git -C "$REPO_DIR" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false \
    commit -q --allow-empty -m init
  if [ "${3-}" != noremote ]; then
    local lower
    lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    git -C "$REPO_DIR" remote add origin "https://github.com/acme/$lower.git"
  fi
  IDS+=("$1")
  SLUGS+=("$2")
  DIRS+=("$REPO_DIR")
}
profile() { printf '%s\n' "$1" >"$REPO_DIR/.claude/workflow.json"; }

mkrepo C01 integrated-defaults noremote
profile '{"mode":"integrated"}'
mkrepo C02 integrated-origin-head
profile '{"mode":"integrated"}'
git -C "$REPO_DIR" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
mkrepo C03 integrated-full-keychain
profile "$(full integrated keychain)"
mkrepo C04 integrated-full-off
profile "$(full integrated off)"
mkrepo C05 discreet-defaults
profile '{"mode":"discreet"}'
mkrepo C06 discreet-full-keychain
profile "$(full discreet keychain)"
mkrepo C07 discreet-full-off
profile "$(full discreet off)"
mkrepo C08 discreet-user-scope
rm -r "${REPO_DIR:?}/.claude"
mkdir -p "$HOME_DIR/.claude/workflow-profiles/github.com/acme/c08"
printf '%s\n' '{"mode":"discreet","base_branch":"main"}' >"$HOME_DIR/.claude/workflow-profiles/github.com/acme/c08/profile.json"
mkrepo C09 preview-partial
profile '{"mode":"integrated","preview":{"up":"make web-up","url":"http://localhost:3000/"}}'
mkrepo C10 schema-invalid
profile '{"mode":"other","pr":{"maxlines":5},"unknown":1}'
mkrepo C11 declared-empty
profile "$EMPTIES"
mkrepo C12 trap-values
profile "$TRAPS"
mkrepo C13 no-profile
rmdir "$REPO_DIR/.claude"
mkrepo C14 unreadable
profile '[1,2]'

# --- Rendering and comparing ----------------------------------------------------------------
# render <brief> <dir> <locale: caller|C> <prefix> → <prefix>.out, .err, .rc
# HOME is the same for both briefs: the user-scope profile and the memory path depend on it.
render() {
  local brief=$1 dir=$2 locale=$3 prefix=$4
  if [ "$locale" = C ]; then
    HOME=$HOME_DIR LC_ALL=C "$brief" "$dir" >"$prefix.out" 2>"$prefix.err"
  else
    HOME=$HOME_DIR "$brief" "$dir" >"$prefix.out" 2>"$prefix.err"
  fi
  echo $? >"$prefix.rc"
}

compared=0
different=0
untrusted=0
OUTPUT=$WORK/runs
mkdir "$OUTPUT"

i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
  id=${IDS[$i]}
  slug=${SLUGS[$i]}
  dir=${DIRS[$i]}
  i=$((i + 1))
  for locale in caller C; do
    base=$OUTPUT/$id-$locale
    render "$REF/bin/ola-workflow-brief" "$dir" "$locale" "$base.ref"
    render "$top/bin/ola-workflow-brief" "$dir" "$locale" "$base.new"

    # The witness: what the reference rendered has to be a brief, or a refusal.
    rc=$(cat "$base.ref.rc")
    lines=$(wc -l <"$base.ref.out" | tr -d ' ')
    case $id in
      C13 | C14)
        if [ "$rc" != 1 ] || [ ! -s "$base.ref.err" ]; then
          echo "brief-equivalence: $id ($locale) did not refuse on $rev: exit $rc, $(wc -c <"$base.ref.err" | tr -d ' ') bytes on stderr" >&2
          untrusted=1
        fi
        ;;
      *)
        if [ "$lines" -lt 20 ]; then
          echo "brief-equivalence: $id ($locale) rendered only $lines lines on $rev (exit $rc): the matrix would see nothing" >&2
          untrusted=1
        fi
        ;;
    esac

    compared=$((compared + 1))
    this=0
    for part in out err rc; do
      if ! cmp -s "$base.ref.$part" "$base.new.$part"; then
        if [ "$this" = 0 ]; then
          echo "== $id $slug ($locale) differs"
        fi
        this=1
        diff -u -L "$rev $id $locale $part" -L "worktree $id $locale $part" "$base.ref.$part" "$base.new.$part"
      fi
    done
    different=$((different + this))
  done
done

echo "$compared comparisons, $different different"
[ "$untrusted" = 0 ] || exit 2
[ "$different" = 0 ]
