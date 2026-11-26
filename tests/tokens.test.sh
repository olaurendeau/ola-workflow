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
# add-generic-password prompts for the token, as the real one does: here, on the standard
# input, and never in an argument. delete-generic-password forgets it.
op=\$1
case \$op in find-generic-password|add-generic-password|delete-generic-password) ;; *) exit 2 ;; esac
shift
svc=""
acct=ola-workflow
while [ \$# -gt 0 ]; do
  case \$1 in -s) svc=\$2; shift 2 ;; -a) acct=\$2; printf '%s\\n' "\$2" >>"$WORK/accounts"; shift 2 ;; -l) shift 2 ;; *) shift ;; esac
done
[ "\$acct" = ola-workflow ] || svc=\$svc@\${acct//\//%}
case \$op in
  add-generic-password) read -r token || exit 1; printf '%s' "\$token" >"$KEYCHAIN/\$svc"; exit 0 ;;
  delete-generic-password) [ -e "$KEYCHAIN/\$svc" ] || exit 44; rm -f "$KEYCHAIN/\$svc"; echo "deleted \$svc" >>"$WORK/deleted"; exit 0 ;;
esac
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

# ------------------------------------------------------- ola-workflow-tokens, both forges
# The command runs in the project's clone, with the fake security, glab, gh and open of this
# suite. The setup reads its token from the standard input only because the fake `security`
# does: the real one prompts on the terminal, and OLA_TOKENS_TEST_NO_TTY skips only the check
# that there is one.
cat >"$WORK/bin/open" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"$WORK/opened"
EOF
cat >"$WORK/bin/gh" <<EOF
#!/usr/bin/env bash
[ "\$GH_TOKEN" = gh-merge-token ] || exit 1
case " \$* " in
  *" -i "*) printf 'HTTP/2.0 200 OK\\r\\ngithub-authentication-token-expiration: 2099-01-01 00:00:00 UTC\\r\\n\\r\\n{}\\n' ;;
  *) echo octo ;;
esac
EOF
# glab answers by token and by endpoint, from a file holding the whole answer, headers
# included. A token found in an argument is a leak, and is written down.
GLAB_FIX=$WORK/glab-fix
mkdir -p "$GLAB_FIX"
export GLAB_FIX
cat >"$WORK/bin/glab" <<EOF
#!/usr/bin/env bash
printf '%s|%s\\n' "\$GITLAB_HOST" "\$*" >>"$WORK/glab.log"
case " \$* " in *" \$GITLAB_TOKEN "*) echo "\$GITLAB_TOKEN" >>"$WORK/glab.leak" ;; esac
[ "\$1" = api ] && [ "\$2" = --include ] || exit 2
f=\$GLAB_FIX/\$GITLAB_TOKEN@\${3//\\//%}
[ -f "\$f" ] || { printf 'HTTP/2.0 404 Not Found\\r\\n\\r\\n{"message":"404 Not found"}\\n'; exit 1; }
cat "\$f"
case \$(sed -n '1s/^HTTP\\/[0-9.]* \\([0-9]*\\).*/\\1/p' "\$f") in 2*) exit 0 ;; *) exit 1 ;; esac
EOF
chmod +x "$WORK/bin/open" "$WORK/bin/gh" "$WORK/bin/glab"

glab_say() { # glab_say <token> <endpoint> <code> <json body>
  printf 'HTTP/2.0 %s X\r\nContent-Type: application/json\r\n\r\n%s\n' "$3" "$4" >"$GLAB_FIX/$1@${2//\//%}"
}
self_say() { # self_say <token> <user id> <granular> <expires_at, empty for none> <token id>
  glab_say "$1" personal_access_tokens/self 200 "$(jq -nc --argjson u "$2" --argjson g "$3" --arg e "$4" --argjson i "$5" \
    '{id:$i,user_id:$u,granular:$g,expires_at:(if $e == "" then null else $e end),active:true,scopes:["api"]}')"
}
tokens() { # tokens <dir> <args…> → the command's output, standard error included
  local dir=$1
  shift
  (cd "$dir" && OLA_TOKENS_TEST_NO_TTY=1 bash "$ROOT/bin/ola-workflow-tokens" "$@" 2>&1)
}
setup_with() { # setup_with <dir> <token pasted> <kind> → OUT and RC
  OUT=$(printf '%s\n' "$2" | tokens "$1" setup "$3")
  RC=$?
}
held() { # held <kind> <account> → the token kept there, or nothing
  cat "$KEYCHAIN/ola-workflow-$1@${2//\//%}" 2>/dev/null
}
fresh() { forget_all; rm -f "$GLAB_FIX"/* "$WORK/glab.log" "$WORK/glab.leak" "$WORK/opened" "$WORK/deleted"; }
PROJ_ACCOUNT=gitlab:gl.example.com/grp/sub/proj
PROJ_ENC=grp%2Fsub%2Fproj

mentions() { # mentions <text> <needle…> → 0 when the text holds each of them
  local text=$1 needle
  shift
  for needle in "$@"; do
    printf '%s\n' "$text" | grep -qF -- "$needle" || { echo 1; return; }
  done
  echo 0
}

# --- GitHub: what `url`, `setup` and `status` print and store does not change.
fresh
check "tokens github: url base" "$(is "$(tokens "$NOWHERE" url base)" 'https://github.com/settings/personal-access-tokens/new?name=ola-workflow+base&description=every+agent%3B+cannot+merge+or+write+a+status&expires_in=90&metadata=read&contents=read&pull_requests=write&issues=write&statuses=read&actions=read')"
check "tokens github: url merge" "$(is "$(tokens "$GH_REMOTE" url merge)" "https://github.com/settings/personal-access-tokens/new?name=ola-workflow+merge&description=the+coordinator%27s+gh+pr+merge+only&expires_in=90&metadata=read&contents=write&pull_requests=write")"
check "tokens github: url review" "$(is "$(tokens "$GITHUB" url review)" "https://github.com/settings/personal-access-tokens/new?name=ola-workflow+review&description=the+pr-reviewer%27s+review+status+only&expires_in=90&metadata=read&statuses=write")"
OUT=$(printf 'gh-merge-token\n' | tokens "$NOWHERE" setup merge)
RC=$?
WANT="== merge — the coordinator's gh pr merge only
   Permissions: metadata=read contents=write pull_requests=write
   On the form, choose 'Only select repositories' and pick each project that has a profile.
   https://github.com/settings/personal-access-tokens/new?name=ola-workflow+merge&description=the+coordinator%27s+gh+pr+merge+only&expires_in=90&metadata=read&contents=write&pull_requests=write
   Paste the token at the prompt (twice; nothing is echoed).
   stored.

base    missing — ola-workflow-tokens setup base
merge   ok, acts as octo, expires 2099-01-01 00:00:00 UTC
review  missing — ola-workflow-tokens setup review"
check "tokens github: setup merge prints and stores as before" "$(is "$OUT" "$WANT")"
check "tokens github: the token is kept at the account of GitHub" "$(is "$(cat "$KEYCHAIN/ola-workflow-merge")" gh-merge-token)"
check "tokens github: no glab call" "$([ ! -e "$WORK/glab.log" ] && echo 0 || echo 1)"

# --- GitLab: the pages, for gitlab.com and for a self-hosted host, never a github.com URL.
GLCOM=$(remote_project glcom "$GL_JSON" git@gitlab.com:o/r.git)
GLDEEP=$(remote_project gldeep "$GL_JSON" git@git.example.com:a/b/c.git)
check "tokens gitlab: url base, gitlab.com" "$(is "$(tokens "$GLCOM" url base)" https://gitlab.com/o/r/-/settings/access_tokens)"
check "tokens gitlab: url base, a self-hosted host and a deep path" \
  "$(is "$(tokens "$GLDEEP" url base)" https://git.example.com/a/b/c/-/settings/access_tokens)"
check "tokens gitlab: url review, gitlab.com: the name only, no classic scope" \
  "$(is "$(tokens "$GLCOM" url review)" 'https://gitlab.com/-/user_settings/personal_access_tokens?name=ola-workflow+review')"
check "tokens gitlab: url merge, a self-hosted host: the same form" \
  "$(is "$(tokens "$GLDEEP" url merge)" 'https://git.example.com/-/user_settings/personal_access_tokens?name=ola-workflow+merge')"
check "tokens gitlab: url base, discreet: the personal page, as the token is the human's" \
  "$(is "$(tokens "$GL_DISCREET" url base)" 'https://gl.example.com/-/user_settings/personal_access_tokens?name=ola-workflow+base')"
check "tokens gitlab: no github.com in any page" \
  "$(for k in base merge review; do tokens "$GL" url $k; tokens "$GL_DISCREET" url $k; done | grep -q github && echo 1 || echo 0)"
check "tokens gitlab: an unknown kind is refused" "$(tokens "$GL" url nope >/dev/null; [ $? = 2 ] && echo 0 || echo 1)"

# --- setup review and merge: only a fine-grained token, kept at the project, never at the host.
fresh
self_say tok-granular 21899033 true 2099-01-01 7
setup_with "$GL" tok-granular review
check "tokens gitlab: setup review keeps a fine-grained token at the project's account" \
  "$([ "$(held review "$PROJ_ACCOUNT")" = tok-granular ] && [ -z "$(held review gitlab:gl.example.com)" ] && echo 0 || echo 1)"
check "tokens gitlab: setup review says the permissions, the project limit and what it does not check" \
  "$(mentions "$OUT" '"Commit Status: Create"' '"Personal Access Token: Read"' 'grp/sub/proj' '"Terraform State"' 'Not checked')"
check "tokens gitlab: setup review opens the page without scopes=api" \
  "$(grep -qF 'https://gl.example.com/-/user_settings/personal_access_tokens?name=ola-workflow+review' "$WORK/opened" && ! grep -q 'scopes=api' "$WORK/opened" && echo 0 || echo 1)"
check "tokens gitlab: setup asks the host of the project, and no github.com is named" \
  "$(grep -q '^gl.example.com|api --include personal_access_tokens/self' "$WORK/glab.log" && ! printf '%s' "$OUT" | grep -q github && echo 0 || echo 1)"
check "tokens gitlab: the token is in no argument of glab" "$([ ! -e "$WORK/glab.leak" ] && echo 0 || echo 1)"
setup_with "$GL" tok-granular merge
check "tokens gitlab: setup merge keeps it at the project's account, under its own kind" \
  "$([ "$(held merge "$PROJ_ACCOUNT")" = tok-granular ] && echo 0 || echo 1)"

fresh
self_say tok-classic 21899033 false "" 8
setup_with "$GL" tok-classic review
check "tokens gitlab: setup review refuses a classic token, and keeps nothing" \
  "$([ "$RC" != 0 ] && [ -z "$(held review "$PROJ_ACCOUNT")" ] && [ -z "$(held review gitlab:gl.example.com)" ] && echo 0 || echo 1)"
check "tokens gitlab: ... and says why" \
  "$(printf '%s' "$OUT" | grep -qF 'This is a classic token. Review and merge take a fine-grained token limited to grp/sub/proj: create one and paste it again.' && echo 0 || echo 1)"
glab_say tok-nofield personal_access_tokens/self 200 '{"id":9,"user_id":1}'
setup_with "$GL" tok-nofield merge
check "tokens gitlab: a token with no 'granular' field is a classic one" \
  "$([ "$RC" != 0 ] && [ -z "$(held merge "$PROJ_ACCOUNT")" ] && printf '%s' "$OUT" | grep -q 'classic token' && echo 0 || echo 1)"

fresh
glab_say tok-min personal_access_tokens/self 403 '{"error":"insufficient_granular_scope","error_description":"no"}'
setup_with "$GL" tok-min review
check "tokens gitlab: setup review refuses the 403 of a token without 'Personal Access Token: Read'" \
  "$([ "$RC" != 0 ] && [ -z "$(held review "$PROJ_ACCOUNT")" ] && echo 0 || echo 1)"
check "tokens gitlab: ... and says to add the permission" \
  "$(printf '%s' "$OUT" | grep -qF 'GitLab will not tell who this token is (403). Add the permission "Personal Access Token: Read" to it and paste it again.' && echo 0 || echo 1)"
glab_say tok-old personal_access_tokens/self 401 '{"message":"401 Unauthorized"}'
setup_with "$GL" tok-old review
check "tokens gitlab: setup review refuses a 401, keeps nothing" \
  "$([ "$RC" != 0 ] && [ -z "$(held review "$PROJ_ACCOUNT")" ] && printf '%s' "$OUT" | grep -q '401' && echo 0 || echo 1)"
glab_say tok-boom personal_access_tokens/self 500 '{"message":"boom-from-gitlab"}'
setup_with "$GL" tok-boom merge
check "tokens gitlab: setup merge refuses a 500, and copies what GitLab said" \
  "$([ "$RC" != 0 ] && [ -z "$(held merge "$PROJ_ACCOUNT")" ] && printf '%s' "$OUT" | grep -q '500.*boom-from-gitlab' && echo 0 || echo 1)"
check "tokens gitlab: a refused token is deleted from the keychain" "$([ -s "$WORK/deleted" ] && echo 0 || echo 1)"

# A refusal deletes the previous token of that kind too (one keychain item per account): it says so.
fresh
store_at review "$PROJ_ACCOUNT" tok-previous
self_say tok-classic 21899033 false "" 8
setup_with "$GL" tok-classic review
check "tokens gitlab: a refusal deletes the previous token of the kind, and says so" \
  "$([ -z "$(held review "$PROJ_ACCOUNT")" ] && printf '%s' "$OUT" | grep -qF 'The previous review token was deleted with it' && echo 0 || echo 1)"

# GitLab gave no answer: nobody knows the token is bad, so it stays, with a warning.
fresh
printf 'not an http answer\n' >"$GLAB_FIX/tok-silent@personal_access_tokens%self"
setup_with "$GL" tok-silent review
check "tokens gitlab: no answer from GitLab keeps the token" \
  "$([ "$(held review "$PROJ_ACCOUNT")" = tok-silent ] && [ ! -e "$WORK/deleted" ] && echo 0 || echo 1)"
check "tokens gitlab: ... and warns that it was not verified" \
  "$(mentions "$OUT" 'warning' 'GitLab gave no answer' 'not verified' 'ola-workflow-tokens status')"

# --- setup base: the bot in integrated mode, the human's read-only token in discreet mode.
fresh
setup_with "$GL" bot-token base
check "tokens gitlab: setup base, integrated, keeps the token at the project's account" \
  "$([ "$(held base "$PROJ_ACCOUNT")" = bot-token ] && echo 0 || echo 1)"
check "tokens gitlab: ... explains the one identity: Developer, scope api, project token or dedicated account" \
  "$(mentions "$OUT" Developer 'api' 'project access token' 'dedicated account')"
check "tokens gitlab: ... and opens the project's token page" \
  "$(grep -qxF 'https://gl.example.com/grp/sub/proj/-/settings/access_tokens' "$WORK/opened" && echo 0 || echo 1)"
fresh
glab_say tok-min personal_access_tokens/self 403 '{"error":"insufficient_granular_scope"}'
setup_with "$GL_DISCREET" tok-min base
check "tokens gitlab: setup base, discreet, accepts a fine-grained token that cannot read itself" \
  "$([ "$(held base "$PROJ_ACCOUNT")" = tok-min ] && printf '%s' "$OUT" | grep -q 'not readable' && echo 0 || echo 1)"
check "tokens gitlab: ... and says which permissions: read only, never Personal Access Token: Read nor Terraform State" \
  "$(mentions "$OUT" '"Merge Request: Read"' '"Work Item: Read"' '"Terraform State"')"
fresh
self_say tok-classic 21899033 false "" 8
setup_with "$GL_DISCREET" tok-classic base
check "tokens gitlab: setup base, discreet, refuses a classic token" \
  "$([ "$RC" != 0 ] && [ -z "$(held base "$PROJ_ACCOUNT")" ] && echo 0 || echo 1)"
glab_say tok-old personal_access_tokens/self 401 '{"message":"401 Unauthorized"}'
setup_with "$GL_DISCREET" tok-old base
check "tokens gitlab: setup base, discreet, refuses a 401" "$([ "$RC" != 0 ] && [ -z "$(held base "$PROJ_ACCOUNT")" ] && echo 0 || echo 1)"

# --- the shared helpers
check "gitlab: the project path is the profile's, without the host, '/' encoded" \
  "$(is "$(ola_gitlab_project_path gl.example.com/grp/sub/proj)" grp%2Fsub%2Fproj)"
check "gitlab: a project at the root has no separator to encode" "$(is "$(ola_gitlab_project_path gl.example.com/proj.x_y-z)" proj.x_y-z)"
for bad in gl.example.com gl.example.com/ 'gl.example.com/a b/c' 'gl.example.com/a$c' 'gl.example.com/a//b' 'gl.example.com/../x' \
           'gl.example.com/a/' 'gl.example.com/a?x=1' 'gl.example.com/a*' "gl.example.com/a
b"; do
  if ola_gitlab_project_path "$bad" >/dev/null 2>&1; then
    ko "gitlab: a path outside [A-Za-z0-9._-] is refused: $(printf %q "$bad")"
  else
    ok "gitlab: a path outside [A-Za-z0-9._-] is refused: $(printf %q "$bad")"
  fi
done
fresh
store_at review "$PROJ_ACCOUNT" tok-granular
self_say tok-granular 21899033 true 2099-01-01 7
got=$(ola_gitlab_token_self review gl.example.com/grp/sub/proj)
check "gitlab: ola_gitlab_token_self gives user_id granular expires_at token_id on one line" "$(is "$got" '21899033 true 2099-01-01 7')"
check "gitlab: ... with the token in the environment of glab, in no argument" \
  "$([ ! -e "$WORK/glab.leak" ] && grep -q 'personal_access_tokens/self' "$WORK/glab.log" && echo 0 || echo 1)"
self_say tok-granular 21899033 true "" 7
check "gitlab: a token that never expires says so" "$(is "$(ola_gitlab_token_self review gl.example.com/grp/sub/proj)" '21899033 true never 7')"
glab_say tok-granular personal_access_tokens/self 403 '{"error":"insufficient_granular_scope"}'
got=$(ola_gitlab_token_self review gl.example.com/grp/sub/proj)
rc=$?
check "gitlab: a refusal fails, with its code and what GitLab said" \
  "$([ "$rc" != 0 ] && printf '%s' "$got" | grep -q '^403 .*insufficient_granular_scope' && echo 0 || echo 1)"
forget_all
got=$(ola_gitlab_token_self review gl.example.com/grp/sub/proj)
check "gitlab: no token in the keychain fails, saying so" "$(printf '%s' "$got" | grep -q 'no review token' && echo 0 || echo 1)"

# --- status: who each token acts as, when it expires, and what is wrong.
date_in() { jq -rn --argjson d "$1" 'now + $d * 86400 | strftime("%Y-%m-%d")'; }
healthy() { # a project, its three tokens, a protected branch: nothing to warn about
  fresh
  store_at base "$PROJ_ACCOUNT" bot-tok
  store_at review "$PROJ_ACCOUNT" rev-tok
  store_at merge "$PROJ_ACCOUNT" mrg-tok
  self_say bot-tok 100 false 2099-01-01 1
  glab_say bot-tok user 200 '{"id":100,"username":"ola-bot","bot":true}'
  glab_say bot-tok "projects/$PROJ_ENC/members/all/100" 200 '{"id":100,"access_level":30}'
  self_say rev-tok 200 true 2099-06-01 2
  self_say mrg-tok 200 true 2099-07-01 3
  glab_say bot-tok users/200 200 '{"id":200,"username":"alice"}'
  glab_say mrg-tok "projects/$PROJ_ENC/protected_branches/main" 200 '{"name":"main","merge_access_levels":[{"access_level":40}]}'
}
status_of() { OUT=$(tokens "$1" status); RC=$?; }
warns() { printf '%s\n' "$OUT" | grep -c '^warning'; }
healthy
status_of "$GL"
check "tokens gitlab: status says, per token, who it acts as and when it expires" \
  "$(printf '%s\n' "$OUT" | grep -q '^base    ok, acts as ola-bot, expires 2099-01-01' &&
     printf '%s\n' "$OUT" | grep -q '^merge   ok, acts as alice, .*expires 2099-07-01' &&
     printf '%s\n' "$OUT" | grep -q '^review  ok, acts as alice, .*expires 2099-06-01' && echo 0 || echo 1)"
check "tokens gitlab: ... and says that the human's are fine-grained" "$(printf '%s\n' "$OUT" | grep '^review' | grep -q 'fine-grained' && echo 0 || echo 1)"
check "tokens gitlab: a healthy project has no warning, and status succeeds" "$([ "$(warns)" = 0 ] && [ "$RC" = 0 ] && echo 0 || echo 1)"
check "tokens gitlab: status names no github.com, and no token is in an argument" \
  "$(! printf '%s' "$OUT" | grep -q github && [ ! -e "$WORK/glab.leak" ] && echo 0 || echo 1)"
check "tokens gitlab: every call names the project explicitly, none leaves it to :id" "$(grep -q ':id' "$WORK/glab.log" && echo 1 || echo 0)"

healthy
self_say rev-tok 100 true 2099-06-01 2
glab_say bot-tok users/100 200 '{"id":100,"username":"someone-else"}'
status_of "$GL"
check "tokens gitlab: warning when the base token and the review token are one user (by user_id, whatever the names)" \
  "$(printf '%s\n' "$OUT" | grep '^warning' | grep -q 'base.*review' && echo 0 || echo 1)"
healthy
self_say mrg-tok 100 true 2099-06-01 3
status_of "$GL"
check "tokens gitlab: ... and the base token and the merge token" "$(printf '%s\n' "$OUT" | grep '^warning' | grep -q 'base.*merge' && echo 0 || echo 1)"

healthy
self_say mrg-tok 200 true 2099-07-01 2
status_of "$GL"
check "tokens gitlab: warning when review and merge are the same token (same token id)" \
  "$(printf '%s\n' "$OUT" | grep '^warning' | grep -q 'review and merge' && echo 0 || echo 1)"

healthy
glab_say bot-tok "projects/$PROJ_ENC/members/all/100" 200 '{"id":100,"access_level":40}'
status_of "$GL"
check "tokens gitlab: warning when the bot is above Developer" \
  "$(printf '%s\n' "$OUT" | grep '^warning' | grep -q 'above Developer' && echo 0 || echo 1)"
check "tokens gitlab: ... and not for a Developer" "$(healthy; status_of "$GL"; [ "$(warns)" = 0 ] && echo 0 || echo 1)"

healthy
glab_say mrg-tok "projects/$PROJ_ENC/protected_branches/main" 404 '{"message":"404 Not found"}'
status_of "$GL"
check "tokens gitlab: warning when no rule names the base branch (wildcards are not checked)" \
  "$(printf '%s\n' "$OUT" | grep '^warning' | grep -q 'no rule protects main by its exact name' && printf '%s\n' "$OUT" | grep '^warning' | grep -q 'wildcard rules are not checked' && ! printf '%s\n' "$OUT" | grep -q 'main is not protected' && echo 0 || echo 1)"
healthy
glab_say mrg-tok "projects/$PROJ_ENC/protected_branches/main" 200 '{"name":"main","merge_access_levels":[{"access_level":30}]}'
status_of "$GL"
check "tokens gitlab: warning when Developers can merge the base branch" \
  "$(printf '%s\n' "$OUT" | grep '^warning' | grep -q 'open to Developers' && echo 0 || echo 1)"
healthy
glab_say mrg-tok "projects/$PROJ_ENC/protected_branches/main" 403 '{"error":"insufficient_granular_scope"}'
status_of "$GL"
check "tokens gitlab: warning when the protection cannot be read, saying so as is" \
  "$(printf '%s\n' "$OUT" | grep '^warning' | grep -q 'cannot be read.*403' && echo 0 || echo 1)"
healthy
printf '{"mode":"integrated","forge":"gitlab","base_branch":"release/1"}\n' >"$GL/.claude/workflow.json"
glab_say mrg-tok "projects/$PROJ_ENC/protected_branches/release%2F1" 200 '{"merge_access_levels":[{"access_level":40}]}'
status_of "$GL"
check "tokens gitlab: the protection read is that of the profile's base branch, encoded" "$([ "$(warns)" = 0 ] && echo 0 || echo 1)"
printf '%s\n' "$GL_JSON" >"$GL/.claude/workflow.json"

healthy
self_say rev-tok 200 true 2000-01-01 2
status_of "$GL"
check "tokens gitlab: warning for an expired token" "$(printf '%s\n' "$OUT" | grep '^warning' | grep -q 'review.*expired' && echo 0 || echo 1)"
healthy
self_say mrg-tok 200 true "$(date_in 3)" 3
status_of "$GL"
check "tokens gitlab: warning for a token that expires within 7 days" "$(printf '%s\n' "$OUT" | grep '^warning' | grep -q 'merge.*expires in' && echo 0 || echo 1)"
healthy
self_say mrg-tok 200 true "$(date_in 30)" 3
status_of "$GL"
check "tokens gitlab: no warning at 30 days" "$([ "$(warns)" = 0 ] && echo 0 || echo 1)"

healthy
self_say rev-tok 200 false "" 2
status_of "$GL"
check "tokens gitlab: a classic token kept for review is reported as such, and status fails" \
  "$(printf '%s\n' "$OUT" | grep '^review' | grep -q 'classic' && [ "$RC" != 0 ] && echo 0 || echo 1)"
healthy
glab_say rev-tok personal_access_tokens/self 403 '{"error":"insufficient_granular_scope"}'
status_of "$GL"
check "tokens gitlab: a fine-grained token without Personal Access Token: Read says what it cannot tell" \
  "$(printf '%s\n' "$OUT" | grep '^review' | grep -qF 'expires: not readable (fine-grained token without Personal Access Token: Read)' && echo 0 || echo 1)"
healthy
glab_say rev-tok personal_access_tokens/self 401 '{"message":"401 Unauthorized"}'
status_of "$GL"
got401=$(printf '%s\n' "$OUT" | grep '^review')
rc401=$RC
healthy
glab_say rev-tok personal_access_tokens/self 403 '{"message":"403 Forbidden"}'
status_of "$GL"
check "tokens gitlab: a 401 and a 403 are the same 'unreadable', and status fails" \
  "$(printf '%s' "$got401" | grep -q unreadable && printf '%s\n' "$OUT" | grep '^review' | grep -q unreadable && [ "$rc401" != 0 ] && [ "$RC" != 0 ] && echo 0 || echo 1)"
healthy
forget_all
status_of "$GL"
check "tokens gitlab: a token missing is said, with the command that makes it" \
  "$(printf '%s\n' "$OUT" | grep -q '^review  missing — ola-workflow-tokens setup review' && [ "$RC" != 0 ] && echo 0 || echo 1)"

# discreet: the base token is the human's, and may not read itself.
healthy
glab_say bot-tok personal_access_tokens/self 403 '{"error":"insufficient_granular_scope"}'
status_of "$GL_DISCREET"
check "tokens gitlab: discreet, a base token that cannot read itself is not a warning, and says why" \
  "$(printf '%s\n' "$OUT" | grep '^base' | grep -qF 'expires: not readable' && [ "$(warns)" = 0 ] && echo 0 || echo 1)"

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
