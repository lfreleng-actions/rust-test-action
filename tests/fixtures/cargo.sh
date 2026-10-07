#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Stand-in for cargo and the cargo-nextest and cargo-llvm-cov plugins.
# Classifies each call into a stage, records it, then simulates the
# side effects run-tests.sh relies on:
#
#   MOCK_CALLS    one line per call: '<stage>: <arguments>'
#   MOCK_ENV_LOG  '<stage>|<cwd>|<RUSTUP_TOOLCHAIN>'
#   MOCK_CRED_LOG 'cargo <stage>|<withheld variables>'
#   MOCK_ARGS     the test run's arguments, one per line
#
# MOCK_FAIL_STAGE names a stage to fail with status 42; MOCK_TEST_EXIT
# and MOCK_DOC_EXIT set the test and doc test exit statuses; MOCK_TREE
# replaces the package list 'cargo tree' prints; MOCK_TEST_HOOK is a
# bash script the test run runs, standing in for project code.

set -euo pipefail

# shellcheck source=record-credentials.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/record-credentials.sh"

option_value() {
  local name="$1"
  shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "$name" ]; then
      printf '%s' "${2:-}"
      return 0
    fi
    shift
  done
  return 1
}

case "${1:-} ${2:-} ${3:-}" in
  "--version "*) stage=version ;;
  "nextest --version"*) stage=nextest-version ;;
  "nextest run"*) stage="test" ;;
  "llvm-cov --version"*) stage=llvm-cov-version ;;
  "llvm-cov clean"*) stage=cov-clean ;;
  "llvm-cov test"* | "llvm-cov nextest"*) stage="test" ;;
  "llvm-cov report --lcov"*) stage=report-lcov ;;
  "llvm-cov report --cobertura"*) stage=report-cobertura ;;
  "locate-project "*) stage=locate ;;
  "tree "*) stage=tree ;;
  "generate-lockfile "*) stage=generate-lockfile ;;
  "test --doc"*) stage=doc ;;
  "test "*) stage="test" ;;
  *)
    echo "Unexpected cargo command: $*" >&2
    exit 90
    ;;
esac

printf '%s: %s\n' "$stage" "$*" >> "$MOCK_CALLS"
printf '%s|%s|%s\n' "$stage" "$(pwd -P)" "${RUSTUP_TOOLCHAIN-unset}" \
  >> "$MOCK_ENV_LOG"
record_credentials "cargo $stage"

if [ "${MOCK_FAIL_STAGE:-}" = "$stage" ]; then
  echo "Mock cargo $stage failed" >&2
  exit 42
fi

case "$stage" in
  version) echo "cargo ${MOCK_CARGO_VERSION:-1.99.0} (abc123 2026-09-01)" ;;
  nextest-version) echo "cargo-nextest 0.9.146 (mock 2026-09-21)" ;;
  llvm-cov-version) echo "cargo-llvm-cov 0.9.1" ;;
  locate)
    if [ -n "${MOCK_ROOT_MANIFEST:-}" ]; then
      printf '%s\n' "$MOCK_ROOT_MANIFEST"
    else
      option_value --manifest-path "$@"
      echo
    fi
    ;;
  generate-lockfile)
    manifest="$(option_value --manifest-path "$@")"
    : > "$(dirname -- "$manifest")/Cargo.lock"
    ;;
  tree)
    printf '%b' "${MOCK_TREE-mock v0.1.0 (/src)\n}"
    ;;
  test)
    printf '%s\n' "$@" > "$MOCK_ARGS"
    if config="$(option_value --tool-config-file "$@")" \
      && [ "${MOCK_NO_JUNIT:-false}" != "true" ]; then
      junit="$(sed -n "s/^path = '\(.*\)'$/\1/p" "${config#*:}")"
      printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
        '<testsuites name="nextest-run" tests="1" failures="0"/>' > "$junit"
    fi
    if [ -n "${MOCK_TEST_HOOK:-}" ]; then
      bash -c "$MOCK_TEST_HOOK"
    fi
    echo "test result: mock"
    exit "${MOCK_TEST_EXIT:-0}"
    ;;
  doc)
    if [ "${MOCK_DOC_NO_LIB:-false}" = "true" ]; then
      echo "error: no library targets found in package \`mock\`" >&2
      exit 101
    fi
    echo "Doc-tests mock"
    exit "${MOCK_DOC_EXIT:-0}"
    ;;
  report-lcov)
    output="$(option_value --output-path "$@")"
    if [ -n "${MOCK_LCOV:-}" ]; then
      printf '%b' "$MOCK_LCOV" > "$output"
    else
      printf '%s\n' "SF:/src/lib.rs" "LF:8" "LH:6" "end_of_record" \
        "SF:/src/main.rs" "LF:4" "LH:1" "end_of_record" > "$output"
    fi
    ;;
  report-cobertura)
    output="$(option_value --output-path "$@")"
    printf '%s\n' '<?xml version="1.0" ?>' '<coverage line-rate="0.5"/>' \
      > "$output"
    ;;
esac
