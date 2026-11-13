#!/usr/bin/env bats
# The SCHEDULER wiring for the profile-merge queue (firstmate inbox 087 item 3).
#
# Why this file exists: the queue's code is core-backend's, and it is well covered there,
# but the CLOCK that runs it lived only in /etc/cron.d on node-8. On 2026-11-05 a hand edit
# there turned the variant line into `plan.py ... > plan.daily.json && cp plan.daily.json
# plan.json`; plan.py writes plan.json itself, so every downstream step read a 267-byte
# summary as if it were the 457 KB plan. Nothing in review could see the line, and no test
# could fail. These cases EXECUTE the writer and the runners and assert the installed
# result and the actual behaviour - never a grep of an installer's source text
# (firstmate ruling 2026-11-04: run the installer into a temp root, assert the results).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"
CRON_WRITER="$HYDRA_REPO/scripts/merge-queue/install-cron.sh"
PREFLIGHT="$HYDRA_REPO/scripts/merge-queue/chain-preflight.sh"
VARIANT="$HYDRA_REPO/scripts/merge-queue/run-variant-queue.sh"
CENSUS="$HYDRA_REPO/scripts/merge-queue/run-census.sh"

setup() {
  TMP="$(mktemp -d)"
  export CRON_DIR="$TMP/cron.d"
  export CHAIN_DIR="$TMP/q1"
  # NOT exported: the cron-writer cases pass HYDRA_ROOT explicitly (they must prove the
  # named tree lands in the cron lines), while the runner cases below use the runner's own
  # default (the checkout it lives in), which is what node-8 does.
  HYDRA_ROOT="$TMP/opt/hydra"
  export MAIN_ENV="$TMP/no-main.env"
  export EDGE_ENV="$TMP/no-edge.env"
  export MERGE_QUEUE_VARIANT_KILL="$TMP/merge-queue-variant.disabled"
  mkdir -p "$CRON_DIR" "$CHAIN_DIR" "$TMP/opt/hydra/scripts/merge-queue"
  # A stand-in chain whose bytes we control, plus a manifest that pins them.
  for f in plan.py variant_plan.py send_variant_copy.py clickup_merges.py sql.py same_person.py; do
    printf 'pinned %s\n' "$f" > "$CHAIN_DIR/$f"
    printf '%s  %s\n' "$(sha256sum "$CHAIN_DIR/$f" | awk '{print $1}')" "$f" >> "$TMP/chain-manifest.sha256"
  done
  export CHAIN_MANIFEST="$TMP/chain-manifest.sha256"
  printf '{"ticket":"1amvh5500001"}\n' > "$CHAIN_DIR/decisions-batch-2.jsonl"
  printf '{"ticket":"1amvh5500002"}\n' > "$CHAIN_DIR/m1_sel.json"
  printf '{"ticket":"1amvh5500003"}\n' > "$CHAIN_DIR/plan.json"
  # A python3 stand-in that records the argv it was called with, so the runner's real
  # sequence (and the absence of --apply on a dry run) is observable without prod access.
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/python3" << 'STUB'
#!/usr/bin/env bash
echo "cwd=$PWD argv=$* approved=${Q1_VARIANT_COPY_APPROVED:-unset}" >> "$STUB_LOG"
STUB
  chmod +x "$TMP/bin/python3"
  export STUB_LOG="$TMP/python-calls.log"
  : > "$STUB_LOG"
  export PATH="$TMP/bin:$PATH"
  export PYTHON="$TMP/bin/python3"
}

teardown() {
  # NOT an `EXIT` trap: in bats 1.14 a trap armed inside setup() swallows the failure
  # report of a FAILING test (it printed "Executed 0 instead of expected 1 tests" and
  # exited 0) - reproduced 2026-11-04.
  rm -rf "$TMP"
}

install_cron() {
  run env CRON_DIR="$CRON_DIR" CHAIN_DIR="$CHAIN_DIR" HYDRA_ROOT="$HYDRA_ROOT" bash "$CRON_WRITER"
  [ "$status" -eq 0 ]
}

@test "the installer, the cron writer and both runners ship executable" {
  [ -x "$INSTALLER" ]
  [ -x "$CRON_WRITER" ]
  [ -x "$VARIANT" ]
  [ -x "$CENSUS" ]
  [ -x "$PREFLIGHT" ]
}

@test "the writer installs BOTH merge-queue cron files, mode 644, marked as managed" {
  install_cron
  [ -f "$CRON_DIR/merge-queue-census" ]
  [ -f "$CRON_DIR/merge-queue-variant-queue" ]
  [ "$(stat -c '%a' "$CRON_DIR/merge-queue-census")" = "644" ]
  [ "$(stat -c '%a' "$CRON_DIR/merge-queue-variant-queue")" = "644" ]
  grep -q 'MANAGED BY scripts/install-aux-units.sh' "$CRON_DIR/merge-queue-census"
  grep -q 'MANAGED BY scripts/install-aux-units.sh' "$CRON_DIR/merge-queue-variant-queue"
}

@test "the installed schedules and commands are the versioned runners, not inline bash -c" {
  install_cron
  grep -qE '^\*/30 \* \* \* \* root .*/scripts/merge-queue/run-census\.sh' "$CRON_DIR/merge-queue-census"
  grep -qE '^17 10 \* \* \* root .*/scripts/merge-queue/run-variant-queue\.sh' "$CRON_DIR/merge-queue-variant-queue"
  grep -qF "root $HYDRA_ROOT/scripts/merge-queue/run-variant-queue.sh" "$CRON_DIR/merge-queue-variant-queue"
  grep -qF ">> $CHAIN_DIR/variant-cron.log" "$CRON_DIR/merge-queue-variant-queue"
  grep -qF ">> $CHAIN_DIR/census-cron.log" "$CRON_DIR/merge-queue-census"
  # No inline interpreter call: the command in cron.d is one path, and the logic lives in
  # a file the suite above can run.
  run grep -q 'python3' "$CRON_DIR/merge-queue-variant-queue"
  [ "$status" -ne 0 ]
}

@test "REGRESSION (2026-11-05): no installed line clobbers plan.json with a summary" {
  # plan.py writes plan.json itself (plan.py:140); lines 142-143 print only a ~267-byte
  # summary. Redirecting that stdout onto plan.json, or copying it over plan.json, is the
  # defect that made every downstream step read a summary as a plan for a day.
  install_cron
  # `run grep` + an explicit status check, NOT `! grep`: bash's errexit ignores the status
  # of a `!` list, so a negated grep inside a bats test body can pass on a MATCH and the
  # case goes green while asserting nothing (found while mutation-checking this very file).
  run grep -q 'plan\.daily\.json' "$CRON_DIR/merge-queue-variant-queue"
  [ "$status" -ne 0 ]
  run grep -qE 'cp [^ ]*plan[^ ]* ?plan\.json|cp plan\.daily\.json plan\.json' "$CRON_DIR/merge-queue-variant-queue"
  [ "$status" -ne 0 ]
  run grep -qE 'plan\.py.*> *plan\.json' "$CRON_DIR/merge-queue-variant-queue"
  [ "$status" -ne 0 ]
}

@test "the INSTALLER's argv decides which tree the cron lines name" {
  # Same seam as the churn suite: a child that is not handed HYDRA_ROOT silently falls
  # back to /opt/hydra and writes cron entries pointing at the wrong checkout.
  run env HYDRA_STOP_AFTER=merge-queue-cron CRON_DIR="$CRON_DIR" CHAIN_DIR="$CHAIN_DIR" \
    bash "$INSTALLER" "$HYDRA_REPO"
  [ "$status" -eq 0 ]
  grep -qF "root $HYDRA_REPO/scripts/merge-queue/run-variant-queue.sh" "$CRON_DIR/merge-queue-variant-queue"
  grep -qF "root $HYDRA_REPO/scripts/merge-queue/run-census.sh" "$CRON_DIR/merge-queue-census"
}

@test "preflight: a pinned chain reads clean" {
  run bash "$PREFLIGHT" --chain-dir "$CHAIN_DIR" --manifest "$CHAIN_MANIFEST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"6 pinned file(s) match"* ]]
}

@test "preflight: one changed file FAILS and is named" {
  printf 'not the pinned bytes\n' > "$CHAIN_DIR/plan.py"
  run bash "$PREFLIGHT" --chain-dir "$CHAIN_DIR" --manifest "$CHAIN_MANIFEST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT changed: plan.py"* ]]
}

@test "preflight: a missing file FAILS and is named (a stale tree is not a pass)" {
  rm -f "$CHAIN_DIR/send_variant_copy.py"
  run bash "$PREFLIGHT" --chain-dir "$CHAIN_DIR" --manifest "$CHAIN_MANIFEST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT missing: send_variant_copy.py"* ]]
}

@test "preflight: a PARTIAL manifest FAILS and names the pins it lacks" {
  # QA finding 2026-11-11: a manifest truncated to a single valid pin used to exit 0 with
  # "1 pinned file(s) match", so a stale send_variant_copy.py kept posting copy nobody
  # approved. The expected set lives in the script, not in the manifest.
  printf '%s  plan.py\n' "$(sha256sum "$CHAIN_DIR/plan.py" | awk '{print $1}')" > "$TMP/partial.sha256"
  run bash "$PREFLIGHT" --chain-dir "$CHAIN_DIR" --manifest "$TMP/partial.sha256"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no pin for variant_plan.py"* ]]
  [[ "$output" == *"a partial manifest would let it drift unnoticed"* ]]
  [[ "$output" != *"pinned file(s) match"* ]]
}

@test "preflight: a DUPLICATE pin FAILS (an ambiguous pin is not a pass)" {
  printf '%s  plan.py\n' "$(sha256sum "$CHAIN_DIR/plan.py" | awk '{print $1}')" >> "$CHAIN_MANIFEST"
  printf '%s  some_other.py\n' "$(sha256sum "$CHAIN_DIR/sql.py" | awk '{print $1}')" >> "$CHAIN_MANIFEST"
  run bash "$PREFLIGHT" --chain-dir "$CHAIN_DIR" --manifest "$CHAIN_MANIFEST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pins plan.py twice"* ]]
}

@test "preflight: an unknown file in the manifest is rejected by name" {
  printf '%s  not_in_the_chain.py\n' "$(sha256sum "$CHAIN_DIR/sql.py" | awk '{print $1}')" >> "$CHAIN_MANIFEST"
  run bash "$PREFLIGHT" --chain-dir "$CHAIN_DIR" --manifest "$CHAIN_MANIFEST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown file: not_in_the_chain.py"* ]]
}

@test "preflight: an empty manifest is a FAILURE, not a clean tree" {
  printf '# no pins here\n' > "$TMP/empty.sha256"
  run bash "$PREFLIGHT" --chain-dir "$CHAIN_DIR" --manifest "$TMP/empty.sha256"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no pins"* ]]
}

@test "the runner SENDS by default, and neither the runner nor the README claims a dry default" {
  # QA finding 2026-11-11: the README said "Dry run by default" while DRY_RUN defaulted to
  # 0, so an operator following the runbook would post real customer replies believing they
  # were previewing. The default is deliberate (the cron line passes no flag and must send),
  # so the assertion pins BOTH halves: the code applies, the docs say it applies.
  run grep -qE '^DRY_RUN="\$\{DRY_RUN:-0\}"' "$VARIANT"
  [ "$status" -eq 0 ]
  run grep -qi 'dry.run by default' "$VARIANT" "$HYDRA_REPO/scripts/merge-queue/README.md"
  [ "$status" -ne 0 ]
}

@test "variant run: the kill file stops the pass and no interpreter is invoked" {
  mkdir -p "$(dirname "$MERGE_QUEUE_VARIANT_KILL")"
  : > "$MERGE_QUEUE_VARIANT_KILL"
  run bash "$VARIANT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kill file present"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "variant run: a drifted chain REFUSES to send (no interpreter is invoked)" {
  printf 'drifted\n' > "$CHAIN_DIR/variant_plan.py"
  run bash "$VARIANT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"chain drift"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "variant run: clean chain -> plan, variant plan, then ONE applying send with the copy approved" {
  run bash "$VARIANT"
  [ "$status" -eq 0 ]
  mapfile -t calls < "$STUB_LOG"
  [ "${#calls[@]}" -eq 3 ]
  [[ "${calls[0]}" == *"argv=plan.py clickup.json m1_sel.json"* ]]
  [[ "${calls[1]}" == *"argv=variant_plan.py plan.json decisions-batch-2.jsonl"* ]]
  [[ "${calls[2]}" == *"argv=send_variant_copy.py --plan variants.json --apply"* ]]
  [[ "${calls[2]}" == *"approved=1"* ]]
}

@test "variant run: --dry-run never applies and never claims the copy approval" {
  run bash "$VARIANT" --dry-run
  [ "$status" -eq 0 ]
  mapfile -t calls < "$STUB_LOG"
  [ "${#calls[@]}" -eq 3 ]
  [[ "${calls[2]}" == *"argv=send_variant_copy.py --plan variants.json"* ]]
  [[ "${calls[2]}" != *"--apply"* ]]
  [[ "${calls[2]}" == *"approved=unset"* ]]
}

@test "census run: kill file stops it; a drifted chain refuses to rewrite plan.json" {
  export MERGE_QUEUE_CENSUS_KILL="$TMP/merge-queue-census.disabled"
  : > "$MERGE_QUEUE_CENSUS_KILL"
  run bash "$CENSUS"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]

  rm -f "$MERGE_QUEUE_CENSUS_KILL"
  printf 'pinned plan.py\n' > "$CHAIN_DIR/plan.py"
  printf 'drifted\n' >> "$CHAIN_DIR/plan.py"
  run bash "$CENSUS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"chain drift"* ]]
  [ ! -s "$STUB_LOG" ]
}
