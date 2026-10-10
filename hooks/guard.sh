#!/usr/bin/env bash
# PreToolUse guard for Bash calls: each sensitive command stays with the role that owns it.
#
# This is the A1 skeleton. A3 ports the real rules from mcp-camptocamp, driven by the
# project profile. Until a profile can be resolved, the guard is deliberately INERT and
# FAIL-OPEN: once the plugin is installed at user level this script runs on every Bash
# call of every project, so a broken guard must never be able to block a session.
#
# Decisions, for when the rules land:
#   - allow: no stdout at all, exit 0
#   - deny:  a hookSpecificOutput JSON on stdout, exit 0
#   - ask:   same shape with permissionDecision "ask" (discreet mode)
#   - fail-closed (exit 2) only once a profile exists.
set -uo pipefail

input=$(cat)

# Diagnostic tap used by scripts/spike/agent-identity.sh: when the variable is set, the
# whole payload is appended as one JSON line. See "Agent identity" in the README.
if [ -n "${OLA_WORKFLOW_PROBE_LOG:-}" ]; then
  printf '%s\n' "$input" >>"$OLA_WORKFLOW_PROBE_LOG" 2>/dev/null || true
fi

exit 0
