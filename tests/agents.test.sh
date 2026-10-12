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
WORKFLOW_ROLES="coordinator developer pr-reviewer"
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
  hits=$(grep -lE -- "$1" "${AGENTS[@]}" 2>/dev/null | sed 's#.*/##' | tr '\n' ' ')
  if [ -z "$hits" ]; then
    ok "no agent hard-codes $2"
  else
    ko "$2 is hard-coded in: $hits"
  fi
}

forbid 'origin/(main|master|trunk|develop)' 'a base branch'
forbid '(make check|npm (run|test)|cargo test|pytest|go test)' 'a check command'
forbid 'gh (issue|label) (create|edit)' 'a forge write the brief governs'
forbid '--match-head-commit' 'the merge form the brief states'
forbid 'agent-review' 'a review status name'
forbid 'SLOT=[0-9]' 'a slot value'
forbid '(docker compose|docker run)' 'a container command'
forbid '(package-lock|Gemfile.lock|Cargo.lock)' 'a project'\''s lockfile'
forbid '1000 (changed )?lines' 'a line budget'

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
