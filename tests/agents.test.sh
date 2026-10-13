#!/usr/bin/env bash
# shellcheck disable=SC2016
#   Every `$` in a command line below is part of what is being tested — `$(echo gh)`,
#   `${u:-gh}`, `$c`, `$EDITOR` — and expanding it here would test nothing.
# The agents are prompts, so what is testable about them is not what they say but what they
# must not say, and whether the single source they all cite stays the single source.
#
# Four instruments, each one earned by a defect this repository has already paid for:
#   - a negative assertion, because a prompt is full of "never do X" sentences that satisfy
#     a positive grep by accident;
#   - a liveness witness beside each absence, because an absence passes vacuously on an
#     empty file, a renamed section, or a pattern that stopped matching;
#   - the pair "how many state it / how many need it", because a rule in two files out of
#     three is duplicated between those two and stranded for the third, and those two
#     failures are corrected in opposite directions;
#   - an assertion tying the agents to the schema, not only to each other, because every
#     check that compares things of the same kind missed the drift between kinds.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BRIEF=$ROOT/bin/ola-workflow-brief
failures=0
total=0

ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

# The workflow roles, and the diagnostics that are not roles. Declared rather than
# globbed, so that `probe` — which exists to dump a hook payload, not to work — is not held
# to rules about modes and slots. Both directions are checked below, so a new file cannot
# quietly escape either set.
WORKFLOW_ROLES="coordinator product-designer architect developer pr-reviewer"
DIAGNOSTICS="probe"
# Declared the same way as the roles, and for the same reason: the witness below compares
# what is on disk against what is declared, and deriving the skills *from disk* made that
# comparison tautological — an undeclared `skills/undeclared/SKILL.md` left it green saying
# "the 8 commands on disk are exactly the declared ones". A witness that reads its
# expectation from the thing it is checking is not a witness.
WORKFLOW_SKILLS="workflow-init"

AGENTS=()
for role in $WORKFLOW_ROLES; do AGENTS+=("$ROOT/agents/$role.md"); done
ALL=()
for f in "$ROOT"/agents/*.md; do ALL+=("$f"); done
[ "${#ALL[@]}" -gt 0 ] || { echo "no agent files found"; exit 1; }

for f in "${ALL[@]}"; do
  stem=${f##*/}; stem=${stem%.md}
  case " $WORKFLOW_ROLES $DIAGNOSTICS " in
    *" $stem "*) ok "$stem is a declared role or diagnostic" ;;
    *) ko "agents/$stem.md is neither a declared workflow role nor a declared diagnostic" ;;
  esac
done
for role in $WORKFLOW_ROLES; do
  if [ -f "$ROOT/agents/$role.md" ]; then ok "$role has a file"; else ko "$role is a declared role with no file"; fi
done

# --- A prompt may not name a command that does not exist -----------------------------
# Three shipped artefacts offered `/ola-workflow:workflow-init` before any such skill
# existed — the coordinator, the brief's no-profile refusal, and the README. Nothing
# noticed, because a slash command has no reader until an agent offers it to a human; then
# the one moment the plugin had to explain itself is the moment it fails.
#
# This check took four tries, and the two failures are worth keeping written down because
# they are the same failure twice:
#
#   - a pattern looking for `/<name>` cannot tell an offer from a path, so
#     `skills/workflow-init/SKILL.md` in the README failed the suite;
#   - then "a bare `/name` **with a hyphen** is an offer" — and the hyphen is in
#     `${TMPDIR:-/tmp}/ola-brief.XXXXXX`, the mktemp idiom every suite here uses. One such
#     line in a scanned file and `make check` fails on correct code, with no rephrasing
#     available. The justifying comment claimed the only hyphenated tokens on the tree were
#     `-` and `ola-workflow`; measured, `ola-workflow` occurs zero times in the scanned set.
#     I asserted a measurement instead of making one.
#
# An assertion against a lie that can forbid the truth is worse than no assertion: it puts
# the author between deleting true text and switching the check off, and under pressure the
# check loses.
#
# A third rule lived here for three cycles and is **gone**: "a namespace spelled almost
# right" (`ola_workflow:x`, `Ola-Workflow:x`). Every anchor it was given had legitimate text
# on the other side of it — slashed, it failed on `/8080:8080`, a Docker port mapping;
# unslashed, on `image: ola_workflow:latest`, `log: ola_workflow:started`,
# `docker build -t ola_workflow:dev` and a SQL reference. Five measured instances of one
# defect, each closed by narrowing and each reopened next door.
#
# What it bought was small: a misspelled namespace, which rule 1 cannot see because it only
# looks at the exact prefix. What it cost was a check that fails on an ordinary sentence. So
# it is a **stated limit** rather than a sixth attempt — a prompt that spells this plugin's
# namespace wrong is not detected — and the two rules that remain do no guessing at all.
#
# The general lesson, written here because it was learned five times: when a check is meant
# to separate a mention from an offer, it cannot, because they are the same characters. Only
# the two ends of that spectrum are decidable — a name that must resolve, and a name this
# plugin provides written without its namespace.
PROMPTS=("$ROOT"/agents/*.md "$BRIEF" "$ROOT/README.md")
for skill in "$ROOT"/skills/*/SKILL.md; do [ -f "$skill" ] && PROMPTS+=("$skill"); done

# Every scanned file must be *readable* and have content. Without this the scan reads
# whatever it can and the verdicts below pass on the rest: dropping $BRIEF from the list left
# the suite green, because a witness counting tokens cannot notice a file that went missing.
#
# Three conditions, and this witness needed three tries to get them. `[ -s ]` alone asks the
# size, which stat answers for a file nobody can open, so `chmod 000 README.md` left the
# suite green with the README silently out of the scan. `[ -r ] && [ -s ]` then both pass for
# a **directory** named like a scanned file, which `cat` cannot read either. `[ -f ]` is the
# one that says "a regular file", and the three together are what the label claims.
#
# The pattern is worth naming: each round closed the case that had just been measured and
# left the one next to it, because the label ("readable, has content") was treated as the
# specification instead of being derived from what `cat` actually needs.
for f in "${PROMPTS[@]}"; do
  label=$f
  case $label in */skills/*) label=skills/${label#*/skills/} ;; *) label=${label##*/} ;; esac
  if [ -f "$f" ] && [ -r "$f" ] && [ -s "$f" ]; then
    ok "$label is a regular file, readable and non-empty, so the scan below covers it"
  else
    ko "$label is scanned for offers and is not a readable, non-empty file"
  fi
done

# What this plugin provides, from the filesystem rather than from a list here. `:` separates
# a nested name: an agent at agents/sub/x.md is ola-workflow:sub:x, which the README
# documents as a template.
# An array, not a string: `for name in $provided` splits on blanks and expands globs, so a
# skill directory named `my skill` would be looked for as two names that do not exist and
# the real one would never be checked. A name is one element, whatever is in it.
PROVIDED=()
for f in "$ROOT"/skills/*/SKILL.md; do [ -f "$f" ] && { n=${f%/SKILL.md}; PROVIDED+=("${n##*/}"); }; done
for f in "$ROOT"/agents/*.md; do n=${f##*/}; PROVIDED+=("${n%.md}"); done

# Its own witness, and it asserts the **exact set** rather than a floor. `>= 6` for a real 7
# is a threshold, which is a number one tunes until it passes — and it would have let a
# command disappear from disk without a word, which is the one thing this witness exists to
# notice. The expected set is derived from what this file already declares at the top, so a
# role added there and not shipped, or shipped and not declared, fails on one side or the
# other.
# Quoted and one per line: `for r in $WORKFLOW_ROLES` splits on blanks and expands globs,
# which is what the comment eleven lines above forbids — and a declared name holding a `*`
# would have been expanded against the working directory.
# shellcheck disable=SC2086  # the three are blank-separated lists and must split here
expected_provided=$(printf '%s\n' $WORKFLOW_ROLES $DIAGNOSTICS $WORKFLOW_SKILLS | LC_ALL=C sort -u)
got_provided=$(printf '%s\n' "${PROVIDED[@]}" | LC_ALL=C sort -u)
if [ "$got_provided" = "$expected_provided" ]; then
  ok "witness: the ${#PROVIDED[@]} commands on disk are exactly the declared ones"
else
  ko "witness: on disk [$(printf '%s' "$got_provided" | tr '\n' ' ')] against declared [$(printf '%s' "$expected_provided" | tr '\n' ' ')]"
fi

# One scan, two patterns, and which way round the lookbehind asks its question took six
# cycles to get right.
#
# Five versions listed what precedes a **path** and rejected those: a letter, a digit, `.`,
# `-`, `_`, `/`, `:`. Every one was missing a character, and every missing character was a
# correct sentence refused — `${TMPDIR:-/tmp}/ola-brief.XXXXXX`, then `/8080:8080`, then
# `$profile_dir/runs/<slug>/developer`, a path whose last segment happens to be a role name
# and which the sibling file this check also scans already writes. A blacklist of what a path
# can look like is open-ended, and every hole in it accuses the truth.
#
# What precedes an **offer** is a small closed set: nothing (the start of a line), a blank, a
# backtick, an opening bracket, a quote (`\x27` for the apostrophe, which cannot be written
# literally inside the single-quoted perl program). So the lookbehind is a whitelist, and the
# direction
# of error flips with it: a character missing from this list makes the scan *miss* an offer,
# which is a false negative and safe, where a character missing from the old list refused a
# true sentence and was not.
#
# What it misses, measured rather than left to be discovered: an offer glued to `**` (bold),
# to `:`, to `,` or to `>`. `*` is deliberately **not** in the list — `*/developer` under a
# glob is in the innocent table below, and adding `*` would reopen the exact false positive
# this version closed. The other three are rare enough in these files to be worth less than
# the risk of widening the list again.
scan_text() { # scan_text < text → `<kind> <token>` lines, sorted
  perl -ne '
    while (m{(?:^|(?<=[\s`(["\x27]))/?(ola-workflow:[A-Za-z0-9_.:+-]+)}g)          { print "named $1\n" }
    while (m{(?:^|(?<=[\s`(["\x27]))/([A-Za-z0-9_.+-]+)(?![:/?\#A-Za-z0-9_.+-])}g) { print "slash $1\n" }
  ' | LC_ALL=C sort -u
}
SCAN=$(cat "${PROMPTS[@]}" 2>/dev/null | scan_text)   # the per-file witness above is what notices a file this cannot read

# A witness per pattern, because a dead pattern is the defect this block already had: when
# only the `named` count was checked, neutering the slash pattern left the suite green and
# printing "both verdicts read something". Three patterns, three counts.
for pair in named:1 slash:1; do
  kind=${pair%:*}
  got=$(printf '%s\n' "$SCAN" | grep -c "^$kind " || true)
  if [ "$got" -ge "${pair#*:}" ]; then
    ok "witness: the $kind pattern read $got token(s), so its verdict below reads something"
  else
    ko "witness: the $kind pattern read nothing — its verdict below is blind"
  fi
done

# The two rules, written once and fed two ways: the shipped prompts, and the fixture tables
# below. They were written twice for one cycle — inline here and again inside the fixture
# helper — and the two promptly disagreed: a skip added to one left the other accusing a
# version tag. A rule stated in two places is a rule agreed in one.
#
# Each verdict is a line `ok|ko:<rule>:<token>`, so a caller can print them all or keep only
# the refusals.
verdicts_for() { # verdicts_for < text → one `ok|ko:<rule>:<token>` line per verdict
  local scan; scan=$(scan_text)

  # 1. Named: every `ola-workflow:<x>` must resolve, with or without the leading slash. Both
  # spellings are real — a slash command is typed `/ola-workflow:x`, the Agent tool's
  # subagent_type is the bare `ola-workflow:x` — and either way the thing has to exist. The
  # class is greedy, `.` and `+` included, so a malformed name fails by its own name rather
  # than being quietly captured as the valid prefix of itself.
  printf '%s\n' "$scan" | sed -n 's/^named ola-workflow://p' | while IFS= read -r t; do
    [ -n "$t" ] || continue
    # No skip here, and the one that was here was wrong twice over. It read "a command name
    # never begins with a digit", which is false — `skills/2fa-setup/SKILL.md` with
    # `name: 2fa-setup` passes `claude plugin validate --strict` with no warning — and it let
    # `/ola-workflow:2fa-nope` through, which is this check's original defect walking back in.
    #
    # There is nothing to put in its place: `ola-workflow:latest` (an image tag) and
    # `ola-workflow:workflow-init` (a command) are the same shape, and no reading of the text
    # tells them apart. So the rule flags every `ola-workflow:<x>` that is not a command, and
    # that is the **limit**: do not write this plugin's namespace followed by something that
    # is not one of its commands. It is in the README, next to the reason.
    as_path=$(printf '%s' "$t" | tr ':' '/')
    if [ -f "$ROOT/skills/$as_path/SKILL.md" ] || [ -f "$ROOT/agents/$as_path.md" ]; then
      echo "ok:named:$t"
    else
      echo "ko:named:$t"
    fi
  done

  # 2. A command this plugin provides must never be written as a bare `/name`, which resolves
  # to nothing. Exact equality against the filesystem — no guessing about what a name looks
  # like, which is what two earlier versions of this check did.
#
# The lookahead rejects a token followed by more path (`/probe/last.json`,
# `/developer/settings`, `/coordinator?x=1`): a path has path after it, and that *is*
# decidable, unlike the token standing alone.
  #
  # The gap, stated rather than guessed around: a bare offer of something that does not exist
  # *yet* — `/verify-ui` before that skill ships — is not detected, because nothing can tell
  # it from `/tmp` or `/usr`. The day the skill ships, this rule covers it.
  for name in "${PROVIDED[@]}"; do
    if printf '%s\n' "$scan" | grep -qxF "slash $name"; then
      echo "ko:slash:$name"
    else
      echo "ok:slash:$name"
    fi
  done
  return 0
}

while IFS= read -r verdict; do
  [ -n "$verdict" ] || continue
  rest=${verdict#*:}
  token=${rest#*:}
  case $verdict in
    ok:named:*)  ok "ola-workflow:$token is named by a prompt, and exists" ;;
    ko:named:*)  ko "ola-workflow:$token is named by a shipped prompt, and nothing provides it. Either add it, or — if the point was to name a wrong example — describe it rather than write it, since a mention and an offer are the same characters here." ;;
    ok:slash:*)  ok "$token is never named without its namespace" ;;
    ko:slash:*)  ko "/$token is named by a shipped prompt and resolves to nothing: a command of this plugin is typed /ola-workflow:$token. If you meant to show the mistake, describe it rather than write it." ;;
    *)           ko "unrecognised verdict from verdicts_for: $verdict" ;;
  esac
done <<EOF
$(cat "${PROMPTS[@]}" 2>/dev/null | verdicts_for)
EOF

# --- The scan itself, against text it must not accuse ---------------------------------
# This check could forbid true text three times running: once on a path
# (`skills/workflow-init/SKILL.md`), once on the mktemp idiom
# (`${TMPDIR:-/tmp}/ola-brief.XXXXXX`), once on a Docker port mapping (`/8080:8080`) in a
# README that already talks about Docker. Each time it was green on the tree *as it stood*
# and one sentence away from failing, and each time it was found by a reader rather than by
# the suite — because the suite only ever scanned the files that happen to exist today.
#
# So the scan is fed text directly. A false positive here is the dangerous direction: it puts
# the author between deleting a true sentence and switching the check off, and under pressure
# the check loses. Hence two tables, and the innocent one first.
#
# The innocent table is the record of what this check has cost: each line was green on the
# tree as it stood and one sentence away from failing, and each was found by a reader rather
# than by the suite. Adding a line here is cheaper than the cycle that finds it.
# shellcheck disable=SC2016  # ${TMPDIR:-/tmp} is the text under test, not an expansion
innocent='skills/workflow-init/SKILL.md and agents/developer.md
ghcr.io/acme/ola-workflow:latest and registry.example.com/ola-workflow:dev
a log line ola_workflow: started, a key ola-workflow: build, OLA_WORKFLOW: 1
the file runs/probe/last.json, the path /developer/settings, the url /coordinator?x=1
the memory goes to $profile_dir/runs/<slug>/developer and runs/<slug>/probe
and to ${OLA_RUNS}/architect, or */developer under a glob
image: ola_workflow:latest and the tag ola_workflow:1.2
log: ola_workflow:started and docker build -t ola_workflow:dev .
select * from ola_workflow:v1 and ghcr.io/acme/ola_workflow:1.2
the designer/developer split, runs/probe/last.json
W=$(mktemp -d "${TMPDIR:-/tmp}/ola-brief.XXXXXX")
docker run -p /8080:8080 -v /host:/container img
ports: - /8080:8080 and a path /a:b and a link [x](/a:b)
see file:///tmp/x and https://example.com/a and C:/win/path
2>/dev/null and s/a/b/ and a date 12/10/2026
a ratio 1:2, a time 12:30, fd00::1, file:line, <!-- spike:begin -->
paths /tmp/x, /usr/bin, /srv, ~/.claude/plugins
dispatch `ola-workflow:developer` and offer `/ola-workflow:workflow-init`'
# `/no-such-skill` and not `/verify-ui`: the second is a skill `README.md` plans to ship, and
# a table that hard-codes it would make this suite fail on the correct change that adds it.
# A fixture must name something that stays false.
guilty='run /workflow-init to set up
later /no-such-skill will exist
offer /ola-workflow:nope and dispatch ola-workflow:nope
/ola-workflow:Workflow_Init and /ola-workflow:workflow-init.v2
and /developer, which is an agent
offer "/workflow-init" or `/ola-workflow:nope` in quotes'

accused=$(printf '%s\n' "$innocent" | verdicts_for | sed -n 's/^ko://p')
if [ -z "$accused" ]; then
  ok "the scan accuses none of the 18 lines of correct text it has failed on or nearly did"
else
  ko "the scan accuses correct text: $(printf '%s' "$accused" | tr '\n' ' ')"
fi

# The exact set, not a count over a threshold: a threshold is a number one tunes until it
# passes, and it hides both a rule that stopped firing and a rule that started firing twice.
# `/no-such-skill` is deliberately absent from the expected set — it is the gap rule 2 names,
# and nothing can tell a bare offer of a command that does not exist yet from `/tmp`. The two
# spellings of `nope`, slashed and bare, are one verdict because they are one missing name;
# and `ola_workflow:workflow-init` is written bare here on purpose, because the bare form is
# the one `subagent_type` uses and the rule now covers it.
expected='named:Workflow_Init
named:nope
named:workflow-init.v2
slash:developer
slash:workflow-init'
# LC_ALL=C, because the collation of the user's locale decides whether `Workflow_Init`
# sorts before `nope` — and this assertion compared a sorted list against a written one, so
# it passed in `make` and failed in an interactive shell on the same files. A test whose
# verdict depends on the environment's locale is a test that is right by accident.
caught=$(printf '%s\n' "$guilty" | verdicts_for | sed -n 's/^ko://p' | LC_ALL=C sort -u | grep . || true)
if [ "$caught" = "$expected" ]; then
  ok "the scan catches exactly the 5 broken spellings it claims, and no others"
else
  ko "the scan's verdicts changed: got [$(printf '%s' "$caught" | tr '\n' ' ')] want [$(printf '%s' "$expected" | tr '\n' ' ')]"
fi

# A skill resolves by its frontmatter name, not by its directory, so the two disagreeing is
# a command that exists under a name nothing offers.
for skill in "$ROOT"/skills/*/SKILL.md; do
  [ -f "$skill" ] || continue
  dir=${skill%/SKILL.md}; dir=${dir##*/}
  declared=$(awk '/^---$/{c++; next} c==1 && /^name:/{sub(/^name:[[:space:]]*/, ""); print; exit}' "$skill")
  if [ "$declared" = "$dir" ]; then
    ok "skills/$dir: its declared name is the one that resolves"
  else
    ko "skills/$dir: declares name '$declared', so it resolves as ola-workflow:$declared"
  fi
  if [ -n "$(awk '/^---$/{c++; next} c==1 && /^description:/' "$skill")" ]; then
    ok "skills/$dir: has a description, which is what decides whether it is loaded"
  else
    ko "skills/$dir: has no description, so nothing can decide to load it"
  fi
done

frontmatter() { awk '/^---$/{c++; if (c==2) exit} c==1' "$1"; }
body() { awk '/^---$/{c++; next} c>=2' "$1"; }

# --- Every agent file is alive -------------------------------------------------------
# This is the witness every assertion below leans on: all of them would pass on an empty
# file, so "it is not empty, and it has both halves" has to be checked first.
for f in "${AGENTS[@]}"; do
  name=${f##*/}
  if [ -s "$f" ] && [ -n "$(frontmatter "$f")" ] && [ -n "$(body "$f")" ]; then
    ok "$name: has frontmatter and a body"
  else
    ko "$name: empty, or missing its frontmatter or its body"
  fi
done

# Existence is not substance. Stubbed down to eight lines, two of these agents left every
# assertion below green — so the witness asserts what the coordinator actually consumes
# from each of them, which is what a stub cannot fake without becoming the real thing.
for f in "${AGENTS[@]}"; do
  name=${f##*/}
  if [ "$(body "$f" | grep -c .)" -ge 20 ]; then
    ok "$name: has a body of substance, not a stub"
  else
    ko "$name: body is $(body "$f" | grep -c .) non-empty lines, which is a stub"
  fi
  if grep -q '^## Steps' "$f"; then
    ok "$name: says in what order it works"
  else
    ko "$name: has no Steps section, so nothing says how it proceeds"
  fi
done
# The coordinator reads a Status from each of the others, and dispatches each of them.
for role in product-designer architect developer pr-reviewer; do
  if grep -q 'Status:' "$ROOT/agents/$role.md"; then
    ok "$role: reports a Status, which the coordinator reads first"
  else
    ko "$role: reports no Status, so the coordinator cannot tell done from blocked"
  fi
done

# --- Frontmatter ----------------------------------------------------------------------
for f in "${AGENTS[@]}"; do
  name=${f##*/}
  fm=$(frontmatter "$f")
  stem=${name%.md}
  declared=$(printf '%s' "$fm" | sed -n 's/^name: *//p')
  if [ "$declared" = "$stem" ]; then ok "$name: name matches the file"; else ko "$name: declares name '$declared' in $name"; fi
  if printf '%s' "$fm" | grep -q '^description: '; then ok "$name: has a description"; else ko "$name: has no description, so nothing can dispatch it on purpose"; fi
  if printf '%s' "$fm" | grep -q '^tools: '; then ok "$name: declares its tools"; else ko "$name: declares no tools, so it gets all of them"; fi
  # Keys Claude Code ignores for a plugin agent. Writing one would promise a guard rail
  # that does not exist — the spike recorded in the README established which.
  ignored=$(printf '%s' "$fm" | grep -cE '^(permissionMode|hooks|mcpServers|initialPrompt|observer[A-Za-z]*):')
  if [ "$ignored" = 0 ]; then ok "$name: claims no frontmatter key that plugin agents ignore"; else ko "$name: sets a key that is ignored for a plugin agent"; fi
done

# Only the developer works in a worktree, and only the reviewer pins a model.
worktrees=$(grep -l '^isolation: worktree' "${AGENTS[@]}" | sed 's#.*/##' | tr '\n' ' ')
if [ "$worktrees" = "developer.md " ]; then ok "only the developer is isolated in a worktree"; else ko "worktree isolation is on: ${worktrees:-nobody}"; fi
models=$(grep -l '^model: ' "${AGENTS[@]}" | sed 's#.*/##' | tr '\n' ' ')
if [ "$models" = "pr-reviewer.md " ]; then ok "only the reviewer pins a model"; else ko "a model is pinned on: ${models:-nobody}"; fi

# --- One source, cited by all ---------------------------------------------------------
# The pair that matters: the brief is stated once and needed by every agent. Each agent
# citing it is what makes "once" reachable rather than stranded.
for f in "${AGENTS[@]}"; do
  name=${f##*/}
  if grep -q 'ola-workflow-brief' "$f"; then ok "$name: cites the brief"; else ko "$name: does not cite the brief, so it will restate its rules"; fi
done

# --- What no agent may restate --------------------------------------------------------
# These facts belong to the brief, which resolves them from the profile. An agent that
# writes one down has hard-coded a project — the defect the whole plugin exists to avoid.
# Each is an absence, and the witness above proves the file had something to look at.
# A function per rule rather than a table: the first version used `|` as its field
# separator, which is also what separates an alternation, so every pattern was truncated at
# its first `|` and the whole block was dead. The counter-proof caught it — adding
# "origin/main" to an agent raised nothing — which is the only reason it is not still dead.
forbid() { # forbid <pattern> <what it would be>
  local hits
  # -i, because a prompt starts its sentences with a capital: "Branch from main." slipped
  # through a case-sensitive `branch from main` for exactly that reason.
  hits=$(grep -liE -- "$1" "${AGENTS[@]}" 2>/dev/null | sed 's#.*/##' | tr '\n' ' ')
  if [ -z "$hits" ]; then
    ok "no agent hard-codes $2"
  else
    ko "$2 is hard-coded in: $hits"
  fi
}

# One prohibition per value-bearing profile key, declared here and checked against the
# schema below. Nine hand-picked patterns covered five keys of twelve, so nine realistic
# hard-codings passed green — including `eas submit`, the example epic #1 gives for what
# this plugin exists to prevent. Deriving the list from the schema means a new key cannot
# be added without either a prohibition or an explicit decision not to have one.
forbid_key() { # forbid_key <schema key> <pattern> <what it would be>
  FORBIDDEN_KEYS="$FORBIDDEN_KEYS $1"
  forbid "$2" "$3"
}
FORBIDDEN_KEYS=""

forbid_key base_branch 'origin/(main|master|trunk|develop)|branch from (main|master|trunk)' \
  'a base branch'
forbid_key check '(make check|npm (run|test)|cargo test|pytest|go test|just check)' \
  'a check command'
# The honest limit of this approach: a required-check name is an ordinary word. Nothing
# can tell `checks` the job from `checks` the noun, and a prompt that says "wait for the
# checks" is right to. So this covers the merge form and the review status, which are
# distinctive, and leaves check names to the review.
forbid_key merge '(--match-head-commit|agent-review|gh (issue|label) (create|edit))' \
  'the merge form or a review status'
forbid_key slots 'SLOT=[0-9]|slot (1|2|3|9)\b' 'a slot value'
forbid_key pr '[0-9]{3,4} (changed )?lines|(package-lock|yarn\.lock|Gemfile\.lock|Cargo\.lock)' \
  'a line budget or a lockfile'
forbid_key language '(write (to the human )?in (French|English|français)|langue)' 'a language'
forbid_key context '(docs/agents/|CONTEXT\.md|CLAUDE\.md)' 'a context document path'
forbid_key commands '(eas (build|submit|update)|npm publish|scalingo|clever|vercel|neonctl)' \
  'a project command'
forbid_key db_hosts_allowed '(psql|mysql|mongosh|localhost:[0-9]|127\.0\.0\.1)' \
  'a database host'
forbid_key verify_ui '(playwright|maestro|simctl|ios-simulator|--width [0-9])' \
  'a way of looking at the project'
forbid_key escalation_extra 'escalation_extra' 'the escalation list itself'
forbid_key mode '(integrated|discreet) mode means' 'what a mode means'
# The guard's own state is the one a prompt must never state, and for the sharpest reason:
# an agent told it will be refused, that is not, reads the silence as sanction — and one told
# nothing will stop it, while the guard refuses, learns that a refusal is a bug to work
# around. Both are worse than not knowing. The brief reads the key and says which it is.
forbid_key guard '(OLA_WORKFLOW_GUARD|guard is (on|off|enforcing|inert)|the guard (does not|never) (block|refuse))' \
  'whether the guard applies'

# Both directions: every value-bearing key has a prohibition, and every prohibition names a
# key the schema declares.
for key in $(jq -r '.properties | keys[] | select(startswith("$") | not)' \
              "$ROOT/schema/profile.schema.json"); do
  case " $FORBIDDEN_KEYS " in
    *" $key "*) ok "profile key '$key' has a prohibition guarding it" ;;
    *) ko "profile key '$key' can be hard-coded in a prompt with nothing to catch it" ;;
  esac
done
for key in $FORBIDDEN_KEYS; do
  if jq -e --arg k "$key" '.properties | has($k)' \
      "$ROOT/schema/profile.schema.json" >/dev/null 2>&1; then
    ok "the prohibition for '$key' names a key the schema declares"
  else
    ko "there is a prohibition for '$key', which the schema does not declare"
  fi
done

# --- Dispatch names are namespaced ----------------------------------------------------
# subagent_type is an exact match: a bare name does not resolve to a plugin agent, and the
# spike in the README is where that was measured. A coordinator that writes `developer`
# fails at dispatch time, in front of the human.
coord=$ROOT/agents/coordinator.md
if [ -s "$coord" ]; then
  for role in coordinator product-designer architect developer pr-reviewer; do
    if grep -q "\`$role\`" "$coord"; then
      ko "coordinator.md names \`$role\` without its plugin prefix"
    else
      ok "coordinator.md names $role only with its prefix"
    fi
  done
  # One assertion per role, derived from the declared set — not a count. A count of four
  # for a team of five let an agent be dropped from the coordinator entirely while the
  # suite stayed green: the file stayed flawless, nobody dispatched it, and the absence
  # assertion above was satisfied *by* the disappearance. An absence needs something to be
  # absent from.
  for role in $WORKFLOW_ROLES; do
    if [ "$role" = coordinator ]; then continue; fi
    if grep -q "ola-workflow:$role" "$coord"; then
      ok "coordinator.md dispatches ola-workflow:$role"
    else
      ko "coordinator.md never dispatches $role, so that agent is one nobody uses"
    fi
  done
else
  ko "coordinator.md is missing"
fi

# --- The agents and the schema --------------------------------------------------------
# The assertion that compares two kinds rather than two instances of one kind. Every key
# the schema declares must reach an agent through the brief, and the brief must not read a
# key the schema does not declare — the drift neither prose nor a grep over prompts sees.
for key in $(jq -r '.properties | keys[] | select(startswith("$") | not)' \
              "$ROOT/schema/profile.schema.json"); do
  if grep -q "\b$key\b" "$BRIEF"; then ok "schema key '$key' reaches the agents through the brief"; else ko "schema key '$key' is declared and no agent can ever see it"; fi
done
for key in $(grep -v '^[[:space:]]*#' "$BRIEF" |
             perl -nle 'print $1 while /\$\(get\s+"?([a-z_]+)/g' | sort -u); do
  if jq -e --arg k "$key" '.properties | has($k)' \
      "$ROOT/schema/profile.schema.json" >/dev/null 2>&1; then
    ok "the brief reads '$key', which the schema declares"
  else
    ko "the brief reads '$key', which the schema does not declare"
  fi
done

# --- No prompt may promise a guard that does not guard --------------------------------
# While hooks/guard.sh is inert, a present-tense claim that the guard refuses or asks is
# false, and in discreet mode it is dangerous: an agent told it will be asked, that pushes
# without asking and sees no prompt, reads the silence as sanction. So the claim is tied to
# the guard's actual state rather than to anyone's memory of it — when A3 makes the guard
# real, this assertion inverts and says so.
# Ask the guard instead of reading it. The first version inferred inertness from two
# textual proxies — a last code line of `exit 0`, and no mention of permissionDecision —
# and both break in the silent direction under the two things A3 will actually do: wrap the
# guard in a function, and write the decision emitters before wiring them. The assertion
# would then skip itself while printing a line that reads like a pass, on exactly the
# commit where the claim starts mattering. Behaviour cannot be fooled that way.
# The question is what a user experiences, which is neither "does the guard have rules"
# nor "does its suite expect decisions". A guard can hold every rule and ship them turned
# off — which is exactly what it does today, on purpose, because the rate of `ask` on real
# sessions is not measured yet. So the probe asks the guard, with a profile, in the
# environment it ships with, and a prompt may claim only what that answers.
#
# Earlier versions got this wrong twice: inferring inertness from the text of guard.sh
# (broken by the two refactors A3 performs) and from one Bash payload (blind to a rule
# about files). This asks the shipped artefact the user's own question.
GUARD_SUITE=$ROOT/tests/guard.test.sh
suite_cases=$(grep -cE '^[[:space:]]*(check|enforced) (allow|deny|ask)' "$GUARD_SUITE" || true)
if [ "$suite_cases" -gt 0 ]; then
  ok "the guard suite states $suite_cases decisions in the form this derivation reads"
else
  ko "the guard suite states no decision in the form read here, so the derivation is blind"
fi

WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ola-agents.XXXXXX")" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
export HOME=$WORK/home
mkdir -p "$HOME"

# $HOME is redirected before the probe and not only before the brief, because a profile
# under the real $HOME wins over the fixture's committed one — the probe would then be
# measuring this machine's configuration.
probe_repo=$WORK/guard-probe
mkdir -p "$probe_repo/.claude"
git -C "$probe_repo" -c init.defaultBranch=main init -q 2>/dev/null
printf '{"mode":"integrated","base_branch":"main"}\n' >"$probe_repo/.claude/workflow.json"

guard_decides=no
for cmd in '$(echo gh) pr merge 7' 'git push --force origin main' 'gh pr merge 7 --squash' \
           'eval gh pr merge 7' 'npm publish'; do
  said=$(jq -n --arg c "$cmd" --arg d "$probe_repo" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"probe",cwd:$d,
      agent_type:"ola-workflow:developer",tool_input:{command:$c}}' |
    "$ROOT/hooks/guard.sh" 2>/dev/null)
  status=$?
  if [ -n "$said" ] || [ "$status" != 0 ]; then
    guard_decides=yes
    break
  fi
done

# The witness: the same guard, with enforcement on, does decide. Without it this block
# would read "inert" just as happily from a guard that is broken, or from a profile the
# fixture failed to write — and then no prompt could ever be allowed to mention the guard.
enforced_said=$(jq -n --arg d "$probe_repo" \
  '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"probe2",cwd:$d,
    agent_type:"ola-workflow:developer",tool_input:{command:"$(echo gh) pr merge"}}' |
  OLA_WORKFLOW_GUARD=enforce "$ROOT/hooks/guard.sh" 2>/dev/null)
if [ -n "$enforced_said" ]; then
  ok "witness: the guard does decide when enforcement is on, so this probe measures something"
else
  ko "witness: the guard decides nothing even when enforcing — the probe below is vacuous"
fi

if [ "$guard_decides" = no ]; then
  for payload in \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push --force origin HEAD"}}' \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"gh pr merge 7 --squash"}}' \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":".github/workflows/ci.yml","content":"x"}}' \
    '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"hooks/guard.sh"}}'; do
    said=$(printf '%s' "$payload" | "$ROOT/hooks/guard.sh" 2>/dev/null)
    status=$?
    if [ -n "$said" ] || [ "$status" != 0 ]; then
      ko "the guard decides something its own suite never expects: $said"
      guard_decides=yes
      break
    fi
  done
fi


if [ "$guard_decides" = no ]; then
  claims=$(grep -lE 'guard (refuses|blocks|will ask|asks|prevents)' \
    "${ALL[@]}" "$BRIEF" 2>/dev/null | sed 's#.*/##' | tr '\n' ' ')
  if [ -z "$claims" ]; then
    ok "the guard decides nothing its suite expects, and no prompt claims otherwise"
  else
    ko "the guard decides nothing yet, and these promise otherwise: $claims"
  fi
else
  # The guard decides something now, and this arm is what that switch turns on.
  #
  # It asks of the **brief** and not of the five prompts, and that is a change from the shape
  # this assertion was written in ("all six must say so"). The reason is the one this project
  # keeps: whether the guard applies is a value in the profile, the brief is the single reader
  # of the profile, and five prompts restating a conditional fact would drift apart one
  # justified edit at a time — the exact failure the brief exists to prevent.
  #
  # It is not a weakening, because the other half is asserted from the other side: the
  # `forbid_key guard` prohibition above means no prompt may make a claim about enforcement
  # of its own, in either direction. Together: the one reader states it, and nobody else may.
  if grep -qE 'guard (refuses|blocks|will ask|asks|prevents)' "$BRIEF"; then
    ok "the guard decides, and the brief — the one reader of the profile — says so"
  else
    ko "the guard decides now, and the brief tells an agent nothing will stop it"
  fi
  # And it must say so for *both* values of the key, or the half that matters is missing: an
  # agent told nothing will stop it, while the guard refuses, learns to treat a refusal as a
  # bug to work around.
  for want in enforce log; do
    probe=$WORK/stops-$want
    mkdir -p "$probe/.claude"
    git -C "$probe" -c init.defaultBranch=main init -q 2>/dev/null
    printf '{"mode":"integrated","guard":"%s"}\n' "$want" >"$probe/.claude/workflow.json"
    # Through a file, not a pipe: `… | grep -q` reported a miss on output that holds the
    # match, and a harness that lies about the thing it measures is worse than no harness.
    # The file also lets the failure show what was printed.
    "$BRIEF" "$probe" >"$WORK/out-$want" 2>"$WORK/err-$want" || true
    # The *content*, not the heading: both branches print the heading, so grepping for it
    # left the suite green on a brief that told a log-mode agent "The guard refuses…" — the
    # exact defect the comment above cites. An assertion that cannot tell the two arms apart
    # is an assertion about a heading.
    case $want in
      enforce) expect='guard refuses' ;;
      log)     expect='Nothing\.' ;;
    esac
    if grep -q '## What stops you' "$WORK/out-$want" && grep -qE "$expect" "$WORK/out-$want"; then
      ok "the brief says what stops an agent when guard is $want, and says the right thing"
    else
      ko "the brief says nothing about what stops an agent when guard is $want: $(head -c 100 "$WORK/err-$want" "$WORK/out-$want" | tr '\n' ' ')"
    fi
  done
fi

# --- The brief, per mode --------------------------------------------------------------
# The mode rules live here rather than in five prompts, so this is where they are checked —
# against the program's real output, not against a sentence about it.
brief_for() { # brief_for <mode> → the brief of a throwaway project in that mode
  local mode=$1
  local repo=$WORK/$mode
  mkdir -p "$repo/.claude"
  git -C "$repo" -c init.defaultBranch=main init -q 2>/dev/null
  git -C "$repo" remote add origin "https://github.com/someone/$mode.git" 2>/dev/null
  printf '{"mode":"%s","base_branch":"trunk","check":{"full":"just check"},' "$mode" \
    >"$repo/.claude/workflow.json"
  printf '"slots":{"developers":[1,2],"reviewer":9},"merge":{"review_status":"reviewed"}}\n' \
    >>"$repo/.claude/workflow.json"
  "$BRIEF" "$repo"
}

integrated=$(brief_for integrated)
discreet=$(brief_for discreet)

# The witnesses first: every absence below would pass on an empty brief.
if [ "$(printf '%s' "$integrated" | wc -l)" -gt 20 ]; then ok "the integrated brief has content"; else ko "the integrated brief is empty or nearly so"; fi
if [ "$(printf '%s' "$discreet" | wc -l)" -gt 20 ]; then ok "the discreet brief has content"; else ko "the discreet brief is empty or nearly so"; fi

# Both modes resolve the profile rather than assuming anything.
for pair in "integrated:$integrated" "discreet:$discreet"; do
  mode=${pair%%:*}
  text=${pair#*:}
  case $text in
    *trunk*) ok "$mode: the brief names the project's own base branch" ;;
    *) ko "$mode: the brief does not name the base branch from the profile" ;;
  esac
  case $text in
    *"just check"*) ok "$mode: the brief names the project's own check command" ;;
    *) ko "$mode: the brief does not name the check command from the profile" ;;
  esac
done

# Discreet mode: no instruction to write on the forge, and none to merge. These are
# absences, and the witness above is what makes them mean something.
for forbidden in 'gh pr merge' 'gh issue create' 'gh label' 'gh pr comment' 'gh api'; do
  case $discreet in
    *"$forbidden"*) ko "the discreet brief still tells an agent how to run $forbidden" ;;
    *) ok "the discreet brief gives no way to run $forbidden" ;;
  esac
done
case $discreet in
  *'Merging. Nobody merges'*) ok "the discreet brief says nobody merges" ;;
  *) ko "the discreet brief does not forbid merging" ;;
esac
case $discreet in
  *runs/*) ok "the discreet brief names the local memory directory" ;;
  *) ko "the discreet brief does not say where the memory goes" ;;
esac

# Integrated mode does carry the merge form, with the SHA pinned.
case $integrated in
  *'--match-head-commit'*) ok "the integrated brief pins the merge to a SHA" ;;
  *) ko "the integrated brief does not pin the merge to a SHA" ;;
esac
case $integrated in
  *reviewed*) ok "the integrated brief names the project's own review status" ;;
  *) ko "the integrated brief does not name the review status from the profile" ;;
esac

# A value the profile does not state is announced as a default before the rules, not
# presented as one of them. Unmarked, a reviewer enforces a budget nobody set.
minimal=$WORK/minimal
mkdir -p "$minimal/.claude"
git -C "$minimal" -c init.defaultBranch=master init -q 2>/dev/null
git -C "$minimal" remote add origin https://github.com/someone/minimal.git 2>/dev/null
printf '{"mode":"integrated"}\n' >"$minimal/.claude/workflow.json"
bare=$("$BRIEF" "$minimal")
case $bare in
  *'these are my defaults'*) ok "a minimal profile says which values are the plugin's" ;;
  *) ko "a minimal profile presents the plugin's defaults as the project's rules" ;;
esac
# key → value, because the decision an agent makes is about the value: "pr.max_lines"
# alone does not tell it which budget not to enforce.
while read -r key value; do
  case $bare in
    *"$key → $value"*) ok "the defaults notice gives $key and its value" ;;
    *) ko "the defaults notice does not give $key → $value" ;;
  esac
done <<'PAIRS'
pr.max_lines 1000
pr.title conventional
merge.review_status agent-review
language.human en
slots.var SLOT
PAIRS
# The notice comes before the rules: a rule read first and qualified later has been believed.
notice_line=$(printf '%s' "$bare" | grep -n 'these are my defaults' | cut -d: -f1)
rule_line=$(printf '%s' "$bare" | grep -n '^Base branch:' | cut -d: -f1)
if [ -n "$notice_line" ] && [ -n "$rule_line" ] && [ "$notice_line" -lt "$rule_line" ]; then
  ok "the defaults notice comes before the rules"
else
  ko "the defaults notice comes after the rules (notice $notice_line, rules $rule_line)"
fi

# The base branch is the one default worth resolving: the repository knows its own.
git -C "$minimal" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init 2>/dev/null
git -C "$minimal" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master 2>/dev/null
case $("$BRIEF" "$minimal") in
  *'Base branch: master'*) ok "the base branch is read from origin/HEAD, not guessed" ;;
  *) ko "the base branch was guessed although origin/HEAD says master" ;;
esac

# A profile that is readable but does not match the schema is published with that said.
# A key spelled wrong is a key that is not there, and the real command is lost in silence.
printf '{"mode":"integrated","chekc":{"full":"make check"}}\n' >"$minimal/.claude/workflow.json"
invalid=$("$BRIEF" "$minimal")
case $invalid in
  *'does not match the schema'*) ok "a schema-invalid profile is published with a warning" ;;
  *) ko "a schema-invalid profile is published as if it were sound" ;;
esac
case $invalid in
  *chekc*) ok "the warning names the key that is wrong" ;;
  *) ko "the warning does not say which key is wrong" ;;
esac

# No profile: a refusal that says what to do, not a set of guessed defaults.
mkdir -p "$WORK/bare"
git -C "$WORK/bare" -c init.defaultBranch=main init -q 2>/dev/null
out=$("$BRIEF" "$WORK/bare" 2>&1)
status=$?
if [ "$status" = 1 ] && [ -n "$out" ]; then
  ok "no profile: the brief refuses, with a status and a reason"
else
  ko "no profile: the brief exited $status saying '${out:-nothing}'"
fi
case $out in
  *workflow-init*) ok "no profile: the refusal says what to do about it" ;;
  *) ko "no profile: the refusal does not offer workflow-init" ;;
esac
case $out in
  *trunk*|*"just check"*) ko "no profile: the refusal leaked another project's values" ;;
  *) ok "no profile: nothing is guessed" ;;
esac

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total agent test(s) failed"
  exit 1
fi
echo "all $total agent tests passed"
