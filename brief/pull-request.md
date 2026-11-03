## A reviewable pull request
At most {{pr_max_lines}} changed lines{{#pr_exclude}}, excluding {{pr_exclude}}{{/pr_exclude}}.
{{#title_conventional}}
Title in Conventional Commits form: it becomes the commit message on {{base}}.
{{/title_conventional}}
{{#title_free}}
Title: no imposed form.
{{/title_free}}

Description: short, in this order —
{{#integrated}}
- `Closes #<task>`, when the request closes a task: one made from a task closes it. A
  request that closes none (a release, say) has no such line.
{{/integrated}}
{{#discreet}}
- `Closes #<issue>` only if the human named an issue to close: the task lives in the
  local memory, not on the forge.
{{/discreet}}
- 1 to 3 sentences: what changes, and why.
- a line saying what was checked, its label in the language of the artifacts ("Checked" in
  English): the check command you ran, then one line per notable verification.
{{#integrated}}
- a Design line, only if the task points at a design: its artifact URL from the design's
  README, or the path of its page when it was never published.
{{/integrated}}
{{#preview}}
- a Captures block, only if the request changes what a user sees: a before/after table,
  "before" only when an existing screen changes, then the lines pr-assets printed.
{{/preview}}
- `Decision: … — Reason: …`, only if there is one.
- `<details><summary>…</summary> … </details>`, only if needed: the rest goes there.
Headings and labels in the language of the artifacts: {{language_artifacts}}.
A longer description is a suggestion in review, never a blocking finding.
