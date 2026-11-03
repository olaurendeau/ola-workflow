# ola-workflow

Describe a change in plain words, and a team of Claude Code agents takes it from there: it
writes down what "done" means, splits the work into pull requests small enough to review,
builds them test-first, has each one reviewed by an agent that did not write it, and merges
what is safe to merge. You stay in charge of the decisions that are yours: scope,
dependencies, releases.

Two things set it apart. **It is enforced where it can be:** merging belongs to the
coordinator and the review status to the independent reviewer, and GitHub itself refuses both
to every other role. Pushing to the base branch, tagging and publishing are rules the agents
carry, not rules GitHub applies — the docs say which is which. And **it is generic:**
everything specific to a project lives in a profile file, so the same plugin drives a project
you own and a repository you contribute to twice a year, **without committing anything to
it**.

It is a Claude Code plugin. A project with no profile is unaffected: the plugin does nothing
there, and your own GitHub login is left alone.

## How it works

You talk to one agent, the **coordinator**. It hands the work from role to role, in the steps
below. Each reads **role** — what it does — what it produces. A change that no user sees and that
fits one pull request skips steps 2 to 4.

1. **coordinator** — asks you only if your goal is unclear — a request in one sentence.
2. **product-designer** — says what "done" means, and the words users read — an epic, the GitHub issue that holds it.
3. **design-reviewer** — checks the design, for visual work only — a verdict. You settle a dispute.
4. **architect** — splits the epic into small tasks — one issue per task.
5. **developer** — builds one task, test first, in its own worktree — a pull request.
6. **pr-reviewer** — reviews what it did not write — a verdict and an `agent-review` status.
7. **security-reviewer** — also reads changes to paths the project marks for security review — findings; a second reading confirms each blocking one.
8. **coordinator** — merges once the checks, the review status and any security review are green.
   You merge instead when a change touches a path the project reserves to you; in a repository that is not yours, nobody does.

```mermaid
flowchart TD
  co[coordinator] -->|"request, framed with you"| pd[product-designer]
  pd <-->|"visual work: design, verdict"| dr[design-reviewer]
  pd -->|"epic"| ar[architect]
  ar -->|"tasks"| co
  co -->|"a task; findings to fix"| dv[developer]
  dv -->|"pull request"| pr[pr-reviewer]
  pr -->|"verdict, status"| co
  co -.->|"security paths"| sr[security-reviewer]
  sr -.->|"findings"| co
```

The agents decide the rest alone, taking the option closest to existing code. Yours to decide:

- Scope and product: what a user sees, departing from what was asked.
- Dependencies: a new runtime dependency, any major version upgrade.
- Process and security: CI, rulesets, quality thresholds, hooks, agent definitions.
- Release: whether to release, and the version. The release is your act.

Each role writes down what the next needs: on GitHub (issues, labels, the `agent-review` status) in
your own project, in local files in [a repository that is not yours](docs/discreet-mode.md). A
project opts in with a profile file; without one, nothing happens: [Configuration](docs/configuration.md).

GitHub refuses merging and setting the review status to the agents' token. The coordinator gets a
stronger one for the merge command alone, the pr-reviewer for the status command alone. Pushing,
tags and releases rest on rules alone: see [GitHub tokens](docs/github-tokens.md#what-it-does-not-stop).

A whole request, step by step, is in the [walkthrough](docs/walkthrough.md).

## Quickstart

You need macOS for the GitHub tokens, and `gh`, `git`, `jq` and Claude Code
([prerequisites](docs/getting-started.md#1-prerequisites)). Install the plugin, from a Claude
Code session:

```
/plugin install ola-workflow --marketplace olaurendeau/ola-workflow
```

or from a shell:

```bash
claude plugin install ola-workflow --marketplace olaurendeau/ola-workflow
```

The plugin's commands are on the `PATH` of a session's Bash calls and nowhere else: in a
terminal, first run the `export` line of [step 2](docs/getting-started.md#2-install-the-plugin),
then create the three tokens the agents work with ([GitHub tokens](docs/github-tokens.md)):

```bash
ola-workflow-tokens setup
```

In the project, in a Claude Code session, write its profile. It asks whose project it is:
yours (`integrated`) or someone else's (`discreet`).

```
/ola-workflow:workflow-init
```

Back in the terminal, in the project, check the profile, then talk to the coordinator:

```bash
ola-profile validate
claude --agent ola-workflow:coordinator
```

Each step says what you should see, and what to do when you do not, in
[Getting started](docs/getting-started.md).

## Where to go next

| If you want to… | Read |
|---|---|
| Install it and run a first request | [Getting started](docs/getting-started.md) |
| See what happens between a request and a merged pull request | [Walkthrough](docs/walkthrough.md) |
| Contribute to someone else's repository without committing anything to it | [Discreet mode](docs/discreet-mode.md) |
| Configure a project | [Configuration](docs/configuration.md) |
| Know what GitHub enforces and what it does not | [GitHub tokens](docs/github-tokens.md) |
| Know which model each agent runs on | [Models](docs/models.md) |
| Understand why a rule is what it is | [Decision log](docs/decisions/README.md) |
| See how plugin agents are identified, as measured | [Agent identity](docs/agent-identity.md) |
| Work on the plugin itself | [Contributing](docs/contributing.md) |

## Status

GitHub refuses two things a role does not own: merging, and writing the review status. Two,
not all. What follows is a rule the agents carry and nothing applies:

- Pushing to the base branch, tagging, releasing, publishing and changing repository settings
  ([what it does not stop](docs/github-tokens.md#what-it-does-not-stop)).
- In discreet mode, writes to the forge and `git push`
  ([Discreet mode](docs/discreet-mode.md)).
- The `commands` rules of a profile: the brief states them, nothing applies them
  ([Configuration](docs/configuration.md)).
- The merge gate: GitHub checks who merges, not whether the checks were green. The
  coordinator reads them on the forge.

Not shipped: a `verify-ui` skill.
