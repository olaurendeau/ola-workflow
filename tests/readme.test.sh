#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
#   SC2015, `A && ok || ko`: ok() only counts and prints, so ko() cannot run after a passing test.
#   SC2016: the backticks in single quotes below are the Markdown being tested, not a command.
# The README's "How it works" section is what a reader meets first. What the repository can
# check about it: it comes before "Install"; its steps name the roles in the order the
# workflow runs them; its diagram is made of roles that are files in agents/ (the human is
# no box); it lists the decisions that belong to the human under the headings the brief
# prints, read from the brief and not copied here; it names the two acts GitHub refuses and
# links the pages it relies on; it stays short and has no subsection.
#
# Whether a stranger understands it after reading is judged by a person, in the final README.
#
# Each check is proved first on a throwaway file, where it can fail. On the real README a
# clean verdict is also what a check that reads nothing prints, so a witness says each scan
# read something.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/scratch.sh
. "$ROOT/scripts/scratch.sh"

failures=0
total=0
ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

ola_scratch readme
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT

README=$ROOT/README.md
BRIEF=$ROOT/bin/ola-workflow-brief
MAX_SECTION=45
MAX_DIAGRAM=25

# The roles, in the order the workflow runs them; the coordinator frames, then merges.
EXPECTED="coordinator product-designer design-reviewer architect developer pr-reviewer security-reviewer coordinator"

# section <file> → the lines of "## How it works", up to the next "## " heading.
section() {
  awk '/^## How it works[[:space:]]*$/ { on = 1; print; next } on && /^## / { exit } on { print }' "$1"
}

# steps <file> → the role of each numbered step (`1. **role** — …`), in order, on one line.
steps() {
  section "$1" | sed -nE 's/^[0-9]+\. \*\*([a-z-]+)\*\*.*/\1/p' | tr '\n' ' ' | sed 's/ $//'
}

# diagram <file> → the lines of the first mermaid block of the section.
diagram() {
  section "$1" | awk '/^```mermaid/ { on = 1; next } on && /^```/ { exit } on { print }'
}

# nodes <file> → the role named by each `id[role]` of the diagram, one per line, sorted.
nodes() {
  diagram "$1" | grep -oE '[A-Za-z0-9_]+\[[^]]*\]' | sed -E 's/^[^[]*\[(.*)\]$/\1/' | sort -u
}

# Fixture: a section that is right, then one fault at a time.
good=$WORK/good.md
cat >"$good" <<'EOF'
# x

## How it works

1. **coordinator** — a — b
2. **product-designer** — a — b

```mermaid
flowchart TD
  co[coordinator] --> pd[product-designer]
```

## Install
EOF

[ "$(steps "$good")" = "coordinator product-designer" ] &&
  ok "steps reads the role of each numbered step, in order" ||
  ko "steps misreads the fixture: '$(steps "$good")'"
[ "$(nodes "$good" | tr '\n' ' ')" = "coordinator product-designer " ] &&
  ok "nodes reads the role of each diagram box" ||
  ko "nodes misreads the fixture: '$(nodes "$good" | tr '\n' ' ')'"
[ "$(section "$good" | wc -l | tr -d ' ')" = 10 ] &&
  ok "section stops at the next heading" ||
  ko "section reads $(section "$good" | wc -l | tr -d ' ') lines of a ten-line fixture"
sed 's/^  co\[coordinator\]/  co[coordinator] --> hu[the human]\n  co[coordinator]/' "$good" >"$WORK/human.md"
nodes "$WORK/human.md" | grep -qx 'the human' &&
  ok "a box for the human would be read as a node, so the comparison with agents/ refuses it" ||
  ko "a box for the human is not read as a node"

# --- The real README ---------------------------------------------------------------------
SEC=$(section "$README")
[ -n "$SEC" ] && ok "witness: the section exists and is not empty" || ko "the README has no '## How it works' section"

# C0.1: before the install instructions, and the steps are the roles in order.
how=$(grep -n '^## How it works' "$README" | head -1 | cut -d: -f1)
install=$(grep -n '^## Install' "$README" | head -1 | cut -d: -f1)
if [ -n "$how" ] && [ -n "$install" ] && [ "$how" -lt "$install" ]; then
  ok "How it works comes before Install"
else
  ko "How it works (line '${how:-none}') does not come before Install (line '${install:-none}')"
fi
[ "$(steps "$README")" = "$EXPECTED" ] &&
  ok "the steps are the roles of the workflow, in the order it runs them" ||
  ko "the steps are '$(steps "$README")', expected '$EXPECTED'"

# C0.2: every box of the diagram is a file of agents/, every agent but probe is a box.
files=$(for f in "$ROOT"/agents/*.md; do b=${f##*/}; echo "${b%.md}"; done | grep -vx probe | sort -u)
boxes=$(nodes "$README")
[ -n "$boxes" ] && ok "witness: the diagram has at least one box ($(echo "$boxes" | wc -l | tr -d ' '))" ||
  ko "no box read in the diagram"
if [ "$boxes" = "$files" ]; then
  ok "the diagram's boxes are exactly the files of agents/, probe aside"
else
  ko "boxes '$(echo "$boxes" | tr '\n' ' ')' differ from agents/ '$(echo "$files" | tr '\n' ' ')'"
fi
n=$(diagram "$README" | wc -l | tr -d ' ')
[ "$n" -gt 0 ] && [ "$n" -le "$MAX_DIAGRAM" ] &&
  ok "the diagram is $n lines, at most $MAX_DIAGRAM" || ko "the diagram is $n lines, expected 1 to $MAX_DIAGRAM"

# C0.3: the human's decisions carry the brief's own headings. The brief is run on a
# throwaway profile with no escalation_extra, so its Escalation section is the base list.
proj=$WORK/project
mkdir -p "$proj/.claude"
git -C "$proj" -c init.defaultBranch=main init -q 2>/dev/null
printf '{"mode":"integrated"}\n' >"$proj/.claude/workflow.json"
"$BRIEF" "$proj" >"$WORK/brief.txt" 2>"$WORK/brief.err" || true
headings=$(awk '/^## Escalation/ { on = 1; next } on && /^$/ { exit } on && /^- / { sub(/^- /, ""); sub(/:.*/, ""); print }' "$WORK/brief.txt")
[ -n "$headings" ] && ok "witness: $(echo "$headings" | wc -l | tr -d ' ') headings read from the brief" ||
  ko "no heading read from the brief's Escalation section: $(head -c 200 "$WORK/brief.err")"
echo "$headings" | while IFS= read -r h; do
  [ -n "$h" ] || continue
  if printf '%s\n' "$SEC" | grep -qF -- "- $h:"; then echo "ok    the section lists the decision '$h'"
  else echo "FAIL  the section does not list the brief's decision '$h'"; fi
done >"$WORK/headings.out"
cat "$WORK/headings.out"
nok=$(grep -c '^ok ' "$WORK/headings.out"); nko=$(grep -c '^FAIL ' "$WORK/headings.out")
total=$((total + nok + nko)); failures=$((failures + nko))

# C0.4: where the memory is, with a link.
printf '%s\n' "$SEC" | grep -qE '\]\(docs/configuration\.md[^)]*\)' &&
  ok "the section links the page that says where the memory lives" || ko "no link to docs/configuration.md"

# C0.5: the two acts GitHub refuses, and the link.
printf '%s\n' "$SEC" | grep -qi 'merging' && printf '%s\n' "$SEC" | grep -qi 'review status' &&
  ok "the section names the two acts: merging and the review status" ||
  ko "the section does not name merging and the review status"
printf '%s\n' "$SEC" | grep -qE '\]\(docs/github-tokens\.md[^)]*\)' &&
  ok "the section links docs/github-tokens.md" || ko "no link to docs/github-tokens.md"

# C0.6: short, in one piece.
n=$(printf '%s\n' "$SEC" | wc -l | tr -d ' ')
[ "$n" -le "$MAX_SECTION" ] && ok "the section is $n lines, at most $MAX_SECTION" ||
  ko "the section is $n lines, over $MAX_SECTION"
printf '%s\n' "$SEC" | grep -q '^###' && ko "the section has a subsection" || ok "the section has no subsection"
{ echo '## How it works'; for _ in $(seq 1 50); do echo line; done; } >"$WORK/long.md"
[ "$(section "$WORK/long.md" | wc -l | tr -d ' ')" -gt "$MAX_SECTION" ] &&
  ok "fixture: a section of more than $MAX_SECTION lines is measured as over" ||
  ko "fixture: the length is not measured"

# C0.8: the example stays in the walkthrough: linked, not copied.
printf '%s\n' "$SEC" | grep -qE '\]\(docs/walkthrough\.md[^)]*\)' &&
  ok "the section links docs/walkthrough.md" || ko "no link to docs/walkthrough.md"
if printf '%s\n' "$SEC" | grep -qE '^Example:|^Example$|Add a filter'; then
  ko "the section copies the walkthrough's example"
else
  ok "the section does not copy the walkthrough's example"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures of $total readme tests failed"
  exit 1
fi
echo "all $total readme tests passed"
