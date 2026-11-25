#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015
#   SC2016: several arguments below are shell metacharacters on purpose: `$(id)` has to reach
#   the script as text.
#   SC2015: `A && ok || ko`: ok() only counts and prints, so ko() cannot run after a passing
#   test.
# Runs bin/ola-workflow-capture against a fake browser, and bin/ola-workflow-pr-assets
# against a bare repository standing in for GitHub. No network, no real browser.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/scratch.sh
. "$ROOT/scripts/scratch.sh"

failures=0
total=0
ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

CAPTURE=$ROOT/bin/ola-workflow-capture
ASSETS=$ROOT/bin/ola-workflow-pr-assets

ola_scratch captures
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT
export HOME=$WORK/home
mkdir -p "$HOME"
# A commit and a clone need an identity whatever the host has configured.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# --- capture ----------------------------------------------------------------------------

# The fake browser logs its arguments, one per line, to $FAKE_LOG, and then acts as
# $FAKE_MODE says.
FAKE=$WORK/fake-chrome
cat >"$FAKE" <<'EOF'
#!/usr/bin/env bash
out=
for a in "$@"; do
  case $a in
    --screenshot=*) out=${a#--screenshot=} ;;
  esac
done
printf '%s\n' "$@" >"$FAKE_LOG"
case ${FAKE_MODE:-png} in
  png) printf '\211PNG\r\n\032\nfake' >"$out" ;;
  nowrite) ;;
  text) echo "not a png at all" >"$out" ;;
  fail) exit 3 ;;
  # A helper process of its own, as Chrome has: killing the browser's PID alone leaves it.
  hang) sleep 60 & echo $! >"$FAKE_CHILDPID"; echo $$ >"$FAKE_PIDFILE"; wait ;;
esac
EOF
chmod +x "$FAKE"

# cap <mode> <url> <out> → runs the script; sets rc and msg
cap() {
  local mode=$1
  shift
  rm -f "$WORK/fake.log"
  msg=$(FAKE_MODE=$mode FAKE_LOG=$WORK/fake.log FAKE_PIDFILE=$WORK/fake.pid \
    OLA_WORKFLOW_CHROME=$FAKE "$CAPTURE" "$@" 2>&1)
  rc=$?
}

is_png() { [ "$(head -c 8 "$1" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ]; }

OUT=$WORK/shot.png

cap png http://localhost:3002/ "$OUT"
[ "$rc" = 0 ] && [ -s "$OUT" ] && is_png "$OUT" && ok "a capture is written and is a PNG" ||
  ko "a capture is written and is a PNG (rc=$rc: $msg)"
args=$(cat "$WORK/fake.log" 2>/dev/null)
for want in --headless "--screenshot=$OUT" http://localhost:3002/; do
  case "
$args
" in
    *"
$want
"*) ok "the browser received $want" ;;
    *) ko "the browser did not receive $want" ;;
  esac
done
profile1=$(printf '%s\n' "$args" | sed -n 's/^--user-data-dir=//p')
if [ -n "$profile1" ] && [ ! -e "$profile1" ]; then
  ok "the browser's profile directory is gone after the run"
else
  ko "the browser's profile directory is gone after the run ('$profile1')"
fi

cap png http://localhost:3002/ "$OUT"
profile2=$(sed -n 's/^--user-data-dir=//p' "$WORK/fake.log")
if [ -n "$profile1" ] && [ -n "$profile2" ] && [ "$profile1" != "$profile2" ]; then
  ok "two runs get two different profile directories"
else
  ko "two runs get two different profile directories ('$profile1' / '$profile2')"
fi

# Refused before the browser is ever started.
for bad in 'file:///etc/passwd' 'javascript:alert(1)' '--renderer-cmd-prefix=x' '' \
           'http://' 'http://a b/' 'ftp://example.com/' "$(printf 'http://a/\nb')"; do
  cap png "$bad" "$WORK/refused.png"
  if [ "$rc" = 2 ] && [ ! -e "$WORK/fake.log" ] && [ ! -e "$WORK/refused.png" ]; then
    ok "the URL '$(printf '%s' "$bad" | tr '\n' ' ')' is refused with 2, the browser untouched"
  else
    ko "the URL '$bad' is refused with 2, the browser untouched (rc=$rc, log: $(ls "$WORK/fake.log" 2>&1))"
  fi
done
for bad in out.txt -x.png "$WORK/no-such-dir/x.png" "$WORK"; do
  cap png http://localhost:3002/ "$bad"
  if [ "$rc" = 2 ] && [ ! -e "$WORK/fake.log" ]; then
    ok "the output '$bad' is refused with 2, the browser untouched"
  else
    ko "the output '$bad' is refused with 2, the browser untouched (rc=$rc)"
  fi
done
cap png http://localhost:3002/
[ "$rc" = 2 ] && ok "a missing output argument is a usage error" || ko "a missing output argument is a usage error (rc=$rc)"

# A browser that exits 0 and writes nothing, over an older capture at the same path.
printf '\211PNG\r\n\032\nolder' >"$OUT"
cap nowrite http://localhost:3002/ "$OUT"
if [ "$rc" = 1 ] && [ ! -e "$OUT" ]; then
  ok "a browser that writes nothing fails, and the older capture is not taken for the new one"
else
  ko "a browser that writes nothing fails, and the older capture is not taken for the new one (rc=$rc)"
fi

cap text http://localhost:3002/ "$OUT"
[ "$rc" = 1 ] && [ ! -e "$OUT" ] && ok "a file that is not a PNG fails and is not kept" ||
  ko "a file that is not a PNG fails and is not kept (rc=$rc)"

printf '\211PNG\r\n\032\nolder' >"$OUT"
cap fail http://localhost:3002/ "$OUT"
[ "$rc" = 1 ] && [ ! -e "$OUT" ] && ok "a browser that fails makes the script fail" ||
  ko "a browser that fails makes the script fail (rc=$rc)"

# A browser that never comes back is killed, helpers included, inside the reduced delay.
start=$SECONDS
rm -f "$WORK/fake.pid" "$WORK/fake.child"
msg=$(FAKE_MODE=hang FAKE_LOG=$WORK/fake.log FAKE_PIDFILE=$WORK/fake.pid FAKE_CHILDPID=$WORK/fake.child \
  OLA_WORKFLOW_CHROME=$FAKE OLA_WORKFLOW_CAPTURE_TIMEOUT=1 "$CAPTURE" http://localhost:3002/ "$OUT" 2>&1)
rc=$?
elapsed=$((SECONDS - start))
if [ "$rc" = 1 ] && [ "$elapsed" -lt 15 ]; then
  ok "a browser that never returns is killed and the script fails (${elapsed}s)"
else
  ko "a browser that never returns is killed and the script fails (rc=$rc, ${elapsed}s: $msg)"
fi
hungpid=$(cat "$WORK/fake.pid" 2>/dev/null)
helperpid=$(cat "$WORK/fake.child" 2>/dev/null)
if [ -n "$hungpid" ] && ! kill -0 "$hungpid" 2>/dev/null; then
  ok "the hung browser is no longer running"
else
  ko "the hung browser is no longer running (pid '$hungpid')"
  [ -z "$hungpid" ] || kill -KILL "$hungpid" 2>/dev/null
fi
if [ -n "$helperpid" ] && ! kill -0 "$helperpid" 2>/dev/null; then
  ok "the hung browser's helper process is no longer running either"
else
  ko "the hung browser's helper process is no longer running either (pid '$helperpid')"
  [ -z "$helperpid" ] || kill -KILL "$helperpid" 2>/dev/null
fi

# A TERM sent to the script reaches the browser's group, which is no longer the script's.
rm -f "$WORK/fake.pid" "$WORK/fake.child"
FAKE_MODE=hang FAKE_LOG=$WORK/fake.log FAKE_PIDFILE=$WORK/fake.pid FAKE_CHILDPID=$WORK/fake.child \
  OLA_WORKFLOW_CHROME=$FAKE "$CAPTURE" http://localhost:3002/ "$OUT" >/dev/null 2>&1 &
scriptpid=$!
for _ in $(seq 1 50); do
  [ -s "$WORK/fake.pid" ] && [ -s "$WORK/fake.child" ] && break
  sleep 0.1
done
hungpid=$(cat "$WORK/fake.pid" 2>/dev/null)
helperpid=$(cat "$WORK/fake.child" 2>/dev/null)
kill -TERM "$scriptpid" 2>/dev/null
wait "$scriptpid" 2>/dev/null
termrc=$?
if [ -n "$hungpid" ] && [ -n "$helperpid" ] && ! kill -0 "$hungpid" 2>/dev/null && ! kill -0 "$helperpid" 2>/dev/null; then
  ok "a TERM sent to the script takes the browser and its helper down with it"
else
  ko "a TERM sent to the script takes the browser and its helper down with it (pids '$hungpid' '$helperpid')"
  [ -z "$hungpid" ] || kill -KILL "$hungpid" 2>/dev/null
  [ -z "$helperpid" ] || kill -KILL "$helperpid" 2>/dev/null
fi

# 128 + the signal, as a shell reports it: 143 for TERM. 130 is for INT, which a background
# job cannot receive here, so only the former is exercised.
[ "$termrc" = 143 ] && ok "a TERM sent to the script ends it with 143" ||
  ko "a TERM sent to the script ends it with 143 (rc=$termrc)"

msg=$(OLA_WORKFLOW_CAPTURE_TIMEOUT=abc OLA_WORKFLOW_CHROME=$FAKE "$CAPTURE" http://localhost:3002/ "$OUT" 2>&1)
rc=$?
[ "$rc" = 2 ] && ok "a timeout that is not an integer is refused" || ko "a timeout that is not an integer is refused (rc=$rc)"

# OLA_WORKFLOW_CHROME alone: no fallback to a browser the caller did not name.
mkdir -p "$WORK/fallback"
cp "$FAKE" "$WORK/fallback/google-chrome"
rm -f "$WORK/fake.log"
msg=$(PATH="$WORK/fallback:$PATH" FAKE_LOG=$WORK/fake.log OLA_WORKFLOW_CHROME=$WORK/absent \
  "$CAPTURE" http://localhost:3002/ "$OUT" 2>&1)
rc=$?
case $msg in
  *OLA_WORKFLOW_CHROME*) named=1 ;;
  *) named= ;;
esac
if [ "$rc" = 1 ] && [ -n "$named" ] && [ ! -e "$WORK/fake.log" ]; then
  ok "OLA_WORKFLOW_CHROME on an absent path: exit 1, the variable named, no fallback"
else
  ko "OLA_WORKFLOW_CHROME on an absent path: exit 1, the variable named, no fallback (rc=$rc: $msg)"
fi

# Without the variable, a browser on the PATH is found.
msg=$(PATH="$WORK/fallback:$PATH" FAKE_LOG=$WORK/fake.log \
  "$CAPTURE" http://localhost:3002/ "$OUT" 2>&1)
rc=$?
[ "$rc" = 0 ] && [ -s "$WORK/fake.log" ] && ok "without the variable, google-chrome on the PATH is used" ||
  ko "without the variable, google-chrome on the PATH is used (rc=$rc: $msg)"

# --- pr-assets --------------------------------------------------------------------------

png() { printf '\211PNG\r\n\032\n%s' "$2" >"$1"; }
png "$WORK/shot.png" "first picture"
png "$WORK/other.png" "second picture"
echo "just text" >"$WORK/x.png"
echo "just text" >"$WORK/notes.txt"
png "$WORK/-x.png" "dash"

BARE=$WORK/origin.git
git init --quiet --bare "$BARE"

# mkclone <dir> <origin url as configured> → a clone whose configured URL is a GitHub one
# and which git rewrites to the bare repository, so that the script reads the former and
# git pushes to the latter.
mkclone() {
  # A real clone: it has the fetch refspec, so a fetch of pr-assets updates
  # refs/remotes/origin/pr-assets and FETCH_HEAD in it, as it does for a developer.
  git clone --quiet "$BARE" "$1" 2>/dev/null
  git -C "$1" config remote.origin.url "$2"
  git -C "$1" config "url.$BARE.insteadOf" "$2"
  echo base >"$1/README"
  git -C "$1" add README
  git -C "$1" commit --quiet -m base
}

A=$WORK/clone-a
mkclone "$A" https://github.com/someone/x.git
echo staged >"$A/staged"
git -C "$A" add staged
echo loose >"$A/untracked"

state() {
  printf '%s\n' "$(git -C "$1" rev-parse HEAD)" "$(git -C "$1" ls-files -s)" \
    "$(git -C "$1" status --porcelain)" "$(git -C "$1" branch --list)" \
    "$(git -C "$1" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags)"
}
before=$(state "$A")

msg=$(cd "$A" && "$ASSETS" 12 "$WORK/shot.png" 2>&1)
rc=$?
[ "$rc" = 0 ] && ok "the first push succeeds" || ko "the first push succeeds (rc=$rc: $msg)"
if git -C "$BARE" show pr-assets:12/shot.png 2>/dev/null | cmp -s - "$WORK/shot.png"; then
  ok "the file is at 12/shot.png, byte for byte"
else
  ko "the file is at 12/shot.png, byte for byte"
fi
roots=$(git -C "$BARE" rev-list --max-parents=0 pr-assets 2>/dev/null)
tip=$(git -C "$BARE" rev-parse pr-assets 2>/dev/null)
[ -n "$tip" ] && [ "$roots" = "$tip" ] && ok "the first push creates pr-assets as a root commit" ||
  ko "the first push creates pr-assets as a root commit"
after=$(state "$A")
[ "$before" = "$after" ] && ok "HEAD, the index, the status and the branches of the clone are unchanged" ||
  ko "HEAD, the index, the status and the branches of the clone are unchanged"
[ -z "$(git -C "$A" branch --list pr-assets)" ] && ok "no local pr-assets branch is created" ||
  ko "no local pr-assets branch is created"

# The exact markdown, https and scp-like.
[ "$msg" = '![shot](https://github.com/someone/x/blob/pr-assets/12/shot.png?raw=true)' ] &&
  ok "the markdown line, for an https remote" || ko "the markdown line, for an https remote (got: $msg)"
S=$WORK/clone-scp
mkclone "$S" git@github.com:owner/repo.git
msg=$(cd "$S" && "$ASSETS" 7 "$WORK/other.png" 2>&1)
if [ "$msg" = '![other](https://github.com/owner/repo/blob/pr-assets/7/other.png?raw=true)' ]; then
  ok "the markdown line, for a git@github.com:owner/repo.git remote"
else
  ko "the markdown line, for a git@github.com:owner/repo.git remote (got: $msg)"
fi

# The host an SSH remote names is not always the web host. `ssh -G` says which machine an
# alias reaches, and GitHub's SSH-over-443 host is not its web host: both would give a dead
# link while the push succeeds. The ssh below stands in for the user's ~/.ssh/config.
mkdir -p "$WORK/sshshim"
cat >"$WORK/sshshim/ssh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -G ] || exit 1
shift
[ "$1" != -- ] || shift
case $1 in
  gh-work) echo "hostname ssh.github.com" ;;
  gh-perso) echo "hostname github.com" ;;
  ssh.github.com) echo "hostname ssh.github.com" ;;
  git.example.org) echo "hostname git.example.org" ;;
  # Anything else, an http(s) host included, resolves elsewhere: a link that went through
  # ssh -G for an https remote would not name the host the remote does.
  *) echo "hostname 192.0.2.1" ;;
esac
EOF
chmod +x "$WORK/sshshim/ssh"
n=0
while IFS='|' read -r remote want; do
  n=$((n + 1))
  C=$WORK/clone-alias-$n
  mkclone "$C" "$remote"
  msg=$(cd "$C" && PATH="$WORK/sshshim:$PATH" "$ASSETS" 40 "$WORK/other.png" 2>&1)
  if [ "$msg" = "![other](https://$want/blob/pr-assets/40/other.png?raw=true)" ]; then
    ok "the link names the web host, for $remote"
  else
    ko "the link names the web host, for $remote (got: $msg)"
  fi
done <<'REMOTES'
git@gh-work:owner/repo.git|github.com/owner/repo
git@gh-perso:owner/repo.git|github.com/owner/repo
git@ssh.github.com:owner/repo.git|github.com/owner/repo
ssh://git@ssh.github.com:443/owner/repo.git|github.com/owner/repo
https://github.com/owner/repo.git|github.com/owner/repo
git@git.example.org:owner/repo.git|git.example.org/owner/repo
REMOTES

# A second clone, behind, pushes for another PR: the first one's files are still there.
B=$WORK/clone-b
mkclone "$B" https://github.com/someone/x.git
git -C "$B" fetch --quiet origin '+refs/heads/pr-assets:refs/remotes/origin/pr-assets'
git -C "$A" fetch --quiet origin
before=$(state "$A")
(cd "$A" && "$ASSETS" 13 "$WORK/other.png" >/dev/null 2>&1)
if [ "$before" = "$(state "$A")" ]; then
  ok "a second push from a clone that has fetched leaves HEAD, the index, the status and the branches unchanged"
else
  ko "a second push from a clone that has fetched leaves HEAD, the index, the status and the branches unchanged"
fi
(cd "$B" && "$ASSETS" 14 "$WORK/shot.png" "$WORK/other.png" >/dev/null 2>&1)
rc=$?
files=$(git -C "$BARE" ls-tree -r --name-only pr-assets 2>/dev/null | tr '\n' ' ')
want="12/shot.png 13/other.png 14/other.png 14/shot.png 40/other.png 7/other.png "
[ "$rc" = 0 ] && [ "$files" = "$want" ] &&
  ok "a clone that is behind builds on the remote head: earlier files are kept" ||
  ko "a clone that is behind builds on the remote head: earlier files are kept (rc=$rc: $files)"

# A name pushed again replaces the old one.
png "$WORK/shot.png" "a newer picture"
(cd "$A" && "$ASSETS" 12 "$WORK/shot.png" >/dev/null 2>&1)
git -C "$BARE" show pr-assets:12/shot.png 2>/dev/null | cmp -s - "$WORK/shot.png" &&
  ok "a name pushed again replaces the old one" || ko "a name pushed again replaces the old one"
[ "$(git -C "$BARE" rev-list --count pr-assets)" -ge 4 ] &&
  ok "history is kept: every push is a commit on top" || ko "history is kept: every push is a commit on top"

# A pre-receive hook that refuses the first attempt: the script tries again.
cat >"$BARE/hooks/pre-receive" <<EOF
#!/usr/bin/env bash
if [ ! -e "$WORK/hook-refused-once" ]; then
  : >"$WORK/hook-refused-once"
  echo "refused on purpose" >&2
  exit 1
fi
EOF
chmod +x "$BARE/hooks/pre-receive"
png "$WORK/retry.png" "retried"
msg=$(cd "$A" && "$ASSETS" 20 "$WORK/retry.png" 2>&1)
rc=$?
if [ "$rc" = 0 ] && [ -e "$WORK/hook-refused-once" ] &&
  git -C "$BARE" cat-file -e pr-assets:20/retry.png 2>/dev/null; then
  ok "a push refused once is built again and succeeds"
else
  ko "a push refused once is built again and succeeds (rc=$rc: $msg)"
fi

# Someone else pushes between our fetch and our push: a shim in front of git advances
# pr-assets on origin just before the first `git push`. A force would erase their file; a
# retry on the new head keeps it.
REAL_GIT=$(command -v git)
mkdir -p "$WORK/shim"
cat >"$WORK/shim/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = push ] && [ ! -e "$WORK/competitor-pushed" ]; then
  : >"$WORK/competitor-pushed"
  export GIT_DIR=$BARE GIT_INDEX_FILE=$WORK/competitor-index
  parent=\$("$REAL_GIT" rev-parse pr-assets)
  "$REAL_GIT" read-tree "\$parent"
  blob=\$(printf competitor | "$REAL_GIT" hash-object -w --stdin)
  "$REAL_GIT" update-index --add --cacheinfo "100644,\$blob,99/competitor.png"
  commit=\$("$REAL_GIT" commit-tree "\$("$REAL_GIT" write-tree)" -p "\$parent" -m competitor)
  "$REAL_GIT" update-ref refs/heads/pr-assets "\$commit"
  unset GIT_DIR GIT_INDEX_FILE
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$WORK/shim/git"
msg=$(cd "$A" && PATH="$WORK/shim:$PATH" "$ASSETS" 22 "$WORK/retry.png" 2>&1)
rc=$?
if [ "$rc" = 0 ] && git -C "$BARE" cat-file -e pr-assets:99/competitor.png 2>/dev/null &&
  git -C "$BARE" cat-file -e pr-assets:22/retry.png 2>/dev/null; then
  ok "a push that loses a race is built again on the new head, nothing of theirs is erased"
else
  ko "a push that loses a race is built again on the new head, nothing of theirs is erased (rc=$rc: $msg)"
fi

# Always refused: three attempts, then 1, and no force.
cat >"$BARE/hooks/pre-receive" <<EOF
#!/usr/bin/env bash
echo x >>"$WORK/hook-calls"
exit 1
EOF
rm -f "$WORK/hook-calls"
tip=$(git -C "$BARE" rev-parse pr-assets)
(cd "$A" && "$ASSETS" 21 "$WORK/retry.png" >/dev/null 2>&1)
rc=$?
calls=$(wc -l <"$WORK/hook-calls" | tr -d ' ')
[ "$rc" = 1 ] && [ "$calls" = 3 ] && [ "$(git -C "$BARE" rev-parse pr-assets)" = "$tip" ] &&
  ok "a push always refused is tried 3 times, then exit 1, the branch intact" ||
  ko "a push always refused is tried 3 times, then exit 1, the branch intact (rc=$rc, $calls attempts)"
rm -f "$BARE/hooks/pre-receive"

# --- pr-assets, forge: gitlab -------------------------------------------------------------

# On GitLab the raw file is at <project>/-/raw/<branch>/<path>, with no ?raw=true; the web
# host of GitLab's SSH-over-443 host altssh.gitlab.com is gitlab.com; a subgroup is part of
# the project path. The forge comes from the profile, never from the host's name: a
# self-managed GitLab is called anything.
GLBARE=$WORK/gitlab-origin.git
git init --quiet --bare "$GLBARE"
glclone() { # glclone <dir> <origin url as configured> <profile json, or empty for none>
  git clone --quiet "$GLBARE" "$1" 2>/dev/null
  git -C "$1" config remote.origin.url "$2"
  git -C "$1" config "url.$GLBARE.insteadOf" "$2"
  echo base >"$1/README"
  git -C "$1" add README
  git -C "$1" commit --quiet -m base
  if [ -n "$3" ]; then
    mkdir -p "$1/.claude"
    printf '%s\n' "$3" >"$1/.claude/workflow.json"
  fi
}
cat >"$WORK/sshshim/ssh" <<'SHIM'
#!/usr/bin/env bash
[ "$1" = -G ] || exit 1
shift
[ "$1" != -- ] || shift
case $1 in
  gitlab.com) echo "hostname gitlab.com" ;;
  gl-work|altssh.gitlab.com) echo "hostname altssh.gitlab.com" ;;
  gh-work) echo "hostname ssh.github.com" ;;
  *) echo "hostname 192.0.2.1" ;;
esac
SHIM
GL='{"mode":"integrated","forge":"gitlab"}'
n=0
while IFS='|' read -r remote want; do
  n=$((n + 1))
  C=$WORK/clone-gitlab-$n
  glclone "$C" "$remote" "$GL"
  msg=$(cd "$C" && PATH="$WORK/sshshim:$PATH" "$ASSETS" 41 "$WORK/other.png" 2>&1)
  if [ "$msg" = "![other](https://$want/-/raw/pr-assets/41/other.png)" ]; then
    ok "forge gitlab: the link is /-/raw/ on the web host, for $remote"
  else
    ko "forge gitlab: the link is /-/raw/ on the web host, for $remote (got: $msg)"
  fi
done <<'REMOTES'
https://gitlab.com/group/repo.git|gitlab.com/group/repo
https://gitlab.com/group/sub/deep/repo.git|gitlab.com/group/sub/deep/repo
git@gitlab.com:group/sub/repo.git|gitlab.com/group/sub/repo
git@gl-work:group/repo.git|gitlab.com/group/repo
git@altssh.gitlab.com:group/repo.git|gitlab.com/group/repo
ssh://git@altssh.gitlab.com:443/group/sub/repo.git|gitlab.com/group/sub/repo
https://git.example.org/group/repo.git|git.example.org/group/repo
REMOTES
git -C "$GLBARE" show pr-assets:41/other.png 2>/dev/null | cmp -s - "$WORK/other.png" &&
  ok "forge gitlab: the file is at 41/other.png, byte for byte" ||
  ko "forge gitlab: the file is at 41/other.png, byte for byte"

# Without forge: gitlab, the GitHub form, byte for byte, whatever the host is called.
C=$WORK/clone-gitlab-noprofile
glclone "$C" https://gitlab.com/group/repo.git ""
msg=$(cd "$C" && "$ASSETS" 42 "$WORK/other.png" 2>&1)
[ "$msg" = '![other](https://gitlab.com/group/repo/blob/pr-assets/42/other.png?raw=true)' ] &&
  ok "no profile: the GitHub form, whatever the host" ||
  ko "no profile: the GitHub form, whatever the host (got: $msg)"
C=$WORK/clone-gitlab-ghprofile
glclone "$C" https://git.example.org/o/r.git '{"mode":"integrated","forge":"github"}'
msg=$(cd "$C" && "$ASSETS" 43 "$WORK/other.png" 2>&1)
[ "$msg" = '![other](https://git.example.org/o/r/blob/pr-assets/43/other.png?raw=true)' ] &&
  ok "forge github: the GitHub form" || ko "forge github: the GitHub form (got: $msg)"
# ssh.github.com is rewritten for GitHub only, and altssh.gitlab.com for GitLab only.
C=$WORK/clone-gitlab-ghalt
glclone "$C" git@gl-work:o/r.git '{"mode":"integrated"}'
msg=$(cd "$C" && PATH="$WORK/sshshim:$PATH" "$ASSETS" 44 "$WORK/other.png" 2>&1)
[ "$msg" = '![other](https://altssh.gitlab.com/o/r/blob/pr-assets/44/other.png?raw=true)' ] &&
  ok "forge github: altssh.gitlab.com is left alone" || ko "forge github: altssh.gitlab.com is left alone (got: $msg)"
C=$WORK/clone-gitlab-glalt
glclone "$C" git@gh-work:o/r.git "$GL"
msg=$(cd "$C" && PATH="$WORK/sshshim:$PATH" "$ASSETS" 45 "$WORK/other.png" 2>&1)
[ "$msg" = '![other](https://ssh.github.com/o/r/-/raw/pr-assets/45/other.png)' ] &&
  ok "forge gitlab: ssh.github.com is left alone" || ko "forge gitlab: ssh.github.com is left alone (got: $msg)"

# A clone with no identity: the commit is made as ola-workflow, with an address under the
# forge's own noreply domain (users.noreply.github.com, users.noreply.gitlab.com).
noid() { # noid <dir> <pr> → runs the script with no git identity at all
  (cd "$1" && env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.useConfigOnly GIT_CONFIG_VALUE_0=true \
    "$ASSETS" "$2" "$WORK/other.png" 2>&1)
}
C=$WORK/clone-gitlab-noid
glclone "$C" https://gitlab.com/group/repo.git "$GL"
msg=$(noid "$C" 46)
who=$(git -C "$GLBARE" log -1 --format='%an <%ae> %cn <%ce>' pr-assets 2>/dev/null)
[ "$who" = 'ola-workflow <ola-workflow@users.noreply.gitlab.com> ola-workflow <ola-workflow@users.noreply.gitlab.com>' ] &&
  ok "forge gitlab: without an identity, the commit is ola-workflow@users.noreply.<host>" ||
  ko "forge gitlab: without an identity, the commit is ola-workflow@users.noreply.<host> (got: $who; $msg)"
C=$WORK/clone-github-noid
glclone "$C" https://github.com/o/r.git ""
msg=$(noid "$C" 47)
who=$(git -C "$GLBARE" log -1 --format='%an <%ae> %cn <%ce>' pr-assets 2>/dev/null)
[ "$who" = 'ola-workflow <ola-workflow@users.noreply.github.com> ola-workflow <ola-workflow@users.noreply.github.com>' ] &&
  ok "forge github: without an identity, the commit is ola-workflow@users.noreply.github.com" ||
  ko "forge github: without an identity, the commit is ola-workflow@users.noreply.github.com (got: $who; $msg)"

# Refusals: exit 2, and pr-assets untouched on origin.
tip=$(git -C "$BARE" rev-parse pr-assets)
refuse() { # refuse <label> <args...>
  local label=$1
  shift
  msg=$(cd "$A" && "$ASSETS" "$@" 2>&1)
  rc=$?
  if [ "$rc" = 2 ] && [ "$(git -C "$BARE" rev-parse pr-assets)" = "$tip" ]; then
    ok "refused with 2, pr-assets intact: $label"
  else
    ko "refused with 2, pr-assets intact: $label (rc=$rc: $msg)"
  fi
}
refuse "PR 0" 0 "$WORK/shot.png"
refuse "PR 12a" 12a "$WORK/shot.png"
refuse "PR -1" -1 "$WORK/shot.png"
refuse 'PR $(id)' '$(id)' "$WORK/shot.png"
refuse "PR 012" 012 "$WORK/shot.png"
refuse "a .txt file" 30 "$WORK/notes.txt"
refuse "a text file named x.png" 30 "$WORK/x.png"
refuse "a name starting with a dash" 30 "$WORK/-x.png"
refuse "an absent file" 30 "$WORK/absent.png"
refuse "a directory" 30 "$WORK"
refuse "no file at all" 30
refuse "the same name twice" 30 "$WORK/shot.png" "$WORK/shot.png"
# A bad file after good ones: nothing is pushed.
refuse "a bad file after a good one" 30 "$WORK/shot.png" "$WORK/x.png"

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total capture test(s) failed"
  exit 1
fi
echo "all $total capture tests passed"
