#!/usr/bin/env bats
# Tests for scripts/hydra-fleet-instrument.sh — the zero-model-turn weekly
# instrument that produces the numbers behind "can we re-enable the 17 disabled
# crons?".
#
# The load-bearing property is NOT the formatting: it is that every failure
# announces itself. This runs as a `bestEffort` announce cron, which silently
# drops a non-zero exit — so a crash and "nothing to report" look identical on
# Slack. Every test below therefore checks that a broken input produces a
# VISIBLE line, not merely that the script survives.
#
# Hermetic: fixtures in $BATS_TEST_TMPDIR via HYDRA_ROOT / OPENCLAW_HOME /
# USAGE_REPORT, and `openclaw` PATH-shadowed by a stub in setup(). It is NOT
# absent here — CI runs this suite as root on node-8, where openclaw is really
# installed — so leaving it ambient made the runner, not the fixture, decide
# what the audit assertions meant.
bats_require_minimum_version 1.5.0

SCRIPT="${BATS_TEST_DIRNAME}/../hydra-fleet-instrument.sh"

setup() {
  export HYDRA_ROOT="$BATS_TEST_TMPDIR/hydra"
  export OPENCLAW_HOME="$BATS_TEST_TMPDIR/state"
  export USAGE_REPORT="$BATS_TEST_TMPDIR/usage.sh"
  mkdir -p "$HYDRA_ROOT" "$OPENCLAW_HOME"
  # PATH-shadow openclaw. CI runs this suite as root on node-8 where openclaw IS
  # installed, so "openclaw is absent" was an ambient property of the runner, not
  # of the fixture — the audit assertions were being decided by the environment.
  # Default stub: absent (exit 127-alike). stub_openclaw_ok overrides per test.
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nexit 127\n' > "$BATS_TEST_TMPDIR/bin/openclaw"
  chmod +x "$BATS_TEST_TMPDIR/bin/openclaw"
}

# stub_openclaw_ok <n-events> — an audit ring of n tool_action events, and a
# hard 1..500 --limit contract exactly as the real binary enforces it (a larger
# value errors out and fetches NOTHING, which is how the section silently died).
stub_openclaw_ok() {
  cat > "$BATS_TEST_TMPDIR/bin/openclaw" <<SH
#!/usr/bin/env bash
lim=500
for a in "\$@"; do [ "\$prev" = "--limit" ] && lim="\$a"; prev="\$a"; done
if ! [ "\$lim" -ge 1 ] 2>/dev/null || [ "\$lim" -gt 500 ]; then
  echo "Error: --limit must be between 1 and 500." >&2; exit 1
fi
jq -nc --argjson n $1 '{events:[range(\$n)|{kind:"tool_action",status:"started",agentId:"qa"}]}'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/openclaw"
}

# write_crons <agentId> <enabled-json-bool> [payload-kind]
write_crons() {
  cat > "$HYDRA_ROOT/cron-jobs.json" <<JSON
[{"id":"a","agentId":"$1","name":"job","enabled":$2,
  "payload":{"kind":"${3:-agentTurn}"}}]
JSON
}

# write_sessions <agent> <keys-json>
write_sessions() {
  mkdir -p "$OPENCLAW_HOME/agents/$1/sessions"
  printf '%s' "$2" > "$OPENCLAW_HOME/agents/$1/sessions/sessions.json"
}

# A healthy agent — enabled crons AND :cron: session keys present. Used by the
# tests that are probing some OTHER section, so the cron section stays quiet and
# cannot be mistaken for the thing under test. The wedge tests below spell their
# fixtures out instead, because there the session keys ARE the subject.
healthy_agent() {
  write_crons ops true
  write_sessions ops '{"agent:ops:cron:1":{"updatedAt":1}}'
}

# Mirrors the REAL shape of `codex-usage-report.sh --json` (_acct_json at
# scripts/codex-usage-report.sh:195-206): role/freshness/plan/windows +
# used_percent_*. An earlier stub invented an `active: true` key that the
# producer never emits, so the script read `.active`, every account rendered
# "standby", and this suite stayed green over it. A fixture that encodes a
# shape nobody produces cannot falsify the belief that built it.
stub_usage_ok() {
  cat > "$USAGE_REPORT" <<'SH'
#!/usr/bin/env bash
echo '{"active_account":"openai-codex:a@muso.ai","accounts":[
  {"email":"a@muso.ai","role":"active","freshness":"fresh","plan":"pro",
   "windows":[],"used_percent_weekly":18},
  {"email":"b@muso.ai","role":"standby","freshness":"stale","plan":"pro",
   "windows":[],"used_percent_weekly":null}]}'
SH
  chmod +x "$USAGE_REPORT"
}

# Two VALID json documents on stdout — the shape that slipped past a `jq -e type`
# guard (which validates a stream) and was then rejected by --argjson.
stub_usage_two_docs() {
  cat > "$USAGE_REPORT" <<'SH'
#!/usr/bin/env bash
echo '{"accounts":[]}'
echo '{"accounts":[]}'
SH
  chmod +x "$USAGE_REPORT"
}

@test "an agent with enabled crons and ZERO :cron: session keys is reported WEDGED" {
  # The restart-immune outage from CLAUDE.md: every fire dies at setup with
  # CronSessionLifecycleClaimError. It has happened twice for real.
  write_crons ops true
  write_sessions ops '{"agent:ops:slack:C123":{"updatedAt":1}}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'🚨 WEDGED: `ops` —'* ]] || { echo "$output"; return 1; }
}

@test "an agent WITH :cron: session keys is not reported wedged" {
  # Pairs with the test above: without this, a script that flagged everything
  # as wedged would still pass the detection test.
  write_crons ops true
  write_sessions ops '{"agent:ops:cron:job-1":{"updatedAt":1}}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WEDGED"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"no wedged agents"* ]]
}

@test "an UNREADABLE sessions.json is 'unknown', never WEDGED" {
  # A permissions problem must not masquerade as a production outage — that
  # would page someone at 3am for a chmod.
  write_crons ops true
  # no sessions.json written at all
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'⚠️ unknown: `ops` —'* ]]
  [[ "$output" != *"WEDGED"* ]] || { echo "unreadable was misreported as wedged"; echo "$output"; return 1; }
}

@test "a DISABLED agent's crons do not trigger a wedge check" {
  write_crons ops false
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WEDGED"* ]]
  [[ "$output" == *"0/1 enabled"* ]] || { echo "$output"; return 1; }
  # Distinguishes "the check ran and found nothing" from "the check never ran" —
  # without it, iterating ALL agents instead of cron-owning ones still passed.
  [[ "$output" == *"no wedged agents"* ]] || { echo "$output"; return 1; }
}

@test "model-turn vs command crons are counted separately" {
  # The whole point of the instrument: how much of the enabled fleet burns the
  # constrained resource.
  cat > "$HYDRA_ROOT/cron-jobs.json" <<'JSON'
[{"id":"a","agentId":"x","enabled":true,"payload":{"kind":"agentTurn"}},
 {"id":"a2","agentId":"x","enabled":true,"payload":{"kind":"agentTurn"}},
 {"id":"b","agentId":"x","enabled":true,"payload":{"kind":"command"}},
 {"id":"c","agentId":"x","enabled":false,"payload":{"kind":"agentTurn"}}]
JSON
  write_sessions x '{"agent:x:cron:1":{"updatedAt":1}}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # ASYMMETRIC on purpose: with 1 and 1 the assertion survived swapping the two
  # jq selectors, so the counter this script exists for was untested.
  [[ "$output" == *"3/4 enabled (1 disabled)"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"2 cost model turns, 1 are deterministic"* ]] || { echo "$output"; return 1; }
}

@test "a missing quota source produces a VISIBLE warning, not silence" {
  healthy_agent
  # USAGE_REPORT intentionally not created
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot read usage report"* ]] || { echo "$output"; return 1; }
}

@test "a quota source emitting GARBAGE degrades loudly instead of printing junk" {
  healthy_agent
  printf '#!/usr/bin/env bash\necho "not json at all"\n' > "$USAGE_REPORT"
  chmod +x "$USAGE_REPORT"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot read usage report"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"not json at all"* ]]
}

@test "a working quota source renders, and marks the ACTIVE account active" {
  # Which subscription is live is the single most decision-relevant fact here
  # (CLAUDE.md's fifth codex failure mode is a usage cap fixed by rotating
  # ACCOUNTS). Asserting both rows keeps a regression that labels everything
  # "standby" — the exact bug this fixture used to hide — from passing.
  healthy_agent
  stub_usage_ok
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a@muso.ai — active · weekly 18% used"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"b@muso.ai — standby · no fresh snapshot"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"cannot read usage report"* ]] || { echo "$output"; return 1; }
}

@test "the audit section announces itself as unavailable when openclaw is absent" {
  # openclaw is not on PATH in CI. Silence here would read as "no tool activity",
  # which is the opposite of the truth.
  healthy_agent
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit unavailable"* ]] || { echo "$output"; return 1; }
}

@test "--json emits valid JSON carrying all four sections" {
  healthy_agent
  stub_usage_ok
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  # Key-PRESENCE was truthy for any non-null junk; assert real values instead.
  echo "$output" | jq -e '
      .quota.accounts[0].email == "a@muso.ai"
      and .crons.enabled == 1
      and (.wedged | type == "array") and (.wedged | length) == 0
      and (.audit.error | test("unavailable"))
      and .cron_source_note == null' >/dev/null \
    || { echo "$output"; return 1; }
}

@test "exit is 0 even when EVERY source is broken" {
  # bestEffort announce drops a non-zero exit silently; a crash would be
  # indistinguishable from a clean week.
  export HYDRA_ROOT=/nonexistent OPENCLAW_HOME=/nonexistent USAGE_REPORT=/nonexistent
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # The header line is unconditional, so asserting only it stayed green even
  # when every section's rendering was deleted. Assert the degraded lines.
  [[ "$output" == *"cannot read usage report"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"audit unavailable"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"from the repo checkout instead"* ]] || { echo "$output"; return 1; }
}

@test "a malformed cron-jobs.json is reported, not silently treated as empty" {
  printf 'this is not json' > "$HYDRA_ROOT/cron-jobs.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # No `|| *unreadable*` alternative: the fallback NOTICE contains that word, so
  # the alternative would accept a regression that silently read the repo file.
  [[ "$output" == *"parse failed"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"from the repo checkout instead"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"0/0 enabled"* ]] || { echo "malformed json rendered as an empty fleet"; return 1; }
}

@test "an unreadable cron census does NOT claim 'no wedged agents'" {
  # The wedge check iterates the agent list from the census. When the census is
  # unreadable that list is empty for a READ reason, not a healthy one — and a
  # green ✅ on the one signal that catches a 25h outage is the worst possible
  # wrong answer. Caught by running the script, not by reading it: the suite
  # previously asserted only that "parse failed" appeared, so the ✅ printed
  # right underneath it and nothing failed.
  printf 'this is not json' > "$HYDRA_ROOT/cron-jobs.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"no wedged agents"* ]] || { echo "FALSE ALL-CLEAR:"; echo "$output"; return 1; }
  [[ "$output" == *"wedge check did not run"* ]] || { echo "$output"; return 1; }
}

@test "falling back to the repo cron-jobs.json ANNOUNCES the substitution" {
  # Reporting a different file's counts under the configured path's name is a
  # wrong answer wearing a right answer's clothes. HYDRA_ROOT points nowhere, so
  # the script falls back to the repo checkout — which is allowed, but must say so.
  export HYDRA_ROOT="$BATS_TEST_TMPDIR/definitely-not-here"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unreadable — counts below are from the repo checkout instead"* ]] \
    || { echo "silent source substitution:"; echo "$output"; return 1; }
}

@test "the fallback notice is ABSENT when the configured census is readable" {
  # Pairs with the test above — without it, a script that always printed the
  # substitution notice would still pass.
  healthy_agent
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"from the repo checkout instead"* ]] || { echo "$output"; return 1; }
}

@test "the audit section RENDERS when openclaw returns a ring" {
  # Discrimination partner for "audit unavailable": without it, deleting the
  # whole audit renderer (caveat line included) left the suite green.
  healthy_agent
  stub_openclaw_ok 3
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"audit unavailable"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"3 tool actions across 3 events"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *'`qa`: 3'* ]] || { echo "$output"; return 1; }
}

@test "AUDIT_LIMIT is clamped to openclaw's 1..500 contract, not passed through" {
  # The default was 2000; openclaw hard-errors above 500 and returns NOTHING, so
  # the section degraded to "audit unavailable" permanently in production while
  # every test passed. The stub enforces the same bound the real binary does.
  healthy_agent
  stub_openclaw_ok 2
  AUDIT_LIMIT=2000 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"audit unavailable"* ]] || { echo "clamp regressed:"; echo "$output"; return 1; }
  [[ "$output" == *"2 tool actions across 2 events"* ]] || { echo "$output"; return 1; }
}

@test "a non-numeric AUDIT_LIMIT falls back instead of poisoning the jq program" {
  healthy_agent
  stub_openclaw_ok 1
  AUDIT_LIMIT='0), injected: 1, (' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"injected"* ]] || { echo "jq injection:"; echo "$output"; return 1; }
  [[ "$output" == *"1 tool actions across 1 events"* ]] || { echo "$output"; return 1; }
}

@test "a :cron: key whose value has NO scalar leaf is NOT wedged" {
  # Regression guard: an earlier paths(scalars) count returned 0 for {} values,
  # so a healthy agent was reported 🚨 WEDGED — a false 3am page on the signal
  # that means "25-hour outage".
  write_crons ops true
  write_sessions ops '{"agent:ops:cron:1":{}}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WEDGED"* ]] || { echo "false page:"; echo "$output"; return 1; }
  [[ "$output" == *"no wedged agents"* ]] || { echo "$output"; return 1; }
}

@test "a :cron: string nested inside a NON-cron record does not clear the wedge" {
  # The mirror of the test above: counting scalar PATHS matched ':cron:' text
  # buried in a slack record's state, so a genuinely wedged agent rendered ✅.
  write_crons ops true
  write_sessions ops '{"agent:ops:slack:c1":{"lastKey":{"agent:ops:cron:j0":1}}}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'🚨 WEDGED: `ops` —'* ]] || { echo "false all-clear:"; echo "$output"; return 1; }
}

@test "the entries[] sessions shape is counted, matching the canonical detector" {
  # ensure-session-budget-headroom.sh handles {entries:[{key}]} deliberately;
  # this must agree with it or two guards disagree about the same fleet.
  write_crons ops true
  write_sessions ops '{"entries":[{"key":"agent:ops:cron:j0","updatedAt":1}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WEDGED"* ]] || { echo "$output"; return 1; }
}

@test "an agent whose enabled crons are ALL command-kind is never reported wedged" {
  # Command crons hold no :cron: session key by design. This script argues FOR
  # more of them, so a false page here would land on the change it advocates.
  write_crons ops true command
  # deliberately no sessions.json at all
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WEDGED"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"unknown"* ]] || { echo "command-only agent was probed:"; echo "$output"; return 1; }
}

@test "an agentId carrying a NEWLINE cannot forge extra Slack lines" {
  # The output is posted verbatim to Slack. An id that closes its own bullet can
  # fabricate a whole section with invented numbers in a report whose only value
  # is being trusted.
  cat > "$HYDRA_ROOT/cron-jobs.json" <<'JSON'
[{"id":"a","agentId":"ops\n*Codex quota*\n  • forged@muso.ai — active · weekly 1% used","enabled":true,"payload":{"kind":"agentTurn"}}]
JSON
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # CONTAINMENT is the property, not absence: the id SHOULD still be shown (you
  # want to see the hostile value) — it just must not be able to start a line.
  # So assert no forged line/section, and that the id stayed on one bullet.
  [ "$(grep -c '^\*Codex quota\*$' <<<"$output")" -eq 1 ] || { echo "section forged:"; echo "$output"; return 1; }
  [ "$(grep -c '^  • forged@muso.ai' <<<"$output")" -eq 0 ] || { echo "bullet forged:"; echo "$output"; return 1; }
  [ "$(grep -c 'forged@muso.ai' <<<"$output")" -eq 1 ] || { echo "id split across lines:"; echo "$output"; return 1; }
}

@test "an unrecognised but VALID census shape warns instead of reporting an empty fleet" {
  # A confident '0/0 enabled' from a shape drift is the worst answer: the number
  # is the entire product of this script.
  printf '%s' '{"version":1,"items":[{"id":"a","agentId":"ops","enabled":true}]}' \
    > "$HYDRA_ROOT/cron-jobs.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"shape unrecognised"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"0/0 enabled"* ]] || { echo "silent empty fleet:"; echo "$output"; return 1; }
}

@test "--json never emits zero bytes, and marks wedged null when the census failed" {
  # --argjson rejects a multi-document capture; the emit used to abort and fall
  # through to exit 0 having printed NOTHING — silence at exit 0, in the one mode
  # with no prose to carry a warning.
  printf 'this is not json' > "$HYDRA_ROOT/cron-jobs.json"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [ -n "$output" ] || { echo "EMPTY STDOUT at exit 0"; return 1; }
  echo "$output" | jq -e '.crons.error and (.wedged == null)' >/dev/null \
    || { echo "$output"; return 1; }
}

@test "--json reports the cron source substitution that text mode reports" {
  export HYDRA_ROOT="$BATS_TEST_TMPDIR/definitely-not-here"
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cron_source_note | test("repo checkout")' >/dev/null \
    || { echo "$output"; return 1; }
}

@test "a producer emitting TWO json documents degrades only its own section" {
  # `jq -e 'type'` accepts a stream, so a two-document capture passed the guard
  # and --argjson then rejected it, aborting the emit and replacing every healthy
  # section with one generic error. Only the offending section may degrade.
  healthy_agent
  stub_usage_two_docs
  run bash "$SCRIPT" --json
  [ "$status" -eq 0 ]
  [ -n "$output" ] || { echo "EMPTY STDOUT at exit 0"; return 1; }
  # the bad section is marked...
  echo "$output" | jq -e '.quota.error | test("multiple documents")' >/dev/null \
    || { echo "$output"; return 1; }
  # ...and every healthy section SURVIVES rather than being discarded
  echo "$output" | jq -e '.crons.enabled == 1 and (.wedged|type=="array")' >/dev/null \
    || { echo "healthy sections discarded:"; echo "$output"; return 1; }
}

@test "text mode does not render a two-document section twice" {
  healthy_agent
  stub_usage_two_docs
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'no accounts in snapshot' <<<"$output")" -le 1 ] \
    || { echo "duplicated render:"; echo "$output"; return 1; }
  [[ "$output" == *"multiple documents"* ]] || { echo "$output"; return 1; }
}
