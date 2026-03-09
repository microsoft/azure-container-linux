# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

GLSA_ALLOWLIST=(
	201412-09 # incompatible CA certificate version numbers
	202407-05 # ebuild of sys-auth/sssd already has a custom patch to fix CVE-2021-3621
)

glsa_image() {
  if glsa-check-$BOARD -t all | grep -Fvx "${GLSA_ALLOWLIST[@]/#/-e}"; then
    echo "The above GLSAs apply to $ROOT"
    return 1
  fi

  return 0
}

test_image_content() {
  local root="$1"
  local returncode=0

  info "Checking $1"
  local check_root="${BUILD_LIBRARY_DIR}/check_root"
  if ! ROOT="$root" "$check_root" libs; then
    warn "test_image_content: Failed dependency check"
    warn "This may be the result of having a long-lived SDK with binary"
    warn "packages that predate portage 2.2.18. If this is the case try:"
    echo "    emerge-$BOARD -agkuDN --rebuilt-binaries=y -j9  @world"
    echo "    emerge-$BOARD -a --depclean"
    #returncode=1
  fi

  local denylist_dirs=(
    "$root/usr/share/locale"
  )
  for dir in "${denylist_dirs[@]}"; do
    if [ -d "$dir" ]; then
      warn "test_image_content: Denied directory found: $dir"
      # Only a warning for now, size isn't important enough to kill time
      # playing whack-a-mole on things like this this yet.
      #error "test_image_content: Denied directory found: $dir"
      #returncode=1
    fi
  done

  # Check that there are no conflicts between /* and /usr/*
  if ! ROOT="$root" "$check_root" usr; then
    error "test_image_content: Failed /usr conflict check"
    returncode=1
  fi

  # Check that there are no #! lines pointing to non-existant locations
  if [[ "${PACKAGE_SOURCE_MODE}" == "PORTAGE" ]]; then
  if ! ROOT="$root" "$check_root" shebang; then
    warn "test_image_content: Failed #! check"
    # Only a warning for now. We still have to actually remove all of the
    # offending scripts.
    #error "test_image_content: Failed #! check"
    #returncode=1
  fi
  else
    # Reenablement tracked by https://dev.azure.com/mariner-org/ACL/_sprints/taskboard/ACL%20Team/ACL/MMM/Kr/CYC2?workitem=17546
    # Skip this check in HYBRID mode - Azure Linux uses /bin as symlink to usr/bin
    # which causes false positives for scripts with /bin/sh or /bin/bash shebangs
    warn "test_image_content: Skipping shebang check in HYBRID mode"
  fi

  if [[ "${PACKAGE_SOURCE_MODE}" == "PORTAGE" ]]; then
  if ! sudo ROOT="$root" "$check_root" symlink; then
    error "test_image_content: Failed symlink check"
    returncode=1
    fi
  else
    # Reenablement tracked by https://dev.azure.com/mariner-org/ACL/_sprints/taskboard/ACL%20Team/ACL/MMM/Kr/CYC2?workitem=17546
    # Skip symlink check in HYBRID mode - Azure Linux packages may have symlinks
    # pointing to files that are optional or configured at runtime (e.g., /etc/sysconfig/grub -> /etc/default/grub)
    warn "test_image_content: Skipping symlink check in HYBRID mode"
  fi

  if ! ROOT="$root" glsa_image; then
      returncode=1
  fi

  return $returncode
}
