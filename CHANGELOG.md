# Changelog

## 0.3.3

**0.3.2 demandait confirmation à chaque incrément.** `((i++))` et `inzip=$((inzip+1))` sont
de l'arithmétique, et 0.3.2 les lisait comme des sous-shells mal découpés.

```
claude plugin update ola-workflow@ola-workflow
```

### Une expression n'est pas une commande, et le découpeur tombait dedans

Signalé depuis une session réelle, deux fois ([#48](https://github.com/olaurendeau/ola-workflow/issues/48)) :

```
ola-workflow: this command cannot be read … the split cut inside it (at: ( inzip+1)).
```

Le corps de `$((inzip+1))` est `(inzip+1)`, qui n'est pas une ligne de commande. Le découpage
tombait dedans et le segment sortait illisible — une confirmation par appel, sur n'importe
quel projet, pour un incrément de boucle. Même défaut sur `((i++))` et sur `"$((i+1))"`.

Les deux formes sont maintenant creusées : l'expression disparaît, et le garde-fou se taît.

### Ce que creuser aurait pu cacher

Creuser une expansion est une place où une commande peut se cacher, donc chacune des seize
nouvelles lignes de `tests/tokenize.test.sh` est **mesurée des deux côtés** : ce que le
tokenizer annonce, et ce que le shell exécute vraiment avec un faux `gh` sur le PATH.

La suite passe de 305 à 345 assertions. Sept lignes en portent trois chacune — le shell
n'exécute rien, le tokenizer ne nomme rien, et la ligne n'est pas illisible, la troisième
étant celle qui coûtait une confirmation par appel. Neuf en portent deux. Une s'ajoute dans
la boucle des préfixes.

**Une substitution imbriquée dans une expression s'exécute.** `$(( $(gh pr merge 7 --admin) +
1 ))` lance `gh`, et quatre orthographes de cette forme — `$( )`, backquotes, arithmétique
imbriquée, commande arithmétique — sont des lignes de test. Couper la récursion fait tomber
les quatre.

**Et `$((` n'est pas toujours de l'arithmétique.** `$((echo RAN) )` exécute `echo` sur
bash 3.2.57, bash 5.3.20 et zsh 5.9. La règle qui vient à l'esprit — « les deux parenthèses
fermantes sont collées » — est **fausse**, et je l'ai écrite avant de la mesurer :
`$((echo RAN) && (:))` finit par `))` et exécute quand même. Une seule ligne de test la
réfute, et c'est elle qui tombe quand on remet la mauvaise règle.

La règle que les trois shells appliquent est textuelle : en balayant après `$((` avec une
profondeur de parenthèses, le premier `)` à profondeur 0 décide. Suivi d'un `)`, c'est une
expansion arithmétique, et l'expression ne s'exécute jamais — `((gh pr merge 7 --admin))` est
une erreur de syntaxe sur les trois shells, pas un merge. Suivi d'autre chose, c'est un
sous-shell, et le corps tourne.

Un guillemet dans l'expression reste illisible, donc demandé : bash y lit un `)` entre
guillemets comme du texte, zsh y termine la substitution, et les deux exécutent alors des
choses différentes. Ce fichier ne peut pas avoir raison pour les deux.

### Une affirmation fausse retirée de la suite

Une ligne de `tests/tokenize.test.sh` affirmait depuis 0.3.1 que
`((gh pr merge 7 --admin))` doit se lire comme un merge, au titre des préfixes qui changent
la façon d'atteindre une commande sans changer ses opérandes. Aucun shell ne l'exécute. Elle
est remplacée par les deux formes qui, elles, l'exécutent : `( (gh …) )` et `((gh …) )`.

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
