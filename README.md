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
Two things the documentation does not say, and that both the guard and the default session
agent depend on. Measured with `make spike` on **Claude Code 2.1.296**, 2026-10-10:

| scenario | `agent_type` | `agent_id` |
|---|---|---|
| main session, no agent | *absent* | *absent* |
| subagent, `subagent_type: ola-workflow:probe` | `ola-workflow:probe` | present |
| subagent, `subagent_type: probe` | — the call fails, see below | — |
| `--agent ola-workflow:probe` | `ola-workflow:probe` | *absent* |
| `--agent probe` | `ola-workflow:probe` | *absent* |
| `"agent"` passed with `--settings` | `ola-workflow:probe` | *absent* |
| `"agent"` in a project's `.claude/settings.json` | `ola-workflow:probe` | *absent* |

What this means:

- **`agent_type` is always the namespaced name** `<plugin>:<agent>`, both for a subagent and
  for a session agent. A plugin agent has no bare alias. The name is built from the plugin
  name, the path under `agents/` and the frontmatter `name`, so `agents/sub/x.md` would be
  `ola-workflow:sub:x`. The guard therefore keeps only the part after the last `:` and must
  be tested against both forms.
- **`agent_id`, not `agent_type`, tells a subagent from a session agent**: it is present only
  inside a subagent, and absent on the main thread even under `--agent`.
- **A missing agent has no `agent_type` key at all** — not `""`, not `main`.
- **`settings.json` accepts the namespaced name**, including in a project's committed
  `.claude/settings.json`, which is how a project pins its default agent:
  `"agent": "ola-workflow:coordinator"`. `--agent` additionally accepts the bare name
  (resolved by `:`-suffix), and a missing `--agent` is fatal while a missing settings `agent`
  only warns.
- **The Agent tool is different: `subagent_type` is an exact match.** A bare name does not
  resolve to a plugin agent:

  ```
  Agent type 'probe' not found. Available agents: claude, Explore, general-purpose,
  ola-workflow:probe, Plan, statusline-setup
  ```

  So the coordinator has to dispatch `ola-workflow:developer`, never `developer`. The same
  holds for a skill's `agent:` key.

The fields a `PreToolUse` payload offers the guard, as measured:
`agent_id`, `agent_type`, `cwd`, `effort`, `hook_event_name`, `permission_mode`, `prompt_id`,
`session_id`, `tool_input`, `tool_name`, `tool_use_id`, `transcript_path`.

Re-run `make spike` after a Claude Code upgrade: none of this is contractual. The seven
scenarios live in [`scripts/spike/agent-identity.sh`](scripts/spike/agent-identity.sh); it
loads the plugin with `--plugin-dir`, so nothing is installed and nothing is written inside
the repository.
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
