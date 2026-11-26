# Changelog

## 1.0.0

- Apply the same cherry-pick checks to any `release/*` target branch rather
  than assuming one release version.
- Check each release cherry-pick against its original main-branch patch with
  whitespace-sensitive patch IDs, rather than relying on commit titles or an
  aggregate diff.
- Require a successful ACL ADO pipeline run whose GitHub repository resource
  is pinned to a revision containing the complete fix; the pipeline's own
  source revision is not the tested repository revision.
- Audit subsequent changes through the run and current main tip so omitted
  follow-ups cannot be hidden behind a passing build.
- Trace earlier prerequisites and verify that required prerequisites and
  follow-ups survive in the final release candidate, not just the target tip.
- Bound the initial patch search to the release/main split, widening when
  necessary; require effective full build and test coverage for both
  architectures, including on manual runs.
