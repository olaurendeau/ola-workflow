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
# shellcheck source=scripts/scratch.sh
. "$ROOT/scripts/scratch.sh"
BRIEF=$ROOT/bin/ola-workflow-brief
failures=0
total=0

ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

# The workflow roles, and the diagnostics that are not roles. Declared rather than
# globbed, so that `probe` — which exists to dump a hook payload, not to work — is not held
# to rules about modes and slots. Both directions are checked below, so a new file cannot
# quietly escape either set.
WORKFLOW_ROLES="coordinator product-designer design-reviewer architect developer pr-reviewer security-reviewer"
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

# The pages under docs/, because text moved out of the README does not stop being read by
# whoever opens the repository: a command named wrongly there is as wrong as in the README.
# Not security-precedents.md, which quotes what an attacker types, nor docs/design/, which
# holds pages published elsewhere and not prose of this project.
# `find` from $1/docs, never from the root of the repository: .claude/worktrees/ lives there
# and holds other agents' copies of this very tree. No globstar and no mapfile, for bash 3.2.
docs_pages() { # docs_pages <root> → the pages, one path per line, sorted
  [ -d "$1/docs" ] || return 0
  find "$1/docs" -type f -name '*.md' ! -path "$1/docs/design/*" ! -path "$1/docs/security-precedents.md" |
    LC_ALL=C sort
}
# The label keeps the path under docs/: docs/decisions/README.md is not README.md.
page_label() { # page_label <root> <path>
  case $2 in
    "$1"/docs/*) echo "docs/${2#"$1"/docs/}" ;;
    "$1"/brief/*) echo "brief/${2#"$1"/brief/}" ;;
    */skills/*) echo "skills/${2#*/skills/}" ;;
    *) echo "${2##*/}" ;;
  esac
}
# The text of the brief lives in brief/, in templates: the script no longer holds it, so a
# scan that read only the script would pass on less than it used to, and say nothing.
# Subfolders included, and no globstar for bash 3.2.
brief_pages() { # brief_pages <root> → the templates, one path per line, sorted
  [ -d "$1/brief" ] || return 0
  find "$1/brief" -type f -name '*.md' | LC_ALL=C sort
}
# The files scanned for offers, and the files that may promise what was removed. Functions of
# a root, because docs_pages answers nothing on the real tree today: that the docs pages are
# in both lists is proved further down, on a throwaway tree.
prompt_files() { # prompt_files <root> → one path per line
  local f
  for f in "$1"/agents/*.md "$BRIEF" "$1/README.md"; do echo "$f"; done
  for f in "$1"/skills/*/SKILL.md; do [ -f "$f" ] && echo "$f"; done
  docs_pages "$1"
  brief_pages "$1"
}
claimant_files() { # claimant_files <root> → one path per line
  local f
  for f in "$1"/agents/*.md "$BRIEF" "$1/README.md" "$1/skills/workflow-init/SKILL.md"; do echo "$f"; done
  docs_pages "$1"
  brief_pages "$1"
}
PROMPTS=()
while IFS= read -r page; do PROMPTS+=("$page"); done < <(prompt_files "$ROOT")

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
  label=$(page_label "$ROOT" "$f")
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
# What precedes an **offer** is a small closed set: nothing (the start of a line), a space, a
# tab, a backtick, an apostrophe, a double quote, an opening paren, an opening bracket. Eight
# positions, and both ends of the pattern are pinned by measurement further down — the
# apostrophe is written `\x27`, which it must be, since it cannot appear literally inside the
# single-quoted perl program. So the lookbehind is a whitelist, and the direction
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
  # The whitelist is written **once** and shared. It was written twice, and only the copy the
  # extent block pins was guarded: adding a character to the other copy alone left 83 of 89
  # additions green, two of them realistic — `-` makes `image: my-ola-workflow:latest` guilty
  # and `,` makes `tags: a,ola-workflow:1.2` guilty. A class written twice is a class agreed
  # once, which is this project's oldest lesson and it reached a regex.
  #
  # `[ \t]` and not `\s`: perl's `\s` also matches `\r`, `\f` and `\v`, so the set was
  # eleven characters while this file and the README both said eight — and a sweep of
  # printable ASCII structurally cannot see the other three. A claim of exactness has to be
  # exact.
  perl -ne '
    my $before = qr{(?:^|(?<=[ \t`(["\x27]))};
    while (m{$before/?(ola-workflow:[A-Za-z0-9_.:+-]+)}g)                  { print "named $1\n" }
    while (m{$before/([A-Za-z0-9_.+-]+)(?![:/?\#A-Za-z0-9_.+-])}g)         { print "slash $1\n" }
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
    # is not one of its commands. It is in docs/contributing.md, next to the reason.
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
# `/developer/settings`, `/coordinator?x=1`, `/developer#section`): a path has path after it,
# and that *is* decidable, unlike the token standing alone.
#
# It also holds `A-Za-z0-9_.+-`, and those are **not** dead, though they look it: the capture
# class is greedy, so the character after a maximal match can never be one of them. That
# reasoning ignores **backtracking**. The lookahead is re-tested every time `+` recedes, and
# those characters are what makes receding fail — that is, what aborts the whole match.
# Without them the pattern stops refusing and starts *truncating*: `/developers/me` yields
# `developer`, `/architects/list` yields `architect`, `-v /developers:/mnt` yields
# `developer`. All three measured, all three ordinary path text.
#
# I deleted them on the strength of that reasoning, after measuring that removing `.` changed
# nothing — and read that zero as proof of deadness when it was the absence of a fixture for
# this shape. The same zero that correctly meant "`:` has no reader" meant "nothing tests
# this" here. The fixture below exists so the reasoning is never needed again.
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

# --- The whitelist has exactly these members, no more and no fewer -------------------
# The fixtures above guard a member's **removal**: drop `"` from the class and a guilty line
# stops being caught. They say nothing about an **addition**, and the drift that cost a review
# cycle was an addition — two characters grew in the code while the README still named four.
# A sentence claiming "this cannot drift" was false in exactly the direction it was written to
# cover.
#
# So the extent is pinned by measurement, not by a list written twice: every printable
# character is put in front of a role name and the set that makes it an offer is compared with
# the one this check means to have. Adding a member fails here; removing one fails above.
# All 256 bytes, in perl, and not 32..126 in awk. The printable range cannot see `\r`, `\f`
# or `\v`, which perl's `\s` matches — so the version of this sweep that stopped at 126 left
# the `[ \t]`-not-`\s` fix unguarded, and restoring `\s` passed green while the assertion
# printed "exactly these 8". A sweep that cannot see a character cannot pin it.
# Done in one perl process rather than 512 shell round trips: the scan is one regex, and
# reimplementing it here would be the second copy this file exists to avoid — so the pattern
# is read out of this file and applied, which also means a change to it cannot be missed.
extent=$(perl -e '
  my $src = do { local (@ARGV, $/) = ($ARGV[0]); <> };
  my ($before) = $src =~ /my \$before = (qr\{.*?\});/s;
  my ($slash)  = $src =~ /while \(m\{\$before(\/\(\[A-Za-z0-9_\.\+-\]\+\)\(\?\![^}]*\))\}g\)/s;
  die "pattern not found in the file under test\n" unless $before && $slash;
  my $re = qr{${\ eval $before }$slash};
  my (@makes, @blocks);
  for my $i (0 .. 255) {
    my $pre = chr($i) . "/developer\n";
    push @makes, $i if $pre =~ /$re/ && $1 eq "developer";
    # A trailing /me, not just the character: with the character alone the greedy capture
    # class absorbs it whatever the lookahead says, so the probe cannot tell the two apart,
    # and that is why the first version of this block measured zero for six members. The
    # trailing path forces the match to recede, and receding is where the lookahead decides
    # between aborting and truncating. (No apostrophes in here: this is inside a
    # single-quoted shell string, and one would close it. Third time.)
    my $post = " /developer" . chr($i) . "/me\n";
    push @blocks, $i unless $post =~ /$re/ && $1 eq "developer";
  }
  push @makes, "bol" if "/developer\n" =~ /$re/ && $1 eq "developer";
  printf "%s|%s\n", join(",", @makes), join(",", @blocks);
' "$0")
makes=${extent%%|*}
blocks=${extent#*|}

# 9 tab, 32 space, 34 ", 39 ', 40 (, 91 [, 96 `, plus the start of a line.
want_makes='9,32,34,39,40,91,96,bol'
if [ "$makes" = "$want_makes" ]; then
  ok "exactly 8 positions make an offer, over all 256 bytes"
else
  ko "the lookbehind's extent changed: [$makes] against [$want_makes]"
fi

# And the other end, which had no reader at all. The 70 bytes below are exactly the
# lookahead's own character set, so dropping any member — `A-Z`, `0-9`, `_`, `.`, `+`, `-`
# included — moves the set and fails here. Each of those six was droppable with the suite
# staying green, and `/developer.md#modes` was a measured false positive; the granularity is
# where the defect hid, since `A-Za-z0-9_.+-` reads as one member while it is six.
# Seventy, and they add up: the four the lookahead names on its own (35 #, 47 /, 58 :, 63 ?)
# plus the capture class it repeats — 26 upper, 26 lower, 10 digits, and 4 more (_ . + -).
# 4 + 26 + 26 + 10 + 4 = 70, so a reader can check the literal without running it.
want_blocks='35,43,45,46,47,48,49,50,51,52,53,54,55,56,57,58,63,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,95,97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,112,113,114,115,116,117,118,119,120,121,122'
if [ "$blocks" = "$want_blocks" ]; then
  ok "exactly 70 bytes keep a role name from being a verdict, over all 256"
else
  ko "the lookahead's extent changed: [$blocks] against [$want_blocks]"
fi

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
a mount -v /tmp:/developer and a label app:/probe
an anchor /developer#section and a file /probe.json and /coordinator.md
and a mount -v /developer:/mnt, whose host path is a role name
and /developers/me, /architects/list, -v /developers:/mnt — a role name plus a letter
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
# A here-document, not a single-quoted string: one of the characters under test **is** the
# apostrophe, and a shell single-quoted string cannot hold one. Writing `\x27` there put the
# four literal characters in the fixture instead, so the form it was added to cover was still
# not covered — the second time in two commits that this quoting bit the same way.
guilty=$(cat <<'GUILTY'
run /workflow-init to set up
later /no-such-skill will exist (a negative fixture: it must produce no verdict at all)
offer /ola-workflow:nope and dispatch ola-workflow:nope
/ola-workflow:Workflow_Init and /ola-workflow:workflow-init.v2
and /developer, which is an agent
offer "/ola-workflow:nope-dq" and '/ola-workflow:nope-sq' and `/ola-workflow:nope-bt`
and (/ola-workflow:nope-par) and [/ola-workflow:nope-brk]
GUILTY
)

accused=$(printf '%s\n' "$innocent" | verdicts_for | sed -n 's/^ko://p')
if [ -z "$accused" ]; then
  ok "the scan accuses none of the 22 lines of correct text it has failed on or nearly did"
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
# One distinct token per member of the whitelist, because the verdict set is deduplicated by
# token: the line added to "close the quoted forms" produced `named:nope` and
# `slash:workflow-init`, which two other lines already produced, so it guarded nothing.
# Measured — five of the six members could be deleted from the lookbehind with no assertion
# moving, and the commit that added two of them claimed to have closed them. A fixture whose
# verdict is already in the set is a fixture that is not read.
expected='named:Workflow_Init
named:nope
named:nope-brk
named:nope-bt
named:nope-dq
named:nope-par
named:nope-sq
named:workflow-init.v2
slash:developer
slash:workflow-init'
# LC_ALL=C, because the collation of the user's locale decides whether `Workflow_Init`
# sorts before `nope` — and this assertion compared a sorted list against a written one, so
# it passed in `make` and failed in an interactive shell on the same files. A test whose
# verdict depends on the environment's locale is a test that is right by accident.
caught=$(printf '%s\n' "$guilty" | verdicts_for | sed -n 's/^ko://p' | LC_ALL=C sort -u | grep . || true)
if [ "$caught" = "$expected" ]; then
  ok "the scan catches exactly the 10 broken spellings it claims, and no others"
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
for role in product-designer design-reviewer architect developer pr-reviewer security-reviewer; do
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
  # that does not exist — the spike recorded in docs/agent-identity.md established which.
  ignored=$(printf '%s' "$fm" | grep -cE '^(permissionMode|hooks|mcpServers|initialPrompt|observer[A-Za-z]*):')
  if [ "$ignored" = 0 ]; then ok "$name: claims no frontmatter key that plugin agents ignore"; else ko "$name: sets a key that is ignored for a plugin agent"; fi
done

# Only the developer works in a worktree.
worktrees=$(grep -l '^isolation: worktree' "${AGENTS[@]}" | sed 's#.*/##' | tr '\n' ' ')
if [ "$worktrees" = "developer.md " ]; then ok "only the developer is isolated in a worktree"; else ko "worktree isolation is on: ${worktrees:-nobody}"; fi

# --- What each agent runs on ------------------------------------------------------------
# Declared here, not read off the files, for the reason the roles themselves are declared
# above: an expectation taken from the thing it checks is not an expectation. `-` means the
# key is absent, so that role follows the session — only the coordinator does, because it is
# the session agent and the human picks its model.
#
# This replaced a pair of greps asserting "only the reviewer pins a model". That one
# sentence covered two things at once — the reviewer pins one, nobody else does — and a map
# only covers what it names, so this one names every file under `agents/`, `probe` included,
# which the pair it replaces left out of its set.
EXPECTED_MODEL="coordinator=- product-designer=sonnet design-reviewer=sonnet architect=opus developer=sonnet pr-reviewer=opus security-reviewer=opus probe=haiku"
EXPECTED_EFFORT="coordinator=- product-designer=- design-reviewer=- architect=- developer=high pr-reviewer=high security-reviewer=high probe=low"

# fm_key <frontmatter> <key> → the value, or nothing. Takes the text rather than the path,
# so the witness below can hand it a fixture instead of a file.
fm_key() { printf '%s\n' "$1" | sed -n "s/^$2: *//p"; }

# The witness beside the absences, and it is the whole of what keeps them honest: every
# comparison below reads `-` once the pattern stops matching, and a map corrected to `-`
# everywhere would then pass on seven files that pin nothing at all.
fixture=$(printf 'name: x\nmodel: sonnet\neffort: high\n')
if [ "$(fm_key "$fixture" model)" = sonnet ] && [ "$(fm_key "$fixture" effort)" = high ]; then
  ok "the extractor reads a model and an effort off a frontmatter that has both"
else
  ko "the extractor reads no model or no effort off a fixture that has both"
fi

for f in "${ALL[@]}"; do
  name=${f##*/}
  stem=${name%.md}
  fm=$(frontmatter "$f")
  for key in model effort; do
    case $key in
      model) declared=$EXPECTED_MODEL ;;
      effort) declared=$EXPECTED_EFFORT ;;
    esac
    got=$(fm_key "$fm" "$key")
    want=
    # A name is compared against a list of names with `case`, one pair at a time: a single
    # pattern over the whole map would match a value where it meant to match a key.
    for pair in $declared; do
      case $pair in "$stem="*) want=${pair#*=} ;; esac
    done
    if [ -z "$want" ]; then
      ko "$name: this suite declares no $key for it, so nothing says what it should run at"
    elif [ "${got:--}" = "$want" ]; then
      if [ "$want" = - ]; then
        ok "$name: pins no $key, so it follows the session"
      else
        ok "$name: $key is $want"
      fi
    else
      ko "$name: $key is '${got:--}', and this suite declares '$want'"
    fi
  done
done

# The pair that keeps the maps and the tree the same size. The loop above walks the files,
# so it cannot see a name left in a map after its file goes, nor a map that names one agent
# fewer than the other — and both would read as "nothing to check here".
for entry in "model:$EXPECTED_MODEL" "effort:$EXPECTED_EFFORT"; do
  key=${entry%%:*}
  named=$(printf '%s' "${entry#*:}" | tr ' ' '\n' | grep -c .)
  if [ "$named" = "${#ALL[@]}" ]; then
    ok "the $key map names one agent per file under agents/"
  else
    ko "the $key map names $named agents, and agents/ holds ${#ALL[@]} files"
  fi
done

# Who may publish, and who may write. The product-designer publishes its design to claude.ai
# and writes the page it publishes, outside the repository — so `Write`, never `Edit`: there
# is no file of the project it has any business changing. The design-reviewer judges that
# page and must not be able to touch it, which is the whole of its independence. The
# security-reviewer is held to the same: it judges code, and could otherwise fix what it
# found and call the finding closed.
# tools_of <role> → its declared tools, one per line.
tools_of() { frontmatter "$ROOT/agents/$1.md" | sed -n 's/^tools: *//p' | tr ',' '\n' | tr -d ' '; }
for want in Artifact Write; do
  if tools_of product-designer | grep -qx "$want"; then
    ok "product-designer: declares $want, to publish its design"
  else
    ko "product-designer: does not declare $want, so visual work cannot be published"
  fi
done
for role in $WORKFLOW_ROLES; do
  [ "$role" = product-designer ] && continue
  if tools_of "$role" | grep -qx Artifact; then
    ko "$role: declares Artifact, which only the product-designer publishes with"
  else
    ok "$role: cannot publish an artifact"
  fi
done
for unwanted in Edit Write; do
  case $unwanted in
    Write) roles="design-reviewer security-reviewer" ;;
    *) roles="product-designer design-reviewer security-reviewer" ;;
  esac
  for role in $roles; do
    if tools_of "$role" | grep -qx "$unwanted"; then
      ko "$role: declares $unwanted, so it can change what it was asked to judge"
    else
      ok "$role: does not declare $unwanted"
    fi
  done
done
# The witness for the absences above: they pass on a role whose tools line went missing.
for role in product-designer design-reviewer security-reviewer; do
  if [ -n "$(tools_of "$role")" ]; then ok "$role: has a tools line to read"; else ko "$role: has no tools line, so the absences above say nothing"; fi
done

# The coordinator is the session agent, and a session agent's `tools:` list filters out MCP
# tools too: without this entry a `claude --chrome` session under the coordinator has no
# Claude in Chrome tool at all (#68). The server-level form is what Claude Code documents
# for `tools`; the subagents work in worktrees and have no browser to drive.
if tools_of coordinator | grep -qx 'mcp__claude-in-chrome__\*'; then
  ok "coordinator: declares the Claude in Chrome tools, so a --chrome session keeps them"
else
  ko "coordinator: does not declare mcp__claude-in-chrome__*, so --chrome gives it no browser tool"
fi
for role in $WORKFLOW_ROLES; do
  [ "$role" = coordinator ] && continue
  if tools_of "$role" | grep -q '^mcp__'; then
    ko "$role: declares an MCP tool, and only the coordinator drives the browser"
  else
    ok "$role: declares no MCP tool"
  fi
done

# The words of an interface are decided by the product-designer, and the developer takes
# them as they are. Unowned, they are written by whoever writes the code last.
if grep -qE '^[0-9]+\. \*\*Write the words' "$ROOT/agents/product-designer.md"; then
  ok "product-designer: has a step that decides the words of the interface"
else
  ko "product-designer: nothing says who writes the words a user reads"
fi
if grep -qi 'verbatim' "$ROOT/agents/developer.md"; then
  ok "developer: takes the designer's words and design files verbatim"
else
  ko "developer: nothing stops it rewording what the designer decided"
fi
# What the developer reads, runs and reports is a cost paid on every task, so each rule is a
# sentence it must keep. Each is looked for in the step that carries it, as one line: where
# prose wraps is not what it says, and a file-wide grep stays green with the step rewritten.
dev=$ROOT/agents/developer.md
dev_step() { # dev_step <n> — the text of step <n>, as one line
  awk -v n="$1" '$0 ~ "^" n "\\. \\*\\*" {on=1; print; next} on && /^([0-9]+\. \*\*|## )/{exit} on' "$dev" \
    | tr -s ' \n' '  '
}
dev_section() { # dev_section <heading> — the text under "## <heading>", as one line
  awk -v h="## $1" 'index($0, h) == 1 {on=1; next} on && /^## /{exit} on' "$dev" | tr -s ' \n' '  '
}
step1=$(dev_step 1); step2=$(dev_step 2); step3=$(dev_step 3); step4=$(dev_step 4)
findings=$(dev_section "When the coordinator sends review findings")
report=$(dev_section "Report")
for s in "$step1" "$step2" "$step3" "$step4" "$findings" "$report"; do
  [ -n "$s" ] || ko "developer: a step the cost rules live in cannot be read"
done
case $step1 in
  *'line range'*'grep -n'*) ok "developer: reads the passages it needs, by range or grep -n" ;;
  *) ko "developer: step 1 reads every named file whole" ;;
esac
case $step2 in
  *'git fetch -q'*) ok "developer: fetches the head of a pull request it takes over" ;;
  *) ko "developer: takes over a pull request without fetching its head" ;;
esac
case $step2 in
  *'detached HEAD'*'git push origin HEAD:<branch>'*'another agent'*)
    ok "developer: takes over a pull request in a detached HEAD, pushes to its branch, leaves other worktrees alone" ;;
  *) ko "developer: nothing says how to take over a branch checked out in another worktree" ;;
esac
case $step2 in
  *'not with `git checkout <branch>`'*'git checkout --detach origin/<branch>'*)
    ok "developer: does not send a pull request takeover to a plain git checkout" ;;
  *) ko "developer: tells a takeover to check the branch out, which git refuses in another worktree" ;;
esac
case $step3 in
  *'only the test you are writing'*) ok "developer: runs only the test it writes, for red and green" ;;
  *) ko "developer: runs more than the test it writes while building" ;;
esac
case $step4 in
  *'once, at the end'*) ok "developer: runs the affected command once, at the end" ;;
  *) ko "developer: nothing limits how often the affected command runs" ;;
esac
case $step4 in
  *'only to check a fix to that suite'*) ok "developer: reruns a full or end-to-end suite only to check a fix to it" ;;
  *) ko "developer: reruns a full suite without a reason" ;;
esac
case $findings in
  *'touched test first'*'once'*) ok "developer: re-checks a fix with the touched test, then the affected command once" ;;
  *) ko "developer: re-checks a fix with everything" ;;
esac
case $findings in
  *'git merge origin/<base>'*'never rebase'*'never force'*)
    ok "developer: catches up by merging the base branch, never rebases, never forces a push" ;;
  *) ko "developer: does not name the catch-up method, so a rebase and a forced push stay possible" ;;
esac
case $report in
  *'one line each'*'pull request description'*) ok "developer: reports what changed and what it tested in one line each" ;;
  *) ko "developer: reports in detail what the pull request already says" ;;
esac
# The coordinator carries the artifact's URL into the epic: the next request on the same
# screen starts from it rather than publishing a second page. (That it dispatches the
# design-reviewer is checked with every other role, from WORKFLOW_ROLES.)
if grep -q 'artifact URL' "$ROOT/agents/coordinator.md"; then
  ok "coordinator: records the artifact URL in the epic"
else
  ko "coordinator: never records the artifact URL in the epic"
fi

# The coordinator is the main session. Launched as a sub-agent it loses its prompt cache
# after 5 minutes and never summarises its context, and a coordinator spends its time
# waiting: one such run cost 40% of a project's tokens over three days. The rule lives in the
# prompt only (no hook), so this sentence is all that holds it. Read flattened, so that a
# line wrap in the prompt does not decide the verdict.
coord=$(tr -s ' \n' '  ' < "$ROOT/agents/coordinator.md")
case $coord in
  *'never dispatch `ola-workflow:coordinator` as a sub-agent'*) ok "coordinator: never dispatches itself as a sub-agent" ;;
  *) ko "coordinator: nothing forbids dispatching ola-workflow:coordinator as a sub-agent" ;;
esac
case $coord in
  *'in parallel, with the slots from the brief'*) ok "coordinator: handles a new request itself while an epic runs" ;;
  *) ko "coordinator: does not say who handles a new request while an epic runs" ;;
esac
case $coord in
  *'loses its prompt cache after 5 minutes'*'never summarises its context'*) ok "coordinator: gives the reason, cache lost and context never summarised" ;;
  *) ko "coordinator: gives no reason for never running as a sub-agent" ;;
esac

# The human reads the coordinator in a terminal, where "#204" is not clickable: the first
# mention of a pull request or an issue, in each message, is a full link. The prompt is the
# only thing that holds it. Read flattened, as above. The rule has to name both kinds of
# page (the pull request or merge request, and the issue), say "first mention" and "each
# message", and build the link for GitHub and for GitLab; it writes nothing to the forge.
case $coord in
  *'**first mention**'*'full link'*) ok "coordinator: links the first mention of a pull request or issue" ;;
  *) ko "coordinator: says nothing of a link at the first mention" ;;
esac
case $coord in
  *'In **each** message'*'pull request'*'merge request'*'or an issue'*) ok "coordinator: the link rule covers pull requests, merge requests and issues, in each message" ;;
  *) ko "coordinator: the link rule does not cover both pull requests and issues in each message" ;;
esac
case $coord in
  *'<repo-url>/pull/<N>'*'<repo-url>/issues/<N>'*'<repo-url>/-/merge_requests/<N>'*'<repo-url>/-/issues/<N>'*) ok "coordinator: builds the link for GitHub and for GitLab" ;;
  *) ko "coordinator: does not build the link for both GitHub and GitLab" ;;
esac
# The remote is `upstream` first, as `gh` resolves it: in a fork, `origin` is another
# repository, whose pull request of the same number is another page. The forge is asked
# first, since it resolves the fork, the SSH alias and the subgroup.
case $coord in
  *'Ask the forge for the URL'*'gh pr view <N> --json url'*'gh issue view <N> --json url'*) ok "coordinator: asks the forge for the URL first" ;;
  *) ko "coordinator: does not ask the forge for the URL of a pull request or an issue" ;;
esac
case $coord in
  *'git remote get-url upstream || git remote get-url origin'*) ok "coordinator: the fallback takes upstream before origin, as gh does" ;;
  *) ko "coordinator: the fallback does not take upstream before origin" ;;
esac
case $coord in
  *'the web host'*'ssh.github.com'*'the whole path'*'subgroup'*) ok "coordinator: the fallback uses the web host and the whole path" ;;
  *) ko "coordinator: the fallback does not say web host and whole path, so an alias or a subgroup gives a dead link" ;;
esac
case $coord in
  *'posts no comment and changes nothing there'*) ok "coordinator: the link rule writes nothing on the forge" ;;
  *) ko "coordinator: the link rule does not say it writes nothing on the forge" ;;
esac

# --- The security review ---------------------------------------------------------------
# A false positive here is not a comment someone scrolls past: a blocking finding sends a
# developer round the review loop, then a delta review, then an arbitration. So each thing
# that keeps one from reaching the developer is a sentence its owner must keep. Prose, not
# proof — what these catch is the sentence deleted in a rewrite, which is how a safeguard
# goes without anyone deciding it should.
sec=$ROOT/agents/security-reviewer.md
# The witness: the absence of a status below passes on a file that publishes nothing.
if grep -q 'Security review of' "$sec"; then
  ok "security-reviewer: publishes its review under a prefix of its own"
else
  ko "security-reviewer: publishes no review anyone, or the next cycle, can find"
fi
# Its findings are advice the coordinator relays. A status it wrote would be a second gate
# nobody configured, and GitHub refuses it the token anyway.
if grep -q 'statuses/' "$sec"; then
  ko "security-reviewer: writes a commit status, and its verdict is advice"
else
  ok "security-reviewer: writes no commit status"
fi
if grep -q '^## Verifying one finding' "$sec" && grep -q 'Verification of' "$sec"; then
  ok "security-reviewer: has a verify mode that publishes its verdict"
else
  ko "security-reviewer: has no verify mode, so a finding is only ever checked by its author"
fi
# Read at the head, a precedent could be added by the very change it excuses. Looked for in
# the step that reads the precedents, not in the whole file: the refutation step reads the
# base too, for another reason, and kept a file-wide grep green with this one rewritten.
if awk '/^2\. \*\*Read what is settled/{on=1} /^3\. /{on=0} on' "$sec" | grep -qF 'origin/<base>:'; then
  ok "security-reviewer: reads the precedents from the base branch"
else
  ko "security-reviewer: reads the precedents where the change under review can edit them"
fi
if grep -q 'all three hold' "$sec"; then
  ok "security-reviewer: blocks only when all three conditions hold"
else
  ko "security-reviewer: no explicit rule says when a finding blocks"
fi
if grep -q 'pending verification' "$ROOT/agents/coordinator.md" &&
   grep -qF 'Only a `confirmed` finding goes to the developer' "$ROOT/agents/coordinator.md"; then
  ok "coordinator: sends a security finding to the developer only once it is confirmed"
else
  ko "coordinator: can send an unverified security finding to the developer"
fi
# The merge waits for the security review. It sets no status and the merge gate does not read
# it, so this sentence is all that holds the coordinator back: written as "no finding is
# confirmed", it was already true while the security review was still running, and while a
# finding waited for its verifier. Read in the sentence that ends step 6, where it binds, as
# one line: where prose wraps is not what it says.
done_when=$(awk '/^   Done when the review on the current head SHA/{on=1} on && /^$/{exit} on' \
  "$ROOT/agents/coordinator.md" | tr -s ' \n' '  ')
if [ -n "$done_when" ]; then
  ok "coordinator: step 6 ends on a Done when"
else
  ko "coordinator: step 6 has no Done when to read"
fi
# Two clauses, each its own: nested under "when a security review is owed", the first went
# quiet after a fix that owed none, and a confirmed finding merged.
case $done_when in
  *'; no security finding is `confirmed` and still open;'*)
    ok "coordinator: never merges over a confirmed security finding" ;;
  *) ko "coordinator: can merge over a confirmed security finding" ;;
esac
case $done_when in
  *'the last security review owed'*'has reported'*'pending verification'*'has a verdict'*)
    ok "coordinator: does not merge before the security review and its verifications are in" ;;
  *) ko "coordinator: can merge while the security review or a verification is still running" ;;
esac
# A security review owed on every head would contradict the rule for fixes, which owes one
# only when the fix touches the security paths.
case $done_when in
  *'on that same SHA'*) ko "coordinator: owes a security review on every head SHA" ;;
  *) ok "coordinator: owes a security review only when one is owed" ;;
esac
if grep -q 'security_precedents' "$ROOT/agents/coordinator.md"; then
  ok "coordinator: turns a ruled false positive into a precedent"
else
  ko "coordinator: a false positive the human ruled on comes back on the next request"
fi
# It reads at the SHA and runs nothing, so a reviewer slot would only keep a pr-reviewer
# waiting: a request touching a security path would take both slots of a project with two.
if grep -qi 'reviewer slot' "$sec"; then
  ko "security-reviewer: takes a reviewer slot it never uses"
else
  ok "security-reviewer: takes no reviewer slot"
fi
# The brief is what the coordinator dispatches from, so it says so too.
if grep -q '## Security review' "$ROOT/brief/security-review.md" && grep -q 'takes no slot' "$ROOT/brief/security-review.md"; then
  ok "the brief says the security review takes no slot"
else
  ko "the brief does not say the security review takes no slot"
fi
# Two reviewers comment on one request. Each finds its own previous review to compute a
# delta, and the pr-reviewer taking the security review for its own would review from the
# wrong SHA.
if grep -q 'Security review of' "$ROOT/agents/pr-reviewer.md" &&
   grep -q 'Verification of' "$ROOT/agents/pr-reviewer.md"; then
  ok "pr-reviewer: does not take a security comment for its previous review"
else
  ko "pr-reviewer: may take a security comment for its own previous review"
fi
# The checks take minutes and the review takes as long: a reviewer that waits for them to
# end serialises the two. It reads them once and publishes; the merge gate reads the CI
# again on its own, and the report's CI line tells the coordinator to.
prr=$(tr '\n' ' ' < "$ROOT/agents/pr-reviewer.md" | tr -s ' ')
# The witness: the paragraph that carried the old sentence is still there to be looked at.
case $prr in
  *'Do not run the full check yourself'*) ok "witness: pr-reviewer step 5 is readable" ;;
  *) ko "witness: pr-reviewer step 5 is not where the absence below looks" ;;
esac
if printf '%s' "$prr" | grep -qiE 'wait(s|ing)? (for|until) (them|the checks?|CI)'; then
  ko "pr-reviewer: waits for the checks to finish before it publishes"
else
  ok "pr-reviewer: does not wait for the checks to finish"
fi
case $prr in
  *'CI: green | running | failed: <check> | cancelled'*)
    ok "pr-reviewer: reports where the CI stands, so the coordinator reads it again before merging" ;;
  *) ko "pr-reviewer: reports no CI line, so a status given while the checks ran looks final" ;;
esac
# Step 7 withholds the status of a SHA the head left; the line must have a value for it.
case $prr in
  *'Report `CI: cancelled`'*) ok "pr-reviewer: says what it reports when the checks were cancelled" ;;
  *) ko "pr-reviewer: a cancelled check has no value on the CI line" ;;
esac
case $prr in
  *'git grep -n'*"sed -n '<a>,<b>p'"*) ok "pr-reviewer: says how to read a range at the SHA" ;;
  *) ko "pr-reviewer: names no way to read a range at the SHA, so every git show looks banned" ;;
esac
case $prr in
  *'Never read a whole file that way'*) ok "pr-reviewer: does not read whole files at the SHA" ;;
  *) ko "pr-reviewer: may read whole files with git show, thousands of calls on a large request" ;;
esac
# The meaning of the status: it judges the code and the checks already failed, not the
# checks green. Requiring them green is what made the reviewer wait for them.
case $prr in
  *'successful only with zero blocking findings **and** no required check already failed'*)
    ok "pr-reviewer: a successful status needs no failed required check, not a green CI" ;;
  *) ko "pr-reviewer: the meaning of a successful status is not the one that lets it publish while checks run" ;;
esac
case $prr in
  *'successful only with'*'checks green on that SHA'*)
    ko "pr-reviewer: requires the checks green to set a successful status, so it waits for them" ;;
  *) ok "pr-reviewer: does not require the checks green to set a successful status" ;;
esac
case $prr in
  *'Checks still running'*'judgement of the code alone'*'A required check already failed'*'status is `failure` and names the check'*)
    ok "pr-reviewer: running checks do not hold the status, a failed one does" ;;
  *) ko "pr-reviewer: nothing says what the status is while checks run or after one fails" ;;
esac

# A catch-up of the base branch gives a new head SHA and leaves the request's change as it
# was: a confirmation of the previous review, not a review of the changes again. The witness
# first: the paragraph the absences and phrases below are looked for in.
case $prr in
  *'A **confirmation** is for a head that is the reviewed SHA caught up with the base branch'*)
    ok "witness: pr-reviewer step 3 has its confirmation paragraph" ;;
  *) ko "witness: pr-reviewer step 3 has no confirmation paragraph, the checks below look at nothing" ;;
esac
case $prr in
  *'git merge-tree --write-tree'*) ok "pr-reviewer: a confirmation needs a merge of the base that conflicts with nothing" ;;
  *) ko "pr-reviewer: a confirmation does not check that merging the base conflicts with nothing" ;;
esac
case $prr in
  *'git patch-id --verbatim'*) ok "pr-reviewer: a confirmation needs the request's change identical" ;;
  *) ko "pr-reviewer: a confirmation does not check that the request's change is identical" ;;
esac
case $prr in
  *'--no-color --no-ext-diff origin/<base>...<reviewed SHA> | git patch-id --verbatim'*'--no-color --no-ext-diff origin/<base>...<head> | git patch-id --verbatim'*)
    ok "pr-reviewer: the comparison of a confirmation does not depend on the host's git config" ;;
  *) ko "pr-reviewer: the comparison of a confirmation can be blinded by color.diff or diff.external" ;;
esac
case $prr in
  *'full, delta from <SHA> or confirmation of <SHA>'*) ok "pr-reviewer: the report says confirmation of <SHA>" ;;
  *) ko "pr-reviewer: the report has no value for a confirmation" ;;
esac
case $prr in
  *'you do not review the changes again (steps 4 and 6) and you do not break the code in a worktree to see whether the tests fail'*)
    ok "pr-reviewer: a confirmation redoes neither the review nor the tests breaking the code" ;;
  *) ko "pr-reviewer: nothing says a confirmation spares the review and the tests breaking the code" ;;
esac
case $prr in
  *'A blocking finding that was still open stays open'*'so the status is `failure`'*)
    ok "pr-reviewer: a confirmation carries an open blocking finding, and a catch-up lifts none" ;;
  *) ko "pr-reviewer: nothing says a confirmation keeps an open blocking finding open" ;;
esac
# What is carried to the head is the findings, not the verdict: a republished `failure` would
# keep the merge gate shut after a flaky check's rerun, or ignore a catch-up that breaks CI.
case $prr in
  *'previous verdict carried over'*)
    ko "pr-reviewer: a confirmation carries the previous verdict over, and may republish a stale failure" ;;
  *'The findings are carried, not the verdict: step 8 sets the status from them and from the checks of the head'*'with none open, it is `success` unless a required check failed on the head'*)
    ok "pr-reviewer: a confirmation carries the findings and lets step 8 set the status from the head's checks" ;;
  *) ko "pr-reviewer: nothing says a confirmation sets its status from the findings and the head's checks" ;;
esac
case $prr in
  *'cannot be evaluated because the reviewed SHA is gone, review the changes as usual'*)
    ok "pr-reviewer: a condition that cannot be evaluated sends back to the normal review" ;;
  *) ko "pr-reviewer: nothing says what a confirmation does when its conditions cannot be evaluated" ;;
esac
case $prr in
  *'diff <(git diff <base>...<reviewed SHA>) <(git diff <base>...<head>)'*) ok "pr-reviewer: the delta command is still there" ;;
  *) ko "pr-reviewer: the delta command is gone" ;;
esac

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
forbid_key context '(docs/agents/|docs/design|CONTEXT\.md|CLAUDE\.md)' 'a context document path'
forbid_key commands '(eas (build|submit|update)|npm publish|scalingo|clever|vercel|neonctl)' \
  'a project command'
forbid_key db_hosts_allowed '(psql|mysql|mongosh|localhost:[0-9]|127\.0\.0\.1)' \
  'a database host'
forbid_key verify_ui '(playwright|maestro|simctl|ios-simulator|--width [0-9])' \
  'a way of looking at the project'
# What a prompt that hard-codes a preview would write: a dev server command or its address.
forbid_key preview '(npm run dev|yarn dev|pnpm dev|rails server|https?://localhost)' \
  'a way of starting a preview'
forbid_key escalation_extra 'escalation_extra' 'the escalation list itself'
# The paths that get a security review, and the command that matches them, are the brief's:
# a prompt that lists them has decided for every project which files are worth a look.
forbid_key security '(security\.paths|:\(glob\)|security-precedents)' \
  'which paths get a security review'
# Waiting on CI is the brief's rule: it says to read a check once. A prompt that loops or
# watches contradicts it. `forbid`, not `forbid_key`: this is no profile key.
forbid '--watch|sleep [0-9]|until .*sleep' 'a busy-wait on CI'
forbid_key mode '(integrated|discreet) mode means' 'what a mode means'
# Whether GitHub refuses is the one fact a prompt must never state, and for the sharpest
# reason: an agent told it will be refused, that is not, reads the silence as sanction — and
# one told nothing will stop it, while GitHub refuses, learns that a 403 is a bug to work
# around. Both are worse than not knowing. The brief reads the key and says which it is.
forbid_key github_tokens '(GH_TOKEN|github_tokens|ola-workflow-has-no-base-token|(merge|review|base) token)' \
  'which GitHub token an agent holds'

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

# --- The coordinator spends no cache it need not -------------------------------------
# An agent idle for more than five minutes rewrites its whole context when it is resumed
# (about 130k tokens); a fresh one starts at about 6k. Each sentence is looked for in the
# part that carries it, as one line: where prose wraps is not what it says, and a file-wide
# grep stays green with the step rewritten.
coord=$ROOT/agents/coordinator.md
coord_part() { # coord_part <awk start regex> <awk stop regex> — that part of the prompt, as one line
  awk -v s="$1" -v e="$2" '$0 ~ s {on=1; print; next} on && $0 ~ e {exit} on' "$coord" | tr -s ' \n' '  '
}
resume=$(coord_part '^## Resume or start fresh' '^## ')
# shellcheck disable=SC2034  # read through ${!part} below
step3b=$(coord_part '^   \\*\\*3b\\. ' '^4\\. \\*\\*')
step6=$(coord_part '^6\\. \\*\\*Review' '^7\\. \\*\\*')
step8=$(coord_part '^8\\. \\*\\*Close' '^## ')
coord_all=$(tr -s ' \n' '  ' < "$coord")
for part in resume step3b step6 step8; do
  if [ -n "${!part}" ]; then
    ok "witness: coordinator $part is readable"
  else
    ko "witness: coordinator $part is not where the assertions below look"
  fi
done
case $resume in
  *'SendMessage'*'less than 5 min'*'fresh agent of the same role'*)
    ok "coordinator: resumes an agent only under 5 min, and otherwise starts a fresh one" ;;
  *) ko "coordinator: nothing limits SendMessage to an agent that reported less than 5 min ago" ;;
esac
case $resume in
  *'developer: the task'*'the pull request'*'one slot from the brief'*'findings word for word'*)
    ok "coordinator: a fresh developer gets the task, the pull request, a slot and the findings" ;;
  *) ko "coordinator: a fresh developer is not given what it needs to start cold" ;;
esac
case $resume in
  *'product-designer: the epic'*'paths'*'URL, and the findings'*)
    ok "coordinator: a fresh product-designer gets the epic, the paths, the URL and the findings" ;;
  *) ko "coordinator: a fresh product-designer is not given what it needs to start cold" ;;
esac
case $resume in
  *'pr-reviewer'*'the pull request'*'a reviewer slot'*'previous review'*)
    ok "coordinator: a fresh pr-reviewer gets the pull request and a slot, and finds its previous review" ;;
  *) ko "coordinator: a fresh pr-reviewer is not given what it needs to start cold" ;;
esac
case $resume in
  *'needs-decision'*'nothing pushed'*'whatever its age'*'only in its worktree'*)
    ok "coordinator: an agent that reported needs-decision with nothing pushed is resumed whatever its age" ;;
  *) ko "coordinator: a needs-decision answered after 5 min with nothing pushed sends a fresh agent to redo the work" ;;
esac
case $step6 in
  *'log points at the code, send it to a developer'*'Resume or start fresh'*'flaky'*)
    ok "coordinator: a failing check goes to a developer chosen by Resume or start fresh" ;;
  *) ko "coordinator: a failing check still names the original developer" ;;
esac
case $step6 in
  *'rerun turns green'*'only if'*'set `failure`'*'confirmation of the same SHA'*)
    ok "coordinator: the confirming review is owed only when the reviewer had set failure" ;;
  *) ko "coordinator: the confirming review is dispatched after every green rerun" ;;
esac
case $resume in
  *'130k'*'6k'*) ok "coordinator: the rule carries its reason, a cold resume against a fresh start" ;;
  *) ko "coordinator: the rule does not say what a cold resume costs" ;;
esac
case $resume in
  *'When in doubt, a fresh agent'*) ok "coordinator: in doubt, starts a fresh agent" ;;
  *) ko "coordinator: in doubt, nothing says to start a fresh agent" ;;
esac
case $resume in
  *'review findings'*'fresh developer'*)
    ok "coordinator: review findings go to a fresh developer, as a review outlasts 5 min" ;;
  *) ko "coordinator: review findings can go back to an agent whose cache has expired" ;;
esac
for part in step3b step6; do
  case ${!part} in
    *'Resume or start fresh'*) ok "coordinator: $part applies the resume rule" ;;
    *) ko "coordinator: $part sends to an agent without the resume rule" ;;
  esac
done
case $step6 in
  *'CI is still running'*'does not wait'*'neither do you'*'next agent report'*'tell the human'*'merge is waiting for CI'*)
    ok "coordinator: reads a running CI again at the next agent report, and tells the human the merge waits" ;;
  *) ko "coordinator: says nothing of what to do when the CI is still running at merge time" ;;
esac
case $step6 in
  *'rerun'*'green'*'confirmation'*'failure'*)
    ok "coordinator: a flaky check that turns green is followed by a confirming review" ;;
  *) ko "coordinator: a failure status left by a flaky check stays on the SHA and blocks the merge" ;;
esac
case $step8 in
  *'fresh session'*'forge'*'memory'*) ok "coordinator: offers a fresh session when an epic closes" ;;
  *) ko "coordinator: does not offer a fresh session when an epic closes" ;;
esac
# Suggestions: a suggestion costs a whole cycle (developer, review, CI) when it is fixed on
# its own, so "fix now" is tied to a cycle already owed, and the rest are noted, not opened as
# tasks. The bullet is read on its own: the same words elsewhere in step 6 prove nothing.
sugg=$(printf '%s' "$step6" | sed 's/.*\*\*Suggestions\*\*/**Suggestions**/; s/- \*\*A security review\*\*.*//')
case $sugg in
  '**Suggestions**'*) ok "witness: coordinator step 6 has a Suggestions bullet" ;;
  *) ko "witness: coordinator step 6 has no Suggestions bullet to read" ;;
esac
case $sugg in
  *'Fix now'*'only if a cycle is already owed'*'blocking finding'*'confirmed security finding'*'failing check'*'same dispatch'*)
    ok "coordinator: a suggestion is fixed now only when a cycle is already owed, and travels with it" ;;
  *) ko "coordinator: a suggestion can cost a cycle of its own" ;;
esac
case $sugg in
  *'Follow-up'*'otherwise'*'where the epic lives'*'integrated mode'*'comment'*'Follow-ups of #'*'discreet mode'*'epic.md'*'No task per suggestion'*)
    ok "coordinator: other suggestions are noted where the epic lives, with no task per suggestion" ;;
  *) ko "coordinator: nothing says where a suggestion triaged as a follow-up is noted" ;;
esac
case $sugg in
  *'Reject'*'reason'*'Publish the triage'*) ok "coordinator: a rejected suggestion carries a reason, and the triage is published" ;;
  *) ko "coordinator: a rejected suggestion can be dropped without a reason or a publication" ;;
esac
case $coord_all in
  *'keep as a follow-up task'*) ko "coordinator: still opens a follow-up task per suggestion" ;;
  *) ok "coordinator: opens no follow-up task per suggestion" ;;
esac
case $step8 in
  *'epic closes'*'follow-ups'*'noted'*'one task'*'all of them'*'files'*'proves'*'report'*)
    ok "coordinator: closing an epic builds one task from its noted follow-ups, and reports it" ;;
  *) ko "coordinator: closing an epic does not group its follow-ups into one task" ;;
esac
case $step8 in
  *'without an epic'*'single task'*'one task when its pull request is merged'*)
    ok "coordinator: a request without an epic groups its follow-ups when its pull request merges" ;;
  *) ko "coordinator: a single-task request leaves its follow-ups ungrouped" ;;
esac
case $coord_all in
  *'The human rules a security finding a false positive'*'open a task that adds it'*)
    ok "coordinator: the security precedent task is kept, it is no suggestion" ;;
  *) ko "coordinator: the security precedent task is gone" ;;
esac

case $coord_all in
  *'only the Report block'*) ok "coordinator: asks an agent for its Report block only" ;;
  *) ko "coordinator: asks for a detailed account that stays in its context" ;;
esac

# --- The coordinator takes its state back from the forge ------------------------------
# A summary or a /clear erases what the coordinator held; the forge is the memory, so the
# coordinator reads it again, one line per item and bounded. The section is read between
# its heading and the next, and the commands out of it, so a mention elsewhere in the file
# cannot satisfy these.
resume_state=$(coord_part '^## Resume the state' '^## ')
resume_state_raw=$(awk '/^## Resume the state/{on=1; next} on && /^## /{exit} on' "$coord")
step4=$(coord_part '^4\\. \\*\\*Design and split' '^5\\. \\*\\*')
for part in resume_state step4; do
  if [ -n "${!part}" ]; then
    ok "witness: coordinator $part is readable"
  else
    ko "witness: coordinator $part is not where the assertions below look"
  fi
done
case $coord_all in
  *'ola-workflow-brief'*'## Resume the state'*'## The team'*)
    ok "coordinator: resumes the state right after the brief, before the team" ;;
  *) ko "coordinator: the state is not resumed between the brief and the team" ;;
esac
case $resume_state in
  *'At startup'*'/clear'*'summarised'*'forge'*)
    ok "coordinator: reads the forge again at startup, after /clear and after a summary" ;;
  *) ko "coordinator: does not say to read the forge again at startup, after /clear and a summary" ;;
esac
case $resume_state in
  *'open epics'*'open tasks'*'epic'*'open pull request'*'head SHA'*'RFR'*'task it closes'*)
    ok "coordinator: reads open epics, tasks with their epic, and pull requests with head SHA, RFR and task" ;;
  *) ko "coordinator: the state it resumes lacks epics, tasks, or pull requests with head SHA and RFR" ;;
esac
case $resume_state in
  *'epic.md'*'tasks/'*'gh pr list'*'only reads'*)
    ok "coordinator: in discreet mode, reads the memory directory and the open pull requests" ;;
  *) ko "coordinator: says nothing of resuming the state in discreet mode" ;;
esac
resume_cmds=$(printf '%s\n' "$resume_state_raw" | grep -E '^ +gh ' || true)
case $(printf '%s\n' "$resume_cmds" | grep -c 'gh ') in
  3) ok "coordinator: resumes the state with three commands" ;;
  *) ko "coordinator: the state is not three commands: epics, tasks, pull requests" ;;
esac
for sub in 'issue list --label epic' 'issue list --label task' 'pr list'; do
  line=$(printf '%s\n' "$resume_cmds" | grep -F "gh $sub" || true)
  case $line in
    *'--jq'*) ok "coordinator: '$sub' prints one line per item, through --jq" ;;
    *) ko "coordinator: '$sub' is not reduced to one line per item by --jq" ;;
  esac
done
case $resume_cmds in
  *body*|*comments*) ko "coordinator: the state it resumes reads a body or comments, not one line per item" ;;
  *) ok "coordinator: the state it resumes reads no body and no comments" ;;
esac
case $resume_cmds in
  *'--limit'*'parent'*'headRefOid'*'closingIssuesReferences'*)
    ok "coordinator: bounds the task list, and asks the parent, head SHA and closed tasks" ;;
  *) ko "coordinator: the commands lack --limit, parent, headRefOid or closingIssuesReferences" ;;
esac
case $step4 in
  *'sub-issue of the epic'*'--parent <epic>'*) ok "coordinator: step 4 creates each task as a sub-issue of its epic" ;;
  *) ko "coordinator: step 4 does not create tasks with --parent, so the task list has no epic to show" ;;
esac

# --- The shape of a pull request description ------------------------------------------
# The brief states it once, the developer writes it and the pr-reviewer judges it. An agent
# that restates the shape is the second copy this file exists to prevent, so the markup of
# the folded block is not written in any agent file. Not a schema key, hence `forbid`.
forbid '<details>|<summary>' 'the folded block of a description'
# The step is read between its number and the next section, so that a sentence elsewhere in
# the file cannot satisfy it.
dev_step5=$(awk '/^5\. /{on=1} /^## /{on=0} on' "$ROOT/agents/developer.md")
case $dev_step5 in
  *'description'*'brief states'*) ok "developer: step 5 opens the request with the description the brief states" ;;
  *) ko "developer: step 5 does not prescribe the description of the brief" ;;
esac
review_checklist=$(awk '/^## Checklist/{on=1} on' "$ROOT/agents/pr-reviewer.md")
case $review_checklist in
  *'- **Description**:'*) ok "pr-reviewer: the checklist has a Description point" ;;
  *) ko "pr-reviewer: the checklist does not judge the description" ;;
esac
desc_point=$(printf '%s\n' "$review_checklist" | awk '/^- \*\*Description\*\*/{on=1; print; next} on && /^- /{exit} on')
case $desc_point in
  *'suggestion'*) ok "pr-reviewer: a description that runs long is a suggestion" ;;
  *) ko "pr-reviewer: nothing says that a long description is only a suggestion" ;;
esac

# --- Captures, in the roles' steps -----------------------------------------------------
# The roles say when to capture and how to judge, and cite the brief for the rest: neither
# a script's address on the branch nor a preview value is theirs to write.
forbid 'pr-assets/' 'the address of a capture on pr-assets'
step_of() { awk -v n="$2" '$0 ~ "^" n "\\. "{on=1; next} /^[0-9]+\. |^## /{on=0} on' "$1"; }
dev_step2=$(step_of "$ROOT/agents/developer.md" 2 | tr '\n' ' ')
case $dev_step2 in
  *'existing screen'*'"before"'*'before any change'*) ok "developer: step 2 captures \"before\" before any change, for an existing screen" ;;
  *) ko "developer: step 2 does not capture \"before\" before any change" ;;
esac
dev_step4=$(step_of "$ROOT/agents/developer.md" 4 | tr '\n' ' ')
case $dev_step4 in
  *'"after"'*'Read'*'before'*'pushing'*) ok "developer: step 4 captures \"after\" and looks at each PNG before pushing it" ;;
  *) ko "developer: step 4 does not make the developer look at each capture before pushing it" ;;
esac
case $dev_step4 in
  *'captures are expected'*'what a user sees'*'"after"'*) ok "developer: step 4 captures \"after\" only for a change a user sees" ;;
  *) ko "developer: step 4 captures \"after\" whether or not the change is visible to a user" ;;
esac
case $(step_of "$ROOT/agents/developer.md" 5 | tr '\n' ' ') in
  *'captures'*'number'*'description'*) ok "developer: step 5 pushes the captures under the request's number, into the description" ;;
  *) ko "developer: step 5 does not push the captures under the number of the request" ;;
esac
# Squeezed: the sentence wraps in the role, and a line break is a run of spaces once joined.
case $(step_of "$ROOT/agents/architect.md" 3 | tr -s '\n ' ' ') in
  *'captures are expected'*'screens'*'states'*'capture'*) ok "architect: step 3 cites the brief's \"captures are expected\" and names the screens and states to capture" ;;
  *) ko "architect: step 3 does not cite the brief's \"captures are expected\" with the screens and states to capture" ;;
esac
case $(printf '%s\n' "$review_checklist" | awk '/^- \*\*Description\*\*/{on=1; print; next} on && /^- /{exit} on' | tr '\n' ' ') in
  *'captures are expected'*'blocking'*) ok "pr-reviewer: a missing capture is blocking when the brief expects captures" ;;
  *) ko "pr-reviewer: the Description point does not make a missing capture blocking" ;;
esac
case $(cat "$ROOT/skills/workflow-init/SKILL.md") in
  *'`preview`'*'ask'*) ok "workflow-init: preview is asked for, not detected" ;;
  *) ko "workflow-init: nothing says preview is asked for" ;;
esac

# --- workflow-init writes the session settings, in integrated mode only ---------------
# The coordinator's context is reread on every call, and the session only summarises itself
# near the end of a 1M window. `autoCompactWindow` moves that to 250k; it lives in the
# project's `.claude/settings.json`, next to `agent`, so workflow-init has to write it.
init_skill=$(tr -s '\n ' ' ' < "$ROOT/skills/workflow-init/SKILL.md")
# The integrated passage: from its marker to the next numbered step.
passage=$(awk '/^ *\*\*The session settings/{on=1} on && /^[0-9]+\. /{exit} on' "$ROOT/skills/workflow-init/SKILL.md" | tr -s '\n ' ' ')
case $passage in
  *'`"agent": "ola-workflow:coordinator"`'*) ok "workflow-init: the integrated passage writes the coordinator as the agent" ;;
  *) ko "workflow-init: the integrated passage does not write \"agent\": \"ola-workflow:coordinator\"" ;;
esac
case $passage in
  *'`"autoCompactWindow": 250000`'*) ok "workflow-init: the integrated passage writes the auto-compact window at 250000" ;;
  *) ko "workflow-init: the integrated passage does not write \"autoCompactWindow\": 250000" ;;
esac
case $passage in
  *'read it and keep its other keys'*) ok "workflow-init: the integrated passage keeps the other keys of an existing file" ;;
  *) ko "workflow-init: the integrated passage does not say it keeps the other keys" ;;
esac
case $passage in
  *'`agent` is already there with another value'*'ask the human before replacing'*) ok "workflow-init: a different existing agent is asked about before it is replaced" ;;
  *) ko "workflow-init: nothing says a different existing agent is asked about before it is replaced" ;;
esac
case $passage in
  *'`autoCompactWindow` is already there with another value'*'ask the human'*) ok "workflow-init: a different existing auto-compact window is shown and asked about" ;;
  *) ko "workflow-init: nothing says a different existing auto-compact window is asked about" ;;
esac
case $passage in
  *'keeps another `agent`'*'`autoCompactWindow` is still written'*) ok "workflow-init: the auto-compact window is still written when the human keeps another agent" ;;
  *) ko "workflow-init: nothing says the auto-compact window is still written when the human keeps another agent" ;;
esac
discreet_says() {
  case $1 in
    *'In `discreet` mode this setting is not written in the repository'*'`.claude/settings.local.json`'*) return 0 ;;
    *) return 1 ;;
  esac
}
if discreet_says "$init_skill"; then
  ok "workflow-init: in discreet mode the setting is not written in the repository"
else
  ko "workflow-init: nothing says the setting is not written in the repository in discreet mode"
fi
# Witness: the matcher must refuse the opposite sentence, or the check above proves nothing.
if discreet_says 'In `discreet` mode this setting is written in the repository, in `.claude/settings.local.json`'; then
  ko "workflow-init: the discreet matcher accepts the opposite sentence"
else
  ok "workflow-init: the discreet matcher refuses the opposite sentence"
fi
case $init_skill in
  *'`.claude/settings.local.json`'*'by hand'*'check-ignore'*) ok "workflow-init: a settings.local.json made by hand is checked for being git-ignored" ;;
  *) ko "workflow-init: nothing says to check that a hand-made settings.local.json is git-ignored" ;;
esac
step7=$(awk '/^7\. \*\*Report/{on=1} on && /^## /{exit} on' "$ROOT/skills/workflow-init/SKILL.md" | tr -s '\n ' ' ')
case $step7 in
  *'three things'*) ko "workflow-init: step 7 still says it names three things, and lists more" ;;
  *'settings file'*) ok "workflow-init: step 7 does not count what it lists" ;;
  *) ko "workflow-init: step 7 does not name the settings file" ;;
esac
readme_first=$(awk '/^### Writing the first one/{on=1; next} on && /^### /{exit} on' "$ROOT/docs/configuration.md" | tr -s '\n ' ' ')
case $readme_first in
  *'.claude/settings.json'*'autoCompactWindow'*) ok "docs/configuration.md: \"Writing the first one\" says the skill also writes the session settings" ;;
  *) ko "docs/configuration.md: \"Writing the first one\" describes a skill that writes only the profile" ;;
esac
case $init_skill in
  *'settings file too'*'commit'*) ok "workflow-init: the report says the settings file is the human's to commit" ;;
  *) ko "workflow-init: the report does not say the settings file is the human's to commit" ;;
esac
if jq -e '.agent == "ola-workflow:coordinator" and .autoCompactWindow == 250000' "$ROOT/.claude/settings.json" >/dev/null; then
  ok "this repository's settings.json sets the coordinator and the 250000 auto-compact window"
else
  ko "this repository's settings.json lacks the coordinator or the 250000 auto-compact window"
fi

# --- Dispatch names are namespaced ----------------------------------------------------
# subagent_type is an exact match: a bare name does not resolve to a plugin agent, and the
# spike in docs/agent-identity.md is where that was measured. A coordinator that writes `developer`
# fails at dispatch time, in front of the human.
coord=$ROOT/agents/coordinator.md
if [ -s "$coord" ]; then
  for role in coordinator product-designer architect developer pr-reviewer security-reviewer; do
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
# A key is read where `read_key` or `$(get` is followed by its name, wherever on the line the
# call stands: `cond && read_key a.b` and `if read_key a.b` count, a comment does not. The
# definition `read_key() {` and the usage comment `# read_key <dotted.key>` name no key.
KEY_RE='(?:\$\(get|\bread_key)\s+"?([a-z_]+)'
keys_of() { grep -v '^[[:space:]]*#' | perl -nle 'BEGIN { $re = shift } print $1 while /$re/g' "$KEY_RE" | sort -u; }
found=$(printf '%s\n' 'cond && read_key aa.b' 'if read_key "cc.$x"; then' 'v=$(get dd)' \
  'read_key() { # read_key <dotted.key> [join] → ee' '# read_key ff' | keys_of | tr '\n' ' ')
if [ "$found" = 'aa cc dd ' ]; then
  ok "the key reader finds a call anywhere on a line, and not a definition or a comment"
else
  ko "the key reader found '$found' where aa cc dd was expected"
fi
brief_keys=$(keys_of <"$BRIEF")
# The witness: a pattern that finds nothing proves no key is declared, and passes.
n_keys=$(printf '%s\n' "$brief_keys" | grep -c .)
if [ "$n_keys" -ge 11 ]; then
  ok "the brief reads at least 11 schema keys ($n_keys)"
else
  ko "the brief reads fewer than 11 keys: '$brief_keys'"
fi
for key in $brief_keys; do
  if jq -e --arg k "$key" '.properties | has($k)' \
      "$ROOT/schema/profile.schema.json" >/dev/null 2>&1; then
    ok "the brief reads '$key', which the schema declares"
  else
    ko "the brief reads '$key', which the schema does not declare"
  fi
done

# --- What stops an agent is said by the brief, and only by the brief -------------------
# Whether GitHub refuses a merge or a review status depends on one profile key,
# github_tokens, and the brief is the one reader of the profile. So the brief says which it
# is, for both values, and nothing else shipped may claim either way — the `forbid_key
# github_tokens` prohibition above covers the prompts. An agent told it will be refused,
# that is not, reads the silence as sanction; one told nothing will stop it, while GitHub
# refuses, learns to work around a 403.
ola_scratch agents
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT
export HOME=$WORK/home
mkdir -p "$HOME"

# --- docs_pages, on a tree built for it ------------------------------------------------
dfx=$WORK/docs-pages
mkdir -p "$dfx/docs/decisions" "$dfx/docs/design/x" "$dfx/.claude/worktrees/w/docs"
for f in docs/top.md docs/decisions/README.md docs/security-precedents.md docs/design/x/README.md \
  docs/note.txt .claude/worktrees/w/docs/other.md README.md; do
  echo x >"$dfx/$f"
done
got=$(docs_pages "$dfx" | sed "s#^$dfx/##" | tr '\n' ' ')
if [ "$got" = "docs/decisions/README.md docs/top.md " ]; then
  ok "docs_pages finds a page at the top of docs/ and one in a subfolder, and skips security-precedents.md, docs/design/, non-pages and worktrees"
else
  ko "docs_pages answered '$got' on a tree holding two pages and five things that are not"
fi
# Status and stderr as well as stdout: without the `[ -d ]` guard `find` complains and fails,
# and an empty stdout alone would call that a pass.
absent=$(docs_pages "$WORK/absent" 2>&1)
absent_rc=$?
if [ -z "$absent" ] && [ "$absent_rc" = 0 ]; then
  ok "docs_pages answers nothing, without failing, when there is no docs/"
else
  ko "docs_pages answered '$absent' with status $absent_rc where there is no docs/"
fi
# The two lists that carry the pages to the scans: dropping docs_pages from either left the
# suite green, because today there is no page to miss.
for list in prompt_files claimant_files; do
  if "$list" "$dfx" | grep -qxF "$dfx/docs/decisions/README.md" &&
    "$list" "$dfx" | grep -qxF "$dfx/docs/top.md" &&
    ! "$list" "$dfx" | grep -qF "security-precedents.md"; then
    ok "$list includes the pages under docs/"
  else
    ko "$list does not include the pages under docs/, or includes one it should skip"
  fi
done
if [ "$(page_label "$dfx" "$dfx/docs/decisions/README.md")" = docs/decisions/README.md ] &&
  [ "$(page_label "$dfx" "$dfx/README.md")" = README.md ]; then
  ok "a page under docs/ keeps its path as its label, so it is not taken for the README"
else
  ko "docs/decisions/README.md and README.md are labelled alike"
fi

# --- The table of models and efforts, against the two maps -----------------------------
# Nothing above compared the models table to anything: EXPECTED_MODEL and EXPECTED_EFFORT
# are compared to the frontmatter, and the table docs/models.md prints could say anything. It is
# compared to the same two maps, in both directions. `*(none)*` is the table's way of
# writing `-`. The table lives in docs/models.md: that is the variable below.
MODELS_PAGE=$ROOT/docs/models.md

# models_problems <page> → one line per disagreement; `no-page` / `no-table` when there is
# nothing to compare, which is a failure and not a pass.
models_problems() {
  local page=$1 rows row agent model effort pair key want
  [ -f "$page" ] || { echo "no-page"; return; }
  rows=$(awk '
    !t && /^\| agent \|/ { t = 1; next }
    t && /^\|/ { print; next }
    t { exit }
  ' "$page" | sed '1d')
  [ -n "$rows" ] || { echo "no-table"; return; }
  local seen=" "
  while IFS= read -r row; do
    agent=$(printf '%s' "$row" | awk -F'|' '{ gsub(/[` ]/, "", $2); print $2 }')
    model=$(printf '%s' "$row" | awk -F'|' '{ gsub(/[` ]/, "", $3); print $3 }')
    effort=$(printf '%s' "$row" | awk -F'|' '{ gsub(/[` ]/, "", $4); print $4 }')
    [ "$model" = '*(none)*' ] && model=-
    [ "$effort" = '*(none)*' ] && effort=-
    seen="$seen$agent "
    for key in model effort; do
      case $key in model) want=$EXPECTED_MODEL ;; effort) want=$EXPECTED_EFFORT ;; esac
      pair=
      for p in $want; do case $p in "$agent="*) pair=${p#*=} ;; esac; done
      if [ -z "$pair" ]; then
        echo "the table has a row for $agent, which the suite's $key map does not name"
      else
        case $key in model) got=$model ;; effort) got=$effort ;; esac
        [ "$got" = "$pair" ] || echo "$agent: the table says $key '$got', the suite declares '$pair'"
      fi
    done
  done <<EOF
$rows
EOF
  for p in $EXPECTED_MODEL; do
    case $seen in *" ${p%%=*} "*) ;; *) echo "the suite declares ${p%%=*}, which the table has no row for" ;; esac
  done
}

mt=$WORK/models-table
mkdir -p "$mt"
cat >"$mt/page.md" <<'EOF'
| agent | `model` | `effort` | what it buys |
|---|---|---|---|
| coordinator | *(none)* | *(none)* | x |
| product-designer | `sonnet` | *(none)* | x |
| design-reviewer | `sonnet` | *(none)* | x |
| architect | `opus` | *(none)* | x |
| developer | `sonnet` | `high` | x |
| pr-reviewer | `opus` | `high` | x |
| security-reviewer | `opus` | `high` | x |
| probe | `haiku` | `low` | x |

Text after.
EOF
if [ -z "$(models_problems "$mt/page.md")" ]; then
  ok "models table: a table that says what the maps say, *(none)* included, has no disagreement"
else
  ko "models table: the good fixture is refused: $(models_problems "$mt/page.md" | tr '\n' '|')"
fi
sed 's/| architect | `opus`/| architect | `sonnet`/' "$mt/page.md" >"$mt/model.md"
case $(models_problems "$mt/model.md") in
  *"architect: the table says model 'sonnet'"*) ok "models table: a model changed in the table is reported" ;;
  *) ko "models table: a model changed in the table is not reported" ;;
esac
sed 's/| developer | `sonnet` | `high`/| developer | `sonnet` | *(none)*/' "$mt/page.md" >"$mt/effort.md"
case $(models_problems "$mt/effort.md") in
  *"developer: the table says effort '-'"*) ok "models table: an effort dropped in the table is reported" ;;
  *) ko "models table: an effort dropped in the table is not reported" ;;
esac
grep -v '^| probe ' "$mt/page.md" >"$mt/short.md"
case $(models_problems "$mt/short.md") in
  *"declares probe, which the table has no row for"*) ok "models table: an agent the suite declares and the table lacks is reported" ;;
  *) ko "models table: a missing row is not reported" ;;
esac
sed 's/^| probe .*/&\n| ghost | `opus` | `high` | x |/' "$mt/page.md" >"$mt/ghost.md"
case $(models_problems "$mt/ghost.md") in
  *"row for ghost"*) ok "models table: a row for an agent the suite does not name is reported" ;;
  *) ko "models table: a row for an unknown agent is not reported" ;;
esac
printf 'no table\n' >"$mt/none.md"
if [ "$(models_problems "$mt/none.md")" = no-table ]; then ok "models table: a page without the table is a failure"; else ko "models table: a page without the table is not reported"; fi
if [ "$(models_problems "$mt/absent.md")" = no-page ]; then ok "models table: an absent page is a failure"; else ko "models table: an absent page is not reported"; fi

problems=$(models_problems "$MODELS_PAGE")
case $problems in
  "") ok "the table of ${MODELS_PAGE#"$ROOT"/} says what each agent runs on, as the suite declares it" ;;
  no-page) ko "${MODELS_PAGE#"$ROOT"/} does not exist, so nothing says what each agent runs on" ;;
  no-table) ko "${MODELS_PAGE#"$ROOT"/} has no table whose header begins with '| agent |'" ;;
  *) while IFS= read -r p; do ko "models table: $p"; done <<EOF
$problems
EOF
  ;;
esac

for want in keychain off; do
  probe=$WORK/stops-$want
  mkdir -p "$probe/.claude"
  git -C "$probe" -c init.defaultBranch=main init -q 2>/dev/null
  printf '{"mode":"integrated","github_tokens":"%s"}\n' "$want" >"$probe/.claude/workflow.json"
  # Through a file, not a pipe: `… | grep -q` reported a miss on output that holds the
  # match, and the file lets the failure show what was printed.
  "$BRIEF" "$probe" >"$WORK/out-$want" 2>"$WORK/err-$want" || true
  # The content, not the heading: both arms print the heading.
  case $want in
    keychain) expect='GitHub refuses' ;;
    off)      expect='^Nothing\.' ;;
  esac
  if grep -q '## What stops you' "$WORK/out-$want" && grep -qE "$expect" "$WORK/out-$want"; then
    ok "the brief says what stops an agent when github_tokens is $want, and says the right thing"
  else
    ko "the brief says nothing right about what stops an agent when github_tokens is $want: $(head -c 100 "$WORK/err-$want" "$WORK/out-$want" | tr '\n' ' ')"
  fi
done

# The base token cannot read check runs, so `gh pr checks` fails for every role (measured
# on GitHub, 2026-10-19). An agent not told so reads that failure as a refusal of its role,
# or as checks that are not green. The brief gives what does work, and only where the tokens
# are on: with them off, `gh pr checks` works and the detour is noise.
if grep -qF 'actions/runs?head_sha=<SHA>' "$WORK/out-keychain" && grep -qF 'gh pr checks' "$WORK/out-keychain"; then
  ok "with the tokens on, the brief says gh pr checks fails and how to read the checks instead"
else
  ko "with the tokens on, the brief does not say how to read the checks without the Checks API"
fi
if grep -qE 'head_sha|gh pr checks' "$WORK/out-off"; then
  ko "with the tokens off, the brief still steers away from gh pr checks"
else
  ok "with the tokens off, the brief leaves gh pr checks alone"
fi

# The guard that read command lines is gone, so nothing shipped may still promise it. A net
# over prose, not a proof: it catches the phrasings this project actually wrote.
claims_in() { # claims_in <root> → the label of each claimant that still promises it, blank-terminated
  local files=() page
  while IFS= read -r page; do files+=("$page"); done < <(claimant_files "$1")
  while IFS= read -r page; do
    printf '%s ' "$(page_label "$1" "$page")"
  done < <(grep -lE 'guard (refuses|blocks|will ask|asks|prevents|reads)|tokeniz' "${files[@]}" 2>/dev/null)
}
claims=$(claims_in "$ROOT")
if [ -z "$claims" ]; then
  ok "nothing shipped promises the command-line guard that was removed"
else
  ko "these still promise the removed command-line guard: $claims"
fi
# The message names the page by its path under docs/, as the scan's own labels do.
echo "the guard refuses" >"$dfx/docs/decisions/README.md"
if [ "$(claims_in "$dfx")" = "docs/decisions/README.md " ]; then
  ok "a page under docs/ that still promises the guard is named by its path, not as README.md"
else
  ko "a promise in docs/decisions/README.md is named '$(claims_in "$dfx")'"
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

# Keeping context small: rules every role needs, written once here rather than in seven
# prompts. Both modes print the section, with each of its four rules.
for pair in "integrated:$integrated" "discreet:$discreet"; do
  mode=${pair%%:*}
  text=${pair#*:}
  case $text in
    *'## Keeping context small'*) ok "$mode: the brief has the context-economy section" ;;
    *) ko "$mode: the brief has no '## Keeping context small' section" ;;
  esac
  for rule in 'No busy-waiting on CI' 'Read a file by line range' \
              'Silence or bound noisy commands' 'Short reports'; do
    case $text in
      *"$rule"*) ok "$mode: the context rule '$rule' is in the brief" ;;
      *) ko "$mode: the context rule '$rule' is missing from the brief" ;;
    esac
  done
done

# The description's shape, stated by the brief for both modes. Read in the section it lives in
# (from its heading to the next), so another section cannot satisfy it.
reviewable_of() { printf '%s\n' "$1" | awk '/^## A reviewable pull request/{on=1; next} /^## /{on=0} on'; }
for pair in "integrated:$integrated" "discreet:$discreet"; do
  mode=${pair%%:*}
  section=$(reviewable_of "${pair#*:}")
  case $section in
    *'1 to 3 sentences'*) ok "$mode: the description is 1 to 3 sentences" ;;
    *) ko "$mode: the brief does not bound the description" ;;
  esac
  case $section in
    *'a line saying what was checked'*) ok "$mode: the description has a line saying what was checked" ;;
    *) ko "$mode: the brief asks for no line saying what was checked" ;;
  esac
  # A label in backticks reads as the literal text to write, whatever the language of the
  # artifacts: it is named in words and left to the language the brief prints.
  case $section in
    *'`Checked`'*) ko "$mode: the Checked label is literal, though labels follow the artifacts language" ;;
    *'its label in the language of the artifacts'*) ok "$mode: the label of the checked line follows the artifacts language" ;;
    *) ko "$mode: the brief does not say which language the checked label is in" ;;
  esac
  case $section in
    *'<details><summary>'*) ok "$mode: the rest of the description goes in a folded block" ;;
    *) ko "$mode: the brief names no folded block" ;;
  esac
  case $section in
    *'never a blocking finding'*) ok "$mode: a long description is never blocking" ;;
    *) ko "$mode: the brief does not say a long description is not blocking" ;;
  esac
done
case $(reviewable_of "$integrated") in
  *'- `Closes #<task>`'*) ok "integrated: the description closes the task" ;;
  *) ko "integrated: the description does not say what it closes" ;;
esac
# Not every request closes a task — a release closes none, and a reviewer must not block it
# for the missing line — yet one made from a task must close it: both halves are stated.
case $(reviewable_of "$integrated" | tr '\n' ' ') in
  *'when the request closes a task'*'one made from a task closes it'*'closes none'*) ok "integrated: Closes is conditional, and a request made from a task closes it" ;;
  *) ko "integrated: the brief makes Closes unconditional, or lets a task go unclosed" ;;
esac
case $(reviewable_of "$discreet") in
  *'- `Closes #<task>`'*) ko "discreet: the description must close a task that is not on the forge" ;;
  *'only if the human named an issue'*) ok "discreet: the Closes line is conditional on an issue the human named" ;;
  *) ko "discreet: the brief says nothing of the Closes line" ;;
esac
# The headings follow language.artifacts: a profile that sets it is read, not assumed.
french=$WORK/french
mkdir -p "$french/.claude"
git -C "$french" -c init.defaultBranch=main init -q 2>/dev/null
printf '{"mode":"integrated","language":{"artifacts":"fr"}}\n' >"$french/.claude/workflow.json"
case $(reviewable_of "$("$BRIEF" "$french")") in
  *'language of the artifacts: fr.'*) ok "the description's headings are in the artifacts language of the profile" ;;
  *) ko "the description's headings ignore language.artifacts" ;;
esac

# --- Captures --------------------------------------------------------------------------
# The profile says how to start the app, the brief is the only reader of the profile, and
# the roles cite the brief. Read in the section it lives in, so another section cannot
# satisfy a presence, nor hide an absence.
captures_of() { printf '%s\n' "$1" | awk '/^## Captures/{on=1; next} /^## /{on=0} on'; }
PREVIEW='{"up":"make web-up PORT=300{slot}","url":"http://localhost:300{slot}/","down":"make web-down PORT=300{slot}"}'
brief_preview() { # brief_preview <mode> [preview json] → the brief of a project with a preview
  local mode=$1
  local preview=${2:-$PREVIEW}
  local repo=$WORK/preview-$mode-$RANDOM
  mkdir -p "$repo/.claude"
  git -C "$repo" -c init.defaultBranch=main init -q 2>/dev/null
  printf '{"mode":"%s","preview":%s}\n' "$mode" "$preview" >"$repo/.claude/workflow.json"
  "$BRIEF" "$repo"
}
with_preview=$(brief_preview integrated)
with_preview_discreet=$(brief_preview discreet)
for pair in "integrated:$with_preview" "discreet:$with_preview_discreet" "integrated:$integrated" "discreet:$discreet"; do
  case $(captures_of "${pair#*:}") in
    '') ko "${pair%%:*}: the brief has no '## Captures' section" ;;
    *) ok "${pair%%:*}: the brief has a '## Captures' section" ;;
  esac
done
for pair in "integrated:$with_preview" "discreet:$with_preview_discreet"; do
  mode=${pair%%:*}
  section=$(captures_of "${pair#*:}")
  for want in 'make web-up PORT=300{slot}' 'http://localhost:300{slot}/' 'make web-down PORT=300{slot}' \
              'ola-profile get preview.url --slot' 'ola-workflow-capture <url> <file.png>' \
              'ola-workflow-pr-assets <pr> <file.png>'; do
    case $section in
      *"$want"*) ok "$mode, with a preview: the Captures section holds '$want'" ;;
      *) ko "$mode, with a preview: the Captures section lacks '$want'" ;;
    esac
  done
  # The wording the roles cite: the pr-reviewer's blocking rule rests on it, so it is stated
  # rather than inferred from the description's shape.
  case $section in
    *'Captures are expected of a request that changes what a user sees, and only of one.'*)
      ok "$mode, with a preview: the Captures section says when captures are expected" ;;
    *) ko "$mode, with a preview: the Captures section does not say when captures are expected" ;;
  esac
  case $section in
    *'outside the worktree'*'never committed'*) ok "$mode, with a preview: captures stay outside the worktree and are never committed" ;;
    *) ko "$mode, with a preview: nothing says captures are kept out of the worktree and the commits" ;;
  esac
  case $section in
    *'whatever the result'*) ok "$mode, with a preview: down runs whatever the result" ;;
    *) ko "$mode, with a preview: nothing says to run down whatever the result" ;;
  esac
  case $section in
    *'readable by whoever can read the repository'*'development data'*) ok "$mode, with a preview: pr-assets is public to the repository's readers, so development data only" ;;
    *) ko "$mode, with a preview: nothing warns who reads pr-assets" ;;
  esac
  case $(reviewable_of "${pair#*:}" | tr '\n' ' ') in
    *'only if the request changes what a user sees'*'before'*'only when an existing screen changes'*)
      ok "$mode, with a preview: the description has a Captures block, only for a visible change" ;;
    *) ko "$mode, with a preview: the shape of the description has no Captures block" ;;
  esac
done
case $(captures_of "$with_preview_discreet" | tr '\n' ' ') in
  *'pushing `pr-assets`'*'the human confirms'*) ok "discreet, with a preview: pushing pr-assets waits for the human" ;;
  *) ko "discreet, with a preview: nothing says pushing pr-assets needs the human" ;;
esac
case $(captures_of "$with_preview" | tr '\n' ' ') in
  *'the human confirms'*) ko "integrated, with a preview: pushing pr-assets is made to wait for a human it does not need" ;;
  *) ok "integrated, with a preview: pushing pr-assets does not wait for the human" ;;
esac
# Without a preview: no capture is expected, no script is named, the description asks for none.
for pair in "integrated:$integrated" "discreet:$discreet" \
            "partial:$(brief_preview integrated '{"up":"make web-up","url":"http://localhost:3000/"}')"; do
  mode=${pair%%:*}
  text=${pair#*:}
  case $(captures_of "$text" | tr '\n' ' ') in
    *'No capture is expected'*'in one line'*) ok "$mode, without a preview: no capture is expected, and a visible change says so in one line" ;;
    *) ko "$mode, without a preview: the Captures section does not say that none is expected" ;;
  esac
  case $text in
    *ola-workflow-capture*|*ola-workflow-pr-assets*) ko "$mode, without a preview: the brief names a capture script" ;;
    *) ok "$mode, without a preview: the brief names no capture script" ;;
  esac
  case $(reviewable_of "$text") in
    *aptures*) ko "$mode, without a preview: the shape of the description asks for captures" ;;
    *) ok "$mode, without a preview: the shape of the description asks for no captures" ;;
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

# The RFR label: the human sees which pull requests they can merge. The coordinator adds it
# once the gate holds and removes it when it stops being true, in integrated mode only: the
# workflow leaves no trace in a discreet project.
case $integrated in
  *'gh pr edit <N> --add-label RFR'*) ok "integrated: the brief tells the coordinator to add RFR" ;;
  *) ko "integrated: the brief never says how to add the RFR label" ;;
esac
case $integrated in
  *'gh pr edit <N> --remove-label RFR'*) ok "integrated: the brief tells the coordinator to remove RFR" ;;
  *) ko "integrated: the brief never says how to remove the RFR label, so one stays on an old SHA" ;;
esac
# A pull request that returns to the human fails the gate on a sensitive path or pattern, and
# it is exactly one the human needs to see: the label ignores those two conditions.
case $integrated in
  *'the sensitive paths and patterns aside'*'only'*'decide who merges'*)
    ok "integrated: RFR goes on a pull request the human merges too" ;;
  *) ko "integrated: RFR reads as never on a sensitive-path pull request, the very ones the human merges" ;;
esac
case $integrated in
  *'gh label create RFR'*) ok "integrated: the brief says how to create the RFR label" ;;
  *) ko "integrated: the brief gives no command to create the RFR label" ;;
esac
case $discreet in
  *RFR*) ko "discreet: the brief mentions the RFR label, and the workflow leaves no trace there" ;;
  *) ok "discreet: the brief says nothing of the RFR label" ;;
esac
# One source, cited by all: step 7 points at the brief and does not repeat the commands.
step7=$(awk '/^7\. \*\*Merge\*\*/{on=1} on && /^8\. /{exit} on' "$ROOT/agents/coordinator.md" | tr -s ' \n' '  ')
case $step7 in
  *'The RFR label'*) ok "coordinator: step 7 cites the brief on the RFR label" ;;
  *) ko "coordinator: step 7 does not cite what the brief says about the RFR label" ;;
esac
case $step7 in
  *'--add-label'*|*'--remove-label'*) ko "coordinator: step 7 repeats the label commands the brief owns" ;;
  *) ok "coordinator: step 7 does not repeat the label commands" ;;
esac

# Design: where it is documented, where it is staged, and whether it may leave the machine.
# Publishing an artifact sends the page to claude.ai, so in discreet mode it waits for the
# human's yes — the brief says so, and says nothing about committing it to the repository.
case $integrated in
  *'## Design'*) ok "integrated: the brief has a Design section" ;;
  *) ko "integrated: the brief says nothing about design" ;;
esac
case $integrated in
  *'docs/design/<slug>/'*) ok "integrated: designs are documented under the default docs/design" ;;
  *) ko "integrated: the brief does not say where designs are documented" ;;
esac
case $discreet in
  *'## Design'*) ok "discreet: the brief has a Design section" ;;
  *) ko "discreet: the brief says nothing about design" ;;
esac
case $discreet in
  *docs/design*) ko "discreet: the brief sends designs into the repository" ;;
  *) ok "discreet: no design is documented in the repository" ;;
esac
case $discreet in
  *'runs/<slug>/design/'*) ok "discreet: designs are kept in the local memory" ;;
  *) ko "discreet: the brief does not say where designs are kept" ;;
esac
case $discreet in
  *'only after the human'*) ok "discreet: publishing an artifact waits for the human" ;;
  *) ko "discreet: nothing holds an artifact back until the human agrees" ;;
esac
case $integrated in
  *'only after the human'*) ko "integrated: the brief holds back a publish the mode allows" ;;
  *) ok "integrated: publishing visual work needs no extra confirmation" ;;
esac
# The default is said where it is used, not in the notice: a project with no interface
# would otherwise open every brief on a default it has no reason to set.
case $integrated in
  *'docs/design/<slug>/ (not in the profile — my default)'*) ok "integrated: the design directory is marked as my default" ;;
  *) ko "integrated: the default design directory is presented as the project's" ;;
esac
# The page and its README carry the designer's decisions and the review verdicts until a
# developer copies them: they are written somewhere a reboot does not wipe.
stage=$(printf '%s' "$integrated" | sed -n 's/^Written first in: *//p')
case $stage in
  "$HOME"/.claude/*) ok "integrated: the design is staged under the user's own directory" ;;
  *) ko "integrated: the design is staged at '${stage:-nowhere}', which may not survive" ;;
esac

# The profile's own directory wins over the default.
designed=$WORK/designed
mkdir -p "$designed/.claude"
git -C "$designed" -c init.defaultBranch=main init -q 2>/dev/null
git -C "$designed" remote add origin https://github.com/someone/designed.git 2>/dev/null
printf '{"mode":"integrated","context":{"design":"ui/specs"}}\n' >"$designed/.claude/workflow.json"
designed_brief=$("$BRIEF" "$designed")
case $designed_brief in
  *'ui/specs/<slug>/'*) ok "integrated: context.design names the design directory" ;;
  *) ko "integrated: context.design is ignored" ;;
esac
# A value the profile states is the project's, and must not be marked as mine: a note on
# every brief would teach an agent to discount it on the one brief where it is true.
case $designed_brief in
  *'(not in the profile — my default)'*) ko "integrated: a design directory the profile states is marked as my default" ;;
  *) ok "integrated: a design directory the profile states carries no default note" ;;
esac

# The link to the design in the description (#99). A request that realises a design carries
# the URL of its artifact, read in the design's README, or the path of its page when it was
# never published. Integrated mode only: in discreet mode the workflow leaves no trace in
# the project, and a link to an artifact would be one.
design_flat=$(reviewable_of "$integrated" | tr '\n' ' ')
case $design_flat in
  *'a Design line, only if the task points at a design'*) ok "integrated: the description has a Design line, only for a task that points at a design" ;;
  *) ko "integrated: the description has no conditional Design line" ;;
esac
case $design_flat in
  *'a Design line'*'artifact URL'*'README'*'path of its page'*'never published'*) ok "integrated: the Design line is the README's URL, or the page's path when never published" ;;
  *) ko "integrated: the Design line does not say where its URL comes from, nor what stands in when there is none" ;;
esac
# Placed after the summary sentences, before the Decision line.
case $design_flat in
  *'1 to 3 sentences'*'a Design line'*'Decision:'*) ok "integrated: the Design line comes after the summary and before the Decision" ;;
  *) ko "integrated: the Design line is not placed after the summary sentences" ;;
esac
case $(reviewable_of "$discreet") in
  *Design*) ko "discreet: the description asks for a Design line, a trace the mode does not leave" ;;
  *) ok "discreet: the description has no Design line" ;;
esac
# The developer is not made to look for the URL: the architect gives it with the page.
case $(step_of "$ROOT/agents/architect.md" 3 | tr '\n' ' ') in
  *'draws a screen'*'README'*'artifact URL'*) ok "architect: a task that draws a screen gets the artifact URL with the page and the README" ;;
  *) ko "architect: a task that draws a screen is not given the artifact URL" ;;
esac
# A missing Design line is a comfort the human asked for, never a reason to block: the
# reviewer's Description point says it is a suggestion.
design_review=$(printf '%s\n' "$review_checklist" | awk '/^- \*\*Description\*\*/{on=1; print; next} on && /^- /{exit} on' | tr '\n' ' ' | sed -n 's/.*\(Design line.*\)/\1/p')
case $design_review in
  *'is blocking'*) ko "pr-reviewer: the Design line is spoken of as blocking" ;;
  *'Design line'*'suggestion'*) ok "pr-reviewer: a missing Design line is a suggestion" ;;
  *) ko "pr-reviewer: the Description point does not make a missing Design line a suggestion" ;;
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

# Reviewer slots: a single value, as brief_for writes it, or a list, one reviewer per slot.
case $integrated in
  *'reviewers: 9'*) ok "the brief names a single reviewer slot" ;;
  *) ko "the brief does not name the single reviewer slot from the profile" ;;
esac
listed=$WORK/listed
mkdir -p "$listed/.claude"
git -C "$listed" -c init.defaultBranch=main init -q 2>/dev/null
git -C "$listed" remote add origin https://github.com/someone/listed.git 2>/dev/null
printf '{"mode":"integrated","slots":{"developers":[1,2],"reviewer":[8,9]}}\n' \
  >"$listed/.claude/workflow.json"
case $("$BRIEF" "$listed") in
  *'reviewers: 8 9'*) ok "the brief names every reviewer slot of a list" ;;
  *) ko "the brief does not name both reviewer slots of [8,9]" ;;
esac

# The security review: which paths get one is the profile's, and git matches them, so the
# brief hands over the command rather than the globs alone.
for mode in integrated discreet; do
  secured=$WORK/secured-$mode
  mkdir -p "$secured/.claude"
  git -C "$secured" -c init.defaultBranch=main init -q 2>/dev/null
  git -C "$secured" remote add origin "https://github.com/someone/secured-$mode.git" 2>/dev/null
  printf '{"mode":"%s","security":{"paths":["back/auth/**","Dockerfile*"]},%s}\n' "$mode" \
    '"context":{"security_precedents":"notes/precedents.md"}' >"$secured/.claude/workflow.json"
  "$BRIEF" "$secured" >"$WORK/secured-$mode.out" 2>&1
  if grep -q '^## Security review' "$WORK/secured-$mode.out" &&
     grep -qF "':(glob)back/auth/**' ':(glob)Dockerfile*'" "$WORK/secured-$mode.out"; then
    ok "$mode: the brief gives the command that matches the security paths"
  else
    ko "$mode: the brief does not give the command matching security.paths: $(head -c 200 "$WORK/secured-$mode.out" | tr '\n' ' ')"
  fi
  # Whether a fix owes a security review is a question about the fix, not the request.
  if grep -qF "diff <(git diff --no-color --no-ext-diff origin/main...<reviewed SHA> -- ':(glob)back/auth/**' ':(glob)Dockerfile*' | git patch-id --verbatim) <(git diff --no-color --no-ext-diff origin/main...<SHA> -- ':(glob)back/auth/**' ':(glob)Dockerfile*' | git patch-id --verbatim)" "$WORK/secured-$mode.out"; then
    ok "$mode: the brief gives the command for a fix since the last review"
  else
    ko "$mode: the brief matches the security paths only against the whole request"
  fi
  if grep -qE '^security_precedents: +notes/precedents\.md' "$WORK/secured-$mode.out"; then
    ok "$mode: the brief names the precedents document"
  else
    ko "$mode: the brief does not name context.security_precedents"
  fi
done
if grep -q 'security-reviews/<branch>/<sha>.md' "$WORK/secured-discreet.out"; then
  ok "discreet: the brief says where a security review is kept"
else
  ko "discreet: the brief does not say where a security review goes"
fi
for forbidden in 'gh pr comment' 'gh api'; do
  if grep -qF "$forbidden" "$WORK/secured-discreet.out"; then
    ko "discreet: the security section tells an agent how to run $forbidden"
  else
    ok "discreet: the security section gives no way to run $forbidden"
  fi
done

# The command for a fix, run for real. A catch-up brings main's files into the diff between
# two SHAs, and none of them is the pull request's: only what the PR changes against main may
# make a fix owe a new security review. Built on a real repository with a bare origin.
fixrepo=$WORK/fix-origin-work
gitq() { git -C "$fixrepo" -c user.email=t@e -c user.name=t "$@"; }
git init -q --bare -b main "$WORK/fix-origin.git" 2>/dev/null
git clone -q "$WORK/fix-origin.git" "$fixrepo" 2>/dev/null
mkdir -p "$fixrepo/back/auth" "$fixrepo/docs" "$fixrepo/.claude"
printf '{"mode":"integrated","base_branch":"main","security":{"paths":["back/auth/**"]}}\n' \
  >"$fixrepo/.claude/workflow.json"
seq 1 40 >"$fixrepo/back/auth/a"
echo b >"$fixrepo/back/auth/b"
seq 1 40 >"$fixrepo/back/auth/c"
echo doc >"$fixrepo/docs/d"
gitq checkout -q -b main 2>/dev/null
gitq add -A && gitq commit -q -m base && gitq push -q origin main 2>/dev/null
# The pull request changes the top of a and the middle of c; main then changes b, the bottom
# of a and inserts lines above the whole of c, which moves the PR's hunk in c; the PR
# catches up by a merge that conflicts with nothing.
gitq checkout -q -b pr
sed -i.bak '2s/.*/pr/' "$fixrepo/back/auth/a" && rm "$fixrepo/back/auth/a.bak"
sed -i.bak '20s/.*/pr/' "$fixrepo/back/auth/c" && rm "$fixrepo/back/auth/c.bak"
gitq commit -q -am "pr change"
reviewed=$(gitq rev-parse HEAD)
gitq checkout -q main
echo b2 >>"$fixrepo/back/auth/b"
sed -i.bak '39s/.*/main/' "$fixrepo/back/auth/a" && rm "$fixrepo/back/auth/a.bak"
seq 101 105 | cat - "$fixrepo/back/auth/c" >"$fixrepo/back/auth/c.new" && mv "$fixrepo/back/auth/c.new" "$fixrepo/back/auth/c"
gitq commit -q -am "main moves"
gitq push -q origin main 2>/dev/null
gitq checkout -q pr
gitq merge -q --no-edit main >/dev/null 2>&1
caught_up=$(gitq rev-parse HEAD)
fixcmd=$("$BRIEF" "$fixrepo" | awk '/^    diff </{sub(/^    /,""); print; exit}')
fix_run() { # fix_run <new SHA> — what the brief's command prints for a fix at that SHA
  local cmd=${fixcmd//<reviewed SHA>/$reviewed}
  cmd=${cmd//<SHA>/$1}
  (cd "$fixrepo" && bash -c "$cmd" 2>&1)
}
if [ -n "$fixcmd" ]; then
  ok "behaviour: the brief prints a comparison command to run"
else
  ko "behaviour: the brief prints no comparison command"
fi
if [ -z "$(fix_run "$caught_up")" ]; then
  ok "behaviour: a catch-up of main owes no new security review"
else
  ko "behaviour: a catch-up of main prints $(fix_run "$caught_up" | head -c 200)"
fi
sed -i.bak '10s/.*/fix/' "$fixrepo/back/auth/a" && rm "$fixrepo/back/auth/a.bak"
gitq commit -q -am "fix in a"
fix_a=$(gitq rev-parse HEAD)
if [ -n "$(fix_run "$fix_a")" ]; then
  ok "behaviour: a fix changing a security path owes a new security review"
else
  ko "behaviour: a fix changing back/auth/a prints nothing"
fi
gitq checkout -q -b outside "$caught_up"
echo more >>"$fixrepo/docs/d"
gitq commit -q -am "fix outside"
if [ -z "$(fix_run "$(gitq rev-parse HEAD)")" ]; then
  ok "behaviour: a fix outside the security paths owes nothing"
else
  ko "behaviour: a fix outside the security paths prints something"
fi
gitq checkout -q -b spaces "$caught_up"
sed -i.bak '2s/$/ /' "$fixrepo/back/auth/a" && rm "$fixrepo/back/auth/a.bak"
gitq commit -q -am "whitespace only"
if [ -n "$(fix_run "$(gitq rev-parse HEAD)")" ]; then
  ok "behaviour: a fix changing only whitespace in a security path owes a new security review"
else
  ko "behaviour: a whitespace-only fix prints nothing, so --verbatim is not doing its work"
fi
# A host's git config must not blind the comparison: with colour forced or an external diff
# tool, git diff writes nothing git patch-id can read, and two empty sides print nothing.
for setting in "color.diff always" "color.ui always" "diff.external true"; do
  # shellcheck disable=SC2086 # the setting is a name and a value
  gitq config $setting
  if [ -n "$(fix_run "$fix_a")" ]; then
    ok "behaviour: a fix changing a security path owes a review under $setting"
  else
    ko "behaviour: under $setting a fix changing back/auth/a prints nothing"
  fi
  gitq config --unset "${setting%% *}"
done
# The sentence around the command names the base branch of the project, not a fixed one.
basedir=$WORK/fix-base-develop
mkdir -p "$basedir/.claude"
git -C "$basedir" init -q 2>/dev/null
printf '{"mode":"integrated","base_branch":"develop","security":{"paths":["back/auth/**"]}}\n' \
  >"$basedir/.claude/workflow.json"
basetext=$("$BRIEF" "$basedir" | sed -n '/^A fix owes a new one/,/^$/p')
case $basetext in
  *main*) ko "behaviour: the fix paragraph says main on a project whose base branch is develop" ;;
  *'against develop'*'origin/develop'*) ok "behaviour: the fix paragraph names the project's base branch" ;;
  *) ko "behaviour: the fix paragraph does not name develop: $(printf '%s' "$basetext" | head -c 200)" ;;
esac
case $("$BRIEF" "$basedir") in
  *'identical change between two places'*) ok "behaviour: the brief states the limit of the comparison" ;;
  *) ko "behaviour: the brief does not state that moving an identical change goes unseen" ;;
esac
case $step6 in
  *'prints anything'*) ok "coordinator: a fix owes a security review when the comparison prints anything" ;;
  *) ko "coordinator: step 6 does not say a fix owes a security review when the comparison prints anything" ;;
esac
case $step6 in
  *'command for a fix, from the SHA last reviewed, prints a file'*) ko "coordinator: step 6 still reads the fix command as a diff between the two SHAs printing a file" ;;
  *) ok "coordinator: step 6 no longer reads the fix command as a file list between the two SHAs" ;;
esac

# The two conditions of a confirmation, run as the pr-reviewer writes them, on the repository
# above: a catch-up with no conflict, a fix on top of one, a catch-up that needed a conflict
# resolved. The commands are taken out of the prompt, so a rewording that breaks one fails here.
prr_cmd() { # prr_cmd <start of the command line> — that command as the prompt writes it
  awk -v s="         $1" 'index($0, s) == 1 { sub(/^         /, ""); print; exit }' "$ROOT/agents/pr-reviewer.md"
}
merge_cmd=$(prr_cmd 'git merge-tree --write-tree')
ident_cmd=$(prr_cmd 'diff <(git diff')
if [ -n "$merge_cmd" ] && [ -n "$ident_cmd" ]; then
  ok "behaviour: the pr-reviewer prompt gives both commands of a confirmation"
else
  ko "behaviour: the pr-reviewer prompt lacks a command of a confirmation (merge-tree: '$merge_cmd')"
fi
conf_run() { # conf_run <command> <reviewed SHA> <head> — runs it in the repository, prints its output and "exit N"
  local cmd=${1//<reviewed SHA>/$2}
  cmd=${cmd//<head>/$3}
  cmd=${cmd//<base>/main}
  (cd "$fixrepo" && bash -c "$cmd" 2>&1; echo "exit $?")
}
out=$(conf_run "$merge_cmd" "$reviewed" "$caught_up")
if [ "$out" = "exit 0" ]; then
  ok "behaviour: merging the base into the reviewed SHA of a plain catch-up conflicts with nothing"
else
  ko "behaviour: merge-tree on a plain catch-up says: $out"
fi
out=$(conf_run "$ident_cmd" "$reviewed" "$caught_up")
if [ "$out" = "exit 0" ]; then
  ok "behaviour: a catch-up leaves the request's change identical, nothing is printed"
else
  ko "behaviour: the comparison on a catch-up says: $(printf '%s' "$out" | head -c 200)"
fi
out=$(conf_run "$ident_cmd" "$reviewed" "$fix_a")
if [ "$out" != "exit 0" ]; then
  ok "behaviour: a fix on top of the catch-up is not a confirmation"
else
  ko "behaviour: the comparison prints nothing for a catch-up plus a fix"
fi
for setting in "color.diff always" "color.ui always" "diff.external true"; do
  # shellcheck disable=SC2086 # the setting is a name and a value
  gitq config $setting
  out_catch=$(conf_run "$ident_cmd" "$reviewed" "$caught_up")
  out_fix=$(conf_run "$ident_cmd" "$reviewed" "$fix_a")
  gitq config --unset "${setting%% *}"
  if [ "$out_catch" = "exit 0" ] && [ "$out_fix" != "exit 0" ]; then
    ok "behaviour: the confirmation comparison tells a catch-up from a fix under $setting"
  else
    ko "behaviour: under $setting the confirmation comparison says '$out_catch' for a catch-up and '$out_fix' for a fix"
  fi
done
# A catch-up that conflicts: the reviewed SHA changes the line main changed, the author
# resolves it by hand in the merge.
gitq checkout -q -b conflicting "$reviewed"
sed -i.bak '39s/.*/pr39/' "$fixrepo/back/auth/a" && rm "$fixrepo/back/auth/a.bak"
gitq commit -q -am "pr also changes line 39"
reviewed_conflict=$(gitq rev-parse HEAD)
gitq merge -q --no-edit main >/dev/null 2>&1
seq 1 40 | sed '2s/.*/pr/;39s/.*/resolved/' >"$fixrepo/back/auth/a"
gitq add -A && gitq commit -q -m "catch-up resolving a conflict"
resolved=$(gitq rev-parse HEAD)
out=$(conf_run "$merge_cmd" "$reviewed_conflict" "$resolved")
if [ "$out" = "exit 1" ]; then
  ok "behaviour: a catch-up that conflicts makes merge-tree exit 1, so it is not a confirmation"
else
  ko "behaviour: merge-tree on a catch-up with a conflict says: $out"
fi
case $step6 in
  *'lighter confirmation'*'the reviewer decides how'*) ok "coordinator: step 6 lets a review owed after a catch-up become a confirmation, the reviewer's call" ;;
  *) ko "coordinator: step 6 does not say a review owed after a catch-up may be a confirmation" ;;
esac
case $step7 in
  *'a new head SHA needs a new review'*'a confirmation'*) ok "coordinator: step 7 says a catch-up that leaves the change intact is a confirmation" ;;
  *) ko "coordinator: step 7 does not mention a confirmation for a new head SHA after a catch-up" ;;
esac
# No paths: said, so that a quiet result is not read as a clean one.
case $integrated in
  *'## Security review'*'not dispatched'*) ok "no security paths: the brief says the security-reviewer is not dispatched" ;;
  *) ko "no security paths: the brief is silent about the security review" ;;
esac
case $integrated in
  *':(glob)'*) ko "no security paths: the brief still gives a matching command" ;;
  *) ok "no security paths: the brief gives no matching command" ;;
esac

# A value the profile does not state is announced as a default before the rules, not
# presented as one of them. Unmarked, a reviewer enforces a budget nobody set.
minimal=$WORK/minimal
mkdir -p "$minimal/.claude"
git -C "$minimal" -c init.defaultBranch=master init -q 2>/dev/null
git -C "$minimal" remote add origin https://github.com/someone/minimal.git 2>/dev/null
printf '{"mode":"integrated"}\n' >"$minimal/.claude/workflow.json"
bare=$("$BRIEF" "$minimal")
# context.design is said where it is used, in the Design section, not in this notice.
case $bare in
  *'context.design →'*) ko "the defaults notice opens on a design directory nobody needs to set" ;;
  *) ok "the defaults notice leaves context.design to the Design section" ;;
esac
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
