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

**The team is complete, and nothing enforces it yet.** In place: the manifests, the CI, the
test harness, the answer to how a plugin agent is identified (see
[Agent identity](#agent-identity)), the project profile with its schema and its
`ola-profile` CLI, and the **five agents** — a coordinator that frames and dispatches, a
product designer that turns a request into criteria a test can prove, an architect that
splits an epic into reviewable tasks, developers that build test-first in their own
worktrees, and an independent reviewer.

The guard is still **inert**. It allows everything, so the rules these agents follow are
rules nothing applies: an agent that follows a rule and an agent that is prevented from
breaking it are not the same thing. Until the guard is real, use this where a mistake is
cheap — a new project, not one that deploys on merge.

| step | content |
|---|---|
| A3 | the real guard, ported from `mcp-camptocamp` and driven by the profile |
| A4 | the conditional merge gate |
| A6 | the `workflow-init` and `verify-ui` skills, then 1.0.0 |

### Where the rules live

The agents share one source: `ola-workflow-brief`, on the PATH beside `ola-profile`. It
resolves the profile and prints the rules that follow from it — mode, languages, base
branch, commands, slots, escalation, restricted commands, where the memory goes, what the
merge gate requires. Each agent starts by running it, and each prompt holds only what is
specific to its role.

That is not tidiness. Five prompts restating the same facts drift apart one justified edit
at a time, and `tests/agents.test.sh` holds the line from the other side: no agent may
name a base branch, a check command, a review status, a slot value or a line budget, since
those belong to the brief. Run it against an agent that hard-codes one and it says which.

## How a project is configured

The plugin does nothing until it finds a profile. Where the file lives decides who owns
it; the `mode` key inside decides how the workflow behaves. It is looked for in two
places, in this order:

1. `~/.claude/workflow-profiles/<host>/<owner>/<repo>/profile.json` — **yours**, kept out
   of the project. The identity comes from
   `git remote get-url upstream || git remote get-url origin`, so a fork is known by the
   repository it contributes to, and a worktree resolves like its checkout;
2. `<project>/.claude/workflow.json` — the project's, committed with it.

**Your own profile wins**, because the two are not equally trusted: a third-party
repository must not be able to turn the discreet profile you chose for it into an
integrated one, and so grant itself writes to the forge and allowances on commands. One
that is there but unusable — corrupt, empty, not even a file — still wins, and the
resolution gives up rather than handing the last word back to the repository.

In practice a profile you keep for someone else's repository sets `"mode": "discreet"` and
a committed one sets `"mode": "integrated"`, but nothing forces that pairing: the key is
what is read.

Two details of that identity, both deliberate. An IPv6 host keeps its address and loses its
brackets (`ssh://git@[fd00::1]/srv/app.git` → `fd00::1/srv/app`), so two spellings of one
address give two profile directories — a split, never a collision. And `ola-profile id`
prints the host it parsed: a remote URL carrying credentials will have part of that URL
read back, which ends up in agent transcripts. Credentials belong in a credential helper,
not in a remote URL.

No profile means no effect: the hook exits 0 and the agents offer to run
`/ola-workflow:workflow-init`.

The file is described by [`schema/profile.schema.json`](schema/profile.schema.json), which
is also what validates it — point your editor at it:

| key | what it decides |
|---|---|
| `mode` | **required**: `integrated` or `discreet` |
| `language` | what to write in, for the human, the artifacts and the agents |
| `base_branch` | the branch PRs target and nobody pushes to |
| `check` | `full` (what CI runs), `affected` (the subset), `cleanup` |
| `slots` | how parallel agents avoid colliding on ports, databases and containers |
| `pr` | `max_lines`, `exclude`, `title` |
| `merge` | `required_checks`, `review_status`, `sensitive_paths`, `sensitive_patterns` |
| `commands` | per-command `allow_args` / `deny_args` rules the guard applies |
| `db_hosts_allowed` | the databases an agent may connect to |
| `context` | the documents the agents read: product, architecture, review checklist, glossary |
| `verify_ui` | how a change is seen running |
| `escalation_extra` | what this project reserves for the human |

Any string value may hold `{slot}`, which is replaced with the slot in use when one is
given. That is how parallel agents get their own ports, databases and containers, and it
works in every value — not just in `check.affected`.

Read it with `ola-profile`, which is on the PATH of every Bash call once the plugin is
installed:

```bash
ola-profile mode                              # integrated | discreet
ola-profile path                              # the file in use
ola-profile get check.affected --slot 3       # {slot} replaced
ola-profile get base_branch main              # with a default
ola-profile get merge.required_checks         # an array prints one item per line
ola-profile validate                          # every problem, or silence
```

Exit status 1 means the value asked for is not available: no profile applies to this
project (not an error, just an opt-out), the profile cannot be read, or `get` found no such
key and no default was given. A default stands in for a missing key, never for a missing or
unreadable profile — inventing a configuration is how a truncated file ends up reporting no
protected branch and no required checks.

This repository carries its own profile in
[`.claude/workflow.json`](.claude/workflow.json): the workflow is developed with the
workflow, which is the only honest test of how generic it is.

|  | integrated | discreet |
|---|---|---|
| Memory | GitHub issues, labels, a review commit status, review comments | local files under the profile directory |
| Conventions | the profile, plus the project's own CONTRIBUTING | read from the project: CONTRIBUTING, PR template, commit language |
| Writes to GitHub | allowed, per role | issues, labels, comments, statuses: **refused**. `git push` and `gh pr create`: **ask** (a human confirms) |
| Merge | the coordinator, through the merge gate | nobody |

### Globs

Every glob in a profile is a git pathspec `:(glob)`, and `schema/profile.schema.json` states
the rule for whoever writes one. Two notes for whoever *implements* a key that consumes
them:

- **Let git do the matching** — `git diff --numstat base..head -- . ':(glob,exclude)<pattern>'`
  does it inside the command that already counts lines. Re-implementing the dialect with a
  shell `case` would silently widen `pr.exclude` and `sensitive_patterns[].exclude`, and
  widening those two *removes* coverage, which is the one direction that matters.
- **The recursion keys on literal versus glob**, not on the absence of a slash: `docs` and
  `src/deep` pull in their subtrees, while `doc*`, `doc?` and `[dx]ocs` match nothing at
  all. That is what makes the schema's own example sound — `Dockerfile*` cannot reach into a
  neighbouring `Dockerfiles/`.

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
