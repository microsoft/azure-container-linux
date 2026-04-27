# ACL SPECS

Custom and patched package specs for Azure Container Linux (ACL). These are
packages that require ACL-specific modifications beyond what Azure Linux ships
by default — typically Flatcar compatibility patches, Azure integration fixes,
or packages not yet available upstream.

## Ported from Flatcar

| Package | Version | Description |
|---------|---------|-------------|
| **ignition** | 2.22.0 | First boot installer and configuration tool. Patched for Flatcar compatibility (`coreos` → `flatcar` rename, Flatcar Ignition translation support). |
| **rust-afterburn** | 5.8.2 | Cloud provider agent for instance metadata. Carries patches to retain Container Linux legacy support and reduce binary size. |
| **sdnotify-proxy** | 0.1.0 | Proxies `sd_notify` messages between systemd and processes in different cgroups (e.g., Docker-containerized etcd). Originally from Flatcar. |

## Moved from Azure Linux SPECS-Extended to Base

These packages already exist in Azure Linux but in the extended spec repo.
ACL carries them in base specs to match the package set expected by Flatcar.

| Package | Version | Description |
|---------|---------|-------------|
| **adcli** | 0.9.2 | Active Directory enrollment tool. Imported from Fedora with upstream LDAPS fixes. |
| **jose** | 14 | Tools for JSON Object Signing and Encryption (JOSE). Imported from Fedora. |
| **luksmeta** | 9 | Utility for storing metadata in LUKSv1 headers. Carries test and layout-assumption fixes. |
| **realmd** | 0.17.1 | Kerberos realm enrollment service. Patched for SSSD packaging, ccache handling, and multi-name AD server support. |

## Added for LISA Testing

stress-ng and its build dependencies, needed for LISA test integration.

| Package | Version | Description |
|---------|---------|-------------|
| **stress-ng** | 0.18.02 | Stress test tool. Imported from Fedora. |
| **Judy** | 1.0.5 | General purpose dynamic array library (stress-ng `BuildRequires`). Imported from Fedora. |
| **libbsd** | 0.12.2 | BSD-compatible functions for portability (stress-ng `BuildRequires`). Imported from Fedora. |
| **lksctp-tools** | 1.0.19 | User-space access to Linux Kernel SCTP (stress-ng `BuildRequires`). Carries upstream patches. |

## ACL-Patched System Packages

| Package | Version | Description |
|---------|---------|-------------|
| **WALinuxAgent** | 2.11.1.4 | Windows Azure Linux Agent. Patched with Azure Linux and ACL platform support. |
| **systemd** | 255 | System and Service Manager. Heavily patched for ACL — includes Azure Linux PAM config, scheduler defaults, networkd tweaks, and upstream backports. |
| **selinux-policy** | — | SELinux reference policy. Patched for ACL — `dac_read_search` perms, `cloud-init` compatibility, `unconfined_u` default, container SELinux, and Kubernetes fixes. |
| **qemu** | 9.1.0 | Processor emulator. Patched to disable unsupported targets on Azure Linux, fix build issues, and address CVEs. |
| **microcode_ctl** | 2.1 | CPU microcode update tool for x86. Imported from Fedora with wildcard tar fix. |
