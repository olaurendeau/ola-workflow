# Discreet mode

Discreet mode is for a repository that is not yours, or one where nothing of the workflow
may be committed. The agents work the same way, but the workflow leaves no trace in the
repository and writes nothing on the forge.

This page says what the code does. It describes the rules the agents are given and the
merge and the commit status that GitHub refuses; it does not claim that a real contribution
to a third-party repository was run this way end to end.

## Where the profile lives

A discreet profile is yours, kept outside the project:

```
~/.claude/workflow-profiles/<host>/<owner>/<repo>/profile.json
```

The identity comes from `git remote get-url upstream || git remote get-url origin`, so a
fork is known by the repository it contributes to. The file sets `"mode": "discreet"`.

**Your profile wins** over a `.claude/workflow.json` committed in the repository, even when
that one is corrupt: a third-party repository must not be able to turn the profile you
chose for it into an integrated one. The resolution, the identity details and the keys are
in [configuration](configuration.md).

## Writing it

```
/ola-workflow:workflow-init
```

The skill asks the one thing it does not guess: *whose project is this?* The answer
"someone else's, or nothing is to be committed" gives `"mode": "discreet"` and a file in
your profile directory. Nothing is written in the repository: the skill gives you the two
session keys (`"agent": "ola-workflow:coordinator"` and `"autoCompactWindow": 250000`)
instead. With no remote there is nothing to key the profile on, and it stops there.

## Where the memory goes

`ola-profile dir` prints the profile's directory. The agents' memory is under it:

```
<profile directory>/runs/<slug>/
```

with `epic.md`, `tasks/`, `reviews/<branch>/<sha>.md` and
`security-reviews/<branch>/<sha>.md`. The brief tells the agents to keep the repository
itself clean: `git status` must be as they found it.

## What differs from integrated mode

|  | integrated | discreet |
|---|---|---|
| Memory | GitHub issues, labels, a review commit status, review comments | local files under `runs/<slug>/` |
| Conventions | the profile: `context`, `pr`, `language` | the same: the profile. Nothing reads the project's CONTRIBUTING, pull request template or commit language |
| Writes to GitHub | allowed, per role | issues, labels, comments, reviews, releases: **forbidden by the agents' rules, and nothing refuses them**. `git push` and `gh pr create`: the human confirms first, also a rule |
| Merge | the coordinator, through the merge gate; the `RFR` label marks a pull request ready | nobody. With the role tokens on, GitHub refuses it to every role |

What GitHub refuses and what is a rule are not the same thing. The role tokens make GitHub
refuse two operations whatever the mode: merging a pull request, and writing a commit
status. In discreet mode no command gets a stronger token, so those two are refused to
every role. Everything else in the table's discreet column is a rule the agents apply
themselves: the brief says of an issue, a comment, a label, a push and a pull request that
*nothing refuses* it, and that *silence is not permission, you are the enforcement*. With
`"github_tokens": "off"` the merge and the status are rules too.

See [GitHub tokens](github-tokens.md) for the tokens.
