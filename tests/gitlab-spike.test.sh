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
mkdir -p "$FAKES"
cat >"$FAKES/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$CALLS"
cfg=$(cat)
[ "${MODE:-}" != down ] || exit 7
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
  */api/v4/user) body="{\"id\":$([ $user = bot ] && echo 2 || echo 1),\"username\":\"$user\",\"bot\":$([ $user = bot ] && echo true || echo false)}" ;;
  *) body='{"id":7,"iid":3,"username":"x","default_branch":"main","sha":"0123456789abcdef0123456789abcdef01234567","message":"nope"}' ;;
esac
[ -z "$out" ] || printf '%s' "$body" >"$out"
printf 200
EOF
for tool in git glab; do
  cat >"$FAKES/$tool" <<EOF
#!/usr/bin/env bash
printf '$tool %s\n' "\$*" >>"\$CALLS"
exit 1
EOF
done
chmod +x "$FAKES"/*
: >"$CALLS"

run() { # run [args...] → OUT (stdout and stderr together), STATUS; stdin is empty
  OUT=$(PATH="$FAKES:$PATH" CALLS="$CALLS" FAKE_BOT="$BOT" "$SCRIPT" "$@" 2>&1 </dev/null)
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
grep -q '^curl ' "$CALLS" && ! grep -E '^curl ' "$CALLS" | grep -qiE 'private-token|authorization' && ok "curl is given no header on its command line" || ko "a curl call carries a header in argv"
[ "$n" -ge 14 ] || ko "fewer than 14 measure lines ($n)"

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total gitlab-spike test(s) failed"
  exit 1
fi
echo "all $total gitlab-spike tests passed"
