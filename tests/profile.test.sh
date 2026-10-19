#!/usr/bin/env bash
# Profile resolution, reading and validation, against throwaway git repositories.
# Nothing here touches the network or the real HOME.
set -uo pipefail

SCRATCH_ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/scratch.sh
. "$SCRATCH_ROOT/scripts/scratch.sh"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLI=$ROOT/bin/ola-profile
# shellcheck source=hooks/lib/profile.sh
. "$ROOT/hooks/lib/profile.sh"

failures=0
total=0

eq() { # eq <expected> <actual> <label>
  total=$((total + 1))
  if [ "$1" = "$2" ]; then
    echo "ok    $3"
  else
    echo "FAIL  $3"
    echo "        expected: $(printf '%s' "$1" | sed -n 'l' | head -4)"
    echo "        actual:   $(printf '%s' "$2" | sed -n 'l' | head -4)"
    failures=$((failures + 1))
  fi
}

ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

rc() { # rc <expected status> <label> -- <command...>
  local expected=$1 label=$2 out actual
  shift 3
  out=$("$@" 2>/dev/null)
  actual=$?
  total=$((total + 1))
  if [ "$actual" = "$expected" ] && [ -z "$out" ]; then
    echo "ok    $label"
  else
    echo "FAIL  $label (status $actual, output '${out}')"
    failures=$((failures + 1))
  fi
}

# pwd -P: on macOS mktemp hands back a symlink, while git reports physical paths.
ola_scratch profile
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT
export HOME=$WORK/home
mkdir -p "$HOME"

mkrepo() { # mkrepo <path> <origin url> [upstream url]
  local path=$1 origin=${2:-} upstream=${3:-}
  mkdir -p "$path"
  git -C "$path" -c init.defaultBranch=main init -q 2>/dev/null
  [ -n "$origin" ] && git -C "$path" remote add origin "$origin"
  [ -n "$upstream" ] && git -C "$path" remote add upstream "$upstream"
  git -C "$path" -c user.email=t@example.com -c user.name=t \
    commit -q --allow-empty -m "init" 2>/dev/null
}

user_profile() { # user_profile <id> <json>
  mkdir -p "$HOME/.claude/workflow-profiles/$1"
  printf '%s\n' "$2" >"$HOME/.claude/workflow-profiles/$1/profile.json"
}

FULL_PROFILE='{
  "mode": "integrated",
  "language": {"human": "fr", "artifacts": "fr", "agents": "en"},
  "base_branch": "master",
  "check": {"full": "make check", "affected": "make check-affected SLOT={slot}", "cleanup": "make down-all {slot}"},
  "slots": {"var": "SLOT", "developers": [1, 2, 3, 4], "reviewer": 9},
  "pr": {"max_lines": 1000, "exclude": ["package-lock.json"], "title": "conventional"},
  "merge": {
    "required_checks": ["checks", "pr-size"],
    "review_status": "agent-review",
    "sensitive_paths": ["back/migrations/**", ".github/**"],
    "sensitive_patterns": [{"file": "Makefile", "regex": "deploy"}, {"regex": "git push"}]
  },
  "commands": [{"cmd": "eas", "allow_args": "^build", "reason": "builds only"}],
  "db_hosts_allowed": ["pg", "localhost"],
  "context": {"product": "docs/agents/product.md"},
  "verify_ui": {"kind": "ios-simulator", "up": "make sim-up"},
  "escalation_extra": ["données de production"]
}'

# --- Remote URL → profile directory ---------------------------------------------------
# A remote URL is the only project-controlled input to a path, so this is also a security
# boundary: nothing may walk out of the profiles directory.
# The expectations were confronted with git itself where they were not obvious. Notably
# the scp-like syntax has no port field, so `git@[fd00::1]:2222/srv/app.git` makes
# `2222/srv/app.git` the path — verified with a logging GIT_SSH_COMMAND, which git invokes
# as `git@fd00::1 git-upload-pack '2222/srv/app.git'`.
while IFS='|' read -r url expected; do
  [ -n "$url" ] || continue
  got=$(ola_profile_url_id "$url" 2>/dev/null) || got="(refused)"
  eq "$expected" "$got" "url_id $url"
done <<'TABLE'
git@github.com:owner/repo.git|github.com/owner/repo
git@github.com:owner/repo|github.com/owner/repo
https://github.com/owner/repo.git|github.com/owner/repo
https://github.com/owner/repo|github.com/owner/repo
https://user:ghp_token@github.com/owner/repo.git|github.com/owner/repo
ssh://git@github.com:22/owner/repo.git|github.com/owner/repo
ssh://github.com/owner/repo|github.com/owner/repo
git://example.com/owner/repo|example.com/owner/repo
https://GitHub.COM/Owner/Repo.git|github.com/Owner/Repo
https://gitlab.com/group/sub/deeper/repo.git|gitlab.com/group/sub/deeper/repo
git@gitlab.com:group/sub/repo.git|gitlab.com/group/sub/repo
https://github.com/owner/repo/|github.com/owner/repo
https://alice:s3cr3t@p@ss@github.com/acme/widget.git|github.com/acme/widget
git@a@b@gitlab.com:group/repo.git|gitlab.com/group/repo
https://user@github.com/owner/re@po|github.com/owner/re@po
ssh://host:22|(refused)
https://github.com:443/|(refused)
https://user:tok/en@github.com/o/r.git|(refused)
https://user:tok/en@github.com/o/r|(refused)
https://github.com:notaport/o/r|(refused)
https://github.com:/o/r|github.com/o/r
ssh://git@[fd00::1]/srv/team/app.git|fd00::1/srv/team/app
ssh://git@[fd00::1]:2222/srv/team/app.git|fd00::1/srv/team/app
https://[2001:db8::1]:8443/o/r.git|2001:db8::1/o/r
https://[2001:DB8::1]/o/r|2001:db8::1/o/r
https://user:tok@[fd00::1]/o/r|fd00::1/o/r
https://[fd00::1/o/r|(refused)
https://[fd00::1]x/o/r|(refused)
https://[fd00::1]:notaport/o/r|(refused)
git@../x:owner/repo|(refused)
git@[fd00::1]:srv/app.git|fd00::1/srv/app
git@[fd00::1]:/srv/app.git|fd00::1/srv/app
[fd00::1]:srv/app.git|fd00::1/srv/app
git@[fd00::1]:2222/srv/app.git|fd00::1/2222/srv/app
git@[fd00::1]/srv/app.git|(refused)
git@[fd00::1:srv/app.git|(refused)
https://github.com:8443/o/r|github.com/o/r
ssh://git@github.com:2222/o/r.git|github.com/o/r
https://github.com@evil.com/o/r|evil.com/o/r
https://host/owner/.git|(refused)
https://github.com//repo|(refused)
../..|(refused)
/srv/.|(refused)
/|(refused)
/srv/git/repo.git|local/repo
file:///srv/git/repo|local/repo
../sibling-repo|local/sibling-repo
https://github.com/../../etc/passwd|(refused)
git@github.com:../escape.git|(refused)
https://github.com/owner/../../repo|(refused)
|(refused)
nonsense|(refused)
https:///owner/repo|(refused)
TABLE

# A component holding a slash does come out of a URL: `git@../x:owner/repo` makes `../x`
# the authority, which the clause below is what refuses. The earlier version of this
# comment claimed it was unreachable, and the reviewer was right that it is not.
for bad in 'a/b' '..' '.' ''; do
  total=$((total + 1))
  if ola_profile_component_ok "$bad"; then
    echo "FAIL  component_ok refuses '$bad'"
    failures=$((failures + 1))
  else
    echo "ok    component_ok refuses '$bad'"
  fi
done
for good in repo 'owner.name' 'a_b-c' '.hidden'; do
  total=$((total + 1))
  if ola_profile_component_ok "$good"; then
    echo "ok    component_ok accepts '$good'"
  else
    echo "FAIL  component_ok accepts '$good'"
    failures=$((failures + 1))
  fi
done

# --- Integrated mode ------------------------------------------------------------------
mkrepo "$WORK/integrated" "git@github.com:olaurendeau/racine.git"
mkdir -p "$WORK/integrated/.claude"
printf '%s\n' "$FULL_PROFILE" >"$WORK/integrated/.claude/workflow.json"
git -C "$WORK/integrated" add -A >/dev/null 2>&1
git -C "$WORK/integrated" -c user.email=t@example.com -c user.name=t \
  commit -q -m "profile" 2>/dev/null

eq "$WORK/integrated/.claude/workflow.json" "$("$CLI" -C "$WORK/integrated" path)" "integrated: path"
eq integrated "$("$CLI" -C "$WORK/integrated" mode)" "integrated: mode"
eq "$WORK/integrated/.claude" "$("$CLI" -C "$WORK/integrated" dir)" "integrated: dir"
eq "github.com/olaurendeau/racine" "$("$CLI" -C "$WORK/integrated" id)" "integrated: id"
# A subdirectory resolves like the project root: the guard gets whatever cwd the tool used.
mkdir -p "$WORK/integrated/back/src"
eq integrated "$("$CLI" -C "$WORK/integrated/back/src" mode)" "integrated: from a subdirectory"

# --- Reading values -------------------------------------------------------------------
eq master "$("$CLI" -C "$WORK/integrated" get base_branch)" "get: scalar"
eq "make check" "$("$CLI" -C "$WORK/integrated" get check.full)" "get: nested"
eq "make check-affected SLOT=3" \
  "$("$CLI" -C "$WORK/integrated" --slot 3 get check.affected)" "get: {slot} replaced"
eq "make check-affected SLOT={slot}" \
  "$("$CLI" -C "$WORK/integrated" get check.affected)" "get: {slot} kept without --slot"
eq "checks
pr-size" "$("$CLI" -C "$WORK/integrated" get merge.required_checks)" "get: array, one per line"
eq "1
2
3
4" "$("$CLI" -C "$WORK/integrated" get slots.developers)" "get: array of numbers"
eq '{"human":"fr","artifacts":"fr","agents":"en"}' \
  "$("$CLI" -C "$WORK/integrated" get language)" "get: object as compact JSON"
eq '[{"file":"Makefile","regex":"deploy"},{"regex":"git push"}]' \
  "$("$CLI" -C "$WORK/integrated" get merge.sensitive_patterns)" "get: array of objects as JSON"
rc 1 "get: missing key exits 1" -- "$CLI" -C "$WORK/integrated" get nope.nope
eq main "$("$CLI" -C "$WORK/integrated" get nope main)" "get: default for a missing key"
eq "SLOT=7" "$("$CLI" -C "$WORK/integrated" --slot 7 get nope 'SLOT={slot}')" "get: {slot} in the default"

# --- An option is read wherever it is written ----------------------------------------
# `--slot` was read before the subcommand and dropped **in silence** after it — which is the
# form the README documents and the form a person writes. It returned `make check SLOT={slot}`
# and an agent ran that literally, reported from a real project.
#
# Every row below writes the option somewhere a person might, and the one that was broken is
# the second. The suite had a row for the first position only, so the defect was not a
# missing assertion about a rule: it was an assertion about one spelling of a rule that has
# four. An option understood in one position and ignored in another is worse than one refused
# everywhere, because a refusal is a message and the silence is a command with a brace in it.
for form in "--slot|3|get|check.affected" \
            "get|check.affected|--slot|3" \
            "--slot=3|get|check.affected" \
            "get|check.affected|--slot=3"; do
  IFS='|' read -r -a argv <<<"$form"
  eq "make check-affected SLOT=3" "$("$CLI" -C "$WORK/integrated" "${argv[@]}")" \
    "get: {slot} replaced with the option written as: $(printf '%s ' "${argv[@]}")"
done
# The same, reaching the default rather than a key, because that is a second reader of the
# slot and it was right while the first was wrong.
eq "SLOT=5" "$("$CLI" -C "$WORK/integrated" get nope 'SLOT={slot}' --slot 5)" \
  "get: {slot} in the default, option written last"
# And `--` still means "stop reading options", so a key spelt like one can be asked for.
rc 1 "an argument after -- is an argument, not an option" -- \
  "$CLI" -C "$WORK/integrated" get -- --slot
# An option nobody knows is still refused, wherever it sits.
rc 2 "an unknown option after the subcommand is still refused" -- \
  "$CLI" -C "$WORK/integrated" get check.affected --made-up 3
rc 2 "a missing value after the subcommand is still refused" -- \
  "$CLI" -C "$WORK/integrated" get check.affected --slot
eq master "$("$CLI" -C "$WORK/integrated" get base_branch fallback)" "get: default unused when set"
eq fallback "$("$CLI" -C "$WORK/integrated" get base_branch.deeper fallback)" \
  "get: a key path through a scalar is just absent"
rc 1 "get: a key path through a scalar, without a default" -- \
  "$CLI" -C "$WORK/integrated" get base_branch.deeper
rc 2 "get: an empty key is a usage error" -- "$CLI" -C "$WORK/integrated" get ""
eq "ios-simulator" "$(cd "$WORK/integrated" && "$CLI" get verify_ui.kind)" "get: without -C, from the cwd"
eq "pg
localhost" "$("$CLI" -C "$WORK/integrated" get db_hosts_allowed)" "get: a list of hosts"
# The schema now states that {slot} works in any string value, not only check.affected.
eq "make down-all 4" "$("$CLI" -C "$WORK/integrated" --slot 4 get check.cleanup)" \
  "get: {slot} in a value the schema does not single out"

# --- Discreet mode --------------------------------------------------------------------
mkrepo "$WORK/discreet" "https://github.com/someone/their-repo.git"
user_profile "github.com/someone/their-repo" '{"mode": "discreet", "base_branch": "trunk"}'
eq "$HOME/.claude/workflow-profiles/github.com/someone/their-repo/profile.json" \
  "$("$CLI" -C "$WORK/discreet" path)" "discreet: path"
eq discreet "$("$CLI" -C "$WORK/discreet" mode)" "discreet: mode"
eq trunk "$("$CLI" -C "$WORK/discreet" get base_branch)" "discreet: get"
eq "$HOME/.claude/workflow-profiles/github.com/someone/their-repo" \
  "$("$CLI" -C "$WORK/discreet" dir)" "discreet: dir is where the memory goes"
eq "" "$(git -C "$WORK/discreet" status --porcelain)" "discreet: the repository stays clean"

# --- A fork is known by the repository it contributes to ------------------------------
mkrepo "$WORK/fork" "git@github.com:olaurendeau/their-repo.git" \
  "https://github.com/upstream-org/their-repo.git"
user_profile "github.com/upstream-org/their-repo" '{"mode": "discreet", "base_branch": "develop"}'
eq "github.com/upstream-org/their-repo" "$("$CLI" -C "$WORK/fork" id)" "fork: upstream wins over origin"
eq develop "$("$CLI" -C "$WORK/fork" get base_branch)" "fork: reads the upstream profile"

# --- Worktrees ------------------------------------------------------------------------
# Developers work in worktrees, so resolution has to behave there, in both modes.
git -C "$WORK/integrated" worktree add -q --detach "$WORK/integrated-wt" >/dev/null 2>&1
eq integrated "$("$CLI" -C "$WORK/integrated-wt" mode)" "worktree: integrated profile is checked out"
eq "$WORK/integrated-wt/.claude/workflow.json" \
  "$("$CLI" -C "$WORK/integrated-wt" path)" "worktree: its own copy of the profile"
git -C "$WORK/discreet" worktree add -q --detach "$WORK/discreet-wt" >/dev/null 2>&1
eq "github.com/someone/their-repo" "$("$CLI" -C "$WORK/discreet-wt" id)" "worktree: remote still resolves"
eq trunk "$("$CLI" -C "$WORK/discreet-wt" get base_branch)" "worktree: same user profile"

# --- The user's own profile wins over a committed one ---------------------------------
# A third-party repository must not be able to upgrade the discreet profile its user chose
# into an integrated one, which would hand it writes to the forge and command allowances.
mkdir -p "$WORK/discreet/.claude"
printf '%s\n' '{"mode": "integrated", "base_branch": "from-project"}' \
  >"$WORK/discreet/.claude/workflow.json"
eq trunk "$("$CLI" -C "$WORK/discreet" get base_branch)" "precedence: user over project"
eq discreet "$("$CLI" -C "$WORK/discreet" mode)" "precedence: a repository cannot upgrade the mode"
eq "$HOME/.claude/workflow-profiles/github.com/someone/their-repo/profile.json" \
  "$("$CLI" -C "$WORK/discreet" path)" "precedence: the user's file is the one in use"

# A user profile that is corrupt, empty or not even a file must not restore the committed
# one: that would be the way back in for the content the precedence exists to distrust.
user_profile "github.com/someone/their-repo" '{"mode": "integrated",,,'
eq "$HOME/.claude/workflow-profiles/github.com/someone/their-repo/profile.json" \
  "$("$CLI" -C "$WORK/discreet" path)" "precedence: a corrupt user profile still wins"
eq discreet "$("$CLI" -C "$WORK/discreet" mode)" "precedence: corrupt means discreet, not the repo's mode"
rc 1 "precedence: get refuses rather than read the repo's file" -- \
  "$CLI" -C "$WORK/discreet" get base_branch from-project

printf '' >"$HOME/.claude/workflow-profiles/github.com/someone/their-repo/profile.json"
eq discreet "$("$CLI" -C "$WORK/discreet" mode)" "precedence: an empty user profile still wins"
user_profile "github.com/someone/their-repo" '{"mode": "discreet", "base_branch": "trunk"}'

# Inside a directory with no execute bit every test on a file reads false, so a profile
# that is right there looks absent. Falling through would hand the repository the last
# word, which is the one direction the precedence forbids. root ignores the bits, so this
# only means anything as an ordinary user.
if [ "$(id -u)" != 0 ]; then
  for level in "$HOME/.claude/workflow-profiles" \
               "$HOME/.claude/workflow-profiles/github.com" \
               "$HOME/.claude/workflow-profiles/github.com/someone/their-repo"; do
    chmod 000 "$level"
    rc 1 "precedence: an unenterable ${level##*workflow-profiles} gives up, it does not fall through" -- \
      "$CLI" -C "$WORK/discreet" mode
    chmod 755 "$level"
  done
  eq discreet "$("$CLI" -C "$WORK/discreet" mode)" "precedence: and works again once readable"

  # The accident can sit above the profiles directory, where even [ -d ] on the root
  # reads false. The contract has no exception, so neither does this.
  for level in "$HOME/.claude" "$HOME"; do
    chmod 000 "$level"
    rc 1 "precedence: an unenterable ${level##*/} gives up too" -- \
      "$CLI" -C "$WORK/discreet" mode
    chmod 755 "$level"
  done
  eq discreet "$("$CLI" -C "$WORK/discreet" mode)" "precedence: still fine afterwards"
else
  # Said rather than skipped in silence. Seven assertions vanishing between two platforms is
  # how a gap goes unnoticed — found by diffing the printed labels of a macOS run against a
  # container run, after a `stat` dialect made 193 guard tests fail on Linux while the suite
  # was green here. A skip with no reader is a gap.
  ok "precedence: the unenterable-directory block needs an ordinary user, and this is root"
fi

# Not a regular file at all: giving up is the only answer that keeps the order meaningful.
rm -f "$HOME/.claude/workflow-profiles/github.com/someone/their-repo/profile.json"
mkdir -p "$HOME/.claude/workflow-profiles/github.com/someone/their-repo/profile.json"
rc 1 "precedence: a directory where the profile should be refuses" -- \
  "$CLI" -C "$WORK/discreet" path
rc 1 "precedence: and does not fall back to the repository" -- \
  "$CLI" -C "$WORK/discreet" mode
rmdir "$HOME/.claude/workflow-profiles/github.com/someone/their-repo/profile.json"
user_profile "github.com/someone/their-repo" '{"mode": "discreet", "base_branch": "trunk"}'

rm -rf "$WORK/discreet/.claude"

# --- No profile at all: nothing happens ----------------------------------------------
mkrepo "$WORK/bare" "git@github.com:someone/unconfigured.git"
rc 1 "no profile: path" -- "$CLI" -C "$WORK/bare" path
rc 1 "no profile: mode" -- "$CLI" -C "$WORK/bare" mode
rc 1 "no profile: dir" -- "$CLI" -C "$WORK/bare" dir
rc 1 "no profile: get" -- "$CLI" -C "$WORK/bare" get base_branch
rc 1 "no profile: show" -- "$CLI" -C "$WORK/bare" show
eq "github.com/someone/unconfigured" "$("$CLI" -C "$WORK/bare" id)" "no profile: id still resolves"
# A default stands in for a missing key, never for a missing profile: issue #2 says the
# caller decides what to do about a project that has not opted in.
rc 1 "no profile: a default does not invent a configuration" -- \
  "$CLI" -C "$WORK/bare" get base_branch main
# Outside a repository, and inside a repository without any remote.
mkdir -p "$WORK/not-a-repo"
rc 1 "outside a repository: path" -- "$CLI" -C "$WORK/not-a-repo" path
mkrepo "$WORK/no-remote" ""
rc 1 "no remote: id" -- "$CLI" -C "$WORK/no-remote" id
rc 1 "no remote: path" -- "$CLI" -C "$WORK/no-remote" path

# The library is sourced by the guard, which runs under `set -u`: an unbound variable
# would end the shell mid-decision instead of leaving the guard inert.
rc 1 "HOME unset: resolution gives up quietly" -- env -u HOME "$CLI" -C "$WORK/discreet" path
total=$((total + 1))
if out=$(env -u HOME bash -c ". '$ROOT/hooks/lib/profile.sh'; set -u
  ola_profile_path '$WORK/discreet' || echo GAVE_UP
  echo STILL_ALIVE" 2>&1) \
  && [ "$out" = "GAVE_UP
STILL_ALIVE" ]; then
  echo "ok    HOME unset: a sourcing shell survives under set -u"
else
  echo "FAIL  HOME unset: a sourcing shell should survive ('$out')"
  failures=$((failures + 1))
fi

# A bare clone has no working tree, so only the user profile can apply.
git clone -q --bare "$WORK/discreet" "$WORK/bare-clone.git" 2>/dev/null
git -C "$WORK/bare-clone.git" remote set-url origin "https://github.com/someone/their-repo.git"
eq discreet "$("$CLI" -C "$WORK/bare-clone.git" mode)" "bare repository: the user profile applies"
git -C "$WORK/bare-clone.git" remote set-url origin "https://github.com/someone/unknown.git"
rc 1 "bare repository: no profile, no answer" -- "$CLI" -C "$WORK/bare-clone.git" path

# --- A broken profile is treated as the restrictive mode -----------------------------
mkrepo "$WORK/broken" "git@github.com:someone/broken.git"
mkdir -p "$WORK/broken/.claude"
printf '%s' '{"mode": "integrated",,,' >"$WORK/broken/.claude/workflow.json"
eq discreet "$("$CLI" -C "$WORK/broken" mode)" "broken JSON: mode falls back to discreet"
printf '%s\n' '{"base_branch": "main"}' >"$WORK/broken/.claude/workflow.json"
eq discreet "$("$CLI" -C "$WORK/broken" mode)" "missing mode: falls back to discreet"
printf '%s\n' '{"mode": "wide-open"}' >"$WORK/broken/.claude/workflow.json"
eq discreet "$("$CLI" -C "$WORK/broken" mode)" "unknown mode: falls back to discreet"

# An empty or whitespace-only profile is the shape a truncated write leaves behind. jq
# exits 0 with no output on it, so `get` has to refuse explicitly: answering "empty, and
# successfully" would report no protected branch and zero required checks.
for content in '' '   ' '
'; do
  printf '%s' "$content" >"$WORK/broken/.claude/workflow.json"
  rc 1 "empty profile: get refuses" -- "$CLI" -C "$WORK/broken" get base_branch
  rc 1 "empty profile: get refuses even with a default" -- "$CLI" -C "$WORK/broken" get base_branch main
  rc 1 "empty profile: get of an array refuses" -- "$CLI" -C "$WORK/broken" get merge.required_checks
  rc 1 "empty profile: show refuses" -- "$CLI" -C "$WORK/broken" show
  eq discreet "$("$CLI" -C "$WORK/broken" mode)" "empty profile: mode stays discreet"
done
printf '%s' '{"mode": "integrated",,,' >"$WORK/broken/.claude/workflow.json"
rc 1 "broken JSON: get refuses with a default" -- "$CLI" -C "$WORK/broken" get base_branch main

# Valid JSON that is not an object. `jq -e .` accepts all of these, so without a type
# check they read as an object missing every key, and the caller's default is handed out
# for a file nobody can use. The schema says the profile is an object; so does this.
for value in '[1,2]' '"hello"' '42' 'true' 'null' 'false'; do
  printf '%s\n' "$value" >"$WORK/broken/.claude/workflow.json"
  rc 1 "non-object profile $value: get refuses" -- "$CLI" -C "$WORK/broken" get base_branch
  rc 1 "non-object profile $value: and refuses a default too" -- \
    "$CLI" -C "$WORK/broken" get merge.required_checks zzz
  rc 1 "non-object profile $value: show refuses" -- "$CLI" -C "$WORK/broken" show
  eq discreet "$("$CLI" -C "$WORK/broken" mode)" "non-object profile $value: mode stays discreet"
done
rm -rf "$WORK/broken/.claude"

# --- Validation -----------------------------------------------------------------------
printf '%s\n' "$FULL_PROFILE" >"$WORK/valid.json"
total=$((total + 1))
if out=$("$CLI" validate "$WORK/valid.json" 2>&1) && [ -z "$out" ]; then
  echo "ok    validate: a full profile passes quietly"
else
  echo "FAIL  validate: a full profile should pass ($out)"
  failures=$((failures + 1))
fi
printf '%s\n' '{"mode": "discreet"}' >"$WORK/minimal.json"
total=$((total + 1))
if "$CLI" validate "$WORK/minimal.json" >/dev/null 2>&1; then
  echo "ok    validate: mode alone is enough"
else
  echo "FAIL  validate: mode alone should be enough"
  failures=$((failures + 1))
fi

expect_problem() { # expect_problem <json> <substring> <label>
  local out
  printf '%s\n' "$1" >"$WORK/bad.json"
  out=$("$CLI" validate "$WORK/bad.json" 2>&1)
  total=$((total + 1))
  if [ -n "$out" ] && [ "${out#*"$2"}" != "$out" ]; then
    echo "ok    validate: $3"
  else
    echo "FAIL  validate: $3 (got '$out')"
    failures=$((failures + 1))
  fi
}
expect_problem '{"base_branch": "main"}' 'mode: required key is missing' 'mode is required'
expect_problem '{"mode": "yolo"}' 'is not one of integrated, discreet' 'mode is an enum'
expect_problem '{"mode": "discreet", "sensitive_paths": []}' 'sensitive_paths: unknown key' \
  'a key at the wrong level is caught'
expect_problem '{"mode": "discreet", "chekc": {}}' 'chekc: unknown key' 'a typo is caught'
expect_problem '{"mode": "discreet", "base_branch": 7}' 'expected string, got integer' 'types are checked'
expect_problem '{"mode": "discreet", "pr": {"max_lines": 0}}' 'below the minimum' 'minimum is checked'
expect_problem '{"mode": "discreet", "pr": {"title": "poetic"}}' 'is not one of conventional, free' \
  'nested enums are checked'
expect_problem '{"mode": "discreet", "db_hosts_allowed": "pg"}' 'expected array, got string' \
  'an array is not a string'
expect_problem '{"mode": "discreet", "merge": {"sensitive_patterns": [{"regex": "x", "exclude": "t"}]}}' \
  'expected array, got string' 'a pattern exclusion is a list of globs'
expect_problem '{"mode": "discreet", "merge": {"sensitive_patterns": [{"regex": "a"}, {"file": "b"}]}}' \
  'sensitive_patterns[1]/regex: required key is missing' 'the offending array item is named'
expect_problem '{"mode": "discreet", "commands": [{"allow_args": "x"}]}' \
  'commands[0]/cmd: required key is missing' 'a command needs its cmd'
expect_problem '{"mode": "discreet", "slots": {"developers": [{"a": 1}]}}' \
  'developers[0]: expected' 'slot items are scalars'
expect_problem '{"mode": "discreet", "slots": {"reviewer": [{"a": 1}]}}' \
  'reviewer[0]: expected' 'reviewer slot items are scalars'
expect_problem '{"mode": "discreet", "slots": {"reviewer": []}}' \
  'at least 1 required' 'a list of reviewer slots is not empty'
expect_problem '{"mode": "discreet", "slots": {"reviewer": true}}' \
  'expected ["string","integer","array"], got boolean' 'a reviewer slot is a value or a list'
# One reviewer slot or several: the single value predates the list and must stay valid.
for value in '9' '"r1"' '[8, 9]'; do
  printf '{"mode": "discreet", "slots": {"reviewer": %s}}\n' "$value" >"$WORK/reviewers.json"
  out=$("$CLI" validate "$WORK/reviewers.json" 2>&1)
  total=$((total + 1))
  if [ -z "$out" ]; then
    echo "ok    validate: slots.reviewer may be $value"
  else
    echo "FAIL  validate: slots.reviewer $value refused ('$out')"
    failures=$((failures + 1))
  fi
done
# Valid JSON that is not an object: the schema interpreter has the useful message, so
# validate must not flatten it to "not valid JSON".
for value in '[1,2]' '"hello"' '42' 'true' 'null'; do
  printf '%s\n' "$value" >"$WORK/bad.json"
  out=$("$CLI" validate "$WORK/bad.json" 2>&1)
  total=$((total + 1))
  case $out in
    *'expected object'*) echo "ok    validate: $value is reported as the wrong type" ;;
    *) echo "FAIL  validate: $value reported as '$out'"; failures=$((failures + 1)) ;;
  esac
done
for empty in '' '   '; do
  printf '%s' "$empty" >"$WORK/bad.json"
  out=$("$CLI" validate "$WORK/bad.json" 2>&1)
  total=$((total + 1))
  case $out in
    *'not valid JSON'*) echo "ok    validate: a file holding no JSON value is rejected" ;;
    *) echo "FAIL  validate: empty file reported as '$out'"; failures=$((failures + 1)) ;;
  esac
done

mkdir -p "$WORK/broken/.claude"
# A file holding two JSON values is what a `>>` where a `>` was meant leaves behind. Both
# readers must refuse it, and in the same direction: jq evaluates its program once per
# input value and -e reports on the last, so a naive object test calls this readable and
# get would then serve values out of a file validate rejects.
for pair in '{"a":1} {"b":2}' '{"a":1} [1,2]' '[1,2] {"a":1}' '{"a":1} {"a":1}'; do
  printf '%s\n' "$pair" >"$WORK/broken/.claude/workflow.json"
  rc 1 "two values ($pair): get refuses" -- "$CLI" -C "$WORK/broken" get a
  rc 1 "two values ($pair): get refuses a default too" -- "$CLI" -C "$WORK/broken" get a zzz
  rc 1 "two values ($pair): show refuses" -- "$CLI" -C "$WORK/broken" show
  eq discreet "$("$CLI" -C "$WORK/broken" mode)" "two values ($pair): mode stays discreet"
  printf '%s\n' "$pair" >"$WORK/bad.json"
  out=$("$CLI" validate "$WORK/bad.json" 2>&1)
  total=$((total + 1))
  case $out in
    *'not valid JSON'*) echo "ok    two values ($pair): validate refuses" ;;
    *) echo "FAIL  two values ($pair): validate said '$out'"; failures=$((failures + 1)) ;;
  esac
done
rm -rf "$WORK/broken/.claude"
mkdir -p "$WORK/broken/.claude"

# The property that matters, and the one three separate defects broke: every reader agrees
# on whether a file is a usable profile. Not "get serves nothing validate would reject" —
# that sentence is false on purpose, since `{"base_branch":"x"}` is a perfectly readable
# profile that the schema rejects, and gating `get` on the validator would make one typo'd
# key render a whole project inert.
#
# So this compares the readers against each other, and `mode` must answer `discreet`
# exactly when the others refuse, because `mode` is the one whose answer grants rights.
for content in '{"mode":"integrated"}' \
               '{"mode":"integrated"} {}' \
               '{"mode":"integrated"} null' \
               '{"mode":"integrated"} [1,2]' \
               '{"mode":"integrated"} 0' \
               '{"mode":"integrated"} {"base_branch":"x"}' \
               '{"mode":"integrated"} {,' \
               '{"mode":"discreet"} {}' \
               '{"base_branch":"x"}' \
               '[1,2]' '"hello"' '42' 'true' 'null' '' '   ' '{,'; do
  printf '%s' "$content" >"$WORK/broken/.claude/workflow.json"
  usable=no
  ola_profile_readable "$WORK/broken/.claude/workflow.json" && usable=yes
  got_mode=$("$CLI" -C "$WORK/broken" mode 2>/dev/null)
  # With a default, so that an absent key does not look like a refused file: that
  # distinction is the whole point of get's three statuses.
  get_ok=no
  "$CLI" -C "$WORK/broken" get mode zzz >/dev/null 2>&1 && get_ok=yes
  show_ok=no
  "$CLI" -C "$WORK/broken" show >/dev/null 2>&1 && show_ok=yes
  total=$((total + 1))
  if [ "$usable" = no ]; then
    if [ "$get_ok" = no ] && [ "$show_ok" = no ] && [ "$got_mode" = discreet ]; then
      echo "ok    readers agree it is unusable: $content"
    else
      echo "FAIL  readers disagree on an unusable profile (mode=$got_mode get=$get_ok show=$show_ok): $content"
      failures=$((failures + 1))
    fi
  elif [ "$get_ok" = yes ] && [ "$show_ok" = yes ]; then
    echo "ok    readers agree it is usable: $content"
  else
    echo "FAIL  readers disagree on a usable profile (get=$get_ok show=$show_ok): $content"
    failures=$((failures + 1))
  fi
done
rm -rf "$WORK/broken/.claude"

printf '%s' '{,' >"$WORK/bad.json"
total=$((total + 1))
if out=$("$CLI" validate "$WORK/bad.json" 2>&1); then
  echo "FAIL  validate: broken JSON should fail"
  failures=$((failures + 1))
else
  case $out in
    *"not valid JSON"*) echo "ok    validate: broken JSON is reported as such" ;;
    *) echo "FAIL  validate: broken JSON reported as '$out'"; failures=$((failures + 1)) ;;
  esac
fi
rc 1 "validate: a missing file fails" -- "$CLI" validate "$WORK/nope.json"
# `validate` with no argument validates the profile of the current project.
total=$((total + 1))
if ( cd "$WORK/integrated" && "$CLI" validate >/dev/null 2>&1 ); then
  echo "ok    validate: no argument validates the project's own profile"
else
  echo "FAIL  validate: no argument should validate the project's own profile"
  failures=$((failures + 1))
fi

# --- The schema itself ----------------------------------------------------------------
total=$((total + 1))
if jq -e '.["$schema"] and .properties.mode and (.required | index("mode"))' \
  "$ROOT/schema/profile.schema.json" >/dev/null 2>&1; then
  echo "ok    schema: parses and declares mode as required"
else
  echo "FAIL  schema: unexpected shape"
  failures=$((failures + 1))
fi
# Every key the schema allows must be documented, so `workflow-init` and humans can tell
# what a key is for without reading the guard.
undocumented=$(jq -r '[.properties | to_entries[]
  | select(.key != "$schema") | select(.value.description == null) | .key] | join(", ")' \
  "$ROOT/schema/profile.schema.json")
eq "" "$undocumented" "schema: every top-level key has a description"
# ola_profile_mode matches the two modes literally, for speed in the guard's hot path.
# This is the only rule stated twice, so it is pinned here: adding a mode to the schema
# must fail this test until the case in hooks/lib/profile.sh knows about it.
eq "integrated discreet" \
  "$(jq -r '.properties.mode.enum | join(" ")' "$ROOT/schema/profile.schema.json")" \
  "schema: the modes are exactly the ones ola_profile_mode accepts"

# --- The public accessor cannot be made to invent ------------------------------------
mkdir -p "$WORK/broken/.claude"
# The three-state primitive was collapsed by the first caller written after it existed, in
# two lines, and a truncated profile then announced a base branch the project did not have.
# So the policy moved into the name every caller reaches for first, and these assertions
# are what keeps it there: whatever the shape of the profile, ola_profile_get either
# prints a value the profile holds, prints a default the caller passed on purpose, or
# prints nothing at all.
for content in '' '   ' '{,' '[1,2]' '"hello"' '42' 'true' 'null' \
               '{"a":1} {"b":2}'; do
  printf '%s' "$content" >"$WORK/broken/.claude/workflow.json"
  out=$(ola_profile_get base_branch "$WORK/broken" "" invented 2>/dev/null)
  status=$?
  if [ "$status" != 0 ] && [ -z "$out" ]; then
    ok "unusable profile ($content): the accessor invents nothing, default or not"
  else
    ko "unusable profile ($content): the accessor printed '$out' with status $status"
  fi
done

# And on a readable profile the default is honoured — otherwise the assertion above would
# pass by the accessor never working at all.
printf '%s\n' '{"mode":"discreet"}' >"$WORK/broken/.claude/workflow.json"
eq invented "$(ola_profile_get base_branch "$WORK/broken" "" invented)" \
  "witness: a readable profile does honour a default"
eq discreet "$(ola_profile_get mode "$WORK/broken" "" invented)" \
  "witness: and a present key wins over the default"
rc 1 "a readable profile with no default prints nothing" -- \
  ola_profile_get base_branch "$WORK/broken"

# {slot} applies to a default too: a default is a value like any other.
eq "port 7" "$(ola_profile_get nope "$WORK/broken" 7 'port {slot}')" \
  "a default gets its {slot} substituted"

# ola_profile_has answers presence, which is what a caller needs to say "this value is
# mine, not the project's".
if ola_profile_has mode "$WORK/broken" && ! ola_profile_has base_branch "$WORK/broken"; then
  ok "ola_profile_has separates a present key from an absent one"
else
  ko "ola_profile_has does not separate present from absent"
fi
rm -rf "$WORK/broken/.claude"
mkdir -p "$WORK/broken/.claude"

# The behavioural guarantee, which no spelling can evade: on a profile nobody can parse,
# no CLI prints a value and none exits 0. The grep below catches one spelling of the
# collapse and is a smell detector; this is the invariant.
printf '%s' '{"mode":"integrated","base_branch":"trunk",,,' \
  >"$WORK/broken/.claude/workflow.json"
# Only the commands that serve a value **out of** the profile. `mode` and `path` are
# diagnostics and must answer: `mode` falls back to discreet, the restrictive side, and
# `path` says which file is in use, not whether it is sound. Asserting silence from them
# would be asserting against the fail-safe this invariant exists to protect.
for cli in "$ROOT/bin"/*; do
  name=${cli##*/}
  for args in "show" "get base_branch" "get base_branch invented" "get merge.required_checks"; do
    # shellcheck disable=SC2086  # args is a deliberate word list
    out=$("$cli" -C "$WORK/broken" $args 2>/dev/null)
    status=$?
    if [ "$status" != 0 ] && [ -z "$out" ]; then
      ok "$name $args: a truncated profile yields nothing, with a non-zero status"
    else
      ko "$name $args: printed '$out' with status $status on a truncated profile"
    fi
  done
done
# And the diagnostics do answer, on the restrictive side: that is the other half of the
# invariant, and asserting only silence would let a CLI that answers nothing at all pass.
eq discreet "$("$CLI" -C "$WORK/broken" mode)" \
  "a truncated profile still reports the restrictive mode"
eq "$WORK/broken/.claude/workflow.json" "$("$CLI" -C "$WORK/broken" path)" \
  "and path still says which file is in use"

# The witness: the same calls do work on a sound profile, or the loop above would pass by
# the CLIs being broken outright.
printf '%s\n' '{"mode":"integrated","base_branch":"trunk"}' \
  >"$WORK/broken/.claude/workflow.json"
eq trunk "$("$CLI" -C "$WORK/broken" get base_branch)" \
  "witness: the same call works on a sound profile"
printf '%s' '{"mode":"integrated","base_branch":"trunk",,,' \
  >"$WORK/broken/.claude/workflow.json"

# No caller may re-implement the policy: a `case` on the accessor's status is how it was
# collapsed, and the primitive carries the long name so that reaching for it is a choice.
# shellcheck disable=SC2016  # the $ is part of the pattern being searched for
collapsers=$(grep -lE 'case \$(status|\?) in' "$ROOT/bin"/* 2>/dev/null |
  sed 's#.*/##' | tr '\n' ' ')
if [ -z "$collapsers" ]; then
  ok "no CLI re-implements the default policy with a status case"
else
  ko "the default policy is decided again in: $collapsers"
fi

# --- A broken jq program is not an answer --------------------------------------------
# The library signals "no such key" and "unusable profile" with halt_error codes chosen to
# stay clear of jq's own: 3 is a compile error and 4 is `-e` with no output. If a signal
# shared a code, a typo in the program would be read as an answer — and `get` is the one
# reader that turns an answer into "use the caller's default", so the default would be
# served on a perfectly good profile. This pins it by breaking the gate on purpose.
# A probe script rather than a composed `bash -c` string: the gate holds quotes of its own,
# and three levels of escaping is how a test ends up proving nothing.
cat >"$WORK/gate-probe.sh" <<'PROBE'
#!/usr/bin/env bash
. "$1"
OLA_PROFILE_GATE=$2
ola_profile_get base_branch "$3" >/dev/null 2>&1
echo $?
PROBE
chmod +x "$WORK/gate-probe.sh"

get_status_with_gate() { # get_status_with_gate <gate program>
  "$WORK/gate-probe.sh" "$ROOT/hooks/lib/profile.sh" "$1" "$WORK/integrated"
}

# The control comes first, because without it the assertion below passes whenever `get`
# returns 1 — including if the fixture held no profile at all. That is the same way a test
# can pass for the wrong reason as a test whose name is false.
total=$((total + 1))
intact=$(get_status_with_gate "$OLA_PROFILE_GATE")
if [ "$intact" = 0 ]; then
  echo "ok    control: the fixture is read successfully with the gate intact"
else
  echo "FAIL  control: the fixture is wrong, get returned $intact with an intact gate"
  failures=$((failures + 1))
fi

total=$((total + 1))
broken=$(get_status_with_gate 'this is not jq')
if [ "$broken" = 1 ]; then
  echo "ok    a non-compiling gate reads as unusable, not as an absent key"
else
  echo "FAIL  a non-compiling gate returned $broken, which get would treat as an absent key"
  failures=$((failures + 1))
fi

# --- The remote is only looked up when a discreet profile could exist -----------------
# The guard of A3 runs this resolution on every PreToolUse, so the cost is part of the
# contract: resolving a remote takes three subprocesses, and someone who has never written
# a discreet profile must not pay them. A git that records its calls pins both directions.
stub=$WORK/stub
mkdir -p "$stub"
# shellcheck disable=SC2016  # $* and $@ belong to the stub being written, not to here
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$GIT_CALL_LOG"\nexec %s "$@"\n' \
  "$(command -v git)" >"$stub/git"
chmod +x "$stub/git"

git_calls() { # git_calls <home> → the remote lookups made while resolving the mode
  local log=$WORK/git-calls.log
  : >"$log"
  env "HOME=$1" "GIT_CALL_LOG=$log" "PATH=$stub:$PATH" \
    "$CLI" -C "$WORK/integrated" mode >/dev/null 2>&1
  grep -c 'remote get-url' "$log" | tr -d ' '
}

mkdir -p "$WORK/home-without-profiles"
eq 0 "$(git_calls "$WORK/home-without-profiles")" \
  "cost: no profiles directory, no remote lookup"
eq integrated "$(HOME=$WORK/home-without-profiles "$CLI" -C "$WORK/integrated" mode)" \
  "cost: and the project profile still resolves"
# Two, not one: upstream is tried before origin, so a repository without a fork remote
# pays the miss as well. Its own fixture home, so the count cannot drift with what earlier
# tests happened to create.
mkdir -p "$WORK/home-with-profiles/.claude/workflow-profiles"
eq 2 "$(git_calls "$WORK/home-with-profiles")" \
  "cost: a profiles directory costs the upstream and origin lookups"

# --- The glob dialect the schema promises ---------------------------------------------
# The schema tells profile authors how its globs behave. That is prose, and prose has no
# counter-proof — except when it describes a tool, which is testable. It is worth testing
# because the first version of that sentence was wrong: it equated `:(glob)` with
# .gitignore, which matches a slash-less pattern at any depth while a pathspec is anchored
# at the repository root. Nobody writes pathspec magic and everybody has written a
# .gitignore, so the wrong analogy was the one that would have been believed.
globrepo=$WORK/globs
mkdir -p "$globrepo/src/deep"
git -C "$globrepo" -c init.defaultBranch=main init -q 2>/dev/null
touch "$globrepo/Dockerfile" "$globrepo/src/deep/Dockerfile" "$globrepo/src/deep/a.ts"
git -C "$globrepo" add -A 2>/dev/null

glob_match() { git -C "$globrepo" ls-files -- ":(glob)$1" | tr '\n' ' '; }
eq "Dockerfile " "$(glob_match 'Dockerfile*')" \
  "dialect: a pattern with no slash is anchored at the root"
# The counter-proof of the claim itself: gitignore does what the first sentence promised,
# and that is precisely why the analogy was misleading.
eq "Dockerfile src/deep/Dockerfile " \
  "$(printf 'Dockerfile*\n' >"$globrepo/.gitignore"
    for f in Dockerfile src/deep/Dockerfile; do
      git -C "$globrepo" check-ignore --no-index -q "$f" && printf '%s ' "$f"
    done
    rm -f "$globrepo/.gitignore")" \
  "dialect: the same pattern in a .gitignore does match at any depth"
eq "Dockerfile src/deep/Dockerfile " "$(glob_match '**/Dockerfile*')" \
  "dialect: ** reaches every level"
eq "src/deep/a.ts " "$(glob_match 'src/**/*.ts')" "dialect: ** crosses a slash"
eq "" "$(glob_match 'src/*.ts')" "dialect: a single * does not cross a slash"
# The clause says no wildcard crosses a slash, so the test says it of each wildcard and
# not only of the one that was easy to check.
touch "$globrepo/src/deep/b.ts"
mkdir -p "$globrepo/Dockerfiles"
touch "$globrepo/Dockerfiles/one"
git -C "$globrepo" add -A 2>/dev/null
# "Does not cross a slash" means the wildcard cannot consume the `/` itself, not that it
# cannot appear in a path with slashes. The first version of these two asserted the second
# reading and failed, which is the test doing its job on its author.
eq "" "$(glob_match 'src?deep/a.ts')" "dialect: ? cannot consume a slash"
eq "" "$(glob_match 'src[/]deep/a.ts')" "dialect: nor can a character class"
eq "" "$(glob_match 'src*deep/a.ts')" "dialect: nor can a single *"
# One witness per negative assertion, each asserting a non-empty value: an `eq ""` control
# would witness nothing, since that is what the absence of everything produces too. Three
# assertions, three witnesses — "each wildcard" has to mean each of the three, or the
# comment promises more than the block checks.
eq "src/deep/a.ts " "$(glob_match 'src/dee?/a.ts')" "dialect: witness, ? works within a component"
eq "src/deep/a.ts " "$(glob_match 'src/[d]eep/a.ts')" "dialect: witness, a class works within a component"
eq "src/deep/a.ts " "$(glob_match 'src/*eep/a.ts')" "dialect: witness, * works within a component"
# And a wildcard never recurses on a directory name, which is what keeps the sentence's
# own example honest: Dockerfile* must not reach into a neighbouring Dockerfiles/.
eq "Dockerfile " "$(glob_match 'Dockerfile*')" \
  "dialect: a wildcard does not recurse into a directory it would match"
eq "" "$(glob_match 'Dockerfile?')" "dialect: nor with ?"
# Three patterns that look alike and reach three depths. The anchoring example above
# teaches "no slash means the top only", which a bare directory name contradicts.
mkdir -p "$globrepo/docs/a"
touch "$globrepo/docs/x.md" "$globrepo/docs/a/y.md"
git -C "$globrepo" add -A 2>/dev/null
eq "docs/a/y.md docs/x.md " "$(glob_match 'docs')" "dialect: a bare directory name is recursive"
eq "docs/x.md " "$(glob_match 'docs/*')" "dialect: one level under a directory"
# A leading ! is not a negation: it matches nothing, and says nothing about it. An entry
# written that way would protect exactly nothing.
eq "" "$(glob_match '!docs/**')" "dialect: a leading ! matches nothing, silently"

# The behaviours above pin git. These pin the sentence, and they are worth exactly what
# they claim and no more.
#
# The reviewer mutation-tested the first version of this block: inverting the description
# to say the opposite ("— like a .gitignore rule — a pattern with no slash is **not**
# anchored…") left all of its assertions passing, because `anchored at the` survives
# inside `not anchored at the` — it contains its own negation. Dropping a two-letter
# prefix while simplifying a caveat is the most ordinary rewrite there is.
#
# So the claim is anchored on the word that carries its polarity, which fails on that
# inversion. The honest limit: no assertion over prose is paraphrase-proof — "a .gitignore
# rule, by contrast, matches at any depth" would be true without containing "unlike". The
# reachable goal is to make an inversion noisy, not to prove a sentence true.
dialect=$(jq -r '.description' "$ROOT/schema/profile.schema.json")
total=$((total + 1))
case $dialect in
  *'unlike a .gitignore'*) echo "ok    dialect: the description still contrasts with .gitignore" ;;
  *) echo "FAIL  dialect: the contrast with .gitignore is gone, so the rule may have been inverted"
     failures=$((failures + 1)) ;;
esac

# A deletion canary, which is all this is: it answers "has someone removed the rule?",
# never "is the rule right?".
for claim in ':(glob)' 'no wildcard crosses' '**/Dockerfile*' 'named literally' 'never with a' 'README: Globs'; do
  total=$((total + 1))
  case $dialect in
    *"$claim"*) echo "ok    canary: the description still mentions '$claim'" ;;
    *) echo "FAIL  canary: the description no longer mentions '$claim'"
       failures=$((failures + 1)) ;;
  esac
done

# --- `where` and `path` agree on the layout -------------------------------------------
# The layout "a user profile lives at ~/.claude/workflow-profiles/<id>/profile.json" is
# written in two functions: the one that resolves an existing profile, and the one that says
# where a new one would go. Two copies are how an init command writes a file to a path the
# resolver does not read — the profile would be created, reported as created, and never
# applied.
#
# The first version of this block asserted membership, which is insensitive to order: with
# the two halves of `ola_profile_candidates` swapped, the whole suite stayed green although
# the function then announced the repository's file as the winner. And it borrowed another
# section's fixture to cover "both candidates present", a fixture whose repository half had
# been removed 500 lines earlier — so the case it claimed to test did not exist. Both are
# fixed the same way: the precedence is asserted as an order, on a fixture built here for it.
BOTH=$WORK/both
mkrepo "$BOTH" "https://github.com/someone/both.git"
mkdir -p "$BOTH/.claude"
printf '%s\n' '{"mode": "integrated", "base_branch": "from-project"}' >"$BOTH/.claude/workflow.json"
user_profile "github.com/someone/both" '{"mode": "discreet", "base_branch": "from-user"}'

listed=$("$CLI" -C "$BOTH" where)
eq 2 "$(printf '%s\n' "$listed" | grep -c .)" "witness: both candidates exist, so the order is testable"
eq from-user "$("$CLI" -C "$BOTH" get base_branch)" "witness: and the user profile is the one in use"
eq "$("$CLI" -C "$BOTH" path)" "$(printf '%s\n' "$listed" | sed -n '1s/^[a-z]* //p')" \
  "where lists the winning candidate first, so the order carries the precedence"
eq "user" "$(printf '%s\n' "$listed" | sed -n '1s/ .*//p')" "where names the scope that wins"

# The round trip, in the direction an init command uses it: write where `where` says, and
# `path` must find it. Nothing else proves the two agree about a file that does not exist
# yet, which is the only moment the question is asked.
for scope in user project; do
  repo=$WORK/rt-$scope
  mkrepo "$repo" "https://github.com/someone/rt-$scope.git"
  target=$("$CLI" -C "$repo" where "$scope")
  mkdir -p "${target%/*}"
  printf '%s\n' '{"mode": "discreet", "base_branch": "round-trip"}' >"$target"
  eq "$target" "$("$CLI" -C "$repo" path)" "round trip: a profile written at \`where $scope\` is the one resolved"
  eq round-trip "$("$CLI" -C "$repo" get base_branch)" "round trip: and its values are the ones read"
done

# Every fixture this suite has built, as a second net: whatever `path` answers, `where` must
# have named. The witness counts the fixtures that *resolved*, not the ones that agreed —
# counting agreements means the number printed on failure is the number of passes, which is
# the one moment it has to be the number of fixtures.
resolved_count=0
agreed=0
for repo in "$WORK/integrated" "$WORK/discreet" "$WORK/fork" "$WORK/integrated-wt" \
            "$WORK/discreet-wt" "$BOTH"; do
  resolved=$("$CLI" -C "$repo" path 2>/dev/null) || continue
  resolved_count=$((resolved_count + 1))
  named=$("$CLI" -C "$repo" where 2>/dev/null | sed 's/^[a-z]* //')
  case $'\n'"$named"$'\n' in
    *$'\n'"$resolved"$'\n'*) agreed=$((agreed + 1)) ;;
    *) ko "${repo##*/}: path resolves $resolved, which where never names: $named" ;;
  esac
done
if [ "$resolved_count" -eq 6 ] && [ "$agreed" -eq 6 ]; then
  ok "where names the path path resolves, on all 6 fixtures"
else
  ko "$resolved_count of 6 fixtures resolved a profile and $agreed agreed — the net has holes"
fi

# Each scope answers on its own, because that is how a caller writing a file uses it: it
# has chosen a scope and wants one path, not a list to pick a line out of.
eq "$HOME/.claude/workflow-profiles/github.com/someone/their-repo/profile.json" \
  "$("$CLI" -C "$WORK/discreet" where user)" "where user: the path, scope stripped"
eq "$WORK/integrated/.claude/workflow.json" \
  "$("$CLI" -C "$WORK/integrated" where project)" "where project: the committed path"
# And it answers where no profile exists, which is the whole reason it exists: `path` is
# silent there, and something has to be able to create the first one.
mkrepo "$WORK/virgin" "https://github.com/acme/nothing.git"
eq "$HOME/.claude/workflow-profiles/github.com/acme/nothing/profile.json" \
  "$("$CLI" -C "$WORK/virgin" where user)" "where answers before any profile exists"
rc 1 "witness: and path answers nothing there" -- "$CLI" -C "$WORK/virgin" path

# A repository with no remote has no identity, so no user-scope path can be built — but it
# has a top level, so the committed one can. The scopes are independent, and the skill that
# writes the first profile depends on that: a fresh `git init` is the common case.
mkrepo "$WORK/no-remote" ""
rc 1 "where user: no remote, no identity, no user path" -- "$CLI" -C "$WORK/no-remote" where user
eq "$WORK/no-remote/.claude/workflow.json" \
  "$("$CLI" -C "$WORK/no-remote" where project)" "where project: works without a remote"

# Outside a repository there is no identity and no top level, so there is no candidate at
# all — and saying so with status 1 is this CLI's contract. Printing nothing, successfully,
# is the one answer a caller must never get.
mkdir -p "$WORK/not-a-repo"
rc 1 "where: no repository, no candidate, and it says so" -- "$CLI" -C "$WORK/not-a-repo" where
rc 1 "where user: the same, per scope" -- "$CLI" -C "$WORK/not-a-repo" where user
rc 2 "where: an unknown scope is a usage error" -- "$CLI" -C "$WORK/integrated" where sideways

# The schema the CLI validates against, so that whoever writes a profile can point an
# editor at it without restating where the plugin keeps it. It is not a value to put *in* a
# profile: the path holds the plugin version, so it is right on one machine until the next
# upgrade — which is why the skill writes no `$schema` key.
eq 0 "$("$CLI" schema >/dev/null 2>&1; echo $?)" "schema: answers"
if [ -f "$("$CLI" schema)" ] && jq -e '.properties.mode' "$("$CLI" schema)" >/dev/null 2>&1; then
  ok "schema: names a file that is the profile schema"
else
  ko "schema: names $("$CLI" schema), which is not the profile schema"
fi
rc 1 "schema: says so rather than naming a file that is not there" -- \
  env OLA_PROFILE_SCHEMA=/nonexistent/profile.schema.json "$CLI" schema

# --- Bad usage ------------------------------------------------------------------------
rc 2 "usage: no command" -- "$CLI"
rc 2 "usage: unknown command" -- "$CLI" frobnicate
rc 2 "usage: unknown option" -- "$CLI" --nope path
rc 2 "usage: get without a key" -- "$CLI" get
# These two used to spin forever: `shift 2` on a single argument shifts nothing.
rc 2 "usage: -C without a value" -- "$CLI" -C
rc 2 "usage: --slot without a value" -- "$CLI" --slot
rc 2 "usage: -C with an empty value" -- "$CLI" -C "" mode
rc 2 "usage: validate from a directory that does not exist" -- "$CLI" -C "$WORK/nope" validate

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total profile test(s) failed"
  exit 1
fi
echo "all $total profile tests passed"
