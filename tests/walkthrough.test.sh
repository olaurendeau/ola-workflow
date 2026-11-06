#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
#   SC2015, `A && ok || ko`: ok() only counts and prints, so ko() cannot run after a passing test.
#   SC2016: the backticks in single quotes below are the Markdown being tested, not a command.
# docs/walkthrough.md follows one request from the human's sentence to the merged pull
# request. What the repository can check about it: the roles come in the order the workflow
# runs them and each step says what it produces and what the human decides; `probe` (a
# measuring tool, not a role) is not among them; the section on what GitHub refuses names the
# two refusals and what nothing enforces, and links "What it does not stop" rather than
# copying a run of its words; an interrupted step has its section; and nothing in a code
# block is invented — a block opens with a line saying "Example", or each of its lines is
# found in agents/, bin/, brief/ or skills/.
#
# The checks on the page's content (roles, sections, code blocks) are functions proved first
# on a throwaway file, where they can fail; the probe, link and agents/ file checks are inline
# and have no fixture. On the real page a clean verdict is also what a check that reads
# nothing prints, so each scan reports what it read, and a witness beside the real run says
# it read something.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/scratch.sh
. "$ROOT/scripts/scratch.sh"

failures=0
total=0
ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

ola_scratch walkthrough
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT

PAGE=$ROOT/docs/walkthrough.md
TOKENS=$ROOT/docs/github-tokens.md

# The roles, in the order the workflow runs them: coordinator frames and merges, the others
# in between. The page numbers its steps in `## N. role — what it does` headings.
EXPECTED="coordinator product-designer design-reviewer architect developer pr-reviewer security-reviewer coordinator"

# step_roles <page> → the role of each numbered step heading, in the page's order, on one line.
step_roles() {
  sed -n -E 's/^## [0-9]+\. `?([a-z-]+)`? .*/\1/p' "$1" | tr '\n' ' ' | sed 's/ $//'
}

# check_blocks <root> <page> → one BLOCK line per fenced block read, one ERR line per line of a
# block that is neither under an "Example" opener nor found in agents/, bin/, brief/ or skills/.
# A fence is ``` or ~~~, indented or not, closed by the same mark. A line is found as a fixed
# string, leading blanks aside: the page quotes, it does not match patterns. Two things are
# defects of their own, because the check would not read what they hold: a fence never
# closed, which would swallow the rest, and an indented code block, which is no fence.
check_blocks() {
  local root=$1 page=$2 line n=0 inblock=0 first=0 exempt=0 prevblank=1 open="" fence text
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    text=${line#"${line%%[![:space:]]*}"}
    fence=""
    case $text in '```'*) fence='```' ;; '~~~'*) fence='~~~' ;; esac
    if [ -n "$fence" ] && { [ "$inblock" = 0 ] || [ "$fence" = "$open" ]; }; then
      if [ "$inblock" = 1 ]; then
        inblock=0 prevblank=1
      else
        inblock=1 open=$fence first=1 exempt=0
        echo "BLOCK $n"
      fi
      continue
    fi
    if [ "$inblock" = 0 ]; then
      case $line in
        '    '* | $'\t'*) [ "$prevblank" = 1 ] && echo "ERR $n: an indented code block, which is not read: fence it" ;;
      esac
      if [ -z "$text" ]; then prevblank=1; else prevblank=0; fi
      continue
    fi
    [ -n "$text" ] || continue
    if [ "$first" = 1 ]; then
      first=0
      case $text in Example*) exempt=1 ;; esac
    fi
    [ "$exempt" = 1 ] && continue
    grep -rqF -- "$text" "$root/agents" "$root/bin" "$root/brief" "$root/skills" 2>/dev/null ||
      echo "ERR $n: $text"
  done <"$page"
  [ "$inblock" = 0 ] || echo "ERR $n: a fenced block is never closed"
}

# section_text <page> <regex> → the "## " section whose heading starts with the regex, heading
# included, up to the next "## " heading.
section_text() {
  awk -v re="$2" '/^## /{ p = ($0 ~ ("^## " re)) } p' "$1"
}

# step_fields <page> → one STEP line per numbered step, and one ERR line for each of "Produces"
# and "You decide" that a step does not say (C3.2).
step_fields() {
  awk '
    function flush() {
      if (!n) return
      print "STEP " n
      if (!hp) print "ERR " n ": no Produces"
      if (!hd) print "ERR " n ": no You decide"
    }
    /^## / { flush(); n = 0 }
    /^## [0-9]+\. / { n = $2; sub(/\./, "", n); hp = 0; hd = 0 }
    n && /\*\*Produces:\*\*/ { hp = 1 }
    n && /\*\*You decide:\*\*/ { hd = 1 }
    END { flush() }
  ' "$1"
}

# missing_terms <page> <section regex> <term>... → each term the section lacks, one per line
# (case-insensitive, fixed string), or NOSECTION when the page has no such section.
missing_terms() {
  local page=$1 re=$2 sec t
  shift 2
  sec=$(section_text "$page" "$re")
  [ -n "$sec" ] || { echo NOSECTION; return; }
  for t in "$@"; do
    printf '%s\n' "$sec" | grep -qiF -- "$t" || echo "$t"
  done
}

# table_rows <page> <section regex> → how many rows of the section's table have no empty cell,
# header and separator aside.
table_rows() {
  section_text "$1" "$2" | awk -F'|' '
    /^\|/ && !/^\|[-| ]+\|$/ {
      rows++
      for (i = 2; i < NF; i++) if ($i ~ /^[[:space:]]*$/) { rows--; break }
    }
    END { print (rows > 1 ? rows - 1 : 0) }'
}

# copied_run <source> <page> → WORDS n, the words of the source's "What it does not stop"
# section (Markdown marks and line breaks aside), then COPY <run> for the first run of eight
# consecutive words that the page repeats. Eight words is a sentence's worth: a bullet pasted
# in, reflowed or not, is caught; a link and a paraphrase are not.
copied_run() {
  local sec pg
  sec=$(section_text "$1" "What it does not stop" 2>/dev/null | tail -n +2 | tr -d '`*' | tr -s '[:space:]' ' ')
  pg=$(tr -d '`*' <"$2" | tr -s '[:space:]' ' ')
  SEC=$sec PG=$pg awk 'BEGIN {
    n = split(ENVIRON["SEC"], w, " ")
    print "WORDS " n
    for (i = 1; i + 7 <= n; i++) {
      s = w[i]
      for (j = 1; j < 8; j++) s = s " " w[i + j]
      if (index(ENVIRON["PG"], s)) { print "COPY " s; exit }
    }
  }'
}

# --- Fixtures ---------------------------------------------------------------------------
fx=$WORK/fx
mkdir -p "$fx/agents" "$fx/bin" "$fx/skills"
echo 'Status: done | blocked | needs-decision' >"$fx/agents/a.md"
echo '    coordinator  gh pr merge <N> --squash' >"$fx/bin/b"

printf '%s\n' '# t' '```' 'Example' 'anything at all' '```' >"$fx/exempt.md"
got=$(check_blocks "$fx" "$fx/exempt.md")
[ "$got" = "BLOCK 2" ] && ok "a block that opens with an Example line is read and passes whatever it says" ||
  ko "an Example block answered '$got'"

printf '%s\n' '```' 'Status: done | blocked | needs-decision' '  gh pr merge <N> --squash' '```' >"$fx/sourced.md"
got=$(check_blocks "$fx" "$fx/sourced.md")
[ "$got" = "BLOCK 1" ] && ok "a block whose every line is found in agents/ or bin/ passes" ||
  ko "a sourced block answered '$got'"

printf '%s\n' '```' 'Status: done | blocked | needs-decision' 'Merged in 3 seconds, all green' '```' >"$fx/invented.md"
got=$(check_blocks "$fx" "$fx/invented.md")
[ "$got" = "$(printf 'BLOCK 1\nERR 3: Merged in 3 seconds, all green')" ] &&
  ok "a line found nowhere, in a block with no Example opener, is named with its line number" ||
  ko "an invented line answered '$got'"

printf '%s\n' '```' 'Status: done | blocked | needs-decision' 'Example' '```' >"$fx/late.md"
got=$(check_blocks "$fx" "$fx/late.md")
case $got in
  *'ERR 3: Example'*) ok "an Example line that is not the first of the block exempts nothing" ;;
  *) ko "a late Example line answered '$got'" ;;
esac

printf '%s\n' '```' 'Status: done' >"$fx/open.md"
got=$(check_blocks "$fx" "$fx/open.md")
case $got in
  *'never closed'*) ok "a fence that is never closed is a defect, not a block swallowing the page" ;;
  *) ko "an unclosed fence answered '$got'" ;;
esac

printf '%s\n' '~~~' 'Status: done | blocked | needs-decision' 'Merged in 3 seconds, all green' '~~~' >"$fx/tilde.md"
got=$(check_blocks "$fx" "$fx/tilde.md")
[ "$got" = "$(printf 'BLOCK 1\nERR 3: Merged in 3 seconds, all green')" ] &&
  ok 'a ~~~ fence is read like a ``` one' ||
  ko "a tilde fence answered '$got'"

printf '%s\n' '- a list item' '' '  ```' '  Status: done | blocked | needs-decision' '  Merged in 3 seconds, all green' '  ```' >"$fx/indented-fence.md"
got=$(check_blocks "$fx" "$fx/indented-fence.md")
[ "$got" = "$(printf 'BLOCK 3\nERR 5: Merged in 3 seconds, all green')" ] &&
  ok "a fence indented under a list item is read" ||
  ko "an indented fence answered '$got'"

printf '%s\n' '~~~' '```' 'Merged in 3 seconds, all green' '~~~' >"$fx/mixed.md"
got=$(check_blocks "$fx" "$fx/mixed.md")
case $got in
  *'ERR 2: ```'*'ERR 3: Merged'*) ok 'a ``` line inside a ~~~ block is a line of it, not a close' ;;
  *) ko "a mixed fence answered '$got'" ;;
esac

printf '%s\n' 'A paragraph' '' '    Merged in 3 seconds, all green' >"$fx/indented-code.md"
got=$(check_blocks "$fx" "$fx/indented-code.md")
case $got in
  'ERR 3: an indented code block'*) ok "an indented code block is a defect, since no fence says where it ends" ;;
  *) ko "an indented code block answered '$got'" ;;
esac

printf '%s\n' '- an item' '  continued on a second line' '' '- another' >"$fx/continuation.md"
got=$(check_blocks "$fx" "$fx/continuation.md")
[ -z "$got" ] && ok "a list item continued on an indented line is not a code block" ||
  ko "a continuation line answered '$got'"

printf '%s\n' '## 1. coordinator — a' '## 2. `architect` — b' '## 3. developer — c' >"$fx/steps.md"
[ "$(step_roles "$fx/steps.md")" = "coordinator architect developer" ] &&
  ok "step_roles reads the role of each numbered heading, backticks or not, in page order" ||
  ko "step_roles answered '$(step_roles "$fx/steps.md")'"

# C3.2: each step says what it produces and what the human decides.
printf '%s\n' '## 1. coordinator — a' '- **Produces:** x' '- **You decide:** y' \
  '## 2. architect — b' '- **Produces:** x' '## 3. developer — c' '- **You decide:** y' \
  '## Not a step' 'nothing' >"$fx/fields.md"
got=$(step_fields "$fx/fields.md")
[ "$got" = "$(printf 'STEP 1\nSTEP 2\nERR 2: no You decide\nSTEP 3\nERR 3: no Produces')" ] &&
  ok "step_fields names the step that lacks Produces or You decide, and reads the last step" ||
  ko "step_fields answered '$got'"

# C3.3: the section that says what GitHub refuses and what nothing enforces.
printf '%s\n' '## Intro' 'text' '## What GitHub refuses, and what nothing enforces' \
  'merging, a commit status, the pr-reviewer, the coordinator' 'pushing, tagging, publishing' \
  '## Next' 'tagging again' >"$fx/refuses.md"
refuses_terms=(merging "commit status" pr-reviewer coordinator pushing tagging publishing)
got=$(missing_terms "$fx/refuses.md" "What GitHub refuses" "${refuses_terms[@]}")
[ -z "$got" ] && ok "missing_terms is silent when the section holds every term" ||
  ko "missing_terms answered '$got' on a complete section"
printf '%s\n' '## What GitHub refuses, and what nothing enforces' 'merging, a commit status, pr-reviewer' \
  'the coordinator, pushing, publishing' '## Next' 'tagging' >"$fx/refuses2.md"
got=$(missing_terms "$fx/refuses2.md" "What GitHub refuses" "${refuses_terms[@]}")
[ "$got" = "tagging" ] && ok "missing_terms names a term the section lacks, though a later section has it" ||
  ko "missing_terms answered '$got' for a section without tagging"
got=$(missing_terms "$fx/steps.md" "What GitHub refuses" tagging)
[ "$got" = "NOSECTION" ] && ok "missing_terms says when the page has no such section" ||
  ko "missing_terms answered '$got' on a page with no section"

# The interrupted-step section: a table whose rows have all their cells.
printf '%s\n' '## When a step is interrupted' '| a | b | c |' '|---|---|---|' '| 1 | 2 | 3 |' \
  '| 4 | | 6 |' '| 7 | 8 | 9 |' '## Next' '| x | y | z |' >"$fx/table.md"
[ "$(table_rows "$fx/table.md" "When a step is interrupted")" = 2 ] &&
  ok "table_rows counts the rows with every cell filled, header and separator aside" ||
  ko "table_rows answered '$(table_rows "$fx/table.md" "When a step is interrupted")'"

# The text of "What it does not stop" is read by link, not copied.
printf '%s\n' '# t' '## What it does not stop' '' \
  '- **A first thing.** It lives in your keychain, under your user, and'  \
  '  an agent that runs the command itself gets it.' \
  '- **A second thing.** Git authenticates with your own credentials, not with' \
  '  the token, so an agent can push to the base branch.' '## Next' 'other' >"$fx/src.md"
printf '%s\n' 'See [What it does not stop](src.md#what-it-does-not-stop).' \
  'An agent can get around the rules some other way.' >"$fx/link.md"
got=$(copied_run "$fx/src.md" "$fx/link.md")
[ "$got" = "WORDS 45" ] && ok "a link and a paraphrase are no copy, and the scan says how many words it read" ||
  ko "copied_run on a link answered '$got'"
for n in 1 2; do
  case $n in
    1) pasted='It lives in your keychain, under your user, and an agent that runs the command' ;;
    2) pasted='Git authenticates with your own credentials, not with the token, so an agent' ;;
  esac
  printf '%s\n' 'Some text,' "$pasted" 'itself.' >"$fx/copy$n.md"
  got=$(copied_run "$fx/src.md" "$fx/copy$n.md")
  case $got in
    *COPY*) ok "a sentence of bullet $n pasted in, with the line breaks moved, is a copy" ;;
    *) ko "a pasted bullet $n answered '$got'" ;;
  esac
done
got=$(copied_run "$WORK/none.md" "$fx/link.md")
[ "$got" = "WORDS 0" ] && ok "a source with no such section reads zero words, which the witness refuses" ||
  ko "copied_run on a missing source answered '$got'"

# --- The real page ----------------------------------------------------------------------
if [ -s "$PAGE" ]; then
  ok "docs/walkthrough.md exists and is not empty"
else
  ko "docs/walkthrough.md is missing or empty"
  echo "$failures of $total walkthrough test(s) failed"
  exit 1
fi

roles=$(step_roles "$PAGE")
[ "$roles" = "$EXPECTED" ] &&
  ok "the steps are the roles of the workflow, in the order it runs them" ||
  ko "the steps are '$roles', expected '$EXPECTED'"

missing=""
for r in $roles; do [ -f "$ROOT/agents/$r.md" ] || missing="$missing $r"; done
[ -z "$missing" ] && ok "every role the page names is a file of agents/" ||
  ko "roles with no file in agents/:$missing"

out=$(step_fields "$PAGE")
steps=$(printf '%s\n' "$out" | grep -c '^STEP ')
[ "$steps" -ge 1 ] && ok "witness: $steps numbered step(s) of the page were read" ||
  ko "witness: the check read no numbered step of the page"
errs=$(printf '%s\n' "$out" | grep '^ERR ')
[ -z "$errs" ] && ok "every step says what it produces and what the human decides" ||
  ko "steps lacking a field: $errs"

if grep -qiw probe "$PAGE"; then
  ko "the page mentions probe, a measuring tool and not a role of the workflow"
else
  ok "probe is not on the page"
fi

got=$(missing_terms "$PAGE" "What GitHub refuses" "${refuses_terms[@]}")
[ -z "$got" ] && ok "the section on what GitHub refuses names both refusals and what nothing enforces" ||
  ko "the section on what GitHub refuses lacks: $got"

if section_text "$PAGE" "What GitHub refuses" | grep -qF '(github-tokens.md#what-it-does-not-stop)'; then
  ok "that section links github-tokens.md#what-it-does-not-stop"
else
  ko "that section does not link github-tokens.md#what-it-does-not-stop"
fi

out=$(copied_run "$TOKENS" "$PAGE")
words=$(printf '%s\n' "$out" | sed -n 's/^WORDS //p')
[ "${words:-0}" -ge 8 ] && ok "witness: $words words of 'What it does not stop' were read" ||
  ko "witness: docs/github-tokens.md has no 'What it does not stop' section to compare with"
copy=$(printf '%s\n' "$out" | sed -n 's/^COPY //p')
[ -z "$copy" ] && ok "the page does not copy 'What it does not stop'" ||
  ko "the page repeats a run of 'What it does not stop' instead of linking it: $copy"

got=$(missing_terms "$PAGE" "When a step is interrupted" 403 "review is absent" "check fails" "behind the base" sensitive RFR)
[ -z "$got" ] && ok "the interrupted-step section covers a refused merge, a missing review and a sensitive path" ||
  ko "the interrupted-step section lacks: $got"
rows=$(table_rows "$PAGE" "When a step is interrupted")
[ "$rows" -ge 3 ] && ok "witness: $rows rows of the interrupted-step table say what stops, what the coordinator does, what returns to you" ||
  ko "the interrupted-step table has $rows complete row(s), expected 3 or more"

got=$(missing_terms "$PAGE" "8\\. " "does not always merge" "sensitive path" RFR)
[ -z "$got" ] && ok "the last step says that a sensitive path sends the merge to the human" ||
  ko "the last step lacks: $got"

out=$(check_blocks "$ROOT" "$PAGE")
blocks=$(printf '%s\n' "$out" | grep -c '^BLOCK ')
[ "$blocks" -ge 1 ] && ok "witness: $blocks code block(s) of the page were read" ||
  ko "witness: the check read no code block of the page"
errs=$(printf '%s\n' "$out" | grep '^ERR ')
[ -z "$errs" ] && ok "every code block is marked Example or quoted from agents/, bin/, brief/ or skills/" ||
  ko "invented lines in code blocks: $errs"

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total walkthrough test(s) failed"
  exit 1
fi
echo "all $total walkthrough tests passed"
