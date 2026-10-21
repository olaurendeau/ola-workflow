# Security precedents

What the security-reviewer does not report on this project, because the human ruled it a
false positive. The security-reviewer reads this file from the base branch before it looks
for anything, so a change cannot excuse itself by adding a line here — and the file is in
`merge.sensitive_paths`, so only the human merges a new precedent.

One entry per ruling:

- **Pattern** — the code shape, precise enough to recognise again.
- **Why it is not exploitable** — the attacker it would need, and why there is none.
- **Ruled** — the pull request or issue where the human decided.

(none yet)
