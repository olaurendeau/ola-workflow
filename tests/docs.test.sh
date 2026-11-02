#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
#   SC2015, `A && ok || ko`: ok() only counts and prints, so ko() cannot run after a passing test.
#   SC2016: the backticks in single quotes below are the Markdown being tested, not a command.
# What the documentation promises and the repository can check: every relative link of the
# README and of docs/ resolves to a file, and every anchor to a heading; and the table of
# profile keys in the README is the schema's own list of keys.
#
# Each check is proved on a throwaway tree first. On the real tree a clean verdict is also
# what a check that reads nothing prints, so the fixtures are what say the check can fail,
# and a witness beside the real run says it read something.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/scratch.sh
. "$ROOT/scripts/scratch.sh"

failures=0
total=0
ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

ola_scratch docs
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT

# --- Links ----------------------------------------------------------------------------
# check_links <root> <file>... → one line per link read (LINK), per anchor verified
# (ANCHOR) and per defect (ERR file:line: …). Perl, because a heading's anchor is a Unicode
# rule (GitHub keeps letters, digits, `_` and `-`, whatever the script) and sed has no
# opinion on that.
#
# Anchors follow GitHub: lower case, everything but letters, digits, `_`, `-` and spaces
# removed, each space a hyphen, a repeated title suffixed -1, -2. So "The `x` — y" is
# `the-x--y`: the dash goes, both spaces stay. Backticks are removed and their content is
# kept. Links inside a fenced block or an inline code span are text, not links.
# Stated limits: setext headings (underlined) are not read as headings; a link text spread
# over two lines is not read; an anchor on a target that is not a .md file is not checked.
cat >"$WORK/links.pl" <<'PERL'
use strict; use warnings; use utf8;
use File::Basename qw(dirname);
use Encode qw(decode encode);
binmode(STDOUT, ':utf8');
# Paths are characters here and bytes only at the filesystem: argv is decoded once, and `fs()`
# encodes at each open and each test, so a non-ASCII checkout path is not double-encoded.
my ($root, @files) = map { decode('UTF-8', $_) } @ARGV;
sub fs { encode('UTF-8', shift) }
# %XX is a byte; a run of them is UTF-8 and decodes to characters, not to one char per byte.
sub unescape { my $x = shift; $x =~ s/((?:%[0-9A-Fa-f]{2})+)/decode('UTF-8', pack('H*', join '', $1 =~ m{%(..)}g))/ge; $x }
my %cache;

sub slug {
  my $t = shift;
  $t =~ s/\[((?:[^\[\]]|\[[^\]]*\])*)\]\([^)]*\)/$1/g;
  # A code span is literal text: `<n>` is the letter n, `_` stays. Set aside first, so that
  # what follows (HTML tags, emphasis) only reads the prose around it.
  my @code;
  $t =~ s/(`+)(.+?)(?<!`)\1(?!`)/push @code, $2; "\x00" . $#code . "\x00"/ge;
  $t =~ s/<[^>]*>//g;
  # `_x_` and `__x__` are emphasis at a word boundary and vanish; `snake_case` keeps its `_`.
  $t =~ s/(?<![\p{L}\p{N}_])(_{1,2})(?=\S)(.+?)(?<=\S)\1(?![\p{L}\p{N}_])/$2/g;
  $t =~ s/\x00(\d+)\x00/$code[$1]/g;
  $t =~ s/`//g;
  $t =~ s/\s+#+\s*$//;
  $t =~ s/^\s+|\s+$//g;
  $t = lc $t;
  $t =~ s/[^\p{L}\p{N}\p{M}_\- ]//g;
  $t =~ s/ /-/g;
  return $t;
}

# scan(file) → ({anchor => 1}, [[line, target], ...])
sub scan {
  my $f = shift;
  return @{$cache{$f}} if $cache{$f};
  my (%anchors, @links, %seen);
  open(my $fh, '<:encoding(UTF-8)', fs($f)) or return ({}, []);
  my ($fence, $n) = ('', 0);
  while (my $line = <$fh>) {
    $n++;
    chomp $line;
    if ($fence ne '') {
      $fence = '' if $line =~ /^ {0,3}\Q@{[substr($fence, 0, 1)]}\E{@{[length $fence]},}\s*$/;
      next;
    }
    if ($line =~ /^ {0,3}(`{3,}|~{3,})/) { $fence = $1; next; }
    if ($line =~ /^ {0,3}#{1,6}\s+(.*)$/) {
      my $s = slug($1);
      my $k = $seen{$s}++;
      $anchors{$k ? "$s-$k" : $s} = 1;
    }
    $anchors{lc $2} = 1 while $line =~ /<a\s[^>]*\b(name|id)="([^"]+)"/g;
    (my $text = $line) =~ s/(`+).+?(?<!`)\1(?!`)/ /g;
    while ($text =~ /!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)/g) {
      push @links, [$n, $1];
    }
    if ($text =~ /^ {0,3}\[([^\]]+)\]:\s*<?(\S+?)>?(?:\s|$)/ && substr($1, 0, 1) ne '^') {
      push @links, [$n, $2];
    }
  }
  close $fh;
  $cache{$f} = [\%anchors, \@links];
  return (\%anchors, \@links);
}

for my $file (@files) {
  my $rel = $file;
  $rel =~ s/^\Q$root\E\/?//;
  my (undef, $links) = scan($file);
  for my $l (@$links) {
    my ($n, $t) = @$l;
    print "LINK $rel:$n $t\n";
    next if $t =~ /^[A-Za-z][A-Za-z0-9+.\-]*:/ || $t =~ m{^//};
    my ($p, $a) = split /#/, $t, 2;
    $p = unescape($p);
    my $target =
        $p eq ''         ? $file
      : $p =~ m{^/}      ? "$root$p"
      :                    dirname($file) . "/$p";
    unless (-e fs($target)) { print "ERR $rel:$n: $t points at a file that does not exist\n"; next; }
    next unless defined $a && length $a && -f fs($target) && $target =~ /\.md$/;
    $a = unescape($a);
    my ($anchors) = scan($target);
    print "ANCHOR $rel:$n $t\n";
    print "ERR $rel:$n: $t points at a heading that does not exist\n" unless $anchors->{lc $a};
  }
}
PERL
check_links() { perl "$WORK/links.pl" "$@"; }

# A page of the fixtures, written by the case that needs it.
fx=$WORK/fx
mkdir -p "$fx/docs/sub"
cat >"$fx/other.md" <<'EOF'
# Other

## Same title

## Same title

## The `thing` — and more

## Café déjà
EOF
cat >"$fx/docs/good.md" <<'EOF'
# Good

See [the other page](../other.md), [a heading](../other.md#other),
[the second duplicate](../other.md#same-title-1), [backticks and a dash](../other.md#the-thing--and-more),
[accents](../other.md#café-déjà), [here](#good), [a sibling](sub/deep.md), [a directory](sub/),
[external](https://example.com/missing.md#nope) and [mail](mailto:a@b.c).
EOF
printf '# Deep\n' >"$fx/docs/sub/deep.md"
good=$(check_links "$fx" "$fx/docs/good.md")
if [ "$(printf '%s\n' "$good" | grep -c "^LINK ")" = 10 ] && ! printf '%s\n' "$good" | grep -q '^ERR '; then
  ok "links: a page of good links, duplicates, backticks, a dash and accents included, has no defect and ten links read"
else
  ko "links: the good fixture is not clean or not fully read: $(printf '%s' "$good" | grep -E '^ERR|^LINK' | head -5 | tr '\n' '|')"
fi

# What GitHub renders, not what the source says: a code span keeps its `<n>`, an emphasised
# word loses its `_`, a word with an inner `_` keeps it; `%C3%A9` is one é, in an anchor and
# in a path. The tree sits under a non-ASCII folder, so a path built from bytes and from
# characters alike would double-encode it and every link would be reported missing.
ux=$WORK/répertoire
mkdir -p "$ux/docs"
printf '%s\n' '# U' '' '## Run `gh pr merge <n>`' '' '## _emph_ word' '' '## a snake_case word' '' \
  '## Café déjà' '' '[a](#run-gh-pr-merge-n), [b](#emph-word), [c](#a-snake_case-word),' \
  '[d](#caf%C3%A9-d%C3%A9j%C3%A0), [e](fichi%C3%A9.md), [f](fichi%C3%A9.md#fichi%C3%A9), [g](fichié.md)' >"$ux/docs/u.md"
printf '# fichié\n' >"$ux/docs/fichié.md"
unicode=$(check_links "$ux" "$ux/docs/u.md")
if [ "$(printf '%s\n' "$unicode" | grep -c '^LINK ')" = 7 ] && ! printf '%s\n' "$unicode" | grep -q '^ERR '; then
  ok "links: <n> in a code span, an emphasised word, a snake_case word and %XX as UTF-8 resolve, under a non-ASCII path"
else
  ko "links: GitHub's anchors or a non-ASCII path are refused: $(printf '%s' "$unicode" | grep -E '^ERR' | head -5 | tr '\n' '|')"
fi

# One defect per fixture, each alone on its page, so a verdict names its cause.
defect() { # defect <label> <expected fragment> <page text>
  local label=$1 want=$2 text=$3 out
  printf '%s\n' "$text" >"$fx/docs/bad.md"
  out=$(check_links "$fx" "$fx/docs/bad.md" | grep '^ERR ')
  case $out in
    *"$want"*) ok "links: $label is reported" ;;
    *) ko "links: $label is not reported (got: ${out:-nothing})" ;;
  esac
}
defect "a file that does not exist" "missing.md" '[x](missing.md)'
defect "an anchor that does not exist" "#nowhere" '[x](../other.md#nowhere)'
defect "an anchor on the page itself that does not exist" "#nowhere" '[x](#nowhere)'
defect "a third copy of a title that exists twice" "#same-title-2" '[x](../other.md#same-title-2)'
defect "a dash kept as one hyphen instead of two" "#the-thing-and-more" '[x](../other.md#the-thing-and-more)'
defect "a reference definition that does not exist" "gone.md" '[x]: gone.md'

# What is not a link: a fenced block, an inline code span, a tilde fence.
printf '%s\n' '# T' '```bash' '[x](missing.md)' '```' '~~~' '[y](also-missing.md#a)' '~~~' \
  'and `[z](inline-missing.md)` here, then [ok](#t)' >"$fx/docs/code.md"
code=$(check_links "$fx" "$fx/docs/code.md")
if ! printf '%s\n' "$code" | grep -q '^ERR ' && [ "$(printf '%s\n' "$code" | grep -c '^LINK ')" = 1 ]; then
  ok "links: a link in a fenced block or an inline code span is text, and the one real link is read"
else
  ko "links: code is read as links: $(printf '%s' "$code" | tr '\n' '|')"
fi

# The real tree. README.md and docs/**, with no exclusion: security-precedents.md and the
# designs hold links too. Listed from $ROOT/docs, never from the root of the repository,
# where .claude/worktrees/ holds other agents' copies of this very tree.
pages=("$ROOT/README.md")
while IFS= read -r p; do pages+=("$p"); done < <(find "$ROOT/docs" -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)
real=$(check_links "$ROOT" "${pages[@]}")
read_links=$(printf '%s\n' "$real" | grep -c '^LINK ')
read_anchors=$(printf '%s\n' "$real" | grep -c '^ANCHOR ')
if [ "$read_links" -gt 0 ] && [ "$read_anchors" -gt 0 ]; then
  ok "links: the real tree was read ($read_links links, $read_anchors of them with an anchor, over ${#pages[@]} pages)"
else
  ko "links: the real tree yielded $read_links links and $read_anchors anchors, so a clean verdict means nothing"
fi
errs=$(printf '%s\n' "$real" | grep '^ERR ')
if [ -z "$errs" ]; then
  ok "links: every relative link and anchor of the README and docs/ resolves"
else
  while IFS= read -r e; do ko "links: ${e#ERR }"; done <<EOF
$errs
EOF
fi

# --- Keys -----------------------------------------------------------------------------
# The first table of the page whose header begins with `| key |` is the list of profile
# keys, and it is the schema's list of keys: in both directions, because a key the schema
# has and the page lacks is undocumented, and a key the page has and the schema lacks is
# documented and refused. #129 moves the table: that is the variable below.
KEYS_PAGE=$ROOT/README.md
SCHEMA=$ROOT/schema/profile.schema.json
# `$schema` is a key of `properties` (so that an editor may point at the schema) and no row
# of the table carries it: it is not a setting. Declared rather than filtered silently, so
# the day the table documents it this line is the one to delete.
KEYS_EXCEPTION='$schema'

# key_problems <page> <schema> → one line per disagreement; `no-page` / `no-table` when
# there is nothing to compare, which is a failure and not a pass.
key_problems() {
  local page=$1 schema=$2 table doc sch
  [ -f "$page" ] || { echo "no-page"; return; }
  table=$(awk '
    !t && /^\| key \|/ { t = 1 }
    t && /^\|/ { print; next }
    t { exit }
  ' "$page")
  [ -n "$table" ] || { echo "no-table"; return; }
  # Rows after the header and the `|---|` line; the first cell, backticks and blanks off.
  doc=$(printf '%s\n' "$table" | sed '1,2d' | awk -F'|' '{ k = $2; gsub(/[` ]/, "", k); if (k != "") print k }' | LC_ALL=C sort -u)
  sch=$(jq -r '.properties | keys[]' "$schema" | grep -vxF "$KEYS_EXCEPTION" | LC_ALL=C sort -u)
  comm -23 <(printf '%s\n' "$sch") <(printf '%s\n' "$doc") | sed 's/^/in the schema, not in the table: /'
  comm -13 <(printf '%s\n' "$sch") <(printf '%s\n' "$doc") | sed 's/^/in the table, not in the schema: /'
}

kf=$WORK/keys
mkdir -p "$kf"
cat >"$kf/schema.json" <<'EOF'
{"properties": {"$schema": {}, "mode": {}, "pr": {}}}
EOF
printf '%s\n' 'Some text.' '' '| key | what |' '|---|---|' '| `mode` | a |' '| `pr` | b |' '' '| key | other |' '|---|---|' '| `later` | c |' >"$kf/page.md"
if [ -z "$(key_problems "$kf/page.md" "$kf/schema.json")" ]; then
  ok "keys: a table with every key but \$schema, and a second table after it, is the schema's list"
else
  ko "keys: the good fixture is refused: $(key_problems "$kf/page.md" "$kf/schema.json" | tr '\n' '|')"
fi
grep -v '`pr`' "$kf/page.md" >"$kf/missing-row.md"
case $(key_problems "$kf/missing-row.md" "$kf/schema.json") in
  *"in the schema, not in the table: pr"*) ok "keys: a row removed from the table is reported" ;;
  *) ko "keys: a row removed from the table is not reported" ;;
esac
jq '.properties.extra = {}' "$kf/schema.json" >"$kf/schema-more.json"
case $(key_problems "$kf/page.md" "$kf/schema-more.json") in
  *"in the schema, not in the table: extra"*) ok "keys: a key added to the schema is reported" ;;
  *) ko "keys: a key added to the schema is not reported" ;;
esac
sed 's/| `pr` | b |/| `pr` | b |\n| `ghost` | z |/' "$kf/page.md" >"$kf/ghost.md"
case $(key_problems "$kf/ghost.md" "$kf/schema.json") in
  *"in the table, not in the schema: ghost"*) ok "keys: a row for a key the schema lacks is reported" ;;
  *) ko "keys: a row for a key the schema lacks is not reported" ;;
esac
printf 'no table here\n' >"$kf/none.md"
[ "$(key_problems "$kf/none.md" "$kf/schema.json")" = no-table ] && ok "keys: a page without the table is a failure" || ko "keys: a page without the table is not reported"
[ "$(key_problems "$kf/absent.md" "$kf/schema.json")" = no-page ] && ok "keys: an absent page is a failure" || ko "keys: an absent page is not reported"

problems=$(key_problems "$KEYS_PAGE" "$SCHEMA")
case $problems in
  "") ok "keys: the table of ${KEYS_PAGE#"$ROOT"/} lists exactly the keys of the schema" ;;
  no-page) ko "keys: ${KEYS_PAGE#"$ROOT"/} does not exist" ;;
  no-table) ko "keys: ${KEYS_PAGE#"$ROOT"/} has no table whose header begins with '| key |'" ;;
  *) while IFS= read -r p; do ko "keys: $p"; done <<EOF
$problems
EOF
  ;;
esac

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total docs test(s) failed"
  exit 1
fi
echo "all $total docs tests passed"
