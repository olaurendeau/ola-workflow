# Changelog

## Unreleased

### The guard can decide, and ships switched off

Without `OLA_WORKFLOW_GUARD=enforce` it **logs what it would have decided and allows the
command**. Turning that round is [#29](../../issues/29), because `escalation_extra` reserves
"changing what the guard forbids" for this repository's human. The number that default was
waiting for is now measured: **about 6% of ordinary commands ask, and nothing is refused
wrongly** — all of it the design's own cost, where the command a line runs is not in that
line at all (`source x`, `eval "$(…)"`, `trap … EXIT`, `$EDITOR file`).

- **A tokenizer** reads what a shell would really run, rather than matching its text. The
  implementation this is ported from matches text, so `g\h pr merge` and `$(echo gh) pr merge`
  walk past rules that `gh pr merge` trips — measured, both do. Quote removal, escapes,
  `$'\x67h'`, wrappers (`sudo -u x`, `env FOO=1`, `nice -n 10`, `xargs -I{}`), grammar
  prefixes (assignments, redirections, reserved words, function headers, case labels,
  subshells) and heredocs are all undone once, here.
- **Three decisions.** `allow` says nothing at all; `deny` and `ask` carry a reason.
  `ask` exists because a shell command cannot always be read, and refusing those would refuse
  `$EDITOR file` while allowing them is the hole the guard exists to close.
- **Fail-closed, but only once a profile exists.** A project that has not opted in gets a
  process and nothing else — the guard exits 0 before any rule. From a profile on, anything
  unexpected blocks rather than passes.
- **Rules read words, never text.** A joined string cannot express a position (so a label
  named "ready to merge" was read as a merge), cannot hold a literal (a review status named
  `c++-review` reached `grep -E` as a pattern), and cannot be case-folded field by field (`gh`
  accepts `-X put`). An option carries its value eight ways, including after a group of short
  flags; the group is parsed against a table of which letters take a value, and a letter in
  neither is asked about rather than guessed.
- **Two role rules.** Merging belongs to the coordinator — the CLI form and the API form
  alike, since a PUT on `pulls/N/merge` merges exactly as `gh pr merge` does. `--admin` and
  `--auto` are refused to every role, the coordinator included: one bypasses the checks the
  gate is made of, the other merges when the review no longer applies to what lands. The
  review status belongs to the pr-reviewer alone, under the name the *project's* profile gives
  it, because whoever writes it can let anything through.
- **One resolution per session.** Everything the guard reads from the profile is resolved
  together and cached; the absence of a profile is deliberately not cached, so a project that
  opts in *during* a session is guarded from the next command.

### Not in this release

The remaining role rules (pushing to the base branch, tags, releases, repository settings),
declarative `commands[]` rules, discreet mode's prohibitions, and the conditional merge gate.

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
