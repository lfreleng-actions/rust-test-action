#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Stand-in for rustup. 'show active-toolchain' prints MOCK_TOOLCHAIN, a
# channel or a path, followed by MOCK_TOOLCHAIN_REASON in parentheses,
# as rustup would; 'component add' and 'toolchain install' record
# themselves, and fail when MOCK_COMPONENT_FAIL or MOCK_INSTALL_FAIL is
# 'true'. 'which --toolchain <name> rustc' finds every toolchain except
# those MOCK_MISSING lists, and refuses to answer unless
# RUSTUP_AUTO_INSTALL is 0, since it could install one otherwise.
# Every call appends '<cwd>|<RUSTUP_TOOLCHAIN>|<arguments>' to
# MOCK_RUSTUP_LOG, each argument in angle brackets on one line to
# MOCK_RUSTUP_ARGV, and its credentials to MOCK_CRED_LOG.

set -euo pipefail

# shellcheck source=record-credentials.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/record-credentials.sh"

printf '%s|%s|%s\n' "$(pwd -P)" "${RUSTUP_TOOLCHAIN-unset}" "$*" \
  >> "$MOCK_RUSTUP_LOG"
{
  printf '<%s>' "$@"
  printf '\n'
} >> "$MOCK_RUSTUP_ARGV"
record_credentials "rustup $*"
case "$*" in
  "show active-toolchain")
    if [ "${MOCK_RUSTUP_FAIL:-false}" = "true" ]; then
      echo "error: toolchain not installed" >&2
      exit 1
    fi
    printf '%s (%s)\n' \
      "${MOCK_TOOLCHAIN:-stable-x86_64-unknown-linux-gnu}" \
      "${MOCK_TOOLCHAIN_REASON:-default}"
    ;;
  "component add llvm-tools-preview --toolchain "*)
    if [ "${MOCK_COMPONENT_FAIL:-false}" = "true" ]; then
      echo "error: component unavailable" >&2
      exit 1
    fi
    ;;
  "which --toolchain "*" rustc")
    if [ "${RUSTUP_AUTO_INSTALL-}" != "0" ]; then
      echo "mock rustup: this call could auto-install a toolchain" >&2
      exit 92
    fi
    if [[ " ${MOCK_MISSING:-} " == *" $3 "* ]]; then
      echo "error: toolchain '$3' is not installed" >&2
      exit 1
    fi
    echo "/opt/rustup/toolchains/$3/bin/rustc"
    ;;
  "toolchain install "*)
    if [ "${MOCK_INSTALL_FAIL:-false}" = "true" ]; then
      echo "error: component unavailable for download" >&2
      exit 1
    fi
    ;;
  *)
    echo "Unexpected rustup command: $*" >&2
    exit 90
    ;;
esac
