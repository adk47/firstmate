#!/usr/bin/env bash

# Print missing/invalid muso variables after systemd parses an EnvironmentFile.
# This deliberately delegates parsing to systemd instead of sourcing the file
# as shell code. Callers distinguish missing values (stdout, exit 0) from an
# unavailable/broken systemd-run (non-zero exit).
muso_main_env_missing() {
  local env_file="${1:?environment file required}"
  local systemd_run_bin="${MUSO_SYSTEMD_RUN_BIN:-systemd-run}"

  "$systemd_run_bin" --quiet --wait --collect --pipe \
    --property="EnvironmentFile=$env_file" \
    /usr/bin/python3 -c '
import os
required = (
    "MUSO_ADMIN_EMAIL", "MUSO_ADMIN_PASSWORD",
    "MUSO_PROD_ADMIN_EMAIL", "MUSO_PROD_ADMIN_PASSWORD",
    "MUSO_DEV_ADMIN_EMAIL", "MUSO_DEV_ADMIN_PASSWORD",
)
for key in required:
    if not os.environ.get(key):
        print(key)
if os.environ.get("MUSO_ENV") != "prod":
    print("MUSO_ENV=prod")
if os.environ.get("MUSO_NONINTERACTIVE") != "1":
    print("MUSO_NONINTERACTIVE=1")
if os.environ.get("MUSO_STATE_DIR") != "/var/log/muso-ops":
    print("MUSO_STATE_DIR=/var/log/muso-ops")
'
}

# Print the deploy-log lines the caller should emit for a main.env file that
# is present on disk, given muso_main_env_missing()'s result. Distinguishes
# "we checked and vars are missing" (WARN, actionable) from "we could not
# check" (muso_main_env_missing returned non-zero — systemd-run, python3, or
# the EnvironmentFile itself was unavailable — INFO only, never claim vars are
# missing when we never actually looked).
muso_main_env_report() {
  local env_file="${1:?environment file required}"
  local effective_missing
  local -a missing_vars=()

  if effective_missing="$(muso_main_env_missing "$env_file" 2>/dev/null)"; then
    while IFS= read -r var; do
      [[ -n "$var" ]] && missing_vars+=("$var")
    done <<< "$effective_missing"
    if (( ${#missing_vars[@]} > 0 )); then
      echo "WARN: $env_file is missing: ${missing_vars[*]}"
      echo "WARN: ops agent admin API / muso CLI operations will fail until these are added (docs/runbooks/RUNBOOK.md, 'muso CLI')."
      echo "WARN: fix with:  sudo vim $env_file  &&  systemctl restart openclaw-gateway-main"
    fi
  else
    echo "INFO: skipped main.env validation (env check could not run in this context)"
  fi
}
