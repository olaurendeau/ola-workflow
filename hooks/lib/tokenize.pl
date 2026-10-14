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
  my $i = 0;
  # `|` separates commands everywhere except between a `case`'s `in` and the `)` that
  # closes a pattern, where it separates alternatives. The information belongs here, at
  # the cut, rather than in the normaliser downstream: the normaliser could only notice
  # afterwards that the cut had gone through a pattern, and declare the segment unreadable
  # — which cost an ask per multi-pattern arm. One flag, of the same nature as the ones
  # this function already keeps for quotes and parens.
  my $case_pattern = 0;
  my $flush = sub { push @segments, $cur if $cur =~ /\S/; $cur = '' };

  while ($i < length $s) {
    my $c = substr($s, $i, 1);

    if ($c eq '\\') { $cur .= substr($s, $i, 2); $i += 2; next }

    if ($c eq "'") {
      my $j = index($s, "'", $i + 1);
      $j = length($s) if $j < 0;
      my $body = substr($s, $i + 1, $j - $i - 1);
      if ($cur =~ $runs_code) { split_line($body); $cur .= '""' }
      else { $cur .= substr($s, $i, $j - $i + 1) }
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
      if ($cur =~ $runs_code) { split_line($str); $cur .= '""' } else { $cur .= '"' . $str . '"' }
      next;
    }

    if ($c eq '$' && substr($s, $i + 1, 1) eq '(') {
      my $e = closing_paren($s, $i + 2);
      split_line(substr($s, $i + 2, $e - $i - 2));
      $cur .= '$()'; $i = $e + 1; next;
    }
    if (($c eq '<' || $c eq '>') && substr($s, $i + 1, 1) eq '(') {
      my $e = closing_paren($s, $i + 2);
      split_line(substr($s, $i + 2, $e - $i - 2));
      $cur .= $c . '()'; $i = $e + 1; next;
    }
    if ($c eq '`') {
      my $e = closing_backtick($s, $i + 1);
      split_line(substr($s, $i + 1, $e - $i - 1));
      $cur .= '$()'; $i = $e + 1; next;
    }

    # A # starts a comment only at the beginning of a word.
    if ($c eq '#' && ($cur eq '' || $cur =~ /\s\z/)) {
      $i++ while $i < length($s) && substr($s, $i, 1) ne "\n";
      next;
    }

    # `>&` and `&>` are redirections, not separators.
    if ($c eq '&' && ($cur =~ /[<>]\z/ || substr($s, $i + 1, 1) eq '>')) { $cur .= $c; $i++; next }

    # Entering a case pattern: after `in`, up to the `)` that closes it.
    if (!$case_pattern && $cur =~ /(?:^|[\s;])case\s[^)]*\sin\s*\z/) { $case_pattern = 1 }
    if ($case_pattern) {
      if ($c eq '|') { $cur .= $c; $i++; next }          # an alternative, not a pipeline
      $case_pattern = 0 if $c eq ')';
    }
    if ($c =~ /[;&|\n]/) { $flush->(); $i++; next }

    $cur .= $c; $i++;
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

sub words {
  my ($s) = @_;
  my @w;
  my $cur = '';
  my $i = 0;
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
    if ($c =~ /\s/) { push @w, $cur if length $cur; $cur = ''; $i++; next }
    $cur .= $c; $i++;
  }
  push @w, $cur if length $cur;
  return @w;
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
  if (@w && $w[-1] !~ /["'\\]/) {
    my $last = $w[-1];
    while ($last =~ /\)$/ && ($last =~ tr/)//) > ($last =~ tr/(//)) { chop $last }
    $w[-1] = $last;
    pop @w unless length $last;
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
      if ($w eq 'coproc' && @w > 1
          && $w[1] =~ /^[A-Za-z_][A-Za-z0-9_]*$/
          && @w > 2 && $w[2] =~ /^\{/) {
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
    # A redirection in front of a command: 2>/dev/null gh …
    # `{fd}>log` too, which bash allows and which read as the command word: the segment was
    # named `{fd}>log`, readable, and `{fd}>log gh pr merge 7 --admin` was allowed. Both
    # spellings of the same grammar, and the first one shipped without the second.
    if ($w =~ /^[0-9]*[<>]/ || $w =~ /^\{[A-Za-z_][A-Za-z0-9_]*\}[<>]/) {
      push @walked, $w; shift @w; next;
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
              [@w[1 .. $#w]]);
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
                [@w[1 .. $#w]]);
      }
      next;
    }

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
              [@w[1 .. $#w]]);
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
              [@w[1 .. $#w]]);
    }
    # And it cannot begin with a dash. The shell would look for a file named `-p`, so a word
    # like that is always an option some prefix should have consumed and did not — the net
    # under the whole family, of which `time -p` was one member and the next grammar word to
    # be mishandled will be another. A silent allow is what this replaces: `-p` was a
    # perfectly readable command word that no rule names.
    if ($bare =~ /^-/) {
      return ($name, join(' ', @walked, $w),
              'an option sits where the command word should be, so some prefix was not read correctly and what runs cannot be named',
              [@w[1 .. $#w]]);
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
            [@w[1 .. $#w]])
      if $why;

    return ($name, join(' ', @walked, $w), undef, [@w[1 .. $#w]]);
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
