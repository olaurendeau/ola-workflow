---
name: workflow-init
description: Writes this project's ola-workflow profile. Inspects the repository, asks the human the one thing that cannot be inferred — whose project this is — and creates the profile file the plugin resolves, in the right scope. Use it when the plugin reports that no profile applies, or when a profile needs rewriting from scratch.
---

The plugin does nothing until it finds a profile. Your job is to write that file, once,
with values this repository actually has — and to leave out the ones it does not.

**A key you invent is worse than a key you omit.** An omitted key reads as "not declared"
in `ola-workflow-brief`, which an agent treats as a question for the human. An invented one
reads as this project's rule: a check command nobody runs, a branch that does not exist, a
line budget nobody set, each enforced by a reviewer against a developer. So every value you
write comes from something you ran or something the human told you, and nothing else.

## Steps

1. **Look at both places a profile can be, not at the one that wins.** `ola-profile where`
   lists every candidate, in precedence order, whether a file is there or not. For each
   line, check whether that file exists.

   `ola-profile path` answers something different — which profile *applies* — and that is
   the wrong question here. A repository can carry a committed profile while the human's own
   one overrides it: looking only at `path` showed one file and let step 5 overwrite the
   other, which the human had never been shown.

   If a file exists in the scope you are about to write, print it (`ola-profile show` if it
   is also the one that applies, otherwise `cat` it) and ask the human whether to replace it
   before touching anything. A profile is what grants forge writes and merge authority, so
   overwriting one silently is a privilege change nobody asked for.

   If a file exists in the *other* scope, say so: it changes which one will apply.

2. **Establish the identity, and find out which scopes are available.** `ola-profile id`
   prints `<host>/<owner>/<repo>`, resolved from `git remote get-url upstream || origin`.

   | what answers | what it means |
   |---|---|
   | both `where user` and `where project` | both scopes are open; step 3 chooses |
   | only `where project` (no remote yet) | a fresh `git init`: the committed scope is the only one, because a user-scope profile is keyed on the remote |
   | neither | not a git repository at all. Say so and stop — there is nothing to key a profile on |

   Do not stop merely because `id` fails: a repository with no remote is the common case for
   a project being started, and everything except the user scope works there.

   If the URL carried credentials, `id` will have read part of them back. Say so — they
   belong in a credential helper, not in a remote URL — and do not repeat the value.

3. **Ask the one question that cannot be inferred: whose project is this?** Use
   `AskUserQuestion`. Never guess it, in either direction, and never infer it from the
   remote's owner — the human may contribute to a repository they own, or run the workflow
   discreetly on their own.

   | answer | mode | the file goes to |
   |---|---|---|
   | mine, and the workflow is committed with it | `integrated` | `ola-profile where project` |
   | someone else's, or nothing is to be committed | `discreet` | `ola-profile where user` |

   If they choose `discreet` and step 2 found no remote, say so and stop there: a user-scope
   profile is keyed on the remote, so there is nowhere to put one. Offer the two ways
   forward — add the remote and run this again, or commit the profile instead — and let them
   pick. Do not quietly write the committed file after they asked for nothing committed.

   What turns on it: in `integrated` the agents write to the forge — issues, labels, review
   statuses — and the coordinator merges. In `discreet` none of that is allowed, the memory
   is local, and nobody merges. Guessing `integrated` for a repository that did not ask for
   it is the mistake with consequences, so when the human's answer is unclear, ask again
   rather than pick the permissive one.

   Run the `where` command for the scope they chose and use exactly the path it prints. Do
   not build that path yourself: the layout is the resolver's, and a file written next to
   where it looks is a file it never reads.

   If the human wants the workflow committed but step 2 found no remote, that is fine —
   `where project` works without one.

4. **Detect what the repository can tell you.** Run things; do not read a filename and
   conclude. For each key below, write it only on a positive result:

   | key | how to find it | if nothing is found |
   |---|---|---|
   | `check.full` | the one command that runs everything CI runs: a `check` target in a Makefile, a `check`/`test` script in `package.json`, a CI workflow's own command | ask the human; it is the contract between a developer and a reviewer, and nothing else can supply it |
   | `check.affected` | a narrower target or script, if one exists | omit it — the brief then says the full command is the only one |
   | `context.product`, `.architecture`, `.review_checklist`, `.glossary` | each one only if that file exists | omit the ones that do not |
   | `context.design` | a directory that already holds the project's designs or mockups, in `integrated` mode only | omit it — the brief then uses `docs/design` and says it is a default |

   Everything else is **not** detectable, and goes in only if the human states it:

   - `base_branch` — leave it out. The brief resolves it from `origin/HEAD` itself and marks
     that it did, which is strictly better than a value here: the detection prints
     `origin/main`, and a profile saying `base_branch: origin/main` is a branch no repository
     has. Valid JSON, valid against the schema, wrong — and invisible, because the brief has
     no reason to doubt a key the profile states. Write it only if the human names a branch
     that is not `origin/HEAD`.
   - `language` — three keys, and the language of commit subjects tells you about at most
     one of them. Guessing `language.agents` from the commit log is inventing two keys out of
     three. Ask, or leave the whole object out; English is the default and the brief says so.
   - `slots`, `pr`, `merge`, `commands`, `db_hosts_allowed`, `verify_ui` — nothing in a
     repository states these. Omitted, they produce a notice in the brief; invented, they
     produce a rule.
   - `preview` — a web interface cannot be told from a repository either. Ask the human
     whether the project has one, and only then for three things: the command that starts
     it on a slot and hands the shell back once the app answers, its URL, and the command
     that stops it. Nothing is written without an answer.
   - `github_tokens` — leave it out, which means `keychain`: every agent works with a
     GitHub token that can neither merge nor write a commit status, and only the
     coordinator's exact merge and the pr-reviewer's exact review status get a stronger one.
     Tell the human the three tokens have to exist, and that they create them with
     `ola-workflow-tokens setup` in a terminal. Write `"github_tokens": "off"` only if the
     human asks for it, and say what that costs — the agents then hold the human's own
     login, and every rule in the brief applies only as far as they choose to apply it.

   In `discreet` mode, `context.*` paths point inside the profile directory, not into the
   repository — the repository is not yours to add documents to.

5. **Show the file before writing it.** Print the JSON you intend to write, each value next
   to where it came from — detected and how, or stated by the human. A value whose origin
   you cannot name is a value to drop. Then write it, after the human agrees.

   **Do not write a `"$schema"` key.** The schema travels with the installed plugin, under a
   path that holds the version (`…/plugins/cache/ola-workflow/ola-workflow/<version>/…`), so
   every value available to you is right on one machine until the next plugin upgrade — and
   in project scope the human then commits it for everyone else. `$schema` is also a key
   nothing in this plugin reads back, so a wrong one stays wrong silently; `ola-profile
   validate` is the reader, and it finds the schema itself.

   Tell the human instead that `ola-profile schema` prints the file, which is what they
   point their editor at, and that the path changes when the plugin is upgraded.

   Create the directory if it does not exist — in user scope it will not, and in project
   scope a fresh repository has no `.claude/` either.

6. **Validate the file you wrote, then read back what will actually apply.**

   ```
   ola-profile validate <the path you wrote>   # every problem in that file, or silence
   ola-profile path                            # the profile that applies
   ola-workflow-brief                          # the rules as the agents receive them
   ```

   Pass the path. `ola-profile validate` with no argument validates whichever profile
   *applies*, which can be the other scope's file — and then it reports problems in a file
   you did not touch, or silence about the one you did.

   Then check that `ola-profile path` is the file you wrote. If it is not, say so plainly
   and first: the profile exists, and another one overrides it, so nothing you just
   configured is in effect.

   Read the brief yourself before showing it. If it announces a value the human did not
   choose and you did not detect, a key is wrong — fix the profile, not the brief.

7. **Report**, naming three things: the file you wrote and its scope, every key you left
   out with what the brief will say instead, and — in `integrated` mode — that the file is
   a change to the repository and needs committing. Do not commit it yourself: it is the
   profile that decides what the agents may do, so it is the human's to put under version
   control.

## What you do not do

You do not enable a mode the human did not pick, you do not write a key to make the brief
look complete, and you do not commit or push. If the repository already has a profile you
did not get permission to replace, stop and say so.
