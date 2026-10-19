#!/usr/bin/env bash
# What does a PreToolUse payload hold when the agent comes from a plugin?
#
# Two things the Claude Code docs do not say, and that the hooks and the default
# session agent of B16 both depend on:
#   1. the exact value of agent_type for a plugin agent, as a subagent and as the session
#      agent (--agent);
#   2. whether the settings.json "agent" key accepts a namespaced plugin agent name.
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

echo
printf '%-4s %-48s %-28s %-10s %s\n' '#' 'scenario' 'agent_type' 'agent_id' 'calls'
printf '%-4s %-48s %-28s %-10s %s\n' '---' '---' '---' '---' '---'
for entry in "${labels[@]}"; do
  n=${entry%%|*}
  label=${entry#*|}
  log="$OUT/spike-$n.jsonl"
  calls=$(grep -c . "$log" 2>/dev/null | tr -d ' ')
  if [ "${calls:-0}" -eq 0 ]; then
    printf '%-4s %-48s %-28s %-10s %s\n' "$n" "$label" '(no Bash call)' '-' 0
  else
    atype=$(jq -r 'if has("agent_type") then .agent_type else "<absent>" end' "$log" | tail -1)
    aid=$(jq -r 'if has("agent_id") then "present" else "<absent>" end' "$log" | tail -1)
    printf '%-4s %-48s %-28s %-10s %s\n' "$n" "$label" "$atype" "$aid" "$calls"
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
