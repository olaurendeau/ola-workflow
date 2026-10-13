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

# Everything the guard reads from the profile is resolved here and kept together, because
# resolving twice is resolving differently. The readability gate used to test the *cached*
# path while every accessor below re-resolved from scratch: a user-scope profile appearing
# mid-session — half-written, as a file being saved is — left the gate looking at the old
# readable project file while the accessor hit the new broken one, returned "unusable", and
# tripped the fail-closed trap. Exit 2 on every command for the rest of the session,
# including on `ola-profile validate`, which is the recovery the message names.
#
# So a rule may read nothing but this record. A new rule that needs a new value adds a
# field here, which is visible, rather than reaching for the profile again, which is not.
resolve() {
  local file mode readable status
  if file=$(ola_profile_path "$cwd"); then
    mode=$(ola_profile_mode "$cwd")
    if ola_profile_readable "$file"; then
      readable=yes
      status=$(ola_profile_get merge.review_status "$cwd" "" agent-review)
    else
      readable=no
      status=""
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$cwd" "$file" "$mode" "$(mtime_of "$file")" "$readable" "$status"
  else
    printf '%s\t\t\t\t\t\n' "$cwd"
  fi
}

cached=""
if [ -n "$session" ] && [ -r "$cache" ]; then
  cached=$(cat "$cache" 2>/dev/null)
fi
if [ -n "$cached" ]; then
  IFS=$'\t' read -r c_cwd c_file _ c_mtime _ _ <<<"$cached"
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
IFS=$'\t' read -r _ profile mode _ profile_readable review_status <<<"$cached"

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
if [ "$profile_readable" != yes ]; then
  decide ask "ola-workflow: $profile cannot be read, so this project's rules are unknown. Run: ola-profile validate"
fi

# ---------------------------------------------------------------------------- the rules
# One segment per simple command, with its words already unquoted and its command word
# resolved. Rules read `words` and never `raw`: everything a shell does between the text
# and the command word is already undone there, and a rule written as a regex in a
# project's profile could undo none of it.
segments=$(printf '%s' "$command_line" | perl "$TOKENIZE")

# A rule reads words, not a joined string, and that is what makes it able to say what it
# means. Three defects came from matching the join, all found in one review:
#
#   - a substring cannot be a position, so `(^| )pr( .*)? merge( |$)` refused
#     `gh pr edit 7 --add-label "ready to merge"` — a label, in the words of the project's
#     own process, read as a merge;
#   - a joined string cannot hold a literal, so a review status named `c++-review` reached
#     `grep -E` as a pattern and matched neither itself nor anything else, and an empty one
#     matched every status write there is. Both are schema-valid;
#   - a joined string cannot be case-folded one field at a time, and `gh` accepts
#     `-X put` — measured — which a rule written for `PUT` walked straight past.
#
# So: `gh_subcommand` for an operation, `has_word` for a flag, `opt_value` for what an
# option carries. All three compare with `=`, never with a pattern.
has_word() { # has_word <value>
  local w
  for w in ${words[@]+"${words[@]}"}; do [ "$w" = "$1" ] && return 0; done
  return 1
}
opt_value() { # opt_value <name> … → what the first of those options carries
  local i=0 n w
  while [ "$i" -lt "${#words[@]}" ]; do
    w=${words[$i]}
    for n in "$@"; do
      if [ "$w" = "$n" ]; then
        i=$((i + 1))
        [ "$i" -lt "${#words[@]}" ] && printf '%s' "${words[$i]}"
        return 0
      fi
      case $w in
        "$n"=*) printf '%s' "${w#*=}"; return 0 ;;
      esac
    done
    i=$((i + 1))
  done
  return 1
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# The subcommand path of `gh`, which is what a rule about an operation needs: `gh pr merge`
# is three positions, not a substring. `gh` lets a flag come before the subcommand
# (`gh -R o/r pr view 25` works — measured), so the leading options are walked, with the
# same two tables the tokenizer uses for wrappers and for the same reason: assuming an
# unknown option is boolean is how a rule lands on a value and misses. An option in neither
# table makes the operation unknown, and unknown is asked, never guessed.
# The two tables are a `case`, not a regex handed to grep. A list of option names begins
# with a dash, and `grep -qxE '-R|--repo'` reads its own pattern as options — which is how
# every form came back `ask` on the first run of this very function. `case` compares
# literals, cannot be fed an option, and costs no process.
#
# And the tables apply only to what comes *before* the subcommand. An option that follows
# it belongs to it and cannot change which one it is: `--squash`, `-X`, `--search`,
# `--add-label` are all unknown here, and consulting the tables for them asked about every
# real gh call there is — a 100% ask rate, measured, on the first version of this function.
# So the walk collects the leading run of non-option words and stops at the first option;
# the tables are consulted only while nothing has been collected yet, which is exactly
# where an unknown option could still hide the subcommand.
gh_subcommand() { # gh_subcommand → the leading non-option words after `gh`; 1 if unreadable
  local i=1 w out=""
  while [ "$i" -lt "${#words[@]}" ]; do
    w=${words[$i]}
    case $w in
      -*)
        [ -n "$out" ] && break          # the subcommand is already known
        case $w in
          -*=*)             i=$((i + 1)) ;;   # the value is inside the word
          -R|--repo)        i=$((i + 2)) ;;   # takes a value: skip it too
          --help|--version) i=$((i + 1)) ;;   # takes none
          *)                return 1 ;;       # neither table knows it: say so, never assume
        esac ;;
      *) out="$out $w"; i=$((i + 1)) ;;
    esac
  done
  printf '%s' "${out# }"
}

# A help request performs nothing, whatever it asks about. Without this `gh pr merge --help`
# was refused for not being the coordinator — a refusal that teaches an agent the guard does
# not understand what it is reading, which is how refusals stop being read.
asks_for_help() { has_word --help || has_word -h; }

while IFS= read -r segment; do
  [ -n "$segment" ] || continue
  # One jq call per segment, not one per field: this runs on every Bash call of every
  # project with a profile, and the words come back as lines after the four scalars.
  readable=""; cmd=""; reason=""; resolved=""; words=()
  while IFS= read -r line; do
    case $readable in
      "") readable=$line; continue ;;
    esac
    case ${cmd_read:-} in
      "") cmd=$line; cmd_read=yes; continue ;;
    esac
    case ${reason_read:-} in
      "") reason=$line; reason_read=yes; continue ;;
    esac
    case ${resolved_read:-} in
      "") resolved=$line; resolved_read=yes; continue ;;
    esac
    words+=("$line")
  done < <(printf '%s' "$segment" |
    jq -r '.readable, .command, (.reason // ""), .resolved, (.words[] // empty)')
  unset cmd_read reason_read resolved_read

  if [ "$readable" = false ]; then
    decide ask "ola-workflow: this command cannot be read, so no rule can be applied to it — $reason (at: $resolved). Confirm only if you know what it runs."
  fi

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
  if [ "$cmd" = gh ] && ! asks_for_help; then
    if sub=$(gh_subcommand); then
      # The subcommand, by position. `gh pr merge` and nothing that merely contains those
      # words: a label named "ready to merge", a search for `merge`, `gh pr merge --help`.
      case $sub in
        'pr merge'|'pr merge '*) merging=yes ;;
      esac
    else
      decide ask "ola-workflow: this gh call carries an option I do not know ($(printf '%s' "${words[*]}")), so which operation it performs cannot be read and no rule can be applied to it."
    fi
    # The API form merges exactly as the CLI does, so a rule that knew only the CLI would
    # be a rule about spelling. The method is compared folded, because gh accepts `-X put`.
    if printf '%s' "${words[*]}" | grep -qE 'pulls/[^ /]+/merge'; then
      case $(lower "$(opt_value -X --method || true)") in
        put|patch|post) merging=yes ;;
      esac
    fi
  fi
  if [ "$merging" = yes ]; then
    # --admin and --auto are refused to everyone, the coordinator included: one bypasses
    # the checks the gate is made of, the other merges later, when nobody is watching and
    # the review no longer applies to the commit that lands.
    if has_word --admin || has_word --auto; then
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
  # Each half compared as a value. The status name comes from the project's profile and is
  # therefore arbitrary text — `c++-review` is schema-valid — so it may never reach a regex:
  # as a pattern it matched nothing it was meant to, and an empty one matched everything.
  writes_status=no
  if printf '%s' "${words[*]}" | grep -qE '(^| )[^ ]*statuses/'; then
    case $(lower "$(opt_value -X --method || true)") in
      post|put|patch) writes_status=yes ;;
    esac
    for w in ${words[@]+"${words[@]}"}; do
      case $w in state=*) writes_status=yes ;; esac
    done
  fi
  if [ "$writes_status" = yes ] && [ -n "$review_status" ] &&
     has_word "context=$review_status"; then
    if [ "$role" != pr-reviewer ]; then
      decide deny "ola-workflow: only the pr-reviewer sets the $review_status status, because it is what the merge gate reads. Ask the coordinator to dispatch a review."
    fi
  fi
done <<<"$segments"

exit 0
