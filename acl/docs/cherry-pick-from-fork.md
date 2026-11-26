# Cherry-picking a fork PR for ACL validation

Maintainers can use the [mirror-fork-pr skill](../../.github/skills/mirror-fork-pr/SKILL.md)
to copy a reviewed contributor fork PR to a first-party branch for validation.
The mirror PR is intended to merge after checks and review; the contributor's
original PR remains open for discussion and attribution until the mirror is
verified merged. This workflow is on demand, not an automatic sync.

## Before the first mirror or any refresh

Treat every fork revision as untrusted. Run the security review **before**
copying it to a first-party branch: inspect the full PR diff and each commit's
blobs and messages, including intermediate additions later removed. The skill
specifies the text-only, size, mode, and credential gates. A first-party branch
can run CI with privileges a fork PR does not have. If the review cannot be
completed or the revision is unsafe, do not push it or run validation.

Pin the source PR's head SHA and ordered commit list. Present the findings and
the proposed changes to the requester and obtain approval for **that exact
SHA**. If the head changes, review and approve the new revision first. Fetch
the PR ref through the first-party repository, verify the pinned SHA, then
cherry-pick the approved commits individually in oldest-first order with
`git cherry-pick -x`. Preserve their patches and authorship. Stop on conflicts
or discrepancies rather than inventing a replacement patch.

## Validation and follow-up

Compare the source and mirrored series with `git range-diff`, inspect the
resulting changes, and recheck them for secrets before any push. The skill
describes the branch identity, PR attribution, and contributor notification.
Do not merge either PR automatically.

For a new source revision, refresh the **same** validation PR after another
review and approval. Append-only changes may be pushed normally; a rewritten
source history requires reconstructing the full approved series and updating
the branch only with an exact `--force-with-lease`. If the branch changed
outside this workflow, stop instead of overwriting someone else's work.

After GitHub confirms the mirror merged into the expected default branch,
verify the checks, original authorship, and unchanged source head before
closing the contributor's PR with a single explanatory comment. Never claim
validation passed if required checks failed or are still pending.
