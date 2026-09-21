#!/usr/bin/env bats
# Tests for scripts/lib/ensure-session-budget-headroom.sh — the detect-and-page
# guard for openclaw 7.1's per-agent session disk-budget reaper.
#
# The bug it guards (2026-07-27): once an agent's sessions dir crosses
# session.maintenance.maxDiskBytes and the removable file set is exhausted,
# `enforceSessionDiskBudget` falls through to deleting session store ENTRIES.
# Slack keys are protected, `agent:<id>:cron:<jobId>` keys are not — so ALL of
# that agent's cron sessions get evicted and every fire then dies at setup with
# CronSessionLifecycleClaimError. The `operations` agent lost all 8 crons for
# ~25h before anyone connected the dots.
#
# A whole filesystem is faked under $TEST_TMPDIR (SESSION_BUDGET_STATE_ROOT), so
# no test ever reads /root. `openclaw` is PATH-stubbed for `cron list --all
# --json`; ssh is shadowed so an accidental remote call fails loudly
# (memory/feedback_bats_must_stub_openclaw).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/lib/ensure-session-budget-headroom.sh"

# _mk_profile <profile> <maxDiskBytes|"unset"> [maxEntries|"unset"]
#
# maxEntries defaults to "unset" so every pre-existing caller keeps exercising
# the disk half alone.
#
# NOTE: every `local` below declares ONE variable per statement on purpose.
# `local p="$1" dir="…$p"` expands ALL right-hand sides BEFORE performing any of
# the assignments, so $p is still empty when $dir is built — the paths silently
# land in ".openclaw-" and every assertion fails with no visible error.
_mk_profile() {
  local p="$1"
  local max="$2"
  local ents="${3:-unset}"
  local dir="$SESSION_BUDGET_STATE_ROOT/.openclaw-$p"
  mkdir -p "$dir"
  python3 - "$dir/openclaw.json" "$max" "$ents" <<'PY'
import json, sys
path, max_disk, max_entries = sys.argv[1], sys.argv[2], sys.argv[3]
m = {"mode": "enforce"}
if max_disk != "unset":
    m["maxDiskBytes"] = max_disk
if max_entries != "unset":
    m["maxEntries"] = int(max_entries)
json.dump({"session": {"maintenance": m}}, open(path, "w"))
PY
}

# _mk_agent <profile> <agent> <padding-bytes> <cron-key-count> [protected-key-count]
#
# The protected keys are Slack channel+thread keys, which is what openclaw's
# isProtectedSessionMaintenanceEntry actually protects (a `threadId` in the key,
# or chatType group/channel/thread). Default 1 preserves the original fixture.
_mk_agent() {
  local p="$1"
  local a="$2"
  local bytes="$3"
  local cronkeys="$4"
  local protkeys="${5:-1}"
  local d="$SESSION_BUDGET_STATE_ROOT/.openclaw-$p/agents/$a/sessions"
  mkdir -p "$d"
  # sessions.json with N cron keys plus M protected slack keys.
  python3 - "$d/sessions.json" "$cronkeys" "$a" "$protkeys" <<'PY'
import json, sys
path, n, agent, m = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
store = {}
for i in range(m):
    store[f"agent:{agent}:slack:channel:c123:thread:{1000 + i}.0"] = {
        "updatedAt": 1, "chatType": "thread"}
for i in range(n):
    store[f"agent:{agent}:cron:job-{i}"] = {"updatedAt": 1}
open(path, "w").write(json.dumps(store))
PY
  [ "$bytes" -gt 0 ] && head -c "$bytes" /dev/zero > "$d/transcript.jsonl"
  return 0
}

# _set_enabled_crons <agent> <count>
# _set_enabled_crons <agent> <n> [fired]
#
# <fired> = "yes" (default) stamps lastRunAtMs, i.e. these crons HAVE run under
# their current registration. "no" leaves it absent, which is what a
# declaration-keyed cron looks like after a boot regenerates its uuid.
#
# The default is "yes" because every caller below is asserting the genuine
# wedge, and a job with no run under its current id is EXPECTED to have no base
# session — so leaving lastRunAtMs absent would make those tests pass for the
# wrong reason once the fired-gate exists.
_set_enabled_crons() {
  python3 - "$FAKE_CRON_JSON" "$1" "$2" "${3:-yes}" "${4:-}" <<'PY'
import json, sys, time
path, agent, n, fired = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
# 5th arg: sessionTarget. Omitted => field ABSENT, which must default to
# "isolated" (counted), so every pre-existing test keeps its meaning.
target = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None
now = int(time.time() * 1000)
jobs = []
for i in range(n):
    j = {"id": f"j{i}", "enabled": True, "agentId": agent}
    if fired == "yes":
        j["lastRunAtMs"] = now - 3600_000
    if target:
        j["sessionTarget"] = target
    jobs.append(j)
json.dump({"jobs": jobs}, open(path, "w"))
PY
}

# _set_mixed_target_crons <agent> -- one main-target cron and one ISOLATED
# one, both enabled, both fired. The isolated job CAN own a base ":cron:"
# key, so this agent must still page when it has none.
_set_mixed_target_crons() {
  python3 - "$FAKE_CRON_JSON" "$1" <<'PY'
import json, sys, time
path, agent = sys.argv[1], sys.argv[2]
now = int(time.time() * 1000)
jobs = [
    {"id": "jmain", "enabled": True, "agentId": agent,
     "sessionTarget": "main", "lastRunAtMs": now - 3600_000},
    {"id": "jiso", "enabled": True, "agentId": agent,
     "sessionTarget": "isolated", "lastRunAtMs": now - 3600_000},
]
json.dump({"jobs": jobs}, open(path, "w"))
PY
}

# _add_run_keys <profile> <agent> <n> [job]
#
# Appends `agent:<id>:cron:<job>:run:<i>` PER-RUN children to an existing 7.1
# store. These must never count toward the wedge signature: openclaw 2.0's cron
# reaper deletes them after cron.sessionRetention (24h default) by design, so
# their presence or absence says nothing about whether the agent's cron surface
# survived. Only the base `agent:<id>:cron:<job>` key does.
_add_run_keys() {
  local p="$1" a="$2" n="$3" job="${4:-job-0}"
  local f="$SESSION_BUDGET_STATE_ROOT/.openclaw-$p/agents/$a/sessions/sessions.json"
  python3 - "$f" "$a" "$n" "$job" <<'PY'
import json, sys
path, agent, n, job = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
store = json.load(open(path))
for i in range(n):
    store[f"agent:{agent}:cron:{job}:run:{i}"] = {"updatedAt": 1}
open(path, "w").write(json.dumps(store))
PY
}

# ── openclaw >= 2026.8 fixtures ──────────────────────────────────────────────
# On 2.0 sessions.json is gone; the guard reads
# `openclaw --profile <p> sessions --all-agents --json` instead, which in
# production is backed by per-agent SQLite. So the fixture here is a REAL
# sqlite file per agent (not a stub JSON blob) — the `openclaw` stub below
# reads it with node:sqlite and renders the CLI's JSON shape, exercising the
# same node:sqlite path the production code effectively goes through the CLI
# for. Byte-budget padding is a real inserted BLOB row (not appended raw
# bytes), so the db stays a valid file for anything that ever needs to reopen
# it.
#
# _mk_agent_2026_8 <agent> <padding-bytes> <cron-key-count> [protected-key-count]
_mk_agent_2026_8() {
  local a="$1" bytes="$2" cronkeys="$3" protkeys="${4:-1}"
  mkdir -p "$FAKE_SESSIONS_DIR"
  node --experimental-sqlite --no-warnings -e '
    const {DatabaseSync} = require("node:sqlite");
    const [ , dbPath, agent, bytesStr, cronStr, protStr] = process.argv;
    const bytes = parseInt(bytesStr, 10), n = parseInt(cronStr, 10), m = parseInt(protStr, 10);
    const db = new DatabaseSync(dbPath);
    db.exec("CREATE TABLE sessions (key TEXT, chatType TEXT)");
    const ins = db.prepare("insert into sessions (key, chatType) values (?, ?)");
    for (let i = 0; i < m; i++) ins.run(`agent:${agent}:slack:channel:c123:thread:${1000 + i}.0`, "thread");
    for (let i = 0; i < n; i++) ins.run(`agent:${agent}:cron:job-${i}`, null);
    if (bytes > 0) {
      db.exec("CREATE TABLE padding (data BLOB)");
      db.prepare("insert into padding (data) values (?)").run(Buffer.alloc(bytes));
    }
  ' "$FAKE_SESSIONS_DIR/$a.sqlite" "$a" "$bytes" "$cronkeys" "$protkeys"
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  export SESSION_BUDGET_STATE_ROOT="$TEST_TMPDIR/root"
  export SESSION_BUDGET_PROFILES="main"
  export FAKE_CRON_JSON="$TEST_TMPDIR/cron.json"
  export FAKE_SESSIONS_DIR="$TEST_TMPDIR/sessions-2026-8"

  mkdir -p "$TEST_TMPDIR/bin"

  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh call refused ($*)" >&2
exit 99
STUB

  # Fake openclaw: only `cron list --all --json` is used by the guard.
  # $FAKE_CRON_FAIL fails for every profile; $FAKE_CRON_FAIL_PROFILE fails for
  # just one (so a multi-profile run can have one good and one unreachable
  # gateway). Both exercise the read-error path.
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
args="$*"
case "$1" in
  --version) echo "openclaw ${FAKE_OPENCLAW_VERSION:-2026.7.1}"; exit 0 ;;
esac
case "$args" in
  *"cron list --all --json"*)
    [ -n "${FAKE_CRON_FAIL:-}" ] && exit 7
    if [ -n "${FAKE_CRON_FAIL_PROFILE:-}" ]; then
      case "$args" in *"--profile ${FAKE_CRON_FAIL_PROFILE} "*) exit 7 ;; esac
    fi
    cat "$FAKE_CRON_JSON"
    ;;
  *"sessions --all-agents --json"*)
    [ -n "${FAKE_SESSIONS_FAIL:-}" ] && exit 7
    # QA bot finding (PR #897 round 2): the guard must query the sessions
    # CLI exactly ONCE per profile, never re-query per collector. Log every
    # call (for the "exactly once" assertion), and optionally fail every
    # call PAST the first (for the "a later transient failure cannot read
    # as clean" assertion) — a stub that succeeds once then fails.
    [ -n "${FAKE_SESSIONS_CALL_LOG:-}" ] && echo "call" >> "$FAKE_SESSIONS_CALL_LOG"
    if [ -n "${FAKE_SESSIONS_FAIL_AFTER_FIRST:-}" ] && [ -n "${FAKE_SESSIONS_CALL_LOG:-}" ]; then
      [ "$(wc -l < "$FAKE_SESSIONS_CALL_LOG")" -gt 1 ] && exit 7
    fi
    # The production code MUST always send --limit all (the CLI paginates at
    # 100 by default) — assert it here so a regression that drops the flag
    # fails this stub loudly instead of silently under-counting.
    case "$args" in
      *"--limit all"*) ;;
      *) echo "test stub: sessions call is missing --limit all ($args)" >&2; exit 91 ;;
    esac
    # FAKE_SESSIONS_PAGINATED simulates the CLI still returning a partial
    # page (the adversarial/defensive case — the guard must never trust
    # --limit all on faith).
    if [ -n "${FAKE_SESSIONS_PAGINATED:-}" ]; then
      echo '{"stores":[{"agentId":"ops","path":"/nonexistent"}],"sessions":[],"count":100,"totalCount":1758,"hasMore":true}'
      exit 0
    fi
    # FAKE_SESSIONS_NULL_STORES reproduces the QA bot's exact round-5 fixture
    # (PR #897): stores/sessions are null instead of arrays, yet the
    # bookkeeping counters (count/totalCount/hasMore) are internally
    # consistent — this must be UNEVALUATED via the schema gate, never a
    # false clean from `.stores[]?` silently iterating null as "nothing".
    if [ -n "${FAKE_SESSIONS_NULL_STORES:-}" ]; then
      echo '{"stores":null,"sessions":null,"count":0,"totalCount":0,"hasMore":false}'
      exit 0
    fi
    node --experimental-sqlite --no-warnings -e '
      const {DatabaseSync} = require("node:sqlite");
      const fs = require("fs"), path = require("path");
      const dir = process.argv[1];
      const stores = [], sessions = [];
      if (fs.existsSync(dir)) {
        for (const f of fs.readdirSync(dir)) {
          if (!f.endsWith(".sqlite")) continue;
          const agentId = f.replace(/\.sqlite$/, "");
          const p = path.join(dir, f);
          stores.push({agentId, path: p});
          const db = new DatabaseSync(p, {readOnly: true});
          // Real 2026.8 entries carry NO chatType field at all (staging-
          // verified 2026-08-31) — omit it here too, so this fixture proves
          // classification works from .key alone, the verified mechanism.
          for (const row of db.prepare("select key from sessions").all()) {
            sessions.push({agentId, key: row.key});
          }
        }
      }
      // QA bot finding (PR #897 round 3): a stores[] entry whose path is
      // absent/unreadable on disk must be UNEVALUATED, not read as 0 bytes.
      // FAKE_SESSIONS_BROKEN_PATH_AGENT adds exactly that shape — a real
      // stores[] entry naming a path that does not exist.
      const brokenAgent = process.env.FAKE_SESSIONS_BROKEN_PATH_AGENT || "";
      if (brokenAgent) {
        stores.push({agentId: brokenAgent, path: path.join(dir, "vanished-" + brokenAgent + ".sqlite")});
      }
      process.stdout.write(JSON.stringify({
        stores, sessions,
        count: sessions.length, totalCount: sessions.length, hasMore: false,
      }));
    ' "$FAKE_SESSIONS_DIR"
    ;;
  *) echo "unexpected openclaw invocation: $args" >&2; exit 90 ;;
esac
STUB

  chmod +x "$TEST_TMPDIR/bin/ssh" "$TEST_TMPDIR/bin/openclaw"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  # Default: one agent, no enabled crons, tiny sessions dir.
  echo '{"jobs":[]}' > "$FAKE_CRON_JSON"
  _mk_profile main 4gb
}

teardown() {
  [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

@test "clean when every agent is well under the budget" {
  _mk_agent main ops 1024 3
  _set_enabled_crons ops 2
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "CRITICAL when an agent's sessions dir exceeds maxDiskBytes" {
  _mk_profile main 1mb
  _mk_agent main ops $((2 * 1024 * 1024)) 3
  _set_enabled_crons ops 2
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL"* ]]
  [[ "$output" == *"main/ops"* ]]
  [[ "$output" == *"maxDiskBytes"* ]]
}

@test "CRITICAL on the wedge signature: enabled crons but ZERO cron session keys" {
  # Well under budget, so ONLY the eviction signature can fire. This is the
  # exact 2026-07-27 operations state.
  _mk_agent main ops 1024 0
  _set_enabled_crons ops 8
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"8 enabled model-turn cron(s) but ZERO"* ]]
  [[ "$output" == *"CronSessionLifecycleClaimError"* ]]
}

@test "no wedge finding when the agent has zero cron keys but no enabled crons" {
  # An agent that simply owns no crons must not be flagged — otherwise every
  # chat-only agent pages forever and the alert becomes noise.
  _mk_agent main chatonly 1024 0
  echo '{"jobs":[]}' > "$FAKE_CRON_JSON"
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "WARN fires between the ratio threshold and the hard cap" {
  _mk_profile main 10mb
  _mk_agent main ops $((9 * 1024 * 1024)) 3   # 90% of 10mb, over the 0.8 ratio
  _set_enabled_crons ops 2
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" != *"CRITICAL"* ]]
}

@test "the BYTE checks are dormant when maxDiskBytes is unset (reaper returns early upstream)" {
  # enforceSessionDiskBudget: `if (maxBytes == null || highWaterBytes == null)
  # return null`. Nothing can be evicted BY SIZE, so a 50MB dir must not be
  # flagged however large it grows.
  #
  # SCOPE CORRECTION (#829): this test used to give the agent ZERO cron keys
  # against 5 enabled crons and still assert exit 0 — i.e. it pinned the
  # behaviour that an unset disk cap suppressed the wedge signature for the
  # whole profile. That was a false all-clear: the entry reaper is a separate
  # mechanism that upstream never disables, so those 5 crons were genuinely
  # dying while the guard reported clean. Dormancy of one reaper is now scoped
  # to that reaper's own checks; see the next test for the corrected case.
  _mk_profile main unset
  _mk_agent main ops $((50 * 1024 * 1024)) 3
  _set_enabled_crons ops 5
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "the wedge signature still fires when maxDiskBytes is unset" {
  # An agent with enabled crons and zero cron keys is a confirmed outage no
  # matter which reaper emptied it. Gating this on the disk cap being configured
  # made the guard's single most decisive signal silently conditional.
  _mk_profile main unset
  _mk_agent main ops 1024 0
  _set_enabled_crons ops 5
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"5 enabled model-turn cron(s) but ZERO"* ]]
}

# ── Entry-cap half of the invariant (issue #829) ─────────────────────────────
# CLAUDE.md states BOTH maxDiskBytes AND maxEntries must stay above an agent's
# peak protected footprint, but only the disk half was ever enforced here. On
# 2026-08-14 main/scout lost its cron surface while sitting at 0.70GiB of a 4gb
# budget — 17.6% — because its 1,145 protected Slack threads had crossed
# maxEntries 1000. The guard fired the eviction signature but named the wrong
# cap, and the incident report followed it to a fix that would have changed
# nothing.

@test "CRITICAL when the protected footprint reaches maxEntries, far under maxDiskBytes" {
  # The exact #829 state. capEntryCount computes
  #   maxRemovableEntries = max(0, maxEntries - protectedCount)
  # which is 0 here, so EVERY non-protected entry — i.e. every ":cron:" key — is
  # deleted on each store load no matter how much disk headroom remains.
  _mk_profile main 4gb 1000
  _mk_agent main scout 1024 0 1145
  _set_enabled_crons scout 1
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL"* ]]
  [[ "$output" == *"main/scout"* ]]
  [[ "$output" == *"maxEntries"* ]]
  # It must NOT blame the disk cap: that misdirection is the bug being fixed.
  [[ "$output" != *"maxDiskBytes 4"* ]]
}

@test "WARN when the protected footprint crosses the ratio but not maxEntries" {
  # The lead time that was missing: scout should have warned at 800, days before
  # its cron surface died.
  _mk_profile main 4gb 1000
  _mk_agent main scout 1024 4 900
  _set_enabled_crons scout 1
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"maxEntries"* ]]
  [[ "$output" != *"CRITICAL"* ]]
}

@test "entry-cap check still runs when maxDiskBytes is unset" {
  # Regression guard: the dormant-disk-budget branch used to `continue` the whole
  # profile. With the entry cap added, that early exit would skip the half of the
  # invariant that actually fires — a dormant disk reaper says nothing about the
  # entry reaper, which upstream always enforces.
  _mk_profile main unset 1000
  _mk_agent main scout 1024 0 1200
  _set_enabled_crons scout 1
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"maxEntries"* ]]
}

@test "an absent maxEntries falls back to openclaw's default of 500, not to dormant" {
  # Unlike maxDiskBytes — whose absence makes enforceSessionDiskBudget return
  # early — an absent maxEntries resolves to DEFAULT_SESSION_MAX_ENTRIES (500)
  # upstream. Treating it as dormant would be a false all-clear on a live reaper.
  _mk_profile main 4gb unset
  _mk_agent main scout 1024 0 600
  _set_enabled_crons scout 1
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"maxEntries"* ]]
  [[ "$output" == *"500"* ]]
}

@test "cron keys do not count toward the protected footprint" {
  # Only non-removable entries starve capEntryCount. An agent whose entry count
  # is over the cap purely because of removable cron keys is healthy — the
  # reaper trims those to fit, which is ordinary maintenance, not a wedge.
  _mk_profile main 4gb 1000
  _mk_agent main scout 1024 900 200   # 1100 total entries, only 200 protected
  _set_enabled_crons scout 1
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "a chat-only agent is never flagged on the entry cap" {
  # Entry-cap pressure only matters where it can evict a cron surface. Paging on
  # every busy chat agent would drown the signal that catches the outage.
  _mk_profile main 4gb 1000
  _mk_agent main cto 1024 0 5000
  echo '{"jobs":[]}' > "$FAKE_CRON_JSON"
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "maxEntries 0 is a CRITICAL wedge, never dormant" {
  # Upstream's `maintenance?.maxEntries ?? DEFAULT` only fills a NULLISH value, so
  # a configured 0 stands and pins maxRemovableEntries at max(0, 0 - protected) =
  # 0 — every removable key, i.e. every ":cron:" key, deleted on each store load.
  # Skipping the check on `maxe <= 0` reported that fleet-wide kill as "clean".
  _mk_profile main 4gb 0
  _mk_agent main scout 1024 4 1200
  _set_enabled_crons scout 4
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL"* ]]
  [[ "$output" == *"maxEntries 0"* ]]
}

@test "a non-integer maxEntries is UNEVALUATED, and never aborts the scan" {
  # `maxEntries: "1k"` used to reach `$(( maxe * PCT / 100 ))`, whose arithmetic
  # error is FATAL to the command-substitution subshell collect_findings runs in:
  # the function died on the spot, every finding for this profile and all later
  # ones was dropped, and it still returned 1 — a CRITICAL page with an empty
  # body. The disk half must survive an unusable entry cap.
  _mk_profile main 1mb
  python3 - "$SESSION_BUDGET_STATE_ROOT/.openclaw-main/openclaw.json" <<'PY'
import json, sys
json.dump({"session": {"maintenance": {
    "mode": "enforce", "maxDiskBytes": "1mb", "maxEntries": "1k"}}},
    open(sys.argv[1], "w"))
PY
  _mk_agent main ops $((2 * 1024 * 1024)) 3
  _set_enabled_crons ops 2
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNEVALUATED"* ]]
  [[ "$output" == *"not a non-negative integer"* ]]
  # The over-budget disk finding must still be reported, not swallowed.
  [[ "$output" == *"maxDiskBytes"* ]]
  [[ "$output" == *"main/ops"* ]]
}



# ── not-yet-fired registrations are NOT a wedge ─────────────────────────────
# A base session is created BY a run, and it is deleted with its owning job id.
# Declaration-keyed crons (every skill-collection-review-<agent>) get a FRESH
# uuid on every boot, so after a restart the old base session goes with the old
# job and the new job legitimately has none until it fires. Verified after the
# 2026-09-16 09:41Z restart: all nine skill-collection-review jobs had
# lastRunAtMs ABSENT with next fires days out, and the guard flagged exactly
# ceo and cmo — the two agents whose ONLY cron is declaration-keyed.
@test "a cron that has not fired under its CURRENT registration is not a wedge" {
  # The live ceo/cmo shape: one enabled cron, no run history, zero base keys.
  _mk_agent main ceo 1024 0
  _set_enabled_crons ceo 1 no
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" != *"ZERO"* ]]
}

@test "a cron that HAS fired under its current registration still pages" {
  # The discriminator: identical fixture, one recorded run. The base session
  # should exist and does not, so this is real eviction and must page.
  _mk_agent main ceo 1024 0
  _set_enabled_crons ceo 1 yes
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 enabled model-turn cron(s) but ZERO"* ]]
}

@test "one fired cron among several not-yet-fired ones is enough to page" {
  # The signature is per-AGENT while the rule is per-JOB, so an agent must not
  # be excused just because SOME of its crons are freshly registered.
  _mk_agent main ops 1024 0
  python3 - "$FAKE_CRON_JSON" <<'PY'
import json, sys, time
now = int(time.time() * 1000)
jobs = [{"id": "fresh1", "enabled": True, "agentId": "ops"},
        {"id": "fresh2", "enabled": True, "agentId": "ops"},
        {"id": "ran1", "enabled": True, "agentId": "ops", "lastRunAtMs": now - 7200_000}]
json.dump({"jobs": jobs}, open(sys.argv[1], "w"))
PY
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"3 enabled model-turn cron(s) but ZERO"* ]]
}

@test "the entry-cap finding still fires for an agent whose crons have never run" {
  # The fired-gate must narrow ONLY the wedge line. Regression for the jq trap
  # that deleted such an agent from the inventory entirely and silently took
  # its entry-cap CRITICAL with it.
  _mk_profile main 4gb 10
  _mk_agent main ceo 1024 0 25
  _set_enabled_crons ceo 1 no
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"protected (non-removable) entries >= maxEntries"* ]]
  [[ "$output" != *"ZERO"* ]]
}

@test "a fired cron WITH a base session is clean" {
  _mk_agent main ops 1024 2
  _set_enabled_crons ops 2 yes
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" != *"ZERO"* ]]
}

# ── base vs per-run cron sessions ───────────────────────────────────────────
# A cron has TWO session shapes with OPPOSITE meanings:
#   agent:<id>:cron:<jobId>              persistent base -- losing it IS the wedge
#   agent:<id>:cron:<jobId>:run:<runId>  per-run, deleted by openclaw 2.0's own
#                                        reaper after cron.sessionRetention (24h)
# Counting them together made this guard look like it was false-positiving on
# 2026-09-16 (main/ceo and main/cmo). It was not: measured base/run on live main
# that day was ceo 0/0, cmo 0/0 against clio 2/1, cto 12/0, devops 3/4,
# finance 1/1, operations 6/32, qa 522/12, scout 2/1 -- and
# operations/caroline-weekly-rollup, credit-fleet-fraud-scan-weekly,
# finance/daily-dispute-handler and cto/caroline-autonomy-improver all hold a
# BASE session while running far less often than daily. ceo and cmo were the
# only agents with enabled crons and no base session: genuinely wedged.
@test "per-run sessions alone are NOT a cron surface: base=0 run=many still pages" {
  # The decisive case. An agent mid-run whose base session was evicted looks
  # busy -- ten live per-run children -- and is nevertheless wedged: the next
  # fire has no base session to claim.
  _mk_agent main ops 1024 0
  _add_run_keys main ops 10
  _set_enabled_crons ops 3
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"3 enabled model-turn cron(s) but ZERO"* ]]
}

@test "a base session with NO per-run children is healthy, not a wedge" {
  # The case that looked like a false positive: an agent whose crons run less
  # often than daily has had every per-run child reaped, and that is correct
  # behaviour. Its base session is intact, so nothing is wrong.
  _mk_agent main ceo 1024 1
  _set_enabled_crons ceo 1
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" != *"ZERO"* ]]
}

@test "per-run children do not mask a missing base session for ONE of two jobs" {
  # Guards the aggregate: the signature is per-AGENT, so an agent keeping one
  # base session plus many run children for a busy job still reads as having a
  # cron surface. This pins that the count is of BASE keys, not of all keys --
  # base=1 with 20 run children must be 1, which is why this stays clean rather
  # than tripping any count-based threshold.
  _mk_agent main ops 1024 1
  _add_run_keys main ops 20
  _set_enabled_crons ops 2
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" != *"ZERO"* ]]
}

@test "2026.8+: per-run sessions alone still page (same rule through the CLI path)" {
  # The 2.0 reader is a different code path (cached sessions --all-agents JSON,
  # not sessions.json), so the rule is pinned on both sides.
  export FAKE_OPENCLAW_VERSION=2026.8.2
  _mk_profile main 4gb
  _mk_agent_2026_8 ops 1024 0 1
  python3 - "$FAKE_SESSIONS_DIR/ops.sqlite" <<'PY'
import sys
from sqlite3 import connect
con = connect(sys.argv[1])
for i in range(8):
    con.execute("insert into sessions (key, chatType) values (?, ?)",
                ("agent:ops:cron:job-0:run:%d" % i, None))
con.commit(); con.close()
PY
  _set_enabled_crons ops 2
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 enabled model-turn cron(s) but ZERO"* ]]
}

@test "command-kind crons do not count toward the wedge signature" {
  # ONLY model-turn crons get a ":cron:" session key (same filter, same reason,
  # as scripts/hydra-fleet-instrument.sh). An agent whose enabled crons are all
  # payload.kind:"command" legitimately has zero, so counting them pages a
  # healthy agent as a permanent outage.
  _mk_agent main finance 1024 0 10
  python3 - "$FAKE_CRON_JSON" <<'PY'
import json, sys
json.dump({"jobs": [
    {"id": f"c{i}", "enabled": True, "agentId": "finance",
     "payload": {"kind": "command"}} for i in range(3)]},
    open(sys.argv[1], "w"))
PY
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "the remediation line names the entry cap, not just the disk cap" {
  # The operator-facing text is the actual defect surface in #829: it named only
  # maxDiskBytes/highWaterBytes, so the responder raised the cap that was not
  # binding. A guard that reports the wrong lever is worse than one that is silent.
  _mk_profile main 4gb 1000
  _mk_agent main scout 1024 0 1145
  _set_enabled_crons scout 1
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"maxEntries"* ]]
  [[ "$output" == *"Fix:"* ]]
}

@test "exit 2 when the gateway cron query fails (never a silent all-clear)" {
  _mk_agent main ops 1024 0
  _set_enabled_crons ops 3
  FAKE_CRON_FAIL=1 run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "a confirmed violation still PAGES when another profile cannot be evaluated" {
  # THE regression this guard exists to avoid. An earlier sticky-upwards rc made
  # a read error outrank a violation, so with edge unreachable and main/ops
  # genuinely over budget the script returned 2 — which the watchdog treats as
  # log-only — and the confirmed outage never paged (it wasn't even printed).
  # Completeness and severity are independent axes.
  export SESSION_BUDGET_PROFILES="main edge"
  _mk_profile main 1mb
  _mk_agent main ops $((5 * 1024 * 1024)) 2     # real CRITICAL on main
  _set_enabled_crons ops 1
  _mk_profile edge 1mb
  mkdir -p "$SESSION_BUDGET_STATE_ROOT/.openclaw-edge/agents/sup/sessions"
  FAKE_CRON_FAIL_PROFILE=edge run "$SCRIPT" --check   # edge gateway unreachable
  [ "$status" -eq 1 ]                       # pages, does NOT collapse to 2
  [[ "$output" == *"CRITICAL"* ]]
  [[ "$output" == *"main/ops"* ]]           # the confirmed finding is PRINTED
  [[ "$output" == *"UNEVALUATED"* ]]        # and edge is named, not swallowed
  [[ "$output" == *"edge"* ]]
}

@test "a failed cron inventory does not suppress that SAME profile's size checks" {
  # The intra-profile twin of the test above. The cron inventory is needed ONLY
  # for the zero-cron-key correlation; the disk-size checks are independent. An
  # earlier `continue` on inventory failure skipped them too, so an agent already
  # over maxDiskBytes reported as merely UNEVALUATED (exit 2 -> watchdog logs,
  # never pages) — the same confirmed-violation suppression, one scope down.
  _mk_profile main 1mb
  _mk_agent main ops $((5 * 1024 * 1024)) 0
  _set_enabled_crons ops 4
  FAKE_CRON_FAIL=1 run "$SCRIPT" --check
  [ "$status" -eq 1 ]                       # pages, does NOT collapse to 2
  [[ "$output" == *"CRITICAL"* ]]           # the size violation IS reported
  [[ "$output" == *"main/ops"* ]]
  [[ "$output" == *"UNEVALUATED"* ]]        # and the unknown signal is named
  # The zero-cron-key correlation is the ONE thing that must be skipped: without
  # the inventory we cannot know the agent owns enabled crons, and claiming the
  # wedge on that basis would be a fabricated outage.
  [[ "$output" != *"ZERO"* ]]
}

@test "an unevaluated profile is reported, never silently dropped" {
  # Exit 2 must still SAY which profile it could not evaluate — a bare
  # "could not evaluate" with no detail is not actionable.
  export SESSION_BUDGET_PROFILES="main"
  _mk_agent main ops 1024 3
  _set_enabled_crons ops 1
  FAKE_CRON_FAIL=1 run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNEVALUATED"* ]]
  [[ "$output" == *"main"* ]]
  # Match the real all-clear phrase, not the bare word — the exit-2 log line
  # legitimately contains "NOT clean".
  [[ "$output" != *"clean: every agent"* ]]
}

@test "report mode always exits 0 so it can never block a gateway start" {
  # It sits in ExecStartPre via openclaw-pre-start-heal.sh; a guard that can
  # refuse to start the gateway is worse than the bug it guards.
  _mk_profile main 1mb
  _mk_agent main ops $((5 * 1024 * 1024)) 0
  _set_enabled_crons ops 8
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CRITICAL"* ]]
}

@test "report mode exits 0 even when the check errors out" {
  _mk_agent main ops 1024 0
  _set_enabled_crons ops 3
  FAKE_CRON_FAIL=1 run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "unreadable sessions.json is a READ ERROR, not a wedge and not an all-clear" {
  # Three-way distinction that has to hold:
  #   0 cron keys  -> the outage (page)
  #   unreadable   -> exit 2, "could not evaluate" (do NOT page a permissions
  #                   blip as an outage, but do NOT report clean either — that
  #                   would be a false all-clear on the decisive signal)
  # Uses an ENOTDIR file-parent rather than a chmod, because CI bats runs as
  # root and root reads 0000 files anyway
  # (memory/reference_ci_selfhosted_runner_root_unwritable_test).
  local d="$SESSION_BUDGET_STATE_ROOT/.openclaw-main/agents/ops/sessions"
  mkdir -p "$d"
  # sessions.json is a DIRECTORY -> jq read fails, count is -1, not 0.
  mkdir -p "$d/sessions.json"
  _set_enabled_crons ops 4
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" != *"ZERO"* ]]                  # not misreported as the wedge
  [[ "$output" != *"clean: every agent"* ]]    # never a silent all-clear
  [[ "$output" == *"UNEVALUATED"* ]]
}

@test "unreadable sessions.json still exits 0 in report mode (never blocks start)" {
  local d="$SESSION_BUDGET_STATE_ROOT/.openclaw-main/agents/ops/sessions"
  mkdir -p "$d/sessions.json"
  _set_enabled_crons ops 4
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not evaluate"* ]]
}

# _mk_sparse_agent <profile> <agent> <apparent-bytes>
# Sparse file: multi-GiB APPARENT size at ~zero disk cost. _dir_bytes measures
# apparent size (stat), which is also what the reaper sums, so this exercises
# the real code path without writing gigabytes in CI.
_mk_sparse_agent() {
  local p="$1"
  local a="$2"
  local bytes="$3"
  local d="$SESSION_BUDGET_STATE_ROOT/.openclaw-$p/agents/$a/sessions"
  mkdir -p "$d"
  printf '{"agent:%s:cron:j0":{"updatedAt":1}}\n' "$a" > "$d/sessions.json"
  dd if=/dev/null of="$d/big.jsonl" bs=1 seek="$bytes" 2>/dev/null
}

# _stub_clamping_awk — PATH-shadow awk with one that emulates OLDER mawk, where
# `printf "%d"` goes through a 32-bit integer conversion and clamps at
# INT32_MAX. Every other awk program delegates to the real binary untouched.
#
# Without this the three tests below are VACUOUS on our hosts: node-8 runs
# mawk 1.3.4 and macOS runs BWK awk, and neither clamps, so they would pass just
# as happily against the `printf "%d"` this change replaced. With it, reverting
# _parse_bytes to "%d" makes them fail — which is the only thing that makes them
# a real regression guard.
_stub_clamping_awk() {
  cat > "$TEST_TMPDIR/bin/awk" <<'STUB'
#!/bin/bash
real=/usr/bin/awk
out="$("$real" "$@")"
for a in "$@"; do
  case "$a" in
    *'printf "%d"'*)
      case "$out" in
        ''|*[!0-9]*) : ;;
        *) if [ "$out" -gt 2147483647 ] 2>/dev/null; then out=2147483647; fi ;;
      esac
      ;;
  esac
done
printf '%s' "$out"
STUB
  chmod +x "$TEST_TMPDIR/bin/awk"
}

@test "parsing survives an awk whose printf %d clamps at INT32_MAX" {
  # The non-vacuous version of the overflow guard. Under a clamping awk a "%d"
  # parser reads 4gb as 2147483647 (~2GiB) and this 3GiB agent reports CRITICAL.
  _stub_clamping_awk
  _mk_profile main 4gb
  _mk_sparse_agent main ops $((3 * 1024 * 1024 * 1024))
  _set_enabled_crons ops 1
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" != *"CRITICAL"* ]]
}

@test "a 4gb cap is not truncated to 2GiB by 32-bit awk integer conversion" {
  # Regression guard for awk `printf "%d"`, which clamps at INT32_MAX on older
  # mawk builds. If maxDiskBytes parsed as ~2GiB instead of 4GiB, a 3GiB agent
  # would trip CRITICAL here. It must read as clean: 3GiB < 80% of 4GiB (3.2GiB).
  _mk_profile main 4gb
  _mk_sparse_agent main ops $((3 * 1024 * 1024 * 1024))
  _set_enabled_crons ops 1
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" != *"CRITICAL"* ]]
}

@test "the 80% warn line sits at 3.2GiB for a 4gb cap, not 1.6GiB" {
  # Pins the threshold arithmetic end to end: 3.5GiB is over 80% of 4GiB but
  # under the cap => WARN, never CRITICAL. Under a clamped parse this agent
  # would be far over the (mis-parsed) cap and report CRITICAL instead.
  _mk_profile main 4gb
  _mk_sparse_agent main ops $(( (7 * 1024 * 1024 * 1024) / 2 ))   # 3.5GiB
  _set_enabled_crons ops 1
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" != *"CRITICAL"* ]]
  [[ "$output" == *"4.0GiB"* ]]     # the cap is REPORTED as 4GiB, not 2GiB
}

@test "a 4gb cap still detects a genuinely over-budget agent above 4GiB" {
  # The other side of the same boundary — proves the cap wasn't just raised out
  # of reach by the parse change.
  _mk_profile main 4gb
  _mk_sparse_agent main ops $((5 * 1024 * 1024 * 1024))
  _set_enabled_crons ops 1
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL"* ]]
  [[ "$output" == *"5.0GiB"* ]]
}

@test "size units parse with binary multipliers (4gb == 4 GiB)" {
  # 512mb -> 536870912 and 4gb -> 4294967296 are the values openclaw itself
  # reports back in `sessions cleanup --json`; a decimal-multiplier parser would
  # silently mis-threshold.
  _mk_profile main 4gb
  _mk_agent main ops $((3 * 1024 * 1024)) 2   # far under 4GiB, and under 80%
  _set_enabled_crons ops 1
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]

  # 3MiB is over 80% of a 3mb (3145728 B) cap -> WARN, proving mb parsing too.
  _mk_profile main 3mb
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
}

# ── openclaw >= 2026.8 (sessions.json gone, per-agent SQLite via the CLI) ────
# Mirrors a handful of the 7.1 cases above against the real-sqlite fixture, to
# prove the runtime split reaches the same verdicts from the same underlying
# data, not just that it runs without erroring.

@test "2026.8+: clean when every agent is well under the budget" {
  export FAKE_OPENCLAW_VERSION=2026.8.1
  _mk_agent_2026_8 ops 1024 3
  _set_enabled_crons ops 2
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "2026.8+: CRITICAL when an agent's session store exceeds maxDiskBytes" {
  export FAKE_OPENCLAW_VERSION=2026.8.1
  _mk_profile main 1mb
  _mk_agent_2026_8 ops $((2 * 1024 * 1024)) 3
  _set_enabled_crons ops 2
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL"* ]]
  [[ "$output" == *"main/ops"* ]]
  [[ "$output" == *"maxDiskBytes"* ]]
}

@test "2026.8+: CRITICAL on the wedge signature: enabled crons but ZERO cron session keys" {
  export FAKE_OPENCLAW_VERSION=2026.8.1
  _mk_agent_2026_8 ops 1024 0
  _set_enabled_crons ops 8
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"8 enabled model-turn cron(s) but ZERO"* ]]
  [[ "$output" == *"CronSessionLifecycleClaimError"* ]]
}

@test "2026.8+: CRITICAL when the protected footprint reaches maxEntries, far under maxDiskBytes" {
  # The #829 shape, replayed against the SQLite-backed data source.
  export FAKE_OPENCLAW_VERSION=2026.8.1
  _mk_profile main 4gb 1000
  _mk_agent_2026_8 scout 1024 5 1000
  _set_enabled_crons scout 3
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL"* ]]
  [[ "$output" == *"protected (non-removable) entries >= maxEntries"* ]]
}

@test "2026.8+: a failed sessions CLI call is UNEVALUATED, never a silent all-clear" {
  # Distinct failure mode from 7.1's unreadable sessions.json: here the whole
  # per-agent data source for the profile is gone, not just one agent's file.
  export FAKE_OPENCLAW_VERSION=2026.8.1
  export FAKE_SESSIONS_FAIL=1
  _mk_agent_2026_8 ops 1024 3
  _set_enabled_crons ops 2
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNEVALUATED"* ]]
  [[ "$output" == *"sessions --all-agents --json"* ]]
}

@test "2026.8+: report mode never blocks on a failed sessions CLI call" {
  export FAKE_OPENCLAW_VERSION=2026.8.1
  export FAKE_SESSIONS_FAIL=1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "2026.8+: a partial (paginated) sessions page is UNEVALUATED, never clean" {
  # Adversarial case (2026-08-31 staging finding): the CLI paginates at 100
  # by default, and this must never be trusted at face value even with
  # --limit all sent. The stub here returns hasMore:true, count(100) <
  # totalCount(1758) regardless — proving the guard checks the response
  # shape itself, not just that it sent the right flag. Without the
  # pagination-paranoia gate this fixture reports clean (0 findings from an
  # empty "sessions" array) — the mutation this test exists to catch.
  export FAKE_OPENCLAW_VERSION=2026.8.1
  export FAKE_SESSIONS_PAGINATED=1
  _set_enabled_crons ops 8
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNEVALUATED"* ]]
  [[ "$output" == *"PARTIAL page"* ]]
  [[ "$output" == *"hasMore=true"* ]]
  [[ "$output" != *"CRITICAL"* ]]
}

@test "2026.8+: a counter-consistent but null stores/sessions response is UNEVALUATED, never clean" {
  # QA bot finding (PR #897 round 5, thread 3898259244): the fixture
  # `{"stores":null,"sessions":null,"count":0,"totalCount":0,"hasMore":false}`
  # satisfies the existing hasMore/count/totalCount bookkeeping check
  # (0==0, hasMore false) while stores/sessions are null, not arrays.
  # `_agent_dirs`'s `.stores[]?` then silently iterates null as "nothing",
  # so zero agents are enumerated and the profile reads as clean with zero
  # findings — a false clean, not a stricter one. The schema gate must
  # catch this BEFORE the bookkeeping check gets a chance to pass it.
  export FAKE_OPENCLAW_VERSION=2026.8.1
  export FAKE_SESSIONS_NULL_STORES=1
  _set_enabled_crons ops 2
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNEVALUATED"* ]]
  [[ "$output" == *"missing/null/wrong-typed field"* ]]
  [[ "$output" != *"CRITICAL"* ]]
}

@test "2026.8+: report mode never blocks on a null stores/sessions response" {
  export FAKE_OPENCLAW_VERSION=2026.8.1
  export FAKE_SESSIONS_NULL_STORES=1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "2026.8+: report mode never blocks on a partial (paginated) sessions page" {
  export FAKE_OPENCLAW_VERSION=2026.8.1
  export FAKE_SESSIONS_PAGINATED=1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

# QA bot finding (PR #897 round 2): _sessions_json's cache used to be a bash
# associative array, mutated inside `$(...)`/pipe subshells whose writes
# never escape — so every per-agent collector re-issued the real CLI call
# instead of reading a cache. A transient failure on any call PAST the first
# (i.e. after collect_findings already validated the first response as a
# complete page) silently starved that later collector's jq input, which
# reads as "nothing to report" — a false clean, not UNEVALUATED. The fix
# fetches to a FILE exactly once per profile, in the parent frame, and every
# collector only ever reads that file.
@test "2026.8+ sessions CLI is queried EXACTLY ONCE per profile, never re-queried per collector" {
  _mk_agent_2026_8 ops 1024 3
  _set_enabled_crons ops 2
  export FAKE_OPENCLAW_VERSION=2026.8.1
  export FAKE_SESSIONS_CALL_LOG="$TEST_TMPDIR/sessions-call-log"
  : > "$FAKE_SESSIONS_CALL_LOG"
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
  [ "$(wc -l < "$FAKE_SESSIONS_CALL_LOG")" -eq 1 ]
}

@test "2026.8+ a sessions CLI failure on a call PAST the first cannot produce a false clean" {
  _mk_agent_2026_8 ops 1024 3
  _set_enabled_crons ops 2
  export FAKE_OPENCLAW_VERSION=2026.8.1
  export FAKE_SESSIONS_CALL_LOG="$TEST_TMPDIR/sessions-call-log"
  export FAKE_SESSIONS_FAIL_AFTER_FIRST=1
  : > "$FAKE_SESSIONS_CALL_LOG"
  run "$SCRIPT" --check
  # With only ONE real call ever made, this must still read the complete,
  # successful first response and report clean — never silently starve a
  # later collector and let that read as clean by accident.
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
  [ "$(wc -l < "$FAKE_SESSIONS_CALL_LOG")" -eq 1 ]
}

# ── QA bot finding (PR #897, 2026-08-31): an unparseable runtime version must
# not silently guess < 2026.8 and run the (on an actual 2.0 box, absent)
# 7.1 file-tree checks — that risks a false "clean" when there is real
# budget/eviction risk unevaluated. Overrides the shared stub for --version
# only, since FAKE_OPENCLAW_VERSION's `${:-default}` can't itself express
# "produced nothing".
_stub_unparseable_openclaw_version() {
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
args="$*"
case "$1" in
  --version) echo ""; exit 0 ;;
esac
echo "unexpected openclaw invocation: $args" >&2
exit 90
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
}

@test "unparseable runtime version: --check exits 2 (UNEVALUATED), never a false clean" {
  _stub_unparseable_openclaw_version
  # An agent well under any conceivable budget: if the guard silently
  # guessed pre-2026.8 and ran the (on 2.0, absent) file-tree checks, it
  # would find nothing and report clean instead of UNEVALUATED.
  _mk_agent main ops 1024 3
  _set_enabled_crons ops 2
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNEVALUATED"* ]]
  [[ "$output" == *"could not determine openclaw runtime version"* ]]
  [[ "$output" != *"CRITICAL"* ]]
}

@test "unparseable runtime version: report mode never blocks on it (still exits 0)" {
  _stub_unparseable_openclaw_version
  _mk_agent main ops 1024 3
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "2026.8+ an agent whose stores[] path is absent on disk is UNEVALUATED, never 0-byte clean" {
  # QA bot finding (PR #897 round 3): a stores[] entry naming a path that
  # doesn't actually exist on disk used to `return 0` with NO stdout, which
  # the caller reads as "nothing to check" and silently skips — false clean
  # disk headroom for an agent whose SQLite store vanished.
  _mk_agent_2026_8 ops 1024 3
  _set_enabled_crons ops 2
  export FAKE_OPENCLAW_VERSION=2026.8.1
  export FAKE_SESSIONS_BROKEN_PATH_AGENT=ghost
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNEVALUATED"* ]]
  [[ "$output" == *"main/ghost"* ]]
  [[ "$output" == *"session store path absent or unreadable"* ]]
}


# -- main-target crons cannot own a base ":cron:" key (2026-09-21) ----------
# A cron with sessionTarget "main" runs inside the agent's OWN main session, so
# it never creates a base `:cron:<jobId>` key however healthily it fires. Only
# ISOLATED model-turn crons do. Live on main 2026-09-21 ceo and cmo each had
# exactly one enabled model-turn cron -- both `skill-collection-review-*`,
# target=main, lastRunAtMs set, `cron list` status ok -- and this guard paged
# them as a standing outage. ceo sat at 5 entries / 1.6M against maxEntries
# 10000 and maxDiskBytes 8gb, so no cap could ever have been the fix. These
# declaration-keyed jobs are created by openclaw 2.0 at boot and did not exist
# on 7.1, which is why the original model was true when it was written.

@test "an agent whose only enabled cron is main-target is CLEAN with zero cron keys" {
  _mk_agent main ceo 1024 0
  _set_enabled_crons ceo 1 yes main
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" != *"ZERO"* ]]
  [[ "$output" != *"CRITICAL"* ]]
}

@test "a main-target cron does not mask a genuinely wedged ISOLATED cron" {
  # Scope guard: excluding main-target must not swallow the real signature when
  # the same agent also owns an isolated cron that CAN hold a base key.
  _mk_agent main ops 1024 0
  _set_mixed_target_crons ops
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CRITICAL"* ]]
  [[ "$output" == *"ops"* ]]
}

@test "an ABSENT sessionTarget still counts - the guard fails toward paging" {
  # An unfamiliar cron shape must keep the wedge signature, not lose it.
  _mk_agent main ops 1024 0
  _set_enabled_crons ops 1
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"ZERO"* ]]
}
