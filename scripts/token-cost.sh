#!/usr/bin/env bash
# What did a piece of work cost in tokens, by role and by pull request?
#
# Reads the Claude Code logs of a project (~/.claude/projects/<slug>/) and prints the
# weighted cost per role, per PR, and how many times the prompt cache had to be rewritten.
# It is the before/after baseline of the token-cost epic, so the rules below are the
# measurement: change one and the numbers of two runs stop being comparable.
#
# Usage: scripts/token-cost.sh [--since <ISO date>] [--until <ISO date>] <directory>...
#   --since   keep the calls at or after this timestamp
#   --until   keep the calls strictly before it (so `--until 2026-11-01` stops on 31 Oct)
#   Several directories are accepted: a session opened from a worktree logs elsewhere.
#
# Sources
#   <dir>/*.jsonl                          the main session, role "coordinator"
#   <dir>/<session>/subagents/agent-*.jsonl  a subagent; its role is the agentType of the
#                                          sibling agent-*.meta.json, without the
#                                          "ola-workflow:" prefix ("unknown" when absent, or when
#                                          unreadable, which is then said on stderr)
#
# A call is an assistant record carrying message.usage, that the API served. Claude Code
# also logs its own errors ("API Error: Can't reach the API server", a limit reached) as
# assistant records with model "<synthetic>", isApiErrorMessage, no requestId and a usage
# at zero: they are not calls. Counted, each would be a cache rewrite for 0, and would set
# the previous context to 0, hiding the real rewrite that follows an error.
# A request is logged several times while it streams (output 8, then 123): the calls are
# deduplicated by requestId keeping the record with the most output tokens — keeping the
# first would undercount the output, which weighs 5. A requestId seen in two files counts
# once.
#
# Weighted cost = input x 1 + cache_creation x 1.25 + cache_read x 0.1 + output x 5.
# It is in input-token equivalents ("raw", shown in M) and its rule never depends on the model:
# it is the base of the before/after comparison, and changing it makes two runs incomparable.
#
# Cost in $ = the weighted cost x the input price of the call's model / 1 000 000. The model
# is message.model and its price is in the table below: the longest prefix that matches wins
# ("claude-opus-5-5" is priced by its own line, not by "claude-opus-5"). One price per model is
# enough for this rule because it carries the ratios 1.25 / 0.1 / 5 of the list prices.
# A call whose model is absent, or not in the table, counts in the raw cost and not in the
# cost in $, and an "unpriced:" line under the total names each such model, with its calls and
# its raw cost. A price is never guessed: add the model to the table.
#
# A cache rewrite is a call whose cache_read is under 50% of the previous call's context
# (input + cache_read + cache_creation), calls sorted by timestamp within one log. The
# first call of a log is not one. The flag is computed on the whole log and only then
# filtered by --since/--until, otherwise the first call of the window would never count.
#
# A PR is attributed, in this order, from:
#   1. the first user message of the log: "PR #N", "pull request #N" or "/pull/N";
#   2. else the first "/pull/N" in a tool result (a developer's `gh pr create`);
#   3. else "none".
# The main session is attributed to no PR. It is a heuristic and the share left in "none"
# is printed, so that one can see what it covers.
#
# Needs bash (3.2 is enough: nothing here is an associative array) and jq >= 1.5. All the
# aggregation is in jq for that reason.
set -uo pipefail

# Input price per model prefix, in $ per million tokens.
# Source: Anthropic pricing page, https://platform.claude.com/docs/en/about-claude/pricing,
# "Model pricing", base input tokens, read on 2026-11-02. One line per prefix, "<prefix> <price>":
# the tests read the lines of this block, so keep that form.
# The page differs from the rule above in two places, that this script does not follow so that
# the raw cost stays comparable: the cache read of Opus 5.5 and Sonnet 5.5 is 0.05x the input
# price, not 0.1x; Haiku 5.5 costs 5x more for a prompt over 100 000 tokens (the price below is
# the one up to 100 000).
PRICES='
claude-opus-5-5    4
claude-opus-5      5
claude-sonnet-5-5  2
claude-sonnet-5    2
claude-haiku-5-5   0.10
'

# shellcheck source=scripts/scratch.sh
. "$(dirname "$0")/scratch.sh"

usage() {
  echo "usage: ${0##*/} [--since <ISO date>] [--until <ISO date>] <directory>..." >&2
  exit 2
}

since=""
until_=""
dirs=""
while [ $# -gt 0 ]; do
  case $1 in
    --since | --until)
      [ $# -ge 2 ] || usage
      if [ "$1" = --since ]; then since=$2; else until_=$2; fi
      shift 2
      ;;
    --since=*) since=${1#--since=}; shift ;;
    --until=*) until_=${1#--until=}; shift ;;
    -h | --help) usage ;;
    -*) echo "${0##*/}: unknown option $1" >&2; usage ;;
    *)
      # One directory per line: a path with a space is one path, and an array would not
      # survive `set -u` on bash 3.2.
      dirs="$dirs$1
"
      shift
      ;;
  esac
done
[ -n "$dirs" ] || usage

command -v jq >/dev/null || { echo "${0##*/}: jq is needed" >&2; exit 2; }

ola_scratch token-cost
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT

# One log in, one object out: {role, pr, calls: [{id, ts, o, cost, rw}]}.
# The input is read as text and parsed line by line with fromjson?, because the log of a
# session still running ends on a half-written line, and one such line must not cost the
# whole measurement. That is the one place where an error is swallowed without a word, on purpose.
# shellcheck disable=SC2016
#   The program is jq's, not the shell's.
PER_LOG='
  def text: if type == "string" then .
            elif type == "array" then [.[] | select(type == "object" and .type == "text") | .text // empty | strings] | join("\n")
            else "" end;
  def result_text: if type == "string" then .
                   elif type == "array" then [.[] | (.text? // empty) | strings] | join("\n")
                   else "" end;
  def pr_in($re): first(match($re; "i") | .captures[0].string | tonumber) // null;
  def price($m; $table): if ($m | type) != "string" then null
                 else [$table[] | select(.p as $p | $m | startswith($p))] | sort_by(.p | length) | last | .v end;
  def tool_results: [.message.content | arrays | .[] | select(type == "object" and .type == "tool_result") | .content | result_text] | join("\n");

  ( [$prices | split("\n")[] | split(" ") | map(select(length > 0)) | select(length == 2)
     | {p: .[0], v: (.[1] | tonumber)}] ) as $table
  | [ inputs | fromjson? | select(type == "object") | . as $r
    | if $r.type == "assistant" and ($r.message.usage | type) == "object"
         and $r.message.model != "<synthetic>" and $r.isApiErrorMessage != true then
        $r.message.usage as $u
        | {k: "a", id: $r.requestId, ts: ($r.timestamp // ""),
           m: (if ($r.message.model | type) == "string" then $r.message.model else null end),
           price: price($r.message.model; $table),
           i: ($u.input_tokens // 0), cc: ($u.cache_creation_input_tokens // 0),
           cr: ($u.cache_read_input_tokens // 0), o: ($u.output_tokens // 0)}
      elif $r.type == "user" then
        {k: "u", msg: ($r | .message.content | text | pr_in("(?:PR #|pull request #|/pull/)([0-9]+)")),
         res: ($r | tool_results | pr_in("/pull/([0-9]+)"))}
      else empty end
  ] as $recs
  | ([$recs[] | select(.k == "u")]) as $users
  | ( if $main then "none"
      elif ($users | length) > 0 and $users[0].msg != null then $users[0].msg | tostring
      else ([$users[] | .res | select(. != null)] | first // null | if . == null then "none" else tostring end)
      end ) as $pr
  | [ $recs | to_entries[] | select(.value.k == "a") | .value + {n: .key} ]
  | map(.id = (.id // ("noid:" + $file + ":" + (.n | tostring))))
  | group_by(.id) | map(max_by(.o)) | sort_by(.ts)
  | reduce .[] as $c ({prev: null, out: []};
      ($c.i + $c.cr + $c.cc) as $ctx
      | .out += [{id: $c.id, ts: $c.ts, o: $c.o, m: $c.m, price: $c.price,
                  cost: ($c.i + $c.cc * 1.25 + $c.cr * 0.1 + $c.o * 5),
                  rw: (.prev != null and $c.cr < 0.5 * .prev)}]
      | .prev = $ctx)
  | {role: $role, pr: $pr, calls: .out}
'

# shellcheck disable=SC2016
AGGREGATE='
  [ .[] | .role as $role | .pr as $pr | .calls[] | . + {role: $role, pr: $pr} ]
  | group_by(.id) | map(max_by(.o))
  | map(select(($since == "" or .ts >= $since) and ($until == "" or .ts < $until)))
  | map(. + {usd: (if .price != null then .cost * .price / 1000000 else 0 end)})
  | . as $calls
  | (map(.cost) | add // 0) as $total
  | (map(.usd) | add // 0) as $totalusd
  | def share($x): if $total > 0 then $x * 100 / $total else 0 end;
    def shareusd($x): if $totalusd > 0 then $x * 100 / $totalusd else 0 end;
    def sum: map(.cost) | add // 0;
    def usd: map(.usd) | add // 0;
    ( $calls | group_by(.role)
      | map({role: .[0].role, n: length, cost: sum, usd: usd,
             rw: (map(select(.rw)) | length), rwcost: (map(select(.rw)) | sum)})
      | sort_by(-.cost) | .[]
      | ["R", .role, .n, .cost, share(.cost), .rw, .rwcost, .usd, shareusd(.usd)] ),
    ( $calls | map(. + {mk: (.m // "(no model)")}) | group_by(.mk)
      | map({m: .[0].mk, n: length, cost: sum, usd: usd, priced: (.[0].price != null)})
      | sort_by([-.usd, -.cost]) | .[]
      | ["M", .m, .n, .cost, .usd, shareusd(.usd), .priced] ),
    ( $calls | group_by(.pr) | map({pr: .[0].pr, cost: sum, usd: usd}) | sort_by(-.cost)
      | .[:15][] | ["P", .pr, .cost, share(.cost), .usd] ),
    ( $calls | group_by(.pr) | map({pr: .[0].pr, cost: sum, usd: usd}) | sort_by(-.cost)
      | .[15:] | select(length > 0)
      | ["O", length, (map(.cost) | add), share(map(.cost) | add), (map(.usd) | add)] ),
    ["T", ($calls | length), $total, ([$calls[] | select(.pr != "none") | .pr] | unique | length),
     (($calls | map(select(.rw)) | length)), ($calls | map(select(.rw)) | sum), $totalusd],
    ( $calls | map(select(.price == null) | . + {mk: (.m // "(no model)")}) | group_by(.mk)
      | map(["U", .[0].mk, length, sum]) | .[] )
  | @tsv
'

found=0
LOGS=$WORK/logs.jsonl
: >"$LOGS"
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  if [ ! -d "$dir" ]; then
    echo "${0##*/}: $dir is not a directory" >&2
    exit 2
  fi
  for f in "$dir"/*.jsonl "$dir"/*/subagents/agent-*.jsonl; do
    [ -f "$f" ] || continue
    case $f in
      "$dir"/*/subagents/agent-*.jsonl)
        role=""
        meta=${f%.jsonl}.meta.json
        if [ -f "$meta" ]; then
          role=$(jq -r '.agentType // empty' "$meta" 2>/dev/null) \
            || echo "${0##*/}: $meta is not readable, the role of $f is unknown" >&2
        fi
        role=${role#ola-workflow:}
        [ -n "$role" ] || role=unknown
        main=false
        ;;
      *) role=coordinator main=true ;;
    esac
    jq -cnR --arg role "$role" --arg file "${f%/}" --arg prices "$PRICES" --argjson main "$main" "$PER_LOG" <"$f" >>"$LOGS" || {
      echo "${0##*/}: could not read $f" >&2
      exit 2
    }
    found=$((found + 1))
  done
done <<EOF
$dirs
EOF

if [ "$found" -eq 0 ]; then
  echo "${0##*/}: no .jsonl log found in the given directories" >&2
  exit 2
fi

ROWS=$WORK/rows.tsv
jq -rs --arg since "$since" --arg until "$until_" "$AGGREGATE" "$LOGS" >"$ROWS" || {
  echo "${0##*/}: the aggregation failed" >&2
  exit 2
}

awk -F'\t' '
  function m(x) { return sprintf("%.2f", x / 1000000) }
  /^R/ { if (!r++) printf "%-20s %8s %12s %7s %9s %14s %10s %9s\n", "role", "calls", "cost (M)", "share", "rewrites", "rewrite cost (M)", "cost ($)", "share ($)"
         printf "%-20s %8d %12s %6.1f%% %9d %14s %10.2f %8.1f%%\n", $2, $3, m($4), $5, $6, m($7), $8, $9 }
  /^M/ { if (!k++) printf "\n%-24s %8s %12s %10s %9s\n", "model", "calls", "cost (M)", "cost ($)", "share ($)"
         if ($7 == "true") printf "%-24s %8d %12s %10.2f %8.1f%%\n", $2, $3, m($4), $5, $6
         else printf "%-24s %8d %12s %10s %9s\n", $2, $3, m($4), "-", "-" }
  /^P/ { if (!p++) printf "\n%-20s %12s %7s %10s\n", "PR", "cost (M)", "share", "cost ($)"
         printf "%-20s %12s %6.1f%% %10.2f\n", ($2 == "none" ? "none" : "#" $2), m($3), $4, $5 }
  /^O/ { printf "%-20s %12s %6.1f%% %10.2f\n", "(" $2 " other PRs)", m($3), $4, $5 }
  /^T/ { printf "\ntotal: %s M weighted over %d calls, %d distinct PRs, %d cache rewrites (%s M), %.2f $ priced\n", m($3), $2, $4, $5, m($6), $7 }
  /^U/ { printf "unpriced: %s (%d calls, %s M raw)\n", $2, $3, m($4) }
' "$ROWS"
