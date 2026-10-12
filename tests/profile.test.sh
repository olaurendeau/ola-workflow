#!/usr/bin/env bash
# Profile resolution, reading and validation, against throwaway git repositories.
# Nothing here touches the network or the real HOME.
set -uo pipefail

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
WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ola-profile.XXXXXX")" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
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
  "check": {"full": "make check", "affected": "make check-affected SLOT={slot}", "cleanup": "make down-all"},
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
eq master "$("$CLI" -C "$WORK/integrated" get base_branch fallback)" "get: default unused when set"
eq "ios-simulator" "$(cd "$WORK/integrated" && "$CLI" get verify_ui.kind)" "get: without -C, from the cwd"

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
expect_problem '{"mode": "discreet", "merge": {"sensitive_patterns": [{"regex": "a"}, {"file": "b"}]}}' \
  'sensitive_patterns[1]/regex: required key is missing' 'the offending array item is named'
expect_problem '{"mode": "discreet", "commands": [{"allow_args": "x"}]}' \
  'commands[0]/cmd: required key is missing' 'a command needs its cmd'
expect_problem '{"mode": "discreet", "slots": {"developers": [{"a": 1}]}}' \
  'developers[0]: expected' 'slot items are scalars'
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
