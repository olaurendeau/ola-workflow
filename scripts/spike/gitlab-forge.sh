#!/usr/bin/env bash
# What does a real GitLab do, where the GitLab design of ola-workflow (epic #160, section 1)
# assumes it? Fourteen measures, M01 to M14, each printed as one line:
#
#     Mnn <what> → <observed>
#
# The whole output is pasted as the Evidence of the decision record
# (the draft docs/decisions/drafts/gitlab-identities-measured.md, once filled in). If a measure contradicts the model
# (assumptions A1, A2, A3 or A6 of the design), the epic stops for a revision.
#
# Run by the human, never by an agent. gitlab.com is the only host the epic measures: --host
# exists for a try-out, and a result on another host is not an Evidence.
#
# Needs a THROWAWAY project, because the script creates issues, branches, merge requests,
# tags and commit statuses in it and MERGES merge requests into its default branch: M08's on
# purpose, and on gitlab.com's shared runners the two scheduled merges of M09 and the one of
# M10 (glab mr merge) complete too, so up to four land there, with a .gitlab-ci.yml (two jobs,
# one manual) that M12 then uses on the default branch. It may also set the protection of that
# branch to "Maintainers", and for a minute requires a green pipeline to merge (M11), putting
# the setting back. It deletes what can be deleted; commit statuses, pipelines and the merged
# commits stay: delete the project afterwards.
#   - the human is Owner (or Maintainer) of the project;
#   - a second identity is a Developer member of it: a project access token's bot (Premium)
#     or a dedicated account; the script adds nobody;
#   - git can push to https://<host>/<project>.git with the human's own credentials, as the
#     agents do (a credential helper: git never prompts here);
#   - glab on PATH for M10 (optional: M10 then says "not measurable").
#
# Tokens come from the environment only, are checked for their characters, go to curl as a
# config on its standard input and to glab as an environment variable: never an argument, never
# printed. Enter them without echo and without history:
#   read -rs SPIKE_BOT_TOKEN; read -rs SPIKE_HUMAN_TOKEN; export SPIKE_BOT_TOKEN SPIKE_HUMAN_TOKEN
#   SPIKE_BOT_TOKEN   the Developer identity, scope api
#   SPIKE_HUMAN_TOKEN the human's personal access token, scope api
# (SPIKE_NAP, whole seconds between two looks at GitLab, is for the test: leave it alone.)
#
# Usage: scripts/spike/gitlab-forge.sh --dry-run [--host H] [--project P]
#        scripts/spike/gitlab-forge.sh --project <group/.../project> [--host gitlab.com] [--yes] | tee run.txt
# --dry-run prints the plan and touches nothing: no network, no git, no token read.
# Without --yes it names the host and the project and waits for the project path to be typed.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/scratch.sh
. "$REPO/scripts/scratch.sh"

HOST=gitlab.com
PROJECT=""
DRY=0
YES=0

usage() {
  sed -n '/^# Usage:/,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'
}
die() { echo "gitlab-forge.sh: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --host) [ $# -ge 2 ] || die "--host needs a value"; HOST=$2; shift 2 ;;
    --project) [ $# -ge 2 ] || die "--project needs a value"; PROJECT=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --yes) YES=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument" ;;
  esac
done

printf '%s' "$HOST" | grep -Eq '^[A-Za-z0-9.-]+(:[0-9]+)?$' || die "--host is not a plain host name"
[ -z "$PROJECT" ] || printf '%s' "$PROJECT" | grep -Eq '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+$' ||
  die "--project is not a group/project path"

plan() { # one line per measure: the same text the run prints in front of its observations
  cat <<'EOF'
M01 who each token is (GET /user, bot flag, same user or not) and the GitLab version (GET /version)
M02 project access tokens on this namespace and tier: create a Developer one, then revoke it; else the dedicated-account path
M03 granular personal access tokens: the fields of a PAT, POST /user/personal_access_tokens, and the UI by hand
M04 bot: issue, label, label RFR, MR (branch pushed with the human's git credentials), edit description, add and remove an MR label, note
M05 bot: POST a status success then failed, author recorded, author_id/user tricks, same state again, bot overwriting a human status and the reverse
M06 human: POST a status, author recorded; GET .../statuses with and without all=true and with two ref values: which query gives the latest by name
M07 a .gitlab-ci.yml job named agent-review in a pipeline the human's push triggered: in the commit statuses? author? what tells a job from an external status
M08 merge: bot PUT merge, auto_merge and merge_when_pipeline_succeeds refused; human wrong sha, then right sha with squash=true; squash message
M09 push options with the human's credentials: merge_request.merge_when_pipeline_succeeds and merge_request.auto_merge schedule a merge as the human
M10 glab: version, GITLAB_TOKEN over the stored login, empty GITLAB_TOKEN, GITLAB_HOST, which remote :id resolves to, mr merge default, api -f typing
M11 a status posted before any pipeline exists: separate pipeline? a failed external status posted last: pipeline red, merge blocked with and without "Pipelines must succeed" (set for a minute, then put back)
M12 bot: create a tag (unprotected and protected), create a pipeline, play a manual job on a branch and on the protected default branch
M13 expiry of the human PAT and of the bot token (GET /personal_access_tokens/self)
M14 the PAT creation page pre-filled (/-/user_settings/personal_access_tokens?name=…&scopes=…), by hand
EOF
}

banner() {
  echo "ola-workflow GitLab spike"
  echo "host:    $HOST"
  echo "project: ${PROJECT:-<not given>}"
  if [ "$HOST" != gitlab.com ]; then
    echo "note:    $HOST is not gitlab.com. Self-managed is not measured: nothing run here is an Evidence for the decision."
  fi
}

if [ "$DRY" = 1 ]; then
  banner
  echo "dry run: no network, no git, no token read. The run would measure:"
  plan
  exit 0
fi

[ -n "$PROJECT" ] || { usage >&2; die "--project is required (a throwaway project)"; }
for v in SPIKE_BOT_TOKEN SPIKE_HUMAN_TOKEN; do
  [ -n "${!v:-}" ] || die "$v is not set (tokens come from the environment only)"
  printf '%s' "${!v}" | grep -Eq '^[A-Za-z0-9_.=-]+$' || die "$v holds characters a token does not"
done
for tool in curl jq git; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

banner
echo "It will create and delete objects in that project, merge up to four merge requests into its"
echo "default branch (with a .gitlab-ci.yml), may set that branch's protection to Maintainers and"
echo "briefly require a green pipeline to merge."
if [ "$YES" = 0 ]; then
  printf 'Type the project path to go on: '
  read -r answer || answer=""
  [ "$answer" = "$PROJECT" ] || die "not confirmed, nothing was touched"
fi

ola_scratch gitlab-spike
WORK=$OLA_SCRATCH
BODY=$WORK/body
CLONE=$WORK/clone
CREATED=$WORK/created
: >"$CREATED"
RUN=$(date +%Y%m%d%H%M%S)
EXPIRES=$(date -u -v+1d +%F 2>/dev/null || date -u -d tomorrow +%F)
ENC=$(jq -rn --arg p "$PROJECT" '$p|@uri')
GITURL="https://$HOST/$PROJECT.git"
HTTP=000
NAP=${SPIKE_NAP:-3} # seconds between two looks at GitLab; for the test, which sets it to 0
case $NAP in '' | *[!0-9]*) die "SPIKE_NAP is for the test and takes whole seconds" ;; esac
PID=""
BASE=""

# --- plumbing ---------------------------------------------------------------------------

api() { # api <bot|human> <METHOD> <path> [key=value ...] → HTTP (code), BODY (the answer)
  local who=$1 method=$2 path=$3 tok kv
  shift 3
  if [ "$who" = bot ]; then tok=$SPIKE_BOT_TOKEN; else tok=$SPIKE_HUMAN_TOKEN; fi
  : >"$BODY"
  # printf is a builtin and curl reads its config on stdin: the token is in no argument list.
  HTTP=$(
    {
      printf 'url = "https://%s/api/v4%s"\n' "$HOST" "$path"
      printf 'request = "%s"\n' "$method"
      [ "$method" != GET ] || printf 'get\n'
      printf 'header = "PRIVATE-TOKEN: %s"\n' "$tok"
      for kv in "$@"; do
        printf 'data-urlencode = "%s"\n' "$(printf '%s' "$kv" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      done
    } | curl -sS -K - -o "$BODY" -w '%{http_code}' --max-time 60 2>"$WORK/curl.err"
  ) || HTTP=000
}
jb() { jq -r "$1" "$BODY" 2>/dev/null; }
transport() { # the last line curl said, without a token in it
  local l t
  l=$(tail -n 1 "$WORK/curl.err" 2>/dev/null)
  for t in "$SPIKE_BOT_TOKEN" "$SPIKE_HUMAN_TOKEN"; do
    [ -z "$t" ] || l=${l//"$t"/***} # mask first: a cut would leave the start of a token on the edge
  done
  l=$(printf '%s' "$l" | cut -c1-160)
  echo "${l:-curl said nothing}"
}
msg() { jq -r '(.message // .error // "no message") | tostring' "$BODY" 2>/dev/null | tr '\n' ' ' | cut -c1-140; }
h() { # the code, and the reason when it is not a 2xx
  case $HTTP in
    2??) echo "HTTP $HTTP" ;;
    000) echo "HTTP 000 (no answer: $(transport))" ;;
    *) echo "HTTP $HTTP $(msg)" ;;
  esac
}
m() { printf 'M%02d %s → %s\n' "$1" "$2" "$3"; }
pre() { printf 'Pre %s → %s\n' "$1" "$2"; }
res() { # res <n> <what> <got> <regex the expectation must match> <the expectation, in words>
  if printf '%s' "$3" | grep -Eq "$4"; then m "$1" "$2" "$3 — ok"; else m "$1" "$2" "$3 — differs: expected $5"; fi
}
rec() { printf '%s %s\n' "$1" "$2" >>"$CREATED"; }
manual() { # manual <n> <what> <what to look at> — asks, or leaves the line to fill in
  local ans=""
  if [ "$YES" = 0 ] && [ -t 0 ]; then
    printf '%s\nObserved (one line, empty to skip): ' "$3" >&2
    read -r ans || ans=""
  fi
  m "$1" "$2" "${ans:-manual: $3}"
}
statuses_line() { # one entry per status of the answer: name:status:author@ref#id
  jb '[.[]? | "\(.name):\(.status):\(.author.username // "?")@\(.ref // "?")#\(.id)"] | join(" | ")'
}
pipelines_of() { # pipelines_of <sha> → "n: id/source/status, …"
  api human GET "/projects/$PID/pipelines?sha=$1"
  jb '"\(length): " + ([.[]? | "\(.id)/\(.source // "?")/\(.status)"] | join(", "))'
}

# shellcheck disable=SC2329
#   called by the EXIT trap below
cleanup() {
  local kind arg ok=0 left=""
  [ -n "$PID" ] || { rm -rf "${WORK:?}"; return; }
  while read -r kind arg; do
    case $kind in
      mr)
        api human POST "/projects/$PID/merge_requests/$arg/cancel_merge_when_pipeline_succeeds"
        api human PUT "/projects/$PID/merge_requests/$arg" state_event=close
        ;;
      issue) api human DELETE "/projects/$PID/issues/$arg" ;;
      branch) api human DELETE "/projects/$PID/repository/branches/$arg" ;;
      tag) api human DELETE "/projects/$PID/repository/tags/$arg" ;;
      ptag) api human DELETE "/projects/$PID/protected_tags/$arg" ;;
      label) api human DELETE "/projects/$PID/labels/$arg" ;;
      pipesetting) api human PUT "/projects/$PID" "only_allow_merge_if_pipeline_succeeds=$arg" ;;
      pat) api human DELETE "/personal_access_tokens/$arg" ;;
      *) continue ;;
    esac
    # a merge request already merged cannot be closed: that is not a leftover
    case $HTTP in 2?? | 404) ok=$((ok + 1)) ;; *) left="$left $kind:$arg(HTTP $HTTP)" ;; esac
  done < <(awk '{ a[NR] = $0 } END { for (i = NR; i >= 1; i--) print a[i] }' "$CREATED")
  echo "Cleanup → $ok objects removed or gone; leftovers:${left:- none}. Commit statuses, pipelines and merged commits stay: delete the project."
  rm -rf "${WORK:?}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

G() { git -C "$CLONE" -c user.name=ola-spike -c user.email=ola-spike@invalid "$@"; }
mkbranch() { # mkbranch <name> <ci|plain> → a commit on a new branch of the base; LAST_SHA
  local br=$1 kind=$2
  PUSH_RC=1
  G fetch -q origin 2>/dev/null
  G checkout -q -b "$br" "origin/$BASE" || return 1
  printf 'ola-spike %s %s\n' "$RUN" "$br" >"$CLONE/spike-$br.txt"
  if [ "$kind" = ci ]; then
    printf 'agent-review:\n  script: ["true"]\nmanual-job:\n  when: manual\n  script: ["true"]\n' >"$CLONE/.gitlab-ci.yml"
  fi
  G add -A && G commit -q -m "ola-spike $RUN $br" || return 1
  LAST_SHA=$(G rev-parse HEAD)
}
pushb() { # pushb <branch> [git push options...] → pushed with the human's git credentials
  local br=$1
  shift
  GIT_TERMINAL_PROMPT=0 G push -q "$@" origin "$br" 2>"$WORK/git.err"
  PUSH_RC=$?
  [ "$PUSH_RC" != 0 ] || rec branch "$br"
}
push_result() { # the last push, in words
  if [ "${PUSH_RC:-1}" = 0 ]; then echo ok; else echo "git exit ${PUSH_RC:-?}: $(tail -n 1 "$WORK/git.err" 2>/dev/null | cut -c1-120)"; fi
}
open_mr() { # open_mr <branch> <title> → MR_IID, MR_SHA, opened by the bot
  api bot POST "/projects/$PID/merge_requests" "source_branch=$1" "target_branch=$BASE" "title=$2" "description=ola-spike $RUN"
  MR_IID=$(jb '.iid // empty')
  MR_SHA=$(jb '.sha // empty')
  [ -z "$MR_IID" ] || rec mr "$MR_IID"
}
wait_mergeable() { # wait_mergeable <iid> → up to 60 s for GitLab to finish checking
  local i=0 s=""
  while [ $i -lt 20 ]; do
    api human GET "/projects/$PID/merge_requests/$1"
    s=$(jb '.detailed_merge_status // .merge_status')
    case $s in checking | unchecked | preparing | ci_still_running) sleep 3 ;; *) break ;; esac
    i=$((i + 1))
  done
  echo "${s:-?}"
}

# --- the measures -----------------------------------------------------------------------

m01() {
  local hu hid bu bid
  api human GET /user
  [ "$HTTP" = 200 ] || { m 1 "human token: GET /user" "$(h) — not measurable, the run stops"; exit 1; }
  hu=$(jb .username); hid=$(jb .id)
  m 1 "human token is" "user $hu (id $hid), bot=$(jb '.bot // false')"
  api bot GET /user
  [ "$HTTP" = 200 ] || { m 1 "bot token: GET /user" "$(h) — not measurable, the run stops"; exit 1; }
  bu=$(jb .username); bid=$(jb .id)
  m 1 "bot token is" "user $bu (id $bid), bot=$(jb '.bot // false')"
  if [ "$bid" = "$hid" ]; then
    m 1 "the two identities" "differs: both tokens are the same user, the review identity cannot be told from the bot — the run stops"
    exit 1
  fi
  m 1 "the two identities" "different users — ok"
  HUM_U=$hu; HUM_ID=$hid; BOT_U=$bu; BOT_ID=$bid
  api human GET /version
  m 1 "GitLab version (GET /version)" "$(jb '"\(.version // "?") revision \(.revision // "?") enterprise=\(.enterprise // "?")"')"
}

pre_project() {
  local nsid levels
  api human GET "/projects/$ENC"
  [ "$HTTP" = 200 ] || { pre "project $PROJECT" "$(h) — the run stops"; exit 1; }
  PID=$(jb .id); BASE=$(jb '.default_branch // empty'); nsid=$(jb .namespace.id)
  pre "project" "id $PID, visibility $(jb .visibility), default branch ${BASE:-none (empty repository)}, merge_method $(jb .merge_method), squash_option $(jb .squash_option), only_allow_merge_if_pipeline_succeeds $(jb .only_allow_merge_if_pipeline_succeeds)"
  api human GET "/namespaces/$nsid"
  pre "namespace plan" "$(jb '.plan // "not shown"')"
  api human GET "/projects/$PID/members/all/$BOT_ID"
  pre "bot role in the project" "$(jb '.access_level // "not a member"') (30 is Developer)"
  api human GET "/projects/$PID/members/all/$HUM_ID"
  pre "human role in the project" "$(jb '.access_level // "not a member"') (40 Maintainer, 50 Owner)"
  # the repository: an empty project gets a first commit on main, from the human
  rm -rf "$CLONE"
  if GIT_TERMINAL_PROMPT=0 git clone -q "$GITURL" "$CLONE" 2>"$WORK/git.err"; then
    pre "git clone with the human's credentials" "ok"
    if [ -z "$BASE" ]; then
      G checkout -q -b main && printf 'ola-spike\n' >"$CLONE/README.md" && G add -A && G commit -q -m "ola-spike init" &&
        GIT_TERMINAL_PROMPT=0 G push -q origin main 2>"$WORK/git.err" && BASE=main
      pre "first commit of an empty project" "$([ -n "$BASE" ] && echo "pushed to main" || echo failed)"
    fi
  else
    pre "git clone with the human's credentials" "not measurable: the clone failed — M04 to M12 need it"
  fi
  GIT_OK=0
  if [ -d "$CLONE/.git" ] && [ -n "$BASE" ]; then GIT_OK=1; fi
  if [ -n "$BASE" ]; then
    api human GET "/projects/$PID/protected_branches/$BASE"
    levels=$([ "$HTTP" = 200 ] && jb '[.merge_access_levels[]?.access_level] | join(",")' || echo none)
    if [ "$levels" != 40 ]; then
      api human DELETE "/projects/$PID/protected_branches/$BASE"
      api human POST "/projects/$PID/protected_branches" "name=$BASE" push_access_level=40 merge_access_level=40
      pre "protection of $BASE" "merge levels were '$levels', set to Maintainers: $(h)"
    else
      pre "protection of $BASE" "merge levels $levels (Maintainers) as found"
    fi
  fi
}

m02() {
  local tid
  api human GET "/projects/$PID/access_tokens"
  m 2 "list project access tokens" "$(h)"
  api human POST "/projects/$PID/access_tokens" "name=ola-spike-$RUN" "scopes[]=api" access_level=30 "expires_at=$EXPIRES"
  tid=$(jb '.id // empty')
  case $HTTP in
    2??) m 2 "create a Developer project access token (revoked at once)" "HTTP $HTTP — available on this namespace: the bot can be a project access token" ;;
    *) m 2 "create a Developer project access token" "$(h) — not available: the one extra identity is a dedicated account" ;;
  esac
  [ -z "$tid" ] || { api human DELETE "/projects/$PID/access_tokens/$tid"; m 2 "revoke it" "$(h)"; }
}

m03() {
  local tid
  api human GET /personal_access_tokens/self
  m 3 "fields of a PAT as the API answers (human)" "$(jb 'keys | join(",")')"
  m 3 "a field about permissions or granularity in it" "$(jb '[paths | map(tostring) | join(".") | select(test("permission|granular"; "i"))] | unique | join(",") | if . == "" then "none" else . end')"
  api human POST /user/personal_access_tokens "name=ola-spike-m3-$RUN" "scopes[]=read_api" "expires_at=$EXPIRES"
  tid=$(jb '.id // empty')
  m 3 "POST /user/personal_access_tokens (read_api, one day)" "$(h); fields: $(jb 'keys | join(",")'); granular-looking: $(jb '[paths | map(tostring) | join(".") | select(test("permission|granular"; "i"))] | unique | join(",") | if . == "" then "none" else . end')"
  [ -z "$tid" ] || { api human DELETE "/personal_access_tokens/$tid"; m 3 "revoke it" "$(h)"; }
  manual 3 "granular PAT permissions in the UI on gitlab.com" "open https://$HOST/-/user_settings/personal_access_tokens, create a token: are per-resource permissions offered? could one deny commit statuses and allow MR creation?"
}

m04() {
  local iid
  api bot POST "/projects/$PID/issues" "title=ola-spike $RUN" "description=ola-spike"
  iid=$(jb '.iid // empty')
  [ -z "$iid" ] || rec issue "$iid"
  res 4 "bot: create issue" "$(h)" '^HTTP 2' "2xx"
  api bot POST "/projects/$PID/labels" name=RFR color=#428BCA
  [ "$HTTP" != 201 ] || rec label RFR
  m 4 "bot: create label RFR (409 means it existed)" "$(h)"
  api bot PUT "/projects/$PID/issues/${iid:-0}" labels=RFR
  res 4 "bot: label the issue" "$(h) labels=$(jb '.labels | join(",")')" '^HTTP 2' "2xx"
  [ "$GIT_OK" = 1 ] || { m 4 "bot: branch and merge request" "not measurable: no git clone"; return; }
  mkbranch "ola-spike-$RUN-a" plain && pushb "ola-spike-$RUN-a" -o ci.skip
  res 4 "human git credentials: push a branch" "$(push_result)" '^ok$' "a clean push"
  open_mr "ola-spike-$RUN-a" "ola-spike $RUN A"
  IA=$MR_IID; SHA_A=$MR_SHA
  res 4 "bot: open a merge request" "$(h)" '^HTTP 2' "2xx"
  api bot PUT "/projects/$PID/merge_requests/${IA:-0}" "description=edited by the bot"
  res 4 "bot: edit the MR description" "$(h)" '^HTTP 2' "2xx"
  api bot PUT "/projects/$PID/merge_requests/${IA:-0}" add_labels=RFR
  res 4 "bot: add the MR label RFR" "$(h) labels=$(jb '.labels | join(",")')" '^HTTP 2.*RFR' "2xx and RFR"
  api bot PUT "/projects/$PID/merge_requests/${IA:-0}" remove_labels=RFR
  res 4 "bot: remove the MR label RFR" "$(h) labels=$(jb '.labels | join(",")')" '^HTTP 2' "2xx"
  api bot POST "/projects/$PID/merge_requests/${IA:-0}/notes" "body=ola-spike note"
  res 4 "bot: note on the MR" "$(h)" '^HTTP 2' "2xx"
}

post_status() { # post_status <who> <sha> <state> <name> [key=value ...] → HTTP, BODY
  local who=$1 sha=$2 st=$3 nm=$4
  shift 4
  api "$who" POST "/projects/$PID/statuses/$sha" "state=$st" "name=$nm" "$@"
}
author() { jb '.author.username // "no author"'; }

m05() {
  local n=0 f
  [ -n "${SHA_A:-}" ] || { m 5 "bot: commit statuses" "not measurable: no merge request from M04"; return; }
  PL_BEFORE=$(pipelines_of "$SHA_A")
  post_status bot "$SHA_A" success agent-review-m05
  res 5 "bot: POST status success" "$(h) author $(author)" "author $BOT_U\$" "author $BOT_U"
  PL_AFTER=$(pipelines_of "$SHA_A")
  post_status bot "$SHA_A" failed agent-review-m05
  res 5 "bot: POST the same name failed" "$(h) status $(jb .status) author $(author)" "author $BOT_U\$" "author $BOT_U"
  PL_AFTER2=$(pipelines_of "$SHA_A")
  for f in "author_id=$HUM_ID" "user_id=$HUM_ID" "user=$HUM_U" "username=$HUM_U" "created_by=$HUM_U" "author[username]=$HUM_U"; do
    n=$((n + 1))
    post_status bot "$SHA_A" success "agent-review-m05-trick$n" "$f"
    res 5 "bot: POST a status with ${f%%=*} set to the human (ignored or refused)" "$(h) author $(author)" "(^HTTP 4|author $BOT_U\$)" "a refusal or author $BOT_U"
  done
  post_status bot "$SHA_A" success agent-review-m05
  m 5 "bot: re-post an already posted state (success on a failed one, then success again)" "$(h) status $(jb .status) author $(author)"
  post_status bot "$SHA_A" success agent-review-m05
  m 5 "bot: re-post the same state a second time" "$(h) status $(jb .status) author $(author)"
  post_status human "$SHA_A" failed agent-review-m05-h
  post_status bot "$SHA_A" success agent-review-m05-h
  res 5 "bot posts success after the human's failed, same name: the author" "$(h) status $(jb .status) author $(author)" "author $BOT_U\$|^HTTP 4" "author $BOT_U or a refusal (never the human's name on the bot's state)"
  post_status bot "$SHA_A" failed agent-review-m05-b
  post_status human "$SHA_A" success agent-review-m05-b
  m 5 "human posts success after the bot's failed, same name" "$(h) status $(jb .status) author $(author)"
}

latest_by_name() { # the default query, then the all=true one, for one name → what each answers
  local q
  for q in "" "all=true" "ref=$1" "ref=$2" "all=true&ref=$1"; do
    api human GET "/projects/$PID/repository/commits/$SHA_A/statuses?name=agent-review-m06${q:+&$q}"
    m 6 "GET .../statuses?name=agent-review-m06${q:+&$q}" "$(h); $(jb 'length') entries: $(statuses_line)"
  done
  api human GET "/projects/$PID/repository/commits/$SHA_A/statuses?name=agent-review-m06&all=true"
  m 6 "the latest by id among all=true" "$(jb '[.[]?] | sort_by(.id) | last | "\(.name):\(.status):\(.author.username // "?")@\(.ref // "?")#\(.id)"')"
}
m06() {
  [ -n "${SHA_A:-}" ] || { m 6 "human: commit statuses" "not measurable: no merge request from M04"; return; }
  post_status human "$SHA_A" success agent-review-m06 "ref=ola-spike-$RUN-a"
  res 6 "human: POST status success (ref the branch)" "$(h) author $(author)" "author $HUM_U\$" "author $HUM_U"
  post_status human "$SHA_A" failed agent-review-m06 "ref=$BASE"
  m 6 "human: POST the same name with another ref and the state failed" "$(h) status $(jb .status) author $(author) pipeline $(jb '.pipeline_id // "?"')"
  post_status human "$SHA_A" success agent-review-m06 "ref=ola-spike-$RUN-a"
  m 6 "human: POST the same name again with the first ref" "$(h) status $(jb .status) pipeline $(jb '.pipeline_id // "?"')"
  latest_by_name "ola-spike-$RUN-a" "$BASE"
}

m07() {
  local sha pl id i=0 ids line
  [ "$GIT_OK" = 1 ] || { m 7 "a CI job named agent-review" "not measurable: no git clone"; return; }
  mkbranch "ola-spike-$RUN-ci" ci && pushb "ola-spike-$RUN-ci"
  sha=$LAST_SHA
  m 7 "push a branch with a .gitlab-ci.yml job named agent-review, as the human" "$(push_result)"
  while [ $i -lt 12 ]; do
    api human GET "/projects/$PID/pipelines?sha=$sha"
    [ "$(jb 'length')" != 0 ] && break
    sleep 5
    i=$((i + 1))
  done
  pl=$(jb '.[0].id // empty')
  [ -n "$pl" ] || { m 7 "the pipeline of that push" "not measurable: none within 60 s (CI disabled, no runner, or the account not verified)"; return; }
  m 7 "the pipeline of that push" "$(pipelines_of "$sha")"
  api human GET "/projects/$PID/pipelines/$pl/jobs"
  m 7 "jobs of the pipeline (GET /pipelines/:id/jobs)" "$(jb '[.[]? | "\(.name):\(.status)"] | join(", ")')"
  post_status bot "$sha" success agent-review
  m 7 "bot: POST an external status named agent-review on the same SHA" "$(h) author $(author) pipeline $(jb '.pipeline_id // "?"')"
  m 7 "pipelines of that SHA now" "$(pipelines_of "$sha")"
  api human GET "/projects/$PID/repository/commits/$sha/statuses?name=agent-review&all=true"
  m 7 "commit statuses named agent-review (all=true)" "$(jb 'length') entries: $(statuses_line)"
  cp "$BODY" "$WORK/st.json"
  ids=$(jq -r '.[]?.id' "$WORK/st.json" 2>/dev/null)
  for id in $ids; do
    line=$(jq -r --argjson i "$id" '.[]? | select(.id == $i) | "author \(.author.username // "?") pipeline \(.pipeline_id // "?") allow_failure \(.allow_failure // "?") keys " + (keys | join(","))' "$WORK/st.json" 2>/dev/null)
    api human GET "/projects/$PID/jobs/$id"
    m 7 "status #$id: $line" "GET /projects/:id/jobs/$id → HTTP $HTTP (200 is a CI job, 404 an external status)"
  done
}

m08() {
  local im sha st
  [ "$GIT_OK" = 1 ] || { m 8 "merge" "not measurable: no git clone"; return; }
  # a ci branch: once merged, the default branch carries manual-job, which M12 plays as the bot
  mkbranch "ola-spike-$RUN-m" ci && pushb "ola-spike-$RUN-m" -o ci.skip
  open_mr "ola-spike-$RUN-m" "ola-spike $RUN M"
  im=$MR_IID; sha=$MR_SHA
  [ -n "$im" ] || { m 8 "merge" "not measurable: the merge request was not opened"; return; }
  m 8 "merge request ready?" "$(wait_mergeable "$im")"
  api bot PUT "/projects/$PID/merge_requests/$im/merge" "sha=$sha"
  res 8 "bot: PUT merge (protected branch, Maintainers)" "$(h)" '^HTTP 40[13]' "401 or 403"
  api bot PUT "/projects/$PID/merge_requests/$im/merge" "sha=$sha" auto_merge=true
  res 8 "bot: PUT merge with auto_merge=true" "$(h)" '^HTTP 40[13]' "401 or 403"
  api bot PUT "/projects/$PID/merge_requests/$im/merge" "sha=$sha" merge_when_pipeline_succeeds=true
  res 8 "bot: PUT merge with merge_when_pipeline_succeeds=true" "$(h)" '^HTTP 40[13]' "401 or 403"
  api human GET "/projects/$PID/merge_requests/$im"
  res 8 "the MR after the bot's attempts" "state $(jb .state), scheduled $(jb '.merge_when_pipeline_succeeds // .auto_merge_enabled // false')" '^state opened, scheduled false' "opened and nothing scheduled"
  api human PUT "/projects/$PID/merge_requests/$im/merge" sha=0000000000000000000000000000000000000000
  res 8 "human: PUT merge with a wrong sha" "$(h)" '^HTTP 409' "409"
  api human PUT "/projects/$PID/merge_requests/$im/merge" "sha=$sha" squash=true
  st=$(jb '"state \(.state // "?")"')
  m 8 "human: PUT merge with the right sha and squash=true" "$(h) $st"
  sha=$(jb '.squash_commit_sha // empty')
  st=squash_commit_sha
  [ -n "$sha" ] || { sha=$(jb '.merge_commit_sha // empty'); st=merge_commit_sha; }
  if [ -n "$sha" ]; then
    api human GET "/projects/$PID/repository/commits/$sha"
    m 8 "the commit title ($st) against the MR title 'ola-spike $RUN M'" "'$(jb .title)' — $([ "$(jb .title)" = "ola-spike $RUN M" ] && echo equal || echo different)"
  else
    m 8 "the squash commit" "not measurable: the answer names no squash_commit_sha nor merge_commit_sha"
  fi
}

m09() {
  local br n=0 opt iid
  [ "$GIT_OK" = 1 ] || { m 9 "push options" "not measurable: no git clone"; return; }
  for opt in merge_request.merge_when_pipeline_succeeds merge_request.auto_merge; do
    n=$((n + 1))
    br=ola-spike-$RUN-p$n
    mkbranch "$br" ci || continue
    pushb "$br" -o merge_request.create -o "merge_request.target=$BASE" -o "merge_request.title=ola-spike $RUN P$n" -o "$opt"
    api human GET "/projects/$PID/merge_requests?source_branch=$br"
    iid=$(jb '.[0].iid // empty')
    if [ -z "$iid" ]; then
      m 9 "git push -o merge_request.create -o $opt" "no merge request created; push: $(push_result)"
      continue
    fi
    rec mr "$iid"
    res 9 "git push -o merge_request.create -o $opt (human's credentials)" "MR !$iid state $(jb '.[0].state'), scheduled $(jb '.[0].merge_when_pipeline_succeeds // .[0].auto_merge_enabled // false'), by $(jb '.[0].merge_user.username // "nobody"')" 'scheduled true' "a scheduled merge (the hole the design leaves open)"
  done
}

GLREPO=$WORK/glab-repo
gl() { # gl <token|-|empty> <dir> <glab args...> — the token goes by environment, a subshell keeps it there
  # stderr goes to a file, so a notice on it never reaches jq; GL_STDERR=merge puts it back in the output.
  # HOME and XDG_CONFIG_HOME are the scratch ones too: a glab that ignored GLAB_CONFIG_DIR would
  # write its login there, never into the human's own configuration.
  local tok=$1 dir=$2
  shift 2
  (
    export GLAB_CONFIG_DIR=$WORK/glab-config NO_PROMPT=1 HOME=$WORK/glab-home XDG_CONFIG_HOME=$WORK/glab-home/.config
    unset GITLAB_TOKEN GITLAB_HOST
    [ -z "$GL_HOST_ENV" ] || export GITLAB_HOST=$GL_HOST_ENV
    case $tok in
      empty) export GITLAB_TOKEN= ;;
      human) export GITLAB_TOKEN=$SPIKE_HUMAN_TOKEN ;;
      bot) export GITLAB_TOKEN=$SPIKE_BOT_TOKEN ;;
    esac
    cd "$dir" || exit 1
    if [ "${GL_STDERR:-}" = merge ]; then glab "$@" 2>&1; else glab "$@" 2>>"$WORK/glab.err"; fi
  )
}
who_glab() { gl "$1" "$2" api user | jq -r '.username // "no user"' 2>/dev/null || echo "no answer"; }

m10() {
  local im sq out rc
  if ! command -v glab >/dev/null; then m 10 "glab" "not measurable: glab is not on PATH"; return; fi
  m 10 "glab version" "$(glab --version 2>&1 | head -n 1)"
  mkdir -p "$WORK/glab-config" "$WORK/glab-home" "$WORK/norepo" "$GLREPO"
  git -C "$GLREPO" init -q 2>/dev/null
  git -C "$GLREPO" remote add origin "$GITURL"
  git -C "$GLREPO" remote add upstream "https://$HOST/${PROJECT}-ola-spike-absent.git"
  GL_HOST_ENV=""
  printf '%s' "$SPIKE_HUMAN_TOKEN" | gl - "$WORK/norepo" auth login --hostname "$HOST" --stdin >"$WORK/glab-login.out"
  rc=$?
  m 10 "glab auth login --stdin into a scratch config (the human's PAT)" "exit $rc"
  if [ "$rc" != 0 ]; then
    m 10 "glab" "not measurable: glab could not log in (exit $rc), so nothing else was asked of it"
    return
  fi
  if [ -z "$(find "$WORK/glab-config" -type f 2>/dev/null | head -n 1)" ]; then
    m 10 "the login landed in the scratch GLAB_CONFIG_DIR" "no file there: this glab ignores GLAB_CONFIG_DIR (scratch home: $(find "$WORK/glab-home" -type f 2>/dev/null | wc -l | tr -d ' ') file(s), the human's own configuration untouched) — the run stops"
    exit 1
  fi
  m 10 "the login landed in the scratch GLAB_CONFIG_DIR" "yes — ok"
  res 10 "no GITLAB_TOKEN: the stored login acts as" "$(who_glab - "$GLREPO")" "^$HUM_U\$" "$HUM_U"
  res 10 "GITLAB_TOKEN=<bot> over the stored login acts as" "$(who_glab bot "$GLREPO")" "^$BOT_U\$" "$BOT_U (the environment wins)"
  res 10 "GITLAB_TOKEN empty: falls back to the stored login, acts as" "$(who_glab empty "$GLREPO")" "^$HUM_U\$" "$HUM_U (an empty variable falls back)"
  GL_HOST_ENV=$HOST
  res 10 "GITLAB_HOST=$HOST outside any repository, GITLAB_TOKEN=<bot>, acts as" "$(who_glab bot "$WORK/norepo")" "^$BOT_U\$" "$BOT_U"
  GL_HOST_ENV=""
  out=$(gl human "$GLREPO" api 'projects/:id' | jq -r '.path_with_namespace // .message // "no answer"' 2>/dev/null)
  m 10 "glab api projects/:id with remotes upstream (absent project) and origin ($PROJECT)" "$out — $([ "$out" = "$PROJECT" ] && echo "origin was used" || echo "upstream was used, or glab could not tell")"
  [ "$GIT_OK" = 1 ] || { m 10 "glab mr merge and api -f" "not measurable: no git clone"; return; }
  mkbranch "ola-spike-$RUN-g" ci && pushb "ola-spike-$RUN-g"
  open_mr "ola-spike-$RUN-g" "ola-spike $RUN G"
  im=$MR_IID
  [ -n "$im" ] || { m 10 "glab mr merge and api -f" "not measurable: the merge request was not opened"; return; }
  gl human "$GLREPO" api -X PUT "projects/:id/merge_requests/$im" -f squash=true >/dev/null
  api human GET "/projects/$PID/merge_requests/$im"
  sq=$(jb .squash)
  m 10 "glab api -f squash=true (a string field) leaves the MR's squash at" "$sq (a JSON boolean in the answer: $([ "$sq" = true ] && echo coerced || echo not coerced))"
  gl human "$GLREPO" api -X PUT "projects/:id/merge_requests/$im" -F squash=false >/dev/null
  api human GET "/projects/$PID/merge_requests/$im"
  m 10 "glab api -F squash=false (a typed field) leaves it at" "$(jb .squash)"
  out=$(GL_STDERR=merge gl human "$GLREPO" mr merge "$im" --yes | head -n 3 | tr '\n' ' ' | cut -c1-200)
  api human GET "/projects/$PID/merge_requests/$im"
  m 10 "glab mr merge $im --yes (pipeline pending): the default is" "state $(jb .state), scheduled $(jb '.merge_when_pipeline_succeeds // .auto_merge_enabled // false'); glab said: $out"
}

mr_state() { # the MR A, as the human reads it
  api human GET "/projects/$PID/merge_requests/$IA"
  echo "head pipeline $(jb '.head_pipeline.status // "none"'), detailed_merge_status $(jb '.detailed_merge_status // "?"'), merge_status $(jb '.merge_status // "?"')"
}

m11() {
  local pl orig i=0 st
  [ -n "${SHA_A:-}" ] || { m 11 "statuses and pipelines" "not measurable: no merge request from M04"; return; }
  m 11 "pipelines of the SHA before any status" "$PL_BEFORE"
  m 11 "…after the bot's first status (success)" "$PL_AFTER"
  m 11 "…after the bot's failed status" "$PL_AFTER2"
  # M05 and M06 have posted success again on every name: a failed status has to come last,
  # on the pipeline the MR shows, and nothing may follow it.
  api human GET "/projects/$PID/merge_requests/$IA"
  pl=$(jb '.head_pipeline.id // empty')
  api human GET "/projects/$PID"
  orig=$(jb '.only_allow_merge_if_pipeline_succeeds // false')
  post_status bot "$SHA_A" failed agent-review-m11 ${pl:+"pipeline_id=$pl"}
  m 11 "bot: POST a last failed status (agent-review-m11) on the MR's head pipeline ${pl:-(none known yet)}" "$(h) pipeline $(jb '.pipeline_id // "?"')"
  while [ $i -lt 10 ]; do
    api human GET "/projects/$PID/merge_requests/$IA"
    st=$(jb '.head_pipeline.status // "none"')
    [ "$st" != failed ] || break
    sleep "$NAP"
    i=$((i + 1))
  done
  m 11 "the MR after that failed external status, 'Pipelines must succeed' = $orig (as found)" "$(wait_mergeable "$IA"); $(mr_state)"
  rec pipesetting "$orig"
  api human PUT "/projects/$PID" only_allow_merge_if_pipeline_succeeds=true
  m 11 "human: require a green pipeline to merge (put back right after)" "$(h) now $(jb .only_allow_merge_if_pipeline_succeeds)"
  sleep "$NAP"
  m 11 "the same MR with 'Pipelines must succeed' on" "$(wait_mergeable "$IA"); $(mr_state)"
  api human PUT "/projects/$PID" "only_allow_merge_if_pipeline_succeeds=$orig"
  m 11 "human: put 'Pipelines must succeed' back to $orig" "$(h) now $(jb .only_allow_merge_if_pipeline_succeeds)"
}

play_in() { # play_in <label> <pipeline id> — the bot plays the manual job of that pipeline
  local job
  api bot GET "/projects/$PID/pipelines/$2/jobs"
  job=$(jb '[.[]? | select(.name == "manual-job")][0].id // empty')
  [ -n "$job" ] || { m 12 "bot: play the manual job $1" "not measurable: no manual-job in pipeline $2 ($(h))"; return; }
  api bot POST "/projects/$PID/jobs/$job/play"
  m 12 "bot: play the manual job $1" "$(h)"
}

m12() {
  local t=ola-spike-$RUN-t pl
  [ "$GIT_OK" = 1 ] || { m 12 "tags and pipelines" "not measurable: no git clone"; return; }
  api bot POST "/projects/$PID/repository/tags" "tag_name=$t-1" "ref=$BASE"
  [ "$HTTP" != 201 ] || rec tag "$t-1"
  m 12 "bot: create an unprotected tag" "$(h)"
  api human POST "/projects/$PID/protected_tags" "name=$t-prot-*" create_access_level=40
  [ "${HTTP#2}" = "$HTTP" ] || rec ptag "$(jq -rn --arg n "$t-prot-*" '$n|@uri')"
  m 12 "human: protect the tag pattern $t-prot-* (Maintainers)" "$(h)"
  api bot POST "/projects/$PID/repository/tags" "tag_name=$t-prot-1" "ref=$BASE"
  [ "$HTTP" != 201 ] || rec tag "$t-prot-1"
  res 12 "bot: create a protected tag" "$(h)" '^HTTP 40[13]' "401 or 403"
  api bot POST "/projects/$PID/pipeline" "ref=ola-spike-$RUN-ci"
  m 12 "bot: create a pipeline on the CI branch" "$(h)"
  api bot GET "/projects/$PID/pipelines?ref=ola-spike-$RUN-ci"
  pl=$(jb '.[0].id // empty')
  if [ -n "$pl" ]; then play_in "of an unprotected branch" "$pl"; else m 12 "bot: play the manual job of an unprotected branch" "not measurable: no pipeline on the CI branch"; fi
  # M08 merged a branch with a .gitlab-ci.yml into the default branch: it holds manual-job now
  api bot POST "/projects/$PID/pipeline" "ref=$BASE"
  m 12 "bot: create a pipeline on the protected branch" "$(h)"
  pl=""
  case $HTTP in 2??) pl=$(jb '.id // empty') ;; esac
  if [ -z "$pl" ]; then
    api human GET "/projects/$PID/pipelines?ref=$BASE"
    pl=$(jb '.[0].id // empty')
  fi
  if [ -n "$pl" ]; then play_in "on the protected branch $BASE (pipeline $pl)" "$pl"; else m 12 "bot: play the manual job on the protected branch" "not measurable: no pipeline on $BASE (was the merge of M08 refused, or CI off?)"; fi
}

m13() {
  local w
  for w in human bot; do
    api "$w" GET /personal_access_tokens/self
    m 13 "$w token: GET /personal_access_tokens/self" "$(h) expires_at $(jb '.expires_at // "never"'), scopes $(jb '.scopes // [] | join(",")'), active $(jb '.active // "?"')"
  done
}

m14() {
  manual 14 "the PAT creation page pre-filled" "open https://$HOST/-/user_settings/personal_access_tokens?name=ola-workflow-review&description=ola-workflow&scopes=api : are the name, the description and the scope pre-filled?"
}

echo
echo "run $RUN — $(date -u +%FT%TZ)"
GIT_OK=0
HUM_U=""; HUM_ID=""; BOT_U=""; BOT_ID=""
m01
pre_project
m02
m03
m04
m05
m06
m07
m08
m09
m10
m11
m12
m13
m14
exit 0
