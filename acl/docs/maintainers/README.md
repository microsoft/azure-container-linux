# Maintainer guide: merging changes into release branches

This is a maintainer procedure for pull requests targeting `release/*`.
Ordinary development PRs should target `aclmain`.

## Qualify the change on aclmain first

Land the complete change on `aclmain` and wait for a **completed, successful
run of the [aclmain nightly pipeline](https://dev.azure.com/mariner-org/70814062-73d6-4295-8e5f-b224172b9c69/_build/definition?definitionId=5304)** that resolved the GitHub ACL source revision containing it.
PR checks or a green run against an older/different source do not replace
nightly qualification. Confirm the run's actual repository pin, not just its
branch name or the pipeline repository's commit.

## Choose the backport scope

- **Cherry-pick** when the change is self-contained. Preserve every proposed
  commit's patch exactly as it landed on `aclmain` (including whitespace).
  Identify the original main commits, carry all required prerequisites and
  later fixes in the correct order, and check that the successful nightly
  tested the *complete* change. Do not treat matching commit messages or an
  equivalent final diff as proof. If release-specific adaptation is necessary,
  flag it for explicit review; the patch-identity gate cannot PASS it as-is.
  Full release validation may be skipped for targeted cherry-picks, but warn
  in the PR that downstream release readiness was not reassessed. A passing
  nightly and cherry-pick check do not establish full release qualification.
- **Take the full changeset** when the release should receive the whole
  `aclmain` candidate rather than selected commits. Review the complete
  difference against the current release tip and follow the
  [ACL release-validation guidance](https://dev.azure.com/mariner-org/ACL/_git/acl-pipelines?path=/docs/releases/README.md&version=GBmain)
  and its [detailed reference](https://dev.azure.com/mariner-org/ACL/_git/acl-pipelines?path=/.github/skills/acl-release-validation/REFERENCE.md&version=GBmain).
  Qualify the exact candidate against the release control, including
  downstream evidence; a successful nightly alone is not a release readiness
  decision. The linked examples describe `release/3.0`: for another
  `release/*` branch, establish the applicable control and requirements with
  the release owner. Do not use a partial backport and call it a full promotion.

## Review and merge

1. Open a PR into the intended `release/*` branch and confirm its target and
   complete diff. All required PR checks must pass. Run the
   [release cherry-pick validation skill](../../../.github/skills/validate-release-cherry-picks/SKILL.md) and require **PASS** for
   cherry-picks. For a full changeset, run it where applicable; if a gate
   cannot PASS or there is a good reason to disregard its result, document
   the precise reason, evidence, and release-owner decision before merging.
   Never interpret UNVERIFIED as PASS.
2. Only a maintainer with the **admin role** can merge a release-branch PR.
   Obtain the required **just-in-time (JIT) admin access** before attempting
   the merge. Do not use elevated access to skip failing PR checks.
3. Prefer **rebase and merge** when it preserves the reviewed changes and
   branch history. In the merge UI, explicitly select the **bypass** checkbox
   required for the protected release branch; this does not waive the PR
   checks or qualification above. If the option is unavailable or the
   proposed merge differs from what was reviewed, stop and resolve that
   before merging.
4. After merging, verify the release branch contains the intended change
   and no unexpected commits.
