# Configuration

## How a project is configured

The plugin does nothing until it finds a profile. Where the file lives decides who owns
it; the `mode` key inside decides how the workflow behaves. It is looked for in two
places, in this order:

1. `~/.claude/workflow-profiles/<host>/<owner>/<repo>/profile.json` — **yours**, kept out
   of the project. The identity comes from
   `git remote get-url upstream || git remote get-url origin`, so a fork is known by the
   repository it contributes to, and a worktree resolves like its checkout;
2. `<project>/.claude/workflow.json` — the project's, committed with it.

**Your own profile wins**, because the two are not equally trusted: a third-party
repository must not be able to turn the discreet profile you chose for it into an
integrated one, and so grant itself writes to the forge and allowances on commands. One
that is there but unusable — corrupt, empty, not even a file — still wins, and the
resolution gives up rather than handing the last word back to the repository.

In practice a profile you keep for someone else's repository sets `"mode": "discreet"` and
a committed one sets `"mode": "integrated"`, but nothing forces that pairing: the key is
what is read.

Two details of that identity, both deliberate. An IPv6 host keeps its address and loses its
brackets (`ssh://git@[fd00::1]/srv/app.git` → `fd00::1/srv/app`), so two spellings of one
address give two profile directories — a split, never a collision. And `ola-profile id`
prints `<host>/<owner>/<repo>`, but it does not guarantee that the credentials of a remote
URL are removed: such a remote can appear in its output (see
[#137](https://github.com/olaurendeau/ola-workflow/issues/137)). They do not belong in a
remote URL anyway, which any `git remote -v` shows: use a credential helper.

No profile means no effect: the hook exits 0 and the agents offer to run
`/ola-workflow:workflow-init`, the skill that writes one.

### Writing the first one

```
/ola-workflow:workflow-init
```

It establishes the identity, asks the one thing it must not guess — whose project this is,
which decides both the mode and the scope the file is written in — detects what the
repository can tell it, shows the file before writing it, and reads the result back as an
agent will receive it. In `integrated` mode it also writes the session settings beside it, in
`.claude/settings.json`: `"agent": "ola-workflow:coordinator"` and `"autoCompactWindow": 250000`,
keeping the file's other keys and asking before replacing a value of yours. In `discreet`
mode it writes nothing in the repository and gives you those two keys instead.

It writes a profile key only on a positive result, and that is the rule it is built around: an
omitted key reads as *not declared* in the brief, which an agent treats as a question for
the human, while an invented one reads as this project's rule — a check command nobody runs,
enforced by a reviewer against a developer. `slots`, `pr`, `merge`, `commands`,
`db_hosts_allowed`, `verify_ui` and `preview` are not detectable at all and are left out unless
you state them.

The file is described by [`schema/profile.schema.json`](../schema/profile.schema.json), which
is also what validates it — point your editor at it:

| key | what it decides |
|---|---|
| `mode` | **required**: `integrated` or `discreet` |
| `language` | what to write in, for the human, the artifacts and the agents |
| `base_branch` | the branch PRs target and nobody pushes to |
| `check` | `full` (what CI runs), `affected` (the subset), `cleanup` |
| `slots` | how parallel agents avoid colliding on ports, databases and containers: one per developer, and one or more for reviewers, each running a review at the same time |
| `pr` | `max_lines`, `exclude`, `title` |
| `merge` | `required_checks`, `review_status`, `sensitive_paths`, `sensitive_patterns` |
| `security` | `paths`: the globs whose change gets a security review beside the code review; none, and nobody is dispatched |
| `commands` | per-command `allow_args` / `deny_args` rules the brief states — nothing applies them yet |
| `github_tokens` | `keychain` (the default) or `off` — see [GitHub tokens](github-tokens.md) |
| `db_hosts_allowed` | the databases an agent may connect to |
| `context` | the documents the agents read: product, architecture, review checklist, security precedents, glossary; and `design`, where each design is documented (`docs/design` by default, integrated mode only) |
| `verify_ui` | how a change is seen running |
| `preview` | `up`, `url`, `down`: how a web app is started on a slot to be captured for a pull request — see [Captures](#captures) |
| `escalation_extra` | what this project reserves for the human |

Any string value may hold `{slot}`, which is replaced with the slot in use when one is
given. That is how parallel agents get their own ports, databases and containers, and it
works in every value — not just in `check.affected`.

Read it with `ola-profile`, which is on the PATH of every Bash call once the plugin is
installed:

```bash
ola-profile mode                              # integrated | discreet
ola-profile path                              # the file in use
ola-profile where user                        # where one would go, before any exists
ola-profile schema                            # the file this CLI validates against
ola-profile get check.affected --slot 3       # {slot} replaced; --slot may go anywhere
ola-profile get base_branch main              # with a default
ola-profile get merge.required_checks         # an array prints one item per line
ola-profile validate                          # every problem, or silence
```

Exit status 1 means the value asked for is not available: no profile applies to this
project (not an error, just an opt-out), the profile cannot be read, or `get` found no such
key and no default was given. A default stands in for a missing key, never for a missing or
unreadable profile — inventing a configuration is how a truncated file ends up reporting no
protected branch and no required checks.

This repository carries its own profile in
[`.claude/workflow.json`](../.claude/workflow.json): the workflow is developed with the
workflow, which is the only honest test of how generic it is. Its
[`.claude/settings.json`](../.claude/settings.json) makes every session opened here an
`ola-workflow:coordinator`, on the installed plugin rather than this tree, so the plugin is
not rewritten under itself while it works. For an ordinary session, name another agent:
`claude --agent <name>`.

What changes between the two modes — memory, writes to the forge, merge — is in
[discreet mode](discreet-mode.md).

### Captures

A pull request that changes what a user sees can show it. The profile's `preview` says how
to start the web app on a slot (`up`, which returns once the app answers at `url`), where to
look (`url`) and how to stop it (`down`); `{slot}` applies to all three. It is not
`verify_ui`, which is how a developer sees a change running and may aim at a simulator:
`preview` is web only. Without it, no capture is expected, and the brief says so.

Two scripts, on the PATH of every Bash call:

- `ola-workflow-capture <url> <file.png>` takes a screenshot with a headless Chrome or
  Chromium. One must be installed; `OLA_WORKFLOW_CHROME` names the one to use, and then only
  that one.
- `ola-workflow-pr-assets <pr> <file.png>...` pushes the files to the `pr-assets` branch,
  at `<pr>/<name>.png`, and prints one markdown line per file for the description. The link
  is a `blob/pr-assets/...?raw=true` one.

`pr-assets` is as readable as the repository: capture development data only. Captures are
written outside the worktree and are never committed.

### Globs

Every glob in a profile is a git pathspec `:(glob)`, and `schema/profile.schema.json` states
the rule for whoever writes one. Two notes for whoever *implements* a key that consumes
them:

- **Let git do the matching** — `git diff --numstat base..head -- . ':(glob,exclude)<pattern>'`
  does it inside the command that already counts lines. Re-implementing the dialect with a
  shell `case` would silently widen `pr.exclude` and `sensitive_patterns[].exclude`, and
  widening those two *removes* coverage, which is the one direction that matters.
- **The recursion keys on literal versus glob**, not on the absence of a slash: `docs` and
  `src/deep` pull in their subtrees, while `doc*`, `doc?` and `[dx]ocs` match nothing at
  all. That is what makes the schema's own example sound — `Dockerfile*` cannot reach into a
  neighbouring `Dockerfiles/`.

## Where the rules live

The agents share one source: `ola-workflow-brief`, on the PATH beside `ola-profile`. It
resolves the profile and prints the rules that follow from it — mode, languages, base
branch, commands, slots, escalation, restricted commands, where the memory goes, what the
merge gate requires. Each agent starts by running it, and each prompt holds only what is
specific to its role.

The words of those rules are not in the script. They are Markdown templates in `brief/`,
one file per section, and `bin/ola-workflow-brief` keeps the logic: which section is
printed, and the value each template reads.

- `brief/<section>.md` is a section; `brief/<section>.<variant>.md` when the whole text
  changes with the mode or the profile (`memory.integrated.md`, `memory.discreet.md`).
  `brief/items/` holds one element of a list, `brief/refusals/` the refusals printed when
  there is no profile to read.
- A template has two syntaxes and no others: `{{name}}` prints a value, and
  `{{#name}}…{{/name}}` keeps what it encloses when the value is not empty. A name the script
  never declares stops the brief whole, naming the file.
- A new value is computed in `bin/ola-workflow-brief`, never in a template.
- A change to `brief/` is merged by the human, like a change to `bin/`: it is what every
  agent is told.

To change a rule, edit the Markdown. `scripts/brief-equivalence.sh` renders fifteen
profiles with your branch and with `origin/main`, and shows exactly what the change does to
each; for a rewrite that should change nothing, it must show nothing. `tests/brief.test.sh`
fails on a sentence that comes back into the script.

That is not tidiness. Seven prompts restating the same facts drift apart one justified edit
at a time, and `tests/agents.test.sh` holds the line from the other side: no agent may
name a base branch, a check command, a review status, a slot value or a line budget, since
those belong to the brief. Run it against an agent that hard-codes one and it says which.
