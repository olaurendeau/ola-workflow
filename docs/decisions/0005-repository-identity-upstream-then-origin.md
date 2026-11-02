# A repository is known by its upstream, then its origin

## Status

accepted

## Date

2026-10-12

## Context

The user's profile directory is named after the repository, and a fork contributes to another repository than the one it was cloned from. A worktree has to resolve like the checkout it belongs to.

## Decision

The identity of a repository comes from the remote named upstream when there is one, and from the remote named origin otherwise.

## Consequences

A fork is known by the repository it contributes to, and a worktree resolves like its checkout. An IPv6 host keeps its address and loses its brackets, so two spellings of one address give two profile directories: a split, never a collision. A remote address carrying credentials has part of it read back into transcripts, so credentials belong in a credential helper.

## Evidence

- [Pull request 3](https://github.com/olaurendeau/ola-workflow/pull/3)
- [CHANGELOG, 0.2.0](../../CHANGELOG.md#020)
- [README, how a project is configured, at the commit the journal began](https://github.com/olaurendeau/ola-workflow/blob/936ff0996fbedb5e0d981e91030c9a63efdc00fd/README.md#L212-L233)
