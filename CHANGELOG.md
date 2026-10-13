# Changelog

## 0.3.0

**The guard applies its rules.** A project with no profile is still untouched; a project that
wrote one is guarded unless it says `"guard": "log"`.

### The guard

- **A tokenizer** reads what a shell would really run, rather than matching its text. The
  implementation this is ported from matches text, so `g\h pr merge` and `$(echo gh) pr merge`
  walk past rules that `gh pr merge` trips — measured, both do. Quote removal, escapes,
  `$'\x67h'`, wrappers (`sudo --user x`, `env FOO=1`, `nice -n 10`, `xargs -I{}`, both
  spellings of every option), grammar prefixes (assignments, redirections, reserved words,
  function headers, case labels, subshells) and heredocs are all undone once, here.
- **Three decisions.** `allow` says nothing at all; `deny` and `ask` carry a reason. `ask`
  exists because a shell command cannot always be read, and refusing those would refuse
  `$EDITOR file` while allowing them is the hole the guard exists to close.
- **Fail-closed, and it no longer fails open.** With `jq` off the PATH every field read came
  back empty, so the guard took its "another tool's payload, not my business" exit — 0,
  silently, with a profile present. `gh pr merge --admin` ran. The tools are checked up front
  now, conditional on a profile the way every other refusal is.
- **Rules read words, never text.** A joined string cannot express a position (a label named
  "ready to merge" was read as a merge), cannot hold a literal (a review status named
  `c++-review` reached `grep -E` as a pattern), and cannot be case-folded field by field (`gh`
  accepts `-X put`). An option carries its value eight ways; short groups are parsed against a
  table of which letters take a value, because the guess that every letter before the target
  is boolean let `-tX -X PUT` merge.
- **Two role rules.** Merging belongs to the coordinator — the CLI form and the API form
  alike, since a PUT on `pulls/N/merge` merges exactly as `gh pr merge` does. `--admin` and
  `--auto` are refused to every role, the coordinator included: one bypasses the checks the
  gate is made of, the other merges when the review no longer applies to what lands. The
  review status belongs to the pr-reviewer alone, under the name the *project's* profile gives
  it, because whoever writes it can let anything through. A write whose body comes from a file
  or stdin is asked about rather than guessed — `gh api` sends POST as soon as a parameter is
  added, so `--input body.json` is a write with no `-X` in sight.
- **One resolution per session**, cached; the absence of a profile is deliberately not cached,
  so a project that opts in *during* a session is guarded from the next command.

### `/ola-workflow:workflow-init`

The skill that writes a project's profile. It asks the one thing it must not guess — whose
project this is, which decides both the mode and where the file goes — detects the rest, and
writes a key only on a positive result: an omitted key reads as *not declared* in the brief,
which an agent treats as a question, while an invented one reads as the project's rule.

`ola-profile where [user|project]` answers before any profile exists, which `path` cannot do
and creating the first one needs; `ola-profile schema` names the file the CLI validates
against.

### Fixed

- `ola-profile get … --slot N` dropped `--slot` **in silence** when it came after the
  subcommand — the form the README documents. It returned `make check SLOT={slot}` and an
  agent ran that literally. Options are now read wherever they are written.
- `merge.sensitive_paths` named `hooks/guard.sh` alone, so the library the guard sources was
  outside the zone reserved for a human.

### Measured, on 2026-10-14

**3.7%** of 134 ordinary commands are asked about, and **none refused wrongly**; four
independent samples put the range at 3–7%. The rate is a property of the sample and not of
the guard: the same five commands are asked about either way, so a 32-command sample holding
all five reads 15.6%. What is worth watching is which commands, not the percentage — all five
run something that is not in their own text. The cost per Bash call is 4 subprocesses with no
profile, 8 warm with one.

### Not in this release

The remaining role rules (pushing to the base branch, tags, releases, repository settings),
declarative `commands[]` rules, discreet mode's prohibitions, the conditional merge gate, and
the `verify-ui` skill.

## 0.2.0

The profile and the team. **The guard still allows everything** — see *Not in this release*.

### A project is described by a profile, not by the plugin

- `schema/profile.schema.json` describes it, and a jq mini-validator **interprets** that
  schema rather than restating it, so a key added there is checked with no code change.
  `additionalProperties: false` everywhere: a misspelt key is an error, not a silence.
- Resolution looks in `~/.claude/workflow-profiles/<host>/<owner>/<repo>/profile.json`
  first, then `<project>/.claude/workflow.json`. **Yours wins over the one a repository
  ships**, because a third-party repository must not be able to turn the discreet profile
  you chose for it into an integrated one.
- `ola-profile path|dir|id|mode|get|show|validate`, on the PATH of every Bash call.
- A profile that cannot be read never yields a value: `ola_profile_get` returns the default
  you passed for a key the profile lacks, and nothing at all for a profile nobody can
  parse. The two are indistinguishable on purpose, so inventing a configuration takes a
  deliberate act.

### Five agents

A coordinator that frames and dispatches, a product designer that turns a request into
criteria a test can prove, an architect that splits an epic into reviewable tasks,
developers that build test-first in their own worktrees, and an independent reviewer that
pins a SHA and publishes nothing when it could not run the checks.

`ola-workflow-brief` holds the rules they share — mode, languages, base branch, commands,
slots, escalation, restricted commands, memory location, merge gate — resolved from the
profile. Each prompt keeps only its role. It also says which values are the plugin's
defaults rather than the project's, and refuses outright rather than inventing a
configuration.

### Known, from the start

`agent_type` carries the namespaced name (`ola-workflow:developer`) in a hook payload, and
`subagent_type` is an exact match, so a bare role name does not resolve. Measured, not
assumed: `make spike` replays it.

## Not in this release

**The guard allows everything.** `hooks/guard.sh` ends in `exit 0`, so every rule above is
a rule the agents follow and nothing enforces: an agent that follows a rule and an agent
that is prevented from breaking it are not the same thing. Nothing stops a push to the base
branch, a merge without review, a publication or a tag.

Use this where a mistake is cheap — a new project, not one that deploys on merge.

*Corrected after 0.2.0 was tagged:* this section first said the tokenizer the real rules
need "is written and measured, and it is not wired in yet". It is neither in this release
nor on `main` — it is on an open branch. Anyone reading that sentence and going to look for
the file would not have found it, which is a different and worse thing than "not wired in".
The tag is left where it is; the sentence is not.

## 0.1.0

The plugin skeleton, the marketplace, CI (shellcheck in a container, bash suites,
`claude plugin validate --strict`), and the spike that settled how a plugin agent is
identified.
