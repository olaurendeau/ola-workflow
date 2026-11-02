# The user's profile wins over the repository's, even unreadable

## Status

accepted

## Date

2026-10-12

## Context

A profile can sit in the user's own directory or be committed with the project, and the two are not equally trusted. A third-party repository must not be able to turn the discreet profile the user chose for it into an integrated one, and so grant itself writes to the forge and allowances on commands.

## Decision

The profile in the user's own directory is the one in force when it exists, including when it is corrupt, empty or not a file, in which case the resolution gives up rather than handing the last word back to the repository.

## Consequences

The trust follows who owns the file. The pairing of discreet with the user's profile and integrated with the committed one is a habit and not a rule: the `mode` key is what is read, whichever file holds it.

## Evidence

- [CHANGELOG, 0.2.0](../../CHANGELOG.md#020)
- [Pull request 3](https://github.com/olaurendeau/ola-workflow/pull/3), hardened by [pull request 5](https://github.com/olaurendeau/ola-workflow/pull/5)
- [README, how a project is configured, at the commit the journal began](https://github.com/olaurendeau/ola-workflow/blob/936ff0996fbedb5e0d981e91030c9a63efdc00fd/README.md#L218-L226)
