#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
#   SC2015, `A && ok || ko`: ok() only counts and prints, so ko() cannot run after a passing test.
#   SC2016: the backticks in single quotes below are the Markdown being tested, not a command.
# docs/walkthrough.md follows one request from the human's sentence to the merged pull
# request. What the repository can check about it: the roles come in the order the workflow
# runs them, `probe` (a measuring tool, not a role) is not among them, the page links the
# section that says what GitHub does not stop rather than copying it, and nothing in a code
# block is invented — a block opens with a line saying "Example", or each of its lines is
# found in agents/, bin/ or skills/.
#
# Each check is proved on a throwaway tree first. On the real page a clean verdict is also
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

ola_scratch walkthrough
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT

PAGE=$ROOT/docs/walkthrough.md

# The roles, in the order the workflow runs them: coordinator frames and merges, the others
# in between. The page numbers its steps in `## N. role — what it does` headings.
EXPECTED="coordinator product-designer design-reviewer architect developer pr-reviewer security-reviewer coordinator"

# step_roles <page> → the role of each numbered step heading, in the page's order, on one line.
step_roles() {
  sed -n -E 's/^## [0-9]+\. `?([a-z-]+)`? .*/\1/p' "$1" | tr '\n' ' ' | sed 's/ $//'
}

# check_blocks <root> <page> → one BLOCK line per fenced block read, one ERR line per line of a
# block that is neither under an "Example" opener nor found in agents/, bin/ or skills/.
# A line is found as a fixed string, leading blanks aside: the page quotes, it does not match
# patterns. An unclosed fence is a defect of its own, because it would swallow the rest.
check_blocks() {
  local root=$1 page=$2 line n=0 inblock=0 first=0 exempt=0 text
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case $line in
      '```'*)
        if [ "$inblock" = 1 ]; then
          inblock=0
        else
          inblock=1 first=1 exempt=0
          echo "BLOCK $n"
        fi
        continue
        ;;
    esac
    [ "$inblock" = 1 ] || continue
    text=${line#"${line%%[![:space:]]*}"}
    [ -n "$text" ] || continue
    if [ "$first" = 1 ]; then
      first=0
      case $text in Example*) exempt=1 ;; esac
    fi
    [ "$exempt" = 1 ] && continue
    grep -rqF -- "$text" "$root/agents" "$root/bin" "$root/skills" 2>/dev/null ||
      echo "ERR $n: $text"
  done <"$page"
  [ "$inblock" = 0 ] || echo "ERR $n: a fenced block is never closed"
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

printf '%s\n' '## 1. coordinator — a' '## 2. `architect` — b' '## 3. developer — c' >"$fx/steps.md"
[ "$(step_roles "$fx/steps.md")" = "coordinator architect developer" ] &&
  ok "step_roles reads the role of each numbered heading, backticks or not, in page order" ||
  ko "step_roles answered '$(step_roles "$fx/steps.md")'"

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

if grep -qiw probe "$PAGE"; then
  ko "the page mentions probe, a measuring tool and not a role of the workflow"
else
  ok "probe is not on the page"
fi

if grep -qF '(github-tokens.md#what-it-does-not-stop)' "$PAGE"; then
  ok "the page links github-tokens.md#what-it-does-not-stop"
else
  ko "the page does not link github-tokens.md#what-it-does-not-stop"
fi

# The text of that section is read by link, not copied: its first bullet is a sentence long
# enough to be recognised if it were pasted.
if grep -qF 'An agent that sets out to get around it' "$PAGE"; then
  ko "the page copies a sentence of 'What it does not stop' instead of linking it"
else
  ok "the page does not copy 'What it does not stop'"
fi

out=$(check_blocks "$ROOT" "$PAGE")
blocks=$(printf '%s\n' "$out" | grep -c '^BLOCK ')
[ "$blocks" -ge 1 ] && ok "witness: $blocks code block(s) of the page were read" ||
  ko "witness: the check read no code block of the page"
errs=$(printf '%s\n' "$out" | grep '^ERR ')
[ -z "$errs" ] && ok "every code block is marked Example or quoted from agents/, bin/ or skills/" ||
  ko "invented lines in code blocks: $errs"

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total walkthrough test(s) failed"
  exit 1
fi
echo "all $total walkthrough tests passed"
