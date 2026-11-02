# GitHub refuses the merge and the status, by token

## Status

accepted

## Date

2026-10-19

## Context

Merging a pull request and writing a review status had to be reserved to one role each. A guard that read command lines did it, and it had to undo every spelling a shell accepts: each spelling it missed was a merge it let through, and 0.3.2 alone fixed fifty-seven of them.

## Decision

Every Bash command of a session runs with a base token that can neither merge nor write a commit status, and two exact commands run with a stronger token held by one role each.

## Consequences

A token has no spelling, so `gh pr merge`, `gh api`, `curl` and a script meet the same 403, and nothing is asked any more because a command could not be read. It takes three fine-grained tokens per human to create, and it does not stop an agent that reads the keychain itself, a push to the base branch (git uses the human's own credentials), or the merge gate's conditions: GitHub checks who merges, not whether the checks were green.

## Evidence

- [CHANGELOG, 0.4.0](../../CHANGELOG.md#040)
- [Pull request 51](https://github.com/olaurendeau/ola-workflow/pull/51)
- [README, GitHub tokens, at the commit the journal began](https://github.com/olaurendeau/ola-workflow/blob/936ff0996fbedb5e0d981e91030c9a63efdc00fd/README.md#L112-L158)
