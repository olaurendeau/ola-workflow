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
  def tool_results: [.message.content | arrays | .[] | select(type == "object" and .type == "tool_result") | .content | result_text] | join("\n");

  [ inputs | fromjson? | select(type == "object") | . as $r
    | if $r.type == "assistant" and ($r.message.usage | type) == "object"
         and $r.message.model != "<synthetic>" and $r.isApiErrorMessage != true then
        $r.message.usage as $u
        | {k: "a", id: $r.requestId, ts: ($r.timestamp // ""),
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
      | .out += [{id: $c.id, ts: $c.ts, o: $c.o,
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
  | . as $calls
  | (map(.cost) | add // 0) as $total
  | def share($x): if $total > 0 then $x * 100 / $total else 0 end;
    def sum: map(.cost) | add // 0;
    ( $calls | group_by(.role)
      | map({role: .[0].role, n: length, cost: sum,
             rw: (map(select(.rw)) | length), rwcost: (map(select(.rw)) | sum)})
      | sort_by(-.cost) | .[]
      | ["R", .role, .n, .cost, share(.cost), .rw, .rwcost] ),
    ( $calls | group_by(.pr) | map({pr: .[0].pr, cost: sum}) | sort_by(-.cost)
      | .[:15][] | ["P", .pr, .cost, share(.cost)] ),
    ( $calls | group_by(.pr) | map({pr: .[0].pr, cost: sum}) | sort_by(-.cost)
      | .[15:] | select(length > 0) | ["O", length, (map(.cost) | add), share(map(.cost) | add)] ),
    ["T", ($calls | length), $total, ([$calls[] | select(.pr != "none") | .pr] | unique | length),
     (($calls | map(select(.rw)) | length)), ($calls | map(select(.rw)) | sum)]
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
    jq -cnR --arg role "$role" --arg file "${f%/}" --argjson main "$main" "$PER_LOG" <"$f" >>"$LOGS" || {
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
  /^R/ { if (!r++) printf "%-20s %8s %12s %7s %9s %14s\n", "role", "calls", "cost (M)", "share", "rewrites", "rewrite cost (M)"
         printf "%-20s %8d %12s %6.1f%% %9d %14s\n", $2, $3, m($4), $5, $6, m($7) }
  /^P/ { if (!p++) printf "\n%-20s %12s %7s\n", "PR", "cost (M)", "share"
         printf "%-20s %12s %6.1f%%\n", ($2 == "none" ? "none" : "#" $2), m($3), $4 }
  /^O/ { printf "%-20s %12s %6.1f%%\n", "(" $2 " other PRs)", m($3), $4 }
  /^T/ { printf "\ntotal: %s M weighted over %d calls, %d distinct PRs, %d cache rewrites (%s M)\n", m($3), $2, $4, $5, m($6) }
' "$ROWS"
