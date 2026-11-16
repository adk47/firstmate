#!/usr/bin/env bash
# The sustained ledger measurement (firstmate 017/018): start it the minute the shards are live, it waits out the
# window, then measures decisions persisted per minute and a proof row per applied conclusion, read-only.
#
#   sustained.sh [--start YYYY-MM-DDTHH:MM] [--minutes 30] [--target 1000] [--out DIR]
#
# --start defaults to the next whole UTC minute. The window is [start, start + minutes). It reads the live ledgers
# with `mode=ro` (never created, never migrated) under a 2G memory cap, after the window closes plus 60 s for the last
# writes to commit. Exit: ledger_rate.py --check's (0 = sustained at target with every applied conclusion proved,
# 1 = not, 2 = BLIND: a required store could not be read).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LEDGER=/var/lib/hydra/credit-review/ledger.sqlite3
DRAIN=/var/lib/hydra/credit-review/drain.sqlite
start="" minutes=30 target=1000 out=/root/verif1000/sustained
while [ $# -gt 0 ]; do
  case "$1" in
    --start) start=$2; shift 2 ;;
    --minutes) minutes=$2; shift 2 ;;
    --target) target=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
[ -n "$start" ] || start=$(date -u -d "@$(( ($(date -u +%s) / 60 + 1) * 60 ))" +%Y-%m-%dT%H:%M)
start_s=$(date -u -d "${start/T/ } UTC" +%s)
until_s=$(( start_s + minutes * 60 ))
since=$(date -u -d "@$start_s" +%Y-%m-%dT%H:%M:%S)
until=$(date -u -d "@$until_s" +%Y-%m-%dT%H:%M:%S)
mkdir -p "$out"
tag=$(date -u -d "@$start_s" +%Y%m%dT%H%MZ)
echo "window [$since, $until) UTC, target $target/min for $minutes min; result -> $out/rate-$tag.json" >&2
wait_s=$(( until_s + 60 - $(date -u +%s) ))
[ "$wait_s" -le 0 ] || sleep "$wait_s"
rc=0
systemd-run --scope -q -p MemoryMax=2G nice -n 10 \
  python3 "$here/ledger_rate.py" --ledger "$LEDGER" --drain "$DRAIN" --since "$since" --until "$until" \
  --target "$target" --sustain "$minutes" --check > "$out/rate-$tag.json" || rc=$?
python3 - "$out/rate-$tag.json" "$rc" <<'EOF'
import json, sys
o = json.load(open(sys.argv[1])); c = o["combined"]
print(f"window {o['window']['since']}..{o['window']['until']} rc={sys.argv[2]} sustained={o['sustained']}")
print(f"decisions persisted: total {c['total']}, per minute min/median/max {c['per_minute_min']}/"
      f"{c['per_minute_median']}/{c['per_minute_max']}, longest run >= {o['target_per_minute']}: "
      f"{c['longest_run_at_or_above_target']} min, of which stamped in <10 s: "
      f"{c['minutes_at_target_stamped_in_under_10_seconds']}")
print(f"applied conclusions {o['applied']}, without a proof row {o['applied_without_proof']}, absent {o['absent']}")
for k, v in o["sources"].items():
    if "absent" in v:
        print(f"  {k}: absent ({v['absent']})")
    else:
        print(f"  {k}: total {v['summary']['total']} applied {v['applied']} no-proof {v['without_proof']} "
              f"not-applied {v.get('attempted_not_applied', {})}")
print("per minute: " + " ".join(f"{m[11:]}={n}/{c['stamped_seconds'][m]}s" for m, n in c["per_minute"].items()))
EOF
exit "$rc"
