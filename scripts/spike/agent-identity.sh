#!/usr/bin/env bash
# What does a PreToolUse payload hold when the agent comes from a plugin?
#
# Two things the Claude Code docs do not say, and that the guard of A3 and the default
# session agent of B16 both depend on:
#   1. the exact value of agent_type for a plugin agent, as a subagent and as the session
#      agent (--agent);
#   2. whether the settings.json "agent" key accepts a namespaced plugin agent name.
#
# Nothing is installed: --plugin-dir loads the plugin for one session only, and the
# payloads are written outside the repository. Re-run this after a Claude Code upgrade.
#
# Usage: scripts/spike/agent-identity.sh [output directory]
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/ola-workflow-spike}"
PROMPT='Run exactly this command with the Bash tool: echo ola-workflow-probe   Then answer: probe done'

command -v claude >/dev/null || { echo "spike needs the claude CLI on PATH" >&2; exit 2; }
command -v jq >/dev/null || { echo "spike needs jq on PATH" >&2; exit 2; }

mkdir -p "$OUT" || exit 1
echo "payloads and transcripts: $OUT"
echo "claude version: $(claude --version 2>/dev/null)"
echo

labels=()
logs=()

# run <n> <label> -- <command...>   (run from $OUT so no repository is touched)
run() {
  local n=$1 label=$2
  local log="$OUT/spike-$n.jsonl"
  shift 3
  : >"$log"
  printf '==> %s: %s\n' "$n" "$label"
  (cd "$OUT" && OLA_WORKFLOW_PROBE_LOG="$log" "$@" >"$OUT/spike-$n.out" 2>"$OUT/spike-$n.err")
  labels+=("$n|$label")
  logs+=("$log")
}

# A project whose own .claude/settings.json pins the agent: the B16 case.
proj="$OUT/project-settings"
mkdir -p "$proj/.claude"
printf '{\n  "agent": "ola-workflow:probe"\n}\n' >"$proj/.claude/settings.json"

run 1 'main session, no agent' -- \
  claude -p --plugin-dir "$REPO" --allowedTools Bash "$PROMPT"

run 2 'subagent, namespaced subagent_type' -- \
  claude -p --plugin-dir "$REPO" --allowedTools Bash --allowedTools Agent \
  'Call the Agent tool once with subagent_type "ola-workflow:probe" and prompt "go". Then answer: dispatched'

run 3 'subagent, bare subagent_type' -- \
  claude -p --plugin-dir "$REPO" --allowedTools Bash --allowedTools Agent \
  'Call the Agent tool once with subagent_type "probe" and prompt "go". If the call fails, quote the error verbatim and stop.'

run 4 'session agent, --agent namespaced' -- \
  claude -p --plugin-dir "$REPO" --agent ola-workflow:probe --allowedTools Bash "$PROMPT"

run 5 'session agent, --agent bare' -- \
  claude -p --plugin-dir "$REPO" --agent probe --allowedTools Bash "$PROMPT"

run 6 'settings "agent" key, via --settings' -- \
  claude -p --plugin-dir "$REPO" --settings '{"agent":"ola-workflow:probe"}' --allowedTools Bash "$PROMPT"

cd "$proj" || exit 1
run 7 'settings "agent" key, in .claude/settings.json' -- \
  claude -p --plugin-dir "$REPO" --setting-sources user,project,local --allowedTools Bash "$PROMPT"

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
    atype=$(jq -r 'if has("agent_type") then .agent_type else "«absent»" end' "$log" | tail -1)
    aid=$(jq -r 'if has("agent_id") then "present" else "«absent»" end' "$log" | tail -1)
    printf '%-4s %-48s %-28s %-10s %s\n' "$n" "$label" "$atype" "$aid" "$calls"
  fi
done

echo
echo "payload fields available to the guard (from the first payload recorded):"
for log in "${logs[@]}"; do
  if [ -s "$log" ]; then
    jq -r 'keys | join(", ")' "$log" | head -1
    break
  fi
done

echo
echo "error output, where a scenario produced no Bash call:"
for entry in "${labels[@]}"; do
  n=${entry%%|*}
  if [ ! -s "$OUT/spike-$n.jsonl" ]; then
    echo "--- $n"
    tail -c 600 "$OUT/spike-$n.out" 2>/dev/null
    tail -c 600 "$OUT/spike-$n.err" 2>/dev/null
  fi
done
