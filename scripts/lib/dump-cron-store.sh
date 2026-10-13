#!/usr/bin/env bash
# Dump the LIVE openclaw cron store (SQLite `cron_jobs`) to a JSON file via the
# runtime's own loadCronStore — the same read deploy.sh's store-only cron guard
# and the PR pre-flight "Cron job orphan check" both feed to
# detect-store-only-crons.py.
#
# Fail-CLOSED: a missing SQLite file, missing SDK or failed read exits non-zero.
# MUS-3346: the old pre-flight read cron/jobs.json (a path the 7.x runtime never
# writes) and `exit 0`'d when it was absent, so it was green on every PR.
#
# Usage: dump-cron-store.sh <out.json>
# Env:   OPENCLAW_STATE_DIR  profile dir (default /root/.openclaw-main)
#        CRON_SDK            cron-store-runtime.js path (default: discovered
#                            under `npm root -g`; override is for tests)
set -euo pipefail

OUT="${1:?usage: dump-cron-store.sh <out.json>}"
STATE_DIR="${OPENCLAW_STATE_DIR:-/root/.openclaw-main}"
DB="$STATE_DIR/state/openclaw.sqlite"

if [ ! -f "$DB" ]; then
  echo "cron store dump: live SQLite store not found at $DB" >&2
  exit 1
fi

if [ -z "${CRON_SDK:-}" ]; then
  # Node's ESM resolver ignores NODE_PATH and the global npm root, so the import
  # must use the ABSOLUTE dist path (PR #537).
  GLOBAL_NODE_MODULES=$(npm root -g 2>/dev/null) || {
    echo "cron store dump: 'npm root -g' failed — cannot locate openclaw global install" >&2
    exit 1
  }
  CRON_SDK="$GLOBAL_NODE_MODULES/openclaw/dist/plugin-sdk/cron-store-runtime.js"
fi
if [ ! -f "$CRON_SDK" ]; then
  echo "cron store dump: openclaw cron-store SDK not found at $CRON_SDK — openclaw layout changed" >&2
  exit 1
fi

OPENCLAW_STATE_DIR="$STATE_DIR" CRON_SDK="$CRON_SDK" STORE_DUMP="$OUT" \
  node --input-type=module -e '
    import { writeFileSync } from "node:fs";
    try {
      const m = await import(process.env.CRON_SDK);
      const cur = await m.loadCronStore(m.resolveCronStorePath());
      writeFileSync(process.env.STORE_DUMP, JSON.stringify(cur));
      process.exit(0);
    } catch (e) { console.error(e); process.exit(1); }
  '
