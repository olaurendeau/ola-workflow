# The hook rewrites two command forms and lets everything else through

## Status

accepted

## Date

2026-10-19

## Context

A rewritten command is the one that permission rules are matched against, measured on Claude Code, so rewriting every command would turn every allowlisted one into a question.

## Decision

The elevation hook recognises two forms, each with one regular expression over a character set that holds no shell metacharacter, and every other command passes untouched.

## Consequences

The user's permission rules apply to every other command as written. A form the hook does not recognise runs with the base token and gets a 403, so a mistake costs a retry and never a merge: a right is lost, never gained. The coordinator has to write the merge command in its exact form, with the full 40-character SHA.

## Evidence

- [CHANGELOG, 0.4.0](../../CHANGELOG.md#040)
- [Pull request 51](https://github.com/olaurendeau/ola-workflow/pull/51)
- [README, how it is wired, at the commit the journal began](https://github.com/olaurendeau/ola-workflow/blob/936ff0996fbedb5e0d981e91030c9a63efdc00fd/README.md#L143-L153)
