#!/usr/bin/env bash
# Run replay_builder.py on node-8 from stdin with this branch's comm_state.py and need_asks.py embedded.
# Read-only and nothing is written on node-8. Run it BETWEEN ticks: it asks the replica a handful of statements.
# usage: run_replay.sh <tick dir on node-8> [page_start page_len max_users]
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)"
dir="${1:?tick dir on node-8}"; shift
{
  printf 'SRC = {\n'
  for m in comm_state need_asks; do
    printf '  "%s": "%s",\n' "$m" "$(base64 -w0 "$root/scripts/credit_review/$m.py")"
  done
  printf '}\n'
  cat "$here/replay_builder.py"
} | ssh -o ConnectTimeout=15 root@40.160.32.80 "cd '$dir' && python3 -I - need-asks-all.json $*"
