#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# hydra-fleet-instrument.sh — weekly fleet instrumentation, ZERO model turns.
#
# WHY THIS EXISTS. 17 of 31 crons are disabled, rationed against the Codex
# weekly turn budget. That rationing was a judgement call made during a quota
# crunch and has never been re-measured — the active account has since been
# rotated. Re-enabling crons without numbers is a guess; this script produces
# the numbers so the decision is measured.
#
# Run as a `payload.kind:"command"` cron with `delivery.mode:"announce"`, so it
# costs no model turns. Waking an LLM to relay a deterministic script's stdout
# is exactly the anti-pattern the re-architecture targets.
#
# WHAT IT DOES NOT DO. It never re-enables anything, never writes config, and
# makes no recommendation. Detect-and-report only: re-sizing the fleet is a
# human decision, and a script that quietly widened it would defer the same
# quota outage with nobody informed.
#
# Output: Slack mrkdwn (bullets, no tables — matches codex-usage-report.sh).
# `--json` emits the same data structured.
#
# FAIL-LOUD IN THE CONTENT, exit 0. Every section degrades independently to an
# explicit "cannot read" line rather than vanishing. A `bestEffort` announce
# delivery drops a non-zero exit silently, so a hard failure here would look
# identical to "nothing to report" — the one outcome that must never be
# ambiguous in a script whose entire job is measurement.
#
# Env overrides (tests / non-default layouts):
#   OPENCLAW_HOME       default /root/.openclaw-main
#   HYDRA_ROOT          default /opt/hydra
#   AUDIT_LIMIT         default 500    (events pulled from the audit ring;
#                       openclaw enforces 1..500 and hard-errors above it, so a
#                       larger value fetches NOTHING — this is clamped, not passed
#                       through. Documenting 2000 here is what invited the value
#                       that silently killed the section.)
#   USAGE_REPORT        default $HERE/codex-usage-report.sh
#   INSTRUMENT_PROFILE  default main
# ──────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPENCLAW_HOME="${OPENCLAW_HOME:-/root/.openclaw-main}"
HYDRA_ROOT="${HYDRA_ROOT:-/opt/hydra}"
# openclaw enforces `audit --limit` in 1..500 and hard-errors outside it. A
# larger value does not fetch more, it fetches NOTHING: the command exits 1 and
# the whole section degrades to "audit unavailable" forever. Clamp rather than
# trust the caller, and keep the ceiling next to the reason for it.
AUDIT_LIMIT="${AUDIT_LIMIT:-500}"
case "$AUDIT_LIMIT" in ''|*[!0-9]*) AUDIT_LIMIT=500 ;; esac
[ "$AUDIT_LIMIT" -lt 1 ] && AUDIT_LIMIT=1
[ "$AUDIT_LIMIT" -gt 500 ] && AUDIT_LIMIT=500
USAGE_REPORT="${USAGE_REPORT:-$HERE/codex-usage-report.sh}"
INSTRUMENT_PROFILE="${INSTRUMENT_PROFILE:-main}"

JSON_MODE=0
[ "${1:-}" = "--json" ] && JSON_MODE=1

# ── 1. Codex quota ───────────────────────────────────────────────────────────
# Delegated, NOT reimplemented. codex-usage-report.sh already owns the snapshot
# parsing, the per-account archive, and the "never print a token" rule. A second
# implementation would drift from it and re-introduce the hand-rolled-jq bug
# that scripts/codex-usage-report.sh was written to kill (hydra#382).
quota_json='{"error":"usage report unavailable"}'
if [ -x "$USAGE_REPORT" ] || [ -r "$USAGE_REPORT" ]; then
  if out=$(bash "$USAGE_REPORT" --json 2>/dev/null) && [ -n "$out" ] \
     && printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    quota_json="$out"
  fi
fi

# ── 2. Cron census + wedge detection ─────────────────────────────────────────
# The wedge signature is documented in CLAUDE.md: an agent with enabled crons
# and ZERO `:cron:` keys in its sessions index is wedged RIGHT NOW — every fire
# dies at setup with CronSessionLifecycleClaimError, restart-immune. It has
# happened twice (maxEntries 2026-07-16, maxDiskBytes 2026-07-27, ~25h outage).
cron_json='{"error":"cron-jobs.json unreadable"}'
cron_file="$HYDRA_ROOT/cron-jobs.json"
# Falling back to the repo checkout is intended (it lets this run outside
# /opt/hydra), but it MUST announce itself: silently reporting a different
# file's numbers under the configured path's name is a wrong answer wearing a
# right answer's clothes — worse than the "cannot read" line it replaces, and
# exactly what this script exists not to do.
cron_source_note=""
if [ ! -r "$cron_file" ]; then
  cron_source_note="$HYDRA_ROOT/cron-jobs.json unreadable — counts below are from the repo checkout instead"
  cron_file="$HERE/../cron-jobs.json"
fi
if [ -r "$cron_file" ]; then
  cron_json=$(jq -c '
      (if type=="array" then . else (.jobs // .crons // null) end) as $j
      | if ($j|type) != "array"
        then {error:"cron-jobs.json shape unrecognised — no top-level array, .jobs or .crons"}
        else {
          total:    ($j|length),
          enabled:  ([$j[]|select(.enabled != false)]|length),
          disabled: ([$j[]|select(.enabled == false)]|length),
          model_turn_enabled:
            ([$j[]|select(.enabled != false and (.payload.kind//"") != "command")]|length),
          command_enabled:
            ([$j[]|select(.enabled != false and (.payload.kind//"") == "command")]|length),
          # ONLY model-turn crons get a `:cron:` session key. An agent whose
          # enabled crons are all payload.kind:"command" legitimately has none,
          # so including it here would page 🚨 WEDGED for working-as-designed —
          # and this script exists to argue for MORE command crons, so that
          # false page would land on exactly the change it advocates.
          # Sanitised HERE, at the boundary, not at the renderer: the shell loop
          # below reads this list line by line, so an id containing a newline
          # would split into two "agents" before any renderer could clean it —
          # forging a second bullet. Control chars -> space, backtick -> quote
          # (cannot close its code span), "/" -> "_" (cannot traverse out of the
          # agents dir when the id is pasted into a sessions.json path).
          agents_with_enabled_crons:
            ([$j[]|select(.enabled != false and (.payload.kind//"") != "command")
                  |.agentId|select(. != null)|tostring|explode
                  |map(if . < 32 or . == 127 then 32
                       elif . == 96 then 39
                       elif . == 47 then 95
                       else . end)|implode]|unique)
        } end' "$cron_file" 2>/dev/null) \
    || cron_json='{"error":"cron-jobs.json parse failed"}'
fi

# Wedge check per agent that actually has enabled crons. The loop emits one JSON
# object per finding straight to `jq -s`, which slurps them into an array and
# yields [] when nothing was emitted — so no agents, an errored cron_json (whose
# `[]?` yields nothing), and no wedges all collapse to the same empty result
# without a bash array to marshal back through jq.
wedged=$(
  printf '%s' "$cron_json" | jq -r '.agents_with_enabled_crons[]?' 2>/dev/null |
    while IFS= read -r agent; do
      [ -n "$agent" ] || continue
      sess="$OPENCLAW_HOME/agents/$agent/sessions/sessions.json"
      # Unreadable is NOT the same as wedged — report it separately rather than
      # letting a permissions problem masquerade as an outage.
      if [ ! -r "$sess" ]; then
        jq -nc --arg a "$agent" '{agent:$a,state:"unknown",why:"sessions.json unreadable"}'
        continue
      fi
      # Count session KEYS, exactly as scripts/lib/ensure-session-budget-headroom.sh
      # `_cron_key_count` does — the canonical detector this signal belongs to.
      # An earlier `paths(scalars)` version was wrong in BOTH directions: it
      # missed a `:cron:` entry whose value has no scalar leaf (`{}`) and so
      # false-paged a healthy agent, and it matched `:cron:` text nested inside
      # a *slack* record and so reported a genuinely wedged agent as healthy.
      # Both shapes are handled: a top-level object keyed by session key (what
      # node-8 actually writes) and the `{entries:[{key:…}]}` array form.
      n=$(jq '[ (.entries // .sessions // .)
                | if type=="object" then keys else [.[].key?] end
                | .[] | select(type=="string" and test(":cron:")) ] | length' \
          "$sess" 2>/dev/null) || n=""
      # jq emits one number PER input document, so a multi-document sessions.json
      # yields "0\n0" — which makes `[ "$n" -eq 0 ]` an integer-expected error on
      # stderr, take no branch, and silently drop the agent while ✅ prints. An
      # announce cron never delivers stderr, so that would be invisible.
      case "$n" in ''|*[!0-9]*) n="" ;; esac
      if [ -z "$n" ]; then
        jq -nc --arg a "$agent" '{agent:$a,state:"unknown",why:"sessions.json parse failed"}'
      elif [ "$n" -eq 0 ]; then
        jq -nc --arg a "$agent" '{agent:$a,state:"WEDGED",why:"enabled crons but zero :cron: session keys"}'
      fi
    done | jq -sc '.' 2>/dev/null
) || wedged='[]'
[ -n "$wedged" ] || wedged='[]'

# ── 3. Per-agent tool actions from the audit ring ────────────────────────────
# CAVEAT, surfaced in the output and not just here: `openclaw audit` is a RING
# BUFFER. This is "the last AUDIT_LIMIT events", NOT a clean 7-day count, and a
# busy week silently truncates the oldest agents first. Treat it as relative
# share between agents, never as an absolute weekly total.
audit_json='{"error":"audit unavailable"}'
if command -v openclaw >/dev/null 2>&1; then
  if a=$(OPENCLAW_STATE_DIR="$OPENCLAW_HOME" \
         openclaw --profile "$INSTRUMENT_PROFILE" audit --json --limit "$AUDIT_LIMIT" 2>/dev/null) \
     && printf '%s' "$a" | jq -e '.events' >/dev/null 2>&1; then
    audit_json=$(printf '%s' "$a" | jq -c --argjson limit "$AUDIT_LIMIT" '
        [.events[]? | select(.kind=="tool_action" and .status=="started")] as $t
        | { sampled_events: (.events|length),
            tool_actions:   ($t|length),
            truncated:      ((.events|length) >= $limit),
            by_agent: ( $t | group_by(.agentId // "unknown")
                        | map({agent:(.[0].agentId // "unknown"), actions:length})
                        | sort_by(-.actions) ) }' 2>/dev/null) \
      || audit_json='{"error":"audit parse failed"}'
  fi
fi

# ── emit ─────────────────────────────────────────────────────────────────────
# --argjson rejects anything that is not exactly ONE json document, and a section
# capture can hold two (a half-written file, a producer that printed twice). That
# used to abort the emit and fall through to `exit 0` having printed NOTHING —
# silence at exit 0, in the one mode with no prose to carry a warning. Normalise
# every section to a single document first, replacing an unusable one with a
# visible error object.
# `jq -e 'type'` is NOT the right check: it validates every value in a STREAM and
# exits 0 for two concatenated documents, which --argjson then rejects (exit 2) —
# aborting the whole emit and replacing every healthy section with one generic
# error. Slurp and require exactly ONE value, so a two-document producer degrades
# only ITS OWN section and the rest still report. `null` slurps to length 1, so a
# legitimately-null section is preserved.
for _v in quota_json cron_json wedged audit_json; do
  if [ "$(printf '%s' "${!_v}" | jq -s 'length' 2>/dev/null)" != "1" ]; then
    printf -v "$_v" '%s' '{"error":"section produced non-JSON or multiple documents"}'
  fi
done

if [ "$JSON_MODE" -eq 1 ]; then
  # `wedged` must distinguish "checked, none found" ([]) from "could not check"
  # (null) — the JSON twin of the text mode's "wedge check did not run" line.
  # Without it a broken census is byte-identical to a healthy fleet.
  printf '%s' "$cron_json" | jq -e '.error' >/dev/null 2>&1 && wedged='null'
  jq -nc --argjson quota "$quota_json" --argjson cron "$cron_json" \
         --argjson wedged "$wedged" --argjson audit "$audit_json" \
         --arg note "$cron_source_note" \
    '{quota:$quota, crons:$cron, wedged:$wedged, audit:$audit,
      cron_source_note:(if $note=="" then null else $note end)}' \
    || printf '%s\n' '{"error":"instrument emit failed — sections unrenderable"}'
  exit 0
fi

say() { printf '%s\n' "$1"; }
say "*Hydra fleet instrumentation* — $(date -u '+%Y-%m-%d %H:%M UTC')"
say ""

# `.error // empty` prints nothing when the key is absent, so one jq pass both
# detects the degraded path and carries its message — the reason each section
# reads its error into a variable instead of testing and re-extracting.
section_error() { printf '%s' "$1" | jq -r '.error // empty' 2>/dev/null; }

# Agent ids reach Slack verbatim inside a code span, and they come from
# cron-jobs.json / the audit ring rather than from us. A control character (a
# newline especially) lets an id close its bullet and forge further lines —
# including a whole fabricated section with invented numbers, in a report whose
# only value is being trusted. Strip control chars and backticks, and bound the
# length, at the one place ids are rendered.
# Done by CODEPOINT, not regex: a character class written through two layers of
# shell+jq escaping silently mis-parsed and blanked ordinary letters instead
# (`ops` rendered as spaces). explode/implode has no escaping surface at all.
# < 32 and 127 are control chars -> space; 96 is a backtick -> apostrophe, so an
# id cannot close the code span it sits in.
SAFE_AGENT='(.agent // "?" | tostring | explode
             | map(if . < 32 or . == 127 then 32 elif . == 96 then 39 else . end)
             | implode | .[0:64])'

# quota
say "*Codex quota*"
quota_err=$(section_error "$quota_json")
if [ -n "$quota_err" ]; then
  say "  • ⚠️ cannot read usage report — $quota_err"
else
  printf '%s' "$quota_json" | jq -r '
    (.accounts // [] | .[]?
      # codex-usage-report.sh `_acct_json` emits role:"active"|"standby" — there
      # is NO `.active` key. Reading one made EVERY account render "standby",
      # including the live one, which destroys the single most decision-relevant
      # fact in the report (which subscription is burning the quota).
      | "  • \(.email // "?") — \(if (.role // "") == "active" then "active" else "standby" end)"
        + (if (.used_percent_weekly // null) != null
           then " · weekly \(.used_percent_weekly)% used" else " · no fresh snapshot" end))
    // "  • (no accounts in snapshot)"' 2>/dev/null \
    || say "  • ⚠️ usage report shape unrecognised — run codex-usage-report.sh directly"
fi
say ""

# crons
say "*Crons*"
[ -n "$cron_source_note" ] && say "  • ⚠️ $cron_source_note"
cron_err=$(section_error "$cron_json")
if [ -n "$cron_err" ]; then
  say "  • ⚠️ $cron_err"
else
  printf '%s' "$cron_json" | jq -r '
    "  • \(.enabled)/\(.total) enabled (\(.disabled) disabled)",
    "  • of the enabled: \(.model_turn_enabled) cost model turns, \(.command_enabled) are deterministic commands"'
fi
if [ "$(printf '%s' "$wedged" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
  printf '%s' "$wedged" | jq -r '.[] | "  • \(if .state=="WEDGED" then "🚨 WEDGED" else "⚠️ unknown" end): `\('"$SAFE_AGENT"')` — \(.why)"'
elif [ -n "$cron_err" ]; then
  # The census failed, so the agent list the wedge check iterates was empty for
  # a READ reason, not because the fleet is healthy. Saying "no wedged agents"
  # here would be a false all-clear on the one signal that catches the outage —
  # the same trap ensure-session-budget-headroom.sh calls out in its header.
  say "  • ⚠️ wedge check did not run — no readable cron census to check against"
else
  say "  • ✅ no wedged agents (every agent with enabled crons has :cron: session keys)"
fi
say ""

# audit
say "*Tool actions by agent* (audit ring sample — relative share, NOT a weekly total)"
audit_err=$(section_error "$audit_json")
if [ -n "$audit_err" ]; then
  say "  • ⚠️ $audit_err"
else
  printf '%s' "$audit_json" | jq -r '
    "  • sample: \(.tool_actions) tool actions across \(.sampled_events) events"
      + (if .truncated then " — ⚠️ ring TRUNCATED at the limit; older activity is missing" else "" end),
    (.by_agent[]? | "  • `\('"$SAFE_AGENT"')`: \(.actions)")'
fi
exit 0
