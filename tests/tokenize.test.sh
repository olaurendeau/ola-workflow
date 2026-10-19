#!/usr/bin/env bash
# shellcheck disable=SC2016
#   Every `$` below is part of a command line the tokenizer must read, not a value this
#   file wants expanded: `$(echo gh)`, `${u:-gh}` and `$c` are the cases under test, and
#   expanding them here would test nothing.
# What the tokenizer says the shell will run, checked against what the shell actually runs.
#
# The cases are derived from bash's expansion pipeline rather than enumerated as evasions,
# one class per grammatical step — brace, tilde, parameter, command substitution,
# arithmetic, word splitting, pathname, quote removal — plus what the grammar allows in
# front of a command word (assignments, redirections, reserved words, function headers)
# and the builtins that run code the text does not contain. Enumerating evasions cannot
# terminate; the grammar can, and it is falsifiable: point at a step and ask.
#
# Each row is also measured, not argued: the shell half of this suite runs the line with a
# logging stub on the PATH, so a row that claims "the shell runs gh" is a row the shell
# agreed with.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/scratch.sh
. "$ROOT/scripts/scratch.sh"
TOKENIZE="$ROOT/hooks/lib/tokenize.pl"
failures=0
total=0

ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

command -v perl >/dev/null || { echo "needs perl" >&2; exit 2; }
command -v jq >/dev/null || { echo "needs jq" >&2; exit 2; }

ola_scratch tokenize
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT

# A stub that records which command actually ran, so a claim about the shell is measured.
mkdir -p "$WORK/stubs"
for c in gh git npm; do
  printf '#!/bin/sh\nprintf "%s\\n" >>"$TOKENIZE_LOG"\n' "$c" >"$WORK/stubs/$c"
  chmod +x "$WORK/stubs/$c"
done

commands_of() { printf '%s' "$1" | perl "$TOKENIZE" | jq -r '.command' | tr '\n' ' '; }
readable_of() { printf '%s' "$1" | perl "$TOKENIZE" | jq -r 'select(.command == $c) | .readable' --arg c "$2" | head -1; }

# sees <label> <command line> <expected command word>
# The tokenizer must name that command word, and the shell must agree it runs it.
sees() {
  local label=$1 line=$2 want=$3 got
  got=$(commands_of "$line")
  case " $got " in
    *" $want "*) ok "$label: names $want" ;;
    *) ko "$label: named '$got', not $want — in: $line" ;;
  esac
  TOKENIZE_LOG=$WORK/log; : >"$TOKENIZE_LOG"
  ( cd "$WORK" && TOKENIZE_LOG=$WORK/log PATH="$WORK/stubs:$PATH" bash -c "$line" >/dev/null 2>&1 )
  if grep -qx "$want" "$WORK/log" 2>/dev/null; then
    ok "$label: and the shell agrees it runs $want"
  else
    ko "$label: the shell ran '$(tr '\n' ' ' <"$WORK/log")', not $want — the row is wrong"
  fi
}

# runs_nothing <label> <command line>
# The mirror of `sees`, for a construct that runs no command at all. Three verdicts, because
# the interesting failures are different: the shell must run none of the stubs, the tokenizer
# must name none of them, and the line must not come out unreadable — the third is not a
# nicety, it is an ask on every call, and it is what `inzip=$((inzip+1))` cost before this
# section existed.
runs_nothing() {
  local label=$1 line=$2 got unreadable
  got=$(commands_of "$line")
  unreadable=$(printf '%s' "$line" | perl "$TOKENIZE" | jq -r 'select(.readable == false) | .raw' | tr '\n' ' ')
  TOKENIZE_LOG=$WORK/log; : >"$TOKENIZE_LOG"
  ( cd "$WORK" && TOKENIZE_LOG=$WORK/log PATH="$WORK/stubs:$PATH" bash -c "$line" >/dev/null 2>&1 )
  if [ -s "$WORK/log" ]; then
    ko "$label: the shell ran '$(tr '\n' ' ' <"$WORK/log")', so this row is wrong — in: $line"
  else
    ok "$label: the shell runs nothing"
  fi
  case " $got " in
    *" gh "*|*" git "*|*" npm "*) ko "$label: the tokenizer named '$got' on a line that runs nothing" ;;
    *) ok "$label: and the tokenizer names no command" ;;
  esac
  if [ -n "$unreadable" ]; then
    ko "$label: reported unreadable ($unreadable), which spends an ask per call"
  else
    ok "$label: and asks nothing"
  fi
}

# names <label> <command line> <expected command word>
# The tokenizer half only, for a line whose execution cannot be measured here. Every use
# must be backed by a measured row of the same grammatical class, asserted where it is used.
names() {
  local got
  got=$(commands_of "$2")
  case " $got " in
    *" $3 "*) ok "$1: names $3 (tokenizer only — see the note above)" ;;
    *) ko "$1: named '$got', not $3 — in: $2" ;;
  esac
}

# asks <label> <command line> <substring of the reason>
# What cannot be known without running it is declared, never guessed. Almost every row here
# is a command the shell does run, so silence would be a miss and a refusal a false
# positive: the caller is meant to ask. Two rows in the arithmetic section are the
# exception, and say so where they stand — there nothing runs, and the ask is the price of
# two shells disagreeing about the same text.
asks() {
  local label=$1 line=$2 why=$3 reasons
  reasons=$(printf '%s' "$line" | perl "$TOKENIZE" | jq -r 'select(.readable == false) | .reason' | tr '\n' '|')
  if [ -n "$reasons" ] && [ "${reasons#*"$why"}" != "$reasons" ]; then
    ok "$label: declared unreadable — $why"
  else
    ko "$label: reason was '$reasons', expected to mention '$why' — in: $line"
  fi
}

echo "--- quote removal: four spellings of one name, and two that hold no name at all"
sees 'backslash'      'g\h --version' gh
sees 'double quotes'  '"gh" --version' gh
sees 'single quotes'  "'gh' --version" gh
sees 'concatenated'   'g"h" --version' gh
sees 'ANSI-C'         "\$'gh' --version" gh
sees 'ANSI-C hex'     "\$'\\x67h' --version" gh
sees 'ANSI-C octal'   "\$'\\147\\150' --version" gh

echo "--- what the grammar allows in front of a command word"
sees 'assignment'     'FOO=1 gh --version' gh
sees 'redirection'    '2>/dev/null gh --version' gh
sees 'both'           'FOO=1 2>/dev/null gh --version' gh
sees 'negation'       '! gh --version' gh
sees 'subshell'       '(gh --version)' gh
sees 'group'          '{ gh --version; }' gh
sees 'function body'  'f() { gh --version; }; f' gh
# Four spellings bash accepts; one was recognised, and the other three named the function
# instead of its body while reporting readable — a miss in silence, not an ask.
# Five spellings POSIX and bash accept, written out because the header was listed by
# spelling three times and missed one each time — the last being a blank between the name
# and the parens. The pattern is now derived from the construct, so these are a check that
# the derivation covers the writings rather than the definition of what is covered.
sees 'function no space' 'f(){ gh --version; }; f' gh
sees 'function blank'    'f () { gh --version; }; f' gh
sees 'function tab'      "f	() { gh --version; }; f" gh
sees 'function keyword'  'function f { gh --version; }; f' gh
sees 'function both'     'function f() { gh --version; }; f' gh
sees 'function all'      'function f () { gh --version; }; f' gh
sees 'for loop'       'for i in 1; do gh --version; done' gh
sees 'while loop'     'n=0; while [ $n = 0 ]; do n=1; gh --version; done' gh
sees 'if'             'if true; then gh --version; fi' gh
sees 'case arm'       'case x in x) gh --version ;; esac' gh

echo "--- wrappers: the first word is not the command"
sees 'exec -a'        '(exec -a innocent gh --version)' gh
sees 'xargs -0'       'echo x | xargs -0 gh --version' gh
# Two more rows the shell half cannot measure, for reasons worth writing down: `command -p`
# deliberately uses the *default* PATH, so the stub is out of reach by design, and `sudo -n`
# fails rather than prompt. Their class — a wrapper's boolean option — is measured by the
# `xargs -0` row above.
# The standard glued spellings. Sending them to unreadable was safe and would have spent a
# question on each, which matters because the question budget is what decides whether this
# guard gets switched on or switched off.
sees 'nice priority'  'nice -5 gh --version' gh
sees 'nice glued'     'nice -n5 gh --version' gh
names 'stdbuf glued'  'stdbuf -oL gh --version' gh   # GNU coreutils, absent here
sees 'xargs glued'    'echo x | xargs -n1 gh --version' gh

names 'command -p'    'command -p gh --version' gh
names 'timeout glued' 'timeout -s9 10 gh --version' gh
names 'sudo glued'    'sudo -ux gh --version' gh
names 'sudo -n'       'sudo -n gh --version' gh
sees 'exec'           '(exec gh --version)' gh
sees 'command'        'command gh --version' gh
sees 'env'            'env FOO=1 gh --version' gh
sees 'env -u'         'env -u FOO gh --version' gh
sees 'nice'           'nice -n 10 gh --version' gh
sees 'nohup'          'nohup gh --version' gh
# Three rows the tokenizer is checked on while the shell half cannot be: this host has no
# `timeout`, and `sudo` would wait for a password. Their grammatical class — a wrapper
# whose option takes a value — *is* measured, by the `nice -n 10` and `env -u FOO` rows
# above, and the two assertions below fail if those rows ever leave, so this is not a hole
# that closes quietly.
names 'timeout'       'timeout 5 gh --version' gh
names 'timeout -k'    'timeout -k 5 10 gh --version' gh
names 'sudo -u'       'sudo -u root gh --version' gh
if grep -q "sees 'nice'" "$0" && grep -q "sees 'env -u'" "$0"; then
  ok "the value-taking-option class is still measured by the nice and env rows"
else
  ko "the rows that measure the value-taking-option class are gone, so names() rows are unbacked"
fi
sees 'time'           'time gh --version' gh
sees 'a path'         './stubs/gh --version' gh

echo "--- where the shell runs code from"
sees 'sh -c'          "sh -c 'gh --version'" gh
sees 'substitution'   'out="$(gh --version)"' gh
sees 'backticks'      'out=`gh --version`' gh
sees 'process subst'  'cat <(gh --version) >/dev/null' gh
sees 'pipeline'       'true | gh --version' gh
sees 'and-list'       'true && gh --version' gh
sees 'separator'      'true; gh --version' gh
sees 'continuation'   'gh \
--version' gh

echo "--- what cannot be read without running it"
asks 'command substitution' '$(echo gh) --version' 'parameter or command substitution'
asks 'parameter'      'c=gh; $c --version' 'parameter or command substitution'
asks 'default value'  '${u:-gh} --version' 'parameter or command substitution'
asks 'brace'          '{gh,git} --version' 'brace expansion'
asks 'pathname'       './g? --version' 'pathname pattern'
asks 'eval'           'eval gh --version' 'not in this text'
asks 'source'         '. ./s.sh' 'not in this text'
asks 'source word'    'source ./s.sh' 'not in this text'
asks 'trap'           'trap "gh --version" EXIT' 'not in this text'
asks 'unknown option' 'nice -q10 gh --version' 'whether it takes a value'
asks 'unknown option 2' 'exec -Z gh --version' 'whether it takes a value'
# The case alternation used to be declared unreadable, which cost an ask per
# multi-pattern arm; the `|` state now lives in the splitter, where the cut happens.
sees 'case alternation' 'case x in a|x) gh --version ;; esac' gh
sees 'case later arm'   'case x in a) true ;; x) gh --version ;; esac' gh

echo "--- the separator that is not one, and the text that is not code"
if [ "$(commands_of "gh pr comment -b 'a; gh pr merge 7'" | tr -d ' ')" = gh ] &&
   [ "$(printf '%s' "gh pr comment -b 'a; gh pr merge 7'" | perl "$TOKENIZE" | wc -l | tr -d ' ')" = 1 ]; then
  ok "a separator inside quotes is text: one segment"
else
  ko "a quoted separator was treated as a separator"
fi
if [ "$(commands_of 'gh pr comment -b "a" ; gh pr merge 7')" = "gh gh " ]; then
  ok "a separator outside quotes is a separator: two segments"
else
  ko "a real separator did not split: $(commands_of 'gh pr comment -b "a" ; gh pr merge 7')"
fi
if [ "$(commands_of 'gh pr comment --body-file - <<EOF
gh pr merge 7
EOF')" = "gh " ]; then
  ok "a heredoc body is text, not a command"
else
  ko "a heredoc body was read as a command"
fi

echo "--- both spellings of a wrapper option, because a table of one is right half the time"
# `sudo -u postgres psql` read as psql while `sudo --user postgres psql` — the same command,
# the long spelling, and the commoner one in anything written to be read — was declared
# unreadable and cost an ask. A table of short forms is a table that is right half the time.
#
# `names` and not `sees`: these long forms are GNU's, and the host this runs on is macOS,
# where `nice --adjustment` and `env --unset` do not exist. A row whose execution cannot be
# measured here is the exact case `names` exists for — and the measured rows of the same
# class are the short spellings a few lines above, which `sees` does run.
names "sudo, long"    'sudo --user postgres git status' git
names "env, long"     'env --unset FOO git status' git
names "nice, long"    'nice --adjustment 10 git status' git
names "timeout, long" 'timeout --signal TERM 60 git status' git
names "xargs, long"   'xargs --replace {} git status' git
names "sudo boolean, long" 'sudo --login git status' git
# The witness for those six: the short spelling of the same construct is measured, so the
# walk itself is not taken on trust — only the table's long column is. `nice -n` and not
# `sudo -u`, because sudo cannot be run here either and a witness that cannot run is not a
# witness.
sees "nice, short, measured" 'nice -n 5 gh --version' gh
# And an option neither table knows is still an admission, whichever spelling it wears.
asks "a long option neither table knows" 'sudo --made-up x git status' 'whether it takes a value is unknown'

echo "--- an option where the command word goes is not a command word"
# `time` was in the reserved-word table *and* the wrapper table, and the reserved branch runs
# first: `time` was eaten as punctuation, `-p` became the command word, readable, and
# `time -p gh pr merge 7 --admin` was **allowed**. Not asked — allowed, because `-p` is a
# perfectly readable word that no rule names.
#
# Two fixes, and the second is the one that matters: `time` is a wrapper whatever the grammar
# calls it, and a command word can never begin with a dash — the shell would look for a file
# named `-p`. The net covers the next grammar word to be mishandled, which has not been
# written yet.
sees "time, bash form"   'time gh --version' gh
names "time -p"          'time -p gh --version' gh
names "time -f"          'time -f %e gh --version' gh
names "time -v"          'time -v gh --version' gh
# A reserved word followed by an option is what the `time` defect looked like from the
# inside, and it is what the net catches whatever reserved word is in front: the shell would
# look for a file named `-p`.
asks "an option after a reserved word"  'then -p gh pr merge 7' 'an option sits where the command word should be'
asks "an option after coproc"           'coproc -p gh pr merge' 'an option sits where the command word should be'
asks "an option after a negation"       '! -v gh pr merge' 'an option sits where the command word should be'

echo "--- a help request performs nothing, for a wrapper as for anything else"
# Thirteen of the fourteen wrappers asked the human to confirm `<wrapper> --help`, with the
# reason "whether it takes a value is unknown here" — which is not what is happening. And the
# design justifies asking by "the command is not in this text", which `env --help` fails: it
# runs exactly what it says. A table gap wearing the costume of a design cost.
for line in 'env --help' 'sudo --help' 'nice --help' 'timeout --help' 'xargs --help' \
            'stdbuf --help' 'ionice --help' 'nohup --help' 'setsid --help' 'doas -h' \
            'timeout -h' 'xargs -h' 'command -V'; do
  total=$((total + 1))
  verdict=$(printf '%s' "$line" | perl "$TOKENIZE" | jq -r '"\(.command)/\(.readable)"')
  if [ "$verdict" = "/true" ]; then
    echo "ok    '$line' runs no command, and is not asked about"
  else
    echo "FAIL  '$line' reported $verdict"
    failures=$((failures + 1))
  fi
done
# And an option that belongs to the *inner* command must not be read as the wrapper's: this
# is what scanning every remaining word broke.
sees 'version through a wrapper'  'echo x | xargs -0 gh --version' gh
sees 'version after a priority'   'nice -5 gh --version' gh

# Nor as a help request when it is an option's **value**. A scan of its own over the leading
# run of dashes does not know which of them take a value, so this read as help and the
# segment reported no command at all — `env -u -h gh pr merge 7 --admin` was **allowed**, one
# word from `env -u FOO gh pr merge 7 --admin`, which is refused. It shipped that way in
# 0.3.0, and the inner command really runs: measured on macOS and on GNU for all four below.
#
# The rows are here because their absence is what let it ship. The fix was to delete the
# second reader, not to teach it the tables the first one already had.
names 'help as the value of env -u'     'env -u -h gh --version' gh
names 'version as the value of env -u'  'env -u -V gh --version' gh
names 'help as the value of exec -a'    'exec -a -h gh --version' gh
names 'help as the value of xargs -E'   'xargs -E -h gh --version' gh
names 'help as the value of sudo -p'    'sudo -p -h gh --version' gh
# The witness those five need: the same wrappers, with an ordinary value, are measured.
sees 'env -u with an ordinary value'    'env -u FOO gh --version' gh

echo "--- two grammar forms whose second spelling shipped unread"
# Both are escapes the dash net cannot reach, because neither leaves an option where the
# command word goes — they leave a *name*. And in both cases one spelling was handled and
# its twin was not, which is the shape this file keeps finding: `coproc` alone was right and
# `coproc NAME { … }` named the coprocess; `2>/dev/null` was right and `{fd}>log` read as
# the command word. `coproc CO { gh pr merge 7 --admin; }` and
# `{fd}>log gh pr merge 7 --admin` were both allowed in 0.3.0.
names 'coproc with a name'      'coproc CO { gh --version; }' gh
names 'coproc, paren form'      'coproc CO ( gh --version )' gh
# Any compound command, which is what bash allows after the name — two spellings were closed
# in two releases before the set was looked up. These are its grammar's, not a memory of it.
names 'coproc then if'          'coproc CO if gh --version; then :; fi' gh
names 'coproc then while'       'coproc CO while gh --version; do :; done' gh
names 'coproc then until'       'coproc CO until gh --version; do :; done' gh
names 'coproc then case'        'coproc CO case x in a) gh --version;; esac' gh
names 'coproc without a name'   'coproc gh --version' gh
names 'a varname file descriptor' '{fd}>log gh --version' gh
sees  'a numbered redirection'  '2>/dev/null gh --version' gh

# And the target, when a blank separates it from the operator. `2> /dev/null gh pr merge 7
# --admin` was allowed — one space from the glued form, which is refused — because skipping
# one word left `/dev/null` as the command word. Thirteen spellings did it.
#
# What decides is whether the operator **ends** the word. `2>&1` does not and must keep being
# skipped alone: a fix that took its next word would have traded one escape for another, so
# that row is here too.
sees 'a separated target'       '2> /dev/null gh --version' gh
sees 'a bare redirection'       '> out gh --version' gh
sees 'an appending one'         '>> out gh --version' gh
sees 'both merged forms'        '&> out gh --version' gh
sees 'the other merged form'    '>& out gh --version' gh
sees 'an input redirection'     '< /dev/null gh --version' gh
names 'a varname, separated'    '{fd}> out gh --version' gh
sees 'a duplication, no target' '2>&1 gh --version' gh
sees 'a duplication then one'   '2>&1 > out gh --version' gh
sees 'an assignment first'      'FOO=1 > out gh --version' gh

# The two operators that begin with `&`, which the character class 0.3.1 shipped could not
# match: it asked for an optional file descriptor then `<` or `>`, so `&>` and `&>>` became
# the command word themselves and `&> out gh pr merge 7 --admin` ran.
#
# `>|` needed the *splitter* as well: it is one operator, and cutting at the `|` left a bare
# `>` as one segment and a second whose command word was `out`.
sees 'the clobber operator'     '>| out gh --version' gh
sees 'clobber, glued'           '>|out gh --version' gh
sees 'clobber with a fd'        '2>| out gh --version' gh
sees 'read-write'               '<> f gh --version' gh
sees 'read-write with a fd'     '2<> f gh --version' gh
names 'duplicating input'       '<& 3 gh --version' gh
# `&>>` is bash 4, and the host this runs on is bash 3.2 — so the shell half cannot be
# measured here, which is exactly what `names` is for. Its witness is `&>` two rows up, which
# 3.2 does have and which `sees` runs.
names 'append both streams'     '&>> out gh --version' gh
# And a pipe is still a pipe.
sees 'an ordinary pipeline'     'echo x | gh --version' gh

# A redirection ends a word wherever it sits, so an operator may be glued **behind** the
# command word: `gh>out --version` is the command `gh` with its output redirected, and
# `gh>out pr merge 7 --admin` really merges. The list of operators had just stopped being a
# list while the list of *placements* still was one — the prefix form was read and the glued
# one was not, which is the same shape one layer down.
sees  'glued behind, output'      'gh>out --version' gh
sees  'glued behind, append'      'gh>>out --version' gh
sees  'glued behind, clobber'     'gh>|out --version' gh
sees  'glued behind, input'       'gh</dev/null --version' gh
sees  'glued behind, read-write'  'gh<>out --version' gh
sees  'glued behind, both streams' 'gh&>out --version' gh
sees  'glued behind, duplicated'  'gh>&2 --version' gh
sees  'glued behind, here-string' 'gh<<<x --version' gh
# fd 3 is not open and `&>>` is bash 4, so the shell half of these two cannot be measured on
# the host (3.2). Their witnesses are the rows above, which `sees` runs.
names 'glued behind, dup input'   'gh<&3 --version' gh
names 'glued behind, append both' 'gh&>>out --version' gh
# A file descriptor glued in front still belongs to the operator: splitting `2>out` would
# leave a word `2`, which the walk would then name as the command.
sees  'a fd belongs to its operator' '2>out gh --version' gh
names 'and so does a varname one'    '{fd}>out gh --version' gh

echo "--- a paren ends a word too, and process substitution is a word"
# Sixteen command lines were allowed in silence because the word splitter did not end a word
# at a paren: the construct and its command arrived glued together, as a command word like
# `CO(gh` or `x)gh` that no rule names. Each really runs the merge, which is what `sees`
# measures here.
names 'coproc, glued'           'coproc CO(gh --version)' gh
sees 'a negation, glued'        '!(gh --version)' gh
sees 'time, glued'              'time(gh --version)' gh
sees 'if, glued'                'if(gh --version); then :; fi' gh
sees 'while, glued'             'while(gh --version); do break; done' gh
sees 'until, glued'             'until(gh --version); do :; done' gh
sees 'a brace, glued'           '{(gh --version); }' gh
sees 'a case arm, glued'        'case x in x)gh --version;; esac' gh
sees 'a case arm with its paren' 'case x in (x)gh --version;; esac' gh
# And the constructs where the paren belongs to the word stay whole: a substitution the
# splitter has hollowed out, a function header, an array assignment.
sees 'a subshell'               '(gh --version)' gh
sees 'a function header'        'f(){ gh --version; }; f' gh
names 'a substitution in a path' 'gh api repos/o/r/statuses/$(git rev-parse HEAD)' gh
# `<(…)` is process substitution: bash expands it to a /dev/fd path and passes it as a
# **word**. Read as a redirection it was dropped from the operands, and the option carrying
# it lost its value — `--input <(echo x)` came out as a bare `--input`.
# Both spellings of the option, because the first fix was applied to the two readers that had
# shown the symptom and not to the word splitter: a `<` still ended a word, so the glued
# `--input=<(echo x)` came out as `--input=` plus `<()` and the value read empty again — one
# spelling over from the finding being fixed.
for form in '--input <(echo x)=--input <()' '--input=<(echo x)=--input=<()'; do
  written=${form%%=--input*}
  want=--input${form##*=--input}
  subst=$(printf 'gh api -X POST repos/o/r/statuses/abc %s' "$written" |
    perl "$TOKENIZE" | jq -r 'select(.command == "gh") | .normalised')
  case $subst in
    *"$want") ok "process substitution stays an operand, with its option: $written" ;;
    *) ko "'$written' normalised to '$subst', which does not end in '$want'" ;;
  esac
done

# A word made only of closing parens runs nothing. An arithmetic `for` head is cut by the `;`
# inside it, and its last piece is two words now that a word ends after a `)` that closes
# nothing: the bare `)` was reported unreadable, which asks — and the first answer wins, so
# the merge rule was never reached on a line that really merges.
sees 'an arithmetic for head'    'for ((i=0;i<1;i++)); do gh --version; done' gh
for lone in ')' '))' ')))'; do
  verdict=$(printf '%s' "$lone" | perl "$TOKENIZE" | jq -r '"\(.command)/\(.readable)"')
  if [ "$verdict" = "/true" ]; then
    ok "'$lone' runs no command, and is not reported as unreadable"
  else
    ko "'$lone' reported $verdict, which spends an ask on punctuation"
  fi
done

echo "--- arithmetic runs no command, and the shell decides which parens are arithmetic"
# `$(( … ))` and `(( … ))` are expressions, and an expression runs nothing: `((gh pr merge 7
# --admin))` is a syntax error, not a merge. So the splitter hollows them out — and a
# hollowed construct is a place a command could hide, which is why every row below is
# measured on both halves rather than argued.
#
# Which `((` is arithmetic is decided textually, not by trying to parse: scanning after the
# `((` with a paren depth, the first `)` at depth 0 must be followed by another `)`.
# Otherwise the construct is a command substitution or a subshell holding a `(`, and the
# body runs. The obvious rule — "the two closing parens are glued" — is wrong, and
# `((gh …) && (:))` is the counter-example: it ends in `))` and all three shells run the
# merge. Measured on bash 3.2.57, bash 5.3.20 and zsh 5.9, which agree on every row here.
runs_nothing 'an arithmetic command'                '((i=1))'
runs_nothing 'an increment, the form that asked'    'inzip=$((inzip+1))'
runs_nothing 'an increment in double quotes'        'echo "$((i+1))"'
runs_nothing 'nested parens in an expression'       'x=$(( (1)+(2) ))'
runs_nothing 'a semicolon inside an expression'     'x=$((echo x; :))'
runs_nothing 'a merge spelled as an arithmetic command'   '((gh pr merge 7 --admin))'
runs_nothing 'a merge spelled as an arithmetic expansion' 'x=$((gh pr merge 7 --admin))'

# The same text one character apart, where the body does run. Each of these is the reason
# the hollowing is conditional.
sees 'a subshell wearing two parens'       '((gh pr merge 7 --admin) )' gh
sees 'the same, with a semicolon'          '((gh pr merge 7 --admin); :)' gh
sees 'the same, ending in two parens'      '((gh pr merge 7 --admin) && (:))' gh
sees 'an expansion that is a subshell'     'x=$((gh pr merge 7 --admin) )' gh
sees 'a substitution in an expression'     'x=$(( $(gh pr merge 7 --admin) + 1 ))' gh
sees 'a backquoted one'                    'x=$(( `gh pr merge 7 --admin` + 1 ))' gh
sees 'nested arithmetic around one'        'x=$(( $(( $(gh pr merge 7 --admin) )) + 1 ))' gh
sees 'an arithmetic command around one'    '(( $(gh pr merge 7 --admin) ))' gh
# The construct leaves no text behind, so the splitter keeps a letter where it stood: without
# it, the `#` below starts a word, the comment branch drops the rest of the line, and the
# merge on the next line is never seen.
sees 'a comment after an arithmetic command' '((i=1)) #x
gh pr merge 7 --admin' gh

echo "--- a -c body is read with the grammar of the shell that will read it"
# `((cmd))` is bash's arithmetic command, and zsh's and ksh's. `sh`, `dash` and busybox `ash`
# have no such thing: they read the same text as two nested subshells, so the body RUNS.
# This file descends into a `dash -c` body on purpose, so hollowing `(( … ))` there was a
# merge that no rule saw — a silent allow where 0.3.2 denied. Measured: dash 0.5.12 and
# busybox ash both merge, bash 3.2.57, bash 5.3.20, zsh 5.9 and ksh all refuse it.
#
# The shell half measures the named shell and not bash, without a new helper: the line under
# test is itself a `dash -c …`, so bash starts dash and the stub records what dash ran. That
# matters, because `sees` and `runs_nothing` hard-code `bash -c`, and a claim about another
# shell's grammar is one they could otherwise never contradict.
if command -v dash >/dev/null; then
  sees 'a merge in a dash body'      'dash -c "((gh pr merge 7 --admin))"' gh
  sees 'after another command'       'dash -c "echo hi; ((gh pr merge 7 --admin))"' gh
  sees 'three parens deep'           'dash -c "(((gh pr merge 7 --admin)))"' gh
  sees 'an expression spaced out'    'dash -c "(( (gh pr merge 7 --admin) ))"' gh
  sees 'env in front of it'          'env dash -c "((gh pr merge 7 --admin))"' gh
else
  # Both halves of every row above are measured where dash exists, which is the host this
  # was written on and the CI runner; here only the tokenizer can be.
  for dashless in 'dash -c "((gh pr merge 7 --admin))"' \
                  'dash -c "echo hi; ((gh pr merge 7 --admin))"' \
                  'dash -c "(((gh pr merge 7 --admin)))"' \
                  'dash -c "(( (gh pr merge 7 --admin) ))"' \
                  'env dash -c "((gh pr merge 7 --admin))"'; do
    names 'a merge in a dash body, no dash on this host' "$dashless" gh
  done
fi
# `sh` is bash on macOS and dash on Debian, so what the shell half would measure depends on
# the host. The tokenizer's answer must not: it reads `sh` as a shell with no arithmetic
# command, which is the conservative half of the two. Refusing a merge that was only ever a
# syntax error costs nothing; the other way round is a merge.
names 'a merge in an sh body'        'sh -c "((gh pr merge 7 --admin))"' gh
names 'the options glued'            'sh -ce "((gh pr merge 7 --admin))"' gh
# And a shell that does have one keeps it, body included.
runs_nothing 'an arithmetic command in a bash body' 'bash -c "((gh pr merge 7 --admin))"'
# `eval` runs in the current shell, so it inherits its grammar: the expression is hollowed,
# nothing is left to name, and what remains is the ask `eval` always costs. It denied on
# 0.3.2 — on a line bash refuses as a syntax error, so the refusal was right by accident.
asks 'an arithmetic command in an eval' 'eval "((gh pr merge 7 --admin))"' 'eval'
# The one branch of arith_end the mutations cannot reach, and the second exception to the
# note on `asks`: a quote in the expression. bash reads a quoted `)` as text, zsh ends the
# substitution on it, and the two then run different things — so the line stays unreadable
# and the guard asks. Nothing runs here on any shell measured, so the ask hides nothing.
asks 'a quote in an expression' 'x=$(( "gh pr merge 7 --admin" ))' 'a whole command line'

echo "--- an escaped operator is an argument, not an operator"
# Two lookbehinds in the splitter decide whether a `|` or an `&` belongs to a redirection
# written just before it. They read the text with escapes neutralised, because a `\>` is an
# argument: read on the text as written, the answer was yes, so `echo \>|gh pr merge 7
# --admin` came out as a single segment named `echo` and the merge ran. The `>|` half of that
# was a regression introduced by the fix that taught the splitter about `>|` at all; the `&`
# half had been there from the beginning.
sees 'an escaped > then a pipe'   'echo \>|gh --version' gh
sees 'an escaped > then an amp'   'echo \>& gh --version' gh
sees 'two escaped > then a pipe'  'echo \>\>|gh --version' gh
sees 'a fd then an escaped >'     'echo x 2\>|gh --version' gh
# The neutralised character is a letter and not a blank, because a blank would make this look
# like a word boundary followed by a comment — and the comment branch drops the rest of the
# line, which would have hidden the `gh` here instead of showing it.
sees 'an escaped blank is no boundary' 'echo a\ #b; gh --version' gh

echo "--- a conditional expression runs no command"
# `[[` opens one, and what follows is not a command word: walking past it left `-f` there,
# which the dash net then asked about — a question about the shell own grammar, the same
# defect `[` had and the same answer.
for line in '[[ -f x ]]' '[[ -z "$x" ]]' '[[ $a == b ]]'; do
  total=$((total + 1))
  verdict=$(printf '%s' "$line" | perl "$TOKENIZE" | jq -r '"\(.command)/\(.readable)"' | head -1)
  if [ "$verdict" = "/true" ]; then
    echo "ok    '$line' runs no command, and is not asked about"
  else
    echo "FAIL  '$line' reported $verdict"
    failures=$((failures + 1))
  fi
done

echo "--- nothing to judge is not the same as unreadable"
for line in 'c=gh' '}' 'done' '2>/dev/null'; do
  verdict=$(printf '%s' "$line" | perl "$TOKENIZE" | jq -r '"\(.command)/\(.readable)"')
  if [ "$verdict" = "/true" ]; then
    ok "'$line' runs no command, and is not reported as unreadable"
  else
    ko "'$line' reported $verdict, which would spend an ask on nothing"
  fi
done

echo "--- a prefix changes how the command is reached, never what it is given"
# This is the invariant `normalised` exists for, and it is the one a rule depends on: rules
# match this field, so a word that disappears from it is a rule that stops applying, with
# nothing to show that it has. The property is stated against a reference rather than per
# form — every grammatical prefix must leave the operands of the bare line untouched — so
# a new prefix branch is covered the day it is written, including the one that miscounts.
#
# It was not stated, and two forms were wrong at once: `(gh pr merge 7)` came out as
# `gh merge 7`, the `pr` gone because the walk renders `(gh` as two words and the
# normaliser recovered its position by counting them; and `--admin)` kept its paren, so
# every rule anchored on a word boundary walked past it.
reference=$(printf '%s' 'gh pr merge 7 --admin' | perl "$TOKENIZE" | jq -r '.normalised')
for prefix_form in \
    'gh pr merge 7 --admin' \
    '(gh pr merge 7 --admin)' \
    '( (gh pr merge 7 --admin) )' \
    '((gh pr merge 7 --admin) )' \
    'exec gh pr merge 7 --admin' \
    '(exec gh pr merge 7 --admin)' \
    'command gh pr merge 7 --admin' \
    'env FOO=1 gh pr merge 7 --admin' \
    'FOO=1 gh pr merge 7 --admin' \
    '2>/dev/null gh pr merge 7 --admin' \
    'then gh pr merge 7 --admin' \
    'nice -n 10 gh pr merge 7 --admin' \
    'xargs -r gh pr merge 7 --admin' \
    'case $x in a) gh pr merge 7 --admin' \
    'f () { gh pr merge 7 --admin' \
    "g\\h pr merge 7 --admin" \
    '/usr/local/bin/gh pr merge 7 --admin' \
    '"gh" pr merge 7 --admin'; do
  got=$(printf '%s' "$prefix_form" | perl "$TOKENIZE" | jq -r 'select(.command == "gh") | .normalised' | head -1)
  if [ "$got" = "$reference" ]; then
    ok "the operands survive: $prefix_form"
  else
    ko "'$prefix_form' normalised to '$got', not '$reference'"
  fi
done

# The witness this reference needs: it must not be empty, or every row above compares
# nothing with nothing and passes.
if [ "$reference" = 'gh pr merge 7 --admin' ]; then
  ok "witness: the reference is the whole line, so the rows above compare something"
else
  ko "witness: the reference is '$reference' — the rows above prove nothing"
fi

echo "--- a redirection is not an operand, wherever it sits"
# Same reference, same property, stated for the placements a prefix branch cannot cover: the
# shell takes a redirection out of a command's words before running it, so a rule reading
# positions must see what the shell sees. Splitting the word at its operator was not enough
# on its own — `gh>out pr merge 7 --admin` then became `gh` with the operands
# `>out pr merge 7 --admin`, and the subcommand path read `>out pr merge 7`, which matches no
# rule about `pr merge`. The target goes too when the operator ends the word, which is why
# `< x` in the middle of a line does not eat `--admin`.
for redir_form in \
    'gh>out pr merge 7 --admin' \
    'gh>|out pr merge 7 --admin' \
    'gh&>out pr merge 7 --admin' \
    'gh<in pr merge 7 --admin' \
    'gh pr merge 7 --admin >out' \
    'gh pr merge 7 --admin > out' \
    'gh pr merge 7 >out --admin' \
    'gh pr merge 7 > out --admin' \
    'gh pr merge 7 < x --admin' \
    'gh pr merge 7 --admin 2>&1' \
    'gh pr merge 7 --admin <<<x' \
    'coproc CO(gh pr merge 7 --admin)' \
    '!(gh pr merge 7 --admin)' \
    'time(gh pr merge 7 --admin)' \
    'case x in x)gh pr merge 7 --admin' \
    'case x in (x)gh pr merge 7 --admin'; do
  got=$(printf '%s' "$redir_form" | perl "$TOKENIZE" | jq -r 'select(.command == "gh") | .normalised' | head -1)
  if [ "$got" = "$reference" ]; then
    ok "the operands survive, and the redirection is gone: $redir_form"
  else
    ko "'$redir_form' normalised to '$got', not '$reference'"
  fi
done

# A `)` that closes a substitution is balanced inside its own word and stays, because what
# marks punctuation is the imbalance, not the character. The substitution's body is already
# hollowed out by the splitter — it is a segment of its own, and what it computes is not in
# this text — so what must survive here is the empty `$()`, with its closing paren: a rule
# that reads a path must still see that the path ends in something it cannot know.
balanced=$(printf '%s' 'gh api repos/o/r/statuses/$(git rev-parse HEAD)' | perl "$TOKENIZE" |
  jq -r 'select(.command == "gh") | .normalised')
case $balanced in
  *'statuses/$()') ok "a balanced ) belongs to its word and is kept" ;;
  *) ko "a balanced ) was taken for punctuation: $balanced" ;;
esac

echo "--- the three fields, and which one a rule may use"
record=$(printf '%s' 'g\h pr merge 7' | perl "$TOKENIZE")
if [ "$(jq -r .raw <<<"$record")" = 'g\h pr merge 7' ] &&
   [ "$(jq -r .command <<<"$record")" = gh ] &&
   [ -n "$(jq -r .resolved <<<"$record")" ]; then
  ok "raw keeps what was written, command is normalised, resolved says how"
else
  ko "the three fields are not what they claim: $record"
fi
if printf '%s' 'x' | perl "$TOKENIZE" | jq -e 'has("raw") and has("command") and has("resolved") and has("readable") and has("reason")' >/dev/null; then
  ok "every record carries all five fields, so a reader need not test for them"
else
  ko "a record is missing a field"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total tokenizer test(s) failed"
  exit 1
fi
echo "all $total tokenizer tests passed"
