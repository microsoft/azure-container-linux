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
    database for SBOM generation. The resulting extension must be signed and
    published through the normal artifact-signing gate before consumption.
    AgentBaker activates it only when streaming is enabled, creates writable
    compatibility/configuration paths, and starts the services. This does not
    add streaming binaries to the base OS image or enable streaming by default.

Sysexts are defined in `sysexts.yaml` with a required `mode` field. **Embedded** sysexts (e.g. `containerd`) are placed directly in the image and activated at boot. **Standalone** sysexts are built separately and downloaded on demand. Package names can be RPM names (e.g. `cuda-open`) or portage-style names (e.g. `app-containers/docker`) — the build system tries direct RPM installation first and falls back to the catalog. The `archs` field controls which architectures to build for; omitting it builds for all. An optional mangle script (`build_library/sysext_mangle_<name>` or `build_library/rpm/sysexts/sysext_mangle_<name>`) can relocate files that RPMs install outside `/usr`.
