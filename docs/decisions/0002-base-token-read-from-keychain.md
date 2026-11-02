# The base token is read from the keychain at each command

## Status

accepted

## Date

2026-10-19

## Context

The session needs a base token on every Bash command, subagents included.

## Decision

The line that the session start appends to the environment file looks the base token up in the macOS keychain each time a command runs, and the token is never written to a file.

## Consequences

No token lies in a file of the project or of the profile directory. It works on macOS only, and the keychain is under the same user as the agents, so an agent that sets out to read it gets it.

## Evidence

- [CHANGELOG, 0.4.0](../../CHANGELOG.md#040)
- [Pull request 51](https://github.com/olaurendeau/ola-workflow/pull/51)
- [README, how it is wired, at the commit the journal began](https://github.com/olaurendeau/ola-workflow/blob/936ff0996fbedb5e0d981e91030c9a63efdc00fd/README.md#L139-L142)
- [README, macOS only, at the commit the journal began](https://github.com/olaurendeau/ola-workflow/blob/936ff0996fbedb5e0d981e91030c9a63efdc00fd/README.md#L162)
