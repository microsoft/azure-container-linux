#!/bin/bash
# Smoke test: pull and run an nginx container, verifying the container runtime works.
# On QEMU VMs, build_rpm_image.sh follows up with a curl check against the VM IP.
# On Azure VMs, the NSG doesn't expose port 80, so the curl check is skipped —
# a successful exit from this script is sufficient to validate container functionality.

set -uo pipefail

# ---------------------------------------------------------------------------
# dump_containerd_state — full diagnostic dump. Called pre-flight (once) and
# on any error via trap. Prints every clue a post-mortem needs to name the
# containerd startup failure without requiring another pipeline retrigger.
# ---------------------------------------------------------------------------
dump_containerd_state() {
    echo ""
    echo "========================================="
    echo "DIAGNOSTIC DUMP: containerd state ($1)"
    echo "========================================="

    echo ""
    echo "--- systemd-detect-virt ---"
    systemd-detect-virt 2>&1 || true

    echo ""
    echo "--- which ctr / containerd ---"
    which ctr 2>&1 || true
    which containerd 2>&1 || true

    echo ""
    echo "--- rpm -q moby-containerd moby-runc ---"
    rpm -q moby-containerd moby-runc 2>&1 || true

    echo ""
    echo "--- systemctl is-enabled containerd ---"
    systemctl is-enabled containerd 2>&1 || true

    echo ""
    echo "--- systemctl is-active containerd ---"
    systemctl is-active containerd 2>&1 || true

    echo ""
    echo "--- systemctl status containerd --no-pager -l ---"
    systemctl status containerd --no-pager -l 2>&1 || true

    echo ""
    echo "--- journalctl -u containerd --no-pager -b ---"
    journalctl -u containerd --no-pager -b 2>&1 || true

    echo ""
    echo "--- Unit file / wants / runtime dir listings ---"
    ls -la \
        /usr/lib/systemd/system/containerd.service \
        /etc/systemd/system/containerd.service \
        /usr/lib/systemd/system/multi-user.target.wants/ \
        /etc/systemd/system/multi-user.target.wants/ \
        /run/containerd/ \
        /var/lib/containerd/ \
        2>&1 || true

    echo ""
    echo "--- /usr/lib/systemd/system/containerd.service (contents) ---"
    cat /usr/lib/systemd/system/containerd.service 2>&1 || true

    echo ""
    echo "--- Drop-ins for containerd.service ---"
    ls -la \
        /usr/lib/systemd/system/containerd.service.d/ \
        /etc/systemd/system/containerd.service.d/ \
        2>&1 || true
    for f in /usr/lib/systemd/system/containerd.service.d/*.conf /etc/systemd/system/containerd.service.d/*.conf; do
        [ -f "$f" ] || continue
        echo ""
        echo ">>> $f <<<"
        cat "$f" 2>&1 || true
    done

    echo ""
    echo "--- /etc/containerd/ config ---"
    ls -la /etc/containerd/ 2>&1 || true
    for f in /etc/containerd/*.toml /etc/containerd/config.toml; do
        [ -f "$f" ] || continue
        echo ""
        echo ">>> $f <<<"
        cat "$f" 2>&1 || true
    done

    echo ""
    echo "========================================="
    echo "END DIAGNOSTIC DUMP"
    echo "========================================="
    echo ""
}

trap 'rc=$?; echo "❌ container-test failed at line $LINENO (exit $rc)"; dump_containerd_state "on-error"; exit $rc' ERR

# Pre-flight dump so we know the starting state even if the ctr call hangs
# silently rather than errors.
dump_containerd_state "pre-flight"

iptables -I INPUT -p tcp --dport 80 -j ACCEPT
ctr image pull mcr.microsoft.com/azurelinux/base/nginx:1 > /dev/null
ctr run --detach --net-host mcr.microsoft.com/azurelinux/base/nginx:1 nginx
sleep 2
