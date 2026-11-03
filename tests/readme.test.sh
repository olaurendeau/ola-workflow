#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
#   SC2015, `A && ok || ko`: ok() only counts and prints, so ko() cannot run after a passing test.
#   SC2016: the backticks in single quotes below are the Markdown being tested, not a command.
# The README's "How it works" section is what a reader meets first. What the repository can
# check about it: it comes right before "Quickstart"; its steps name the roles in the order the
# workflow runs them; its diagram is made of roles that are files in agents/ (the human is
# no box); it lists the decisions that belong to the human under the headings the brief
# prints, read from the brief and not copied here; it names the two acts GitHub refuses and
# links the pages it relies on; it stays short and has no subsection.
#
# The README as a whole is checked below the same way: at most 140 lines; the pitch word for
# word; the sections in order; at most six commands in the quickstart; the nine rows of
# "Where to go next" as the epic wrote them; a short Status; no roles list, no history, no
# version. Whether a stranger understands it after reading is judged by a person: the pull
# request that finalised the README says so.
#
# The helpers that read the README (section, steps, nodes) are proved first on a throwaway
# fixture, where they can fail; so are the length limit and the diagram's boxes. The other
# checks read the real README, where a clean verdict is also what a scan that reads nothing
# prints: a witness says each scan read something.
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

# nodes <file> → the label of each node of the diagram, one per line, sorted. A node is an id
# followed by a shape: id[label], id(label), id((label)) or id{label}.
nodes() {
  diagram "$1" | grep -oE '[A-Za-z0-9_]+(\[[^]]*\]|\(+[^)]*\)+|\{+[^}]*\}+)' |
    sed -E 's/^[A-Za-z0-9_]+[[({]+//; s/[])}]+$//' | sort -u
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
for shape in 'hu((you))' 'hu(you)' 'hu{you}' 'hu([you])'; do
  sed "s/^  co\[coordinator\]/  co[coordinator] --> $shape\n  co[coordinator]/" "$good" >"$WORK/shape.md"
  nodes "$WORK/shape.md" | grep -qx 'you' &&
    ok "a human box written $shape is read as a node too" ||
    ko "a human box written $shape escapes the comparison with agents/"
done

# --- The real README ---------------------------------------------------------------------
SEC=$(section "$README")
[ -n "$SEC" ] && ok "witness: the section exists and is not empty" || ko "the README has no '## How it works' section"

# C0.1: right before the quickstart, and the steps are the roles in order.
how=$(grep -n '^## How it works' "$README" | head -1 | cut -d: -f1)
quickstart=$(grep -n '^## Quickstart' "$README" | head -1 | cut -d: -f1)
if [ -n "$how" ] && [ -n "$quickstart" ] && [ "$how" -lt "$quickstart" ]; then
  ok "How it works comes before Quickstart"
else
  ko "How it works (line '${how:-none}') does not come before Quickstart (line '${quickstart:-none}')"
fi
# Tightened: the section ends where the quickstart begins, nothing between.
[ -n "$quickstart" ] && [ "$(awk '/^## / { n++; if (n == 2) { print $0; exit } }' "$README")" = "## Quickstart" ] &&
  [ "$(awk '/^## / { n++; if (n == 1) { print $0; exit } }' "$README")" = "## How it works" ] &&
  ok "no section stands between How it works and Quickstart" ||
  ko "something stands between How it works and Quickstart"
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

# C0.4: where the memory is, with a link; for a repository that is not yours, discreet mode.
printf '%s\n' "$SEC" | grep -qE '\]\(docs/configuration\.md[^)]*\)' &&
  ok "the section links the page that says where the memory lives" || ko "no link to docs/configuration.md"
printf '%s\n' "$SEC" | grep -qE '\]\(docs/discreet-mode\.md[^)]*\)' &&
  ok "the section links the page for a repository that is not yours" || ko "no link to docs/discreet-mode.md"

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

# The two things a stranger would get wrong: who merges, and the steps a change may skip.
printf '%s\n' "$SEC" | grep -qi 'You merge instead' && printf '%s\n' "$SEC" | grep -qi 'nobody' &&
  ok "the section says when the human merges and when nobody does" ||
  ko "the section does not say when the human merges, or when nobody does"
# One word, one list: "sensitive" names the paths the human merges in the profile, and the
# paths that get a security review are another list, so the section must not use it for both.
! printf '%s\n' "$SEC" | grep -qi 'sensitive' &&
  ok "the section does not call either path list 'sensitive'" ||
  ko "the section says 'sensitive', which names two different lists"
printf '%s\n' "$SEC" | grep -qiw 'spec' &&
  ko "the section says 'spec', where the rest of the repository says 'epic'" ||
  ok "the section says 'epic', not 'spec'"
printf '%s\n' "$SEC" | grep -qiE 'skips steps? [0-9]' &&
  ok "the section says which steps a change may skip" || ko "the section does not say which steps may be skipped"

# C0.8: the example stays in the walkthrough: linked, not copied.
printf '%s\n' "$SEC" | grep -qE '\]\(docs/walkthrough\.md[^)]*\)' &&
  ok "the section links docs/walkthrough.md" || ko "no link to docs/walkthrough.md"
if printf '%s\n' "$SEC" | grep -qE '^Example:|^Example$|Add a filter'; then
  ko "the section copies the walkthrough's example"
else
  ok "the section does not copy the walkthrough's example"
fi

# --- The README as a whole -----------------------------------------------------------------
# What a reader meets: the pitch, then four sections in a fixed order, in at most 140 lines.
MAX_README=140
MAX_STATUS=15
MAX_QUICKSTART_COMMANDS=6
MAX_TABLE=8

# part <file> <heading> → the lines of "## <heading>", up to the next "## " heading.
part() {
  awk -v h="## $2" '$0 == h { on = 1; print; next } on && /^## / { exit } on { print }' "$1"
}

# headings <file> → the "## " headings outside code blocks, in order, joined with `|`.
headings() {
  awk '/^```/ { code = !code } !code && /^## / { sub(/^## /, ""); print }' "$1" | paste -sd'|' -
}

# pitch <file> → the paragraphs between the title and the first "## " heading, each joined
# into one line with single spaces.
pitch() {
  awk '
    /^# / && !seen { seen = 1; next }
    /^## / { exit }
    NF { buf = buf (buf == "" ? "" : " ") $0; next }
    buf != "" { print buf; buf = "" }
    END { if (buf != "") print buf }
  ' "$1" | sed -E 's/  +/ /g'
}

# commands <file> <heading> → the lines of the fenced blocks of a section that are neither
# blank nor mermaid: what a reader is asked to type.
commands() {
  part "$1" "$2" | awk '
    /^```mermaid/ { skip = 1; next }
    /^```/ { if (skip) { skip = 0; next } code = !code; next }
    code && NF { print }
  '
}

# tables <file> → the rows of each table outside "Where to go next", one number per table,
# header and separator left out. That table is the one decision D3 of the epic exempts from
# the limit: its text is the epic's.
tables() {
  awk '
    /^```/ { code = !code }
    /^## / { exempt = ($0 == "## Where to go next") }
    !code && /^\|/ { if (!intable) { n = 0; intable = 1 } n++; next }
    intable { if (!exempt) print n - 2; intable = 0 }
    END { if (intable && !exempt) print n - 2 }
  ' "$1"
}

cat >"$WORK/pitch.txt" <<'EOF'
Describe a change in plain words, and a team of Claude Code agents takes it from there: it writes down what "done" means, splits the work into pull requests small enough to review, builds them test-first, has each one reviewed by an agent that did not write it, and merges what is safe to merge. You stay in charge of the decisions that are yours: scope, dependencies, releases.
Two things set it apart. **It is enforced where it can be:** merging belongs to the coordinator and the review status to the independent reviewer, and GitHub itself refuses both to every other role. Pushing to the base branch, tagging and publishing are rules the agents carry, not rules GitHub applies — the docs say which is which. And **it is generic:** everything specific to a project lives in a profile file, so the same plugin drives a project you own and a repository you contribute to twice a year, **without committing anything to it**.
It is a Claude Code plugin. A project with no profile is unaffected: the plugin does nothing there, and your own GitHub login is left alone.
EOF
PITCH_EXPECTED=$(cat "$WORK/pitch.txt")

# The nine rows of the epic, word for word.
cat >"$WORK/table.txt" <<'EOF'
| If you want to… | Read |
|---|---|
| Install it and run a first request | [Getting started](docs/getting-started.md) |
| See what happens between a request and a merged pull request | [Walkthrough](docs/walkthrough.md) |
| Contribute to someone else's repository without committing anything to it | [Discreet mode](docs/discreet-mode.md) |
| Configure a project | [Configuration](docs/configuration.md) |
| Know what GitHub enforces and what it does not | [GitHub tokens](docs/github-tokens.md) |
| Know which model each agent runs on | [Models](docs/models.md) |
| Understand why a rule is what it is | [Decision log](docs/decisions/README.md) |
| See how plugin agents are identified, as measured | [Agent identity](docs/agent-identity.md) |
| Work on the plugin itself | [Contributing](docs/contributing.md) |
EOF
TABLE_EXPECTED=$(cat "$WORK/table.txt")

# Fixture: the helpers can fail.
whole=$WORK/whole.md
cat >"$whole" <<'EOF'
# x

First
paragraph.

Second.

## A

```bash
one
two
```

```mermaid
a --> b
```

| h | h |
|---|---|
| 1 | 1 |
| 2 | 2 |

## B

```
three
```

## Where to go next

| h | h |
|---|---|
| 1 | 1 |
| 2 | 2 |
| 3 | 3 |
EOF
[ "$(headings "$whole")" = "A|B|Where to go next" ] && ok "headings reads the sections in order" ||
  ko "headings misreads the fixture: '$(headings "$whole")'"
[ "$(pitch "$whole" | head -1)" = "First paragraph." ] && [ "$(pitch "$whole" | wc -l | tr -d ' ')" = 2 ] &&
  ok "pitch reads a paragraph on one line" || ko "pitch misreads the fixture: '$(pitch "$whole" | tr '\n' '|')'"
[ "$(commands "$whole" A | wc -l | tr -d ' ')" = 2 ] && [ "$(commands "$whole" B | wc -l | tr -d ' ')" = 1 ] &&
  ok "commands counts the lines of the code blocks, mermaid aside" ||
  ko "commands misreads the fixture: A=$(commands "$whole" A | wc -l) B=$(commands "$whole" B | wc -l)"
[ "$(tables "$whole" | tr '\n' ' ')" = "2 " ] &&
  ok "tables measures every table but the exempted one" || ko "tables misreads the fixture: '$(tables "$whole" | tr '\n' ' ')'"
{ echo '# x'; for _ in $(seq 1 141); do echo line; done; } >"$WORK/long-readme.md"
[ "$(wc -l <"$WORK/long-readme.md" | tr -d ' ')" -gt "$MAX_README" ] &&
  ok "fixture: a file of more than $MAX_README lines is measured as over" || ko "fixture: the length is not measured"

# C1.1
n=$(wc -l <"$README" | tr -d ' ')
[ "$n" -le "$MAX_README" ] && ok "the README is $n lines, at most $MAX_README" || ko "the README is $n lines, over $MAX_README"

# C1.2: the three paragraphs after the title are the validated pitch.
[ "$(pitch "$README")" = "$PITCH_EXPECTED" ] && ok "the three paragraphs after the title are the pitch, word for word" ||
  ko "the opening paragraphs differ from the pitch: $(pitch "$README" | cut -c1-80 | tr '\n' '|')"

# C1.3: the four sections after the pitch, in order; the flow right before the quickstart.
[ "$(headings "$README")" = "How it works|Quickstart|Where to go next|Status" ] &&
  ok "the sections are How it works, Quickstart, Where to go next, Status, in that order" ||
  ko "the sections are '$(headings "$README")'"
nq=$(commands "$README" Quickstart | wc -l | tr -d ' ')
[ "$nq" -gt 0 ] && [ "$nq" -le "$MAX_QUICKSTART_COMMANDS" ] &&
  ok "the quickstart asks for $nq commands, at most $MAX_QUICKSTART_COMMANDS" ||
  ko "the quickstart asks for $nq commands, expected 1 to $MAX_QUICKSTART_COMMANDS"
ns=$(part "$README" Status | wc -l | tr -d ' ')
[ "$ns" -gt 1 ] && [ "$ns" -le "$MAX_STATUS" ] && ok "Status is $ns lines, at most $MAX_STATUS" ||
  ko "Status is $ns lines, expected 2 to $MAX_STATUS"

# The quickstart keeps both forms of the install, and does not hand the terminal a command it
# cannot find: the plugin's bin/ is on the PATH of a session's Bash calls only, so the
# quickstart sends the reader to the export line of getting-started.md before the tokens.
QS=$(part "$README" Quickstart)
printf '%s\n' "$QS" | grep -qxF '/plugin install ola-workflow --marketplace olaurendeau/ola-workflow' &&
  ok "the quickstart has the slash form of the install" || ko "the quickstart lacks the slash form of the install"
printf '%s\n' "$QS" | grep -qxF 'claude plugin install ola-workflow --marketplace olaurendeau/ola-workflow' &&
  ok "the quickstart has the shell form of the install" || ko "the quickstart lacks the shell form of the install"
setup_line=$(printf '%s\n' "$QS" | grep -n '^ola-workflow-tokens setup$' | head -1 | cut -d: -f1)
export_line=$(printf '%s\n' "$QS" | grep -n 'getting-started\.md#2-install-the-plugin' | head -1 | cut -d: -f1)
if [ -n "$setup_line" ] && [ -n "$export_line" ] && [ "$export_line" -lt "$setup_line" ] &&
  printf '%s\n' "$QS" | grep -q '`export` line'; then
  ok "the quickstart sends the reader to the PATH line of getting-started.md before the tokens"
else
  ko "the quickstart gives 'ola-workflow-tokens setup' without first pointing at the PATH line (setup at '${setup_line:-none}', pointer at '${export_line:-none}')"
fi

# C1.4: the roles are files of agents/, and probe is a tool, not a role of the flow.
named=$(steps "$README" | tr ' ' '\n' | grep . | sort -u)
missing=$(for r in $named; do [ -f "$ROOT/agents/$r.md" ] || echo "$r"; done)
[ -n "$named" ] && [ -z "$missing" ] && ok "every role the README names is a file of agents/" ||
  ko "roles with no file in agents/: '$missing'"
grep -qiw 'probe' "$README" && ko "the README names probe, a measuring tool and no role" ||
  ok "the README does not present probe as a role"
if part "$README" Status | grep -qiwE 'product-designer|design-reviewer|architect|developers?|pr-reviewer|security-reviewer'; then
  ko "Status lists roles, which How it works already does"
else
  ok "Status does not list the roles"
fi

# C1.5 and C6.4: no history, no number that changes at each release.
if grep -qiE 'since [0-9]+\.|earlier versions|[0-9]+ bugs|fixed [a-z-]+ of them' "$README"; then
  ko "the README tells a fixed defect or the history of a version"
else
  ok "the README tells no history of a version"
fi
if grep -qE '[0-9]+\.[0-9]+\.[0-9]+|Claude Code [0-9]' "$README"; then
  ko "the README carries a version: $(grep -oE '[0-9]+\.[0-9]+\.[0-9]+|Claude Code [0-9][^ ]*' "$README" | head -3 | tr '\n' ' ')"
else
  ok "the README carries no plugin version and no undated Claude Code version"
fi

# C9.6, C8.2: the table is the epic's, row for row.
table=$(part "$README" "Where to go next" | grep '^|')
[ "$table" = "$TABLE_EXPECTED" ] && ok "Where to go next is the epic's table, nine rows, word for word" ||
  ko "Where to go next differs from the epic's table"
# D3: the limit holds for every other table.
over=$(tables "$README" | awk -v m="$MAX_TABLE" '$1 > m')
[ -z "$over" ] && ok "no other table is over $MAX_TABLE rows" || ko "a table has $over rows, over $MAX_TABLE"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures of $total readme tests failed"
  exit 1
fi
echo "all $total readme tests passed"
