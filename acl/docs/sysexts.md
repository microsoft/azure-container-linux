# System Extensions (sysexts)

ACL uses **systemd-sysext** squashfs images to deliver optional functionality on top of the read-only `/usr` partition.

## Base sysexts

Baked into the rootfs during `build_image`:

- `containerd` — containerd runtime

Per platform:

- `oem-azure`
- `oem-qemu`

## Standalone sysexts

Built and shipped alongside the disk image:

- **GPU** (available through Microsoft Artifact Registry):
  - `nvidia-driver-cuda-open`
  - `nvidia-driver-cuda`
  - `nvidia-driver-vgpu`
  - `nvidia-container-toolkit`
  - `nvidia-fabric-manager`
- **Scenario-specific**:
  - `docker`
  - `artifact-streaming` — ACR Mirror, OverlayBD and its snapshotter for AKS.
    Build with `--build-standalone-sysexts=artifact-streaming`. The ACR Mirror
    1.0.0 vendor RPM is fetched by a pinned checksum; OverlayBD dependencies
    come from the normal signed RPM repositories. Mirror remains in the RPM
    database for SBOM generation. Release distribution through a registry still
    requires the normal artifact-signing gate.
    AgentBaker activates it only when streaming is enabled, creates writable
    compatibility/configuration paths, and starts the services. This does not
    merge streaming binaries into the base `/usr` or enable streaming by default.

For the test-only BYOI handoff on this branch, Azure VM image conversion caches
the built raw extension at
`/oem/aks-sysext-cache/artifact-streaming.raw`. The root filesystem is read-only
during conversion, while the OEM partition is writable. This cache is separate
from `/oem/sysext`, so it is not automatically activated. The matching AgentBaker
branch reads the OEM cache after its normal `/opt` cache, so the
`aclmain` -> `aks-image-build` path does not
need release publication or registry credentials on the node. The raw must be
built before Azure VM conversion; a missing payload fails the build. Caching
does not add an activation link or start services. The existing development
image flow carries its build-time Secure Boot certificate; this is test-image
validation, not a claim of release signing or release qualification.

The streaming packaging regression tests run with
`python3 acl/tests/test_artifact_streaming_sysext.py` from the repository root.
They use the production manifest selector, so `yq` v4 must be on `PATH`.

Sysexts are defined in `sysexts.yaml` with a required `mode` field. **Embedded** sysexts (e.g. `containerd`) are placed directly in the image and activated at boot. **Standalone** sysexts are built separately and downloaded on demand. Package names can be RPM names (e.g. `cuda-open`) or portage-style names (e.g. `app-containers/docker`) — the build system tries direct RPM installation first and falls back to the catalog. The `archs` field controls which architectures to build for; omitting it builds for all. An optional mangle script (`build_library/sysext_mangle_<name>` or `build_library/rpm/sysexts/sysext_mangle_<name>`) can relocate files that RPMs install outside `/usr`.
