# Who approves each step is a key of the profile

## Status

accepted

## Date

2026-11-27

## Context

Which steps stop for the human was written in the plugin: the human validates a design, an architecture, a merge on a sensitive path and a release, or none of them, for every project alike. A project that trusts the design-reviewer, or that wants a human on every merge, had no way to say so, and `merge.sensitive_*` said it only for the merge.

## Decision

The `approval` key of the profile says who approves each step: `design`, `architecture`, `merge` and `release`, each `human` or `agent`, and `merge` also `{ "human_when": { "paths", "patterns" } }`. A profile without the key keeps the brief it had, byte for byte. A step the profile omits takes the default of a profile without the key, and a value the schema refuses is read as the most restrictive one, as an unknown mode is read as discreet. `approval.merge`, in any form, beside `merge.sensitive_paths` or `merge.sensitive_patterns` is a schema error, not a silent precedence. The words are the brief's, and no prompt names the key.

## Consequences

The schema now holds a conflict between two keys, which is why the validator reads `oneOf`, `if`/`then`, `not` and `errorMessage`. A refused value is announced by the brief and read as the restrictive one, while `ola-profile validate` exits 1 with the message of the step. The steps themselves, the release command of the hook and the coordinator's stops arrive in later pull requests of the same epic.

## Evidence

- [Epic 229](https://github.com/olaurendeau/ola-workflow/issues/229)
- [Task 234](https://github.com/olaurendeau/ola-workflow/issues/234)
