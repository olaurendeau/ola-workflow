#!/usr/bin/env bash
# shellcheck disable=SC2016
#   Every `$` in a command line below is part of what is being tested — `$(echo gh)`,
#   `${u:-gh}`, `$c`, `$EDITOR` — and expanding it here would test nothing.
# Runs hooks/guard.sh against simulated PreToolUse inputs.
# Harness ported from mcp-camptocamp tests/hooks/guard.test.sh: the commands below are
# only ever strings inside JSON, they are never executed.
# A3 adds the rule cases (merge, tags, publication, push, API writes) under the section
# headings kept at the bottom of this file.
set -uo pipefail

GUARD="$(cd "$(dirname "$0")/.." && pwd)/hooks/guard.sh"
failures=0
total=0

# Classify one guard run: allow (no decision on stdout) | deny | ask | error(exit N).
classify() {
  local output=$1 rc=$2 decision
  if [ "$rc" -ne 0 ]; then
    echo "error(exit $rc)"
    return
  fi
  if [ -n "$output" ]; then
    decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$output" 2>/dev/null)
    if [ -n "$decision" ]; then
      echo "$decision"
      return
    fi
  fi
  echo allow
}

report() {
  local expected=$1 actual=$2 label=$3
  total=$((total + 1))
  if [ "$actual" = "$expected" ]; then
    echo "ok    $expected  $label"
  else
    echo "FAIL  expected $expected, got $actual  $label"
    failures=$((failures + 1))
  fi
}

# check <allow|deny|ask> <agent_type|""> <command>
# An empty agent omits the key entirely, which is what Claude Code sends on a main
# session with no agent (agent_type is optional and absent, not "").
check() {
  local expected=$1 agent=$2 cmd=$3 input output rc
  input=$(jq -n --arg c "$cmd" --arg a "$agent" \
    '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}
     + (if $a == "" then {} else {agent_type: $a} end)')
  output=$("$GUARD" <<<"$input" 2>/dev/null)
  rc=$?
  report "$expected" "$(classify "$output" "$rc")" "[${agent:-main}] ${cmd//$'\n'/ ⏎ }"
}

# check_payload <allow|deny|ask> <label> <raw stdin>
# Feeds the guard an arbitrary payload, valid JSON or not.
check_payload() {
  local expected=$1 label=$2 payload=$3 output rc
  output=$("$GUARD" <<<"$payload" 2>/dev/null)
  rc=$?
  report "$expected" "$(classify "$output" "$rc")" "$label"
}

lines() { printf '%s\n' "$@"; }

# Every form agent_type can take: absent, empty, bare (a project agent, or the bare
# fallback --agent accepts), and namespaced (what a plugin agent actually sends).
ROLES=("" coordinator ola-workflow:coordinator ola-workflow:developer ola-workflow:pr-reviewer)

# No profile exists yet, so the guard is inert: everything is allowed, for every role,
# including the commands A3 will restrict. These cases are the "no profile → no effect
# on other projects" contract, and A3 must keep them passing with a profile-less repo.
RESTRICTED_LATER=(
  'gh pr merge 5 --squash'
  'gh api -X PUT repos/o/r/pulls/7/merge'
  'git push --force origin main'
  'git push origin v1.2.3'
  'git tag v1.2.3'
  'npm publish --access public'
  'npm version patch'
  'gh release create v1.2.3'
  'gh api repos/o/r/statuses/abc -f state=success -f context=agent-review'
  'gh secret set FOO'
)
for cmd in "${RESTRICTED_LATER[@]}"; do
  for role in "${ROLES[@]}"; do
    check allow "$role" "$cmd"
  done
done

# Everyday commands stay allowed, of course.
EVERYDAY=(
  'make check'
  'git status'
  'git log --oneline -5'
  'gh pr view 5 --json mergeStateStatus'
  'tests/run.sh'
  "$(lines 'gh pr comment 7 --body-file - <<EOF' 'A comment that merely mentions gh pr merge.' 'EOF')"
)
for cmd in "${EVERYDAY[@]}"; do
  for role in "${ROLES[@]}"; do
    check allow "$role" "$cmd"
  done
done

# Robustness: a payload the guard cannot parse must still allow, never crash. The guard
# runs on every Bash call of every project, so a crash here would block real sessions.
check_payload allow 'empty stdin' ''
check_payload allow 'not JSON' 'this is not json at all'
check_payload allow 'truncated JSON' '{"hook_event_name": "PreToolUse", "tool_input":'
check_payload allow 'no tool_input' '{"hook_event_name": "PreToolUse", "tool_name": "Bash"}'
check_payload allow 'empty agent_type' '{"hook_event_name":"PreToolUse","tool_name":"Bash","agent_type":"","tool_input":{"command":"gh pr merge 5"}}'
check_payload allow 'null command' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":null}}'
check_payload allow 'JSON array' '[]'

# The guard says nothing on stdout when it allows: a stray byte there would land in the
# transcript on every single Bash call.
total=$((total + 1))
if [ -z "$("$GUARD" <<<'{"tool_input":{"command":"git status"}}' 2>/dev/null)" ]; then
  echo "ok    silent  no stdout when allowing"
else
  echo "FAIL  silent  the guard wrote to stdout while allowing"
  failures=$((failures + 1))
fi

# The diagnostic tap: one JSON line per call when OLA_WORKFLOW_PROBE_LOG is set, and
# nothing written when it is not. scripts/spike/agent-identity.sh depends on this.
probe_log=$(mktemp "${TMPDIR:-/tmp}/ola-probe.XXXXXX")
OLA_WORKFLOW_PROBE_LOG="$probe_log" "$GUARD" \
  <<<'{"tool_name":"Bash","agent_type":"ola-workflow:probe","tool_input":{"command":"echo hi"}}' >/dev/null 2>&1
OLA_WORKFLOW_PROBE_LOG="$probe_log" "$GUARD" \
  <<<'{"tool_name":"Bash","tool_input":{"command":"echo again"}}' >/dev/null 2>&1
total=$((total + 1))
if [ "$(wc -l <"$probe_log" | tr -d ' ')" = 2 ] \
  && [ "$(jq -r 'select(.agent_type) | .agent_type' "$probe_log")" = "ola-workflow:probe" ]; then
  echo "ok    probe  log holds one parseable JSON line per call"
else
  echo "FAIL  probe  unexpected log contents:"
  cat "$probe_log"
  failures=$((failures + 1))
fi

unset_log=$(mktemp "${TMPDIR:-/tmp}/ola-probe-unset.XXXXXX")
rm -f "$unset_log"
(unset OLA_WORKFLOW_PROBE_LOG; "$GUARD" <<<'{"tool_input":{"command":"git status"}}') >/dev/null 2>&1
total=$((total + 1))
if [ ! -e "$unset_log" ]; then
  echo "ok    probe  nothing written when OLA_WORKFLOW_PROBE_LOG is unset"
else
  echo "FAIL  probe  wrote a log although OLA_WORKFLOW_PROBE_LOG was unset"
  failures=$((failures + 1))
fi
rm -f "$probe_log"

# --- With a profile, and enforcing ----------------------------------------------------
# Everything above runs with no profile, which is the branch that keeps this plugin
# invisible in a project that did not ask for it. What follows needs a profile, because a
# guard only has rules once a project has declared any.
#
# And it needs OLA_WORKFLOW_GUARD=enforce, because the shipped default is log-only: the
# rate of `ask` on real sessions is not measured yet, and a guard switched on before that
# is a guard a human switches off. These cases describe what enforcement does when it is
# turned on; tests/agents.test.sh is what checks that no prompt claims it is on.
WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ola-guard.XXXXXX")" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
export HOME=$WORK/home
mkdir -p "$HOME"

profiled() { # profiled <mode> → a throwaway project with a profile in that mode
  local mode=$1
  local repo=$WORK/$mode
  mkdir -p "$repo/.claude"
  git -C "$repo" -c init.defaultBranch=main init -q 2>/dev/null
  printf '{"mode":"%s","base_branch":"main"}\n' "$mode" >"$repo/.claude/workflow.json"
  printf '%s' "$repo"
}
INTEGRATED=$(profiled integrated)

# enforced <expected> <role> <command> [cwd]
# Same three-way classification as check(), with a profile and enforcement on.
enforced() {
  local expected=$1 agent=$2 cmd=$3 dir=${4:-$INTEGRATED} input output rc
  input=$(jq -n --arg c "$cmd" --arg a "$agent" --arg d "$dir" \
    '{hook_event_name: "PreToolUse", tool_name: "Bash", session_id: "t", cwd: $d,
      tool_input: {command: $c}}
     + (if $a == "" then {} else {agent_type: $a} end)')
  output=$(OLA_WORKFLOW_GUARD=enforce "$GUARD" <<<"$input" 2>/dev/null)
  rc=$?
  report "$expected" "$(classify "$output" "$rc")" "[enforce ${agent:-main}] ${cmd//$'\n'/ ⏎ }"
}

# A command whose command word can be read is allowed: this change adds the question, not
# the prohibitions. The role rules arrive in the task after this one.
for cmd in 'git status' 'make check' 'gh pr view 5' 'gh pr merge 7 --squash' \
           'git push --force origin main' 'npm publish'; do
  enforced allow ola-workflow:developer "$cmd"
done

# A command word nobody can read without running it: asked, never guessed. Refusing would
# refuse $EDITOR file; allowing is the hole this guard exists to close.
for cmd in '$(echo gh) pr merge 7' 'c=gh; $c pr merge 7' '${u:-gh} pr merge' \
           '{gh,git} pr merge' './g? pr merge' 'eval gh pr merge 7' '. ./s.sh' \
           'source ./s.sh' 'trap "gh pr merge 7" EXIT' '$EDITOR notes.md' \
           'nice -q10 gh pr merge'; do
  enforced ask ola-workflow:developer "$cmd"
done

# The reason must name what could not be read. A question a human cannot judge is
# answered by reflex, and then `ask` is `allow` with an extra step.
reason=$(OLA_WORKFLOW_GUARD=enforce "$GUARD" <<<"$(jq -n --arg d "$INTEGRATED" \
  '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"t",cwd:$d,
    tool_input:{command:"$(echo gh) pr merge"}}')" |
  jq -r '.hookSpecificOutput.permissionDecisionReason')
total=$((total + 1))
case $reason in
  *'command substitution'*'$()'*) echo "ok    the question names what it could not read" ;;
  *) echo "FAIL  the question says only: $reason"; failures=$((failures + 1)) ;;
esac

# A profile that exists and cannot be read: the rules are unknown, so nothing can be
# judged. Asked rather than denied, because the human must be able to run the command that
# fixes the file — and the message names the file.
BROKEN=$(profiled integrated)
printf '%s' '{"mode":,,,' >"$BROKEN/.claude/workflow.json"
enforced ask ola-workflow:developer 'git status' "$BROKEN"
broken_reason=$(OLA_WORKFLOW_GUARD=enforce "$GUARD" <<<"$(jq -n --arg d "$BROKEN" \
  '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"t2",cwd:$d,
    tool_input:{command:"git status"}}')" |
  jq -r '.hookSpecificOutput.permissionDecisionReason')
total=$((total + 1))
case $broken_reason in
  *workflow.json*'ola-profile validate'*) echo "ok    an unreadable profile names the file and how to see why" ;;
  *) echo "FAIL  an unreadable profile says only: $broken_reason"; failures=$((failures + 1)) ;;
esac

# The shipped default decides nothing. This is the assertion that makes the log-only
# default a fact rather than an intention.
default_out=$("$GUARD" <<<"$(jq -n --arg d "$INTEGRATED" \
  '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"t3",cwd:$d,
    tool_input:{command:"$(echo gh) pr merge"}}')" 2>/dev/null)
total=$((total + 1))
if [ -z "$default_out" ]; then
  echo "ok    the shipped default allows, so nothing is enforced before it is measured"
else
  echo "FAIL  the default enforced something: $default_out"
  failures=$((failures + 1))
fi

# And it records what it would have decided, which is the whole point of shipping it this
# way: the rate of `ask` is measurable on real sessions before anyone depends on it.
log=$WORK/decisions.jsonl
: >"$log"
OLA_WORKFLOW_GUARD_LOG=$log "$GUARD" <<<"$(jq -n --arg d "$INTEGRATED" \
  '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"t4",cwd:$d,
    agent_type:"ola-workflow:developer",tool_input:{command:"$(echo gh) pr merge"}}')" >/dev/null 2>&1
total=$((total + 1))
if [ "$(jq -r '.verdict' "$log" 2>/dev/null)" = ask ] &&
   [ "$(jq -r '.enforcing' "$log" 2>/dev/null)" = no ] &&
   [ "$(jq -r '.role' "$log" 2>/dev/null)" = developer ]; then
  echo "ok    the log records the verdict, the role, and that it was not enforced"
else
  echo "FAIL  the log says: $(cat "$log")"
  failures=$((failures + 1))
fi

# The role is the part after the last colon: agent_type carries the namespaced name of a
# plugin agent, measured by the A1 spike.
: >"$log"
OLA_WORKFLOW_GUARD_LOG=$log "$GUARD" <<<"$(jq -n --arg d "$INTEGRATED" \
  '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"t5",cwd:$d,
    agent_type:"ola-workflow:pr-reviewer",tool_input:{command:"eval x"}}')" >/dev/null 2>&1
total=$((total + 1))
if [ "$(jq -r '.role' "$log" 2>/dev/null)" = pr-reviewer ]; then
  echo "ok    a namespaced agent_type is reduced to its role"
else
  echo "FAIL  the role was read as: $(jq -r '.role' "$log" 2>/dev/null)"
  failures=$((failures + 1))
fi

# --- A3 rule sections, kept empty on purpose ------------------------------------------
# Merging
# Review status
# Version bump
# Version tags
# Bulk tag pushes, moving or deleting a version tag
# Manual publication
# Text that only mentions a command: messages, bodies, echo, heredoc bodies
# Global options before the subcommand
# Refspecs, --mirror, globs, push.followTags
# Quoted strings and substitutions are not cut apart
# Tags and releases through the REST API and GraphQL
# Declarative commands[] rules from the profile
# Discreet mode: deny and ask
# --------------------------------------------------------------------------------------

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total guard test(s) failed"
  exit 1
fi
echo "all $total guard tests passed"
