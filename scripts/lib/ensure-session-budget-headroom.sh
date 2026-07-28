#!/usr/bin/env bash
# ensure-session-budget-headroom.sh — page BEFORE openclaw's per-agent session
# disk-budget reaper starts cannibalising cron sessions and silently kills an
# agent's entire cron surface.
#
# ── The bug this closes (2026-07-27 → 07-28 operations cron outage) ──────────
# openclaw 7.1's `enforceSessionDiskBudget`
# (/usr/lib/node_modules/openclaw/dist/store-*.js) is PER-AGENT —
# `const sessionsDir = path.dirname(params.storePath)`. When an agent's sessions
# dir exceeds `session.maintenance.maxDiskBytes` it deletes removable FILES to
# get back under highWaterBytes; when the removable set is exhausted and it is
# still over, it falls through to deleting session store ENTRIES:
#
#     delete params.store[key]
#
# oldest-updatedAt first, skipping only the active key and
# `shouldPreserveMaintenanceEntry`. Slack conversation keys are PROTECTED;
# `agent:<id>:cron:<jobId>` keys are NOT. So once an agent's irreducible
# (all-referenced, all-protected) footprint crosses maxDiskBytes, every sweep
# deletes ALL of that agent's cron session entries — and every subsequent cron
# fire dies at SETUP in ~1.1s with:
#
#     CronSessionLifecycleClaimError: Session "agent:<id>:cron:<jobId>"
#     changed while starting work. Retry.
#
# The `Retry.` is advisory — openclaw does NOT retry, the run is dropped. This
# is restart-immune (re-deleted on the next agent turn) and does NOT self-heal.
#
# On 2026-07-27 the `operations` agent crossed 512mb and ALL 8 of its enabled
# crons died for ~25h: support-email-triage-hourly, credit-verification-batch,
# both codex-usage-report DMs, systemic-data-issue-report, caroline-daily-review,
# caroline-weekly-rollup, credit-fleet-fraud-scan. Census at the time:
# 445 protected Slack entries / ZERO cron entries (healthy `qa`: 117 / 49).
#
# ── Why this keeps happening ────────────────────────────────────────────────
# This is the SIBLING of the `maxEntries` wedge (PR #694, raised 100 → 1000).
# Both share one structural flaw: openclaw NEVER auto-prunes protected Slack
# threads, so an agent's protected footprint grows WITHOUT BOUND. Any fixed
# budget is therefore eventually crossed, after which the reaper eats cron
# sessions. Raising the budget buys time; it is not a permanent fix. The
# standing invariant is:
#
#     BOTH session.maintenance.maxDiskBytes AND maxEntries must stay above
#     each agent's PEAK PROTECTED footprint, which only ever grows.
#
# ── Why this guard cannot self-heal ─────────────────────────────────────────
# Unlike ensure-codex-auth.sh / ensure-codex-version-pinned.sh / ensure-secret-
# perms.sh, there is no convergent target to re-assert: choosing a new budget is
# a SIZING decision (headroom vs. disk), and silently raising a cap in response
# to growth would just defer the same outage with no human ever informed. So
# this script is DETECT-AND-PAGE ONLY. It reports; a human re-sizes.
#
# ── Modes ───────────────────────────────────────────────────────────────────
#   (default / "report"): log findings to stderr and ALWAYS exit 0, so it can sit
#     in ExecStartPre (openclaw-pre-start-heal.sh) without ever blocking a
#     gateway start.
#
#   --check (read-only detector, for cron-health-watchdog.sh / CI): exit 1 if ANY
#     agent is CRITICAL or WARN, printing one "  - <profile>/<agent>: …" line per
#     finding. Exit 0 clean, exit 2 on read error. Matches the repo guard
#     convention (0 clean / 1 violation / 2 err).
#
# ── Findings ────────────────────────────────────────────────────────────────
#   CRITICAL  agent sessions bytes > maxDiskBytes
#             (the reaper is already eating cron entries)
#   CRITICAL  agent has >=1 ENABLED cron but ZERO ":cron:" keys in sessions.json
#             (the decisive wedge signature — this is what a live outage looks
#             like, and what would have caught 2026-07-27 on day one)
#   WARN      agent sessions bytes > SESSION_BUDGET_WARN_RATIO * maxDiskBytes
#
# ── Env overrides (used by scripts/tests/ensure-session-budget-headroom.bats) ──
#   SESSION_BUDGET_PROFILES    space-separated profiles (default "main edge")
#   SESSION_BUDGET_WARN_RATIO  warn threshold as a fraction (default 0.8)
#   SESSION_BUDGET_STATE_ROOT  parent of the per-profile state dirs; the state
#                              dir is "<root>/.openclaw-<profile>" (default "/root")
#   `openclaw` is resolved from PATH so tests can stub it.
#
# set -uo pipefail (NOT -e): report mode must never abort before its exit 0.
set -uo pipefail

PROFILES="${SESSION_BUDGET_PROFILES:-main edge}"
WARN_RATIO="${SESSION_BUDGET_WARN_RATIO:-0.8}"
STATE_ROOT="${SESSION_BUDGET_STATE_ROOT:-/root}"

LOGPREFIX="[ensure-session-budget-headroom $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*" >&2; }

# _parse_bytes <value> — turn openclaw's size syntax ("512mb", "4gb", "1024",
# "512 MB") into an integer byte count on stdout. Prints nothing when the value
# is absent/unparseable, so callers can treat empty as "budget not configured".
# openclaw itself accepts b/kb/mb/gb/tb with binary (1024) multipliers.
_parse_bytes() {
  printf '%s' "${1:-}" | awk '
    {
      s = tolower($0)
      gsub(/[[:space:]]/, "", s)
      if (match(s, /^[0-9]+(\.[0-9]+)?/) == 0) exit 0
      num = substr(s, RSTART, RLENGTH) + 0
      unit = substr(s, RSTART + RLENGTH)
      mult = 1
      if (unit == "" || unit == "b")        mult = 1
      else if (unit == "k" || unit == "kb") mult = 1024
      else if (unit == "m" || unit == "mb") mult = 1024 * 1024
      else if (unit == "g" || unit == "gb") mult = 1024 * 1024 * 1024
      else if (unit == "t" || unit == "tb") mult = 1024 * 1024 * 1024 * 1024
      else exit 0
      printf "%d", num * mult
    }'
}

# _max_disk_bytes <profile> — print the configured maxDiskBytes in bytes for a
# profile, read from the LIVE config so this can never drift from the value
# actually in force. Empty when the key is unset (the reaper is dormant then —
# `if (maxBytes == null || highWaterBytes == null) return null` — so there is
# nothing to guard).
_max_disk_bytes() {
  local profile="$1" cfg raw
  cfg="$STATE_ROOT/.openclaw-$profile/openclaw.json"
  [ -r "$cfg" ] || return 1
  raw="$(jq -r '.session.maintenance.maxDiskBytes // empty' "$cfg" 2>/dev/null)" || return 1
  _parse_bytes "$raw"
}

# _agent_dirs <profile> — print each agent id that has a sessions dir.
_agent_dirs() {
  local profile="$1" d
  for d in "$STATE_ROOT/.openclaw-$profile"/agents/*/sessions; do
    [ -d "$d" ] || continue
    basename "$(dirname "$d")"
  done
}

# stat size flag: GNU coreutils on node-8/CI, BSD stat on the macOS dev host.
# `du -sb` would be simpler but is GNU-only, so it silently returns nothing on
# macOS and every size check degrades to a no-op.
if stat -c%s /dev/null >/dev/null 2>&1; then
  _STAT_SIZE_FLAG='-c%s'
else
  _STAT_SIZE_FLAG='-f%z'
fi

# _dir_bytes <dir> — apparent size in bytes (matches how the reaper sums file
# sizes; `du -s` block counts would overstate it). One batched stat per dir, not
# one per file, so this stays cheap on a 3.5k-file sessions dir.
_dir_bytes() {
  find "$1" -type f -exec stat "$_STAT_SIZE_FLAG" {} + 2>/dev/null \
    | awk '{s += $1} END {printf "%d", s + 0}'
}

# _cron_key_count <profile> <agent> — number of ":cron:" keys in the agent's
# sessions.json. Prints -1 when the file is unreadable/unparseable so callers can
# distinguish "no data" from a genuine zero (a genuine zero IS the wedge).
_cron_key_count() {
  local f="$STATE_ROOT/.openclaw-$1/agents/$2/sessions/sessions.json"
  [ -r "$f" ] || { printf '%s' -1; return; }
  jq -r '(.entries // .)
         | (if type == "object" then keys else [.[].key] end)
         | [ .[] | select(type == "string" and test(":cron:")) ] | length' \
    "$f" 2>/dev/null || printf '%s' -1
}

# _enabled_cron_counts <profile> — print "<agentId> <count>" per agent that owns
# at least one ENABLED cron. Returns 1 when the gateway query fails, so an
# unreachable gateway is a read error (exit 2) rather than a silent all-clear.
_enabled_cron_counts() {
  local profile="$1" out
  out="$(openclaw --profile "$profile" cron list --all --json 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out" | jq -r '
      (.jobs // [])
      | map(select(.enabled == true) | .agentId // "default")
      | group_by(.)[]
      | "\(.[0]) \(length)"' 2>/dev/null || return 1
}

# collect_findings — emit "SEV<TAB>profile/agent<TAB>message" per finding on
# stdout. Returns 2 on a read error that makes the check meaningless.
#
# rc is STICKY-UPWARDS: a read error (2) on one profile must never be downgraded
# to a mere violation (1) by a later profile, or an unreachable gateway would be
# reported as if it had been successfully evaluated.
collect_findings() {
  local rc=0 profile agent maxb bytes warn_at ckeys ecount
  _flag() { [ "$rc" -lt "$1" ] && rc="$1"; return 0; }
  for profile in $PROFILES; do
    [ -n "$profile" ] || continue
    [ -d "$STATE_ROOT/.openclaw-$profile" ] || continue

    maxb="$(_max_disk_bytes "$profile")" || {
      log "ERROR: cannot read $STATE_ROOT/.openclaw-$profile/openclaw.json"
      _flag 2; continue
    }
    if [ -z "$maxb" ] || [ "$maxb" -le 0 ] 2>/dev/null; then
      # maxDiskBytes unset => enforceSessionDiskBudget returns early; dormant.
      continue
    fi
    # bash arithmetic is integer-only, so scale by 100 rather than multiplying
    # by a fractional ratio (which would silently truncate to 0).
    warn_at=$(( maxb * $(printf '%s' "$WARN_RATIO" | awk '{printf "%d", $1 * 100}') / 100 ))

    # Agents that own at least one enabled cron — needed for the wedge signature.
    local enabled_map=""
    if ! enabled_map="$(_enabled_cron_counts "$profile")"; then
      log "ERROR: 'openclaw --profile $profile cron list --all --json' failed"
      _flag 2; continue
    fi

    while read -r agent; do
      [ -n "$agent" ] || continue
      bytes="$(_dir_bytes "$STATE_ROOT/.openclaw-$profile/agents/$agent/sessions")"
      [ -n "$bytes" ] || continue

      if [ "$bytes" -gt "$maxb" ]; then
        printf 'CRITICAL\t%s/%s\tsessions %s > maxDiskBytes %s — the reaper is deleting cron session entries; every cron on this agent will claim-error\n' \
          "$profile" "$agent" "$(_human "$bytes")" "$(_human "$maxb")"
        _flag 1
      elif [ "$bytes" -gt "$warn_at" ]; then
        printf 'WARN\t%s/%s\tsessions %s > %s%% of maxDiskBytes %s — raise session.maintenance.maxDiskBytes before it crosses\n' \
          "$profile" "$agent" "$(_human "$bytes")" \
          "$(printf '%s' "$WARN_RATIO" | awk '{printf "%d", $1 * 100}')" "$(_human "$maxb")"
        _flag 1
      fi

      # Wedge signature: owns enabled crons but has no cron session entries.
      ecount="$(printf '%s\n' "$enabled_map" | awk -v a="$agent" '$1 == a {print $2; exit}')"
      if [ -n "$ecount" ] && [ "$ecount" -gt 0 ]; then
        ckeys="$(_cron_key_count "$profile" "$agent")"
        if [ "$ckeys" = "0" ]; then
          printf 'CRITICAL\t%s/%s\t%s enabled cron(s) but ZERO ":cron:" session keys — cron sessions have been evicted; fires will die at setup with CronSessionLifecycleClaimError\n' \
            "$profile" "$agent" "$ecount"
          _flag 1
        fi
      fi
    done < <(_agent_dirs "$profile")
  done
  return "$rc"
}

# _human <bytes> — compact size for log lines.
_human() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B KiB MiB GiB TiB", u, " ")
    i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d%s" : "%.1f%s"), b, u[i]
  }'
}

main() {
  local mode="${1:-report}" findings rc
  findings="$(collect_findings)"; rc=$?

  case "$mode" in
    --check|check)
      if [ "$rc" -eq 2 ]; then
        log "ERROR: could not evaluate session budget headroom"
        return 2
      fi
      if [ "$rc" -eq 1 ]; then
        log "SESSION BUDGET HEADROOM VIOLATION:"
        printf '%s\n' "$findings" | while IFS=$'\t' read -r sev target msg; do
          [ -n "$target" ] || continue
          echo "  - [$sev] $target: $msg"
        done
        log "Fix: raise session.maintenance.maxDiskBytes (and highWaterBytes) in openclaw-main.json / openclaw-edge.json, land the PR, and apply live with 'openclaw --profile <p> config set …' + a gateway restart (the running daemon caches the budget). NEVER run 'openclaw doctor --fix' (codex-auth fan-out)."
        return 1
      fi
      log "clean: every agent is under maxDiskBytes and no cron surface is evicted ($PROFILES)"
      return 0
      ;;
    report|"")
      if [ "$rc" -eq 1 ]; then
        log "session budget findings (report mode — not blocking start):"
        printf '%s\n' "$findings" | while IFS=$'\t' read -r sev target msg; do
          [ -n "$target" ] || continue
          echo "  - [$sev] $target: $msg" >&2
        done
      elif [ "$rc" -eq 2 ]; then
        log "WARNING: could not evaluate session budget headroom (continuing)"
      else
        log "clean: every agent is under maxDiskBytes ($PROFILES)"
      fi
      return 0
      ;;
    *)
      echo "usage: $(basename "$0") [--check]" >&2
      return 2
      ;;
  esac
}

main "$@"
