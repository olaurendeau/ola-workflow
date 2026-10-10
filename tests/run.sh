#!/usr/bin/env bash
# Runs every tests/*.test.sh and sums up the verdicts.
# Needs bash, jq and perl only: it is the same run on the host (bash 3.2) and in CI.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

for tool in jq perl; do
  command -v "$tool" >/dev/null || { echo "tests need $tool on PATH" >&2; exit 2; }
done

failed=()
for suite in tests/*.test.sh; do
  [ -f "$suite" ] || continue
  echo "==> $suite"
  if "$suite"; then :; else failed+=("$suite"); fi
  echo
done

if [ "${#failed[@]}" -gt 0 ]; then
  printf 'failing suite: %s\n' "${failed[@]}" >&2
  exit 1
fi
echo "all suites passed"
