#!/usr/bin/env bash
# What docs/discreet-mode.md promises and the code does: the page names the profile path, the
# memory path, the mode key and the identity remotes; it carries the only table of
# integrated / discreet; it does not call "refused" what nothing refuses, and it quotes the
# brief on that; and the reproducible part of the clean-repository rule holds — a discreet
# brief and a profile directory leave `git status --porcelain` as it was.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/scratch.sh
. "$ROOT/scripts/scratch.sh"

failures=0
total=0
ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

PAGE=$ROOT/docs/discreet-mode.md

need() { # need <label> <fixed string>
  if [ -f "$PAGE" ] && grep -qF -- "$2" "$PAGE"; then
    ok "discreet page: $1"
  else
    ko "discreet page: $1 is missing from docs/discreet-mode.md (looked for '$2')"
  fi
}
# shellcheck disable=SC2088  # the page prints a literal ~, and grep -F looks for that very text
need "the profile's path" '~/.claude/workflow-profiles/<host>/<owner>/<repo>/profile.json'
need "the memory's path" 'runs/<slug>/'
need "the mode key" '"mode": "discreet"'
need "the identity, upstream" 'git remote get-url upstream'
need "the identity, then origin" 'git remote get-url origin'
need "why the user's profile wins" '**Your profile wins**'
need "the skill that writes the profile" '/ola-workflow:workflow-init'
need "the question it asks" 'whose project is this?'
need "the table" '|  | integrated | discreet |'
need "the Conventions row, said as the code does" 'Nothing reads the project'

# One fact, one page: the table is in exactly one file of docs/ and the README.
holders=$(grep -rlF -- '|  | integrated | discreet |' "$ROOT/docs" "$ROOT/README.md" 2>/dev/null |
  grep -v '/docs/design/' | sed "s#^$ROOT/##" | sort | tr '\n' ' ')
if [ "$holders" = "docs/discreet-mode.md " ]; then
  ok "the integrated / discreet table is in docs/discreet-mode.md and nowhere else"
else
  ko "the integrated / discreet table is held by: '$holders'"
fi

# The page claims no roadmap and no real-world verification (decisions of 2026-11-02).
if grep -qiE 'roadmap|not here yet|coming soon' "$PAGE" 2>/dev/null; then
  ko "discreet page: it holds a roadmap"
else
  ok "discreet page: no roadmap"
fi
need "no claim of real-world verification, stated" 'does not claim that a real contribution'

# "refused" is true of a merge and a commit status only: nothing refuses the rest. A line of
# the page may say refused / refuses only in one of the sentences below, which are the
# true ones; take them out and no "refus" may remain. A line about issues or labels that
# merely mentions the merge is not exempt.
allowed='nothing refuses|that github refuses|github refuses it to every role|what github refuses'
allowed="$allowed|refuse two operations whatever the mode: merging a pull request|those two are refused to"
bad=$(grep -niE 'refus' "$PAGE" 2>/dev/null | tr '[:upper:]' '[:lower:]' |
  sed -E "s/($allowed)//g" | grep -E 'refus' || true)
if [ -z "$bad" ]; then
  ok "discreet page: it says refused only in the sentences about the merge and the status, or in the negative"
else
  ko "discreet page: a line says refused outside those sentences: $bad"
fi
# The page does not state as fact what its own table calls a rule.
if grep -qiE 'writes nothing on the forge' "$PAGE" 2>/dev/null; then
  ko "discreet page: it states as fact that nothing is written on the forge"
else
  ok "discreet page: it does not state as fact that nothing is written on the forge"
fi
# The table's Writes row must not carry the word without the negation.
row=$(grep -F '| Writes to GitHub |' "$PAGE" 2>/dev/null || true)
case $row in
  *'**refused**'*) ko "discreet page: the Writes row still says refused" ;;
  *'nothing refuses them'*) ok "discreet page: the Writes row says nothing refuses them" ;;
  *) ko "discreet page: the Writes row does not say that nothing refuses them" ;;
esac

# --- What the brief says, and the page quotes ------------------------------------------
ola_scratch discreet-mode
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT
export HOME=$WORK/home
mkdir -p "$HOME"
unset GH_TOKEN GITHUB_TOKEN

repo=$WORK/repo
mkdir -p "$repo"
git -C "$repo" -c init.defaultBranch=main init -q
git -C "$repo" remote add origin https://github.com/someone/their-repo.git
git -C "$repo" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
pdir=$HOME/.claude/workflow-profiles/github.com/someone/their-repo
mkdir -p "$pdir"
printf '%s\n' '{"mode": "discreet", "base_branch": "main"}' >"$pdir/profile.json"

before=$(git -C "$repo" status --porcelain)
brief=$("$ROOT/bin/ola-workflow-brief" "$repo" 2>&1)
dir=$("$ROOT/bin/ola-profile" -C "$repo" dir 2>&1)
after=$(git -C "$repo" status --porcelain)

if [ "$dir" = "$pdir" ]; then
  ok "ola-profile dir is the profile directory the page names"
else
  ko "ola-profile dir answered '$dir', expected '$pdir'"
fi
case $brief in
  *"$pdir/runs/<slug>/"*) ok "the brief puts the memory under <profile directory>/runs/<slug>/" ;;
  *) ko "the brief does not name $pdir/runs/<slug>/" ;;
esac
if [ -z "$before" ] && [ "$before" = "$after" ] && [ ! -e "$repo/.claude" ]; then
  ok "a discreet brief leaves the repository as it found it (git status --porcelain unchanged)"
else
  ko "git status changed: before '$before', after '$after'"
fi

# The page cites the brief's own sentences on what nothing refuses. If the brief changes
# them, the page must follow.
case $brief in
  *'nothing refuses'*|*'Nothing refuses'*) ok "the brief says nothing refuses the rest" ;;
  *) ko "the brief no longer says that nothing refuses the rest of what discreet mode forbids" ;;
esac
case $brief in
  *'silence is not permission, you are the'*) ok "the brief says silence is not permission" ;;
  *) ko "the brief no longer says silence is not permission" ;;
esac
need "the brief's sentence, cited" 'silence is not permission, you are the enforcement'
need "the brief's sentence on the rest, cited" '*nothing refuses* it'

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total discreet mode test(s) failed"
  exit 1
fi
echo "all $total discreet mode tests passed"
