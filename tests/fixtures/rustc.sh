#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Stand-in for 'rustc --version', recording the stage environment and
# credentials in the same formats as the cargo stand-in. MOCK_RUSTC_FAIL
# makes it fail with status 42; MOCK_RUSTC_LINE replaces its version
# line.

set -euo pipefail

# shellcheck source=record-credentials.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/record-credentials.sh"

[ "$*" = "--version" ] || exit 90
printf '%s|%s|%s\n' rustc-version "$(pwd -P)" "${RUSTUP_TOOLCHAIN-unset}" \
  >> "$MOCK_ENV_LOG"
record_credentials rustc
if [ -n "${MOCK_RUSTC_FAIL:-}" ]; then
  echo "Mock rustc --version failed" >&2
  exit 42
fi
echo "${MOCK_RUSTC_LINE:-rustc ${MOCK_RUSTC_VERSION:-1.99.0} (abc123 2026-09-01)}"
