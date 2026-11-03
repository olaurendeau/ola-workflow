# GitLab's identities, statuses and merge are measured, not assumed

<!--
DRAFT, not an entry yet. docs/decisions/README.md and tests/decisions.test.sh accept only
accepted, rejected or superseded, and an Evidence that cites something: this file is kept
here, out of the journal, until the human has run scripts/spike/gitlab-forge.sh on gitlab.com
(epic #160, task #161).

To publish it: fill the 14 rows and the sections below from the run, move the file to
docs/decisions/NNNN-gitlab-identities-measured.md (NNNN = the next number), set the Status to
accepted (or rejected if the model fails), set the Date, paste the run in Evidence with the
pull request or issue it was reported on, and add the row to the index of docs/decisions/.
Then delete this comment and this paragraph.
-->

## Status

proposed

## Date

to fill: the day of the run

## Context

The GitLab design of epic #160 (section 1) rests on facts the GitLab documentation does not all
guarantee: a Developer identity is refused the merge into a protected branch but not a commit
status; a status records who wrote it; a CI job named like the review status shows up as the
human's. `scripts/spike/gitlab-forge.sh` measures them, M01 to M14, on gitlab.com. Self-managed
GitLab is not measured (human decision 10 of the epic): nothing below holds for it until
someone runs the script there.

Assumptions put to the test: A1 (no per-endpoint token that could replace the author check),
A2 (a Developer cannot write a status attributed to another user, an overwrite never keeps the
old author), A3 ("Allowed to merge: Maintainers" refuses the Developer's merge and auto-merge),
A6 (a CI job and an external status can be told apart).

## Decision

To fill from the run. It states, in this order:

1. whether the model of section 1 holds as designed (A1, A2, A3, A6), or what changes: if one of
   them is false the epic stops for a revision before #162;
2. the query that gives the latest status of a name on a SHA (M06), and the signal that tells a
   CI job from an external status (M07);
3. the final spelling of the two `glab api` forms, the coordinator's merge and the
   pr-reviewer's status (M08, M10);
4. the identity path the tier offers: a project access token or a dedicated account (M02), and
   whether granular personal access tokens exist (M03).

## Consequences

To fill: what each measure that differs from the design changes in tasks #162 to #172.

| measure | what is measured | observed on gitlab.com |
|---|---|---|
| M01 | the two tokens' users, the bot flag, the GitLab version | |
| M02 | project access tokens on this namespace and tier | |
| M03 | granular personal access tokens | |
| M04 | what the Developer identity can do around an issue and a merge request | |
| M05 | the author of a status, tricks, overwrites | |
| M06 | the human's status, and the query for the latest by name | |
| M07 | a CI job named `agent-review`: author, and job against external status | |
| M08 | merge refused to the bot, 409 on a wrong sha, the squash message | |
| M09 | push options schedule a merge as the human | |
| M10 | glab: token precedence, `:id`, merge default, `-f` typing | |
| M11 | a status before any pipeline, a failed external status | |
| M12 | tag, manual job and pipeline by the bot | |
| M13 | expiry of the two tokens | |
| M14 | the pre-filled PAT page | |

## Evidence

To fill: the whole output of the run of `scripts/spike/gitlab-forge.sh` on gitlab.com, pasted
in the pull request or the issue that records it, and linked here (an address or `#NNN`).
