#!/usr/bin/env bash
# The agents are prompts, so what is testable about them is not what they say but what they
# must not say, and whether the single source they all cite stays the single source.
#
# Four instruments, each one earned by a defect this repository has already paid for:
#   - a negative assertion, because a prompt is full of "never do X" sentences that satisfy
#     a positive grep by accident;
#   - a liveness witness beside each absence, because an absence passes vacuously on an
#     empty file, a renamed section, or a pattern that stopped matching;
#   - the pair "how many state it / how many need it", because a rule in two files out of
#     three is duplicated between those two and stranded for the third, and those two
#     failures are corrected in opposite directions;
#   - an assertion tying the agents to the schema, not only to each other, because every
#     check that compares things of the same kind missed the drift between kinds.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BRIEF=$ROOT/bin/ola-workflow-brief
failures=0
total=0

ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

# The workflow roles, and the diagnostics that are not roles. Declared rather than
# globbed, so that `probe` — which exists to dump a hook payload, not to work — is not held
# to rules about modes and slots. Both directions are checked below, so a new file cannot
# quietly escape either set.
WORKFLOW_ROLES="coordinator product-designer architect developer pr-reviewer"
DIAGNOSTICS="probe"

AGENTS=()
for role in $WORKFLOW_ROLES; do AGENTS+=("$ROOT/agents/$role.md"); done
ALL=()
for f in "$ROOT"/agents/*.md; do ALL+=("$f"); done
[ "${#ALL[@]}" -gt 0 ] || { echo "no agent files found"; exit 1; }

for f in "${ALL[@]}"; do
  stem=${f##*/}; stem=${stem%.md}
  case " $WORKFLOW_ROLES $DIAGNOSTICS " in
    *" $stem "*) ok "$stem is a declared role or diagnostic" ;;
    *) ko "agents/$stem.md is neither a declared workflow role nor a declared diagnostic" ;;
  esac
done
for role in $WORKFLOW_ROLES; do
  if [ -f "$ROOT/agents/$role.md" ]; then ok "$role has a file"; else ko "$role is a declared role with no file"; fi
done

frontmatter() { awk '/^---$/{c++; if (c==2) exit} c==1' "$1"; }
body() { awk '/^---$/{c++; next} c>=2' "$1"; }

# --- Every agent file is alive -------------------------------------------------------
# This is the witness every assertion below leans on: all of them would pass on an empty
# file, so "it is not empty, and it has both halves" has to be checked first.
for f in "${AGENTS[@]}"; do
  name=${f##*/}
  if [ -s "$f" ] && [ -n "$(frontmatter "$f")" ] && [ -n "$(body "$f")" ]; then
    ok "$name: has frontmatter and a body"
  else
    ko "$name: empty, or missing its frontmatter or its body"
  fi
done

# Existence is not substance. Stubbed down to eight lines, two of these agents left every
# assertion below green — so the witness asserts what the coordinator actually consumes
# from each of them, which is what a stub cannot fake without becoming the real thing.
for f in "${AGENTS[@]}"; do
  name=${f##*/}
  if [ "$(body "$f" | grep -c .)" -ge 20 ]; then
    ok "$name: has a body of substance, not a stub"
  else
    ko "$name: body is $(body "$f" | grep -c .) non-empty lines, which is a stub"
  fi
  if grep -q '^## Steps' "$f"; then
    ok "$name: says in what order it works"
  else
    ko "$name: has no Steps section, so nothing says how it proceeds"
  fi
done
# The coordinator reads a Status from each of the others, and dispatches each of them.
for role in product-designer architect developer pr-reviewer; do
  if grep -q 'Status:' "$ROOT/agents/$role.md"; then
    ok "$role: reports a Status, which the coordinator reads first"
  else
    ko "$role: reports no Status, so the coordinator cannot tell done from blocked"
  fi
done

# --- Frontmatter ----------------------------------------------------------------------
for f in "${AGENTS[@]}"; do
  name=${f##*/}
  fm=$(frontmatter "$f")
  stem=${name%.md}
  declared=$(printf '%s' "$fm" | sed -n 's/^name: *//p')
  if [ "$declared" = "$stem" ]; then ok "$name: name matches the file"; else ko "$name: declares name '$declared' in $name"; fi
  if printf '%s' "$fm" | grep -q '^description: '; then ok "$name: has a description"; else ko "$name: has no description, so nothing can dispatch it on purpose"; fi
  if printf '%s' "$fm" | grep -q '^tools: '; then ok "$name: declares its tools"; else ko "$name: declares no tools, so it gets all of them"; fi
  # Keys Claude Code ignores for a plugin agent. Writing one would promise a guard rail
  # that does not exist — the spike recorded in the README established which.
  ignored=$(printf '%s' "$fm" | grep -cE '^(permissionMode|hooks|mcpServers|initialPrompt|observer[A-Za-z]*):')
  if [ "$ignored" = 0 ]; then ok "$name: claims no frontmatter key that plugin agents ignore"; else ko "$name: sets a key that is ignored for a plugin agent"; fi
done

# Only the developer works in a worktree, and only the reviewer pins a model.
worktrees=$(grep -l '^isolation: worktree' "${AGENTS[@]}" | sed 's#.*/##' | tr '\n' ' ')
if [ "$worktrees" = "developer.md " ]; then ok "only the developer is isolated in a worktree"; else ko "worktree isolation is on: ${worktrees:-nobody}"; fi
models=$(grep -l '^model: ' "${AGENTS[@]}" | sed 's#.*/##' | tr '\n' ' ')
if [ "$models" = "pr-reviewer.md " ]; then ok "only the reviewer pins a model"; else ko "a model is pinned on: ${models:-nobody}"; fi

# --- One source, cited by all ---------------------------------------------------------
# The pair that matters: the brief is stated once and needed by every agent. Each agent
# citing it is what makes "once" reachable rather than stranded.
for f in "${AGENTS[@]}"; do
  name=${f##*/}
  if grep -q 'ola-workflow-brief' "$f"; then ok "$name: cites the brief"; else ko "$name: does not cite the brief, so it will restate its rules"; fi
done

# --- What no agent may restate --------------------------------------------------------
# These facts belong to the brief, which resolves them from the profile. An agent that
# writes one down has hard-coded a project — the defect the whole plugin exists to avoid.
# Each is an absence, and the witness above proves the file had something to look at.
# A function per rule rather than a table: the first version used `|` as its field
# separator, which is also what separates an alternation, so every pattern was truncated at
# its first `|` and the whole block was dead. The counter-proof caught it — adding
# "origin/main" to an agent raised nothing — which is the only reason it is not still dead.
forbid() { # forbid <pattern> <what it would be>
  local hits
  # -i, because a prompt starts its sentences with a capital: "Branch from main." slipped
  # through a case-sensitive `branch from main` for exactly that reason.
  hits=$(grep -liE -- "$1" "${AGENTS[@]}" 2>/dev/null | sed 's#.*/##' | tr '\n' ' ')
  if [ -z "$hits" ]; then
    ok "no agent hard-codes $2"
  else
    ko "$2 is hard-coded in: $hits"
  fi
}

# One prohibition per value-bearing profile key, declared here and checked against the
# schema below. Nine hand-picked patterns covered five keys of twelve, so nine realistic
# hard-codings passed green — including `eas submit`, the example epic #1 gives for what
# this plugin exists to prevent. Deriving the list from the schema means a new key cannot
# be added without either a prohibition or an explicit decision not to have one.
forbid_key() { # forbid_key <schema key> <pattern> <what it would be>
  FORBIDDEN_KEYS="$FORBIDDEN_KEYS $1"
  forbid "$2" "$3"
}
FORBIDDEN_KEYS=""

forbid_key base_branch 'origin/(main|master|trunk|develop)|branch from (main|master|trunk)' \
  'a base branch'
forbid_key check '(make check|npm (run|test)|cargo test|pytest|go test|just check)' \
  'a check command'
# The honest limit of this approach: a required-check name is an ordinary word. Nothing
# can tell `checks` the job from `checks` the noun, and a prompt that says "wait for the
# checks" is right to. So this covers the merge form and the review status, which are
# distinctive, and leaves check names to the review.
forbid_key merge '(--match-head-commit|agent-review|gh (issue|label) (create|edit))' \
  'the merge form or a review status'
forbid_key slots 'SLOT=[0-9]|slot (1|2|3|9)\b' 'a slot value'
forbid_key pr '[0-9]{3,4} (changed )?lines|(package-lock|yarn\.lock|Gemfile\.lock|Cargo\.lock)' \
  'a line budget or a lockfile'
forbid_key language '(write (to the human )?in (French|English|français)|langue)' 'a language'
forbid_key context '(docs/agents/|CONTEXT\.md|CLAUDE\.md)' 'a context document path'
forbid_key commands '(eas (build|submit|update)|npm publish|scalingo|clever|vercel|neonctl)' \
  'a project command'
forbid_key db_hosts_allowed '(psql|mysql|mongosh|localhost:[0-9]|127\.0\.0\.1)' \
  'a database host'
forbid_key verify_ui '(playwright|maestro|simctl|ios-simulator|--width [0-9])' \
  'a way of looking at the project'
forbid_key escalation_extra 'escalation_extra' 'the escalation list itself'
forbid_key mode '(integrated|discreet) mode means' 'what a mode means'

# Both directions: every value-bearing key has a prohibition, and every prohibition names a
# key the schema declares.
for key in $(jq -r '.properties | keys[] | select(startswith("$") | not)' \
              "$ROOT/schema/profile.schema.json"); do
  case " $FORBIDDEN_KEYS " in
    *" $key "*) ok "profile key '$key' has a prohibition guarding it" ;;
    *) ko "profile key '$key' can be hard-coded in a prompt with nothing to catch it" ;;
  esac
done
for key in $FORBIDDEN_KEYS; do
  if jq -e --arg k "$key" '.properties | has($k)' \
      "$ROOT/schema/profile.schema.json" >/dev/null 2>&1; then
    ok "the prohibition for '$key' names a key the schema declares"
  else
    ko "there is a prohibition for '$key', which the schema does not declare"
  fi
done

# --- Dispatch names are namespaced ----------------------------------------------------
# subagent_type is an exact match: a bare name does not resolve to a plugin agent, and the
# spike in the README is where that was measured. A coordinator that writes `developer`
# fails at dispatch time, in front of the human.
coord=$ROOT/agents/coordinator.md
if [ -s "$coord" ]; then
  for role in coordinator product-designer architect developer pr-reviewer; do
    if grep -q "\`$role\`" "$coord"; then
      ko "coordinator.md names \`$role\` without its plugin prefix"
    else
      ok "coordinator.md names $role only with its prefix"
    fi
  done
  prefixed=$(grep -c 'ola-workflow:[a-z-]*' "$coord")
  if [ "$prefixed" -ge 4 ]; then ok "coordinator.md dispatches four namespaced agents"; else ko "coordinator.md mentions only $prefixed namespaced agents"; fi
else
  ko "coordinator.md is missing"
fi

# --- The agents and the schema --------------------------------------------------------
# The assertion that compares two kinds rather than two instances of one kind. Every key
# the schema declares must reach an agent through the brief, and the brief must not read a
# key the schema does not declare — the drift neither prose nor a grep over prompts sees.
for key in $(jq -r '.properties | keys[] | select(startswith("$") | not)' \
              "$ROOT/schema/profile.schema.json"); do
  if grep -q "\b$key\b" "$BRIEF"; then ok "schema key '$key' reaches the agents through the brief"; else ko "schema key '$key' is declared and no agent can ever see it"; fi
done
for key in $(grep -v '^[[:space:]]*#' "$BRIEF" |
             perl -nle 'print $1 while /\$\(get\s+"?([a-z_]+)/g' | sort -u); do
  if jq -e --arg k "$key" '.properties | has($k)' \
      "$ROOT/schema/profile.schema.json" >/dev/null 2>&1; then
    ok "the brief reads '$key', which the schema declares"
  else
    ko "the brief reads '$key', which the schema does not declare"
  fi
done

# --- No prompt may promise a guard that does not guard --------------------------------
# While hooks/guard.sh is inert, a present-tense claim that the guard refuses or asks is
# false, and in discreet mode it is dangerous: an agent told it will be asked, that pushes
# without asking and sees no prompt, reads the silence as sanction. So the claim is tied to
# the guard's actual state rather than to anyone's memory of it — when A3 makes the guard
# real, this assertion inverts and says so.
# Ask the guard instead of reading it. The first version inferred inertness from two
# textual proxies — a last code line of `exit 0`, and no mention of permissionDecision —
# and both break in the silent direction under the two things A3 will actually do: wrap the
# guard in a function, and write the decision emitters before wiring them. The assertion
# would then skip itself while printing a line that reads like a pass, on exactly the
# commit where the claim starts mattering. Behaviour cannot be fooled that way.
# Derived, not enumerated. Five hand-written Bash commands sampled one axis while holding
# tool_name at Bash — and merge.sensitive_paths is about *files*, so the rule enforcing it
# inspects Write and Edit. A guard denying a Write to .github/ was invisible to all five
# probes, and a sixth Bash command would have fixed that instance and left the next.
#
# So the question is asked of the place where the guard's decisions are already written:
# tests/guard.test.sh is a table of (expectation, agent, command) that drives guard.sh
# directly, and that suite has to pass. Every rule A3 adds extends this probe by itself.
#
# This matters more than tidiness: a false "inert" reading does not miss a lie, it forbids
# a truth — and a test that fails on correct content leaves an author choosing between
# deleting a true sentence and disabling the test. Under pressure the test loses.
GUARD_SUITE=$ROOT/tests/guard.test.sh
# The witness, because `expected_decisions = 0` is an absence and an absence passes
# vacuously: if that suite renames its helper, the derivation stays at zero and reads as if
# it works. So assert the vocabulary it greps for exists at all.
suite_cases=$(grep -cE '^[[:space:]]*check (allow|deny|ask)' "$GUARD_SUITE" || true)
if [ "$suite_cases" -gt 0 ]; then
  ok "the guard suite states $suite_cases decisions in the form this derivation reads"
else
  ko "the guard suite states no decision in the form read here, so the derivation is blind"
fi
expected_decisions=$(grep -cE '^[[:space:]]*check (deny|ask)' "$GUARD_SUITE" || true)

guard_decides=no
if [ "$expected_decisions" -gt 0 ]; then
  guard_decides=yes
fi

# And the inverse, which the derivation alone would miss: a guard that decides something
# its own suite never expects. One probe per decision verb the hook can emit is enough to
# notice, because any of them means the guard is no longer inert.
if [ "$guard_decides" = no ]; then
  for payload in \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push --force origin HEAD"}}' \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"gh pr merge 7 --squash"}}' \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":".github/workflows/ci.yml","content":"x"}}' \
    '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"hooks/guard.sh"}}'; do
    said=$(printf '%s' "$payload" | "$ROOT/hooks/guard.sh" 2>/dev/null)
    status=$?
    if [ -n "$said" ] || [ "$status" != 0 ]; then
      ko "the guard decides something its own suite never expects: $said"
      guard_decides=yes
      break
    fi
  done
fi


if [ "$guard_decides" = no ]; then
  claims=$(grep -lE 'guard (refuses|blocks|will ask|asks|prevents)' \
    "${ALL[@]}" "$BRIEF" 2>/dev/null | sed 's#.*/##' | tr '\n' ' ')
  if [ -z "$claims" ]; then
    ok "the guard decides nothing its suite expects, and no prompt claims otherwise"
  else
    ko "the guard decides nothing yet, and these promise otherwise: $claims"
  fi
else
  # The guard decides something now, so the prompts may — and should — say so. This arm is
  # what A3 turns on, and it is an assertion rather than a note so that the switch is
  # visible in the suite rather than inferred from its silence.
  for f in "${AGENTS[@]}" "$BRIEF"; do
    name=${f##*/}
    if grep -qE 'guard (refuses|blocks|will ask|asks|prevents)' "$f"; then
      ok "$name: the guard decides, and this says so"
    else
      ko "$name: the guard decides now, and this tells an agent nothing will stop it"
    fi
  done
fi

# --- The brief, per mode --------------------------------------------------------------
# The mode rules live here rather than in five prompts, so this is where they are checked —
# against the program's real output, not against a sentence about it.
WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ola-agents.XXXXXX")" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
export HOME=$WORK/home
mkdir -p "$HOME"

brief_for() { # brief_for <mode> → the brief of a throwaway project in that mode
  local mode=$1
  local repo=$WORK/$mode
  mkdir -p "$repo/.claude"
  git -C "$repo" -c init.defaultBranch=main init -q 2>/dev/null
  git -C "$repo" remote add origin "https://github.com/someone/$mode.git" 2>/dev/null
  printf '{"mode":"%s","base_branch":"trunk","check":{"full":"just check"},' "$mode" \
    >"$repo/.claude/workflow.json"
  printf '"slots":{"developers":[1,2],"reviewer":9},"merge":{"review_status":"reviewed"}}\n' \
    >>"$repo/.claude/workflow.json"
  "$BRIEF" "$repo"
}

integrated=$(brief_for integrated)
discreet=$(brief_for discreet)

# The witnesses first: every absence below would pass on an empty brief.
if [ "$(printf '%s' "$integrated" | wc -l)" -gt 20 ]; then ok "the integrated brief has content"; else ko "the integrated brief is empty or nearly so"; fi
if [ "$(printf '%s' "$discreet" | wc -l)" -gt 20 ]; then ok "the discreet brief has content"; else ko "the discreet brief is empty or nearly so"; fi

# Both modes resolve the profile rather than assuming anything.
for pair in "integrated:$integrated" "discreet:$discreet"; do
  mode=${pair%%:*}
  text=${pair#*:}
  case $text in
    *trunk*) ok "$mode: the brief names the project's own base branch" ;;
    *) ko "$mode: the brief does not name the base branch from the profile" ;;
  esac
  case $text in
    *"just check"*) ok "$mode: the brief names the project's own check command" ;;
    *) ko "$mode: the brief does not name the check command from the profile" ;;
  esac
done

# Discreet mode: no instruction to write on the forge, and none to merge. These are
# absences, and the witness above is what makes them mean something.
for forbidden in 'gh pr merge' 'gh issue create' 'gh label' 'gh pr comment' 'gh api'; do
  case $discreet in
    *"$forbidden"*) ko "the discreet brief still tells an agent how to run $forbidden" ;;
    *) ok "the discreet brief gives no way to run $forbidden" ;;
  esac
done
case $discreet in
  *'Merging. Nobody merges'*) ok "the discreet brief says nobody merges" ;;
  *) ko "the discreet brief does not forbid merging" ;;
esac
case $discreet in
  *runs/*) ok "the discreet brief names the local memory directory" ;;
  *) ko "the discreet brief does not say where the memory goes" ;;
esac

# Integrated mode does carry the merge form, with the SHA pinned.
case $integrated in
  *'--match-head-commit'*) ok "the integrated brief pins the merge to a SHA" ;;
  *) ko "the integrated brief does not pin the merge to a SHA" ;;
esac
case $integrated in
  *reviewed*) ok "the integrated brief names the project's own review status" ;;
  *) ko "the integrated brief does not name the review status from the profile" ;;
esac

# A value the profile does not state is announced as a default before the rules, not
# presented as one of them. Unmarked, a reviewer enforces a budget nobody set.
minimal=$WORK/minimal
mkdir -p "$minimal/.claude"
git -C "$minimal" -c init.defaultBranch=master init -q 2>/dev/null
git -C "$minimal" remote add origin https://github.com/someone/minimal.git 2>/dev/null
printf '{"mode":"integrated"}\n' >"$minimal/.claude/workflow.json"
bare=$("$BRIEF" "$minimal")
case $bare in
  *'these are my defaults'*) ok "a minimal profile says which values are the plugin's" ;;
  *) ko "a minimal profile presents the plugin's defaults as the project's rules" ;;
esac
# key → value, because the decision an agent makes is about the value: "pr.max_lines"
# alone does not tell it which budget not to enforce.
while read -r key value; do
  case $bare in
    *"$key → $value"*) ok "the defaults notice gives $key and its value" ;;
    *) ko "the defaults notice does not give $key → $value" ;;
  esac
done <<'PAIRS'
pr.max_lines 1000
pr.title conventional
merge.review_status agent-review
language.human en
slots.var SLOT
PAIRS
# The notice comes before the rules: a rule read first and qualified later has been believed.
notice_line=$(printf '%s' "$bare" | grep -n 'these are my defaults' | cut -d: -f1)
rule_line=$(printf '%s' "$bare" | grep -n '^Base branch:' | cut -d: -f1)
if [ -n "$notice_line" ] && [ -n "$rule_line" ] && [ "$notice_line" -lt "$rule_line" ]; then
  ok "the defaults notice comes before the rules"
else
  ko "the defaults notice comes after the rules (notice $notice_line, rules $rule_line)"
fi

# The base branch is the one default worth resolving: the repository knows its own.
git -C "$minimal" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init 2>/dev/null
git -C "$minimal" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master 2>/dev/null
case $("$BRIEF" "$minimal") in
  *'Base branch: master'*) ok "the base branch is read from origin/HEAD, not guessed" ;;
  *) ko "the base branch was guessed although origin/HEAD says master" ;;
esac

# A profile that is readable but does not match the schema is published with that said.
# A key spelled wrong is a key that is not there, and the real command is lost in silence.
printf '{"mode":"integrated","chekc":{"full":"make check"}}\n' >"$minimal/.claude/workflow.json"
invalid=$("$BRIEF" "$minimal")
case $invalid in
  *'does not match the schema'*) ok "a schema-invalid profile is published with a warning" ;;
  *) ko "a schema-invalid profile is published as if it were sound" ;;
esac
case $invalid in
  *chekc*) ok "the warning names the key that is wrong" ;;
  *) ko "the warning does not say which key is wrong" ;;
esac

# No profile: a refusal that says what to do, not a set of guessed defaults.
mkdir -p "$WORK/bare"
git -C "$WORK/bare" -c init.defaultBranch=main init -q 2>/dev/null
out=$("$BRIEF" "$WORK/bare" 2>&1)
status=$?
if [ "$status" = 1 ] && [ -n "$out" ]; then
  ok "no profile: the brief refuses, with a status and a reason"
else
  ko "no profile: the brief exited $status saying '${out:-nothing}'"
fi
case $out in
  *workflow-init*) ok "no profile: the refusal says what to do about it" ;;
  *) ko "no profile: the refusal does not offer workflow-init" ;;
esac
case $out in
  *trunk*|*"just check"*) ko "no profile: the refusal leaked another project's values" ;;
  *) ok "no profile: nothing is guessed" ;;
esac

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total agent test(s) failed"
  exit 1
fi
echo "all $total agent tests passed"
