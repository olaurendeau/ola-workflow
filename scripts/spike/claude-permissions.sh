#!/usr/bin/env bash
# Does the "allow" that hooks/elevate.sh answers get past a user's "ask" rule?
#
# Claude Code ranks an `ask` rule above an `allow` one, so a project's list cannot loosen what
# the user asked to be asked about. What is not known is what a hook's `permissionDecision:
# "allow"` becomes against an `ask` rule aimed at `glab api` or `glab` (and `gh`). Measured
# already (decision 0003): a rule is matched against the REWRITTEN command (`…/with-token.sh
# gitlab review glab api …`), which no longer begins with `glab`. So one of two things holds,
# and the permission rules the docs propose depend on which:
#   ran    the exact form passes without a question (the hook's allow holds);
#   asked  the `ask` rule wins (one more question per status and per merge, no right opened).
#
# For each of glab and gh, in a throwaway directory, with a fake glab and a fake gh on PATH
# that only write their arguments down, it runs `claude -p --output-format json` once per case
#   rule: ask on `<tool>:*` | ask on `<tool> api:*` | no rule
#   hook: rewrites the command and answers allow | answers allow without rewriting | no hook
# and prints one line per case: `ran`, `asked` (a refusal in `permission_denials`), or
# `not measurable: <why>`. `no rule` with `no hook` is the control: nothing allows the
# command, so it must be `asked`; a `ran` there means -p allows more than assumed, and the
# other lines then say nothing.
#
# What it does not measure, and says: the rules reach Claude Code through `--settings <file>`,
# and `--setting-sources project` leaves the user's settings out, so a rule placed in the
# user's own settings is NOT the source measured (same priority assumed). The mode is `-p`,
# not interactive. A managed policy, if the machine has one, still applies.
#
# It calls `claude`, which is billed to whoever runs it: the human runs this, never an agent.
# It reads and writes no setting of the human's, touches no forge (the fakes are the only
# glab and gh it reaches: they come first on PATH, and a real gh or glab ahead of them would
# find nothing to authenticate with: each case gets throwaway GH_CONFIG_DIR and
# GLAB_CONFIG_DIR, GH_TOKEN, GITHUB_TOKEN, GITLAB_TOKEN, GITLAB_ACCESS_TOKEN and OAUTH_TOKEN
# are unset for claude, and GH_HOST and GITLAB_HOST are spike.invalid, a host no keyring
# knows), and refuses a directory that is not new.
#
# Usage: scripts/spike/claude-permissions.sh [--dry-run] [output directory]
#   --dry-run  prints the cases and the commands, runs nothing and creates nothing
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=scripts/scratch.sh
. "$ROOT/scripts/scratch.sh"

dry=0
if [ "${1:-}" = --dry-run ]; then dry=1; shift; fi
[ "$#" -le 1 ] || { echo "usage: ${0##*/} [--dry-run] [output directory]" >&2; exit 2; }

command -v jq >/dev/null || { echo "spike needs jq on PATH" >&2; exit 2; }
if [ "$dry" = 0 ]; then
  command -v claude >/dev/null || { echo "spike needs the claude CLI on PATH" >&2; exit 2; }
fi

# A throwaway directory, or nothing: a given one must not exist yet, or be empty. Running in
# a project or in a home would put the test's settings and its commands where the human works.
if [ "$#" = 1 ]; then
  OUT=$1
  if [ -e "$OUT" ] && { [ ! -d "$OUT" ] || [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; }; then
    echo "${0##*/}: $OUT exists and is not an empty directory: refusing to run there" >&2
    exit 2
  fi
  if [ "$dry" = 0 ]; then
    mkdir -p "$OUT" || exit 2
    OUT=$(cd "$OUT" && pwd -P) || exit 2
  fi
elif [ "$dry" = 1 ]; then
  OUT="(a new scratch directory)"
else
  ola_scratch claude-permissions
  OUT=$OLA_SCRATCH
fi
bin=$OUT/bin

command_for() { # <tool> → the exact form the hook knows
  case $1 in
    glab) echo 'glab api projects/spike%2Fspike/statuses' ;;
    gh) echo 'gh api repos/spike/spike/statuses' ;;
  esac
}

# The fakes. They record their arguments, which is how a command is known to have run. None
# of it is made when only the plan is printed.
if [ "$dry" = 0 ]; then
mkdir -p "$bin" || exit 2
for tool in glab gh; do
  cat >"$bin/$tool" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SPIKE_CALLS:?}/${0##*/}"
echo '{}'
FAKE
  chmod +x "$bin/$tool"
done

# What elevate.sh does to an exact form: runs it through an enveloper, here one that only
# execs what follows the forge and the role.
cat >"$bin/with-token.sh" <<'WRAP'
#!/usr/bin/env bash
shift 2
exec "$@"
WRAP
chmod +x "$bin/with-token.sh"

# The test hook. `rewrite` also rewrites, in the form elevate.sh writes (`bash <path> forge role
# command`, the path quoted); both answer allow for an exact form.
cat >"$bin/hook.sh" <<'HOOK'
#!/usr/bin/env bash
mode=$1
wrapper="bash $(printf '%q' "$(cd "$(dirname "$0")" && pwd)/with-token.sh")"
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
case $cmd in
  "glab api "*) forge=gitlab ;;
  "gh api "*) forge=github ;;
  *) exit 0 ;;
esac
if [ "$mode" = rewrite ]; then
  printf '%s' "$input" | jq -c --arg c "$wrapper $forge review $cmd" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow",
      permissionDecisionReason: "spike", updatedInput: (.tool_input + {command: $c})}}'
else
  printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"spike"}}'
fi
HOOK
chmod +x "$bin/hook.sh"

fi

# One case: <n> <tool> <rule: tool|api|none> <hook: rewrite|allow|none> → prints its verdict.
run_case() {
  local n=$1 tool=$2 rule=$3 hook=$4 dir settings cmd rules="" hooks="{}" calls out rc denials
  dir=$OUT/case-$n
  calls=$dir/calls
  mkdir -p "$calls" || { echo "not measurable: cannot create $dir"; return; }
  case $rule in
    tool) rules="Bash($tool:*)" ;;
    api) rules="Bash($tool api:*)" ;;
  esac
  if [ "$hook" != none ]; then
    hooks=$(jq -nc --arg c "$(printf '%q' "$bin/hook.sh") $hook" \
      '{PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $c}]}]}')
  fi
  settings=$dir/settings.json
  jq -n --arg r "$rules" --argjson h "$hooks" \
    '{permissions: {ask: (if $r == "" then [] else [$r] end)}, hooks: $h}' >"$settings"
  cmd=$(command_for "$tool")

  out=$dir/answer.json
  printf '%s' "Run exactly this one command with the Bash tool, nothing else, then say done: $cmd" |
    ( cd "$dir" && unset GH_TOKEN GITHUB_TOKEN GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN &&
        SPIKE_CALLS=$calls GH_HOST=spike.invalid GITLAB_HOST=spike.invalid GH_CONFIG_DIR=$dir/gh-config GLAB_CONFIG_DIR=$dir/glab-config PATH="$bin:$PATH" \
        claude -p --output-format json --settings "$settings" --setting-sources project ) \
      >"$out" 2>"$dir/answer.err"
  rc=$?

  if ! jq -e . "$out" >/dev/null 2>&1; then
    echo "not measurable: claude exited $rc without JSON: $(head -c 120 "$dir/answer.err" | tr '\n' ' ')"
    return
  fi
  denials=$(jq -r '(.permission_denials // null) | if . == null then "none" else length end' "$out" 2>/dev/null)
  case $denials in
    0)
      if [ -s "$calls/$tool" ]; then
        echo ran
      else
        echo "not measurable: the command neither ran nor was refused"
      fi
      ;;
    none | "") echo "not measurable: no permission_denials in the answer" ;;
    *) echo asked ;;
  esac
}

echo "output: $OUT"
[ "$dry" = 1 ] || echo "claude version: $(claude --version 2>/dev/null)"
echo "source of the rules: --settings (not the user's settings), --setting-sources project"
echo

n=0
verdicts=""
for tool in glab gh; do
  cmd=$(command_for "$tool")
  for rule in tool api none; do
    case $rule in
      tool) rule_label="ask Bash($tool:*)" ;;
      api) rule_label="ask Bash($tool api:*)" ;;
      none) rule_label="no rule" ;;
    esac
    for hook in rewrite allow none; do
      n=$((n + 1))
      case $hook in
        rewrite) hook_label="hook rewrites + allow" ;;
        allow) hook_label="hook allow only" ;;
        none) hook_label="no hook" ;;
      esac
      if [ "$dry" = 1 ]; then
        result="(not run) $cmd"
      else
        result=$(run_case "$n" "$tool" "$rule" "$hook")
      fi
      printf '%-4s | %-20s | %-22s | %s\n' "$tool" "$rule_label" "$hook_label" "$result"
      if [ "$hook" = rewrite ] && [ "$rule" != none ]; then
        verdicts="$verdicts$tool|$rule_label|$result
"
      fi
    done
  done
done

[ "$dry" = 1 ] && exit 0
echo
echo "reading (the exact rewritten form, under an ask rule):"
printf '%s' "$verdicts" | while IFS='|' read -r tool rule_label result; do
  [ -n "$tool" ] || continue
  case $result in
    ran) meaning="the hook's allow holds: no question" ;;
    asked) meaning="the ask rule wins: one question per call" ;;
    *) meaning="no answer" ;;
  esac
  echo "  $tool, $rule_label: $result -> $meaning"
done
