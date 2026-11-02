# Contributing

For whoever changes the plugin itself. Using it on a project is in the [README](../README.md).

## Development

```bash
make check     # everything the CI runs: lint, test, validate
make lint      # shellcheck, in its own container (needs Docker, nothing else to install)
make test      # the bash suites: tests/run.sh
make validate  # claude plugin validate --strict .
make spike     # replays the agent-identity spike
make spike-artifact  # prints how to replay the artifact spike, by hand
scripts/token-cost.sh [--since D] [--until D] <dir>...  # weighted token cost per role, per model and per PR, raw and in $, from ~/.claude/projects/<slug>/
```

What each command needs:

- `make test` needs `bash`, `jq` 1.5 or later, `perl` and `git` only — the suites build
  throwaway repositories and fake `PreToolUse` payloads, never executing the commands they
  contain — and runs identically on macOS (bash 3.2) and on CI. `tests/run.sh` refuses up
  front when one is missing, rather than failing a hundred assertions that name the wrong
  cause.
- `make lint` needs Docker.
- `make validate` needs the `claude` CLI, on your `PATH`.
- `make check` needs all of the above.

### How the repository is laid out

| folder | holds |
|---|---|
| `agents/` | one prompt per role, and `probe`, a measuring tool and not a role |
| `skills/` | the skills the plugin ships (`workflow-init`) |
| `bin/` | the commands the agents run: the brief, the profile, the tokens, the captures |
| `hooks/` | the `SessionStart` and `PreToolUse` hooks that give a command its token |
| `schema/` | the JSON schema of a profile |
| `tests/` | the bash suites, run by `tests/run.sh` |
| `docs/` | the documentation that is not the README: pages, decisions, designs |

This repository is developed with its own workflow: its profile is
[`.claude/workflow.json`](../.claude/workflow.json), and a change goes through a coordinator
session, an architect, developers in worktrees and an independent review, like any project
the plugin drives.

### A change

A pull request has a title in Conventional Commits form, which becomes the commit message on
main, and at most 1000 changed lines. It is merged by the coordinator, once its checks and
the review status are green on its head; a change to a sensitive path of the profile is
merged by the human. The form of the description is the one `ola-workflow-brief` prints:
this page does not copy it, so that it cannot drift from it.

### When a change needs a decision entry

A pull request that changes one of these is recorded in
[`docs/decisions/`](decisions/README.md), which also says how to write an entry:

- the boundary of what a role can do: tokens, hooks, what is enforced and what is only asked;
- the model or the effort of a role;
- the precedence or the format of the profile;
- what is written where, according to the mode;
- a runtime dependency;
- a choice founded on a measurement.

Not for a fix, a rename or a matter of style. The `Decision: … — Reason: …` line of the pull
request then links to the entry.

### One writing convention, enforced by the suite

`tests/agents.test.sh` checks that every `ola-workflow:<name>` written in an agent prompt,
in a skill, in `ola-workflow-brief`, in the README or in a page under `docs/` resolves to
something shipped, and that a command this plugin provides is never written as a bare
`/name`. The pages scanned under `docs/` are all of them but `docs/security-precedents.md`,
which quotes what an attacker types, and `docs/design/`, which holds pages published
elsewhere. Both checks catch the same defect: a prompt that offers a human a command which
does not exist, found only at the one moment the plugin had to explain itself.

The convention that follows, and the reason it exists: **do not write this plugin's
namespace followed by something that is not one of its commands, and do not write a role or
skill name after a bare slash.** Both checks fail on either, and neither can do better — a
mention and an offer are the same characters. An image tag of this plugin has the same shape
as one of its commands, and a sentence forbidding a wrong spelling has the same shape as the
wrong spelling. Describe them instead: "a command written without its namespace", "the
plugin's name followed by a version".

This paragraph is itself under the rule, which is why it names no example. Writing one would
fail the check — and that is the clearest demonstration of the limit there is.

What makes a path decidable is **the character before the slash** — together with whether
more path follows it — and the question is asked the safe way round: an offer is preceded by
the start of a line, a blank or a tab, a quote (single, double or back), or an opening paren
or bracket. Eight positions in all; everything else is a path. Five earlier versions listed
what precedes a *path* instead, and each was one character short of refusing a true sentence;
the last one refused `$profile_dir/runs/<slug>/developer`, a path whose last segment happens
to be a role name.

Those eight are pinned in `tests/agents.test.sh` by **measurement**: every printable character
is put in front of a role name and the set that makes an offer is compared with the set this
sentence names. So adding a ninth fails, and dropping one of the eight fails too.

An earlier version of this paragraph claimed it could not drift, while the fixtures only
guarded *removal* — and the drift that had just happened was an addition: two characters grew
in the code while this sentence still named four.

A whitelist errs by missing an offer, which is a false negative; a blacklist errs by accusing
a sentence, which is not. That asymmetry is the whole reason it is written this way round.

What is deliberately **not** checked at all: the namespace spelled wrong. That rule existed
for three cycles and failed on ordinary sentences about image tags, log lines and SQL every
time it was narrowed.
