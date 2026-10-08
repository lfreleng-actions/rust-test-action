#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Sourced by the stand-ins. Appends '<program>|<values>' to
# MOCK_CRED_LOG, one field for each variable in withheld_names, then
# CARGO_REGISTRIES_PRIVATE_INDEX, writing 'unset' for each one absent
# from the environment, so tests can prove the action withheld them.

withheld_names=(CARGO_REGISTRY_TOKEN CARGO_REGISTRIES_CRATES_IO_TOKEN
  CARGO_REGISTRIES_PRIVATE_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN
  ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_RUNTIME_TOKEN GITHUB_OUTPUT
  GITHUB_ENV GITHUB_PATH GITHUB_STATE GITHUB_STEP_SUMMARY)

record_credentials() {
  local line="$1" name
  for name in "${withheld_names[@]}" CARGO_REGISTRIES_PRIVATE_INDEX; do
    line="$line|${!name-unset}"
  done
  printf '%s\n' "$line" >> "$MOCK_CRED_LOG"
}
