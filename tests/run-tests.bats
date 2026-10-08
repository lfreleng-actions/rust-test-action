#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Unit tests for scripts/prepare.sh and scripts/run-tests.sh, run
# against cargo, rustup and rustc stand-ins (fixtures/). Nothing is
# compiled and nothing touches the network.

# Each @test runs in its own subshell and setup() resets the state, so
# variables exported inside one test stay local to it. Single-quoted
# '$' text is deliberate: it is test data or a script for bash -c.
# shellcheck disable=SC2016,SC2030,SC2031

bats_require_minimum_version 1.7.0

setup() {
  repo_dir="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  script="$repo_dir/scripts/run-tests.sh"
  prepare="$repo_dir/scripts/prepare.sh"
  mkdir -p "$BATS_TEST_TMPDIR/work space"
  # Spaces in every path catch missing quotes.
  workdir="$(cd "$BATS_TEST_TMPDIR/work space" && pwd -P)"
  project="$workdir/my crate"
  mkdir -p "$workdir/bin" "$project/src" "$workdir/runner temp"
  local tool
  for tool in cargo rustup rustc; do
    cp "$BATS_TEST_DIRNAME/fixtures/$tool.sh" "$workdir/bin/$tool"
    chmod +x "$workdir/bin/$tool"
  done
  cp "$BATS_TEST_DIRNAME/fixtures/record-credentials.sh" "$workdir/bin/"
  # The stand-ins and setup scripts get the bash running these tests,
  # whatever /bin/bash is. Tests that loop call setup again, so it
  # must tolerate what an earlier call left behind.
  ln -sf "$BASH" "$workdir/bin/bash"
  printf '%s\n' '[package]' 'name = "mock"' 'version = "0.1.0"' \
    > "$project/Cargo.toml"
  : > "$project/Cargo.lock"

  # No real cargo or rustup can leak in from the caller's PATH.
  export PATH="$workdir/bin:/usr/bin:/bin"
  export GITHUB_WORKSPACE="$workdir"
  export GITHUB_OUTPUT="$workdir/github output"
  export GITHUB_STEP_SUMMARY="$workdir/job summary"
  export RUNNER_TEMP="$workdir/runner temp"
  export INPUT_PATH_PREFIX="my crate"
  export MOCK_CALLS="$workdir/cargo calls"
  export MOCK_ENV_LOG="$workdir/cargo env"
  export MOCK_ARGS="$workdir/test args"
  export MOCK_RUSTUP_LOG="$workdir/rustup calls"
  export MOCK_RUSTUP_ARGV="$workdir/rustup argv"
  export MOCK_CRED_LOG="$workdir/credentials"
  unset INPUT_MANIFEST_PATH INPUT_WORKSPACE INPUT_PACKAGES INPUT_EXCLUDE
  unset INPUT_FEATURES INPUT_ALL_FEATURES INPUT_NO_DEFAULT_FEATURES
  unset INPUT_TOOLCHAIN INPUT_LOCKFILE_REQUIRED INPUT_SETUP_SCRIPT
  unset INPUT_TOOLCHAIN_COMPONENTS INPUT_TOOLCHAIN_TARGETS
  unset INPUT_TEST_RUNNER INPUT_NEXTEST_VERSION INPUT_TEST_ARGS
  unset INPUT_DOC_TESTS INPUT_COVERAGE INPUT_LLVM_COV_VERSION INPUT_JUNIT
  unset INPUT_ARTEFACT_UPLOAD INPUT_ARTEFACT_NAME INPUT_ARTEFACT_PATH
  unset INPUT_PERMIT_FAIL
  unset INPUT_SUMMARY
  unset MOCK_FAIL_STAGE MOCK_TEST_EXIT MOCK_DOC_EXIT MOCK_DOC_NO_LIB
  unset MOCK_NO_JUNIT MOCK_LCOV MOCK_ROOT_MANIFEST MOCK_TOOLCHAIN
  unset MOCK_TOOLCHAIN_REASON MOCK_TREE MOCK_TEST_HOOK
  unset MOCK_RUSTUP_FAIL MOCK_COMPONENT_FAIL MOCK_INSTALL_FAIL MOCK_MISSING
  unset MOCK_CARGO_VERSION
  unset MOCK_RUSTC_VERSION MOCK_RUSTC_FAIL MOCK_RUSTC_LINE RUSTUP_TOOLCHAIN
  unset CARGO_REGISTRY_TOKEN CARGO_REGISTRIES_CRATES_IO_TOKEN
  unset CARGO_REGISTRIES_PRIVATE_TOKEN CARGO_REGISTRIES_PRIVATE_INDEX
  unset ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL
  unset ACTIONS_RUNTIME_TOKEN GITHUB_ENV GITHUB_PATH GITHUB_STATE
  local file
  for file in "$GITHUB_OUTPUT" "$GITHUB_STEP_SUMMARY" "$MOCK_CALLS" \
    "$MOCK_ENV_LOG" "$MOCK_ARGS" "$MOCK_RUSTUP_LOG" "$MOCK_RUSTUP_ARGV" \
    "$MOCK_CRED_LOG"; do
    : > "$file"
  done
}

run_action() {
  run "$BASH" "$script"
}

run_prepare() {
  run "$BASH" "$prepare"
}

output_value() {
  sed -n "s/^$1=//p" "$GITHUB_OUTPUT"
}

# The arguments of the calls classified as stage $1, one call per line.
stage_calls() {
  sed -n "s/^$1: //p" "$MOCK_CALLS"
}

# The test run's arguments, one per line.
test_args() {
  cat "$MOCK_ARGS"
}

stage_list() {
  sed 's/:.*//' "$MOCK_CALLS" | tr '\n' ' '
}

# Field N of the environment recorded for stage $1: 2 cwd,
# 3 RUSTUP_TOOLCHAIN.
stage_env() {
  awk -F'|' -v stage="$1" -v field="$2" \
    '$1 == stage { print $field }' "$MOCK_ENV_LOG"
}

reports_dir() {
  find "$RUNNER_TEMP" -maxdepth 1 -type d -name 'rust-test-reports.*'
}

summary() {
  cat "$GITHUB_STEP_SUMMARY"
}

manifest="Cargo.toml"
# The selection cargo receives with the default inputs.
select_line() {
  printf -- '--manifest-path %s --locked --workspace' "$project/$manifest"
}

### Default flow ###

@test "runs cargo test with the default inputs and records every output" {
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_list)" = "version locate test " ]
  [ "$(stage_calls test)" = "test $(select_line)" ]
  [ "$(cat "$GITHUB_OUTPUT")" = "$(printf '%s\n' \
    toolchain=stable-x86_64-unknown-linux-gnu toolchain_kind=channel \
    cargo_version=1.99.0 rustc_version=1.99.0 tests_outcome=passed \
    coverage_percent= junit_path= coverage_lcov_path= \
    coverage_cobertura_path= "artefact_path=$(reports_dir)" report_dir= \
    artefact_name=rust-test-results)" ]
  [[ "$output" == *"Rust tests complete"* ]]
}

@test "runs every command in the project directory, pinned to the channel" {
  export INPUT_COVERAGE=true INPUT_TEST_RUNNER=nextest
  rm "$project/Cargo.lock"
  run_action

  [ "$status" -eq 0 ]
  [ "$(cut -d'|' -f2 "$MOCK_ENV_LOG" | sort -u)" = "$project" ]
  [ "$(cut -d'|' -f3 "$MOCK_ENV_LOG" | sort -u)" \
    = stable-x86_64-unknown-linux-gnu ]
  [ "$(stage_env rustc-version 3)" = stable-x86_64-unknown-linux-gnu ]
  [ "$(cut -d'|' -f1 "$MOCK_RUSTUP_LOG" | sort -u)" = "$project" ]
}

@test "writes a job summary with the outcome and a check table" {
  run_action

  [ "$status" -eq 0 ]
  summary | grep -qx '## 🦀 Rust Test'
  summary | grep -qx '### ✅ Tests passed'
  summary | grep -qx '| Check | Result |'
  summary | grep -qF '| Runner | <code>cargo test</code> |'
  summary | grep -qF '| Manifest | <code>my crate/Cargo.toml</code> |'
  summary | grep -qF '| Lockfile | ✅ Present |'
  summary | grep -qF '| Tests | ✅ Passed |'
  summary | grep -qF '| Doc tests | ✅ Run by <code>cargo test</code> |'
  summary | grep -qF '| Coverage | ➖ Not requested |'
  summary | grep -qF '| Artefact | ➖ No reports to upload |'
}

@test "summary 'false' writes no job summary" {
  export INPUT_SUMMARY=false
  run_action

  [ "$status" -eq 0 ]
  [ ! -s "$GITHUB_STEP_SUMMARY" ]
}

@test "escapes untrusted values in the job summary" {
  mkdir -p "$workdir/a|b<i>"
  cp "$project/Cargo.toml" "$project/Cargo.lock" "$workdir/a|b<i>/"
  export INPUT_PATH_PREFIX="a|b<i>"
  run_action

  [ "$status" -eq 0 ]
  summary | grep -qF '<code>a&#124;b&lt;i&gt;/Cargo.toml</code>'
  run ! grep -qF 'a|b<i>' "$GITHUB_STEP_SUMMARY"
}

### Toolchain ###

@test "the toolchain input overrides the project's selection" {
  export INPUT_TOOLCHAIN=1.85.0
  run_action

  [ "$status" -eq 0 ]
  # Installed already: probed without auto-install, from the project
  # directory, never reinstalled nor named through rustup show.
  [ "$(cat "$MOCK_RUSTUP_ARGV")" = '<which><--toolchain><1.85.0><rustc>' ]
  [ "$(cut -d'|' -f1,2 "$MOCK_RUSTUP_LOG")" = "$project|1.85.0" ]
  [ "$(output_value toolchain)" = 1.85.0 ]
  [ "$(output_value toolchain_kind)" = channel ]
  [ "$(cut -d'|' -f3 "$MOCK_ENV_LOG" | sort -u)" = 1.85.0 ]
  # Nothing requested, so no row for components and targets.
  run ! grep -q 'Components and targets' "$GITHUB_STEP_SUMMARY"
}

@test "installs a toolchain named by the input only when it is missing" {
  export INPUT_TOOLCHAIN=1.85.0 MOCK_MISSING=1.85.0
  run_action

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_RUSTUP_ARGV")" = "$(printf '%s\n' \
    '<which><--toolchain><1.85.0><rustc>' \
    '<toolchain><install><1.85.0><--profile><minimal><--no-self-update>')" ]
  # Both run before every cargo call.
  [ "$(head -n2 "$MOCK_CRED_LOG" | cut -d' ' -f1-3)" \
    = "$(printf '%s\n' 'rustup which --toolchain' 'rustup toolchain install')" ]
  [ "$(output_value toolchain_kind)" = channel ]
  [ "$(cut -d'|' -f3 "$MOCK_ENV_LOG" | sort -u)" = 1.85.0 ]
  run ! grep -q 'Components and targets' "$GITHUB_STEP_SUMMARY"
}

@test "a path toolchain runs unpinned with a warning" {
  export MOCK_TOOLCHAIN="/opt/rust tool"
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value toolchain)" = "/opt/rust tool" ]
  [ "$(output_value toolchain_kind)" = path ]
  [ "$(cut -d'|' -f3 "$MOCK_ENV_LOG" | sort -u)" = unset ]
  [[ "$output" == *"::warning::The project selects the path toolchain"* ]]
  summary | grep -qF '⚠️ Path toolchain <code>/opt/rust tool</code>'
}

# Output shapes taken from rustup 1.29.1.
@test "keeps parentheses that belong to a path toolchain" {
  export MOCK_TOOLCHAIN="/opt/rust (legacy)"
  export MOCK_TOOLCHAIN_REASON="overridden by '/src/p (x)/rust-toolchain.toml'"
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value toolchain)" = "/opt/rust (legacy)" ]
  [ "$(output_value toolchain_kind)" = path ]
}

@test "reads the toolchain whatever reason rustup gives" {
  local reason
  for reason in 'overridden by environment variable RUSTUP_TOOLCHAIN' \
    'environment override by RUSTUP_TOOLCHAIN' \
    "directory override for '/src/p (x)'" 'a future reason'; do
    setup
    export MOCK_TOOLCHAIN="/opt/rust (legacy)" MOCK_TOOLCHAIN_REASON="$reason"
    run_action
    [ "$status" -eq 0 ]
    [ "$(output_value toolchain)" = "/opt/rust (legacy)" ]
  done
  setup
  export MOCK_TOOLCHAIN=nightly-2026-09-01
  export MOCK_TOOLCHAIN_REASON='overridden by environment variable RUSTUP_TOOLCHAIN'
  run_action
  [ "$status" -eq 0 ]
  [ "$(output_value toolchain)" = nightly-2026-09-01 ]
  [ "$(stage_env version 3)" = nightly-2026-09-01 ]
}

@test "works without rustup" {
  rm "$workdir/bin/rustup"
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value toolchain)" = "" ]
  [ "$(output_value toolchain_kind)" = none ]
  [ "$(cut -d'|' -f3 "$MOCK_ENV_LOG" | sort -u)" = unset ]
  summary | grep -qF '| Toolchain | No rustup: cargo 1.99.0 |'
}

@test "the toolchain input without rustup fails" {
  rm "$workdir/bin/rustup"
  export INPUT_TOOLCHAIN=stable
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"toolchain needs rustup"* ]]
  [ ! -s "$MOCK_CALLS" ]
}

@test "fails when rustup cannot name the toolchain" {
  export MOCK_RUSTUP_FAIL=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"rustup could not name the toolchain"* ]]
}

@test "rejects an unexpected toolchain name from rustup" {
  export MOCK_TOOLCHAIN='stable;evil'
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected toolchain name"* ]]
  [ "$(output_value toolchain)" = "" ]
}

@test "reports pre-release and build versions" {
  export MOCK_CARGO_VERSION='1.99.0-nightly' MOCK_RUSTC_VERSION='1.99.0+local.1'
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value cargo_version)" = 1.99.0-nightly ]
  [ "$(output_value rustc_version)" = 1.99.0+local.1 ]
}

@test "fails on an unexpected cargo version" {
  local version
  for version in '$(boom)' '1.99' 'v1.99.0' '1.99.0;x' '1.99.0-'; do
    setup
    export MOCK_CARGO_VERSION="$version"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"cargo --version reported an unexpected version"* ]]
    [ "$(output_value cargo_version)" = "" ]
    [ "$(output_value tests_outcome)" = failed ]
    [ -z "$(stage_calls test)" ]
  done
}

@test "fails on an unexpected rustc version" {
  local version
  for version in 'unknown' '1.99.0x' '1.99.0.1'; do
    setup
    export MOCK_RUSTC_VERSION="$version"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"rustc --version reported an unexpected version"* ]]
    [ "$(output_value rustc_version)" = "" ]
    [ -z "$(stage_calls test)" ]
  done

  # A version line from some other program is not rustc's.
  setup
  export MOCK_RUSTC_LINE='clippy-driver 1.99.0 (abc123 2026-09-01)'
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"rustc --version reported an unexpected version"* ]]
  [ "$(output_value rustc_version)" = "" ]
}

@test "fails when cargo or rustc cannot report a version" {
  export MOCK_FAIL_STAGE=version
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo --version failed for the selected toolchain"* ]]
  [ "$(output_value cargo_version)" = "" ]

  setup
  export MOCK_RUSTC_FAIL=1
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"rustc --version failed for the selected toolchain"* ]]
  [ "$(output_value rustc_version)" = "" ]
  [ -z "$(stage_calls test)" ]
}

### Toolchain components and targets ###

# The rustup calls other than 'show active-toolchain'.
install_calls() {
  grep -vxF '<show><active-toolchain>' "$MOCK_RUSTUP_ARGV" || true
}

@test "installs components and targets in one rustup call" {
  export INPUT_TOOLCHAIN=1.90.0 INPUT_TOOLCHAIN_COMPONENTS='clippy rust-src'
  export INPUT_TOOLCHAIN_TARGETS=wasm32-unknown-unknown
  run_action

  [ "$status" -eq 0 ]
  # A list named anything, so no probe: the one install call alone.
  [ "$(install_calls)" = "$(printf '%s' '<toolchain><install><1.90.0>' \
    '<--profile><minimal><--no-self-update>' \
    '<--component><clippy,rust-src><--target><wasm32-unknown-unknown>')" ]
  # The install comes before every cargo call, in the project directory.
  [ "$(head -n1 "$MOCK_CRED_LOG" | cut -d'|' -f1)" \
    = 'rustup toolchain install 1.90.0 --profile minimal --no-self-update --component clippy,rust-src --target wasm32-unknown-unknown' ]
  [ "$(cut -d'|' -f1,2 "$MOCK_RUSTUP_LOG")" = "$project|1.90.0" ]
  summary | grep -qF '| Components and targets | ✅ components <code>clippy rust-src</code>, targets <code>wasm32-unknown-unknown</code> |'
}

@test "splits components and targets on commas and whitespace" {
  export INPUT_TOOLCHAIN_COMPONENTS=$'clippy,rustfmt\r\n rust-src\t, llvm-tools-preview'
  export INPUT_TOOLCHAIN_TARGETS=' x86_64-unknown-linux-musl,,aarch64-unknown-linux-gnu '
  run_action

  [ "$status" -eq 0 ]
  [ "$(install_calls)" = "$(printf '%s' \
    '<toolchain><install><stable-x86_64-unknown-linux-gnu>' \
    '<--profile><minimal><--no-self-update>' \
    '<--component><clippy,rustfmt,rust-src,llvm-tools-preview>' \
    '<--target><x86_64-unknown-linux-musl,aarch64-unknown-linux-gnu>')" ]
}

@test "passes only the lists that name anything" {
  export INPUT_TOOLCHAIN_TARGETS=thumbv7em-none-eabihf
  run_action
  [ "$status" -eq 0 ]
  [ "$(install_calls)" = "$(printf '%s' \
    '<toolchain><install><stable-x86_64-unknown-linux-gnu>' \
    '<--profile><minimal><--no-self-update><--target><thumbv7em-none-eabihf>')" ]
  summary | grep -qF '| Components and targets | ✅ targets <code>thumbv7em-none-eabihf</code> |'

  setup
  export INPUT_TOOLCHAIN_COMPONENTS=' , clippy '
  run_action
  [ "$status" -eq 0 ]
  [ "$(install_calls)" = "$(printf '%s' \
    '<toolchain><install><stable-x86_64-unknown-linux-gnu>' \
    '<--profile><minimal><--no-self-update><--component><clippy>')" ]
  summary | grep -qF '| Components and targets | ✅ components <code>clippy</code> |'
}

@test "leaves a project's channel alone when nothing is requested" {
  export INPUT_TOOLCHAIN_COMPONENTS=' , ' INPUT_TOOLCHAIN_TARGETS=$'\n'
  run_action

  [ "$status" -eq 0 ]
  [ -z "$(install_calls)" ]
  run ! grep -q 'Components and targets' "$GITHUB_STEP_SUMMARY"
}

@test "fails when rustup cannot install the toolchain" {
  export INPUT_TOOLCHAIN=1.90.0 INPUT_TOOLCHAIN_COMPONENTS=clippy
  export MOCK_INSTALL_FAIL=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::rustup could not install toolchain 1.90.0 with the requested toolchain_components and toolchain_targets"* ]]
  [ ! -s "$MOCK_CALLS" ]
  [ "$(output_value cargo_version)" = "" ]
  summary | grep -qF '### ❌ Failed at Install toolchain'
  summary | grep -qF '| Components and targets | ❌ rustup could not install them |'

  # A missing toolchain named by the input alone fails the same way,
  # without naming the lists, which requested nothing.
  setup
  export INPUT_TOOLCHAIN=1.90.0 MOCK_MISSING=1.90.0 MOCK_INSTALL_FAIL=true
  run_action
  [ "$status" -eq 1 ]
  [ "$(grep '^::error::' <<< "$output")" \
    = '::error::rustup could not install toolchain 1.90.0' ]
  [ ! -s "$MOCK_CALLS" ]
  summary | grep -qF '### ❌ Failed at Install toolchain'
  run ! grep -q 'Components and targets' "$GITHUB_STEP_SUMMARY"
}

@test "a path toolchain ignores components and targets with a warning" {
  export MOCK_TOOLCHAIN="/opt/rust tool"
  export INPUT_TOOLCHAIN_COMPONENTS=clippy INPUT_TOOLCHAIN_TARGETS=wasm32-wasip1
  run_action

  [ "$status" -eq 0 ]
  [ -z "$(install_calls)" ]
  [[ "$output" == *"::warning::toolchain_components and toolchain_targets are ignored for a path toolchain; install them into that toolchain instead"* ]]
  summary | grep -qF '| Components and targets | ⚠️ Ignored for a path toolchain |'
}

@test "components or targets without rustup fail, naming the inputs" {
  local input
  for input in TOOLCHAIN_COMPONENTS TOOLCHAIN_TARGETS; do
    setup
    rm "$workdir/bin/rustup"
    export "INPUT_$input=clippy"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::toolchain_components and toolchain_targets need rustup on PATH"* ]]
    [ ! -s "$MOCK_CALLS" ]
    [ "$(output_value toolchain_kind)" = none ]
    summary | grep -qF '| Components and targets | ❌ Needs rustup |'
  done
}

@test "rejects invalid component and target names without echoing them" {
  local input message value
  for input in TOOLCHAIN_COMPONENTS TOOLCHAIN_TARGETS; do
    case "$input" in
      TOOLCHAIN_COMPONENTS)
        message="toolchain_components must list rustup component names" ;;
      TOOLCHAIN_TARGETS)
        message="toolchain_targets must list target triples" ;;
    esac
    for value in $'clippy\n::error::forged' '-clippy' '.hidden' '_x' \
      'clippy;evil' 'a/b' 'x+y' 'cé' $'ok\r::error::forged'; do
      setup
      export "INPUT_$input=$value"
      run_action
      [ "$status" -eq 1 ]
      [[ "$output" == *"::error::$message"* ]]
      [[ "$output" != *"forged"* ]]
      [ ! -s "$MOCK_RUSTUP_LOG" ]
      [ ! -s "$MOCK_CALLS" ]
      # prepare.sh checks the same inputs.
      run_prepare
      [ "$status" -eq 1 ]
      [[ "$output" == *"::error::$message"* ]]
    done
  done
}

@test "accepts the characters rustup names use" {
  export INPUT_TOOLCHAIN_COMPONENTS='rustc-codegen-cranelift-preview 0llvm.tools_x'
  export INPUT_TOOLCHAIN_TARGETS='x86_64-unknown-linux-gnu.v2 wasm32-wasip1'
  run_action

  [ "$status" -eq 0 ]
  [[ "$(install_calls)" == *'<--component><rustc-codegen-cranelift-preview,0llvm.tools_x><--target><x86_64-unknown-linux-gnu.v2,wasm32-wasip1>' ]]
}

@test "withholds credentials and runner command files from the install" {
  local request
  # With a list, the install alone; without, the probe and the install.
  for request in 1:INPUT_TOOLCHAIN_COMPONENTS=clippy 2:MOCK_MISSING=1.90.0; do
    setup
    export CARGO_REGISTRY_TOKEN=secret-a CARGO_REGISTRIES_CRATES_IO_TOKEN=secret-b
    export CARGO_REGISTRIES_PRIVATE_TOKEN=secret-e
    export CARGO_REGISTRIES_PRIVATE_INDEX=sparse+https://index.example/
    export ACTIONS_ID_TOKEN_REQUEST_TOKEN=secret-c
    export ACTIONS_ID_TOKEN_REQUEST_URL=https://token.example
    export ACTIONS_RUNTIME_TOKEN=secret-d
    export GITHUB_ENV="$workdir/command-env" GITHUB_PATH="$workdir/command-path"
    export GITHUB_STATE="$workdir/command-state"
    export INPUT_TOOLCHAIN=1.90.0 "${request#*:}"
    run_action

    [ "$status" -eq 0 ]
    [ "$(grep -c '^rustup ' "$MOCK_CRED_LOG")" -eq "${request%%:*}" ]
    [ "$(grep '^rustup ' "$MOCK_CRED_LOG" | cut -d'|' -f2- | sort -u)" \
      = "$(printf 'unset|%.0s' {1..11})sparse+https://index.example/" ]
  done
}

### Credentials ###

@test "withholds credentials and runner command files from every command" {
  export CARGO_REGISTRY_TOKEN=secret-a CARGO_REGISTRIES_CRATES_IO_TOKEN=secret-b
  export CARGO_REGISTRIES_PRIVATE_TOKEN=secret-e
  export CARGO_REGISTRIES_PRIVATE_INDEX=sparse+https://index.example/
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN=secret-c
  export ACTIONS_ID_TOKEN_REQUEST_URL=https://token.example
  export ACTIONS_RUNTIME_TOKEN=secret-d
  export GITHUB_ENV="$workdir/command-env" GITHUB_PATH="$workdir/command-path"
  export GITHUB_STATE="$workdir/command-state"
  export INPUT_TEST_RUNNER=nextest INPUT_COVERAGE=true
  printf '%s\n' 'env > "$SETUP_ENV"' > "$project/setup.sh"
  export INPUT_SETUP_SCRIPT=setup.sh SETUP_ENV="$workdir/setup env"
  rm "$project/Cargo.lock"
  run_action

  [ "$status" -eq 0 ]
  # Eleven withheld variables, then the registry index, which stays.
  [ "$(cut -d'|' -f2- "$MOCK_CRED_LOG" | sort -u)" \
    = "$(printf 'unset|%.0s' {1..11})sparse+https://index.example/" ]
  # Every program the action runs reported in: the toolchain lookup,
  # cargo and rustc versions, both plugins, llvm-tools and the tests.
  local program
  for program in 'rustup show active-toolchain' rustc 'cargo version' \
    'cargo nextest-version' 'cargo llvm-cov-version' \
    'rustup component add llvm-tools-preview --toolchain stable-x86_64-unknown-linux-gnu' \
    'cargo locate' 'cargo generate-lockfile' 'cargo cov-clean' 'cargo tree' \
    'cargo test' 'cargo doc' 'cargo report-lcov'; do
    cut -d'|' -f1 "$MOCK_CRED_LOG" | grep -qxF "$program"
  done
  [ -s "$workdir/setup env" ]
  run ! grep -E 'secret|token\.example|^GITHUB_(OUTPUT|ENV|PATH|STATE|STEP_SUMMARY)=' \
    "$workdir/setup env"
  grep -qxF 'CARGO_REGISTRIES_PRIVATE_INDEX=sparse+https://index.example/' \
    "$workdir/setup env"
  # The action's own writes still reach the command files.
  [ "$(output_value tests_outcome)" = passed ]
  [ -n "$(output_value junit_path)" ]
  summary | grep -qF '## 🦀 Rust Test'
}

# Write a stand-in for each named program to $workdir/planted-<name>:
# it records the withheld variables, then runs the real program.
write_planted() {
  local name
  for name in "$@"; do
    printf '%s\n' '#!/bin/bash' \
      "source \"$workdir/bin/record-credentials.sh\"" \
      "record_credentials \"planted $name\"" \
      "for d in /usr/bin /bin; do [ -x \"\$d/$name\" ] && exec \"\$d/$name\" \"\$@\"; done" \
      'exit 127' > "$workdir/planted-$name"
  done
}

export_withheld() {
  export CARGO_REGISTRY_TOKEN=secret-a CARGO_REGISTRIES_PRIVATE_TOKEN=secret-e
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN=secret-c ACTIONS_RUNTIME_TOKEN=secret-d
  export GITHUB_ENV="$workdir/command-env"
}

# An earlier step in the job may have put repository-controlled
# programs on PATH, so both scripts scrub before running any program.
@test "programs already on PATH get no credentials in either script" {
  local which name
  for which in prepare action; do
    setup
    export_withheld
    write_planted dirname ls
    for name in dirname ls; do
      cp "$workdir/planted-$name" "$workdir/bin/$name"
      chmod +x "$workdir/bin/$name"
    done
    # An existing, empty artefact_path makes the input check list it.
    rm -rf "$project/reports"
    mkdir "$project/reports"
    export INPUT_ARTEFACT_PATH=reports INPUT_SETUP_SCRIPT=setup.sh
    : > "$project/setup.sh"
    "run_$which"
    export PATH=/usr/bin:/bin

    [ "$status" -eq 0 ]
    grep -q '^planted dirname|' "$MOCK_CRED_LOG"
    grep -q '^planted ls|' "$MOCK_CRED_LOG"
    [ "$(cut -d'|' -f2-12 "$MOCK_CRED_LOG" | sort -u)" \
      = "$(printf 'unset|%.0s' {1..10})unset" ]
    [ -n "$(cat "$GITHUB_OUTPUT")" ]
  done
}

# Project code can put programs on PATH, for example in Cargo's bin
# directory, and the action runs helpers such as tee and rm after it.
@test "programs planted on PATH by project code get no credentials" {
  export_withheld
  write_planted env tee find rm ls wc grep awk sed cat mktemp
  printf '%s\n' 'for f in "$PLANTED"/planted-*; do' \
    '  cp "$f" "$PLANTED/bin/${f##*/planted-}"; chmod +x "$PLANTED/bin/${f##*/planted-}"' \
    'done' > "$project/setup.sh"
  export INPUT_SETUP_SCRIPT=setup.sh PLANTED="$workdir"
  export INPUT_TEST_RUNNER=nextest INPUT_COVERAGE=true
  run_action
  # The assertions must not run the planted programs themselves.
  export PATH=/usr/bin:/bin

  [ "$status" -eq 0 ]
  grep -q '^planted tee|' "$MOCK_CRED_LOG"
  grep -q '^planted rm|' "$MOCK_CRED_LOG"
  [ "$(cut -d'|' -f2-12 "$MOCK_CRED_LOG" | sort -u)" \
    = "$(printf 'unset|%.0s' {1..10})unset" ]
  [ "$(output_value tests_outcome)" = passed ]
}

### Project selection ###

@test "passes the selection inputs to cargo" {
  export INPUT_EXCLUDE="delta  epsilon" INPUT_FEATURES="serde, fast/simd  tls"
  export INPUT_ALL_FEATURES=true INPUT_NO_DEFAULT_FEATURES=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_calls test)" = "test $(select_line) --exclude delta --exclude epsilon --features serde,fast/simd,tls --all-features --no-default-features" ]
}

# cargo would run every member given --workspace and -p together.
@test "packages replace --workspace" {
  export INPUT_PACKAGES=$'alpha  beta\ngamma_1'
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_calls test)" = "test --manifest-path $project/Cargo.toml --locked -p alpha -p beta -p gamma_1" ]
}

@test "workspace 'false' leaves out --workspace" {
  export INPUT_WORKSPACE=false
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_calls test)" = "test --manifest-path $project/Cargo.toml --locked" ]
}

@test "exclude with packages fails" {
  export INPUT_PACKAGES=alpha INPUT_EXCLUDE=beta
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"exclude cannot be combined with packages"* ]]
  [ ! -s "$MOCK_CALLS" ]
}

@test "uses manifest_path below path_prefix" {
  mkdir -p "$project/crates/inner"
  cp "$project/Cargo.toml" "$project/crates/inner/Cargo.toml"
  export INPUT_MANIFEST_PATH=crates/inner/Cargo.toml
  manifest=crates/inner/Cargo.toml
  export MOCK_ROOT_MANIFEST="$project/Cargo.toml"
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_calls test)" = "test $(select_line)" ]
  summary | grep -qF '<code>my crate/crates/inner/Cargo.toml</code>'
}

@test "rejects invalid package, exclude and feature names" {
  local input value
  for input in PACKAGES EXCLUDE FEATURES; do
    for value in 'a;b' '$(x)' '../up' 'a=b'; do
      setup
      export "INPUT_$input=$value"
      run_action
      [ "$status" -eq 1 ]
      [[ "$output" == *"contains an invalid name"* ]]
      [[ "$output" != *"$value"* ]]
      [ ! -s "$MOCK_CALLS" ]
    done
  done
}

@test "accepts feature names with dots, plus signs and a package prefix" {
  export INPUT_FEATURES="simd.v2,codec+fast my-dep/simd.v2 _x"
  run_action

  [ "$status" -eq 0 ]
  [[ "$(stage_calls test)" == *" --features simd.v2,codec+fast,my-dep/simd.v2,_x"* ]]
}

@test "rejects malformed feature names" {
  local value
  for value in '.hidden' '+x' 'a/b/c' '/x' 'x/' 'a/.b'; do
    setup
    export INPUT_FEATURES="$value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"features contains an invalid name"* ]]
    [ ! -s "$MOCK_CALLS" ]
  done
}

@test "exclude without workspace fails" {
  export INPUT_EXCLUDE=alpha INPUT_WORKSPACE=false
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"exclude needs workspace 'true'"* ]]
}

### Path containment ###

@test "rejects a path_prefix outside the workspace" {
  local value
  for value in /etc .. "my crate/../.." "$BATS_TEST_TMPDIR"; do
    setup
    export INPUT_PATH_PREFIX="$value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"path_prefix must resolve inside the workspace"* ]]
    [ ! -s "$MOCK_CALLS" ]
  done
}

@test "rejects a path_prefix symlink leading out of the workspace" {
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  cp "$project/Cargo.toml" "$BATS_TEST_TMPDIR/outside/"
  ln -s "$BATS_TEST_TMPDIR/outside" "$workdir/link"
  export INPUT_PATH_PREFIX=link
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"path_prefix must resolve inside the workspace"* ]]
}

@test "rejects a missing path_prefix" {
  export INPUT_PATH_PREFIX=missing
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"path_prefix is not a directory"* ]]
}

@test "accepts an absolute path_prefix inside the workspace" {
  export INPUT_PATH_PREFIX="$project"
  run_action

  [ "$status" -eq 0 ]
}

@test "rejects a manifest_path that is not a Cargo.toml" {
  export INPUT_MANIFEST_PATH=src/lib.rs
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest_path must name a Cargo.toml file"* ]]
}

@test "rejects an absolute or missing manifest_path" {
  export INPUT_MANIFEST_PATH="$project/Cargo.toml"
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest_path must be a path relative to path_prefix"* ]]

  export INPUT_MANIFEST_PATH=sub/Cargo.toml
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest_path does not name a file"* ]]
}

@test "rejects a symlinked manifest_path" {
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  cp "$project/Cargo.toml" "$BATS_TEST_TMPDIR/outside/"
  mkdir -p "$project/sub"
  ln -s "$BATS_TEST_TMPDIR/outside/Cargo.toml" "$project/sub/Cargo.toml"
  export INPUT_MANIFEST_PATH=sub/Cargo.toml
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest_path must not be a symlink"* ]]
}

@test "rejects a manifest_path escaping the workspace" {
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  cp "$project/Cargo.toml" "$BATS_TEST_TMPDIR/outside/"
  export INPUT_PATH_PREFIX=. INPUT_MANIFEST_PATH=../outside/Cargo.toml
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest_path must resolve inside the workspace"* ]]
}

@test "a failed cargo test leaves its doc tests unconfirmed" {
  export MOCK_TEST_EXIT=101
  run_action

  [ "$status" -eq 1 ]
  summary | grep -qF '| Doc tests | ⚠️ Unknown: <code>cargo test</code> failed |'
}

### Lockfile ###

@test "generates a missing Cargo.lock with a warning" {
  rm "$project/Cargo.lock"
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_list)" = "version locate generate-lockfile test " ]
  [ "$(stage_calls generate-lockfile)" \
    = "generate-lockfile --manifest-path $project/Cargo.toml" ]
  [[ "$output" == *"::warning::Cargo.lock is missing"* ]]
  summary | grep -qF '| Lockfile | ⚠️ Generated |'
  summary | grep -qF -- '- Cargo.lock is missing'
}

@test "lockfile_required fails on a missing Cargo.lock" {
  rm "$project/Cargo.lock"
  export INPUT_LOCKFILE_REQUIRED=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"Cargo.lock is missing and lockfile_required is 'true'"* ]]
  [ -z "$(stage_calls generate-lockfile)" ]
  [ -z "$(stage_calls test)" ]
  summary | grep -qx '### ❌ Failed at Check lockfile'
}

@test "lockfile_required passes with a Cargo.lock present" {
  export INPUT_LOCKFILE_REQUIRED=true
  run_action

  [ "$status" -eq 0 ]
}

@test "looks for Cargo.lock at the workspace root" {
  mkdir -p "$project/member"
  cp "$project/Cargo.toml" "$project/member/"
  export INPUT_PATH_PREFIX="my crate/member" INPUT_LOCKFILE_REQUIRED=true
  export MOCK_ROOT_MANIFEST="$project/Cargo.toml"
  run_action

  [ "$status" -eq 0 ]
}

@test "a failed lockfile generation fails, even with permit_fail" {
  rm "$project/Cargo.lock"
  export MOCK_FAIL_STAGE=generate-lockfile INPUT_PERMIT_FAIL=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo generate-lockfile failed"* ]]
  [[ "$output" != *"::warning::Cargo.lock is missing"* ]]
  summary | grep -qF '| Lockfile | ❌ Generation failed |'
}

@test "rejects a symlinked Cargo.lock" {
  rm "$project/Cargo.lock"
  ln -s "$BATS_TEST_TMPDIR/elsewhere.lock" "$project/Cargo.lock"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"Cargo.lock must not be a symlink"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere.lock" ]
}

@test "rejects a workspace root outside the workspace" {
  export MOCK_ROOT_MANIFEST="$BATS_TEST_TMPDIR/Cargo.toml"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"workspace root for manifest_path lies outside"* ]]
}

@test "rejects an unexpected workspace root from cargo" {
  export MOCK_ROOT_MANIFEST="relative/Cargo.toml"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected workspace root"* ]]
}

@test "rejects a symlinked workspace root manifest" {
  mkdir "$project/root"
  printf '[workspace]\n' > "$BATS_TEST_TMPDIR/outside.toml"
  ln -s "$BATS_TEST_TMPDIR/outside.toml" "$project/root/Cargo.toml"
  export MOCK_ROOT_MANIFEST="$project/root/Cargo.toml"
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"workspace root manifest must not be a symlink"* ]]
  [ -z "$(stage_calls test)" ]
}

### Setup script ###

@test "runs setup_script in the project directory before cargo builds" {
  printf '%s\n' 'pwd -P > "$SETUP_LOG"' \
    'printf "%s\n" "${RUSTUP_TOOLCHAIN-unset}" >> "$SETUP_LOG"' \
    'cat "$MOCK_CALLS" >> "$SETUP_LOG"' > "$project/setup.sh"
  export INPUT_SETUP_SCRIPT=setup.sh SETUP_LOG="$workdir/setup log"
  run_action

  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$workdir/setup log")" = "$project" ]
  [ "$(sed -n 2p "$workdir/setup log")" = stable-x86_64-unknown-linux-gnu ]
  # Only the version query ran before it; nothing was built.
  [ "$(sed -n '3,$p' "$workdir/setup log" | sed 's/:.*//')" = version ]
  summary | grep -qF '| Setup script | ✅ <code>setup.sh</code> |'
}

@test "a failing setup_script fails, even with permit_fail" {
  printf '%s\n' 'exit 3' > "$project/setup.sh"
  export INPUT_SETUP_SCRIPT=setup.sh INPUT_PERMIT_FAIL=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"setup_script exited with status 3"* ]]
  [ -z "$(stage_calls test)" ]
  [ "$(output_value tests_outcome)" = failed ]
}

@test "a failure before the reports marks requested ones not reached" {
  printf '%s\n' 'exit 3' > "$project/setup.sh"
  export INPUT_SETUP_SCRIPT=setup.sh INPUT_TEST_RUNNER=nextest \
    INPUT_COVERAGE=true INPUT_JUNIT=true INPUT_DOC_TESTS=false
  run_action

  [ "$status" -eq 1 ]
  summary | grep -qF '| Coverage | ⏸️ Not reached |'
  summary | grep -qF '| JUnit XML | ⏸️ Not reached |'
  summary | grep -qF '| Doc tests | ➖ Disabled |'
}

@test "rejects a missing, absolute, symlinked or escaping setup_script" {
  export INPUT_SETUP_SCRIPT=missing.sh
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"setup_script does not name a file"* ]]

  printf '%s\n' 'true' > "$BATS_TEST_TMPDIR/outside.sh"
  export INPUT_SETUP_SCRIPT="$BATS_TEST_TMPDIR/outside.sh"
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"setup_script must be a path relative to path_prefix"* ]]

  ln -s "$BATS_TEST_TMPDIR/outside.sh" "$project/link.sh"
  export INPUT_SETUP_SCRIPT=link.sh
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"setup_script must not be a symlink"* ]]

  export INPUT_SETUP_SCRIPT=../../outside.sh
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"setup_script must resolve inside the workspace"* ]]
  [ ! -s "$MOCK_CALLS" ]
}

### Runner selection ###

@test "nextest runs cargo nextest with a JUnit profile by default" {
  export INPUT_TEST_RUNNER=nextest
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_list)" = "version nextest-version locate test doc " ]
  [[ "$(stage_calls test)" == "nextest run $(select_line) --profile rust-test-action --tool-config-file rust-test-action:"*/nextest.toml ]]
  local reports
  reports="$(reports_dir)"
  [ "$(output_value junit_path)" = "$reports/junit.xml" ]
  [ -s "$reports/junit.xml" ]
  [ "$(output_value report_dir)" = "$reports" ]
  summary | grep -qF '| Runner | <code>cargo nextest run</code> (nextest 0.9.146) |'
  summary | grep -qF '| JUnit XML | 📄 <code>junit.xml</code> ('
  summary | grep -qF '| Artefact | 📦 <code>rust-test-results</code> |'
}

@test "the nextest tool config holds only the JUnit profile" {
  export INPUT_TEST_RUNNER=nextest
  # Keep the scratch directory so the config can be inspected.
  cat > "$workdir/bin/rm" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$workdir/bin/rm"
  run_action

  [ "$status" -eq 0 ]
  local config
  config="$(find "$RUNNER_TEMP" -name nextest.toml)"
  [ "$(cat "$config")" = "$(printf '%s\n' '[profile.rust-test-action.junit]' \
    "path = '$(reports_dir)/junit.xml'")" ]
}

@test "the scratch directory is removed and the reports kept" {
  export INPUT_TEST_RUNNER=nextest
  run_action

  [ "$status" -eq 0 ]
  [ -z "$(find "$RUNNER_TEMP" -maxdepth 1 -name 'rust-test-action.*')" ]
  [ -s "$(reports_dir)/junit.xml" ]
}

@test "junit 'false' runs nextest with the project's own profile" {
  export INPUT_TEST_RUNNER=nextest INPUT_JUNIT=false
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_calls test)" = "nextest run $(select_line)" ]
  [ "$(output_value junit_path)" = "" ]
  [ "$(output_value report_dir)" = "" ]
  # The empty report directory stays, named by artefact_path.
  [ -d "$(reports_dir)" ]
  [ -z "$(ls -A "$(reports_dir)")" ]
  [ "$(output_value artefact_path)" = "$(reports_dir)" ]
  summary | grep -qF '| JUnit XML | ➖ Not requested |'
}

@test "junit 'true' with the cargo runner fails" {
  export INPUT_JUNIT=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"junit 'true' needs test_runner 'nextest'"* ]]
  [ ! -s "$MOCK_CALLS" ]
}

@test "the cargo runner writes no JUnit report" {
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value junit_path)" = "" ]
}

@test "fails when nextest writes no JUnit report after passing tests" {
  export INPUT_TEST_RUNNER=nextest MOCK_NO_JUNIT=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"nextest wrote no JUnit report"* ]]
  summary | grep -qx '### ❌ Failed at Collect JUnit report'
}

@test "a missing JUnit report after failing tests is only a warning" {
  export INPUT_TEST_RUNNER=nextest MOCK_NO_JUNIT=true MOCK_TEST_EXIT=101
  export INPUT_PERMIT_FAIL=true
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::nextest failed and wrote no JUnit report; see the step log."* ]]
  [[ "$output" != *"before any tests ran"* ]]
  [ "$(output_value junit_path)" = "" ]
}

@test "fails when cargo-nextest is not installed" {
  export INPUT_TEST_RUNNER=nextest MOCK_FAIL_STAGE=nextest-version
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo-nextest is not installed"* ]]
  [ -z "$(stage_calls test)" ]
}

### Doc tests ###

@test "doc_tests 'false' passes --tests to cargo test" {
  export INPUT_DOC_TESTS=false
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_calls test)" = "test $(select_line) --tests" ]
  summary | grep -qF '| Doc tests | ➖ Disabled |'
}

@test "nextest runs doc tests separately, without test_args" {
  export INPUT_TEST_RUNNER=nextest INPUT_TEST_ARGS="--no-capture"
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_calls doc)" = "test --doc $(select_line)" ]
  summary | grep -qF '| Doc tests | ✅ Passed |'
}

@test "nextest with doc_tests 'false' runs no doc tests" {
  export INPUT_TEST_RUNNER=nextest INPUT_DOC_TESTS=false
  run_action

  [ "$status" -eq 0 ]
  [ -z "$(stage_calls doc)" ]
  [[ "$(stage_calls test)" != *"--tests"* ]]
}

@test "a selection without a library has no doc tests to run" {
  export INPUT_TEST_RUNNER=nextest MOCK_DOC_NO_LIB=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value tests_outcome)" = passed ]
  summary | grep -qF '| Doc tests | ➖ No library targets |'
}

@test "failing doc tests fail the step" {
  export INPUT_TEST_RUNNER=nextest MOCK_DOC_EXIT=101
  run_action

  [ "$status" -eq 1 ]
  [ "$(output_value tests_outcome)" = failed ]
  [[ "$output" == *"Doc tests failed with exit status 101"* ]]
  summary | grep -qx '### ❌ Failed at Run doc tests'
  summary | grep -qF '| Tests | ✅ Passed |'
}

@test "doc tests still run after the main tests fail" {
  export INPUT_TEST_RUNNER=nextest MOCK_TEST_EXIT=100
  run_action

  [ "$status" -eq 1 ]
  [ -n "$(stage_calls doc)" ]
  summary | grep -qx '### ❌ Failed at Run tests'
}

### test_args ###

@test "splits test_args on whitespace without a shell" {
  : > "$project/zz-glob-target"
  export INPUT_TEST_ARGS=$'filter\t"two words"  -- --test-threads=1 * $(touch boom) ~'
  run_action

  [ "$status" -eq 0 ]
  [ "$(test_args | tail -n 9)" = "$(printf '%s\n' filter '"two' 'words"' \
    -- --test-threads=1 '*' '$(touch' 'boom)' '~')" ]
  [ ! -e "$project/boom" ]
  [ ! -e boom ]
}

@test "passes test_args to nextest after the action's own arguments" {
  export INPUT_TEST_RUNNER=nextest INPUT_TEST_ARGS="--no-tests=pass -E test(x)"
  run_action

  [ "$status" -eq 0 ]
  [[ "$(stage_calls test)" == *"/nextest.toml --no-tests=pass -E test(x)" ]]
}

@test "rejects a multi-line test_args" {
  local value
  for value in $'--a\n::error::forged' $'--a\r--b'; do
    setup
    export INPUT_TEST_ARGS="$value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"test_args must be a single line"* ]]
    [[ "$output" != *"forged"* ]]
    [ ! -s "$MOCK_CALLS" ]
  done
}

### Coverage ###

@test "coverage with cargo writes both reports and the line percentage" {
  export INPUT_COVERAGE=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_list)" = "version llvm-cov-version locate cov-clean tree test doc report-lcov report-cobertura " ]
  [ "$(stage_calls cov-clean)" = "llvm-cov clean --workspace --manifest-path $project/Cargo.toml" ]
  [ "$(stage_calls tree)" = "tree $(select_line) --depth 0 --prefix none --format {p}" ]
  [ "$(stage_calls test)" = "llvm-cov test --no-report $(select_line)" ]
  local reports
  reports="$(reports_dir)"
  [ "$(stage_calls report-lcov)" = "llvm-cov report --lcov --output-path $reports/lcov.info --manifest-path $project/Cargo.toml --locked -p mock" ]
  [ "$(stage_calls report-cobertura)" = "llvm-cov report --cobertura --output-path $reports/cobertura.xml --manifest-path $project/Cargo.toml --locked -p mock" ]
  [ "$(output_value coverage_percent)" = 58.33 ]
  [ "$(output_value coverage_lcov_path)" = "$reports/lcov.info" ]
  [ "$(output_value coverage_cobertura_path)" = "$reports/cobertura.xml" ]
  [ "$(output_value report_dir)" = "$reports" ]
  [ "$(output_value junit_path)" = "" ]
  grep -qx 'stable-x86_64-unknown-linux-gnu|component add llvm-tools-preview --toolchain stable-x86_64-unknown-linux-gnu' \
    <(cut -d'|' -f2- "$MOCK_RUSTUP_LOG")
  summary | grep -qF '| Coverage | 📊 58.33% of lines |'
  summary | grep -qF '| Doc tests | ✅ Passed |'
}

@test "coverage with nextest runs cargo llvm-cov nextest with the JUnit profile" {
  export INPUT_COVERAGE=true INPUT_TEST_RUNNER=nextest
  run_action

  [ "$status" -eq 0 ]
  [[ "$(stage_calls test)" == "llvm-cov nextest --no-report $(select_line) --profile rust-test-action --tool-config-file rust-test-action:"*/nextest.toml ]]
  local reports
  reports="$(reports_dir)"
  [ "$(output_value junit_path)" = "$reports/junit.xml" ]
  [ "$(output_value coverage_lcov_path)" = "$reports/lcov.info" ]
  [ "$(cd "$reports" && printf '%s ' *)" = "cobertura.xml junit.xml lcov.info " ]
  summary | grep -qF '(nextest 0.9.146, llvm-cov 0.9.1)'
}

@test "coverage with doc_tests 'false' runs no doc tests" {
  export INPUT_COVERAGE=true INPUT_DOC_TESTS=false
  run_action

  [ "$status" -eq 0 ]
  [ -z "$(stage_calls doc)" ]
  [ "$(stage_calls test)" = "llvm-cov test --no-report $(select_line)" ]
}

@test "parses line coverage from every lcov record" {
  local lcov expected
  while IFS='=' read -r lcov expected; do
    setup
    export INPUT_COVERAGE=true MOCK_LCOV="$lcov"
    run_action
    [ "$status" -eq 0 ]
    [ "$(output_value coverage_percent)" = "$expected" ]
  done <<'EOF'
SF:a\nLF:10\nLH:10\nend_of_record\n=100.00
SF:a\nLF:3\nLH:1\nend_of_record\nSF:b\nLF:3\nLH:1\nend_of_record\n=33.33
SF:a\nLF:3\nLH:2\nend_of_record\n=66.67
SF:a\nDA:1,1\nLF:200\nLH:0\nend_of_record\n=0.00
SF:a\nBRF:4\nBRH:4\nLF:8\nLH:1\nend_of_record\n=12.50
EOF
}

@test "an lcov report without lines gives no percentage, with a warning" {
  export INPUT_COVERAGE=true MOCK_LCOV='SF:a\nLF:0\nLH:0\nend_of_record\n'
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value coverage_percent)" = "" ]
  [ -n "$(output_value coverage_lcov_path)" ]
  [[ "$output" == *"::warning::The lcov report records no lines"* ]]
}

@test "rejects a malformed coverage figure" {
  local lcov
  for lcov in 'LF:1e400\nLH:1\n' 'LF:4\nLH:-1\n' 'LF:1\nLH:5\n' \
    'LF:2.5\nLH:1\n'; do
    setup
    export INPUT_COVERAGE=true MOCK_LCOV="$lcov"
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"could not read the line coverage"* ]]
    [ "$(output_value coverage_percent)" = "" ]
  done
}

# cargo-llvm-cov 0.9.1 'report' rejects --exclude and the feature flags,
# and with no selection covers only the root package of a workspace.
@test "coverage reports cover the packages the tests ran" {
  export INPUT_COVERAGE=true INPUT_EXCLUDE=gamma INPUT_FEATURES=fast
  export MOCK_TREE='alpha v0.1.0 (/src)\n\nbeta_two v1.0.0 (/src/b)\n'
  run_action

  [ "$status" -eq 0 ]
  [ "$(stage_calls tree)" = "tree $(select_line) --exclude gamma --features fast --depth 0 --prefix none --format {p}" ]
  local stage
  for stage in report-lcov report-cobertura; do
    [[ "$(stage_calls "$stage")" == *" --locked -p alpha -p beta_two" ]]
    [[ "$(stage_calls "$stage")" != *--exclude* ]]
    [[ "$(stage_calls "$stage")" != *--features* ]]
  done
}

@test "coverage stops before the tests when cargo tree cannot list packages" {
  local tree
  for tree in fail '' '\n\n' 'bad;name v0.1.0 (/src)\n'; do
    setup
    export INPUT_COVERAGE=true
    if [ "$tree" = fail ]; then
      export MOCK_FAIL_STAGE=tree
    else
      export MOCK_TREE="$tree"
    fi
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::"*"cargo tree"* ]]
    [ -z "$(stage_calls test)" ]
    summary | grep -qx '### ❌ Failed at Prepare coverage'
  done
}

@test "a failed coverage report fails the step after passing tests" {
  local stage
  for stage in report-lcov report-cobertura; do
    setup
    export INPUT_COVERAGE=true MOCK_FAIL_STAGE="$stage" INPUT_PERMIT_FAIL=true
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"cargo llvm-cov could not write the"* ]]
    summary | grep -qx '### ❌ Failed at Write coverage reports'
  done
}

# Doc tests run uninstrumented and outside nextest, so their failure
# cannot explain a missing report.
@test "a failed report after failing doc tests alone still fails" {
  local case
  for case in coverage junit; do
    setup
    export MOCK_DOC_EXIT=101 INPUT_PERMIT_FAIL=true
    if [ "$case" = coverage ]; then
      export INPUT_COVERAGE=true MOCK_FAIL_STAGE=report-lcov
    else
      export INPUT_TEST_RUNNER=nextest MOCK_NO_JUNIT=true
    fi
    run_action

    [ "$status" -eq 1 ]
    if [ "$case" = coverage ]; then
      summary | grep -qx '### ❌ Failed at Write coverage reports'
    else
      summary | grep -qx '### ❌ Failed at Collect JUnit report'
    fi
  done
}

@test "a failed coverage report after failing tests is only a warning" {
  export INPUT_COVERAGE=true MOCK_TEST_EXIT=101 MOCK_FAIL_STAGE=report-lcov
  export INPUT_PERMIT_FAIL=true
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::cargo llvm-cov could not write the lcov report"* ]]
  [ "$(output_value coverage_percent)" = "" ]
  [ "$(output_value tests_outcome)" = failed ]
}

@test "coverage reports are still written after failing tests" {
  export INPUT_COVERAGE=true MOCK_TEST_EXIT=101
  run_action

  [ "$status" -eq 1 ]
  [ "$(output_value coverage_percent)" = 58.33 ]
  [ -n "$(output_value report_dir)" ]
}

@test "coverage without a rustup channel skips llvm-tools with a warning" {
  rm "$workdir/bin/rustup"
  export INPUT_COVERAGE=true
  run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Coverage needs the llvm-tools component"* ]]
}

@test "fails when llvm-tools cannot be added" {
  export INPUT_COVERAGE=true MOCK_COMPONENT_FAIL=true
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"could not add the llvm-tools-preview component"* ]]
  [ -z "$(stage_calls test)" ]
}

@test "fails when cargo-llvm-cov is not installed" {
  export INPUT_COVERAGE=true MOCK_FAIL_STAGE=llvm-cov-version
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"cargo-llvm-cov is not installed"* ]]
}

### permit_fail ###

@test "failing tests fail the step" {
  export MOCK_TEST_EXIT=101
  run_action

  [ "$status" -eq 1 ]
  [ "$(output_value tests_outcome)" = failed ]
  [[ "$output" == *"::error::Tests failed with exit status 101"* ]]
  summary | grep -qx '### ❌ Failed at Run tests'
  summary | grep -qF '| Tests | ❌ Failed (exit status 101) |'
}

@test "permit_fail reports failing tests as a warned success" {
  export MOCK_TEST_EXIT=101 INPUT_PERMIT_FAIL=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value tests_outcome)" = failed ]
  [[ "$output" == *"::warning::Run tests failed; permit_fail is 'true'"* ]]
  summary | grep -qx '### ⚠️ Tests failed (permitted)'
  summary | grep -qF -- "- Run tests failed; permit&#95;fail is 'true'"
}

@test "permit_fail still writes the JUnit report for failing tests" {
  export INPUT_TEST_RUNNER=nextest MOCK_TEST_EXIT=100 INPUT_PERMIT_FAIL=true
  run_action

  [ "$status" -eq 0 ]
  [ -s "$(output_value junit_path)" ]
  [ "$(output_value report_dir)" = "$(reports_dir)" ]
}

@test "permit_fail does not excuse invalid inputs" {
  export INPUT_PERMIT_FAIL=true INPUT_TEST_RUNNER=pytest
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"test_runner must be 'cargo' or 'nextest'"* ]]
  [ "$(output_value tests_outcome)" = failed ]
  summary | grep -qx '### ❌ Failed at Check inputs'
}

### Input validation ###

@test "refuses Windows runners before running anything" {
  export RUNNER_OS=Windows
  run_prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"Windows runners are not supported"* ]]
  [ ! -s "$GITHUB_OUTPUT" ]

  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"Windows runners are not supported"* ]]
  [ ! -s "$MOCK_CALLS" ]
  [ ! -s "$MOCK_RUSTUP_LOG" ]
  [ "$(output_value tests_outcome)" = failed ]
}

@test "summary 'false' holds for a refused Windows runner" {
  export RUNNER_OS=Windows INPUT_SUMMARY=false
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"Windows runners are not supported"* ]]
  [ ! -s "$GITHUB_STEP_SUMMARY" ]
}

@test "the runner guard refuses only Windows" {
  local os
  for os in Linux macOS; do
    setup
    export RUNNER_OS="$os"
    run_action
    [ "$status" -eq 0 ]
  done
}

@test "rejects non-boolean values for every boolean input" {
  local input value
  for input in WORKSPACE ALL_FEATURES NO_DEFAULT_FEATURES LOCKFILE_REQUIRED \
    PERMIT_FAIL SUMMARY DOC_TESTS COVERAGE ARTEFACT_UPLOAD; do
    # An empty input takes the default, so a blank one stands in for it.
    for value in TRUE yes 1 ' '; do
      setup
      export "INPUT_$input=$value"
      run_action
      [ "$status" -eq 1 ]
      local name
      name="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
      [[ "$output" == *"$name must be 'true' or 'false'"* ]]
      [ ! -s "$MOCK_CALLS" ]
    done
  done
}

@test "rejects an invalid junit value" {
  export INPUT_TEST_RUNNER=nextest INPUT_JUNIT=yes
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"junit must be 'true', 'false' or empty"* ]]
}

@test "rejects invalid tool versions" {
  local input value
  for input in NEXTEST_VERSION LLVM_COV_VERSION; do
    for value in latest 0.9 '0.9.1,cargo-audit' 'v0.9.1' '0.9.1 '; do
      setup
      export "INPUT_$input=$value"
      run_action
      [ "$status" -eq 1 ]
      [[ "$output" == *"must be a release version such as 1.2.3"* ]]
    done
  done
}

@test "rejects an invalid toolchain without echoing it" {
  local value
  for value in $'stable\n::error::forged' 'stable toolchain' '../x' 'a;b'; do
    setup
    export INPUT_TOOLCHAIN="$value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"toolchain may contain only"* ]]
    [[ "$output" != *"forged"* ]]
  done
}

@test "rejects an invalid artefact_name" {
  local value
  for value in 'a/b' 'a b' '-lead' '.hidden' "$(printf 'x%.0s' {1..101})"; do
    setup
    export INPUT_ARTEFACT_NAME="$value"
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"artefact_name may contain only"* ]]
  done
}

@test "rejects control characters in paths" {
  export INPUT_PATH_PREFIX=$'my crate\n::error::forged'
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"path_prefix must not contain control characters"* ]]
  [[ "$output" != *"forged"* ]]

  export INPUT_PATH_PREFIX="my crate" INPUT_MANIFEST_PATH=$'x\n/Cargo.toml'
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest_path must not contain control characters"* ]]
}

### Artefact ###

@test "artefact_upload 'false' leaves the upload outputs unset" {
  export INPUT_TEST_RUNNER=nextest INPUT_ARTEFACT_UPLOAD=false
  run_action

  [ "$status" -eq 0 ]
  run ! grep -q '^report_dir=' "$GITHUB_OUTPUT"
  run ! grep -q '^artefact_name=' "$GITHUB_OUTPUT"
  [ -n "$(output_value junit_path)" ]
  summary | grep -qF '| Artefact | ➖ Disabled |'
}

@test "artefact_name names the upload" {
  export INPUT_TEST_RUNNER=nextest INPUT_ARTEFACT_NAME=tests-linux-1.85
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value artefact_name)" = tests-linux-1.85 ]
  summary | grep -qF '| Artefact | 📦 <code>tests-linux-1.85</code> |'
}

@test "artefact_path keeps the reports in place below path_prefix" {
  export INPUT_TEST_RUNNER=nextest INPUT_COVERAGE=true
  export INPUT_ARTEFACT_PATH="test reports/run 1/"
  run_action

  [ "$status" -eq 0 ]
  local dir="$project/test reports/run 1"
  [ "$(output_value artefact_path)" = "$dir" ]
  [ "$(output_value report_dir)" = "$dir" ]
  [ "$(output_value junit_path)" = "$dir/junit.xml" ]
  [ "$(output_value coverage_lcov_path)" = "$dir/lcov.info" ]
  [ "$(output_value coverage_cobertura_path)" = "$dir/cobertura.xml" ]
  [ -s "$dir/junit.xml" ] && [ -s "$dir/lcov.info" ] && [ -s "$dir/cobertura.xml" ]
  [ -z "$(reports_dir)" ]
}

@test "artefact_path may name an existing empty directory" {
  mkdir -p "$project/reports"
  export INPUT_TEST_RUNNER=nextest INPUT_ARTEFACT_PATH=reports
  run_action

  [ "$status" -eq 0 ]
  [ "$(output_value artefact_path)" = "$project/reports" ]
  [ -s "$project/reports/junit.xml" ]
}

@test "artefact_path names the reports of failing tests for upload" {
  local permit
  for permit in false true; do
    setup
    rm -rf "$project/reports"
    export INPUT_TEST_RUNNER=nextest INPUT_COVERAGE=true MOCK_TEST_EXIT=100
    export INPUT_ARTEFACT_PATH=reports INPUT_PERMIT_FAIL="$permit"
    run_action

    if [ "$permit" = true ]; then
      [ "$status" -eq 0 ]
    else
      [ "$status" -eq 1 ]
    fi
    [ "$(output_value tests_outcome)" = failed ]
    [ "$(output_value report_dir)" = "$project/reports" ]
    [ "$(output_value artefact_name)" = rust-test-results ]
    [ -s "$project/reports/junit.xml" ]
    [ -s "$project/reports/lcov.info" ]
  done
}

@test "rejects an unsafe artefact_path before running anything" {
  local case value message
  for case in absolute control full file symlink dotdot outside \
    outside-link; do
    setup
    mkdir -p "$workdir/elsewhere" "$project/full"
    : > "$project/full/old.xml"
    : > "$project/plain-file"
    ln -sfn "$workdir/elsewhere" "$project/link"
    ln -sfn "$BATS_TEST_TMPDIR" "$project/out"
    case "$case" in
      absolute) value=/tmp/reports message="must be a path relative to path_prefix" ;;
      control) value=$'a\nb' message="must not contain control characters" ;;
      full) value=full message="must be empty or absent" ;;
      file) value=plain-file message="must name a directory" ;;
      symlink) value=link/ message="must not be a symlink" ;;
      dotdot) value=new/../x message="may not use '.', '..' or '//'" ;;
      outside) value=../../rust-test-outside message="must resolve inside the workspace" ;;
      outside-link) value=out/reports message="must resolve inside the workspace" ;;
    esac
    export INPUT_ARTEFACT_PATH="$value"
    run_prepare
    [ "$status" -eq 1 ]
    [[ "$output" == *"artefact_path $message"* ]]
    run_action
    [ "$status" -eq 1 ]
    [[ "$output" == *"artefact_path $message"* ]]
    [ ! -s "$MOCK_CALLS" ]
    [ ! -e "$BATS_TEST_TMPDIR/rust-test-outside" ]
    [ ! -e "$BATS_TEST_TMPDIR/reports" ]
    [ -z "$(ls -A "$workdir/elsewhere")" ]
    [ "$(output_value artefact_path)" = "" ]
  done
}

# The JUnit path goes into a TOML literal string.
@test "rejects a report directory path holding a single quote" {
  export INPUT_ARTEFACT_PATH="it's"
  run_prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"artefact_path resolves to a path holding characters this action cannot quote"* ]]

  setup
  mkdir -p "$workdir/runner's temp"
  export RUNNER_TEMP="$workdir/runner's temp"
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"RUNNER_TEMP resolves to a path holding characters this action cannot quote"* ]]
  [ -z "$(stage_calls test)" ]
}

# upload-artifact reads its path as a glob pattern.
@test "rejects glob characters in the report directory only for uploads" {
  export INPUT_ARTEFACT_PATH='reports[1]'
  run_action
  [ "$status" -eq 1 ]
  [[ "$output" == *"must not hold * ? [ ] or a backslash"* ]]
  [ ! -s "$MOCK_CALLS" ]

  setup
  export INPUT_ARTEFACT_PATH='reports[1]' INPUT_ARTEFACT_UPLOAD=false
  run_action
  [ "$status" -eq 0 ]
  [ "$(output_value artefact_path)" = "$project/reports[1]" ]
}

# The checks in check_inputs ran before mkdir; what mkdir leaves behind
# is checked again. A mkdir stand-in fakes a change in between.
@test "artefact_path is checked again after mkdir" {
  local plant message
  for plant in ': > "$1/planted"' \
    'rmdir "$1" && ln -s "$GITHUB_WORKSPACE/elsewhere" "$1"'; do
    setup
    rm -rf "$project/reports"
    mkdir -p "$workdir/elsewhere"
    printf '%s\n' '#!/bin/bash' 'for last; do :; done' '/bin/mkdir "$@" || exit' \
      'case "$last" in' "  */reports) set -- \"\$last\"; $plant ;;" 'esac' \
      > "$workdir/bin/mkdir"
    chmod +x "$workdir/bin/mkdir"
    export INPUT_ARTEFACT_PATH=reports
    run_action

    case "$plant" in
      *planted*) message="artefact_path must be empty or absent" ;;
      *) message="artefact_path must resolve inside the workspace, without symlinks" ;;
    esac
    [ "$status" -eq 1 ]
    [[ "$output" == *"$message"* ]]
    [ -z "$(stage_calls test)" ]
    summary | grep -qx '### ❌ Failed at Prepare reports'
    [ "$(output_value artefact_path)" = "" ]
  done
}

@test "a setup script cannot fill artefact_path before the tests" {
  printf '%s\n' 'mkdir -p reports && : > reports/forged.xml' > "$project/setup.sh"
  export INPUT_SETUP_SCRIPT=setup.sh INPUT_ARTEFACT_PATH=reports
  run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"artefact_path must be empty or absent"* ]]
  [ -z "$(stage_calls test)" ]
  [ "$(output_value artefact_path)" = "" ]
  [ "$(output_value report_dir)" = "" ]
}

@test "an early stop creates no report directory" {
  local where
  for where in "" reports; do
    setup
    printf '%s\n' 'exit 3' > "$project/setup.sh"
    export INPUT_SETUP_SCRIPT=setup.sh INPUT_ARTEFACT_PATH="$where"
    run_action

    [ "$status" -eq 1 ]
    summary | grep -qx '### ❌ Failed at Run setup script'
    [ -z "$(reports_dir)" ]
    [ ! -e "$project/reports" ]
    [ "$(output_value artefact_path)" = "" ]
  done
}

# Project code can reach the reports directory through RUNNER_TEMP; the
# test run's hook stands in for it here.
@test "refuses to upload a reports directory holding anything but files" {
  local plant
  for plant in \
    'ln -s /etc/hosts "$d/stolen"' \
    'ln -s /etc/hosts "$d/.stolen"' \
    'mkdir "$d/nested"' \
    'mv "$d" "$d.real" && ln -s "$d.real" "$d"'; do
    setup
    export MOCK_TEST_HOOK="for d in \"\$RUNNER_TEMP\"/rust-test-reports.*; do $plant; done"
    export INPUT_TEST_RUNNER=nextest INPUT_COVERAGE=true
    run_action

    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::The reports directory holds something other than regular files"* ]]
    [ "$(output_value report_dir)" = "" ]
    [ "$(output_value artefact_path)" = "" ]
    [ "$(output_value junit_path)" = "" ]
    [ "$(output_value coverage_lcov_path)" = "" ]
    [ "$(output_value coverage_cobertura_path)" = "" ]
    [ "$(output_value tests_outcome)" = failed ]
    summary | grep -qF 'Failed at Check reports'
  done
}

@test "a tampered reports directory does not hide an earlier failure" {
  export MOCK_TEST_HOOK='for d in "$RUNNER_TEMP"/rust-test-reports.*; do ln -s /etc/hosts "$d/stolen"; done'
  export INPUT_TEST_RUNNER=nextest MOCK_TEST_EXIT=101
  run_action

  [ "$status" -eq 1 ]
  [ "$(output_value report_dir)" = "" ]
  summary | grep -qF 'Failed at Run tests'
}

# A setup script can put programs on PATH, for example in Cargo's bin
# directory, ahead of the system tools. The checks that run after it
# must not trust them.
write_silent_tools() {
  printf '%s\n' "for t in $*; do" \
    '  printf "#!/bin/bash\nexit 0\n" > "$PLANTED/bin/$t"' \
    '  chmod +x "$PLANTED/bin/$t"' 'done' > "$project/setup.sh"
  export INPUT_SETUP_SCRIPT=setup.sh PLANTED="$workdir"
}

@test "a planted find cannot hide a symlink from the upload check" {
  write_silent_tools find
  export MOCK_TEST_HOOK='for d in "$RUNNER_TEMP"/rust-test-reports.*; do ln -s /etc/hosts "$d/stolen"; done'
  export INPUT_TEST_RUNNER=nextest
  run_action
  export PATH=/usr/bin:/bin

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::The reports directory holds something other than regular files"* ]]
  [ "$(output_value report_dir)" = "" ]
  [ "$(output_value artefact_path)" = "" ]
  summary | grep -qF 'Failed at Check reports'
}

@test "a planted ls cannot hide a filled artefact_path" {
  write_silent_tools ls
  printf '%s\n' 'mkdir -p reports && : > reports/.forged.xml' >> "$project/setup.sh"
  export INPUT_ARTEFACT_PATH=reports
  run_action
  export PATH=/usr/bin:/bin

  [ "$status" -eq 1 ]
  [[ "$output" == *"artefact_path must be empty or absent"* ]]
  [ -z "$(stage_calls test)" ]
  [ "$(output_value report_dir)" = "" ]
}

@test "a planted mktemp cannot choose the reports directory" {
  printf '%s\n' 'printf "#!/bin/bash\nmkdir -p \"%s\"\necho \"%s\"\n" "$PLANTED/chosen" "$PLANTED/chosen" > "$PLANTED/bin/mktemp"' \
    'chmod +x "$PLANTED/bin/mktemp"' > "$project/setup.sh"
  export INPUT_SETUP_SCRIPT=setup.sh PLANTED="$workdir"
  export INPUT_TEST_RUNNER=nextest
  run_action
  export PATH=/usr/bin:/bin

  [ "$status" -eq 0 ]
  [ ! -e "$workdir/chosen" ]
  [ "$(output_value report_dir)" = "$(reports_dir)" ]
  [ -s "$(reports_dir)/junit.xml" ]
}

# A directory that cannot be listed might hide anything.
@test "refuses to upload a reports directory it cannot list" {
  [ "$(id -u)" -ne 0 ] || skip "root can list any directory"
  export MOCK_TEST_HOOK='for d in "$RUNNER_TEMP"/rust-test-reports.*; do chmod 300 "$d"; done'
  export INPUT_TEST_RUNNER=nextest
  run_action
  chmod 700 "$RUNNER_TEMP"/rust-test-reports.*

  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::The reports directory holds something other than regular files"* ]]
  [ "$(output_value report_dir)" = "" ]
  summary | grep -qF 'Failed at Check reports'
}

### Outputs ###

@test "set_output refuses multi-line values" {
  run "$BASH" -c 'source "$1"; set_output name "$(printf "a\nb=c")"' \
    _ "$repo_dir/scripts/common.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing to write a multi-line value to output name"* ]]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "writes each output once, as a single name=value line" {
  export INPUT_TEST_RUNNER=nextest INPUT_COVERAGE=true
  run_action

  [ "$status" -eq 0 ]
  [ "$(cut -d= -f1 "$GITHUB_OUTPUT" | sort | uniq -d)" = "" ]
  run ! grep -qv '^[a-z_]*=' "$GITHUB_OUTPUT"
}

@test "format_size renders readable sizes" {
  run "$BASH" -c 'source "$1"; format_size 0; echo; format_size 1023; echo
    format_size 1536; echo; format_size 10485760' _ "$repo_dir/scripts/common.sh"

  [ "$output" = "$(printf '%s\n' '0 B' '1023 B' '1.5 KiB' '10.0 MiB')" ]
}

### prepare.sh ###

@test "prepare names the tools to install" {
  local runner cov expected
  while read -r runner cov expected; do
    setup
    export INPUT_TEST_RUNNER="$runner" INPUT_COVERAGE="$cov"
    export INPUT_NEXTEST_VERSION=0.9.140 INPUT_LLVM_COV_VERSION=0.8.7
    run_prepare
    [ "$status" -eq 0 ]
    [ "$(cat "$GITHUB_OUTPUT")" = "tools=${expected#-}" ]
  done <<'EOF'
cargo false -
cargo true cargo-llvm-cov@0.8.7
nextest false cargo-nextest@0.9.140
nextest true cargo-nextest@0.9.140,cargo-llvm-cov@0.8.7
EOF
}

@test "prepare installs nothing and runs no cargo command" {
  export INPUT_TEST_RUNNER=nextest INPUT_COVERAGE=true
  run_prepare

  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_CALLS" ]
  [ ! -s "$GITHUB_STEP_SUMMARY" ]
}

@test "prepare fails on invalid inputs with a summary" {
  export INPUT_NEXTEST_VERSION='0.9.146,evil-tool'
  run_prepare

  [ "$status" -eq 1 ]
  [ ! -s "$GITHUB_OUTPUT" ]
  [[ "$output" == *"nextest_version must be a release version"* ]]
  summary | grep -qx '### ❌ Failed at Check inputs'
}

### action.yaml ###

@test "action.yaml hands every input to both scripts through env" {
  local action="$repo_dir/action.yaml" name upper
  local -a names
  mapfile -t names < <(awk '
    /^inputs:/ { on = 1; next }
    /^[a-z]/ { on = 0 }
    on && /^  [a-z_]+:$/ { sub(/:$/, ""); sub(/^  /, ""); print }
  ' "$action")
  [ "${#names[@]}" -eq 25 ]
  for name in "${names[@]}"; do
    upper="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
    [ "$(grep -cF "INPUT_$upper: \${{ inputs.$name }}" "$action")" -eq 2 ]
  done
  # No input reaches a run: block directly.
  run ! grep -E '^ +run:.*\$\{\{' "$action"
}

@test "action.yaml defaults match the scripts" {
  local action="$repo_dir/action.yaml"
  default_of() {
    awk -v name="  $1:" '
      $0 == name { on = 1; next }
      on && /^    default:/ { gsub(/.*default: "|"$/, ""); print; exit }
    ' "$action"
  }
  # shellcheck source=../scripts/common.sh
  source "$repo_dir/scripts/common.sh"
  [ "$(default_of nextest_version)" = "$default_nextest_version" ]
  [ "$(default_of llvm_cov_version)" = "$default_llvm_cov_version" ]
  [ "$(default_of test_runner)" = cargo ]
  [ "$(default_of doc_tests)" = true ]
  [ "$(default_of artefact_upload)" = true ]
  [ "$(default_of junit)" = "" ]
  [ "$(default_of artefact_name)" = "$default_artefact_name" ]
  [ "$(default_of artefact_path)" = "" ]
}

# Failing tests, permitted or not, keep their reports as evidence.
@test "action.yaml uploads the reports even after a failed test step" {
  local action="$repo_dir/action.yaml" step
  step="$(awk '/- name: "Upload test reports"/ { on = 1 } on' "$action")"
  [[ "$step" == *"if: \${{ !cancelled() && steps.test.outputs.report_dir != '' }}"* ]]
  [[ "$step" == *"path: \${{ steps.test.outputs.report_dir }}"* ]]
  [[ "$step" == *"if-no-files-found: warn"* ]]
  grep -qF "value: \${{ steps.upload.outputs.artifact-id != '' && steps.test.outputs.artefact_name || '' }}" "$action"
  grep -qF 'value: ${{ steps.test.outputs.artefact_path }}' "$action"
}
