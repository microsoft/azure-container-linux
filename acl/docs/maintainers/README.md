# Maintainer guide: merging changes into release branches

This is a maintainer procedure for pull requests targeting `release/*`.
Ordinary development PRs should target `aclmain`.

## Merge checklist

1. Normally, land the complete change on `aclmain`. Wait for a **completed,
   successful [aclmain nightly pipeline](https://dev.azure.com/mariner-org/ACL/_build/definition?definitionId=5304)**
   run whose resolved GitHub ACL source revision includes it. A full manual
   run of the same pipeline also counts when both architectures were built
   and tested with the required coverage. Verify the main SHA, source pin,
   parameters, and effective job/test results; a green PR check, partial
   manual run, or the pipeline repository's commit is not equivalent
   evidence. For an emergency that cannot wait, follow the explicit
   exception process below.
2. Choose a targeted cherry-pick or the full changeset (below). Open a PR
   into the intended `release/*` branch and review its entire diff. Record
   the original main commits and target tip for a cherry-pick, or the exact
   candidate and release control for a full promotion.
3. For cherry-picks, run the
   [validation skill](../../../.github/skills/validate-release-cherry-picks/SKILL.md).
   Review its per-commit PASS report, including prerequisites, follow-ups,
   and tested source pins. For a full promotion, follow the linked
   release-validation guidance and retain its candidate/control report.
   Summarize the result and any limitation in the public PR without linking
   internal reports or runs.
4. Confirm **all required PR checks pass** and the reviewed PR head has not
   changed. If the cherry-pick skill does not PASS, use only a documented
   exception below with substitute evidence and release-owner approval;
   never treat UNVERIFIED as PASS or bypass failing PR checks.
5. A maintainer with the **admin role** must obtain **just-in-time (JIT)**
   access to merge. Prefer **rebase and merge for cherry-picks** and a
   **merge commit for full promotions** so main/release ancestry is
   preserved. Use a reviewed squash fallback only as described below.
   Select the **bypass** checkbox
   required for the protected release branch; it does not waive checks or
   qualification. If bypass is unavailable, stop and resolve access or
   protection before merging. Verify the resulting branch has only the
   intended changes.

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

## Merge-method fallback

For targeted cherry-picks, if rebase and merge is unavailable or cannot
preserve the reviewed changes, **squash and merge** is an option, as used in
[#156](https://github.com/microsoft/azure-container-linux/pull/156). For
full promotions, prefer a **merge commit** to retain common history with
`aclmain`, as in [#121](https://github.com/microsoft/azure-container-linux/pull/121).
If that is unavailable, **rebase and merge** has been used for a full
promotion in [#102](https://github.com/microsoft/azure-container-linux/pull/102),
but only use it after the release owner explicitly accepts losing shared
ancestry and confirms the candidate/control validation still applies.
Before using either fallback, compare the resulting tree with the reviewed
PR, confirm necessary fixes survive, and retain the cherry-pick or
full-promotion evidence because commit identities change. If the proposed
result differs, re-review it before merging. Switching methods does **not**
substitute for the required bypass permission.

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
