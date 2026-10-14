# ola-workflow

A team of Claude Code agents — a coordinator, a product designer and an independent design
reviewer, an architect, developers working in isolated worktrees, and an independent PR
reviewer — plus a `PreToolUse` guard
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

**The team is complete, and the guard refuses two things a role does not own.** Two, not
all: merging belongs to the coordinator and the review status to the pr-reviewer, and those
are the only operations any rule names. Pushing to the base branch, tagging, releasing,
publishing and changing repository settings are **not refused by anything** — they are rules
the prompts carry and nothing applies, which is a different thing from a rule. See
[What is not here yet](#what-is-not-here-yet).

In place: the manifests, the CI,
the test harness, the answer to how a plugin agent is identified (see
[Agent identity](#agent-identity)), the project profile with its schema and its
`ola-profile` CLI, the **six agents** — a coordinator that frames and dispatches, a product
designer that turns a request into criteria a test can prove and the words a user reads, and
for visual work publishes the design as a claude.ai artifact it keeps at one URL, a design
reviewer that judges that page against the epic, an architect that splits an
epic into reviewable tasks, developers that build test-first in their own worktrees, and an
independent reviewer — and the **guard**: a tokenizer that reads what a shell would really
run, three decisions, fail-closed once a profile exists, and its first two role rules.

A project with no profile is unaffected, which is the whole point of the design: the hook
exits 0 before any rule, at a cost of seven subprocesses — `make measure` prints which. A
project that wrote a profile has
opted in, and `"guard": "log"` is how it watches the decisions before letting them act.

### What it costs, and how to find out

Every number this repository published about the guard has been wrong at least once, and
always the same way: measured once, written down, quoted after the thing changed. Two were
wrong because the *method* was wrong — a subprocess count that only counted the tools the
author had thought to instrument. So the measurement ships:

```bash
make measure
```

It reads `scripts/ordinary-commands.txt`, feeds each line to the guard as the text of a
payload (nothing is executed), and prints what was asked about and what it cost. On
2026-10-14, on that 90-command sample:

| | |
|---|---|
| asked about | **5**, and **0 refused** — a refusal there would be a false positive |
| rate on that sample | **5.6%** |
| external commands per Bash call, no profile | **7** — `cat`, `dirname` ×2, `git`, `jq` ×3 |
| the same, with a profile, cached | **14** |

**The rate is a property of the sample, not of the guard.** It counts how many of your
commands run something that is not in their own text, so a sample that holds all five of
those reads 15.6% at 32 commands and 3.7% at 134 — the same five commands, two denominators.
The number worth watching is which commands, not the percentage.

Those five are `source x`, `. x`, `eval "$(…)"`, `trap … EXIT`, `$EDITOR file`. Each builds
its command word by expansion or reads a body from a file. Refusing them would refuse
`$EDITOR file`; allowing them is the hole the guard exists to close; so it asks, and that is
the price.

A project with no profile pays the first line of that table and nothing else: the guard
exits 0 before any rule.

### What is not here yet

| step | content |
|---|---|
| A3 | the remaining role rules: pushing to the base branch, tags, releases, repository settings |
| A4 | declarative `commands[]` rules, discreet mode's prohibitions, the conditional merge gate |
| A6 | the `verify-ui` skill, then 1.0.0 |

Until the merge gate exists, the coordinator checks it by hand against the forge. And the
guard knows nothing about a release: that rule is the prompts' alone.

### Where the rules live

The agents share one source: `ola-workflow-brief`, on the PATH beside `ola-profile`. It
resolves the profile and prints the rules that follow from it — mode, languages, base
branch, commands, slots, escalation, restricted commands, where the memory goes, what the
merge gate requires. Each agent starts by running it, and each prompt holds only what is
specific to its role.

That is not tidiness. Six prompts restating the same facts drift apart one justified edit
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
`/ola-workflow:workflow-init`, the skill that writes one.

### Writing the first one

```
/ola-workflow:workflow-init
```

It establishes the identity, asks the one thing it must not guess — whose project this is,
which decides both the mode and the scope the file is written in — detects what the
repository can tell it, shows the file before writing it, and reads the result back as an
agent will receive it.

It writes a key only on a positive result, and that is the rule it is built around: an
omitted key reads as *not declared* in the brief, which an agent treats as a question for
the human, while an invented one reads as this project's rule — a check command nobody runs,
enforced by a reviewer against a developer. `slots`, `pr`, `merge`, `commands`,
`db_hosts_allowed` and `verify_ui` are not detectable at all and are left out unless you
state them.

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
| `context` | the documents the agents read: product, architecture, review checklist, glossary; and `design`, where each design is documented (`docs/design` by default, integrated mode only) |
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
ola-profile where user                        # where one would go, before any exists
ola-profile schema                            # the file this CLI validates against
ola-profile get check.affected --slot 3       # {slot} replaced; --slot may go anywhere
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
  name, the path under `agents/` and the frontmatter `name`, so `agents/<dir>/<name>.md`
  would be `ola-workflow:<dir>:<name>`. (A template, not a name: `tests/agents.test.sh`
  checks that every `ola-workflow:…` written in a prompt or here resolves to something
  shipped, so an illustration has to be visibly an illustration.) The guard keeps only the
  part after the last `:` and must
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

### Publishing an artifact from a plugin agent

The product-designer publishes visual work as a claude.ai artifact and keeps it at one URL.
Measured on **Claude Code 2.1.299**, 2026-10-14, with
[`scripts/spike/agent-artifact.sh`](scripts/spike/agent-artifact.sh):

| scenario | `Artifact` available | publish, then publish with `url` |
|---|---|---|
| `claude -p`, main session | no | — |
| `claude -p`, plugin agent declaring `Artifact` | no | — |
| interactive, `general-purpose` subagent | yes, loaded directly | not measured |
| interactive, plugin agent declaring `Write, Artifact` | yes | same URL, version 1 then 2 |

So a plugin agent gets the tool by naming it in `tools:`, and a second publish with `url`
updates the page in place. **Headless runs have no `Artifact` at all**, the main session
included, which is why this spike is replayed by hand: `make spike-artifact` prints the
session to start and the prompt to paste. It publishes one private page in the account of
whoever runs it.

## Development

```bash
make check     # everything the CI runs: lint, test, validate
make lint      # shellcheck, in its own container (nothing to install)
make test      # the bash suites: tests/run.sh
make validate  # claude plugin validate --strict .
make spike     # replays the agent-identity spike
make spike-artifact  # prints how to replay the artifact spike, by hand
```

### One writing convention, enforced by the suite

`tests/agents.test.sh` checks that every `ola-workflow:<name>` written in an agent prompt,
in `ola-workflow-brief` or in this README resolves to something shipped, and that a command
this plugin provides is never written as a bare `/name`. Both catch the same defect: a
prompt that offers a human a command which does not exist, found only at the one moment the
plugin had to explain itself.

The convention that follows, and the reason it exists: **do not write this plugin's
namespace followed by something that is not one of its commands, and do not write a role or
skill name after a bare slash.** Both checks fail on either, and neither can do better — a
mention and an offer are the same characters. An image tag of this plugin has the same shape
as one of its commands, and a sentence forbidding a wrong spelling has the same shape as the
wrong spelling. Describe them instead: "a command written without its namespace", "the
plugin's name followed by a version".

This paragraph is itself under the rule, which is why it names no example. Writing one would
fail the check — and that is the clearest demonstration of the limit there is.

What makes a path decidable is **the character before the slash** — together with whether
more path follows it — and the question is asked the safe way round: an offer is preceded by
the start of a line, a blank or a tab, a quote (single, double or back), or an opening paren
or bracket. Eight positions in all; everything else is a path. Five earlier versions listed
what precedes a *path* instead, and each was one character short of refusing a true sentence;
the last one refused `$profile_dir/runs/<slug>/developer`, a path the brief itself writes.

Those eight are pinned in `tests/agents.test.sh` by **measurement**: every printable character
is put in front of a role name and the set that makes an offer is compared with the set this
sentence names. So adding a ninth fails, and dropping one of the eight fails too.

An earlier version of this paragraph claimed it could not drift, while the fixtures only
guarded *removal* — and the drift that had just happened was an addition: two characters grew
in the code while this sentence still named four.

A whitelist errs by missing an offer, which is a false negative; a blacklist errs by accusing
a sentence, which is not. That asymmetry is the whole reason it is written this way round.

What is deliberately **not** checked at all: the namespace spelled wrong. That rule existed
for three cycles and failed on ordinary sentences about image tags, log lines and SQL every
time it was narrowed.

The test suites fake `PreToolUse` payloads and never execute the commands they contain.
They need `bash`, `jq`, `perl` and `git` only — the suites build throwaway repositories —
and run identically on macOS (bash 3.2) and on CI. `tests/run.sh` refuses up front when one
is missing, rather than failing a hundred assertions that name the wrong cause.
