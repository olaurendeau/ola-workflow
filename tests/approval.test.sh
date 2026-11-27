#!/usr/bin/env bash
# shellcheck disable=SC2015
#   SC2015, `A && ok || ko`: ok() only counts and prints, so ko() cannot run after a passing test.
# The `approval` key in the Escalation section of the brief, in both modes: what a profile
# without it prints (nothing new), what each step and each value prints, and what a value the
# schema refuses is read as. Throwaway repositories and a throwaway HOME, no network.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/scratch.sh
. "$ROOT/scripts/scratch.sh"

failures=0
total=0
ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

ola_scratch approval
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT
export HOME=$WORK/home
mkdir -p "$HOME"
unset GH_TOKEN GITHUB_TOKEN

# One repository per mode. Integrated reads the profile the project commits, discreet the one
# in HOME, so a profile is written where its mode says.
INT=$WORK/integrated
DIS=$WORK/discreet
for r in "$INT" "$DIS"; do
  mkdir -p "$r"
  git -C "$r" -c init.defaultBranch=main init -q
  git -C "$r" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
done
git -C "$INT" remote add origin https://github.com/someone/integrated.git
git -C "$DIS" remote add origin https://github.com/someone/discreet.git
mkdir -p "$INT/.claude" "$HOME/.claude/workflow-profiles/github.com/someone/discreet"

# A brief takes about a second, and the same profile is asked for by several checks: each
# one is rendered once and kept.
mkdir -p "$WORK/cache"
escalation() { # escalation <mode> <profile json> → the Escalation section of the brief
  local mode=$1 json=$2 repo=$INT file=$INT/.claude/workflow.json
  local cached=$WORK/cache/$(printf '%s %s' "$mode" "$json" | cksum | tr ' ' _)
  if [ ! -f "$cached" ]; then
    if [ "$mode" = discreet ]; then
      repo=$DIS
      file=$HOME/.claude/workflow-profiles/github.com/someone/discreet/profile.json
    fi
    printf '%s\n' "$json" >"$file"
    "$ROOT/bin/ola-workflow-brief" "$repo" 2>&1 |
      awk '/^## Escalation/ { on = 1 } on { print } /^Record a decision/ { on = 0 }' >"$cached"
  fi
  cat "$cached"
}

has() { # has <text> <line> → 0 when the line is in the text, whole
  printf '%s\n' "$1" | grep -qxF -- "$2"
}
mentions() { # mentions <text> <fragment>
  printf '%s\n' "$1" | grep -qF -- "$2"
}
check() { # check <label> <command...>
  local label=$1
  shift
  if "$@"; then ok "$label"; else ko "$label"; fi
}
lacks() { ! "$@"; }
lineno() { # lineno <text> <line> → the number of the first line equal to it, 0 when none
  printf '%s\n' "$1" | awk -v want="$2" '$0 == want { print NR; found = 1; exit } END { if (!found) print 0 }'
}

FIXED_1='- Loosening a check or a quality threshold.'
FIXED_2='- Ruling that a security finding is a false positive.'
FIXED_3='- Widening a token, or what a token may do.'
FIXED_4='- Changing the settings or the rulesets of the repository.'
RELEASE_CURRENT="- Release: whether to release, and the version. The release itself is the human's act."
RELEASE_HUMAN='- Release: the human decides whether to release, and the version. Once they have asked, the coordinator does the whole chain: the release pull request, the annotated tag, the GitHub release.'

for mode in integrated discreet; do
  base='"mode": "'$mode'"'

  # --- Without the key, nothing of the new texts ------------------------------------------
  out=$(escalation "$mode" "{$base}")
  check "$mode: without approval, the release line is the current one" has "$out" "$RELEASE_CURRENT"
  for text in "$FIXED_1" "$FIXED_2" "$FIXED_3" "$FIXED_4" 'Who approves each step' 'the whole chain' 'my default'; do
    check "$mode: without approval, no \"$text\"" lacks mentions "$out" "$text"
  done
  withextra=$(escalation "$mode" "{$base, \"escalation_extra\": [\"changing the billing provider\"]}")
  check "$mode: without approval, escalation_extra still follows the list" has "$withextra" '- changing the billing provider'

  # --- The four fixed lines, whatever the values ------------------------------------------
  for approval in '{}' '{"design": "human"}' '{"design": "agent"}' '{"architecture": "human"}' \
                  '{"architecture": "agent"}' '{"merge": "human"}' '{"merge": "agent"}' \
                  '{"merge": {"human_when": {"paths": ["infra/**"]}}}' '{"release": "human"}' \
                  '{"release": "agent"}' '{"design": "maybe"}' '{"merge": {}}' '{"release": "maybe"}'; do
    out=$(escalation "$mode" "{$base, \"approval\": $approval}")
    for line in "$FIXED_1" "$FIXED_2" "$FIXED_3" "$FIXED_4"; do
      check "$mode: approval $approval keeps \"${line#- }\"" has "$out" "$line"
    done
    check "$mode: approval $approval prints who approves each step" mentions "$out" 'Who approves each step:'
  done

  # --- escalation_extra lengthens the list and removes none of it -------------------------
  plain=$(escalation "$mode" "{$base, \"approval\": {}}")
  extended=$(escalation "$mode" "{$base, \"approval\": {}, \"escalation_extra\": [\"changing the billing provider\", \"anything under legal/\"]}")
  for line in "$FIXED_1" "$FIXED_2" "$FIXED_3" "$FIXED_4" "$RELEASE_CURRENT" '- changing the billing provider' '- anything under legal/'; do
    check "$mode: with escalation_extra, \"${line#- }\" is there" has "$extended" "$line"
  done
  without_extra=$(printf '%s\n' "$extended" | grep -vxF -e '- changing the billing provider' -e '- anything under legal/')
  [ "$without_extra" = "$plain" ] &&
    ok "$mode: escalation_extra adds its lines and changes nothing else" ||
    ko "$mode: escalation_extra changed more than its own lines"
  first=$(lineno "$extended" "$FIXED_4")
  last=$(lineno "$extended" '- anything under legal/')
  block=$(lineno "$extended" 'Who approves each step:')
  order="$first,$last,$block"
  { [ "$first" -gt 0 ] && [ "$first" -lt "$last" ] && [ "$last" -lt "$block" ]; } &&
    ok "$mode: the fixed lines, then escalation_extra, then who approves ($order)" ||
    ko "$mode: the order is not fixed lines, escalation_extra, who approves ($order)"

  # --- Release ----------------------------------------------------------------------------
  out=$(escalation "$mode" "{$base, \"approval\": {\"release\": \"agent\"}}")
  check "$mode: release agent, no Release line in the list" lacks mentions "${out%%Who approves each step:*}" '- Release:'
  case $mode in
    integrated)
      check "$mode: release agent, the block says the coordinator decides" \
        has "$out" '- Release: the coordinator decides whether to release, and the version' ;;
    discreet)
      check "$mode: release agent, the block says nothing is published here" \
        has "$out" '- Release: nothing is published on the forge here' ;;
  esac
  out=$(escalation "$mode" "{$base, \"approval\": {\"release\": \"human\"}}")
  check "$mode: release human, the line of the whole chain" has "$out" "$RELEASE_HUMAN"
  check "$mode: release human, no line of the current text" lacks has "$out" "$RELEASE_CURRENT"
  check "$mode: release human, no longer the human's act" lacks mentions "$out" "is the human's act"
  for approval in '{}' '{"release": "maybe"}'; do
    out=$(escalation "$mode" "{$base, \"approval\": $approval}")
    check "$mode: release $approval, the current line" has "$out" "$RELEASE_CURRENT"
    check "$mode: release $approval, not the whole chain" lacks has "$out" "$RELEASE_HUMAN"
  done
  out=$(escalation "$mode" "{$base, \"approval\": {}}")
  [ "$mode" = integrated ] &&
    check "$mode: release omitted is marked as a default" \
      has "$out" '- Release: the human decides, and acts (not in the profile — my default)'
  out=$(escalation "$mode" "{$base, \"approval\": {\"release\": \"human\"}}")
  [ "$mode" = integrated ] &&
    check "$mode: release human is not marked as a default" \
      has "$out" '- Release: the human decides; once they have asked, the coordinator does the whole chain'

  # --- Design and architecture ------------------------------------------------------------
  for step in Design Architecture; do
    key=$(printf '%s' "$step" | tr '[:upper:]' '[:lower:]')
    out=$(escalation "$mode" "{$base, \"approval\": {}}")
    check "$mode: $key omitted is marked as a default" mentions "$out" "- $step: "
    case $key in
      design) agent='the design-reviewer, with no stop for the human' ;;
      *) agent='no stop for the human' ;;
    esac
    check "$mode: $key omitted reads as an agent, marked" has "$out" "- $step: $agent (not in the profile — my default)"
    out=$(escalation "$mode" "{$base, \"approval\": {\"$key\": \"agent\"}}")
    check "$mode: $key agent, not marked" has "$out" "- $step: $agent"
    out=$(escalation "$mode" "{$base, \"approval\": {\"$key\": \"human\"}}")
    check "$mode: $key human" has "$out" "- $step: the human"
    for bad in '"maybe"' '3'; do
      out=$(escalation "$mode" "{$base, \"approval\": {\"$key\": $bad}}")
      check "$mode: $key $bad is read as human" has "$out" "- $step: the human"
    done
  done

  # --- Merge ------------------------------------------------------------------------------
  if [ "$mode" = discreet ]; then
    for approval in '{}' '{"merge": "human"}' '{"merge": "agent"}'; do
      out=$(escalation "$mode" "{$base, \"approval\": $approval}")
      check "$mode: merge $approval, nothing is merged here" has "$out" '- Merge: nothing is merged here'
    done
  else
    out=$(escalation "$mode" "{$base, \"approval\": {\"merge\": \"human\"}}")
    check "$mode: merge human" has "$out" '- Merge: the human merges every pull request'
    out=$(escalation "$mode" "{$base, \"approval\": {\"merge\": \"agent\"}}")
    check "$mode: merge agent" has "$out" '- Merge: the coordinator merges a pull request whose gate holds'
    out=$(escalation "$mode" "{$base, \"approval\": {\"merge\": {\"human_when\": {\"paths\": [\"infra/**\"]}}}}")
    check "$mode: merge human_when" mentions "$out" '- Merge: the human merges a pull request that touches a path or matches a pattern of approval.merge.human_when'
    out=$(escalation "$mode" "{$base, \"approval\": {}}")
    check "$mode: merge omitted reads merge.sensitive_*, marked" mentions "$out" 'merge.sensitive_paths or matches merge.sensitive_patterns, the coordinator any other whose gate holds (not in the profile — my default)'
    for bad in '"maybe"' '{}'; do
      out=$(escalation "$mode" "{$base, \"approval\": {\"merge\": $bad}}")
      check "$mode: merge $bad is read as human" has "$out" '- Merge: the human merges every pull request'
    done
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total approval test(s) failed"
  exit 1
fi
echo "all $total approval tests passed"
