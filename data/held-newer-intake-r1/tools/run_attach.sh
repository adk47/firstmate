#!/usr/bin/env bash
# Attach attach_sampler.py to the tick now running on node-8. Passive: it starts nothing and writes nothing there.
# usage: run_attach.sh [segment=paid] [wait_minutes=120]     (stdout is the aggregate report)
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)"
{
  printf 'SRC = {"proc_sampler": "%s"}\n' "$(base64 -w0 "$root/data/node8-fly-gate-v2/tools/proc_sampler.py")"
  cat "$here/attach_sampler.py"
} | ssh -o ConnectTimeout=15 -o ServerAliveInterval=30 root@40.160.32.80 \
  "tick=\$(pgrep -f '^bash /opt/hydra/scripts/credit-verify-outbound.sh' | head -1); [ -n \"\$tick\" ] || { echo 'no tick is running'; exit 5; }; exec python3 -I - \"\$tick\" ${1:-paid} ${2:-120}"
