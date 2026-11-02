# ola-workflow

A team of Claude Code agents — a coordinator, a product designer and an independent design
reviewer, an architect, developers working in isolated worktrees, an independent PR
reviewer and, on the paths a project declares, a security reviewer — whose two irreversible
acts, merging and setting the review status, GitHub itself keeps with the role that owns them.

The workflow is **generic**: everything project-specific lives in a profile file, so the
same plugin drives a project you own and a repository you contribute to twice a year
**without committing anything to it**.

## How it works

You talk to one agent, the **coordinator**. It reads the project's *profile*, one file that
holds its rules (base branch, check commands, *slots*: numbers that keep parallel work apart),
and hands the work on, in this order. Each step starts from what the last one left on GitHub.

1. **coordinator** — frames your request — a framing. It asks you only if the goal is unclear.
2. **product-designer** — writes what "done" means and the words users read — the epic, an issue. You decide what a user sees.
3. **design-reviewer** — judges the design, for visual work only — a verdict. The designer revises.
4. **architect** — splits the epic — ordered tasks, as issues. Anything new in dependencies is yours.
5. **developer** — builds one task, test first, in its own worktree — a pull request.
6. **pr-reviewer** — reviews what it did not write — a verdict and the `agent-review` status.
7. **security-reviewer** — reads changes to declared `security.paths` — findings, each checked twice.
8. **coordinator** — merges once the checks are green and the review is clean — a merged pull request.

```mermaid
flowchart TD
  co[coordinator] -->|"you: what is done"| pd[product-designer]
  pd -->|"visual work"| dr[design-reviewer]
  dr -->|"verdict"| pd
  pd -->|"epic"| ar[architect]
  ar -->|"tasks"| co
  co -->|"one task, one slot"| dv[developer]
  dv -->|"pull request"| pr[pr-reviewer]
  pr -->|"blocking findings"| dv
  pr -->|"clean review"| co
  co -.->|"declared paths"| sr[security-reviewer]
  sr -.->|"confirmed findings"| dv
  co -->|"merge; sensitive paths: you"| co
```

The agents decide the rest alone, taking the option closest to existing code. Yours to decide:

- Scope and product: what a user sees, departing from what was asked.
- Dependencies: a new runtime dependency, any major version upgrade.
- Process and security: CI, rulesets, quality thresholds, hooks, agent definitions.
- Release: whether to release, and the version. The release is your act.

The memory is GitHub itself (issues, labels, the review status) in *integrated* mode, your
own project; in *discreet* mode, for a repository that is not yours, local files. See
[Configuration](docs/configuration.md).
GitHub refuses two acts to every role but its owner: merging, kept by the coordinator, and the
review status, kept by the pr-reviewer. Pushing to the base branch, tags and releases rest on
the agents' rules alone: see [GitHub tokens](docs/github-tokens.md#what-it-does-not-stop).
A whole request, step by step, is in the [walkthrough](docs/walkthrough.md).

## Install

```
/plugin install ola-workflow --marketplace olaurendeau/ola-workflow
```

or, from a shell:

```bash
claude plugin install ola-workflow --marketplace olaurendeau/ola-workflow
```

User scope is the default, which is what you want: install once, use everywhere. Then, in a
terminal, create the tokens the agents work with — see [GitHub tokens](docs/github-tokens.md):

```bash
ola-workflow-tokens setup
```

## Status

**The team is complete, and GitHub refuses two things a role does not own.** Two, not all:
merging belongs to the coordinator and the review status to the pr-reviewer, and every agent
works with a token that can do neither. Pushing to the base branch, tagging, releasing,
publishing and changing repository settings are **not refused by anything** — they are rules
the prompts carry and nothing applies, which is a different thing from a rule. See
[What it does not stop](docs/github-tokens.md#what-it-does-not-stop).

In place: the manifests, the CI,
the test harness, the answer to how a plugin agent is identified (see
[Agent identity](docs/agent-identity.md)), the project profile with its schema and its
`ola-profile` CLI, the **seven roles** (`agents/` also ships `probe`, a measuring tool that
is no part of the flow) — a coordinator that frames and dispatches, a product
designer that turns a request into criteria a test can prove and the words a user reads, and
for visual work publishes the design as a claude.ai artifact it keeps at one URL, a design
reviewer that judges that page against the epic, an architect that splits an
epic into reviewable tasks, developers that build test-first in their own worktrees, an
independent reviewer, and a security reviewer dispatched beside it when a change touches the
paths the project declares, whose blocking findings each go to a second, cold reading before
a developer sees them — and the **role tokens**.

A project with no profile is unaffected, which is the whole point of the design: both hooks
exit before doing anything, and its sessions keep your own GitHub login.

### What is not here yet

| step | content |
|---|---|
| A3 | pushing to the base branch, tags, releases, repository settings |
| A4 | declarative `commands[]` rules, discreet mode's prohibitions on the forge and on pushing (a merge and a review status are refused there too, by the tokens), the conditional merge gate |
| A6 | the `verify-ui` skill, then 1.0.0 |

Until the merge gate exists, the coordinator checks it by hand against the forge: GitHub
checks *who* merges, not whether the checks were green.

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

## Development

```bash
make check     # everything the CI runs: lint, test, validate
make lint      # shellcheck, in its own container (needs Docker, nothing else to install)
make test      # the bash suites: tests/run.sh
make validate  # claude plugin validate --strict .
make spike     # replays the agent-identity spike
make spike-artifact  # prints how to replay the artifact spike, by hand
scripts/token-cost.sh [--since D] [--until D] <dir>...  # weighted token cost per role, per model and per PR, raw and in $, from ~/.claude/projects/<slug>/
```

### One writing convention, enforced by the suite

`tests/agents.test.sh` checks that every `ola-workflow:<name>` written in an agent prompt,
in a skill, in `ola-workflow-brief` or in this README resolves to something shipped, and
that a command this plugin provides is never written as a bare `/name`. Both catch the
same defect: a prompt that offers a human a command which does not exist, found only at
the one moment the plugin had to explain itself.

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
the last one refused `$profile_dir/runs/<slug>/developer`, a path whose last segment happens
to be a role name.

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
They need `bash`, `jq` 1.5 or later, `perl` and `git` only — the suites build throwaway
repositories — and run identically on macOS (bash 3.2) and on CI. `tests/run.sh` refuses up
front when one is missing, rather than failing a hundred assertions that name the wrong
cause.
