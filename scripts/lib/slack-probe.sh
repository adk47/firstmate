#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# slack-probe.sh — pure/injectable classifier for smoke-test.sh's post-restart
# Slack account gate (deploy Step 7). Unit-tested by scripts/tests/slack-probe.bats.
#
# WHY: openclaw-main.json carries channels.slack.accounts.*.botToken as hydra-env
# SecretRefs. If a ref does not resolve the gateway drops the token
# (botTokenSource != "config") and that account silently goes dark. Neither
# `openclaw secrets audit` (blind to these refs — a control with a missing env id
# still reports 0 unresolved) nor any offline check proves resolution; only a
# running gateway does. So this reads `channels status --channel slack --probe
# --json` after the restart and demands, for EVERY account in the deployed config:
#   botTokenSource == "config"  AND  probe.ok == true.
# A missing account, non-JSON output or empty input is a FAIL, never a pass.
# Prints only account ids and sources — never token values.
#
# Contract: slack_probe_verdict <openclaw-main.json> <status-json-file>
#   stdout : one "ok:"/"BAD:" line per account, then a final "pass" or "fail"
#   return : 0 = pass, 1 = fail
# ──────────────────────────────────────────────────────────────
slack_probe_verdict() {
  local config="$1" status="$2"
  python3 - "$config" "$status" <<'PYEOF'
import json, sys
cfg_path, status_path = sys.argv[1], sys.argv[2]
try:
    with open(cfg_path) as f:
        expected = sorted(json.load(f)["channels"]["slack"]["accounts"].keys())
except Exception as e:
    print(f"BAD: cannot read slack accounts from {cfg_path}: {type(e).__name__}")
    print("fail"); sys.exit(1)
if not expected:
    print("BAD: config lists no slack accounts — refusing to pass vacuously")
    print("fail"); sys.exit(1)
try:
    with open(status_path) as f:
        doc = json.load(f)
except ValueError as e:
    print(f"BAD: channels status output is not JSON (empty or undecodable: {type(e).__name__})")
    print("fail"); sys.exit(1)
except Exception as e:
    print(f"BAD: channels status output is not the expected JSON ({type(e).__name__})")
    print("fail"); sys.exit(1)
# Parsed JSON with no Slack rows yet (no channelAccounts, no "slack" key, or an
# empty list): the gateway answers before its Slack channel has registered. Seen
# on the 2026-10-20 18:36Z deploy (attempt 5: KeyError) after #1300. Not a
# SecretRef verdict, so slack_probe_run retries it; a real dropped token always
# shows up as a ROW with botTokenSource != "config" and stays final.
accts = doc.get("channelAccounts") if isinstance(doc, dict) else None
slack = accts.get("slack") if isinstance(accts, dict) else None
if slack is None or slack == []:
    why = "no channelAccounts" if not isinstance(accts, dict) else ("empty slack list" if slack == [] else "no slack key")
    print(f"BAD: channels status has no Slack accounts yet ({why})")
    print("fail"); sys.exit(1)
try:
    rows = slack
    got = {r["accountId"]: r for r in rows}
except Exception as e:
    print(f"BAD: channels status output is not the expected JSON ({type(e).__name__})")
    print("fail"); sys.exit(1)
bad = 0
for acct in expected:
    r = got.get(acct)
    if r is None:
        print(f"BAD: {acct}: missing from channels status"); bad += 1; continue
    src = r.get("botTokenSource")
    ok = (r.get("probe") or {}).get("ok")
    if src == "config" and ok is True:
        print(f"ok: {acct}: botTokenSource=config probe.ok=true")
    else:
        print(f"BAD: {acct}: botTokenSource={src} probe.ok={ok}"); bad += 1
print("fail" if bad else "pass")
sys.exit(1 if bad else 0)
PYEOF
}

# slack_probe_run <openclaw-main.json> — runs the live probe (30s cap) into a
# temp file, classifies it, prints the verdict lines. Same return as above.
# A run whose output is empty or not JSON at all (the CLI could not reach a
# gateway that is still in main-session restart recovery: "Opening handshake has
# timed out", an empty answer) is NOT a SecretRef verdict, so it is retried up to
# SLACK_PROBE_ATTEMPTS (default 12; the 18:36Z deploy needed more than 5) times,
# SLACK_PROBE_WAIT_SECS (default 20) apart, and so is parsed JSON that has no
# Slack rows yet (the gateway answers before its Slack channel registers: seen on
# the 18:36Z deploy). Any run that
# returns Slack ROWS is final at once, pass or fail: a dropped botToken
# (botTokenSource != "config"), a failed probe, a malformed row or a missing
# account is never retried away. If no attempt ever returns rows, the last
# verdict stands and the gate fails as before.
# Why: on 2026-10-20 the gate failed both deploys (04:01Z and 14:06Z) and forced
# rollbacks while the gateway was still recovering from the restart; the same
# probe passed on every account minutes later, with nothing changed.
slack_probe_run() {
  local config="$1" tmp rc out attempt
  local attempts="${SLACK_PROBE_ATTEMPTS:-12}" wait_s="${SLACK_PROBE_WAIT_SECS:-20}"
  [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=12
  [[ "$wait_s" =~ ^[0-9]+$ ]] || wait_s=20
  tmp=$(mktemp)
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    : >"$tmp"
    timeout 30 openclaw --profile main channels status --channel slack --probe --json >"$tmp" 2>/dev/null || true
    rc=0
    out=$(slack_probe_verdict "$config" "$tmp") || rc=$?
    if [ "$rc" -eq 0 ] || ! grep -qE '^BAD: channels status (output is not JSON \(empty or undecodable:|has no Slack accounts yet)' <<<"$out"; then
      break
    fi
    if [ "$attempt" -lt "$attempts" ]; then
      echo "slack-probe: attempt $attempt/$attempts got no Slack rows yet (gateway still starting?) — retrying in ${wait_s}s" >&2
      sleep "$wait_s"
    fi
  done
  rm -f "$tmp"
  printf '%s\n' "$out"
  return "$rc"
}
