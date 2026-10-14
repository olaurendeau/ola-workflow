#!/usr/bin/env bash
# Runs every tests/*.test.sh and sums up the verdicts.
# Needs bash, jq, perl and git only — the suites build throwaway repositories — and it is
# the same run on the host (bash 3.2) and in CI. The preflight below refuses up front when
# one is missing; it named only jq and perl for a while, ten lines above the loop that
# already checked git.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# git included, because the suites build throwaway repositories: without it they do not
# skip, they fail 121 times naming the wrong cause ("the integrated brief is empty"). A
# missing dependency has to be named as one, which is what this preflight is for — and the
# README said bash, jq and perl only, which was wrong in the same place.
missing=""
for tool in jq perl git; do
  command -v "$tool" >/dev/null || missing="$missing $tool"
done
# All of them, not the first: naming one at a time means one run per missing tool, and the
# point of a preflight is to say what is needed in one go.
[ -z "$missing" ] || { echo "tests need these on PATH:$missing" >&2; exit 2; }

# hooks/lib/profile.sh uses limit/2 and halt_error/1, both jq 1.5 and later.
# Anchored rather than `jq-1.[0-4]*`, which would also reject a future jq-1.10: the same
# one-notch-too-greedy pattern that refused every IPv6 address earlier in this branch.
case $(jq --version 2>/dev/null) in
  jq-1.[0-4]|jq-1.[0-4].*|jq-1.[0-4]-*|jq-1.[0-4]rc*|jq-0*)
    echo "tests need jq >= 1.5 for limit/2 and halt_error/1, found $(jq --version)" >&2
    exit 2
    ;;
esac

# One convention across the suites, and it was broken in two of them for a long time:
# `ok()` and `ko()` count the assertion themselves, so a `total=$((total + 1))` beside a
# call to either counts it twice. Only a block printing its own line with a bare `echo`
# increments by hand. The suites announced 87 assertions they never ran — and a test count
# is read, by whoever decides whether a change is covered, and quoted in every pull request
# this project opens. It was wrong, and nothing was looking, so now something is: the number
# each suite announces has to be the number of verdicts it printed.
failed=()
note() { # note <suite> <message> — fails the suite once, however many things are wrong
  echo "  !! $1 $2" >&2
  case " ${failed[*]-} " in
    *" $1 "*) ;;
    *) failed+=("$1") ;;
  esac
}

for suite in tests/*.test.sh; do
  [ -f "$suite" ] || continue
  echo "==> $suite"
  # stdout is captured for counting and stderr goes straight through, because folding them
  # together puts a stray stderr line into the counted stream and stops the suite's own
  # error messages from arriving as they happen.
  out=$("$suite") || status=$?
  status=${status:-0}
  printf '%s\n' "$out"
  if [ "$status" -ge 2 ]; then
    # A suite that could not run at all (a missing dependency exits 2) has nothing to count,
    # and saying "announced no count" about it would name the wrong cause.
    note "$suite" "could not run (exit $status)"
    echo
    unset status
    continue
  fi
  [ "$status" = 0 ] || note "$suite" "reported failing assertions"
  announced=$(printf '%s\n' "$out" | sed -n 's/^all \([0-9]*\) .*passed$/\1/p;s/^\([0-9]*\) of \([0-9]*\) .*failed$/\2/p' | tail -1)
  printed=$(printf '%s\n' "$out" | grep -cE '^(ok|FAIL) ')
  if [ -z "$announced" ]; then
    note "$suite" "announced no count at all"
  elif [ "$announced" != "$printed" ]; then
    note "$suite" "announces $announced assertions and printed $printed"
  fi
  unset status
  echo
done

if [ "${#failed[@]}" -gt 0 ]; then
  printf 'failing suite: %s\n' "${failed[@]}" >&2
  exit 1
fi
echo "all suites passed"
