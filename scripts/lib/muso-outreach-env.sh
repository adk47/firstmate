#!/bin/bash
# Source this file, then call muso_outreach_load_env.
# Loads shared.env then main.env from ${OPENCLAW_ENV_DIR:-/etc/openclaw}
# (NOCODB_API_TOKEN lives only in main.env) and checks the token is set.
# Returns 2 (never exits: people source this in a shell). Never prints a value.
muso_outreach_load_env() {
  local dir="${OPENCLAW_ENV_DIR:-/etc/openclaw}" f
  for f in "$dir/shared.env" "$dir/main.env"; do
    # shellcheck disable=SC1090  # env files are chosen at run time
    [[ -r "$f" ]] && { set -a; . "$f"; set +a; }
  done
  if [[ -z "${NOCODB_API_TOKEN:-}" ]]; then
    echo "[muso-outreach-monday] FATAL: NOCODB_API_TOKEN empty after loading $dir/{shared,main}.env" >&2
    return 2
  fi
  return 0
}
