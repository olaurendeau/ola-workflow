# Renders one Markdown template of the brief (brief/*.md) on stdout.
#
#   OLA_BRIEF_<name>=<value> ... awk -f brief-render.awk /absolute/path/to/template.md
#
# The template is the text; bash only supplies values. Three constructs, nothing else:
#
#   {{name}}           the value, as it is: printed, never read again, so a `{{x}}` inside
#                      a value comes out as `{{x}}`
#   {{#name}}...{{/name}}   kept when the value is not the empty string. Compared as a
#                      string: awk takes an ENVIRON value that looks like a number for a
#                      number, and `if (v)` would call "0" false, "00" and " " too
#   names are [a-z][a-z0-9_]*; blocks nest; a closing tag closes the innermost open block
#
# Newlines. A line that is only a block tag, with nothing around it, produces nothing, its
# newline included. Anywhere else a tag is inline: only its own text disappears, and the
# newline of a line is printed when no false block is open at the end of that line. That is
# what lets a block open at the end of one line and close in the middle of the next:
#
#   ...from a report{{#on}}
#   — read as ... cannot{{/on}}:
#
# gives "...from a report:" when `on` is empty and both lines otherwise.
#
# Values come from ENVIRON only: `-v` would interpret backslashes, a pattern would give `&`
# and `\1` a meaning, and the template path is read as a file by being absolute — a
# relative `x=y` would be taken by awk for an assignment. Every name used must be declared,
# a flag as much as a value, or a misspelled flag would hide a block without a word.
#
# On an error: exit 2, `<file>:<line>: <reason>` on stderr and nothing on stdout, because
# the output is held until END. A caller prints the brief whole or not at all.
#
# POSIX awk only. CI runs mawk and a Mac runs BWK awk: no gensub, no 3-argument match(), no
# length() of an array. Characters are looked up in a string and never in a range, so the
# locale cannot widen [a-z].

function fail(why) {
  print file ":" FNR ": " why > "/dev/stderr"
  bad = 1
  exit 2
}

# The length of the name starting at position p of s: 0 when there is none.
function name_length(s, p,    n, c, allowed) {
  n = 0
  while (p + n <= length(s)) {
    c = substr(s, p + n, 1)
    allowed = LOWER
    if (n > 0) allowed = LOWER DIGITS "_"
    if (index(allowed, c) == 0) break
    n++
  }
  return n
}

function emit(text) {
  if (off == 0) out = out text
}

function declared(name) {
  if (!(("OLA_BRIEF_" name) in ENVIRON)) fail("{{" name "}} is not declared by the caller")
}

BEGIN {
  LOWER = "abcdefghijklmnopqrstuvwxyz"
  DIGITS = "0123456789"
  out = ""
  depth = 0     # open blocks
  off = 0       # how many of them are false
  if (ARGC != 2 || substr(ARGV[1], 1, 1) != "/") {
    print "brief-render: one absolute template path expected" > "/dev/stderr"
    bad = 1
    exit 2
  }
  file = ARGV[1]
}

{
  line = $0
  lone = 0
  ntags = 0
  while ((i = index(line, "{{")) > 0) {
    emit(substr(line, 1, i - 1))
    rest = substr(line, i + 2)
    kind = substr(rest, 1, 1)
    p = 1
    if (kind == "#" || kind == "/") p = 2; else kind = ""
    n = name_length(rest, p)
    if (n == 0 || substr(rest, p + n, 2) != "}}") fail("`{{` does not open a tag: expected {{name}}, {{#name}} or {{/name}}")
    name = substr(rest, p, n)
    line = substr(rest, p + n + 2)
    ntags++
    declared(name)
    if (kind == "") {
      emit(ENVIRON["OLA_BRIEF_" name])
    } else if (kind == "#") {
      depth++
      names[depth] = name
      lines[depth] = FNR
      kept[depth] = (ENVIRON["OLA_BRIEF_" name] != "")
      if (!kept[depth]) off++
      if (ntags == 1 && i == 1 && line == "") lone = 1
    } else {
      if (depth == 0) fail("{{/" name "}} closes nothing")
      if (names[depth] != name) fail("{{/" name "}} closes {{#" names[depth] "}} (line " lines[depth] ")")
      if (!kept[depth]) off--
      depth--
      if (ntags == 1 && i == 1 && line == "") lone = 1
    }
  }
  emit(line)
  if (off == 0 && !lone) out = out "\n"
}

END {
  if (bad) exit 2
  if (depth > 0) {
    print file ":" lines[depth] ": {{#" names[depth] "}} is never closed" > "/dev/stderr"
    exit 2
  }
  printf "%s", out
}
