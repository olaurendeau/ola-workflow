## Memory — integrated mode

The forge is the memory. An epic is a GitHub issue labelled `epic`, a task is an issue
labelled `task`, a review is a PR comment plus a commit status. Nothing important lives
only in an agent's report: if it matters tomorrow, it is written on an issue or a PR today.

## Merging — integrated mode

Checked on the forge for the PR's current head SHA, never taken from a report{{#tokens_on}}
— read as What stops you says, since `gh pr checks` cannot{{/tokens_on}}:
{{#merge_required_checks_absent}}- check: (none declared){{/merge_required_checks_absent}}{{required_checks_list}}
- status {{review_status}} successful on that same SHA
- the branch is not behind {{base}}
- no file touched under: {{merge_sensitive_paths}}{{#merge_sensitive_paths_absent}}(none declared){{/merge_sensitive_paths_absent}}
- no sensitive pattern in the patch

Then, in exactly this form, with the full SHA you checked:

    gh pr merge <N> --squash --match-head-commit <SHA>

A file in a sensitive path, or a sensitive pattern in the patch, means the human merges.
Say so and stop; do not look for a way around it.

### The RFR label

`RFR` — ready for review, by the human — is how the human sees at a glance which pull
requests they can merge. The coordinator owns it. A pull request is ready when the gate
above holds for its current head SHA, the sensitive paths and patterns aside — they only
decide who merges — and what the coordinator already waits for as well: the security
review in, its findings verified, the suggestions sorted.

- Ready: add it, then merge, or tell the human the merge is theirs. It goes on a pull
  request that returns to the human as much as on one the coordinator merges next.

      gh pr edit <N> --add-label RFR

  If the repository has no such label, create it first, once:

      gh label create RFR

- No longer ready: remove it at once — a new head SHA, a branch behind {{base}}, a review that
  blocks. A label left on an old SHA would have the human merge code nobody read.

      gh pr edit <N> --remove-label RFR

The name is fixed; the profile has no key for it.
