# ola-workflow

A team of Claude Code agents — a coordinator, a product designer and an independent design
reviewer, an architect, developers working in isolated worktrees, an independent PR
reviewer and, on the paths a project declares, a security reviewer — whose two irreversible
acts, merging and setting the review status, GitHub itself keeps with the role that owns them.

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
