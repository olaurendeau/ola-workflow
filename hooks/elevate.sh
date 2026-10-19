#!/usr/bin/env bash
# PreToolUse/Bash: two commands, in one exact form each, get a stronger token than the base
# one every agent holds (hooks/session.sh, hooks/lib/github-tokens.sh).
#
#   the coordinator   gh pr merge <N> --squash --match-head-commit <40-hex SHA>
#   the pr-reviewer   gh api [-X POST] repos/<owner>/<repo>/statuses/<40-hex SHA>
#                       -f state=… -f context=<review status> [-f description='…'] [-f target_url=…]
#
# For those, the command is rewritten to run through hooks/lib/with-token.sh and allowed.
# Everything else passes through untouched, as if this hook did not exist: no rewrite, no
# decision, the human's permission rules apply as they are written. That matters, because a
# rewritten command is the one those rules are matched against (measured), so rewriting
# every command would turn every allowlisted one into a question.
#
# This hook never refuses, and nothing depends on it reading a command right. A form it
# does not recognise — a pipe, a `;`, a substitution, `--admin`, a short SHA, another
# role — runs with the base token, and GitHub answers 403. A mistake here costs a merge
# that has to be retried in the right form, never a merge that should not have happened.
# Which is why the forms are recognised by one regular expression each, over a character
# set with no shell metacharacter in it, and why "allow" is safe to answer: what is allowed
# is exactly one simple command, with nothing around it.
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
input=$(cat)

# Diagnostic tap used by scripts/spike/agent-identity.sh to see the raw payload.
if [ -n "${OLA_WORKFLOW_PROBE_LOG:-}" ]; then
  printf '%s\n' "$input" >>"$OLA_WORKFLOW_PROBE_LOG" 2>/dev/null || true
fi

# Without jq nothing is elevated, which is the safe direction: the command runs with the
# base token.
command -v jq >/dev/null 2>&1 || exit 0
field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

command_line=$(field '.tool_input.command')
[ -n "$command_line" ] || exit 0
# One line, or it is not one of the forms.
case $command_line in
  *$'\n'*|*$'\r'*) exit 0 ;;
esac

# Only this plugin's agents. A role name is what follows the plugin prefix, and another
# plugin's `coordinator` is not ours.
agent_type=$(field '.agent_type')
case $agent_type in
  ola-workflow:*) role=${agent_type##*:} ;;
  *) exit 0 ;;
esac

SHA='[0-9a-f]{40}'
MERGE_FORM="^gh pr merge [0-9]+ --squash --match-head-commit $SHA\$"

kind=""
case $role in
  coordinator)
    [[ $command_line =~ $MERGE_FORM ]] && kind=merge ;;
  pr-reviewer)
    [[ $command_line == "gh api "*statuses/* ]] && kind=review ;;
esac
# Cheap so far: nothing above read the profile, and almost every command stops here.
[ -n "$kind" ] || exit 0

# shellcheck source=hooks/lib/profile.sh
. "$SELF_DIR/lib/profile.sh"
cwd=$(field '.cwd')
[ -n "$cwd" ] || cwd=$(pwd)
ola_profile_path "$cwd" >/dev/null 2>&1 || exit 0
[ "$(ola_profile_mode "$cwd" 2>/dev/null)" = integrated ] || exit 0
[ "$(ola_profile_get github_tokens "$cwd" "" keychain 2>/dev/null)" = off ] && exit 0

if [ "$kind" = review ]; then
  # The context is the profile's review status, and only a plain name is accepted: it goes
  # into the expression below, and a name with a regex or shell metacharacter in it is not
  # elevated at all rather than escaped. `.` is the one ERE metacharacter the set lets
  # through, and it is escaped.
  context=$(ola_profile_get merge.review_status "$cwd" "" agent-review 2>/dev/null)
  case $context in
    ''|*[!A-Za-z0-9._/-]*) exit 0 ;;
  esac
  context_re=${context//./\\.}
  q="'"
  repo='repos/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|\{owner\}/\{repo\})'
  # A description in single quotes may hold anything but a single quote; in double quotes,
  # nothing the shell would expand. A URL is unquoted and holds no metacharacter.
  description="description=(${q}[^${q}]*${q}|\"[^\"\$\`\\\\]*\")"
  fields="-f (state=(success|failure|error|pending)|context=$context_re|$description|target_url=https://[A-Za-z0-9/._~:%#=+@-]+)"
  status_form="^gh api (-X POST |--method POST )?$repo/statuses/$SHA( $fields)+\$"
  # The form says which fields may appear, not that the two which matter do.
  has_state=' -f state='
  has_context=" -f context=$context_re( |\$)"
  [[ $command_line =~ $status_form ]] || exit 0
  [[ $command_line =~ $has_state ]] || exit 0
  [[ $command_line =~ $has_context ]] || exit 0
fi

rewritten="bash $(printf '%q' "$SELF_DIR/lib/with-token.sh") $kind $command_line"
printf '%s' "$input" | jq -c --arg c "$rewritten" --arg r "ola-workflow: the $role runs this with the $kind token" '
  {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow",
                        permissionDecisionReason: $r,
                        updatedInput: (.tool_input + {command: $c})}}'
