#!/usr/bin/env bash
# Runs every tests/*.test.sh and sums up the verdicts.
# Needs bash, jq and perl only: it is the same run on the host (bash 3.2) and in CI.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

for tool in jq perl; do
  command -v "$tool" >/dev/null || { echo "tests need $tool on PATH" >&2; exit 2; }
done

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
# `ok()` and `ko()` count the assertion themselves, so a `total=$((total + 1))` beside a call
# to either counts it twice. Only a block printing its own line with a bare `echo` increments
# by hand. The suites announced 87 assertions they never ran — and a test count is read, by
# whoever decides whether a change is covered, and quoted in every pull request this project
# opens. It was wrong and nothing was looking, so now something is.
note() { # note <suite> <message> — fails the suite once, however many things are wrong
  echo "  !! $1 $2" >&2
  case " ${failed[*]-} " in
    *" $1 "*) ;;
    *) failed+=("$1") ;;
  esac
}

failed=()
for suite in tests/*.test.sh; do
  [ -f "$suite" ] || continue
  echo "==> $suite"
  out=$("$suite") || status=$?
  status=${status:-0}
  printf '%s\n' "$out"
  if [ "$status" -ge 2 ]; then
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
