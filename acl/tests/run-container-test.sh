#!/bin/bash
# Smoke test: pull and run an nginx container, verifying the container runtime works.
# On QEMU VMs, build_rpm_image.sh follows up with a curl check against the VM IP.
# On Azure VMs, the NSG doesn't expose port 80, so the curl check is skipped —
# a successful exit from this script is sufficient to validate container functionality.

set -euo pipefail

fail() {
    echo "FAILED: $*" >&2
    exit 1
}

run_overlayfs_smoke_test() {
    iptables -I INPUT -p tcp --dport 80 -j ACCEPT
    ctr image pull mcr.microsoft.com/azurelinux/base/nginx:1 > /dev/null
    ctr run --detach --net-host mcr.microsoft.com/azurelinux/base/nginx:1 nginx
    sleep 2
}

# Exit successfully when the additional EROFS test does not apply.
require_erofs_profile() {
    local containerd_pid containerd_cmdline effective_config snapshotter

    if [[ ! -r /sys/kernel/security/ipe/policies/acl_ipe_boot_policy/active ]] ||
        [[ "$(< /sys/kernel/security/ipe/policies/acl_ipe_boot_policy/active)" != 1 ]]; then
        echo "Skipping EROFS SELinux test: IPE policy is not active."
        exit 0
    fi
    [[ "$(< /sys/kernel/security/ipe/enforce)" == 0 ]] || fail "Expected IPE audit mode"

    containerd_pid="$(systemctl show --property=MainPID --value containerd)"
    [[ "${containerd_pid}" =~ ^[1-9][0-9]*$ ]] || fail "Containerd is not running"
    containerd_cmdline="$(tr '\0' ' ' < "/proc/${containerd_pid}/cmdline")"
    [[ " ${containerd_cmdline} " == *" --config /run/containerd/acl-config.toml "* ]] ||
        fail "Containerd is not using the IPE-selected config"

    effective_config="$(containerd --config /run/containerd/acl-config.toml config dump)"
    snapshotter="$(awk '
        {
            gsub(/\047/, "\"")
            sub(/^[[:space:]]+/, "")
            sub(/[[:space:]]+$/, "")
        }
        /^\[/ { section = $0 }
        section == "[plugins.\"io.containerd.cri.v1.images\"]" && /^snapshotter =/ {
            gsub(/"/, "", $3)
            print $3
            found = ($3 != "")
        }
        END { if (!found) exit 1 }
    ' <<< "${effective_config}")" || fail "Could not determine the effective CRI snapshotter"
    if [[ "${snapshotter}" != erofs ]]; then
        echo "Skipping EROFS SELinux test: effective CRI snapshotter is ${snapshotter}."
        exit 0
    fi
}

latest_nginx_image() {
    # MCR does not publish :latest here; select the highest stable version/build.
    curl --fail --silent --show-error --max-time 30 --retry 2 \
        https://mcr.microsoft.com/v2/oss/v2/ingress-nginx/controller/tags/list |
        jq -er '
            .tags | map(select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+$"))) |
            (max_by(ltrimstr("v") | gsub("-"; ".") | split(".") | map(tonumber)) //
             error("No stable ingress-nginx tags found")) |
            "mcr.microsoft.com/oss/v2/ingress-nginx/controller:" + .
        '
}

test_ctr() {
    timeout 60 ctr "$@"
}

start_erofs_nginx() {
    local image="$1" id="$2" directory="$3"
    # ctr bypasses CRI labeling without changing the VM's enable_selinux setting.
    # Force LuaJIT compilation, rather than only testing ordinary nginx startup.
    # A private Unix socket avoids host port conflicts and firewall changes.
    test_ctr run --snapshotter erofs --detach --user 1000:1000 \
        --log-uri "file://${directory}/nginx.log" "${image}" "${id}" /bin/sh -ec '
cat > /tmp/ipe-nginx.conf <<EOF
daemon off;
master_process off;
pid /tmp/ipe-nginx.pid;
error_log stderr notice;
events { worker_connections 32; }
http {
    access_log off;
    client_body_temp_path /tmp/client_temp;
    proxy_temp_path /tmp/proxy_temp;
    fastcgi_temp_path /tmp/fastcgi_temp;
    init_by_lua_block {
        local jit = require("jit")
        jit.on()
        jit.flush()
        jit.opt.start("hotloop=1")
        local sum = 0
        for i = 1, 10000 do sum = sum + i end
        assert(sum == 50005000 and require("jit.util").traceinfo(1),
               "LuaJIT did not generate executable code")
    }
    server {
        listen unix:/tmp/ipe-nginx.sock;
        location = /healthz { return 200 "ok\n"; }
    }
}
EOF
exec /usr/bin/nginx -p /tmp/ -c /tmp/ipe-nginx.conf
'
}

cleanup_erofs_nginx() {
    local status="$1" directory="$2" id="$3" tasks containers
    trap - EXIT
    if [[ -f "${directory}/nginx.log" ]]; then
        cat "${directory}/nginx.log" || status=1
    fi
    if tasks="$(test_ctr tasks ls -q)"; then
        if grep -Fxq "${id}" <<< "${tasks}"; then
            test_ctr tasks delete --force "${id}" || status=1
        fi
    else
        status=1
    fi
    if containers="$(test_ctr containers ls -q)"; then
        if grep -Fxq "${id}" <<< "${containers}"; then
            test_ctr containers delete "${id}" || status=1
        fi
    else
        status=1
    fi
    rm -f -- "${directory}/nginx.log" || status=1
    rmdir -- "${directory}" || status=1
    exit "${status}"
}

run_erofs_selinux_test() (
    local selinux_mode image directory id tasks pid ready label domain
    selinux_mode="$(getenforce)"
    case "${selinux_mode}" in
        Enforcing|Permissive) ;;
        *) fail "Expected SELinux Enforcing or Permissive, got: ${selinux_mode}" ;;
    esac
    echo "EROFS SELinux test mode: ${selinux_mode}"

    command -v curl > /dev/null
    image="$(latest_nginx_image)"
    echo "EROFS SELinux test image: ${image}"
    directory="$(mktemp -d /var/tmp/ipe-erofs-nginx.XXXXXX)"
    id="${directory##*/}"
    trap 'cleanup_erofs_nginx "$?" "${directory}" "${id}"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    timeout 300 ctr images pull --snapshotter erofs "${image}" > /dev/null
    start_erofs_nginx "${image}" "${id}" "${directory}"

    tasks="$(test_ctr tasks ls)"
    pid="$(awk -v id="${id}" '$1 == id && $3 == "RUNNING" { print $2 }' <<< "${tasks}")"
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || fail "NGINX task is not running"
    ready=false
    for _ in {1..15}; do
        if curl --silent --show-error --fail --max-time 2 --noproxy '*' \
            --unix-socket "/proc/${pid}/root/tmp/ipe-nginx.sock" http://localhost/healthz; then
            ready=true
            break
        fi
        sleep 2
    done
    [[ "${ready}" == true ]] || fail "NGINX/LuaJIT startup failed"
    label="$(stat -Lc %C "/proc/${pid}/exe")"
    domain="$(tr -d '\000\n' < "/proc/${pid}/attr/current")"
    echo "EROFS nginx: pid=${pid} executable=${label} domain=${domain}"
    [[ "${label}" == system_u:object_r:container_file_t:s0 ]] ||
        fail "Unexpected nginx executable label"
    [[ "${domain}" == system_u:system_r:spc_t:s0 ]] ||
        fail "Unexpected nginx process domain"

    [[ "$(getenforce)" == "${selinux_mode}" && "$(< /sys/kernel/security/ipe/enforce)" == 0 &&
        "$(< /sys/kernel/security/ipe/policies/acl_ipe_boot_policy/active)" == 1 ]] ||
        fail "Security settings changed during the test"
    echo "PASS: EROFS nginx labels and LuaJIT startup"
)

run_overlayfs_smoke_test
require_erofs_profile
run_erofs_selinux_test
