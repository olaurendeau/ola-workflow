# Changelog

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
