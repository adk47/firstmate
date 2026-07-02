#!/usr/bin/env bats

# Tests for caroline-behavior-digest.py. Same harness as the notifier suites:
# load the module via importlib and monkeypatch its module-level network seam
# (get_conversation / post_slack) so nothing touches a real API. The pure logic
# (classify, capability_records, summarize, detect_anomalies, the wrapper-audit
# extractors, reopen_rate, read_sends, build_digest) is driven directly.
#
# $DIGEST is read inside python heredocs via os.environ['DIGEST'] so the heredocs
# stay single-quoted (no bash interpolation of python braces/dollars).

setup() {
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export DIGEST="$SCRIPTS_DIR/caroline-behavior-digest.py"
  export STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STATE_DIR"
  export CAROLINE_DIGEST_STATE="$STATE_DIR/state.json"
  export CAROLINE_DIGEST_SKIP_HOST_GUARD=1
  export CAROLINE_DIGEST_NOW=1781784000  # 2026-06-18 12:00 UTC
}

_load='import os
from importlib import util
spec = util.spec_from_file_location("d", os.environ["DIGEST"])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
NOW = int(os.environ["CAROLINE_DIGEST_NOW"])
def iso(e): return mod._iso(e)'

@test "syntax-checks" {
  run python3 -m py_compile "$DIGEST"
  [ "$status" -eq 0 ]
}

@test "inline self-test passes" {
  run python3 "$DIGEST" --self-test
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "self-test ok"
}

@test "classify: the full muso-cli decision vocabulary maps correctly" {
  run python3 - <<PYEOF
$_load
assert mod.classify("applied") == "success" and mod.classify("noop") == "success"
assert mod.classify("refused") == "route_to_human"
assert mod.classify("gate_refused") == "backend_refused"
assert mod.classify("dry_run") == "preview" and mod.classify("authorized") == "authorized"
assert mod.classify("brand_new") == "unclassified" and mod.classify(None) == "unclassified"
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "capability_records: keeps only the three self-serve verbs" {
  run python3 - <<PYEOF
$_load
recs = [{"tool":"credits_verify"},{"tool":"profiles_consolidate"},{"tool":"profiles_claim_self"},
        {"tool":"order_lookup"},{"tool":"credit_verification_check"},{"no_tool":1},"junk"]
assert [c["tool"] for c in mod.capability_records(recs)] == \
  ["credits_verify","profiles_consolidate","profiles_claim_self"], mod.capability_records(recs)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "summarize: outcomes, 24h/7d window, preview/test-actor exclusion, reasons" {
  run python3 - <<PYEOF
$_load
recs = [
  {"tool":"credits_verify","decision":"authorized","ts":iso(NOW-1000),"actor_identity":"a@b.com"},
  {"tool":"credits_verify","decision":"applied","ts":iso(NOW-999),"actor_identity":"a@b.com"},
  {"tool":"profiles_claim_self","decision":"refused","ts":iso(NOW-50),"actor_identity":"x@example.com","result":"not the owner"},
  {"tool":"profiles_consolidate","decision":"gate_refused","ts":iso(NOW-40),"actor_identity":"c@d.com","result":"backend said no"},
  {"tool":"profiles_consolidate","decision":"dry_run","ts":iso(NOW-10),"actor_identity":"p@v.com"},
  {"tool":"credits_verify","decision":"applied","ts":iso(NOW-10*86400),"actor_identity":"old@b.com"},
]
caps = mod.capability_records(recs)
s = mod.summarize(caps, NOW, 86400); t = s["totals"]
assert t["success"]==1 and t["route_to_human"]==1 and t["backend_refused"]==1, t
assert t["preview"]==1 and t["authorized"]==1 and s["authorized_without_terminal"]==0, s
assert s["real_actors"]==["a@b.com","c@d.com"], s["real_actors"]   # p@v.com (preview) NOT served
assert s["test_actors"]==["x@example.com"], s["test_actors"]
assert "not the owner" in s["reasons"] and "backend said no" in s["reasons"], s["reasons"]
assert mod.summarize(caps, NOW, 7*86400)["totals"]["success"]==1, "10d-old excluded from 7d"
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "anomaly: a fresh in-flight authorized is graced; only OLD unpaired (>=2) pages" {
  run python3 - <<PYEOF
$_load
# Fresh authorized (within GRACE) whose terminal hasn't landed -> NOT a crash gap.
inflight = mod.summarize(mod.capability_records([
  {"tool":"credits_verify","decision":"authorized","ts":iso(NOW-10),"actor_identity":"a@b.com"}]), NOW, 86400)
assert inflight["authorized_without_terminal"]==0, inflight
assert mod.detect_anomalies(inflight, {}, False, 0, 40)==([],[]), "in-flight must not page"
# Two OLD unpaired authorized -> crash gap -> CRITICAL.
crash = mod.summarize(mod.capability_records([
  {"tool":"credits_verify","decision":"authorized","ts":iso(NOW-600),"actor_identity":"a@b.com"},
  {"tool":"credits_verify","decision":"authorized","ts":iso(NOW-600),"actor_identity":"b@b.com"}]), NOW, 86400)
assert crash["authorized_without_terminal"]==2, crash
crit, warn = mod.detect_anomalies(crash, {}, False, 0, 40)
assert any("authorized" in c for c in crit), crit
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "anomaly: an unrecognized decision value is CRITICAL schema-drift" {
  run python3 - <<PYEOF
$_load
s = mod.summarize(mod.capability_records([
  {"tool":"credits_verify","decision":"weird_new","ts":iso(NOW),"actor_identity":"a@b.com"}]), NOW, 86400)
assert s["totals"]["unclassified"]==1, s
crit, warn = mod.detect_anomalies(s, {}, False, 0, 40)
assert any("schema drift" in c for c in crit), crit
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "anomaly: audited wrapper-side misconfig is CRITICAL" {
  run python3 - <<PYEOF
$_load
empty = mod.summarize([], NOW, 86400)
# Only the statuses the wrappers _audit before exiting (ops_dry_run_set is NOT
# one -- the OPS_DRY_RUN path exits before _audit, so it never lands here).
for st in ("refused_no_approver","refused_no_requester","refused_no_muso"):
    crit, warn = mod.detect_anomalies(empty, {st:2}, False, 0, 40)
    assert any("fail-close" in c for c in crit), (st, crit)
assert "ops_dry_run_set" not in mod.WRAPPER_MISCONFIG, "ops_dry_run_set is never audited; must not be a wrapper-misconfig status"
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "anomaly: OPS_DRY_RUN kill switch is detected from env (CRITICAL), not from a wrapper status" {
  run python3 - <<PYEOF
$_load
empty = mod.summarize([], NOW, 86400)
# detect_anomalies fires on the kill_switch flag (computed from OPS_DRY_RUN env in
# main), NOT on any wrapper-audit record -- because the wrapper never writes one.
crit, warn = mod.detect_anomalies(empty, {}, True, 0, 40)
assert any("OPS_DRY_RUN" in c and "PAUSED" in c for c in crit), crit
assert mod.detect_anomalies(empty, {}, False, 0, 40)==([],[]), "no kill switch => no page"
# misconfig_counts must never surface ops_dry_run_set even if a record carried it.
w=[{"tool":"credits_verify","mode":"apply","status":"ops_dry_run_set","_ts":NOW-10}]
assert mod.misconfig_counts(w)=={}, mod.misconfig_counts(w)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "anomaly: applies above the ceiling is CRITICAL; a clean window pages nothing" {
  run python3 - <<PYEOF
$_load
recs = []
for i in range(45):
    recs.append({"tool":"credits_verify","decision":"authorized","ts":iso(NOW-600-i),"actor_identity":"a%d@b.com"%i})
    recs.append({"tool":"credits_verify","decision":"applied","ts":iso(NOW-599-i),"actor_identity":"a%d@b.com"%i})
s = mod.summarize(mod.capability_records(recs), NOW, 86400)
crit, warn = mod.detect_anomalies(s, {}, False, 0, 40)
assert any("exceeds the ceiling" in c for c in crit), crit
clean = mod.summarize(mod.capability_records([
  {"tool":"credits_verify","decision":"authorized","ts":iso(NOW-600),"actor_identity":"a@b.com"},
  {"tool":"credits_verify","decision":"applied","ts":iso(NOW-599),"actor_identity":"a@b.com"}]), NOW, 86400)
assert mod.detect_anomalies(clean, {}, False, 0, 40)==([],[]), "clean must not page"
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "wrapper extractors: selfserve events (apply+success+conv-id) and misconfig counts" {
  run python3 - <<PYEOF
$_load
w = [
  {"tool":"credits_verify","mode":"apply","status":"verified","intercom_conv_id":"C1","_ts":NOW-100},
  {"tool":"credits_verify","mode":"apply","status":"muso_failed","intercom_conv_id":"C2","_ts":NOW-90},   # not success
  {"tool":"credits_verify","mode":"dry-run","status":"verified","intercom_conv_id":"C3","_ts":NOW-80},     # not apply
  {"tool":"profiles_consolidate","mode":"apply","status":"merged","_ts":NOW-70},                            # no conv-id
  {"tool":"credits_verify","mode":"apply","status":"refused_no_approver","intercom_conv_id":"C5","_ts":NOW-60},  # misconfig
]
assert mod.selfserve_reopen_events(w)==[("C1",NOW-100)], mod.selfserve_reopen_events(w)
assert mod.misconfig_counts(w)=={"refused_no_approver":1}, mod.misconfig_counts(w)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "read_wrapper_audits: window-filters by ts and stamps _ts" {
  run python3 - <<PYEOF
$_load
import os
a = os.path.join(os.environ["STATE_DIR"], "w1.jsonl")
open(a,"w").write(
  '{"tool":"credits_verify","mode":"apply","status":"verified","intercom_conv_id":"C1","ts":"%s"}\n'%iso(NOW-100)+
  '{"tool":"credits_verify","mode":"apply","status":"verified","intercom_conv_id":"OLD","ts":"%s"}\n'%iso(NOW-10*86400))
recs = mod.read_wrapper_audits([a], NOW, 86400)
assert len(recs)==1 and recs[0]["intercom_conv_id"]=="C1" and recs[0]["_ts"]==NOW-100, recs
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "reopen_rate: reply strictly AFTER anchor counts; dedup latest anchor; cap bounds GETs" {
  run python3 - <<PYEOF
$_load
def fake(cid, tok):
    if cid=="R1": return {"conversation_parts":{"conversation_parts":[{"author":{"type":"user"},"created_at":NOW-100}]}}
    if cid=="R2": return {"conversation_parts":{"conversation_parts":[
        {"author":{"type":"user"},"created_at":NOW-900},{"author":{"type":"admin"},"created_at":NOW-50}]}}
    raise AssertionError("OLD must be window-filtered out: "+cid)
mod.get_conversation = fake
ev = [("R1",NOW-500),("R2",NOW-500),("R2",NOW-700),("OLD",NOW-30*86400)]
checked, reopened, errors = mod.reopen_rate(ev, "t", NOW, 7*86400, 300)
assert (checked,reopened,errors)==(2,1,0), (checked,reopened,errors)  # R2 deduped, OLD dropped
calls={"n":0}
def counting(cid,tok):
    calls["n"]+=1; return {"conversation_parts":{"conversation_parts":[]}}
mod.get_conversation = counting
mod.reopen_rate([("C%d"%i, NOW-100) for i in range(50)], "t", NOW, 7*86400, 10)
assert calls["n"]==10, calls["n"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "reopen_rate: a failing Intercom GET is counted as an error, never crashes" {
  run python3 - <<PYEOF
$_load
def boom(cid, tok):
    if cid=="R1": raise RuntimeError("intercom 500")
    return {"conversation_parts":{"conversation_parts":[{"author":{"type":"user"},"created_at":NOW-50}]}}
mod.get_conversation = boom
checked, reopened, errors = mod.reopen_rate([("R1",NOW-500),("R2",NOW-500)], "t", NOW, 7*86400, 300)
assert (checked,reopened,errors)==(1,1,1), (checked,reopened,errors)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "read_sends: parses only 'sent conv=' lines into (conv,ts) (authoritative real sends)" {
  run python3 - <<PYEOF
$_load
import os
p = os.path.join(os.environ["STATE_DIR"], "rn.log")
open(p,"w").write(
  "2026-06-18T10:00:00Z sent conv=C1 ticket=T1 action_type=credit-verify email_sha=abc\n"
  "2026-06-10T10:00:00Z sent conv=C2 ticket=T2 action_type=profile-claim email_sha=def\n"
  "some diagnostic line without the marker\n"
  "resolve-notify: SEEDED 124 currently-resolved verification ticket(s); sent 0 (cold start)\n")
sends = mod.read_sends(p)
assert sends==[("C1", mod.parse_ts("2026-06-18T10:00:00Z")), ("C2", mod.parse_ts("2026-06-10T10:00:00Z"))], sends
recent = [s for s in sends if s[1] >= NOW-7*86400]
assert len(recent)==1, ("only the in-7d send", recent)  # 06-10 is >7d before 06-18
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "build_digest renders empty + populated; all three reopen lines; UVN; WoW delta" {
  run python3 - <<PYEOF
$_load
empty = mod.summarize([], NOW, 86400)
# signature: (s24, s7, s_all, ops, reopen_selfserve, reopen_done, reopen_close, anomalies, prev7, reconcile=None)
t = mod.build_digest(empty, empty, empty, {"closes_7d":0,"notifies_7d":0}, None, None, None, ([],[]), None)
assert "Caroline autonomy" in t and "no real attempts" in t, t
assert "UVN credit verification" in t and "0 approved" in t, t
s = mod.summarize(mod.capability_records([
  {"tool":"credits_verify","decision":"applied","ts":iso(NOW-100),"actor_identity":"a@b.com"},
  {"tool":"profiles_claim_self","decision":"refused","ts":iso(NOW-50),"actor_identity":"y@z.com","result":"not the owner"}]), NOW, 86400)
t2 = mod.build_digest(s, s, s, {"closes_7d":3,"notifies_7d":2},
                      {"checked":4,"reopened":1,"errors":0}, {"checked":2,"reopened":0,"errors":0},
                      {"checked":3,"reopened":0,"errors":0}, ([],[]), {"success":0})
assert "1 done" in t2 and "route-to-human" in t2, t2
assert "3 conversation(s) auto-closed" in t2, ("headline leads with closes", t2)
assert "1 approved" in t2 and "UVN credit verification" in t2, ("UVN line", t2)
assert "Reopen-after-auto-close" in t2 and "Reopen-after-self-serve" in t2 and "Reopen-after-done" in t2, t2
assert "+1 WoW" in t2, ("week-over-week real success", t2)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "build_digest: verb outcomes + UVN exclude smoke/test actors; anomalies still see them" {
  run python3 - <<PYEOF
$_load
# A real applied + a smoke (not-the-owner@) refusal on the SAME verb.
recs = mod.capability_records([
  {"tool":"credits_verify","decision":"applied","ts":iso(NOW-100),"actor_identity":"real@cust.com"},
  {"tool":"credits_verify","decision":"refused","ts":iso(NOW-90),"actor_identity":"not-the-owner@example.com","result":"smoke"}])
s = mod.summarize(recs, NOW, 86400)
# per_verb (all) sees both; per_verb_real sees only the real customer.
assert s["per_verb"]["credits_verify"]["route_to_human"]==1, s["per_verb"]
assert s["per_verb_real"]["credits_verify"]["route_to_human"]==0, s["per_verb_real"]
assert s["per_verb_real"]["credits_verify"]["success"]==1, s["per_verb_real"]
# reasons (full) carries the smoke reason; reasons_real (display) does not.
assert "smoke" in s["reasons"] and "smoke" not in s["reasons_real"], (s["reasons"], s["reasons_real"])
t = mod.build_digest(s, s, s, {"closes_7d":0,"notifies_7d":0}, None, None, None, ([],[]), None)
# UVN shows 1 approved / 0 routed (smoke refusal excluded from the displayed count).
assert "1 approved" in t and "0 routed to a human" in t, ("smoke excluded from UVN display", t)
# the smoke-only refusal must not render a 'why routed/refused' line under a
# header now scoped to real customers.
assert "smoke" not in t and "Why routed/refused" not in t, ("smoke reason hidden from display", t)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "build_digest: 0 notifies despite auto-closes notes the cold-start caveat (no false --apply-off claim)" {
  run python3 - <<PYEOF
$_load
empty = mod.summarize([], NOW, 86400)
t = mod.build_digest(empty, empty, empty, {"closes_7d":12,"notifies_7d":0}, None, None, None, ([],[]), None)
# must explain the benign cold-start cause + the actionable --apply fallback, but
# must NOT assert the notifiers ARE still dry-run (telemetry can't prove that).
assert "cold-start seed" in t and "--apply" in t, ("dormant-notify clarifier", t)
assert "still dry-run" not in t, ("must not over-claim dry-run", t)
# with 0 closes too, it's just 'nothing to notify yet'.
t2 = mod.build_digest(empty, empty, empty, {"closes_7d":0,"notifies_7d":0}, None, None, None, ([],[]), None)
assert "nothing to notify yet" in t2 and "cold-start seed" not in t2, t2
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "build_digest escapes Slack control chars in customer-derived reasons" {
  run python3 - <<PYEOF
$_load
s = mod.summarize(mod.capability_records([
  {"tool":"credits_verify","decision":"refused","ts":iso(NOW-10),"actor_identity":"a@b.com","result":"owner <@U999> & <!channel>"}]), NOW, 86400)
t = mod.build_digest(s, s, s, {"closes_7d":0,"notifies_7d":0}, None, None, None, ([],[]), None)
assert "&lt;@U999&gt;" in t and "&amp;" in t, t
assert "<@U999>" not in t and "<!channel>" not in t, t
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "routed_credit_requests + reconcile_routes: buckets routed credits, fail-soft" {
  run python3 - <<PYEOF
$_load
# routed_credit_requests: only REAL-customer credits_verify routes, deduped by
# request_id, carrying (request_id, profile_id); test actors + non-routed excluded.
w = [
  {"tool":"credits_verify","status":"refused_route_to_human","request_id":"R1","profile_id":"P1","actor_identity":"a@b.com","_ts":NOW-100},
  {"tool":"credits_verify","status":"refused_route_to_human","request_id":"R2","profile_id":"P1","actor_identity":"a@b.com","_ts":NOW-90},
  {"tool":"credits_verify","status":"refused_route_to_human","request_id":"R3","profile_id":"P2","actor_identity":"not-the-owner@x.com","_ts":NOW-80},  # test actor
  {"tool":"credits_verify","status":"verified","request_id":"R4","profile_id":"P3","actor_identity":"c@d.com","_ts":NOW-70},                            # not routed
  {"tool":"credits_verify","status":"refused_route_to_human","request_id":"R5","profile_id":"P4","actor_identity":"e@f.com","_ts":NOW-60},              # routed...
  {"tool":"credits_verify","mode":"apply","status":"verified","request_id":"R5","profile_id":"P4","actor_identity":"e@f.com","_ts":NOW-50},             # ...retried OK -> autonomy, not a hand-off
]
assert sorted(mod.routed_credit_requests(w))==[("R1","P1"),("R2","P1")], mod.routed_credit_requests(w)
# reconcile_routes: monkeypatch the read seam (NEVER a subprocess). R1 approved,
# R2 still UVN; a raising lookup -> error (no crash); over-cap profiles -> errors.
def fake(pid, status, wrapper):
    if pid=="P1" and status=="approved": return {"R1"}
    if pid=="P1" and status=="user_verification_needed": return {"R2"}
    raise RuntimeError("boom")
mod.credit_request_ids = fake
assert mod.reconcile_routes([("R1","P1"),("R2","P1")], "x", 60)=={"checked":2,"approved":1,"pending":1,"other":0,"errors":0}
assert mod.reconcile_routes([("RX","PBAD")], "x", 60)["errors"]==1, "raising lookup -> error, not crash"
cap = mod.reconcile_routes([("R1","P1"),("RY","PY")], "x", 1)
assert cap["checked"]==1 and cap["errors"]>=1, ("over-cap profiles surface as errors", cap)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "build_digest: route-reconciliation line renders recoverable framing; None -> not checked" {
  run python3 - <<PYEOF
$_load
s = mod.summarize(mod.capability_records([
  {"tool":"credits_verify","decision":"refused","ts":iso(NOW-30),"actor_identity":"real@cust.com","result":"no corroboration"}]), NOW, 86400)
assert s["per_verb_real"]["credits_verify"]["route_to_human"]==1, s
# with a reconcile dict: the recoverable / pending / withdrawn disposition renders.
t = mod.build_digest(s, s, s, {"closes_7d":1,"notifies_7d":1}, None, None, None, ([],[]), None,
                     reconcile={"checked":3,"approved":1,"pending":1,"other":1,"errors":0})
assert "1 later approved by a human" in t and "recoverable" in t, t
assert "1 still pending review" in t and "1 withdrawn/reverted" in t, t
# routes present but reconcile None -> explicit 'not checked', never silently dropped.
t2 = mod.build_digest(s, s, s, {"closes_7d":1,"notifies_7d":1}, None, None, None, ([],[]), None)
assert "disposition not checked" in t2, t2
# no routes at all -> no reconciliation line rendered.
empty = mod.summarize([], NOW, 86400)
t3 = mod.build_digest(empty, empty, empty, {"closes_7d":0,"notifies_7d":0}, None, None, None, ([],[]), None,
                      reconcile={"checked":0,"approved":0,"pending":0,"other":0,"errors":0})
assert "Of the credits routed to a human" not in t3, t3
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "--check makes NO network call and writes NO state; JSON shape is stable" {
  audit="$STATE_DIR/audit.jsonl"
  printf '%s\n' '{"tool":"credits_verify","decision":"applied","ts":"2026-06-18T11:00:00Z","actor_identity":"a@b.com"}' > "$audit"
  run env CAROLINE_DIGEST_SKIP_HOST_GUARD=1 CAROLINE_DIGEST_NOW=1781784000 \
    CAROLINE_DIGEST_AUDIT="$audit" CAROLINE_DIGEST_STATE="$CAROLINE_DIGEST_STATE" \
    CAROLINE_DIGEST_WRAPPER_LOGS=/dev/null CLOSE_RESOLVED_SHADOW=/dev/null \
    RESOLVE_NOTIFY_LOG=/dev/null OVERDUE_NOTIFY_LOG=/dev/null \
    python3 "$DIGEST"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert d['s24_totals']['success']==1, d; assert d['reopen_selfserve'] is None and d['reopen_done'] is None, d; assert d['misconfig24']=={}, d; print('ok')"
  [ ! -f "$CAROLINE_DIGEST_STATE" ]
}

@test "ops-relief: counts auto-closes via the shadow log's closed_at field (not ts)" {
  shadow="$STATE_DIR/shadow.jsonl"; audit="$STATE_DIR/a.jsonl"; : > "$audit"
  printf '%s\n' '{"id":"c1","closed_at":1781700000,"email":"a@b.com","new_state":"closed"}' >> "$shadow"  # within 7d of NOW
  printf '%s\n' '{"id":"c2","closed_at":1781000000,"email":"x@y.com","new_state":"closed"}' >> "$shadow"  # >7d old
  run env CAROLINE_DIGEST_SKIP_HOST_GUARD=1 CAROLINE_DIGEST_NOW=1781784000 \
    CAROLINE_DIGEST_AUDIT="$audit" CLOSE_RESOLVED_SHADOW="$shadow" CAROLINE_DIGEST_WRAPPER_LOGS=/dev/null \
    RESOLVE_NOTIFY_LOG=/dev/null OVERDUE_NOTIFY_LOG=/dev/null \
    python3 "$DIGEST"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert d['ops']['closes_7d']==1, d; print('ok')"
}

@test "malformed audit lines are tolerated and counted (warns only at >=5)" {
  run python3 - <<PYEOF
$_load
import os
p = os.path.join(os.environ["STATE_DIR"], "torn.jsonl")
open(p,"w").write('{"tool":"credits_verify","decision":"applied","ts":"%s","actor_identity":"a@b.com"}\n{ not json\n'%iso(NOW-10))
recs, malformed = mod.read_jsonl(p)
assert len(recs)==1 and malformed==1, (len(recs), malformed)
crit, warn = mod.detect_anomalies(mod.summarize(mod.capability_records(recs), NOW, 86400), {}, False, malformed, 40)
assert warn==[], ("1 malformed must not warn (<5)", warn)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "OPS_DRY_RUN=1 in the digest's env surfaces a CRITICAL kill-switch anomaly (--check)" {
  audit="$STATE_DIR/audit.jsonl"; : > "$audit"
  run env CAROLINE_DIGEST_SKIP_HOST_GUARD=1 CAROLINE_DIGEST_NOW=1781784000 OPS_DRY_RUN=1 \
    CAROLINE_DIGEST_AUDIT="$audit" CAROLINE_DIGEST_WRAPPER_LOGS=/dev/null \
    CLOSE_RESOLVED_SHADOW=/dev/null RESOLVE_NOTIFY_LOG=/dev/null OVERDUE_NOTIFY_LOG=/dev/null \
    python3 "$DIGEST"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert d['kill_switch'] is True, d; assert any('OPS_DRY_RUN' in c for c in d['critical']), d; print('ok')"
  # And NOT flagged when unset (-u clears any inherited OPS_DRY_RUN on the runner).
  run env -u OPS_DRY_RUN CAROLINE_DIGEST_SKIP_HOST_GUARD=1 CAROLINE_DIGEST_NOW=1781784000 \
    CAROLINE_DIGEST_AUDIT="$audit" CAROLINE_DIGEST_WRAPPER_LOGS=/dev/null \
    CLOSE_RESOLVED_SHADOW=/dev/null RESOLVE_NOTIFY_LOG=/dev/null OVERDUE_NOTIFY_LOG=/dev/null \
    python3 "$DIGEST"
  echo "$output" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert d['kill_switch'] is False and d['critical']==[], d; print('ok')"
}

@test "reopen-after-done uses resolve-notify sends ONLY; ops-relief counts both notifiers" {
  run python3 - <<PYEOF
$_load
import sys, io, json, contextlib
# resolve-notify sent to R1; overdue-notifier sent to O1. Reopen-after-done must
# query R1 only (overdue's 'still working' nudge is not a 'done' note); notifies
# total must count BOTH.
rl = os.path.join(os.environ["STATE_DIR"], "resolve.log")
ol = os.path.join(os.environ["STATE_DIR"], "overdue.log")
open(rl,"w").write("%s sent conv=R1 ticket=T1 action_type=credit-verify email_sha=a\n" % iso(NOW-100))
open(ol,"w").write("%s sent conv=O1 ticket=T2 action_type=profile-claim email_sha=b\n" % iso(NOW-100))
seen = []
def fake_get(cid, tok):
    seen.append(cid)
    return {"conversation_parts":{"conversation_parts":[{"author":{"type":"user"},"created_at":NOW-10}]}}
mod.get_conversation = fake_get
mod.post_slack = lambda *a, **k: True
os.environ.update({"CAROLINE_DIGEST_AUDIT":"/dev/null","CAROLINE_DIGEST_WRAPPER_LOGS":"/dev/null",
  "CLOSE_RESOLVED_SHADOW":"/dev/null","RESOLVE_NOTIFY_LOG":rl,"OVERDUE_NOTIFY_LOG":ol,
  "MUSOAI_INTERCOM_TOKEN":"t","CAROLINE_DIGEST_SKIP_HOST_GUARD":"1"})
sys.argv = ["d","--post"]
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = mod.main()
assert rc == 0, rc
assert seen == ["R1"], ("reopen-after-done must query resolve sends only", seen)
summary = json.loads(buf.getvalue().strip().splitlines()[-1])
assert summary["ops"]["notifies_7d"] == 2, ("ops-relief counts both notifiers", summary["ops"])
assert summary["reopen_done"]["checked"] == 1, summary["reopen_done"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "reopen-after-auto-close queries the close-resolved shadow conv-ids (--post)" {
  run python3 - <<PYEOF
$_load
import sys, io, json, contextlib
sh = os.path.join(os.environ["STATE_DIR"], "shadow.jsonl")
open(sh,"w").write(
  '{"id":"K1","closed_at":%d,"email":"a@b.com","new_state":"closed"}\n' % (NOW-100) +
  '{"id":"K2","closed_at":%d,"email":"c@d.com","new_state":"closed"}\n' % (NOW-200) +
  '{"id":"OLD","closed_at":%d,"email":"e@f.com","new_state":"closed"}\n' % (NOW-30*86400))
seen=[]
def fake_get(cid, tok):
    seen.append(cid)
    # K1: customer replied after we closed (reopened); K2: only admin -> not reopened.
    if cid=="K1": return {"conversation_parts":{"conversation_parts":[{"author":{"type":"user"},"created_at":NOW-10}]}}
    return {"conversation_parts":{"conversation_parts":[{"author":{"type":"admin"},"created_at":NOW-10}]}}
mod.get_conversation = fake_get
mod.post_slack = lambda *a, **k: True
os.environ.update({"CAROLINE_DIGEST_AUDIT":"/dev/null","CAROLINE_DIGEST_WRAPPER_LOGS":"/dev/null",
  "CLOSE_RESOLVED_SHADOW":sh,"RESOLVE_NOTIFY_LOG":"/dev/null","OVERDUE_NOTIFY_LOG":"/dev/null",
  "MUSOAI_INTERCOM_TOKEN":"t","CAROLINE_DIGEST_SKIP_HOST_GUARD":"1"})
sys.argv = ["d","--post"]
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = mod.main()
assert rc == 0, rc
assert sorted(seen)==["K1","K2"], ("OLD is >7d -> window-filtered out", seen)
summary = json.loads(buf.getvalue().strip().splitlines()[-1])
assert summary["reopen_close"]["checked"]==2 and summary["reopen_close"]["reopened"]==1, summary["reopen_close"]
assert summary["ops"]["closes_7d"]==2, summary["ops"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "host guard: refuses (returns 0, no network) when not on ovh-node-8" {
  # Hermetic: CI bats run ON ovh-node-8, so monkeypatch the hostname check
  # in-process rather than relying on the runner's hostname (and so this can
  # never reach a real Slack post on the live host). Prove main() refuses
  # (returns 0) BEFORE any Slack/Intercom call.
  run python3 - <<PYEOF
$_load
import sys
mod.socket.gethostname = lambda: "some-other-host"
def boom(*a, **k): raise AssertionError("must not reach the network when host-guarded")
mod.post_slack = boom
mod.get_conversation = boom
os.environ.pop("CAROLINE_DIGEST_SKIP_HOST_GUARD", None)
sys.argv = ["d", "--post"]
rc = mod.main()
assert rc == 0, rc
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}
