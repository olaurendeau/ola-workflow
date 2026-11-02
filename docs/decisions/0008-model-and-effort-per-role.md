# Each role pins its model and effort: Opus for judgement, Sonnet for volume

## Status

accepted

## Date

2026-10-21

## Context

Two agents out of seven pinned a model and the other five ran on whatever the session was set to. Since 0.5.0 runs one reviewer per slot, that meant two of the most expensive reviews at a time on every new head SHA.

## Decision

A role pins Opus where a wrong judgement costs a whole cycle and Sonnet where the volume is, the three heaviest roles pin a high effort as a ceiling, and the coordinator pins nothing.

## Consequences

The cost follows where judgement is needed and not the session's setting. The coordinator is the session agent, so a key there would be ignored or would override the human's choice, and the model variable of the environment no longer reaches a role that pins one. No saving is claimed: a number that has to be true belongs to something that recomputes it, and nothing here does. The suite keeps the table as a map and fails a role by name when it drifts.

## Evidence

- [CHANGELOG, 0.6.0](../../CHANGELOG.md#060)
- [Pull request 59](https://github.com/olaurendeau/ola-workflow/pull/59)
- [README, what each agent runs on, at the commit the journal began](https://github.com/olaurendeau/ola-workflow/blob/936ff0996fbedb5e0d981e91030c9a63efdc00fd/README.md#L79-L110)
