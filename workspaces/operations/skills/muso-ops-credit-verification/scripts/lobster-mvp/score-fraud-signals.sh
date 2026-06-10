#!/usr/bin/env bash
# score-fraud-signals.sh — Lobster step (operations BATCH pipeline ONLY).
#
# A multi-factor, PROFILE-LEVEL fraud detector that runs AFTER
# score-backend-signals.sh and BEFORE verdict-engine.sh. It can DOWNGRADE a
# backend signal_approve to a new "signal_fraud" bucket so a credit the
# backend would auto-approve is instead routed to user_verification_needed
# (UVN). Caroline / customer-facing flows are OUT OF SCOPE — this is the ops
# batch only.
#
# ── INPUT CONTRACT ──────────────────────────────────────────────────────────
# Stdin:  the EXACT stdout of score-backend-signals.sh, i.e.
#   { queue_depth, fetch_size, selector,
#     counts: {total, signal_approve, signal_review, signal_uvn},
#     signal_approve: [ {cr_id, profile_id, isrc, credited_name, role,
#                        _signal:{bucket,reason,...}}, ... ],
#     signal_review:  [ ... same per-credit shape ... ],
#     signal_uvn:     [ ... ] }
#
# Env CV_FRAUD_RAW_BATCH:  path to a file containing the RAW fetched batch
#   (the stdout of pick-credits.sh / fetch-*.sh), i.e.
#   { queue_depth, items: [ <full credit objects with credits[], metadata.*,
#                            profile.*, verificationData.* > ], ... }
#   The scorer NEEDS the raw fields (credits[], metadata.source/label,
#   profile.creditCount/popularity, verificationData) that score-backend-
#   signals.sh drops. Keying is by credit .id == per-credit .cr_id.
#
#   WHY a file, not stdin: a Lobster step has exactly one stdin, which must be
#   the scored buckets so the OUTPUT shape stays a drop-in superset for
#   verdict-engine.sh. Re-reading the raw batch from a file is the LEAST
#   invasive option (it modifies NO existing script — pick-credits.sh,
#   score-backend-signals.sh, verdict-engine.sh all stay byte-for-byte
#   unchanged). The Phase-2 lobster wiring is responsible for persisting
#   $pick.stdout to this file. See fraud-detection-spec.md § Pipeline wiring.
#
#   If CV_FRAUD_RAW_BATCH is unset or unreadable, the scorer cannot compute
#   profile factors → it FAILS SOFT to pure pass-through (input emitted
#   unchanged, loud stderr note), regardless of CV_FRAUD_MODE. The batch is
#   never blocked.
#
# ── OUTPUT CONTRACT ─────────────────────────────────────────────────────────
# Stdout: the SAME top-level shape as the input, with these additions:
#   * Every per-credit object gains a `_fraud` object (always, in shadow and
#     enforce; never in off):
#       _fraud: { score: <number 0..1>, threshold: <number>,
#                 over: <bool>, factors: { <name>: <weighted contribution>,...},
#                 fired: [ <factor names that contributed > 0>, ... ],
#                 reason: "fraud:<f1>+<f2>=<score>" | null,
#                 muso_only_available: <bool> }
#   * MODE = off      → input emitted UNCHANGED. No `_fraud`, no signal_fraud.
#   * MODE = shadow   → `_fraud` annotated on every credit; `_signal.bucket`
#                       UNCHANGED; a new top-level `signal_fraud` array lists
#                       the credits that WOULD have been re-bucketed (copies,
#                       with original bucket preserved in `_fraud.orig_bucket`)
#                       so Slack can surface them without changing verdicts.
#                       Existing signal_* arrays are untouched.
#   * MODE = enforce  → for every credit with `_fraud.over == true`, set
#                       `_signal.bucket = "signal_fraud"` (overriding
#                       signal_approve / signal_review / signal_uvn), record
#                       the prior value in `_fraud.orig_bucket`, MOVE the
#                       credit out of its old signal_* array into a new
#                       top-level `signal_fraud` array, and add
#                       counts.signal_fraud. signal_approve shrinks
#                       accordingly — this is the auto-approve downgrade.
#
# verdict-engine.sh maps signal_fraud → would_uvn (and carries the top-level
# signal_fraud array through for the renderer), and the lobster pipeline both
# persists CV_FRAUD_RAW_BATCH and runs this step between score and verdict.
# That wiring is IN PLACE, so enforce is mechanically safe with the shipped
# pipeline. The real gate is rollout discipline, not a missing engine change:
# follow off → shadow (observe in Slack, verdicts unchanged) → enforce, exactly
# like the CV_EVIDENCE_MODE rollout, and only flip enforce after a shadow batch
# has been reviewed.
#
# ── FACTORS & SCORE ─────────────────────────────────────────────────────────
# Computed once per profileId (aggregating the profile's credits in THIS
# batch), then stamped onto each of that profile's credits. Each factor is a
# 0..1 indicator; the score is a weighted sum normalized by total weight, so
# the score is always 0..1 and the threshold is unit-free. See
# fraud-detection-spec.md for the exact formulas and env table.
#
# Pure bash + jq + the fail-soft trino helper. Reuses the num() coercion
# pattern from score-backend-signals.sh.

set -euo pipefail

# ── Mode gate ───────────────────────────────────────────────────────────────
CV_FRAUD_MODE="${CV_FRAUD_MODE:-off}"

INPUT=$(cat)

# off → pure pass-through, no work, no trino, input byte-shape preserved.
if [[ "$CV_FRAUD_MODE" == "off" ]]; then
  printf '%s' "$INPUT"
  # ensure trailing newline parity with jq -c consumers
  case "$INPUT" in *$'\n') : ;; *) printf '\n' ;; esac
  exit 0
fi

if [[ "$CV_FRAUD_MODE" != "shadow" && "$CV_FRAUD_MODE" != "enforce" ]]; then
  echo "[score-fraud-signals] WARN: unknown CV_FRAUD_MODE='$CV_FRAUD_MODE' (expected off|shadow|enforce); treating as off (pass-through)." >&2
  printf '%s' "$INPUT"
  case "$INPUT" in *$'\n') : ;; *) printf '\n' ;; esac
  exit 0
fi

# ── Raw batch (required for shadow/enforce) ─────────────────────────────────
soft_passthrough() {
  echo "[score-fraud-signals] FAIL-SOFT pass-through ($CV_FRAUD_MODE mode): $1 — verdicts UNCHANGED this run." >&2
  printf '%s' "$INPUT"
  case "$INPUT" in *$'\n') : ;; *) printf '\n' ;; esac
  exit 0
}

RAW_BATCH_FILE="${CV_FRAUD_RAW_BATCH:-}"
if [[ -z "$RAW_BATCH_FILE" ]]; then
  soft_passthrough "CV_FRAUD_RAW_BATCH not set (need raw credit objects for credits[]/metadata/profile factors)"
fi
if [[ ! -r "$RAW_BATCH_FILE" ]]; then
  soft_passthrough "CV_FRAUD_RAW_BATCH=$RAW_BATCH_FILE not readable"
fi
RAW=$(cat "$RAW_BATCH_FILE")
# Type-check, not just truthiness: a valid-JSON raw batch with .items as an
# object/string passes `jq -e '.items'` but then aborts the whole batch at the
# group_by() scoring program below — violating the fail-soft contract.
if ! printf '%s' "$RAW" | jq -e '(.items | type) == "array"' >/dev/null 2>&1; then
  soft_passthrough "raw batch at $RAW_BATCH_FILE has no .items array"
fi

# ── Env: factor weights + threshold + tuning knobs ──────────────────────────
# All defaults grounded in the Tier-0 gates (docs/credit-verification/
# design.md) and the muso-credit-investigator point system. See the env table
# in fraud-detection-spec.md. Weights are RELATIVE — the score is the weighted
# sum of fired factors divided by the SUM OF ALL WEIGHTS, so it is always
# 0..1 and the threshold is comparable across weight retunes.
CV_FRAUD_THRESHOLD="${CV_FRAUD_THRESHOLD:-0.60}"

CV_FRAUD_W_ROLE_INFLATION="${CV_FRAUD_W_ROLE_INFLATION:-3}"
CV_FRAUD_W_SOURCE_QUALITY="${CV_FRAUD_W_SOURCE_QUALITY:-2}"
CV_FRAUD_W_ESTABLISHMENT="${CV_FRAUD_W_ESTABLISHMENT:-2}"
CV_FRAUD_W_VELOCITY="${CV_FRAUD_W_VELOCITY:-2}"
CV_FRAUD_W_BACKEND_HARD_REJECT="${CV_FRAUD_W_BACKEND_HARD_REJECT:-3}"
CV_FRAUD_W_MUSO_ONLY="${CV_FRAUD_W_MUSO_ONLY:-3}"

# Factor sub-thresholds (mirror Tier-0 gate defaults; fraud = the inverse).
CV_TIER0_MIN_CC="${CV_TIER0_MIN_CC:-100}"          # G1 establishment
CV_TIER0_MIN_POP="${CV_TIER0_MIN_POP:-50}"         # G2 establishment
CV_TIER0_MIN_INDUSTRY="${CV_TIER0_MIN_INDUSTRY:-0.70}"  # G3 source quality
CV_FRAUD_ROLE_INFLATION_FRAC="${CV_FRAUD_ROLE_INFLATION_FRAC:-0.50}"  # >=50% non-creative roles fires
CV_FRAUD_MUSO_ONLY_PCT="${CV_FRAUD_MUSO_ONLY_PCT:-50}"  # muso-only pop% over this fires (saved-query band)
# Absolute roles-per-track breadth that also fires role_inflation. NOTE: this is
# an ABSOLUTE heuristic (the "11-role bundle" Ming-Vauz pattern), NOT Tier-0 G5
# — G5 is profile-RELATIVE (max(unverified breadth) > max(approved breadth)+1),
# which needs the profile's approved corpus that the per-credit batch object
# does not carry. Relative-G5 breadth is a deferred follow-up (see GH issue).
CV_FRAUD_ROLE_BREADTH_MAX="${CV_FRAUD_ROLE_BREADTH_MAX:-6}"

# Non-creative role list (muso-credit-investigator SKILL.md). Matching is
# case-insensitive on WHOLE-WORD boundaries ("art" matches "Cover Art" but NOT
# "Quartet"/"Artwork"; "album cover" still matches "Album Cover Photography").
# Carried into jq as a JSON array.
NONCREATIVE_ROLES_JSON='["album cover","editorial","photography","art","design","a&r","marketing","management","publisher"]'

# ── Gather this batch's profileIds and ask Trino (fail-soft) ────────────────
PROFILE_IDS=$(printf '%s' "$RAW" | jq -r '[.items[]?.profileId // empty] | unique | .[]')

# The helper returns a wrapper {available:bool, data:{pid:pct}}. `available` is
# the authoritative signal — do NOT infer it from whether `data` is empty (a
# healthy Trino that returns zero qualifying rows is available:true, data:{}).
MUSO_WRAP='{"available":false,"data":{}}'
if [[ -n "$PROFILE_IDS" ]]; then
  LOOKUP_SH="$(cd "$(dirname "$0")" && pwd)/../lib/fraud-muso-only-lookup.sh"
  if [[ -x "$LOOKUP_SH" ]] || command -v "$LOOKUP_SH" >/dev/null 2>&1; then
    # Helper is itself fail-soft (always exits 0, always prints the wrapper).
    # No stderr redirect: the helper's stderr inherits ours by default, and an
    # explicit 2>>/dev/stderr fails with ENXIO under the gateway (stderr is a
    # socketpair there, not openable as a file) — which silently degraded the
    # muso_only factor on EVERY gateway run (2026-06-10 incident).
    MUSO_WRAP=$(printf '%s\n' "$PROFILE_IDS" | bash "$LOOKUP_SH" || printf '{"available":false,"data":{}}')
    if ! printf '%s' "$MUSO_WRAP" | jq -e '.data' >/dev/null 2>&1; then
      echo "[score-fraud-signals] muso-only helper returned non-conforming output; treating as unavailable." >&2
      MUSO_WRAP='{"available":false,"data":{}}'
    fi
  else
    echo "[score-fraud-signals] muso-only helper not executable at $LOOKUP_SH; muso_only factor unavailable." >&2
    MUSO_WRAP='{"available":false,"data":{}}'
  fi
else
  # No profileIds in the batch ⇒ nothing to look up; not a failure (vacuously
  # available so a profile-less batch never spuriously cries "Trino down").
  MUSO_WRAP='{"available":true,"data":{}}'
fi
MUSO_MAP=$(printf '%s' "$MUSO_WRAP" | jq -c '.data')
MUSO_AVAILABLE=$(printf '%s' "$MUSO_WRAP" | jq '.available')

# ── The scoring jq program ──────────────────────────────────────────────────
# Stages:
#  1. From RAW .items, compute per-profile factor indicators + weighted score.
#  2. Build a {cr_id: _fraud} map keyed by credit id.
#  3. Stamp _fraud onto each scored credit; apply mode semantics.
# The raw batch goes in via --slurpfile, NOT --argjson: a 500-credit raw
# batch is megabytes, and a single argv element over ~128KB dies with
# "Argument list too long" (E2BIG, exit 126) on Linux — which killed the
# first shadow cron batch (2026-06-10 16:01Z) before any credit was scored.
printf '%s' "$INPUT" | jq -c \
  --slurpfile rawf "$RAW_BATCH_FILE" \
  --argjson muso "$MUSO_MAP" \
  --argjson musoAvail "$MUSO_AVAILABLE" \
  --arg mode "$CV_FRAUD_MODE" \
  --argjson threshold "$CV_FRAUD_THRESHOLD" \
  --argjson wRole "$CV_FRAUD_W_ROLE_INFLATION" \
  --argjson wSrc "$CV_FRAUD_W_SOURCE_QUALITY" \
  --argjson wEst "$CV_FRAUD_W_ESTABLISHMENT" \
  --argjson wVel "$CV_FRAUD_W_VELOCITY" \
  --argjson wHard "$CV_FRAUD_W_BACKEND_HARD_REJECT" \
  --argjson wMuso "$CV_FRAUD_W_MUSO_ONLY" \
  --argjson minCC "$CV_TIER0_MIN_CC" \
  --argjson minPop "$CV_TIER0_MIN_POP" \
  --argjson minIndustry "$CV_TIER0_MIN_INDUSTRY" \
  --argjson roleFrac "$CV_FRAUD_ROLE_INFLATION_FRAC" \
  --argjson musoPct "$CV_FRAUD_MUSO_ONLY_PCT" \
  --argjson breadthMax "$CV_FRAUD_ROLE_BREADTH_MAX" \
  --argjson noncreative "$NONCREATIVE_ROLES_JSON" '
  def num(p): (p | tonumber? // 0);

  # Is a single role string a non-creative ("inflation-risk") role? Whole-word
  # match (\b...\b) so the short tokens ("art","a&r","design") do not match
  # inside unrelated creative roles ("Quartet","Artwork"); multi-word entries
  # ("album cover") still match within longer strings ("Album Cover Photography").
  def is_noncreative($roles): . as $r
    | ($r | ascii_downcase) as $rl
    | any($roles[]; . as $n | ($rl | test("\\b" + $n + "\\b")));

  ($rawf[0]) as $raw
  | ($raw.items // []) as $items

  # ---- Per-profile aggregation -------------------------------------------
  | ($items | group_by(.profileId)) as $byprofile
  | ( $byprofile | map(
        . as $grp
        | ($grp[0].profileId) as $pid
        # creditCount/popularity are profile-scoped: read from any item.
        | (num($grp[0].profile.creditCount)) as $cc
        | (num($grp[0].profile.popularity))  as $pop
        # All role strings across this profiles batch credits.
        | ([ $grp[] | (.credits // [])[] ]) as $allroles
        | ($allroles | length) as $nroles
        | ([ $allroles[] | select(is_noncreative($noncreative)) ] | length) as $nnoncreative
        # roles-per-track breadth (max credits[] length across the batch).
        | ([ $grp[] | ((.credits // []) | length) ] | max // 0) as $maxbreadth
        # source mix: fraction NOT industry-sourced.
        | ($grp | length) as $ncredits
        | ([ $grp[] | select((.metadata.source // "") != "industry") ] | length) as $nnonindustry
        # velocity + hard-reject from verificationData.rule_risk_percent.
        | ([ $grp[] | (.verificationData.rule_risk_percent // {}) ]) as $rrps
        | (any($rrps[]; num(.reject_high_velocity_profile) > 0)) as $velocity_fired
        | (any($rrps[];
              num(.reject_artist_credit) > 0
              or num(.reject_deleted_catalog_track) > 0
              or num(.reject_individual_org_credit) > 0
              or num(.reject_publisher_label_credit) > 0
              or num(.reject_high_risk_profile) > 0)) as $hard_fired
        | ($muso[$pid] // null) as $muso_pct

        # ---- Factor indicators (each 0 or 1) -----------------------------
        | ( if $nroles > 0 then ($nnoncreative / $nroles) else 0 end ) as $noncreative_frac
        | ( (($noncreative_frac >= $roleFrac) or ($maxbreadth >= $breadthMax)) ) as $f_role
        | ( if $ncredits > 0 then (($nnonindustry / $ncredits) > (1 - $minIndustry)) else false end ) as $f_src
        | ( ($cc < $minCC) or ($pop < $minPop) ) as $f_est
        | ( $velocity_fired ) as $f_vel
        | ( $hard_fired ) as $f_hard
        | ( ($muso_pct != null) and ($muso_pct > $musoPct) ) as $f_muso

        # ---- Weighted score (normalized 0..1) ----------------------------
        | ( (if $f_role then $wRole else 0 end)
            + (if $f_src then $wSrc else 0 end)
            + (if $f_est then $wEst else 0 end)
            + (if $f_vel then $wVel else 0 end)
            + (if $f_hard then $wHard else 0 end)
            + (if $f_muso then $wMuso else 0 end) ) as $weighted
        | ( $wRole + $wSrc + $wEst + $wVel + $wHard + $wMuso ) as $maxweight
        | ( if $maxweight > 0 then ($weighted / $maxweight) else 0 end ) as $score

        # ordered factor map so the reason string is deterministic.
        | { factors: {
              role_inflation:     (if $f_role then ($wRole/$maxweight) else 0 end),
              source_quality:     (if $f_src  then ($wSrc/$maxweight)  else 0 end),
              establishment:      (if $f_est  then ($wEst/$maxweight)  else 0 end),
              velocity:           (if $f_vel  then ($wVel/$maxweight)  else 0 end),
              backend_hard_reject:(if $f_hard then ($wHard/$maxweight) else 0 end),
              muso_only:          (if $f_muso then ($wMuso/$maxweight) else 0 end)
            },
            fired: ( [ (if $f_role then "role_inflation" else empty end),
                       (if $f_src  then "source_quality" else empty end),
                       (if $f_est  then "establishment" else empty end),
                       (if $f_vel  then "velocity" else empty end),
                       (if $f_hard then "backend_hard_reject" else empty end),
                       (if $f_muso then "muso_only" else empty end) ] ),
            score: ($score),
            threshold: $threshold,
            over: ($score >= $threshold),
            muso_only_available: $musoAvail,
            muso_only_pct: $muso_pct }
        | . as $fr
        | { key: $pid,
            value: ($fr + {
              reason: ( if ($fr.over) then
                          "fraud:" + ($fr.fired | join("+")) + "=" + (($fr.score*100|round)/100 | tostring)
                        else null end )
            }) }
      ) | from_entries ) as $profile_fraud

  # ---- Stamp _fraud onto each scored credit + apply mode ------------------
  | ( def stamp($c):
        ($profile_fraud[$c.profile_id] // {
            factors:{}, fired:[], score:0, threshold:$threshold,
            over:false, muso_only_available:$musoAvail,
            muso_only_pct:null, reason:null }) as $fr
        | $c + { _fraud: $fr };

      .signal_approve as $sa0
    | .signal_review  as $sr0
    | .signal_uvn     as $su0
    | ( ($sa0 // []) | map(stamp(.)) ) as $sa
    | ( ($sr0 // []) | map(stamp(.)) ) as $sr
    | ( ($su0 // []) | map(stamp(.)) ) as $su

    | if $mode == "shadow" then
        # Annotate only; keep buckets. signal_fraud = COPIES of over-threshold
        # credits, original bucket recorded for Slack.
        ( ($sa + $sr + $su)
          | map(select(._fraud.over))
          | map( ._fraud += {orig_bucket: ._signal.bucket} ) ) as $fraud_copies
        | .signal_approve = $sa
        | .signal_review  = $sr
        | .signal_uvn     = $su
        | .signal_fraud   = $fraud_copies
        | .counts.signal_fraud = ($fraud_copies | length)
      else
        # enforce: move over-threshold credits into signal_fraud, set bucket.
        ( ($sa + $sr + $su)
          | map( if ._fraud.over
                   then ._fraud += {orig_bucket: ._signal.bucket}
                        | ._signal.bucket = "signal_fraud"
                        | ._signal.reason = ._fraud.reason
                   else . end ) ) as $all
        | ($all | map(select(._signal.bucket == "signal_approve"))) as $nsa
        | ($all | map(select(._signal.bucket == "signal_review")))  as $nsr
        | ($all | map(select(._signal.bucket == "signal_uvn")))     as $nsu
        | ($all | map(select(._signal.bucket == "signal_fraud")))   as $nsf
        | .signal_approve = $nsa
        | .signal_review  = $nsr
        | .signal_uvn     = $nsu
        | .signal_fraud   = $nsf
        | .counts.signal_approve = ($nsa | length)
        | .counts.signal_review  = ($nsr | length)
        | .counts.signal_uvn     = ($nsu | length)
        | .counts.signal_fraud   = ($nsf | length)
      end
    )
  '
