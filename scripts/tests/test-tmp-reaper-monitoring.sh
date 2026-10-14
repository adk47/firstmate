#!/usr/bin/env bash
# Mutation battery for scripts/tmp-reaper.sh: the bats suite must pass on the
# real script and go RED on each safety mutation. Run: bash this-file
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../tmp-reaper.sh"
BATS_FILE="$HERE/tmp-reaper.bats"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
ln -s "$HERE/../lib" "$work/lib"  # the reaper sources lib/ beside itself
fail=0

run_suite() { TMP_REAPER_SCRIPT="$1" bats "$BATS_FILE" >"$work/out" 2>&1; }

run_suite "$SRC" && echo "PASS baseline: suite green on real script" \
  || { echo "FAIL baseline: suite red on real script"; tail -20 "$work/out"; fail=1; }

# mutate <label> <sed-expr>: apply to a scratch copy, require the suite to fail
mutate() {
  local label="$1" expr="$2" m="$work/mut.sh"
  sed -E "$expr" "$SRC" >"$m"; chmod +x "$m"
  if cmp -s "$SRC" "$m"; then echo "FAIL $label: mutation did not change the script"; fail=1; return; fi
  if run_suite "$m"; then echo "FAIL $label: suite stayed green (gate cannot fail)"; fail=1
  else echo "PASS $label: suite went red ($(grep -c '^not ok' "$work/out") failing)"; fi
}

mutate "widen dir regex to .*"        "s|^DEFAULT_DIR_RE=.*|DEFAULT_DIR_RE='.*'|"
mutate "drop open-handle check"       's|^  \[ -n "\$out" \] && return 0$|  false|'
mutate "lsof failure fails open"       's|^  if \[ -n "\$err" ] [|][|] \[ "\$rc" -gt 1 \]; then return 2; fi$|  :|'
mutate "ignore failed deletions"       's|^\[ "\$failures" -eq 0 \]$|true|'
mutate "mktemp failure fails open"      's|^  errf=\$\(mktemp\) [|][|] return 2$|  errf=$(mktemp)|'
mutate "file handle check back to +D" 's|lsof -t -- "\$1"|lsof -t +D "$1"|'
mutate "remove jest_0 exclusion"     '/\[ "\$name" = "jest_0" \] && continue/d'
mutate "drop 3h TTL to 0"             's|^SHORT_MIN=180|SHORT_MIN=0|'
mutate "drop 24h tmp.* TTL to 3h"     's|^LONG_MIN=1440|LONG_MIN=180|'

exit "$fail"
