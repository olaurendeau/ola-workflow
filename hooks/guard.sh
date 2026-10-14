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
# Whether the decisions are applied is **the project's** to say, in its profile:
#
#   "guard": "enforce"   refuse and ask. The default, because a profile is how a project
#                        opts in, and a rule nothing applies is not a rule.
#   "guard": "log"       decide exactly the same way, let the command run, and write the
#                        decision to OLA_WORKFLOW_GUARD_LOG if that is set.
#
# It shipped log-only at first, waiting on a number: at 1% of commands asking the question is
# free, at 20% a human switches the guard off and has no guard at all. `make measure` answers
# it now, on a sample that ships with the repository — and no number is written here, because
# three of the ones that were turned out to be wrong, twice because the method was. So the
# default is enforcement, and what it costs is a command away.
#
# OLA_WORKFLOW_GUARD=enforce|log still overrides the profile, for one session: it is how the
# tests pin a mode, and how a human watches before letting it act.
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOKENIZE=$SELF_DIR/lib/tokenize.pl

input=$(cat)

# Diagnostic tap used by scripts/spike/agent-identity.sh. Kept first and cheap so that a
# spike can always see the raw payload, whatever the guard decides afterwards.
if [ -n "${OLA_WORKFLOW_PROBE_LOG:-}" ]; then
  printf '%s\n' "$input" >>"$OLA_WORKFLOW_PROBE_LOG" 2>/dev/null || true
fi

# The tools this guard cannot work without, checked before anything is read.
#
# Without this it failed **open**, which is the one thing the whole design forbids: with `jq`
# off the PATH every `field` call returns empty, so `command_line` is empty, so the guard
# took the "nothing to read" exit — exit 0, silently, with enforcement on and a profile
# present. `gh pr merge 7 --admin` ran. Measured.
#
# The check has to be conditional on a profile the way every other refusal is, and it can
# be: resolving the profile's *path* needs git and the filesystem, not jq. So a missing tool
# in a project that never opted in still costs nothing, and in a project that did it blocks
# and says which tool.
#
# Which project, though, is asked of the **working directory** and not of the payload: the
# payload is JSON and jq is what reads it. That is not a guess — Claude Code runs a hook in
# the session's own directory, so the two agree in practice — and when they do not, the
# answer errs towards blocking, which is the direction this branch exists for. A second JSON
# parser in shell would be a second reader of the same thing, and those drift.
missing_tools=""
for tool in jq perl; do
  command -v "$tool" >/dev/null 2>&1 || missing_tools="$missing_tools $tool"
done

field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

cwd=$(field '.cwd')
[ -n "$cwd" ] || cwd=$(pwd)

if [ -n "$missing_tools" ]; then
  # shellcheck source=hooks/lib/profile.sh
  . "$SELF_DIR/lib/profile.sh"
  if ola_profile_path "$cwd" >/dev/null 2>&1; then
    echo "ola-workflow: the guard needs$missing_tools on PATH and cannot find it, so it cannot judge this command. $cwd has a profile, so the command is blocked rather than allowed." >&2
    exit 2
  fi
  exit 0
fi

command_line=$(field '.tool_input.command')
# Nothing to read: another tool, or a payload shape this guard does not know. Not its
# business, and guessing would be.
[ -n "$command_line" ] || exit 0

session=$(field '.session_id')

# shellcheck source=hooks/lib/profile.sh
. "$SELF_DIR/lib/profile.sh"

# ------------------------------------------------------ the profile, resolved once a session
# Resolving a profile costs three subprocesses, and this runs on every Bash call: a session
# of 200 commands would spend seconds on it. The profile cannot change during a session
# unless a human edits it, so the answer is cached — and the cache is invalidated by the
# profile's own mtime, because a cache that serves a stale profile applies the rules of a
# project that no longer exists, which is worse than being slow.
#
# Two things are deliberately not cached, and in both cases the invalidation has to watch a
# directory rather than the resolved file: the absence of a profile (see below), and — still
# outstanding — the appearance of a *higher-precedence* profile beside a cached
# lower-precedence one. Both need the candidate list, and the guard must not restate where
# profiles live to get it.
cache=${TMPDIR:-/tmp}/ola-workflow-guard-${session:-nosession}.cache
NL='
'

# An mtime is a run of digits, and nothing else is accepted however it was printed. The two
# `stat` dialects disagree about `-f`: on BSD it selects a format, on GNU and busybox it
# means --file-system and **succeeds**, printing a multi-line report about the device. So
# `stat -f %m || stat -c %Y` returned that report on Linux, with tabs and newlines in it,
# which shifted every field after it in the tab-separated cache line — and the field after
# it is now whether the profile is readable. Every command of every test came back
# `ask: this profile cannot be read` on CI while the suite was green on macOS.
#
# Trying the dialects in the other order would fix today's case and leave the shape of the
# defect: a command that succeeds while answering something else. Validating the answer
# closes it whatever stat does, and the fallback of 0 only ever makes the cache miss.
mtime_of() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null)
  case $m in ''|*[!0-9]*) m=$(stat -f %m "$1" 2>/dev/null) ;; esac
  case $m in ''|*[!0-9]*) m=0 ;; esac
  printf '%s' "$m"
}

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
  local file mode readable status guard
  if file=$(ola_profile_path "$cwd"); then
    mode=$(ola_profile_mode "$cwd")
    if ola_profile_readable "$file"; then
      readable=yes
      status=$(ola_profile_get merge.review_status "$cwd" "" agent-review)
      guard=$(ola_profile_get guard "$cwd" "" enforce)
    else
      readable=no
      status=""
      guard=enforce
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$cwd" "$file" "$mode" "$(mtime_of "$file")" "$readable" "$status" "$guard"
  else
    printf '%s\t\t\t\t\t\t\n' "$cwd"
  fi
}

cached=""
if [ -n "$session" ] && [ -r "$cache" ]; then
  cached=$(cat "$cache" 2>/dev/null)
  # One line, seven fields, or it is not a cache entry. A field holding a tab or a newline
  # shifts every field after it, and the fields after the first two decide whether a rule
  # applies at all — so a line that does not parse must read as "nothing cached" and not as
  # a profile whose values have slid one column to the left. That is how a `stat` dialect
  # mismatch turned into "this project's rules are unknown" on every command.
  case $cached in
    *"$NL"*) cached="" ;;
  esac
  if [ -n "$cached" ]; then
    fields=$(printf '%s' "$cached" | awk -F'\t' '{print NF}')
    [ "$fields" = 7 ] || cached=""
  fi
fi
if [ -n "$cached" ]; then
  IFS=$'\t' read -r c_cwd c_file _ c_mtime _ _ _ <<<"$cached"
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
  # "No profile" is never cached. Its invalidation has nothing to key on — there is no file
  # to watch the mtime of — so a cached one survived the whole session, and a project
  # enrolled *during* it stayed ruleless to the end. That is what /ola-workflow:workflow-init
  # does: it writes the profile, reports it written, and the guard it switches on does not
  # come on until the next session. `gh pr merge` included.
  #
  # This is not free, and the first version of this comment claimed it was. Measured, with a
  # ~/.claude/workflow-profiles directory present: **3 git subprocesses on every Bash call**
  # of every project that has no profile, about 56 ms here against 30 ms warm — some 5
  # seconds over a 200-command session, which is the argument that made the cache exist in
  # the first place. The cost is only paid once someone keeps a discreet profile somewhere,
  # because without that directory the remote is never looked up.
  #
  # Correctness over 40 ms, deliberately, until the invalidation can be right: what has to
  # be watched is the **container directory** of each candidate, whose mtime does change
  # when a file appears in it (measured) — not the resolved file, which is what does not
  # exist. That needs the candidate list, and the guard must not restate where profiles live
  # to get it, so it waits for `ola_profile_candidates`.
  IFS=$'\t' read -r _ fresh_file _ _ _ _ _ <<<"$cached"
  [ -n "$session" ] && [ -n "$fresh_file" ] &&
    { printf '%s\n' "$cached" >"$cache" 2>/dev/null || true; }
fi
IFS=$'\t' read -r _ profile mode _ profile_readable review_status guard_mode <<<"$cached"

# No profile: this project has not opted into the workflow, so the guard has nothing to
# apply and says nothing. This is the branch that keeps the plugin invisible everywhere it
# was not asked for, and it is reached before any rule exists.
[ -n "$profile" ] || exit 0

# ------------------------------------------------------------------------- fail closed
# From here a profile exists, so a project is relying on this guard. Anything unexpected
# blocks rather than passes: exit 2 is how a hook says "I could not decide, do not run it".
set -e
trap 'echo "ola-workflow: the guard failed, so this command is blocked. Run: ola-profile validate" >&2; exit 2' ERR

# The profile decides, the environment overrides. The order matters: a project that wrote
# `"guard": "log"` must not be silently enforced by an exported variable it never set, and a
# human watching one session must be able to say so without editing the project's file.
enforcing=yes
case $guard_mode in
  log) enforcing=no ;;
esac
case ${OLA_WORKFLOW_GUARD:-} in
  enforce) enforcing=yes ;;
  log)     enforcing=no ;;
esac

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
# So: `gh_subcommand` for an operation, `has_flag` for a boolean, `opt_value` for what an
# option carries. All three compare with `=`, never with a pattern.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# opt_values <name> … → every value those options carry, one per line, in order.
#
# An option carries its value in seven ways, and reading only some of them is a false
# negative with nothing to show for it. Measured against the real `gh` with GH_DEBUG=api:
#
#   -X PUT          separate word
#   -X=PUT          glued with an equals sign
#   -XPUT           glued, short options only
#   -iXPUT          glued after a group of short flags
#   -iX PUT         the letter ends the group, the value is the next word
#   --method PUT    separate word
#   --method=PUT    glued with an equals sign
#
# Five of the seven were missed at some point, one per review cycle, each time by a list of
# spellings that was one short. So the group is *parsed* rather than pattern-matched: a short
# option group is read left to right, and the first letter that takes a value consumes the
# rest of the word or the next word. That is what `-tX -X PUT` requires — `-t` takes `X` as
# its value, so the `-X` in that word is not an option at all, and reading it as one both
# missed the real method and skipped the word carrying it. A merge, allowed.
#
# Which letters take a value is a table, because guessing is the dangerous direction and the
# guess that every letter before the target is boolean is exactly what broke. A letter in
# neither table makes the reading unknown, and unknown is asked.
GH_SHORT_VALUE=fFHXpqt      # gh api: --raw-field --field --header --method --preview --jq --template
GH_SHORT_BOOL=i             # gh api: --include
OPT_UNREADABLE=no

opt_values() {
  local i=0 n w step group rest letter j held
  OPT_UNREADABLE=no
  while [ "$i" -lt "${#words[@]}" ]; do
    w=${words[$i]}
    step=1
    case $w in
      --*)
        for n in "$@"; do
          case $n in --*) ;; *) continue ;; esac
          if [ "$w" = "$n" ]; then
            [ $((i + 1)) -lt "${#words[@]}" ] && printf '%s\n' "${words[$((i + 1))]}"
            step=2
            break
          fi
          case $w in
            "$n"=*) printf '%s\n' "${w#*=}"; break ;;
          esac
        done ;;
      -?*)
        # A short group. Walk its letters; the first value-taking one ends the group.
        group=${w#-}
        j=0
        while [ "$j" -lt "${#group}" ]; do
          letter=${group:$j:1}
          rest=${group:$((j + 1))}
          case $GH_SHORT_VALUE in
            *"$letter"*)
              # This letter carries the value. Emit it only if it is one the caller asked
              # for; either way the group is over.
              held=""
              if [ -n "$rest" ]; then
                held=${rest#=}
              elif [ $((i + 1)) -lt "${#words[@]}" ]; then
                held=${words[$((i + 1))]}
                step=2
              fi
              for n in "$@"; do
                [ "$n" = "-$letter" ] && printf '%s\n' "$held"
              done
              j=${#group} ;;
            *)
              case $GH_SHORT_BOOL in
                *"$letter"*) j=$((j + 1)) ;;
                *) OPT_UNREADABLE=yes; j=${#group} ;;
              esac ;;
          esac
        done ;;
    esac
    i=$((i + step))
  done
}


# opt_value <name> … → what the LAST of those options carries, because that is the one the
# tool uses: `gh api -X GET -X PUT …` sends a PUT, measured in both orders. Taking the first
# turned every repeated option into a way past the rule.
opt_value() {
  local last
  last=$(opt_values "$@" | tail -1)
  [ -n "$last" ] || return 1
  printf '%s' "$last"
}

# has_flag <--name> → that boolean flag is set. A boolean is also written `--name=true`, and
# `--name=false` *unsets* it — so neither a membership test nor a prefix test will do, and
# `gh pr merge --admin=true` walked past `has_word --admin` while really merging past the
# checks. The last occurrence decides, as it does for a value.
has_flag() {
  local w verdict=1
  for w in ${words[@]+"${words[@]}"}; do
    [ "$w" = "$1" ] && { verdict=0; continue; }
    case $w in
      "$1"=*)
        case $(lower "${w#*=}") in
          false|0|f|no) verdict=1 ;;
          *)            verdict=0 ;;
        esac ;;
    esac
  done
  return "$verdict"
}

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
# Sets GH_SUB and GH_PATH_END rather than printing, because `sub=$(gh_subcommand)` runs the
# function in a subshell and the index it works out there does not come back — which left
# `help_is_the_operation` reading a stale 0 and refusing `gh pr merge --help` again. A
# function with two results has two variables; one of them on stdout buys nothing.
GH_SUB=""
GH_PATH_END=0
gh_subcommand() { # gh_subcommand → 0 and sets GH_SUB/GH_PATH_END; 1 when unreadable
  local i=1 w out=""
  GH_SUB=""
  GH_PATH_END=${#words[@]}
  while [ "$i" -lt "${#words[@]}" ]; do
    w=${words[$i]}
    case $w in
      -*)
        [ -n "$out" ] && { GH_PATH_END=$i; break; }   # the subcommand is already known
        case $w in
          -*=*)             i=$((i + 1)) ;;   # the value is inside the word
          -R|--repo)        i=$((i + 2)) ;;   # takes a value: skip it too
          --help|--version) GH_PATH_END=$i; i=$((i + 1)) ;;   # takes none
          *)                return 1 ;;       # neither table knows it: say so, never assume
        esac ;;
      *) out="$out $w"; i=$((i + 1)) ;;
    esac
  done
  GH_SUB=${out# }
  return 0
}

# A help request performs nothing, so `gh pr merge --help` must not be refused for not
# being the coordinator — a refusal an agent cannot make sense of is how refusals stop being
# read. But `-h` anywhere is not a help request: `gh pr merge 7 --squash --subject -h` gives
# `-h` to `--subject` as its value and **merges**, measured, and the first version of this
# disarmed the rule on exactly that line. Whether a `-h` is a flag or a value depends on
# which options take values, which is a table per subcommand that cannot be kept correct.
#
# So help is honoured only where it is unambiguous: immediately after the subcommand path,
# which is where a human writes it to read the help. Any later `-h` may be an operand, and a
# merge that is refused for mentioning help is a false positive of no consequence, while a
# merge allowed for mentioning help is the hole.
help_is_the_operation() {
  [ "$GH_PATH_END" -lt "${#words[@]}" ] || return 1
  case ${words[$GH_PATH_END]} in
    --help|-h) return 0 ;;
  esac
  return 1
}

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

  # A segment with no words runs no command — a bare assignment, a `done`, a closing brace.
  # There is nothing for a rule to be about, and going on costs more than a skipped loop:
  # under bash 3.2, the only bash macOS ships, `"${words[*]}"` on an empty array trips
  # `set -u` and the fail-closed trap, so every `if … fi`, `for … done` and `esac` in a
  # command line printed `words[*]: unbound variable` — in the shipped mode, on stderr,
  # where nothing in this suite was reading.
  [ "${#words[@]}" -gt 0 ] || continue

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
  if [ "$cmd" = gh ]; then
    if gh_subcommand && ! help_is_the_operation; then
      # The subcommand, by position. `gh pr merge` and nothing that merely contains those
      # words: a label named "ready to merge", a search for `merge`, `gh pr merge --help`.
      case $GH_SUB in
        'pr merge'|'pr merge '*) merging=yes ;;
      esac
    elif ! gh_subcommand; then
      decide ask "ola-workflow: this gh call carries an option I do not know (${words[*]}), so which operation it performs cannot be read and no rule can be applied to it."
    fi
    # The short-option tables are `gh api`'s, so they are consulted for `gh api` and nowhere
    # else. Applied to every `gh` call they asked about `gh -R owner/repo pr merge`, because
    # `-R` is a root flag and not one of `api`'s — a table used outside the command it
    # describes is a table about the wrong thing. Other subcommands carry long flags
    # (`--admin`, `--squash`), which need no splitting.
    case $GH_SUB in
      api|api\ *)
        opt_values -X --method >/dev/null
        if [ "$OPT_UNREADABLE" = yes ]; then
          decide ask "ola-workflow: this gh api call groups short options I cannot split (${words[*]}), so neither the method nor the fields can be read and no rule can be applied to it."
        fi ;;
    esac

    # The API form merges exactly as the CLI does, so a rule that knew only the CLI would
    # be a rule about spelling. The method is compared folded, because gh accepts `-X put`.
    if printf '%s' "${words[*]}" | grep -qE 'pulls/[^ /]+/merge' && ! help_is_the_operation; then
      case $(lower "$(opt_value -X --method || true)") in
        put|patch|post) merging=yes ;;
      esac
    fi
  fi
  if [ "$merging" = yes ]; then
    # --admin and --auto are refused to everyone, the coordinator included: one bypasses
    # the checks the gate is made of, the other merges later, when nobody is watching and
    # the review no longer applies to the commit that lands.
    if has_flag --admin || has_flag --auto; then
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
  # The fields are read through opt_values, not looked for among the words: `-Fstate=success`
  # is one word, and a membership test on `state=…` never saw it.
  writes_status=no
  names_it=no
  from_elsewhere=no
  if printf '%s' "${words[*]}" | grep -qE '(^| )[^ ]*statuses/'; then
    case $(lower "$(opt_value -X --method || true)") in
      post|put|patch) writes_status=yes ;;
    esac
    # `gh api` sends POST as soon as any parameter is added — its own help says so — so a
    # `statuses/` call carrying a field or a body **is** a write with no `-X` in sight.
    # Reading the method alone meant `--input body.json` was not a write at all, so the
    # question below was never asked and a developer set the status the merge gate reads.
    # Measured against the real endpoint.
    # `opt_value --input`, not `has_word --input`: the glued `--input=body.json` is one word,
    # and a membership test never sees it. The same lesson as the eight option spellings,
    # relearned one line later.
    if opt_value --input >/dev/null 2>&1 || [ -n "$(opt_values -f -F --field --raw-field)" ]; then
      writes_status=yes
    fi
    while IFS= read -r field; do
      [ -n "$field" ] || continue
      # Two questions, so two `case` statements. They were arms of one, and a `case` stops
      # at its first match: `-f state=@file` matched `state=*`, so the field was counted as a
      # write and never as a value that is not in this text. One `case` can only answer one
      # question, and these two are independent of each other.
      case $field in
        state=*) writes_status=yes ;;
      esac
      # `-F key=@file` reads the value from a file, and `@-` from stdin: the value is not in
      # this text at all. So is the whole body under `--input`. The rule was detecting the
      # write and then guessing the rest, against this file's own doctrine that an unknown is
      # asked and never guessed — measured, `--input body.json` really sends the status and
      # was allowed to every role.
      case $field in
        *=@*) from_elsewhere=yes ;;
      esac
      [ "$field" = "context=$review_status" ] && names_it=yes
    done <<EOF
$(opt_values -f -F --field --raw-field)
EOF
    opt_value --input >/dev/null 2>&1 && from_elsewhere=yes
  fi
  if [ "$writes_status" = yes ] && [ "$from_elsewhere" = yes ] && [ "$role" != pr-reviewer ]; then
    decide ask "ola-workflow: this writes a commit status and takes its content from a file or from stdin, so whether it sets the $review_status status cannot be read here. Confirm only if you know it does not."
  fi
  if [ "$writes_status" = yes ] && [ "$names_it" = yes ] && [ -n "$review_status" ]; then
    if [ "$role" != pr-reviewer ]; then
      decide deny "ola-workflow: only the pr-reviewer sets the $review_status status, because it is what the merge gate reads. Ask the coordinator to dispatch a review."
    fi
  fi
done <<<"$segments"

exit 0
