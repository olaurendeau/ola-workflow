# Changelog

## 0.9.0

**The coordinator never runs as a sub-agent.** A coordinator dispatched as a sub-agent loses
its prompt cache after 5 minutes and never compacts its context, which is ruinous for a role
that spends its time waiting. Measured with `scripts/token-cost.sh` on one project: an average
context of 442k tokens, up to 966k, and about 59 M weighted tokens over 3 days, 40% of that
project's cost, 29 M of it cache rewrites.

- No coordinator in a sub-agent (#105): the coordinator runs as the session's main agent and
  never dispatches `ola-workflow:coordinator`, in the background or not. A request that
  arrives while an epic is running is its own to handle, in parallel, with the slots from the
  brief.

## 0.8.0

**A pull request that is short to read, captured when it changes what a user sees, and
cheaper to produce.** The brief now states the form of a PR description once, for every role,
and the agents spend less context on each task. The first measure of what a workflow costs in
tokens ships with it.

- A short description (#86): `Closes #<task>` when the request closes one (a release has no
  such line), 1 to 3 sentences, a line saying what was checked, in the language of the
  artifacts. The developer writes it, and the pr-reviewer judges it; a description that runs
  long is a suggestion, never a blocking finding.
- Captures (#88, #97): a new `preview` key in the profile (`up`, `url`, `down`) says how to
  start the app on a slot. `ola-workflow-capture` photographs a page with headless Chrome, and
  `ola-workflow-pr-assets` pushes the PNG files to a `pr-assets` branch and prints the
  markdown to paste. A request that changes what a user sees carries a Captures block, a
  before/after table when an existing screen changes. Without `preview`, the brief says no
  capture is expected. When captures are expected, the pr-reviewer blocks a visible change
  that has none. The `pr-assets` branch is as readable as the repository, so capture
  development data only: nothing real, nothing private.
- A link to the design (#101): in integrated mode, a request that follows a design links its
  published artifact, or names the page's path when it was never published. A missing line is
  a suggestion in review.
- An `RFR` label (#92): in integrated mode, the coordinator puts it on a request whose merge
  gate holds for the current head SHA, whether it merges it or hands it to the human, and
  takes it off as soon as the request is no longer ready: new SHA, branch behind, blocking
  review.
- Context kept small (#85, #80, #81): the brief prints four rules for every role: no
  busy-waiting on CI, reads by line range, noisy commands silenced or bounded, short reports.
  The developer reads the passages it needs and runs the affected tests once, at the end. The
  pr-reviewer publishes its verdict without waiting for CI, reports the CI state on its own
  line, and reads the changed passages at the SHA instead of whole files. Its `agent-review`
  status now judges the code alone, while CI may still be running, and is `failure`, naming
  the check, when a required check had already failed for a reason outside the code. A green
  `agent-review` no longer means a green CI: read the checks too before merging a request
  that touches a sensitive path.
- Resuming agents (#80, #94): a developer can take over a request whose branch another agent
  holds. The coordinator resumes an agent only if its last report is under five minutes old,
  and otherwise starts a fresh one of the same role: review findings go to a fresh developer.
  The one exception is an agent that reported `needs-decision` with nothing pushed: it gets
  the human's answer whatever its age, since its work exists only in its worktree. The
  coordinator reads a running CI again at the next report instead of waiting, asks for the
  Report block only, and proposes a fresh session when an epic closes.
- Measuring the cost (#87): `scripts/token-cost.sh` computes from the session logs the
  weighted token cost by role and by PR, and the number of cache rewrites, so that an epic
  aimed at the cost has a before and an after.

Fixes:

- The developer catches up with the base branch by merging it, never by rebasing, so a push
  never has to be forced (#93).
- The pr-reviewer writes line ranges as `sed -n '<a>,<b>p'`: `'a,bp'` read `a` as sed's
  append command (#95).

## 0.7.0

**A session opened with Chrome connected, under the coordinator, had no browser tool at
all.** Since 0.6.0 this repository opens every session as the coordinator, and a session
agent's `tools:` list filters MCP tools exactly as it filters built-in ones: a list naming
Bash and Read, with no entry for the Claude in Chrome server, left the browser unreachable
even when it was connected (#68).

- The coordinator declares `mcp__claude-in-chrome__*`, the server-level form Claude Code
  documents for `tools`, so a session keeps the browser the human connected to it.
- No other role declares an MCP tool, and the suite holds both halves: the coordinator has
  the entry, every other workflow role has none. They work in worktrees, and have no browser
  to drive.

## 0.6.0

**A security reviewer, tuned for precision: a false positive here costs a developer a whole
review cycle.** Until now security was one line of the pr-reviewer's checklist. A project
opts in by listing, in `security.paths`, the globs whose change gets a security review beside
the code review; the brief prints the `git diff` command that decides, so git does the
matching. With no paths declared, nobody is dispatched and the brief says so.

- A finding is a complete path — a source an attacker controls, a sink, and no effective
  check between them — each with a file and a line. The reviewer lists candidates, then tries
  to refute each through named tests: it predates the change, no privilege boundary is
  crossed, the input is trusted, the check is only client side, a validation is *read*
  elsewhere, a precedent covers it. What it cannot prove is counted, not reported.
- A finding blocks only when all three hold: the change introduces it or makes it reachable,
  it is proven line by line, and its severity is medium or above. A proven finding that
  predates the change becomes a suggestion for a follow-up.
- Each blocking finding is `pending verification` until a second security-reviewer,
  dispatched on that one finding in a fresh context, confirms it — trying to refute it, and
  forbidden to invent a defence it has not read. Only a `confirmed` finding reaches the
  developer.
- A false positive the human rules on becomes a precedent in the document
  `context.security_precedents` names, read from the base branch so that a change cannot
  excuse itself. This repository lists that file among its sensitive paths, so only the human
  merges a new precedent.
- Its verdict is advice the coordinator relays: no commit status, and the merge gate does not
  read it. The coordinator does not merge until the security review owed has reported, every
  finding pending verification has a verdict, and none is confirmed and still open. It takes
  no slot: it builds, tests and starts nothing.
- In discreet mode, nothing goes on the forge: a security review is written to
  `security-reviews/<branch>/<SHA>.md` under the memory directory, and each verification to
  a file of its own beside it, `<SHA>.Sn.md`, since verifiers run in parallel.
- The pr-reviewer no longer takes a `Security review of` or `Verification of` comment for its
  own previous review.

**This repository opens every session as the coordinator**, through `.claude/settings.json`,
on the installed plugin rather than this tree, so the plugin is not rewritten under itself
while it works. `claude --agent <name>` opens any other.

**Each role says which model it runs on, instead of inheriting the session's.** Two agents
out of seven pinned one; the other five ran on whatever the session was set to — and since
0.5.0 runs one reviewer per slot, that meant two Opus reviews at a time on every new head
SHA.

- Opus where a wrong judgement costs a whole cycle: the architect, whose split is paid for in
  full when its third task turns out to need its fifth, and the pr-reviewer, which has to find
  what nobody wrote down. Sonnet where the volume is: the developer, the product-designer and
  the design-reviewer, each holding a page or a task against criteria somebody already wrote.
  The coordinator pins nothing — it is the session agent, and the model there is the one
  chosen for the session.
- The developer and the pr-reviewer pin `effort: high`, and so does the security-reviewer
  this release adds, on Opus like the pr-reviewer. That is a ceiling, not a cut: it keeps
  the heaviest roles at `high` however high the session is set, and the session is what they
  used to follow.
- Measured rather than believed: a frontmatter `effort` reaches a plugin **subagent**, and is
  ignored when the same file runs as a session agent, where the model's own default applies.
  `CLAUDE_CODE_EFFORT_LEVEL` overrides it; `CLAUDE_CODE_SUBAGENT_MODEL`, the other way round,
  no longer reaches a role that pins a model. The spike grew an eighth scenario and an
  `effort` column, the payload's `effort` turned out to be an object rather than a string, and
  everything it records was re-measured on Claude Code 2.1.305.
- The suite holds the whole table as a map declared beside it, `probe` included — which the
  assertion it replaces left out of its set. A role that stops pinning its model, pins another
  one, or arrives without being named in the map fails by name.

No figure is given for what this saves, deliberately: a number that has to be *true* belongs
to something that recomputes it, not to a line in a changelog.

## 0.5.0

**Reviews were the bottleneck, so they run in parallel and each cycle reads only what
changed.** #26 took fourteen full reviews in twenty-one hours, every one of them reading the
whole diff again.

- `slots.reviewer` takes a list, and the coordinator runs one reviewer per slot at once,
  as it already did for developers. A single value still works, an empty list does not —
  the schema validator now reads `minItems`. This repository now has two.
- The pr-reviewer is dispatched when a request opens, without waiting for CI, and reads
  CI's result on the SHA instead of running the full check again. It runs it itself only
  when the SHA carries none of the required checks: discreet mode, or no CI.
- A second review is a **delta**: the reviewer finds its previous one, says which blocking
  finding is fixed, disputed or still open, and judges what changed since. A defect on an
  untouched line is blocking only if the change made it reachable. The delta compares the
  request's whole change at both SHAs, not its commits: `git range-diff` skips merge
  commits, and would have shown the code written while resolving a conflict as unchanged.
- A review is no longer thrown away when the head moves under it: it is published on the SHA
  it pinned, which the merge gate never mistakes for the head, and the next cycle is a delta
  from there. When CI cancelled that SHA's checks, the review carries no status at all.
- In discreet mode, reviews are kept under `reviews/<branch>/`, so a review can be found again
  after a rebase.
- The coordinator no longer tells every project that it ships `make measure`, which went
  with the guard in 0.4.0.

## 0.4.0

**The guard that read command lines is gone. GitHub refuses instead.** Every agent now works
with a token that can neither merge nor write a commit status, and two exact commands get a
stronger one. Create the tokens once, in a terminal:

```
ola-workflow-tokens setup
```

### Why

The guard had to work out, from the text of a command, what a shell would run, and then
refuse a merge or a review status to the wrong role. Each spelling it missed was a merge it
let through: 0.3.2 fixed fifty-seven of them, and `gh ${x} pr merge` (#41), `f ( ){ … }`
(#42) and `gh pr --repo o/r merge` (#43) were still open. Each spelling it could not read
was a question to the human, which is how ordinary commands kept stopping the session.

A token has no spelling. `gh pr merge`, `gh api -X PUT …/merge`, `curl` and a script all hit
the same 403.

### What changed

- `hooks/session.sh` (SessionStart) gives every Bash command of a session in a project
  with a profile the **base** token, through `CLAUDE_ENV_FILE`. Subagents get it too
  (measured on Claude Code 2.1.302). The token is read from the macOS keychain on each
  command and never written to a file.
- `hooks/elevate.sh` (PreToolUse) runs two commands with a stronger token, and only these
  two:
  - `gh pr merge <N> --squash --match-head-commit <SHA>` from the coordinator gets the
    **merge** token;
  - `gh api repos/{owner}/{repo}/statuses/<SHA> -f state=… -f context=<review_status> …`
    from the pr-reviewer gets the **review** token.

  Each form is matched by one regular expression, over a character set with no shell
  metacharacter in it, and only in integrated mode. Every other command passes untouched,
  so your permission rules apply exactly as written, and nothing is asked any more because
  a command could not be read.
- A form the hook does not recognise runs with the base token and gets a 403. A mistake
  costs a retry, never a merge.
- `bin/ola-workflow-tokens`: `setup` opens GitHub's form pre-filled for each of the three
  fine-grained tokens and stores them in the keychain, and `status` says who each acts as
  and when it expires.

### Breaking

- The `guard` profile key is gone, along with `OLA_WORKFLOW_GUARD`, `OLA_WORKFLOW_GUARD_LOG`
  and `make measure`. A profile that still sets `guard` fails `ola-profile validate`: remove
  the key. It is replaced by `github_tokens`, `keychain` (the default) or `off`.
- Without the tokens, every gh call in a project with a profile fails with a 401, and the
  session is told so when it starts.
- The coordinator has to give `--match-head-commit` the full 40-character SHA.
- `gh pr checks` fails with the role tokens: GitHub gives check runs to no fine-grained
  token (a classic one with `repo` can read them). The brief reads a SHA's checks as its
  Actions jobs and its statuses instead. A check run by an app other than GitHub Actions
  cannot be read that way, and the agents ask.

### Not stopped, and said so in the README

- An agent that reads the keychain itself.
- `git push` to the base branch: git uses your own credentials, and a free private
  repository has no ruleset.
- The merge gate's conditions: GitHub checks who merges, not whether the checks were green.

## 0.3.2

**0.3.1 shipped with seven ways to merge past the guard and a script that can delete your
repository.** Update.

```
claude plugin update ola-workflow@ola-workflow
```

### `make measure` could erase the tree it ran in, and report success

```
WORK=$(cd "$(mktemp -d "$TMPDIR/ola-x.XXXXXX")" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
```

With a `$TMPDIR` that does not exist or is not writable, the inner substitution is empty,
`cd ""` succeeds and stays put, `pwd -P` answers the **current** directory, and the trap
erases it. Exit status 0. It happened: an independent review had its worktree wiped
mid-review by `make measure`, and the script said nothing.

The same idiom opened all four test suites. They now share `scripts/scratch.sh`, which sets a
variable rather than printing one — inside `WORK=$(…)` an `exit 2` would end only the
substitution's subshell and the caller would carry on with an empty path, which is the defect
again one layer down. **Four** independent conditions must hold before the trap is
installed — `mktemp` succeeded, the result is a directory, it can be entered, and its name is
the one we just asked for — and `${WORK:?}` in the trap is a fifth. The fourth is the one
that catches an `mktemp` which succeeds and answers something else, and an earlier draft of
this entry left it out of the count.

It is the same shape as every other defect this project keeps finding — a command that fails
and is read as a result — in its most expensive form.

### Seven ways a merge got past the guard in 0.3.1

All seven have one shape: something that is not the command gets read as the command word, so
the rule that asks whether the command is `gh` is never consulted. **Fifty-seven spellings**,
each one measured against the tokenizer 0.3.1 shipped and each one now a row of
`tests/guard.test.sh` — the count below reconstitutes as 16 + 4 + 4 + 12 + 5 + 1 + 15.

- **Sixteen with a blank between the operator and its target.** `2> /dev/null gh pr merge 7
  --admin` was allowed, one space from the glued form, which is refused: the skip consumed
  the operator and not the target, so `/dev/null` became the command word. What decides is
  whether the operator **ends** the word — `2>` takes the next word, `2>&1` does not and
  still must not.
- **Four written with `&>` or `&>>`.** The branch asked for an optional file descriptor then
  `<` or `>`, which neither begins with, so the operator became the command word itself.
- **Four written with `>|`.** It is one operator and the splitter cut at the `|`, leaving a
  bare `>` as one segment and `out gh pr merge 7 --admin` as the next, commanding `out`.
- **Twelve with the operator glued *behind* the command word.** `gh>out pr merge 7 --admin`
  arrived as a command named `gh>out`, which matches no rule, and merged. A word ends at an
  unquoted operator now, as it does in the shell. This is the one that says what the others
  were: the prefix placement was read and the glued one was not, which is an enumeration of
  *placements* sitting behind a list of operators that had just stopped being one.
- **Five written `coproc NAME` then a compound command** — `( … )`, `if`, `while`, `until`,
  `case` — where the name read as the command word. The brace form was closed in 0.3.1, each
  before anyone looked up the set. `for` and `select` complete the set the code now covers
  and were never escapes: the `;` before `do` puts the merge in a segment of its own.
- **One with an escaped `>` before an `&`.** `echo \>& gh pr merge 7 --admin` became a single
  segment named `echo`, because the lookbehind that decides whether an `&` belongs to a
  redirection read the text as written, where a `\>` ends in `>`. The same lookbehind for
  `|` was introduced while closing `>|` above and had the same defect; it was caught in
  review and never shipped. Both now read the text with escapes neutralised.
- **Fifteen with a paren glued to the construct** in front of the command:
  `coproc CO(gh pr merge 7 --admin)`, `!(…)`, `time(…)`, `if(…)`, `while(…)`, `until(…)`,
  `elif(…)`, `then(…)`, `else(…)`, `do(…)`, `{(…)` and four `case x in x)gh …` forms. A paren
  is a metacharacter and the word splitter did not end a word there, so the construct and its
  command arrived glued — read as a command named `CO(gh`, or, for the `case` forms, as
  nothing at all. Every branch that handles these constructs was already written; what was
  missing is that the two never arrived separately. `(gh pr merge 7 --admin)` and
  `f(){ gh pr merge 7 --admin; }` were *not* escapes, and are rows so that they stay refused.

The operators are one definition in `hooks/lib/tokenize.pl`, read by the three places that
need them, and it is bash's twelve rather than a list someone remembered. The first attempt
at this fix wrote a list of seven inline, which left five of the twelve out for the length of
one commit — the same defect as the one being fixed, one layer up, and review is what caught
it.

**This is not a complete account, and no account of a guard that matches text can be.** Three
escapes of the same family are open and measured, each with its own issue: an expansion in
`gh`'s subcommand path shifts the positions a rule reads, so `gh ${x} pr merge 7 --admin` is
allowed while the shell really merges ([#41](https://github.com/olaurendeau/ola-workflow/issues/41),
with why the cheap fix costs more than it buys); and a blank *between* the parens of a
function header makes three words where the pattern joins two, so `f ( ){ gh pr merge 7
--admin; }` is allowed while `f(){ … }` and `f (){ … }` are refused
([#42](https://github.com/olaurendeau/ola-workflow/issues/42)); and an option that takes a
value, written *between* `gh` and its subcommand, truncates the path a rule reads, so
`gh pr --repo o/r merge 7 --admin` is allowed while `gh -R o/r pr merge 7 --admin` — the same
command with the option one position earlier — is refused
([#43](https://github.com/olaurendeau/ola-workflow/issues/43), the one to fix first: it is a
developer merging).

Five rounds of independent review on this one change found fifteen things — three, three,
two, four and three — and they sort into four kinds: **six defects this change itself
introduced**, three false claims (two in this entry, one in a comment the fix had just written
to justify itself), five escapes that were already there, and one load-bearing guard that had
no test row. Six plus three plus five plus one.

An earlier draft of this paragraph said six escapes, counting that last one among them. It was
not an escape: the line was already refused, and what was missing was an assertion about it.
The review that caught the slip said what it was — one example generalised into a claim, which
is the defect the paragraph above this one had just finished removing from a comment.

Every one of the six defects was caught before it shipped, which is what the rounds bought —
and also what says when to stop. On a class that cannot be exhausted, a defect the change
introduces blocks it; an escape that was already there becomes an issue. Otherwise the loop has
no end: by the fourth round, most of what was found was in the fix written by the third. What the guard is for is making the ordinary path visible, not proving a negative;
`make measure` prints what it asks about and what it costs, and `ask` is what it does with
everything it cannot read.

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
