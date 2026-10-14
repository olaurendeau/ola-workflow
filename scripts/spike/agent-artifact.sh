#!/usr/bin/env bash
# Can a plugin agent publish a claude.ai artifact, and keep it at the same URL?
#
# The product-designer publishes its design for visual work and maintains it across
# requests. That rests on three things the Claude Code docs do not say for a plugin agent:
#   1. whether `Artifact` in a plugin agent's `tools:` actually hands it the tool;
#   2. whether a second publish with `url` updates the page rather than creating another;
#   3. what the tool's result says, so the designer's prompt can quote it.
#
# The probe agent lives in a throwaway plugin under the output directory, so the shipped
# plugin carries no diagnostic agent for this. It publishes ONE private page in the account
# of whoever runs this; its URL is printed at the end, delete it from claude.ai if you wish.
#
# Headless (`claude -p`) cannot answer: on Claude Code 2.1.299 the Artifact tool is absent
# there even from the main session, so a "no" from this script measures the mode, not the
# agent. Run it with --interactive to get the command for a real session instead.
#
# Usage: scripts/spike/agent-artifact.sh [--interactive] [output directory]
set -uo pipefail

interactive=0
if [ "${1:-}" = --interactive ]; then interactive=1; shift; fi
OUT="${1:-${TMPDIR:-/tmp}/ola-workflow-spike-artifact}"

command -v claude >/dev/null || { echo "spike needs the claude CLI on PATH" >&2; exit 2; }

plugin="$OUT/plugin"
mkdir -p "$plugin/.claude-plugin" "$plugin/agents" "$OUT/page" || exit 1
printf '{\n  "name": "spike-artifact",\n  "version": "0.0.0"\n}\n' \
  >"$plugin/.claude-plugin/plugin.json"
cat >"$plugin/agents/artifact-probe.md" <<'AGENT'
---
name: artifact-probe
description: Diagnostic agent. Publishes one throwaway artifact, then updates it in place. Never use it for real work.
tools: Write, Artifact
---

You exist to answer three questions about the Artifact tool. Do exactly this:

1. Say whether a tool named Artifact is in your tool list: `artifact-tool: yes` or `artifact-tool: no`.
   If no, stop there.
2. Write the file named in the prompt with: <!doctype html><title>Spike artifact</title><p>v1</p>
   Publish it with the Artifact tool (icon "test"). Report `first-url: <url>`.
3. Overwrite the same file with v2 instead of v1, publish the same file again with `url`
   set to the first URL. Report `second-url: <url>`.
4. Quote the first line of each publish result verbatim, as `result-1:` and `result-2:`.
AGENT

page="$OUT/page/index.html"
PROMPT="Call the Agent tool once with subagent_type \"spike-artifact:artifact-probe\" and prompt \"file: $page\". Then print its answer verbatim. If the call fails, quote the error verbatim and stop."
if [ "$interactive" = 1 ]; then
  echo "Start an interactive session with the throwaway plugin:"
  echo "  cd $OUT && claude --plugin-dir $plugin"
  echo "and paste:"
  echo "  $PROMPT"
  exit 0
fi

echo "transcript: $OUT"
echo "claude version: $(claude --version 2>/dev/null)"

printf '%s' "$PROMPT" |
  ( cd "$OUT" && claude -p --plugin-dir "$plugin" --allowedTools Agent Write Artifact ) \
    >"$OUT/answer.txt" 2>"$OUT/answer.err"

echo
cat "$OUT/answer.txt"
[ -s "$OUT/answer.err" ] && { echo "--- stderr"; tail -c 1000 "$OUT/answer.err"; }

first=$(sed -n 's/.*first-url: *\([^ ]*\).*/\1/p' "$OUT/answer.txt" | head -1)
second=$(sed -n 's/.*second-url: *\([^ ]*\).*/\1/p' "$OUT/answer.txt" | head -1)
echo
if [ -n "$first" ] && [ "$first" = "$second" ]; then
  echo "verdict: a plugin agent publishes, and updates in place ($first)"
elif [ -n "$first" ]; then
  echo "verdict: a plugin agent publishes, but the second publish moved ($first -> ${second:-none})"
else
  echo "verdict: no publish from a plugin agent"
fi
