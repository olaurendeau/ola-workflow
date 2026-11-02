# Only the coordinator declares the browser tools

## Status

accepted

## Date

2026-10-23

## Context

A session agent's tool list filters tools of connected servers exactly as it filters built-in ones, so a list naming no entry for the browser server left the browser unreachable in a session opened as the coordinator, even when it was connected.

## Decision

The coordinator declares the tools of the Chrome server in the form Claude Code documents for a whole server, and no other role declares any tool of a server.

## Consequences

A session keeps the browser the human connected to it. The other roles work in worktrees and have no browser to drive, and the suite holds both halves: the coordinator has the entry and every other workflow role has none.

## Evidence

- [CHANGELOG, 0.7.0](../../CHANGELOG.md#070)
- [Issue 68](https://github.com/olaurendeau/ola-workflow/issues/68) and [pull request 69](https://github.com/olaurendeau/ola-workflow/pull/69)
