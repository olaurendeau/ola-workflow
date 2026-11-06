## What stops you
GitHub refuses **two** operations to every role but the one that owns them, however the
command is written — `gh`, `gh api`, a script, `curl`:
- merging a pull request, to anyone but the coordinator;
- writing a commit status, to anyone but the pr-reviewer.

Every Bash command runs with a GitHub token that can do neither. Two commands, in one exact
form each, run with a stronger one — nothing may come before, after or around them, and the
SHA is the full 40 characters:

    coordinator  gh pr merge <N> --squash --match-head-commit <SHA>
    pr-reviewer  gh api repos/{owner}/{repo}/statuses/<SHA> -f state=<success|failure> -f context={{review_status}} -f description='<one line>'

- A 403 on one of these means you are not the role that owns it, or the form is not exactly
  this one. Report it; do not look for another way or another token.
- A 401 on every gh call means the human has not created the tokens yet. Say so: they run
  `ola-workflow-tokens setup`.
- `gh pr checks`, and anything else that reads check runs, fails with "Resource not
  accessible by personal access token". GitHub gives check runs to no fine-grained token;
  it is not your role being refused. Read a SHA's checks as its Actions jobs and its
  statuses:

      gh api "repos/{owner}/{repo}/actions/runs?head_sha=<SHA>" --jq '.workflow_runs[] | "\(.id) \(.name) \(.status) \(.conclusion)"'
      gh run view <run id> --json jobs --jq '.jobs[] | "\(.name) \(.status) \(.conclusion)"'
      gh api repos/{owner}/{repo}/commits/<SHA>/status --jq '.statuses[] | "\(.context) \(.state)"'

  A check is a job of that name or a status of that context. When several runs of one
  workflow are on that SHA, the most recent counts, as it does on GitHub. A check run by an
  app other than GitHub Actions is in neither list: a required check found nowhere is not
  green, ask the human.

**Everything else above is a rule nothing applies.** Pushing to the base branch — `git push`
uses the human's own credentials — tagging, releasing, publishing, changing repository
settings: they hold only as far as you hold them. Do not read the absence of a refusal as
permission; on those, you are the enforcement.
