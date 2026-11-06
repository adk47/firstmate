#!/usr/bin/env bats
# .github/workflows/qa-tier-recheck.yml, executed the way the runner executes it.
#
# The gate step's REAL `run:` body and env names are pulled out with
# yaml.safe_load (never retyped) and run under `bash -e` in a sandbox with a
# PATH-shadowed `gh`, so nothing here reaches GitHub. Assertions are on the
# step's GITHUB_OUTPUT (`go=`), which is what the dispatch step keys on.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WF="$HYDRA_REPO/.github/workflows/qa-tier-recheck.yml"
SHA="0123456789abcdef0123456789abcdef01234567"
TIER_LINE="Tier: 1, because it only touches CI"

setup() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$STUB_GH_ARGV"
[ -z "${STUB_GH_FAIL:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
if [ "$1" = run ]; then cat "${STUB_RUNS_JSON:-/dev/null}"; exit 0; fi
expr=""; prev=""
for a in "$@"; do [ "$prev" = --jq ] && expr="$a"; prev="$a"; done
jq -r "$expr" <<<"${STUB_STATUSES:-[]}"
STUB
  chmod +x "$SANDBOX/bin/gh"
  export STUB_GH_ARGV="$SANDBOX/gh.argv"
  : > "$STUB_GH_ARGV"
  python3 - "$WF" "$SANDBOX" <<'PY'
import sys, yaml
wf, out = sys.argv[1:3]
steps = yaml.safe_load(open(wf))["jobs"]["dispatch"]["steps"]
step = next(s for s in steps if s.get("name") == "Tier re-review gate")
open(f"{out}/gate.sh", "w").write(step["run"])
open(f"{out}/gate.env", "w").write("\n".join(step["env"]))
PY
}

teardown() { rm -rf "$SANDBOX"; }

# run_gate <action> <old-body> <new-body>
run_gate() {
  : > "$SANDBOX/out"
  run env -i PATH="$SANDBOX/bin:$PATH" HOME="$HOME" \
    STUB_GH_ARGV="$STUB_GH_ARGV" STUB_GH_FAIL="${STUB_GH_FAIL:-}" STUB_STATUSES="${STUB_STATUSES:-[]}" \
    GITHUB_OUTPUT="$SANDBOX/out" GH_TOKEN=x REPO=Muso-AI/hydra HEAD_SHA="$SHA" \
    ACTION="$1" OLD_BODY="$2" NEW_BODY="$3" bash -e "$SANDBOX/gate.sh"
}

go() { sed -n 's/^go=//p' "$SANDBOX/out"; }

statuses() {  # newest first, as the API returns them
  local json="[" sep="" s
  for s in "$@"; do json+="$sep{\"context\":\"${s%%=*}\",\"state\":\"${s#*=}\"}"; sep=","; done
  export STUB_STATUSES="$json]"
}

@test "gate env carries exactly the inputs the body reads" {
  for v in GH_TOKEN REPO HEAD_SHA ACTION OLD_BODY NEW_BODY; do
    grep -qx "$v" "$SANDBOX/gate.env"
  done
}

@test "labeled on a NO-GO head -> go" {
  statuses ci=success qa-review=failure
  run_gate labeled "" ""
  [ "$status" -eq 0 ]
  [ "$(go)" = true ]
  grep -qx "repos/Muso-AI/hydra/commits/$SHA/statuses?per_page=100" "$STUB_GH_ARGV"
}

@test "labeled with no verdict yet (PR creation) -> no dispatch" {
  statuses ci=pending
  run_gate labeled "" ""
  [ "$status" -eq 0 ]
  [ "$(go)" = false ]
}

@test "labeled on a GO head -> no dispatch" {
  statuses qa-review=success
  run_gate labeled "" ""
  [ "$(go)" = false ]
}

@test "only the NEWEST qa-review row counts" {
  statuses qa-review=pending qa-review=failure
  run_gate labeled "" ""
  [ "$(go)" = false ]
  statuses qa-review=failure qa-review=success
  run_gate labeled "" ""
  [ "$(go)" = true ]
}

@test "statuses lookup fails -> warn and dispatch anyway" {
  STUB_GH_FAIL=1 run_gate labeled "" ""
  [ "$status" -eq 0 ]
  [ "$(go)" = true ]
  [[ "$output" == *"::warning::"* ]]
}

@test "edit adds the first complete Tier line on a NO-GO head -> go" {
  statuses qa-review=failure
  run_gate edited $'## Summary\nadds the tier:2 label check' $'## Summary\nadds the tier:2 label check\n\n  '"$TIER_LINE"
  [ "$(go)" = true ]
}

@test "edit completes an incomplete 'Tier: 0' -> go" {
  statuses qa-review=failure
  run_gate edited $'body\nTier: 0' $'body\nTier: 0, because docs only'
  [ "$(go)" = true ]
}

@test "edit with CRLF line endings still detects the line" {
  statuses qa-review=failure
  run_gate edited $'body\r\n' $'body\r\n'"$TIER_LINE"$'\r\n'
  [ "$(go)" = true ]
}

@test "edit when the old body already had a Tier line -> no dispatch, no API call" {
  statuses qa-review=failure
  run_gate edited "$TIER_LINE" "$TIER_LINE"$'\ntypo fixed'
  [ "$(go)" = false ]
  [ ! -s "$STUB_GH_ARGV" ]
}

@test "prose mentions, wrong case, and mid-line matches are not a Tier line" {
  statuses qa-review=failure
  for body in "QA said tier: missing" "tier: 1, because x" "see Tier: 1, because x" "Tier: 4, because x" "Tier: 1"; do
    run_gate edited "" "$body"
    [ "$(go)" = false ]
  done
  [ ! -s "$STUB_GH_ARGV" ]
}

@test "a hostile body is data, not code" {
  statuses qa-review=failure
  run_gate edited "" $'$(touch '"$SANDBOX"$'/pwned)\n`touch '"$SANDBOX"$'/pwned`\n'"$TIER_LINE"
  [ "$(go)" = true ]
  [ ! -e "$SANDBOX/pwned" ]
}

@test "a long body does not trip pipefail" {
  statuses qa-review=failure
  big="$TIER_LINE"$'\n'"$(head -c 59900 /dev/zero | tr '\0' 'x')"
  run_gate edited "" "$big"
  [ "$status" -eq 0 ]
  [ "$(go)" = true ]
}

@test "an in-flight run of this workflow never makes a concurrent auto-review refuse" {
  name="$(python3 - "$WF" "$SHA" <<'PY'
import sys, yaml
wf, sha = sys.argv[1:3]
title = "qa Muso-AI/hydra#123 is red"
rn = yaml.safe_load(open(wf)).get("run-name", title)
for k, v in {"github.repository": "Muso-AI/hydra",
             "github.event.pull_request.number": "123",
             "github.event.pull_request.head.sha": sha,
             "github.event.pull_request.title": title}.items():
    rn = rn.replace("${{ " + k + " }}", v)
print(rn)
PY
)"
  printf '[{"databaseId":100,"name":"%s","status":"in_progress","createdAt":"%s"}]\n' \
    "$name" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SANDBOX/runs.json"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/openclaw.calls"\n' "$SANDBOX" > "$SANDBOX/bin/openclaw"
  chmod +x "$SANDBOX/bin/openclaw"
  PATH="$SANDBOX/bin:$PATH" STUB_RUNS_JSON="$SANDBOX/runs.json" GITHUB_RUN_ID=200 \
    run "$HYDRA_REPO/scripts/qa-dispatch-pr-review.sh" 123 "$SHA" Muso-AI/hydra U0AL36NADEY
  [[ "$output" != *"DEDUP-REFUSED"* ]]
  grep -q "cron add" "$SANDBOX/openclaw.calls"
}

@test "the dispatch step forces a broker re-review of the same head" {
  # This workflow exists to re-review the SAME head after a tier-only NO-GO.
  # In broker mode the key is already `done`, so without QA_BROKER_FORCE=1 the
  # enqueue is a duplicate (76), the red qa-review status stays, and no review
  # is ever scheduled. The env is read from the workflow, never retyped.
  python3 - "$WF" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["dispatch"]["steps"]
step = next(s for s in steps if "qa-dispatch-pr-review.sh" in (s.get("run") or ""))
env = step.get("env") or {}
assert env.get("QA_BROKER_FORCE") == "1", env
PY
}

@test "a forced broker dispatch reopens a finished key instead of refusing it" {
  # The wiring above is only useful if the dispatcher honours it end to end.
  export QA_QUEUE_DB="$SANDBOX/queue.sqlite"
  export QA_BROKER_URL=cli
  export QA_DISPATCH_MODE=broker
  export QA_BROKER_DEDUPE_DONE=go-only
  export QA_BROKER_MAX_REVIEWS_PER_KEY=2
  # The dispatcher verifies the head before enqueueing; stub it so the test
  # never reaches GitHub.
  cat > "$SANDBOX/bin/gh-head" <<STUB
#!/usr/bin/env bash
printf '%s 2026-11-06T00:00:00Z\\n' "$SHA"
STUB
  chmod +x "$SANDBOX/bin/gh-head"
  export GH="$SANDBOX/bin/gh-head"
  local broker="$HYDRA_REPO/scripts/lib/qa_broker.py"
  python3 "$broker" --db "$QA_QUEUE_DB" enqueue Muso-AI/hydra 123 "$SHA" U0AL36NADEY >/dev/null
  local id
  id="$(python3 -c "
import sqlite3
c=sqlite3.connect('$QA_QUEUE_DB')
print(c.execute('SELECT id FROM jobs').fetchone()[0])")"
  python3 "$broker" --db "$QA_QUEUE_DB" claim w1 >/dev/null
  python3 "$broker" --db "$QA_QUEUE_DB" finish "$id" w1 no_go >/dev/null
  # Without force: duplicate, nothing queued.
  run env QA_BROKER_FORCE=0 "$HYDRA_REPO/scripts/qa-dispatch-pr-review.sh" 123 "$SHA" Muso-AI/hydra U0AL36NADEY
  [ "$status" -eq 76 ]
  # With force (what the workflow sets): reopened and claimable.
  run env QA_BROKER_FORCE=1 "$HYDRA_REPO/scripts/qa-dispatch-pr-review.sh" 123 "$SHA" Muso-AI/hydra U0AL36NADEY
  [ "$status" -eq 0 ]
  python3 -c "
import sqlite3
c=sqlite3.connect('$QA_QUEUE_DB')
rows=c.execute('SELECT status FROM jobs ORDER BY id').fetchall()
assert [r[0] for r in rows]==['queued'], rows
c.close()"
}
