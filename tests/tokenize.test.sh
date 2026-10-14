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
TOKENIZE="$ROOT/hooks/lib/tokenize.pl"
failures=0
total=0

ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

command -v perl >/dev/null || { echo "needs perl" >&2; exit 2; }
command -v jq >/dev/null || { echo "needs jq" >&2; exit 2; }

WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ola-tokenize.XXXXXX")" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

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
# What cannot be known without running it is declared, never guessed. Each of these is a
# command the shell does run, so silence here would be a miss and a refusal would be a
# false positive: the caller is meant to ask.
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
names 'coproc without a name'   'coproc gh --version' gh
names 'a varname file descriptor' '{fd}>log gh --version' gh
sees  'a numbered redirection'  '2>/dev/null gh --version' gh

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
    '((gh pr merge 7 --admin))' \
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
