# Walkthrough: one request, from your sentence to the merge

This page follows one request through the whole workflow, step by step: which agent acts,
what it produces, and what you are asked to decide at that moment. The request is made up:

```
Example
Add a filter to the list of orders, so I can see only the ones that are late.
```

The project is yours (mode *integrated*: the issues, labels and review status live on GitHub)
and it has a *profile* (the file that tells the plugin its base branch, its check commands,
its slots). Each step starts from what the previous one left on GitHub, which is the
workflow's memory. What is made up on this page is the request above and each line that
starts with "Example:"; nothing else is.

Example: the filter changes what a user sees.

## 1. coordinator — frames the request

You talk to the coordinator, the main session, and only to it. It runs `ola-workflow-brief`
to read the project's rules, restates your request in one sentence and, if the goal or the
success criteria are ambiguous, asks you with two to four options and a recommendation.
A request that changes what a user sees goes through the design steps; a fix or a test that
nobody sees would skip them and go straight to the tasks.

- **Produces:** a framing, nothing on GitHub yet.
- **You decide:** what "finished" means, when your sentence leaves it open.
  Example: late since when? Which orders?

## 2. product-designer — writes down what "done" means

The product-designer turns the request into a problem, user stories, acceptance criteria and
the exact words a user will read. For visual work it also builds the page of the design. The
coordinator records the result as the *epic*, an issue labelled `epic`.

- **Produces:** the epic, and for visual work a design page, written outside the repository
  and published as an artifact: its URL goes into the epic, so that the next request on the
  same screen starts from that page. A developer's task later copies the page into
  the project's design directory (`docs/design/<slug>/` by default, set by `context.design`)
  with its README.
- **You decide:** whether the design is published when the project's rules wait for your
  answer. A no is final for this design: it stays a local page.

## 3. design-reviewer — judges the design

For visual work only. The design-reviewer reads the epic and the design and returns a
verdict with findings. Blocking findings go back to the product-designer, which revises the
page, until the revision is approved.

- **Produces:** a verdict on the design, recorded in the epic.
- **You decide:** when the designer disputes a finding, or one survives two cycles, you
  rule, and the answer is recorded in the epic.

## 4. architect — splits the work

The architect turns the epic into a design and an ordered list of tasks, each with its files,
its tests, its dependencies and what "done" means. The coordinator creates each task as an
issue labelled `task`, a sub-issue of the epic.

- **Produces:** the tasks, in dependency order.
  Example: one task for the filter itself, one for the words, if they are separate.
- **You decide:** nothing routine. A task that needs a new runtime dependency, or a major
  version upgrade, is yours to approve.

## 5. developer — builds one task

For each task whose dependencies are merged, the coordinator dispatches a developer with the
task and one *slot*: a number that keeps parallel work from colliding on ports, databases
and containers. Tasks that do not depend on each other run in parallel, one developer each,
never more than the project has slots. Each developer works in its own git worktree, writes a
failing test for each criterion before the code that passes it, runs the project's check
command, and opens a pull request that closes its task.

- **Produces:** a pull request, titled in the Conventional Commits form, whose description
  starts with `Closes #<task>`.
- **You decide:** what the task does not settle. The developer stops with `needs-decision`
  rather than choosing for a new dependency, a change to what a user sees beyond the task, a
  change to CI or to a threshold, or a pull request over the line budget.

## 6. pr-reviewer — reviews what it did not write

The coordinator dispatches a pr-reviewer as soon as the pull request is open, with a reviewer
slot. It reads the code while the checks run, and publishes a verdict as a comment and as a
commit status named `agent-review` on the head SHA it read.

- **Blocking findings** go, word for word, to a fresh developer, who fixes them in new commits
  on the same branch. A fix that changes what the code does is reviewed again on the new
  SHA; a fix that changes only what a file says about it is not.
- **Suggestions** are sorted by the coordinator: fixed now if a cycle is already owed, noted
  on the epic as a follow-up, or rejected with a reason.
- **Produces:** the review status on the SHA, and the triage published on the pull request.
- **You decide:** when the developer disputes a finding, or one survives two cycles, the
  coordinator judges it first: a valid finding goes back to the developer, with no question
  to you. Only a finding it judges a false positive comes to you, and your answer is
  recorded so that the reviewer treats it as settled.

## 7. security-reviewer — only when the change touches a declared path

If the profile declares security paths and the pull request touches one of them, the
coordinator also dispatches a security-reviewer. It reads and runs nothing. Each blocking
finding it reports is checked by a second security-reviewer that reads it cold, and only a
confirmed finding goes to a developer. It sets no status; the coordinator waits for it all
the same.

Example: the filter touches none of those paths, so this step does not happen for our request.

- **Produces:** findings, each confirmed or refuted.
- **You decide:** a finding you rule a false positive is recorded in the project's security
  precedents, so that it does not come back.

## 8. coordinator — merges, or hands the merge to you

When the review on the current head SHA has no blocking finding, the checks are green, the
branch is not behind the base branch and no suggestion is left untriaged, the coordinator
checks the gate on GitHub, for that very SHA, and merges in exactly this form:

```
gh pr merge <N> --squash --match-head-commit <SHA>
```

Then it moves on to the tasks that merge unblocked. When the epic is done, it reports what
shipped, which decisions it took alone and which follow-up task it opened.

**The coordinator does not always merge.** If the pull request touches a sensitive path, or
carries a sensitive pattern, the merge is yours. It labels the pull request `RFR`, for
*ready for review, by the human*, says so, and stops. The label comes off the moment the
pull request is no longer ready: a new head SHA, a branch behind the base, a review that
blocks.

- **Produces:** the merged pull request, and the report.
- **You decide:** every merge it hands you; and, always, whether to release and which
  version. A release is yours to decide and yours to do.

## What GitHub refuses, and what nothing enforces

GitHub refuses two acts to every role but the one that owns them: merging a pull request to
anyone but the coordinator, and writing a commit status to anyone but the pr-reviewer. The
rest — pushing to the base branch, tagging, publishing — is carried by the agents' rules and
by nothing else. [What it does not stop](github-tokens.md#what-it-does-not-stop) says what
that leaves open, and why; it is the one place that says it.

## When a step is interrupted

A step that cannot finish is a normal state, and each has an owner.

| What stops | What the coordinator does | What comes back to you |
|---|---|---|
| The merge is refused (a 403) | Nothing else: it does not look for another command or another token | Merge from your own terminal, or fix who holds which token |
| The review is absent: the reviewer reported `blocked`, it could not read or run the checks | Resolves the environment, then dispatches the reviewer again; without the status on that SHA, it does not merge | Anything about the environment it cannot resolve |
| A check fails | Sends the log to a developer if it points at the code; reruns it if the runner was flaky | A fix that needs a dependency |
| The checks are still running when everything else is done | Reads them again at the next agent report; no loop | Told that the merge waits for CI, and given control back |
| The branch is now behind the base branch | Has the developer catch up; the new head SHA is reviewed again | Nothing |
| A path is sensitive | Labels the pull request `RFR` and stops | The merge |
