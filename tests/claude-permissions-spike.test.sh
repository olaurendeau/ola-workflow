#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
#   SC2015: `A && ok || ko`: ok() only counts and prints, so ko() cannot run after a passing test.
#   SC2016: the single quotes are deliberate, in the fake tools' bodies and in the pattern that
#   looks for `$HOME` in the script: what is written there must reach the file unexpanded.
# scripts/spike/claude-permissions.sh calls the real `claude`, billed to the human who runs
# it: there is no such call here. A fake `claude` on PATH stands in. It reads the settings it
# is given, as Claude Code would, and answers like one where an ask rule beats a hook's
# allow, so that a script which wrote the rules wrong, or read the answer wrong, fails. What
# is proved: one line per case, the control, the refusals, and that nothing of the human's
# (settings, network) is read or reached.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/scratch.sh
. "$ROOT/scripts/scratch.sh"
SCRIPT=$ROOT/scripts/spike/claude-permissions.sh

failures=0
total=0
ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

ola_scratch claude-permissions-test
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT

FAKES=$WORK/fakes
HOME_DIR=$WORK/home
ARGS=$WORK/claude-args
NET=$WORK/net
mkdir -p "$FAKES" "$HOME_DIR/.claude"
# The human's settings: if anything of them reaches an output or a settings file, it shows.
printf '{"permissions":{"allow":["Bash(HUMAN_MARKER:*)"]}}\n' >"$HOME_DIR/.claude/settings.json"

# The fake claude. ask rule -> the call is refused; else a hook that answers allow (rewriting
# or not) -> the command runs, as the fake glab/gh on PATH records; else (the control) nothing
# allows it -> refused. FAKE_MODE bends it: down (exit 1, no JSON), silent (neither ran nor
# refused), nodenials (JSON without the field).
cat >"$FAKES/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { echo "9.9.9 (Claude Code)"; exit 0; }
printf 'cwd=%s\nargs=%s\nenv=%s|%s|%s|%s|%s\nstdin=' "$PWD" "$*" "${GH_TOKEN-unset}" "${GITHUB_TOKEN-unset}" "${GITLAB_TOKEN-unset}" "${GH_CONFIG_DIR-unset}" "${GLAB_CONFIG_DIR-unset}" >>"$CLAUDE_ARGS"
prompt=$(cat)
printf '%s\n' "$prompt" >>"$CLAUDE_ARGS"
settings=""
prev=""
for a in "$@"; do
  [ "$prev" = --settings ] && settings=$a
  prev=$a
done
[ "${FAKE_MODE:-}" != down ] || { echo "claude: not logged in" >&2; exit 1; }
[ "${FAKE_MODE:-}" != nodenials ] || { echo '{"type":"result","result":"done"}'; exit 0; }
cmd=${prompt##*: }
tool=${cmd%% *}
asked=0
ask=$(jq -r '.permissions.ask[]?' "$settings")
case $ask in
  "Bash($tool:*)" | "Bash($tool api:*)") asked=1 ;;
esac
# A hook is a shell command line, run as Claude Code runs it: with `sh -c`, the call on its
# stdin. One that does not run, or does not answer allow, allows nothing; one that rewrites
# changes the command that runs.
allowed=0
if [ "$(jq '.hooks.PreToolUse | length' "$settings")" != 0 ]; then
  hookcmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$settings")
  answer=$(jq -nc --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}' | sh -c "$hookcmd" 2>/dev/null)
  [ "$(printf '%s' "$answer" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" != allow ] || allowed=1
  rewritten=$(printf '%s' "$answer" | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null)
  [ -z "$rewritten" ] || cmd=$rewritten
fi
[ "$allowed" = 1 ] || asked=1
if [ "${FAKE_MODE:-}" = silent ]; then
  echo '{"type":"result","permission_denials":[]}'
elif [ "$asked" = 1 ]; then
  echo '{"type":"result","permission_denials":[{"tool_name":"Bash"}]}'
else
  bash -c "$cmd" >/dev/null
  echo '{"type":"result","permission_denials":[]}'
fi
EOF
# What the script must never reach: a network tool, and a REAL gh or glab, which these stand
# for. They sit on the PATH the script receives, behind the script's own fakes: only a script
# that does not put its fakes first, or does not run the command, gets here.
for t in curl wget nc ssh gh glab; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$NET_LOG"\nexit 1\n' "$t" >"$FAKES/$t"
done
chmod +x "$FAKES"/*

run() { # run <args...> → OUT, STATUS
  : >"$ARGS"
  : >"$NET"
  # A human's tokens and config directories, which must not reach a case.
  OUT=$(GH_TOKEN=leak-gh GITHUB_TOKEN=leak-github GITLAB_TOKEN=leak-gitlab GH_CONFIG_DIR=$HOME_DIR/gh GLAB_CONFIG_DIR=$HOME_DIR/glab HOME=$HOME_DIR TMPDIR=$WORK CLAUDE_ARGS=$ARGS NET_LOG=$NET PATH="$FAKES:$PATH" "$SCRIPT" "$@" 2>&1)
  STATUS=$?
}

# 1. the plan: every case, no claude call
run --dry-run
[ "$STATUS" = 0 ] && [ ! -s "$ARGS" ] && ok "--dry-run lists the cases and calls no claude" || ko "status $STATUS, claude args: $(cat "$ARGS")"
left=$(find "$WORK" -maxdepth 1 -name 'ola-claude-permissions.*')
[ -z "$left" ] && ok "--dry-run leaves no scratch directory behind" || ko "left behind: $left"
run --dry-run "$WORK/dry-out"
[ "$STATUS" = 0 ] && [ ! -e "$WORK/dry-out" ] && ok "--dry-run creates not even the directory it is given" || ko "status $STATUS, $(ls -d "$WORK/dry-out" 2>&1)"
[ "$(printf '%s\n' "$OUT" | grep -c ' | (not run) ')" = 18 ] && ok "18 cases: 2 forges, 3 rules, 3 hooks" || ko "cases: $(printf '%s\n' "$OUT" | grep -c ' | (not run) ')"

# 2. the run: one line per case, the verdict follows the rule and the hook
D=$WORK/run1
run "$D"
[ "$STATUS" = 0 ] || ko "status $STATUS: $OUT"
[ "$(grep -c '^cwd=' "$ARGS")" = 18 ] && ok "claude is called once per case" || ko "calls: $(grep -c '^cwd=' "$ARGS")"
line() { printf '%s\n' "$OUT" | grep -F "$1" | head -n 1; }
case $(line 'glab | ask Bash(glab:*) ') in *'hook rewrites + allow  | asked') ok "glab: an ask on glab:* beats the rewriting hook" ;; *) ko "$(line 'glab | ask Bash(glab:*) ')" ;; esac
case $(printf '%s\n' "$OUT" | grep -F 'glab | ask Bash(glab api:*)' | sed -n 2p) in *'hook allow only        | asked') ok "glab: an ask on glab api:* beats an allow without rewrite" ;; *) ko "$(line 'glab | ask Bash(glab api:*)')" ;; esac
case $(printf '%s\n' "$OUT" | grep -F 'gh   | no rule' | head -n 1) in *'hook rewrites + allow  | ran') ok "gh: with no rule, the rewritten form runs" ;; *) ko "$(printf '%s\n' "$OUT" | grep -F 'gh   | no rule')" ;; esac
case $(printf '%s\n' "$OUT" | grep -F 'gh   | no rule' | sed -n 3p) in *'no hook                | asked') ok "the control (no rule, no hook) is asked" ;; *) ko "control: $(printf '%s\n' "$OUT" | grep -F 'gh   | no rule')" ;; esac
[ "$(printf '%s\n' "$OUT" | grep -cE '\| (ran|asked)$')" = 18 ] && ok "one verdict line per case" || ko "verdict lines: $(printf '%s\n' "$OUT" | grep -cE '\| (ran|asked)$')"
printf '%s\n' "$OUT" | grep -q 'claude version: 9.9.9' && ok "the Claude Code version is printed" || ko "no version"
printf '%s\n' "$OUT" | grep -q "not the user's settings" && ok "it says the user's settings are not the source measured" || ko "no such line"
printf '%s\n' "$OUT" | grep -q 'glab, ask Bash(glab:\*): asked ->' && ok "the reading names the ask rule's verdict" || ko "no reading"

# 3. where it runs and how
grep -q -- '--setting-sources project' "$ARGS" && grep -q -- '--output-format json' "$ARGS" && ok "claude -p reads the rules from --settings only, project sources" || ko "args: $(head -n 3 "$ARGS")"
if grep '^cwd=' "$ARGS" | grep -v "^cwd=$D/case-" | grep -q .; then
  ko "a case ran outside its own directory: $(grep '^cwd=' "$ARGS" | grep -v "^cwd=$D/case-" | head -n 1)"
else
  ok "every case runs in its own directory under the output directory"
fi
grep -rq HUMAN_MARKER "$D" && ko "the human's settings reached the output directory" || ok "no setting of the human's is read: the marker is nowhere in the output"
printf '%s\n' "$OUT" | grep -q HUMAN_MARKER && ko "the human's settings reached the output" || ok "nor in what is printed"
grep -nE '\$HOME|~/\.claude|\.claude/settings' "$SCRIPT" | grep -v '^[0-9]*:#' | grep -q . && ko "the script names a place where the human's settings live" || ok "the script names no place where the human's settings live"
[ ! -s "$NET" ] && ok "no network tool and no real gh or glab is reached" || ko "called: $(cat "$NET")"
grep '^env=' "$ARGS" | grep -qv '^env=unset|unset|unset|' && ko "a token reached claude: $(grep '^env=' "$ARGS" | grep -v '^env=unset|unset|unset|' | head -n 1)" || ok "no GH_TOKEN, GITHUB_TOKEN or GITLAB_TOKEN reaches claude"
[ "$(grep '^env=' "$ARGS" | grep -c "|$D/case-[0-9]*/gh-config|$D/case-[0-9]*/glab-config\$")" = 18 ] && ok "gh and glab read a throwaway config directory, in each case" || ko "config dirs: $(grep '^env=' "$ARGS" | head -n 1)"
[ -x "$D/bin/glab" ] && [ -s "$D/case-7/calls/glab" ] && ok "the fake glab recorded the call (a command is known to have run)" || ko "no call recorded"

set_of() { jq -c '.permissions.ask' "$D/case-$1/settings.json"; }
hook_of() { jq -r '.hooks.PreToolUse[0].hooks[0].command // "none"' "$D/case-$1/settings.json" | awk '{print $NF}'; }
[ "$(set_of 1)" = '["Bash(glab:*)"]' ] && [ "$(set_of 4)" = '["Bash(glab api:*)"]' ] && [ "$(set_of 7)" = '[]' ] && [ "$(set_of 10)" = '["Bash(gh:*)"]' ] && [ "$(set_of 13)" = '["Bash(gh api:*)"]' ] && ok "each case writes its own rule in its settings file" || ko "rules: $(set_of 1) $(set_of 4) $(set_of 7) $(set_of 10) $(set_of 13)"
[ "$(hook_of 1)" = rewrite ] && [ "$(hook_of 2)" = allow ] && [ "$(hook_of 3)" = none ] && ok "each case wires its own hook (rewrite, allow only, none)" || ko "hooks: $(hook_of 1) $(hook_of 2) $(hook_of 3)"
rewritten=$(printf '{"tool_input":{"command":"glab api projects/x"}}' | "$D/bin/hook.sh" rewrite | jq -r '.hookSpecificOutput | .permissionDecision + " " + .updatedInput.command')
case $rewritten in "allow bash $D/bin/with-token.sh gitlab review glab api projects/x") ok "the rewriting hook answers allow with elevate.sh's form: bash <path> forge role command" ;; *) ko "rewrite: $rewritten" ;; esac
[ -z "$(printf '{"tool_input":{"command":"ls"}}' | "$D/bin/hook.sh" rewrite)" ] && ok "the test hook leaves any other command alone" || ko "hook answered for ls"

# 3b. a directory whose name holds a space: the hook is a shell command line
run "$WORK/out with space"
[ "$STATUS" = 0 ] && [ "$(printf '%s\n' "$OUT" | grep -cE '\| (ran|asked)$')" = 18 ] && ok "a directory with a space in its name: 18 verdicts" || ko "status $STATUS, verdicts: $(printf '%s\n' "$OUT" | grep -cE '\| (ran|asked)$')"
case $(printf '%s\n' "$OUT" | grep -F 'gh   | no rule' | head -n 1) in *'hook rewrites + allow  | ran') ok "...and the rewritten form still runs there" ;; *) ko "$(printf '%s\n' "$OUT" | grep -F 'gh   | no rule' | head -n 1)" ;; esac

# 4. the refusals
run "$ROOT"
[ "$STATUS" = 2 ] && [ ! -s "$ARGS" ] && ok "a directory that is not empty is refused, no claude call" || ko "status $STATUS, args: $(cat "$ARGS")"
run "$HOME_DIR"
[ "$STATUS" = 2 ] && [ ! -s "$ARGS" ] && ok "a home directory is refused" || ko "status $STATUS"
run "$D"
[ "$STATUS" = 2 ] && ok "a directory already used is refused" || ko "status $STATUS"
run a b
[ "$STATUS" = 2 ] && ok "two directories are refused" || ko "status $STATUS"
EMPTY=$WORK/empty
mkdir -p "$EMPTY"
run "$EMPTY"
[ "$STATUS" = 0 ] && ok "an empty directory is accepted" || ko "status $STATUS: $OUT"

# 5. what claude can answer instead of a verdict
for mode in down silent nodenials; do
  : >"$ARGS"
  OUT=$(FAKE_MODE=$mode HOME=$HOME_DIR TMPDIR=$WORK CLAUDE_ARGS=$ARGS NET_LOG=$NET PATH="$FAKES:$PATH" "$SCRIPT" 2>&1)
  [ "$(printf '%s\n' "$OUT" | grep -c '| not measurable: ')" = 18 ] && ok "claude '$mode': 18 lines say not measurable, none a false verdict" || ko "$mode: $(printf '%s\n' "$OUT" | grep -cE '\| (ran|asked)$') verdicts"
done
case $OUT in *"no permission_denials"*) ok "the reason is on the line" ;; *) ko "no reason: $OUT" ;; esac

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total claude-permissions-spike test(s) failed"
  exit 1
fi
echo "all $total claude-permissions-spike tests passed"
