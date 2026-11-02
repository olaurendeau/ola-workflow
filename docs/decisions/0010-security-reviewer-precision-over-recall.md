# The security reviewer favours precision, and every blocking finding is read cold

## Status

accepted

## Date

2026-10-21

## Context

A false positive from a security review costs a developer a whole review cycle, and until then security was one line of the pull request reviewer's checklist.

## Decision

A security finding blocks only when it is a complete path introduced by the change and proven line by line at medium severity or above, and each blocking finding stays pending until a second reviewer in a fresh context has tried to refute it.

## Consequences

What the reviewer cannot prove is counted and not reported, and a proven finding that predates the change becomes a suggestion for a follow-up. A false positive that the human rules on becomes a precedent read from the base branch, so a change cannot excuse itself. It costs a second dispatch per blocking finding, and its verdict is advice that the coordinator relays: no status is written and the merge gate does not read it.

## Evidence

- [CHANGELOG, 0.6.0](../../CHANGELOG.md#060)
- [Pull request 60](https://github.com/olaurendeau/ola-workflow/pull/60)
