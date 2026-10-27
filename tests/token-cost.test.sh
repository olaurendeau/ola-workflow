#!/usr/bin/env bash
# shellcheck disable=SC2015
#   `A && ok || ko`: ok() only counts and prints, so ko() cannot run after a passing test.
# Runs scripts/token-cost.sh against logs written here. The numbers are fictitious and large
# (millions), because the script prints millions with two decimals: a rule that changes the
# cost by a hundred tokens would not show, and a rule that cannot show cannot be tested.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/scratch.sh
. "$ROOT/scripts/scratch.sh"
SCRIPT=$ROOT/scripts/token-cost.sh

failures=0
total=0
ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

ola_scratch token-cost
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT

n=0
fresh() { # fresh → a new project directory, answered in $P
  n=$((n + 1))
  P=$WORK/p$n
  mkdir -p "$P"
}
T() { printf '2026-10-%sT10:00:00.000Z' "$1"; } # T <day>
call() { # call <file> <requestId|-> <timestamp> <input> <cache_creation> <cache_read> <output>
  jq -cn --arg id "$2" --arg ts "$3" --argjson i "$4" --argjson cc "$5" --argjson cr "$6" --argjson o "$7" '
    {type: "assistant", timestamp: $ts, message: {usage: {input_tokens: $i,
      cache_creation_input_tokens: $cc, cache_read_input_tokens: $cr, output_tokens: $o}}}
    | if $id != "-" then . + {requestId: $id} else . end' >>"$1"
}
umsg() { jq -cn --arg t "$2" '{type: "user", message: {role: "user", content: $t}}' >>"$1"; }
uresult() { # a tool result whose content is a list of text blocks, as Claude Code writes it
  jq -cn --arg t "$2" '{type: "user", message: {role: "user",
    content: [{type: "tool_result", tool_use_id: "x", content: [{type: "text", text: $t}]}]}}' >>"$1"
}
synthetic() { # synthetic <file> <timestamp> <mark> → an API error as Claude Code logs it: no requestId, usage at zero
  # mark "model" flags it by message.model, "flag" by isApiErrorMessage, "both" by both
  jq -cn --arg ts "$2" --arg f "$3" '
    {type: "assistant", timestamp: $ts, message: {usage: {input_tokens: 0,
      cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 0}}}
    | if $f != "flag" then .message.model = "<synthetic>" else . end
    | if $f != "model" then .isApiErrorMessage = true else . end' >>"$1"
}
sub() { # sub <project> <name> <agentType|-> → the path of a subagent log (and its meta)
  local d=$1/session1/subagents
  mkdir -p "$d"
  [ "$3" = - ] || jq -cn --arg a "$3" '{agentType: $a}' >"$d/agent-$2.meta.json"
  printf '%s' "$d/agent-$2.jsonl"
}

run() { # run [args...] → OUT, STATUS
  OUT=$("$SCRIPT" "$@" 2>"$WORK/stderr")
  STATUS=$?
}
row() { # row <role> <column> → a field of the role table (1 = role, 2 = calls, 3 = cost, 5 = rewrites)
  printf '%s\n' "$OUT" | awk -v r="$1" -v c="$2" '$1 == r { print $c; exit }'
}
prrow() { printf '%s\n' "$OUT" | awk -v r="$1" '$1 == r { print $2; exit }'; } # the cost of a PR row
totalline() { printf '%s\n' "$OUT" | grep '^total:'; }

# --- the weighted cost -----------------------------------------------------------------
fresh
call "$P/main.jsonl" r1 "$(T 01)" 1000000 2000000 10000000 1000000
run "$P"
# 1 + 2 x 1.25 + 10 x 0.1 + 1 x 5 = 9.5
[ "$STATUS" = 0 ] && [ "$(row coordinator 3)" = 9.50 ] \
  && ok "the weighted cost is input + 1.25 creation + 0.1 read + 5 output (9.50 M)" \
  || ko "the weighted cost was '$(row coordinator 3)' (exit $STATUS), expected 9.50"

# --- deduplication ---------------------------------------------------------------------
fresh
call "$P/main.jsonl" r1 "$(T 01)" 0 0 0 80000
call "$P/main.jsonl" r1 "$(T 01)" 0 0 0 1230000
run "$P"
[ "$(row coordinator 2)" = 1 ] && [ "$(row coordinator 3)" = 6.15 ] \
  && ok "a requestId logged twice (output 8 then 123) counts once, for 123" \
  || ko "a requestId logged twice gave $(row coordinator 2) call(s) for $(row coordinator 3) M, expected 1 for 6.15"

fresh
call "$P/main.jsonl" r1 "$(T 01)" 0 0 0 1230000
call "$P/main.jsonl" r1 "$(T 01)" 0 0 0 80000
run "$P"
[ "$(row coordinator 3)" = 6.15 ] \
  && ok "the largest output is kept whichever record comes last" \
  || ko "the smaller record last gave $(row coordinator 3) M, expected 6.15"

fresh
call "$P/main.jsonl" r1 "$(T 01)" 0 0 0 1000000
call "$(sub "$P" a ola-workflow:developer)" r1 "$(T 01)" 0 0 0 1000000
run "$P"
[ "$(totalline | grep -o 'over [0-9]* calls')" = "over 1 calls" ] \
  && ok "a requestId seen in two files counts once" \
  || ko "a requestId seen in two files: $(totalline)"

fresh
call "$P/main.jsonl" - "$(T 01)" 0 0 0 1000000
call "$P/main.jsonl" - "$(T 01)" 0 0 0 1000000
run "$P"
[ "$(row coordinator 2)" = 2 ] \
  && ok "calls without a requestId are not merged with one another" \
  || ko "two calls without requestId gave $(row coordinator 2)"

# --- cache rewrites --------------------------------------------------------------------
fresh
call "$P/main.jsonl" r1 "$(T 01)" 0 100000 0 1
call "$P/main.jsonl" r2 "$(T 02)" 0 0 10000 1
run "$P"
[ "$(row coordinator 5)" = 1 ] \
  && ok "100k of context followed by a 10k cache_read is a rewrite" \
  || ko "100k then 10k gave $(row coordinator 5) rewrite(s), expected 1"

fresh
call "$P/main.jsonl" r1 "$(T 01)" 0 100000 0 1
call "$P/main.jsonl" r2 "$(T 02)" 0 10000 90000 1
run "$P"
[ "$(row coordinator 5)" = 0 ] \
  && ok "100k of context followed by a 90k cache_read is not a rewrite" \
  || ko "100k then 90k gave $(row coordinator 5) rewrite(s), expected 0"

fresh
call "$P/main.jsonl" r1 "$(T 01)" 30000 30000 40000 1
call "$P/main.jsonl" r2 "$(T 02)" 0 0 40000 1
run "$P"
[ "$(row coordinator 5)" = 1 ] \
  && ok "the context is input + cache_read + cache_creation (40k against 100k is a rewrite)" \
  || ko "40k against a 100k context made of the three gave $(row coordinator 5) rewrite(s), expected 1"

fresh
call "$P/main.jsonl" r1 "$(T 01)" 0 100000 0 1
call "$P/main.jsonl" r2 "$(T 02)" 0 50000 50000 1
run "$P"
[ "$(row coordinator 5)" = 0 ] \
  && ok "a cache_read at exactly 50% of the previous context is not a rewrite" \
  || ko "100k then exactly 50k gave $(row coordinator 5) rewrite(s), expected 0"

fresh
call "$P/main.jsonl" r1 "$(T 01)" 0 0 0 1
run "$P"
[ "$(row coordinator 5)" = 0 ] \
  && ok "the first call of a log is not a rewrite" \
  || ko "a single call gave $(row coordinator 5) rewrite(s), expected 0"

fresh
call "$P/main.jsonl" a2 "$(T 02)" 0 10000 90000 1
call "$P/main.jsonl" z1 "$(T 01)" 0 100000 0 1
run "$P"
[ "$(row coordinator 5)" = 0 ] \
  && ok "calls are ordered by timestamp, not by their place in the file" \
  || ko "out-of-order records gave $(row coordinator 5) rewrite(s), expected 0"

fresh
call "$P/main.jsonl" r1 "$(T 01)" 0 1000000 0 0
call "$P/main.jsonl" r2 "$(T 02)" 1000000 0 0 0
run "$P"
# the second call costs 1 M; the first is not a rewrite
[ "$(totalline | grep -o '[0-9]* cache rewrites ([0-9.]* M)')" = "1 cache rewrites (1.00 M)" ] \
  && ok "the cost of the rewrites is the weighted cost of the calls that are one" \
  || ko "rewrite cost: $(totalline)"

for mark in model flag both; do
  fresh
  call "$P/main.jsonl" r1 "$(T 01)" 0 0 1000000 1
  synthetic "$P/main.jsonl" "$(T 02)" "$mark"
  call "$P/main.jsonl" r3 "$(T 03)" 0 1000000 0 0
  run "$P"
  # the error is not a call: the third call is rewritten against the first one's 1 M, and costs 1.25 M
  { [ "$(row coordinator 2)" = 2 ] && [ "$(totalline | grep -o '[0-9]* cache rewrites ([0-9.]* M)')" = "1 cache rewrites (1.25 M)" ]; } \
    && ok "an API error record (marked by '$mark') is not a call and does not hide the rewrite after it" \
    || ko "synthetic record marked by '$mark': $(row coordinator 2) call(s), $(totalline)"
done

# --- the role --------------------------------------------------------------------------
fresh
call "$P/main.jsonl" r1 "$(T 01)" 1000000 0 0 0
call "$(sub "$P" a ola-workflow:developer)" r2 "$(T 01)" 2000000 0 0 0
call "$(sub "$P" b ola-workflow:pr-reviewer)" r3 "$(T 01)" 3000000 0 0 0
call "$(sub "$P" c -)" r4 "$(T 01)" 4000000 0 0 0
call "$(sub "$P" d plain-name)" r5 "$(T 01)" 5000000 0 0 0
run "$P"
{
  [ "$(row coordinator 3)" = 1.00 ] && [ "$(row developer 3)" = 2.00 ] \
    && [ "$(row pr-reviewer 3)" = 3.00 ] && [ "$(row unknown 3)" = 4.00 ] \
    && [ "$(row plain-name 3)" = 5.00 ]
} \
  && ok "the role comes from meta.json, without the prefix; the main session is the coordinator; no meta is unknown" \
  || ko "roles: $(printf '%s\n' "$OUT" | sed -n 2,7p | tr '\n' '|')"

# --- the attribution to a PR -----------------------------------------------------------
fresh
umsg "$(sub "$P" a ola-workflow:developer)" "Slot 1. Fix the thing, PR #12."
call "$(sub "$P" a ola-workflow:developer)" r1 "$(T 01)" 1000000 0 0 0
umsg "$(sub "$P" b ola-workflow:pr-reviewer)" "Review this pull request #13 please"
call "$(sub "$P" b ola-workflow:pr-reviewer)" r2 "$(T 01)" 2000000 0 0 0
umsg "$(sub "$P" c ola-workflow:pr-reviewer)" "Review https://github.com/o/r/pull/14"
call "$(sub "$P" c ola-workflow:pr-reviewer)" r3 "$(T 01)" 3000000 0 0 0
run "$P"
{ [ "$(prrow '#12')" = 1.00 ] && [ "$(prrow '#13')" = 2.00 ] && [ "$(prrow '#14')" = 3.00 ]; } \
  && ok "the first user message gives the PR: 'PR #N', 'pull request #N' and '/pull/N'" \
  || ko "PR rows: $(printf '%s\n' "$OUT" | grep '^#' | tr '\n' '|')"

fresh
f=$(sub "$P" a ola-workflow:developer)
umsg "$f" "Slot 1. Fix the thing."
uresult "$f" "Created https://github.com/o/r/pull/21"
uresult "$f" "Also https://github.com/o/r/pull/22"
call "$f" r1 "$(T 01)" 1000000 0 0 0
run "$P"
{ [ "$(prrow '#21')" = 1.00 ] && [ -z "$(prrow '#22')" ]; } \
  && ok "without a PR in the first message, the first /pull/N of a tool result gives it" \
  || ko "tool result attribution: $(printf '%s\n' "$OUT" | grep -E '^(#|none)' | tr '\n' '|')"

fresh
f=$(sub "$P" a ola-workflow:developer)
umsg "$f" "Fix the thing, PR #12."
uresult "$f" "Created https://github.com/o/r/pull/99"
call "$f" r1 "$(T 01)" 1000000 0 0 0
run "$P"
{ [ "$(prrow '#12')" = 1.00 ] && [ -z "$(prrow '#99')" ]; } \
  && ok "the first message outranks a tool result" \
  || ko "precedence: $(printf '%s\n' "$OUT" | grep -E '^(#|none)' | tr '\n' '|')"

fresh
f=$(sub "$P" a ola-workflow:developer)
umsg "$f" "Fix the thing."
call "$f" r1 "$(T 01)" 1000000 0 0 0
umsg "$P/main.jsonl" "Look at PR #5"
uresult "$P/main.jsonl" "see https://github.com/o/r/pull/6"
call "$P/main.jsonl" r2 "$(T 01)" 2000000 0 0 0
run "$P"
{ [ "$(prrow none)" = 3.00 ] && [ "$(totalline | grep -o '[0-9]* distinct PRs')" = "0 distinct PRs" ]; } \
  && ok "no PR found gives none, and the main session is attributed to no PR" \
  || ko "none: $(printf '%s\n' "$OUT" | grep -E '^(#|none)' | tr '\n' '|') / $(totalline)"

fresh
f=$(sub "$P" a ola-workflow:developer)
umsg "$f" "PR #12"
call "$f" r1 "$(T 01)" 1000000 0 0 0
f=$(sub "$P" b ola-workflow:pr-reviewer)
umsg "$f" "PR #12"
call "$f" r2 "$(T 01)" 1000000 0 0 0
f=$(sub "$P" c ola-workflow:pr-reviewer)
umsg "$f" "PR #13"
call "$f" r3 "$(T 01)" 1000000 0 0 0
run "$P"
{ [ "$(prrow '#12')" = 2.00 ] && [ "$(totalline | grep -o '[0-9]* distinct PRs')" = "2 distinct PRs" ]; } \
  && ok "the logs of one PR add up, and the distinct PRs are counted" \
  || ko "distinct PRs: $(totalline)"

# --- the window ------------------------------------------------------------------------
fresh
call "$P/main.jsonl" r1 "$(T 01)" 1000000 0 0 0
call "$P/main.jsonl" r2 "$(T 20)" 2000000 0 0 0
run --since 2026-10-10 "$P"
[ "$(row coordinator 2)" = 1 ] && [ "$(row coordinator 3)" = 2.00 ] \
  && ok "--since leaves out a call that is earlier" \
  || ko "--since: $(row coordinator 2) call(s), $(row coordinator 3) M, expected 1 and 2.00"

run --until 2026-10-10 "$P"
[ "$(row coordinator 2)" = 1 ] && [ "$(row coordinator 3)" = 1.00 ] \
  && ok "--until leaves out a call that is later" \
  || ko "--until: $(row coordinator 2) call(s), $(row coordinator 3) M, expected 1 and 1.00"

run --since=2026-10-10 "$P"
[ "$STATUS" = 0 ] && [ "$(row coordinator 3)" = 2.00 ] \
  && ok "--since=DATE is the same as --since DATE" \
  || ko "--since=: exit $STATUS, '$(row coordinator 3)', expected 2.00"

run --until=2026-10-10 "$P"
[ "$STATUS" = 0 ] && [ "$(row coordinator 3)" = 1.00 ] \
  && ok "--until=DATE is the same as --until DATE" \
  || ko "--until=: exit $STATUS, '$(row coordinator 3)', expected 1.00"

fresh
call "$P/main.jsonl" r1 "$(T 01)" 0 100000 0 1
call "$P/main.jsonl" r2 "$(T 20)" 0 0 10000 1
run --since 2026-10-10 "$P"
[ "$(row coordinator 5)" = 1 ] \
  && ok "a rewrite is judged against the call before the window, not against nothing" \
  || ko "rewrite at the edge of the window: $(row coordinator 5), expected 1"

# --- the PR table is capped ------------------------------------------------------------
fresh
for k in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
  f=$(sub "$P" "a$k" ola-workflow:developer)
  umsg "$f" "PR #$((100 + k))"
  call "$f" "r$k" "$(T 01)" "${k}000000" 0 0 0
done
run "$P"
# PR #101 costs 1 M, #116 costs 16 M: the table keeps the 15 dearest and sums the rest
{
  [ "$(printf '%s\n' "$OUT" | grep -c '^#')" = 15 ] && [ "$(prrow '#116')" = 16.00 ] \
    && [ "$(prrow '#102')" = 2.00 ] && [ -z "$(prrow '#101')" ] \
    && [ "$(printf '%s\n' "$OUT" | grep '^(1 other PRs)' | awk '{print $4}')" = 1.00 ]
} \
  && ok "the PR table keeps the 15 dearest PRs and sums the others on one row" \
  || ko "PR table of 16 PRs: $(printf '%s\n' "$OUT" | grep -E '^(#|\()' | tr '\n' '|')"

fresh
for k in 1 2 3; do
  f=$(sub "$P" "a$k" ola-workflow:developer)
  umsg "$f" "PR #$((100 + k))"
  call "$f" "r$k" "$(T 01)" "${k}000000" 0 0 0
done
run "$P"
[ "$(printf '%s\n' "$OUT" | grep -c 'other PRs')" = 0 ] \
  && ok "no 'other PRs' row when the table is not cut" \
  || ko "an 'other PRs' row for 3 PRs"

# --- an unreadable meta.json -------------------------------------------------------------
fresh
f=$(sub "$P" a ola-workflow:developer)
printf '{"agentTy' >"${f%.jsonl}.meta.json"
call "$f" r1 "$(T 01)" 1000000 0 0 0
run "$P"
{ [ "$STATUS" = 0 ] && [ "$(row unknown 3)" = 1.00 ] && grep -q 'meta.json' "$WORK/stderr"; } \
  && ok "an unreadable meta.json gives role unknown and is reported on stderr" \
  || ko "broken meta.json: exit $STATUS, role unknown '$(row unknown 3)', stderr '$(cat "$WORK/stderr")'"

fresh
f=$(sub "$P" a -)
call "$f" r1 "$(T 01)" 1000000 0 0 0
run "$P"
[ ! -s "$WORK/stderr" ] \
  && ok "an absent meta.json is unknown without a word" \
  || ko "an absent meta.json wrote on stderr: $(cat "$WORK/stderr")"

# --- several directories and the errors ------------------------------------------------
fresh
A=$P
call "$A/main.jsonl" r1 "$(T 01)" 1000000 0 0 0
fresh
call "$P/main.jsonl" r2 "$(T 01)" 2000000 0 0 0
run "$A" "$P"
[ "$(row coordinator 3)" = 3.00 ] \
  && ok "several directories add up" \
  || ko "two directories gave $(row coordinator 3) M, expected 3.00"

fresh
call "$P/main.jsonl" r1 "$(T 01)" 1000000 0 0 0
printf '{"type":"assistant","timest' >>"$P/main.jsonl"
run "$P"
[ "$STATUS" = 0 ] && [ "$(row coordinator 3)" = 1.00 ] \
  && ok "a half-written last line does not cost the measurement" \
  || ko "truncated line: exit $STATUS, $(row coordinator 3) M"

fresh
run "$P"
{ [ "$STATUS" = 2 ] && [ -s "$WORK/stderr" ]; } \
  && ok "a directory without log exits 2 and says so on stderr" \
  || ko "an empty directory exited $STATUS"

run "$WORK/does-not-exist"
[ "$STATUS" = 2 ] && ok "a directory that does not exist exits 2" || ko "a missing directory exited $STATUS"

run
[ "$STATUS" = 2 ] && ok "no directory exits 2" || ko "no argument exited $STATUS"

run --bogus "$P"
[ "$STATUS" = 2 ] && ok "an unknown option exits 2" || ko "an unknown option exited $STATUS"

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total token-cost test(s) failed"
  exit 1
fi
echo "all $total token-cost tests passed"
