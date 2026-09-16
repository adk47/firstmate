#!/usr/bin/env bash
# ensure-session-budget-headroom.sh — page BEFORE either of openclaw's per-agent
# session-maintenance reapers (disk budget OR entry cap) starts cannibalising
# cron sessions and silently kills an agent's entire cron surface.
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
#   --check (read-only detector, for cron-health-watchdog.sh / CI): prints one
#     "  - [SEV] <profile>/<agent>: …" line per finding and exits on the repo
#     guard convention (0 clean / 1 violation / 2 err):
#       1  any CRITICAL or WARN was CONFIRMED — pages, even if another profile
#          could not be evaluated (that profile is listed as UNEVALUATED in the
#          same output, so the page says what was and was not checked)
#       2  nothing confirmed but something could NOT be evaluated
#       0  everything evaluated and clean
#     Completeness and severity are INDEPENDENT: an unreachable edge gateway must
#     never suppress a confirmed main/operations page.
#
# ── TWO reapers, not one (2026-08-14 scout outage, issue #829) ──────────────
# The guard originally checked only the DISK half above, even though the
# invariant it documents names both caps. That gap produced a second outage and
# then misdirected its diagnosis: main/scout lost its cron surface while sitting
# at 754,813,973 B — 0.70GiB, 17.6% of its 4gb maxDiskBytes. The disk reaper was
# never involved. The ENTRY reaper was:
#
#   capEntryCount(store, maxEntries):
#     maxRemovableEntries = max(0, maxEntries - protectedCount)
#     toRemove = <non-protected keys>.slice(maxRemovableEntries)
#
# scout held 1,145 protected Slack thread keys (1,140 of them in one channel —
# #company-finder, its own cron's delivery target) against maxEntries 1000, so
# maxRemovableEntries was 0 and the slice was the ENTIRE removable set: every
# ":cron:" key, deleted on every store load. Evidence at the time: 234 `.deleted.`
# tombstones in two days versus 1 for healthy `qa`.
#
# The two reapers are independent and either one alone wedges a cron surface, so
# EVERY check must be scoped to its own reaper. In particular an unset
# maxDiskBytes makes only the byte checks dormant — `maxEntries` defaults rather
# than disabling (DEFAULT_SESSION_MAX_ENTRIES), so it is never dormant.
#
# ── Findings ────────────────────────────────────────────────────────────────
#   CRITICAL  agent sessions bytes > maxDiskBytes
#             (the disk reaper is already eating cron entries)
#   CRITICAL  agent PROTECTED entry count >= maxEntries
#             (the entry reaper can spare nothing removable — issue #829)
#   CRITICAL  agent has >=1 ENABLED cron that HAS FIRED under its current
#             registration, but ZERO **base** ":cron:<jobId>" keys
#             (the decisive wedge signature — this is what a live outage looks
#             like, and what would have caught 2026-07-27 on day one. "Base"
#             excludes the ":run:<runId>" children, which openclaw 2.0's cron
#             reaper deletes after cron.sessionRetention (24h default) as
#             designed — see _cron_key_count for why counting them together
#             made this read as a false positive on 2026-09-16)
#   WARN      agent sessions bytes > SESSION_BUDGET_WARN_RATIO * maxDiskBytes
#   WARN      agent protected entries > SESSION_BUDGET_WARN_RATIO * maxEntries
#
# The entry-cap findings count PROTECTED entries, never total entries: an agent
# far above maxEntries in total is healthy if its removable keys absorb the cap,
# whereas protected growth alone is what starves it. Both are scoped to agents
# owning enabled MODEL-TURN crons — a cron surface is what these reapers can
# destroy, and only model-turn crons have a ":cron:" session key to lose
# (`payload.kind:"command"` jobs never create one, so counting them would page a
# healthy agent forever; see _enabled_cron_counts).
#
# A configured `maxEntries` of 0 is NOT dormant — upstream's `?? DEFAULT` fills
# only a nullish value, so 0 stands and pins maxRemovableEntries at 0, the
# maximal wedge. A `maxEntries` that is not a non-negative integer is a profile-
# level UNEVALUATED, never an abort: it feeds bash arithmetic, whose errors are
# fatal to the subshell collect_findings runs in.
#
# An UNREADABLE sessions.json on a cron-owning agent is neither of those: it is a
# read error (exit 2), never a silent "clean". Treating it as zero cron keys
# would page a permissions blip as an outage; treating it as no-finding would be
# a false all-clear on the one signal that catches the outage.
#
# ── Env overrides (used by scripts/tests/ensure-session-budget-headroom.bats) ──
#   SESSION_BUDGET_PROFILES    space-separated profiles (default "main edge")
#   SESSION_BUDGET_WARN_RATIO  warn threshold as a fraction (default 0.8)
#   SESSION_BUDGET_STATE_ROOT  parent of the per-profile state dirs; the state
#                              dir is "<root>/.openclaw-<profile>" (default "/root")
#   `openclaw` is resolved from PATH so tests can stub it.
#
# ── openclaw >= 2026.8 (sessions.json is gone there) ──────────────────────────
# session.maintenance's two caps (maxDiskBytes / maxEntries) and the config
# file they live in are unchanged on 2.0, so the config reads below stay
# runtime-agnostic. What moves is the DATA the reapers act on: 7.1 keeps it in
# each agent's agents/<id>/sessions/sessions.json; 2026.8+ has no such file —
# session storage lives in per-agent SQLite, exposed only through
# `openclaw --profile <p> sessions --all-agents --json`
# (-> {stores:[{agentId,path}], sessions:[...], count, totalCount, hasMore,
# ...}). Every collector that used to read sessions.json directly
# (_agent_dirs, the per-agent byte count, _cron_key_count,
# _protected_key_count) is therefore runtime-gated: below 2026.8 they keep
# reading the file tree exactly as before; at/above it they read this ONE
# cached CLI call instead, and the byte count stats the single SQLite file
# `stores[].path` names rather than summing a directory.
#
# Staging-verified on a live 2026.8.1 gateway (2026-08-31):
#  - The CLI PAGINATES: default `--limit` is 100 (a 1758-entry profile came
#    back as count:100, totalCount:1758). Un-limited, that undercounts every
#    per-agent metric silently — a false-clean, exactly the failure class this
#    guard exists to prevent. `_sessions_json` therefore always passes
#    `--limit all` (verified: returns count==totalCount, hasMore:false), AND
#    `collect_findings` treats a still-partial response (hasMore==true or
#    count!=totalCount) as UNEVALUATED rather than trusting a partial page.
#  - Entry `.key` is exactly the 7.1 format (`agent:<id>:slack:channel:<c>:
#    thread:<ts>`, `agent:<id>:cron:...`), so the ":cron:"/":thread:|:channel:
#    |:group:" key-pattern matchers below are the VERIFIED classification
#    mechanism — the same convention prune-completed-slack-thread-sessions.sh
#    already relies on. `chatType` does NOT exist on 2.0 entries (both
#    `.chatType` and `.origin.chatType` sampled null on every live entry;
#    real fields are abortedLastRun, acpRuntime, ageMs, agentId, agentRuntime,
#    contextTokens, inputTokens, key, kind, label, lastInteractionAt, model,
#    modelProvider, outputTokens, sessionId, sessionStartedAt, status,
#    systemSent, totalTokens, totalTokensFresh, updatedAt, visibility) — the
#    chatType fallback branch below is dead code on 2.0 (kept only because it
#    is harmless: `// ""` degrades to the key-pattern test either way) and
#    must not be read as evidence chatType is part of the 2.0 shape.
#
# set -uo pipefail (NOT -e): report mode must never abort before its exit 0.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=version-compare.sh
source "$SCRIPT_DIR/version-compare.sh"

PROFILES="${SESSION_BUDGET_PROFILES:-main edge}"
WARN_RATIO="${SESSION_BUDGET_WARN_RATIO:-0.8}"
STATE_ROOT="${SESSION_BUDGET_STATE_ROOT:-/root}"

# bash arithmetic is integer-only, so the warn thresholds scale by 100 rather
# than multiplying by a fractional ratio (which would silently truncate to 0).
WARN_RATIO_PCT="$(printf '%s' "$WARN_RATIO" | awk '{printf "%d", $1 * 100}')"

# Resolved once so every collector below reads a consistent runtime answer
# instead of shelling out repeatedly. An UNPARSEABLE runtime is NOT guessed
# either direction: guessing < 2026.8 on an actual 2.0 box would run the old
# file-tree checks against a layout (agents/*/sessions/sessions.json) that no
# longer exists there — _agent_dirs finds zero agents, and collect_findings
# reports a false "clean" with real budget/eviction risk unevaluated (the
# exact failure class this guard exists to avoid). collect_findings instead
# emits an explicit UNEVALUATED finding per profile and skips guessing.
RUNTIME_VER="$(openclaw_runtime_version)"
SESSION_BUDGET_2026_8_PLUS=0
SESSION_BUDGET_RUNTIME_UNKNOWN=0
if [ -z "$RUNTIME_VER" ]; then
  SESSION_BUDGET_RUNTIME_UNKNOWN=1
elif version_at_least "2026.8" "$RUNTIME_VER"; then
  SESSION_BUDGET_2026_8_PLUS=1
fi

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
      # "%.0f", NOT "%d": awk %d goes through an integer conversion that clamps
      # at INT32_MAX (2147483647) on older mawk builds, which would silently
      # read a "4gb" cap as ~2GiB and drag the 80% warn line down with it.
      # %.0f stays in double precision — exact for integers well past any
      # plausible budget. (node-8 runs mawk 1.3.4, which does NOT clamp; this is
      # portability hardening, not a live bug.) Same reason on _dir_bytes below.
      printf "%.0f", num * mult
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

# openclaw's fallback when session.maintenance.maxEntries is absent
# (store-*.js: `maxEntries: maintenance?.maxEntries ?? DEFAULT_SESSION_MAX_ENTRIES`).
# This is the key asymmetry with the disk half: an absent maxDiskBytes makes
# enforceSessionDiskBudget return early (genuinely dormant), but an absent
# maxEntries just resolves to this default and the reaper runs anyway. Treating
# "unset" as dormant here would be a false all-clear on a live reaper.
DEFAULT_SESSION_MAX_ENTRIES=500

# _max_entries <profile> — print the entry cap actually in force for a profile,
# falling back to openclaw's default when the key is unset. Returns 1 only when
# the config itself cannot be read (same condition as _max_disk_bytes, so one
# UNEVALUATED finding covers both).
_max_entries() {
  local profile="$1" cfg raw
  cfg="$STATE_ROOT/.openclaw-$profile/openclaw.json"
  [ -r "$cfg" ] || return 1
  raw="$(jq -r '.session.maintenance.maxEntries // empty' "$cfg" 2>/dev/null)" || return 1
  [ -n "$raw" ] || { printf '%s' "$DEFAULT_SESSION_MAX_ENTRIES"; return 0; }
  printf '%s' "$raw"
}

# _sessions_json_fetch <profile> / _sessions_json <profile> — the ONE call to
# `openclaw --profile <profile> sessions --all-agents --json --limit all`
# (2026.8+ only) per profile, and every per-agent collector's read of it.
#
# QA bot finding (PR #897 round 2): an in-memory associative-array cache is
# USELESS here — every caller reads it through a `$(...)` or `| jq` pipeline
# (e.g. `sessions_raw="$(_sessions_json "$profile")"`, `_sessions_json
# "$profile" | jq ...`), and bash runs BOTH sides of that in a subshell. A
# write to `_SESSIONS_JSON_CACHE` inside a subshell never escapes it, so the
# "cache" always misses and every collector re-issues the real CLI call —
# meaning a transient failure on any LATER call (after the first one
# succeeded and passed the hasMore/count/totalCount check in collect_findings)
# silently starves that one collector's jq input, which reads as "found
# nothing" (clean), not UNEVALUATED. A FILE persists across subshells (they
# share a filesystem), so this fetches to disk exactly once, in the parent
# scope (collect_findings' own frame), before any collector runs, and every
# collector — however deeply piped/subshelled — only ever reads that file.
#
# `--limit all` is NOT optional: the CLI paginates (default --limit is 100; a
# live 1758-entry profile came back as count:100, totalCount:1758 without
# it), and an unlimited call would silently undercount every per-agent metric
# — a false-clean. `--limit all` is staging-verified to return
# count==totalCount, hasMore:false.
_sessions_json_file() { printf '%s/sessions-%s.json' "$SESSION_BUDGET_TMPDIR" "$1"; }

_sessions_json_fetch() {
  local profile="$1" out f
  f="$(_sessions_json_file "$profile")"
  out="$(openclaw --profile "$profile" sessions --all-agents --json --limit all 2>/dev/null)" || true
  printf '%s' "$out" > "$f"
}

# _sessions_json <profile> — prints the fetched file's contents, or empty if
# the fetch was never run / failed / returned nothing. Never issues a call
# itself — callers must call `_sessions_json_fetch` first (collect_findings
# does this once per profile, ahead of every collector).
_sessions_json() {
  local profile="$1" f
  f="$(_sessions_json_file "$profile")"
  [ -r "$f" ] && cat "$f" || printf ''
}

# _agent_dirs <profile> — print each agent id that owns session storage.
# 7.1: each agent with a sessions/ dir. 2026.8+: sessions.json is gone, so
# this reads the `stores[]` list _sessions_json cached instead — a failed/
# empty call therefore enumerates ZERO agents here, which is why
# collect_findings checks _sessions_json itself (not just this function's
# output) before trusting an empty agent list as "nothing to report".
_agent_dirs() {
  local profile="$1" d
  if [ "$SESSION_BUDGET_2026_8_PLUS" -eq 1 ]; then
    _sessions_json "$profile" | jq -r '.stores[]?.agentId // empty' 2>/dev/null
    return
  fi
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
    | awk '{s += $1} END {printf "%.0f", s + 0}'
}

# _agent_bytes <profile> <agent> — bytes used by one agent's session storage,
# runtime-aware. 7.1 sums the sessions/ directory (_dir_bytes, matching the
# reaper's own per-file accounting). 2026.8+ has no such directory to sum —
# session storage is the single SQLite file the `stores[]` entry for this
# agent names — so this stats that one file instead. Prints -1 (same sentinel
# as _cron_key_count/_protected_key_count) when the agent's store path is
# absent or unreadable — QA bot finding (PR #897 round 3): this used to
# `return 0` with NO stdout, which the caller's `[ -n "$bytes" ]` guard reads
# as "nothing to check" and silently skips — an agent whose SQLite path
# vanished (deleted, permission change, disk issue) then reports no finding
# at all, i.e. false-clean disk headroom, instead of UNEVALUATED. Every agent
# reaching this function was already enumerated FROM `stores[]` (see
# _agent_dirs), so a missing/unreadable path here is a genuine anomaly, not
# an expected "no store entry" case.
_agent_bytes() {
  local profile="$1" agent="$2" path
  if [ "$SESSION_BUDGET_2026_8_PLUS" -eq 1 ]; then
    path="$(_sessions_json "$profile" | jq -r --arg a "$agent" \
      '.stores[]? | select(.agentId == $a) | .path // empty' 2>/dev/null | head -1)"
    if [ -z "$path" ] || [ ! -r "$path" ]; then
      printf '%s' -1
      return
    fi
    stat "$_STAT_SIZE_FLAG" "$path" 2>/dev/null
    return
  fi
  _dir_bytes "$STATE_ROOT/.openclaw-$profile/agents/$agent/sessions"
}

# _cron_key_count <profile> <agent> — number of BASE cron session keys for this
# agent. 7.1: reads the agent's sessions.json. 2026.8+: filters the cached
# `sessions --all-agents --json` array by agentId instead (see the header
# comment on the `.sessions[]` shape assumption). Prints -1 when the source is
# unreadable/unparseable so callers can distinguish "no data" from a genuine
# zero (a genuine zero IS the wedge).
#
# BASE ONLY — this is the whole correctness of the wedge signature. A cron has
# TWO session shapes and they have opposite meanings:
#
#   agent:<id>:cron:<jobId>              the PERSISTENT base session, one per
#                                        job. Losing it IS the wedge: the next
#                                        fire dies at setup with
#                                        CronSessionLifecycleClaimError.
#   agent:<id>:cron:<jobId>:run:<runId>  a PER-RUN session, disposable by
#                                        design. openclaw 2.0's own reaper
#                                        (dist src/cron/session-reaper.ts,
#                                        DEFAULT_RETENTION_MS = 864e5 = 24h,
#                                        knob cron.sessionRetention) deletes
#                                        these on purpose.
#
# Counting both together is why this guard looked like it was false-positiving
# on 2026-09-16: an agent whose crons run less often than daily has zero `:run:`
# children and the combined count reads 0 even while its base sessions are
# intact. Measured on live main the same day, base vs run:
#
#     ceo 0/0   clio 2/1   cmo 0/0   cto 12/0   devops 3/4
#     finance 1/1   operations 6/32   qa 522/12   scout 2/1
#
# operations/caroline-weekly-rollup, operations/credit-fleet-fraud-scan-weekly,
# finance/daily-dispute-handler and cto/caroline-autonomy-improver all hold a
# BASE session while running far less often than daily — the reaper never
# touches it. ceo and cmo were the only agents with enabled crons and NO base
# session, i.e. genuinely wedged, which is what the guard had been saying.
#
# So do NOT "fix" this by gating on how long ago the cron last ran. That models
# per-run expiry as base-session loss and suppresses the one signature that
# catches the outage; it was proposed, built, and rejected on PR #946.
_cron_key_count() {
  local profile="$1" agent="$2"
  if [ "$SESSION_BUDGET_2026_8_PLUS" -eq 1 ]; then
    _sessions_json "$profile" | jq -r --arg a "$agent" '
      [ .sessions[]? | select(.agentId == $a) | (.key // "")
        | select(type == "string" and test(":cron:") and (test(":run:") | not)) ] | length' \
      2>/dev/null || printf '%s' -1
    return
  fi
  local f="$STATE_ROOT/.openclaw-$profile/agents/$agent/sessions/sessions.json"
  [ -r "$f" ] || { printf '%s' -1; return; }
  jq -r '(.entries // .)
         | (if type == "object" then keys else [.[].key] end)
         | [ .[] | select(type == "string" and test(":cron:") and (test(":run:") | not)) ] | length' \
    "$f" 2>/dev/null || printf '%s' -1
}

# _protected_key_count <profile> <agent> — number of NON-REMOVABLE keys in the
# agent's sessions.json, mirroring openclaw's isProtectedSessionMaintenanceEntry:
# a threadId in the key, an external group/channel key, or an entry whose
# chatType is group/channel/thread. Prints -1 when unreadable/unparseable.
#
# This — not the total entry count — is the quantity that starves the reaper.
# capEntryCount removes `keys.slice(maxRemovableEntries)` where
# `maxRemovableEntries = max(0, maxEntries - protectedCount)`, so an agent can
# sit far ABOVE maxEntries in total and stay healthy (the cap just trims its
# removable keys), while an agent whose PROTECTED count alone reaches maxEntries
# loses every removable key on every load. Counting totals would page the
# healthy case and miss nothing the protected count does not already catch.
_protected_key_count() {
  local profile="$1" agent="$2"
  if [ "$SESSION_BUDGET_2026_8_PLUS" -eq 1 ]; then
    _sessions_json "$profile" | jq -r --arg a "$agent" '
      [ .sessions[]? | select(.agentId == $a)
        | select((.key | type == "string")
              and ((.key | test(":thread:|:channel:|:group:"))
                   or (((.chatType // .origin.chatType // "")
                        | ascii_downcase) as $c
                       | $c == "group" or $c == "channel" or $c == "thread"))) ]
      | length' \
      2>/dev/null || printf '%s' -1
    return
  fi
  local f="$STATE_ROOT/.openclaw-$profile/agents/$agent/sessions/sessions.json"
  [ -r "$f" ] || { printf '%s' -1; return; }
  jq -r '(.entries // .)
         | (if type == "object" then to_entries else map({key: .key, value: .}) end)
         | [ .[] | select((.key | type == "string")
               and ((.key | test(":thread:|:channel:|:group:"))
                    or (((.value.chatType // .value.origin.chatType // "")
                         | ascii_downcase) as $c
                        | $c == "group" or $c == "channel" or $c == "thread"))) ]
         | length' \
    "$f" 2>/dev/null || printf '%s' -1
}

# _enabled_cron_counts <profile> — print "<agentId> <count>" per agent that owns
# at least one ENABLED MODEL-TURN cron. Returns 1 when the gateway query fails,
# so an unreachable gateway is a read error (exit 2) rather than a silent
# all-clear.
#
# `payload.kind:"command"` crons are excluded because ONLY model-turn crons ever
# get a ":cron:" session key (same filter, same reason, as
# scripts/hydra-fleet-instrument.sh). Counting them would make every finding
# below wrong in both directions: an agent whose enabled crons are ALL command
# kind legitimately has zero ":cron:" keys, so the wedge signature would page it
# as an outage forever (live today: `finance` runs 4 enabled crons, 3 of them
# command kind — disable its one model-turn job and the guard cries wolf), and
# the entry-cap line would claim more cron sessions are at risk than exist.
# `.payload.kind?` (optional) so a non-object payload degrades to "kept" instead
# of erroring the whole inventory into UNEVALUATED.
_enabled_cron_counts() {
  local profile="$1" out
  out="$(openclaw --profile "$profile" cron list --all --json 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  # Third field = how many of that agent's enabled model-turn crons have FIRED
  # under their CURRENT registration (a numeric lastRunAtMs). It rides this
  # existing call rather than a second `cron list`, which would be a second
  # chance to disagree with the first.
  #
  # `fired` must be built as a NULLABLE field, never a filtered stream: jq's
  # `numbers` yields EMPTY on a non-match and an `empty` inside an object
  # constructor deletes the WHOLE object, which silently drops the agent from
  # this inventory and takes its entry-cap CRITICAL and WARN with it. That
  # exact bug was written and caught on this PR — see
  # docs/lessons/working-in-hydra.md.
  printf '%s' "$out" | jq -r '
      (.jobs // [])
      | map(select(.enabled == true and ((.payload.kind? // "") != "command"))
            | { agent: (.agentId // "default"),
                ran: ([ .lastRunAtMs?, .state?.lastRunAtMs? ] | map(numbers) | .[0]) })
      | group_by(.agent)[]
      | "\(.[0].agent) \(length) \([ .[].ran | numbers ] | length)"' 2>/dev/null || return 1
}

# collect_findings — emit "SEV<TAB>profile/agent<TAB>message" per finding on
# stdout, where SEV is CRITICAL, WARN, or UNEVALUATED.
#
# COMPLETENESS AND SEVERITY ARE INDEPENDENT AXES — do not collapse them.
# An earlier version made the return code sticky-upwards (a read error outranked
# a violation). That inverted the guard's whole purpose: with edge unreachable
# and main/operations genuinely wedged, it returned 2, the watchdog treats 2 as
# log-only, and the confirmed outage NEVER PAGED — it was not even printed.
# So: a profile we could not evaluate is emitted as its own UNEVALUATED finding
# (it is never silently dropped), while findings we DID confirm still drive the
# exit code. Precedence is therefore violation-first:
#   1  any CRITICAL/WARN  -> page, and list any UNEVALUATED profiles alongside
#   2  only UNEVALUATED   -> nothing confirmed, cannot claim clean either
#   0  nothing at all     -> clean
collect_findings() {
  local viol=0 uneval=0 profile agent maxb bytes warn_at ckeys ecount
  local maxe pkeys entry_warn_at disk_dormant cfired
  local sessions_raw sessions_hasmore sessions_count sessions_totalcount
  for profile in $PROFILES; do
    [ -n "$profile" ] || continue
    [ -d "$STATE_ROOT/.openclaw-$profile" ] || continue

    if [ "$SESSION_BUDGET_RUNTIME_UNKNOWN" -eq 1 ]; then
      printf 'UNEVALUATED\t%s\tcould not determine openclaw runtime version ("openclaw --version" returned nothing/unparseable) — refusing to guess whether the 7.1 file-tree checks or the 2026.8+ sessions-API checks apply to this profile\n' \
        "$profile"
      uneval=1
      continue
    fi

    maxb="$(_max_disk_bytes "$profile")" || {
      printf 'UNEVALUATED\t%s\tcannot read %s/.openclaw-%s/openclaw.json — budget for this profile is UNKNOWN\n' \
        "$profile" "$STATE_ROOT" "$profile"
      uneval=1; continue
    }
    # Same file, same failure condition — already reported above, so this cannot
    # fail on its own once _max_disk_bytes succeeded.
    maxe="$(_max_entries "$profile")" || maxe=""

    # 2026.8+: sessions.json is gone, so every per-agent check below reads
    # through _sessions_json instead. A failed/empty CLI call makes
    # _agent_dirs enumerate zero agents, which would otherwise look like a
    # profile with nothing to report — check the call itself first so that
    # reads as UNEVALUATED, not a false "clean", same shape as the maxb read
    # failure above.
    if [ "$SESSION_BUDGET_2026_8_PLUS" -eq 1 ]; then
      # The ONE real CLI call for this profile, run directly (not inside a
      # `$(...)`/pipe) so its file write lands in this frame, not a
      # subshell that discards it. Every collector below reads the file via
      # `_sessions_json`, however deeply it pipes/subshells that read.
      _sessions_json_fetch "$profile"
      sessions_raw="$(_sessions_json "$profile")"
      if [ -z "$sessions_raw" ]; then
        printf 'UNEVALUATED\t%s\t"openclaw --profile %s sessions --all-agents --json --limit all" failed or returned nothing — session budget/eviction signals for this profile are UNKNOWN (disk config was readable, but there is no per-agent data to check it against)\n' \
          "$profile" "$profile"
        uneval=1
        continue
      fi

      # Schema gate FIRST, before the completeness/paranoia gate below. QA
      # bot finding (PR #897 round 5): a malformed-but-counter-consistent
      # response — `{"stores":null,"sessions":null,"count":0,"totalCount":0,
      # "hasMore":false}` — passes hasMore/count/totalCount cleanly (0==0,
      # hasMore false), yet `.stores`/`.sessions` are null, not arrays.
      # `_agent_dirs`'s `.stores[]?` then iterates null as "nothing" (the
      # `?` suppresses the type error), so zero agents get enumerated and
      # the profile silently reads as "nothing to check" = CLEAN, even
      # though the whole snapshot is unusable. Validate the FULL shape —
      # .stores/.sessions must be arrays, .count/.totalCount numbers,
      # .hasMore a boolean — fail-closed (UNEVALUATED) on ANY null, absent,
      # or wrong-typed field before trusting the snapshot at all.
      sessions_schema_ok="$(printf '%s' "$sessions_raw" | jq -r '
        (has("stores") and (.stores | type == "array"))
        and (has("sessions") and (.sessions | type == "array"))
        and (has("count") and (.count | type == "number"))
        and (has("totalCount") and (.totalCount | type == "number"))
        and (has("hasMore") and (.hasMore | type == "boolean"))
      ' 2>/dev/null)"
      if [ "$sessions_schema_ok" != "true" ]; then
        printf 'UNEVALUATED\t%s\t"openclaw --profile %s sessions --all-agents --json --limit all" returned a response with a missing/null/wrong-typed field (stores/sessions must be arrays, count/totalCount numbers, hasMore a boolean) — trusting a malformed snapshot would silently undercount or entirely skip session budget/eviction signals for this profile\n' \
          "$profile" "$profile"
        uneval=1
        continue
      fi

      # Paranoia gate: `--limit all` is supposed to return a complete page
      # (count==totalCount, hasMore:false), but never TRUST that on faith —
      # a partial page silently undercounts every per-agent metric below,
      # which is a false-clean, not a stricter one. Any sign this is a
      # partial page (hasMore true, or count/totalCount mismatch/missing)
      # is UNEVALUATED, same as a failed call.
      sessions_hasmore="$(printf '%s' "$sessions_raw" | jq -r '.hasMore // false' 2>/dev/null)"
      sessions_count="$(printf '%s' "$sessions_raw" | jq -r '.count // "null"' 2>/dev/null)"
      sessions_totalcount="$(printf '%s' "$sessions_raw" | jq -r '.totalCount // "null"' 2>/dev/null)"
      if [ "$sessions_hasmore" != "false" ] || [ "$sessions_count" = "null" ] \
        || [ "$sessions_totalcount" = "null" ] || [ "$sessions_count" != "$sessions_totalcount" ]; then
        printf 'UNEVALUATED\t%s\t"openclaw --profile %s sessions --all-agents --json --limit all" returned a PARTIAL page (hasMore=%s count=%s totalCount=%s) — trusting it would silently undercount session budget/eviction signals for this profile\n' \
          "$profile" "$profile" "$sessions_hasmore" "$sessions_count" "$sessions_totalcount"
        uneval=1
        continue
      fi
    fi

    # maxEntries is taken RAW from the config (unlike maxDiskBytes, which
    # _parse_bytes reduces to digits), and it feeds arithmetic below. Validate it
    # as a bare non-negative integer FIRST: an arithmetic error inside $(( )) is
    # fatal to the command-substitution subshell collect_findings runs in, so a
    # `"maxEntries": "1k"` typo would abandon this profile AND every later one,
    # emit no findings at all, and still return 1 — i.e. page a CRITICAL with an
    # empty body. Reject it as UNEVALUATED instead, and keep the disk half running.
    case "$maxe" in
      ''|*[!0-9]*)
        printf 'UNEVALUATED\t%s\tsession.maintenance.maxEntries is %s, not a non-negative integer — the entry-cap signal for this profile is UNKNOWN (disk checks still ran)\n' \
          "$profile" "${maxe:-<unreadable>}"
        uneval=1
        maxe=""
        ;;
    esac

    disk_dormant=0
    if [ -z "$maxb" ] || [ "$maxb" -le 0 ] 2>/dev/null; then
      # maxDiskBytes unset => enforceSessionDiskBudget returns early, so the DISK
      # half is dormant. The ENTRY cap is a separate reaper that upstream always
      # enforces (it defaults rather than disabling), so this must skip only the
      # byte checks — `continue` here would abandon the profile and blind the
      # guard to exactly the half that fired in #829.
      disk_dormant=1
    fi

    warn_at=$(( ${maxb:-0} * WARN_RATIO_PCT / 100 ))
    entry_warn_at=$(( ${maxe:-0} * WARN_RATIO_PCT / 100 ))

    # Agents that own at least one enabled cron — needed ONLY for the wedge
    # signature. The disk-size checks below are independent of it, so a failed
    # cron inventory must NOT skip them: `continue` here would mean an agent
    # already over maxDiskBytes reports as merely UNEVALUATED (exit 2, watchdog
    # logs without paging). That is the same confirmed-violation suppression the
    # cross-profile precedence rule exists to prevent, one scope level down.
    # Degrade the profile instead of abandoning it: record that the eviction
    # signal is unknown, then still run every check that does not depend on it.
    local enabled_map=""
    local have_inventory=1
    if ! enabled_map="$(_enabled_cron_counts "$profile")"; then
      printf 'UNEVALUATED\t%s\t"openclaw --profile %s cron list --all --json" failed — the cron-eviction signal for this profile is UNKNOWN (disk-size checks still ran)\n' \
        "$profile" "$profile"
      uneval=1
      enabled_map=""        # the failed call may have emitted partial output
      have_inventory=0
    fi

    while read -r agent; do
      [ -n "$agent" ] || continue

      if [ "$disk_dormant" -eq 0 ]; then
        bytes="$(_agent_bytes "$profile" "$agent")"
        if [ "$bytes" = "-1" ]; then
          # QA bot finding (PR #897 round 3): an agent that was enumerated
          # FROM stores[] but whose store path is now absent/unreadable is a
          # genuine anomaly, not "0 bytes used" — report it as UNEVALUATED
          # rather than silently skipping the byte check for this agent.
          printf 'UNEVALUATED\t%s/%s\tsession store path absent or unreadable — disk-budget signal for this agent is UNKNOWN\n' \
            "$profile" "$agent"
          uneval=1
        elif [ -n "$bytes" ]; then
          if [ "$bytes" -gt "$maxb" ]; then
            printf 'CRITICAL\t%s/%s\tsessions %s > maxDiskBytes %s — the reaper is deleting cron session entries; every cron on this agent will claim-error\n' \
              "$profile" "$agent" "$(_human "$bytes")" "$(_human "$maxb")"
            viol=1
          elif [ "$bytes" -gt "$warn_at" ]; then
            printf 'WARN\t%s/%s\tsessions %s > %s%% of maxDiskBytes %s — raise session.maintenance.maxDiskBytes before it crosses\n' \
              "$profile" "$agent" "$(_human "$bytes")" "$WARN_RATIO_PCT" "$(_human "$maxb")"
            viol=1
          fi
        fi
      fi

      # ── Key-based checks ────────────────────────────────────────────────────
      # Both the entry-cap check and the wedge signature only matter for agents
      # that own enabled MODEL-TURN crons: a cron surface is the thing these reapers can
      # destroy. Entry-cap pressure on a chat-only agent is ordinary maintenance,
      # and paging on it would drown the signal that catches the outage.
      # Skipped when the cron inventory could not be read — the profile is
      # already flagged UNEVALUATED above.
      [ "$have_inventory" -eq 1 ] || continue
      ecount="$(printf '%s\n' "$enabled_map" | awk -v a="$agent" '$1 == a {print $2; exit}')"
      [ -n "$ecount" ] && [ "$ecount" -gt 0 ] || continue
      # How many of them have fired under their current registration.
      cfired="$(printf '%s\n' "$enabled_map" | awk -v a="$agent" '$1 == a {print $3; exit}')"
      case "$cfired" in ''|*[!0-9]*) cfired=0 ;; esac

      pkeys="$(_protected_key_count "$profile" "$agent")"
      ckeys="$(_cron_key_count "$profile" "$agent")"
      if [ "$pkeys" = "-1" ] || [ "$ckeys" = "-1" ]; then
        # Unreadable index: NOT a wedge (don't page a permissions blip as an
        # outage) but NOT clean either — reporting nothing would be a false
        # all-clear on the one signal that actually catches the outage.
        printf 'UNEVALUATED\t%s/%s\tsessions.json unreadable — entry-cap and cron-eviction signals for this agent are UNKNOWN\n' \
          "$profile" "$agent"
        uneval=1
        continue
      fi

      # Entry-cap half: capEntryCount removes keys.slice(maxRemovableEntries)
      # with maxRemovableEntries = max(0, maxEntries - protectedCount). Once the
      # PROTECTED footprint alone reaches maxEntries that slice is the whole
      # removable set, so every ":cron:" key dies on each store load — no matter
      # how far under maxDiskBytes the agent sits. This is the #829 signature.
      # No `maxe > 0` guard: a configured 0 is NOT dormant. Upstream's
      # `?? DEFAULT_SESSION_MAX_ENTRIES` only fills a NULLISH value, so 0 stands
      # and pins maxRemovableEntries at max(0, 0 - protectedCount) = 0 — the
      # maximal wedge, every removable key deleted on every load. `pkeys >= maxe`
      # is trivially true there, so the CRITICAL branch covers it; treating it as
      # dormant reported a fleet-wide cron kill as "clean".
      if [ -n "$maxe" ]; then
        if [ "$pkeys" -ge "$maxe" ]; then
          # Report the ENABLED-CRON count as what is at risk, never as a count of
          # ":cron:" keys present — this finding fires alongside the wedge line,
          # which reports ZERO keys, and two numbers that read as the same
          # quantity but disagree is how #829 got misdiagnosed in the first place.
          printf 'CRITICAL\t%s/%s\t%s protected (non-removable) entries >= maxEntries %s — capEntryCount can spare NOTHING, so the ":cron:" session key for every one of this agent'"'"'s %s enabled model-turn cron(s) is deleted on each store load; raise session.maintenance.maxEntries\n' \
            "$profile" "$agent" "$pkeys" "$maxe" "$ecount"
          viol=1
        elif [ "$pkeys" -gt "$entry_warn_at" ]; then
          # State the REMAINING removable slots, not just the ratio: capEntryCount
          # keeps only the first maxRemovableEntries removable keys, so eviction
          # begins as soon as that number drops below the agent's removable set —
          # well before the protected count reaches the cap. A WARN that only says
          # "before it crosses" would read as "nothing has happened yet" while
          # cron keys are already being trimmed.
          printf 'WARN\t%s/%s\t%s protected entries > %s%% of maxEntries %s — only %s removable slot(s) left for %s enabled model-turn cron(s); raise session.maintenance.maxEntries\n' \
            "$profile" "$agent" "$pkeys" "$WARN_RATIO_PCT" "$maxe" \
            "$(( maxe - pkeys ))" "$ecount"
          viol=1
        fi
      fi

      # Wedge signature: owns enabled crons that HAVE FIRED under their current
      # registration, yet has no base cron session.
      #
      # The "have fired" half is load-bearing, and it is why this reported
      # main/ceo and main/cmo on 2026-09-16 while both were fine. A base session
      # is created BY a run (dist isolated-agent-*.js resolves
      # `cron:${input.job.id}` inside the run path), and it is deleted with its
      # owning job id (`removeCronJobBaseSession`: "Removes the reusable base
      # session whose owning isolated cron job was deleted"). Declaration-keyed
      # crons — every `skill-collection-review-<agent>` — are re-registered with
      # a FRESH uuid on every boot, so after a restart the old base session goes
      # with the old job id and the new job legitimately has none until it fires.
      # Verified after the 09:41Z restart: all nine skill-collection-review jobs
      # showed lastRunAtMs ABSENT with next fires days out, and the only agents
      # flagged were ceo and cmo because a declaration-keyed cron is the ONLY
      # cron each of them owns. Proof that the first fire is enough:
      # operations/support-email-triage-hourly held a base session for a job that
      # had run since that same restart.
      #
      # So a job with no run under its current id tells us nothing, and paging on
      # it makes every restart an outage for every weekly cron. Only a job that
      # HAS fired and still has no base session is evidence of eviction.
      if [ "$ckeys" = "0" ] && [ "${cfired:-0}" -gt 0 ]; then
        printf 'CRITICAL\t%s/%s\t%s enabled model-turn cron(s) but ZERO ":cron:" session keys — cron sessions have been evicted; fires will die at setup with CronSessionLifecycleClaimError\n' \
          "$profile" "$agent" "$ecount"
        viol=1
      fi
    done < <(_agent_dirs "$profile")
  done
  # Violation-first: a confirmed finding must page even when some other profile
  # could not be evaluated (that profile is already in the output as
  # UNEVALUATED, so the page says what was and was not checked).
  [ "$viol" -eq 1 ] && return 1
  [ "$uneval" -eq 1 ] && return 2
  return 0
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

# _emit_findings <findings> [stream] — print one "  - [SEV] target: msg" line per
# finding. ALWAYS called whenever there is anything to say, whether the overall
# result is a violation or only an unevaluated profile: a finding that was
# collected but never printed is indistinguishable from one that was never found.
_emit_findings() {
  printf '%s\n' "$1" | while IFS=$'\t' read -r sev target msg; do
    [ -n "$target" ] || continue
    echo "  - [$sev] $target: $msg"
  done
}

main() {
  local mode="${1:-report}" findings rc
  # Backs _sessions_json_fetch/_sessions_json's file-based per-profile cache
  # (see their comment): a real file, not a bash variable, so the write
  # survives every collector's `$(...)`/pipe subshell.
  SESSION_BUDGET_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/session-budget-headroom.XXXXXX")"
  trap 'rm -rf "$SESSION_BUDGET_TMPDIR"' EXIT
  findings="$(collect_findings)"; rc=$?

  case "$mode" in
    --check|check)
      if [ "$rc" -eq 1 ]; then
        # Violations win over incomplete evaluation. Any UNEVALUATED profile is
        # already in $findings, so the page states exactly what was and was not
        # checked instead of swallowing the confirmed outage.
        log "SESSION BUDGET HEADROOM VIOLATION:"
        _emit_findings "$findings"
        log "Fix: raise the cap the finding above actually names — session.maintenance.maxEntries for a protected-entry finding, maxDiskBytes (and highWaterBytes) for a bytes finding. TWO independent reapers evict cron sessions, so an agent can be wedged on the entry cap while sitting at a fraction of its disk budget (issue #829: main/scout, 17.6% of maxDiskBytes). Raising the cap that is not binding changes nothing. Land the values in openclaw-main.json / openclaw-edge.json, then apply live with 'openclaw --profile <p> config set …' + a gateway restart (the running daemon caches the budget). NEVER run 'openclaw doctor --fix' (codex-auth fan-out)."
        return 1
      fi
      if [ "$rc" -eq 2 ]; then
        log "ERROR: could not evaluate session budget headroom (nothing confirmed, but NOT clean):"
        _emit_findings "$findings"
        return 2
      fi
      log "clean: every agent is under maxDiskBytes AND maxEntries, and no cron surface is evicted ($PROFILES)"
      return 0
      ;;
    report|"")
      if [ "$rc" -eq 1 ]; then
        log "session budget findings (report mode — not blocking start):"
        _emit_findings "$findings" >&2
      elif [ "$rc" -eq 2 ]; then
        log "WARNING: could not evaluate session budget headroom (continuing):"
        _emit_findings "$findings" >&2
      else
        log "clean: every agent is under maxDiskBytes AND maxEntries ($PROFILES)"
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
