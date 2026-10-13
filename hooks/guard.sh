#!/usr/bin/env bash
# PreToolUse guard: it keeps each sensitive command with the role that owns it.
#
# This script runs on **every** Bash call of **every** project once the plugin is
# installed, which dictates everything about it:
#
#   - a project with no profile has not opted in, so the guard exits 0 before doing
#     anything else, and the only cost is a process;
#   - once a profile exists, the guard runs **fail-closed**: if it breaks, it blocks. A
#     guard that fails open is a guard that silently stops guarding;
#   - it answers in milliseconds, so the resolved profile is cached per session.
#
# Three decisions:
#   allow  nothing on stdout, exit 0 — the only quiet one
#   deny   a permissionDecision on stdout, exit 0
#   ask    the same, with "ask": the human decides
#
# `ask` exists because a shell command cannot always be read. A command word assembled by
# expansion, a body sourced from a file, `eval` — these run a command that is not in the
# text at all, measured. Refusing them would refuse `$EDITOR file`; allowing them is the
# hole this guard exists to close. So the honest answer is to ask, and to say what could
# not be read.
#
# OLA_WORKFLOW_GUARD=enforce turns the decisions on. Until then the guard **logs what it
# would have decided** and allows, because the rate of `ask` on real sessions is not known
# yet: at 1% it is free, at 20% a human switches the guard off and gets no guard at all.
# Measure first. OLA_WORKFLOW_GUARD_LOG names the file; without it, logging is silent.
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOKENIZE=$SELF_DIR/lib/tokenize.pl

input=$(cat)

# Diagnostic tap used by scripts/spike/agent-identity.sh. Kept first and cheap so that a
# spike can always see the raw payload, whatever the guard decides afterwards.
if [ -n "${OLA_WORKFLOW_PROBE_LOG:-}" ]; then
  printf '%s\n' "$input" >>"$OLA_WORKFLOW_PROBE_LOG" 2>/dev/null || true
fi

field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

command_line=$(field '.tool_input.command')
# Nothing to read: another tool, or a payload shape this guard does not know. Not its
# business, and guessing would be.
[ -n "$command_line" ] || exit 0

cwd=$(field '.cwd')
[ -n "$cwd" ] || cwd=$PWD
session=$(field '.session_id')

# shellcheck source=hooks/lib/profile.sh
. "$SELF_DIR/lib/profile.sh"

# ------------------------------------------------------ the profile, resolved once a session
# Resolving a profile costs three subprocesses, and this runs on every Bash call: a session
# of 200 commands would spend seconds on it. The profile cannot change during a session
# unless a human edits it, so the answer is cached — and the cache is invalidated by the
# profile's own mtime, because a cache that serves a stale profile applies the rules of a
# project that no longer exists, which is worse than being slow.
cache=${TMPDIR:-/tmp}/ola-workflow-guard-${session:-nosession}.cache

mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

resolve() {
  local file mode
  if file=$(ola_profile_path "$cwd"); then
    mode=$(ola_profile_mode "$cwd")
    printf '%s\t%s\t%s\t%s\n' "$cwd" "$file" "$mode" "$(mtime_of "$file")"
  else
    printf '%s\t\t\t\n' "$cwd"
  fi
}

cached=""
if [ -n "$session" ] && [ -r "$cache" ]; then
  cached=$(cat "$cache" 2>/dev/null)
fi
if [ -n "$cached" ]; then
  IFS=$'\t' read -r c_cwd c_file _ c_mtime <<<"$cached"
  # Three ways a cache stops being about this project: another directory, a profile that
  # moved or disappeared, a profile that was edited.
  if [ "$c_cwd" != "$cwd" ] ||
     { [ -n "$c_file" ] &&
       { [ ! -f "$c_file" ] || [ "$(mtime_of "$c_file")" != "$c_mtime" ]; }; }; then
    cached=""
  fi
fi
if [ -z "$cached" ]; then
  cached=$(resolve)
  [ -n "$session" ] && { printf '%s\n' "$cached" >"$cache" 2>/dev/null || true; }
fi
IFS=$'\t' read -r _ profile mode _ <<<"$cached"

# No profile: this project has not opted into the workflow, so the guard has nothing to
# apply and says nothing. This is the branch that keeps the plugin invisible everywhere it
# was not asked for, and it is reached before any rule exists.
[ -n "$profile" ] || exit 0

# ------------------------------------------------------------------------- fail closed
# From here a profile exists, so a project is relying on this guard. Anything unexpected
# blocks rather than passes: exit 2 is how a hook says "I could not decide, do not run it".
set -e
trap 'echo "ola-workflow: the guard failed, so this command is blocked. Run: ola-profile validate" >&2; exit 2' ERR

enforcing=no
[ "${OLA_WORKFLOW_GUARD:-}" = enforce ] && enforcing=yes

# The role. agent_type carries the namespaced name of a plugin agent
# (ola-workflow:developer), measured by the A1 spike, so the role is what follows the last
# colon. A session with no agent has no agent_type at all, and is nobody: it gets the same
# answer as a role that owns nothing.
role=$(field '.agent_type'); role=${role##*:}

decide() { # decide <allow|deny|ask> <reason>
  local verdict=$1 reason=$2
  if [ -n "${OLA_WORKFLOW_GUARD_LOG:-}" ]; then
    jq -n -c --arg v "$verdict" --arg r "$reason" --arg role "$role" --arg mode "$mode" \
      --arg cmd "$command_line" --arg enforcing "$enforcing" \
      '{verdict:$v, reason:$r, role:$role, mode:$mode, enforcing:$enforcing, command:$cmd}' \
      >>"$OLA_WORKFLOW_GUARD_LOG" 2>/dev/null || true
  fi
  [ "$verdict" = allow ] && exit 0
  # Not enforcing yet: the decision is recorded and the command runs. The rate of `ask` on
  # real sessions decides whether this becomes enforcement or gets rethought — and a guard
  # switched on before that measurement is a guard a human switches off.
  [ "$enforcing" = yes ] || exit 0
  jq -n --arg d "$verdict" --arg r "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d,
                           permissionDecisionReason: $r}}'
  exit 0
}

# A profile that exists and cannot be read: this project's rules are unknown, so no command
# can be judged against them. Asked rather than denied, because the human has to be able to
# run the very command that fixes the file — and the message names the file.
if ! ola_profile_readable "$profile"; then
  decide ask "ola-workflow: $profile cannot be read, so this project's rules are unknown. Run: ola-profile validate"
fi

# ---------------------------------------------------------------------------- the rules
# One segment per simple command, with its command word normalised. Rules read `command`
# and never `raw`: everything a shell does between the text and the command word is already
# undone there, and a rule written as a regex in a project's profile could undo none of it.
segments=$(printf '%s' "$command_line" | perl "$TOKENIZE")

# Who owns what. The roles come from the brief's own vocabulary, not from this file: a
# project renames nothing here, it declares its reviewer's status name in the profile.
review_status=$(ola_profile_get merge.review_status "$cwd" "" agent-review)

# `has <text> <extended regex>`: the only way a rule reads a segment. It is given the
# normalised field and never the raw one — a rule written as a regex in a project's profile
# cannot undo quoting, so `gh pr "merge"` would walk past a pattern `gh pr merge` trips.
has() { printf '%s' "$1" | grep -qE "$2"; }

while IFS= read -r segment; do
  [ -n "$segment" ] || continue
  readable=$(printf '%s' "$segment" | jq -r '.readable')
  if [ "$readable" = false ]; then
    reason=$(printf '%s' "$segment" | jq -r '.reason')
    resolved=$(printf '%s' "$segment" | jq -r '.resolved')
    decide ask "ola-workflow: this command cannot be read, so no rule can be applied to it — $reason (at: $resolved). Confirm only if you know what it runs."
  fi

  cmd=$(printf '%s' "$segment" | jq -r '.command')
  text=$(printf '%s' "$segment" | jq -r '.normalised')

  # ------------------------------------------------------------------ merging
  # A merge is the one action that makes a change permanent, so it belongs to the one role
  # that has seen the review. The API form counts: a PUT on a pulls/N/merge path merges
  # exactly as the CLI does, and a rule that only knew the CLI would be a rule about
  # spelling rather than about merging.
  # Written with `if` and not `&&`, because under `set -e` a `grep` that does not match
  # makes the whole statement fail and the guard exits 2 — blocking every command on its
  # own bug. Which is what happened, and what the suite said on the first run: the
  # fail-closed branch is not theoretical, and it is reached by a shell idiom.
  merging=no
  if [ "$cmd" = gh ] && has "$text" '(^| )pr( .*)? merge( |$)'; then merging=yes; fi
  if has "$text" 'pulls/[^ /]+/merge' &&
     has "$text" '(-X|--method)[= ]?(PUT|PATCH|POST)'; then merging=yes; fi
  if [ "$merging" = yes ]; then
    # --admin and --auto are refused to everyone, the coordinator included: one bypasses
    # the checks the gate is made of, the other merges later, when nobody is watching and
    # the review no longer applies to the commit that lands.
    if has "$text" '(^| )--(admin|auto)( |$)'; then
      decide deny "ola-workflow: --admin and --auto are refused to every role. --admin merges past the checks this project requires, and --auto merges at a moment when the review no longer applies to what lands. Merge with --match-head-commit on the SHA you checked."
    fi
    if [ "$role" != coordinator ]; then
      decide deny "ola-workflow: only the coordinator merges, once the checks and the $review_status status are successful on the head SHA. Report the pull request to the coordinator instead."
    fi
  fi

  # ---------------------------------------------------- the review status
  # The status is what the merge gate reads, so whoever can write it can let anything
  # through. It belongs to the reviewer alone — including against the coordinator, which
  # would otherwise be able to approve the change it is about to merge.
  if has "$text" 'statuses/' &&
     has "$text" '(-X|--method)[= ]?(POST|PUT|PATCH)|(-f|--field|--raw-field)[= ]?state=' &&
     has "$text" "$review_status"; then
    if [ "$role" != pr-reviewer ]; then
      decide deny "ola-workflow: only the pr-reviewer sets the $review_status status, because it is what the merge gate reads. Ask the coordinator to dispatch a review."
    fi
  fi
done <<<"$segments"

exit 0
