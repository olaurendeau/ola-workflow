#!/usr/bin/env bash
# shellcheck disable=SC2015
#   `A && ok || ko`: ok() only counts and prints, so ko() cannot run after a passing test.
# scripts/spike/gitlab-forge.sh measures a real GitLab, and the human runs it: there is no
# network test. What is proved here is what can be proved offline — the plan, the refusals,
# and that no token reaches an output or a command line. The fake curl, git and glab put on
# PATH record their calls: a --dry-run that touches one of them fails.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/scratch.sh
. "$ROOT/scripts/scratch.sh"
SCRIPT=$ROOT/scripts/spike/gitlab-forge.sh

failures=0
total=0
ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

ola_scratch gitlab-spike
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT

BOT=glpat-botsecret0123456789
HUMAN=glpat-humansecret0123456789

# The fakes. curl answers like a GitLab that knows nothing: it reads the config on stdin (as
# the script feeds it, so the token never is in argv), tells the two tokens apart, writes a
# body where -o says and prints the status code. MODE=down makes it fail as a dead network.
FAKES=$WORK/bin
CALLS=$WORK/calls
CFGS=$WORK/cfgs
GLAB_ENV=$WORK/glab-env
GITENV=$WORK/git-env
: >"$GITENV"
export GITENV
COMMITS=$WORK/commits
export COMMITS
unset GIT_TERMINAL_PROMPT # the fetch is proved to set it itself
mkdir -p "$FAKES"
cat >"$FAKES/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$CALLS"
cfg=$(cat)
# what the script asked for, without the token line: the test reads the encoding from it
[ -z "${CFGS:-}" ] || { printf '%s\n' "$cfg" | grep -v '^header' >>"$CFGS"; echo "--" >>"$CFGS"; }
# a dead network, whose message happens to repeat the token: the script must not print it
[ "${MODE:-}" != down ] || { echo "curl: (7) Failed to connect to gitlab.com port 443 ${PAD:-}(token $FAKE_BOT)" >&2; exit 7; }
out=""
prev=""
for a in "$@"; do
  [ "$prev" = -o ] && out=$a
  prev=$a
done
user=human
case $cfg in *"$FAKE_BOT"*) user=bot ;; esac
url=$(printf '%s\n' "$cfg" | sed -n 's/^url = "\(.*\)"$/\1/p')
case $url in
  # a SHA that has no pipeline, ever (FAKE_NOPIPE=1)
  */pipelines\?sha=*) body=$([ "${FAKE_NOPIPE:-}" = 1 ] && echo '[]' || echo '[{"id":9,"source":"push","status":"pending"}]') ;;
  */api/v4/user) body="{\"id\":$([ $user = bot ] && echo 2 || echo 1),\"username\":\"$user\",\"bot\":$([ $user = bot ] && echo true || echo false)}" ;;
  # an empty project, as GitLab says it: a default branch that exists nowhere, and empty_repo
  */api/v4/projects/group%2Fthrowaway) body="{\"id\":7,\"default_branch\":\"main\",\"empty_repo\":${FAKE_EMPTY:-false}}" ;;
  *) body='{"id":7,"iid":3,"username":"x","default_branch":"main","sha":"0123456789abcdef0123456789abcdef01234567","message":"nope"}' ;;
esac
[ -z "$out" ] || printf '%s' "$body" >"$out"
printf 200
EOF
# git: a repository that accepts everything (the script then reaches M04 to M12), unless
# FAKE_GIT=down, where it answers nothing, FAKE_GIT=nocommit, where it clones but cannot commit,
# FAKE_GIT=onecommit, where only the first commit works, or FAKE_GIT=nopush, where nothing is pushed.
# It records the GIT_TERMINAL_PROMPT each call was given, in $GITENV.
cat >"$FAKES/git" <<'EOF'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$CALLS"
printf 'prompt=%s %s\n' "${GIT_TERMINAL_PROMPT-unset}" "$*" >>"$GITENV"
case "${FAKE_GIT:-up}" in
  up) ;;
  nocommit) case " $* " in *" commit "*) exit 1 ;; esac ;;
  nopush) case " $* " in *" push "*) exit 1 ;; esac ;;
  # onecommit: the first commit works (M04's), every later one fails
  onecommit) case " $* " in *" commit "*) echo x >>"$COMMITS"; [ "$(wc -l <"$COMMITS")" -le 1 ] || exit 1 ;; esac ;;
  *) exit 1 ;;
esac
for a in "$@"; do last=$a; done
case " $* " in
  *" clone "*) mkdir -p "$last/.git" ;;
  *" rev-parse "*) echo 0123456789abcdef0123456789abcdef01234567 ;;
esac
exit 0
EOF
# glab: a login writes its config where GLAB_CONFIG_DIR says (FAKE_GLAB=honours), or, like a glab
# too old to know the variable, under XDG_CONFIG_HOME or HOME (FAKE_GLAB=ignores). It records
# the HOME it was given. FAKE_GLAB=fails refuses the login. Everything else fails.
cat >"$FAKES/glab" <<'EOF'
#!/usr/bin/env bash
printf 'glab %s\n' "$*" >>"$CALLS"
printf 'glab %s HOME=%s XDG_CONFIG_HOME=%s\n' "$*" "$HOME" "${XDG_CONFIG_HOME:-}" >>"$GLAB_ENV"
cat >/dev/null </dev/stdin 2>/dev/null || true
case "$*" in
  *"auth login"*)
    [ "${FAKE_GLAB:-}" != fails ] || exit 1
    if [ "${FAKE_GLAB:-honours}" = honours ]; then dir=$GLAB_CONFIG_DIR; else dir=${XDG_CONFIG_HOME:-$HOME/.config}/glab-cli; fi
    mkdir -p "$dir" && echo "hosts:" >"$dir/config.yml"
    exit 0 ;;
esac
exit 1
EOF
chmod +x "$FAKES"/*
: >"$CALLS"

run() { # run [args...] → OUT (stdout and stderr together), STATUS; stdin is empty
  OUT=$(PATH="$FAKES:$PATH" CALLS="$CALLS" CFGS="$CFGS" GLAB_ENV="$GLAB_ENV" SPIKE_NAP=0 FAKE_BOT="$BOT" "$SCRIPT" "$@" 2>&1 </dev/null)
  STATUS=$?
}
no_secret() { # no_secret <label> → the tokens are in neither the output nor a recorded command line
  if printf '%s\n' "$OUT" | grep -qF -e "$BOT" -e "$HUMAN" || grep -qF -e "$BOT" -e "$HUMAN" "$CALLS"; then
    ko "$1: a token reached the output or a command line"
  else
    ok "$1: no token in the output nor in a command line"
  fi
}

[ -x "$SCRIPT" ] && ok "the script exists and is executable" || ko "the script is missing or not executable"

# --- refusals ---------------------------------------------------------------------------
run
[ "$STATUS" = 2 ] && printf '%s' "$OUT" | grep -q -e '--project' && ok "no project: exit 2 and it names --project" || ko "no project exited $STATUS: $OUT"

run --bogus
[ "$STATUS" = 2 ] && ok "an unknown option exits 2" || ko "an unknown option exited $STATUS"

run --project 'a/b c'
[ "$STATUS" = 2 ] && ok "a project path with a space exits 2" || ko "a bad project path exited $STATUS"

run --host 'evil.example/x' --project a/b
[ "$STATUS" = 2 ] && ok "a host with a slash exits 2" || ko "a bad host exited $STATUS"

run --project a/b
[ "$STATUS" = 2 ] && printf '%s' "$OUT" | grep -q SPIKE_BOT_TOKEN && ok "no token: exit 2 and it names the variable" || ko "no token exited $STATUS: $OUT"

SPIKE_BOT_TOKEN='bad token;x' SPIKE_HUMAN_TOKEN=$HUMAN run --project a/b
[ "$STATUS" = 2 ] && ! printf '%s' "$OUT" | grep -qF 'bad token' && ok "a token with odd characters exits 2 without being printed" || ko "an odd token exited $STATUS: $OUT"

export SPIKE_BOT_TOKEN=$BOT SPIKE_HUMAN_TOKEN=$HUMAN
: >"$CALLS"
run --project group/sub/throwaway
if [ "$STATUS" = 2 ] && printf '%s' "$OUT" | grep -q 'gitlab.com' && printf '%s' "$OUT" | grep -q 'group/sub/throwaway' && [ ! -s "$CALLS" ]; then
  ok "without --yes and no answer it names host and project, touches nothing and exits 2"
else
  ko "unconfirmed run: status $STATUS, calls: $(cat "$CALLS"), output: $OUT"
fi
no_secret "unconfirmed run"

# --- --dry-run: offline -----------------------------------------------------------------
unset SPIKE_BOT_TOKEN SPIKE_HUMAN_TOKEN
: >"$CALLS"
run --dry-run
n=$(printf '%s\n' "$OUT" | grep -cE '^M(0[1-9]|1[0-4]) ')
[ "$STATUS" = 0 ] && [ "$n" = 14 ] && ok "--dry-run needs no token nor project and prints M01 to M14" || ko "--dry-run exited $STATUS with $n measure lines: $OUT"
[ ! -s "$CALLS" ] && ok "--dry-run calls neither curl, git nor glab" || ko "--dry-run called: $(cat "$CALLS")"

run --dry-run --project group/throwaway
printf '%s' "$OUT" | grep -q 'gitlab.com' && printf '%s' "$OUT" | grep -q 'group/throwaway' && ok "--dry-run says which host and project it would touch" || ko "no host or project in the plan: $OUT"

run --dry-run --host gitlab.example.com --project group/throwaway
printf '%s' "$OUT" | grep -qi 'self-managed is not measured' && ok "another host is announced as not measured" || ko "no self-managed notice: $OUT"

SPIKE_BOT_TOKEN=$BOT SPIKE_HUMAN_TOKEN=$HUMAN run --dry-run --project group/throwaway
no_secret "--dry-run"

# --- a run against the fake -------------------------------------------------------------
export SPIKE_BOT_TOKEN=$BOT SPIKE_HUMAN_TOKEN=$HUMAN
: >"$CALLS"
MODE=down run --yes --project group/throwaway
[ "$STATUS" = 1 ] && printf '%s' "$OUT" | grep -q '^M01 ' && ok "a GitLab that does not answer stops the run at M01, exit 1" || ko "dead network: status $STATUS: $OUT"
no_secret "dead network"
# the transport error is shown, with no token in it
printf '%s' "$OUT" | grep -q 'Failed to connect' && ok "a transport failure shows what curl said" || ko "HTTP 000 without curl's message: $OUT"
printf '%s' "$OUT" | grep -qF '***' && ok "…with the token in curl's message masked" || ko "the token in curl's message was not masked: $OUT"
PAD=$(printf '%090d' 0) MODE=down run --yes --project group/throwaway
printf '%s' "$OUT" | grep -q 'Failed to connect' && ! printf '%s' "$OUT" | grep -qF 'glp' && ok "a token across column 160 of curl's message is masked, not cut" || ko "a start of the token shows on the cut: $OUT"
SPIKE_NAP=soon PATH="$FAKES:$PATH" "$SCRIPT" --yes --project group/throwaway >/dev/null 2>&1 </dev/null
STATUS=$?
[ "$STATUS" = 2 ] && ok "a SPIKE_NAP that is not whole seconds exits 2" || ko "SPIKE_NAP=soon exited $STATUS"

: >"$CALLS"
run --yes --project group/throwaway
n=$(printf '%s\n' "$OUT" | grep -cE '^M(0[1-9]|1[0-4]) ')
missing=""
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do
  printf '%s\n' "$OUT" | grep -q "^M$i " || missing="$missing M$i"
done
[ -z "$missing" ] && ok "a run that gets weak answers still prints a line for every measure" || ko "no line for:$missing"
[ "$STATUS" = 0 ] && ok "the run ends with exit 0 when every measure was reported" || ko "run exited $STATUS: $OUT"
printf '%s' "$OUT" | grep -q '^Cleanup' && ok "the run says what it cleaned up" || ko "no Cleanup line"
no_secret "full run"
# M04: the label colour reaches curl as '#428BCA', which --data-urlencode turns into %23428BCA;
# '%23428BCA' on the config line would become %2523428BCA on the wire, and a 400
grep -qF 'data-urlencode = "color=#428BCA"' "$CFGS" && ok "the label colour is sent as #428BCA, encoded once by curl" || ko "no color=#428BCA in what curl was given: $(grep color "$CFGS")"
! grep -qF 'color=%23' "$CFGS" && ok "the label colour is not encoded by hand" || ko "color=%23… is given to curl, which would encode the % again"
# M11: a failed status posted last, the project setting put on then back, M12 tries the default branch.
# $CFGS holds blocks cut by "--": the last status posted must be the failed one; M12 must create a
# pipeline on the default branch (the fake's "main") and try its manual job.
awk -v RS='--\n' '/\/statuses\// { last = $0 } END { exit !(last ~ /state=failed/ && last ~ /name=agent-review-m11/) }' "$CFGS" && ok "M11's failed status is the last one posted" || ko "the last status posted is not agent-review-m11 failed"
awk -v RS='--\n' '/\/pipeline"/ && /ref=main"/ { f = 1 } END { exit !f }' "$CFGS" && printf '%s\n' "$OUT" | grep -q '^M12 bot: play the manual job on the protected branch' && ok "M12 tries the default branch" || ko "M12 never created a pipeline on main nor played its manual job"
printf '%s\n' "$OUT" | grep -q '^M11 bot: POST a last failed status' && ok "M11 posts a last failed status itself" || ko "no M11 line for the last failed status"
printf '%s\n' "$OUT" | grep -q "^M11 the same MR with 'Pipelines must succeed' on" && ok "M11 reads the MR with the setting on" || ko "no M11 line with the setting on"
grep -qF 'data-urlencode = "only_allow_merge_if_pipeline_succeeds=true"' "$CFGS" && ok "M11 turns 'Pipelines must succeed' on" || ko "M11 never sets only_allow_merge_if_pipeline_succeeds"
first=$(grep -n 'only_allow_merge_if_pipeline_succeeds=true' "$CFGS" | head -n 1 | cut -d: -f1)
last=$(grep -n 'only_allow_merge_if_pipeline_succeeds=' "$CFGS" | tail -n 1 | cut -d: -f1)
[ -n "$first" ] && [ "$last" -gt "$first" ] && grep 'only_allow_merge_if_pipeline_succeeds=' "$CFGS" | tail -n 1 | grep -q 'only_allow_merge_if_pipeline_succeeds=false' && ok "…and puts it back as found" || ko "the setting is not put back"
printf '%s\n' "$OUT" | grep -q '^M10 the login landed in the scratch GLAB_CONFIG_DIR → yes' && ok "M10 checks that the login landed in the scratch config" || ko "no M10 check of the config location"
grep -q '^curl ' "$CALLS" && ! grep -E '^curl ' "$CALLS" | grep -qiE 'private-token|authorization' && ok "curl is given no header on its command line" || ko "a curl call carries a header in argv"
[ "$n" -ge 14 ] || ko "fewer than 14 measure lines ($n)"
# a fetch, like a push, must never wait for a password nobody will type
grep -q ' fetch ' "$GITENV" && ! grep ' fetch ' "$GITENV" | grep -qv '^prompt=0 ' && ok "every git fetch runs with GIT_TERMINAL_PROMPT=0" || ko "a git fetch may prompt: $(grep ' fetch ' "$GITENV" | grep -v '^prompt=0 ' | head -n 1)"
# a project that is not empty gets no first commit
! grep -q 'ola-spike init' "$CALLS" && ok "a project with a repository gets no first commit" || ko "a first commit was made on a project that is not empty"

# --- an empty project: GitLab still says default_branch main, and says empty_repo true
: >"$CALLS"
FAKE_EMPTY=true run --yes --project group/throwaway
grep -q 'commit -q -m ola-spike init' "$CALLS" && grep -q 'push -q origin main' "$CALLS" && ok "an empty project (empty_repo true, default_branch main) gets its first commit on main" || ko "no first commit on an empty project: $(grep '^git' "$CALLS" | head -n 5)"
printf '%s\n' "$OUT" | grep -q '^Pre first commit of an empty project → pushed to main' && ok "…and the run says so" || ko "no 'first commit' line: $(printf '%s\n' "$OUT" | grep '^Pre')"
no_secret "empty project"

# --- M07 when the branch cannot be made: not measurable, and the run goes on
: >"$CALLS"
FAKE_GIT=nocommit run --yes --project group/throwaway
missing=""
for i in 07 08 09 10 11 12 13 14; do
  printf '%s\n' "$OUT" | grep -q "^M$i " || missing="$missing M$i"
done
printf '%s\n' "$OUT" | grep -q '^M07 .*not measurable' && [ -z "$missing" ] && [ "$STATUS" = 0 ] && ok "M07 says not measurable when its branch cannot be made, and M08 to M14 still run" || ko "no branch: status $STATUS, missing:$missing, $(printf '%s\n' "$OUT" | grep -E 'M07|unbound' | head -n 3)"
! printf '%s\n' "$OUT" | grep -q 'unbound variable' && ok "…with no unbound variable" || ko "an unbound variable: $(printf '%s\n' "$OUT" | grep 'unbound')"

# --- M07 when the branch cannot be made, the message says so (and not another reason), even
# when an earlier branch was made: LAST_SHA is the previous one's unless mkbranch clears it
: >"$CALLS"
: >"$COMMITS"
FAKE_GIT=onecommit run --yes --project group/throwaway
printf '%s\n' "$OUT" | grep -qx 'M07 a CI job named agent-review → not measurable: the branch could not be made' && ok "M07 names the branch, not the CI, when it cannot be made after an earlier branch was" || ko "M07 line: $(printf '%s\n' "$OUT" | grep '^M07' | head -n 3)"
! printf '%s\n' "$OUT" | grep -q '^M07 push a branch' && ok "…and pushes nothing for it" || ko "M07 pushed on a stale SHA"

# --- M07 when the push fails: it says so at once, it does not wait for a pipeline
: >"$CALLS"
FAKE_GIT=nopush run --yes --project group/throwaway
printf '%s\n' "$OUT" | grep -qx 'M07 the pipeline of that push → not measurable: the push failed, so no pipeline can come of it' && ok "M07 blames the push, not CI, when the push fails" || ko "M07 lines: $(printf '%s\n' "$OUT" | grep '^M07' | head -n 3)"
! printf '%s\n' "$OUT" | grep -q '^M07 jobs of the pipeline' && ok "…and looks at no jobs" || ko "M07 went on after a failed push"

# --- M07 waits NAP seconds between two looks, never a fixed 5 (a fake sleep records the delays)
SLEEPS=$WORK/sleeps
mkdir -p "$WORK/sleepbin"
cat >"$WORK/sleepbin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SLEEPS"
EOF
chmod +x "$WORK/sleepbin/sleep"
: >"$SLEEPS"
: >"$CALLS"
OUT=$(SLEEPS="$SLEEPS" FAKE_NOPIPE=1 PATH="$WORK/sleepbin:$FAKES:$PATH" CALLS="$CALLS" CFGS="$CFGS" GLAB_ENV="$GLAB_ENV" SPIKE_NAP=0 FAKE_BOT="$BOT" "$SCRIPT" --yes --project group/throwaway 2>&1 </dev/null)
printf '%s\n' "$OUT" | grep -q '^M07 the pipeline of that push → not measurable: none within' && [ -s "$SLEEPS" ] && ! grep -qvx 0 "$SLEEPS" && ok "M07 sleeps SPIKE_NAP between two looks for a pipeline, nothing else" || ko "M07 sleeps: $(sort "$SLEEPS" | uniq -c | tr '\n' ' ')"

# --- the plan: lines that fit a terminal, and nothing lost where they are cut
run --dry-run
long=$(printf '%s\n' "$OUT" | awk 'length($0) > 100' | head -n 1)
[ -z "$long" ] && ok "--dry-run prints no line longer than 100 columns, so no terminal cuts one" || ko "a plan line is longer than 100 columns: $long"
unwrapped=$(printf '%s\n' "$OUT" | awk '/^ +/ { sub(/^ +/, ""); line = line " " $0; next } { if (line != "") print line; line = $0 } END { print line }')
for phrase in 'remove an MR label, note' 'success then failed, author recorded' 'which query gives the latest by name' 'merge blocked with and without'; do
  printf '%s\n' "$unwrapped" | grep -qF "$phrase" && ok "--dry-run, once the cut lines are joined, still says '$phrase'" || ko "the plan lost a space where it is cut: '$phrase' not found"
done
n=$(printf '%s\n' "$OUT" | grep -cE '^M(0[1-9]|1[0-4]) ')
[ "$n" = 14 ] && ok "…and each measure still starts its own line" || ko "$n lines start with a measure number in the plan"

# --- SPIKE_NAP refused before anything is created: no scratch directory is left behind
LEFT=$WORK/left-tmp
mkdir -p "$LEFT"
TMPDIR=$LEFT SPIKE_NAP=soon PATH="$FAKES:$PATH" "$SCRIPT" --yes --project group/throwaway >/dev/null 2>&1 </dev/null
STATUS=$?
[ "$STATUS" = 2 ] && [ -z "$(ls "$LEFT")" ] && ok "a refused SPIKE_NAP leaves no ola-gitlab-spike directory in TMPDIR" || ko "status $STATUS, left in TMPDIR: $(ls "$LEFT")"

# --- no usable git: M04 to M12 say so, and the run still reports every measure
: >"$CALLS"
OUT=$(FAKE_GIT=down PATH="$FAKES:$PATH" CALLS="$CALLS" CFGS="$CFGS" GLAB_ENV="$GLAB_ENV" SPIKE_NAP=0 FAKE_BOT="$BOT" "$SCRIPT" --yes --project group/throwaway 2>&1 </dev/null)
STATUS=$?
missing=""
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do
  printf '%s\n' "$OUT" | grep -q "^M$i " || missing="$missing M$i"
done
[ "$STATUS" = 0 ] && [ -z "$missing" ] && ok "without git the run still prints a line for every measure" || ko "no git: status $STATUS, missing:$missing"

# --- a glab that ignores GLAB_CONFIG_DIR: the run stops, the human's configuration is not touched
REALHOME=$WORK/realhome
mkdir -p "$REALHOME"
: >"$GLAB_ENV"
OUT=$(HOME="$REALHOME" XDG_CONFIG_HOME="$REALHOME/.config" FAKE_GLAB=ignores PATH="$FAKES:$PATH" CALLS="$CALLS" CFGS="$CFGS" GLAB_ENV="$GLAB_ENV" SPIKE_NAP=0 FAKE_BOT="$BOT" "$SCRIPT" --yes --project group/throwaway 2>&1 </dev/null)
STATUS=$?
[ "$STATUS" = 1 ] && printf '%s\n' "$OUT" | grep -q '^M10 the login landed in the scratch GLAB_CONFIG_DIR → no file there' && ok "a glab that ignores GLAB_CONFIG_DIR stops the run at M10, exit 1" || ko "ignoring glab: status $STATUS: $(printf '%s\n' "$OUT" | grep '^M10')"
! printf '%s\n' "$OUT" | grep -q '^M11 ' && ok "…and nothing after M10 was measured" || ko "the run went on after M10"
[ -z "$(find "$REALHOME" -type f)" ] && ok "…and the human's own HOME got no glab configuration" || ko "a file landed in the real HOME: $(find "$REALHOME" -type f)"
grep -q 'auth login' "$GLAB_ENV" && ! grep 'auth login' "$GLAB_ENV" | grep -qF "HOME=$REALHOME" && ok "the glab login ran with a scratch HOME" || ko "the glab login ran with the real HOME: $(cat "$GLAB_ENV")"
printf '%s\n' "$OUT" | grep -q '^Cleanup' && ok "…and the cleanup still ran" || ko "no Cleanup line after the stop"
no_secret "glab that ignores GLAB_CONFIG_DIR"

# --- a glab that refuses the login: that is the cause told, and the run goes on to M11 to M14
OUT=$(FAKE_GLAB=fails PATH="$FAKES:$PATH" CALLS="$CALLS" CFGS="$CFGS" GLAB_ENV="$GLAB_ENV" SPIKE_NAP=0 FAKE_BOT="$BOT" "$SCRIPT" --yes --project group/throwaway 2>&1 </dev/null)
STATUS=$?
[ "$STATUS" = 0 ] && printf '%s\n' "$OUT" | grep -q '^M10 glab → not measurable: glab could not log in (exit 1)' && ! printf '%s\n' "$OUT" | grep -q 'ignores GLAB_CONFIG_DIR' && ok "a refused glab login says so, not that GLAB_CONFIG_DIR is ignored" || ko "refused login: status $STATUS: $(printf '%s\n' "$OUT" | grep '^M10')"
printf '%s\n' "$OUT" | grep -q '^M14 ' && ok "…and M11 to M14 are still measured" || ko "the run stopped after a refused login"

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total gitlab-spike test(s) failed"
  exit 1
fi
echo "all $total gitlab-spike tests passed"
