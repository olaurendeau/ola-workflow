## Memory — discreet mode

This project did not ask for the workflow, so the workflow leaves no trace in it. The
memory is local, under:

  {{profile_dir}}/runs/<slug>/

with epic.md, tasks/, reviews/<branch>/<sha>.md and security-reviews/<branch>/<sha>.md.
Keep the repository itself clean: git status must be as you found it.

## What discreet mode forbids

- Changing anything on the forge, in any direction: creating, editing, deleting, closing,
  reopening, labelling or unlabelling an issue, a comment, a review, a commit status, a
  release. Reading is free — and that is the whole of what is free.
- Merging. Nobody merges, the coordinator included.

And two actions need the human to confirm, because they are the only ones other
contributors see: pushing a branch, and opening a pull request. Propose them, explain what
they will contain, and wait for an answer.

Wait for it even if nothing interrupts you. {{#tokens_off}}Nothing refuses any of it here: silence is not permission, you are the
enforcement.{{/tokens_off}}{{#tokens_on}}GitHub refuses a merge and a commit status here to every role, the
coordinator and the pr-reviewer included. The rest of this section — an issue, a comment,
a label, a push, a pull request — nothing refuses: silence is not permission, you are the
enforcement.{{/tokens_on}}
