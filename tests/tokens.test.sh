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

# The fake keychain: one file per service for the default account, one per service and
# account for any other (the account's slashes written as %), holding the token. An item
# that exists and is empty is answered as such (exit 0, nothing on stdout), as the real one
# does, so that the code under test is the one that treats it as missing.
KEYCHAIN=$WORK/keychain
mkdir -p "$KEYCHAIN" "$WORK/bin"
cat >"$WORK/bin/security" <<EOF
#!/usr/bin/env bash
[ "\$1" = find-generic-password ] || exit 2
shift
svc=""
acct=ola-workflow
while [ \$# -gt 0 ]; do
  case \$1 in -s) svc=\$2; shift 2 ;; -a) acct=\$2; printf '%s\\n' "\$2" >>"$WORK/accounts"; shift 2 ;; *) shift ;; esac
done
[ "\$acct" = ola-workflow ] || svc=\$svc@\${acct//\//%}
[ -e "$KEYCHAIN/\$svc" ] || { echo "security: item not found" >&2; exit 44; }
cat "$KEYCHAIN/\$svc"
EOF
chmod +x "$WORK/bin/security"
export PATH="$WORK/bin:$PATH"
store() { printf '%s' "$2" >"$KEYCHAIN/ola-workflow-$1"; }
forget() { rm -f "$KEYCHAIN/ola-workflow-$1"; }
# store_at <kind> <account> <token>: the token of a GitLab account (host, group or project).
store_at() { printf '%s' "$3" >"$KEYCHAIN/ola-workflow-$1@${2//\//%}"; }
forget_all() { rm -f "$KEYCHAIN"/*; }

project() { # project <name> <profile json> → a repository with that committed profile
  local dir=$WORK/$1
  mkdir -p "$dir/.claude"
  git -C "$dir" -c init.defaultBranch=main init -q 2>/dev/null
  printf '%s\n' "$2" >"$dir/.claude/workflow.json"
  printf '%s' "$dir"
}
# remote_project <name> <profile json> <remote url> → the same, with an origin.
remote_project() {
  local dir
  dir=$(project "$1" "$2")
  git -C "$dir" remote add origin "$3"
  printf '%s' "$dir"
}
NOWHERE=$WORK/nowhere
mkdir -p "$NOWHERE"
INTEGRATED=$(project integrated '{"mode":"integrated"}')
DISCREET=$(project discreet '{"mode":"discreet"}')
GITLAB=$(project gitlab '{"mode":"integrated","forge":"gitlab"}')
GITHUB=$(project github '{"mode":"integrated","forge":"github"}')
OFF=$(project off '{"mode":"integrated","github_tokens":"off"}')
CUSTOM=$(project custom '{"mode":"integrated","merge":{"review_status":"ci.review"}}')
ODD=$(project odd '{"mode":"integrated","merge":{"review_status":"c++-review"}}')
GL_JSON='{"mode":"integrated","forge":"gitlab"}'
GL=$(remote_project gl "$GL_JSON" git@gl.example.com:grp/sub/proj.git)
GL_DISCREET=$(remote_project gldiscreet '{"mode":"discreet","forge":"gitlab"}' git@gl.example.com:grp/sub/proj.git)
GH_REMOTE=$(remote_project ghremote '{"mode":"integrated","forge":"github"}' git@github.com:o/r.git)
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
# with the forge (github) and that kind, the original command intact at the end, the other input fields kept.
elevated() {
  local kind=$1 dir=$2 agent=$3 cmd=$4 out err
  err=$WORK/err; : >"$err"
  out=$(elevate "$dir" "$agent" "$cmd" 2>"$err")
  if [ -s "$err" ]; then
    ko "elevated $kind: '$cmd' wrote to stderr: $(head -1 "$err")"
  elif [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" = allow ] &&
     [ "$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$out")" = \
       "bash $(printf '%q' "$ROOT/hooks/lib/with-token.sh") github $kind $cmd" ] &&
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

# The profile may name the forge; github is the default and the same answer.
elevated merge  "$GITHUB" "$C" "$MERGE"
elevated review "$GITHUB" "$R" "$STATUS"

# A GitHub form in a project hosted on GitLab is not that project's form: it passes untouched.
untouched "$GITLAB" "$C" "$MERGE"
untouched "$GITLAB" "$R" "$STATUS"
# GitLab's own forms are not elevated yet, whatever the role.
untouched "$GITLAB" "$C" "glab mr merge 12 --squash --sha $SHA"
untouched "$GITLAB" "$R" "glab api projects/1/statuses/$SHA -f state=success -f name=agent-review"
# And a GitLab form in a GitHub project is no GitHub form.
untouched "$INTEGRATED" "$C" "glab mr merge 12 --squash --sha $SHA"
untouched "$GITHUB"     "$R" "glab api projects/1/statuses/$SHA -f state=success -f name=agent-review"

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
out=$(bash "$ROOT/hooks/lib/with-token.sh" github merge printenv GH_TOKEN 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$out" = merge-token-value ]; then
  ok "with-token: the command runs with that kind's token"
else
  ko "with-token: expected merge-token-value, exit $rc: $out"
fi
forget review
out=$(GH_TOKEN=session-token bash "$ROOT/hooks/lib/with-token.sh" github review printenv GH_TOKEN 2>"$WORK/err"); rc=$?
if [ "$rc" = 3 ] && [ -z "$out" ] && grep -q 'ola-workflow-tokens setup review' "$WORK/err"; then
  ok "with-token: no token, nothing runs, and the message names the fix"
else
  ko "with-token: with no review token, exit $rc, ran: '$out', said: $(cat "$WORK/err")"
fi
store review ""
out=$(bash "$ROOT/hooks/lib/with-token.sh" github review printenv GH_TOKEN 2>/dev/null); rc=$?
if [ "$rc" = 3 ] && [ -z "$out" ]; then
  ok "with-token: an empty token is a missing one"
else
  ko "with-token: an empty token ran the command (exit $rc, '$out')"
fi

# The forge comes first. One that is unknown, or missing, runs nothing.
for args in "merge printenv GH_TOKEN" "bitbucket merge printenv GH_TOKEN" "github"; do
  # shellcheck disable=SC2086
  out=$(bash "$ROOT/hooks/lib/with-token.sh" $args 2>/dev/null); rc=$?
  if [ "$rc" != 0 ] && [ -z "$out" ]; then
    ok "with-token: '$args' runs nothing"
  else
    ko "with-token: '$args' ran (exit $rc, '$out')"
  fi
done

# ola_token_read: the default account is unchanged, and another one can be asked for.
# shellcheck source=hooks/lib/github-tokens.sh
. "$ROOT/hooks/lib/github-tokens.sh"
store merge merge-token-value
: >"$WORK/accounts"
ola_token_read merge >/dev/null
ola_token_read merge other-account >/dev/null
if [ "$(tr '\n' ' ' <"$WORK/accounts")" = "ola-workflow other-account " ]; then
  ok "ola_token_read: the default account is ola-workflow, an account can be given"
else
  ko "ola_token_read: accounts asked for were: $(tr '\n' ' ' <"$WORK/accounts")"
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

# ----------------------------------------------------------------------- GitLab
# shellcheck source=hooks/lib/profile.sh
. "$ROOT/hooks/lib/profile.sh"
# shellcheck source=hooks/lib/gitlab-tokens.sh
. "$ROOT/hooks/lib/gitlab-tokens.sh"
sourced_var() { # sourced_var <env file> <name> → that variable after sourcing the file
  # Claude Code sources the line in the user's shell, bash or zsh: under both when zsh is
  # installed, and a difference between them is an answer no check can match.
  local b z
  b=$(env -u GH_TOKEN -u GITLAB_TOKEN -u GITLAB_HOST bash -c '. "$1"; printf "%s" "${!2}"' _ "$1" "$2")
  if command -v zsh >/dev/null 2>&1; then
    z=$(env -u GH_TOKEN -u GITLAB_TOKEN -u GITLAB_HOST zsh -c '. "$1"; printf "%s" "${(P)2}"' _ "$1" "$2")
    [ "$b" = "$z" ] || b="DIFFERS bash='$b' zsh='$z'"
  fi
  printf '%s' "$b"
}
gitlab_session() { # gitlab_session <dir> → the env file the hook wrote; what it said is in $WORK/said
  local envfile=$WORK/env-gl-$RANDOM
  : >"$envfile"
  session "$1" "$envfile" >"$WORK/said" 2>&1
  printf '%s' "$envfile"
}
check() { # check <label> <0 when it holds>
  if [ "$2" = 0 ]; then ok "$1"; else ko "$1"; fi
}
is() { [ "$1" = "$2" ] && echo 0 || echo 1; } # is <got> <want> → 0 when equal

# The accounts, from the project up to the host.
got=$(ola_gitlab_accounts gl.example.com/grp/sub/proj | tr '\n' ' ')
check "gitlab: the accounts go from the project up to the host" \
  "$(is "$got" 'gitlab:gl.example.com/grp/sub/proj gitlab:gl.example.com/grp/sub gitlab:gl.example.com/grp gitlab:gl.example.com ')"
got=$(ola_gitlab_accounts gl.example.com/proj | tr '\n' ' ')
check "gitlab: a project at the root of the host has two accounts" \
  "$(is "$got" 'gitlab:gl.example.com/proj gitlab:gl.example.com ')"

# The project's own token goes before a group's, which goes before the host's.
forget_all
store base github-base
store_at base gitlab:gl.example.com host-token
env=$(gitlab_session "$GL")
check "gitlab: a token kept at the host serves the project" "$(is "$(sourced_var "$env" GITLAB_TOKEN)" host-token)"
store_at base gitlab:gl.example.com/grp group-token
store_at base gitlab:gl.example.com/grp/sub/proj project-token
env=$(gitlab_session "$GL")
check "gitlab: a project's token goes before the group's and the host's" \
  "$(is "$(sourced_var "$env" GITLAB_TOKEN)" project-token)"
forget_all; store base github-base
store_at base gitlab:gl.example.com/grp group-token
store_at base gitlab:gl.example.com host-token
env=$(gitlab_session "$GL")
check "gitlab: a group's token goes before the host's" "$(is "$(sourced_var "$env" GITLAB_TOKEN)" group-token)"
check "gitlab: GITLAB_HOST is the host of the remote" "$(is "$(sourced_var "$env" GITLAB_HOST)" gl.example.com)"
check "gitlab: the file never holds a token" "$(grep -qE 'group-token|host-token|project-token' "$env" && echo 1 || echo 0)"
check "gitlab: the GH_TOKEN line is still written" "$(is "$(sourced_var "$env" GH_TOKEN)" github-base)"
check "gitlab: the GH_TOKEN line comes first" "$(head -1 "$env" | grep -q '^export GH_TOKEN=' && echo 0 || echo 1)"

# No token: a value GitLab rejects, never an empty one (an empty GITLAB_TOKEN makes glab
# fall back to the human's own login), and the session is told.
forget_all
env=$(gitlab_session "$GL")
check "gitlab: no base token — GITLAB_TOKEN is a value GitLab rejects, never empty" \
  "$(is "$(sourced_var "$env" GITLAB_TOKEN)" ola-workflow-has-no-base-token)"
check "gitlab: no base token — the session is told, naming GitLab and the fix" \
  "$(grep -q 'every glab call of this session will fail with a 401' "$WORK/said" && grep -q 'ola-workflow-tokens setup' "$WORK/said" && echo 0 || echo 1)"
store_at base gitlab:gl.example.com ""
env=$(gitlab_session "$GL")
check "gitlab: an empty token is a missing one" "$(is "$(sourced_var "$env" GITLAB_TOKEN)" ola-workflow-has-no-base-token)"
# ... and the ascent goes on past it: an empty item at the project is not the end of the road.
store_at base gitlab:gl.example.com/grp/sub/proj ""
store_at base gitlab:gl.example.com host-token
env=$(gitlab_session "$GL")
check "gitlab: an empty token at the project is passed over, the host's serves" \
  "$(is "$(sourced_var "$env" GITLAB_TOKEN)" host-token)"

# A token kept for host A is never exported for host B, nor for a sibling or parent domain.
forget_all
store_at base gitlab:a.example.com host-a-token
store_at base gitlab:gl.example.com.evil host-evil-token
store_at base gitlab:example.com host-parent-token
env=$(gitlab_session "$GL")
check "gitlab: the token of another host is never exported" \
  "$(is "$(sourced_var "$env" GITLAB_TOKEN)" ola-workflow-has-no-base-token)"

# A path component with shell syntax stays inert in the sourced line, and is asked for as is.
forget_all
HOSTILE='gitlab:gl.example.com/g/a$(touch PWNED)"b c;`touch PWNED2`/p'
EVIL=$(remote_project evil "$GL_JSON" 'git@gl.example.com:g/a$(touch PWNED)"b c;`touch PWNED2`/p.git')
store_at base "$HOSTILE" evil-project-token
: >"$WORK/accounts"
env=$(gitlab_session "$EVIL")
got=$(cd "$WORK" && sourced_var "$env" GITLAB_TOKEN)
if [ "$got" = evil-project-token ] && [ ! -e "$WORK/PWNED" ] && [ ! -e "$WORK/PWNED2" ] &&
   grep -qxF "$HOSTILE" "$WORK/accounts"; then
  ok "gitlab: quotes, \$( ) and spaces in the path stay inert in the sourced line"
else
  ko "gitlab: a hostile path — got '$got', env: $(cat "$env")"
fi

# A host that starts with `=` is expanded by zsh (`==ls` is `/bin/ls`): the line escapes it,
# and the host stays the text of the remote, under bash and zsh alike.
forget_all; store base github-base
EQ=$(remote_project eqhost "$GL_JSON" 'git@=ls:grp/p.git')
store_at base 'gitlab:=ls' eq-host-token
env=$(gitlab_session "$EQ")
check "gitlab: a host starting with = stays that text in GITLAB_HOST" "$(is "$(sourced_var "$env" GITLAB_HOST)" '=ls')"
check "gitlab: a host starting with = is still asked for as is" "$(is "$(sourced_var "$env" GITLAB_TOKEN)" eq-host-token)"

# The ssh-over-443 host of gitlab.com is gitlab.com: a token is kept for it, and glab is
# sent to it, not to altssh.gitlab.com, which serves no API.
forget_all; store base github-base
ALT=$(remote_project altssh "$GL_JSON" 'ssh://git@altssh.gitlab.com:443/grp/p.git')
store_at base gitlab:gitlab.com/grp gl-com-token
env=$(gitlab_session "$ALT")
check "gitlab: altssh.gitlab.com exports GITLAB_HOST=gitlab.com" "$(is "$(sourced_var "$env" GITLAB_HOST)" gitlab.com)"
check "gitlab: altssh.gitlab.com reads the tokens kept for gitlab.com" "$(is "$(sourced_var "$env" GITLAB_TOKEN)" gl-com-token)"
store_at merge gitlab:gitlab.com merge-gl-com-token
out=$(cd "$ALT" && bash "$ROOT/hooks/lib/with-token.sh" gitlab merge sh -c 'printf "%s|%s" "$GITLAB_TOKEN" "$GITLAB_HOST"' 2>&1)
check "with-token gitlab: altssh.gitlab.com lends the token and the host of gitlab.com" "$(is "$out" 'merge-gl-com-token|gitlab.com')"

# GitHub projects: no GitLab line at all, whatever the keychain holds. The file is the one
# line GH_TOKEN has always been.
store base github-base
store_at base gitlab:github.com github-host-token
for dir in "$INTEGRATED" "$GITHUB" "$GH_REMOTE"; do
  envfile=$WORK/env-gh-$RANDOM; : >"$envfile"
  session "$dir" "$envfile" >/dev/null 2>&1
  if [ "$(wc -l <"$envfile" | tr -d ' ')" = 1 ] && ! grep -q GITLAB "$envfile" &&
     [ "$(cat "$envfile")" = "$(ola_token_env_line)" ]; then
    ok "gitlab: $(basename "$dir") — one GH_TOKEN line, no GitLab line"
  else
    ko "gitlab: $(basename "$dir") — file: $(cat "$envfile")"
  fi
done

# Discreet GitLab: the agents read with the human's own glab login, nothing of GitLab is exported.
envfile=$WORK/env-gl-discreet; : >"$envfile"
out=$(session "$GL_DISCREET" "$envfile" 2>&1)
if ! grep -q GITLAB "$envfile" && [ -z "$out" ]; then
  ok "gitlab: a discreet profile writes no GITLAB_TOKEN line, and says nothing"
else
  ko "gitlab: discreet — said '$out', file: $(cat "$envfile")"
fi

# A GitLab project whose remote is unknown still never gets an empty token, and claims no host.
env=$(gitlab_session "$GITLAB")
check "gitlab: with no remote, GITLAB_TOKEN is the rejected value and no host is claimed" \
  "$([ "$(sourced_var "$env" GITLAB_TOKEN)" = ola-workflow-has-no-base-token ] && ! grep -q GITLAB_HOST "$env" && echo 0 || echo 1)"

# Tokens off, and no CLAUDE_ENV_FILE, in a GitLab project.
OFF_GL=$(remote_project offgl '{"mode":"integrated","forge":"gitlab","github_tokens":"off"}' git@gl.example.com:grp/p.git)
envfile=$WORK/env-offgl; : >"$envfile"
out=$(session "$OFF_GL" "$envfile" 2>&1)
check "gitlab: github_tokens off leaves the session alone" "$([ -z "$out" ] && [ ! -s "$envfile" ] && echo 0 || echo 1)"
out=$(session "$GL" "" 2>&1)
check "gitlab: no CLAUDE_ENV_FILE is said out loud, without naming GitHub" \
  "$(printf '%s' "$out" | grep -q "human's own glab login" && ! printf '%s' "$out" | grep -q GitHub && echo 0 || echo 1)"

# with-token.sh lends the token read by the same ascent, for the host of the project only.
forget_all
store_at merge gitlab:gl.example.com merge-host-token
store_at merge gitlab:other.example.com merge-other-token
out=$(cd "$GL" && env -u GITLAB_HOST GITLAB_TOKEN=session-token bash "$ROOT/hooks/lib/with-token.sh" gitlab merge \
  sh -c 'printf "%s|%s" "$GITLAB_TOKEN" "$GITLAB_HOST"' 2>&1); rc=$?
check "with-token gitlab: the token and GITLAB_HOST of the project's host (exit $rc: $out)" \
  "$([ "$rc" = 0 ] && [ "$out" = 'merge-host-token|gl.example.com' ] && echo 0 || echo 1)"
store_at merge gitlab:gl.example.com/grp/sub/proj merge-project-token
out=$(cd "$GL" && bash "$ROOT/hooks/lib/with-token.sh" gitlab merge printenv GITLAB_TOKEN 2>&1)
check "with-token gitlab: the project's token goes before the host's" "$(is "$out" merge-project-token)"
forget_all
store_at merge gitlab:other.example.com merge-other-token
out=$(cd "$GL" && GITLAB_TOKEN=session-token bash "$ROOT/hooks/lib/with-token.sh" gitlab merge printenv GITLAB_TOKEN 2>"$WORK/err"); rc=$?
check "with-token gitlab: no token for this host, nothing runs, the message names the fix" \
  "$([ "$rc" = 3 ] && [ -z "$out" ] && grep -q 'ola-workflow-tokens setup merge' "$WORK/err" && echo 0 || echo 1)"
store_at merge gitlab:gl.example.com ""
out=$(cd "$GL" && bash "$ROOT/hooks/lib/with-token.sh" gitlab merge printenv GITLAB_TOKEN 2>/dev/null); rc=$?
check "with-token gitlab: an empty token is a missing one" "$([ "$rc" = 3 ] && [ -z "$out" ] && echo 0 || echo 1)"
store_at merge gitlab:gl.example.com/grp/sub/proj ""
store_at merge gitlab:gl.example.com merge-host-token
out=$(cd "$GL" && bash "$ROOT/hooks/lib/with-token.sh" gitlab merge printenv GITLAB_TOKEN 2>&1)
check "with-token gitlab: an empty token at the project is passed over, the host's serves" "$(is "$out" merge-host-token)"
out=$(cd "$NOWHERE" && bash "$ROOT/hooks/lib/with-token.sh" gitlab merge printenv GITLAB_TOKEN 2>/dev/null); rc=$?
check "with-token gitlab: with no remote, no host is known and nothing runs" "$([ "$rc" != 0 ] && [ -z "$out" ] && echo 0 || echo 1)"
# The token never travels in an argument: the command is run as given.
store_at merge gitlab:gl.example.com merge-host-token
out=$(cd "$GL" && bash "$ROOT/hooks/lib/with-token.sh" gitlab merge sh -c 'printf "%s" "$*"' _ a b 2>&1)
check "with-token gitlab: the arguments are the command's own, no token among them" "$(is "$out" 'a b')"

# ----------------------------------------------------- what the tokens may do
# The two rights that matter, read from the one table, so that a change to it is a change
# this suite sees.
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
