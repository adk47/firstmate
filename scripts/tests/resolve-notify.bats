#!/usr/bin/env bats

# Tests for resolve-notify.py. Same harness as overdue-verification-notifier.bats:
# load the module via importlib and monkeypatch its module-level network functions
# (fetch_all_tasks / get_conversation / post_intercom_reply / post_slack) so nothing
# touches a real API. Pure logic (extract_candidate, conversation_suppressed, seed,
# dedupe, circuit breaker) is driven directly.
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
  # Pre-seed so we're past cold start; T9 is new.
  echo '{"__seeded_at__": 1781000000, "TOLD": 1781000000, "conv:COLD": 1781000000}' > "$RESOLVE_NOTIFY_STATE"
  run python3 - <<'PYEOF'
import os, json, sys
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
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
  echo '{"__seeded_at__": 1781000000}' > "$RESOLVE_NOTIFY_STATE"
  run python3 - <<'PYEOF'
import os, json, sys
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
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
  echo '{"__seeded_at__": 1781000000, "T9": 1781000000, "conv:C9": 1781000000}' > "$RESOLVE_NOTIFY_STATE"
  run python3 - <<'PYEOF'
import os, sys
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
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

@test "circuit-breaker: many newly-resolved on fresh state aborts and sends nothing" {
  echo '{"__seeded_at__": 1781000000}' > "$RESOLVE_NOTIFY_STATE"  # fresh mtime
  run python3 - <<'PYEOF'
import os, sys
from importlib import util
spec = util.spec_from_file_location('n', os.environ['NOTIFY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
def task(i):
    return {"id": f"T{i}", "status": {"type": "done"},
            "tags": [{"name": "hydra-action-request"}, {"name": "action:credit-verify"}],
            "custom_fields": [{"id": mod.INTERCOM_LINK_FIELD, "value": f"/conversation/C{i}"}],
            "description": "---ACTION-REQUEST---\n{\"customer_email\": \"a@b.com\"}\n---END-ACTION-REQUEST---"}
mod.fetch_all_tasks = lambda key, lid: [task(i) for i in range(40)]  # > default MAX 25
sent = []
mod.post_intercom_reply = lambda *a, **k: sent.append(a)
mod._post_anomaly = lambda text: None  # don't touch Slack
os.environ.update({"CLICKUP_API_KEY": "k", "MUSOAI_INTERCOM_TOKEN": "t"})
sys.argv = ["n", "--apply"]
rc = mod.main()
assert rc == 2, ("breaker should return 2", rc)
assert sent == [], ("breaker must send nothing", sent)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}
