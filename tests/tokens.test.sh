#!/usr/bin/env bash
# shellcheck disable=SC2016
#   Every `$` in a command line below is part of what is being tested.
# Runs hooks/session.sh, hooks/elevate.sh and hooks/lib/with-token.sh against simulated
# payloads, with a fake `security` on the PATH so that neither macOS nor a real keychain is
# needed. The commands under test are strings in JSON; only with-token.sh runs anything,
# and what it runs is `printenv`.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/scratch.sh
. "$ROOT/scripts/scratch.sh"

failures=0
total=0
ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

ola_scratch tokens
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT
export HOME=$WORK/home
mkdir -p "$HOME"

# The fake keychain: one file per service, holding the token.
KEYCHAIN=$WORK/keychain
mkdir -p "$KEYCHAIN" "$WORK/bin"
cat >"$WORK/bin/security" <<EOF
#!/usr/bin/env bash
[ "\$1" = find-generic-password ] || exit 2
shift
svc=""
while [ \$# -gt 0 ]; do
  case \$1 in -s) svc=\$2; shift 2 ;; -a) shift 2 ;; *) shift ;; esac
done
[ -s "$KEYCHAIN/\$svc" ] || { echo "security: item not found" >&2; exit 44; }
cat "$KEYCHAIN/\$svc"
EOF
chmod +x "$WORK/bin/security"
export PATH="$WORK/bin:$PATH"
store() { printf '%s' "$2" >"$KEYCHAIN/ola-workflow-$1"; }
forget() { rm -f "$KEYCHAIN/ola-workflow-$1"; }

project() { # project <name> <profile json> → a repository with that committed profile
  local dir=$WORK/$1
  mkdir -p "$dir/.claude"
  git -C "$dir" -c init.defaultBranch=main init -q 2>/dev/null
  printf '%s\n' "$2" >"$dir/.claude/workflow.json"
  printf '%s' "$dir"
}
NOWHERE=$WORK/nowhere
mkdir -p "$NOWHERE"
INTEGRATED=$(project integrated '{"mode":"integrated"}')
DISCREET=$(project discreet '{"mode":"discreet"}')
OFF=$(project off '{"mode":"integrated","github_tokens":"off"}')
CUSTOM=$(project custom '{"mode":"integrated","merge":{"review_status":"ci.review"}}')
ODD=$(project odd '{"mode":"integrated","merge":{"review_status":"c++-review"}}')
PLUS=$(project plus '{"mode":"integrated","merge":{"review_status":"a+b"}}')

SHA=0123456789abcdef0123456789abcdef01234567

# ------------------------------------------------------------------- elevate.sh
elevate() { # elevate <dir> <agent_type> <command> → the hook's stdout
  jq -n --arg d "$1" --arg a "$2" --arg c "$3" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"t",cwd:$d,
      tool_input:{command:$c,description:"kept"}} + (if $a == "" then {} else {agent_type:$a} end)' |
    bash "$ROOT/hooks/elevate.sh"
}

# elevated <kind> <dir> <agent_type> <command>: allowed, rewritten through with-token.sh
# with that kind, the original command intact at the end, the other input fields kept.
elevated() {
  local kind=$1 dir=$2 agent=$3 cmd=$4 out err
  err=$WORK/err; : >"$err"
  out=$(elevate "$dir" "$agent" "$cmd" 2>"$err")
  if [ -s "$err" ]; then
    ko "elevated $kind: '$cmd' wrote to stderr: $(head -1 "$err")"
  elif [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" = allow ] &&
     [ "$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$out")" = \
       "bash $(printf '%q' "$ROOT/hooks/lib/with-token.sh") $kind $cmd" ] &&
     [ "$(jq -r '.hookSpecificOutput.updatedInput.description' <<<"$out")" = kept ]; then
    ok "elevated $kind (${agent#ola-workflow:}): $cmd"
  else
    ko "elevated $kind (${agent#ola-workflow:}): $cmd — got: ${out:-nothing}"
  fi
}

# untouched <dir> <agent_type> <command>: nothing on stdout or stderr, exit 0 — the
# command runs as written, with the session's base token.
untouched() {
  local dir=$1 agent=$2 cmd=$3 out rc err
  local shown=${cmd//$'\n'/\\n}
  err=$WORK/err; : >"$err"
  out=$(elevate "$dir" "$agent" "$cmd" 2>"$err"); rc=$?
  if [ -z "$out" ] && [ "$rc" = 0 ] && [ ! -s "$err" ]; then
    ok "untouched (${agent#ola-workflow:}): $shown"
  else
    ko "untouched (${agent#ola-workflow:}): $shown — exit $rc, got: ${out:-nothing} $(head -1 "$err")"
  fi
}

C=ola-workflow:coordinator
R=ola-workflow:pr-reviewer
D=ola-workflow:developer
MERGE="gh pr merge 12 --squash --match-head-commit $SHA"
STATUS="gh api repos/o/r/statuses/$SHA -f state=success -f context=agent-review"

# The two forms, and the spellings of them an agent writes.
elevated merge  "$INTEGRATED" "$C" "$MERGE"
elevated review "$INTEGRATED" "$R" "$STATUS"
elevated review "$INTEGRATED" "$R" "$STATUS -f description='0 blocking, 2 suggestions'"
elevated review "$INTEGRATED" "$R" "$STATUS -f description=\"0 blocking: ok (see #12)\""
elevated review "$INTEGRATED" "$R" "$STATUS -f target_url=https://github.com/o/r/pull/12#issuecomment-1"
elevated review "$INTEGRATED" "$R" "gh api -X POST repos/o/r/statuses/$SHA -f context=agent-review -f state=failure"
elevated review "$INTEGRATED" "$R" "gh api --method POST repos/{owner}/{repo}/statuses/$SHA -f state=pending -f context=agent-review"
elevated review "$INTEGRATED" "$R" "$STATUS -f description='\$(not run) \`literal\` ; | &'"
elevated review "$CUSTOM"     "$R" "gh api repos/o/r/statuses/$SHA -f state=success -f context=ci.review"

# Another role, or no role, or someone else's agent with the same name.
untouched "$INTEGRATED" "$D" "$MERGE"
untouched "$INTEGRATED" "$R" "$MERGE"
untouched "$INTEGRATED" ""   "$MERGE"
untouched "$INTEGRATED" "other-plugin:coordinator" "$MERGE"
untouched "$INTEGRATED" "coordinator" "$MERGE"
untouched "$INTEGRATED" "$D" "$STATUS"
untouched "$INTEGRATED" "$C" "$STATUS"

# Not the form: anything around it, any other flag, a short SHA.
for cmd in \
  "$MERGE; rm -rf ~" \
  "$MERGE && gh pr merge 13 --squash --admin" \
  "$MERGE | tee log" \
  "$MERGE > out" \
  "$MERGE &" \
  "$MERGE"' $(id)' \
  "$MERGE --admin" \
  "$MERGE --auto" \
  "gh pr merge 12 --admin --squash --match-head-commit $SHA" \
  "gh pr merge 12 --squash --match-head-commit 0123456" \
  "gh pr merge 12 --squash" \
  " $MERGE" \
  "GH_TOKEN=x $MERGE" \
  "$MERGE"$'\n'"echo second line"; do
  untouched "$INTEGRATED" "$C" "$cmd"
done
for cmd in \
  "$STATUS; gh pr merge 12" \
  "$STATUS -f description=\"\$(gh pr merge 12)\"" \
  "$STATUS -f description=\"\`id\`\"" \
  "$STATUS -f description='a' -f description='b'\"" \
  "$STATUS -F state=@body" \
  "$STATUS --input body.json" \
  "gh api repos/o/r/statuses/$SHA -f state=success -f context=other-review" \
  "gh api repos/o/r/statuses/$SHA -f state=success -f context=agent-review-x" \
  "gh api repos/o/r/statuses/$SHA -f context=agent-review" \
  "gh api repos/o/r/statuses/$SHA -f state=success" \
  "gh api -X DELETE repos/o/r/statuses/$SHA -f state=success -f context=agent-review" \
  "gh api repos/o/r/pulls/12/merge -X PUT -f state=success -f context=agent-review" \
  "$STATUS -f description='two"$'\n'"lines'" \
  "$STATUS -f target_url=https://x.io/a;id"; do
  untouched "$INTEGRATED" "$R" "$cmd"
done

# Where the profile says no: none, discreet, tokens off, a status name that is not plain.
untouched "$NOWHERE"  "$C" "$MERGE"
untouched "$DISCREET" "$C" "$MERGE"
untouched "$DISCREET" "$R" "$STATUS"
untouched "$OFF"      "$C" "$MERGE"
untouched "$OFF"      "$R" "$STATUS"
untouched "$ODD"      "$R" "gh api repos/o/r/statuses/$SHA -f state=success -f context=c++-review"
# A name with a regex metacharacter is not elevated at all, rather than read as a pattern.
untouched "$PLUS"     "$R" "gh api repos/o/r/statuses/$SHA -f state=success -f context=aab"
untouched "$PLUS"     "$R" "gh api repos/o/r/statuses/$SHA -f state=success -f context=a+b"
# `.` in a status name is a literal, not "any character".
untouched "$CUSTOM"   "$R" "gh api repos/o/r/statuses/$SHA -f state=success -f context=ciXreview"

# Another tool, and a payload with no command.
out=$(jq -n --arg d "$INTEGRATED" '{tool_name:"Edit",cwd:$d,agent_type:"ola-workflow:coordinator",tool_input:{file_path:"x"}}' |
  bash "$ROOT/hooks/elevate.sh" 2>&1)
if [ -z "$out" ]; then ok "untouched: a payload with no command"; else ko "untouched: a payload with no command — $out"; fi

# Without jq, nothing is elevated: the command runs with the base token.
mkdir -p "$WORK/nojq"
for tool in bash git cat dirname printf; do ln -sf "$(command -v "$tool")" "$WORK/nojq/$tool"; done
out=$(jq -n --arg d "$INTEGRATED" --arg c "$MERGE" '{cwd:$d,agent_type:"ola-workflow:coordinator",tool_input:{command:$c}}' >"$WORK/payload"
      PATH=$WORK/nojq bash "$ROOT/hooks/elevate.sh" <"$WORK/payload" 2>&1); rc=$?
if [ -z "$out" ] && [ "$rc" = 0 ]; then ok "untouched: without jq, nothing is elevated"; else ko "without jq: exit $rc, $out"; fi

# ----------------------------------------------------------------- with-token.sh
store merge merge-token-value
out=$(bash "$ROOT/hooks/lib/with-token.sh" merge printenv GH_TOKEN 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$out" = merge-token-value ]; then
  ok "with-token: the command runs with that kind's token"
else
  ko "with-token: expected merge-token-value, exit $rc: $out"
fi
forget review
out=$(GH_TOKEN=session-token bash "$ROOT/hooks/lib/with-token.sh" review printenv GH_TOKEN 2>"$WORK/err"); rc=$?
if [ "$rc" = 3 ] && [ -z "$out" ] && grep -q 'ola-workflow-tokens setup review' "$WORK/err"; then
  ok "with-token: no token, nothing runs, and the message names the fix"
else
  ko "with-token: with no review token, exit $rc, ran: '$out', said: $(cat "$WORK/err")"
fi
store review ""
out=$(bash "$ROOT/hooks/lib/with-token.sh" review printenv GH_TOKEN 2>/dev/null); rc=$?
if [ "$rc" = 3 ] && [ -z "$out" ]; then
  ok "with-token: an empty token is a missing one"
else
  ko "with-token: an empty token ran the command (exit $rc, '$out')"
fi

# ------------------------------------------------------------------- session.sh
session() { # session <dir> <env file or ""> → stdout of the hook
  local dir=$1 envfile=$2
  jq -n --arg d "$dir" '{hook_event_name:"SessionStart",session_id:"t",cwd:$d,source:"startup"}' |
    if [ -n "$envfile" ]; then CLAUDE_ENV_FILE=$envfile bash "$ROOT/hooks/session.sh"
    else env -u CLAUDE_ENV_FILE bash "$ROOT/hooks/session.sh"; fi
}
sourced_token() { # sourced_token <env file> → GH_TOKEN after sourcing it, as Claude Code does
  env -u GH_TOKEN bash -c '. "$1"; printf "%s" "$GH_TOKEN"' _ "$1"
}

store base base-token-value
for dir in "$NOWHERE" "$OFF"; do
  envfile=$WORK/env-$(basename "$dir"); : >"$envfile"
  out=$(session "$dir" "$envfile" 2>&1)
  if [ -z "$out" ] && [ ! -s "$envfile" ]; then
    ok "session: $(basename "$dir") — nothing written, nothing said"
  else
    ko "session: $(basename "$dir") should leave the session alone — said '$out', wrote: $(cat "$envfile")"
  fi
done

for dir in "$INTEGRATED" "$DISCREET"; do
  envfile=$WORK/env-$(basename "$dir"); : >"$envfile"
  out=$(session "$dir" "$envfile" 2>&1)
  got=$(sourced_token "$envfile")
  if [ -z "$out" ] && [ "$got" = base-token-value ] && ! grep -q base-token-value "$envfile"; then
    ok "session: $(basename "$dir") — every command gets the base token, and the file never holds it"
  else
    ko "session: $(basename "$dir") — said '$out', sourced GH_TOKEN='$got', file: $(cat "$envfile")"
  fi
done

forget base
envfile=$WORK/env-missing; : >"$envfile"
out=$(session "$INTEGRATED" "$envfile" 2>&1)
got=$(sourced_token "$envfile")
if [ "$got" = ola-workflow-has-no-base-token ] && printf '%s' "$out" | grep -q 'ola-workflow-tokens setup'; then
  ok "session: no base token — GH_TOKEN is a value GitHub rejects, never empty, and the session is told"
else
  ko "session: no base token — sourced GH_TOKEN='$got', said '$out'"
fi

out=$(session "$INTEGRATED" "" 2>&1)
if printf '%s' "$out" | grep -q "human's own GitHub login"; then
  ok "session: no CLAUDE_ENV_FILE — the session is told it runs with the human's login"
else
  ko "session: no CLAUDE_ENV_FILE should be said out loud, got '$out'"
fi

# ----------------------------------------------------- what the tokens may do
# The two rights that matter, read from the one table, so that a change to it is a change
# this suite sees.
# shellcheck source=hooks/lib/github-tokens.sh
. "$ROOT/hooks/lib/github-tokens.sh"
for kind in base review; do
  case "&$(ola_token_permissions $kind)&" in
    *"&contents=write&"*) ko "the $kind token can merge (contents=write)" ;;
    *) ok "the $kind token cannot merge" ;;
  esac
done
for kind in base merge; do
  case "&$(ola_token_permissions $kind)&" in
    *"&statuses=write&"*) ko "the $kind token can write a status (statuses=write)" ;;
    *) ok "the $kind token cannot write a status" ;;
  esac
done

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total token test(s) failed"
  exit 1
fi
echo "all $total token tests passed"
