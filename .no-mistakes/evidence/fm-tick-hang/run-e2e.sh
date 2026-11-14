#!/usr/bin/env bash
# Drives the ak47 hygiene tick, the take-down, the weekly review and the swap
# reclaim end to end against a sandbox /tmp, exactly as an operator would.
set -u
REPO=/home/aaron/.no-mistakes/worktrees/72295860b10d/01M7DM7C2MW2SMQQZH9RF17C2W
EVID=/home/aaron/.no-mistakes/evidence/01M7DM7C2MW2SMQQZH9RF17C2W
SB=$(mktemp -d /tmp/ak47-e2e.XXXXXX)
export AK47_STATE=$SB/state AK47_CACHE=$SB/cache AK47_CONFIG=$SB/config
export AK47_TMP_ROOT=$SB/tmp FM_HOME=$SB/fmhome AK47_BUDGET=$REPO/ak47/budget.conf
mkdir -p "$AK47_STATE" "$AK47_CACHE" "$AK47_CONFIG" "$AK47_TMP_ROOT" "$FM_HOME/state" "$FM_HOME/bin"
cat >"$AK47_CONFIG/devops.conf" <<'CONF'
tmp_mktemp_min=0
tmp_producer_min=0
orphan_min=0
quarantine_days=7
tmp_max_entries=0
tmp_max_moves=2000
swap_pressure=0
fat_process=0
fat_process_gb=3
fat_process_min=10
interval_seconds=300
CONF
# an inbox stub so delivery is observable without touching the real chair
cat >"$FM_HOME/bin/fm-inbox.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FM_HOME/state/inbox.calls"
STUB
chmod +x "$FM_HOME/bin/fm-inbox.sh"

T=$AK47_TMP_ROOT
# 1. a big junk dir nothing enumerates, 40 days idle, unheld -> take-down candidate
mkdir -p "$T/big-junk"; for i in $(seq 1 400); do head -c 20000 /dev/zero >"$T/big-junk/f$i"; done
touch -d '40 days ago' "$T/big-junk"
# 2. a leaked mktemp dir the tick's own table names (routine hygiene)
mkdir -p "$T/tmp.abcdefghij"; head -c 2000 /dev/zero >"$T/tmp.abcdefghij/x"; touch -d '3 days ago' "$T/tmp.abcdefghij"
# 3. protected: the forwarder and the ak47 state dir
mkdir -p "$T/ak47-live" "$T/cli-proxy-api"; touch -d '40 days ago' "$T/ak47-live" "$T/cli-proxy-api"
# 4. a live task's scratch root
mkdir -p "$T/fm-01M7LIVE"; echo meta >"$FM_HOME/state/01M7LIVE.meta"; touch -d '40 days ago' "$T/fm-01M7LIVE"
# 5. an old dir a running process holds open
mkdir -p "$T/held-junk"; head -c 1000 /dev/zero >"$T/held-junk/open.bin"; touch -d '40 days ago' "$T/held-junk"
exec 9<"$T/held-junk/open.bin"
# 6. a young dir (age gate)
mkdir -p "$T/fresh-junk"; head -c 1000 /dev/zero >"$T/fresh-junk/x"
# 7. a symlink that spells itself differently from its target
mkdir -p "$SB/outside-target"; ln -s "$SB/outside-target" "$T/link-junk"; touch -h -d '40 days ago' "$T/link-junk"

echo "=== fixture: sandbox /tmp ==="
ls -la "$T" | sed 's/^/  /'

echo
echo "=== 1. the tick (one run, --apply) ==="
"$REPO/ak47/tick.sh" --apply; echo "tick exit=$?"
echo "--- devops.log (the one line per run an operator reads) ---"
tail -n 1 "$AK47_STATE/devops.log"
echo "--- inbox calls ---"
cat "$FM_HOME/state/inbox.calls" 2>/dev/null || echo "(none)"
echo "--- tree after the tick ---"
find "$T" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | sed 's/^/  /'
echo "--- quarantine contents ---"
find "$AK47_STATE/quarantine" -mindepth 1 -maxdepth 3 -printf '%P\n' 2>/dev/null | sort | sed 's/^/  /'

echo
echo "=== 2. tmp-takedown.sh --dry-run (the big-entry take-down) ==="
"$REPO/ak47/tmp-takedown.sh" --dry-run; echo "dry-run exit=$?"

echo
echo "=== 3. tmp-takedown.sh --apply ==="
"$REPO/ak47/tmp-takedown.sh" --apply; echo "apply exit=$?"
echo "--- big-junk still on disk? ---"
[ -e "$T/big-junk" ] && echo "  still at $T/big-junk" || echo "  moved out of the live tree"
echo "--- inside quarantine (moved, not deleted) ---"
find "$AK47_STATE/quarantine" -mindepth 1 -maxdepth 2 -printf '%P\n' | sort | sed 's/^/  /'
echo "--- protected paths untouched ---"
for p in "$T/ak47-live" "$T/cli-proxy-api" "$T/fm-01M7LIVE" "$T/held-junk" "$T/fresh-junk" "$T/link-junk"; do
  [ -d "$p" ] || [ -L "$p" ] && echo "  kept: $p"
done

echo
echo "=== 4. bounded size walk: an overrunning walk falls back, is not re-paid, and is reported ==="
{ printf 'tmp_gb\t%s\t%s\n' "$(( $(date +%s) - 3600 ))" 698
  printf 'tmp_gb_ok\t%s\t%s\n' "$(( $(date +%s) - 10800 ))" 698
} >"$AK47_STATE/sample.cache"
stubdu=$SB/du-stub; mkdir -p "$stubdu"
printf '#!/bin/sh\nsleep 60\n' >"$stubdu/du"; chmod +x "$stubdu/du"
start=$(date +%s)
PATH="$stubdu:$PATH" AK47_DU_BUDGET=2 "$REPO/ak47/tick.sh" --apply >/dev/null 2>&1
echo "  tick finished in $(( $(date +%s) - start ))s with a du that never returns (budget 2s)"
echo "--- tick line: the budget scored the last real measurement, not an invented 0 ---"
tail -n 1 "$AK47_STATE/devops.log"
echo "--- the sample the weekly review reads ---"
tail -n 1 "$AK47_STATE/samples.log"
echo "--- cached value after the failed walk (re-stamped, so it is not re-paid next tick) ---"
cat "$AK47_STATE/sample.cache"
echo "--- second tick straight after: the failure marker short-circuits the retry ---"
start=$(date +%s)
PATH="$stubdu:$PATH" AK47_DU_BUDGET=2 "$REPO/ak47/tick.sh" --apply >/dev/null 2>&1
echo "  second tick finished in $(( $(date +%s) - start ))s (no du budget paid again)"
echo "--- the finding an operator gets ---"
cat "$AK47_STATE/findings.log" 2>/dev/null | sed 's/^/  /'
tail -n 1 "$FM_HOME/state/inbox.calls" 2>/dev/null | sed 's/^/  /'

echo "--- third tick with the retry window elapsed: the walk is due again, once ---"
start=$(date +%s)
PATH="$stubdu:$PATH" AK47_DU_BUDGET=2 AK47_DU_RETRY=0 "$REPO/ak47/tick.sh" --apply >/dev/null 2>&1
echo "  tick with AK47_DU_RETRY=0 finished in $(( $(date +%s) - start ))s (the failed walk is paid once more)"

echo
echo "=== 4a. expiry is bounded per run, and the deferred backlog is on the line ==="
sed -i 's/^tmp_max_entries=.*/tmp_max_entries=0/' "$AK47_CONFIG/devops.conf"
printf 'quarantine_expire_max=3\n' >>"$AK47_CONFIG/devops.conf"
mkdir -p "$AK47_STATE/quarantine/20200101"
for i in 1 2 3 4 5; do mkdir -p "$AK47_STATE/quarantine/20200101/entry-$i"; echo x >"$AK47_STATE/quarantine/20200101/entry-$i/f"; done
PATH="$stubdu:$PATH" AK47_DU_BUDGET=2 AK47_DU_RETRY=900 "$REPO/ak47/tick.sh" --apply >/dev/null 2>&1
tail -n 1 "$AK47_STATE/devops.log" | sed 's/^/  /'
echo "  entries left in the old quarantine day: $(find "$AK47_STATE/quarantine/20200101" -mindepth 1 -maxdepth 1 | wc -l) of 5"
grep deferred "$AK47_STATE/reap.log" | tail -n 1 | sed 's/^/  /'
sed -i '/^quarantine_expire_max=/d' "$AK47_CONFIG/devops.conf"

echo
echo "=== 4b. the in-use set: no completion marker means \"could not tell\", never \"free\" ==="
IS=$SB/inuse-demo; mkdir -p "$IS/entry"
bash -c '
  . "$1/ak47/lib/safe-delete.sh"
  set +e
  printf "ak47-inuse-complete\n" >"$2/set-with-marker"
  AK47_INUSE_SET="$2/set-with-marker" ak47_has_open_handles "$2/entry"; echo "  complete set, nothing held -> rc=$? (1 = provably free)"
  printf "" >"$2/set-no-marker"
  AK47_INUSE_SET="$2/set-no-marker" ak47_has_open_handles "$2/entry"; echo "  set without its marker -> rc=$? (2 = could not tell, delete refused)"
  AK47_INUSE_SET="$2/absent" ak47_has_open_handles "$2/entry"; echo "  set missing entirely -> rc=$? (2 = could not tell, delete refused)"
' _ "$REPO" "$IS"

echo "=== 5. swap reclaim: the unit's script always restores swap ==="
stub=$SB/stubbin; mkdir -p "$stub"
printf '#!/bin/sh\necho "swapoff $*" >>"%s/swap.calls"\nexit 1\n' "$SB" >"$stub/swapoff"
printf '#!/bin/sh\necho "swapon $*" >>"%s/swap.calls"\nexit 0\n' "$SB" >"$stub/swapon"
chmod +x "$stub/swapoff" "$stub/swapon"
PATH="$stub:$PATH" AK47_SWAP_PRIVILEGE=yes AK47_SWAPOFF="$stub/swapoff" AK47_SWAPON="$stub/swapon" \
  AK47_SWAPOFF_BUDGET=1800 "$REPO/ak47/swap-reclaim.sh"; echo "swap-reclaim exit=$? (1 = reclaim failed)"
echo "--- swap.log ---"; cat "$AK47_STATE/swap.log" | sed 's/^/  /'
echo "--- commands it ran ---"; cat "$SB/swap.calls" | sed 's/^/  /'
echo "--- inbox ---"; tail -n 2 "$FM_HOME/state/inbox.calls" 2>/dev/null | sed 's/^/  /'
echo "--- the unit that owns it ---"
grep -E 'ExecStart|TimeoutStartSec|Type=' "$REPO/ak47/units/ak47-swap-reclaim.service" | sed 's/^/  /'

echo
echo "=== 6. weekly review: a CHANGE next to a HOLDen ceiling, both visible ==="
rm -rf "$AK47_STATE"
mkdir -p "$AK47_STATE"
now=$(date +%s)
{
  echo "AK47_SAMPLES_V1"
  for i in $(seq 0 199); do
    ts=$(( now - (200 - i) * 600 ))
    # tmp_gb spends its top 5% at 25 GB (ceiling 20) -> a raise is proposed.
    # swap_pct sits pinned at 99%, its own maximum -> a raise cannot help.
    gb=10; [ "$i" -ge 190 ] && gb=25
    echo "$ts tmp_gb=$gb swap_pct=99 tmp_entries=1000"
  done
} >"$AK47_STATE/samples.log"
cat >"$AK47_STATE/devops.log" <<LOG
$(date -u -d '@'$((now-600)) +%Y-%m-%dT%H:%M:%SZ) tick mode=apply tmp_before=1000 tmp_after=1000 moved=0 deleted=0 busy=0 protected=0 failures=0 actions=0 loop_gap=0s classes=none expire_pending=0 breaches=tmp_gb=25>20
LOG
"$REPO/ak47/weekly-review.sh" --days 7 --print --no-inbox 2>&1 | sed 's/^/  /'
echo "--- the diff artifact the inbox note points at (CHANGE and HELD together) ---"
cat "$AK47_STATE"/review-*.diff 2>/dev/null | sed 's/^/  /'
echo
echo "--- and the inbox line a CHANGE files ---"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/state/inbox.calls"\n' "$FM_HOME" >"$FM_HOME/bin/fm-inbox.sh"
chmod +x "$FM_HOME/bin/fm-inbox.sh"
"$REPO/ak47/weekly-review.sh" --days 7 >/dev/null 2>&1
tail -n 1 "$FM_HOME/state/inbox.calls" | sed 's/^/  /'
echo
echo
echo "=== 7. the tick rings the reclaim unit and never swaps inline ==="
sb2=$SB/stub-ctl; mkdir -p "$sb2"
printf '#!/bin/sh\nprintf "systemctl %%s\\n" "$*" >>"%s/systemctl.calls"\ncase "$*" in *is-active*) exit 1 ;; esac\nexit 0\n' "$SB" >"$sb2/systemctl"
chmod +x "$sb2/systemctl"
{ printf 'SwapTotal:      33554428 kB\n'; printf 'SwapFree:         335544 kB\n'; printf 'MemAvailable:   90000000 kB\n'; } >"$SB/meminfo"
sed -i 's/^swap_pressure=.*/swap_pressure=1/' "$AK47_CONFIG/devops.conf"
: >"$SB/systemctl.calls"
AK47_SYSTEMCTL="$sb2/systemctl" AK47_SWAP_PRIVILEGE=yes AK47_MEMINFO="$SB/meminfo" \
  "$REPO/ak47/tick.sh" --apply >/dev/null 2>&1
echo "--- tick line ---"; tail -n 1 "$AK47_STATE/devops.log" | sed 's/^/  /'
echo "--- the action record with its revert ---"; grep swap-pressure "$AK47_STATE/reap.log" | tail -n 1 | sed 's/^/  /'
echo "--- what it rang ---"; cat "$SB/systemctl.calls" | sed 's/^/  /'
sed -i 's/^swap_pressure=.*/swap_pressure=0/' "$AK47_CONFIG/devops.conf"

echo
echo "=== 8. an unprivileged tick files one finding instead of failing to swap every tick ==="
: >"$FM_HOME/state/inbox.calls"
sed -i 's/^swap_pressure=.*/swap_pressure=1/' "$AK47_CONFIG/devops.conf"
AK47_SWAP_PRIVILEGE=no AK47_MEMINFO="$SB/meminfo" "$REPO/ak47/tick.sh" --apply >/dev/null 2>&1
sed -i 's/^swap_pressure=.*/swap_pressure=0/' "$AK47_CONFIG/devops.conf"
tail -n 1 "$AK47_STATE/devops.log" | sed 's/^/  /'
grep -c swap "$AK47_STATE/findings.log" 2>/dev/null | sed 's/^/  swap findings recorded: /'
tail -n 1 "$FM_HOME/state/inbox.calls" | sed 's/^/  /'

echo
echo "=== sandbox: $SB (preserved for inspection) ==="
