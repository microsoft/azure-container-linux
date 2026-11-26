# GitHub releases for Azure Container Linux

The [publish-acl-release skill](../../.github/skills/publish-acl-release/SKILL.md)
helps a maintainer draft and publish a GitHub Release for each **published
image version**. A new image version still needs a release when it reuses an
earlier ACL source commit. The skill is a review procedure, not an automatic
release workflow: it does not publish on merge or on a schedule.

## Before starting

- From the published image's release record, copy the **publisher pipeline
  run URL**. Supply that link to the skill; it resolves the image version
  and ACL source commit from the run and its linked producer records. You
  need not provide both manually. Identify the intended release branch if
  the records cannot establish it.
- Have access to the exact AMD64 and ARM64 build/publisher records and
  shipped-image artifacts, including package os-manifests where available.
  Keep restricted build evidence outside this public repository.
- Authenticate `gh` to the GitHub account authorized to publish releases in
  `microsoft/azure-container-linux`. Use Git, Python, and `mdformat` to
  inspect the source range and format the draft. Missing evidence is a reason
  to stop or disclose uncertainty, not to invent release facts.

## Prepare and review

Ask a Copilot agent with this repository checked out:

> Use the publish-acl-release skill to prepare a GitHub Release draft for
> the published image associated with publisher run `<publisher run URL>`.
> Resolve and verify its version and ACL source commit from the run and
> linked producer records.
> Do not create a tag or release. Put the public draft and private evidence
> note outside the repository and show me both for review.

The publisher run URL belongs in the private evidence note, **not** in the
public release body. A successful run by itself is not proof of publication;
if the agent cannot confirm the shipped record, provide that record for
review rather than guessing.
The agent verifies the publication, source pins, version, last shipped
baseline, and package evidence before drafting. If there is no established
shipped baseline, choose one explicitly or approve an **initial release**
with no release-to-release comparison. An initial release may summarize a
clearly labeled source-development range, but must not present it as a
comparison between shipped versions. If the preceding shipped publication
cannot be resolved from the available records, provide its publisher run
link rather than guessing a baseline.

Review the draft's changes, packages for both architectures, missing
coverage, compare link, full PR/commit inventory, and any thanks to external
contributors. The public file must not contain private build records or
restricted links. The separate evidence note contains provenance and
uncertainties for the maintainer; **do not commit or publish it**.
Edit the draft directly if needed. Preparing or reviewing it does not
authorize publication.

## Publish after approval

In a later turn, explicitly approve the **reviewed draft file, version,
shipped baseline (or initial release), and target SHA**, for example:

> I approve publishing the reviewed file `<draft path>` as version
> `<version>` for target `<full SHA>`, compared with shipped version
> `<baseline version>`. Use the publish-acl-release skill.

For an initial release, replace the baseline clause with "initial release:
no prior shipped baseline." The agent rechecks the publication and the
reviewed file, then creates the release with `gh release create` at the
approved commit, and verifies its tag and body. If the facts or draft have
changed materially, review and approve the revised version first. Do not
approve a draft solely because its source commit matches a shipped build:
the release identifies a specific **image version**, not just source code.

The skill does not create a PR. Propose changes to the skill or this guide
through a normal PR against `aclmain`; publishing a release remains a
separate, explicit maintainer action.
