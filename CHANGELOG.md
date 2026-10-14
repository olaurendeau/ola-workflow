# Changelog

## Unreleased

### The product designer shows what it means, and someone else judges it

- **Visual work is published as a claude.ai artifact**, one per design, kept at the same
  URL from one request to the next. The product-designer writes the page outside the
  repository; a developer's task copies it, with its README, into `docs/design/<slug>/`
  through a reviewed pull request — the designer still changes nothing in the project.
- **In discreet mode, nothing is published until the human says yes**, asked by the
  coordinator. Publishing sends the page to claude.ai, and a project that did not ask for
  the workflow did not ask for its contents to leave the machine. Its designs stay in the
  profile's `runs/<slug>/design/`.
- **A new role, `design-reviewer`**, judges the page against the epic: every criterion
  shown, every state drawn, the words, accessibility, consistency with the screens next to
  it. Read-only, and without `Artifact`, so it cannot touch what it judges.
- **The product-designer now writes the words** a user reads — labels, empty states, errors
  — and the developer takes them verbatim. Nothing said who wrote them before, so whoever
  wrote the code last did.
- `context.design` in the profile names the design directory; the brief has a *Design*
  section and announces `docs/design` as its default.

## 0.3.1

**0.3.0 shipped with a merge escape. Update.**

```
claude plugin update ola-workflow@ola-workflow
```

### Three ways a merge got past the guard in 0.3.0

Each is one word from a form that was correctly refused, and each really runs the inner
command — measured on macOS and on GNU.

- **`env -u -h gh pr merge 7 --admin`** was allowed, where `env -u FOO gh pr merge 7 --admin`
  is refused. The help check scanned the leading run of dashes without knowing which of them
  take a value, so a `-h` that was an *option's value* read as a help request and the segment
  reported no command at all. Same for `env -u -V`, `exec -a -h`, `xargs -E -h`, `sudo -p -h`.
  The fix was to delete the second reader: the walk below it already knew which options take
  values, and asking the same question in two places is how the two came to disagree.
- **`coproc CO { gh pr merge 7 --admin; }`** was allowed, named `CO`. `coproc` without a name
  was handled; the named form put the coprocess's name where the command word goes.
- **`{fd}>log gh pr merge 7 --admin`** was allowed, named `{fd}>log`. `2>/dev/null` was
  handled; bash's varname file-descriptor spelling was not.

All three have test rows now, which is what their absence allowed.

### And four claims that were not true

- the README said the guard **refuses what a role does not own**. It refuses **two
  operations**: merging, and writing the review status. Pushing to the base branch, tagging,
  releasing, publishing and repository settings are refused by nothing — they are rules the
  prompts carry and nothing applies. The brief says so now, in the section an agent reads
  before it works;
- the README said four subprocesses with no profile where its own table said seven. Seven;
- `hooks/guard.sh` still carried "three independent samples, between 3% and 7%", a range a
  review could not reproduce. No number is written there now: `make measure` answers it;
- `scripts/measure.sh` could not tell a failure from a result — it read no exit status, so on
  a host whose `jq` is not in `/usr/bin` it printed `4`, the exact wrong number it exists to
  retire. And it claimed to write nothing outside its temporary directory, which was too
  strong.

## 0.3.0

**The guard applies its rules.** A project with no profile is still untouched; a project that
wrote one is guarded unless it says `"guard": "log"`.

### The guard

- **A tokenizer** reads what a shell would really run, rather than matching its text. The
  implementation this is ported from matches text, so `g\h pr merge` and `$(echo gh) pr merge`
  walk past rules that `gh pr merge` trips — measured, both do. Quote removal, escapes,
  `$'\x67h'`, wrappers (`sudo --user x`, `env FOO=1`, `nice -n 10`, `xargs -I{}`, `time -p`,
  short and long spellings of the options each one is known to take), grammar prefixes
  (assignments, redirections, reserved words, function headers, case labels, subshells,
  conditional expressions) and heredocs are all undone once, here. An option where the
  command word should be is refused rather than named, because the shell would look for a
  file of that name — which is how `time -p gh pr merge --admin` came to be allowed in
  silence, `time` having been both a reserved word and a wrapper.
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

### Measured, and the measurement ships

`make measure` reads `scripts/ordinary-commands.txt`, feeds each line to the guard as the
text of a payload — nothing is executed — and prints what was asked about and what it cost.
On its 90-command sample: **5 asked about, 0 refused**, and **7 external commands** per Bash
call with no profile, 14 with one and cached.

It exists because every number this repository published about the guard was wrong at least
once, and three of them because the *method* was wrong: a subprocess count that only counted
the tools the author had thought to instrument published 4 where 7 was true. A number nobody
can reproduce is a number nobody should believe.

The rate is a property of the sample, not of the guard — the same five commands read 15.6%
on a sample of 32 and 3.7% on one of 134. What is worth watching is which commands.

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
