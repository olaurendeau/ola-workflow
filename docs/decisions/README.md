# Decisions

Why a rule of this project is what it is. One file per decision, never rewritten once accepted
except for its status: going back on a decision is a new entry that supersedes the old one.

## When to write an entry

When a pull request changes one of these:

- the boundary of what a role can do: tokens, hooks, what is enforced and what is only asked;
- the model or the effort of a role;
- the precedence or the format of the profile;
- what is written where, according to the mode;
- a runtime dependency;
- a choice founded on a measurement.

Not for a fix, a rename or a matter of style. The pull request description already carries the
`Decision: … — Reason: …` line the brief asks for; in these cases it adds the link to the entry.

An entry has six sections, in this order: Status (accepted, rejected, or superseded by the
number of the entry that replaces it), Date, Context, Decision, Consequences, Evidence. Name it
`NNNN-short-title.md`, with the next number, and add its row below.

## Entries

| number | title | status | date |
|---|---|---|---|
| [0001](0001-github-tokens-per-role.md) | GitHub refuses the merge and the status, by token | accepted | 2026-10-19 |
| [0002](0002-base-token-read-from-keychain.md) | The base token is read from the keychain at each command | accepted | 2026-10-19 |
| [0003](0003-hook-rewrites-two-forms.md) | The hook rewrites two command forms and lets everything else through | accepted | 2026-10-19 |
| [0004](0004-user-profile-wins.md) | The user's profile wins over the repository's, even unreadable | accepted | 2026-10-12 |
| [0005](0005-repository-identity-upstream-then-origin.md) | A repository is known by its upstream, then its origin | accepted | 2026-10-12 |
| [0006](0006-one-brief-for-every-agent.md) | One brief, printed by a command, for every agent | accepted | 2026-10-12 |
| [0007](0007-profile-key-only-on-a-positive-result.md) | A profile key is written only on a positive result | accepted | 2026-10-14 |
| [0008](0008-model-and-effort-per-role.md) | Each role pins its model and effort: Opus for judgement, Sonnet for volume | accepted | 2026-10-21 |
| [0009](0009-agent-identity-measured-by-a-spike.md) | A plugin agent's identity and effort are measured, not read | accepted | 2026-10-21 |
| [0010](0010-security-reviewer-precision-over-recall.md) | The security reviewer favours precision, and every blocking finding is read cold | accepted | 2026-10-21 |
| [0011](0011-only-the-coordinator-has-a-browser.md) | Only the coordinator declares the browser tools | accepted | 2026-10-23 |
| [0012](0012-writing-convention-by-whitelist.md) | The prompts follow a writing convention enforced with a whitelist | accepted | 2026-10-14 |
| [0013](0013-globs-are-git-pathspecs.md) | Every glob of a profile is a git pathspec | accepted | 2026-10-12 |
