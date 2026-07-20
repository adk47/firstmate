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
