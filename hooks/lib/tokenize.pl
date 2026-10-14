#!/usr/bin/env perl
# Splits a shell command line into the simple commands a shell would actually run, and
# names each one's command word.
#
# Reads the command line on stdin, writes one JSON object per line on stdout:
#
#   {"raw": …, "command": …, "resolved": …, "readable": true|false, "reason": …}
#
#   raw        the segment as written, for a message a human reads
#   command    the command word, normalised
#   words      the command word followed by its operands, one array element per word —
#              THE ONLY FIELD A RULE MAY MATCH
#   normalised the same words joined by a space, for a message a human reads
#
# A rule matches `words`, not `normalised`, and the difference is not stylistic. A joined
# string cannot express a position, so `gh pr edit 7 --add-label "ready to merge"` fired a
# rule about `pr … merge`; it cannot hold a literal, so a review status named `c++-review`
# arrived at `grep -E` as a pattern and matched nothing it was meant to; and it cannot be
# case-folded safely, so `-X put` — which `gh` accepts, measured — walked past a rule
# written for `PUT`. Each of those was a false negative or a false positive found in
# review, and all three are unexpressible once a rule reads words.
#   resolved  what the normalisation walked through to get there, for the same message
#   readable  false when the command word cannot be known without running it
#   reason    why, when readable is false
#
# Rules must never match on `raw`. Everything a shell does between the text and the
# command word — quote removal, escapes, wrappers, assignments, redirections — is undone
# here, once, because a rule written as a regex in a project's profile cannot undo any of
# it. That is the defect of the implementation this is ported from: its patterns match the
# text, so `g\h pr merge` and `$(echo gh) pr merge` walk past rules that `gh pr merge`
# trips. Measured, both do.
#
# What stays unreadable is not a failure of this file: a command word assembled by
# expansion, or a body read from a file, is not present in the text at all. Those get
# readable=false and a reason, and the caller is expected to ask rather than to guess —
# refusing them would refuse `$EDITOR file`, allowing them is the hole.
use strict;
use warnings;

my $input = do { local $/; <STDIN> };
$input = '' unless defined $input;

# Line continuations fold before anything else: a command split across lines is one
# command, and the shell has already joined it by the time it runs.
$input =~ s/\\\n//g;

# Heredoc bodies are text, not commands — a pull request body may quote a command without
# running it, and reading the body as code is the false positive this removal exists to
# prevent. The exception is a heredoc fed to a shell (`sh <<EOF`), where the body *is* the
# program. The body is replaced by a marker so that a rule which needs to look at what was
# sent (a review status in a JSON payload, say) can still be given it deliberately.
my @bodies;
$input =~ s{
  ^([^\n]*?)(?<!<)<<(?!<)-?[ \t]*(['"]?)(\w+)\2([^\n]*)\n(.*?)^[ \t]*\3[ \t]*$
}{
  my ($whole, $pre, $post, $body) = ($&, $1, $4, $5);
  if ("$pre$post" =~ m{(?:^|[\s|;&(/])(?:ba|z|da|k)?sh(?:\s|$)}) { $whole }
  else {
    push @bodies, $body;
    "$pre<<HEREDOC_$#bodies $post";
  }
}gsmex;

# ---------------------------------------------------------------------------- escaping
sub json_string {
  my ($s) = @_;
  $s = '' unless defined $s;
  $s =~ s/\\/\\\\/g;
  $s =~ s/"/\\"/g;
  $s =~ s/\n/\\n/g;
  $s =~ s/\r/\\r/g;
  $s =~ s/\t/\\t/g;
  $s =~ s/([\x00-\x1f])/sprintf('\\u%04x', ord($1))/ge;
  return '"' . $s . '"';
}

# ------------------------------------------------------------------- splitting into segments
# Walks the line character by character, because a separator inside quotes is text and a
# quote inside a word is not a separator. Produces one segment per simple command, in the
# order a shell would run them, and recurses into the places a shell runs code from:
# $(…), `…`, <(…), and the argument of `sh -c` or `eval`.
my @segments;

sub closing_paren {
  my ($s, $i) = @_;
  my $depth = 1;
  while ($i < length $s) {
    my $c = substr($s, $i, 1);
    if ($c eq '\\') { $i += 2; next }
    if ($c eq "'") { $i++; $i++ while $i < length($s) && substr($s, $i, 1) ne "'"; $i++; next }
    if ($c eq '"') {
      $i++;
      while ($i < length $s) {
        last if substr($s, $i, 1) eq '"';
        $i += (substr($s, $i, 1) eq '\\') ? 2 : 1;
      }
      $i++; next;
    }
    $depth++ if $c eq '(';
    if ($c eq ')') { $depth--; return $i if $depth == 0 }
    $i++;
  }
  return length($s);
}

sub closing_backtick {
  my ($s, $i) = @_;
  while ($i < length $s) {
    my $c = substr($s, $i, 1);
    return $i if $c eq '`';
    $i += ($c eq '\\') ? 2 : 1;
  }
  return length($s);
}

# A quoted string is code when it is the argument of something that runs code.
# `(?:\s+--)?` after the option: `--` ends options, so `bash -c -- "gh pr merge 7"` runs
# exactly what `bash -c "gh pr merge 7"` runs. Without it the string stayed a string, the
# command word was `bash`, and every rule about the inner command was silently out of
# reach — measured on bash, sh and env alike. `--` is the form an enumeration of option
# spellings always misses, because it is the one that is not an option.
# `env -S` belongs here and not among env's value-taking options: its argument is a
# program, not a value. Consumed as a value it left a segment with no command word at all,
# which this file reports as "nothing to judge" — the answer meant for `c=gh` and `done`,
# handed to a line that runs something.
my $runs_code = qr{(?:^|[\s;&|(])(?:
    (?:(?:ba|z|da|k)?sh|env)(?:\s+-[-a-zA-Z]+)*\s+-[a-zA-Z]*[cS][a-zA-Z]*
  | eval
)(?:\s+--)?\s+\z}x;

sub split_line {
  my ($s) = @_;
  my $cur = '';
  # The same text with every escaped character replaced by a letter, which is what the
  # lookbehinds below must read. They ask "does the segment so far end in a redirection
  # operator", and that is a question about syntax: a `\>` is an argument, not an operator.
  # Asked of `$cur`, which keeps the backslash *and* the `>`, the answer was yes, so
  # `echo \>|gh pr merge 7 --admin` came out as one segment named `echo` and the merge ran —
  # a regression introduced by the fix that taught this splitter about `>|` at all. The
  # sibling `&` lookbehind had the same defect since the beginning (`echo \>& gh …`).
  # A mask rather than a flag, because a lookbehind reads two characters (`>>`), and
  # because the next lookbehind written here gets the right answer without being told.
  my $syn = '';
  my $i = 0;
  # `|` separates commands everywhere except between a `case`'s `in` and the `)` that
  # closes a pattern, where it separates alternatives. The information belongs here, at
  # the cut, rather than in the normaliser downstream: the normaliser could only notice
  # afterwards that the cut had gone through a pattern, and declare the segment unreadable
  # — which cost an ask per multi-pattern arm. One flag, of the same nature as the ones
  # this function already keeps for quotes and parens.
  my $case_pattern = 0;
  my $flush = sub { push @segments, $cur if $cur =~ /\S/; $cur = ''; $syn = '' };

  while ($i < length $s) {
    my $c = substr($s, $i, 1);

    # The escaped character goes into $cur as written and into $syn as a blank: it is a
    # literal, and no lookbehind may take it for punctuation.
    if ($c eq '\\') {
      my $pair = substr($s, $i, 2);
      $cur .= $pair;
      # A letter, not a blank: blanking it would make `echo a\ #b` look like a word boundary
      # followed by a comment, and the comment branch drops the rest of the line — which
      # would have hidden `echo a\ #b; gh pr merge 7 --admin` from the splitter entirely.
      # `x` is in none of the patterns below, so it can spell nothing.
      $syn .= 'x' x length $pair;
      $i += 2; next;
    }

    if ($c eq "'") {
      my $j = index($s, "'", $i + 1);
      $j = length($s) if $j < 0;
      my $body = substr($s, $i + 1, $j - $i - 1);
      if ($syn =~ $runs_code) { split_line($body); $cur .= '""'; $syn .= '""' }
      else { $cur .= substr($s, $i, $j - $i + 1); $syn .= substr($s, $i, $j - $i + 1) }
      $i = $j + 1; next;
    }

    if ($c eq '"') {
      my $str = '';
      $i++;
      while ($i < length $s) {
        my $d = substr($s, $i, 1);
        last if $d eq '"';
        if ($d eq '\\') { $str .= substr($s, $i, 2); $i += 2; next }
        if ($d eq '$' && substr($s, $i + 1, 1) eq '(') {
          my $e = closing_paren($s, $i + 2);
          split_line(substr($s, $i + 2, $e - $i - 2));
          $str .= '$()'; $i = $e + 1; next;
        }
        if ($d eq '`') {
          my $e = closing_backtick($s, $i + 1);
          split_line(substr($s, $i + 1, $e - $i - 1));
          $str .= '$()'; $i = $e + 1; next;
        }
        $str .= $d; $i++;
      }
      $i++;
      if ($syn =~ $runs_code) { split_line($str); $cur .= '""'; $syn .= '""' }
      else { $cur .= '"' . $str . '"'; $syn .= '"' . $str . '"' }
      next;
    }

    if ($c eq '$' && substr($s, $i + 1, 1) eq '(') {
      my $e = closing_paren($s, $i + 2);
      split_line(substr($s, $i + 2, $e - $i - 2));
      $cur .= '$()'; $syn .= '$()'; $i = $e + 1; next;
    }
    if (($c eq '<' || $c eq '>') && substr($s, $i + 1, 1) eq '(') {
      my $e = closing_paren($s, $i + 2);
      split_line(substr($s, $i + 2, $e - $i - 2));
      $cur .= $c . '()'; $syn .= $c . '()'; $i = $e + 1; next;
    }
    if ($c eq '`') {
      my $e = closing_backtick($s, $i + 1);
      split_line(substr($s, $i + 1, $e - $i - 1));
      $cur .= '$()'; $syn .= '$()'; $i = $e + 1; next;
    }

    # A # starts a comment only at the beginning of a word.
    if ($c eq '#' && ($syn eq '' || $syn =~ /\s\z/)) {
      $i++ while $i < length($s) && substr($s, $i, 1) ne "\n";
      next;
    }

    # `>&` and `&>` are redirections, not separators.
    if ($c eq '&' && ($syn =~ /[<>]\z/ || substr($s, $i + 1, 1) eq '>')) { $cur .= $c; $syn .= $c; $i++; next }

    # Entering a case pattern: after `in`, up to the `)` that closes it.
    if (!$case_pattern && $syn =~ /(?:^|[\s;])case\s[^)]*\sin\s*\z/) { $case_pattern = 1 }
    if ($case_pattern) {
      if ($c eq '|') { $cur .= $c; $syn .= $c; $i++; next }   # an alternative, not a pipeline
      $case_pattern = 0 if $c eq ')';
    }
    # `>|` is one operator, not a redirection followed by a pipe. Cutting there left the
    # first segment as a bare `>` and the second as `out gh pr merge 7 --admin`, whose
    # command word is `out` — so the merge rule, which asks whether the command is `gh`, was
    # never consulted. `>| out …` and the glued `>|out …` both ran it.
    if ($c eq '|' && $syn =~ />\z/ && $syn !~ />>\z/) { $cur .= $c; $syn .= $c; $i++; next }
    if ($c =~ /[;&|\n]/) { $flush->(); $i++; next }

    $cur .= $c; $syn .= $c; $i++;
  }
  $flush->();
}

# --------------------------------------------------------- the command word of a segment
# Reserved words and separators that a shell allows in front of a command, which a split on
# `;` leaves at the head of a segment: `for i in 1; do gh …` becomes `do gh …`.
# Every reserved word bash defines, plus the braces and the `!` negation. Without `if`
# and `while` here the first segment of `if true; then …` reports `if` as its command,
# when the command is `true`.
# `time` is deliberately **not** here, though bash calls it a reserved word: it was, and it
# was also a wrapper, and the reserved branch runs first — so `time` was eaten as punctuation
# and `-p` became the command word, readable, allowed. `time -p gh pr merge 7 --admin` ran.
# A word that takes a command after it is a wrapper whatever the grammar calls it, and the
# wrapper branch has the two tables that read its options.
my %reserved = map { $_ => 1 }
  qw(if then elif else fi for while until do done case esac in select function
     coproc ! { } [[ ]]);

# Wrappers whose own arguments are a command. The shell runs the wrapper AND the command,
# so a rule has to see the inner one.
# The set, not an arity: an arity gets the order wrong, because a wrapper's operand follows
# its option — `nice -n 10 gh …` has the 10 after the -n, so skipping "one operand" lands
# on 10 and calls it the command. Measured, that is exactly what happened.
my %wrapper = map { $_ => 1 } qw(
  exec command builtin nohup sudo doas time env nice ionice timeout stdbuf xargs setsid
);

# Which of a wrapper's options take a value, because getting that wrong is the dangerous
# direction: land on an option's value and call it the command, and the rule that should
# have matched does not — a false negative, silently. `sudo -u x gh pr merge` gave `x`
# until this table existed. An option this table does not know makes the segment
# unreadable rather than guessed, which costs an ask and never a miss.
# Both spellings of each option, because a table of short forms is a table that is right
# half the time: `sudo -u postgres psql` read as `psql` while `sudo --user postgres psql`
# — the same command, the long spelling — was declared unreadable and cost an ask. Measured,
# and it is the commoner spelling in anything written to be read.
my %value_opts = (
  sudo    => qr/^(?:-(?:u|g|p|C|h|r|t|U)|--(?:user|group|prompt|close-from|host|role|type|other-user))$/,
  doas    => qr/^(?:-(?:u|C))$/,
  nice    => qr/^(?:-n|--adjustment)$/,
  ionice  => qr/^(?:-(?:c|n|p|P|u)|--(?:class|classdata|pid|pgid|uid))$/,
  timeout => qr/^(?:-(?:s|k)|--(?:signal|kill-after))$/,
  env     => qr/^(?:-(?:u|C)|--(?:unset|chdir))$/,
  stdbuf  => qr/^(?:-(?:i|o|e)|--(?:input|output|error))$/,
  xargs   => qr/^(?:-(?:I|i|L|n|P|s|d|E|a)|--(?:replace|max-lines|max-args|max-procs|max-chars|delimiter|eof|arg-file))$/,
  exec    => qr/^(?:-a)$/,
  time    => qr/^(?:-(?:f|o)|--(?:format|output))$/,
);

# And which take none. The two tables together are the point: an option in neither makes
# the segment unreadable, because *assuming* an unknown option is boolean is how
# `exec -a innocent gh pr merge` came to be named `innocent` — the same defect as
# `sudo -u x`, returning through the fallback instead of through a missing row. The safe
# default for an unknown option is an admission, never a guess.
my %bool_opts = (
  sudo    => qr/^(?:-(?:A|b|E|H|i|k|K|l|n|P|S|s|V|v)|--(?:askpass|background|preserve-env|set-home|login|reset-timestamp|remove-timestamp|list|non-interactive|preserve-groups|stdin|shell|version|validate))$/,
  doas    => qr/^(?:-(?:L|n|s))$/,
  nice    => qr/^$/,
  ionice  => qr/^(?:-t|--ignore)$/,
  timeout => qr/^(?:-v|--(?:foreground|preserve-status|verbose))$/,
  # -S is boolean *here* because its value has already been taken out: the splitter
  # recognises it as running a program, parses it as its own segment, and leaves `""`
  # behind. Judged where it runs, not twice — and not asked about, which is what happens to
  # an option neither table knows.
  env     => qr/^(?:-(?:i|0|v|S)|--(?:ignore-environment|null|debug|split-string))$/,
  stdbuf  => qr/^$/,
  xargs   => qr/^(?:-(?:0|p|r|t|x)|--(?:null|interactive|no-run-if-empty|verbose|exit))$/,
  exec    => qr/^-(?:c|l)$/,
  time    => qr/^(?:-(?:p|v|a|q)|--(?:verbose|append|quiet|portability))$/,
  command => qr/^-(?:p|v|V)$/,
  nohup   => qr/^$/,
  setsid  => qr/^(?:-(?:c|f|w)|--(?:ctty|fork|wait))$/,
  builtin => qr/^$/,
);

# Builtins that run code the text does not contain.
my %indirect = map { $_ => 1 } qw(eval . source trap);

sub ansi_c {
  my ($s) = @_;
  $s =~ s/\\x([0-9a-fA-F]{1,2})/chr(hex($1))/ge;
  $s =~ s/\\([0-7]{1,3})/chr(oct($1))/ge;
  $s =~ s/\\n/\n/g; $s =~ s/\\t/\t/g; $s =~ s/\\\\/\\/g;
  return $s;
}

# Removes what quoting adds, so that g\h, "gh", 'gh', g"h" and $'\x67h' all become gh.
sub unquote {
  my ($w) = @_;
  my $out = '';
  my $i = 0;
  while ($i < length $w) {
    my $c = substr($w, $i, 1);
    if ($c eq '\\') { $out .= substr($w, $i + 1, 1); $i += 2; next }
    if ($c eq '$' && substr($w, $i + 1, 1) eq "'") {
      my $j = index($w, "'", $i + 2);
      $j = length($w) if $j < 0;
      $out .= ansi_c(substr($w, $i + 2, $j - $i - 2));
      $i = $j + 1; next;
    }
    if ($c eq '$' && substr($w, $i + 1, 1) eq '"') { $i++; next }
    if ($c eq "'") {
      my $j = index($w, "'", $i + 1);
      $j = length($w) if $j < 0;
      $out .= substr($w, $i + 1, $j - $i - 1);
      $i = $j + 1; next;
    }
    if ($c eq '"') {
      my $j = $i + 1;
      while ($j < length($w) && substr($w, $j, 1) ne '"') { $j += (substr($w, $j, 1) eq '\\') ? 2 : 1 }
      $out .= substr($w, $i + 1, $j - $i - 1);
      $i = $j + 1; next;
    }
    $out .= $c; $i++;
  }
  return $out;
}

# ------------------------------------------------------- bash's redirection operators
# One definition, read by the three places that need it: the word splitter below, the
# prefix branch of the walk, and the operand filter. It was written out in one of them
# only, and the other two then disagreed with it — which is how an operator glued to the
# command word stayed invisible while the prefix form was refused.
# Longest first, so the alternation cannot match a prefix of a longer operator (`>` where
# `>>` was written, `&>` where `&>>` was). Twelve, which is bash's list and not a memory of
# it: the first attempt at a list held seven.
my $redir_op = qr/&>>|<<<|<<-|<<|>>|>\||<>|<&|>&|&>|>|</;
# What bash lets precede an operator *inside the same word*: a file descriptor number, or
# a `{name}` to be assigned one. Anything else before an operator is a word of its own —
# that is the whole content of the rule below.
my $redir_fd = qr/[0-9]*|\{[A-Za-z_][A-Za-z0-9_]*\}/;
# And what is **not** one, though it starts the same way: `<(…)` and `>(…)` are process
# substitution. Bash expands them to a `/dev/fd/63` path and hands that over as a *word* —
# measured — so a reader that takes them for a redirection drops an argument the command
# really receives. The splitter has already hollowed the body out, so what arrives below is
# `<()`; dropping it took the value away from the option carrying it, and
# `gh api -X POST …/statuses/abc --input <(echo x)` lost its `--input` value. The rule that
# asks about a payload this text does not contain then never fired, and a developer could
# write the commit status the merge gate reads.
my $proc_subst = qr/^(?:$redir_fd)[<>]\(/;

sub words {
  my ($s) = @_;
  my @w;
  my $cur = '';
  # How many `(` the current word has left open, so that a `)` closing one of them belongs
  # to the word — `$()` and `f()` are each a single word — while a `)` closing nothing ends
  # it, which is what bash does with an unquoted metacharacter.
  my $par = 0;
  my $i = 0;
  my $flush = sub { push @w, $cur if length $cur; $cur = ''; $par = 0 };
  while ($i < length $s) {
    my $c = substr($s, $i, 1);
    if ($c eq '\\') { $cur .= substr($s, $i, 2); $i += 2; next }
    if ($c eq "'" || $c eq '"') {
      my $q = $c;
      my $j = $i + 1;
      while ($j < length($s) && substr($s, $j, 1) ne $q) { $j += ($q eq '"' && substr($s, $j, 1) eq '\\') ? 2 : 1 }
      $cur .= substr($s, $i, $j - $i + 1);
      $i = $j + 1; next;
    }
    if ($c =~ /\s/) { $flush->(); $i++; next }
    # A blank is not the only thing that ends a word: bash ends one at an unquoted
    # redirection operator too. `gh>out pr merge 7 --admin` is the command `gh` with its
    # output redirected, and it really merges — but the whole text `gh>out` arrived here as
    # one word, so the rule that asks whether the command is `gh` was never consulted. The
    # prefix placement (`>out gh pr merge`) was handled and the glued one was not, which is
    # an enumeration of *placements* behind a list of operators that had just stopped being
    # one. Every operator, in both placements, from here on.
    # Not when what precedes the operator is empty, a file descriptor number or a `{name}`:
    # those belong to the operator (`2>out`, `{fd}>out`) and splitting them would leave a
    # word `2`, which the walk would then name as the command.
    # The whole operator at once, never one character at a time: tested per character,
    # `gh&>out` cut twice — before the `&` and again before the `>` — and left a word `&`
    # of its own in the operand list, where it took the position `pr` should have had.
    # Process substitution is not a redirection, and this reader has to know that as much as
    # the two below do: `$proc_subst` was added to them and not here, so a `<` still ended a
    # word — `--input=<(echo x)` came out as `--input=` plus `<()`, the option's value read
    # empty, and the rule that asks about a payload this text does not contain went quiet
    # again. One spelling over from the finding it was fixing, because the fix was applied to
    # the readers that had shown the symptom instead of to every reader of the construct.
    if ($c =~ /[<>]/ && substr($s, $i + 1, 1) eq '(') { $cur .= $c; $i++; next }
    if ($c =~ /[<>&]/ && substr($s, $i) =~ /^($redir_op)/) {
      my $op = $1;
      $flush->() if length $cur && $cur !~ /^(?:$redir_fd)\z/;
      $cur .= $op; $i += length $op; next;
    }
    # A paren is a metacharacter too, and the word splitter did not know it. Sixteen command
    # lines were allowed in silence because of that: `coproc CO(gh pr merge 7 --admin)`,
    # `!(…)`, `time(…)`, `if(…)`, `while(…)`, `until(…)`, `do(…)`, `{(…)` and four
    # `case x in x)gh …` forms. Each really runs the merge — measured — and each arrived as a
    # command word like `CO(gh` or `x)gh`, which no rule names. The branches above were
    # already written for the constructs they belong to; what was missing is that the shell
    # ends a word there, so the construct and its command never arrived separately.
    #
    # Two exceptions, each a real construct where the paren belongs to the word: `=(` is an
    # array assignment, and a `(` immediately followed by `)` is a function header — which
    # also covers `$()`, `<()` and `>()`, because the splitter has already hollowed their
    # bodies out before this reader sees them. A third exception for `$(` was written here
    # and is dead: removing it moves no word and no decision, measured, because `()` already
    # answers it. A condition that names three exceptions where two are reachable reads as
    # if all three were load-bearing.
    if ($c eq '(') {
      $flush->() if length $cur && $cur !~ /=\z/ && substr($s, $i + 1, 1) ne ')';
      $cur .= $c; $par++; $i++; next;
    }
    # The `)` stays with the word it closes and the word ends **after** it, rather than the
    # `)` becoming a word of its own. Every branch downstream recognises a label or a
    # subshell by a word *ending* in `)`, and handing them a lone `)` would have broken all
    # of them at once — `a) gh pr merge 7 --admin`, the second arm of a case, named `a`.
    if ($c eq ')') {
      $cur .= $c; $i++;
      if ($par > 0) {
        $par--;
        # A `)` that closes a paren opened at the **start** of this word closes a case
        # pattern written with its optional leading paren — `case x in (x)gh pr merge 7
        # --admin`, which bash accepts and which ran the merge while being read as nothing at
        # all. The same `)` inside `$()`, `f()` or `<()` closes a paren that is not at the
        # start of its word, and those stay whole.
        $flush->() if $cur =~ /^\(/;
      } else {
        $flush->();
      }
      next;
    }
    $cur .= $c; $i++;
  }
  $flush->();
  return @w;
}

# operands <the words after the command word>
# A redirection is not an argument, wherever it sits. The shell takes it out of the
# command's words before running it — `gh pr merge 7 < x --admin` really runs
# `gh pr merge 7 --admin` — so a rule that reads positions has to see what the shell sees.
# Without this, splitting a word at its operator (above) traded one defect for another:
# `gh>out pr merge 7 --admin` became `gh` plus the operands `>out pr merge 7 --admin`, and
# the subcommand path read `>out pr merge 7`, which matches no rule about `pr merge`.
# The target too, when the operator ends the word and the filename is the next one; `2>&1`
# ends in its own target and takes nothing after it, which is why the test is whether the
# operator ends the word and not how many words a redirection has.
#
# Stated limit: a redirection is therefore absent from `words`, so no rule can be written
# about where output goes. Nothing needs one today. The day one does, it needs a field of
# its own, not a reading of `raw` — `raw` is the text, and matching the text is what this
# whole file exists to replace.
sub operands {
  my (@w) = @_;
  my @out;
  while (@w) {
    my $w = shift @w;
    if ($w !~ $proc_subst && $w =~ /^(?:$redir_fd)(?:$redir_op)(.*)$/) {
      shift @w if $1 eq '' && @w;    # the target, when it is its own word
      next;
    }
    push @out, $w;
  }
  return @out;
}

# The segment with every word unquoted and the command word in place of whatever spelled
# it. This is what a rule matches, and it must never be the raw text: a rule written as a
# regex in a project's profile cannot undo quoting, so `gh pr "merge"` would walk past a
# pattern that `gh pr merge` trips. Measured — it does.
# Options whose value is a message a human wrote, and commands whose arguments are text
# rather than code. Their contents are emptied here, because a rule matching the whole
# segment would otherwise fire on a pull request comment that merely *mentions* a command:
# `gh pr comment -b "a; gh pr merge"` normalised to `gh pr comment -b a; gh pr merge`, and
# a rule about merging matched it. This is the one stage of the port whose purpose is to
# prevent a false positive rather than to close an evasion — and a guard that refuses a
# comment for quoting a command is a guard whose refusals stop being read.
# Only options whose value is prose a human wrote. `-F`/`--field` were here and had to go:
# in `gh api` they carry `state=success`, which is precisely what the rule protecting the
# review status has to read, and in `gh pr create` they carry a file path. Neither is prose,
# and emptying them meant one file of this plugin blanked the very word the other asked a
# rule to match. The lesson is the one this file keeps relearning: an option's meaning
# belongs to its command, so a table of spellings shared across commands may hold only
# spellings that mean the same thing everywhere.
my $text_option = qr/^(?:-m|--message|-b|--body|--body-file|-t|--title|--notes)$/;
my %text_command = map { $_ => 1 } qw(echo printf grep egrep fgrep rg awk gawk sed);

# normalise_segment <command word> <operand words>
# The operands are handed over by the walk, never recomputed from the segment. They used to
# be recovered by counting the words of the *rendered* `resolved` string and splicing that
# many off the front — and that count is not the number of input words consumed: the walk
# renders `(gh` as two words `( gh`, so one word too many was dropped and `(gh pr merge 7)`
# normalised to `gh merge 7`, with the `pr` a merge rule matches on simply gone. Counting a
# display string to recover a position is the defect; being given the position is the fix.
# Returns the words: the command word, then its operands, each with quoting removed and
# prose emptied. `normalise_segment` joins them for display; a rule reads the list.
sub segment_words {
  my ($cmd, $operands) = @_;
  my @w = @{ $operands // [] };

  # A subshell's or case arm's closing parens stick to the last word, so
  # `(gh pr merge 7 --admin)` ends in `--admin)` and every rule anchored on a word boundary
  # walks straight past it. What marks punctuation is that the paren is *unbalanced*: bash
  # refuses an unquoted `)` inside an argument outright (`echo a)` is a syntax error), while
  # the `)` of a `$(…)` is balanced inside its own word. So the test is the balance, not a
  # count of parens the walk happened to open — that count belongs to the whole command line
  # and `(cd x && gh pr merge --admin)` puts the opening paren in a different segment from
  # the closing one.
  # A loop over the words and not over one word: `((gh pr merge 7 --admin))` now ends in two
  # of them, `--admin)` and `)`, because the word splitter ends a word after a `)` that
  # closes nothing. Stripping only the last left the `--admin)` behind, with its paren, for
  # every rule anchored on a word boundary to walk past.
  while (@w && $w[-1] !~ /["'\\]/) {
    my $last = $w[-1];
    last unless $last =~ /\)$/ && ($last =~ tr/)//) > ($last =~ tr/(//);
    chop $last;
    if (length $last) { $w[-1] = $last } else { pop @w }
  }

  my @out = (length $cmd ? ($cmd) : ());
  my $all_text = (length $cmd && $text_command{$cmd}) ? 1 : 0;
  my $next_is_text = 0;
  for my $word (@w) {
    if ($next_is_text) { push @out, "''"; $next_is_text = 0; next }
    if ($all_text && $word !~ /^-/) { push @out, "''"; next }
    my $bare = unquote($word);
    push @out, $bare;
    $next_is_text = 1 if $bare =~ $text_option;
  }
  return @out;
}

sub normalise_segment { return join(' ', segment_words(@_)) }

sub json_array {
  my (@w) = @_;
  return '[' . join(',', map { json_string($_) } @w) . ']';
}

sub command_word {
  my ($segment) = @_;
  my @w = words($segment);
  my @walked;
  my $in_case = 0;
  my $after_function = 0;

  while (@w) {
    my $w = $w[0];

    # A case arm's pattern label. Bounded to a segment that opened a `case`, because a
    # word ending in `)` is also what `$()` looks like, and that one must stay visible as
    # an unreadable command word rather than be skipped as punctuation.
    if ($in_case) {
      push @walked, $w; shift @w;
      # The subject, `in`, and the pattern are all punctuation here. The arm's command
      # starts after the label — and a label is a word ending in `)` that holds no
      # expansion, because `$()` ends in `)` too and must stay visible as unreadable.
      $in_case = 0 if $w =~ /\)$/ && $w !~ /[\$`]/;
      next;
    }

    # Reserved words and the heads of compound statements.
    if ($reserved{$w}) {
      # `[[` opens a conditional expression, and what follows is not a command word at all:
      # `[[ -f x ]]` runs nothing. Walking past it left `-f` as the command word, which the
      # dash net then asked about — a question about the shell's own grammar, which is the
      # same defect `[` had and the same answer: nothing to judge.
      if ($w eq '[[') {
        return ('', join(' ', @walked, @w), undef, [], 0);
      }
      # `coproc NAME { … }` names the coprocess before the command, and that name read as
      # the command word: `coproc CO { gh pr merge 7 --admin; }` was allowed, named `CO`.
      # `coproc` without a name was already right, which is why only one of the two forms
      # was ever tested. The name is punctuation here, like a function header is.
      # Any **compound command**, which is what bash actually allows after the name — not
      # just a brace, and not just a brace or a paren. Its grammar lists `( )`, `{ }`,
      # `(( ))`, `[[ ]]`, `if`, `case`, `while`, `until`, `for` and `select`, and
      # `coproc CO if …`, `while`, `until`, `case` all ran the inner command while being read
      # as `CO`. Two spellings were closed in two releases before the set was looked up.
      if ($w eq 'coproc' && @w > 1
          && $w[1] =~ /^[A-Za-z_][A-Za-z0-9_]*$/
          && @w > 2
          && ($w[2] =~ /^[({]/ || $w[2] =~ /^\[\[$/
              || $w[2] =~ /^(?:if|case|while|until|for|select)$/)) {
        push @walked, shift @w;      # coproc
        push @walked, shift @w;      # the name
        next;
      }
      $in_case = 1 if $w eq 'case';
      $after_function = 1 if $w eq 'function';
      push @walked, $w; shift @w; next;
    }
    # A function definition header, derived from the construct rather than listed by
    # spelling. Listing was wrong three times — `f(){`, `function f`, then `f ()` with a
    # blank, which POSIX allows — and listing spellings is the method that always misses
    # one. The construct is: a valid name, then `()`, whatever blanks sit between them. So
    # the two words are joined before the test, and one pattern covers every writing,
    # including the one nobody has used yet.
    if ($w =~ /^[A-Za-z_][A-Za-z0-9_]*$/ && @w > 1 && $w[1] =~ /^\(\)/) {
      push @walked, shift @w;                 # the name
      $w[0] =~ s/^\(\)//;                     # and the parens, keeping anything glued after
      shift @w unless length $w[0];
      $after_function = 0;
      next;
    }
    if ($w =~ /^[A-Za-z_][A-Za-z0-9_]*\(\)/) {
      # Clearing the flag matters: `function f() { gh …` has both spellings at once, and
      # leaving it set made the flag swallow `gh` and name the command `pr`.
      $after_function = 0;
      my $rest = $w;
      $rest =~ s/^[A-Za-z_][A-Za-z0-9_]*\(\)//;
      push @walked, $w;
      if (length $rest) { $w[0] = $rest } else { shift @w }
      next;
    }
    if ($after_function) { push @walked, $w; shift @w; $after_function = 0; next }
    # An assignment in front of a command: FOO=1 gh …
    if ($w =~ /^[A-Za-z_][A-Za-z0-9_]*=/) { push @walked, $w; shift @w; next }
    # A redirection in front of a command: `2>/dev/null gh …`.
    #
    # And its target, when a blank separates the two. `2> /dev/null gh pr merge 7 --admin`
    # was **allowed** — one space from the glued form, which is refused — because skipping
    # one word left `/dev/null` as the command word, so the merge rule, which asks whether
    # the command is `gh`, was never consulted. Thirteen spellings did it: `> out`, `1> out`,
    # `2> /dev/null`, `>> out`, `&> out`, `>& out`, `< /dev/null`, `0< /dev/null`,
    # `{fd}> out`, `{fd}>> out`, `2>&1 > out`, `FOO=1 > out`, `<<< x`. All measured, all
    # really run the inner command.
    #
    # What decides is whether the operator **ends** the word: `2>` takes the next word,
    # `2>&1` does not and must keep being skipped alone — it was already right, and a fix
    # that broke it would trade one escape for another.
    # The operators come from `$redir_op`, defined once above and read by the three places
    # that need them. What 0.3.1 shipped here was a character class — an optional file
    # descriptor then `<` or `>` — and it missed `&>` and `&>>` entirely, because they begin
    # with neither: the operator itself became the command word, and `&> out gh pr merge 7
    # --admin` ran. The first fix replaced the class with a list of seven, which is how five
    # of bash's twelve came to be absent for the length of one commit; review caught that
    # before it shipped. A list written inline is the shape this file keeps paying for, so
    # there is one definition and its three readers share it.
    if ($w !~ $proc_subst && $w =~ /^(?:$redir_fd)(?:$redir_op)(.*)$/) {
      my $rest = $1;
      push @walked, $w; shift @w;
      push @walked, shift @w if $rest eq '' && @w;   # the target, when it is its own word
      next;
    }

    # A subshell's opening paren sticks to the word: `(gh pr merge)` would otherwise name
    # the command `(gh`, which matches no rule.
    if ($w =~ /^\(+/) {
      my $stripped = $w;
      $stripped =~ s/^\(+//;
      push @walked, '(';
      if (length $stripped) { $w[0] = $stripped; $w = $stripped }
      else { shift @w; next }
    }

    my $bare = unquote($w);
    my $name = $bare;
    $name =~ s{.*/}{};   # a path reduces to its basename

    if ($indirect{$name}) {
      return ($name, join(' ', @walked, $w),
              "the command it runs is not in this text ($name)",
              [operands(@w[1 .. $#w])]);
    }
    if ($wrapper{$name}) {
      # A help or version request performs nothing, whatever it asks about, so the segment
      # runs no command rather than being unreadable. Without this, `env --help`,
      # `sudo --help` and eleven more asked the human to confirm a command that prints a page
      # and exits — and the reason given was "whether it takes a value is unknown here",
      # which is not what is happening. `env --help` runs exactly what its text says, so the
      # design's own justification for asking did not cover it: it was a table gap wearing
      # the costume of a design cost.
      # Noticed **inside** the walk below, never by a scan of its own. A separate scan over
      # the leading run of dashes does not know which of them take a value, so a `-h` that is
      # an option's *value* read as a help request and the segment reported no command at
      # all: `env -u -h gh pr merge 7 --admin` was allowed, one word from
      # `env -u FOO gh pr merge 7 --admin`, which is refused. Measured, and the inner command
      # really runs — `env -u -h`, `exec -a -h`, `xargs -E -h`, `sudo -p -h` all do.
      #
      # It shipped that way in 0.3.0. The defect is the second reader: the walk below already
      # knows which options take values, and asking the same question twice in two places is
      # how the two came to disagree. So the flag is set where the walk classifies the word,
      # and only there.
      push @walked, $w;
      shift @w;
      # Skip what belongs to the wrapper rather than to the command: its options, the
      # values those options take, and the assignments `env` exists to set. A bare number
      # or duration is the shape every one of these takes as an operand (`nice -n 10`,
      # `timeout 5`, `timeout 5s`), and no command is named that.
      my $takes_value = $value_opts{$name};
      while (@w) {
        if ($w[0] =~ /^[A-Za-z_][A-Za-z0-9_]*=/                     # env FOO=1
            || $w[0] =~ /^[0-9]+(?:\.[0-9]+)?[smhd]?$/) {           # timeout 5, nice's 10
          push @walked, shift @w; next;
        }
        last unless $w[0] =~ /^-/;
        if ($takes_value && $w[0] =~ $takes_value) {
          push @walked, shift @w;                                   # the option
          push @walked, shift @w if @w;                             # and its value
          next;
        }
        # An option carrying its own value needs nothing after it — `--opt=value`, and the
        # short forms where the value is glued to the letter. These are the standard
        # spellings (`nice -n5`, `stdbuf -oL`, `xargs -n1`, `sudo -ux`, `timeout -s9`), and
        # sending them all to unreadable was safe but would have spent a question on each.
        # The value is inside the word rather than after it, so nothing is guessed.
        if ($w[0] =~ /^--?[A-Za-z0-9-]+=/) { push @walked, shift @w; next }
        if ($takes_value && $w[0] =~ /^-([A-Za-z]).+$/ && "-$1" =~ $takes_value) {
          push @walked, shift @w; next;
        }
        # `nice -5` and `ionice -5` are a priority, not an unknown option.
        if (($name eq 'nice' || $name eq 'ionice') && $w[0] =~ /^-[0-9]+$/) {
          push @walked, shift @w; next;
        }
        # A help or version request performs nothing, whatever it asks about, so the segment
        # runs no command rather than being unreadable. Without this, `env --help`,
        # `sudo --help` and eleven more asked the human to confirm a command that prints a
        # page and exits — and the reason given was "whether it takes a value is unknown
        # here", which is not what is happening. `env --help` runs exactly what its text
        # says, so the design's own justification for asking did not cover it: a table gap
        # wearing the costume of a design cost.
        #
        # Here, after the value-taking options have been consumed, so a `-h` that is a value
        # has already been skipped as one and never reaches this test.
        if ($w[0] =~ /^(?:--help|--usage|--version|-h|-V)$/) {
          return ('', join(' ', @walked, @w), undef, [], 0);
        }
        # A known boolean takes nothing.
        my $boolean = $bool_opts{$name};
        if ($boolean && $w[0] =~ $boolean) { push @walked, shift @w; next }
        return ($name, join(' ', @walked, @w),
                "$name is given the option $w[0], and whether it takes a value is unknown here",
                [operands(@w[1 .. $#w])]);
      }
      next;
    }

    # A word made only of closing parens runs nothing — it is punctuation the split left
    # behind. `for ((i=0;i<1;i++)); do gh pr merge 7 --admin; done` cuts on the `;` inside the
    # arithmetic head, and the third piece, `i++))`, is two words now that a word ends after a
    # `)` that closes nothing: `i++)` is skipped as a label and the bare `)` was then reported
    # unreadable, which asks — and `decide` stops at the first ask, so the merge rule below
    # was never reached on a line that really merges. It also asked about
    # `for ((i=0;i<3;i++)); do echo $i; done`, which is ordinary work.
    if ($bare =~ /^\)+$/) { push @walked, $w; shift @w; next }

    # A `pattern)` label at the head of a segment is the second and later arms of a case:
    # `;;` ends an arm, the split cuts there, and the next segment opens with the label.
    # Skipping it recovers the arm's command. It must hold no expansion, because `$()`
    # also ends in `)` and has to stay visible as an unreadable command word.
    if (!@walked && $bare =~ /\)$/ && $bare !~ /[\$`]/) {
      push @walked, $w; shift @w; next;
    }
    # A label anywhere else means the split cut inside something this splitter does not
    # parse. The implementation this is ported from survives such cases by matching the
    # segment's text, which is robustness by accident; normalising the command word is
    # more precise and loses exactly this, so the loss is declared rather than silent.
    if ($bare =~ /\)$/ && $bare !~ /[\$`]/) {
      return ($name, join(' ', @walked, $w),
              'this looks like a case arm or a subshell, and the split cut inside it',
              [operands(@w[1 .. $#w])]);
    }

    # A command word cannot hold a blank. The shell would look for a file literally named
    # `gh pr merge 7`, which is not what the writer meant and not what runs — so a word
    # like that is always a program string this file failed to recognise as one. Declaring
    # it unreadable is the net under the whole family: `env -u X -S "gh pr merge 7"` put
    # the operand `X` between the options and walked past the pattern that spots a program,
    # and the next spelling to do that is covered too, without having been listed. The
    # alternative was a silent allow, since no rule matches a command named `gh pr merge 7`.
    if ($bare =~ /\s/) {
      return ($name, join(' ', @walked, $w),
              'this holds a whole command line where a command word goes, so what runs is a program this text quotes rather than a command',
              [operands(@w[1 .. $#w])]);
    }
    # And it cannot begin with a dash. The shell would look for a file named `-p`, so a word
    # like that is always an option some prefix should have consumed and did not — the net
    # under the whole family, of which `time -p` was one member and the next grammar word to
    # be mishandled will be another. A silent allow is what this replaces: `-p` was a
    # perfectly readable command word that no rule names.
    if ($bare =~ /^-/) {
      return ($name, join(' ', @walked, $w),
              'an option sits where the command word should be, so some prefix was not read correctly and what runs cannot be named',
              [operands(@w[1 .. $#w])]);
    }

    # Everything the shell would still expand before this becomes a command word.
    my $why;
    $why = 'a parameter or command substitution' if $bare =~ /\$/;
    $why = 'a brace expansion'                   if !$why && $bare =~ /\{[^}]*,/;
    # A bracket expression has to close to be one. `[` on its own is the POSIX test
    # builtin and bash runs it as a command word — `[ -f x ]` was answered `ask`, about a
    # builtin, which spends the human's attention on the shell's own grammar. The test is
    # the construct (does this word glob?), not the character.
    $why = 'a pathname pattern'                  if !$why && $bare =~ /[*?]|\[[^]]*\]/;
    return ($name, join(' ', @walked, $w), "the command word is built by $why",
            [operands(@w[1 .. $#w])])
      if $why;

    return ($name, join(' ', @walked, $w), undef, [operands(@w[1 .. $#w])]);
  }
  # Nothing left after the prefixes: this segment runs no command at all — a bare
  # assignment, a closing brace, a `done`. That is not something unreadable, it is nothing
  # to judge, and calling it unreadable would spend an ask on `c=gh`.
  return ('', join(' ', @walked), undef, []);
}

# ------------------------------------------------------------------------------- output
split_line($input);
for my $seg (@segments) {
  my ($cmd, $resolved, $reason, $operands) = command_word($seg);
  my $trimmed = $seg;
  $trimmed =~ s/^\s+|\s+$//g;
  my @words = segment_words($cmd, $operands);
  my $normalised = join(' ', @words);
  printf "{\"raw\":%s,\"command\":%s,\"words\":%s,\"normalised\":%s,\"resolved\":%s,\"readable\":%s,\"reason\":%s}\n",
    json_string($trimmed), json_string($cmd), json_array(@words), json_string($normalised), json_string($resolved),
    (defined $reason ? 'false' : 'true'),
    (defined $reason ? json_string($reason) : 'null');
}
