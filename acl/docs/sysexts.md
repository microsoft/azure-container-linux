# System Extensions (sysexts)

ACL uses **systemd-sysext** squashfs images to deliver optional functionality on top of the read-only `/usr` partition.

## Base sysexts

Baked into the rootfs during `build_image`:

- `containerd` — containerd runtime

## Standalone sysexts

Built and shipped alongside the disk image:

- **GPU**:
  - `nvidia-driver-cuda-open`
  - `nvidia-driver-cuda`
  - `nvidia-driver-vgpu`
  - `nvidia-container-toolkit`
  - `nvidia-fabric-manager`
- **Scenario-specific**:
  - `docker`
- **OEM**:
  - `oem-azure`
  - `oem-qemu`

Standalone sysexts are defined in `standalone_sysexts.yaml`. Package names can be RPM names (e.g. `cuda-open`) or portage-style names (e.g. `app-containers/docker`) — the build system tries direct RPM installation first and falls back to the catalog. The `archs` field controls which architectures to build for; omitting it builds for all. An optional mangle script (`build_library/sysext_mangle_<name>`) can relocate files that RPMs install outside `/usr`.
