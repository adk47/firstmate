#!/usr/bin/env bats
# credit_verify/zero_read.py: the after-the-tick zero-read. Fixtures stand in for the four durable sources
# (ClickHouse email_events, Loki notify-gateway, Loki core, replica) and the ledger; the tests pin the verdicts
# OK / STOP / UNMEASURED, the exit codes the outbound tick fails closed on, and the credit-class rule.

setup() {
  TMP="$(mktemp -d)"
  export ZR_FIXTURE_DIR="$TMP/fx" ZR_LEDGER="$TMP/ledger.sqlite3" OUT="$TMP/out"
  mkdir -p "$ZR_FIXTURE_DIR"
  python3 - "$ZR_LEDGER" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("create table verify_messages (id integer, account_id text, status text, campaign text, sent_at text, created_at text)")
db.executemany("insert into verify_messages values (?,?,?,?,?,?)", [
    (101, "11", "sent", "uvn-status", "2026-10-30T14:40:00Z", "2026-10-30T14:40:00Z"),
    (102, "12", "sent", "uvn-status", "2026-10-30T14:41:00Z", "2026-10-30T14:41:00Z"),
    (103, "13", "rejected", "uvn-status", None, "2026-10-30T14:42:00Z"),
])
db.commit()
PY
  ZR="$BATS_TEST_DIRNAME/../credit_verify/zero_read.py"
  clean_sources
}

teardown() { rm -rf "$TMP"; }

clean_sources() {
  echo '{"state":"measured","control":1076,"events":[]}' > "$ZR_FIXTURE_DIR/email.json"
  echo '{"state":"measured","control":31396,"kinds":{"GET /internal/v1/users/N/route":61},"unexpected":[]}' > "$ZR_FIXTURE_DIR/bell.json"
  echo '{"state":"measured","control":786,"events":[]}' > "$ZR_FIXTURE_DIR/core.json"
  echo '{"state":"measured","rows":[]}' > "$ZR_FIXTURE_DIR/replica.json"
}

run_zr() { run python3 "$ZR" --ledger-ids 101-103 --start 2026-10-30T14:35:00Z --end 2026-10-30T17:15:00Z --out "$OUT"; }

@test "OK: nothing reached the batch users (exit 0), only the sent rows are checked, a JSON report is written" {
  run_zr
  [ "$status" -eq 0 ]
  [[ "$output" == OK:\ 2\ users* ]]
  ls "$OUT"/zero-read-101-103-*.json
  python3 -c "import json,glob; r=json.load(open(glob.glob('$OUT/*.json')[0])); assert r['verdict']=='OK' and r['users']==2"
}

@test "STOP: a credit-class email to a batch user (exit 1)" {
  echo '{"state":"measured","control":1076,"events":[{"user_id":"11","template_key":"credits_more_info_needed","event_type":"sent"}]}' > "$ZR_FIXTURE_DIR/email.json"
  run_zr
  [ "$status" -eq 1 ]
  [[ "$output" == STOP:* ]]
  [[ "$output" == *"email credits_more_info_needed -> 11"* ]]
}

@test "STOP: a credit-class core event for a batch user (exit 1)" {
  # QA #1545: the report names the FORMAT too (trackEvent vs notification) - an executeNotificationProcedure line is
  # a message that reached the user, and a reader of the STOP line should be able to see which kind it was
  echo '{"state":"measured","control":786,"events":[{"user":"12","event":"backend_profile_credit_requests_info_needed","kind":"trackEvent","t":"x"}]}' > "$ZR_FIXTURE_DIR/core.json"
  run_zr
  [ "$status" -eq 1 ]
  [[ "$output" == *"core trackEvent backend_profile_credit_requests_info_needed -> 12"* ]]
}

@test "STOP: a notify-gateway request that is not read-only (exit 1)" {
  echo '{"state":"measured","control":100,"kinds":{},"unexpected":[{"t":"x","req":"POST /v1/integrations/receive","line":"..."}]}' > "$ZR_FIXTURE_DIR/bell.json"
  run_zr
  [ "$status" -eq 1 ]
}

@test "OK: a non-credit email (payment receipt) is reported, never fatal (p1 ruling)" {
  echo '{"state":"measured","control":437,"events":[{"user_id":"11","template_key":"send_payment_email","event_type":"sent"}]}' > "$ZR_FIXTURE_DIR/email.json"
  echo '{"state":"measured","control":441,"events":[{"user":"11","event":"backend_user_subscription_payment_email_requested","t":"x"}]}' > "$ZR_FIXTURE_DIR/core.json"
  run_zr
  [ "$status" -eq 0 ]
  [[ "$output" == *"send_payment_email -> 11 (not credit-class)"* ]]
}

@test "OK (ruling A): an approval notice is explained when it NAMES the request that was approved in the window" {
  # the core line carries the credit_requests UUID it is about (MEASURED on prod: executeNotificationProcedure credit
  # lines carry it under "id"), and that request was approved at 15:37:06, before the notice at 15:37:10
  echo '{"state":"measured","control":786,"events":[{"user":"12","event":"backend_profile_credit_requests_approved","kind":"trackEvent","t":"2026-10-30T15:37:10+00:00","ids":["0d5d9727-2f43-49cc-a98d-be3057253391"]}]}' > "$ZR_FIXTURE_DIR/core.json"
  echo '{"state":"measured","rows":[{"user":"12","id":"0d5d9727-2f43-49cc-a98d-be3057253391","status":"approved","created":"2026-10-30 15:36:51.789000 UTC","updated":"2026-10-30 15:37:06.936000 UTC","approvalVia":"validator"}]}' > "$ZR_FIXTURE_DIR/replica.json"
  run_zr
  [ "$status" -eq 0 ]
  [[ "$output" == *"the request it NAMES was approved in the window"* ]]
}

@test "APPROVER (QA #1545 round 13): only the VALIDATOR's approval explains a notice - an admin approval of the same request stays UNMEASURED" {
  # the same fixture as the exempt case, with `approvalVia` flipped: the exemption means "the validator decided this
  # while we were looking". An `admin` (or ops) approval is a human action on the row, reported - never an excuse.
  # prod census (120 d, status=approved): none 302302 | validator 36143 | admin 679 | ops_label_pline 24.
  echo '{"state":"measured","control":786,"events":[{"user":"12","event":"backend_profile_credit_requests_approved","kind":"trackEvent","t":"2026-10-30T15:37:10+00:00","ids":["0d5d9727-2f43-49cc-a98d-be3057253391"]}]}' > "$ZR_FIXTURE_DIR/core.json"
  echo '{"state":"measured","rows":[{"user":"12","id":"0d5d9727-2f43-49cc-a98d-be3057253391","status":"approved","created":"2026-10-30 15:36:51.789000 UTC","updated":"2026-10-30 15:37:06.936000 UTC","approvalVia":"admin"}]}' > "$ZR_FIXTURE_DIR/replica.json"
  run_zr
  [ "$status" -eq 2 ]
  [[ "$output" == UNMEASURED:* ]]
  python3 - "$OUT" <<'PY'
import glob, json, sys
rep = json.load(open(sorted(glob.glob(sys.argv[1] + "/zero-read-*.json"))[-1]))
assert any("approved by admin, not by the validator" in x for x in rep["reported"]), rep["reported"]
assert rep["stops"] == [], rep["stops"]
PY
  # and the validator value still exempts the exact same row
  echo '{"state":"measured","rows":[{"user":"12","id":"0d5d9727-2f43-49cc-a98d-be3057253391","status":"approved","created":"2026-10-30 15:36:51.789000 UTC","updated":"2026-10-30 15:37:06.936000 UTC","approvalVia":"validator"}]}' > "$ZR_FIXTURE_DIR/replica.json"
  run_zr
  [ "$status" -eq 0 ]
  [[ "$output" == *"the request it NAMES was approved in the window"* ]]
}

@test "UNMEASURED (ruling A - the exact QA case): a notice NAMING an OLD request is NOT excused by a DIFFERENT request that user had approved in the window" {
  # QA's finding: an old request's credits_accepted arrives at 15:37; a DIFFERENT request of the same user was approved
  # at 15:30 in this window. Under the prohibited (user, window) rule the notice was exempted; it may not be.
  echo '{"state":"measured","control":786,"events":[{"user":"12","event":"backend_profile_credit_requests_approved","kind":"trackEvent","t":"2026-10-30T15:37:10+00:00","ids":["11111111-1111-4111-8111-111111111111"]}]}' > "$ZR_FIXTURE_DIR/core.json"
  echo '{"state":"measured","rows":[{"user":"12","id":"22222222-2222-4222-8222-222222222222","status":"approved","created":"2026-10-30 15:29:00.000000 UTC","updated":"2026-10-30 15:30:00.000000 UTC","approvalVia":"validator"}]}' > "$ZR_FIXTURE_DIR/replica.json"
  run_zr
  [ "$status" -eq 2 ]
  [[ "$output" == UNMEASURED:* ]]
  [[ "$output" == *"no in-window approval it names"* ]]
}

@test "UNMEASURED (ruling A): a credits_accepted EMAIL names no request id at all - MEASURED: messaging.email_events has no id column - so it fails closed, never exempt" {
  echo '{"state":"measured","control":1076,"events":[{"user_id":"12","template_key":"credits_accepted","event_type":"sent","event_time":"2026-10-30 15:37:10.000","detail":{"gate":"live","attempts":1}}]}' > "$ZR_FIXTURE_DIR/email.json"
  echo '{"state":"measured","rows":[{"user":"12","id":"r1","status":"approved","created":"2026-10-30 15:36:51.789000 UTC","updated":"2026-10-30 15:37:06.936000 UTC","approvalVia":"validator"}]}' > "$ZR_FIXTURE_DIR/replica.json"
  run_zr
  [ "$status" -eq 2 ]
  [[ "$output" == UNMEASURED:* ]]
}

@test "CORRELATION (QA #1545 finding 8 critical): two notices at ONE nanosecond are two notices, and exempt() excuses only the one naming an approved request" {
  local py="$BATS_TEST_DIRNAME/../credit_verify/zero_read.py"
  # QA reproduced this at c28348b: `seen` was keyed on (user, kind, event, t), so two DIFFERENT notices sharing a Loki
  # nanosecond merged into one event carrying BOTH ids - the old notice inherited the newly approved request's id and
  # exempt() excused it. Driving core() with raw lines (not fixtures) is what exercises the aggregation.
  run -0 python3 - "$py" <<'PY'
import datetime as dt, importlib.util, os, sys
os.environ.pop("ZR_FIXTURE_DIR", None)                       # core() must PARSE these lines, not read a fixture
spec = importlib.util.spec_from_file_location("zr", sys.argv[1]); z = importlib.util.module_from_spec(spec); spec.loader.exec_module(z)
OLD = "11111111-1111-4111-8111-111111111111"; NEW = "22222222-2222-4222-8222-222222222222"
# ONE nanosecond for both notices, and the instant the approval fixture names (15:30Z) precedes it
T = int(dt.datetime(2026, 10, 30, 15, 37, 10, tzinfo=dt.timezone.utc).timestamp()) * 10**9
def line(rid):
    return ('{"msg":"executeNotificationProcedure","userId":"12","template":"credits_accepted",'
            '"templateKey":"credits_accepted","id":"%s"}' % rid)
class SameT:
    def query(self, *a, **k): return [(T, line(OLD)), (T, line(NEW))]
    def count(self, *a, **k): return 786
r = z.core(SameT(), ["12"], None, None)
assert r["state"] == "measured", r
assert len(r["events"]) == 2, r["events"]                      # two notices at one nanosecond are STILL two notices
assert sorted(tuple(e["ids"]) for e in r["events"]) == [(OLD,), (NEW,)], r["events"]
old_ev = [e for e in r["events"] if e["ids"] == [OLD]][0]
new_ev = [e for e in r["events"] if e["ids"] == [NEW]][0]
# the verdict consequence: only NEW was approved in the window, at 15:30Z, before both notices
approved = {("12", NEW): dt.datetime(2026, 10, 30, 15, 30, tzinfo=dt.timezone.utc)}
assert z.exempt_with(approved, "12", new_ev["t"], new_ev["ids"]) is True
# THE REGRESSION: the old notice names no approval, so it is never excused. With the ids merged onto one record this
# line is True - and the whole window reads OK off a request the notice never mentioned.
assert z.exempt_with(approved, "12", old_ev["t"], old_ev["ids"]) is False, old_ev
print("same-nanosecond ok")
PY
  [[ "$output" == *"same-nanosecond ok"* ]]
}

@test "SELECTOR (QA #1545 finding 9): core's userId matcher tolerates JSON whitespace, so a spaced notification is FETCHED instead of silently missed" {
  local py="$BATS_TEST_DIRNAME/../credit_verify/zero_read.py"
  run python3 - "$py" <<'PY'
import datetime as dt, importlib.util, re, sys
spec = importlib.util.spec_from_file_location("zr", sys.argv[1]); z = importlib.util.module_from_spec(spec); spec.loader.exec_module(z)
start = dt.datetime(2026, 10, 30, 15, 0, tzinfo=dt.timezone.utc)
end = dt.datetime(2026, 10, 30, 16, 0, tzinfo=dt.timezone.utc)
TEMPLATE = "credits_more_info_needed"
class Ws:
    """A Loki that applies the selector's LAST matcher, exactly as Loki would."""
    def __init__(self, line): self.line, self.q = line, []
    def query(self, logql, s, e):
        self.q.append(logql)
        m = re.search(r'`([^`]*)`\s*$', logql)
        pat = m.group(1) if m else logql.rsplit('|~', 1)[1].strip().strip('"')
        return [(int(start.timestamp() * 1e9), self.line)] if re.search(pat, self.line) else []
    def count(self, logql, s, e): return 1
z.FIXTURES = None                        # the suite exports ZR_FIXTURE_DIR; core() must query, not read fixtures
for label, line in (
        ("spaced", '{"msg":"executeNotificationProcedure","userId": "12","template":"%s"}' % TEMPLATE),
        ("tight", '{"msg":"executeNotificationProcedure","userId":"12","template":"%s"}' % TEMPLATE),
        ("spaced both", '{"msg": "executeNotificationProcedure", "userId" : "12", "template": "%s"}' % TEMPLATE)):
    w = Ws(line)
    r = z.core(w, ["12"], start, end)
    assert r["state"] == "measured", (label, r)
    assert [e["event"] for e in r["events"]] == [TEMPLATE], (label, r["events"])
    # a DIFFERENT user must not match, whitespace or not
    w2 = Ws(line.replace('"12"', '"13"'))
    assert z.core(w2, ["12"], start, end)["events"] == [], label
print("whitespace ok")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"whitespace ok"* ]]
}

@test "SELECTOR (QA #1545 round 10): core fetches a NUMERIC json userId too, and does not drag a longer id's user in with it" {
  local py="$BATS_TEST_DIRNAME/../credit_verify/zero_read.py"
  run python3 - "$py" <<'PY'
import datetime as dt, importlib.util, re, sys
spec = importlib.util.spec_from_file_location("zr", sys.argv[1]); z = importlib.util.module_from_spec(spec); spec.loader.exec_module(z)
start = dt.datetime(2026, 10, 30, 15, 0, tzinfo=dt.timezone.utc)
end = dt.datetime(2026, 10, 30, 16, 0, tzinfo=dt.timezone.utc)
TEMPLATE = "credits_more_info_needed"
class Ws:
    """A Loki that applies the selector's LAST matcher, exactly as Loki would."""
    def __init__(self, line): self.line, self.q = line, []
    def query(self, logql, s, e):
        self.q.append(logql)
        m = re.search(r'`([^`]*)`\s*$', logql)
        pat = m.group(1) if m else logql.rsplit('|~', 1)[1].strip().strip('"')
        return [(int(start.timestamp() * 1e9), self.line)] if re.search(pat, self.line) else []
    def count(self, logql, s, e): return 1
z.FIXTURES = None
# parse_core_line has always accepted the NUMERIC form; the selector required quotes, so it was never fetched
for label, line in (
        ("numeric", '{"msg":"executeNotificationProcedure","userId":12,"template":"%s"}' % TEMPLATE),
        ("numeric spaced", '{"msg":"executeNotificationProcedure","userId": 12 ,"template":"%s"}' % TEMPLATE),
        ("numeric last", '{"msg":"executeNotificationProcedure","template":"%s","userId":12}' % TEMPLATE)):
    r = z.core(Ws(line), ["12"], start, end)
    assert r["state"] == "measured", (label, r)
    assert [e["event"] for e in r["events"]] == [TEMPLATE], (label, r["events"])
# the other direction: user 12's selector must not capture user 123's line (a foreign STOP)
assert z.core(Ws('{"msg":"executeNotificationProcedure","userId":123,"template":"%s"}' % TEMPLATE),
              ["12"], start, end)["events"] == []
assert z.core(Ws('{"msg":"executeNotificationProcedure","userId":"123","template":"%s"}' % TEMPLATE),
              ["12"], start, end)["events"] == []
print("numeric ok")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"numeric ok"* ]]
}

@test "COHORT (QA #1545 round 10): a core line for a user OUTSIDE this batch's cohort is reported, never a STOP for the whole run" {
  # the reader's subject is this batch. A foreign user's credit notice reaching the verdict must not kill the run.
  echo '{"state":"measured","control":786,"events":[{"user":"99","event":"credits_more_info_needed","kind":"notification","t":"2026-10-30T15:37:10+00:00","ids":[]}]}' > "$ZR_FIXTURE_DIR/core.json"
  echo '{"state":"measured","control":1076,"events":[]}' > "$ZR_FIXTURE_DIR/email.json"
  echo '{"state":"measured","control":0,"events":[]}' > "$ZR_FIXTURE_DIR/bell.json"
  echo '{"state":"measured","rows":[]}' > "$ZR_FIXTURE_DIR/replica.json"
  run_zr
  [ "$status" -eq 0 ]
  [[ "$output" == OK:* ]]
  python3 - "$OUT" <<'PY'
import glob, json, sys
rep = json.load(open(sorted(glob.glob(sys.argv[1] + "/zero-read-*.json"))[-1]))
assert any("not in this batch's cohort" in x for x in rep["reported"]), rep["reported"]
assert rep["stops"] == [], rep["stops"]
PY
}

@test "CONTROL (QA #1545 round 11): a ZERO email positive control is UNMEASURED - an ingest gap must not read as 'measured, no events'" {
  local py="$BATS_TEST_DIRNAME/../credit_verify/zero_read.py"
  run python3 - "$py" <<'PY'
import datetime as dt, importlib.util, json, subprocess, sys
spec = importlib.util.spec_from_file_location("zr", sys.argv[1]); z = importlib.util.module_from_spec(spec); spec.loader.exec_module(z)
z.FIXTURES = None
start = dt.datetime(2026, 10, 30, 15, 0, tzinfo=dt.timezone.utc)
end = dt.datetime(2026, 10, 30, 16, 0, tzinfo=dt.timezone.utc)
def stub(rows, control):
    # email_events() -> one kubectl/node call that prints [rows_JSONEachRow, control_JSON]
    out = json.dumps(["\n".join(rows), json.dumps({"n": control})])
    z.kubectl = lambda *a, **k: subprocess.CompletedProcess(["kubectl"], 0, out, "")
# bell() and core() already failed closed on a zero control; email did not, so a ClickHouse ingest gap read
# "measured, no events" and the run exited OK - the one source that can see an approval notice.
stub([], 0)
r = z.email_events(["11"], start, end)
assert r["state"] == "unmeasured", r
assert "ingest gap" in r["error"], r
# and the guard does not swallow real data: a nonzero control keeps the rows
row = json.dumps({"user_id": "11", "template_key": "credits_more_info_needed", "class": "", "event_type": "sent",
                  "event_time": "2026-10-30 15:30:00.000"})
stub([row], 273)
r2 = z.email_events(["11"], start, end)
assert r2["state"] == "measured" and r2["control"] == 273, r2
assert [e["template_key"] for e in r2["events"]] == ["credits_more_info_needed"], r2
print("email control ok")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"email control ok"* ]]
}

@test "UNMEASURED (ruling A): a NAMED request created after the window, and a notice BEFORE its approval, are not explanations" {
  # named request created 18:00Z, i.e. after --end 17:15Z: it cannot explain a notice at 15:37Z
  echo '{"state":"measured","control":786,"events":[{"user":"12","event":"backend_profile_credit_requests_approved","kind":"trackEvent","t":"2026-10-30T15:37:10+00:00","ids":["33333333-3333-4333-8333-333333333333"]}]}' > "$ZR_FIXTURE_DIR/core.json"
  echo '{"state":"measured","rows":[{"user":"12","id":"33333333-3333-4333-8333-333333333333","status":"approved","created":"2026-10-30 18:00:00.000000 UTC","updated":"2026-10-30 18:00:05.000000 UTC","approvalVia":"validator"}]}' > "$ZR_FIXTURE_DIR/replica.json"
  run_zr
  [ "$status" -eq 2 ]
  [[ "$output" == *"approved request 33333333-3333-4333-8333-333333333333 of 12 created 2026-10-30 18:00:00.000000 UTC (outside the window)"* ]]
  # named request created in the window but approved AFTER the notice: the evidence has to line up in time
  echo '{"state":"measured","rows":[{"user":"12","id":"33333333-3333-4333-8333-333333333333","status":"approved","created":"2026-10-30 15:36:51.789000 UTC","updated":"2026-10-30 16:00:00.000000 UTC","approvalVia":"validator"}]}' > "$ZR_FIXTURE_DIR/replica.json"
  run_zr
  [ "$status" -eq 2 ]
  # and an event whose own time cannot be read is never excused
  echo '{"state":"measured","control":786,"events":[{"user":"12","event":"backend_profile_credit_requests_approved","kind":"trackEvent","t":"x","ids":["33333333-3333-4333-8333-333333333333"]}]}' > "$ZR_FIXTURE_DIR/core.json"
  run_zr
  [ "$status" -eq 2 ]
}

@test "PARSE (QA #1545 findings 1+2): BOTH core log formats classify, a notify-gateway line is read in any key order, and an unreadable line is UNMEASURED - never OK" {
  local py="$BATS_TEST_DIRNAME/../credit_verify/zero_read.py"
  # finding 1 (CRITICAL): executeNotificationProcedure was selected but parsed with a trackEvent regex, so a credit
  # NOTIFICATION read as event=None -> "not credit-class" -> OK. It is a credit-class STOP now.
  run python3 - "$py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("zr", sys.argv[1]); z = importlib.util.module_from_spec(spec); spec.loader.exec_module(z)
line = ('2026-11-03T00:00:00Z {"level":30,"msg":"executeNotificationProcedure","userId":"11",'
        '"template":"credits_more_info_needed","templateKey":"credits_more_info_needed"}')
kind, user, event = z.parse_core_line(line)
assert (kind, user, event) == ("notification", "11", "credits_more_info_needed"), (kind, user, event)
assert z.CREDIT_EVENT_RE.search(event)                       # credit-class: this is a STOP, not "other"
# a trackEvent line still parses exactly as before
assert z.parse_core_line('x trackEvent: {"event":"credits_accepted"} userId: "11"')[:1] == ("trackEvent",)
assert z.parse_core_line('x trackEvent: {"event":"payment"} ')[2] == "payment"
# a notification with no readable template is UNCLASSIFIED (fails the run closed), never silently "other"
assert z.parse_core_line('{"msg":"executeNotificationProcedure","userId":"11"}')[:1] == ("notification",)
assert z.parse_core_line('{"msg":"executeNotificationProcedure","userId":"11"}')[2] is None
# finding 2: the same request in EITHER key order is read
a = z.parse_gateway_line('{"method":"POST","url":"/internal/v1/users/11/route"}')
b = z.parse_gateway_line('{"url":"/internal/v1/users/11/route?x=1","method":"post"}')
assert a == b == ("POST", "/internal/v1/users/11/route"), (a, b)
assert z.parse_gateway_line('prefix {"req":{"method":"POST","url":"/v1/users/11/push-tokens"}} suf') == ("POST", "/v1/users/11/push-tokens")
# and a line that names a user but yields no request is None (bell() turns that into UNMEASURED)
assert z.parse_gateway_line('not json at all') is None
print("ok")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "CREDIT-CLASS (QA #1545 finding 4): core's REAL approval EMAIL template is credit-class - an uncorrelated one is UNMEASURED, never OK" {
  # `backend_profile_credit_requests_approved` is what core actually sends, and it was reported "not credit-class"
  # before APPROVAL_TEMPLATES was consulted: an approval notice to a batch user read OK with no correlation at all.
  echo '{"state":"measured","control":1076,"events":[{"user_id":"12","template_key":"backend_profile_credit_requests_approved","event_type":"sent","event_time":"2026-10-30 15:37:10.000","detail":{"gate":"live","attempts":1}}]}' > "$ZR_FIXTURE_DIR/email.json"
  run_zr
  [ "$status" -eq 2 ]
  [[ "$output" == UNMEASURED:* ]]
  [[ "$output" == *"approval notice with no in-window approval it names"* ]]
  # a non-credit template is still only reported (p1 ruling): the fix widened credit-class, it did not widen STOP
  echo '{"state":"measured","control":1076,"events":[{"user_id":"12","template_key":"payment_receipt","event_type":"sent","event_time":"2026-10-30 15:37:10.000"}]}' > "$ZR_FIXTURE_DIR/email.json"
  run_zr
  [ "$status" -eq 0 ]
  [[ "$output" == *"not credit-class"* ]]
}

@test "CREDIT-CLASS (QA #1545 finding 5): a notification's TEMPLATE wins over a type= that precedes it - raw line to verdict is UNMEASURED, never OK" {
  local py="$BATS_TEST_DIRNAME/../credit_verify/zero_read.py"
  # the raw line, as core logs it: a generic `type=request` comes FIRST, the template that decides what the message
  # is comes after. The old parser took the first alternative it found in the TEXT and returned "request".
  local line='2026-11-03T00:00:00Z {"level":30,"msg":"executeNotificationProcedure","userId":"12","type":"request","template":"credits_more_info_needed"}'
  local logfmt='2026-11-03T00:00:00Z executeNotificationProcedure "userId":"12" type=request template=credits_more_info_needed'
  # raw line -> the event `core()` would put in its report -> the actual verdict, through the script's own classifier
  run python3 - "$py" "$line" "$logfmt" "$ZR_FIXTURE_DIR" "$OUT" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("zr", sys.argv[1]); z = importlib.util.module_from_spec(spec); spec.loader.exec_module(z)
line, logfmt, fx = sys.argv[2], sys.argv[3], sys.argv[4]
for raw in (line, logfmt):
    kind, user, event = z.parse_core_line(raw)
    assert (kind, user) == ("notification", "12"), (kind, user)
    assert event == "credits_more_info_needed", event          # not "request"
    assert z.credit_event(event)                                # credit-class: STOP/UNMEASURED, never "other"
# a notification that names ONLY a generic type is still read as that type (no template to prefer)
assert z.parse_core_line('x executeNotificationProcedure "userId":"12" type=request')[2] == "request"
# and the priority holds for the other template spellings too
assert z.parse_core_line('x executeNotificationProcedure "userId":"12" type=request notificationType=credits_accepted')[2] == "credits_accepted"
assert z.parse_core_line('x executeNotificationProcedure "userId":"12" type=request templateKey=credits_more_info_needed')[2] == "credits_more_info_needed"
# the report `core()` builds from that raw line, handed to the real verdict: no id named -> UNMEASURED
json.dump({"state": "measured", "control": 786, "events": [
    {"user": "12", "event": "credits_more_info_needed", "kind": "notification", "t": "2026-11-03T00:00:00+00:00", "ids": []}]},
    open(fx + "/core.json", "w"))
print("ok")
PY
  [ "$status" -eq 0 ]
  run_zr
  [ "$status" -eq 1 ]                                         # a credit-class notification with no exemption is a STOP
  [[ "$output" == STOP:* ]]
}

@test "CORRELATION (QA #1545 critical): two notices of the SAME event for one user keep their OWN ids - an old request's notice is not excused by a different request a LATER line names" {
  local py="$BATS_TEST_DIRNAME/../credit_verify/zero_read.py"
  # QA reproduced this through core(): ids were accumulated per (user, kind, event) while the events themselves were
  # per timestamp, so an old-request notice arriving FIRST inherited the id of the new request named by a SECOND
  # notice, passed exempt(), and the window read OK. The ids must be carried by the notice that named them.
  run -0 python3 - "$py" <<'PY'
import importlib.util, os, sys
os.environ.pop("ZR_FIXTURE_DIR", None)                       # core() must PARSE these lines, not read a fixture
spec = importlib.util.spec_from_file_location("zr", sys.argv[1]); z = importlib.util.module_from_spec(spec); spec.loader.exec_module(z)
OLD = "11111111-1111-4111-8111-111111111111"; NEW = "22222222-2222-4222-8222-222222222222"
def line(ts, rid):
    return ('2026-10-30T15:37:%02dZ {"msg":"executeNotificationProcedure","userId":"12",'
            '"template":"credits_accepted","templateKey":"credits_accepted","id":"%s"}' % (ts, rid))
class L:
    def query(self, *a, **k): return [(1751204230 * 10**9, line(10, OLD)), (1751204240 * 10**9, line(20, NEW))]
    def count(self, *a, **k): return 786
r = z.core(L(), ["12"], None, None)
assert r["state"] == "measured", r
assert len(r["events"]) == 2, r["events"]                       # two notices are two events, never merged into one
# each notice keeps ONLY the id it named: the FIRST arrival must not inherit the second notice's id
assert sorted(tuple(e["ids"]) for e in r["events"]) == [(OLD,), (NEW,)], r["events"]
# QA #1545 finding 8 (CRITICAL): the SAME holds at ONE Loki nanosecond. Keying the record on (user, kind, event, t)
# merged two DIFFERENT notices that shared a timestamp into a single event carrying BOTH ids, so the old notice
# inherited the new request's id and exempt() excused it - a false OK.
class SameT:
    def query(self, *a, **k): return [(1751204230 * 10**9, line(10, OLD)), (1751204230 * 10**9, line(20, NEW))]
    def count(self, *a, **k): return 786
r2 = z.core(SameT(), ["12"], None, None)
assert len(r2["events"]) == 2, r2["events"]                      # two notices at one nanosecond are STILL two notices
assert sorted(tuple(e["ids"]) for e in r2["events"]) == [(OLD,), (NEW,)], r2["events"]
print("ok")
PY
  # and the end-to-end verdict for exactly that shape: the old notice is uncorrelated, so the window is UNMEASURED
  echo '{"state":"measured","control":786,"events":[{"user":"12","event":"credits_accepted","kind":"notification","t":"2026-10-30T15:37:10+00:00","ids":["11111111-1111-4111-8111-111111111111"]},{"user":"12","event":"credits_accepted","kind":"notification","t":"2026-10-30T15:37:20+00:00","ids":["22222222-2222-4222-8222-222222222222"]}]}' > "$ZR_FIXTURE_DIR/core.json"
  echo '{"state":"measured","rows":[{"user":"12","id":"22222222-2222-4222-8222-222222222222","status":"approved","created":"2026-10-30 15:36:51.789000 UTC","updated":"2026-10-30 15:37:06.936000 UTC","approvalVia":"validator"}]}' > "$ZR_FIXTURE_DIR/replica.json"
  run_zr
  [ "$status" -eq 2 ]
  [[ "$output" == UNMEASURED:* ]]
  [[ "$output" == *"no in-window approval it names"* ]]
}

@test "UNMEASURED (ruling A): credits_accepted for a request that existed before the window is not explained" {
  echo '{"state":"measured","control":1076,"events":[{"user_id":"12","template_key":"credits_accepted","event_type":"sent"}]}' > "$ZR_FIXTURE_DIR/email.json"
  echo '{"state":"measured","rows":[{"user":"12","id":"r0","status":"approved","created":"2026-10-18 22:56:30.966000 UTC","updated":"2026-10-30 15:37:06.936000 UTC","approvalVia":"validator"}]}' > "$ZR_FIXTURE_DIR/replica.json"
  run_zr
  [ "$status" -eq 2 ]
}

@test "UNMEASURED: a source that cannot be read is never zero (exit 2)" {
  echo '{"state":"unmeasured","error":"Loki returned 0 notify-gateway lines for the window (ingest gap?)"}' > "$ZR_FIXTURE_DIR/bell.json"
  run_zr
  [ "$status" -eq 2 ]
  [[ "$output" == UNMEASURED:* ]]
  [[ "$output" == *"unmeasured ['bell']"* ]]
}

@test "UNMEASURED: a missing source fixture is unmeasured, not OK" {
  rm "$ZR_FIXTURE_DIR/email.json"
  run_zr
  [ "$status" -eq 2 ]
}

@test "LIFECYCLE (QA #1545 finding 6): an OPENED or CLICKED credit email is engagement on an EARLIER send - reported, never a STOP; a send still is" {
  # MEASURED on prod 2026-11-03 (3 d GROUP BY event_type): sent 4132, delivered 4122, skipped 397, clicked 214,
  # opened 96, deferred 15, bounced 10. An old credit email opened during the batch used to exit 1 and the caller
  # wrote the global kill file: engagement is now reported only.
  for et in opened clicked; do
    echo "{\"state\":\"measured\",\"control\":1076,\"events\":[{\"user_id\":\"12\",\"template_key\":\"credits_accepted\",\"event_type\":\"$et\",\"event_time\":\"2026-10-30 15:37:10.000\"}]}" > "$ZR_FIXTURE_DIR/email.json"
    run_zr
    [ "$status" -eq 0 ]
    [[ "$output" == OK:* ]]
    [[ "$output" == *"engagement on an earlier send"* ]]
  done
  # a SEND of the same approval template is still credit-class, and with no id named it is UNMEASURED - never OK
  echo '{"state":"measured","control":1076,"events":[{"user_id":"12","template_key":"credits_accepted","event_type":"sent","event_time":"2026-10-30 15:37:10.000"}]}' > "$ZR_FIXTURE_DIR/email.json"
  run_zr
  [ "$status" -eq 2 ]
  # and every word we do not know stays send evidence: fail closed, never OK
  for et in bounced deferred skipped; do
    echo "{\"state\":\"measured\",\"control\":1076,\"events\":[{\"user_id\":\"12\",\"template_key\":\"credits_more_info_needed\",\"event_type\":\"$et\",\"event_time\":\"2026-10-30 15:37:10.000\"}]}" > "$ZR_FIXTURE_DIR/email.json"
    run_zr
    [ "$status" -eq 1 ]
  done
}

@test "PAGINATION (QA #1545 finding 7): the page boundary is lossless, and an unpaginatable saturated timestamp FAILS CLOSED instead of returning a short list" {
  local py="$BATS_TEST_DIRNAME/../credit_verify/zero_read.py"
  run python3 - "$py" <<'PY'
import datetime as dt, importlib.util, json, sys
spec = importlib.util.spec_from_file_location("zr", sys.argv[1]); z = importlib.util.module_from_spec(spec); spec.loader.exec_module(z)
NS = 1_700_000_000_000_000_000
class Resp:
    def __init__(self, payload): self.payload = payload
    def read(self): return json.dumps(self.payload).encode()
def fake(rows):
    calls = []
    def urlopen(url, timeout=None):
        q = dict(kv.split("=", 1) for kv in url.split("?", 1)[1].split("&"))
        start, end, limit = int(q["start"]), int(q["end"]), int(q["limit"])
        calls.append(start)
        page = [r for r in rows if start <= r[0] <= end][:limit]
        return Resp({"data": {"result": [{"values": [[str(ts), l] for ts, l in page]}]}})
    return urlopen, calls
start = dt.datetime.fromtimestamp(NS / 1e9, dt.timezone.utc)
# a 1 ms end offset, not 10 ns: float64 at 1.7e9 has ~477 ns granularity, so a 10 ns bump
# collapses to E0 == S0 and the fake then excludes the boundary rows.
end = dt.datetime.fromtimestamp((NS + 1_000_000) / 1e9, dt.timezone.utc)
l = z.Loki.__new__(z.Loki); l.port = 3100
# float seconds -> ns rounds, so the test uses the EXACT nanosecond integers the script will send (S0 / E0)
S0, E0 = int(start.timestamp() * 1e9), int(end.timestamp() * 1e9)
# (1) LOSSLESS: the boundary nanosecond holds 3 lines and only 2 fit on the first page. The old cursor was
#     `boundary + 1us`, so the third line was dropped and never seen - a hidden credit notification.
rows = [(S0, "a%d" % i) for i in range(4998)] + [(S0 + 1, "b0"), (S0 + 1, "b1"), (S0 + 1, "b2")]
z.urllib.request.urlopen, calls = fake(rows)
got = l.query("{x}", start, end, limit=5000)
assert sorted(g[1] for g in got) == sorted(r[1] for r in rows), (len(got), len(rows))
assert calls[1] == S0 + 1, calls            # the second page starts AT the boundary, not 1us past it
print("lossless ok")
# (2) SATURATED: 5,001 lines at ONE nanosecond cannot be paged at all. Returning 5,000 would let the reader say OK
#     over an unread line, so the query must fail - and the sources must turn that into UNMEASURED.
z.urllib.request.urlopen, _ = fake([(S0, "c%d" % i) for i in range(5001)])
try:
    l.query("{x}", start, end, limit=5000)
except RuntimeError as e:
    assert "saturated" in str(e), e
else:
    raise AssertionError("a saturated page returned a short list instead of failing closed")
class Boom:
    def query(self, *a, **k): raise RuntimeError("Loki page saturated at 1 ns")
    def count(self, *a, **k): return 5
z.FIXTURES = None      # the suite exports ZR_FIXTURE_DIR; without this core()/bell() read fixtures and never ask
assert z.core(Boom(), ["12"], start, end)["state"] == "unmeasured"
assert z.bell(Boom(), ["12"], start, end)["state"] == "unmeasured"
print("saturated ok")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"lossless ok"* ]]
  [[ "$output" == *"saturated ok"* ]]
}

@test "UNMEASURED (l1 684 §3(ii), the arming bar): a BLANK or unreadable template_key is 'cannot tell what was sent', never 'not credit-class' - it cannot read OK, and it is not a STOP either" {
  # the fail-open this closes: `credit_template("")` answers False, so an unclassifiable email row was reported
  # "(not credit-class)" and the run could still exit 0 OK. MEASURED on prod 2026-11-03 (3 d): 0 such rows, so the
  # rule costs nothing today - it exists for the day one appears.
  echo '{"state":"measured","control":1076,"events":[
    {"user_id":"11","template_key":"","event_type":"sent"},
    {"user_id":"12","template_key":null,"event_type":"delivered"},
    {"user_id":"13","template_key":"   ","event_type":"sent"}
  ]}' > "$ZR_FIXTURE_DIR/email.json"
  run_zr
  [ "$status" -eq 2 ]
  [[ "$output" == UNMEASURED:* ]]
  [[ "$output" == *"template_key"* ]]
  # three unreadable rows, none of them treated as a credit send: no STOP, and the verdict names the category
  python3 - "$OUT" <<'PY'
import glob, json, sys
rep = json.load(open(sorted(glob.glob(sys.argv[1] + "/zero-read-*.json"))[-1]))
assert rep["verdict"] == "UNMEASURED", rep["verdict"]
assert rep["stops"] == [], rep["stops"]
assert len(rep["unknown_template"]) == 3, rep["unknown_template"]
assert any("blank/unreadable template_key" in u for u in rep["unmeasured"]), rep["unmeasured"]
PY
}

@test "UNMEASURED (l1 684 §3(ii)): engagement on an earlier send is still only reported - a blank template on an OPENED row does not fail the run" {
  # an engagement event is never evidence that a NEW message went out, so the template on that row cannot matter;
  # the ordering (engagement first, then unreadable) is deliberate and pinned here.
  echo '{"state":"measured","control":1076,"events":[{"user_id":"11","template_key":"","event_type":"opened"}]}' > "$ZR_FIXTURE_DIR/email.json"
  run_zr
  [ "$status" -eq 0 ]
  [[ "$output" == OK:* ]]
}

@test "COHORT (QA #1545 round 8 critical): an ATTEMPTED row's user is in the cohort - a credit-class message to a user the ledger only ATTEMPTED to reach cannot read OK" {
  # a mixed apply leaves 'attempted' rows (the gateway was called, the outcome is unknown). With the cohort at
  # status='sent' only, user 13 was in NO source query and a credit-class email to them read OK. The tick's own cap
  # and spike reads already count sent+attempted, so the reader measured a strictly smaller world than the one it clears.
  python3 - "$ZR_LEDGER" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("insert into verify_messages values (?,?,?,?,?,?)",
           (104, "13", "attempted", "uvn-status", None, "2026-10-30T14:43:00Z"))
db.commit()
PY
  echo '{"state":"measured","control":1076,"events":[{"user_id":"13","template_key":"credits_more_info_needed","event_type":"sent"}]}' > "$ZR_FIXTURE_DIR/email.json"
  run python3 "$ZR" --ledger-ids 101-104 --start 2026-10-30T14:35:00Z --end 2026-10-30T17:15:00Z --out "$OUT"
  [ "$status" -eq 1 ]                                  # STOP: the credit-class message is SEEN
  [[ "$output" == STOP:* ]]
  [[ "$output" == *"3 users"* ]]                        # 11, 12 and the attempted-only 13
  python3 - "$OUT" <<'PY'
import glob, json, sys
rep = json.load(open(sorted(glob.glob(sys.argv[1] + "/zero-read-*.json"))[-1]))
assert rep["cohort"]["attempted_only"] == 1, rep["cohort"]
assert rep["cohort"]["sent"] == 2, rep["cohort"]
PY
}

@test "READER (QA #1545 round 8 important): a kubectl TIMEOUT is a returncode, not an escaping exception - the email reader reports an unmeasured source instead of raising" {
  # subprocess.run(timeout=...) raises TimeoutExpired; uncaught it left Python with a traceback and exit 1, which the
  # outbound tick reads as a CONFIRMED STOP and answers by writing the global kill file. Asserted at the seam itself
  # (the reader function), because a fixture-driven run never reaches kubectl at all.
  stubs="$TMP/bin"; mkdir -p "$stubs"
  printf '#!/bin/sh\nsleep 5\n' > "$stubs/kubectl"; chmod +x "$stubs/kubectl"
  PATH="$stubs:$PATH" ZR_KUBECTL_TIMEOUT=1 python3 - "$ZR" <<'PY'
import datetime as dt, importlib.util, sys
spec = importlib.util.spec_from_file_location("zero_read", sys.argv[1])
z = importlib.util.module_from_spec(spec); spec.loader.exec_module(z)
z.FIXTURES = None                                    # the seam under test: the REAL kubectl path
r = z.email_events(["11"], dt.datetime(2026, 10, 30, 14, 35), dt.datetime(2026, 10, 30, 17, 15))
assert r["state"] == "unmeasured", r
assert "kubectl timed out" in r["error"], r
PY
}

@test "READER (QA #1545 round 8 important): with no reader reachable the whole run still ends in ONE UNMEASURED line and exit 2 - never a traceback, never exit 1" {
  stubs="$TMP/bin"; mkdir -p "$stubs"
  printf '#!/bin/sh\nsleep 5\n' > "$stubs/kubectl"; chmod +x "$stubs/kubectl"
  PATH="$stubs:$PATH" ZR_KUBECTL_TIMEOUT=1 ZR_FIXTURE_DIR= run python3 "$ZR" --ledger-ids 101-103 --start 2026-10-30T14:35:00Z --end 2026-10-30T17:15:00Z --out "$OUT"
  [ "$status" -eq 2 ]
  [[ "$output" == UNMEASURED:* ]]
  [[ "$output" != *"Traceback"* ]]
  [[ "$output" == *"kubectl timed out"* ]]
}

@test "READER (QA #1545 round 8 important): any unexpected escape ends UNMEASURED (exit 2) in one line - a traceback never carries exit 1, which is the tick's STOP signal" {
  # an unreadable ledger is the cheapest real escape: mode=ro on a missing file raises sqlite3.OperationalError
  run python3 "$ZR" --ledger-ids 998-999 --start 2026-10-30T14:35:00Z --end 2026-10-30T17:15:00Z --out "$OUT"
  [ "$status" -eq 2 ]
  [[ "$output" == UNMEASURED:* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "STOP wins over UNMEASURED" {
  echo '{"state":"measured","control":1,"events":[{"user_id":"11","template_key":"credit_status_team_review","event_type":"sent"}]}' > "$ZR_FIXTURE_DIR/email.json"
  echo '{"state":"unmeasured","error":"x"}' > "$ZR_FIXTURE_DIR/core.json"
  run_zr
  [ "$status" -eq 1 ]
}

@test "no sent users in the range is UNMEASURED (exit 2), never a silent OK" {
  run python3 "$ZR" --ledger-ids 103-103 --start 2026-10-30T14:35:00Z --end 2026-10-30T17:15:00Z --out "$OUT"
  [ "$status" -eq 2 ]
}

# ──────────────────────────────────────────────────────────────
# r5 ruling (2026-11-04): STOP and UNMEASURED are INDEPENDENT facts.
#
# A run with stops AND unmeasured sources used to answer a bare "STOP", so the one line an operator reads said
# "these stops explain the window" while some sources had never been read at all. That is an overclaim in the
# direction that matters: it reads as a complete account of a window that is only partly measured. The combined
# verdict is its own word, and the exit code stays 1 - a STOP is still what kills the run, and the caller must not
# have to learn a new rc to keep that behaviour.
# ──────────────────────────────────────────────────────────────

@test "SPLIT: stops AND unmeasured sources -> STOP+UNMEASURED (exit 1, both facts on the line)" {
  # a real STOP (credit-class email to a batch user) ...
  echo '{"state":"measured","control":1076,"events":[{"user_id":"11","template_key":"credits_more_info_needed","event_type":"sent"}]}' > "$ZR_FIXTURE_DIR/email.json"
  # ... and a source that was never read
  echo '{"state":"error","error":"loki 503"}' > "$ZR_FIXTURE_DIR/core.json"
  run_zr
  [ "$status" -eq 1 ]
  [[ "$output" == STOP+UNMEASURED:* ]]
  [[ "$output" == *"email credits_more_info_needed -> 11"* ]]
  [[ "$output" == *"core"* ]]
  python3 -c "import json,glob; r=json.load(open(glob.glob('$OUT/*.json')[0])); assert r['verdict']=='STOP+UNMEASURED', r['verdict']; assert r['stops'] and r['unmeasured']"
}

@test "SPLIT: stops with every source measured stays a bare STOP (exit 1, no false UNMEASURED)" {
  echo '{"state":"measured","control":1076,"events":[{"user_id":"11","template_key":"credits_more_info_needed","event_type":"sent"}]}' > "$ZR_FIXTURE_DIR/email.json"
  run_zr
  [ "$status" -eq 1 ]
  [[ "$output" == STOP:* ]]
  [[ "$output" != STOP+UNMEASURED:* ]]
  python3 -c "import json,glob; r=json.load(open(glob.glob('$OUT/*.json')[0])); assert r['verdict']=='STOP' and r['stops'] and not r['unmeasured']"
}

@test "SPLIT: unmeasured with no stops stays a bare UNMEASURED (exit 2, never promoted to a STOP)" {
  echo '{"state":"error","error":"loki 503"}' > "$ZR_FIXTURE_DIR/core.json"
  run_zr
  [ "$status" -eq 2 ]
  [[ "$output" == UNMEASURED:* ]]
  python3 -c "import json,glob; r=json.load(open(glob.glob('$OUT/*.json')[0])); assert r['verdict']=='UNMEASURED' and not r['stops'] and r['unmeasured']"
}

@test "SPLIT: the outbound tick accepts the combined verdict as a STOP and names the unmeasured part in the kill line" {
  # The tick's case arm must not fall through to the crash branch on the new word, and the kill line must not let an
  # operator read the stops as a complete account of the window.
  local tick="$BATS_TEST_DIRNAME/../credit-verify-outbound.sh"
  grep -q 'STOP+UNMEASURED' "$tick"
  grep -q 'the stops below do NOT account for every source' "$tick"
}
