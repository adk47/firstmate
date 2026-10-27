#!/usr/bin/env bash
# DAILY credit-status run (paid-wave-runner-p2; captain 2026-10-26 16:05Z "nothing sits silent").
# Every user with an open credit request who was never told its status (no core ask, no ledger message ever)
# gets the approved status copy: paid first, then free, oldest first, within the runner's daily caps
# (1,000 status notes per campaign/day, 400 asks/day; send-gateway 1/user/day). Runs on node-8 as root.
#
#   MODE=dry-run|apply   EMAIL_ROUTE=0|1   SEGMENTS="paid free"   ASKS=0|1   BIN=/opt/hydra/scripts/paid-status
#
# Per segment: population (silent_count.py) -> lens (Fable: watchlist/velocity/single-signal are APPROVAL holds;
# lens users get the ask only, LENS_ASK=1; Fable's named messaging holds stay held) -> segments -> support@
# (held only when a human answered in 7 days) -> classify -> lists -> Intercom route A / B0 / ask -> B0 or Copy A
# for users whose ask was skipped (b0_gap.py) -> email route (identity-refused / action_forbidden users) with the
# same B0 fallback. Every send passes the deployed gate or email_route.py's live checks. Kill switch:
# /etc/hydra/credit-ops-notes.disabled. Writes ids only, under /var/lib/hydra/paid-status/<day>/ (mode 700).
set -uo pipefail
export BIN="${BIN:-/opt/hydra/scripts/paid-status}"
EXCLUDE_CS="${EXCLUDE_CS:-/var/lib/hydra/paid-status/exclude-cs.txt}"  # ids cs already messaged (state, not repo)
HOLD_IDS="${HOLD_IDS:-/var/lib/hydra/paid-status/hold-user-ids.txt}"   # ids held from ANY message (e.g. firstmate 026, until Fable rules)
MODE="${MODE:-dry-run}"
EMAIL_ROUTE="${EMAIL_ROUTE:-1}"
EMAIL_MAX="${EMAIL_MAX:-300}"   # stack-swap-email-m2 warm-up ceiling for send-gateway credit_status_* (notify.), Tue 27; per call
SEGMENTS="${SEGMENTS:-paid free}"
DAY="$(date -u +%F)"
STATE_ROOT="${STATE_ROOT:-/var/lib/hydra/paid-status}"
BASE="$STATE_ROOT/$DAY"
RUNNER="${RUNNER:-/opt/hydra/scripts/credit-review.py}"
export LEDGER="${LEDGER:-/var/lib/hydra/credit-review/ledger.sqlite3}"
KILL_SWITCH="${KILL_SWITCH:-/etc/hydra/credit-ops-notes.disabled}"
CORE_NOTICE="${CORE_NOTICE:-/opt/hydra/scripts/credit_review/core_notice.py}"
MAIN_ENV="${MAIN_ENV:-/etc/openclaw/main.env}"
LOCK="$STATE_ROOT/daily.lock"
install -d -m 700 "$STATE_ROOT"
exec 9>"$LOCK"; flock -n 9 || { echo "$(date -u +%FT%TZ) another daily run holds $LOCK; exit"; exit 0; }
install -d -m 700 "$BASE"
# /etc/openclaw/main.env on node-8 (secrets; not in the repo).
set -a
# shellcheck source=/dev/null
. "$MAIN_ENV"
set +a
log() { echo "$(date -u +%FT%TZ) $*"; }
killed() { [ -e "$KILL_SWITCH" ] && { log "kill switch present: stop"; return 0; }; return 1; }
[ -s "$EXCLUDE_CS" ] || { echo "$(date -u +%FT%TZ) $EXCLUDE_CS missing: refusing to run (fail closed)"; exit 1; }
killed && exit 0
RUN_START="$(date -u +%Y-%m-%dT%H:%M)"
FAILED=0
log "silent count (start)"; python3 "$BIN/silent_count.py" "$BASE/silent-start" || exit 1

runner() { # <segment> <list> <campaign> [--wording W]
  local seg="$1" L="$2" C="$3"; shift 3
  [ -s "list-$L.json" ] || return 0
  killed && return 1
  local rc
  python3 "$RUNNER" uvn-status --list "list-$L.json" --segment "$seg" --campaign "$C" "$@" --mode dry-run --max-users 1000 \
    > "dry-$L.out" 2> "dry-$L.err"; rc=$?; log "$seg $L dry: $(cat "dry-$L.out")"
  # A failed run (QA on #1384) stops the whole daily run: never followed by a 'done'.
  [ "$rc" = 0 ] || { log "$seg $L dry FAILED rc=$rc: stop"; FAILED=1; return 1; }
  if [ "$MODE" = "apply" ]; then
    python3 "$RUNNER" uvn-status --list "list-$L.json" --segment "$seg" --campaign "$C" "$@" --mode apply --max-users 1000 \
      > "apply-$L.out" 2> "apply-$L.err"; rc=$?; log "$seg $L apply: $(cat "apply-$L.out")"
    health || { FAILED=1; return 1; }
    [ "$rc" = 0 ] || { log "$seg $L apply FAILED rc=$rc: stop"; FAILED=1; return 1; }
  fi
}

# Warm-up guardrail (firstmate 014): after every apply, re-read every Intercom contact messaged since this run
# started; stop the whole run on bounce > 2%, any spam complaint, unsubscribes > 1%, or an unreadable check
# (fail closed; health_check.py exit 3 / 2).
health() {
  local out rc
  out="$(python3 "$BIN/health_check.py" --since "$RUN_START")"; rc=$?
  log "health: $out"
  if [ "$rc" != 0 ]; then log "HEALTH STOP (rc=$rc): $out"; touch "$BASE/HEALTH-STOP"; return 1; fi
  return 0
}

email() { # <lists-file> <tag>
  local f="$1" tag="$2" plan
  [ "$EMAIL_ROUTE" = "1" ] && [ -s "$f" ] || return 0
  killed && return 1
  local rc
  plan="$(python3 "$BIN/email_route.py" --lists "$f" --mode dry-run --out "$W/email-$tag" | head -1)"
  [ -s "$plan" ] || { log "email $tag dry FAILED (no plan): stop"; FAILED=1; return 1; }
  log "email $tag dry: $plan $(python3 -c 'import json,sys,collections; print(dict(collections.Counter(r["decision"] for r in json.load(open(sys.argv[1]))["rows"])))' "$plan")"
  if [ "$MODE" = "apply" ]; then
    if [ "${ASKS:-0}" != 1 ]; then  # firstmate 024: never send the ask copy (credit_status_uvn_ask) by email either
      python3 - "$plan" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
n = sum(1 for r in d["rows"] if r["campaign"] == "uvn-status" and r["decision"] == "send")
d["rows"] = [r for r in d["rows"] if r["campaign"] != "uvn-status"]
json.dump(d, open(sys.argv[1] + ".no-asks.json", "w"))
print(f"asks removed from the approved send set: {n}", file=sys.stderr)
PY
      plan="$plan.no-asks.json"
    fi
    python3 "$BIN/email_route.py" --lists "$f" --mode apply --approved "$plan" --out "$W/email-$tag" --pace 2 \
      --max-users "${EMAIL_MAX:-300}" > "$W/email-$tag.apply.out" 2>&1; rc=$?
    tail -2 "$W/email-$tag.apply.out"
    health || { FAILED=1; return 1; }
    [ "$rc" = 0 ] || { log "email $tag apply FAILED rc=$rc: stop"; FAILED=1; return 1; }
  fi
  EMAIL_PLAN="$plan"
}

for SEG in $SEGMENTS; do
  W="$BASE/$SEG"; install -d -m 700 "$W" "$W/cls"; cd "$W" || exit 1
  export PWR_DIR="$W" SEGMENT="$SEG" POP_FILE="$W/pop.txt" LENS_ASK=1
  cp "$BASE/silent-start/silent-$SEG.txt" "$W/pop.txt"; cat "$EXCLUDE_CS" > "$W/exclude-cs.txt"; [ -f "$HOLD_IDS" ] && cat "$HOLD_IDS" >> "$W/exclude-cs.txt"
  log "$SEG population $(wc -l < pop.txt)"
  # Derived lists of an earlier run today (same dir) are never re-sent (QA on #1384).
  rm -f "$W"/list-*.json "$W"/email-lists*.json "$W"/cls/dry-run-*.json
  # A preprocessing failure skips the segment AND fails the run (QA on #1384): cron never reads 'done'.
  python3 "$BIN/fraud_lens.py" "$W" > lens.out || { log "$SEG lens failed"; FAILED=1; continue; }
  python3 "$BIN/segment.py" > segment.out || { log "$SEG segment failed"; FAILED=1; continue; }
  python3 "$BIN/support7d.py" > support.out || { log "$SEG support@ check failed: segment skipped (fail closed)"; FAILED=1; continue; }
  python3 - <<'PY' || { log "$SEG candidate list failed"; FAILED=1; continue; }
import json, os
D = os.environ["PWR_DIR"]
s = json.load(open(f"{D}/segments.json"))
held = {r["user_id"] for r in json.load(open(f"{D}/support7d.json")) if r.get("human_7d") or r.get("error")}
open(f"{D}/support-held-17.txt", "w").write("".join(f"{u}\n" for u in sorted(held)))
cand = [r["user_id"] for r in s if not r["msg_hold"] and not r["lens_held"] and not r["cs_excluded"] and r["user_id"] not in held]
open(f"{D}/cand.txt", "w").write("".join(f"{u}\n" for u in cand))
print("support held", len(held), "candidates", len(cand))
PY
  # Core's own notices (Fable sender map 2026-10-27 item 2): core told a candidate something within 7 days, or
  # changed a request today -> not a candidate this run (core_notice_within_7d). Unreadable: segment skipped.
  python3 "$CORE_NOTICE" batch --users-file "$W/cand.txt" --out "$W/core-notice-held.txt" > core-notice.out \
    || { log "$SEG core notice check failed: segment skipped (fail closed)"; FAILED=1; continue; }
  grep -vxFf "$W/core-notice-held.txt" "$W/cand.txt" > "$W/cand-clear.txt" || true
  log "$SEG core_notice_within_7d held $(grep -c . "$W/core-notice-held.txt") of $(grep -c . "$W/cand.txt") candidates"
  python3 "$BIN/classify2.py" --users "$W/cand-clear.txt" --out-dir "$W/cls" > classify.out || { log "$SEG classify failed"; FAILED=1; continue; }
  python3 "$BIN/build_lists.py" > lists.out || { log "$SEG build_lists failed"; FAILED=1; continue; }
  log "$SEG lists: $(cat lists.out)"
  runner "$SEG" A status-doc-received --wording queued || break
  runner "$SEG" B status-team-review --wording no-ask || break
  # captain 2026-10-27 01:0xZ (firstmate 024): NO proof ask offering documents until a returned document can be
  # accepted. The uvn ask runs only with ASKS=1 (set it only after an explicit captain/firstmate GO).
  if [ "${ASKS:-0}" = 1 ]; then runner "$SEG" U uvn-status || break; fi
  # users whose ask was skipped (documents on file / rows closed) get B0, or Copy A with a pending document
  # b0_gap picks ask-list users the ledger never messaged, which means "ask skipped" ONLY when the ask step ran.
  # With asks off (firstmate 024) it would label every UVN user "nothing else is needed" (2026-10-27 01:18Z incident,
  # stopped before any send). So it runs only with ASKS=1.
  if [ "${ASKS:-0}" = 1 ]; then
    python3 "$BIN/b0_gap.py" > b0gap.out || { log "$SEG b0_gap failed"; FAILED=1; break; }
    log "$SEG b0_gap: $(tr -d '\n' < b0gap.out)"
    runner "$SEG" B2 status-team-review --wording no-ask || break
    runner "$SEG" A3 status-doc-received --wording queued || break
  fi
  # email route: users the Intercom gate cannot reach (identity refusal / action_forbidden)
  EMAIL_PLAN=""; email email-lists.json main || break
  # Same B0 fallback for ask-list users whose ask is skipped - ONLY when asks run (ASKS=1): "already noted" on the
  # ask list also covers asks the gate REFUSED (terminal identity refusals close the rows), which were never
  # delivered (2026-10-26: 30 such users got B0 by email while owing proof; firstmate 025/026).
  if [ -n "$EMAIL_PLAN" ] && [ "${ASKS:-0}" = 1 ]; then
    python3 - "$EMAIL_PLAN" <<'PY'
import importlib.util, json, os, sqlite3, sys
D = os.environ["PWR_DIR"]
spec = importlib.util.spec_from_file_location("b0_gap", os.path.join(os.environ["BIN"], "b0_gap.py"))
b0 = importlib.util.module_from_spec(spec); spec.loader.exec_module(b0)
db = sqlite3.connect("file:" + os.environ["LEDGER"] + "?mode=ro", uri=True)
seg = {r["user_id"]: r for r in json.load(open(f"{D}/segments.json"))}
rows = json.load(open(sys.argv[1]))["rows"]
rows = [r for r in rows if not b0.ask_never_delivered(db, "", int(r["user_id"]))]  # by account id (no email here)
out = [{"user_id": r["user_id"], "request_ids": []} for r in rows
       if r["campaign"] == "uvn-status" and r["decision"] == "skip"
       and r["why"].split(":")[0] in ("already noted (ledger)", "documents on file (proof-on-file)")
       and not (seg.get(r["user_id"], {}).get("ask_only") and r["why"].startswith("already noted"))]
json.dump({"status-team-review": out} if out else {}, open(f"{D}/email-lists-b0.json", "w"))
print(len(out))
PY
    email email-lists-b0.json b0 || break
  fi
done
cd "$BASE" || exit 1
sqlite3 -readonly "$LEDGER" \
  "select distinct account_id from verify_messages where day='$DAY' and status in ('sent','attempted') and account_id is not null order by 1" \
  > "$BASE/messaged-$DAY.user-ids"
python3 "$BIN/silent_count.py" "$BASE/silent-end" > "$BASE/silent-end.json"
[ "${FAILED:-0}" = 1 ] && verb="STOPPED (a send failed; see above)" || verb="done"
log "$verb: $(wc -l < "$BASE/messaged-$DAY.user-ids") users messaged today (all lanes); silent now: $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print({k: v["silent_never_messaged_ever"] for k, v in d.items()})' "$BASE/silent-end.json")"
[ "${FAILED:-0}" = 1 ] && exit 1
exit 0
