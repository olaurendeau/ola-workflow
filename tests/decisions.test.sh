#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
#   SC2015, `A && ok || ko`: ok() only counts and prints, so ko() cannot run after a passing test.
#   SC2016: the backticks in single quotes below are the Markdown being tested, not a command.
# The decision journal under docs/decisions/: one file per decision, named NNNN-short-title.md,
# six sections in a fixed order, a status that is one of three values, and an index that lists
# every entry and whose links resolve.
#
# Each refusal is proved on a throwaway tree first. On the real tree a clean verdict is also
# what a check that reads nothing prints, so the fixtures say the check can fail, and a
# witness beside the real run says it read something.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/scratch.sh
. "$ROOT/scripts/scratch.sh"

failures=0
total=0
ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

ola_scratch decisions
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT

SECTIONS='Status|Date|Context|Decision|Consequences|Evidence'
# Where a link may point from an entry. The live README is not one of them: its sections move,
# and an entry is never rewritten, so a link there rots without anyone being able to fix it.
# An entry cites a version of the CHANGELOG, a pull request, an issue, or the README at a
# commit, which is an absolute address and does not move.

# section_lines <file> <name> → the non-blank lines of one section, outside code fences
section_lines() {
  awk -v want="$2" '
    /^```/ { fence = !fence }
    !fence && /^## / { cur = substr($0, 4); next }
    cur == want && NF { print }
  ' "$1"
}
# headings_of <file> → the "## " headings in order, outside code fences, one per line
headings_of() {
  awk '/^```/ { fence = !fence } !fence && /^## / { print substr($0, 4) }' "$1"
}

# decision_problems <dir> → one line per defect; `no-dir` / `no-index` / `no-entry` when there
# is nothing to read, which is a failure and not a pass.
decision_problems() {
  local d=$1 f base n seen="" heads want status date target idx row count=0
  [ -d "$d" ] || { echo "no-dir"; return; }
  idx=$d/README.md
  [ -f "$idx" ] || { echo "no-index"; return; }
  for f in "$d"/*.md; do
    [ -f "$f" ] || continue
    base=${f##*/}
    [ "$base" = README.md ] && continue
    count=$((count + 1))
    if ! printf '%s\n' "$base" | grep -qE '^[0-9]{4}-[a-z0-9]+(-[a-z0-9]+)*\.md$'; then
      echo "$base: the name is not NNNN-short-title.md"
      continue
    fi
    n=${base%%-*}
    case " $seen " in
      *" $n "*) echo "$base: the number $n is used twice" ;;
    esac
    seen="$seen $n"

    heads=$(headings_of "$f" | tr '\n' '|')
    want="$SECTIONS|"
    if [ "$heads" != "$want" ]; then
      echo "$base: the sections are '${heads%|}', not '$SECTIONS' in that order"
      continue
    fi
    for s in Status Date Context Decision Consequences Evidence; do
      [ -n "$(section_lines "$f" "$s")" ] || echo "$base: the $s section is empty"
    done

    status=$(section_lines "$f" Status | head -n 1)
    case $status in
      accepted | rejected) ;;
      "superseded by "[0-9][0-9][0-9][0-9])
        target=${status#superseded by }
        if ! ls "$d/$target"-*.md >/dev/null 2>&1; then
          echo "$base: superseded by $target, and no such entry exists"
        fi
        ;;
      *) echo "$base: the status '$status' is not accepted, rejected or superseded by NNNN" ;;
    esac

    date=$(section_lines "$f" Date | head -n 1)
    if ! printf '%s\n' "$date" | grep -qE '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'; then
      echo "$base: the date '$date' is not YYYY-MM-DD"
    fi

    # An entry is evidence-backed or it is not written: a pull request, an issue, a version of
    # the CHANGELOG, or an address.
    if ! section_lines "$f" Evidence | grep -qE 'https?://|CHANGELOG\.md#|#[0-9]+'; then
      echo "$base: the Evidence cites no pull request, issue, CHANGELOG version or address"
    fi
    if grep -qE '\]\((\.\./)*README\.md' "$f"; then
      echo "$base: links to the live README, whose sections move"
    fi

    # The index: the entry is listed, its link resolves, and its row says what the entry says.
    row=$(grep -F "($base)" "$idx" | head -n 1)
    if [ -z "$row" ]; then
      echo "$base: is not in the index"
    else
      case $row in *"| $status |"*) ;; *) echo "$base: the index row does not say the status '$status'" ;; esac
      case $row in *"| $date |"*) ;; *) echo "$base: the index row does not say the date '$date'" ;; esac
    fi
  done
  [ "$count" -gt 0 ] || { echo "no-entry"; return; }

  # Every link of the index resolves to a file of the directory.
  while IFS= read -r target; do
    [ -f "$d/$target" ] || echo "README.md: the link '$target' points at no file"
  done < <(grep -oE '\]\([^)#:]+\.md\)' "$idx" | sed 's/^](//; s/)$//')
}

# --- A tree that is right, and each way to make it wrong ------------------------------
good=$WORK/good
mkdir -p "$good"
write_entry() { # write_entry <dir> <file> <status> <date> [evidence]
  cat >"$1/$2" <<EOF
# A decision

## Status

$3

## Date

$4

## Context

Something had to be settled.

## Decision

The project settles it this way.

## Consequences

It costs a little and allows a lot.

## Evidence

${5:-[Pull request 1](https://github.com/example/repo/pull/1)}
EOF
}
write_index() { # write_index <dir> <file> <status> <date>... — one row per triple
  local dir=$1
  shift
  {
    echo '# Decisions'
    echo
    echo '## When to write an entry'
    echo
    echo 'When a pull request changes a boundary.'
    echo
    echo '| number | title | status | date |'
    echo '|---|---|---|---|'
    while [ "$#" -ge 3 ]; do
      echo "| [${1%%-*}]($1) | A decision | $2 | $3 |"
      shift 3
    done
  } >"$dir/README.md"
}
reset() { rm -rf "$good" && mkdir -p "$good"; }
good_tree() {
  reset
  write_entry "$good" 0001-first.md accepted 2026-10-19
  write_entry "$good" 0002-second.md "superseded by 0003" 2026-10-20
  write_entry "$good" 0003-third.md accepted 2026-10-21
  write_index "$good" 0001-first.md accepted 2026-10-19 0002-second.md "superseded by 0003" 2026-10-20 0003-third.md accepted 2026-10-21
}

expect() { # expect <label> <pattern> — the fixture in $good is reported with that pattern
  local got
  got=$(decision_problems "$good")
  case $got in
    *$2*) ok "decisions: $1" ;;
    *) ko "decisions: $1 (got '$(printf '%s' "$got" | tr '\n' '|')')" ;;
  esac
}

good_tree
got=$(decision_problems "$good")
if [ -z "$got" ]; then
  ok "decisions: a tree of three entries, one superseded, with a complete index, has no defect"
else
  ko "decisions: the good fixture is refused: $(printf '%s' "$got" | tr '\n' '|')"
fi

good_tree
sed -i.bak 's/^## Date$/## When/' "$good/0001-first.md" && rm -f "$good/0001-first.md.bak"
expect "a section renamed is reported" "0001-first.md: the sections are"

good_tree
{ printf '# A decision\n\n## Status\n\naccepted\n\n## Date\n\n2026-10-19\n\n## Decision\n\nx\n\n## Context\n\nx\n\n'; printf '## Consequences\n\nx\n\n## Evidence\n\n[p](https://example.com/pull/1)\n'; } >"$good/0001-first.md"
expect "two sections out of order are reported" "0001-first.md: the sections are"

good_tree
printf '\n## Notes\n\nmore\n' >>"$good/0001-first.md"
expect "a seventh section is reported" "0001-first.md: the sections are"

good_tree
write_entry "$good" 0001-first.md maybe 2026-10-19
expect "a status that is not one of the three is reported" "the status 'maybe' is not accepted"

good_tree
write_entry "$good" 0001-first.md "superseded by 0009" 2026-10-19
write_index "$good" 0001-first.md "superseded by 0009" 2026-10-19 0002-second.md "superseded by 0003" 2026-10-20 0003-third.md accepted 2026-10-21
expect "a superseded by that names no entry is reported" "superseded by 0009, and no such entry exists"

good_tree
write_entry "$good" 0001-first.md accepted 2026-13-01
expect "a date that is not a date is reported" "the date '2026-13-01' is not YYYY-MM-DD"

good_tree
write_entry "$good" 0001-first.md accepted "19 October 2026"
expect "a date in words is reported" "the date '19 October 2026' is not YYYY-MM-DD"

good_tree
write_entry "$good" 0001-first.md accepted 2026-10-19 "Because we said so."
expect "an Evidence that cites nothing is reported" "the Evidence cites no pull request"

good_tree
write_entry "$good" 0001-first.md accepted 2026-10-19 "[the README](../../README.md#section)"
expect "a link to the live README is reported" "links to the live README"

good_tree
write_entry "$good" 0001-first.md accepted 2026-10-19 "See [the README at a commit](https://github.com/o/r/blob/0123456789abcdef0123456789abcdef01234567/README.md#L1)."
if [ -z "$(decision_problems "$good")" ]; then
  ok "decisions: the README at a commit, an absolute address, is allowed as Evidence"
else
  ko "decisions: the README at a commit is refused: $(decision_problems "$good" | tr '\n' '|')"
fi

good_tree
write_entry "$good" 0004-fourth.md accepted 2026-10-22
expect "an entry missing from the index is reported" "0004-fourth.md: is not in the index"

good_tree
write_index "$good" 0001-first.md accepted 2026-10-19 0002-second.md "superseded by 0003" 2026-10-20 0003-third.md accepted 2026-10-21 0007-ghost.md accepted 2026-10-22
expect "an index link that resolves to no file is reported" "README.md: the link '0007-ghost.md' points at no file"

good_tree
write_index "$good" 0001-first.md rejected 2026-10-19 0002-second.md "superseded by 0003" 2026-10-20 0003-third.md accepted 2026-10-21
expect "an index row whose status differs from the entry's is reported" "the index row does not say the status 'accepted'"

good_tree
write_index "$good" 0001-first.md accepted 2026-01-01 0002-second.md "superseded by 0003" 2026-10-20 0003-third.md accepted 2026-10-21
expect "an index row whose date differs from the entry's is reported" "the index row does not say the date '2026-10-19'"

good_tree
mv "$good/0002-second.md" "$good/0001-again.md"
expect "a number used twice is reported" "the number 0001 is used twice"

good_tree
cp "$good/0003-third.md" "$good/3-third.md"
expect "a name without four digits is reported" "3-third.md: the name is not NNNN-short-title.md"

good_tree
cp "$good/0003-third.md" "$good/0004-Third_One.md"
expect "a name with capitals or underscores is reported" "0004-Third_One.md: the name is not"

good_tree
rm "$good/README.md"
[ "$(decision_problems "$good")" = no-index ] && ok "decisions: a directory without an index is a failure" || ko "decisions: a directory without an index is not reported"

reset
write_index "$good"
[ "$(decision_problems "$good")" = no-entry ] && ok "decisions: an index with no entry is a failure" || ko "decisions: an index with no entry is not reported"

[ "$(decision_problems "$WORK/absent")" = no-dir ] && ok "decisions: an absent directory is a failure" || ko "decisions: an absent directory is not reported"

# --- The real tree --------------------------------------------------------------------
REAL=$ROOT/docs/decisions
entries=0
for f in "$REAL"/[0-9][0-9][0-9][0-9]-*.md; do [ -f "$f" ] && entries=$((entries + 1)); done
if [ "$entries" -gt 0 ]; then
  ok "decisions: the real journal was read ($entries entries)"
else
  ko "decisions: the real journal holds no entry, so a clean verdict means nothing"
fi

problems=$(decision_problems "$REAL")
if [ -z "$problems" ]; then
  ok "decisions: every entry of docs/decisions/ is well formed, listed in the index, and every index link resolves"
else
  while IFS= read -r p; do ko "decisions: $p"; done <<EOF
$problems
EOF
fi

# The first thirteen are the decisions this project already held when the journal began.
missing=""
n=1
while [ "$n" -le 13 ]; do
  num=$(printf '%04d' "$n")
  ls "$REAL/$num"-*.md >/dev/null 2>&1 || missing="$missing $num"
  n=$((n + 1))
done
if [ -z "$missing" ]; then
  ok "decisions: entries 0001 to 0013, the decisions taken before the journal, are all there"
else
  ko "decisions: no entry for$missing"
fi

# The rule for when to write one is at the head of the index, before the first row.
if awk '/^\|/ { exit 1 } /When to write an entry/ { found = 1 } END { exit !found }' "$REAL/README.md" 2>/dev/null; then
  ok "decisions: the index states when to write an entry, before its first row"
else
  ko "decisions: the index does not state when to write an entry before its first row"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total decisions test(s) failed"
  exit 1
fi
echo "all $total decisions tests passed"
