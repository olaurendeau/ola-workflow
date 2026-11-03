#!/usr/bin/env bash
# shellcheck disable=SC2015
#   SC2015, `A && ok || ko`: ok() only counts and prints, so ko() cannot run after a passing test.
# docs/getting-started.md: the six steps in order, every output it quotes is one the code
# prints, "macOS" comes before the install step, and perl, which only tests/run.sh needs, is
# not listed as something a user must have.
#
# Each refusal is proved on a throwaway page first. On the real page a clean verdict is also
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

ola_scratch getting-started
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT

# The six steps of the page, by the words their headings start with, in the order a user
# runs them.
STEPS='Prerequisites|Install|Create the tokens|Write the project|Check it|Make your first request'

# Every output the page quotes. Each is a fragment of what bin/, hooks/ or brief/ prints, found by
# grep -F; the page has to carry the same fragment, so neither side can drift alone.
QUOTED=(
  'no profile found'
  'No ola-workflow profile applies to this project'
  'not valid JSON'
  'is not one of'
  'expected object, got array'
  'there is no base GitHub token in the keychain'
  'present, but GitHub rejects it (expired or revoked?)'
  'missing — ola-workflow-tokens setup'
  'ok, acts as'
  'the tokens live in the macOS keychain'
)

# page_problems <page> → one line per defect, nothing when the page is sound
page_problems() {
  local page=$1 heads want n=0 line
  [ -s "$page" ] || { echo "no-page"; return; }
  # Headings outside code fences, "## 3. Create…" read as "Create…"
  heads=$(awk '/^```/ { f = !f } !f && /^## [0-9]+\. / { sub(/^## [0-9]+\. /, ""); print }' "$page")
  # The steps, in order: the n-th heading must start with the n-th phrase.
  while IFS= read -r want; do
    n=$((n + 1))
    line=$(printf '%s\n' "$heads" | sed -n "${n}p")
    case $line in
      "$want"*) ;;
      *) echo "step $n should start with \"$want\", it is \"$line\"" ;;
    esac
  done <<EOF
$(printf '%s\n' "$STEPS" | tr '|' '\n')
EOF
  [ "$(printf '%s\n' "$heads" | grep -c .)" -eq 6 ] || echo "the page should have six numbered steps"
  # macOS is named before the install step
  awk '/^## 2\. / { exit 1 } /macOS/ { found = 1 } END { exit !found }' "$page" ||
    echo "macOS is not named before the install step"
  grep -qF '"github_tokens": "off"' "$page" || echo "the page does not give the \"github_tokens\": \"off\" line"
  # The plugin's bin/ is on the PATH of a session's Bash calls only: a terminal needs the
  # line that puts it there, and it comes before the first command the page runs from one.
  grep -qF 'claude plugin list --json' "$page" || echo "the page does not put the plugin's bin/ on the PATH of a terminal"
  awk '/ola-workflow-tokens setup$/ { exit !found } /claude plugin list --json/ { found = 1 }' "$page" ||
    echo "the page runs ola-workflow-tokens setup before it puts bin/ on the PATH"
  # perl is for tests/run.sh alone
  ! grep -qiw 'perl' "$page" || echo "the page lists perl, which no user needs"
}

# export_problems <page> → what the PATH line does when two installs of the plugin are listed
# (user and project scope): it has to add exactly one directory. The line is read from the page
# and run with a `claude` that prints a fixture.
export_problems() {
  local page=$1 line before after added
  line=$(grep -F 'claude plugin list --json' "$page" | head -n 1)
  [ -n "$line" ] || { echo "export: the page has no PATH line"; return; }
  # shellcheck disable=SC2329  # called by the eval below
  claude() { cat "$fx/two-installs.json"; }
  before=$PATH
  after=$(eval "$line" 2>/dev/null; printf '%s' "$PATH")
  added=${after%":$before"}
  case $added in
    */bin) ;;
    *) echo "export: the PATH line adds \"$added\", not one bin/ directory" ;;
  esac
  case $added in
    *:* | *$'\n'*) echo "export: the PATH line adds two directories when user and project installs are listed" ;;
  esac
  unset -f claude
}

# quoted_problems <page> <root> → a quoted output missing from the page or from the code
quoted_problems() {
  local page=$1 root=$2 q
  for q in "${QUOTED[@]}"; do
    grep -qF -- "$q" "$page" || echo "the page does not quote \"$q\""
    grep -rqF -- "$q" "$root/bin" "$root/hooks" "$root/brief" 2>/dev/null || echo "\"$q\" is printed by nothing in bin/, hooks/ or brief/"
  done
}

# --- Fixtures: each defect alone, on a page copied from the real one ----------------------
REAL=$ROOT/docs/getting-started.md
fx=$WORK/fx
mkdir -p "$fx"
cat >"$fx/two-installs.json" <<'JSON'
[{"id":"ola-workflow@ola-workflow","scope":"project","installPath":"/project/ola-workflow/0.9.0"},
 {"id":"other@market","scope":"user","installPath":"/user/other/1.0.0"},
 {"id":"ola-workflow@ola-workflow","scope":"user","installPath":"/user/ola-workflow/0.9.0"}]
JSON

mutate() { # mutate <name> <sed arguments> → $fx/<name>.md
  sed "${@:2}" "$REAL" >"$fx/$1.md"
}
expect_defect() { # expect_defect <label> <name> <pattern in the problems>
  local out
  out=$(page_problems "$fx/$2.md")
  if printf '%s\n' "$out" | grep -q -- "$3"; then ok "page check: $1"; else ko "page check should refuse: $1 (got: ${out:-nothing})"; fi
}

if [ -s "$REAL" ]; then
  mutate swapped -e 's/^## 3\. Create the tokens/## 3. TMP/' -e 's/^## 4\. Write the project/## 4. Create the tokens/' -e 's/^## 3\. TMP/## 3. Write the project/'
  expect_defect "steps out of order" swapped "step 3 should start with"
  mutate nomac 's/macOS/the platform/g'
  expect_defect "macOS missing before the install" nomac "macOS is not named"
  # shellcheck disable=SC2016
  mutate perl 's/^- `git`,$/- `git`, `perl`,/'
  expect_defect "perl listed as a prerequisite" perl "lists perl"
  mutate nopath 's/claude plugin list --json/true/'
  expect_defect "no PATH line for a terminal" nopath "on the PATH of a terminal"
  mutate five 's/^## 6\. /## /'
  expect_defect "a step lacking its number" five "six numbered steps"
  # The export line moved below the command that needs it
  awk -v l="$(grep -nF 'claude plugin list --json' "$REAL" | head -n 1 | cut -d: -f1)" \
    'NR == l { held = $0; next } { print } END { print held }' "$REAL" >"$fx/late.md"
  expect_defect "the PATH line after ola-workflow-tokens setup" late "before it puts bin/ on the PATH"
  : >"$fx/empty.md"
  expect_defect "an empty page" empty "no-page"
else
  ko "the page docs/getting-started.md exists"
fi

# A quoted output the code does not print, and one the page does not carry.
mkdir -p "$fx/root/bin" "$fx/root/hooks"
for q in "${QUOTED[@]}"; do printf '%s\n' "$q" >>"$fx/root/bin/all"; done
printf 'x\n' >"$fx/page.md"
[ -z "$(quoted_problems "$REAL" "$fx/root")" ] && ok "quoted check: passes when the code prints every output" ||
  ko "quoted check should pass on a root that prints everything"
: >"$fx/root/bin/all"
out=$(quoted_problems "$REAL" "$fx/root")
printf '%s\n' "$out" | grep -q 'printed by nothing' && ok "quoted check: refuses an output the code does not print" ||
  ko "quoted check should refuse an output the code does not print"
out=$(quoted_problems "$fx/page.md" "$ROOT")
printf '%s\n' "$out" | grep -q 'does not quote' && ok "quoted check: refuses an output the page does not carry" ||
  ko "quoted check should refuse an output the page does not carry"

# The PATH line: refused when it yields two paths. The fixture is the line as it was.
cat >"$fx/twopaths.md" <<'PAGE'
export PATH="$(claude plugin list --json | jq -r '.[] | select(.id == "ola-workflow@ola-workflow") | .installPath')/bin:$PATH"
PAGE
out=$(export_problems "$fx/twopaths.md")
printf '%s\n' "$out" | grep -q 'adds two directories' && ok "export check: refuses a line that yields two paths" ||
  ko "export check should refuse a line that yields two paths (got: ${out:-nothing})"

# --- The real page ------------------------------------------------------------------------
[ -s "$REAL" ] && [ "$(grep -c '^## ' "$REAL")" -gt 0 ] && ok "the real page was read ($(grep -c '^## ' "$REAL") sections)" ||
  ko "the real page is missing or has no section"

problems=$(page_problems "$REAL")
if [ -z "$problems" ]; then
  ok "the six steps come in order, macOS before the install, and no perl"
else
  while IFS= read -r p; do ko "getting-started: $p"; done <<EOF
$problems
EOF
fi

exports=$(export_problems "$REAL")
if [ -z "$exports" ]; then
  ok "the PATH line adds one directory when user and project installs are both listed"
else
  while IFS= read -r p; do ko "getting-started: $p"; done <<EOF
$exports
EOF
fi

quoted=$(quoted_problems "$REAL" "$ROOT")
if [ -z "$quoted" ]; then
  ok "every output the page quotes (${#QUOTED[@]}) is printed by bin/, hooks/ or brief/"
else
  while IFS= read -r p; do ko "getting-started: $p"; done <<EOF
$quoted
EOF
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total getting-started test(s) failed"
  exit 1
fi
echo "all $total getting-started tests passed"
