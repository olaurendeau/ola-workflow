# ola-workflow

A team of Claude Code agents — a coordinator, a product designer and an independent design
reviewer, an architect, developers working in isolated worktrees, and an independent PR
reviewer — whose two irreversible acts, merging and setting the review status, GitHub itself
keeps with the role that owns them.

The workflow is **generic**: everything project-specific lives in a profile file, so the
same plugin drives a project you own and a repository you contribute to twice a year
**without committing anything to it**.

## Install

```
/plugin install ola-workflow --marketplace olaurendeau/ola-workflow
```

or, from a shell:

```bash
claude plugin install ola-workflow --marketplace olaurendeau/ola-workflow
```

User scope is the default, which is what you want: install once, use everywhere. Then, in a
terminal, create the tokens the agents work with — see [GitHub tokens](#github-tokens):

```bash
ola-workflow-tokens setup
```

## Status

**The team is complete, and GitHub refuses two things a role does not own.** Two, not all:
merging belongs to the coordinator and the review status to the pr-reviewer, and every agent
works with a token that can do neither. Pushing to the base branch, tagging, releasing,
publishing and changing repository settings are **not refused by anything** — they are rules
the prompts carry and nothing applies, which is a different thing from a rule. See
[What it does not stop](#what-it-does-not-stop).

In place: the manifests, the CI,
the test harness, the answer to how a plugin agent is identified (see
[Agent identity](#agent-identity)), the project profile with its schema and its
`ola-profile` CLI, the **seven agents** — a coordinator that frames and dispatches, a product
designer that turns a request into criteria a test can prove and the words a user reads, and
for visual work publishes the design as a claude.ai artifact it keeps at one URL, a design
reviewer that judges that page against the epic, an architect that splits an
epic into reviewable tasks, developers that build test-first in their own worktrees, an
independent reviewer, and a security reviewer dispatched beside it when a change touches the
paths the project declares, whose blocking findings each go to a second, cold reading before
a developer sees them — and the **role tokens**.

A project with no profile is unaffected, which is the whole point of the design: both hooks
exit before doing anything, and its sessions keep your own GitHub login.

### What is not here yet

| step | content |
|---|---|
| A3 | pushing to the base branch, tags, releases, repository settings |
| A4 | declarative `commands[]` rules, discreet mode's prohibitions, the conditional merge gate |
| A6 | the `verify-ui` skill, then 1.0.0 |

Until the merge gate exists, the coordinator checks it by hand against the forge: GitHub
checks *who* merges, not whether the checks were green.

## What each agent runs on

| agent | `model` | `effort` | what it buys |
|---|---|---|---|
| coordinator | *(none)* | *(none)* | the session agent: the human picks its model |
| product-designer | `sonnet` | *(none)* | long writing, bounded by a glossary and a brief |
| design-reviewer | `sonnet` | *(none)* | a checklist held against one page |
| architect | `opus` | *(none)* | a plausible split whose third task needs the fifth is paid for in full |
| developer | `sonnet` | `high` | the largest volume here, on a task already specified file by file |
| pr-reviewer | `opus` | `high` | the defect the author could not see — twice at a time, since 0.5.0 runs a reviewer per slot |
| security-reviewer | `opus` | `high` | a path from an attacker to a sink, and the refutation of every path that is not one: a false positive costs a developer a cycle |
| probe | `haiku` | `low` | one `echo`, so that a hook records a payload |

The rule is **Opus where a wrong judgement costs a whole cycle, Sonnet where the volume is.**
The design-reviewer and the pr-reviewer are not the same kind of reviewer, which is why they
are not on the same model: the design-reviewer holds a page against criteria somebody already wrote down, and
the pr-reviewer has to find what nobody wrote down.

The `high` pins are a ceiling rather than a cut. They hold the three heaviest roles at
`high` however high the session is set, and the session is what they used to follow.

The coordinator pins nothing, deliberately. It is the role a project names as its session
agent, and a frontmatter `effort` is measured to have no effect at all there — see
[Agent identity](#agent-identity). So a key on the coordinator would be either ignored, or,
for the model, a choice taken behind the human who set the session's.

Two things follow from pinning the others:

- **`CLAUDE_CODE_SUBAGENT_MODEL` no longer reaches them.** A model resolves in this order:
  the `model` parameter of the dispatch, then the frontmatter, then that variable, then the
  session's model. Past the second step the variable is never read, so the one remaining way
  to run a role on something else for a single dispatch is that parameter — which the
  coordinator holds.
- **`effort` and `model` are not claims of the same strength.** A `PreToolUse` payload
  carries `effort`, so what a plugin subagent reflects at is *measured* — see
  [Agent identity](#agent-identity). No payload field carries the model, so that column is
  read from the documentation and seen in the session, not measured.

`tests/agents.test.sh` keeps this table as a map declared beside the test: a role that stops
pinning its model, pins another one, or is added without being named in the map fails by
name.

What is deliberately **not** written here is a saving. A saving is a number that has to be
*true*, not merely unchallenged, so it belongs to something that recomputes it rather than to
a sentence every later review would have to check again.

## GitHub tokens

The agents never hold your GitHub login. In a project with a profile, every Bash command of
the session — the coordinator's and each subagent's — runs with `GH_TOKEN` set to a **base**
token. It reads the code, writes pull requests and issues and reads statuses, and it can
neither merge nor write a commit status. GitHub refuses those two with a 403, however the
command is written: `gh pr merge`, `gh api -X PUT …/merge`, `curl`, a script, an alias.

Two commands, in one exact form each, run with a stronger token:

| who | the command, exactly | token | its permissions |
|---|---|---|---|
| coordinator | `gh pr merge <N> --squash --match-head-commit <SHA>` | merge | contents: write, pull requests: write |
| pr-reviewer | `gh api repos/{owner}/{repo}/statuses/<SHA> -f state=… -f context=<review_status> [-f description='…'] [-f target_url=…]` | review | commit statuses: write |
| everyone | anything else | base | contents: read, pull requests: write, issues: write, commit statuses: read, actions: read |

`<SHA>` is the full 40 characters, and nothing may come before, after or around the command.

The base token cannot read check runs: GitHub gives the Checks API to no fine-grained token
(a classic one with `repo` can read it), so `gh pr checks` fails with "Resource not
accessible by personal access token". The brief has the agents read a SHA's GitHub Actions
jobs and its commit statuses instead, which carry the same names. A check posted by an app
other than GitHub Actions is in neither, and the agents are told to ask you about a required
check they cannot find.

How it is wired:

- [`hooks/session.sh`](hooks/session.sh), on `SessionStart`, appends one line to
  `CLAUDE_ENV_FILE`. Claude Code sources that file before each Bash command, subagents
  included (measured on 2.1.302). The line looks the base token up in the keychain each
  time, so the token is never written to a file.
- [`hooks/elevate.sh`](hooks/elevate.sh), on `PreToolUse` for Bash, recognises the two forms
  with one regular expression each, over a character set with no shell metacharacter in it.
  It checks that the role owns the form (from `agent_type`) and that the project is
  `integrated`, then rewrites the command to run through `hooks/lib/with-token.sh` and allows
  it.
- Every other command passes untouched: no rewrite, no decision, and your permission rules
  apply as written. That is deliberate, because a rewritten command is the one the
  permission rules are matched against (measured), so rewriting every command would turn
  every allowlisted one into a question.
- When anything goes wrong, a right is lost and never gained. A form the hook does not
  recognise runs with the base token, and GitHub refuses it.

This replaces a guard that read command lines looking for the same two operations. It had to
undo every spelling a shell accepts, and each spelling it missed was a merge it let through:
0.3.2 alone fixed fifty-seven of them, and three more were still open. A token cannot be
misspelled.

### Setting them up

The tokens live in the macOS keychain, so for now this works on macOS only.

```bash
ola-workflow-tokens setup     # opens GitHub's form pre-filled, once per token, and stores what you paste
ola-workflow-tokens status    # who each token acts as, and when it expires
```

On each form, choose **Only select repositories** and pick the projects that have a
profile. A token expires after 90 days unless you change it on the form; `status` says when.

With no base token, every gh call of the session fails with a 401, and the session is told
why when it starts. `"github_tokens": "off"` in a profile turns all of this off, and the
agents then use your own login.

### What it does not stop

- **An agent that sets out to get around it.** The tokens live in your keychain, under your
  user. An agent that runs `security find-generic-password` itself, or sets its own
  `GH_TOKEN`, gets them. This stops mistakes and misreadings, not an agent determined to
  break the rules.
- **`git push`.** Git authenticates with your own credentials (keychain or SSH), not with
  `GH_TOKEN`, so an agent can push to the base branch. On a free plan with a private
  repository, nothing on GitHub's side can refuse that. Branch protection or a ruleset can,
  on a public repository or a paid plan. And if `gh auth git-credential` is your only git
  credential helper, git uses the base token and pushing fails: configure another helper,
  or SSH.
- **The merge gate's conditions.** GitHub checks *who* merges. Whether the checks and the
  review status are green on the head SHA is still the coordinator's to verify.
- **The main session with no agent.** It has no `agent_type`, so it holds the base token and
  nothing is elevated. Merge from your own terminal.

### Where the rules live

The agents share one source: `ola-workflow-brief`, on the PATH beside `ola-profile`. It
resolves the profile and prints the rules that follow from it — mode, languages, base
branch, commands, slots, escalation, restricted commands, where the memory goes, what the
merge gate requires. Each agent starts by running it, and each prompt holds only what is
specific to its role.

That is not tidiness. Seven prompts restating the same facts drift apart one justified edit
at a time, and `tests/agents.test.sh` holds the line from the other side: no agent may
name a base branch, a check command, a review status, a slot value or a line budget, since
those belong to the brief. Run it against an agent that hard-codes one and it says which.

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
prints the host it parsed: a remote URL carrying credentials will have part of that URL
read back, which ends up in agent transcripts. Credentials belong in a credential helper,
not in a remote URL.

No profile means no effect: the hook exits 0 and the agents offer to run
`/ola-workflow:workflow-init`, the skill that writes one.

### Writing the first one

```
/ola-workflow:workflow-init
```

It establishes the identity, asks the one thing it must not guess — whose project this is,
which decides both the mode and the scope the file is written in — detects what the
repository can tell it, shows the file before writing it, and reads the result back as an
agent will receive it.

It writes a key only on a positive result, and that is the rule it is built around: an
omitted key reads as *not declared* in the brief, which an agent treats as a question for
the human, while an invented one reads as this project's rule — a check command nobody runs,
enforced by a reviewer against a developer. `slots`, `pr`, `merge`, `commands`,
`db_hosts_allowed` and `verify_ui` are not detectable at all and are left out unless you
state them.

The file is described by [`schema/profile.schema.json`](schema/profile.schema.json), which
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
| `github_tokens` | `keychain` (the default) or `off` — see [GitHub tokens](#github-tokens) |
| `db_hosts_allowed` | the databases an agent may connect to |
| `context` | the documents the agents read: product, architecture, review checklist, security precedents, glossary; and `design`, where each design is documented (`docs/design` by default, integrated mode only) |
| `verify_ui` | how a change is seen running |
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
[`.claude/workflow.json`](.claude/workflow.json): the workflow is developed with the
workflow, which is the only honest test of how generic it is. Its
[`.claude/settings.json`](.claude/settings.json) makes every session opened here an
`ola-workflow:coordinator`, on the installed plugin rather than this tree, so the plugin is
not rewritten under itself while it works. For an ordinary session, name another agent:
`claude --agent <name>`.

|  | integrated | discreet |
|---|---|---|
| Memory | GitHub issues, labels, a review commit status, review comments | local files under the profile directory |
| Conventions | the profile, plus the project's own CONTRIBUTING | read from the project: CONTRIBUTING, PR template, commit language |
| Writes to GitHub | allowed, per role | issues, labels, comments, statuses: **refused**. `git push` and `gh pr create`: **ask** (a human confirms) |
| Merge | the coordinator, through the merge gate; the `RFR` label marks a pull request that passes it | nobody |

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

## Agent identity

<!-- spike:begin -->
Three things the documentation does not say, and that the hooks, the default session agent
and the per-role models all depend on. Measured with `make spike` on **Claude Code 2.1.305**,
2026-10-20:

| scenario | `agent_type` | `agent_id` | `effort` |
|---|---|---|---|
| main session, no agent | *absent* | *absent* | `high` |
| subagent, `subagent_type: ola-workflow:probe` | `ola-workflow:probe` | present | `low` |
| subagent, `subagent_type: probe` | — the call fails, see below | — | — |
| `--agent ola-workflow:probe` | `ola-workflow:probe` | *absent* | `medium` |
| `--agent probe` | `ola-workflow:probe` | *absent* | `medium` |
| `"agent"` passed with `--settings` | `ola-workflow:probe` | *absent* | `medium` |
| `"agent"` in a project's `.claude/settings.json` | `ola-workflow:probe` | *absent* | `medium` |
| subagent, `CLAUDE_CODE_EFFORT_LEVEL=high` | `ola-workflow:probe` | present | `high` |

The `effort` column is read from the payload of the same probe, which pins `effort: low`.

What this means:

- **`agent_type` is always the namespaced name** `<plugin>:<agent>`, both for a subagent and
  for a session agent. A plugin agent has no bare alias. The name is built from the plugin
  name, the path under `agents/` and the frontmatter `name`, so `agents/<dir>/<name>.md`
  would be `ola-workflow:<dir>:<name>`. (A template, not a name: `tests/agents.test.sh`
  checks that every `ola-workflow:…` written in a prompt or here resolves to something
  shipped, so an illustration has to be visibly an illustration.) The elevation hook accepts
  only an `ola-workflow:` name and keeps the part after the last `:`.
- **`agent_id`, not `agent_type`, tells a subagent from a session agent**: it is present only
  inside a subagent, and absent on the main thread even under `--agent`.
- **A missing agent has no `agent_type` key at all** — not `""`, not `main`.
- **`settings.json` accepts the namespaced name**, including in a project's committed
  `.claude/settings.json`, which is how a project pins its default agent:
  `"agent": "ola-workflow:coordinator"`. `--agent` additionally accepts the bare name
  (resolved by `:`-suffix), and a missing `--agent` is fatal while a missing settings `agent`
  only warns.
- **The Agent tool is different: `subagent_type` is an exact match.** A bare name does not
  resolve to a plugin agent:

  ```
  Agent type 'probe' not found. Available agents: claude, Explore, general-purpose,
  ola-workflow:probe, Plan, statusline-setup
  ```

  So the coordinator has to dispatch `ola-workflow:developer`, never `developer`. The same
  holds for a skill's `agent:` key.
- **A frontmatter `effort` reaches a subagent — and only a subagent.** `probe` pins
  `effort: low`: dispatched with the Agent tool it runs at `low`, and the very same file run
  as a session agent runs at `medium`, which is the model's own default and not what the file
  asks for. The key is read exactly where the work happens, and the coordinator could not pin
  its own effort even if that were wanted.
- **`CLAUDE_CODE_EFFORT_LEVEL` outranks the frontmatter.** The same dispatch with it set to
  `high` runs at `high`, not at the `low` the file asks for — so it is the session's escape
  hatch from every effort this plugin pins. The model has no hatch of that shape: there the
  frontmatter outranks `CLAUDE_CODE_SUBAGENT_MODEL`, not the other way round.
- **No payload field carries the model.** The fields below are all a hook is offered, so what
  a role runs *on* cannot be measured this way — only what it runs *at*. That is the whole
  difference in strength between the two columns of
  [What each agent runs on](#what-each-agent-runs-on).

The fields a `PreToolUse` payload offers a hook, as measured:
`agent_id`, `agent_type`, `cwd`, `effort`, `hook_event_name`, `permission_mode`, `prompt_id`,
`session_id`, `tool_input`, `tool_name`, `tool_use_id`, `transcript_path`. `effort` is an
object — `{"level": "high"}` — not a string.

Re-run `make spike` after a Claude Code upgrade: none of this is contractual. The eight
scenarios live in [`scripts/spike/agent-identity.sh`](scripts/spike/agent-identity.sh); it
loads the plugin with `--plugin-dir`, so nothing is installed and nothing is written inside
the repository.
<!-- spike:end -->

### Publishing an artifact from a plugin agent

The product-designer publishes visual work as a claude.ai artifact and keeps it at one URL.
Measured on **Claude Code 2.1.299**, 2026-10-14, with
[`scripts/spike/agent-artifact.sh`](scripts/spike/agent-artifact.sh):

| scenario | `Artifact` available | publish, then publish with `url` |
|---|---|---|
| `claude -p`, main session | no | — |
| `claude -p`, plugin agent declaring `Artifact` | no | — |
| interactive, `general-purpose` subagent | yes, loaded directly | not measured |
| interactive, plugin agent declaring `Write, Artifact` | yes | same URL, version 1 then 2 |

So a plugin agent gets the tool by naming it in `tools:`, and a second publish with `url`
updates the page in place. **Headless runs have no `Artifact` at all**, the main session
included, which is why this spike is replayed by hand: `make spike-artifact` prints the
session to start and the prompt to paste. It publishes one private page in the account of
whoever runs it.

## Development

```bash
make check     # everything the CI runs: lint, test, validate
make lint      # shellcheck, in its own container (nothing to install)
make test      # the bash suites: tests/run.sh
make validate  # claude plugin validate --strict .
make spike     # replays the agent-identity spike
make spike-artifact  # prints how to replay the artifact spike, by hand
scripts/token-cost.sh [--since D] [--until D] <dir>...  # weighted token cost per role and per PR, from ~/.claude/projects/<slug>/
```

### One writing convention, enforced by the suite

`tests/agents.test.sh` checks that every `ola-workflow:<name>` written in an agent prompt,
in `ola-workflow-brief` or in this README resolves to something shipped, and that a command
this plugin provides is never written as a bare `/name`. Both catch the same defect: a
prompt that offers a human a command which does not exist, found only at the one moment the
plugin had to explain itself.

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
the last one refused `$profile_dir/runs/<slug>/developer`, a path the brief itself writes.

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

The test suites fake `PreToolUse` payloads and never execute the commands they contain.
They need `bash`, `jq`, `perl` and `git` only — the suites build throwaway repositories —
and run identically on macOS (bash 3.2) and on CI. `tests/run.sh` refuses up front when one
is missing, rather than failing a hundred assertions that name the wrong cause.
