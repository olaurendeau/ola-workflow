#!/usr/bin/env bash
# What does a PreToolUse payload hold when the agent comes from a plugin?
#
# Three things the Claude Code docs do not say, and that the hooks, the default session
# agent of B16 and the per-role models all depend on:
#   1. the exact value of agent_type for a plugin agent, as a subagent and as the session
#      agent (--agent);
#   2. whether the settings.json "agent" key accepts a namespaced plugin agent name;
#   3. whether a frontmatter `effort` reaches a plugin subagent at all, and what outranks
#      it. The docs list `effort` as a subagent key and name three keys a plugin agent
#      ignores, `effort` not among them — which is a sentence, not a measurement. The
#      payload carries an `effort` field, so this one can be read rather than believed.
#      Scenario 1 shows the session's, 2 the one `probe` pins, 4-7 whether the same file
#      run as a session agent reads it at all, and 8 what the environment does to it.
#
# The model cannot be measured this way: no payload field carries it.
#
# Nothing is installed: --plugin-dir loads the plugin for one session only, and the
# payloads are written outside the repository. Re-run this after a Claude Code upgrade.
#
# The prompt goes in on stdin, because --allowedTools is variadic and would otherwise
# swallow a trailing prompt argument.
#
# Usage: scripts/spike/agent-identity.sh [output directory]
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/ola-workflow-spike}"
PROBE='Run exactly this command with the Bash tool: echo ola-workflow-probe
Then answer: probe done'

command -v claude >/dev/null || { echo "spike needs the claude CLI on PATH" >&2; exit 2; }
command -v jq >/dev/null || { echo "spike needs jq on PATH" >&2; exit 2; }

mkdir -p "$OUT" || exit 1
echo "payloads and transcripts: $OUT"
echo "claude version: $(claude --version 2>/dev/null)"
echo

labels=()
RUN_DIR="$OUT"

# run <n> <label> <prompt> -- <command...>
run() {
  local n=$1 label=$2 prompt=$3
  local log="$OUT/spike-$n.jsonl"
  shift 4
  : >"$log"
  printf '==> %s: %s\n' "$n" "$label"
  (
    cd "$RUN_DIR" || exit 1
    printf '%s' "$prompt" | OLA_WORKFLOW_PROBE_LOG="$log" "$@" \
      >"$OUT/spike-$n.out" 2>"$OUT/spike-$n.err"
  )
  labels+=("$n|$label")
}

# A project whose own .claude/settings.json pins the agent: the B16 case.
proj="$OUT/project-settings"
mkdir -p "$proj/.claude"
printf '{\n  "agent": "ola-workflow:probe"\n}\n' >"$proj/.claude/settings.json"

run 1 'main session, no agent' "$PROBE" -- \
  claude -p --plugin-dir "$REPO" --allowedTools Bash

run 2 'subagent, namespaced subagent_type' \
  'Call the Agent tool once with subagent_type "ola-workflow:probe" and prompt "go". If the call fails, quote the error verbatim and stop.' -- \
  claude -p --plugin-dir "$REPO" --allowedTools Bash Agent

run 3 'subagent, bare subagent_type' \
  'Call the Agent tool once with subagent_type "probe" and prompt "go". If the call fails, quote the error verbatim and stop.' -- \
  claude -p --plugin-dir "$REPO" --allowedTools Bash Agent

run 4 'session agent, --agent namespaced' "$PROBE" -- \
  claude -p --plugin-dir "$REPO" --agent ola-workflow:probe --allowedTools Bash

run 5 'session agent, --agent bare' "$PROBE" -- \
  claude -p --plugin-dir "$REPO" --agent probe --allowedTools Bash

run 6 'settings "agent" key, via --settings' "$PROBE" -- \
  claude -p --plugin-dir "$REPO" --settings '{"agent":"ola-workflow:probe"}' --allowedTools Bash

RUN_DIR="$proj"
run 7 'settings "agent" key, in .claude/settings.json' "$PROBE" -- \
  claude -p --plugin-dir "$REPO" --setting-sources user,project,local --allowedTools Bash
RUN_DIR="$OUT"

# Scenario 2 again, with an effort in the environment. `probe` pins `effort: low`, and the
# docs say the variable outranks the frontmatter; the payload says whether it does.
run 8 'subagent, CLAUDE_CODE_EFFORT_LEVEL=high' \
  'Call the Agent tool once with subagent_type "ola-workflow:probe" and prompt "go". If the call fails, quote the error verbatim and stop.' -- \
  env CLAUDE_CODE_EFFORT_LEVEL=high claude -p --plugin-dir "$REPO" --allowedTools Bash Agent

echo
printf '%-4s %-48s %-28s %-10s %-8s %s\n' '#' 'scenario' 'agent_type' 'agent_id' 'effort' 'calls'
printf '%-4s %-48s %-28s %-10s %-8s %s\n' '---' '---' '---' '---' '---' '---'
for entry in "${labels[@]}"; do
  n=${entry%%|*}
  label=${entry#*|}
  log="$OUT/spike-$n.jsonl"
  calls=$(grep -c . "$log" 2>/dev/null | tr -d ' ')
  if [ "${calls:-0}" -eq 0 ]; then
    printf '%-4s %-48s %-28s %-10s %-8s %s\n' "$n" "$label" '(no Bash call)' '-' '-' 0
  else
    atype=$(jq -r 'if has("agent_type") then .agent_type else "<absent>" end' "$log" | tail -1)
    aid=$(jq -r 'if has("agent_id") then "present" else "<absent>" end' "$log" | tail -1)
    # `effort` is an object, `{"level": "high"}`, not a string: measured, not assumed.
    effort=$(jq -r 'if has("effort") then (.effort.level // (.effort | tostring)) else "<absent>" end' "$log" | tail -1)
    printf '%-4s %-48s %-28s %-10s %-8s %s\n' "$n" "$label" "$atype" "$aid" "$effort" "$calls"
  fi
done

echo
echo "payload fields available to the hooks (union over every payload recorded):"
cat "$OUT"/spike-*.jsonl 2>/dev/null | jq -rs 'map(keys) | add | unique | join(", ")'

echo
echo "output of the scenarios that produced no Bash call:"
for entry in "${labels[@]}"; do
  n=${entry%%|*}
  if [ ! -s "$OUT/spike-$n.jsonl" ]; then
    echo "--- $n"
    tail -c 700 "$OUT/spike-$n.out" 2>/dev/null
    tail -c 700 "$OUT/spike-$n.err" 2>/dev/null
    echo
  fi
done
