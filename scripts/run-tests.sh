#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Run a Rust project's tests with cargo test or cargo-nextest,
# optionally under cargo-llvm-cov, and collect JUnit XML and coverage
# reports for upload.
#
# Inputs arrive as INPUT_* environment variables (see action.yaml).
# Stages run in order:
#
#   Check inputs -> Check toolchain -> Install toolchain
#   -> Run setup script -> Check lockfile -> Prepare coverage -> Prepare reports -> Run tests
#   -> Run doc tests -> Write coverage reports -> Collect JUnit report
#
# A failing test or doc test run does not stop the later stages, so the
# reports describe the failure. With permit_fail it then reports
# success with a warning; any other failure always fails the step.

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

readonly nextest_profile="rust-test-action"
readonly version_pattern='^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$'

toolchain=""
toolchain_kind=""
toolchain_pin=""
cargo_version=""
rustc_version=""
tool_versions=""
work_dir=""
reports_dir=""
tests_failed="false"
# Only the main run feeds the coverage and JUnit reports.
main_tests_failed="false"
failed_stage=""
coverage_percent=""
junit_path=""
lcov_path=""
cobertura_path=""
lockfile_cell="⏸️ Not reached"
# Set only when toolchain_components or toolchain_targets name any.
install_cell=""
setup_cell="⏸️ Not reached"
tests_cell="⏸️ Not reached"
doc_cell="⏸️ Not reached"
coverage_cell="➖ Not requested"
junit_cell="➖ Not requested"

### Exit handling ###

# The checks from here on run after project code, which can plant
# programs on PATH (in Cargo's bin directory, say) that report whatever
# suits it. They use bash builtins alone.

# Succeeds when directory $1 holds any entry, hidden ones included.
dir_has_entries() (
  shopt -s nullglob dotglob
  entries=("$1"/*)
  [ "${#entries[@]}" -gt 0 ]
)

# Directory holding the reports when it holds any, for the upload step.
reports_with_files() {
  if [ -n "$reports_dir" ] && [ -d "$reports_dir" ] \
    && dir_has_entries "$reports_dir"; then
    printf '%s' "$reports_dir"
  fi
}

# Project code runs as the runner user and can reach the reports
# directory. A symlink planted there would make the uploader, which
# holds ACTIONS_RUNTIME_TOKEN, read files from outside it, so only a
# real directory of regular files qualifies for upload. A directory
# this cannot list fails, since its entries would go unchecked.
reports_are_plain() (
  shopt -s nullglob dotglob
  [[ ! -L "$reports_dir" && -d "$reports_dir" && -r "$reports_dir" \
    && -x "$reports_dir" ]] || exit 1
  for entry in "$reports_dir"/*; do
    [[ -f "$entry" && ! -L "$entry" ]] || exit 1
  done
)

render_summary() {
  local status="$1" outcome runner_cell artefact_cell report_dir="$2"
  if [ "$summary_enabled" != "true" ]; then
    return 0
  fi
  if [ "$status" -ne 0 ]; then
    outcome="❌ Failed at $(md_text "$stage")"
  elif [ "$tests_failed" = "true" ]; then
    outcome="⚠️ Tests failed (permitted)"
  else
    outcome="✅ Tests passed"
  fi

  if [ "${test_runner:-}" = "nextest" ]; then
    runner_cell="$(md_code "cargo nextest run")"
  else
    runner_cell="$(md_code "cargo test")"
  fi
  if [ -n "$tool_versions" ]; then
    runner_cell="$runner_cell ($(md_text "$tool_versions"))"
  fi
  add_row "Runner" "$runner_cell"
  if [ -n "${manifest_display:-}" ]; then
    add_row "Manifest" "$(md_code "$manifest_display")"
  fi
  case "$toolchain_kind" in
    channel)
      add_row "Toolchain" "$(md_code "$toolchain") (cargo $(md_text \
        "${cargo_version:-unknown}"), rustc $(md_text "${rustc_version:-unknown}"))"
      ;;
    path)
      add_row "Toolchain" "⚠️ Path toolchain $(md_code "$toolchain")"
      ;;
    none)
      add_row "Toolchain" "No rustup: cargo $(md_text "${cargo_version:-unknown}")"
      ;;
  esac
  if [ -n "$install_cell" ]; then
    add_row "Components and targets" "$install_cell"
  fi
  if [ -n "${setup_abs:-}" ]; then
    add_row "Setup script" "$setup_cell"
  fi
  add_row "Lockfile" "$lockfile_cell"
  add_row "Tests" "$tests_cell"
  add_row "Doc tests" "$doc_cell"
  add_row "Coverage" "$coverage_cell"
  add_row "JUnit XML" "$junit_cell"
  if [ "${artefact_upload:-false}" != "true" ]; then
    artefact_cell="➖ Disabled"
  elif [ -n "$report_dir" ]; then
    artefact_cell="📦 $(md_code "$artefact_name")"
  else
    artefact_cell="➖ No reports to upload"
  fi
  add_row "Artefact" "$artefact_cell"
  write_summary "$outcome"
}

finish() {
  local status=$? outcome="passed" report_dir
  trap - EXIT
  report_dir="$(reports_with_files)"
  if [ -n "$reports_dir" ] && [ ! -e "$reports_dir" ] && [ ! -L "$reports_dir" ]; then
    reports_dir=""
  elif [ -n "$reports_dir" ] && ! reports_are_plain; then
    reports_dir="" report_dir="" junit_path="" lcov_path="" cobertura_path=""
    echo "::error::The reports directory holds something other than" \
      "regular files; the action will not upload or name the reports."
    if [ "$status" -eq 0 ]; then
      stage="Check reports"
      failure_reason="The reports directory holds something other than regular files."
      status=1
    fi
  fi
  if [ "$status" -ne 0 ] || [ "$tests_failed" = "true" ]; then
    outcome="failed"
  fi
  if [ "$status" -ne 0 ] && [ -z "$failure_reason" ]; then
    failure_reason="$stage failed with exit status $status; see the step log."
  fi
  if [ "$status" -eq 0 ] && [ "$tests_failed" = "true" ]; then
    warn "$failed_stage failed; permit_fail is 'true', so the step" \
      "reports success."
  fi
  # Every value below is ours or validated, but set_output still checks.
  set_output tests_outcome "$outcome" || status=1
  set_output coverage_percent "$coverage_percent" || status=1
  set_output junit_path "$junit_path" || status=1
  set_output coverage_lcov_path "$lcov_path" || status=1
  set_output coverage_cobertura_path "$cobertura_path" || status=1
  set_output artefact_path "$reports_dir" || status=1
  if [ "${artefact_upload:-false}" = "true" ]; then
    set_output report_dir "$report_dir" || status=1
    set_output artefact_name "$artefact_name" || status=1
  fi
  render_summary "$status" "$report_dir"
  if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
    rm -rf -- "$work_dir"
  fi
  exit "$status"
}
trap finish EXIT

### Running commands ###

# Run a command in the project directory, pinned to the resolved
# toolchain.
in_project() {
  (
    cd -- "$project_dir"
    if [ -n "$toolchain_pin" ]; then
      export RUSTUP_TOOLCHAIN="$toolchain_pin"
    fi
    exec "$@"
  )
}

# Run a cargo command in a log group, keeping a copy of its output in
# $work_dir/run.log. Sets run_status rather than failing.
run_logged() {
  local title="$1"
  shift
  echo "::group::$title"
  echo "Running: $*"
  run_status=0
  in_project "$@" 2>&1 | tee "$work_dir/run.log" || run_status=$?
  echo "::endgroup::"
}

# Print the arguments joined by commas, as rustup lists take them.
join_commas() {
  local IFS=,
  printf '%s' "$*"
}

# Set variable $2 to the version in the 'TOOL X.Y.Z (...)' line that
# 'TOOL --version' prints for tool $1. Fails when the command fails or
# the version is not a Rust release number.
read_version() {
  local tool="$1" line word
  if ! line="$(in_project "$tool" --version)"; then
    fail "$tool --version failed for the selected toolchain"
  fi
  line="${line%%$'\n'*}"
  word="${line#"$tool" }"
  word="${word%% *}"
  if [[ ! "$word" =~ $version_pattern ]]; then
    fail "$tool --version reported an unexpected version"
  fi
  printf -v "$2" '%s' "$word"
}

# The first word after the program name in a cargo plug-in's
# '--version' line, for the job summary only, when it looks like a
# version; otherwise 'unknown'.
version_word() {
  local line="${1%%$'\n'*}" word
  word="${line#* }"
  word="${word%% *}"
  if [[ "$word" =~ ^[0-9][0-9A-Za-z.+-]*$ ]]; then
    printf '%s' "$word"
  else
    printf 'unknown'
  fi
}

# Line coverage from an lcov report: lines hit over lines found, summed
# over every source file, to two decimal places. Prints nothing when
# the report records no lines, and 'invalid' for a count that is not a
# whole number or more lines hit than found.
lcov_line_percent() {
  LC_ALL=C awk -F: '
    $1 == "LF" || $1 == "LH" {
      if ($2 !~ /^[0-9]+$/) { bad = 1 }
      if ($1 == "LF") { found += $2 } else { hit += $2 }
    }
    END {
      if (bad || hit > found) { printf "invalid" }
      else if (found > 0) { printf "%.2f", hit * 100 / found }
    }
  ' "$1"
}

check_inputs

# With the inputs known, a requested check that an early failure stops
# short of reads as not reached, and a disabled one as such.
if [ "$doc_tests" = "false" ]; then
  doc_cell="➖ Disabled"
fi
if [ "$coverage" = "true" ]; then
  coverage_cell="⏸️ Not reached"
fi
if [ "$junit" = "true" ]; then
  junit_cell="⏸️ Not reached"
fi

# mktemp makes the reports directory after project code has run, so it
# is looked up now, before any.
mktemp_bin="$(type -P mktemp)" || true
if [[ "$mktemp_bin" != /* ]]; then
  fail "mktemp must come from an absolute PATH entry"
fi

stage="Prepare workspace"
temp_base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
if ! work_dir="$("$mktemp_bin" -d "$temp_base/rust-test-action.XXXXXX")"; then
  work_dir=""
  fail "could not create a temporary directory"
fi

### Check toolchain ###

# rustup names the toolchain the project selects without running it.
# A channel is pinned for every later command; a path toolchain, from a
# rust-toolchain file naming a directory, runs unpinned.
stage="Check toolchain"
if [ -n "$toolchain_input" ]; then
  if ! command -v rustup > /dev/null 2>&1; then
    fail "toolchain needs rustup, which is not on PATH"
  fi
  toolchain="$toolchain_input"
  toolchain_kind="channel"
  toolchain_pin="$toolchain"
elif command -v rustup > /dev/null 2>&1; then
  if ! toolchain="$(cd -- "$project_dir" \
    && rustup show active-toolchain 2> /dev/null)"; then
    toolchain=""
    fail "rustup could not name the toolchain for path_prefix; set the" \
      "toolchain input or install the one the project selects"
  fi
  toolchain="${toolchain%%$'\n'*}"
  # rustup appends why it chose the toolchain, in parentheses. A path
  # toolchain, and the file path in the reason, may hold ' (' as well,
  # so match the reasons rustup gives; otherwise drop the last ' ('.
  reason_re='^(.+) \((default|(overridden by|environment override by|directory override for) .+)\)$'
  if [[ "$toolchain" =~ $reason_re ]]; then
    toolchain="${BASH_REMATCH[1]}"
  else
    toolchain="${toolchain% (*}"
  fi
  case "$toolchain" in
    /*)
      if [[ "$toolchain" =~ [[:cntrl:]] ]]; then
        toolchain=""
        fail "rustup reported an unexpected toolchain path for path_prefix"
      fi
      toolchain_kind="path"
      warn "The project selects the path toolchain $toolchain; it runs" \
        "unpinned, from the project directory."
      ;;
    *)
      if [[ ! "$toolchain" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        toolchain=""
        fail "rustup reported an unexpected toolchain name for path_prefix"
      fi
      toolchain_kind="channel"
      toolchain_pin="$toolchain"
      ;;
  esac
else
  toolchain_kind="none"
fi
set_output toolchain "$toolchain"
set_output toolchain_kind "$toolchain_kind"

### Install toolchain ###

# A toolchain input makes rustup ignore rust-toolchain.toml, and with
# it the components and targets that file lists; the caller passes
# those through toolchain_components and toolchain_targets. One 'rustup
# toolchain install' installs a missing toolchain with the minimal
# profile, or adds them to the installed one, keeping an exact version
# such as 1.90.0 as it is (a moving channel such as stable updates).
# A channel named by the toolchain input alone is installed only when
# missing, rather than left to rustup's auto-install, which installs
# the default profile and which RUSTUP_AUTO_INSTALL=0 turns off. The
# probe leaves an installed channel as it is, and keeps a toolchain
# from 'rustup toolchain link', which install rejects, working. The
# same rules as rust-build-action.
stage="Install toolchain"
extras=()
if [ "${#component_list[@]}" -gt 0 ]; then
  extras+=("components $(md_code "${component_list[*]}")")
fi
if [ "${#target_list[@]}" -gt 0 ]; then
  extras+=("targets $(md_code "${target_list[*]}")")
fi
if [ "${#extras[@]}" -gt 0 ]; then
  install_cell="⏸️ Not reached"
fi
case "$toolchain_kind" in
  channel)
    install="${#extras[@]}"
    if [ "$install" -eq 0 ] && [ -n "$toolchain_input" ] \
      && ! in_project env RUSTUP_AUTO_INSTALL=0 \
        rustup which --toolchain "$toolchain_pin" rustc > /dev/null 2>&1; then
      install=1
    fi
    if [ "$install" -gt 0 ]; then
      install_args=(toolchain install "$toolchain_pin" --profile minimal
        --no-self-update)
      if [ "${#component_list[@]}" -gt 0 ]; then
        install_args+=(--component "$(join_commas "${component_list[@]}")")
      fi
      if [ "${#target_list[@]}" -gt 0 ]; then
        install_args+=(--target "$(join_commas "${target_list[@]}")")
      fi
      echo "::group::Install toolchain $toolchain_pin"
      echo "Running: rustup ${install_args[*]}"
      install_status=0
      in_project rustup "${install_args[@]}" || install_status=$?
      echo "::endgroup::"
      if [ "$install_status" -ne 0 ]; then
        if [ "${#extras[@]}" -eq 0 ]; then
          fail "rustup could not install toolchain $toolchain_pin"
        fi
        install_cell="❌ rustup could not install them"
        fail "rustup could not install toolchain $toolchain_pin with the" \
          "requested toolchain_components and toolchain_targets"
      fi
      if [ "${#extras[@]}" -gt 0 ]; then
        install_cell="✅ ${extras[0]}${extras[1]+, ${extras[1]}}"
      fi
    fi
    ;;
  path)
    if [ "${#extras[@]}" -gt 0 ]; then
      install_cell="⚠️ Ignored for a path toolchain"
      warn "toolchain_components and toolchain_targets are ignored for a" \
        "path toolchain; install them into that toolchain instead"
    fi
    ;;
  none)
    if [ "${#extras[@]}" -gt 0 ]; then
      install_cell="❌ Needs rustup"
      fail "toolchain_components and toolchain_targets need rustup on PATH"
    fi
    ;;
esac

read_version cargo cargo_version
read_version rustc rustc_version
set_output cargo_version "$cargo_version"
set_output rustc_version "$rustc_version"
echo "Toolchain: ${toolchain:-cargo on PATH} (cargo $cargo_version, rustc $rustc_version)"

tool_list=()
if [ "$test_runner" = "nextest" ]; then
  if ! version_line="$(in_project cargo nextest --version 2> /dev/null)"; then
    fail "cargo-nextest is not installed for this toolchain"
  fi
  tool_list+=("nextest $(version_word "$version_line")")
fi
if [ "$coverage" = "true" ]; then
  if ! version_line="$(in_project cargo llvm-cov --version 2> /dev/null)"; then
    fail "cargo-llvm-cov is not installed for this toolchain"
  fi
  tool_list+=("llvm-cov $(version_word "$version_line")")
fi
for tool in ${tool_list[@]+"${tool_list[@]}"}; do
  tool_versions="${tool_versions:+$tool_versions, }$tool"
done

### Run setup script ###

stage="Run setup script"
if [ -n "$setup_abs" ]; then
  echo "::group::Setup script"
  setup_status=0
  in_project bash "$setup_abs" || setup_status=$?
  echo "::endgroup::"
  if [ "$setup_status" -ne 0 ]; then
    setup_cell="❌ $(md_code "$setup_script") exited with status $setup_status"
    fail "setup_script exited with status $setup_status"
  fi
  setup_cell="✅ $(md_code "$setup_script")"
fi

### Check lockfile ###

# Cargo.lock sits beside the workspace root manifest, which may be a
# parent of manifest_path.
stage="Check lockfile"
if ! root_manifest="$(in_project cargo locate-project --workspace \
  --message-format plain --manifest-path "$manifest_abs")"; then
  fail "cargo could not locate the workspace root for manifest_path"
fi
root_manifest="${root_manifest%%$'\n'*}"
case "$root_manifest" in
  /*/Cargo.toml) ;;
  *) fail "cargo reported an unexpected workspace root for manifest_path" ;;
esac
# A symlinked root manifest would let a file outside the workspace
# define it, as manifest_path is not allowed to.
if [ -L "$root_manifest" ]; then
  fail "the Cargo workspace root manifest must not be a symlink"
fi
if ! lock_dir="$(cd -- "${root_manifest%/Cargo.toml}" 2> /dev/null \
  && pwd -P)" || ! inside_workspace "$lock_dir"; then
  fail "the Cargo workspace root for manifest_path lies outside the workspace"
fi
lockfile="$lock_dir/Cargo.lock"
if [ -L "$lockfile" ]; then
  fail "Cargo.lock must not be a symlink"
elif [ -f "$lockfile" ]; then
  lockfile_cell="✅ Present"
elif [ "$lockfile_required" = "true" ]; then
  lockfile_cell="❌ Missing"
  fail "Cargo.lock is missing and lockfile_required is 'true'"
else
  if ! in_project cargo generate-lockfile --manifest-path "$manifest_abs"; then
    lockfile_cell="❌ Generation failed"
    fail "cargo generate-lockfile failed"
  fi
  lockfile_cell="⚠️ Generated"
  warn "Cargo.lock is missing, so cargo generate-lockfile created one" \
    "with the newest compatible dependencies; commit a Cargo.lock for" \
    "reproducible tests."
fi

### Prepare coverage ###

# cargo-llvm-cov needs the llvm-tools component. Only a rustup channel
# can receive it here; otherwise cargo-llvm-cov explains what is missing.
stage="Prepare coverage"
if [ "$coverage" = "true" ]; then
  if [ "$toolchain_kind" = "channel" ]; then
    if ! in_project rustup component add llvm-tools-preview \
      --toolchain "$toolchain_pin"; then
      fail "could not add the llvm-tools-preview component to $toolchain_pin"
    fi
  else
    warn "Coverage needs the llvm-tools component, which this action" \
      "adds only to rustup channels; install it with the toolchain."
  fi
  # Old profiling data would otherwise leak into this run's figures.
  if ! in_project cargo llvm-cov clean --workspace \
    --manifest-path "$manifest_abs"; then
    fail "cargo llvm-cov clean failed"
  fi
  # cargo llvm-cov report accepts neither --exclude nor the feature
  # flags, and without a selection it covers only the root package of
  # a workspace that has one. Name every package the tests run
  # instead, as cargo tree lists them for the same selection.
  if ! cover_tree="$(in_project cargo tree "${select_args[@]}" --depth 0 \
    --prefix none --format '{p}')"; then
    fail "cargo tree could not list the packages to cover"
  fi
  cover_args=()
  while IFS= read -r cover_line; do
    [ -n "$cover_line" ] || continue
    if [[ ! "${cover_line%% *}" =~ ^[A-Za-z0-9_-]+$ ]]; then
      fail "cargo tree listed a package name this action cannot pass on"
    fi
    cover_args+=(-p "${cover_line%% *}")
  done <<< "$cover_tree"
  if [ "${#cover_args[@]}" -eq 0 ]; then
    fail "cargo tree listed no packages to cover"
  fi
fi

### Prepare reports ###

# Reports outlive this step for the upload, so they sit apart from the
# scratch directory removed on exit: in artefact_path when set, or else
# in a fresh directory below RUNNER_TEMP. Created only now, so an early
# stop leaves none behind. artefact_path was checked before the setup
# script and the earlier steps ran, so the checks run again on what
# mkdir left.
stage="Prepare reports"
if [ -n "$artefact_dir" ]; then
  if ! mkdir -p -- "$artefact_dir" 2> /dev/null; then
    fail "could not create artefact_path"
  fi
  # A symlink anywhere on the way changes the canonical path.
  if [ "$(cd -- "$artefact_dir" 2> /dev/null && pwd -P)" != "$artefact_dir" ]; then
    fail "artefact_path must resolve inside the workspace, without symlinks"
  fi
  if dir_has_entries "$artefact_dir"; then
    fail "artefact_path must be empty or absent, so that the artefact" \
      "holds only this run's reports"
  fi
  reports_dir="$artefact_dir"
else
  if ! new_dir="$("$mktemp_bin" -d "$temp_base/rust-test-reports.XXXXXX")"; then
    fail "could not create a report directory"
  fi
  new_dir="$(cd -- "$new_dir" && pwd -P)"
  check_report_dir_path RUNNER_TEMP "$new_dir"
  reports_dir="$new_dir"
fi

### Run tests ###

stage="Run tests"
runner_args=()
if [ "$test_runner" = "nextest" ] && [ "$junit" = "true" ]; then
  # A tool config file adds a profile that writes JUnit XML straight
  # into the report directory. The repository's own nextest config
  # still applies, and outranks this file where both set a value.
  nextest_config="$work_dir/nextest.toml"
  printf '%s\n' "[profile.$nextest_profile.junit]" \
    "path = '$reports_dir/junit.xml'" > "$nextest_config"
  runner_args=(--profile "$nextest_profile"
    --tool-config-file "rust-test-action:$nextest_config")
fi

case "$test_runner:$coverage" in
  cargo:false)
    test_cmd=(cargo test "${select_args[@]}")
    # --tests runs every target that has tests, but not doc tests.
    if [ "$doc_tests" = "false" ]; then
      test_cmd+=(--tests)
    fi
    ;;
  cargo:true)
    test_cmd=(cargo llvm-cov test --no-report "${select_args[@]}")
    ;;
  nextest:false)
    test_cmd=(cargo nextest run "${select_args[@]}"
      ${runner_args[@]+"${runner_args[@]}"})
    ;;
  nextest:true)
    test_cmd=(cargo llvm-cov nextest --no-report "${select_args[@]}"
      ${runner_args[@]+"${runner_args[@]}"})
    ;;
esac
test_cmd+=(${test_arg_list[@]+"${test_arg_list[@]}"})

run_logged "Tests" "${test_cmd[@]}"
if [ "$run_status" -eq 0 ]; then
  tests_cell="✅ Passed"
else
  tests_cell="❌ Failed (exit status $run_status)"
  tests_failed="true"
  main_tests_failed="true"
  failed_stage="Run tests"
  echo "::error::$(annotation_text "Tests failed with exit status $run_status")"
fi

### Run doc tests ###

# cargo test runs doc tests itself. nextest cannot run them, and
# cargo-llvm-cov leaves them out on stable Rust, so those runs get a
# separate, uninstrumented cargo test --doc. test_args are runner
# arguments and do not apply to it.
stage="Run doc tests"
if [ "$doc_tests" = "false" ]; then
  doc_cell="➖ Disabled"
elif [ "$test_runner" = "cargo" ] && [ "$coverage" = "false" ]; then
  # Doc tests run last in the same cargo test, which stops at the first
  # failing test binary, so a failed run says nothing about them.
  if [ "$main_tests_failed" = "true" ]; then
    doc_cell="⚠️ Unknown: $(md_code "cargo test") failed"
  else
    doc_cell="✅ Run by $(md_code "cargo test")"
  fi
else
  run_logged "Doc tests" cargo test --doc "${select_args[@]}"
  if [ "$run_status" -eq 0 ]; then
    doc_cell="✅ Passed"
  elif grep -q '^error: no library targets found' "$work_dir/run.log"; then
    doc_cell="➖ No library targets"
    echo "No library targets selected, so there are no doc tests to run"
  else
    doc_cell="❌ Failed (exit status $run_status)"
    tests_failed="true"
    failed_stage="${failed_stage:-Run doc tests}"
    echo "::error::$(annotation_text "Doc tests failed with exit status $run_status")"
  fi
fi

### Write coverage reports ###

# Reports come from whatever profiling data the run left, so a failed
# test run still yields them when it got as far as running tests.
stage="Write coverage reports"
if [ "$coverage" = "true" ]; then
  coverage_cell="⏸️ No report"
  report_failed=""
  if ! in_project cargo llvm-cov report --lcov --output-path \
    "$reports_dir/lcov.info" --manifest-path "$manifest_abs" --locked \
    "${cover_args[@]}"; then
    report_failed="lcov"
  elif ! in_project cargo llvm-cov report --cobertura --output-path \
    "$reports_dir/cobertura.xml" --manifest-path "$manifest_abs" --locked \
    "${cover_args[@]}"; then
    report_failed="Cobertura"
  fi
  if [ -n "$report_failed" ]; then
    if [ "$main_tests_failed" = "true" ]; then
      warn "cargo llvm-cov could not write the $report_failed report after" \
        "the failed test run."
    else
      coverage_cell="❌ $report_failed report failed"
      fail "cargo llvm-cov could not write the $report_failed report"
    fi
  fi
  if [ -s "$reports_dir/lcov.info" ]; then
    lcov_path="$reports_dir/lcov.info"
    coverage_percent="$(lcov_line_percent "$lcov_path")"
    if [ -z "$coverage_percent" ]; then
      coverage_cell="⚠️ No instrumented lines"
      warn "The lcov report records no lines, so there is no coverage figure."
    elif [[ ! "$coverage_percent" =~ ^[0-9]{1,3}\.[0-9]{2}$ ]]; then
      coverage_percent=""
      fail "could not read the line coverage from the lcov report"
    else
      coverage_cell="📊 $coverage_percent% of lines"
    fi
  fi
  if [ -s "$reports_dir/cobertura.xml" ]; then
    cobertura_path="$reports_dir/cobertura.xml"
  fi
fi

### Collect JUnit report ###

stage="Collect JUnit report"
if [ "$junit" = "true" ]; then
  if [ -s "$reports_dir/junit.xml" ]; then
    junit_path="$reports_dir/junit.xml"
    junit_size="$(wc -c < "$junit_path")"
    junit_cell="📄 $(md_code junit.xml) ($(format_size "${junit_size//[[:space:]]/}"))"
  elif [ "$main_tests_failed" = "true" ]; then
    junit_cell="⚠️ Not written"
    warn "nextest failed and wrote no JUnit report; see the step log."
  else
    junit_cell="❌ Not written"
    fail "nextest wrote no JUnit report; check that .config/nextest.toml" \
      "does not redefine the $nextest_profile profile's junit.path"
  fi
fi

if [ "$tests_failed" = "true" ] && [ "$permit_fail" != "true" ]; then
  stage="$failed_stage"
  fail "$failed_stage failed; see the step log for the failing tests."
fi
echo "Rust tests complete ✅"
