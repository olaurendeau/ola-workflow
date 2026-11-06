#!/usr/bin/env bash
# shellcheck disable=SC2016
#   A `{{x}}`, a `$` or a backtick in a template below is the text under test: expanding it
#   here would test nothing.
# The renderer of the brief (hooks/lib/brief-render.awk) and the brief built on it.
#
# Every case writes a template, gives the values for that one command, and compares the
# output to the byte with cmp: a `case` pattern forgives a trailing newline, and the
# newline is half of what this engine decides. The engine has to give the same bytes on
# the awk of a Mac (BWK) and on the one of CI (mawk), so nothing here is adapted to either.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/scratch.sh
. "$ROOT/scripts/scratch.sh"
ENGINE=$ROOT/hooks/lib/brief-render.awk

failures=0
total=0
ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

ola_scratch brief
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT

# run_engine <template text> [name=value ...] → RC, and the bytes in $WORK/out and $WORK/err.
# The environment is empty but for PATH and the values given, which the engine reads as
# OLA_BRIEF_<name>. The template is written without a newline of its own.
run_engine() {
  local tpl=$1 kv args=()
  shift
  printf '%s' "$tpl" >"$WORK/tpl.md"
  for kv in "$@"; do args+=("OLA_BRIEF_$kv"); done
  env -i PATH="$PATH" ${args[@]+"${args[@]}"} awk -f "$ENGINE" "$WORK/tpl.md" >"$WORK/out" 2>"$WORK/err"
  RC=$?
}

renders() { # renders <label> <template> <expected output> [name=value ...]
  local label=$1 tpl=$2 want=$3
  shift 3
  run_engine "$tpl" "$@"
  printf '%s' "$want" >"$WORK/want"
  if [ "$RC" = 0 ] && cmp -s "$WORK/want" "$WORK/out"; then
    ok "$label"
  else
    ko "$label (exit $RC; got $(od -c "$WORK/out" | head -3 | tr -s ' ' | tr '\n' '|'))"
  fi
}

refuses() { # refuses <label> <template> <expected stderr fragment> [name=value ...]
  local label=$1 tpl=$2 where=$3
  shift 3
  run_engine "$tpl" "$@"
  if [ "$RC" = 2 ] && [ ! -s "$WORK/out" ] && grep -qF -- "$where" "$WORK/err"; then
    ok "$label"
  else
    ko "$label (exit $RC; stdout $(wc -c <"$WORK/out" | tr -d ' ') bytes; stderr: $(tr '\n' '|' <"$WORK/err"))"
  fi
}

# --- 1. Text without a tag comes out as it went in ---------------------------------------
plain=$'## Title\n\n\n  indented  \ntrailing  \n{slot} and {owner}/{repo} and \\(.id) and `code` and 100%s\n'
renders "text without a tag is unchanged, blank lines, edge spaces and braces included" "$plain" "$plain"
renders "an em dash and an arrow glued to a tag are kept" $'a —{{v}}→ b\n— {{#f}}x{{/f}}→\n' $'a —Z→ b\n— x→\n' v=Z f=1
renders "an empty template renders nothing" "" ""

# --- 2. Values are printed as they are ---------------------------------------------------
trap_value() { # trap_value <label> <value>
  renders "value $1 is printed untouched" $'[{{v}}]\n' $'['"$2"$']\n' "v=$2"
}
trap_value "with a slash" 'a/b'
trap_value "with an ampersand" 'a&b'
trap_value "with a backslash" 'a\b\\c'
trap_value "with a back-reference" 'x\1y'
trap_value "with printf directives" '100%s %d %%'
trap_value "with a tag in it (not read again)" '{{x}}'
trap_value "with closing braces" '}} and }'
trap_value "starting with -n" '-n'
trap_value "on several lines" $'one\ntwo\n\nfour'
trap_value "that is 0" '0'
trap_value "that is 00" '00'
trap_value "that is 1e3" '1e3'
renders "a value holding a block tag does not open a block" $'{{v}}\nafter\n' $'{{#x}}\nafter\n' 'v={{#x}}'

# --- 3. An empty value is nothing --------------------------------------------------------
renders "an empty value prints nothing" $'[{{v}}]\n' $'[]\n' v=
renders "a line that is only an empty value is an empty line" $'a\n{{v}}\nb\n' $'a\n\nb\n' v=

# --- 4. A flag is true when its value is not the empty string ----------------------------
for v in 1 0 00 ' ' 'x'; do
  renders "flag '$v' is true" $'[{{#f}}Y{{/f}}]\n' $'[Y]\n' "f=$v"
done
renders "flag '' is false" $'[{{#f}}Y{{/f}}]\n' $'[]\n' f=

# --- 5. Blocks ---------------------------------------------------------------------------
alone=$'a\n{{#f}}\nb\n{{/f}}\nc\n'
renders "a block alone on its lines, true: the tag lines vanish with their newline" "$alone" $'a\nb\nc\n' f=1
renders "a block alone on its lines, false: the lines vanish" "$alone" $'a\nc\n' f=
renders "an inline block, true" $'x {{#f}}Y{{/f}} z\n' $'x Y z\n' f=1
renders "an inline block, false" $'x {{#f}}Y{{/f}} z\n' $'x  z\n' f=
merging=$'report{{#t}}\n— read it{{/t}}:\n'
renders "a block opened at the end of a line and closed on the next, true" "$merging" $'report\n— read it:\n' t=1
renders "a block opened at the end of a line and closed on the next, false" "$merging" $'report:\n' t=
renders "a block that is a tag and text on one line is inline" $'{{#f}}Y{{/f}}\n' $'Y\n' f=1
renders "an inline block, false, on a line of its own, leaves an empty line" $'a\n{{#f}}Y{{/f}}\nb\n' $'a\n\nb\n' f=
nest=$'a\n{{#o}}\n{{#i}}\nz\n{{/i}}\nw\n{{/o}}\nb\n'
renders "nested blocks, outer true and inner true" "$nest" $'a\nz\nw\nb\n' o=1 i=1
renders "nested blocks, outer true and inner false" "$nest" $'a\nw\nb\n' o=1 i=
renders "nested blocks, outer false and inner true: nothing" "$nest" $'a\nb\n' o= i=1
renders "nested blocks, both false" "$nest" $'a\nb\n' o= i=
renders "an outer false block drops a nested inline block" $'{{#o}}p{{#i}}q{{/i}}r{{/o}}!\n' $'!\n' o= i=1
renders "a name may be opened again once closed" $'{{#f}}a{{/f}}{{#f}}b{{/f}}\n' $'ab\n' f=1

# --- 6. Blank lines in a block -----------------------------------------------------------
blank=$'a\n{{#f}}\n\nb\n\n{{/f}}\nc\n'
renders "blank lines in a true block are kept" "$blank" $'a\n\nb\n\nc\n' f=1
renders "blank lines in a false block are removed" "$blank" $'a\nc\n' f=

# --- 7. Errors: exit 2, nothing on stdout, the file and the line on stderr ----------------
refuses "an undeclared value is refused, with its line" $'fine\n{{nope}}\n' 'tpl.md:2:'
refuses "an undeclared flag is refused: a misspelled one would hide a block" $'{{#nope}}x{{/nope}}\n' 'tpl.md:1:'
refuses "an undeclared name is refused inside a false block too" $'{{#f}}\n{{nope}}\n{{/f}}\n' 'tpl.md:2:' f=
refuses "an opening without its closing braces is refused" $'ok\n{{x\n' 'tpl.md:2:' x=1
refuses "{{ x }} is refused" $'ok\n{{ x }}\n' 'tpl.md:2:' x=1
refuses "{{X}} is refused" $'{{X}}\n' 'tpl.md:1:' X=1 x=1
refuses "{{}} is refused" $'{{}}\n' 'tpl.md:1:'
refuses "{{1x}} is refused: a name starts with a letter" $'{{1x}}\n' 'tpl.md:1:' 1x=1
refuses "a closing without an opening is refused" $'a\n{{/x}}\n' 'tpl.md:2:' x=1
refuses "a closing of another name is refused" $'{{#a}}\n{{#b}}\n{{/a}}\n{{/b}}\n' 'tpl.md:3:' a=1 b=1
refuses "a block left open is refused" $'{{#a}}\nx\n' 'tpl.md:1:' a=1
printf '%s' x >"$WORK/rel.md"
if (cd "$WORK" && env -i PATH="$PATH" awk -f "$ENGINE" rel.md >/dev/null 2>&1); then
  ko "a relative template path is rendered"
else
  ok "a relative template path is not rendered"
fi

# --- The brief ---------------------------------------------------------------------------
# A copy of what the brief is made of, so that a template can be broken without touching
# the tree. The profile is the smallest that applies.
COPY=$WORK/copy
mkdir "$COPY"
for part in bin hooks schema brief; do
  [ -d "$ROOT/$part" ] && cp -R "$ROOT/$part" "$COPY/$part"
done
REPO=$WORK/repo
mkdir -p "$REPO/.claude" "$WORK/home"
git -C "$REPO" -c init.defaultBranch=main init -q 2>/dev/null
printf '{"mode":"integrated"}\n' >"$REPO/.claude/workflow.json"

run_brief() { # run_brief [env assignment...] → RC, $WORK/bout, $WORK/berr
  env HOME="$WORK/home" "$@" "$COPY/bin/ola-workflow-brief" "$REPO" >"$WORK/bout" 2>"$WORK/berr"
  RC=$?
}
broken() { # broken <label> <template file> → the brief refuses whole, and says so in its own words
  if [ "$RC" = 2 ] && [ ! -s "$WORK/bout" ] && grep -qxF "ola-workflow-brief: brief/$2 could not be rendered" "$WORK/berr"; then
    ok "$1"
  else
    ko "$1 (exit $RC; stdout $(wc -c <"$WORK/bout" | tr -d ' ') bytes; stderr: $(tr '\n' '|' <"$WORK/berr"))"
  fi
}

run_brief
if [ "$RC" = 0 ] && [ "$(wc -l <"$WORK/bout")" -ge 20 ] && [ ! -s "$WORK/berr" ]; then
  ok "witness: the unbroken copy renders a brief"
else
  ko "witness: the unbroken copy does not render (exit $RC, $(wc -l <"$WORK/bout") lines)"
fi
cp "$WORK/bout" "$WORK/reference"

printf '%s\n' '{{nope}}' >>"$COPY/brief/commands.md"
run_brief
broken "a name nobody declares in commands.md stops the brief, whole, naming the file" commands.md
cp "$ROOT/brief/commands.md" "$COPY/brief/commands.md"

rm "$COPY/brief/slots.md"
run_brief
broken "a missing slots.md stops the brief, whole, naming the file" slots.md
cp "$ROOT/brief/slots.md" "$COPY/brief/slots.md"

printf '%s\n' '{{zz}}' >>"$COPY/brief/languages.md"
run_brief OLA_BRIEF_zz=leak
broken "a name only the caller's environment declares stops the brief" languages.md
if grep -q leak "$WORK/bout" "$WORK/berr"; then
  ko "an OLA_BRIEF_ variable of the caller reached the output"
else
  ok "an OLA_BRIEF_ variable of the caller is not read, and does not leak"
fi
cp "$ROOT/brief/languages.md" "$COPY/brief/languages.md"

run_brief
if cmp -s "$WORK/bout" "$WORK/reference"; then
  ok "the templates put back, the brief is the one it was"
else
  ko "the brief changed after the templates were put back"
fi
(cd / && env HOME="$WORK/home" "$COPY/bin/ola-workflow-brief" "$REPO" >"$WORK/elsewhere" 2>&1)
if cmp -s "$WORK/elsewhere" "$WORK/reference"; then
  ok "the brief is the same from another working directory"
else
  ko "the brief depends on the directory it is run from"
fi

# A NUL in a value of a restricted command is dropped, so that the NUL-separated fields the
# script reads from jq are not shifted: one in `cmd` or `reason` used to invent a rule line
# and swallow the element after it.
printf '%s\n' '{"mode":"integrated","commands":[{"cmd":"first\u0000x","reason":"why\u0000y"},{"cmd":"second","allow_args":true},{"cmd":"third"}]}' >"$REPO/.claude/workflow.json"
run_brief
nul=$(sed -n '/^## Restricted commands$/,/^Anything else is out of bounds/p' "$WORK/bout")
want=$'## Restricted commands\n- firstx: whyy\n- second: only some arguments are allowed\n- third: some arguments are refused\nAnything else is out of bounds. Knowing it in advance saves a cycle; it is not an'
if [ "$RC" = 0 ] && [ "$nul" = "$want" ]; then
  ok "a NUL in a cmd or a reason invents no rule line and drops no element"
else
  ko "a NUL in a restricted command shifted the fields (exit $RC): $(printf '%s' "$nul" | tr '\n' '|')"
fi
printf '%s\n' '{"mode":"integrated"}' >"$REPO/.claude/workflow.json"

# --- No text in the script ---------------------------------------------------------------
# Once the words are in brief/, nothing stops one from coming back into the script a line at
# a time. Four rules, read on the script with its comments removed:
#   1. no heredoc;
#   2. an `echo` is bare (an empty line) or goes to stderr;
#   3. a `printf` format is a literal with no ASCII letter outside its conversions (%s…),
#      its escapes (\n…) and the `:(glob)` pathspec syntax;
#   4. every file of brief/ is named by a literal `render` of the script, and every literal
#      `render` names a file that exists.
# Each counts what it examined and fails on zero, so that a pattern that stops finding
# anything cannot pass for a script with nothing to find.
# Known limit: a string of text in a jq program of the script is not seen.
text_problems() { # text_problems <script> <brief dir> → one line per problem, none when clean
  local script=$1 briefdir=$2 found name file
  found=$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]#.*$//' "$script" | perl -e '
    local $/; my $s = <STDIN>;
    $s =~ s/\\\n/ /g;
    print "problem: R1 a heredoc in the script\n" while $s =~ /(?<!<)<<(?!<)/g;
    for my $l (split /\n/, $s) {
      while ($l =~ /(?<![\w-])echo(?![\w-])((?:>&2|[^;|)&])*)/g) {
        my $rest = $1;
        print "echo\n";
        print "problem: R2 an echo with text: echo$rest\n"
          unless $rest =~ /^\s*$/ || $rest =~ />&2\s*$/;
      }
      if ($l =~ /(?<![\w-])printf(?![\w-])\s*(.*)$/) {
        my $rest = $1;
        print "printf\n";
        $rest =~ s/^(?:-v\s+\S+|--)\s+// while $rest =~ /^(?:-v\s+\S+|--)\s+/;
        my $fmt;
        if ($rest =~ /^\x27([^\x27]*)\x27/ || $rest =~ /^"((?:[^"\\\x24\x60]|\\.)*)"/
            || $rest =~ /^([^\s\x27"\x24\x60;&|()]+)/) { $fmt = $1 }
        else { print "problem: R3 a printf format that is not a literal: printf $rest\n" }
        if (defined $fmt) {
          $fmt =~ s/\\.//g;
          $fmt =~ s/%[-+ #0-9.*]*[a-zA-Z%]//g;
          $fmt =~ s/:\(glob\)//g;
          print "problem: R3 a printf format with text: $fmt\n" if $fmt =~ /[A-Za-z]/;
        }
      }
      while ($l =~ /(?<![\w-])render(?!\()\s+([^\s;&|)]+)/g) {
        my $n = $1;
        if ($n =~ /^[a-z][a-z0-9._\/-]*$/) { print "render:$n\n" }
        else { print "problem: R4 a render whose file is not a literal: render $n\n" }
      }
    }')
  printf '%s\n' "$found" | grep '^problem: '
  for name in echo printf; do
    printf '%s\n' "$found" | grep -qx "$name" || echo "problem: witness: no $name examined"
  done
  printf '%s\n' "$found" | grep -q '^render:' || echo "problem: witness: no render examined"
  for name in $(printf '%s\n' "$found" | sed -n 's/^render://p' | sort -u); do
    [ -f "$briefdir/$name.md" ] || echo "problem: R4 render $name names brief/$name.md, which does not exist"
  done
  while IFS= read -r file; do
    name=${file#"$briefdir"/}
    name=${name%.md}
    printf '%s\n' "$found" | grep -qx "render:$name" || echo "problem: R4 brief/$name.md is named by no render"
  done < <(find "$briefdir" -type f -name '*.md' | sort)
}

problems=$(text_problems "$ROOT/bin/ola-workflow-brief" "$ROOT/brief")
if [ -z "$problems" ]; then
  ok "the script holds no text: no heredoc, bare or stderr echo, literal printf formats, every template rendered"
else
  ko "the script holds text: $(printf '%s' "$problems" | tr '\n' '|')"
fi

mutant() { # mutant <label> <expected problem prefix> <script mutation, as a sed program> [brief file to add]
  local label=$1 want=$2 prog=$3 extra=${4-} out
  rm -rf "$WORK/mut" && mkdir -p "$WORK/mut" && cp -R "$ROOT/brief" "$WORK/mut/brief"
  sed -e "$prog" "$ROOT/bin/ola-workflow-brief" >"$WORK/mut/script"
  [ -n "$extra" ] && printf 'orphan\n' >"$WORK/mut/brief/$extra"
  out=$(text_problems "$WORK/mut/script" "$WORK/mut/brief")
  if printf '%s\n' "$out" | grep -q "^problem: $want"; then
    ok "$label"
  else
    ko "$label (got: $(printf '%s' "$out" | tr '\n' '|'))"
  fi
}
mutant "rule 1 fails on a heredoc added to the script" "R1" '$a\
cat <<EOF\
Never do this\
EOF'
mutant "rule 2 fails on an echo with text added to the script" "R2 an echo with text: echo \"Never do this\"" '$a\
echo "Never do this"'
mutant "rule 2 fails on an echo to stdout that follows a bare one" "R2" '$a\
echo; echo "Never do this"'
mutant "rule 3 fails on a printf with text added to the script" "R3 a printf format with text: Never do this" '$a\
printf "Never do this\\n"'
mutant "rule 3 fails on a printf whose format is not a literal" "R3 a printf format that is not a literal" '$a\
printf "$x"'
mutant "rule 4 fails on a brief/x.md that no render names" "R4 brief/x.md is named by no render" 's/^x$/x/' x.md
mutant "rule 4 fails on a render of a file that does not exist" "R4 render nowhere names" '$a\
render nowhere'
mutant "rule 4 fails on a render whose file is not a literal" "R4 a render whose file is not a literal" '$a\
render "$section"'

# The witnesses: a script with nothing to examine is not a clean script.
: >"$WORK/empty.sh"
out=$(text_problems "$WORK/empty.sh" "$ROOT/brief")
for what in echo printf render; do
  if printf '%s\n' "$out" | grep -qx "problem: witness: no $what examined"; then
    ok "witness: a script with no $what fails the rule that would have examined it"
  else
    ko "witness: a script with no $what passes (got: $(printf '%s' "$out" | tr '\n' '|'))"
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total brief test(s) failed"
  exit 1
fi
echo "all $total brief tests passed"
