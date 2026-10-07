<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# 🦀 Rust Test

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/rust-test-action) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![pre-commit.ci status badge]][pre-commit.ci results page] [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lfreleng-actions/rust-test-action/badge)](https://scorecard.dev/viewer/?uri=github.com/lfreleng-actions/rust-test-action)
<!-- prettier-ignore-end -->

Runs the tests of a Rust project with `cargo test` or
[cargo-nextest](https://nexte.st/). On request, it measures line
coverage with
[cargo-llvm-cov](https://github.com/taiki-e/cargo-llvm-cov), writes
JUnit XML, lcov and Cobertura reports, and uploads them as one
workflow artefact, also when tests fail.

The action takes no secrets and needs no `id-token` permission. It
runs the tests, and everything else that executes project code,
without the registry, OIDC and runtime credentials or the runner's
command files listed under [Security](#security). The artefact upload
step, which runs `actions/upload-artifact`, is the one step that uses
the runner's own token.

## rust-test-action

## Usage Example

<!-- markdownlint-disable MD013 MD046 -->

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: "Test Rust project"
        id: test
        # Pin to a commit SHA
        uses: lfreleng-actions/rust-test-action@<commit-sha>
        with:
          test_runner: "nextest"
          coverage: "true"

      - name: "Show the coverage"
        shell: bash
        env:
          COVERAGE: ${{ steps.test.outputs.coverage_percent }}
        run: echo "Line coverage: ${COVERAGE}%"
```

In a matrix, give each leg its own `artefact_name`, for example
`rust-test-results-${{ matrix.os }}`. Two uploads with the same name
in one workflow run conflict, and the second fails.

<!-- markdownlint-enable MD013 MD046 -->

## Inputs

<!-- markdownlint-disable MD013 -->

| Name                | Required | Default             | Description                                                                             |
| ------------------- | -------- | ------------------- | --------------------------------------------------------------------------------------- |
| path_prefix         | False    | `.`                 | Directory holding the project; must resolve inside the workspace                        |
| manifest_path       | False    | `Cargo.toml`        | Path to `Cargo.toml`, relative to `path_prefix`; must not be a symlink                  |
| workspace           | False    | `true`              | Test every workspace member (`--workspace`); a non-empty `packages` replaces it         |
| packages            | False    |                     | Whitespace-separated packages to test (`-p`)                                            |
| exclude             | False    |                     | Whitespace-separated packages to leave out; needs `workspace` and no `packages`         |
| features            | False    |                     | Features to enable, separated by whitespace or commas                                   |
| all_features        | False    | `false`             | Enable every feature (`--all-features`)                                                 |
| no_default_features | False    | `false`             | Disable the default features (`--no-default-features`)                                  |
| toolchain           | False    |                     | rustup toolchain to use; empty uses the one rustup selects for the project              |
| lockfile_required   | False    | `false`             | Fail when `Cargo.lock` is missing, rather than generating one with a warning            |
| setup_script        | False    |                     | Script, relative to `path_prefix`, run with bash from `path_prefix` before testing      |
| test_runner         | False    | `cargo`             | `cargo` (`cargo test`) or `nextest` (`cargo nextest run`)                               |
| nextest_version     | False    | `0.9.146`           | cargo-nextest version to install for the `nextest` runner                               |
| test_args           | False    |                     | Extra runner arguments, split on spaces and tabs, never run through a shell             |
| doc_tests           | False    | `true`              | Run doc tests                                                                           |
| coverage            | False    | `false`             | Run the tests under cargo-llvm-cov and write lcov and Cobertura reports                 |
| llvm_cov_version    | False    | `0.9.1`             | cargo-llvm-cov version to install for `coverage`                                        |
| junit               | False    |                     | Write JUnit XML (`true`/`false`); empty means `true` for `nextest`, `false` for `cargo` |
| artefact_upload     | False    | `true`              | Upload the JUnit and coverage reports as a workflow artefact                            |
| artefact_name       | False    | `rust-test-results` | Name of the report artefact; give each matrix leg its own                               |
| artefact_path       | False    |                     | Report directory, relative to `path_prefix`; see [Reports](#reports)                    |
| permit_fail         | False    | `false`             | Report success with a warning when tests fail; see [Notes](#notes) for the scope        |
| summary             | False    | `true`              | Write a results table to the job summary                                                |

<!-- markdownlint-enable MD013 -->

Boolean inputs accept `true` or `false` and nothing else.

## Outputs

<!-- markdownlint-disable MD013 -->

| Name                    | Description                                                                    |
| ----------------------- | ------------------------------------------------------------------------------ |
| toolchain               | Toolchain used: a rustup channel, a path, or empty without rustup              |
| toolchain_kind          | How the action found the toolchain: `channel`, `path` or `none`                |
| cargo_version           | Cargo version that ran the tests; the action fails when it cannot read it      |
| rustc_version           | rustc version that built the tests; the action fails when it cannot read it    |
| tests_outcome           | `passed` or `failed`; `failed` also when the action stopped before the tests   |
| coverage_percent        | Line coverage to two decimals, such as `87.50`; empty without coverage         |
| junit_path              | Absolute path of the JUnit XML report; empty when none                         |
| coverage_lcov_path      | Absolute path of the lcov report; empty when none                              |
| coverage_cobertura_path | Absolute path of the Cobertura XML report; empty when none                     |
| artefact_name           | Name of the uploaded artefact; empty when the action uploaded nothing          |
| artefact_path           | Absolute path of the report directory; empty when stopped before the tests     |

<!-- markdownlint-enable MD013 -->

## Implementation Details

A first step checks every input, then
[taiki-e/install-action](https://github.com/taiki-e/install-action)
installs cargo-nextest and cargo-llvm-cov when the run needs them. It
installs the prebuilt, checksummed binaries that its pinned release
lists, and fails rather than building a tool from source. The test
step then runs these stages:

1. **Check toolchain.** With an empty `toolchain`,
   `rustup show active-toolchain` names the toolchain that
   `path_prefix` selects, without running it. The action pins a
   channel through `RUSTUP_TOOLCHAIN` for every later call. A
   path-based toolchain runs unpinned from `path_prefix`, with a
   warning. Without rustup, the action uses the `cargo` on `PATH` and
   reports `toolchain_kind` as `none`. A `RUSTUP_TOOLCHAIN` in the
   job environment outranks `rust-toolchain.toml`, as in rustup; the
   action reports and uses that toolchain. The action then reads the
   Cargo and rustc versions, and fails when either `--version` command
   fails or prints something other than a Rust release number.
2. **Run setup script.** Runs `setup_script` with bash from
   `path_prefix`, for example to install the native libraries that
   `-sys` crates need.
3. **Check lockfile.** Without `Cargo.lock` beside the workspace root,
   the action fails when `lockfile_required` is `true`. Otherwise it
   runs `cargo generate-lockfile` and warns. Every later Cargo command
   runs with `--locked`.
4. **Prepare coverage.** Adds the `llvm-tools-preview` component to a
   channel toolchain, clears old profiling data, and lists the
   packages the selection inputs pick with `cargo tree`.
5. **Prepare reports.** Creates the report directory, after the setup
   script has run, and checks a set `artefact_path` again.
6. **Run tests.** Runs `cargo test`, `cargo nextest run`,
   `cargo llvm-cov test` or `cargo llvm-cov nextest`, with the
   selection inputs and then `test_args`.
7. **Run doc tests.** nextest cannot run doc tests and cargo-llvm-cov
   leaves them out on stable Rust, so those runs get a separate,
   uninstrumented `cargo test --doc`. A selection without a library
   target has no doc tests, and the action skips them. A plain
   `cargo test` run includes its doc tests last and stops at the first
   failing test binary, so when it fails the summary reports the doc
   tests as unknown.
8. **Write coverage reports.** Writes `lcov.info` and `cobertura.xml`
   for the packages listed in stage 4, naming each with `-p`, since
   `cargo llvm-cov report` accepts neither `exclude` nor the feature
   inputs. It computes `coverage_percent` as the lines hit over the
   lines found in the lcov report.
9. **Collect JUnit report.** For nextest, checks that `junit.xml`
   exists.

A failing test or doc test run does not stop the later stages, so the
reports describe the failure, and the upload step still runs. Any
other failure stops the action. The job summary shows the outcome, a
table of the stages, the report sizes, and any warnings.

### Security

- The action removes these variables from its own environment before
  it runs anything, so Cargo, its plugins, rustc, rustup,
  `setup_script`, and any program that project code places on `PATH`
  run without them:
  - registry tokens: `CARGO_REGISTRY_TOKEN` and every
    `CARGO_REGISTRIES_<NAME>_TOKEN`; other `CARGO_REGISTRIES_<NAME>_*`
    settings, such as `_INDEX`, stay;
  - GitHub OIDC and runtime tokens: `ACTIONS_ID_TOKEN_REQUEST_TOKEN`,
    `ACTIONS_ID_TOKEN_REQUEST_URL` and `ACTIONS_RUNTIME_TOKEN`;
  - the runner's command files: `GITHUB_OUTPUT`, `GITHUB_ENV`,
    `GITHUB_PATH`, `GITHUB_STATE` and `GITHUB_STEP_SUMMARY`.

  Tests run project code: give this job no credentials it does not
  need. The action keeps the command file paths as unexported shell
  variables and writes its own outputs and summary through them.
- `path_prefix`, `manifest_path`, `setup_script` and the Cargo
  workspace root must resolve inside the workspace after following
  symlinks. `manifest_path`, the workspace root `Cargo.toml`,
  `setup_script` and `Cargo.lock` must not be symlinks themselves.
- `test_args` must be one line. The action splits it on spaces and
  tabs and passes each word as one argument, so quotes, globs and `$`
  carry no meaning.
- The action validates every output as a single line before writing
  it, and escapes values it shows in the job summary.
- Removing the command file variables is defence in depth, not a
  boundary. It stops build scripts, proc-macros, tests and setup
  scripts from setting this step's outputs, or the environment, `PATH`
  and summary of later steps, through the documented variables. Their
  paths follow a predictable pattern below `RUNNER_TEMP`, and project
  code runs as the runner user, so code that goes looking can still
  write to them. Trust this action's outputs, and anything later steps
  read from the job environment, no more than the project under test.
- Before naming or uploading the reports directory, the action checks
  that it holds regular files alone and is no symlink. Project code
  could plant a symlink there to make the uploader read files from
  outside it; the action then fails and uploads nothing.

## Reports

With an empty `artefact_path`, the action writes the reports to a new
directory below `RUNNER_TEMP` and nothing into the checkout. The paths
in the outputs stay valid for later steps in the same job.

A non-empty `artefact_path` names a directory, relative to
`path_prefix`, that keeps the reports in place, for example for a
later step that publishes them. It must resolve inside the workspace,
must not be a symlink, and must be empty or absent, so the artefact
holds this run's reports and nothing else. The action creates it
right before the tests run, after `setup_script`, and checks it again
then. An earlier stop creates no report directory and leaves the
`artefact_path` output empty. With `artefact_upload` on, its path
must not hold `*`, `?`, `[`, `]` or a backslash, which
`actions/upload-artifact` reads as glob syntax.

When `artefact_upload` is `true` and the run wrote any report, the
action uploads the directory as the `artefact_name` artefact with
`if-no-files-found: warn`. The upload runs after failing tests too,
with `permit_fail` `true` or `false`, so the reports explain the
failure. The `artefact_name` output is empty when nothing reached the
upload.

## Notes

- The action runs on Linux runners, which its CI tests. It refuses
  Windows runners, whose native paths its workspace checks do not
  handle. Its CI does not cover macOS runners.

- The `cargo` runner cannot write JUnit XML; `junit: "true"` needs
  `test_runner: "nextest"`.
- `test_args` go to the main test run and not to the separate doc
  test run. For `cargo test`, put test harness arguments after `--`,
  for example `-- --test-threads=1`.
- Coverage figures leave out doc tests.
- `permit_fail` covers failing tests and doc tests, and a coverage or
  JUnit report that a failing main test run left unwritten: the
  failure may stop the run before it writes them. Invalid inputs, a
  failing setup script, a missing lockfile, or a report missing after
  the main test run passed, even with failing doc tests, still fail
  the step.
- nextest fails a run that finds no tests to run. Pass
  `test_args: "--no-tests=pass"` to accept that.
- For JUnit XML, the action runs nextest with its own
  `rust-test-action` profile from a tool configuration file. A
  `.config/nextest.toml` in the repository still applies and takes
  precedence where both set a value.
- See [Reports](#reports) for where the reports live.
- Cargo runs from `path_prefix`, so it reads `.cargo/config.toml`
  files from `path_prefix` and its parents.
- The action does not cache Cargo's registry or build directory.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/rust-test-action/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/rust-test-action/main.svg
