# Every glob of a profile is a git pathspec

## Status

accepted

## Date

2026-10-12

## Context

A profile holds globs for the lines a pull request counts, the sensitive paths and the security review, and a shell `case` that re-implements the dialect would silently widen an exclusion, which removes coverage: the one direction that matters.

## Decision

Every glob in a profile is a git pathspec with the glob magic, and the matching is left to git inside the command that already counts the lines.

## Consequences

One dialect is documented once, in the schema, for whoever writes a glob. A directory named literally is recursive and a wildcard is not, so `docs` takes its subtree and `doc*` matches `doc1.md` but does not reach into `docs/`. Every key that consumes a glob has to be implemented through git and not through the shell.

## Evidence

- [Pull request 14](https://github.com/olaurendeau/ola-workflow/pull/14)
- [README, globs, at the commit the journal began](https://github.com/olaurendeau/ola-workflow/blob/936ff0996fbedb5e0d981e91030c9a63efdc00fd/README.md#L337-L350)
