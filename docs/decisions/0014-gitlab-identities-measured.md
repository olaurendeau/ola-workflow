# GitLab's identities, statuses and merge are measured on gitlab.com: A1 is false, the model stands

## Status

accepted

## Date

2026-11-12

## Context

The GitLab design of epic #160 (section 1) rests on facts the GitLab documentation does not all
guarantee: a Developer identity is refused the merge into a protected branch but not a commit
status; a status records who wrote it; a CI job named like the review status shows up as the
human's. `scripts/spike/gitlab-forge.sh` measures them, M01 to M14. This entry records what was
measured, as it was measured: it is accepted as a record, not as a validation of the design.

Where and when. gitlab.com, in a throwaway project of the namespace plan `opensource`, GitLab
19.6.0-pre (enterprise), `glab` 1.123.0, run by the human on 2026-11-12 (task #161). A first run
on 2026-11-06 stopped at M07 on two defects of the script, fixed in the same pull request as this
entry; the human's observation in the interface at that first run is used below and says so.

What is not measured, and so holds for nobody until someone runs the script there:

- the Free tier of gitlab.com: the plan measured is `opensource`, which carries the paid
  features. Anything below that depends on the plan (M02, M03) is a fact about `opensource`;
- self-managed GitLab (human decision 10 of the epic);
- anything the script could not observe, listed under "Inconclusive" in the Decision.

The Evidence is the whole output of the run, below.

## Decision

### The assumptions of the design (section 3.9)

| | assumption | verdict | measure |
|---|---|---|---|
| A1 | No per-endpoint PAT on gitlab.com Free or self-managed CE that could replace the author check (D1 = A) | **false**: granular PATs exist on gitlab.com, on the plan measured. Free and CE: not measured | M03 |
| A2 | A Developer bot cannot write a status attributed to another user; the author is the true one; an overwrite changes the author, never keeps the old one | **holds** | M05, M06 |
| A3 | "Allowed to merge: Maintainers" refuses `PUT …/merge` and `auto_merge` to a Developer bot | **holds**, refused with 401, not 403 | M08 |
| A4 | The API is `https://<host>/api/v4` | **holds** on gitlab.com; no other host was tried | every `curl` of the run, M10 |
| A5 | `GITLAB_TOKEN` overrides glab's stored login for the host; empty falls back | **holds** | M10 |
| A6 | A CI job and an external status can be told apart, at least by the job list of the SHA's pipelines | **holds** | M07, M11 |

A7 (project access tokens need Premium; on Free the extra identity is a dedicated account) is not
one of the four that stop the epic. On the plan measured a Developer project access token is
available (M02, HTTP 201, `bot=true`); on Free it is not measured.

The rule of the epic: if A1, A2, A3 or A6 is false, the epic stops and asks the architect for a
revision before #162. **A1 is false as written** (granular PATs exist); A2, A3 and A6 hold. What
the falsity of A1 changes is stated below, with the human's observation of 2026-11-18: the model
stands, and an architect revision folds the measured details into the tasks. Whether the epic
stops is settled: the coordinator decided that it does not, published in revision 3 on #160
(2026-11-18), because the human observed that merging is not a separate permission of a granular
PAT, so the settled model stands. The human still has to confirm that reading, since the letter
of the rule says "stops".

### What A1 being false says, and what it does not

- M03: the PAT objects the API returns carry a field `granular`. The interface of gitlab.com
  offers granular personal access tokens (M03 "in the UI: yes", answered by the human on both
  runs). At the first run the human's answer was: "granular: oui, par projet ; MR autorisable
  sans commit status : oui": a granular PAT can be limited to one project, and one that may open
  merge requests without being allowed to write commit statuses can be made in the form.
- **Observed, not measured: merge is not a separate permission of a granular PAT.** The human
  was asked on 2026-11-18 whether gitlab.com's granular PAT interface can grant the creation or
  the edit of merge requests while denying their merge, and answered no: whoever may create or
  edit merge requests may merge them. (The forge records the meaning of the question, not its
  exact words; the answer is item 13 of
  [revision 3 on #160](https://github.com/olaurendeau/ola-workflow/issues/160#issuecomment-6975562802).)
  This is the human's reading of the interface. No granular token was created or used, by the run or
  after it, so no refusal or success of a merge by a granular token was ever exercised. The
  consequence, on that observation: a granular PAT acting as the human cannot serve as the
  agents' base token, since the protected branch does not refuse the human's own merge. The base
  token stays a Developer identity (a project access token's bot, or a dedicated account), the
  review and the merge tokens stay the human's own, and the author check stays: the model of
  section 1 stands. What a granular PAT could still be is a narrower form of the human's own
  review or merge token, which is a matter for #167.
- `POST /user/personal_access_tokens` (read_api, one day) answered 400 "scopes does not have a
  valid value": the API route to create one was not explored, only the interface was seen.
- Whether the Free tier and self-managed CE have granular PATs: not measured.

### What was measured

| measure | observed on gitlab.com (plan `opensource`) |
|---|---|
| M01 | The two tokens are two users: the human, and a project access token's bot (`bot=true`). GitLab 19.6.0-pre, `enterprise=true`. In the project, the bot is Developer (30) and the human Owner (50). |
| M02 | A Developer project access token can be created and revoked (HTTP 201, 204): on this plan the bot can be a project access token. Free: not measured. |
| M03 | PAT objects have a field `granular`. The interface offers granular PATs (see above). The API creation route answered 400, see above. |
| M04 | The bot, a Developer, can create an issue, create the label `RFR`, label an issue, open a merge request, edit its description, add and remove an MR label, and add a note (HTTP 200/201). The branch is pushed with the human's git credentials. |
| M05 | A status posted by the bot is authored by the bot. `author_id`, `user_id`, `user`, `username`, `created_by` and `author[username]` set to the human are ignored (HTTP 201, author still the bot, none refused). Re-posting the same state gives a new entry. The bot posting `success` after the human's `failed` of the same name is authored by the bot; the human posting after the bot's is authored by the human: an overwrite changes the author. |
| M06 | A status posted by the human is authored by the human. Posts of one name with two `ref` values stay two entries. `GET …/commits/:sha/statuses?name=N` returns one entry per ref (2 of 3 posts); with `all=true` it returns all 3; `ref=` filters. The latest by `id` among `all=true` is the last one written. |
| M07 | A `.gitlab-ci.yml` job named `agent-review`, in the pipeline of the human's push, appears among the commit statuses of the SHA, authored by the human, with a `pipeline_id`, and as a job of `GET /pipelines/:id/jobs`; `GET /projects/:id/jobs/:status_id` answers 200 for it. The bot posting an external status of the same name on that SHA is refused: HTTP 400 `{"name":["has already been taken"]}`. |
| M08 | The bot's `PUT …/merge`, with `auto_merge=true` and with `merge_when_pipeline_succeeds=true`: HTTP 401 each time, the MR stays opened and not scheduled. The human with a wrong `sha`: 409 "SHA does not match HEAD of source branch". The human with the right `sha` and `squash=true`: merged (200), and the squash commit's title equals the MR's title. |
| M09 | With the human's credentials, `git push -o merge_request.create -o merge_request.merge_when_pipeline_succeeds` and `-o merge_request.auto_merge` each open an MR whose merge is scheduled, by the human. GitLab refuses neither. |
| M10 | `glab` logs in with `--stdin` into a scratch `GLAB_CONFIG_DIR` (the human's own configuration untouched). With no `GITLAB_TOKEN` it acts as the stored login; with `GITLAB_TOKEN=<bot>` as the bot; with it empty it falls back to the stored login; with `GITLAB_HOST` outside any repository and `GITLAB_TOKEN=<bot>`, as the bot. The rest of M10 is inconclusive, see below. |
| M11 | Before any status the SHA has no pipeline. The bot's first external status creates one, of source `external`, which follows the status (`success`, then `failed`). A last `failed` external status leaves the MR's head pipeline `failed`. Whether that blocks the human's merge is inconclusive, see below. |
| M12 | The bot can create an unprotected tag (201), create a pipeline on a non-protected branch (201) and play a manual job there (200). On the protected default branch it cannot create a pipeline (400, "You do not have sufficient permission to run a pipeline on 'main'") nor play a manual job (403). A protected tag is refused with 400. |
| M13 | `GET /personal_access_tokens/self` works for the human's PAT and for the bot's token: scope `api`, active, `expires_at` 2026-12-06 for both. |
| M14 | The PAT creation page opens pre-filled (by hand: yes). |

### The two answers section 1 asked for

- **The latest status of a name on a SHA** (M06): `GET /projects/:id/repository/commits/:sha/statuses?name=<name>&all=true`, sorted by `id`, the last one. Without `all=true` GitLab returns only the latest entry of each `ref` (M06: 2 entries of 3 posts): the older success of the branch (#…827) is dropped, while the branch's latest (#…417) and the one on `main` (#…155) are there. The default list is one entry per ref, so it does not say which is the latest overall; `all=true` lists every entry and the highest `id` is the latest. The list is paged, and past one page the highest `id` may be on another page: this run never held more than 3 entries, so the paging was not exercised. Revision 3 of #160 plans `per_page=100` and a refusal when the page comes back full.
- **A CI job against an external status** (M07, M11): a job is in `GET /pipelines/:id/jobs` of a pipeline of the SHA, and `GET /projects/:id/jobs/:id` answers 200 for its status id; an external status creates a pipeline of source `external` (M11). Whether that pipeline holds a job was not measured: M11 lists the pipelines of the SHA, never the jobs of pipeline 3060366310. The converse, `GET /jobs/:id` answering 404 for an external status, was not observed in this run: the only status read there was the job's.
- A CI job named like the review status carries the human's name as author (M07). It would pass an author check alone: the check has to read the job signal too.

### The forms, as far as they are settled

Over raw HTTP, with the token on curl's standard input, the run settled:

- the status: `POST /projects/:id/statuses/:sha` with `state`, `name` and optionally `ref`; the author is the token's user whatever else is sent (M05);
- the merge: `PUT /projects/:id/merge_requests/:iid/merge` with `sha=<head sha>` and `squash=true`: 409 on a wrong `sha`, 200 on the right one, the squash title is the MR's (M08).

The `glab api` spelling of these two forms is **not settled**: M10 could not measure it, see below. It has to be measured again before #165 and #166 write it into a hook.

### Inconclusive

- **M11, the merge status.** `merge_status` and `detailed_merge_status` stayed `unchecked`, with "Pipelines must succeed" off and on. Whether a red external status blocks the human's merge in the interface is not measured. The gate of the design reads checks itself and does not depend on it.
- **M10, which remote `:id` resolves to.** `glab api projects/:id`, with an `upstream` remote pointing at an absent project and an `origin` pointing at the project, answered nothing: it does not say which remote was used, and may mean glab could not resolve `:id` at all. The next two lines of M10 ran in that same repository, so they are inconclusive too: `-f squash=true` left the MR's `squash` at `false`, and `-F squash=false` leaves it at `false`, which is also the default (it cannot tell a typed field from a string).
- **M10, `glab mr merge --yes`.** It errored; the message was cut after a deprecation warning (glab 1.123.0 deprecates `NO_PROMPT`, which the script sets, for `GLAB_NO_PROMPT`). The MR stayed opened and not scheduled. What `glab mr merge` does by default with a pending pipeline (merge now, or schedule) is not measured.
- **M08, the state of the MR.** It was `unchecked` when the bot's merges were refused. The human then merged the same MR, which says the refusal was about who asked, not about the MR; it is the only control there is.
- **The run hung** for a while before the first line of M08 and then went on; the cause is not established (a credential prompt is the unverified guess).

### Deviations from what the design expected

- **M08**: the bot's merge is refused with **401**, not 403. GitLab answers 401 for a user that may not merge. The hook and the brief of #166 must read a refusal as 401 or 403, and not wait for a 403 as the GitHub text does.
- **M12**: a protected tag refused to the bot gives **400**, not 401 or 403.
- **M05**: the tricks are not refused (the design allowed "ignored or refused"): GitLab ignores them silently, with a 201.

## Consequences

- **The model stands, per the human's observation; the epic does not stop.** A1 is false as written, but a granular PAT cannot be denied the merge it could otherwise be given (observation of 2026-11-18, no granular token created or used), so it cannot be the agents' base token. One Developer bot as base, the human's tokens for review and merge, and the author check stay. The coordinator decided not to stop the epic, published in revision 3 on #160 (2026-11-18), for that reason: merging is not a separate permission of a granular PAT, so the settled model stands. The human has yet to confirm it. The architect's revision folds the measured details into the tasks.
- A2, A3, A6 hold, so the identity-based model of section 1 works on gitlab.com as designed, on the plan measured. The revision still has to take in what differs from the design (the 401, the `glab api` forms not settled, the inconclusive measures).
- #165 (the review status): the query for the latest by name and the job-against-status signal are above. The author recorded cannot be forged by a field (A2). A CI job named `agent-review` has the human as author: the check reads the job signal as well. The `glab api` spelling has to be re-measured.
- #166 (the merge): refusal is 401 for the bot; a wrong `sha` is 409; `squash=true` gives the MR title. The pending pipeline default of `glab mr merge` is not measured: the form never relies on it. The gate does not count on "Pipelines must succeed" (M11 inconclusive).
- #164 (the session): `GITLAB_TOKEN` overrides the stored login, empty falls back, `GITLAB_HOST` works outside a repository (A5).
- #167 (tokens): `GET /personal_access_tokens/self` gives the expiry of both kinds (M13); the PAT page pre-fills (M14); whether the pre-fill carries granular permissions is not measured. If the revision keeps a granular PAT as a narrower review or merge token of the human, #167 pre-fills it instead of `api`.
- The hook of section 3.5 (the push options): M09 confirms the hole (D2): both options schedule a merge as the human and GitLab refuses neither.
- #172 (the docs) says what this entry says is not measured: the Free tier, self-managed GitLab, and everything inconclusive above.
- To re-measure before #165 and #166: M10 with `origin` as the only remote, `-F squash=true` on a merge request, `glab mr merge`'s message in full. The script is left as it is for it.

## Evidence

The run of 2026-11-12 by the human on gitlab.com, in the project
`incubateur-territoires/incubateur/ola-workflow-spike`: the issue
https://github.com/olaurendeau/ola-workflow/issues/161 (the comment
https://github.com/olaurendeau/ola-workflow/issues/161#issuecomment-6975005804), for the epic
https://github.com/olaurendeau/ola-workflow/issues/160. Its whole output, tokens masked (no
`glpat-` appears in it):

```text
ola-workflow GitLab spike
host:    gitlab.com
project: incubateur-territoires/incubateur/ola-workflow-spike
It will create and delete objects in that project, merge up to four merge requests into its
default branch (with a .gitlab-ci.yml), may set that branch's protection to Maintainers and
briefly require a green pipeline to merge.
Type the project path to go on: 
run 20261112164426 — 2026-11-12T15:44:26Z
M01 human token is → user o.laurendeau (id 21899033), bot=false
M01 bot token is → user project_88588878_bot_20f0a1049d84d2d816575015d6c409f4 (id 44160196), bot=true
M01 the two identities → different users — ok
M01 GitLab version (GET /version) → 19.6.0-pre revision c06dfd43dff enterprise=true
Pre project → id 88588878, visibility public, default branch main, merge_method merge, squash_option default_off, only_allow_merge_if_pipeline_succeeds false
Pre namespace plan → opensource
Pre bot role in the project → 30 (30 is Developer)
Pre human role in the project → 50 (40 Maintainer, 50 Owner)
Pre git clone with the human's credentials → ok
Pre protection of main → merge levels 40 (Maintainers) as found
M02 list project access tokens → HTTP 200
M02 create a Developer project access token (revoked at once) → HTTP 201 — available on this namespace: the bot can be a project access token
M02 revoke it → HTTP 204
M03 fields of a PAT as the API answers (human) → active,created_at,description,expires_at,granular,id,last_used_at,last_used_ips,name,revoked,scopes,user_id
M03 a field about permissions or granularity in it → granular
M03 POST /user/personal_access_tokens (read_api, one day) → HTTP 400 scopes does not have a valid value ; fields: error; granular-looking: none
M03 granular PAT permissions in the UI on gitlab.com → yes
M04 bot: create issue → HTTP 201 — ok
M04 bot: create label RFR (409 means it existed) → HTTP 201
M04 bot: label the issue → HTTP 200 labels=RFR — ok
M04 human git credentials: push a branch → ok — ok
M04 bot: open a merge request → HTTP 201 — ok
M04 bot: edit the MR description → HTTP 200 — ok
M04 bot: add the MR label RFR → HTTP 200 labels=RFR — ok
M04 bot: remove the MR label RFR → HTTP 200 labels= — ok
M04 bot: note on the MR → HTTP 201 — ok
M05 bot: POST status success → HTTP 201 author project_88588878_bot_20f0a1049d84d2d816575015d6c409f4 — ok
M05 bot: POST the same name failed → HTTP 201 status failed author project_88588878_bot_20f0a1049d84d2d816575015d6c409f4 — ok
M05 bot: POST a status with author_id set to the human (ignored or refused) → HTTP 201 author project_88588878_bot_20f0a1049d84d2d816575015d6c409f4 — ok
M05 bot: POST a status with user_id set to the human (ignored or refused) → HTTP 201 author project_88588878_bot_20f0a1049d84d2d816575015d6c409f4 — ok
M05 bot: POST a status with user set to the human (ignored or refused) → HTTP 201 author project_88588878_bot_20f0a1049d84d2d816575015d6c409f4 — ok
M05 bot: POST a status with username set to the human (ignored or refused) → HTTP 201 author project_88588878_bot_20f0a1049d84d2d816575015d6c409f4 — ok
M05 bot: POST a status with created_by set to the human (ignored or refused) → HTTP 201 author project_88588878_bot_20f0a1049d84d2d816575015d6c409f4 — ok
M05 bot: POST a status with author[username] set to the human (ignored or refused) → HTTP 201 author project_88588878_bot_20f0a1049d84d2d816575015d6c409f4 — ok
M05 bot: re-post an already posted state (success on a failed one, then success again) → HTTP 201 status success author project_88588878_bot_20f0a1049d84d2d816575015d6c409f4
M05 bot: re-post the same state a second time → HTTP 201 status success author project_88588878_bot_20f0a1049d84d2d816575015d6c409f4
M05 bot posts success after the human's failed, same name: the author → HTTP 201 status success author project_88588878_bot_20f0a1049d84d2d816575015d6c409f4 — ok
M05 human posts success after the bot's failed, same name → HTTP 201 status success author o.laurendeau
M06 human: POST status success (ref the branch) → HTTP 201 author o.laurendeau — ok
M06 human: POST the same name with another ref and the state failed → HTTP 201 status failed author o.laurendeau pipeline 3060367224
M06 human: POST the same name again with the first ref → HTTP 201 status success pipeline 3060366310
M06 GET .../statuses?name=agent-review-m06 → HTTP 200; 2 entries: agent-review-m06:failed:o.laurendeau@main#17975025155 | agent-review-m06:success:o.laurendeau@ola-spike-20261112164426-a#17975025417
M06 GET .../statuses?name=agent-review-m06&all=true → HTTP 200; 3 entries: agent-review-m06:success:o.laurendeau@ola-spike-20261112164426-a#17975024827 | agent-review-m06:failed:o.laurendeau@main#17975025155 | agent-review-m06:success:o.laurendeau@ola-spike-20261112164426-a#17975025417
M06 GET .../statuses?name=agent-review-m06&ref=ola-spike-20261112164426-a → HTTP 200; 1 entries: agent-review-m06:success:o.laurendeau@ola-spike-20261112164426-a#17975025417
M06 GET .../statuses?name=agent-review-m06&ref=main → HTTP 200; 1 entries: agent-review-m06:failed:o.laurendeau@main#17975025155
M06 GET .../statuses?name=agent-review-m06&all=true&ref=ola-spike-20261112164426-a → HTTP 200; 2 entries: agent-review-m06:success:o.laurendeau@ola-spike-20261112164426-a#17975024827 | agent-review-m06:success:o.laurendeau@ola-spike-20261112164426-a#17975025417
M06 the latest by id among all=true → agent-review-m06:success:o.laurendeau@ola-spike-20261112164426-a#17975025417
M07 push a branch with a .gitlab-ci.yml job named agent-review, as the human → ok
M07 the pipeline of that push → 1: 3060367931/push/pending
M07 jobs of the pipeline (GET /pipelines/:id/jobs) → manual-job:manual, agent-review:pending
M07 bot: POST an external status named agent-review on the same SHA → HTTP 400 {"name":["has already been taken"]}  author no author pipeline ?
M07 pipelines of that SHA now → 1: 3060367931/push/pending
M07 commit statuses named agent-review (all=true) → 1 entries: agent-review:pending:o.laurendeau@ola-spike-20261112164426-ci#17975030226
M07 status #17975030226: author o.laurendeau pipeline 3060367931 allow_failure ? keys allow_failure,author,coverage,created_at,description,finished_at,id,name,pipeline_id,ref,sha,started_at,status,target_url → GET /projects/:id/jobs/17975030226 → HTTP 200 (200 is a CI job, 404 an external status)
M08 merge request ready? → unchecked
M08 bot: PUT merge (protected branch, Maintainers) → HTTP 401 401 Unauthorized  — ok
M08 bot: PUT merge with auto_merge=true → HTTP 401 401 Unauthorized  — ok
M08 bot: PUT merge with merge_when_pipeline_succeeds=true → HTTP 401 401 Unauthorized  — ok
M08 the MR after the bot's attempts → state opened, scheduled false — ok
M08 human: PUT merge with a wrong sha → HTTP 409 SHA does not match HEAD of source branch: fad0318ce7c8879a73c9ab7177a1c5153ed220f0  — ok
M08 human: PUT merge with the right sha and squash=true → HTTP 200 state merged
M08 the commit title (squash_commit_sha) against the MR title 'ola-spike 20261112164426 M' → 'ola-spike 20261112164426 M' — equal
M09 git push -o merge_request.create -o merge_request.merge_when_pipeline_succeeds (human's credentials) → MR !3 state opened, scheduled true, by o.laurendeau — ok
M09 git push -o merge_request.create -o merge_request.auto_merge (human's credentials) → MR !4 state opened, scheduled true, by o.laurendeau — ok
M10 glab version → glab 1.123.0 (5686d7484)
M10 glab auth login --stdin into a scratch config (the human's PAT) → exit 0
M10 the login landed in the scratch GLAB_CONFIG_DIR → yes — ok
M10 no GITLAB_TOKEN: the stored login acts as → o.laurendeau — ok
M10 GITLAB_TOKEN=<bot> over the stored login acts as → project_88588878_bot_20f0a1049d84d2d816575015d6c409f4 — ok
M10 GITLAB_TOKEN empty: falls back to the stored login, acts as → o.laurendeau — ok
M10 GITLAB_HOST=gitlab.com outside any repository, GITLAB_TOKEN=<bot>, acts as → project_88588878_bot_20f0a1049d84d2d816575015d6c409f4 — ok
M10 glab api projects/:id with remotes upstream (absent project) and origin (incubateur-territoires/incubateur/ola-workflow-spike) →  — upstream was used, or glab could not tell
M10 glab api -f squash=true (a string field) leaves the MR's squash at → false (a JSON boolean in the answer: not coerced)
M10 glab api -F squash=false (a typed field) leaves it at → false
M10 glab mr merge 5 --yes (pipeline pending): the default is → state opened, scheduled false; glab said: DEPRECATION WARNING: The environment variable NO_PROMPT has been deprecated and will be removed in future releases. Use GLAB_NO_PROMPT instead.               ERROR   
M11 pipelines of the SHA before any status → 0: 
M11 …after the bot's first status (success) → 1: 3060366310/external/success
M11 …after the bot's failed status → 1: 3060366310/external/failed
M11 bot: POST a last failed status (agent-review-m11) on the MR's head pipeline 3060366310 → HTTP 201 pipeline 3060366310
M11 the MR after that failed external status, 'Pipelines must succeed' = false (as found) → unchecked; head pipeline failed, detailed_merge_status unchecked, merge_status unchecked
M11 human: require a green pipeline to merge (put back right after) → HTTP 200 now true
M11 the same MR with 'Pipelines must succeed' on → unchecked; head pipeline failed, detailed_merge_status unchecked, merge_status unchecked
M11 human: put 'Pipelines must succeed' back to false → HTTP 200 now false
M12 bot: create an unprotected tag → HTTP 201
M12 human: protect the tag pattern ola-spike-20261112164426-t-prot-* (Maintainers) → HTTP 201
M12 bot: create a protected tag → HTTP 400 You are not allowed to create this tag as it is protected.  — differs: expected 401 or 403
M12 bot: create a pipeline on the CI branch → HTTP 201
M12 bot: play the manual job of an unprotected branch → HTTP 200
M12 bot: create a pipeline on the protected branch → HTTP 400 {"base":["You do not have sufficient permission to run a pipeline on 'main'. Please select a different branch or contact your administrator 
M12 bot: play the manual job on the protected branch main (pipeline 3060377263) → HTTP 403 403 Forbidden 
M13 human token: GET /personal_access_tokens/self → HTTP 200 expires_at 2026-12-06, scopes api, active true
M13 bot token: GET /personal_access_tokens/self → HTTP 200 expires_at 2026-12-06, scopes api, active true
M14 the PAT creation page pre-filled → yes
Cleanup → 16 objects removed or gone; leftovers: none. Commit statuses, pipelines and merged commits stay: delete the project.
```
