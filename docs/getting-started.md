# Getting started

From an empty machine to your first request, in six steps. Each one says what you should
see and what to do when you do not. The reference for each fact is a link, not a copy.

## 1. Prerequisites

You need these on your `PATH`:

- `bash` (the 3.2 that macOS ships is enough),
- `jq` 1.5 or later,
- `git`,
- `gh`, the GitHub CLI, logged in,
- Claude Code.

**macOS is needed for the GitHub tokens, and you should know it before you install
anything.** The three tokens live in the macOS keychain
([GitHub tokens](github-tokens.md#setting-them-up)). On another system, the plugin works
without them, but then nothing on GitHub's side refuses a merge or a review status that a
role does not own: the agents act with your own login. To say so on purpose, put this in
the profile you write in step 4, and skip step 3:

```json
"github_tokens": "off"
```

Two things are optional: Chrome or Chromium, for `ola-workflow-capture`
([Captures](configuration.md#captures)), and `ssh` for `ola-workflow-pr-assets` on an SSH
remote.

## 2. Install the plugin

```bash
claude plugin install ola-workflow --marketplace olaurendeau/ola-workflow
```

User scope is the default, which is what you want: install once, use everywhere.

*Expected:* the command exits 0 and `ola-workflow` is listed by `claude plugin list`.

*If it fails:* run `claude plugin install --help` and compare with the line above.

The plugin's commands (`ola-workflow-tokens`, `ola-profile`, and the others) are on the
`PATH` of a Claude Code session's Bash calls, and nowhere else. In a terminal they are
`command not found` until you add them. The install directory carries the plugin's version, so
ask Claude Code where it is instead of typing it:

```bash
export PATH="$(claude plugin list --json | jq -r '.[] | select(.id == "ola-workflow@ola-workflow") | .installPath')/bin:$PATH"
```

This lasts for that terminal only. Run the line again in each new terminal where steps 3 and 5
ask for a command, and after the plugin has been updated.

## 3. Create the tokens

In the terminal of step 2, not in a Claude Code session: the command reads the tokens from
your keyboard, and refuses to run without one.

```bash
ola-workflow-tokens setup
```

For each of the three tokens it opens GitHub's form pre-filled and stores what you paste.
On each form choose **Only select repositories** and pick the projects that will have a
profile ([the details](github-tokens.md#setting-them-up)).

*Expected:* the last lines come from `ola-workflow-tokens status`, one per token:

```
base    ok, acts as <your login>, expires <date>
merge   ok, acts as <your login>, expires <date>
review  ok, acts as <your login>, expires <date>
```

*If it fails:*

- `present, but GitHub rejects it (expired or revoked?)`: the token has expired, which
  happens after 90 days unless you changed it on the form. Run
  `ola-workflow-tokens setup <kind>` for that one.
- `missing — ola-workflow-tokens setup <kind>`: run what it says.
- `the tokens live in the macOS keychain` (the message goes on to name `security`): you are
  not on macOS. See step 1.
- With no base token, every `gh` call of an agent session fails with a 401, and the session
  starts with the message `there is no base GitHub token in the keychain`. Run
  `ola-workflow-tokens setup`.

## 4. Write the project's profile

In the project, in a Claude Code session:

```
/ola-workflow:workflow-init
```

It asks the one thing it must not guess, whose project this is, detects the rest from the
repository, shows you the file before writing it and reads it back. What it writes and why:
[Writing the first one](configuration.md#writing-the-first-one).

*Expected:* it ends with a report naming the file it wrote and its scope. In an `integrated`
project that file is a change to the repository: commit it yourself, `workflow-init` never
does.

*If it fails:* a project without a profile is left alone by the plugin. Asked for its
rules, the brief answers `No ola-workflow profile applies to this project`: that is not an
error, it is the plugin staying out of the way until `workflow-init` has run.

## 5. Check it

In the project's directory, in the terminal of step 2:

```bash
ola-profile validate
ola-profile path
```

*Expected:* `validate` prints nothing and exits 0; `path` prints the file that applies, which
should be the one `workflow-init` reported. If it is another, a profile of yours overrides
the one you just wrote, and nothing you configured is in effect.

*If it fails:*

| you see | what it means |
|---|---|
| `command not found` | the plugin's `bin/` is not on this terminal's `PATH`. Run the `export` line of step 2 in it. |
| `no profile found` | no profile applies to this directory. `ola-profile path` prints nothing and exits 1. Run step 4 in the project, not above it. |
| `not valid JSON` | the file is not JSON. It is named in the message. |
| `profile: expected object, got array` | the file is JSON, but not an object: the message names the type it found. |
| `profile/mode: "bogus" is not one of integrated, discreet` | a value the schema refuses, with its path in the profile. One line per problem. |

Where a profile may live and which one wins: [How a project is configured](configuration.md#how-a-project-is-configured).

## 6. Make your first request

Open the project with the coordinator, who is the only agent you talk to:

```bash
claude --agent ola-workflow:coordinator
```

In an `integrated` project, `workflow-init` has already written that into
`.claude/settings.json`, so a plain `claude` is enough.

Then ask for something small and concrete, in a sentence.

*Expected:* the coordinator starts by running `ola-workflow-brief`, then frames your request
and says what it would do before it does it.

*If it does not:* check the agent name, which Claude Code refuses when it is unknown, and run
step 5 again.

## Where next

- [Configuration](configuration.md): every key of the profile.
- [GitHub tokens](github-tokens.md): what the tokens allow and what they do not stop.
