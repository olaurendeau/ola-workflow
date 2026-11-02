# A plugin agent's identity and effort are measured, not read

## Status

accepted

## Date

2026-10-10

## Context

The documentation does not say what a hook receives from a plugin agent, whether a frontmatter effort reaches it, or which name resolves, and the hooks, the default session agent and the per-role models all depend on it.

## Decision

What a plugin agent is called in a hook payload and which effort it runs at are measured by a replayable spike, and the version of Claude Code and the date are written beside the result.

## Consequences

The agent type is always the namespaced name, a subagent is told from a session agent by its identifier, and a frontmatter effort reaches a subagent only. The model cannot be measured this way because no payload field carries it, so that column is read from the documentation. None of it is contractual: the spike is run again after an upgrade of Claude Code.

## Evidence

- Measured on Claude Code 2.1.305, 2026-10-20, with the eight scenarios of the spike script
- [CHANGELOG, 0.1.0](../../CHANGELOG.md#010) and [CHANGELOG, 0.6.0](../../CHANGELOG.md#060)
- [Pull request 59](https://github.com/olaurendeau/ola-workflow/pull/59)
- [README, agent identity, at the commit the journal began](https://github.com/olaurendeau/ola-workflow/blob/936ff0996fbedb5e0d981e91030c9a63efdc00fd/README.md#L354-L421)
