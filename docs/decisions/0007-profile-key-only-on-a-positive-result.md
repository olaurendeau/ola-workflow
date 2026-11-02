# A profile key is written only on a positive result

## Status

accepted

## Date

2026-10-14

## Context

The skill that writes a profile can detect some things about a repository and not others. An omitted key reads as not declared in the brief, which an agent treats as a question for the human. An invented key reads as the project's own rule, such as a check command nobody runs, enforced by a reviewer against a developer.

## Decision

The skill writes a key only when it has detected or been told the value, and leaves out every key it cannot establish.

## Consequences

A wrong guess is never taken for a rule, and an unknown stays a question for the human. The slots, the pull request limits, the merge conditions, the commands, the allowed databases, the visual checks and the preview are not detectable at all and are left out unless the human states them.

## Evidence

- [CHANGELOG, 0.3.0](../../CHANGELOG.md#030)
- [Pull request 26](https://github.com/olaurendeau/ola-workflow/pull/26)
- [README, writing the first profile, at the commit the journal began](https://github.com/olaurendeau/ola-workflow/blob/936ff0996fbedb5e0d981e91030c9a63efdc00fd/README.md#L249-L254)
