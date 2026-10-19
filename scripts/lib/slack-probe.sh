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
        rows = json.load(f)["channelAccounts"]["slack"]
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
slack_probe_run() {
  local config="$1" tmp rc
  tmp=$(mktemp)
  timeout 30 openclaw --profile main channels status --channel slack --probe --json >"$tmp" 2>/dev/null || true
  rc=0
  slack_probe_verdict "$config" "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}
