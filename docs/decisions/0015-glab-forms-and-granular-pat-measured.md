# The glab forms for status and merge hold; a granular PAT writes as its owner, one without Commit: Read is refused the status list, and merge is a separate permission

## Status

accepted

## Date

2026-11-25

## Context

[0014](0014-gitlab-identities-measured.md) left open, for #165 and #166, what revision 3 of epic #160
handed to #200: M08 had only been measured with curl, M10 had concluded nothing about the `glab api`
form, and M07 had neither the 404 of an external status read with the bot's token nor a refusal with
a dummy token. This entry records the second measurement as it happened: it is accepted as a record,
not as a validation of the design. 0014 is not rewritten; what it says about the granular PAT and
about merge is corrected below.

Where and when. gitlab.com, the same throwaway project, namespace plan `opensource`, GitLab
19.7.0-pre (enterprise), `glab` 1.123.0, run by the human on 2026-11-25 (run 20261125100327),
`scripts/spike/gitlab-forge.sh --only forms`, which only runs M15 to M18 after M01 and the project
checks. The bot's token is the same Developer as in 0014 (id 44160196); the human's has id 21899033.
The output contains no token.

What was not measured, and so holds for nobody:

- the Free tier of gitlab.com, and self-managed GitLab: the plan measured is `opensource`;
- what a granular PAT **without** a given permission is refused, except one case (the status list,
  below): the token measured carried the permissions listed below, so merge without "Merge" and a
  status without "Create" were not exercised;
- whether "Commit: Read" lets a granular PAT list statuses: the token measured did not have it, and
  the list was refused (M18);
- the project-limited granular PAT against another **private** project: the other project of the
  measurement is public (see M18), so reading it proves nothing;
- the `-f squash=true` form: the merge is done here with `-F`, the only form measured;
- the bot reading the status list: the list is read with the human's token.

What comes from the human and not from the script. The script's output does not say which
permissions the granular token carried; the list below is the human's, from their screenshot of the
granular PAT interface of 2026-11-25, which lists the merge request permissions Approve, Create,
Delete, Merge, Read, Subscribe, Update, separately, and from their report of the same day that the
"Commit Status" menu offers only **Create**. The screenshot is not in the repository. GitLab's REST
permission documentation, as the review of this record read it, puts
`GET …/repository/commits/:sha/statuses` under "Commit: Read", a permission that was not ticked;
the run did not check that page.

## Decision

We record the following forms and findings. They hold for gitlab.com, plan `opensource`, glab
1.123.0.

### M15: the status form holds

- `glab api --include -X POST projects/<encoded path>/statuses/<SHA> -f state=… -f name=… -f
  description=…`: HTTP/2.0 201, exit code 0, for the human as for the bot. `author.id` says who
  wrote it: 21899033 for the human, 44160196 for the bot, three successive statuses (human, bot,
  human). Without `--include`, the form answers the same way (code 0, `status` `success`, the
  human's `author.id`).
- The list `GET …/commits/<SHA>/statuses?name=<n>&per_page=100`, without `all=true`, returns
  **only one entry** for the three statuses of the same name (the last, #18351150092); with
  `all=true` it returns **three** (#18351148630, #18351149626, #18351150092), by increasing `id`.
  The largest `id` is the last posted, in both cases. The three statuses were on a single reference:
  0014 (M06) had seen that, without `all=true`, the list returns one entry per reference; this run
  does not tell that apart from one entry per name. The list is read without `--include` (code 0, no
  status line).
- Paging is still not exercised: three entries at most.

### M16: a CI job and an external status can be told apart

`GET projects/<path>/jobs/<id>` with the bot's token: for a CI job (`agent-review`, id 18351154184)
**200**; for an external status (id 18351156216) **404**, body "404 Not found", exit code 1; with a
dummy token **401**, body "401 Unauthorized". The 404 of an external status is therefore not "404
Project Not Found": the project is seen, it is the object that is not a job. This is what 0014 had
not observed (A6, the "404" half).

### M17: the merge form holds

`glab api --include -X PUT projects/<encoded path>/merge_requests/<N>/merge -F squash=true -f
sha=<SHA>`:

- a wrong `sha`: **409** "SHA does not match HEAD of source branch: <head sha>", code 1;
- the bot, right `sha`: **401**, code 1; the merge request stays `opened`, not scheduled (body not
  recorded);
- the human, right `sha`: **200**, `state` `merged`, `squash_commit_sha` filled in, and the title of
  the squash commit is the merge request's. `-F squash=true` therefore squashes, where `-f` left
  `squash` at `false` in 0014's M10 (which could not settle it).

### How glab renders refusals

A 2xx gives exit code 0; a 4xx (404, 409, 401, 403) gives 1. With `--include`, the status line
(`HTTP/2.0 404 Not Found`) is in glab's output, and the body of the refusal follows it; standard
error carries only the warning below, nothing of the refusal. glab 1.123.0 writes to standard error,
on every call, `DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will
be removed in future releases. Use GLAB_NO_PROMPT instead.`: the script sets `NO_PROMPT`. Whether
`GLAB_NO_PROMPT` silences the warning was not measured.

### M18: the granular PAT limited to the throwaway project

Permissions ticked (the human's list, see Context): Commit Status: Create; Merge Request: Read,
Update, Merge; nothing else.

- `GET /user` and `GET /personal_access_tokens/self`: **403** `insufficient_granular_scope` (fields
  `error`, `error_description`). With no user-level permission at all, the token cannot say who it
  is, nor its scopes, nor its expiry (0014, M13, read them with a classic PAT).
- Status created: **201**, `author.id` = the human (21899033). A granular PAT writes **as its
  owner**, never as a separate identity.
- Reading the status list: **403** `insufficient_granular_scope`. The script expected a 200. What was
  measured is that a token without "Commit: Read" is refused the list. Whether "Commit: Read" lets a
  granular PAT list statuses was not measured: the human's report is that the "Commit Status" menu
  offers only "Create", but GitLab's REST permission documentation puts that list under "Commit:
  Read", which was not ticked.
- Reading the merge request: 200; merge, right `sha`, `-F squash=true`: **200**, `merged`,
  `squash_commit_sha` filled in, with the "Merge" permission.
- **Merge is a separate permission** (the human's screenshot, list above). This contradicts what
  0014 recorded as the observation of 2026-11-18, and revision 3 on #160 ("merging is not a
  separate permission"), as well as the script's header. The reading of 2026-11-18 was therefore
  wrong, and what 0014 drew from it (a granular PAT cannot be denied the merge it would be given,
  so it cannot be the base token) no longer holds on that ground: see the open questions.
- Other project: the read answers 200, but that project is **public** (the coordinator checked it
  on 2026-11-25 without a token: `GET /api/v4/projects/incubateur-territoires%2Fincubateur%2Fola-workflow-spike-other`
  returns 200, public visibility). That read therefore proves nothing about the limit. The status
  written to that other project: **403** `insufficient_granular_scope`: writing is limited to the
  chosen project.

## Consequences

- **The forms for #165 and #166 are settled, in glab.** Status and merge are written as above; a
  hook reads the result by the exit code and by the status line of `--include` (201, 200; 401, 403,
  404, 409 as refusals), never by waiting for a 403 as GitHub's text does. The project path is
  encoded (`incubateur-territoires%2F…`). The `NO_PROMPT` warning is on standard error on every
  call: a hook must not read standard error as a sign of failure.
- **#165, the review status and its author.** The response's `author.id`, and the list's, say who
  wrote; the latest status of a name is the one with the largest `id` of
  `…?name=<n>&per_page=100&all=true`; without `all=true`, do not rely on it for "the latest", and
  paging is still to be refused when the page is full. The job / external status signal is `GET
  jobs/<id>` with the bot's token: 200 a job, 404 "404 Not found" an external status. A granular PAT
  for review **writes** (author = the human); the token measured, without "Commit: Read", was
  **refused** the status list. Whether it reads with "Commit: Read" is not measured, so a second
  token for reading is not established: measure that before building one (the list was measured
  with the human's token; with the bot's it was not).
- **#166, the merge.** The form holds, 409 on a wrong `sha`, 401 for the bot. A granular token that
  carries "Merge" merges: merging can be given or withdrawn by permission, which 0014 held to be
  impossible.
- **#167, creating and checking tokens.** Checking identity **cannot** go through `/user` or
  `/personal_access_tokens/self` with a minimal granular token (403 `insufficient_granular_scope`):
  neither identity nor expiry can be read. A 403 of that form says the token is recognised (a dummy
  token gets 401, M16) without saying whose it is; the author id of a status created shows it, but
  writing is needed to know. The permissions ticked on the token measured, per the human: Commit
  Status: Create; Merge Request: Read, Update, Merge, each separately; limited to the project. Which
  permission lets a granular PAT list statuses ("Commit: Read" is the candidate) is to be measured
  before #167 builds a second token for reading.
- **#172, the docs** say: the granular PAT writes as its owner; a token without "Commit: Read" was
  refused the status list, and whether "Commit: Read" allows it is not measured; merge is a separate
  permission; writing is limited to the project; `/user` is refused to it; and what was not measured
  (the Free tier, self-managed GitLab, another private project, the refusal for lack of a permission
  other than the status list, whether "Commit: Read" lets a granular PAT list statuses,
  `-f squash=true`, `GLAB_NO_PROMPT`).
- **The coordinator tells the architect, before #165, of the correction to the observation of
  2026-11-18**: merge is a separate permission. This entry redesigns nothing.

Open questions (a decision for the architect or the human, not for this entry):

1. 0014 set the granular PAT aside as the base token because merge could not be separated from it.
   That ground falls. Can a granular PAT without "Merge" and without status "Create", acting as the
   human, be the base token, or does the design keep a Developer bot? The refusal for lack of a
   permission is not measured, except for the status list.
2. As a review or merge token, a granular PAT narrows the rights to what the task does (write a
   status, or merge), limited to the project. The choice is for #167. For review, does the design
   need a second token for reading statuses, or does "Commit: Read" on the same token do? The run
   does not say.
3. How does #167 check the identity and expiry of a minimal granular token, which reads neither
   `/user` nor `/personal_access_tokens/self`: add a user-level permission, trust the creation, or
   read another way?
4. The measuring script still sets `NO_PROMPT` (`GLAB_NO_PROMPT` instead) and its header says merge
   is not a separate permission: to be fixed in a separate task, not here.

## Evidence

The human's measurement of 2026-11-25 on gitlab.com, in the project
`incubateur-territoires/incubateur/ola-workflow-spike`: the task
https://github.com/olaurendeau/ola-workflow/issues/200, of the epic
https://github.com/olaurendeau/ola-workflow/issues/160 (revision 3:
https://github.com/olaurendeau/ola-workflow/issues/160#issuecomment-6975562802), with the script of
https://github.com/olaurendeau/ola-workflow/pull/204. Its whole output, tokens masked (no `glpat-`
appears in it):

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
