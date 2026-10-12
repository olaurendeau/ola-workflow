#!/usr/bin/env perl
# Splits a shell command line into the simple commands a shell would actually run, and
# names each one's command word.
#
# Reads the command line on stdin, writes one JSON object per line on stdout:
#
#   {"raw": …, "command": …, "resolved": …, "readable": true|false, "reason": …}
#
#   raw       the segment as written, for a message a human reads
#   command   the command word, normalised — THE ONLY FIELD A RULE MAY MATCH
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
my $runs_code = qr{(?:^|[\s;&|(])(?:(?:ba|z|da|k)?sh(?:\s+-[-a-zA-Z]+)*\s+-[a-zA-Z]*c[a-zA-Z]*|eval)\s+\z};

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
my %reserved = map { $_ => 1 }
  qw(if then elif else fi for while until do done case esac in select function
     time coproc ! { } [[ ]]);

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
my %value_opts = (
  sudo    => qr/^-(?:u|g|p|C|h|r|t|U)$/,
  doas    => qr/^-(?:u|C)$/,
  nice    => qr/^-(?:n)$/,
  ionice  => qr/^-(?:c|n|p|P|u)$/,
  timeout => qr/^-(?:s|k)$/,
  env     => qr/^-(?:u|C|S)$/,
  stdbuf  => qr/^-(?:i|o|e)$/,
  xargs   => qr/^-(?:I|i|L|n|P|s|d|E|a)$/,
  exec    => qr/^-(?:a)$/,
  time    => qr/^-(?:f|o)$/,
);

# And which take none. The two tables together are the point: an option in neither makes
# the segment unreadable, because *assuming* an unknown option is boolean is how
# `exec -a innocent gh pr merge` came to be named `innocent` — the same defect as
# `sudo -u x`, returning through the fallback instead of through a missing row. The safe
# default for an unknown option is an admission, never a guess.
my %bool_opts = (
  sudo    => qr/^-(?:A|b|E|H|i|k|K|l|n|P|S|s|V|v)$/,
  doas    => qr/^-(?:L|n|s)$/,
  nice    => qr/^$/,
  ionice  => qr/^-(?:t)$/,
  timeout => qr/^-(?:-foreground|-preserve-status|v)$/,
  env     => qr/^-(?:i|0|v)$/,
  stdbuf  => qr/^$/,
  xargs   => qr/^-(?:0|p|r|t|x)$/,
  exec    => qr/^-(?:c|l)$/,
  command => qr/^-(?:p|v|V)$/,
  nohup   => qr/^$/,
  setsid  => qr/^-(?:c|f|w)$/,
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
    if ($w =~ /^[0-9]*[<>]/) { push @walked, $w; shift @w; next }

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
              "the command it runs is not in this text ($name)");
    }
    if ($wrapper{$name}) {
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
        # A known boolean takes nothing.
        my $boolean = $bool_opts{$name};
        if ($boolean && $w[0] =~ $boolean) { push @walked, shift @w; next }
        return ($name, join(' ', @walked, @w),
                "$name is given the option $w[0], and whether it takes a value is unknown here");
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
              'this looks like a case arm or a subshell, and the split cut inside it');
    }

    # Everything the shell would still expand before this becomes a command word.
    my $why;
    $why = 'a parameter or command substitution' if $bare =~ /\$/;
    $why = 'a brace expansion'                   if !$why && $bare =~ /\{[^}]*,/;
    $why = 'a pathname pattern'                  if !$why && $bare =~ /[*?\[]/;
    return ($name, join(' ', @walked, $w), "the command word is built by $why")
      if $why;

    return ($name, join(' ', @walked, $w), undef);
  }
  # Nothing left after the prefixes: this segment runs no command at all — a bare
  # assignment, a closing brace, a `done`. That is not something unreadable, it is nothing
  # to judge, and calling it unreadable would spend an ask on `c=gh`.
  return ('', join(' ', @walked), undef);
}

# ------------------------------------------------------------------------------- output
split_line($input);
for my $seg (@segments) {
  my ($cmd, $resolved, $reason) = command_word($seg);
  my $trimmed = $seg;
  $trimmed =~ s/^\s+|\s+$//g;
  printf "{\"raw\":%s,\"command\":%s,\"resolved\":%s,\"readable\":%s,\"reason\":%s}\n",
    json_string($trimmed), json_string($cmd), json_string($resolved),
    (defined $reason ? 'false' : 'true'),
    (defined $reason ? json_string($reason) : 'null');
}
