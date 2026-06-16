#!/usr/bin/env bats

# Tests for overdue-verification-notifier.py. Follows the notify-merged-customers
# harness: load the module via importlib and monkeypatch its module-level network
# functions (fetch_all_tasks / get_conversation / post_intercom_reply / post_slack)
# so nothing touches a real API. The pure logic (extract_candidate,
# conversation_suppressed, seed, dedupe, circuit breaker) is driven directly.
#
# The module path is exported as $NOTIFY and read inside drivers via
# os.environ['NOTIFY'] so the python heredocs stay single-quoted (no bash
# interpolation of python braces/dollars).

setup() {
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export NOTIFY="$SCRIPTS_DIR/overdue-verification-notifier.py"
  export STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STATE_DIR"
  export OVERDUE_NOTIFY_STATE="$STATE_DIR/notified.json"
  export OVERDUE_NOTIFY_SKIP_HOST_GUARD=1
  export OVERDUE_NOTIFY_SUMMARY_MODE=never
  export OVERDUE_NOTIFY_LOG="$BATS_TEST_TMPDIR/send.log"
  # A fixed "now": 2026-06-17 12:00 UTC (a Wednesday).
  export OVERDUE_NOTIFY_NOW=1781784000
}

@test "syntax-checks" {
  run python3 -m py_compile "$NOTIFY"
  [ "$status" -eq 0 ]
}

@test "inline self-test passes" {
  run python3 "$NOTIFY" --self-test
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "self-test ok"
}

@test "refuses to run without CLICKUP_API_KEY" {
  run bash -c "unset CLICKUP_API_KEY; MUSOAI_INTERCOM_TOKEN=fake python3 '$NOTIFY' </dev/null"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "CLICKUP_API_KEY and MUSOAI_INTERCOM_TOKEN are required"
}

@test "extract_candidate: clean overdue verification ticket passes" {
  run python3 - <<'PYEOF'
import os, json
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = 1781784000
task = {
  "id": "T1",
  "status": {"type": "open", "status": "in progress"},
  "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
  "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD,
                     "value": "https://app.intercom.com/a/inbox/w/inbox/conversation/CONV9"}],
  "description": "x\n---ACTION-REQUEST---\n{\"customer_email\": \"Joe@X.com\"}\n---END-ACTION-REQUEST---",
  "due_date": str((now - 5*86400)*1000),
}
c, r = mod.extract_candidate(task, now, 14)
assert r is None and c["conv_id"] == "CONV9" and c["email"] == "joe@x.com", (c, r)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "extract_candidate: resolved ticket dropped (P0 status gate)" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = 1781784000
base = {"id": "T", "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": ".../conversation/C1"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---",
        "due_date": str((now - 5*86400)*1000)}
for st in ({"status": "resolved"}, {"type": "closed"}, {"status": "impossible"}, {"type": "done"}):
    c, r = mod.extract_candidate(dict(base, status=st), now, 14)
    assert c is None and r == "resolved", (st, c, r)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "extract_candidate: tier-3 / non-allowlisted action dropped" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = 1781784000
base = {"id": "T", "status": {"type": "open"},
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": ".../conversation/C1"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---",
        "due_date": str((now - 5*86400)*1000)}
for at in ("subscription-refund", "dispute", "data-deletion", "data-export", "profile-merge"):
    t = dict(base, tags=[{"name": "hydra-action-request"}, {"name": "action:" + at}])
    c, r = mod.extract_candidate(t, now, 14)
    assert c is None and r == "action-type", (at, c, r)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "extract_candidate: analytics-followup is NOT eligible (analytics carve-out)" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = 1781784000
# analytics-followup is tiered as Tier 1 by ticket-format, but the analytics
# carve-out (SOUL.md / active-incidents.md / common-issues.md) forbids ANY
# per-account follow-up promise for analytics. A proactive "we've flagged it"
# message would re-make that forbidden promise, so it must be dropped.
task = {"id": "T", "status": {"type": "open"},
        "tags": [{"name": "hydra-action-request"}, {"name": "action:analytics-followup"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": ".../conversation/C1"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---",
        "due_date": str((now - 5*86400)*1000)}
assert "analytics-followup" not in mod.ALLOWLIST, "analytics-followup must not be allowlisted"
c, r = mod.extract_candidate(task, now, 14)
assert c is None and r == "action-type", (c, r)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "extract_candidate: weekend-only and too-old are skipped" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
base = {"id": "T", "status": {"type": "open"},
        "tags": [{"name": "hydra-action-request"}, {"name": "action:profile-claim"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": ".../conversation/C1"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---"}
# Friday 2021-06-11 12:00 UTC, checked Saturday -> weekend-only.
friday = 1623412800
c, r = mod.extract_candidate(dict(base, due_date=str(friday*1000)), friday + 86400 + 3600, 14)
assert c is None and r == "weekend-only", ("weekend", c, r)
# 30 days overdue -> too-old.
now = 1781784000
c, r = mod.extract_candidate(dict(base, due_date=str((now - 30*86400)*1000)), now, 14)
assert c is None and r == "too-old", ("too-old", c, r)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "conversation_suppressed: each guard fires; clean conv passes" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
B = mod.CAROLINE_ADMIN_ID
def conv(**kw):
    base = {"source": {"author": {"type": "user", "email": "a@b.com"}}, "state": "open",
            "conversation_parts": {"conversation_parts": []}}
    base.update(kw); return base
assert mod.conversation_suppressed(conv(source={"author": {"type": "user", "email": "z@z.com"}}), "a@b.com", B) == "email-mismatch"
assert mod.conversation_suppressed(conv(state="snoozed"), "a@b.com", B) == "not-open"
assert mod.conversation_suppressed(conv(state="closed"), "a@b.com", B) == "not-open"
assert mod.conversation_suppressed(conv(admin_assignee_id="42"), "a@b.com", B) == "assignee-human"
assert mod.conversation_suppressed(conv(tags={"tags": [{"name": "abuse-block"}]}), "a@b.com", B) == "blocked-tag"
assert mod.conversation_suppressed(conv(conversation_parts={"conversation_parts": [{"author": {"type": "user"}}]}), "a@b.com", B) == "customer-last"
assert mod.conversation_suppressed(conv(conversation_parts={"conversation_parts": [{"author": {"type": "admin", "id": "999"}}]}), "a@b.com", B) == "human-reply"
# Clean: bot replied last, open, right email -> not suppressed.
assert mod.conversation_suppressed(conv(conversation_parts={"conversation_parts": [{"author": {"type": "admin", "id": B}}]}), "a@b.com", B) is None
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "cold start: first run seeds candidates and sends nothing" {
  run python3 - <<'PYEOF'
import os, json
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = int(os.environ['OVERDUE_NOTIFY_NOW'])
def task(tid, conv):
    return {"id": tid, "status": {"type": "open"},
            "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
            "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/" + conv}],
            "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---",
            "due_date": str((now - 5*86400)*1000)}
mod.fetch_all_tasks = lambda key, lid: [task("T1", "C1"), task("T2", "C2")]
sent = []
mod.post_intercom_reply = lambda *a, **k: sent.append(a)
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
import sys
sys.argv = ["n", "--apply"]
rc = mod.main()
assert rc == 0, rc
assert sent == [], ("should send nothing on seed", sent)
state = json.load(open(os.environ["OVERDUE_NOTIFY_STATE"]))
assert "T1" in state and "T2" in state and "conv:C1" in state and "conv:C2" in state, state
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "steady state: newly-overdue ticket sends one reply with the documented payload" {
  run python3 - <<'PYEOF'
import os, json
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = int(os.environ['OVERDUE_NOTIFY_NOW'])
# Pre-seed state with an unrelated ticket so it is NOT a cold start.
json.dump({"OLD": now - 100}, open(os.environ["OVERDUE_NOTIFY_STATE"], "w"))
task = {"id": "T1", "status": {"type": "open"},
        "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/C1"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---",
        "due_date": str((now - 5*86400)*1000)}
mod.fetch_all_tasks = lambda key, lid: [task]
mod.get_conversation = lambda cid, tok: {"source": {"author": {"type": "user", "email": "a@b.com"}},
                                         "state": "open",
                                         "conversation_parts": {"conversation_parts": [{"author": {"type": "admin", "id": mod.CAROLINE_ADMIN_ID}}]}}
calls = []
mod.post_intercom_reply = lambda conv_id, admin_id, message, token: calls.append((conv_id, admin_id, message)) or {"id": "msg"}
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
import sys; sys.argv = ["n", "--apply"]
rc = mod.main()
assert rc == 0, rc
assert len(calls) == 1, calls
conv_id, admin_id, message = calls[0]
assert conv_id == "C1" and admin_id == mod.CAROLINE_ADMIN_ID and message == mod.MESSAGE, calls[0]
state = json.load(open(os.environ["OVERDUE_NOTIFY_STATE"]))
assert "T1" in state and "conv:C1" in state, state
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "dry-run (no --apply) sends nothing but reports the candidate" {
  run python3 - <<'PYEOF'
import os, json
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = int(os.environ['OVERDUE_NOTIFY_NOW'])
json.dump({"OLD": now - 100}, open(os.environ["OVERDUE_NOTIFY_STATE"], "w"))
task = {"id": "T1", "status": {"type": "open"},
        "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/C1"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---",
        "due_date": str((now - 5*86400)*1000)}
mod.fetch_all_tasks = lambda key, lid: [task]
mod.get_conversation = lambda cid, tok: {"source": {"author": {"type": "user", "email": "a@b.com"}}, "state": "open", "conversation_parts": {"conversation_parts": [{"author": {"type": "admin", "id": mod.CAROLINE_ADMIN_ID}}]}}
sent = []
mod.post_intercom_reply = lambda *a, **k: sent.append(a)
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
import sys; sys.argv = ["n"]
rc = mod.main()
assert rc == 0 and sent == [], (rc, sent)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "dry-run does not mutate the persistent state file (pure preview)" {
  run python3 - <<'PYEOF'
import os, json
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = int(os.environ['OVERDUE_NOTIFY_NOW'])
before = {"OLD": now - 100}
json.dump(before, open(os.environ["OVERDUE_NOTIFY_STATE"], "w"))
task = {"id": "T1", "status": {"type": "open"},
        "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/C1"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---",
        "due_date": str((now - 5*86400)*1000)}
mod.fetch_all_tasks = lambda key, lid: [task]
# A SUPPRESSED conv (customer spoke last) — the branch that used to write state.
mod.get_conversation = lambda cid, tok: {"source": {"author": {"type": "user", "email": "a@b.com"}}, "state": "open", "conversation_parts": {"conversation_parts": [{"author": {"type": "user"}}]}}
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
import sys; sys.argv = ["n"]  # dry-run
rc = mod.main()
after = json.load(open(os.environ["OVERDUE_NOTIFY_STATE"]))
assert rc == 0 and after == before, ("dry-run mutated state", before, after)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "per-conversation dedupe: two overdue tickets, same conv -> one send" {
  run python3 - <<'PYEOF'
import os, json
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = int(os.environ['OVERDUE_NOTIFY_NOW'])
json.dump({"OLD": now - 100}, open(os.environ["OVERDUE_NOTIFY_STATE"], "w"))
def task(tid, at):
    return {"id": tid, "status": {"type": "open"},
            "tags": [{"name": "hydra-action-request"}, {"name": "action:" + at}],
            "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/SAME"}],
            "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---",
            "due_date": str((now - 5*86400)*1000)}
mod.fetch_all_tasks = lambda key, lid: [task("T1", "credit-verify"), task("T2", "profile-claim")]
mod.get_conversation = lambda cid, tok: {"source": {"author": {"type": "user", "email": "a@b.com"}}, "state": "open", "conversation_parts": {"conversation_parts": [{"author": {"type": "admin", "id": mod.CAROLINE_ADMIN_ID}}]}}
calls = []
mod.post_intercom_reply = lambda *a, **k: calls.append(a) or {"id": "m"}
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
import sys; sys.argv = ["n", "--apply"]
mod.main()
assert len(calls) == 1, ("one message per conversation", calls)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "state is NOT marked when post_intercom_reply fails (no phantom dedup)" {
  run python3 - <<'PYEOF'
import os, json
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = int(os.environ['OVERDUE_NOTIFY_NOW'])
json.dump({"OLD": now - 100}, open(os.environ["OVERDUE_NOTIFY_STATE"], "w"))
task = {"id": "T1", "status": {"type": "open"},
        "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/C1"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---",
        "due_date": str((now - 5*86400)*1000)}
mod.fetch_all_tasks = lambda key, lid: [task]
mod.get_conversation = lambda cid, tok: {"source": {"author": {"type": "user", "email": "a@b.com"}}, "state": "open", "conversation_parts": {"conversation_parts": [{"author": {"type": "admin", "id": mod.CAROLINE_ADMIN_ID}}]}}
def boom(*a, **k):
    raise RuntimeError("intercom 503")
mod.post_intercom_reply = boom
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
import sys; sys.argv = ["n", "--apply"]
rc = mod.main()
assert rc == 3, rc
state = json.load(open(os.environ["OVERDUE_NOTIFY_STATE"]))
assert "T1" not in state and "conv:C1" not in state, ("failed send must not mark seen", state)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "circuit breaker: many newly-overdue on fresh state aborts (exit 2), sends nothing" {
  run python3 - <<'PYEOF'
import os, json, time
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = int(os.environ['OVERDUE_NOTIFY_NOW'])
# Fresh state file (mtime 1h before the fixed now -> state_age < 12h), with only
# an unrelated key, so the 40 overdue tickets are all "new".
json.dump({"OLD": now - 100}, open(os.environ["OVERDUE_NOTIFY_STATE"], "w"))
os.utime(os.environ["OVERDUE_NOTIFY_STATE"], (now - 3600, now - 3600))
def task(i):
    return {"id": "T%d" % i, "status": {"type": "open"},
            "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
            "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/C%d" % i}],
            "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---",
            "due_date": str((now - 5*86400)*1000)}
mod.fetch_all_tasks = lambda key, lid: [task(i) for i in range(40)]
sent = []
mod.post_intercom_reply = lambda *a, **k: sent.append(a)
mod.post_slack = lambda *a, **k: True
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
import sys; sys.argv = ["n", "--apply"]
rc = mod.main()
assert rc == 2 and sent == [], (rc, len(sent))
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "wrong-customer guard: email mismatch suppresses the send" {
  run python3 - <<'PYEOF'
import os, json
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = int(os.environ['OVERDUE_NOTIFY_NOW'])
json.dump({"OLD": now - 100}, open(os.environ["OVERDUE_NOTIFY_STATE"], "w"))
task = {"id": "T1", "status": {"type": "open"},
        "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/C1"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"ticket@x.com\"}\n---END-ACTION-REQUEST---",
        "due_date": str((now - 5*86400)*1000)}
mod.fetch_all_tasks = lambda key, lid: [task]
mod.get_conversation = lambda cid, tok: {"source": {"author": {"type": "user", "email": "different@y.com"}}, "state": "open", "conversation_parts": {"conversation_parts": []}}
sent = []
mod.post_intercom_reply = lambda *a, **k: sent.append(a)
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
import sys; sys.argv = ["n", "--apply"]
rc = mod.main()
assert rc == 0 and sent == [], (rc, sent)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "wrong-customer guard fails CLOSED: admin-authored / missing-email conversation is suppressed" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
B = mod.CAROLINE_ADMIN_ID
# Admin-initiated conversation: source.author.type != "user", no customer
# email. The old guard read conv_email ONLY for type=="user", so conv_email
# was "" and the wrong-customer check (the #1 safety property) was skipped
# fail-OPEN. It must now suppress: identity could not be positively confirmed.
admin_conv = {"source": {"author": {"type": "admin", "id": "777"}}, "state": "open",
              "conversation_parts": {"conversation_parts": []}}
assert mod.conversation_suppressed(admin_conv, "a@b.com", B) == "email-mismatch", "admin-author must fail closed"
# A user author with NO email is equally unconfirmable -> suppress.
noemail_conv = {"source": {"author": {"type": "user"}}, "state": "open",
                "conversation_parts": {"conversation_parts": []}}
assert mod.conversation_suppressed(noemail_conv, "a@b.com", B) == "email-mismatch", "missing email must fail closed"
# A lead author WITH the right email is confirmable -> not suppressed (the old
# code wrongly ignored non-"user" authors even when they carried the email).
lead_conv = {"source": {"author": {"type": "lead", "email": "A@B.com"}}, "state": "open",
             "conversation_parts": {"conversation_parts": [{"author": {"type": "admin", "id": B}}]}}
assert mod.conversation_suppressed(lead_conv, "a@b.com", B) is None, "lead-with-matching-email must pass"
# Missing conversation state also fails closed (Intercom always sends `state`).
nostate_conv = {"source": {"author": {"type": "user", "email": "a@b.com"}},
                "conversation_parts": {"conversation_parts": []}}
assert mod.conversation_suppressed(nostate_conv, "a@b.com", B) == "not-open", "absent state must fail closed"
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "dual action tags (Tier-3 + allowlisted) are deterministically dropped — no non-deterministic leak" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = int(os.environ['OVERDUE_NOTIFY_NOW'])
# A ticket mis-tagged with BOTH a Tier-3 (subscription-refund) and an allowlisted
# (credit-verify) action tag. The old action_type_of returned the FIRST tag from
# an unordered set, so on some hash seeds it picked credit-verify and the refund
# ticket became eligible. action_types_of must surface BOTH, sorted, and the
# multi-action guard must drop the ticket every time.
task = {"id": "T", "status": {"type": "open"},
        "tags": [{"name": "hydra-action-request"},
                 {"name": "action:subscription-refund"},
                 {"name": "action:credit-verify"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": ".../conversation/C1"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---",
        "due_date": str((now - 5*86400)*1000)}
assert mod.action_types_of(task) == ["credit-verify", "subscription-refund"], mod.action_types_of(task)
c, r = mod.extract_candidate(task, now, 14)
assert c is None and r == "action-type", (c, r)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "empty {} state file is treated as cold start: seeds, sends nothing (no backlog blast)" {
  run python3 - <<'PYEOF'
import os, json
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = int(os.environ['OVERDUE_NOTIFY_NOW'])
# A wiped-to-{} state file: valid JSON, so load_state returns {} (NOT the
# corrupt->None path). The old `state is None` cold-start test missed this, so
# every still-overdue ticket became "new" and could blast.
json.dump({}, open(os.environ["OVERDUE_NOTIFY_STATE"], "w"))
def task(i):
    return {"id": "T%d" % i, "status": {"type": "open"},
            "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
            "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/C%d" % i}],
            "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---",
            "due_date": str((now - 5*86400)*1000)}
mod.fetch_all_tasks = lambda key, lid: [task(i) for i in range(3)]
sent = []
mod.post_intercom_reply = lambda *a, **k: sent.append(a)
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
import sys; sys.argv = ["n", "--apply"]
rc = mod.main()
assert rc == 0 and sent == [], ("{} state must seed, not send", rc, sent)
state = json.load(open(os.environ["OVERDUE_NOTIFY_STATE"]))
assert "T0" in state and "conv:C0" in state, ("must seed candidates", state)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "circuit breaker ignores --limit: a raised send cap does not disarm the wiped-state guard" {
  run python3 - <<'PYEOF'
import os, json
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = int(os.environ['OVERDUE_NOTIFY_NOW'])
# Fresh state (mtime 1h ago) with only an unrelated key -> 40 overdue all "new".
json.dump({"OLD": now - 100}, open(os.environ["OVERDUE_NOTIFY_STATE"], "w"))
os.utime(os.environ["OVERDUE_NOTIFY_STATE"], (now - 3600, now - 3600))
def task(i):
    return {"id": "T%d" % i, "status": {"type": "open"},
            "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
            "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/C%d" % i}],
            "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---",
            "due_date": str((now - 5*86400)*1000)}
mod.fetch_all_tasks = lambda key, lid: [task(i) for i in range(40)]
sent = []
mod.post_intercom_reply = lambda *a, **k: sent.append(a)
mod.post_slack = lambda *a, **k: True
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
# --limit 100 raises the send cap far above 40; the breaker must STILL trip
# because it keys on the default MAX (25), not the operator-overridable cap.
import sys; sys.argv = ["n", "--apply", "--limit", "100"]
rc = mod.main()
assert rc == 2 and sent == [], ("--limit must not disarm breaker", rc, len(sent))
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}
