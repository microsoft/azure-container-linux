# Maintainer guide: merging changes into release branches

This is a maintainer procedure for pull requests targeting `release/*`.
Ordinary development PRs should target `aclmain`.

## Merge checklist

1. Land the change on `aclmain`. Wait for a completed, successful
   [aclmain pipeline](https://dev.azure.com/mariner-org/ACL/_build/definition?definitionId=5304)
   run: nightly or a full manual run. The skill in step 3 checks its source
   commit and test coverage. For an emergency, use the exception below.
2. Open a PR to `release/*`. Choose a targeted cherry-pick or full promotion
   (below), review the diff, and record the main commit(s) or exact
   candidate and release control.
3. **Cherry-pick:** Run
   [validate-release-cherry-picks](../../../.github/skills/validate-release-cherry-picks/SKILL.md);
   require PASS for every commit. **Full promotion:** Run
   [acl-release-validation](https://dev.azure.com/mariner-org/ACL/_git/acl-pipelines?path=/.github/skills/acl-release-validation/SKILL.md&version=GBmain)
   and retain its candidate/control report. Put the verdict, limitations,
   and any risk decision in the public PR; keep internal run links and
   detailed evidence private.
4. Check that all required PR checks pass and the reviewed head is unchanged.
   If the cherry-pick skill does not PASS, document the specific exception,
   substitute evidence, and release-owner approval below. UNVERIFIED is not
   PASS; do not bypass failing checks.
5. Get JIT **admin** access. Use the merge-method order below and select
   the protected branch's **bypass** checkbox. If bypass is unavailable,
   stop and fix access or protection. After merging, verify only the
   intended changes landed.

## Backport options

- **Targeted cherry-pick:** Preserve each main patch exactly, including
  whitespace, and bring all earlier prerequisites and later fixes needed
  for it to work on the release branch. Check that they remain effective
  after **all** proposed PR commits; a change in the target can be overwritten
  by a cherry-pick. Normally, the qualifying aclmain run must include the
  complete change. Low-risk targeted changes such as tests, docs, or CI may
  skip full release validation with the release owner's risk assessment.
  Changes to images, kernels, packages, or runtime behavior can affect AKS;
  determine the appropriate downstream qualification with the release
  owner rather than assuming it can be skipped. See the
  [follow-on cherry-pick reports](https://dev.azure.com/mariner-org/ACL/_git/acl-pipelines?path=/docs/releases/README.md&version=GBmain)
  for incremental candidate/control assessments. If full validation is
  omitted, state the unassessed downstream risk and release-owner decision
  in the PR description or a merge comment **before merging**. A passing
  aclmain run and cherry-pick check do not establish full release qualification.
- **Full changeset:** Promote the whole qualified `aclmain` candidate, not
  selected commits. Start with the
  [ACL release-validation skill](https://dev.azure.com/mariner-org/ACL/_git/acl-pipelines?path=/.github/skills/acl-release-validation/SKILL.md&version=GBmain),
  then follow the
  [ACL release-validation guidance](https://dev.azure.com/mariner-org/ACL/_git/acl-pipelines?path=/docs/releases/README.md&version=GBmain)
  and its [detailed reference](https://dev.azure.com/mariner-org/ACL/_git/acl-pipelines?path=/.github/skills/acl-release-validation/REFERENCE.md&version=GBmain).
  Compare the exact candidate with the release control, including downstream
  evidence. Record shipped versions in the
  [release history](https://dev.azure.com/mariner-org/ACL/_git/acl-pipelines?path=/docs/release-history.md&version=GBmain).
  The linked examples describe `release/3.0`; for another branch, establish
  its control and requirements with the release owner.

## Merge-method order

- **Targeted cherry-picks: rebase and merge, then merge commit, then squash
  and merge.** Cherry-picks already have different SHAs from their `aclmain`
  sources, so a merge commit cannot restore main ancestry. Rebase keeps
  individual backport commits and a linear release history; retain each
  original main SHA in its commit message for traceability. If rebase is
  unavailable, a merge commit preserves the backport commits but makes
  history non-linear. Squash is last because it collapses individual changes
  and their commit-level traceability.
- **Full promotions: merge commit, then rebase and merge, then squash and
  merge.** A merge commit preserves the original `aclmain` commits and
  shared ancestry, giving later promotions an accurate merge base and
  reducing repeated conflicts; the history will be non-linear. Rebase keeps
  commits separate and history linear, but rewrites their SHAs and loses the
  promoted main ancestry. Squash additionally collapses all commits into
  one. Use either fallback only with an explicit release-owner decision
  accepting the ancestry loss and confirming the candidate/control
  validation remains applicable.

Before using a fallback, compare its resulting tree with the reviewed PR,
confirm necessary prerequisites and follow-ups survive, and retain the
cherry-pick or full-promotion evidence. If the result differs, re-review it
before merging. Switching methods does **not** substitute for the required
bypass permission.

## Exceptions to a cherry-pick skill PASS

Do not treat an unverified result as PASS. These cases need a documented
disposition rather than a blanket waiver:

- **Removal makes a prerequisite irrelevant:** If the PR deletes the only
  code or file that needed an earlier main-branch change, prove in the final
  candidate that no remaining behavior depends on it. Mark the prerequisite
  *not required* with that evidence; do not carry it over just to satisfy a
  mechanical history check. A prerequisite still used by the final candidate
  cannot be waived.
- **Emergency patch:** If the release cannot wait for the usual main/nightly
  sequence or a skill PASS, get an explicit release-owner decision before
  merging. Record the urgency, which gates are being deferred, substitute
  validation, residual risk, and the plan to land and test the fix on
  `aclmain`. This is an exception to the normal path, not a PASS result.
- **Release-specific adaptation or non-textual/merge commit:** If verbatim
  patch comparison cannot establish identity, manually compare the effective
  final change and document why the adaptation is necessary.

Record the decision and evidence in the review record. **Required PR checks
must still pass**, and admin/JIT merge rules still apply. A full `aclmain`
promotion follows the separate release-validation guidance above; it is not
a cherry-pick skill exception.
