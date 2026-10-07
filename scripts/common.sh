#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Shared by prepare.sh and run-tests.sh, which source this file: the
# environment scrub, input validation, guarded step outputs and the job
# summary.
#
# Error messages name the offending input and never echo its value: an
# unvalidated value could carry a newline and start a workflow command.

# The globals set here are read by the scripts that source this file.
# shellcheck disable=SC2034

# Keep these defaults in step with action.yaml; a test compares them.
readonly default_nextest_version="0.9.146"
readonly default_llvm_cov_version="0.9.1"
readonly default_artefact_name="rust-test-results"

stage="Check inputs"
failure_reason=""
summary_enabled="true"
summary_rows=()
summary_notes=()

### Environment ###

# Tests run project code, and none of it needs the default registry
# token, the variables that mint GitHub OIDC tokens, or the runner's
# artefact and cache token.
withheld_credentials=(CARGO_REGISTRY_TOKEN
  ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL
  ACTIONS_RUNTIME_TOKEN)
# Without the runner's command file paths, project code cannot set this
# step's outputs, or the environment, PATH and summary of later steps,
# through them; code that goes looking can still find the files, so
# this is defence in depth only.
withheld_command_files=(GITHUB_OUTPUT GITHUB_ENV GITHUB_PATH GITHUB_STATE
  GITHUB_STEP_SUMMARY)

# Remove the withheld variables, and every alternative registry token,
# CARGO_REGISTRIES_<NAME>_TOKEN, from the calling script's own
# environment; both scripts call this right after sourcing this file,
# before they run any program. No child inherits them: not cargo, its
# plugins, rustup or setup_script, and not a helper that project code
# replaced on PATH. Other CARGO_REGISTRIES_<NAME>_* settings stay. The
# command file paths stay as unexported shell variables for the
# scripts' own writes.
withhold_environment() {
  local name
  unset "${withheld_credentials[@]}"
  while IFS= read -r name; do
    if [[ "$name" =~ ^CARGO_REGISTRIES_.+_TOKEN$ ]]; then
      unset "$name"
    fi
  done < <(compgen -e)
  export -n "${withheld_command_files[@]}"
}

### Annotations and outputs ###

# Make text safe as the message of a workflow command.
annotation_text() {
  local text="$1"
  text=${text//'%'/'%25'}
  text=${text//$'\r'/'%0D'}
  text=${text//$'\n'/'%0A'}
  printf '%s' "$text"
}

fail() {
  failure_reason="$*"
  echo "::error::$(annotation_text "$*")"
  exit 1
}

warn() {
  summary_notes+=("$*")
  echo "::warning::$(annotation_text "$*")"
}

# Write one step output. A value spanning lines could forge further
# outputs, so it is refused; this returns 1 rather than exiting, so the
# exit trap can call it too.
set_output() {
  case "$2" in
    *$'\n'* | *$'\r'*)
      echo "::error::Refusing to write a multi-line value to output $1"
      return 1
      ;;
  esac
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

### Input validation ###

require_boolean() {
  case "$2" in
    true | false) ;;
    *) fail "$1 must be 'true' or 'false'" ;;
  esac
}

require_version() {
  if [[ ! "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "$1 must be a release version such as 1.2.3"
  fi
}

# Split $2 on whitespace into the global array 'words', checking each
# word against the pattern $3. $1 names the input and $4 lists the
# allowed characters, for the error message.
split_names() {
  local word
  words=()
  IFS=$' \t\n' read -r -d '' -a words <<< "$2" || true
  for word in ${words[@]+"${words[@]}"}; do
    if [[ ! "$word" =~ $3 ]]; then
      fail "$1 contains an invalid name; allowed characters: $4"
    fi
  done
}

require_relative_path() {
  case "$2" in
    *[[:cntrl:]]*) fail "$1 must not contain control characters" ;;
    /*) fail "$1 must be a path relative to path_prefix" ;;
  esac
}

# Succeed when the canonical directory $1 lies inside the workspace.
inside_workspace() {
  if [ "$1" = "$workspace_real" ]; then
    return 0
  fi
  case "$1/" in
    "${workspace_real%/}"/*) return 0 ;;
  esac
  return 1
}

# Check that file $2 is a regular, non-symlink file inside the
# workspace and set 'resolved_file' to its canonical path. $1 names the
# input for errors.
contained_file() {
  local file="$2" dir
  if [ ! -f "$file" ]; then
    fail "$1 does not name a file below path_prefix"
  fi
  # 'pwd -P' resolves the directory, not the file itself: a symlinked
  # file could still point anywhere.
  if [ -L "$file" ]; then
    fail "$1 must not be a symlink"
  fi
  if ! dir="$(cd -- "$(dirname -- "$file")" 2> /dev/null && pwd -P)"; then
    fail "$1 has a directory that cannot be entered"
  fi
  if ! inside_workspace "$dir"; then
    fail "$1 must resolve inside the workspace"
  fi
  resolved_file="$dir/${file##*/}"
}

# Read the INPUT_* environment, validate every value and resolve the
# paths. Sets the globals both scripts use and writes nothing to disk.
check_inputs() {
  summary_enabled="${INPUT_SUMMARY:-true}"
  require_boolean summary "$summary_enabled"
  # The path checks assume POSIX paths, which Windows runners do not
  # report; refuse them rather than reject every project confusingly.
  if [ "${RUNNER_OS:-}" = "Windows" ]; then
    fail "Windows runners are not supported; use a Linux runner"
  fi

  path_prefix="${INPUT_PATH_PREFIX:-.}"
  manifest_path="${INPUT_MANIFEST_PATH:-Cargo.toml}"
  workspace="${INPUT_WORKSPACE:-true}"
  all_features="${INPUT_ALL_FEATURES:-false}"
  no_default_features="${INPUT_NO_DEFAULT_FEATURES:-false}"
  toolchain_input="${INPUT_TOOLCHAIN:-}"
  lockfile_required="${INPUT_LOCKFILE_REQUIRED:-false}"
  setup_script="${INPUT_SETUP_SCRIPT:-}"
  permit_fail="${INPUT_PERMIT_FAIL:-false}"
  test_runner="${INPUT_TEST_RUNNER:-cargo}"
  nextest_version="${INPUT_NEXTEST_VERSION:-$default_nextest_version}"
  test_args="${INPUT_TEST_ARGS:-}"
  doc_tests="${INPUT_DOC_TESTS:-true}"
  coverage="${INPUT_COVERAGE:-false}"
  llvm_cov_version="${INPUT_LLVM_COV_VERSION:-$default_llvm_cov_version}"
  junit="${INPUT_JUNIT:-}"
  artefact_upload="${INPUT_ARTEFACT_UPLOAD:-true}"
  artefact_name="${INPUT_ARTEFACT_NAME:-$default_artefact_name}"
  artefact_path="${INPUT_ARTEFACT_PATH:-}"

  local name
  for name in permit_fail workspace all_features no_default_features \
    lockfile_required doc_tests coverage artefact_upload; do
    require_boolean "$name" "${!name}"
  done

  case "$test_runner" in
    cargo | nextest) ;;
    *) fail "test_runner must be 'cargo' or 'nextest'" ;;
  esac
  require_version nextest_version "$nextest_version"
  require_version llvm_cov_version "$llvm_cov_version"

  case "$junit" in
    "")
      junit="false"
      if [ "$test_runner" = "nextest" ]; then
        junit="true"
      fi
      ;;
    true)
      if [ "$test_runner" != "nextest" ]; then
        fail "junit 'true' needs test_runner 'nextest':" \
          "cargo test cannot write JUnit XML"
      fi
      ;;
    false) ;;
    *) fail "junit must be 'true', 'false' or empty" ;;
  esac

  if [ -n "$toolchain_input" ] \
    && [[ ! "$toolchain_input" =~ ^[A-Za-z0-9._+-]+$ ]]; then
    fail "toolchain may contain only: A-Z a-z 0-9 . _ + -"
  fi

  if [[ ! "$artefact_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]]; then
    fail "artefact_name may contain only: A-Z a-z 0-9 . _ -" \
      "(at most 100 characters, starting with a letter or digit)"
  fi

  local crate_pattern='^[A-Za-z0-9_-]+$'
  split_names packages "${INPUT_PACKAGES:-}" "$crate_pattern" \
    "A-Z a-z 0-9 _ -"
  package_list=(${words[@]+"${words[@]}"})
  split_names exclude "${INPUT_EXCLUDE:-}" "$crate_pattern" \
    "A-Z a-z 0-9 _ -"
  exclude_list=(${words[@]+"${words[@]}"})
  local features_input="${INPUT_FEATURES:-}"
  # A feature name, or <package>/<feature>, as Cargo accepts them; the
  # same pattern as rust-build-action.
  split_names features "${features_input//,/ }" \
    '^([A-Za-z0-9_][A-Za-z0-9_-]*/)?[A-Za-z0-9_][A-Za-z0-9_+.-]*$' \
    "A-Z a-z 0-9 _ - + . and one package/ prefix"
  feature_list=(${words[@]+"${words[@]}"})
  # Cargo runs every member when given --workspace and -p together, so
  # a package list replaces --workspace rather than joining it.
  if [ "${#exclude_list[@]}" -gt 0 ]; then
    if [ "${#package_list[@]}" -gt 0 ]; then
      fail "exclude cannot be combined with packages"
    fi
    if [ "$workspace" != "true" ]; then
      fail "exclude needs workspace 'true', as cargo does"
    fi
  fi

  # Arguments are split on spaces and tabs and handed over as they are,
  # never through a shell, so quotes and globs carry no meaning.
  case "$test_args" in
    *$'\n'* | *$'\r'*) fail "test_args must be a single line" ;;
  esac
  test_arg_list=()
  IFS=$' \t' read -r -a test_arg_list <<< "$test_args" || true

  local tool
  for tool in cargo mktemp awk; do
    if ! command -v "$tool" > /dev/null 2>&1; then
      fail "required tool not found on PATH: $tool"
    fi
  done

  check_paths
  build_selection
}

check_paths() {
  local workspace_dir="${GITHUB_WORKSPACE:-$PWD}" dir
  if ! workspace_real="$(cd -- "$workspace_dir" 2> /dev/null && pwd -P)"; then
    fail "GITHUB_WORKSPACE is not a directory"
  fi

  case "$path_prefix" in
    *[[:cntrl:]]*) fail "path_prefix must not contain control characters" ;;
    /*) dir="$path_prefix" ;;
    *) dir="$workspace_real/$path_prefix" ;;
  esac
  if ! project_dir="$(cd -- "$dir" 2> /dev/null && pwd -P)"; then
    fail "path_prefix is not a directory"
  fi
  if ! inside_workspace "$project_dir"; then
    fail "path_prefix must resolve inside the workspace"
  fi

  require_relative_path manifest_path "$manifest_path"
  case "$manifest_path" in
    Cargo.toml | */Cargo.toml) ;;
    *) fail "manifest_path must name a Cargo.toml file" ;;
  esac
  contained_file manifest_path "$project_dir/$manifest_path"
  manifest_abs="$resolved_file"
  manifest_display="${manifest_abs#"${workspace_real%/}"/}"

  setup_abs=""
  if [ -n "$setup_script" ]; then
    require_relative_path setup_script "$setup_script"
    contained_file setup_script "$project_dir/$setup_script"
    setup_abs="$resolved_file"
  fi

  artefact_dir=""
  if [ -n "$artefact_path" ]; then
    resolve_artefact_dir
  fi
}

# Resolve artefact_path, which need not exist yet, to 'artefact_dir'.
# The deepest part that exists is canonicalised, so symlinks above it
# are followed before the containment check; the rest may hold only
# plain names, which mkdir later creates as real directories.
resolve_artefact_dir() {
  local candidate rest="" part existing
  require_relative_path artefact_path "$artefact_path"
  candidate="$project_dir/$artefact_path"
  while [[ "$candidate" == */ ]]; do
    candidate="${candidate%/}"
  done
  if [ -L "$candidate" ]; then
    fail "artefact_path must not be a symlink"
  fi
  while [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; do
    part="${candidate##*/}"
    case "$part" in
      "" | . | ..)
        fail "artefact_path may not use '.', '..' or '//' below a" \
          "directory that does not exist yet"
        ;;
    esac
    rest="$part${rest:+/$rest}"
    candidate="${candidate%/*}"
  done
  if ! existing="$(cd -- "$candidate" 2> /dev/null && pwd -P)"; then
    fail "artefact_path must name a directory below path_prefix"
  fi
  artefact_dir="$existing${rest:+/$rest}"
  if ! inside_workspace "$artefact_dir"; then
    fail "artefact_path must resolve inside the workspace"
  fi
  check_report_dir_path artefact_path "$artefact_dir"
  if [ -d "$artefact_dir" ] && [ -n "$(ls -A -- "$artefact_dir")" ]; then
    fail "artefact_path must be empty or absent, so that the artefact" \
      "holds only this run's reports"
  fi
}

# The JUnit path goes into a TOML literal string, which cannot hold a
# single quote, and upload-artifact reads its path as a glob pattern.
# $1 names the source of report directory path $2 for errors.
check_report_dir_path() {
  case "$2" in
    *"'"* | *[[:cntrl:]]*)
      fail "$1 resolves to a path holding characters this action cannot quote"
      ;;
  esac
  if [ "$artefact_upload" = "true" ] \
    && { [[ "$2" == *[][*?\\]* ]] || [[ "$2" =~ [[:space:]]$ ]]; }; then
    fail "$1 must not hold * ? [ ] or a backslash, or end in a space," \
      "for the upload"
  fi
}

# Cargo arguments that select the project, shared by every cargo
# command that builds or runs tests.
build_selection() {
  local name
  select_args=(--manifest-path "$manifest_abs" --locked)
  if [ "$workspace" = "true" ] && [ "${#package_list[@]}" -eq 0 ]; then
    select_args+=(--workspace)
  fi
  for name in ${package_list[@]+"${package_list[@]}"}; do
    select_args+=(-p "$name")
  done
  for name in ${exclude_list[@]+"${exclude_list[@]}"}; do
    select_args+=(--exclude "$name")
  done
  if [ "${#feature_list[@]}" -gt 0 ]; then
    select_args+=(--features "$(IFS=,; printf '%s' "${feature_list[*]}")")
  fi
  if [ "$all_features" = "true" ]; then
    select_args+=(--all-features)
  fi
  if [ "$no_default_features" = "true" ]; then
    select_args+=(--no-default-features)
  fi
}

### Job summary ###

# Escape a value for one Markdown table cell or list item.
md_text() {
  local text="$1"
  text=${text//'&'/'&amp;'}
  text=${text//'<'/'&lt;'}
  text=${text//'>'/'&gt;'}
  text=${text//'|'/'&#124;'}
  text=${text//'`'/'&#96;'}
  text=${text//'*'/'&#42;'}
  text=${text//'_'/'&#95;'}
  text=${text//'['/'&#91;'}
  text=${text//$'\r'/' '}
  text=${text//$'\n'/' '}
  printf '%s' "$text"
}

# Inline code that still renders once its content has been escaped.
md_code() {
  printf '<code>%s</code>' "$(md_text "$1")"
}

# A byte count for people, such as '512 B' or '3.4 KiB'.
format_size() {
  local whole="$1" tenths=0 unit=0
  local -a units=(B KiB MiB GiB)
  while [ "$whole" -ge 1024 ] && [ "$unit" -lt 3 ]; do
    tenths=$(((whole % 1024) * 10 / 1024))
    whole=$((whole / 1024))
    unit=$((unit + 1))
  done
  if [ "$unit" -eq 0 ]; then
    printf '%d B' "$whole"
  else
    printf '%d.%d %s' "$whole" "$tenths" "${units[$unit]}"
  fi
}

# Queue a table row: the label is ours, the cell already escaped.
add_row() {
  summary_rows+=("| $1 | $2 |")
}

# Append the summary in one write, given the outcome line (already
# escaped). A failed write warns and leaves the exit status alone.
write_summary() {
  local outcome="$1" text row note
  if [ "$summary_enabled" != "true" ] || [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
    return 0
  fi
  text="$(
    printf '## 🦀 Rust Test\n\n### %s\n\n' "$outcome"
    if [ -n "$failure_reason" ]; then
      printf '%s\n\n' "$(md_text "$failure_reason")"
    fi
    printf '| Check | Result |\n| --- | --- |\n'
    for row in ${summary_rows[@]+"${summary_rows[@]}"}; do
      printf '%s\n' "$row"
    done
    if [ "${#summary_notes[@]}" -gt 0 ]; then
      printf '\n**Warnings**\n\n'
      for note in "${summary_notes[@]}"; do
        printf -- '- %s\n' "$(md_text "$note")"
      done
    fi
  )"
  if ! printf '\n%s\n' "$text" 2> /dev/null >> "$GITHUB_STEP_SUMMARY"; then
    echo "::warning::Could not write the Rust test job summary"
  fi
}
