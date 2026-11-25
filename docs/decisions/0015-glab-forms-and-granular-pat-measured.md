# Les formes glab du statut et de la fusion tiennent ; un PAT granulaire écrit comme son propriétaire, ne lit pas les statuts, et la fusion est une permission à part

## Status

accepted

## Date

2026-11-25

## Context

[0014](0014-gitlab-identities-measured.md) laissait ouvert, pour #165 et #166, ce que la révision 3
de l'epic #160 a confié à #200 : M08 n'avait été mesuré que par curl, M10 n'avait rien conclu de la
forme `glab api`, et M07 n'avait ni le 404 d'un statut externe lu avec le jeton du bot, ni un
refus avec un jeton factice. Cette entrée enregistre la seconde mesure, telle qu'elle a eu lieu :
elle est acceptée comme un enregistrement, pas comme une validation de la conception. 0014 n'est
pas réécrite ; ce qu'elle dit du PAT granulaire et de la fusion est corrigé plus bas.

Où et quand. gitlab.com, le même projet jetable, plan d'espace de noms `opensource`, GitLab
19.7.0-pre (enterprise), `glab` 1.123.0, passage de l'humain du 2026-11-25 (run 20261125100327),
`scripts/spike/gitlab-forge.sh --only forms`, qui ne lance que M15 à M18 après M01 et les
vérifications du projet. Le jeton du bot est le même Developer que dans 0014 (id 44160196), celui
de l'humain a l'id 21899033. La sortie ne contient aucun jeton.

Ce qui n'est pas mesuré, et ne vaut donc pour personne :

- le palier Free de gitlab.com, et GitLab auto-hébergé : le plan mesuré est `opensource` ;
- ce qu'un PAT granulaire **sans** une permission refuse : le jeton mesuré portait toutes celles
  de la liste ci-dessous (ni la fusion sans « Merge », ni un statut sans « Create » ne sont
  exercés) ;
- le PAT granulaire limité au projet, face à un autre projet **privé** : l'autre projet de la
  mesure est public (voir M18), sa lecture ne prouve rien ;
- la forme `-f squash=true` : la fusion se fait ici en `-F`, seule forme mesurée ;
- le bot qui lit la liste des statuts : la liste est lue avec le jeton de l'humain.

Ce que dit l'humain, et que le script n'a pas vu : l'interface des PAT granulaires, d'après sa
capture d'écran du 2026-11-25, liste les permissions des merge requests Approve, Create, Delete,
Merge, Read, Subscribe, Update, séparément ; et, d'après son compte rendu du même jour, le menu
« Commit Status » ne propose que **Create**. La capture n'est pas dans le dépôt.

## Decision

On enregistre les formes et les constats suivants. Ils valent pour gitlab.com, plan `opensource`,
glab 1.123.0.

### M15 : la forme du statut tient

- `glab api --include -X POST projects/<chemin encodé>/statuses/<SHA> -f state=… -f name=… -f
  description=…` : HTTP/2.0 201, code de sortie 0, pour l'humain comme pour le bot. `author.id` dit
  qui l'a écrit : 21899033 pour l'humain, 44160196 pour le bot, trois statuts successifs (humain,
  bot, humain). Sans `--include`, la forme répond de même (code 0, `status` `success`, `author.id`
  de l'humain).
- La liste `GET …/commits/<SHA>/statuses?name=<n>&per_page=100`, sans `all=true`, ne rend
  **qu'une entrée** pour les trois statuts du même nom (la dernière, #18351150092) ; avec
  `all=true` elle en rend **trois** (#18351148630, #18351149626, #18351150092), par `id`
  croissant. Le plus grand `id` est le dernier posté, dans les deux cas. Les trois statuts étaient
  sur une seule référence : 0014 (M06) avait vu que, sans `all=true`, la liste rend une entrée par
  référence ; ce passage ne distingue pas cela d'une entrée par nom. La liste est lue sans
  `--include` (code 0, pas de ligne d'état).
- Le paging n'est toujours pas exercé : trois entrées au plus.

### M16 : un job CI et un statut externe se distinguent

`GET projects/<chemin>/jobs/<id>` avec le jeton du bot : pour un job CI (`agent-review`, id
18351154184) **200** ; pour un statut externe (id 18351156216) **404**, corps « 404 Not found »,
code de sortie 1 ; avec un jeton factice **401**, corps « 401 Unauthorized ». Le 404 d'un statut
externe n'est donc pas « 404 Project Not Found » : le projet est vu, c'est l'objet qui n'est pas
un job. C'est ce que 0014 n'avait pas observé (A6, la moitié « le 404 »).

### M17 : la forme de la fusion tient

`glab api --include -X PUT projects/<chemin encodé>/merge_requests/<N>/merge -F squash=true -f
sha=<SHA>` :

- un `sha` faux : **409** « SHA does not match HEAD of source branch: <sha de la tête> », code 1 ;
- le bot, bon `sha` : **401**, code 1 ; la merge request reste `opened`, non programmée (corps non
  consigné) ;
- l'humain, bon `sha` : **200**, `state` `merged`, `squash_commit_sha` renseigné, et le titre du
  commit de squash est celui de la merge request. `-F squash=true` squashe donc, là où `-f`
  laissait `squash` à `false` en M10 de 0014 (qui ne pouvait pas trancher).

### Comment glab rend les refus

Un 2xx donne le code de sortie 0 ; un 4xx (404, 409, 401, 403) donne 1. Avec `--include`, la ligne
d'état (`HTTP/2.0 404 Not Found`) est dans la sortie de glab, et le corps du refus la suit ;
l'erreur standard ne porte que l'avertissement ci-dessous, rien du refus. glab 1.123.0 écrit sur
l'erreur standard, à chaque appel, `DEPRECATION WARNING: The environment variable NO_PROMPT has
been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.` : le script
règle `NO_PROMPT`. Que `GLAB_NO_PROMPT` fasse taire l'avertissement n'est pas mesuré.

### M18 : le PAT granulaire limité au projet jetable

Permissions cochées : Commit Status : Create ; Merge Request : Read, Update, Merge ; rien d'autre.

- `GET /user` et `GET /personal_access_tokens/self` : **403** `insufficient_granular_scope` (champs
  `error`, `error_description`). Sans aucune permission au niveau de l'utilisateur, le jeton ne
  peut pas dire à qui il est, ni ses portées, ni son expiration (0014, M13, les lisait avec un PAT
  classique).
- Statut créé : **201**, `author.id` = l'humain (21899033). Un PAT granulaire écrit **comme son
  propriétaire**, jamais comme une identité à part.
- Lecture de la liste des statuts : **403** `insufficient_granular_scope`. Le script attendait un
  200 ; le compte rendu de l'humain est que l'interface ne propose que « Create » pour Commit
  Status : un PAT granulaire ne peut pas lire les statuts, la lecture est faite avec un autre
  jeton.
- Lecture de la merge request : 200 ; fusion, bon `sha`, `-F squash=true` : **200**, `merged`,
  `squash_commit_sha` renseigné, avec la permission « Merge ».
- **La fusion est une permission à part** (capture de l'humain, liste ci-dessus). Cela contredit ce
  que 0014 enregistrait comme observation du 2026-11-18, et la révision 3 sur #160 (« la fusion
  n'est pas une permission séparée »), ainsi que l'en-tête du script. La lecture du 2026-11-18 était
  donc fausse, et ce que 0014 en tirait (un PAT granulaire ne peut pas se voir refuser la fusion
  qu'on lui donnerait, donc il ne peut pas être le jeton de base) ne tient plus sur ce motif : voir
  les questions ouvertes.
- Autre projet : la lecture répond 200, mais ce projet est **public** (le coordinator l'a vérifié
  le 2026-11-25 sans jeton : `GET /api/v4/projects/incubateur-territoires%2Fincubateur%2Fola-workflow-spike-other`
  rend 200, visibilité publique). Cette lecture ne prouve donc rien sur la limite. Le statut écrit
  sur cet autre projet : **403** `insufficient_granular_scope` : l'écriture est limitée au projet
  choisi.

## Consequences

- **Les formes de #165 et #166 sont arrêtées, en glab.** Statut et fusion s'écrivent comme
  ci-dessus ; un hook lit le résultat par le code de sortie et par la ligne d'état de `--include`
  (201, 200 ; 401, 403, 404, 409 en refus), jamais en attendant un 403 comme le texte de GitHub. Le
  chemin du projet est encodé (`incubateur-territoires%2F…`). L'avertissement `NO_PROMPT` est sur
  l'erreur standard à chaque appel : un hook ne doit pas lire l'erreur standard comme le signe d'un
  échec.
- **#165, le statut de revue et son auteur.** `author.id` de la réponse et de la liste dit qui a
  écrit ; le dernier statut d'un nom est celui du plus grand `id` de
  `…?name=<n>&per_page=100&all=true` ; sans `all=true`, ne pas s'y fier pour « le dernier », et le
  paging reste à refuser quand la page est pleine. Le signal job / statut externe est `GET
  jobs/<id>` avec le jeton du bot : 200 un job, 404 « 404 Not found » un statut externe. Un PAT
  granulaire pour la revue **écrit** (auteur = l'humain) mais **ne lit pas** les statuts : la
  lecture du dernier statut passe par un autre jeton (la mesure l'a faite avec celui de l'humain ;
  avec celui du bot, elle n'est pas mesurée).
- **#166, la fusion.** La forme tient, 409 sur un `sha` faux, 401 pour le bot. Un jeton granulaire
  qui porte « Merge » fusionne : la fusion peut être donnée ou retirée par permission, ce que 0014
  tenait pour impossible.
- **#167, créer et vérifier les jetons.** La vérification d'identité **ne peut pas** passer par
  `/user` ni par `/personal_access_tokens/self` avec un jeton granulaire minimal (403
  `insufficient_granular_scope`) : ni l'identité, ni l'expiration ne se lisent. Un 403 de cette
  forme dit que le jeton est reconnu (un jeton factice rend 401, M16) sans dire à qui il est ; l'id
  de l'auteur d'un statut créé le montre, mais il faut écrire pour le savoir. Les permissions à
  cocher, d'après l'interface : Commit Status : Create (pas de lecture à demander) ; Merge Request :
  Read, Update, Merge, chacune à part ; limite au projet.
- **#172, les docs** disent : le PAT granulaire écrit comme son propriétaire ; il ne lit pas les
  statuts ; la fusion est une permission séparée ; l'écriture est limitée au projet ; `/user` lui
  est refusé ; et ce qui n'est pas mesuré (le palier Free, GitLab auto-hébergé, un autre projet
  privé, le refus faute d'une permission, `-f squash=true`, `GLAB_NO_PROMPT`).
- **Le coordinator signale à l'architecte, avant #165, la correction de l'observation du
  2026-11-18** : la fusion est une permission séparée. Cette entrée ne redessine rien.

Questions ouvertes (une décision de l'architecte ou de l'humain, pas de cette entrée) :

1. 0014 écartait le PAT granulaire comme jeton de base parce que la fusion n'en était pas
   séparable. Ce motif tombe. Un PAT granulaire sans « Merge » ni « Create » de statut, qui agit
   comme l'humain, peut-il être le jeton de base, ou la conception garde-t-elle un Developer bot ?
   Le refus faute d'une permission n'est pas mesuré.
2. Comme jeton de revue ou de fusion, un PAT granulaire réduit les droits à ce que la tâche fait
   (écrire un statut, ou fusionner), limité au projet. Le choix est à faire pour #167.
3. Comment #167 vérifie-t-il l'identité et l'expiration d'un jeton granulaire minimal, qui ne lit
   ni `/user` ni `/personal_access_tokens/self` : ajouter une permission au niveau de
   l'utilisateur, se fier à la création, ou lire autrement ?
4. Le script de mesure règle encore `NO_PROMPT` (`GLAB_NO_PROMPT` à la place) et son en-tête dit que
   la fusion n'est pas une permission séparée : à corriger dans une tâche à part, pas ici.

## Evidence

La mesure du 2026-11-25 par l'humain sur gitlab.com, dans le projet
`incubateur-territoires/incubateur/ola-workflow-spike` : la tâche
https://github.com/olaurendeau/ola-workflow/issues/200, de l'epic
https://github.com/olaurendeau/ola-workflow/issues/160 (révision 3 :
https://github.com/olaurendeau/ola-workflow/issues/160#issuecomment-6975562802), avec le script de
https://github.com/olaurendeau/ola-workflow/pull/204. Sa sortie entière, jetons masqués (aucun
`glpat-` n'y figure) :

```text
ola-workflow GitLab spike
host:    gitlab.com
project: incubateur-territoires/incubateur/ola-workflow-spike
It will create and delete objects in that project, merge two merge requests into its default
branch (one as the human, one with the granular token if given), write commit statuses there,
and may set that branch's protection to Maintainers.
On incubateur-territoires/incubateur/ola-workflow-spike-other it reads one commit as the human, and tries one read and one status with the granular token.
--other-project: pick a project that does not matter. If the PAT is not limited to the
throwaway project, the status ola-spike-other-refused (success) stays on the last commit of
that project's default branch, with an external pipeline (M11), and the script cannot remove it.
Type the project path to go on: 
run 20261125100327 — 2026-11-25T09:03:27Z
M01 human token is → user o.laurendeau (id 21899033), bot=false
M01 bot token is → user project_88588878_bot_20f0a1049d84d2d816575015d6c409f4 (id 44160196), bot=true
M01 the two identities → different users — ok
M01 GitLab version (GET /version) → 19.7.0-pre revision 0d2e26f699e enterprise=true
Pre project → id 88588878, visibility public, default branch main, merge_method merge, squash_option default_off, only_allow_merge_if_pipeline_succeeds false
Pre namespace plan → opensource
Pre bot role in the project → 30 (30 is Developer)
Pre human role in the project → 50 (40 Maintainer, 50 Owner)
Pre git clone with the human's credentials → ok
Pre protection of main → merge levels 40 (Maintainers) as found
Pre glab version → glab 1.123.0 (5686d7484)
M15 human: glab api --include -X POST …/statuses/<sha> -f state -f name -f description → exit 0; HTTP/2.0 201 Created; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.; author.id 21899033 — ok
M15 bot: glab api --include -X POST …/statuses/<sha> -f state -f name -f description → exit 0; HTTP/2.0 201 Created; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.; author.id 44160196 — ok
M15 human: glab api --include -X POST …/statuses/<sha> -f state -f name -f description → exit 0; HTTP/2.0 201 Created; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.; author.id 21899033 — ok
M15 list: GET …/commits/<sha>/statuses?name=ola-spike-m15&per_page=100 → 1 entries (id/author.id): 18351150092/21899033; first #18351150092, last #18351150092; largest id is the last posted: yes (exit 0; no state line; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.)
M15 list: GET …/commits/<sha>/statuses?name=ola-spike-m15&per_page=100&all=true → 3 entries (id/author.id): 18351148630/21899033, 18351149626/44160196, 18351150092/21899033; first #18351148630, last #18351150092; largest id is the last posted: yes (exit 0; no state line; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.)
M15 human, without --include: glab api -X POST …/statuses/<sha> → exit 0; status success, author.id 21899033
M16 push a branch with a .gitlab-ci.yml job named agent-review, as the human → ok
M16 ids on that SHA: the CI job agent-review, and an external status ola-spike-m16-ext → job 18351154184, status 18351156216
M16 bot: glab api --include projects/<project>/jobs/<id> (a CI job) → exit 0; HTTP/2.0 200 OK; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead. — ok
M16 bot: glab api --include projects/<project>/jobs/<id> (an external status) → exit 1; HTTP/2.0 404 Not Found; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.; body: 404 Not found — ok
M16 dummy: glab api --include projects/<project>/jobs/<id> (a dummy token) → exit 1; HTTP/2.0 401 Unauthorized; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.; body: 401 Unauthorized — ok
M17 merge request ready? → mergeable
M17 human, wrong sha: glab api --include -X PUT …/merge -F squash=true -f sha=<wrong> → exit 1; HTTP/2.0 409 Conflict; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.; body: SHA does not match HEAD of source branch: 4411ba3b5c65ac6d7dc4601a97714bee7d595c9f — ok
M17 bot, right sha: glab api --include -X PUT …/merge -F squash=true -f sha=<sha> → exit 1; HTTP/2.0 401 Unauthorized; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead. — ok
M17 the MR after the bot's attempt → state opened, scheduled false — ok
M17 human, right sha: glab api --include -X PUT …/merge -F squash=true -f sha=<sha> → exit 0; HTTP/2.0 200 OK; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.; state merged, squash_commit_sha bf97f3fefc682ea72b3bdafdb2014c04d6f35c58 — ok
M17 the squash commit's title against the MR's → 'ola-spike 20261125100327 F' — equal
M18 granular: GET /personal_access_tokens/self → HTTP 403 insufficient_granular_scope ; granular absent, scopes , user_id ? (the human is 21899033), expires_at never, fields error,error_description
M18 granular: GET /user → HTTP 403 insufficient_granular_scope ; user ? (id ?), bot false
M18 granular: glab api --include -X POST …/statuses/<sha> → exit 0; HTTP/2.0 201 Created; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.; author.id 21899033 — ok
M18 granular: list, glab api --include projects/<project>/repository/commits/<sha>/statuses?name=ola-spike-m18&per_page=100 → exit 1; HTTP/2.0 403 Forbidden; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.; body: insufficient_granular_scope — differs: expected a 200 (a refusal means 'Commit statuses: read' is not enough or not ticked)
M18 merge request ready? → mergeable
M18 granular: the merge request, glab api --include projects/<project>/merge_requests/<N> → exit 0; HTTP/2.0 200 OK; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.; state opened — ok
M18 granular, right sha: glab api --include -X PUT …/merge -F squash=true -f sha=<sha> → exit 0; HTTP/2.0 200 OK; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.; state merged, squash_commit_sha 10d4c541c77977840ef8218a210d0802d1976ebc — ok
M18 other project: read, glab api --include projects/<other project> → exit 0; HTTP/2.0 200 OK; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.; body: no message — differs: expected a refusal (401, 403 or 404)
M18 other project: a status, glab api --include -X POST projects/<other project>/statuses/<sha> → exit 1; HTTP/2.0 403 Forbidden; stderr: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.; body: insufficient_granular_scope — ok
Cleanup → 5 objects removed or gone; leftovers: none. Commit statuses, pipelines and merged commits stay: delete the project.
```
