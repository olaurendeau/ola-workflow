# ola-workflow

A team of Claude Code agents — a coordinator, a product designer, an architect, developers
working in isolated worktrees, and an independent PR reviewer — plus a `PreToolUse` guard
that keeps every sensitive command with the role that owns it.

The workflow is **generic**: everything project-specific lives in a profile file, so the
same plugin drives a project you own and a repository you contribute to twice a year
**without committing anything to it**.

## Install

```
/plugin install ola-workflow --marketplace olaurendeau/ola-workflow
```

or, from a shell:

```bash
claude plugin install ola-workflow --marketplace olaurendeau/ola-workflow
```

User scope is the default, which is what you want: install once, use everywhere.

## Status

Early. This is the A1 skeleton: the manifests, the CI, the test harness, and the answer to
how a plugin agent is identified (see [Agent identity](#agent-identity)). The guard is
**inert** — it allows everything — and `probe` is the only agent. Coming next:

| step | content |
|---|---|
| A2 | the project profile: JSON schema, resolution, `ola-profile` CLI |
| A3 | the real guard, ported from `mcp-camptocamp` and driven by the profile |
| A4 | the conditional merge gate |
| A5 | the five workflow agents |
| A6 | the `workflow-init` and `verify-ui` skills, then 1.0.0 |

## How a project is configured

The plugin does nothing until it finds a profile. It looks in two places, in order:

1. `<project>/.claude/workflow.json` — **integrated** mode, committed with the project;
2. `~/.claude/workflow-profiles/<host>/<owner>/<repo>/profile.json` — **discreet** mode,
   nothing in the project at all. The identity comes from
   `git remote get-url upstream || git remote get-url origin`, so it works from worktrees
   too.

No profile means no effect: the hook exits 0 and the agents offer to run
`/ola-workflow:workflow-init`.

|  | integrated | discreet |
|---|---|---|
| Memory | GitHub issues, labels, a review commit status, review comments | local files under the profile directory |
| Conventions | the profile, plus the project's own CONTRIBUTING | read from the project: CONTRIBUTING, PR template, commit language |
| Writes to GitHub | allowed, per role | issues, labels, comments, statuses: **refused**. `git push` and `gh pr create`: **ask** (a human confirms) |
| Merge | the coordinator, through the merge gate | nobody |

## Agent identity

<!-- spike:begin -->
Measured by `make spike` — see [`scripts/spike/agent-identity.sh`](scripts/spike/agent-identity.sh).
<!-- spike:end -->

## Development

```bash
make check     # everything the CI runs: lint, test, validate
make lint      # shellcheck, in its own container (nothing to install)
make test      # the bash suites: tests/run.sh
make validate  # claude plugin validate --strict .
make spike     # replays the agent-identity spike
```

The test suites fake `PreToolUse` payloads and never execute the commands they contain.
They need `bash`, `jq` and `perl` only, and run identically on macOS (bash 3.2) and on CI.
