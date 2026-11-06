# GitHub tokens

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

- [`hooks/session.sh`](../hooks/session.sh), on `SessionStart`, appends one line to
  `CLAUDE_ENV_FILE`. Claude Code sources that file before each Bash command, subagents
  included (measured on 2.1.302). The line looks the base token up in the keychain each
  time, so the token is never written to a file.
- [`hooks/elevate.sh`](../hooks/elevate.sh), on `PreToolUse` for Bash, recognises the two forms
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

## Setting them up

The tokens live in the macOS keychain, so for now this works on macOS only. Run these in a
terminal, not in a Claude Code session, where `setup` refuses for lack of a keyboard. A
terminal does not have the plugin's commands on its `PATH`: the `export` line of
[Getting started](getting-started.md#2-install-the-plugin) adds them.

```bash
ola-workflow-tokens setup     # opens GitHub's form pre-filled, once per token, and stores what you paste
ola-workflow-tokens status    # who each token acts as, and when it expires
```

On each form, choose **Only select repositories** and pick the projects that have a
profile. A token expires after 90 days unless you change it on the form; `status` says when.

With no base token, every gh call of the session fails with a 401, and the session is told
why when it starts. `"github_tokens": "off"` in a profile turns all of this off, and the
agents then use your own login.

## Draft pull requests and the ready mark

Measured on 2026-11-06 with `gh` 2.102.0, for `"publish": "draft"` (#177): can the identity a
session holds open a draft pull request with `gh pr create --draft` and mark it ready with
`gh pr ready`?

- **A, a repository the token covers: measurement in progress.**
- **B, a repository outside the token owner's: not measured.**
- **C, a private repository on GitHub Free: not measured.**

## What it does not stop

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
