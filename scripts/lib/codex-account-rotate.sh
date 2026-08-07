#!/usr/bin/env bash
# codex-account-rotate.sh — switch the fleet's ACTIVE codex (ChatGPT OAuth)
# subscription and load it: state file → auth re-sync → drain-restart → page.
#
# WHY: sol/luna are two MODEL VARIANTS on one subscription, so the model-level
# fallback chain can never express "try the other account" — when the active
# subscription hits its usage cap the whole codex surface dies at once and the
# fleet rides the PAID OpenRouter rung while the standby subscription idles
# (2026-07-21 incident). Account failover therefore happens HERE, at the auth
# layer; the model chain stays the final safety net for "both accounts capped".
#
# Usage:
#   codex-account-rotate.sh --to <email|openai-codex:email> [--force] [--reason "…"]
#   codex-account-rotate.sh --auto [--force] [--allow-unmeasured] [--reason "…"]
#     --auto picks the EMPTIEST candidate whose quota we have MEASURED as
#     healthy (see codex-quota.sh). It refuses rather than guess: rc 7 when
#     every alternate is measured capped, rc 8 when none has a fresh
#     measurement. --allow-unmeasured permits an UNKNOWN target (the page then
#     says the target was unverified); only --force will select one we
#     measured as capped.
#
# Sequence (fail-loud at every step):
#   1. validate the target against the canonical auth store (must exist AND
#      hold an access token — syncing an empty identity would break every
#      runtime store at once)
#   2. cooldown gate (default 120 min; --force bypasses) — bounds cap-flap
#      ping-pong when BOTH accounts are capped to one restart pair per window
#   3. persist to the state file (survives deploys — codex-auth-sync.sh
#      re-resolves it on every heal/refresh, so nothing can silently revert)
#   4. codex-auth-sync.sh fans the new identity + access token to every
#      runtime store; on FAILURE the state file is RESTORED (a state file
#      pointing at an unsyncable profile would poison every later heal)
#   5. drain-restart both gateways (the gateway only loads auth at startup)
#   6. page #clio_devops
#
# Exit codes: 0 rotated (or already-active no-op) · 2 usage/structural error
#   · 3 cooldown refusal · 4 no alternate account · 5 sync failed (state
#   restored, stores untouched) · 6 gateway restart failed (stores converged;
#   token loads on the next successful start; watchdog owns the down-gateway page)
#   · 7 every alternate is MEASURED capped · 8 no alternate has a fresh
#     measurement (quota UNKNOWN — distinct from 7, see below)
#
# WHY 7 AND 8 ARE DIFFERENT (incident 2026-08-06): "we measured it and it is
# capped" and "we could not measure it" are different facts that demand
# different human responses, and collapsing them is how the fleet was rotated
# onto an exhausted account. The old target gate asked cu_row_capped_until
# "is this account capped until some future time?" — a 13-day-old archived row
# whose reset had already lapsed answered "no", the caller read that as
# "healthy", and the rotation landed on an account that capped again within
# hours. cq_row_state replaces that boolean with capped|healthy|unknown, and
# --auto now REFUSES an unknown target (rc 8) unless --allow-unmeasured says
# the operator accepts the risk.
#
# Invoked by codex-keepalive.sh (--auto, on the usage-cap journal signature)
# and by humans (RUNBOOK §"Codex Usage Cap / Account Rotation"). Tested by
# scripts/tests/codex-account-rotate.bats.
set -euo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGPREFIX="[codex-account-rotate $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*" >&2; }

# shellcheck source=codex-active-account.sh
source "$_DIR/codex-active-account.sh"
# Pure snapshot/quota helpers (cu_collect_rollouts, cu_latest_rate_limits,
# cu_archive_*, cu_row_capped_until) — no side effects at source time.
# shellcheck source=codex-usage.sh
source "$_DIR/codex-usage.sh"
# Pure MEASURED-quota helpers (cq_measure_read, cq_row_state, cq_row_load,
# cq_ledger_append, cq_format_evidence) — no side effects at source time.
# shellcheck source=codex-quota.sh
source "$_DIR/codex-quota.sh"
if [ -r "$_DIR/slack-notify.sh" ]; then
  # shellcheck source=slack-notify.sh
  source "$_DIR/slack-notify.sh"
fi
_page() { declare -F slack_notify >/dev/null && slack_notify "[codex-account-rotate] $1" || true; }
_page_critical() { declare -F slack_notify_critical >/dev/null && slack_notify_critical "[codex-account-rotate] $1" || true; }

CODEX_AUTH_ROOT="${CODEX_AUTH_ROOT:-/root}"
CANON_DIR="${CANON_DIR:-${CODEX_AUTH_ROOT}/.openclaw-main/agents/main/agent}"
CANON_PROFILES="$CANON_DIR/auth-profiles.json"
CODEX_ROTATE_SYNC_BIN="${CODEX_ROTATE_SYNC_BIN:-$_DIR/codex-auth-sync.sh}"
CODEX_ROTATE_SERVICES="${CODEX_ROTATE_SERVICES:-openclaw-gateway-main.service openclaw-gateway-edge.service}"
CODEX_ROTATE_COOLDOWN_MIN="${CODEX_ROTATE_COOLDOWN_MIN:-120}"
CODEX_ROTATE_STAMP="${CODEX_ROTATE_STAMP:-/var/lib/hydra/codex-account-rotate.last}"
CODEX_ROTATE_RESTART="${CODEX_ROTATE_RESTART:-1}"
# A rotation target's token must be valid at least this many minutes into the
# future — rotating onto a lapsed standby (refresh timer failing for days)
# would restart the fleet straight into a token_expired storm while this
# script reports a successful recovery.
CODEX_ROTATE_MIN_TOKEN_MIN="${CODEX_ROTATE_MIN_TOKEN_MIN:-10}"
# Per-account snapshot archive: the outgoing account's freshest quota snapshot
# is stashed here at rotation time (rollouts are account-blind on 7.x, so this
# is the only per-account quota knowledge). --auto consults the TARGET's
# archive and refuses (rc 7) a standby whose known quota is still capped —
# rotating onto it would buy nothing but a drain-restart pair.
CODEX_USAGE_ARCHIVE_DIR="${CODEX_USAGE_ARCHIVE_DIR:-/var/lib/hydra/codex-usage}"
CODEX_ROTATE_TARGET_MAX_PCT="${CODEX_ROTATE_TARGET_MAX_PCT:-95}"
CODEX_ROTATE_LOOKBACK_HOURS="${CODEX_ROTATE_LOOKBACK_HOURS:-48}"
# Append-only active-account ledger — see codex-quota.sh. Lets a later rollout
# snapshot be attributed to whoever was ACTUALLY active when it was emitted,
# instead of to whoever is active now (the misattribution that put one
# subscription's numbers under three account names on 2026-08-06).
CODEX_ACTIVE_LEDGER="${CODEX_ACTIVE_LEDGER:-$CODEX_USAGE_ARCHIVE_DIR/active-account.log}"

TARGET="" AUTO=0 FORCE=0 REASON="manual" ALLOW_UNMEASURED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --to)     shift; TARGET="${1:-}"; [ -n "$TARGET" ] || { log "ERROR: --to needs a value"; exit 2; } ;;
    --auto)   AUTO=1 ;;
    --force)  FORCE=1 ;;
    # Accept a target we could not measure. The emergency path: when the active
    # account is dead and nothing has a fresh reading, refusing would strand the
    # fleet on the paid rung while a healthy standby idles (the failure this
    # whole subsystem exists to prevent) — but the page must SAY the target was
    # unmeasured rather than implying it was verified healthy.
    --allow-unmeasured) ALLOW_UNMEASURED=1 ;;
    --reason) shift; REASON="${1:-manual}" ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) log "ERROR: unknown argument: $1 (use --to/--auto/--force/--allow-unmeasured/--reason)"; exit 2 ;;
  esac
  shift
done
if [ "$AUTO" -eq 0 ] && [ -z "$TARGET" ]; then
  log "ERROR: need --to <account> or --auto"; exit 2
fi
if [ "$AUTO" -eq 1 ] && [ -n "$TARGET" ]; then
  log "ERROR: --to and --auto are mutually exclusive"; exit 2
fi

command -v jq >/dev/null 2>&1 || { log "ERROR: jq not found"; exit 2; }
[ -r "$CANON_PROFILES" ] || { log "ERROR: canonical store not readable: $CANON_PROFILES"; exit 2; }

# Same precedence as codex-auth-sync.sh: env override, then state file, then
# the baked default — "current" must mean what the next sync would enforce.
CURRENT="${CODEX_AUTH_PRIMARY:-$(caa_active_key "$CANON_PROFILES")}"

# The minimum acceptable token expiry for a rotation target (epoch ms).
MIN_EXP_MS=$(( ( $(date +%s) + CODEX_ROTATE_MIN_TOKEN_MIN * 60 ) * 1000 ))

if [ "$AUTO" -eq 1 ]; then
  # Structurally usable candidates: an access token must be present and its
  # expiry safely in the future — a candidate failing either is skipped, so
  # --auto lands on rc 4 instead of rotating onto a dead credential.
  CANDIDATES=()
  while IFS= read -r _k; do
    [ -n "$_k" ] && CANDIDATES+=("$_k")
  done < <(jq -r --arg cur "$CURRENT" --argjson minexp "$MIN_EXP_MS" '
      .profiles | to_entries[]
      | select(.key | startswith("openai-codex:"))
      | select(.key != $cur)
      | select((.value.access // "") != "")
      | select(((.value.expires // 0) | (tonumber? // 0)) > $minexp)
      | .key' \
      "$CANON_PROFILES" 2>/dev/null)

  if [ "${#CANDIDATES[@]}" -eq 0 ]; then
    log "no VIABLE alternate openai-codex profile in canonical (current: $CURRENT; candidates lacking an access token or with an expired/expiring token are skipped) — nothing to rotate to; run codex-oauth-refresh.sh / device-code re-auth for the standby"
    exit 4
  fi

  # Pick the EMPTIEST measured-healthy candidate, not merely the first one in
  # canonical's key order. "First viable" was a coin flip that could land on a
  # 97%-used account while a 0% one sat next to it — with a drain-restart pair
  # as the cost of finding out.
  _NOW="$(date +%s)"
  BEST="" BEST_LOAD="" SEEN_UNKNOWN=0
  for _k in "${CANDIDATES[@]}"; do
    _row="$(cq_measure_read "$CODEX_USAGE_ARCHIVE_DIR" "$_k" 2>/dev/null || true)"
    _state="$(cq_row_state "$_row" "$CODEX_ROTATE_TARGET_MAX_PCT" "$CQ_MEASURE_MAX_AGE_MIN" "$_NOW")"
    case "$_state" in
      capped)   log "candidate $_k: $(cq_format_evidence "$_k" "$_row" "$_NOW")" ;;
      unknown) SEEN_UNKNOWN=1; log "candidate $_k: $(cq_format_evidence "$_k" "$_row" "$_NOW")" ;;
      healthy)
        _load="$(cq_row_load "$_row" "$_NOW")" || _load=""
        log "candidate $_k: $(cq_format_evidence "$_k" "$_row" "$_NOW")"
        if [ -n "$_load" ] && { [ -z "$BEST_LOAD" ] || awk -v a="$_load" -v b="$BEST_LOAD" 'BEGIN{exit !(a+0 < b+0)}'; }; then
          BEST="$_k"; BEST_LOAD="$_load"
        fi ;;
    esac
  done

  if [ -n "$BEST" ]; then
    TARGET="$BEST"
    log "auto target: $TARGET (lowest measured load: ${BEST_LOAD}%)"
  elif { [ "$ALLOW_UNMEASURED" -eq 1 ] || [ "$FORCE" -eq 1 ]; } && _CQ_UNKNOWN="$(
      for _k in "${CANDIDATES[@]}"; do
        _row="$(cq_measure_read "$CODEX_USAGE_ARCHIVE_DIR" "$_k" 2>/dev/null || true)"
        if [ "$(cq_row_state "$_row" "$CODEX_ROTATE_TARGET_MAX_PCT" "$CQ_MEASURE_MAX_AGE_MIN" "$_NOW")" = unknown ]; then
          printf '%s' "$_k"; break
        fi
      done
    )" && [ -n "$_CQ_UNKNOWN" ]; then
    # --allow-unmeasured means "I accept a target we could not MEASURE". It does
    # NOT mean "I accept a target we measured and know is capped" — those are
    # different risks and only --force may take the second.
    #
    # This distinction is load-bearing: codex-keepalive.sh adds
    # --allow-unmeasured whenever the ACTIVE account measures capped. If this
    # branch could also select a known-capped alternate, then "active capped +
    # every alternate capped" would drain-restart both gateways onto another
    # spent account, exit 0, and thereby SUPPRESS the rc 7 "every alternate is
    # measured CAPPED" page — turning an honest degradation into a silent
    # restart loop. With no unknown candidate we fall through to rc 7/rc 8.
    TARGET="$_CQ_UNKNOWN"
    UNMEASURED_TARGET=1
    log "auto target: $TARGET — no measured-healthy candidate; this one is UNMEASURED, proceeding (--allow-unmeasured/--force)"
  elif [ "$FORCE" -eq 1 ]; then
    # --force only: the operator accepts a MEASURED-capped target. Pick the
    # least-loaded (soonest to recover) and label it accurately — never as
    # "unmeasured", which would tell them we know less than we do.
    for _k in "${CANDIDATES[@]}"; do
      _row="$(cq_measure_read "$CODEX_USAGE_ARCHIVE_DIR" "$_k" 2>/dev/null || true)"
      _load="$(cq_row_load "$_row" "$_NOW")" || _load=""
      [ -n "$_load" ] || continue
      if [ -z "$BEST_LOAD" ] || awk -v a="$_load" -v b="$BEST_LOAD" 'BEGIN{exit !(a+0 < b+0)}'; then
        TARGET="$_k"; BEST_LOAD="$_load"
      fi
    done
    [ -n "$TARGET" ] || TARGET="${CANDIDATES[0]}"
    log "auto target: $TARGET — every candidate is MEASURED capped; --force selecting the least-loaded (${BEST_LOAD:-unknown}%)"
  elif [ "$SEEN_UNKNOWN" -eq 1 ]; then
    # rc 8, NOT rc 7: we do not know these accounts are capped, only that we
    # cannot see them. Reporting that as "capped" is the false claim this
    # subsystem was rebuilt to make impossible.
    log "no alternate has a FRESH measurement (current: $CURRENT) — refusing to rotate onto an unverified account; run scripts/codex-quota-refresh.sh or pass --allow-unmeasured"
    exit 8
  else
    log "every alternate is MEASURED capped (>= ${CODEX_ROTATE_TARGET_MAX_PCT}%) — refusing; the fleet rides the OpenRouter fallback rung until a window resets (--to/--force to override)"
    exit 7
  fi
fi
UNMEASURED_TARGET="${UNMEASURED_TARGET:-0}"

# Accept a bare email for humans; profile keys pass through untouched.
case "$TARGET" in
  openai-codex:*) : ;;
  *) TARGET="openai-codex:$TARGET" ;;
esac

jq -e --arg k "$TARGET" '.profiles[$k] != null' "$CANON_PROFILES" >/dev/null 2>&1 \
  || { log "ERROR: target '$TARGET' is not a profile in $CANON_PROFILES"; exit 2; }
jq -e --arg k "$TARGET" '(.profiles[$k].access // "") != ""' "$CANON_PROFILES" >/dev/null 2>&1 \
  || { log "ERROR: target '$TARGET' has no access token in canonical — run codex-oauth-refresh.sh (or device-code re-auth) first"; exit 2; }
jq -e --arg k "$TARGET" --argjson minexp "$MIN_EXP_MS" \
    '((.profiles[$k].expires // 0) | (tonumber? // 0)) > $minexp' \
    "$CANON_PROFILES" >/dev/null 2>&1 \
  || { log "ERROR: target '$TARGET' token is expired or expires within ${CODEX_ROTATE_MIN_TOKEN_MIN}min — rotating onto it would 401 the fleet; run codex-oauth-refresh.sh first"; exit 2; }

if [ "$TARGET" = "$CURRENT" ]; then
  log "no-op: $TARGET is already the active account"
  exit 0
fi

# Explicit --to target-quota viability. (--auto already chose the emptiest
# MEASURED-healthy candidate above, so this only guards a hand-picked target.)
# A human naming an account we measured as capped is almost always acting on
# stale knowledge — refuse once, and let --force say "I know, do it anyway"
# (e.g. right after a plan upgrade, when our reading is stale in their favour).
# The two flags mean the same thing here as in --auto, and the quota check is
# ALWAYS computed. Gating the whole block on `ALLOW_UNMEASURED -ne 1` let
# `--to <acct> --allow-unmeasured` skip the capped rejection entirely and
# drain-restart both gateways onto a known-spent account — the same conflation
# that was just fixed in auto mode, and without the --force acknowledgement the
# comment above promises.
if [ "$AUTO" -eq 0 ]; then
  TARGET_ROW="$(cq_measure_read "$CODEX_USAGE_ARCHIVE_DIR" "$TARGET" 2>/dev/null || true)"
  TARGET_STATE="$(cq_row_state "$TARGET_ROW" "$CODEX_ROTATE_TARGET_MAX_PCT")"
  case "$TARGET_STATE" in
    capped)
      # A human naming an account we measured as capped is almost always acting
      # on stale knowledge — refuse once, and let --force say "I know, do it
      # anyway" (e.g. right after a plan upgrade, when our reading is stale in
      # their favour). --allow-unmeasured is NOT that acknowledgement.
      if [ "$FORCE" -ne 1 ]; then
        log "target '$TARGET' is MEASURED capped — $(cq_format_evidence "$TARGET" "$TARGET_ROW") — refusing (--force to override; --allow-unmeasured does NOT cover a measured cap)"
        exit 7
      fi
      log "target '$TARGET' is MEASURED capped — proceeding on --force"
      ;;
    unknown)
      # Deliberately NOT a refusal on this path. --auto is machine-driven, so
      # demanding a flag there costs nothing and stops the actuator guessing;
      # --to is the HUMAN override, and a human naming an account is asserting
      # knowledge the collector does not have (they just re-authed it, they can
      # see the dashboard). Refusing here would put an extra flag between an
      # operator and the recovery command the RUNBOOK tells them to run, during
      # the incident it exists for.
      #
      # What we do NOT do is let it pass silently: the target is marked
      # unmeasured so the success page says the quota was unverified rather
      # than implying we checked it. That is the property that actually
      # mattered on 2026-08-06 — the claim, not the gate.
      UNMEASURED_TARGET=1
      log "target '$TARGET' has no fresh measurement — proceeding on an explicit --to; the page will say the target was UNVERIFIED"
      ;;
  esac
fi

# Cooldown gate — bounds both-accounts-capped flapping to one restart pair
# per window. The keepalive interprets rc=3 as "both capped" and pages.
if [ "$FORCE" -ne 1 ] && [ -r "$CODEX_ROTATE_STAMP" ]; then
  last="$(cat "$CODEX_ROTATE_STAMP" 2>/dev/null || echo 0)"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  now="$(date +%s)"
  # A stamp in the FUTURE would make (now - last) negative, which satisfies the
  # -lt below and refuses EVERY rotation until wall time catches up — a clock
  # rollback would silently disable account failover. Treat it as no stamp.
  [ "$last" -le "$now" ] || last=0
  if [ $(( now - last )) -lt $(( CODEX_ROTATE_COOLDOWN_MIN * 60 )) ]; then
    log "cooldown: last rotation $(( (now - last) / 60 ))min ago (< ${CODEX_ROTATE_COOLDOWN_MIN}min) — refusing (--force to override). If a cap signature is still live, BOTH accounts are likely capped and the fleet rides the OpenRouter fallback rung."
    exit 3
  fi
fi

# Archive the OUTGOING account's freshest quota snapshot (best-effort): once
# it goes standby no new snapshots will be attributable to it, and its
# `resets_at` is exactly what a later --auto needs to know whether rotating
# BACK is viable.
ROLLOUTS=()
while IFS= read -r _f; do
  [ -n "$_f" ] && ROLLOUTS+=("$_f")
done < <(cu_collect_rollouts "$CODEX_AUTH_ROOT" "$CODEX_ROTATE_LOOKBACK_HOURS")
if [ "${#ROLLOUTS[@]}" -gt 0 ]; then
  SNAP_ROW="$(cu_latest_rate_limits "${ROLLOUTS[@]}")"
  # Rotation-boundary guard (same boundary the report/keepalive use): the
  # freshest snapshot is only $CURRENT's if it was emitted AFTER $CURRENT
  # became active (= the last rotation stamp). After A→B then a quick B→A
  # before B ever emits a rollout, the freshest row is still A's — archiving
  # it under B would later make --auto refuse a perfectly fresh B (rc 7).
  if [ -n "$SNAP_ROW" ] && [ -r "$CODEX_ROTATE_STAMP" ]; then
    SNAP_TS="$(printf '%s' "$SNAP_ROW" | cut -f1)"
    LAST_ROT="$(head -n1 "$CODEX_ROTATE_STAMP" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$SNAP_TS" =~ ^[0-9]+$ ]] && [[ "$LAST_ROT" =~ ^[0-9]+$ ]] && [ "$SNAP_TS" -lt "$LAST_ROT" ]; then
      log "skipping archive for $CURRENT: freshest snapshot predates this account's activation (snapshot may belong to the previously active account)"
      SNAP_ROW=""
    fi
  fi
  if [ -n "$SNAP_ROW" ]; then
    if cu_archive_write "$CODEX_USAGE_ARCHIVE_DIR" "$CURRENT" "$SNAP_ROW"; then
      log "archived outgoing account's snapshot for $CURRENT"
    else
      log "WARN: could not archive snapshot for $CURRENT"
    fi
  fi
fi

# Persist — keeping the previous content for rollback on sync failure.
PREV_STATE=""
if [ -r "$CODEX_ACTIVE_ACCOUNT_FILE" ]; then
  PREV_STATE="$(head -n1 "$CODEX_ACTIVE_ACCOUNT_FILE" 2>/dev/null | tr -d '[:space:]')" || PREV_STATE=""
fi
caa_write_active "$TARGET" || { log "ERROR: could not write $CODEX_ACTIVE_ACCOUNT_FILE"; exit 2; }
log "state: active account $CURRENT → $TARGET (reason: $REASON)"

# Fan the new identity + access token out to every runtime store. The sync is
# invoked with an EXPLICIT CODEX_AUTH_PRIMARY: an inherited env override from
# the caller's shell would otherwise pin the sync to the OLD account (env wins
# inside the sync) — stores stay old, sync exits 0, and the success page lies.
SYNC_RC=0
CODEX_AUTH_PRIMARY="$TARGET" "$CODEX_ROTATE_SYNC_BIN" || SYNC_RC=$?
if [ "$SYNC_RC" -ne 0 ]; then
  # The sync is NOT transactional (it converges surface-by-surface and reports
  # failure at the end) — a mid-run failure can leave a MIX of old and new
  # credentials across the runtime stores. Restore the state file, then run a
  # COMPENSATING sync to re-converge the already-written surfaces. The
  # compensation pins $CURRENT — the EFFECTIVE pre-rotation account — not
  # $PREV_STATE: when an env override (or the baked default with no state
  # file) selected the running account, the file's old content is not what
  # the fleet was actually on. Best-effort — if that fails too, the page
  # below is the escalation and ensure-codex-auth/the watchdog own follow-up.
  # State restoration is PART of the rollback result: a swallowed failure here
  # would leave the file naming $TARGET while the logs/page claim it was
  # restored — the next heal would then flip the fleet again. Both shapes are
  # guarded (|| …=0) so a failure can never set -e-abort past the compensating
  # sync and the page.
  RESTORE_OK=1
  if [ -n "$PREV_STATE" ]; then
    caa_write_active "$PREV_STATE" || RESTORE_OK=0
  else
    rm -f "$CODEX_ACTIVE_ACCOUNT_FILE" || RESTORE_OK=0
  fi
  COMP_RC=0
  CODEX_AUTH_PRIMARY="$CURRENT" "$CODEX_ROTATE_SYNC_BIN" || COMP_RC=$?
  RESTORE_NOTE="state file restored to '${PREV_STATE:-<absent>}'"
  [ "$RESTORE_OK" -eq 1 ] || RESTORE_NOTE="state file restore FAILED — it may still name '$TARGET'; fix $CODEX_ACTIVE_ACCOUNT_FILE manually or the next heal flips the fleet again"
  if [ "$COMP_RC" -eq 0 ]; then
    log "ERROR: codex-auth-sync failed (rc=$SYNC_RC) — $RESTORE_NOTE; a compensating sync re-converged the runtime stores to the pre-rotation account ($CURRENT)"
  else
    log "ERROR: codex-auth-sync failed (rc=$SYNC_RC) AND the compensating sync failed (rc=$COMP_RC) — $RESTORE_NOTE; runtime stores may hold a MIX of accounts; run codex-auth-sync.sh manually"
  fi
  _page_critical ":rotating_light: codex account rotation to \`$TARGET\` FAILED at auth sync (rc=$SYNC_RC) — $( [ "$RESTORE_OK" -eq 1 ] && echo "state file restored to \`${PREV_STATE:-default}\`" || echo "state file restore FAILED (may still name \`$TARGET\` — fix \`$CODEX_ACTIVE_ACCOUNT_FILE\` NOW or the next heal re-flips the fleet)" ); compensating sync $( [ "$COMP_RC" -eq 0 ] && echo "re-converged the stores to \`$CURRENT\`" || echo "ALSO FAILED (rc=$COMP_RC) — stores may be mixed, run codex-auth-sync.sh NOW" ). Attempt reason: $REASON. See RUNBOOK §\"Codex Usage Cap / Account Rotation\"."
  exit 5
fi

# Stamp BEFORE the restarts: even a restart failure must hold the cooldown,
# or the keepalive would re-trigger a rotation storm against a sick gateway.
date +%s > "$CODEX_ROTATE_STAMP" || log "WARN: could not write cooldown stamp $CODEX_ROTATE_STAMP"

# Record the switch in the append-only ledger at the same moment, so a rollout
# snapshot emitted after this instant can later be attributed to $TARGET and
# one emitted before it to $CURRENT. Best-effort: a ledger write failure must
# never abort a rotation that has already converged the auth stores.
cq_ledger_append "$CODEX_ACTIVE_LEDGER" "$TARGET" "$REASON" \
  || log "WARN: could not append to active-account ledger $CODEX_ACTIVE_LEDGER"

RESTART_FAILED=0
if [ "$CODEX_ROTATE_RESTART" = "1" ]; then
  # shellcheck source=gateway-restart.sh
  source "$_DIR/gateway-restart.sh"
  GATEWAY_FALLBACK_NOTIFY_FN="${GATEWAY_FALLBACK_NOTIFY_FN:-_page}"
  export GATEWAY_FALLBACK_NOTIFY_FN
  for service in $CODEX_ROTATE_SERVICES; do
    profile="${service##*-}"; profile="${profile%.service}"
    if drain_restart_gateway "$service" "$profile"; then
      log "$service restarted"
    else
      RESTART_FAILED=1
      log "ERROR: $service restart FAILED — new account is in the stores but not loaded"
    fi
  done
else
  log "CODEX_ROTATE_RESTART=0 — skipping gateway restarts (stores converged; the token loads on the next restart)"
fi

if [ "$RESTART_FAILED" -ne 0 ]; then
  _page_critical ":rotating_light: codex active account rotated \`$CURRENT\` → \`$TARGET\` but a gateway restart FAILED — stores converged, token NOT loaded. Check \`systemctl status openclaw-gateway-main openclaw-gateway-edge\` now. Reason: $REASON"
  exit 6
fi

# The success page carries the EVIDENCE for the account we just moved onto,
# or says plainly that we could not measure it. "Rotated to the standby" with
# no number is what let a rotation onto an exhausted account read as a
# successful recovery for hours (2026-08-06).
if [ "$UNMEASURED_TARGET" -eq 1 ]; then
  _page ":arrows_counterclockwise: codex active account rotated \`$CURRENT\` → \`$TARGET\` (reason: $REASON) — *target quota UNMEASURED*: rotating because the previous account was unusable, NOT because this one is known healthy. Auth stores re-synced. Verify with \`/opt/hydra/scripts/codex-quota-refresh.sh\` then \`/opt/hydra/scripts/codex-usage-report.sh\`."
else
  _TARGET_ROW="$(cq_measure_read "$CODEX_USAGE_ARCHIVE_DIR" "$TARGET" 2>/dev/null || true)"
  _CURRENT_ROW="$(cq_measure_read "$CODEX_USAGE_ARCHIVE_DIR" "$CURRENT" 2>/dev/null || true)"
  _page ":arrows_counterclockwise: codex active account rotated (reason: $REASON) — from $(cq_format_evidence "$CURRENT" "$_CURRENT_ROW") → to $(cq_format_evidence "$TARGET" "$_TARGET_ROW"). Auth stores re-synced; \`/opt/hydra/scripts/codex-usage-report.sh\` for the full picture."
fi
log "rotation complete: $CURRENT → $TARGET"
