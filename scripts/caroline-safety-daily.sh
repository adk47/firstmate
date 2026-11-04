#!/usr/bin/env bash
# Caroline safety layer: DAILY red-team replay + injection/output-guard digest (caroline-guard-g1).
#
#   1. replays the red-team corpus against the DEPLOYED edge plugin (scripts/caroline-redteam.mjs: output guard +
#      inbound injection watch, the exact dist/ the gateway runs);
#   2. replays the injected-document cases against the doc-verify judge (scripts/caroline_redteam_docverify.py);
#   3. summarises the last 24 h of the shared ledger (scripts/injection-watch.py digest --write-candidates):
#      inbound injection hits by source/rule, output-guard blocks by rule, watch candidates for the fraud lens;
#   4. enforces ledger retention (RETENTION_DAYS = 30) by sealing the live file and deleting sealed generations that
#      are entirely older than the window - the ledger is the only place customer-derived text lives, so a run
#      that cannot enforce the bound PAGES rather than leaving old text at rest (s1 + QA on #1665);
#   5. writes the day's result to $STATE_DIR/<date>.json and posts the digest to #clio_devops.
# ANY failing case, a layer that cannot load, or fewer passing cases than yesterday PAGES (slack_notify_critical).
#
# Read-only against customers and core: it sends nothing to a customer, writes no core/Intercom state and calls no
# model. Constants, no env switches. Systemd: caroline-safety-daily.{service,timer} (scripts/install-aux-units.sh).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/hydra/caroline-redteam"
PLUGIN_DIR="/root/.openclaw-edge/extensions/intercom"
CLASSIFIER_HEALTH="http://127.0.0.1:18793/health"   # PromptGuard sidecar (safety-classifier.ts SAFETY_CLASSIFIER_URL)

# Test seams (bats): a positional override of the dirs, never an env switch.
[ "${1:-}" = "--state-dir" ] && { STATE_DIR="$2"; shift 2; }
[ "${1:-}" = "--plugin-dir" ] && { PLUGIN_DIR="$2"; shift 2; }
LEDGER="/var/lib/hydra/injection-watch/ledger.jsonl"   # default; a bats test overrides it, never an env switch
[ "${1:-}" = "--ledger" ] && { LEDGER="$2"; shift 2; }
NO_POST=0
[ "${1:-}" = "--no-post" ] && { NO_POST=1; shift; }

mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
today="$(date -u +%F)"
out="$STATE_DIR/$today.json"

pp="$(python3 "$HERE/injection-watch.py" prune --ledger "$LEDGER" 2>&1)"; pp_rc=$?
js="$(node "$HERE/caroline-redteam.mjs" --plugin-dir "$PLUGIN_DIR" 2>&1)"; js_rc=$?
py="$(python3 "$HERE/caroline_redteam_docverify.py" --corpus "$PLUGIN_DIR/redteam/caroline-redteam-cases.json" 2>&1)"; py_rc=$?
dg="$(python3 "$HERE/injection-watch.py" digest --hours 24 --write-candidates --ledger "$LEDGER" 2>&1)"; dg_rc=$?

# Fable s1: the classifier's silent absence must never read as "0 hits", so every digest states it.
if curl -fsS -m 3 -o /dev/null "$CLASSIFIER_HEALTH" 2>/dev/null; then classifier="available"; else classifier="unavailable"; fi

# Assemble the day's record (jq tolerates a layer that printed non-JSON: it is kept as a string).
asjson() { printf '%s' "$1" | jq -c . 2>/dev/null || jq -cn --arg s "$1" '$s'; }
jq -n --arg day "$today" --argjson js_rc "$js_rc" --argjson py_rc "$py_rc" --argjson dg_rc "$dg_rc" \
  --argjson pp_rc "$pp_rc" --argjson pp "$(asjson "$pp")" \
  --argjson js "$(asjson "$js")" --argjson py "$(asjson "$py")" --argjson dg "$(asjson "$dg")" \
  --arg classifier "$classifier" \
  '{day: $day, classifier: $classifier, caroline: $js, caroline_rc: $js_rc, docverify: $py, docverify_rc: $py_rc, digest: $dg, digest_rc: $dg_rc, retention: $pp, retention_rc: $pp_rc}' \
  > "$out.tmp" && mv "$out.tmp" "$out" && chmod 600 "$out" && jq -e 'type == "object"' "$out" >/dev/null 2>&1
record_rc=$?   # mandatory (QA on #1628): a run whose record was not written can never report green

passed() {  # passed <record-file>: passing cases across both layers (0 when unreadable)
  jq -r '[((.caroline.cases // 0) - (.caroline.failed // 0)), ((.docverify.cases // 0) - (.docverify.failed // 0))] | add' "$1" 2>/dev/null || echo 0
}
prev=""
for f in "$STATE_DIR"/*.json; do   # glob order is sorted; keep the latest day before today
  [ -f "$f" ] && [ "$f" != "$out" ] && prev="$f"
done
now_pass="$(passed "$out")"
prev_pass="$( [ -n "$prev" ] && passed "$prev" || echo 0)"

regress=""
[ "$record_rc" -ne 0 ] && regress+="day record $out could not be written (disk full / read-only / rename failed). "
[ "$js_rc" -ne 0 ] && regress+="caroline layer rc=$js_rc ($(jq -r 'if type=="object" then (.error // "\(.failed) case(s) failed: \(.failures|keys|join(", "))") else . end' <<<"$(asjson "$js")" | head -c 300)). "
[ "$py_rc" -ne 0 ] && regress+="doc-verify layer rc=$py_rc ($(jq -r 'if type=="object" then "\(.failed) case(s) failed: \(.failures|keys|join(", "))" else . end' <<<"$(asjson "$py")" | head -c 300)). "
[ "$now_pass" -lt "$prev_pass" ] && regress+="passing cases fell from $prev_pass to $now_pass. "
# The digest is part of the daily contract (QA on #1628): a digest that failed, or could not refresh the
# watch-candidates file, is a failed run, never a green one with stale data.
if [ "$dg_rc" -ne 0 ] || ! jq -e 'type == "object" and has("inbound")' <<<"$dg" >/dev/null 2>&1; then
  regress+="injection digest failed rc=$dg_rc ($(jq -r 'if type=="object" then (.candidates_error // "no candidates error") else . end' <<<"$(asjson "$dg")" | head -c 200)). "
fi

summary="$( [ "$record_rc" -eq 0 ] && jq -r '
  (.digest.classifier_unavailable) as $u
  | (.digest.classifier_calls) as $c
  | "Caroline safety daily \(.day): red-team \(((.caroline.cases // 0) - (.caroline.failed // 0)))/\(.caroline.cases // "?") (guard \(.caroline.guard_version // "?") \(.caroline.guard_mode // "?"), bank \(.caroline.bank_version // "?")), doc-verify \(((.docverify.cases // 0) - (.docverify.failed // 0)))/\(.docverify.cases // "?")."
  + "\nLast 24 h: inbound injection hit-turns \(.digest.inbound.turns // "?") \(.digest.inbound.by_severity // {} | tostring), by source \(.digest.inbound.by_source // {} | tostring); output guard blocked \(.digest.output_guard.blocked // "?") \(.digest.output_guard.by_rule // {} | tostring); paraphrased bank lines \(.digest.output_guard.notes // {} | tostring); "
  # The unavailable count is per-call DURABLE rows; calls comes from 15-min window rows, which can
  # count fewer (restart/idle gaps). Printing "123/117 calls" (read-back 2026-11-03) is arithmetic the
  # data cannot support, so the durable rows stay authoritative and no ratio is printed when they disagree.
  + (if ($u | type) != "number" then "classifier=\(.classifier) now, unavailable calls NOT REPORTED by the digest; "
     elif ($c | type) != "number" then "classifier=\(.classifier) now, unavailable \($u) call(s) in 24 h (per-call rows; the health windows reported no total); "
     elif $u > $c then "classifier=\(.classifier) now, unavailable on \($u) call(s) in 24 h (per-call rows are authoritative; the 15-min health windows counted only \($c), so no ratio is printed); "
     else "classifier=\(.classifier) now, unavailable \($u)/\($c) calls in 24 h; " end)
  + "watch candidates \(.digest.watch_candidates // [] | length)."
  + "\nLedger retention \(.retention.days // 30)d: \(.retention.files_dropped // 0) old generation(s) deleted (\(.retention.dropped // 0) row(s)), \(.retention.files_kept // "?") generation(s) kept holding \(.retention.kept // "?") row(s)."
  # A generation kept because somebody still holds its descriptor is normal (an append is in flight); one kept
  # because /proc could not be read is NOT -- the CLI exits 3 and the regress line below pages for it.
  + (if (.retention.held_open_files // 0) > 0 then " \\(.retention.held_open_files) generation(s) held open by a live writer: kept this run, deleted on a later one; " else "" end)
' "$out")" || { summary="Caroline safety daily $today: NO SUMMARY (day record unreadable)."; regress+="summary unreadable. "; }
# Retention (Fable s1 on #1665): the ledger holds masked customer text, so a prune that did not run is a privacy
# regression, not a cosmetic one. A missing ledger is not a failure (there is nothing to expire); a prune that could
# not take the shared writer lock, or hit a generation it could not read, is (QA on #1665).
if [ "$pp_rc" -ne 0 ]; then
  regress+="ledger RETENTION PRUNE FAILED rc=$pp_rc ($(jq -r 'if type=="object" then "?" else . end' <<<"$(asjson "$pp")" | head -c 200)): rows older than 30 days are still at rest. "
fi
# A prune that could not verify who holds a generation kept every candidate: retention was NOT enforced, and the
# difference between "nobody holds it" and "I could not check" must never be silent (QA on #1665, finding 3).
if jq -e '(.unverified_files // 0) > 0' <<<"$pp" >/dev/null 2>&1; then
  regress+="ledger retention UNVERIFIED ($(jq -r '.unverified_files' <<<"$pp") generation(s) could not be checked for live descriptors, so they were kept): retention NOT enforced. "
fi
# Ledger health (QA on #1628, extended by QA on #1665): the ledger being unwritable loses hits, and a generation we
# cannot READ is an unknown day, not a quiet one -- a HIGH hit that only exists in that file must page.
if jq -e '.ledger_writable == false' <<<"$dg" >/dev/null 2>&1; then
  regress+="injection ledger NOT WRITABLE OR NOT READABLE ($(jq -r '.ledger_error // "?"' <<<"$dg" | head -c 200)): hits are being lost or cannot be reviewed. "
fi

echo "$summary"
[ -n "$regress" ] && echo "REGRESSION: $regress"

if [ "$NO_POST" -eq 0 ]; then
  # shellcheck source=lib/slack-notify.sh
  source "$HERE/lib/slack-notify.sh"
  if [ -n "$regress" ]; then
    slack_notify_critical ":rotating_light: Caroline safety REGRESSION: ${regress}Record: $out\n$summary"
  else
    slack_notify ":shield: $summary"
  fi
fi
[ -n "$regress" ] && exit 1
exit 0
