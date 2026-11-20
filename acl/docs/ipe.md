# Integrity Policy Enforcement (IPE)

This guide is for Azure Container Linux (ACL) users and operators enabling,
verifying, or troubleshooting IPE audit mode on Azure VMs and AKS nodes.

**Audit mode logs policy denials without blocking execution. Enforcing mode
is not supported by the current ACL integration.** Enabling audit also changes
containerd's configuration.

## Before you begin

| Requirement | Details |
|---|---|
| Image | Azure Unified Kernel Image (UKI) with an IPE-enabled kernel and a signed policy bound to the UKI |
| Trust | Kernel trust for the policy signer and any required root-hash signer |
| Runtime | containerd with EROFS and dm-verity referrer support |
| Access | Azure CLI access to the VM or AKS pool, and root access to the node |

Use Bash, Azure CLI, and `jq`; for AKS, also use `kubectl` with the target
cluster's kubeconfig. Run diagnostics as root on the node. For AKS, follow
the [node-access guide](https://learn.microsoft.com/azure/aks/node-access)
and run `chroot /host` in the node debug pod.

This integration supports Azure UKI images, not GRUB, QEMU, or ACL-T images.

IPE complements, rather than replaces, other protections:

- Secure Boot verifies boot components.
- dm-verity checks filesystem blocks against a root hash. A verified signature
  lets IPE trust that hash.
- SELinux controls what processes can access.
- IPE checks whether files used for execution are trusted.

Test images require trust in their test-signing certificates. Do not turn off
Secure Boot or bypass required root signatures to work around errors.

## Policy and packaging

The current [policy source](../../build_library/rpm/additional_files/ipe/acl-ipe-boot-policy.pol)
is:

```text
policy_name=acl_ipe_boot_policy policy_version=0.0.1

DEFAULT action=ALLOW

DEFAULT op=EXECUTE action=DENY
op=EXECUTE boot_verified=TRUE action=ALLOW
op=EXECUTE dmverity_signature=TRUE action=ALLOW
```

Execution is denied unless the file comes from the boot-verified initramfs or
a dm-verity volume with a verified root-hash signature. Executable memory
mappings are checked too. Other IPE operations default to ALLOW. In audit
mode, DENY decisions are logged, not blocked.

The policy ships as a **signed file alongside the UKI**, called a policy
credential. The UKI contains the kernel, early-boot filesystem (initramfs),
and kernel command line.

| Stage | Policy location |
|---|---|
| Source | `build_library/rpm/additional_files/ipe/acl-ipe-boot-policy.pol` |
| Build staging | `${BUILD_DIR}/acl-ipe-policy/acl-ipe-policy.p7b.cred` |
| EFI System Partition (ESP) | `EFI/Linux/<uki>.efi.extra.d/acl-ipe-policy.p7b.cred` |
| Initramfs | `/.extra/credentials/acl-ipe-policy.p7b.cred`, exposed by systemd-stub |
| Loaded kernel state | `/sys/kernel/security/ipe/policies/acl_ipe_boot_policy/` |

The signed file uses CMS/PKCS#7, which packages the policy and signature
together. The signed UKI command line records the file's SHA-256 as
`acl.ipe.policy_sha256=<hash>`. The loader checks this hash; the kernel
separately checks the signature. Builds start with a test-signed policy.
Production publishing replaces it and updates the hash in the UKI.
See the [build guide](BUILD_RPM_IMAGE_README.md#phase-3-build-the-image) for
builder and signing options.

After boot, read the loaded policy at
`/sys/kernel/security/ipe/policies/acl_ipe_boot_policy/policy`.
The policy and `/usr` root hash use separate signatures.

## Loading and activation during boot

Dracut includes `acl-ipe-load.service` and `/usr/bin/acl-ipe-load` in the
initramfs. The IPE loader runs before SELinux policy loading and installs
containerd's profile drop-in. Containerd starts later, during normal host
boot, using the selected profile.

On Azure, the [loader](../../build_library/rpm/additional_files/dracut-acl-ipe-load/acl-ipe-load.sh):

1. Checks the policy file and compares its SHA-256 with the hash in the UKI
   command line.
2. Checks that the kernel's IPE interface is available and stops if a policy
   is already loaded.
3. Writes the signed credential to `/sys/kernel/security/ipe/new_policy`.
   The kernel validates and loads it. **Loaded does not mean active.**
4. Reads the `ipe` entry of the `acl-node-security-profile` tag from the Azure
   Instance Metadata Service (IMDS).
5. For `ipe=audit`, sets `enforce=0`, sets the policy's `active=1`, verifies
   activation, and installs the containerd drop-in.

With `ipe=disabled` or `ipe=off`, a valid policy is loaded but remains
inactive. A missing or unrecognized IPE setting, or unavailable IMDS, does not
activate it. `ipe=enforcing` is rejected as unsupported and leaves it inactive.

Validation or loading errors are logged and skip activation without blocking
boot. Installing the containerd drop-in can fail **after** activation. Check
the kernel's `active` and `enforce` files, not whether the loader service is
running or stopped.

The mode is selected **at boot**. Changing the tag does not change a running
node's policy state or containerd configuration.

## Containerd configuration in audit mode

When IPE audit is activated, containerd uses the EROFS profile. EROFS is a
read-only filesystem used for container layers. The profile also enables
discovery of dm-verity metadata for signed layers.

The startup sequence is:

1. The IPE loader installs a systemd drop-in at
   `/run/systemd/system/containerd.service.d/90-acl-profile.conf`.
2. Before containerd starts, a profile selector combines the existing base
   config with `/usr/share/containerd/acl-erofs.toml`.
3. The selector writes `/run/containerd/acl-config.toml`, and containerd starts
   with `--config /run/containerd/acl-config.toml`.

**The base config is not overwritten.** The generated file imports it and adds
the IPE profile's overrides. On AKS, the base config is normally
`/etc/containerd/config.toml`.

The [IPE profile](../../build_library/rpm/additional_files/containerd2/containerd-acl-erofs.toml)
sets:

| Setting | Audit-mode value | Purpose |
|---|---|---|
| Container image snapshotter | `erofs` | Use EROFS for container layers |
| `enable_dmverity_referrers` | `true` | Find the dm-verity metadata used to verify signed layers |
| Diff plugin order | `["erofs", "walking"]` | Try the EROFS diff plugin before the general-purpose walking plugin |

After IPE is disabled and the node reboots, the drop-in is no longer installed.
Containerd uses the base config directly, normally with `overlayfs` on AKS.

If containerd lacks the required support or the settings conflict, the selector
can fall back to the base config. It logs a warning and only allows this
fallback when IPE's `enforce` setting is `0`. IPE audit stays active, but the
signed EROFS profile is not enabled. If that setting is not `0` or cannot be
read, the selector fails and containerd does not start.

See [Containerd verification](#containerd) to check the running configuration.

## Enable or disable audit

Set the `acl-node-security-profile` tag to `ipe=audit` to enable audit, or
`ipe=disabled` to disable it. **Restart the node for the change to take effect.**

Keep any other entries in the profile. For example, change
`selinux=permissive,ipe=disabled` to `selinux=permissive,ipe=audit`.

### AKS

Update the **node pool's** tags, not the cluster's tags. First check the
existing tags:

```bash
SUB="<subscription-id>"
RG="<cluster-resource-group>"
CLUSTER="<cluster-name>"
POOL="<node-pool-name>"

az aks nodepool show --subscription "$SUB" -g "$RG" \
  --cluster-name "$CLUSTER" -n "$POOL" --query tags -o json
```

**`--tags` replaces all pool tags.** Add every existing tag you want to keep
to the command below, and retain other entries in the security profile:

```bash
az aks nodepool update --subscription "$SUB" -g "$RG" \
  --cluster-name "$CLUSTER" -n "$POOL" \
  --tags "acl-node-security-profile=ipe=audit"
```

Repeat for each pool that needs the change.

### Standalone Azure VM

Check the current tags, then update the profile. `Merge` keeps other VM tags,
but you must still retain other entries within `acl-node-security-profile`:

```bash
VM_ID="<full-vm-resource-id>"
az vm show --ids "$VM_ID" --query tags -o json
```

```bash
az tag update --resource-id "$VM_ID" --operation Merge \
  --tags "acl-node-security-profile=ipe=audit"
```

For either deployment, use `ipe=disabled` in the same command to turn audit off.

### Confirm the tag

Wait for the update to complete, then confirm the node sees the new IMDS tag:

```bash
curl --fail --silent --show-error --noproxy '*' \
  --connect-timeout 3 --max-time 20 -H Metadata:true \
  'http://169.254.169.254/metadata/instance/compute/tagsList?api-version=2021-02-01' |
  jq '.[] | select(.name == "acl-node-security-profile")'
```

## Restart and verify each affected node

For a standalone VM, follow your usual restart procedure, then verify IPE.
For AKS, provide spare capacity to move pods while respecting
PodDisruptionBudgets (PDBs), which limit how many pods can be unavailable.
A single-node cluster may need a temporary second node.

1. Select one node and obtain its Azure identity:

   ```bash
   NODE="<node-name>"
   kubectl get node "$NODE" -o jsonpath='{.spec.providerID}{"\n"}'
   ```

   Derive `NODE_RG`, `VMSS`, and `INSTANCE` from that provider ID, and confirm
   its subscription matches `SUB`. Do not guess an instance number.

2. Record its boot ID, drain it, and restart only that instance:

   ```bash
   BEFORE="$(kubectl get node "$NODE" -o jsonpath='{.status.nodeInfo.bootID}')" &&
   test -n "$BEFORE" &&
   kubectl drain "$NODE" --ignore-daemonsets --timeout=15m &&
   az vmss restart --subscription "$SUB" -g "$NODE_RG" \
     -n "$VMSS" --instance-ids "$INSTANCE"
   ```

   If drain fails, stop and resolve the blocker. Do not use `--force` or
   `--disable-eviction`. Pods with `emptyDir` storage may need
   `--delete-emptydir-data`; **review that data and approve its deletion
   before adding the flag**. DaemonSet pods stay on the node.

3. Wait until this returns a **different, nonempty** ID from `BEFORE`:

   ```bash
   kubectl get node "$NODE" -o jsonpath='{.status.nodeInfo.bootID}{"\n"}'
   ```

   Then wait for readiness:

   ```bash
   kubectl wait --for=condition=Ready "node/$NODE" --timeout=10m
   ```

4. Verify IPE and containerd as described below before `kubectl uncordon "$NODE"`.
   Check workload and system-pod health before moving to the next node.
   If verification fails, leave the node cordoned and investigate.

This is a manual drain and VMSS restart, not an AKS-managed upgrade. Repeat
it for each node: nodes can run different modes until all have restarted.

## Verify effective state

On the node, check the security modules and loaded policy.
`/sys/kernel/security` exposes the kernel's security state:

```bash
cat /sys/kernel/security/lsm
findmnt /sys/kernel/security
IPE=/sys/kernel/security/ipe
ls "$IPE/policies"
cat "$IPE/policies/acl_ipe_boot_policy/policy"
cat "$IPE/policies/acl_ipe_boot_policy/active"; echo
cat "$IPE/enforce"; echo
journalctl -b -u acl-ipe-load.service --no-pager
```

| State | Policy | `active` | `enforce` |
|---|---|---|---|
| Audit working | Expected policy loaded | `1` | `0` |
| Disabled | Loaded but inactive | `0` | May be `1`; check which policy is active |
| Missing or rejected policy | Not loaded | Unavailable | Does not prove IPE is working |

If other policies appear under `policies/`, check their `active` files too.

### Containerd

Check which configuration containerd is running:

```bash
systemctl is-active containerd
PID="$(systemctl show containerd -p MainPID --value)"
tr '\0' ' ' < "/proc/$PID/cmdline"; echo
```

For the [audit profile](#containerd-configuration-in-audit-mode), expect
`--config /run/containerd/acl-config.toml`. Show its settings without printing
registry credentials:

```bash
containerd --config /run/containerd/acl-config.toml config dump |
  grep -E 'snapshotter =|enable_dmverity_referrers =|default ='
```

Expect the container image snapshotter `erofs`,
`enable_dmverity_referrers=true`, and diff plugin order `erofs`, `walking`.
If these differ, check containerd logs for a profile fallback and verify
workload health.

### Audit events

Inspect the **full journal**, not only `journalctl -k` or dmesg:

```bash
journalctl -b --no-pager -o cat | grep 'IPE_ACCESS'
```

With audit active, this optional test copies `/usr/bin/true` to writable
storage, runs it, and looks for its DENY record. The copy is deleted on exit.
Run it only where temporary test files are permitted.

```bash
(
  set -euo pipefail
  test "$(cat /sys/kernel/security/ipe/enforce)" = 0
  test "$(cat /sys/kernel/security/ipe/policies/acl_ipe_boot_policy/active)" = 1
  probe="$(mktemp /var/tmp/acl-ipe-probe.XXXXXX)"
  trap 'rm -- "$probe"' EXIT
  cp /usr/bin/true "$probe"
  chmod 0755 "$probe"
  since="$(date -u +%FT%TZ)"
  pid="$(bash -c 'printf "%s\n" "$$"; exec "$1"' -- "$probe")"
  printf 'Executed %s with pid=%s and exit=0\n' "$probe" "$pid"
  sleep 2
  journalctl -b --since "$since" --no-pager -o cat |
    grep -F "path=\"$probe\"" |
    grep -E "(^|[[:space:]])pid=$pid([[:space:]]|$)" |
    grep -E 'ipe_op=EXECUTE([[:space:]]|$)' |
    grep -E 'enforcing=0([[:space:]]|$)' |
    grep -E 'rule="[^"]*action=DENY"'
)
```

The test should exit successfully and print a DENY record matching the
executable's PID and path, with `enforcing=0`. If not, check policy state,
other security controls, and audit logging.

### Signed `/usr` is a separate check

```bash
findmnt -T /usr -o SOURCE,FSTYPE,OPTIONS
dmsetup table usr
dmsetup status usr
```

For a signed-root image, check for `root_hash_sig_key_desc` in the `/usr`
mapping. A `V` status reports valid dm-verity state; it does not prove that
a root signature or IPE policy is active.

Turning IPE off does **not** remove a required root-hash signature. Missing or
invalid required signatures can prevent boot even with `ipe=disabled`.

## Troubleshooting and limits

| Symptom | Check and action |
|---|---|
| Audit tag set, no policy | Check that the image includes IPE, then check the UKI policy hash and loader errors. Tags do not install a policy. |
| Policy loaded but inactive | Check the IMDS tag and boot ID. A missing tag, IMDS failure, unsupported mode, or pending restart can explain this. |
| Loader stopped, but policy active | Normal for a boot-time service. Check the policy's `active` file and global `enforce` value. |
| No events in kernel logs | Read the full journal, not just dmesg or `journalctl -k`. An auditd log file may not exist. |
| Audit active, containerd uses base config | Check profile-selection logs and the running config. A fallback does not enable the signed EROFS profile. |
| `/usr` generates audit denials | Check whether the root is signed. Signed Btrfs also has a known IPE trust limitation. |
| Node does not boot | Check boot logs for root-signature errors. Use the image's recovery or replacement procedure; turning off IPE does not bypass required root signatures. |
| Drain stalls | Check PDBs, replacement pods, spare capacity, and local data. Do not force eviction. |

The signed-Btrfs test skips the check for unexpected `/usr` denials. Passing
that test does not resolve the known limitation. See [IPE testing](testing.md#ipe-tests).

These checks cover audit mode, not enforcing mode, signed-container
verification, or OS updates and rollback. Do not edit signed policy or UKI
files on a node.
