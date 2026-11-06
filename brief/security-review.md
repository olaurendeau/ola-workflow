## Security review
{{#security_declared}}
A pull request whose change touches one of these paths gets a security review beside
the code review. Dispatch the security-reviewer when this prints a file:

    git diff --name-only origin/{{base}}...<SHA> --{{pathspec}}

A fix owes a new one only when this prints something: it compares what the pull
request changes against {{base}}, in those paths, at the SHA last reviewed and at the new
one, each read against its own merge base with origin/{{base}} — so what a catch-up
brought in does not count, nor does where a change sits in its file. The limit: a fix
that moves an identical change between two places with identical context is not seen
by this command; the pr-reviewer's diff of diffs still sees it:

    diff <(git diff --no-color --no-ext-diff origin/{{base}}...<reviewed SHA> --{{pathspec}} | git patch-id --verbatim) <(git diff --no-color --no-ext-diff origin/{{base}}...<SHA> --{{pathspec}} | git patch-id --verbatim)

It reads at the SHA and runs nothing, so it takes no slot, nor does a verifier. Each blocking
finding it reports is pending verification until a second security-reviewer, dispatched on
that one finding, confirms it. Its verdict is advice the coordinator relays: it sets no
commit status, and the merge gate does not read it — the coordinator waits for it all the
same.
{{/security_declared}}
{{#security_none}}
(none declared — the security-reviewer is not dispatched; the pr-reviewer's checklist
is the only security review)
{{/security_none}}
