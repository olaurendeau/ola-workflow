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

REAL_GUARD="$(cd "$(dirname "$0")/.." && pwd)/hooks/guard.sh"
failures=0
total=0

# $GUARD is a wrapper, and every site in this file runs it rather than the guard directly.
# A guard that writes to stderr while deciding correctly is a guard whose own bug is
# invisible: `"${words[*]}"` on an empty array trips `set -u` under bash 3.2 — the only bash
# macOS ships — so every `if … fi` and `for … done` in a command line printed
# `words[*]: unbound variable`, in the shipped mode, while this suite stayed green because
# every site redirected stderr to /dev/null.
#
# The first fix was a `noisy()` helper called from the two sites that came to mind. A review
# measured it: **2 of 15**, and the three it missed most were the shipped mode, the
# no-profile branch — which runs on every Bash call of every project — and the log. A check
# that has to be remembered at each site is a check that covers the sites someone
# remembered. A wrapper covers them by construction, including the ones written next year.
#
# Exit 2 is the exception: that path exists to explain itself on stderr.
GUARD_HOME=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ola-wrap.XXXXXX")" && pwd -P)
GUARD=$GUARD_HOME/guard
STDERR_LOG=$GUARD_HOME/stderr.log
: >"$STDERR_LOG"
cat >"$GUARD" <<WRAP
#!/usr/bin/env bash
err=\$(mktemp "$GUARD_HOME/err.XXXXXX")
bash "$REAL_GUARD" 2>"\$err"
rc=\$?
if [ -s "\$err" ] && [ "\$rc" != 2 ]; then
  printf '%s\\n' "\$(head -1 "\$err")" >>"$STDERR_LOG"
fi
cat "\$err" >&2
rm -f "\$err"
exit "\$rc"
WRAP
chmod +x "$GUARD"

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
  # The directory is unique per call, not named after the mode. Two calls with the same
  # mode used to hand back the same path, so corrupting the profile of the second one
  # corrupted the first one's too — and every later test got `ask: this profile cannot be
  # read` while reading as though the rule under test had fired. 100 failures, one cause.
  # Fixed by construction rather than by a check: a fixture that cannot collide needs no
  # assertion saying it did not.
  local mode=$1
  local repo
  repo=$(cd "$(mktemp -d "$WORK/$mode.XXXXXX")" && pwd -P)
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

# A command whose command word can be read, and that no rule claims, is allowed. The two
# last ones are deliberate: pushing to a base branch and publishing are refusals this guard
# does not have yet, and listing them here is what will make their arrival visible — the row
# has to be moved, it cannot stay and pass.
for cmd in 'git status' 'make check' 'gh pr view 5' \
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

# --- Merging belongs to the coordinator -----------------------------------------------
# The role matrix, under every spelling the shell accepts. The normalised command word is
# what makes the last three of these fail for a developer, where the implementation this
# is ported from allowed them: its patterns match the text, and `g\h`, `env FOO=1 gh` and
# `exec gh` are not that text.
MERGE_FORMS=(
  'gh pr merge 7 --squash'
  'gh  pr   merge 7'
  'gh -R owner/repo pr merge 7'
  'gh api -X PUT repos/o/r/pulls/7/merge'
  'gh api --method PUT repos/{owner}/{repo}/pulls/7/merge'
  'g\h pr merge 7'
  'env FOO=1 gh pr merge 7'
  '(exec gh pr merge 7)'
  'nice -n5 gh pr merge 7'
  'true && gh pr merge 7'
  'f () { gh pr merge 7; }; f'
  'case x in x) gh pr merge 7 ;; esac'
)
for cmd in "${MERGE_FORMS[@]}"; do
  enforced allow ola-workflow:coordinator "$cmd"
  for role in ola-workflow:developer ola-workflow:pr-reviewer ola-workflow:architect ""; do
    enforced deny "$role" "$cmd"
  done
done

# --admin and --auto are refused to everyone, the coordinator included: one merges past the
# checks the gate is made of, the other merges when the review no longer applies to what
# lands.
for cmd in 'gh pr merge 7 --admin' 'gh pr merge 7 --squash --auto' 'gh pr merge --auto 7'; do
  for role in ola-workflow:coordinator ola-workflow:developer ""; do
    enforced deny "$role" "$cmd"
  done
done

# What is not merging stays allowed, for every role. A guard whose refusals are not
# believed is a guard that gets switched off, and the fastest way there is a false
# positive on an ordinary command.
for cmd in 'gh pr view 7 --json mergeStateStatus' 'gh pr list' 'gh pr checks 7' \
           'gh api repos/o/r/pulls/7' 'gh api -X GET repos/o/r/pulls/7/merge' \
           'git log --grep="pr merge"' 'git merge origin/main' \
           'gh pr comment 7 -b "someone should gh pr merge this"' \
           'gh issue create -t "merge" -b "the merge is blocked"' \
           'echo "gh pr merge 7"'; do
  for role in ola-workflow:coordinator ola-workflow:developer ""; do
    enforced allow "$role" "$cmd"
  done
done

# --- The review status belongs to the reviewer ----------------------------------------
# It is what the merge gate reads, so whoever writes it can let anything through — the
# coordinator included, which would otherwise approve the change it is about to merge.
STATUS=$(profiled integrated)
printf '%s\n' '{"mode":"integrated","merge":{"review_status":"relu-par-agent"}}' \
  >"$STATUS/.claude/workflow.json"
for cmd in 'gh api repos/o/r/statuses/abc -f state=success -f context=relu-par-agent' \
           'gh api -X POST repos/o/r/statuses/abc -f context=relu-par-agent -f state=failure' \
           'gh api --method POST repos/{owner}/{repo}/statuses/$SHA --raw-field state=success --raw-field context=relu-par-agent'; do
  enforced allow ola-workflow:pr-reviewer "$cmd" "$STATUS"
  for role in ola-workflow:coordinator ola-workflow:developer ""; do
    enforced deny "$role" "$cmd" "$STATUS"
  done
done

# The name comes from the profile, so a project that calls its status something else is
# protected on its own name and not on ours.
enforced allow ola-workflow:developer \
  'gh api repos/o/r/statuses/abc -f state=success -f context=agent-review' "$STATUS"
enforced allow ola-workflow:developer \
  'gh api repos/o/r/statuses/abc -f state=success -f context=something-else' "$STATUS"
# Reading a status is not writing one.
enforced allow ola-workflow:developer \
  'gh api repos/o/r/statuses/abc' "$STATUS"
enforced allow ola-workflow:developer \
  'gh api -X GET repos/o/r/commits/abc/statuses' "$STATUS"

# --- What a word-level rule can say, and a joined string could not -------------------
# Every row here is a defect found in review of the first version, which matched a joined
# string with regexes. They are grouped because they share one cause and one fix, and kept
# as behaviour rather than as a note so the interface cannot quietly go back.

# A substring is not a position. A label named in the project's own process vocabulary, a
# search, a help request: none of them merges, and all three were refused.
for cmd in 'gh pr edit 7 --add-label "ready to merge"' \
           'gh pr edit 7 --add-label "do not merge"' \
           'gh pr list --search merge' \
           'gh issue list --search "pr merge"' \
           'gh issue create -t "merge the thing" -b "about pr merge"' \
           'gh pr merge --help' \
           'gh pr merge -h' \
           'gh pr comment 7 -b "ask the coordinator to gh pr merge this"'; do
  enforced allow ola-workflow:developer "$cmd"
done

# `gh` folds the case of an API method — measured against the real forge — so a rule
# written for PUT and read as text walked past `-X put`.
for cmd in 'gh api -X put repos/o/r/pulls/7/merge' \
           'gh api -X Put repos/o/r/pulls/7/merge' \
           'gh api --method=post repos/o/r/pulls/7/merge' \
           'gh api --method patch repos/o/r/pulls/7/merge'; do
  enforced deny ola-workflow:developer "$cmd"
  enforced allow ola-workflow:coordinator "$cmd"
done

# `-F`/`--field` carry `state=success` in `gh api`, so emptying them as prose blinded the
# one rule that has to read a field. One file of this plugin was blanking the word the
# other asked a rule to match.
for cmd in 'gh api -X POST repos/o/r/statuses/abc -F state=success -F context=relu-par-agent' \
           'gh api repos/o/r/statuses/abc --field state=success --field context=relu-par-agent'; do
  enforced allow ola-workflow:pr-reviewer "$cmd" "$STATUS"
  enforced deny ola-workflow:developer "$cmd" "$STATUS"
done

# `--` ends options, so these run exactly what the same line without it runs. It is the
# form an enumeration of option spellings always misses, being the one that is not an
# option — and `env -S` takes a program, not a value.
for cmd in 'bash -c -- "gh pr merge 7"' 'sh -c -- "gh pr merge 7"' 'env -S "gh pr merge 7"'; do
  enforced deny ola-workflow:developer "$cmd"
done

# A command word cannot hold a blank: the shell would look for a file of that name. So it
# is always a program this tokenizer failed to recognise, and asking is the net under the
# whole family rather than under the spellings that have been thought of.
enforced ask ola-workflow:developer 'env -u X -S "gh pr merge 7"'

# `[` is the POSIX test builtin and bash runs it as a command word. It was answered `ask`,
# about the shell's own grammar, because `[` is also a glob metacharacter — and a bracket
# expression has to close to be one.
for cmd in '[ -f x ]' '[ "$a" = b ] && make check' '[[ -f x ]]'; do
  enforced allow ola-workflow:developer "$cmd"
done

# A review status is arbitrary text from a project's profile, so it may never reach a
# regex. Both of these are schema-valid, and as patterns one matched nothing it was meant
# to while the other matched every status write there is.
LITERAL=$(profiled integrated)
printf '%s\n' '{"mode":"integrated","merge":{"review_status":"c++ review"}}' \
  >"$LITERAL/.claude/workflow.json"
enforced deny ola-workflow:developer \
  'gh api -X POST repos/o/r/statuses/abc -f state=success -f "context=c++ review"' "$LITERAL"
enforced allow ola-workflow:pr-reviewer \
  'gh api -X POST repos/o/r/statuses/abc -f state=success -f "context=c++ review"' "$LITERAL"
# And a status that is not this project's stays none of the rule's business.
enforced allow ola-workflow:developer \
  'gh api -X POST repos/o/r/statuses/abc -f state=success -f context=cpp-review' "$LITERAL"

EMPTY=$(profiled integrated)
printf '%s\n' '{"mode":"integrated","merge":{"review_status":""}}' >"$EMPTY/.claude/workflow.json"
enforced allow ola-workflow:developer \
  'gh api -X POST repos/o/r/statuses/abc -f state=success -f context=build' "$EMPTY"

# An option neither table knows, *before* the subcommand, could still be hiding which
# operation this is — so it is asked. After the subcommand it cannot, which is why every
# real `gh` call above is answered rather than asked.
enforced ask ola-workflow:developer 'gh --made-up pr view 7'

# --- The five ways an option carries its value ---------------------------------------
# Moving the rules from a joined string to words lost coverage the messy version had by
# accident: its `[= ]?` was optional, so it caught two of the three glued forms, while a
# whole-word comparison caught none. Four authorisation regressions in one change, each one
# a role merging or writing the review status. So the forms live here and not in anyone's
# memory, and every one is a form `gh` really accepts — measured with GH_DEBUG=api.
#
# The sixth was missed by the list of five, and the seventh by the list of six — which is
# the whole lesson. pflag **groups** short options, and the value follows the letter
# wherever it sits: glued when the letter is inside the group (`-ifstate=success`), the next
# word when it ends it (`-if state=success`). Both really send the field. So the reading is
# derived from the construct — the letter anywhere in a run of letters, then either the rest
# of the word or the next word — rather than being another row in a list that will miss an
# eighth.
#
# The eighth broke the construct itself, not another spelling: the group was read as "every
# letter before the target is boolean", and in `gh api` only `-i` is. `-t`, `-q`, `-p`, `-H`,
# `-f`, `-F` all take values, so `-tX -X PUT` is `-t` carrying `X` — the `-X` in that word is
# not an option at all. Reading it as one both missed the real method and **skipped the word
# carrying it**. The group is parsed now, left to right, against a table of which letters
# take a value; a letter in neither table makes the reading unknown, and unknown is asked.
#
# Every row below is a form the real `gh` accepts, checked with GH_DEBUG=api. `-vXPUT` was
# in this table for one cycle and is not: `gh` answers `unknown shorthand flag: 'v'`, so it
# asserted a refusal of something nobody can run.
for form in '-X PUT' '-X=PUT' '-XPUT' '--method PUT' '--method=PUT' '-iXPUT' '-iX PUT' \
            '-tX -X PUT' '-qX -X PUT' '-pX -X PUT' '-HX:1 -X PUT'; do
  enforced deny ola-workflow:developer "gh api $form repos/o/r/pulls/7/merge"
  enforced allow ola-workflow:coordinator "gh api $form repos/o/r/pulls/7/merge"
done
# The same five, for the fields that name the review status.
for form in '-f state=success -f context=relu-par-agent' \
            '-f=state=success -f=context=relu-par-agent' \
            '-fstate=success -fcontext=relu-par-agent' \
            '--field state=success --field context=relu-par-agent' \
            '--field=state=success --field=context=relu-par-agent' \
            '-Fstate=success -Fcontext=relu-par-agent' \
            '-ifstate=success -ifcontext=relu-par-agent' \
            '-iFstate=success -iFcontext=relu-par-agent' \
            '-if state=success -if context=relu-par-agent' \
            '-iF state=success -iF context=relu-par-agent' \
            '-tf -F state=success -F context=relu-par-agent' \
            '-qf -f state=success -f context=relu-par-agent'; do
  enforced deny ola-workflow:developer "gh api -X POST repos/o/r/statuses/abc $form" "$STATUS"
  enforced allow ola-workflow:pr-reviewer "gh api -X POST repos/o/r/statuses/abc $form" "$STATUS"
done

# An option repeated: the tool uses the last one, measured in both orders, so reading the
# first turned every repetition into a way past the rule.
enforced deny ola-workflow:developer 'gh api -X GET -X PUT repos/o/r/pulls/7/merge'
enforced deny ola-workflow:developer 'gh api --method=GET --method=PUT repos/o/r/pulls/7/merge'
enforced allow ola-workflow:developer 'gh api -X PUT -X GET repos/o/r/pulls/7/merge'

# A boolean is also written `--name=true`, and `--name=false` unsets it. `--admin=true`
# really merges past the checks, and walked past a membership test on `--admin`.
for form in '--admin' '--admin=true' '--admin=1' '--auto' '--auto=true' '--auto=yes'; do
  enforced deny ola-workflow:coordinator "gh pr merge 7 $form"
done
enforced allow ola-workflow:coordinator 'gh pr merge 7 --admin=false'
enforced allow ola-workflow:coordinator 'gh pr merge 7 --auto=0'

# `-h` is a help request only where it cannot be an operand. `--subject -h` gives `-h` to
# `--subject` as its value and **merges** — measured — and honouring help anywhere disarmed
# the rule on exactly that line.
enforced allow ola-workflow:developer 'gh pr merge --help'
enforced allow ola-workflow:developer 'gh pr merge -h'
enforced allow ola-workflow:developer 'gh pr merge 7 --help'
enforced deny ola-workflow:developer 'gh pr merge 7 --squash --subject -h'
enforced deny ola-workflow:developer 'gh pr merge 7 --subject --help'

# --- The cache line keeps its shape ---------------------------------------------------
# The cache is one tab-separated line, so a field holding a tab or a newline shifts every
# field after it — and the fields after the first two decide whether a rule applies at all.
# That is not hypothetical: `stat -f %m` selects a format on BSD and means --file-system on
# GNU and busybox, where it **succeeds** and prints a multi-line report about the device. On
# Linux every command of every test came back `ask: this profile cannot be read`, while this
# suite was green on macOS. The suite could not see it; the CI could, and did.
#
# So the shape is asserted on whatever platform this runs, rather than the dialect being
# enumerated: one line, six fields. A command that succeeds while answering something else
# is caught by its answer, not by its name.
SHAPE=$(profiled integrated)
# The guard is called directly to warm the cache, not through `enforced`. That helper counts
# an assertion, and `enforced … >/dev/null` therefore counted a verdict whose line went to
# /dev/null: the suite announced 317 and printed 316, in the very block whose subject is a
# field that slid. An assertion whose output is discarded is an assertion that is not read.
jq -n --arg d "$SHAPE" '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"shape",
  cwd:$d,agent_type:"ola-workflow:developer",tool_input:{command:"git status"}}' |
  OLA_WORKFLOW_GUARD=enforce "$GUARD" >/dev/null 2>&1
shape_file=${TMPDIR:-/tmp}/ola-workflow-guard-shape.cache
total=$((total + 1))
if [ ! -f "$shape_file" ]; then
  echo "FAIL  the cache was never written, so its shape is untested"
  failures=$((failures + 1))
elif [ "$(wc -l <"$shape_file" | tr -d ' ')" = 1 ] &&
     [ "$(awk -F'\t' 'END {print NF}' "$shape_file")" = 6 ]; then
  echo "ok    the cache is one line of six fields, whatever stat prints here"
else
  echo "FAIL  the cache is $(wc -l <"$shape_file" | tr -d ' ') line(s) of $(awk -F'\t' 'END {print NF}' "$shape_file") field(s): every field after a corrupt one has slid"
  failures=$((failures + 1))
fi

# And a line that does not parse reads as nothing cached, never as a profile whose values
# have slid one column.
#
# The first version of these two rows wrote the corrupt line to `…-shape.cache` while
# `enforced` sends `session_id: "t"` and the guard therefore reads `…-t.cache`. They passed,
# and deleting the whole validation from guard.sh left the suite green: the check that
# watches for a thing with no reader had no reader. So the file written is the one the helper
# actually makes the guard read, named once here and used by both rows.
# The rows that read the validation must have a **valid first field**, because the cwd check
# runs before it: four earlier rows all began with something other than the cwd, so the
# pre-existing directory invalidation threw them away and the validation was never reached.
# Deleting it from guard.sh left the suite green — the check that watches for a thing with no
# reader had no reader, twice in a row, and the second time the negative test that was
# supposed to prove otherwise only passed by deleting one line too many and causing a syntax
# error. So the line below is a *truncated* cache entry whose first four fields are real: it
# is the shape the stat dialect actually produced, and without the validation its empty
# review_status silently disarms the status rule.
# The mtime has to be the real one too, or the mtime check discards the line first and the
# field count is still never reached — which is exactly what the previous attempt did, so
# removing the validation *again* left the suite green. Every earlier field must be valid for
# the last check to be the one under test.
enforced_cache=${TMPDIR:-/tmp}/ola-workflow-guard-t.cache
shape_profile=$SHAPE/.claude/workflow.json
shape_mtime=$(stat -c %Y "$shape_profile" 2>/dev/null)
case $shape_mtime in ''|*[!0-9]*) shape_mtime=$(stat -f %m "$shape_profile" 2>/dev/null) ;; esac
truncated=$(printf '%s\t%s\tintegrated\t%s\tyes' "$SHAPE" "$shape_profile" "$shape_mtime")
printf '%s\n' "$truncated" >"$enforced_cache"
enforced deny ola-workflow:developer \
  'gh api -X POST repos/o/r/statuses/abc -f state=success -f context=agent-review' "$SHAPE"
# And the shapes whose first field is wrong are discarded by the cwd check, which is the
# other half of the same guarantee: either way, nothing cached is served.
printf 'one\ttwo\n' >"$enforced_cache"
enforced allow ola-workflow:developer 'git status' "$SHAPE"
printf 'a\tb\tc\nd\te\tf\n' >"$enforced_cache"
enforced deny ola-workflow:developer 'gh pr merge 7' "$SHAPE"
printf 'a\tb\tc\td\te\tf\tg\n' >"$enforced_cache"
enforced deny ola-workflow:developer 'gh pr merge 7' "$SHAPE"
: >"$enforced_cache"
enforced deny ola-workflow:developer 'gh pr merge 7' "$SHAPE"
rm -f "$enforced_cache" "$shape_file"

# --- A project that enrols during a session gets its rules at once -------------------
# The absence of a profile is not cached, because its invalidation has nothing to key on:
# there is no file to watch. A cached absence survived the whole session, so a project
# enrolled during it stayed ruleless to the end — which is exactly what
# /ola-workflow:workflow-init does: it writes the profile, reports it written, and the guard
# it switches on does not come on until the next session. `gh pr merge` included.
LATE=$(cd "$(mktemp -d "$WORK/late.XXXXXX")" && pwd -P)
git -C "$LATE" -c init.defaultBranch=main init -q 2>/dev/null
late_run() { # late_run <command> → the decision, on one fixed session id
  # Through classify(), not through a second jq of its own: `jq -r '… // "allow"'` prints
  # *nothing* on empty input — the default applies to a value that is null, not to the
  # absence of any value — so an allow came back as the empty string and the witness failed
  # while the guard was right. One classifier, the harness's.
  local out rc
  out=$(jq -n --arg c "$1" --arg d "$LATE" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"late",cwd:$d,
      agent_type:"ola-workflow:developer",tool_input:{command:$c}}' |
    OLA_WORKFLOW_GUARD=enforce "$GUARD" 2>/dev/null)
  rc=$?
  classify "$out" "$rc"
}
total=$((total + 1))
late_first=$(late_run 'gh pr merge 7')
if [ "$late_first" = allow ]; then
  echo "ok    witness: with no profile the guard decides nothing, so the next line measures the change"
else
  echo "FAIL  witness: the guard decided '$late_first' for a project with no profile"
  failures=$((failures + 1))
fi
mkdir -p "$LATE/.claude"
printf '%s\n' '{"mode":"integrated"}' >"$LATE/.claude/workflow.json"
total=$((total + 1))
if [ "$(late_run 'gh pr merge 7')" = deny ]; then
  echo "ok    a profile written mid-session applies to the very next command"
else
  echo "FAIL  a project that enrolled mid-session is still ruleless in that session"
  failures=$((failures + 1))
fi

# --- A short-option group this guard cannot split is asked about ---------------------
# The tables say which of `gh api`'s short options take a value, and a letter in neither is
# an admission rather than a guess — the guess that every letter before the target is boolean
# is what let `-tX -X PUT` merge.
enforced ask ola-workflow:developer 'gh api -zX PUT repos/o/r/pulls/7/merge'
enforced ask ola-workflow:developer 'gh api -iz repos/o/r/statuses/abc'
enforced ask ola-workflow:coordinator 'gh api -zX PUT repos/o/r/pulls/7/merge'

# And the tables are `gh api`'s, so they are not consulted elsewhere: `-R` is a root flag and
# not one of `api`'s, and asking about `gh -R owner/repo pr merge` is a table used outside
# the command it describes. Measured — that is what the first version of this did.
enforced deny ola-workflow:developer 'gh -R owner/repo pr merge 7'
enforced allow ola-workflow:coordinator 'gh -R owner/repo pr merge 7'
enforced allow ola-workflow:developer 'gh pr list --search merge'
enforced allow ola-workflow:developer 'gh pr edit 7 --add-label "ready to merge"'

# --- A payload that is not in the text is asked about, not guessed -------------------
# `-F key=@file` reads the value from a file and `@-` from stdin; `--input` sends a whole
# body from one. Measured: `gh api -X POST …/statuses/abc --input body.json` really sets the
# status, and the rule detected the write and then **guessed** the rest — against this
# guard's own doctrine that an unknown is asked and never guessed, written three screens up.
for cmd in 'gh api -X POST repos/o/r/statuses/abc --input body.json' \
           'gh api -X POST repos/o/r/statuses/abc -F state=success -F context=@ctx.txt' \
           'gh api -X POST repos/o/r/statuses/abc -F state=success -F context=@-'; do
  enforced ask ola-workflow:developer "$cmd" "$STATUS"
  enforced ask ola-workflow:coordinator "$cmd" "$STATUS"
  # The reviewer owns the status, so for it there is nothing to ask about.
  enforced allow ola-workflow:pr-reviewer "$cmd" "$STATUS"
done
# A write whose content *is* in the text is still decided, not asked.
enforced deny ola-workflow:developer \
  'gh api -X POST repos/o/r/statuses/abc -f state=success -f context=relu-par-agent' "$STATUS"
enforced allow ola-workflow:developer \
  'gh api -X POST repos/o/r/statuses/abc -f state=success -f context=other-ci' "$STATUS"

# --- A missing tool blocks, it does not pass -----------------------------------------
# The guard failed **open**, which is the one thing its whole design forbids: with `jq` off
# the PATH every field read returns empty, so the command line read as empty, so it took the
# "nothing to read" exit — 0, silently, with enforcement on and a profile present.
# `gh pr merge 7 --admin` ran. The check is conditional on a profile like every other
# refusal, which it can be: resolving the profile's *path* needs git and the filesystem, not
# jq.
BARE=$(cd "$(mktemp -d "$WORK/bare.XXXXXX")" && pwd -P)
git -C "$BARE" -c init.defaultBranch=main init -q 2>/dev/null
toolless=$WORK/toolless
mkdir -p "$toolless"
for t in bash cat git stat sed grep tr awk head tail wc mktemp dirname perl env; do
  src=$(command -v "$t" 2>/dev/null) && ln -sf "$src" "$toolless/$t"
done

# Run **from** the directory, not with it in the payload: without jq the payload cannot be
# read at all, so the guard asks about its working directory — which is the directory Claude
# Code runs a hook in. A fixture that puts the project in the payload and runs somewhere else
# measures a shape that does not occur, and it measured the wrong project: the repository
# this suite lives in, which has a profile.
without_jq() { # without_jq <cwd> <command> → the exit status, with jq off the PATH
  local payload
  payload=$(jq -n --arg c "$2" --arg d "$1" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"nojq",cwd:$d,
      agent_type:"ola-workflow:developer",tool_input:{command:$c}}')
  ( cd "$1" && printf '%s' "$payload" |
      PATH="$toolless" OLA_WORKFLOW_GUARD=enforce "$GUARD" >/dev/null 2>&1 )
  echo $?
}
total=$((total + 1))
if [ "$(without_jq "$INTEGRATED" 'gh pr merge 7 --admin')" = 2 ]; then
  echo "ok    a project with a profile is blocked when a tool the guard needs is missing"
else
  echo "FAIL  a missing tool let a refused command through: the guard failed open"
  failures=$((failures + 1))
fi
# And a project that never opted in still costs nothing: no profile, no opinion, whatever is
# missing. This is the half that keeps the plugin invisible where it was not asked for.
total=$((total + 1))
if [ "$(without_jq "$BARE" 'gh pr merge 7 --admin')" = 0 ]; then
  echo "ok    a project with no profile is untouched when a tool is missing"
else
  echo "FAIL  a project with no profile was blocked over a missing tool"
  failures=$((failures + 1))
fi

# --- A write whose method gh supplies itself is still a write ------------------------
# `gh api` sends POST as soon as any parameter is added — its own help says so — so reading
# the method alone meant `--input body.json` was not a write at all, the question was never
# asked, and a developer set the status the merge gate reads. Measured against the real
# endpoint.
for cmd in 'gh api repos/o/r/statuses/abc --input body.json' \
           'gh api repos/o/r/statuses/abc --input=body.json' \
           'gh api repos/o/r/statuses/abc --input -'; do
  enforced ask ola-workflow:developer "$cmd" "$STATUS"
  enforced allow ola-workflow:pr-reviewer "$cmd" "$STATUS"
done
# Reading one is still not writing one.
enforced allow ola-workflow:developer 'gh api repos/o/r/statuses/abc' "$STATUS"
enforced allow ola-workflow:developer 'gh api -X GET repos/o/r/commits/abc/statuses' "$STATUS"

# --- A refusal has to say what to do instead ------------------------------------------
# A refusal that names no way forward is a refusal an agent works around, which is how a
# guard turns into an obstacle rather than a rule.
for pair in 'ola-workflow:developer|gh pr merge 7|coordinator' \
            'ola-workflow:coordinator|gh pr merge 7 --admin|--match-head-commit' \
            'ola-workflow:coordinator|gh api repos/o/r/statuses/abc -f state=success -f context=relu-par-agent|dispatch a review'; do
  IFS='|' read -r role cmd want <<<"$pair"
  got=$(OLA_WORKFLOW_GUARD=enforce "$GUARD" <<<"$(jq -n --arg c "$cmd" --arg a "$role" --arg d "$STATUS" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"r",cwd:$d,agent_type:$a,
      tool_input:{command:$c}}')" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  total=$((total + 1))
  if [ "${got#*"$want"}" != "$got" ]; then
    echo "ok    the refusal of '$cmd' says what to do instead ($want)"
  else
    echo "FAIL  the refusal of '$cmd' does not mention $want: $got"
    failures=$((failures + 1))
  fi
done

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

# Read once, over every guard run this file made — which is the point of the wrapper.
total=$((total + 1))
if [ ! -s "$STDERR_LOG" ]; then
  echo "ok    the guard never wrote to stderr while deciding, across all $total runs"
else
  echo "FAIL  the guard wrote to stderr while deciding: $(head -1 "$STDERR_LOG")"
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total guard test(s) failed"
  exit 1
fi
echo "all $total guard tests passed"
