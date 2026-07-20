#!/usr/bin/env bats

# Tests for resolve-notify.py. Same harness as overdue-verification-notifier.bats:
# load the module via importlib and monkeypatch its module-level network functions
# (fetch_all_tasks / get_conversation / post_intercom_reply / post_slack) so nothing
# touches a real API. Pure logic (extract_candidate, conversation_suppressed, seed,
# dedupe, bulk guard) is driven directly.
#
# $NOTIFY is read inside python heredocs via os.environ['NOTIFY'] so the heredocs
# stay single-quoted (no bash interpolation of python braces/dollars).

setup() {
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export NOTIFY="$SCRIPTS_DIR/resolve-notify.py"
  export STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STATE_DIR"
  export RESOLVE_NOTIFY_STATE="$STATE_DIR/notified.json"
  export RESOLVE_NOTIFY_SKIP_HOST_GUARD=1
  export RESOLVE_NOTIFY_SUMMARY_MODE=never
  export RESOLVE_NOTIFY_LOG="$BATS_TEST_TMPDIR/send.log"
  export RESOLVE_NOTIFY_NOW=1781784000  # 2026-06-17 12:00 UTC
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

@test "refuses to run without required env" {
  run bash -c "unset CLICKUP_API_KEY; MUSOAI_INTERCOM_TOKEN=fake python3 '$NOTIFY' </dev/null"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "CLICKUP_API_KEY and MUSOAI_INTERCOM_TOKEN"
}

@test "extract_candidate: a resolved verification ticket passes" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
task = {"id": "T1", "status": {"type": "done", "status": "complete"},
        "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/CONV9"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"A@B.com\"}\n---END-ACTION-REQUEST---"}
c, r = mod.extract_candidate(task, int(os.environ['RESOLVE_NOTIFY_NOW']))
assert c and r is None, (c, r)
assert c["conv_id"] == "CONV9" and c["email"] == "a@b.com", c
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "extract_candidate: a resolved analytics-followup ticket passes (carve-out retired 2026-06-30)" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
# Carve-out retired: analytics-followup is now a normal Tier-1 follow-up (SOUL.md
# "Analytics handling" / common-issues.md row #7), so a resolved analytics ticket
# gets the same "it's sorted" resolve note as credit-verify et al.
task = {"id": "T1", "status": {"type": "done", "status": "complete"},
        "tags": [{"name": "hydra-action-request"}, {"name": "action:analytics-followup"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/CONV9"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"A@B.com\"}\n---END-ACTION-REQUEST---"}
assert "analytics-followup" in mod.ALLOWLIST, "analytics-followup must be allowlisted"
c, r = mod.extract_candidate(task, int(os.environ['RESOLVE_NOTIFY_NOW']))
assert c and r is None, (c, r)
assert c["conv_id"] == "CONV9" and c["email"] == "a@b.com", c
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "extract_candidate: an UNresolved ticket is dropped (not-resolved)" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
task = {"id": "T1", "status": {"type": "open", "status": "in progress"},
        "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/C1"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---"}
c, r = mod.extract_candidate(task, int(os.environ['RESOLVE_NOTIFY_NOW']))
assert c is None and r == "not-resolved", (c, r)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "extract_candidate: a Tier-3 (refund) ticket is excluded even when resolved" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
task = {"id": "T1", "status": {"type": "done"},
        "tags": [{"name": "hydra-action-request"}, {"name": "action:subscription-refund"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/C1"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---"}
c, r = mod.extract_candidate(task, int(os.environ['RESOLVE_NOTIFY_NOW']))
assert c is None and r == "action-type", (c, r)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "extract_candidate: a whitespace-only customer_email fails closed (no-email)" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
task = {"id": "T1", "status": {"type": "done"},
        "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/C1"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"   \"}\n---END-ACTION-REQUEST---"}
c, r = mod.extract_candidate(task, int(os.environ['RESOLVE_NOTIFY_NOW']))
assert c is None and r == "no-email", (c, r)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "suppression: an empty ticket_email fails closed (no no-op guard)" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
conv = {"source": {"author": {"type": "user", "email": "a@b.com"}}, "state": "open",
        "conversation_parts": {"conversation_parts": []}}
assert mod.conversation_suppressed(conv, "", mod.CAROLINE_ADMIN_ID) == "email-mismatch"
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "suppression: customer-last is ALLOWED (the resolve-notify difference)" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
conv = {"source": {"author": {"type": "user", "email": "a@b.com"}}, "state": "open",
        "conversation_parts": {"conversation_parts": [{"author": {"type": "user"}}]}}
assert mod.conversation_suppressed(conv, "a@b.com", mod.CAROLINE_ADMIN_ID) is None
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "suppression: human-reply / email-mismatch / not-open are blocked" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
S = mod.conversation_suppressed; A = mod.CAROLINE_ADMIN_ID
human = {"source": {"author": {"type": "user", "email": "a@b.com"}}, "state": "open",
         "conversation_parts": {"conversation_parts": [{"author": {"type": "admin", "id": "999"}}]}}
assert S(human, "a@b.com", A) == "human-reply"
wrong = {"source": {"author": {"type": "user", "email": "x@y.com"}}, "state": "open",
         "conversation_parts": {"conversation_parts": []}}
assert S(wrong, "a@b.com", A) == "email-mismatch"
closed = {"source": {"author": {"type": "user", "email": "a@b.com"}}, "state": "closed",
          "conversation_parts": {"conversation_parts": []}}
assert S(closed, "a@b.com", A) == "not-open"
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

# --- end-to-end via main() with monkeypatched network ---

@test "cold start: first run seeds resolved tickets and sends nothing" {
  run python3 - <<'PYEOF'
import os, json, sys
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
def task(tid, conv):
    return {"id": tid, "status": {"type": "done"},
            "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
            "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/" + conv}],
            "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---"}
mod.fetch_all_tasks = lambda key, lid: [task("T1", "C1"), task("T2", "C2")]
sent = []
mod.post_intercom_reply = lambda *a, **k: sent.append(a)
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
sys.argv = ["n", "--apply"]
rc = mod.main()
assert rc == 0, rc
assert sent == [], ("seed must send nothing", sent)
state = json.load(open(os.environ["RESOLVE_NOTIFY_STATE"]))
assert "T1" in state and "conv:C1" in state and "T2" in state and "conv:C2" in state, state
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "apply: a NEWLY-resolved ticket sends exactly one reply (customer-last)" {
  run python3 - <<'PYEOF'
import os, json, sys
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
# Pre-seed so we're past cold start; T9 is new.
mod.write_state(os.environ["RESOLVE_NOTIFY_STATE"], {
    mod.SEED_SENTINEL: 1781000000, "TOLD": 1781000000, "conv:COLD": 1781000000})
task = {"id": "T9", "status": {"type": "done"},
        "tags": [{"name": "hydra-action-request"}, {"name": "action:profile-claim"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/C9"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---"}
mod.fetch_all_tasks = lambda key, lid: [task]
# Customer spoke last + email matches -> NOT suppressed for resolve-notify.
mod.get_conversation = lambda cid, tok: {"source": {"author": {"type": "user", "email": "a@b.com"}},
                                         "state": "open",
                                         "conversation_parts": {"conversation_parts": [{"author": {"type": "user"}}]}}
calls = []
mod.post_intercom_reply = lambda conv_id, admin_id, message, token: calls.append((conv_id, message)) or {"id": "m"}
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
sys.argv = ["n", "--apply"]
rc = mod.main()
assert rc == 0, rc
assert len(calls) == 1 and calls[0][0] == "C9", calls
assert calls[0][1] == mod.MESSAGE, "must send the fixed resolution message"
state = json.load(open(os.environ["RESOLVE_NOTIFY_STATE"]))
assert "T9" in state and "conv:C9" in state, state
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "dry-run: previews but never writes state or sends" {
  run python3 - <<'PYEOF'
import os, json, sys
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.write_state(os.environ["RESOLVE_NOTIFY_STATE"], {mod.SEED_SENTINEL: 1781000000})
task = {"id": "T9", "status": {"type": "done"},
        "tags": [{"name": "hydra-action-request"}, {"name": "action:profile-claim"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/C9"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---"}
mod.fetch_all_tasks = lambda key, lid: [task]
mod.get_conversation = lambda cid, tok: {"source": {"author": {"type": "user", "email": "a@b.com"}},
                                         "state": "open", "conversation_parts": {"conversation_parts": []}}
sent = []
mod.post_intercom_reply = lambda *a, **k: sent.append(a)
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
sys.argv = ["n"]  # no --apply
rc = mod.main()
assert rc == 0 and sent == [], ("dry-run sends nothing", sent)
state = json.load(open(os.environ["RESOLVE_NOTIFY_STATE"]))
assert "T9" not in state and "conv:C9" not in state, ("dry-run must not write state", state)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "dedupe: an already-seen ticket is not re-sent" {
  run python3 - <<'PYEOF'
import os, sys
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.write_state(os.environ["RESOLVE_NOTIFY_STATE"], {
    mod.SEED_SENTINEL: 1781000000, "T9": 1781000000, "conv:C9": 1781000000})
task = {"id": "T9", "status": {"type": "done"},
        "tags": [{"name": "hydra-action-request"}, {"name": "action:profile-claim"}],
        "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": "/conversation/C9"}],
        "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---"}
mod.fetch_all_tasks = lambda key, lid: [task]
sent = []
mod.post_intercom_reply = lambda *a, **k: sent.append(a)
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
sys.argv = ["n", "--apply"]
rc = mod.main()
assert rc == 0 and sent == [], ("already-seen must not resend", sent)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "bulk backlog: pages once, holds one cycle, then drains at the normal cap" {
  run python3 - <<'PYEOF'
import contextlib, io, json, os, sys
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.write_state(os.environ["RESOLVE_NOTIFY_STATE"], {mod.SEED_SENTINEL: 1781000000})
def task(i):
    return {"id": f"T{i}", "status": {"type": "done"},
            "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
            "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": f"/conversation/C{i}"}],
            "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---"}
mod.fetch_all_tasks = lambda key, lid: [task(i) for i in range(40)]  # > default MAX 25
sent = []
mod.post_intercom_reply = lambda *a, **k: sent.append(a)
gets = []
mod.get_conversation = lambda cid, tok: gets.append(cid) or {
    "source": {"author": {"type": "user", "email": "a@b.com"}},
    "state": "open", "conversation_parts": {"conversation_parts": []}}
alerts = []
def post_alert(text):
    alerts.append(text)
    return True
mod._post_anomaly = post_alert
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
sys.argv = ["n", "--apply"]

# First observation holds the batch for one timer cycle and alerts once.
assert mod.main() == 0
state = json.load(open(os.environ["RESOLVE_NOTIFY_STATE"]))
assert len(state[mod.BULK_BACKLOG_KEY]["ticket_ids"]) == 40, state
assert len(alerts) == 1 and gets == [] and sent == [], (alerts, gets, sent)

# Dry-run previews the cap and projected remainder without mutating the backlog.
before = open(os.environ["RESOLVE_NOTIFY_STATE"]).read()
sys.argv = ["n", "--limit", "10"]
preview = io.StringIO()
with contextlib.redirect_stdout(preview):
    assert mod.main() == 0
assert open(os.environ["RESOLVE_NOTIFY_STATE"]).read() == before
assert "capped=True" in preview.getvalue() and "bulk_remaining=30" in preview.getvalue(), preview.getvalue()
assert len(gets) == 10 and sent == [], (gets, sent)
gets.clear()

# Later runs drain the stored batch at MAX=25 without repeating the alert.
sys.argv = ["n", "--apply", "--limit", "100"]  # raised limit cannot disarm MAX
assert mod.main() == 0
state = json.load(open(os.environ["RESOLVE_NOTIFY_STATE"]))
assert len(gets) == 25 and len(sent) == 25 and len(alerts) == 1, (len(gets), alerts, sent)
assert len(state[mod.BULK_BACKLOG_KEY]["ticket_ids"]) == 15, state

assert mod.main() == 0
state = json.load(open(os.environ["RESOLVE_NOTIFY_STATE"]))
assert len(gets) == 40 and len(sent) == 40 and len(alerts) == 1, (len(gets), alerts, sent)
assert mod.BULK_BACKLOG_KEY not in state, state
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "bulk backlog: warning delivery gates draining" {
  run python3 - <<'PYEOF'
import json, os, sys
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.write_state(os.environ["RESOLVE_NOTIFY_STATE"], {mod.SEED_SENTINEL: 1781000000})
def task(i):
    return {"id": f"T{i}", "status": {"type": "done"},
            "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
            "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": f"/conversation/C{i}"}],
            "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---"}
mod.fetch_all_tasks = lambda key, lid: [task(i) for i in range(26)]
gets, sent, attempts = [], [], []
mod.get_conversation = lambda cid, tok: gets.append(cid) or {
    "source": {"author": {"type": "user", "email": "a@b.com"}},
    "state": "open", "conversation_parts": {"conversation_parts": []}}
mod.post_intercom_reply = lambda *a, **k: sent.append(a)
mod._post_anomaly = lambda text: attempts.append(text) or len(attempts) > 1
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
sys.argv = ["n", "--apply"]

assert mod.main() == 0
state = json.load(open(os.environ["RESOLVE_NOTIFY_STATE"]))
assert state[mod.BULK_BACKLOG_KEY]["alerted"] is False
assert len(attempts) == 1 and gets == [] and sent == []

assert mod.main() == 0
state = json.load(open(os.environ["RESOLVE_NOTIFY_STATE"]))
assert state[mod.BULK_BACKLOG_KEY]["alerted"] is True
assert len(attempts) == 2 and gets == [] and sent == []

assert mod.main() == 0
assert len(gets) == 25 and len(sent) == 25 and len(attempts) == 2
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "bulk backlog: new tickets wait outside the frozen batch" {
  run python3 - <<'PYEOF'
import json, os, sys
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
backlog = {"first_seen_at": 1781000000, "ticket_ids": ["T0", "T1", "T2"], "alerted": True}
mod.write_state(os.environ["RESOLVE_NOTIFY_STATE"], {
    mod.SEED_SENTINEL: 1781000000, mod.BULK_BACKLOG_KEY: backlog})
def task(i):
    return {"id": f"T{i}", "status": {"type": "done"},
            "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
            "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": f"/conversation/C{i}"}],
            "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---"}
mod.fetch_all_tasks = lambda key, lid: [task(i) for i in range(6)]
mod.get_conversation = lambda cid, tok: {
    "source": {"author": {"type": "user", "email": "a@b.com"}},
    "state": "open", "conversation_parts": {"conversation_parts": []}}
sent = []
mod.post_intercom_reply = lambda cid, *a, **k: sent.append(cid)
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
sys.argv = ["n", "--apply", "--limit", "2"]
assert mod.main() == 0
state = json.load(open(os.environ["RESOLVE_NOTIFY_STATE"]))
assert state[mod.BULK_BACKLOG_KEY]["ticket_ids"] == ["T2"], state
assert sent == ["C0", "C1"], sent
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "bulk backlog: failed leading tickets rotate behind unattempted work" {
  run python3 - <<'PYEOF'
import json, os, sys
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
backlog = {"first_seen_at": 1781000000, "ticket_ids": ["T0", "T1", "T2"], "alerted": True}
mod.write_state(os.environ["RESOLVE_NOTIFY_STATE"], {
    mod.SEED_SENTINEL: 1781000000, mod.BULK_BACKLOG_KEY: backlog})
def task(i):
    return {"id": f"T{i}", "status": {"type": "done"},
            "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
            "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": f"/conversation/C{i}"}],
            "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---"}
mod.fetch_all_tasks = lambda key, lid: [task(i) for i in range(3)]
mod.get_conversation = lambda cid, tok: {
    "source": {"author": {"type": "user", "email": "a@b.com"}},
    "state": "open", "conversation_parts": {"conversation_parts": []}}
mod.post_intercom_reply = lambda cid, *a, **k: (_ for _ in ()).throw(RuntimeError("retry"))
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
sys.argv = ["n", "--apply", "--limit", "1"]
assert mod.main() == 3
state = json.load(open(os.environ["RESOLVE_NOTIFY_STATE"]))
assert state[mod.BULK_BACKLOG_KEY]["ticket_ids"] == ["T1", "T2", "T0"], state
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "state lock: overlapping apply run exits before fetching" {
  run python3 - <<'PYEOF'
import fcntl, os, sys
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.write_state(os.environ["RESOLVE_NOTIFY_STATE"], {mod.SEED_SENTINEL: 1781000000})
held = open(os.environ["RESOLVE_NOTIFY_STATE"] + ".lock", "a+")
fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
mod.fetch_all_tasks = lambda *a: (_ for _ in ()).throw(AssertionError("must not fetch"))
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
sys.argv = ["n", "--apply"]
assert mod.main() == 0
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "legacy migration: explicit mode upgrades once and strict loading rejects downgrade" {
  echo '{"__seeded_at__": 1781000000, "T1": 1781000000, "conv:C1": 1781000000}' > "$RESOLVE_NOTIFY_STATE"
  run python3 "$NOTIFY" --migrate-legacy-state
  [ "$status" -eq 0 ]
  [[ "$output" == *"migrated legacy state"* ]]
  run python3 - <<'PYEOF'
import json, os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
path = os.environ["RESOLVE_NOTIFY_STATE"]
assert mod.load_state(path) is not None
assert os.path.exists(path + mod.STATE_MIGRATION_MARKER_SUFFIX)
downgraded = json.load(open(path))
downgraded.pop(mod.STATE_VERSION_KEY)
downgraded.pop(mod.STATE_CHECKSUM_KEY)
json.dump(downgraded, open(path, "w"))
assert mod.load_state(path) is None, "metadata-free state must never load during normal operation"
before = open(path).read()
assert mod.migrate_legacy_state(path) == 1, "a later deploy must not re-bless downgraded v2 state"
assert open(path).read() == before, "refused migration must not mutate state"
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "systemd closer is ordered after resolve-notify" {
  run python3 - "$SCRIPTS_DIR/install-aux-units.sh" <<'PYEOF'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
unit = text.split("<< CLOSERESVC\n", 1)[1].split("\nCLOSERESVC", 1)[0]
assert "Requires=resolve-notify.service" in unit
assert "After=network-online.target resolve-notify.service" in unit
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "state integrity: a checksum-bearing state fails closed after tampering" {
  run python3 - <<'PYEOF'
import json, os
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
path = os.environ["RESOLVE_NOTIFY_STATE"]
state = {mod.SEED_SENTINEL: 1781000000, "T1": 1781000000, "conv:C1": 1781000000}
mod.write_state(path, state)
assert mod.load_state(path) is not None
tampered = json.load(open(path))
tampered["T1"] = 1781000001
json.dump(tampered, open(path, "w"))
assert mod.load_state(path) is None, "tampered state must enter the safe re-seed path"
mod.write_state(path, state)
tampered = json.load(open(path))
tampered.pop(mod.STATE_VERSION_KEY)
json.dump(tampered, open(path, "w"))
assert mod.load_state(path) is None, "partial integrity metadata must fail closed"
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}
