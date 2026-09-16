#!/usr/bin/env bash
# cron-store.sh — canonical durable-cron accounting + the re-import primitive,
# shared by scripts/deploy.sh (Step 6b convergence heal) and
# scripts/smoke-test.sh (the cron count check).
#
# WHY THIS EXISTS (incident 2026-08-11, PR #819, deploy run 31471588425)
# ---------------------------------------------------------------------
# deploy.sh imports cron-jobs.json into the SQLite cron_jobs store BEFORE the
# Step 6 drain-restart, and verifies the write with a loadCronStore read-back.
# That read-back proves the rows landed. It does NOT prove they survive to the
# restart.
#
# The still-running gateway holds its own in-memory cron table and persists the
# WHOLE table whenever a job is added at runtime. The qa-autoreview bot mints a
# one-shot `qa-autoreview-pr-*` cron per PR event across the org, so
# `[gateway] cron: job added` fires constantly. Any such write between the
# import and the restart rewrites the PRE-IMPORT view over the freshly-imported
# rows, and the casualty is exactly the cron the deploy was ADDING — the one row
# the old gateway's memory never knew about.
#
# Observed on 2026-08-11 (journalctl -u openclaw-gateway-main):
#
#   08:04:39  deploy: Imported 33 cron jobs … (read-back persisted:33)
#   08:07:13  [gateway] cron: job added        <- old pid 2595860 clobbers
#   08:07:35  [gateway] cron: job added        <- again
#   08:10:33  gateway restarted (2595860 -> 1206341)
#   08:12:12  FAIL: cron count mismatch — repo has 33, gateway loaded 32
#
# The deploy auto-rolled back, so the fleet was never unhealthy — but main was
# left undeployed and every later push would have failed identically. The window
# was ~6 minutes because the safe restart deferred 320s draining active
# qa-autoreview cron runs ("restart blocked by active background task run(s)").
# Deploys that do not ADD a cron never notice the clobber (the stale in-memory
# table and the repo agree), which is why this went unseen for months.
#
# Widening the smoke test would not help: by the time it runs the store is
# already wrong and the only outcome is a rollback. deploy.sh Step 6b instead
# re-checks the loaded set AFTER the restart and heals it (re-import + one more
# restart) before the smoke test runs.
#
# This file is pure/injectable so bats can unit-test the accounting without a
# live gateway — same split rationale as lib/websearch-probe.sh and
# lib/credit-gate-probe.sh.

# The canonical durable-cron comparison, defined ONCE.
#
# Ephemeral one-shots (deleteAfterRun + a one-time `at` schedule) are created at
# runtime by agents — the QA bot's per-PR review jobs, the CMO's reminders — and
# self-delete after firing. They are NOT part of the repo definition, so they
# must never be compared against cron-jobs.json: counting them false-failed EVERY
# deploy that overlapped a recent dispatch (2026-06-30, repo=26 vs loaded=28).
# There are routinely 8-9 of them live.
#
# Disabled crons ARE included: `cron list --all` returns them (17 of the 32
# entries were enabled:false on 2026-08-11), and deploy.sh imports the full repo
# set. Do NOT narrow to enabled-only. (Contrast bare `cron list`, which DOES
# hide disabled rows — always pass --all.)
#
# A PAGINATED response makes the durable set UNOBTAINABLE, so we refuse rather
# than substitute `.total` (the ALL-ROWS count, which includes the ephemerals
# this filter exists to exclude). `openclaw cron list` on 2026.7.1 has NO
# pagination flags (--agent/--all/--json/--timeout/--token/--url only, verified
# on node-8), so the unseen rows genuinely cannot be fetched — "read the other
# pages" is not an option that exists. UNKNOWN is the honest answer.
#
# WHAT IS COMPARED: every field the repo DECLARES, recursively — payload (argv,
# cwd, timeouts, prompts), delivery (channel, target, accountId), sessionTarget,
# wakeMode, agentId, name, enabled, and the whole schedule. Not a count, and not
# a hand-picked field list.
#
# A count is not enough: a clobber that preserves the total (swap cron A for B,
# or change A's schedule) compares equal and ships the stale table. The
# 2026-08-11 incident was an addition, the only shape a count catches.
#
# A hand-picked allowlist is not enough either: it silently stops protecting any
# field nobody remembered to add. An earlier version of this file listed
# kind/expr/tz and so left the two `kind: every` jobs with NO scheduling state in
# the comparison at all, and left prompt/argv/Slack-destination edits unguarded.
#
# HOW GATEWAY DEFAULTS ARE HANDLED: `restrict` narrows each gateway job to the
# keys its repo counterpart declares, recursively. A key the gateway adds that
# the repo never declared is a DEFAULT, not a clobber, so it is ignored
# automatically — today and after any future openclaw bump, with no list to
# maintain. Measured on node-8 2026-08-11, the gateway adds: staggerMs (inside
# schedule, defaulted to 300000), plus top-level deleteAfterRun, status,
# lastRunAtMs, lastRunStatus, lastDelivered, lastDeliveryStatus,
# lastFailureNotificationDeliveryStatus and nextRunAtMs. Comparing those would
# red every deploy, and Step 6b cannot heal a default: it would re-import,
# restart, mismatch again and fail. A real clobber restores an OLD
# repo-declared value, which this catches.
#
# THE TWO EXCLUSIONS are repo-declared keys that are nonetheless pure runtime
# bookkeeping, so comparing them would red deploys for reasons unrelated to what
# a cron runs:
#   updatedAtMs — the gateway bumps it on its own schedule (4 of 33 jobs already
#                 differed from the committed value on 2026-08-11).
#   state       — runtime counters. The repo commits `{"consecutiveErrors":0}`
#                 for 2 jobs; the live value changes the moment a cron errors,
#                 and deploy.sh's own sync deliberately preserves live `state`
#                 over the repo's.
# Neither expresses intent about WHAT a cron runs, WHEN, or WHERE it delivers.
# Verified after excluding exactly these two: repo and gateway compare equal for
# all 33 durable jobs, every other declared field included.
export CRON_STORE_RUNTIME_KEYS="state updatedAtMs"

_CRON_STORE_JQ_DEFS='
  def runtime_declared:
    # openclaw >= 2026.8.2 declares crons from config at boot and REGENERATES
    # their ids every boot, so they can never appear in cron-jobs.json. Counting
    # them made Step 6b unpassable on 2026-09-10 ("loaded 44, repo declares 33";
    # 11 unexpected, 0 missing).
    # NAMESPACE **+ RUNTIME PAYLOAD INVARIANT** (QA finding, PR #924). The key
    # alone is forgeable: the runtime refuses a user `cron add` only for its
    # system-owned prefixes (heartbeat-task:, skill-collection-review:), so an
    # operator CAN key an ordinary durable cron `heartbeat:billing` — and a
    # key-only rule would exempt it and let the replace-all import delete it.
    # `cron add` cannot build a heartbeat/skillCollectionReview payload, so the
    # payload is the non-forgeable half. Verified against every live declared
    # row in both profiles (14/14) on 2026-09-10.
    # Anything else is NOT declared and keeps its protection, so a new runtime
    # namespace halts the deploy loudly instead of being dropped.
    ((.declarationKey | type) == "string")
      and (
        (if (.payload | type) == "object" then .payload else {} end) as $p
        | if (.declarationKey | startswith("heartbeat:"))
            then ($p.kind == "heartbeat")
          elif (.declarationKey | startswith("heartbeat-task:"))
            then true
          elif (.declarationKey | startswith("skill-collection-review:"))
            then ($p.kind == "skillCollectionReview")
          elif (.declarationKey == "memory-core:memory-dreaming-promotion")
            then ($p.kind == "agentTurn"
                  and $p.message == "__openclaw_memory_core_short_term_promotion_dream__")
          else false end
      );
  def durable:
    [ .jobs[]
      | select(((.schedule.kind == "at") and (.deleteAfterRun == true)) | not)
      | select(runtime_declared | not) ];
  def canon:
    # enabled normalizes on BOTH sides so a null-vs-false spelling difference is
    # not a false mismatch; the runtime keys are dropped on both sides.
    (.enabled = (.enabled != false)) | del(.state, .updatedAtMs);
  def restrict($tmpl):
    . as $o
    | if ($o | type) == "object" and ($tmpl | type) == "object"
      then reduce ($tmpl | keys_unsorted[]) as $k ({}; .[$k] = ($o[$k] | restrict($tmpl[$k])))
      else $o end;
  def jobset:
    if (.hasMore == true) then "PAGINATED" else (durable | map(canon)) end;
'

# cron_store_jobset_from_json <json>
# Echo the canonical durable job set for an `openclaw cron list --all --json`
# payload — or for cron-jobs.json, which has the same `.jobs` shape.
#   rc 0  job set echoed
#   rc 1  unparseable / unexpected shape — UNKNOWN
#   rc 2  response was paginated — the set cannot be derived
# The caller must treat rc != 0 as "unknown", never as "fine". (A gate that
# skips what it cannot parse IS the bug.)
cron_store_jobset_from_json() {
  local json="$1" out
  [ -n "$json" ] || return 1
  # 2>/dev/null (NOT 2>&1): openclaw emits `Config warnings:` on stderr at every
  # CLI invocation, which corrupted an earlier version of this parse.
  out=$(printf '%s' "$json" | jq -S -c "$_CRON_STORE_JQ_DEFS jobset" 2>/dev/null) || return 1
  [ "$out" = '"PAGINATED"' ] && return 2
  [ "${out:0:1}" = "[" ] || return 1
  printf '%s' "$out"
}

# cron_store_count_from_jobset <jobset-json>
cron_store_count_from_jobset() {
  local n
  n=$(printf '%s' "$1" | jq 'length' 2>/dev/null) || return 1
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$n"
}

# cron_store_durable_count_from_json <json>
# Count-only view, for smoke-test.sh's existing message. Propagates the rc codes.
cron_store_durable_count_from_json() {
  local set rc=0
  set=$(cron_store_jobset_from_json "$1") || rc=$?
  (( rc == 0 )) || return $rc
  cron_store_count_from_jobset "$set"
}

# cron_store_diff <repo-jobset> <gateway-jobset>
# Echo {"missing":[…],"unexpected":[…],"changed":[…]} of job ids. Empty
# everywhere means the gateway agrees with every field the repo declares.
# Returns non-zero if the diff could not be computed — the caller must NOT read
# a failed diff as "nothing differs".
cron_store_diff() {
  local out
  # Explicit reduce rather than INDEX/1: the builtin's arity-1 form does not
  # behave consistently across jq builds, and a diff that errors is a
  # fail-open waiting to happen.
  out=$(jq -n -c --argjson a "$1" --argjson b "$2" "$_CRON_STORE_JQ_DEFS"'
    (reduce $b[] as $r ({}; .[$r.id | tostring] = $r)) as $bi
    | ([$a[].id] | map(tostring)) as $aid
    | {
        missing:    [ $a[] | select($bi[.id | tostring] == null) | .id ],
        unexpected: [ $b[] | . as $y | select(($aid | index($y.id | tostring)) == null) | $y.id ],
        changed:    [ $a[] | . as $x | $bi[$x.id | tostring]
                      | select(. != null) | select((. | restrict($x)) != $x) | $x.id ]
      }' 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# cron_store_diff_is_empty <diff-json>
#   rc 0  a well-formed diff with nothing in it
#   rc 1  differences present, OR the input is not a well-formed diff
# The second half matters: an unparseable or errored diff must never read as
# "no differences". Requiring all three keys is what makes that impossible.
cron_store_diff_is_empty() {
  local n
  n=$(printf '%s' "$1" | jq -e '
        if (type == "object")
           and (has("missing") and has("unexpected") and has("changed"))
           and ((.missing | type) == "array")
           and ((.unexpected | type) == "array")
           and ((.changed | type) == "array")
        then ([.missing[], .unexpected[], .changed[]] | length)
        else error("not a diff") end' 2>/dev/null) || return 1
  [ "$n" = "0" ]
}

# Tunables, named like the GATEWAY_*/RI_* knobs elsewhere in scripts/.
# 5 attempts x 2s covers the ~5s a gateway takes from exec to "http server
# listening" (measured 2026-08-18 on node-8: 12:43:45 restart -> 12:43:50
# listening) without stretching a genuinely dead gateway's deploy by much.
CRON_STORE_READ_TRIES="${CRON_STORE_READ_TRIES:-5}"
CRON_STORE_READ_POLL_SECS="${CRON_STORE_READ_POLL_SECS:-2}"

# _cron_store_gateway_read <profile>
# Echo the raw `cron list --all --json` output, retrying a bounded number of
# times. RETRY EXISTS FOR ONE REASON: this runs seconds after a gateway
# restart, and the CLI needs the gateway's HTTP server to be listening. On
# 2026-08-18 a single attempt landed 1s before it came up, and the resulting
# refused connection was reported as an unverifiable cron store — rolling back
# a deploy whose diff never touched cron. A transient connect failure is not
# evidence about the store's contents.
#
# Bounded on purpose: a permanently dead gateway must still FAIL, and fail
# within a knowable budget, rather than hang the deploy.
_cron_store_gateway_read() {
  local profile="$1" bin raw err rc i
  bin="${OPENCLAW_BIN:-openclaw}"

  # VALIDATE BEFORE ANY ARITHMETIC. Bash recursively evaluates a variable's
  # VALUE in an arithmetic context, so `(( i <= CRON_STORE_READ_TRIES ))` with
  # CRON_STORE_READ_TRIES='a[$(cmd)0]' RUNS cmd — in the root deploy process
  # (verified: the injected command printed). Worse for everyday use, a benign
  # typo like `banana` evaluates to 0, so the loop makes ZERO attempts, the
  # read returns failure without ever contacting the gateway, and a perfectly
  # healthy cron store becomes a FATAL + rollback. Refuse both up front rather
  # than let a knob decide how much of the gate runs.
  if [[ ! "$CRON_STORE_READ_TRIES" =~ ^[0-9]+$ ]] || [ "$CRON_STORE_READ_TRIES" -lt 1 ]; then
    printf '        cron-store: CRON_STORE_READ_TRIES must be a positive integer, got %s\n' \
      "$(printf '%q' "$CRON_STORE_READ_TRIES")" >&2
    return 1
  fi
  if [[ ! "$CRON_STORE_READ_POLL_SECS" =~ ^[0-9]+$ ]]; then
    printf '        cron-store: CRON_STORE_READ_POLL_SECS must be a non-negative integer, got %s\n' \
      "$(printf '%q' "$CRON_STORE_READ_POLL_SECS")" >&2
    return 1
  fi

  err="$(mktemp)"
  for (( i = 1; i <= CRON_STORE_READ_TRIES; i++ )); do
    rc=0
    raw=$("$bin" --profile "$profile" cron list --all --json 2>"$err") || rc=$?
    # An rc-0 read with EMPTY stdout is a failed attempt too, not a store with
    # no jobs: deploy run 35116340141 (2026-09-16 15:44Z) got exactly that
    # ~2 min after the Step 6 restart, the smoke test took it as a verdict and
    # rolled the deploy back while Step 6b's cron.list RPC had succeeded 90 s
    # earlier and the same command answered 98 KB seconds later. A real empty
    # store still prints JSON ({"jobs":[]}), never nothing.
    if [ "$rc" -eq 0 ] && [ -n "$raw" ]; then
      printf '%s' "$raw"
      rm -f "$err"
      return 0
    fi
    if [ "$rc" -eq 0 ]; then
      printf 'cron list --all --json exited 0 with EMPTY output (attempt %s of %s)\n' "$i" "$CRON_STORE_READ_TRIES" >> "$err"
    fi
    [ "$i" -lt "$CRON_STORE_READ_TRIES" ] && sleep "$CRON_STORE_READ_POLL_SECS"
  done
  # Report WHY on stderr, so a refused connection is never mistaken for a
  # corrupt store. Same idiom cron_store_reimport uses below: the caller's
  # fatal line lands directly under this, and the deploy log carries both.
  #
  # Deliberately NOT handed back through a shared file: every caller invokes
  # this as `raw=$(_cron_store_gateway_read ...)`, so a variable cannot cross
  # the subshell, and a predictable path under a world-writable /tmp is a
  # symlink target a local user can pre-place — `: >` follows it and would
  # truncate an arbitrary root-owned file. stderr already flows to the caller
  # and needs no shared state at all.
  [ -s "$err" ] && sed 's/^/        /' "$err" >&2
  rm -f "$err"
  return 1
}

# cron_store_gateway_durable_count <profile>
# Echo the count of durable crons the RUNNING gateway has loaded. This reports
# the gateway's in-memory table, not SQLite — before a restart it still shows
# the pre-import set, which is precisely what makes the clobber detectable.
# Propagates cron_store_durable_count_from_json's rc (1 = unknown,
# 2 = paginated) so the caller can say which kind of blind it is.
cron_store_gateway_durable_count() {
  local profile="$1" raw
  raw=$(_cron_store_gateway_read "$profile") || return 1
  cron_store_durable_count_from_json "$raw"
}

# cron_store_gateway_jobset <profile>
# Echo the durable job set the RUNNING gateway has loaded. This reflects the
# gateway's in-memory table, not SQLite — before a restart it still shows the
# pre-import set, which is precisely what makes the clobber detectable.
cron_store_gateway_jobset() {
  local profile="$1" raw
  raw=$(_cron_store_gateway_read "$profile") || return 1
  cron_store_jobset_from_json "$raw"
}

# cron_store_repo_jobset <cron-jobs.json>
# Echo the job set the repo declares. The repo file carries no ephemeral
# one-shots, so the same canonicalization applies unchanged.
cron_store_repo_jobset() {
  local file="$1"
  [ -f "$file" ] || return 1
  cron_store_jobset_from_json "$(cat "$file")"
}

# cron_store_repo_count <cron-jobs.json>
# Echo the number of jobs the repo declares. The repo file carries no ephemeral
# one-shots, so this is a plain length.
cron_store_repo_count() {
  local file="$1" n
  [ -f "$file" ] || return 1
  n=$(jq '.jobs | length' "$file" 2>/dev/null) || return 1
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$n"
}

# cron_store_reimport <profile> <cron-jobs.json>
# Re-install the repo cron file to the profile's store_key path and re-run the
# SDK save + read-back. Echoes the persisted row count on success.
#
# Deliberately a SECOND import site rather than a refactor of deploy.sh's Step
# 5a block: that block carries its own jobs.json-migration race handling and is
# the load-bearing path on every deploy. This one runs only on the rare heal.
#
# CRON_STORE_STATE_ROOT exists so bats can exercise this function for real
# without writing to the live profile dirs — the bats job runs ON node-8, so a
# hard-coded /root/.openclaw-main here would clobber production fleet state on
# every CI run. Prod default is unchanged.
cron_store_reimport() {
  local profile="$1" repo_json="$2"
  local state_dir="${CRON_STORE_STATE_ROOT:-/root/.openclaw}-${profile}"
  local live_cron="$state_dir/cron/jobs.json"
  local global_modules sdk out n err node_rc=0

  [ -f "$repo_json" ] || return 1
  err=$(mktemp) || return 1

  # Resolve the openclaw global dist the path-independent way (mirrors PR #537):
  # Node's ESM resolver does not search the global npm root for a bare
  # `openclaw/...` specifier and ignores NODE_PATH, so the import MUST use the
  # absolute dist path.
  global_modules=$(npm root -g 2>/dev/null) || { rm -f "$err"; return 1; }
  sdk="$global_modules/openclaw/dist/plugin-sdk/cron-store-runtime.js"
  [ -f "$sdk" ] || { rm -f "$err"; return 1; }

  mkdir -p "$(dirname "$live_cron")" || { rm -f "$err"; return 1; }
  install -m 600 "$repo_json" "$live_cron" || { rm -f "$err"; return 1; }

  # saveCronStore/loadCronStore are ASYNC and MUST be awaited, else the process
  # exits before the SQLite write commits and the store is left empty.
  out=$(OPENCLAW_STATE_DIR="$state_dir" CRON_SDK="$sdk" LIVE_CRON="$live_cron" \
    HYDRA_ALLOW_ORPHAN_CRON="${HYDRA_ALLOW_ORPHAN_CRON:-0}" \
    node --input-type=module -e '
      import { readFileSync } from "node:fs";
      try {
        const m = await import(process.env.CRON_SDK);
        const store = JSON.parse(readFileSync(process.env.LIVE_CRON, "utf8"));
        const target = m.resolveCronStorePath();
        // Preserve live scheduler state exactly as deploy.sh Step 5a does
        // (scripts/deploy.sh, `j['state'] = live_states[j['id']]`). The repo
        // file carries a stale/absent `state`, so saving it raw would reset
        // lastRunAtMs / consecutiveErrors for every durable job on the rare
        // heal — a silent loss of runtime state that the normal import path
        // deliberately avoids. Keyed by id (not name) so a rename keeps it.
        const allowOrphan = process.env.HYDRA_ALLOW_ORPHAN_CRON === "1";
        let preserved = 0;
        let liveJobs = null;
        try {
          const cur = await m.loadCronStore(target);
          liveJobs = cur.jobs || [];
          const live = new Map((cur.jobs || []).map((j) => [j.id, j.state]));
          for (const j of store.jobs || []) {
            if (live.has(j.id) && live.get(j.id) !== undefined) {
              j.state = live.get(j.id);
              preserved++;
            }
          }
        } catch (e) {
          // FAIL CLOSED. Both safety properties of this save depend on that
          // read: preserving live `state`, and proving no undeclared durable
          // cron is about to be deleted. Continuing on a failed read would
          // overwrite the store with raw repo jobs — erasing lastRunAtMs /
          // consecutiveErrors and any recurring cron added since the snapshot —
          // while only printing a warning. An unreadable store means we do not
          // know what we are about to destroy, so we destroy nothing.
          console.error("cron_store_reimport: refusing to save — could not read the live store: " + e);
          process.exit(4);
        }
        // Re-check for undeclared durable jobs against the store we JUST read,
        // not the snapshot converge took seconds ago. saveCronStore is a
        // replace-all with no transaction around it, so a job added in that
        // window would be deleted by the very save meant to heal a clobber.
        // This narrows the exposure from "the whole compare->reimport gap" to
        // the microseconds between this load and the save below. It does not
        // eliminate it — the SDK exposes no compare-and-swap — and refusing is
        // the only safe answer, so the abort is loud rather than silent.
        if (!allowOrphan) {
          const declared = new Set((store.jobs || []).map((j) => j.id));
          // Runtime-declared rows (declarationKey) belong to the openclaw runtime, created
          // from config at boot with ids that regenerate — never committable.
          // See runtime_declared in the jq defs above; keep the two in step.
          // Namespace + the runtime payload invariant: the key alone is
          // forgeable via cron add --declaration-key (QA finding, PR #924).
          // NOTE: this JS is embedded in a SINGLE-QUOTED shell string, so no
          // apostrophes and no backticks may appear anywhere in this block.
          // Mirrors runtime_declared in the jq defs above; keep them in step.
          const isRuntimeDeclared = (j) => {
            const k = j.declarationKey;
            if (typeof k !== "string") return false;
            const p = j.payload && typeof j.payload === "object" ? j.payload : {};
            if (k.startsWith("heartbeat:")) return p.kind === "heartbeat";
            if (k.startsWith("heartbeat-task:")) return true;
            if (k.startsWith("skill-collection-review:")) return p.kind === "skillCollectionReview";
            if (k === "memory-core:memory-dreaming-promotion")
              return p.kind === "agentTurn" &&
                p.message === "__openclaw_memory_core_short_term_promotion_dream__";
            return false;
          };
          const undeclared = (liveJobs || [])
            .filter((j) => !(j.schedule && j.schedule.kind === "at" && j.deleteAfterRun === true))
            .filter((j) => !isRuntimeDeclared(j))
            .filter((j) => !declared.has(j.id))
            .map((j) => j.id);
          if (undeclared.length > 0) {
            console.error("cron_store_reimport: refusing to save — the live store holds durable cron(s) the repo does not declare: " + undeclared.join(", "));
            process.exit(3);
          }
        }
        await m.saveCronStore(target, store);        // delete-by-store_key + re-insert
        const back = await m.loadCronStore(target);  // read-back to verify persistence
        console.log(JSON.stringify({ persisted: (back.jobs || []).length, preserved }));
        process.exit(0);
      } catch (e) { console.error(e); process.exit(1); }
    ' 2>"$err") || node_rc=$?
  if (( ${node_rc:-0} != 0 )); then
    sed 's/^/        /' "$err" >&2
    rm -f "$err"
    # rc 3 = an undeclared durable cron appeared between the snapshot and the
    # save. Distinct from a generic import failure so the caller can say why.
    (( node_rc == 3 )) && return 3
    # rc 4 = the live store could not be read, so nothing was saved.
    (( node_rc == 4 )) && return 4
    return 1
  fi
  # Warnings (e.g. an unreadable live store) go to stderr and must stay OUT of
  # stdout: merging them with 2>&1 corrupted the JSON parse below.
  [ -s "$err" ] && sed 's/^/        /' "$err" >&2
  rm -f "$err"

  n=$(printf '%s' "$out" | jq -r '.persisted' 2>/dev/null) || return 1
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$n"
}

# --- the convergence decision --------------------------------------------

# Results of the last cron_store_converge run, for the caller's messages.
CRON_STORE_EXPECTED=""   # count the repo declares
CRON_STORE_LOADED=""     # count the gateway has loaded
CRON_STORE_PERSISTED=""  # rows the re-import wrote
CRON_STORE_DIFF=""       # what actually differs (ids), not just how many

_cron_store_log_default() { printf '%s\n' "$*"; }

# cron_store_converge <profile> <cron-jobs.json>
#
# The whole Step 6b decision, kept OUT of deploy.sh so it is reachable from
# bats: deploy.sh has no test harness, so logic living inline there is logic
# nothing can exercise until a deploy runs it in production.
#
# Seams (function names, mirroring GATEWAY_EXEC_FN in lib/gateway-restart.sh):
#   CRON_STORE_JOBSET_FN    default cron_store_gateway_jobset
#   CRON_STORE_REIMPORT_FN  default cron_store_reimport
#   CRON_STORE_STOP_FN      REQUIRED — takes <profile>; stops the gateway
#   CRON_STORE_START_FN     REQUIRED — takes <profile>; starts it again. The
#                           caller must guarantee this runs even on a crash.
#   CRON_STORE_LOG_FN       default prints to stdout
#
# Exit codes (every non-zero one except 1 is a deploy-stopping condition):
#   0  in sync — nothing done
#   1  drift found, re-imported + restarted, now in sync (HEALED)
#   2  could not count the repo cron file
#   3  could not read the gateway's loaded set (UNKNOWN)
#   4  gateway response was paginated — durable count unobtainable
#   5  re-import into the SQLite store failed
#   6  re-import persisted the wrong number of rows
#   7  the stop/start seams were not supplied
#   8  could not re-read the loaded set after the heal
#   9  still drifted after the heal
#  10  the gateway holds a durable cron the repo does not declare — refusing to
#      heal, because the re-import would delete it
#  11  an undeclared durable cron appeared between the snapshot and the save —
#      the re-import aborted rather than delete it
#  12  the live cron store could not be read, so the re-import refused to save
#      (it could neither preserve state nor prove nothing would be destroyed)
#  13  the gateway could not be STOPPED — nothing was touched
#  14  the gateway could not be STARTED again after the import — the fleet is
#      DOWN and this is the loudest thing this function can say
#  15  the diff could not be computed BEFORE the heal — UNKNOWN, so nothing was
#      stopped, imported or restarted
#  16  the diff could not be computed AFTER the heal — the store WAS rewritten
#      and the gateway WAS restarted; convergence is simply unverified
#
# One heal attempt only. The window the heal re-opens is seconds (a restart with
# nothing to drain), not the 320s drain that made the original race wide, so a
# second miss is a real anomaly — fail loud rather than loop.
cron_store_converge() {
  local profile="$1" repo_json="$2"
  local jobset_fn="${CRON_STORE_JOBSET_FN:-cron_store_gateway_jobset}"
  local reimport_fn="${CRON_STORE_REIMPORT_FN:-cron_store_reimport}"
  local stop_fn="${CRON_STORE_STOP_FN:-}"
  local start_fn="${CRON_STORE_START_FN:-}"
  local log_fn="${CRON_STORE_LOG_FN:-_cron_store_log_default}"
  local want got rc=0

  CRON_STORE_EXPECTED=""
  CRON_STORE_LOADED=""
  CRON_STORE_PERSISTED=""
  CRON_STORE_DIFF=""

  want=$(cron_store_repo_jobset "$repo_json") || return 2
  CRON_STORE_EXPECTED=$(cron_store_count_from_jobset "$want") || return 2

  got=$("$jobset_fn" "$profile") || rc=$?
  case "$rc" in
    0) ;;
    2) return 4 ;;
    *) return 3 ;;
  esac
  CRON_STORE_LOADED=$(cron_store_count_from_jobset "$got") || return 3

  # Field-level, not a count: a swap, a schedule edit, a changed prompt/argv or
  # a re-pointed Slack destination all keep the total identical.
  # Capture the rc. converge is always called in an `||` context, so `set -e` is
  # disabled for its whole body: a failed diff would otherwise leave
  # CRON_STORE_DIFF empty, the `.unexpected[]?` probe below would find nothing,
  # and we would walk into the stop+replace-all heal without ever knowing what
  # differed. An undiagnosable diff is UNKNOWN, and UNKNOWN never heals.
  local diff_rc=0
  CRON_STORE_DIFF=$(cron_store_diff "$want" "$got") || diff_rc=$?
  (( diff_rc == 0 )) || { CRON_STORE_DIFF=""; return 15; }

  cron_store_diff_is_empty "$CRON_STORE_DIFF" && { CRON_STORE_DIFF=""; return 0; }

  # NEVER heal over a durable cron the repo does not declare. The re-import is
  # saveCronStore = delete-by-store_key + re-insert, so healing here would
  # DELETE a recurring job an operator or agent created live — and it would do
  # it AFTER deploy.sh's store-only guard (detect-store-only-crons.py) already
  # ran, silently bypassing the halt that guard exists to produce. That is how
  # Aaron's ChartMogul crons were lost on 2026-07-16 (PR #702/#706). A job that
  # appeared during the drain is a human decision, never a deploy side effect.
  if [ -n "$(printf '%s' "$CRON_STORE_DIFF" | jq -r '.unexpected[]?' 2>/dev/null)" ]; then
    # HYDRA_ALLOW_ORPHAN_CRON=1 is the SAME explicit override deploy.sh's
    # store-only guard offers; honouring it here keeps the escape hatch working
    # end to end instead of leaving Step 6b as a second, un-overridable wall.
    if [ "${HYDRA_ALLOW_ORPHAN_CRON:-0}" != "1" ]; then
      return 10
    fi
    "$log_fn" "HYDRA_ALLOW_ORPHAN_CRON=1: proceeding with the heal even though the gateway holds durable cron(s) the repo does not declare — they WILL be dropped: $(printf '%s' "$CRON_STORE_DIFF" | jq -c '.unexpected')"
  fi

  "$log_fn" "cron store drift: gateway loaded $CRON_STORE_LOADED durable cron(s), repo declares $CRON_STORE_EXPECTED; diff=$CRON_STORE_DIFF — re-importing and restarting once"

  # STOP THE ONLY WRITER BEFORE TOUCHING THE STORE.
  # saveCronStore is replace-all with no compare-and-swap, so while the gateway
  # runs, a durable cron added between our read and our write is deleted no
  # matter how tight the check is. Verified on node-8: exactly one process (the
  # profile's gateway) holds <state>/openclaw.sqlite open, so stopping it
  # removes every runtime writer and makes this critical section EXCLUSIVE
  # rather than merely narrow.
  #
  # The cost is a hard stop instead of a drained one, cutting in-flight turns —
  # acceptable on a path that only runs when the store is already wrong, and the
  # gateway was about to be restarted anyway. The caller MUST guarantee the
  # start (deploy.sh wraps this in a trap): `Restart=always` does not apply
  # after an explicit stop.
  [ -n "$stop_fn" ] && [ -n "$start_fn" ] || return 7
  "$stop_fn" "$profile" || return 13

  local reimport_rc=0
  CRON_STORE_PERSISTED=$("$reimport_fn" "$profile" "$repo_json") || reimport_rc=$?

  # ALWAYS bring it back, whatever the import did — before reporting anything.
  local start_rc=0
  "$start_fn" "$profile" || start_rc=$?
  (( start_rc == 0 )) || return 14

  (( reimport_rc == 3 )) && return 11
  (( reimport_rc == 4 )) && return 12
  (( reimport_rc == 0 )) || return 5
  [ "$CRON_STORE_PERSISTED" = "$CRON_STORE_EXPECTED" ] || return 6

  rc=0
  got=$("$jobset_fn" "$profile") || rc=$?
  (( rc == 0 )) || return 8
  CRON_STORE_LOADED=$(cron_store_count_from_jobset "$got") || return 8
  diff_rc=0
  CRON_STORE_DIFF=$(cron_store_diff "$want" "$got") || diff_rc=$?
  # 16, not 15: by here the gateway HAS been stopped, the store HAS been
  # rewritten and the gateway HAS been restarted. Reusing the pre-heal code
  # would hand the operator a message claiming none of that happened — a false
  # incident timeline is worse than no message.
  (( diff_rc == 0 )) || { CRON_STORE_DIFF=""; return 16; }
  cron_store_diff_is_empty "$CRON_STORE_DIFF" || return 9

  CRON_STORE_DIFF=""
  return 1
}
