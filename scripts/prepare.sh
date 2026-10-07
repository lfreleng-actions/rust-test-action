#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# First step of the action: validate every input before anything is
# installed, and name the cargo tools the run needs.
#
# Output 'tools' is the taiki-e/install-action tool list, for example
# 'cargo-nextest@0.9.146,cargo-llvm-cov@0.9.1', or empty when the plain
# cargo runner needs nothing extra. Both versions are validated as
# X.Y.Z, so the list cannot smuggle in another tool.

set -euo pipefail

# Builtins only until the environment is scrubbed: an earlier step may
# have put repository-controlled programs on PATH.
script_dir="${BASH_SOURCE[0]%/*}"
if [ "$script_dir" = "${BASH_SOURCE[0]}" ]; then
  script_dir="."
fi
# shellcheck source=common.sh
source "$script_dir/common.sh"
withhold_environment

# Only a failure gets a summary here; on success run-tests.sh writes it.
finish() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    if [ -z "$failure_reason" ]; then
      failure_reason="$stage failed with exit status $status."
    fi
    write_summary "❌ Failed at $(md_text "$stage")"
  fi
  exit "$status"
}
trap finish EXIT

check_inputs

tools=()
if [ "$test_runner" = "nextest" ]; then
  tools+=("cargo-nextest@$nextest_version")
fi
if [ "$coverage" = "true" ]; then
  tools+=("cargo-llvm-cov@$llvm_cov_version")
fi
set_output tools "$(IFS=,; printf '%s' "${tools[*]-}")"
echo "Inputs valid ✅"
