# One brief, printed by a command, for every agent

## Status

accepted

## Date

2026-10-12

## Context

Seven prompts restating the same facts drift apart one justified edit at a time: a base branch, a check command, a review status or a slot value would end up written in several places and right in some.

## Decision

Every agent starts by running one command that prints the rules resolved from the profile, and no prompt names a base branch, a check command, a review status, a slot value or a line budget.

## Consequences

A rule changes in one place and every role reads it. A prompt holds only what is specific to its role, the suite refuses an agent that hard-codes one of those values, and the brief refuses outright rather than inventing a configuration when it has none.

## Evidence

- [CHANGELOG, 0.2.0](../../CHANGELOG.md#020)
- [Pull request 18](https://github.com/olaurendeau/ola-workflow/pull/18)
- [README, where the rules live, at the commit the journal began](https://github.com/olaurendeau/ola-workflow/blob/936ff0996fbedb5e0d981e91030c9a63efdc00fd/README.md#L195-L204)
