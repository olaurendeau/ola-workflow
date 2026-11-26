#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015
#   SC2016: several strings below are Markdown, with backticks in single quotes on purpose.
#   SC2015: `A && ok || ko`: ok() only counts and prints, so ko() cannot run after a passing
#   test.
# Runs bin/ola-workflow-pr-lint on throwaway projects. The four witnesses are descriptions
# this repository really published (#203, #205, #206, #209), copied as they are: a command
# that refuses one of them is wrong, because a refusal is going to be blocking. No network.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/scratch.sh
. "$ROOT/scripts/scratch.sh"

failures=0
total=0
ok() { total=$((total + 1)); echo "ok    $1"; }
ko() { total=$((total + 1)); echo "FAIL  $1"; failures=$((failures + 1)); }

LINT=$ROOT/bin/ola-workflow-pr-lint

ola_scratch pr-lint
WORK=$OLA_SCRATCH
trap 'rm -rf "${WORK:?}"' EXIT
export HOME=$WORK/home
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# project <name> <profile json | none> → a throwaway repository, with the profile when given.
project() {
  mkdir -p "$WORK/$1/.claude"
  git -C "$WORK/$1" init -q
  [ "$2" = none ] || printf '%s\n' "$2" >"$WORK/$1/.claude/workflow.json"
}
project fr '{"mode":"integrated","language":{"artifacts":"fr"}}'
project en '{"mode":"integrated","language":{"artifacts":"en"}}'
project bare none
project de '{"mode":"integrated","language":{"artifacts":"de"}}'
project discreet '{"mode":"discreet","language":{"artifacts":"fr"}}'
project gitlab '{"mode":"integrated","forge":"gitlab","language":{"artifacts":"fr"}}'
project broken 'not json at all'

# lint <project> <args...> → runs the command from that project; sets rc, out, err.
lint() {
  local dir=$1
  shift
  out=$(cd "$WORK/$dir" && "$LINT" "$@" 2>"$WORK/err")
  rc=$?
  err=$(cat "$WORK/err")
}
# lint_stdin <project> <file> [args...] → the same, with the file on the standard input.
lint_stdin() {
  local dir=$1 file=$2
  shift 2
  out=$(cd "$WORK/$dir" && "$LINT" "$@" - <"$file" 2>"$WORK/err")
  rc=$?
  err=$(cat "$WORK/err")
}
# put <name> → the standard input, as is, in $WORK/<name>.md.
put() { cat >"$WORK/$1.md"; }
F() { echo "$WORK/$1.md"; }
has() { case $out in *"$1"*) return 0 ;; esac; return 1; }
# show → the output of the last run, indented, under a FAIL line.
show() { printf '%s\n' "$out" | while IFS= read -r l; do printf '      %s\n' "$l"; done; }
digest_of() { git hash-object --no-filters --stdin <"$1"; }

# accept <label> <project> <name> → exit 0, the success line, the count and the digest.
accept() {
  lint "$2" "$(F "$3")"
  [ "$rc" = 0 ] && has 'follows the form of the brief' && has 'lines outside <details>:' && has 'digest: ' &&
    ok "$1" || { ko "$1 (exit $rc)"; show; }
}
# refuse <label> <project> <name> <text naming the problem> → exit 1, that text, the count and
# the digest, and no success line.
refuse() {
  lint "$2" "$(F "$3")"
  [ "$rc" = 1 ] && has "$4" && has 'lines outside <details>:' && has 'digest: ' && ! has 'follows the form' &&
    ok "$1" || { ko "$1 (exit $rc)"; show; }
}
# usage <label> <args...> → exit 2, nothing on the standard output, a word on stderr.
usage() {
  local label=$1
  shift
  lint fr "$@"
  [ "$rc" = 2 ] && [ -z "$out" ] && [ -n "$err" ] && ok "usage: $label" ||
    { ko "usage: $label (exit $rc, stdout '$out')"; }
}

# --- The witnesses ----------------------------------------------------------------------
put witness-203 <<'WITNESS'
Closes #162

Un profil peut maintenant dire `"forge": "github"` ou `"gitlab"` (absent : `github`, le défaut que l'appelant énonce, comme pour `github_tokens`). Un profil `gitlab` est arrêté net par `ola-workflow-brief` : exit 1, le refus sur stderr, rien sur stdout, car le brief actuel dicterait des commandes `gh` et promettrait des refus que GitLab ne donne pas.

Vérifié : `make check` ; `scripts/brief-equivalence.sh origin/main` : `30 comparisons, 0 different` (les suites existantes sont inchangées, seules des assertions s'ajoutent) ; mutation de la condition du refus : les deux tests du refus échouent, puis repassent une fois rétablie.

Decision: la règle `forbid_key forge` vise `glab <sous-commande>` et non le mot `glab` seul — Reason: `agents/coordinator.md` écrit déjà « the `glab` equivalent » pour lire un lien, sans rien exécuter ; réécrire une définition d'agent sortirait de la tâche.

Aucun changement visible pour l'utilisateur d'un projet GitHub. Fusion par l'humain (`schema/`, `hooks/`, `bin/`, `brief/`) ; relecture de sécurité due.

<details><summary>Détail</summary>

- `schema/profile.schema.json` : clé `forge` (enum `github|gitlab`), `<host>/<path>` dans la description de tête.
- `hooks/lib/profile-validate.jq` : inchangé. L'erreur d'enum nomme déjà les deux valeurs (`is not one of github, gitlab`), testée.
- `hooks/lib/profile.sh` : commentaires `<host>/<path>`, aucun changement de comportement.
- `brief/refusals/forge-unsupported.md` et un `render refusals/forge-unsupported >&2` littéral suivi de `exit 1` dans `bin/ola-workflow-brief`, avant toute sortie.
- `docs/configuration.md` : ligne `forge`.
- Tests : `tests/profile.test.sh` (absent, relu, enum, profil discret sous un sous-groupe `gitlab.example.com/a/b/c`) ; `tests/agents.test.sh` (refus GitLab, GitHub inchangé, `forbid_key forge`).
- Non touché : les autres occurrences de `<owner>/<repo>` (`bin/ola-profile`, `docs/configuration.md`, `tests/discreet-mode.test.sh`, `tests/docs.test.sh`) ; elles sont épinglées par des suites que la tâche laisse inchangées.

</details>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
WITNESS
put witness-205 <<'WITNESS'
Closes #163

L'élévation lit la forge du profil et n'essaie que les formes de cette forge : `elevate.sh` filtre par rôle les débuts `gh ` / `glab `, `with-token.sh` prend la forge avant le type de jeton (`GH_TOKEN` seulement, pour github), `ola_token_read` accepte un compte (défaut inchangé). Aucune forme GitLab n'existe encore : un projet `forge: gitlab` n'élève rien.

Vérifié : `make check`
- `tests/tokens.test.sh` : tous les cas existants gardent leur décision (même allow ou même no-op) ; seule la commande réécrite nomme désormais la forge.
- une forme GitHub dans un projet `forge: gitlab` passe intacte ; une forme `glab` ne l'est dans aucun projet.
- `with-token.sh` n'exécute rien pour une forge inconnue ou absente (ancienne forme à deux arguments comprise).

Relecture de sécurité due (`hooks/`) ; fusion par l'humain.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
WITNESS
put witness-206 <<'WITNESS'
Closes #170

Avec `forge: gitlab` dans le profil, `ola-workflow-pr-assets` imprime des liens `/-/raw/pr-assets/…`, réécrit `altssh.gitlab.com` en `gitlab.com` et signe son commit de repli depuis `ola-workflow@users.noreply.<hôte>` ; `scripts/token-cost.sh` reconnaît `/-/merge_requests/N`. La sortie GitHub ne change pas.

Vérifié : `make check` ; `tests/captures.test.sh` (77) et `tests/token-cost.test.sh` (47), rouges avant le changement ; les tests GitHub existants passent inchangés.

Decision: l'identité de repli GitLab est `ola-workflow@users.noreply.<hôte>` — Reason: le seul « bot » connu hors ligne est l'identité du commit, la forge n'est pas interrogée ; GitHub garde `users.noreply.github.com`.

<details><summary>Détail</summary>

- La forge vient du profil (`ola_profile_get forge`), jamais du nom de l'hôte : un GitLab auto-hébergé se nomme comme on veut. Absente, illisible ou sans profil : GitHub.
- `ssh.github.com` n'est réécrit que pour GitHub, `altssh.gitlab.com` que pour GitLab.
- Revue de sécurité due (`bin/`) ; fusion par l'humain.

</details>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
WITNESS
put witness-209 <<'WITNESS'
Closes #164

Une session GitLab en mode integrated exporte le jeton de base du bot pour l'hôte du remote seulement, lu en remontant du projet à l'hôte (`gitlab:<hôte>/<chemin>` sous les services `ola-workflow-<kind>`), avec une valeur factice jamais vide quand il manque. `with-token.sh gitlab <kind>` lend le jeton de l'humain avec `GITLAB_HOST` posé sur ce même hôte. Les sessions GitHub et le mode discret GitLab n'ont aucune ligne GitLab.

Vérifié : `make check` (lint, tests, validate)
- `tests/tokens.test.sh` (faux `security`) : ordre de remontée projet, groupe, hôte ; un jeton d'un autre hôte, d'un hôte frère ou parent n'est jamais exporté ; un chemin avec `$( )`, guillemets, espaces reste inerte ; valeur factice jamais vide ; ligne `GH_TOKEN` toujours écrite et première ; fichier GitHub identique à `ola_token_env_line` et sans ligne GitLab ; discret GitLab sans `GITLAB_TOKEN` ; `with-token.sh gitlab` : hôte du profil, aucun jeton en argument, rien ne tourne sans jeton ou sans remote ; un jeton vide est un jeton absent et la remontée passe au-delà (le faux `security` répond un élément vide comme le vrai) ; `altssh.gitlab.com` est lu comme `gitlab.com` (hôte exporté et comptes).

Decision: sans remote lisible, la ligne exporte seulement la valeur factice (aucun `GITLAB_HOST`) et la session le dit — Reason: pas d'hôte connu, donc aucun jeton à prêter, mais jamais un `GITLAB_TOKEN` vide qui retomberait sur le login de l'humain.

<details><summary>Sécurité (relecture demandée)</summary>

- Hôte et chemin du remote sont du texte contrôlé par le projet : ils n'entrent dans la ligne sourcée que par `printf %q` ; la boucle de lecture tourne dans une substitution de commande (aucune variable laissée dans la session). Sourcée sous bash et, quand il est installé, sous zsh (les tests comparent les deux) ; un hôte qui commence par `=` y est échappé, zsh le développant sinon.
- Le jeton ne passe jamais dans le fichier ni dans un argument ; la remontée ne quitte jamais l'hôte du remote, et `GITLAB_HOST` est posé avec le jeton lent.
- Limite connue : `ola_profile_url_id` ignore le port ; un GitLab auto-hébergé sur un port non standard n'aura pas `GITLAB_HOST=hôte:port`.
- Fusion par l'humain (`hooks/`).
</details>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
WITNESS

for n in 203 205 206 209; do
  accept "the published description of #$n is accepted (fr)" fr "witness-$n"
done

# The count is of the non-blank lines outside <details>, and is pinned for each witness.
for pair in 203:6 205:8 206:5 209:6; do
  lint fr "$(F "witness-${pair%%:*}")"
  has "lines outside <details>: ${pair#*:}" &&
    ok "witness #${pair%%:*}: ${pair#*:} lines outside <details>" ||
    { ko "witness #${pair%%:*}: expected ${pair#*:} lines outside <details>"; show; }
done

# --- The label follows the language of the artifacts -------------------------------------
# good <label> → a conforming description whose verification line starts with <label>.
good() {
  printf 'Closes #1\n\nOne sentence. Two sentences.\n\n%s `make check`\n\nDecision: a — Reason: b\n\n<details><summary>More</summary>\n\n- x\n\n</details>\n' "$1"
}
good 'Checked:' | put en-ok
good 'Vérifié :' | put fr-ok
accept "Checked: is accepted in an en profile" en en-ok
accept "Checked: is accepted without any profile (default en)" bare en-ok
accept "Checked: is accepted in a profile of another language" de en-ok
accept "Checked: is accepted when the profile cannot be read" broken en-ok
refuse "Vérifié : is refused in an en profile" en fr-ok 'verification line is missing'
refuse "Vérifié : is refused without any profile" bare fr-ok 'verification line is missing'
accept "Vérifié : is accepted in a fr profile" fr fr-ok
refuse "Checked: is refused in a fr profile" fr en-ok 'verification line is missing'
good 'Vérifié:' | put fr-nocolonspace
accept "Vérifié: with no blank before the colon is accepted" fr fr-nocolonspace
good "Ve$(printf '\314\201')rifie$(printf '\314\201') :" | put fr-nfd
accept "Vérifié with decomposed accents is accepted" fr fr-nfd
good "Vérifié$(printf '\302\240'):" | put fr-nbsp
accept "a no-break space before the colon is accepted" fr fr-nbsp
good "Vérifié$(printf '\342\200\257'):" | put fr-nnbsp
accept "a narrow no-break space before the colon is accepted" fr fr-nnbsp
good '**Vérifié :**' | put fr-bold
accept "the label between ** is accepted" fr fr-bold
good '**Checked**:' | put en-bold
accept "**Checked**: is accepted" en en-bold
good 'Vérifiées :' | put fr-other
refuse "another word that starts like the label is refused" fr fr-other 'verification line is missing'
good 'Vérifié' | put fr-nocolon
refuse "the label without a colon is refused" fr fr-nocolon 'verification line is missing'

# --- The five refusals, each one alone ---------------------------------------------------
# 1. A Closes line that is not in the head block.
put closes-late <<'EOF'
Closes #1

Une phrase.

Closes #2

Vérifié : `make check`
EOF
refuse "1: a Closes line after the summary is refused, with its line number" fr closes-late 'closes-late.md:5: a `Closes #` line is only allowed in the head block'
put closes-two <<'EOF'


Closes #1
Closes #2

Une phrase.

Vérifié : `make check`
EOF
accept "1: several Closes lines in the head block, after blank lines, are accepted" fr closes-two
put closes-none <<'EOF'
Une phrase.

Vérifié : `make check`
EOF
accept "1: no Closes line at all is accepted" fr closes-none
put closes-after-check <<'EOF'
Closes #1

Une phrase.

Vérifié : `make check`

Closes #2
EOF
refuse "1: a Closes line after the verification line is refused" fr closes-after-check 'only allowed in the head block'

# 2. The summary. sum <name> <text> → Closes, the text as the summary, the verification line.
sum() { printf 'Closes #1\n\n%s\n\nVérifié : `make check`\n' "$2" | put "$1"; }
sum s-3 'Un. Deux. Trois.'
accept "2: 3 sentences are accepted" fr s-3
sum s-4 'Un. Deux. Trois. Quatre.'
refuse "2: 4 sentences are refused" fr s-4 'the summary has 4 sentences'
sum s-1 'Une seule phrase sans point'
accept "2: one sentence without punctuation counts as one" fr s-1
sum s-frag 'Un. Deux. Trois. Quatre sans point'
refuse "2: a last fragment without punctuation counts as a sentence" fr s-frag 'the summary has 4 sentences'
sum s-lines "$(printf 'Un.\nDeux.\nTrois.\nQuatre.')"
refuse "2: the sentences of several lines are added" fr s-lines 'the summary has 4 sentences'
sum s-code 'Un `x. y. z. w.` fin. Deux.'
accept "2: a . in a code span is not the end of a sentence" fr s-code
sum s-url 'Voir https://example.com/a. Deux. Trois. Quatre.'
accept "2: a URL is not counted, its trailing . with it" fr s-url
sum s-link 'Voir [la page](a. b c. d e. f) ici. Deux.'
accept "2: a link target is not counted" fr s-link
sum s-dec 'La version 3.5 est là. Deux. Trois.'
accept "2: a . inside a number is not the end of a sentence" fr s-dec
sum s-ell 'Un… Deux… Trois… Quatre…'
refuse "2: … ends a sentence" fr s-ell 'the summary has 4 sentences'
sum s-run 'Un ?! Deux !!! Trois. Quatre ...'
refuse "2: a run of terminators is one end" fr s-run 'the summary has 4 sentences'
sum s-closers "$(printf 'Un.) Deux.\" Trois.\x27 Quatre.\302\273')"
refuse "2: a closing ) \" ' » after the terminator does not hide the end" fr s-closers 'the summary has 4 sentences'
printf 'Closes #1\n\nVérifié : `make check`\n' | put s-0
refuse "2: no sentence at all, the verification line first, is refused" fr s-0 'the summary is empty'
printf 'Vérifié : `make check`\nUne phrase.\n' | put s-0b
refuse "2: a sentence after the verification line is not a summary" fr s-0b 'the summary is empty'
for item in '- a.' '* a.' '+ a.' '1. a.' '# a.' '| a | b |' '> a.' '<b>a.</b>'; do
  sum s-struct "$(printf 'Une phrase.\n%s' "$item")"
  refuse "2: a summary line starting with '${item%% *}' is refused" fr s-struct 'the summary has '
done
sum s-dash 'Une phrase - avec un tiret. Deux.'
accept "2: a dash inside a line is not a list" fr s-dash
# A no-break space is 2 bytes (U+00A0) or 3 (U+202F): it is one blank, not the start of a word.
sum s-nbsp "$(printf 'Un. Deux. Trois.\302\240')"
accept "2: a no-break space U+00A0 after the last sentence is not a sentence" fr s-nbsp
sum s-nnbsp "$(printf 'Un. Deux. Trois.\342\200\257')"
accept "2: a no-break space U+202F after the last sentence is not a sentence" fr s-nnbsp
sum s-nbsp4 "$(printf 'Un.\302\240Deux.\342\200\257Trois.\302\240Quatre.\342\200\257')"
refuse "2: sentences separated by no-break spaces are still counted" fr s-nbsp4 'the summary has 4 sentences'
sum s-fr "$(printf 'Un. Deux. Il dit :\302\240\302\253\302\240Je viens.\302\240\302\273\342\200\257')"
accept "2: three sentences, the last in the French form with no-break spaces" fr s-fr
sum s-quote 'Il dit : « Je viens. »'
accept "2: a » after a plain space is not a sentence" fr s-quote
sum s-quote3 'Un. Deux. Il dit : « Trois. »'
accept "2: three sentences, the last one quoted with a » after a space" fr s-quote3
sum s-quote4 'Un. Deux. Trois. Il dit : « Quatre. »'
refuse "2: four sentences, the last one quoted with a » after a space" fr s-quote4 'the summary has 4 sentences'
sum s-closer-sp 'Un. ) Deux. " Trois. *'
accept "2: a lone closer after a blank is not a sentence" fr s-closer-sp
# A heading is # then a blank (or nothing); a list number can interrupt a paragraph only as 1.
sum s-hash "$(printf 'Une phrase.\n#213 est lié.')"
accept "2: a line starting with #213 is prose, not a heading" fr s-hash
sum s-hash-first '#213 est lié. Deux.'
accept "2: a summary starting with #213 is prose" fr s-hash-first
for item in '## a.' '###### a.' '#'; do
  sum s-head "$(printf 'Une phrase.\n%s' "$item")"
  refuse "2: a summary line '$item' is a heading" fr s-head 'the summary has a heading'
done
sum s-year "$(printf 'Une phrase écrite en\n2026. Deux.')"
accept "2: a wrapped line starting with 2026. is not a list" fr s-year
sum s-year-par "$(printf 'Une phrase.\n\n2026. Deux.')"
refuse "2: a paragraph starting with 2026. is a list" fr s-year-par 'the summary has a list'
sum s-num-first '3. Une phrase.'
refuse "2: a summary starting with 3. is a list" fr s-num-first 'the summary has a list'

# 3. The verification line.
printf 'Closes #1\n\nUne phrase.\n' | put v-none
refuse "3: no verification line is refused" fr v-none 'verification line is missing'
printf 'Closes #1\n\nUne phrase. Vérifié : x.\n' | put v-inline
refuse "3: the label in the middle of a line is not a verification line" fr v-inline 'verification line is missing'

# 4. Decision.
put d-before <<'EOF'
Closes #1

Une phrase.

Decision: a — Reason: b

Vérifié : `make check`
EOF
refuse "4: a Decision line before the verification line is refused" fr d-before 'd-before.md:5: a Decision line must come after the verification line'
put d-after-details <<'EOF'
Closes #1

Une phrase.

Vérifié : `make check`

<details><summary>Détail</summary>

Decision: a — Reason: b

</details>
EOF
refuse "4: a Decision line after the first <details> is refused" fr d-after-details 'a Decision line must come before the first <details>'
put d-after-closed <<'EOF'
Closes #1

Une phrase.

Vérifié : `make check`

<details><summary>Détail</summary>

- x

</details>

Decision: a — Reason: b
EOF
refuse "4: a Decision line after the closed <details> is refused" fr d-after-closed 'a Decision line must come before the first <details>'
put d-ok <<'EOF'
Closes #1

Une phrase.

Vérifié : `make check`
Decision: a — Reason: b
Decision: c — Reason: d
EOF
accept "4: Decision lines between the verification line and the <details> are accepted" fr d-ok

# 5. <details>.
put x-before <<'EOF'
Closes #1

Une phrase.

<details><summary>Détail</summary>

- x

</details>

Vérifié : `make check`
EOF
refuse "5: a <details> before the verification line is refused" fr x-before 'x-before.md:5: a <details> before the verification line'
put x-open <<'EOF'
Closes #1

Une phrase.

Vérifié : `make check`

<details><summary>Détail</summary>

- x
EOF
refuse "5: a <details> never closed is refused" fr x-open 'a <details> is never closed by </details>'
put x-nested <<'EOF'
Closes #1

Une phrase.

Vérifié : `make check`

<details><summary>Détail</summary>
<details><summary>Plus</summary>
- x
</details>
EOF
refuse "5: a nested <details> that leaves one open is refused" fr x-nested 'never closed'
put x-oneline <<'EOF'
Closes #1

Une phrase.

Vérifié : `make check`

<details><summary>Détail</summary>x</details>
EOF
accept "5: a <details> closed on its own line is accepted" fr x-oneline
put x-code <<'EOF'
Closes #1

Une phrase avec `<details>` dans un span.

Vérifié : `make check`
EOF
accept "5: <details> in a code span is not a <details>" fr x-code

# A free line after the verification line and after </details> is not refused.
put free <<'EOF'
Closes #1

Une phrase.

Vérifié : `make check`
Une ligne libre.

<details><summary>Détail</summary>x</details>

Generated with Claude.
EOF
accept "a free line after the verification line and after </details> is accepted" fr free

# One refusal per problem: three at once give three lines.
put many <<'EOF'
Closes #1

Un. Deux. Trois. Quatre.

Closes #2

Vérifié : `make check`

<details>
EOF
lint fr "$(F many)"
n=$(printf '%s\n' "$out" | grep -c '^[^ ]*many.md:[0-9]*: ')
[ "$rc" = 1 ] && [ "$n" = 3 ] && ok "a file with three problems gets three lines" ||
  { ko "a file with three problems gets three lines (exit $rc, $n lines)"; show; }

# --- Neither the mode nor the forge ------------------------------------------------------
same=1
for name in witness-206 closes-late s-4 d-after-closed x-open; do
  lint fr "$(F $name)"
  ref=$out refrc=$rc
  for project in discreet gitlab; do
    lint $project "$(F $name)"
    [ "$out" = "$ref" ] && [ "$rc" = "$refrc" ] || { same=0; echo "      $name differs under $project"; }
  done
done
[ "$same" = 1 ] && ok "the same file gives the same verdict and output under integrated, discreet and gitlab" ||
  ko "the same file gives the same verdict and output under integrated, discreet and gitlab"

# --- The count never decides --------------------------------------------------------------
{
  printf 'Closes #1\n\nUne phrase.\n\nVérifié : `make check`\n'
  i=1
  while [ "$i" -le 57 ]; do
    printf -- '- ligne %s\n' "$i"
    i=$((i + 1))
  done
} | put long
lint fr "$(F long)"
[ "$rc" = 0 ] && has 'lines outside <details>: 60' && ok "60 lines outside <details>: exit 0, and the count is printed" ||
  { ko "60 lines outside <details>: exit 0 (exit $rc)"; show; }
{
  printf 'Closes #1\n\nUne phrase.\n\nVérifié : `make check`\n\n<details><summary>d</summary>\n\n'
  i=1
  while [ "$i" -le 100 ]; do
    printf -- '- ligne %s\n' "$i"
    i=$((i + 1))
  done
  printf '</details>\n'
} | put inside
lint fr "$(F inside)"
[ "$rc" = 0 ] && has 'lines outside <details>: 3' && ok "lines inside <details> are not counted" ||
  { ko "lines inside <details> are not counted (exit $rc)"; show; }

# --- The digest ----------------------------------------------------------------------------
want=$(digest_of "$(F witness-206)")
lint fr "$(F witness-206)"
[ "$(printf '%s\n' "$out" | tail -1)" = "digest: $want" ] && ok "the digest is git hash-object --no-filters --stdin, and the last line" ||
  ko "the digest is git hash-object --no-filters --stdin, and the last line"
lint_stdin fr "$(F witness-206)"
stdin_out=$out
lint fr "$(F witness-206)"
# The file name is the only difference between the two.
[ "$(printf '%s\n' "$out" | tail -2)" = "$(printf '%s\n' "$stdin_out" | tail -2)" ] && [ "$rc" = 0 ] &&
  ok "the digest and the count are the same from a file and from the standard input" ||
  ko "the digest and the count are the same from a file and from the standard input"
lint_stdin fr "$(F closes-late)"
has '-:5: a `Closes #` line' && [ "$rc" = 1 ] && ok "from the standard input a problem is named '-'" ||
  ko "from the standard input a problem is named '-'"

# --expect
lint fr --expect "$want" "$(F witness-206)"
[ "$rc" = 0 ] && has 'follows the form' && ok "--expect: the same bytes, exit 0" || ko "--expect: the same bytes, exit 0"
lint_stdin fr "$(F witness-206)" --expect "$want"
[ "$rc" = 0 ] && ok "--expect works from the standard input" || ko "--expect works from the standard input"
{ cat "$(F witness-206)"; printf 'x'; } | put changed-add
{ sed 's/Closes #170/Closes #171/' "$(F witness-206)"; } | put changed-byte
for name in changed-add changed-byte; do
  lint fr --expect "$want" "$(F $name)"
  [ "$rc" = 1 ] && has "not the description that was reviewed: digest $(digest_of "$(F $name)"), expected $want" && ! has 'follows the form' &&
    ok "--expect: $name is refused, the form being right" || { ko "--expect: $name is refused"; show; }
done
{ cat "$(F witness-206)"; echo; } | put changed-eol
lint fr --expect "$want" "$(F changed-eol)"
[ "$rc" = 1 ] && has 'not the description that was reviewed' && ok "--expect: a line ending added is a different description" ||
  ko "--expect: a line ending added is a different description"
awk '{ printf "%s\r\n", $0 }' "$(F witness-206)" | put changed-crlf
lint fr --expect "$want" "$(F changed-crlf)"
[ "$rc" = 1 ] && has 'not the description that was reviewed' && ok "--expect: \\r\\n for \\n is a different description" ||
  ko "--expect: \\r\\n for \\n is a different description"
lint fr "$(F changed-crlf)"
[ "$rc" = 0 ] && has 'lines outside <details>: 5' && ! has "digest: $want" &&
  ok "a body with \\r\\n line endings follows the form, its digest is of the raw bytes" ||
  { ko "a body with \\r\\n line endings follows the form"; show; }
lint fr --expect "$(digest_of "$(F closes-late)")" "$(F closes-late)"
[ "$rc" = 1 ] && has 'only allowed in the head block' && ! has 'not the description' &&
  ok "--expect: the right bytes in the wrong form are refused for the form" ||
  ko "--expect: the right bytes in the wrong form are refused for the form"
lint fr --expect "$(digest_of "$(F witness-206)" | tr 'a-f' 'A-F')" "$(F witness-206)"
[ "$rc" = 0 ] && ok "--expect: upper-case hexadecimal digits are accepted" || ko "--expect: upper-case hexadecimal digits are accepted"

# --- awk fails: no verdict, exit 2, nothing on stdout -----------------------------------
mkdir -p "$WORK/stub"
printf '#!/bin/sh\nexit 1\n' >"$WORK/stub/awk"
chmod +x "$WORK/stub/awk"
out=$(cd "$WORK/fr" && PATH="$WORK/stub:$PATH" "$LINT" "$(F witness-206)" 2>"$WORK/err")
rc=$?
err=$(cat "$WORK/err")
[ "$rc" = 2 ] && [ -z "$out" ] && [ -n "$err" ] && ok "awk fails: exit 2, nothing on stdout, a word on stderr" ||
  { ko "awk fails: exit 2 (exit $rc, stdout '$out')"; }
out=$(cd "$WORK/fr" && PATH="$WORK/stub:$PATH" "$LINT" "$(F s-4)" 2>"$WORK/err")
rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && ok "awk fails on a refused description: still exit 2" || ko "awk fails on a refused description (exit $rc)"

# --- Usage ----------------------------------------------------------------------------------
usage "no argument"
usage "two files" "$(F witness-206)" "$(F witness-205)"
usage "an absent file" "$WORK/absent.md"
usage "a directory" "$WORK"
usage "--expect with a short digest" --expect abc "$(F witness-206)"
usage "--expect with 40 characters that are not hexadecimal" --expect "$(printf 'g%.0s' $(seq 40))" "$(F witness-206)"
usage "--expect with no value" --expect
usage "--expect twice" --expect "$want" --expect "$want" "$(F witness-206)"
usage "an unknown option" --nope "$(F witness-206)"
usage "--expect and no file" --expect "$want"

if [ "$failures" -gt 0 ]; then
  echo "$failures of $total pr-lint test(s) failed"
  exit 1
fi
echo "all $total pr-lint tests passed"
