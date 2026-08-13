#!/usr/bin/env bats
# Tests for scripts/check-trino-sql.sh + scripts/lib/trino_sql_gate.py: the
# Trino SQL staleness gate for skills-all/. A sweep (behind PR #794) found 99
# of 169 SQL statements no longer compile against live Trino; five ops
# escalations trace back to this. This suite is hermetic — a PATH-shadowed
# `kubectl` stub replays canned `EXPLAIN (TYPE VALIDATE)` output, so no test
# here ever reaches the real cluster. The canned PASS/FAIL text for the
# discrimination tests was captured from real live runs against the
# node-8 Trino coordinator (see PR description) — this suite locks that
# real, observed behavior, not a guess at it.
#
# THE SAFETY INVARIANT under test: the Trino CLI splits `--execute` input on
# ';' and only the FIRST statement keeps the EXPLAIN prefix — the rest
# EXECUTE for real. Every live call funnels through trino_sql_gate.py's
# single choke point, which this suite exercises directly (via
# `python3 scripts/lib/trino_sql_gate.py`) for the Layer B / safety /
# discrimination / ratchet tests, and via the full `check-trino-sql.sh`
# driver for the offline Layer A tests (which never touch kubectl at all —
# a Layer A finding exits before Layer B runs).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-trino-sql.sh"
GATE_PY="$HYDRA_REPO/scripts/lib/trino_sql_gate.py"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  mkdir -p "$TEST_TMPDIR/skills-all/dummy" "$TEST_TMPDIR/bin"

  # Layer A allowlist: empty by default (each test that needs an entry
  # writes its own).
  : > "$TEST_TMPDIR/.trino-sql-layer-a-allowlist.txt"
  # Substitutions: empty by default.
  : > "$TEST_TMPDIR/.trino-sql-substitutions.txt"
  # Baseline: empty by default.
  : > "$TEST_TMPDIR/.trino-sql-baseline.txt"

  # scripts/check-trino-sql.sh resolves GATE_PY as $ROOT/scripts/lib/... —
  # symlink the real (pure, network-free) extraction+gate modules in so the
  # full driver runs end-to-end against the synthetic tree.
  mkdir -p "$TEST_TMPDIR/scripts"
  ln -s "$HYDRA_REPO/scripts/lib" "$TEST_TMPDIR/scripts/lib"

  KUBECTL_LOG="$TEST_TMPDIR/kubectl.log"
  : > "$KUBECTL_LOG"
  export KUBECTL_LOG

  # ---- hermetic kubectl stub -------------------------------------------
  # Logs every invocation (for the safety-invariant assertions), answers
  # pod discovery, and replays canned EXPLAIN VALIDATE output for known
  # payload substrings. All canned text below was captured verbatim from a
  # real `kubectl exec ... trino --execute "EXPLAIN (TYPE VALIDATE) ..."`
  # run against the live node-8 coordinator.
  cat > "$TEST_TMPDIR/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$KUBECTL_LOG"

if [ "$1" = "get" ]; then
  echo "test-trino-coordinator-0"
  exit 0
fi

if [ "$1" = "exec" ]; then
  payload=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--execute" ]; then
      payload="$arg"
    fi
    prev="$arg"
  done

  case "$payload" in
    *"SELECT id,email,firstname,lastname,createdat FROM postgresql_core.public.users"*)
      echo '"true"'; exit 0 ;;
    *"u.country"*)
      echo "Query 20260806_134403_59815_j792t failed: line 1:32: Column 'u.country' cannot be resolved" >&2
      exit 1 ;;
    *"common_credits < 5"*)
      echo "Query 20260806_134430_59817_j792t failed: line 1:117: Cannot apply operator: array(varchar) < integer" >&2
      exit 1 ;;
    *"UNNEST(t.profiles) AS p(profile)"*)
      echo "Query 20260806_134431_59818_j792t failed: line 1:119: Column alias list has 1 entries but 'p' has 3 columns available" >&2
      exit 1 ;;
    *"UNNEST(t.profiles) AS p"*)
      echo '"true"'; exit 0 ;;
    *"awsdatacatalog"*)
      echo "Query 20260806_134527_59852_j792t failed: line 1:39: Catalog 'awsdatacatalog' not found" >&2
      exit 1 ;;
    *"RATCHET_FAIL_MARKER"*)
      echo "Query xxx failed: synthetic ratchet failure" >&2
      exit 1 ;;
    *"RATCHET_PASS_MARKER"*)
      echo '"true"'; exit 0 ;;
    *"TRANSPORT_FAIL_MARKER"*)
      # A kubectl/container transport error, NOT a Trino compilation failure:
      # note the absence of the `Query <id> failed:` signature.
      echo 'unable to upgrade connection: container not found ("trino")' >&2
      exit 1 ;;
    *)
      echo '"true"'; exit 0 ;;
  esac
fi

echo "unhandled kubectl invocation: $*" >&2
exit 1
STUB
  chmod +x "$TEST_TMPDIR/bin/kubectl"
  export PATH="$TEST_TMPDIR/bin:$PATH"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# Runs trino_sql_gate.py directly (bypassing the bash Layer-A driver) so
# Layer-B/safety/discrimination/ratchet tests aren't coupled to Layer A's
# file-scoping logic — same code path check-trino-sql.sh dispatches to.
run_gate_py() {
  python3 "$GATE_PY" --root "$TEST_TMPDIR" \
    --baseline "$TEST_TMPDIR/.trino-sql-baseline.txt" \
    --substitutions "$TEST_TMPDIR/.trino-sql-substitutions.txt" \
    "$@"
}

write_fence() {
  # write_fence <file> <sql...>
  local file="$1"; shift
  {
    echo '```sql'
    printf '%s\n' "$@"
    echo '```'
  } > "$file"
}

# ------------------------------------------------------------- Layer A --

@test "layer A fails on a bare awsdatacatalog. reference, no kubectl call" {
  echo 'SELECT * FROM awsdatacatalog.default.matvw_catalog_profile' \
    > "$TEST_TMPDIR/skills-all/dummy/SKILL.md"
  export REPO_ROOT="$TEST_TMPDIR"
  export TRINO_SQL_FULL_SCAN=1
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[awsdatacatalog/layerA]"* ]]
  [ ! -s "$KUBECTL_LOG" ]
}

@test "layer A fails on a bare raw_ids reference" {
  echo 'SELECT raw_ids FROM matvw_catalog_profile' \
    > "$TEST_TMPDIR/skills-all/dummy/SKILL.md"
  export REPO_ROOT="$TEST_TMPDIR"
  export TRINO_SQL_FULL_SCAN=1
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[rawids/layerA]"* ]]
}

@test "layer A fails on a bare profile_permissions reference" {
  echo 'SELECT * FROM profile_permissions' \
    > "$TEST_TMPDIR/skills-all/dummy/SKILL.md"
  export REPO_ROOT="$TEST_TMPDIR"
  export TRINO_SQL_FULL_SCAN=1
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[profilepermissions/layerA]"* ]]
}

@test "layer A fails on a bare profile_v3_lifetime reference" {
  echo 'SELECT * FROM profile_v3_lifetime' \
    > "$TEST_TMPDIR/skills-all/dummy/SKILL.md"
  export REPO_ROOT="$TEST_TMPDIR"
  export TRINO_SQL_FULL_SCAN=1
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[v3/layerA]"* ]]
}

@test "layer A allowlist entry with the matching key exempts the hit" {
  echo 'NEVER query profile_v3_lifetime — frozen.' \
    > "$TEST_TMPDIR/skills-all/dummy/SKILL.md"
  echo 'skills-all/dummy/SKILL.md -- v3 -- NEVER-warning is the doctrine' \
    > "$TEST_TMPDIR/.trino-sql-layer-a-allowlist.txt"
  write_fence "$TEST_TMPDIR/skills-all/dummy/query.md" "SELECT 1"
  cat "$TEST_TMPDIR/skills-all/dummy/query.md" > /dev/null
  export REPO_ROOT="$TEST_TMPDIR"
  export TRINO_SQL_FULL_SCAN=1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "a stale layer A allowlist entry fails on a full scan" {
  echo 'skills-all/dummy/SKILL.md -- v3 -- nothing matches this anymore' \
    > "$TEST_TMPDIR/.trino-sql-layer-a-allowlist.txt"
  echo '# nothing dead here' > "$TEST_TMPDIR/skills-all/dummy/SKILL.md"
  export REPO_ROOT="$TEST_TMPDIR"
  export TRINO_SQL_FULL_SCAN=1
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no longer matches anything"* ]]
}

# ------------------------------------------------------- Discrimination --
# All PASS/FAIL text verified live against node-8 Trino before being baked
# into the kubectl stub above.

@test "discrimination: passes on a valid resolvable SELECT" {
  write_fence "$TEST_TMPDIR/skills-all/dummy/a.md" \
    "SELECT id,email,firstname,lastname,createdat FROM postgresql_core.public.users"
  run run_gate_py --full
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 pass"* ]]
}

@test "discrimination: fails on an unresolvable column (u.country)" {
  write_fence "$TEST_TMPDIR/skills-all/dummy/a.md" \
    "SELECT u.country FROM postgresql_core.public.users u"
  run run_gate_py --full
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"cannot be resolved"* ]]
}

@test "discrimination: fails on a cardinality-less array comparison (common_credits < 5)" {
  write_fence "$TEST_TMPDIR/skills-all/dummy/a.md" \
    'SELECT _id FROM hive."platform-industry-bi-prod".matvw_catalog_profile WHERE common_credits < 5'
  run run_gate_py --full
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot apply operator"* ]]
}

@test "discrimination: fails on an UNNEST alias-arity mismatch (AS p(profile))" {
  write_fence "$TEST_TMPDIR/skills-all/dummy/a.md" \
    'SELECT p.profile FROM hive."platform-industry-bi-prod".matvw_catalog_track t CROSS JOIN UNNEST(t.profiles) AS p(profile)'
  run run_gate_py --full
  [ "$status" -eq 1 ]
  [[ "$output" == *"alias list has 1 entries"* ]]
}

@test "discrimination: passes on the correct bare UNNEST alias (AS p)" {
  write_fence "$TEST_TMPDIR/skills-all/dummy/a.md" \
    'SELECT t._id, p.profile_id FROM hive."platform-industry-bi-prod".matvw_catalog_track t CROSS JOIN UNNEST(t.profiles) AS p WHERE false'
  run run_gate_py --full
  [ "$status" -eq 0 ]
}

@test "discrimination: fails on awsdatacatalog via Layer B (live compile)" {
  write_fence "$TEST_TMPDIR/skills-all/dummy/a.md" \
    "SELECT * FROM awsdatacatalog.default.matvw_catalog_profile LIMIT 1"
  run run_gate_py --full
  [ "$status" -eq 1 ]
  [[ "$output" == *"Catalog 'awsdatacatalog' not found"* ]]
}

@test "discrimination: awsdatacatalog also fails via Layer A (offline, no kubectl)" {
  echo 'SELECT * FROM awsdatacatalog.default.matvw_catalog_profile' \
    > "$TEST_TMPDIR/skills-all/dummy/SKILL.md"
  export REPO_ROOT="$TEST_TMPDIR"
  export TRINO_SQL_FULL_SCAN=1
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[awsdatacatalog/layerA]"* ]]
  [ ! -s "$KUBECTL_LOG" ]
}

# ------------------------------------------------------------------ Safety --

@test "safety: a multi-statement anti-example fence never batches a ';' into one payload" {
  write_fence "$TEST_TMPDIR/skills-all/dummy/anti.md" \
    "SELECT 1 FROM small_table LIMIT 10;" \
    "-- BAD: full scan across two massive tables, no filters" \
    'SELECT * FROM hive."platform-industry-bi-prod".matvw_catalog_track a JOIN hive."platform-industry-bi-prod".matvw_catalog_profile b ON a.profile_id = b._id;'
  run run_gate_py --full
  [ "$status" -eq 0 ]

  # Two independent statements -> exactly two `kubectl exec` invocations,
  # each carrying its own EXPLAIN (TYPE VALIDATE) prefix, and no payload
  # anywhere in the log contains a ';' (which would let a second,
  # unprefixed statement — the BAD anti-example — execute for real).
  run grep -c "^exec " "$KUBECTL_LOG"
  [ "$output" -eq 2 ]
  run grep -c "EXPLAIN (TYPE VALIDATE)" "$KUBECTL_LOG"
  [ "$output" -eq 2 ]
  run grep -c ";" "$KUBECTL_LOG"
  [ "$output" -eq 0 ]
}

@test "safety: a corrupt payload missing the EXPLAIN prefix exits 2 and sends nothing" {
  run python3 "$GATE_PY" --root "$TEST_TMPDIR" \
    --baseline "$TEST_TMPDIR/.trino-sql-baseline.txt" \
    --substitutions "$TEST_TMPDIR/.trino-sql-substitutions.txt" \
    --send-raw "SELECT 1 FROM t"
  [ "$status" -eq 2 ]
  [[ "$output" == *"SAFETY VIOLATION"* ]]
  [[ "$output" == *"does not start with the EXPLAIN"* ]]
  [ ! -s "$KUBECTL_LOG" ]
}

@test "safety: a payload with a top-level ';' after the prefix exits 2 and sends nothing" {
  run python3 "$GATE_PY" --root "$TEST_TMPDIR" \
    --baseline "$TEST_TMPDIR/.trino-sql-baseline.txt" \
    --substitutions "$TEST_TMPDIR/.trino-sql-substitutions.txt" \
    --send-raw "EXPLAIN (TYPE VALIDATE) SELECT 1; SELECT * FROM hive.dangerous"
  [ "$status" -eq 2 ]
  [[ "$output" == *"SAFETY VIOLATION"* ]]
  [ ! -s "$KUBECTL_LOG" ]
}

# ------------------------------------------------------------------ Ratchet --

@test "ratchet: a failing statement already in the baseline contributes 0 to exit" {
  write_fence "$TEST_TMPDIR/skills-all/dummy/a.md" "SELECT RATCHET_FAIL_MARKER"
  # Generate the baseline from this exact fixture first.
  run run_gate_py --full --generate-baseline
  [ "$status" -eq 0 ]
  run run_gate_py --full
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 baselined-fail, 0 new-fail"* ]]
}

@test "ratchet: a baselined statement that now passes is a stale baseline entry (exit 1)" {
  write_fence "$TEST_TMPDIR/skills-all/dummy/a.md" "SELECT RATCHET_FAIL_MARKER"
  run run_gate_py --full --generate-baseline
  [ "$status" -eq 0 ]
  # Now the same fixture is rewritten to a query the stub passes.
  write_fence "$TEST_TMPDIR/skills-all/dummy/a.md" "SELECT RATCHET_PASS_MARKER"
  # But the baseline still references the OLD (now-nonexistent) hash — the
  # stale-baseline-entry-absent path fires since the hint file is in scope.
  run run_gate_py --full
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale"* ]]
}

@test "ratchet: an undeclared/unsubstitutable placeholder exits 1 (skipping is never free)" {
  write_fence "$TEST_TMPDIR/skills-all/dummy/a.md" "SELECT * FROM t WHERE id = <PROFILE_ID>"
  run run_gate_py --full
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP"* ]]
  [[ "$output" == *"unsubstitutable placeholder"* ]]
}

# Zero blocks from a non-empty scope has TWO causes needing OPPOSITE answers.
# This used to be one test asserting exit 2 for both, which reddened any PR that
# edited an SQL-free skills-all/ doc: the scope is every changed *.md/*.sh, so a
# pure-prose SKILL.md landed in "refusing to pass vacuously" — a gate failure
# reported against a PR with no SQL to be stale. Observed on PR #826.
@test "vacuity: a scope whose files carry NO SQL exits 0 (nothing to compile)" {
  echo 'no SQL here, just prose' > "$TEST_TMPDIR/skills-all/dummy/a.md"
  run run_gate_py "skills-all/dummy/a.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to compile"* ]]
}

@test "vacuity: ordinary bash fences are not SQL markers (exits 0)" {
  # The extractor opens ```bash only to look for a trino-query.sh / muso query
  # invocation INSIDE. A skill full of ordinary bash examples carries no SQL —
  # treating every fence as a marker is what made the first fix still refuse.
  printf '```bash\nls -la /tmp\n```\n' > "$TEST_TMPDIR/skills-all/dummy/a.md"
  run run_gate_py "skills-all/dummy/a.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to compile"* ]]
}

@test "vacuity: a commented trino-query.sh mention is documentation, not SQL (exits 0)" {
  printf '```bash\n# bash trino-query.sh "SELECT 1"\n```\n' > "$TEST_TMPDIR/skills-all/dummy/a.md"
  run run_gate_py "skills-all/dummy/a.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to compile"* ]]
}

@test "vacuity: a file that DOES carry a sql fence but yields no block still exits 2" {
  # This is the real extractor-broken signal the vacuity refusal exists for:
  # the marker says SQL is here, extraction disagrees. It must stay fail-closed,
  # otherwise the fix above becomes a bypass.
  printf '```sql\n```\n' > "$TEST_TMPDIR/skills-all/dummy/a.md"
  run run_gate_py "skills-all/dummy/a.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to pass vacuously"* ]]
}

@test "vacuity: SQL that is entirely declared-skipped exits 0, not 2" {
  printf '<!-- trino-sql-gate: skip (fixture) -->\n```sql\nSELECT 1\n```\n' \
    > "$TEST_TMPDIR/skills-all/dummy/a.md"
  run run_gate_py "skills-all/dummy/a.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"declared-skipped"* ]]
}

# --------------------------------------------------------------- False green --
# Each test below pins a path that previously let a real failure exit 0. They
# are the regression locks for the three enforcement-gate defects found in
# review of the gate's own PR (#811) — every one of them was a way to ship
# stale SQL behind a green check.

# Builds a git repo in $TEST_TMPDIR with an origin/main to diff against, so the
# bash driver's PR-mode paths (changed-file discovery + the baseline ratchet)
# are exercised for real rather than stubbed.
init_pr_repo() {
  git -C "$TEST_TMPDIR" init -q
  git -C "$TEST_TMPDIR" config user.email t@example.com
  git -C "$TEST_TMPDIR" config user.name t
  git -C "$TEST_TMPDIR" add -A
  git -C "$TEST_TMPDIR" commit -qm base
  # A local 'origin/main' ref is enough — the driver only ever reads it.
  git -C "$TEST_TMPDIR" update-ref refs/remotes/origin/main HEAD
}

@test "false-green: changed-file discovery failing exits 2, never 'nothing to check'" {
  # No git repo at all, so `git diff origin/main...HEAD` cannot resolve. The
  # old code sent that to an empty scope and exited 0 — a PR full of stale SQL
  # would have been reported clean.
  write_fence "$TEST_TMPDIR/skills-all/dummy/a.md" "SELECT RATCHET_FAIL_MARKER"
  export REPO_ROOT="$TEST_TMPDIR"
  export TRINO_SQL_FULL_SCAN=0
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Cannot determine changed files"* ]]
  # Must not have taken the "nothing to check" SUCCESS path. Matched on that
  # message specifically — the fail-closed error text quotes the phrase itself.
  [[ "$output" != *"No changed skills-all/"* ]]
}

@test "false-green: stability — a resolvable base ref still scopes normally (exit 0)" {
  # Pairs with the test above: proves the fail-closed branch discriminates a
  # broken base ref from the ordinary "no relevant files changed" case, rather
  # than exiting 2 unconditionally.
  init_pr_repo
  export REPO_ROOT="$TEST_TMPDIR"
  export TRINO_SQL_FULL_SCAN=0
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to check"* ]]
}

@test "false-green: a PR adding a failing query AND its baseline entry is rejected" {
  # The end-to-end bypass: baseline the regression in the same change that
  # introduces it and Layer B counts it as pre-existing debt, exiting 0.
  init_pr_repo
  write_fence "$TEST_TMPDIR/skills-all/dummy/a.md" "SELECT RATCHET_FAIL_MARKER"
  export REPO_ROOT="$TEST_TMPDIR"
  # Generate the baseline entry for the brand-new failing statement...
  run run_gate_py --full --generate-baseline
  [ "$status" -eq 0 ]
  # ...and commit query + baseline together, exactly as a bypassing PR would.
  git -C "$TEST_TMPDIR" add -A
  git -C "$TEST_TMPDIR" commit -qm "add query and baseline it"
  export TRINO_SQL_FULL_SCAN=0
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gained entries relative to the merge base"* ]]
  [[ "$output" == *"can only SHRINK"* ]]
}

@test "false-green: stability — removing a baseline entry is still allowed" {
  # Pairs with the test above: the ratchet must block growth only. Without this
  # the previous test would pass just as well against a check that rejected any
  # baseline edit at all.
  write_fence "$TEST_TMPDIR/skills-all/dummy/a.md" "SELECT RATCHET_FAIL_MARKER"
  run run_gate_py --full --generate-baseline
  [ "$status" -eq 0 ]
  init_pr_repo
  # Fix the query and drop its baseline entry — the shrink direction.
  write_fence "$TEST_TMPDIR/skills-all/dummy/a.md" "SELECT RATCHET_PASS_MARKER"
  : > "$TEST_TMPDIR/.trino-sql-baseline.txt"
  git -C "$TEST_TMPDIR" add -A
  git -C "$TEST_TMPDIR" commit -qm "fix query, shrink baseline"
  export REPO_ROOT="$TEST_TMPDIR"
  export TRINO_SQL_FULL_SCAN=0
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"gained entries"* ]]
}

@test "false-green: same-hash pass/fail collision keeps the failing occurrence" {
  # Identical raw SQL in a bare ```sql fence and behind trino-query.sh hashes
  # the same, but only the runner block is rewritten — here into the stub's
  # PASS marker. Keyed by hash, whichever block was visited last won and the
  # failure vanished; per-occurrence records keep it.
  mkdir -p "$TEST_TMPDIR/scripts"
  cat > "$TEST_TMPDIR/scripts/trino-query.sh" <<'REWRITE'
#!/usr/bin/env bash
# Stub standing in for the real legacy-name rewrite: under TRINO_REWRITE_ONLY=1
# trino-query.sh echoes the rewritten SQL and exits 0.
echo "${1//RATCHET_FAIL_MARKER/RATCHET_PASS_MARKER}"
REWRITE
  chmod +x "$TEST_TMPDIR/scripts/trino-query.sh"

  {
    echo '```sql'
    echo 'SELECT RATCHET_FAIL_MARKER'
    echo '```'
    echo
    echo '```bash'
    echo 'bash scripts/trino-query.sh "SELECT RATCHET_FAIL_MARKER"'
    echo '```'
  } > "$TEST_TMPDIR/skills-all/dummy/a.md"

  run run_gate_py --full
  # The bare fence genuinely fails; the rewritten runner block genuinely passes.
  # The run must stay red on the real failure.
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 pass"* ]]
  [[ "$output" == *"1 new-fail"* ]]
}

@test "false-green: a leading ';' is a delimiter — SafetyViolation, kubectl never called" {
  # THE safety invariant. split_statements() drops the empty first statement,
  # so this payload used to read as delimiter-free and was SENT: the Trino CLI
  # keeps the EXPLAIN prefix on the empty first statement and EXECUTES the
  # trailing SELECT for real against prod.
  run run_gate_py --send-raw 'EXPLAIN (TYPE VALIDATE) ; SELECT * FROM hive.dangerous'
  [ "$status" -eq 2 ]
  [[ "$output" == *"SAFETY VIOLATION"* ]]
  # The whole point: nothing reached the cluster.
  run grep -c exec "$KUBECTL_LOG"
  [ "$status" -ne 0 ] || [ "$output" = "0" ]
}

@test "false-green: stability — a ';' inside a comment is still not a delimiter" {
  # Pairs with the test above: the detector must not regress into a naive
  # substring check. A literal ';' inside a `-- ...` comment is a real case in
  # skills-all/muso-query-writer/reference.md and must still send.
  run run_gate_py --send-raw 'EXPLAIN (TYPE VALIDATE) SELECT 1 -- a ; b'
  [ "$status" -eq 0 ]
  run grep -c exec "$KUBECTL_LOG"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "false-green: a transport error is never absorbed by the baseline (exit 2)" {
  # A kubectl/container error also exits non-zero. Treating it as ok=False let
  # the baseline swallow it, so a total Trino outage reported every baselined
  # statement as 'baselined-fail' and exited 0 having validated nothing.
  write_fence "$TEST_TMPDIR/skills-all/dummy/a.md" "SELECT TRANSPORT_FAIL_MARKER"
  # Baseline that exact statement, so the old code path would have exited 0.
  h="$(python3 -c "import sys;sys.path.insert(0,'$HYDRA_REPO');from scripts.lib import trino_sql_gate as g;print(g.normalized_hash('SELECT TRANSPORT_FAIL_MARKER'))")"
  echo "$h -- skills-all/dummy/a.md:2 -- SELECT TRANSPORT_FAIL_MARKER" \
    > "$TEST_TMPDIR/.trino-sql-baseline.txt"
  run run_gate_py --full
  [ "$status" -eq 2 ]
  [[ "$output" == *"transport error"* ]]
  [[ "$output" != *"baselined-fail"* ]]
}

@test "false-green: stability — a real Trino compile failure is still a SQL verdict" {
  # Pairs with the test above: only NON-Trino stderr may escalate to exit 2.
  # A genuine `Query <id> failed:` must stay a baselineable ok=False, or the
  # ratchet stops working entirely.
  write_fence "$TEST_TMPDIR/skills-all/dummy/a.md" "SELECT RATCHET_FAIL_MARKER"
  run run_gate_py --full --generate-baseline
  [ "$status" -eq 0 ]
  run run_gate_py --full
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 baselined-fail"* ]]
}

@test "false-green: an undecodable file in scope cannot be hidden by a valid block" {
  # The old `continue` dropped the unreadable file; the readable one kept
  # result.blocks non-empty, so the 'refusing to pass vacuously' guard stayed
  # quiet and the gate exited 0 having scanned only part of its scope.
  printf 'header\n\xff\xfe binary garbage\n' > "$TEST_TMPDIR/skills-all/dummy/bad.md"
  write_fence "$TEST_TMPDIR/skills-all/dummy/good.md" \
    "SELECT id,email,firstname,lastname,createdat FROM postgresql_core.public.users"
  run run_gate_py "skills-all/dummy/bad.md" "skills-all/dummy/good.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read/decode"* ]]
}
