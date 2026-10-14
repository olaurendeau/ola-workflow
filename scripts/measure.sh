#!/usr/bin/env bash
# What the guard costs, measured rather than remembered.
#
# Every number this repository publishes about the guard has been wrong at least once, and
# always in the same way: measured once, written down, and then quoted after the thing
# changed. Two were wrong because the *method* was wrong — a subprocess count that only
# counted the tools the author had thought to instrument. So the measurement ships, the
# README cites this script, and a number nobody can reproduce is a number nobody should
# believe.
#
#   make measure
#
# It runs no command from the sample. It does leave the shim scripts and a log in its own
# temporary directory, which it removes — but `mktemp -d` itself and the tools it calls leave
# their own files under $TMPDIR, so "writes nothing outside" was a claim too strong and has
# been withdrawn.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GUARD=$ROOT/hooks/guard.sh
SAMPLE=${1:-$ROOT/scripts/ordinary-commands.txt}

for tool in jq perl git; do
  command -v "$tool" >/dev/null || { echo "measure needs $tool on PATH" >&2; exit 2; }
done
[ -r "$SAMPLE" ] || { echo "measure: no sample at $SAMPLE" >&2; exit 2; }

WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ola-measure.XXXXXX")" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
export HOME=$WORK/home
mkdir -p "$HOME"

project() { # project <name> [profile json] → a throwaway repository
  local d=$WORK/$1
  mkdir -p "$d"
  git -C "$d" -c init.defaultBranch=main init -q 2>/dev/null
  if [ -n "${2:-}" ]; then
    mkdir -p "$d/.claude"
    printf '%s\n' "$2" >"$d/.claude/workflow.json"
  fi
  printf '%s' "$d"
}
BARE=$(project bare)
PROFILED=$(project profiled '{"mode":"integrated"}')

payload() { # payload <command> <cwd> <session>
  jq -n --arg c "$1" --arg d "$2" --arg s "$3" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:$s,cwd:$d,
      agent_type:"ola-workflow:developer",tool_input:{command:$c}}'
}

# ---------------------------------------------------------------- what it asks about
echo "# What the guard asks about"
echo
asks=0 denies=0 total=0
asked=""
while IFS= read -r cmd; do
  case $cmd in ''|'#'*) continue ;; esac
  total=$((total + 1))
  decision=$(payload "$cmd" "$PROFILED" "m$total" |
    OLA_WORKFLOW_GUARD=enforce "$GUARD" 2>/dev/null |
    jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)
  case $decision in
    ask)  asks=$((asks + 1)); asked="$asked  $cmd$(printf '\n')" ;;
    deny) denies=$((denies + 1)); echo "  REFUSED  $cmd" ;;
  esac
done <"$SAMPLE"

printf 'sample          %s commands, from %s\n' "$total" "${SAMPLE#"$ROOT"/}"
printf 'asked about     %s\n' "$asks"
printf 'refused         %s   (a refusal here would be a false positive: the sample is ordinary work)\n' "$denies"
[ "$total" -gt 0 ] && printf 'rate            %s%%\n' "$(awk -v a="$asks" -v t="$total" 'BEGIN { printf "%.1f", 100 * a / t }')"
echo
echo "The rate is a property of the sample, not of the guard: it counts how many of these"
echo "commands run something that is not in their own text. Change the mix and it moves."
[ -n "$asked" ] && { echo; echo "Asked about:"; printf '%s' "$asked"; }

# ---------------------------------------------------------------- what it costs
echo
echo "# What the guard costs, per Bash call"
echo
# Every external command is counted, by interposing a directory of shims in front of the
# PATH — not a hand-picked list, which is how 4 came to be published where 7 was true. The
# shell that runs the hook is not counted; what it execs is.
SHIM=$WORK/shim
mkdir -p "$SHIM"
REAL_PATH=$PATH
for name in $(ls /usr/bin /bin 2>/dev/null | sort -u); do
  case $name in *[!a-zA-Z0-9_.-]*) continue ;; esac
  real=$(PATH=$REAL_PATH command -v "$name" 2>/dev/null) || continue
  { printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "%s" >>"%s/exec.log"\n' "$name" "$WORK"
    printf 'exec "%s" "$@"\n' "$real"
  } >"$SHIM/$name"
  chmod +x "$SHIM/$name"
done

count() { # count <cwd> <session> → externals execed, and their names
  # The guard's own exit status is read, and a failure is reported rather than counted. The
  # first version swallowed it, and the PATH it builds holds only the shims plus /usr/bin and
  # /bin — so on a host whose `jq` lives in /opt or /usr/local the guard exited 2 and this
  # printed `4`, which is precisely the wrong number this script exists to retire. A measure
  # that cannot tell a failure from a result is not a measure.
  local rc
  : >"$WORK/exec.log"
  payload 'make check' "$1" "$2" |
    PATH="$SHIM:$(dirname "$(command -v jq)"):$(dirname "$(command -v perl)"):/usr/bin:/bin" \
      bash "$GUARD" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FAILED(exit %s)' "$rc"
    return
  fi
  grep -cv '^bash$' "$WORK/exec.log"
}
names() { sort "$WORK/exec.log" | uniq -c | awk '{ printf "%s×%s ", $2, $1 }'; }

printf 'no profile                     %-3s  %s\n' "$(count "$BARE" c1)" "$(names)"
mkdir -p "$HOME/.claude/workflow-profiles"
printf 'no profile, but you keep one   %-3s  %s\n' "$(count "$BARE" c2)" "$(names)"
printf 'a profile, first call           %-3s  %s\n' "$(count "$PROFILED" c3)" "$(names)"
printf 'a profile, cached               %-3s  %s\n' "$(count "$PROFILED" c3)" "$(names)"
echo
echo "A project with no profile pays the first line and nothing else: the guard exits 0"
echo "before any rule."
