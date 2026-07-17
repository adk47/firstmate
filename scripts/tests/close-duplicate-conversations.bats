#!/usr/bin/env bats

# Tests for close-duplicate-conversations.py. Follows the cs-needs-human-digest
# harness: load the module via importlib and monkeypatch its module-level
# network functions (fetch_open_convs / close_conversation / post_pointer_comment
# / post_slack_summary / reverify_still_valid) so nothing touches a real API.
# The pure logic (tier_for, group_duplicates, flatten_candidates) is driven
# directly. PATH is stubbed for openclaw/muso per repo doctrine even though
# this script does not shell out to them today, so a future edit that adds a
# subprocess call fails loud here instead of silently hitting a real binary.
#
# The module path is exported as $CLOSEDUP and read inside drivers via
# os.environ['CLOSEDUP'] so the python heredocs stay single-quoted (no bash
# interpolation of python braces/dollars).

setup() {
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export CLOSEDUP="$SCRIPTS_DIR/close-duplicate-conversations.py"
  export STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STATE_DIR"
  export CLOSE_SHADOW_LOG="$STATE_DIR/close-resolved-shadow.jsonl"
  export RESOLVE_NOTIFY_STATE="$STATE_DIR/resolve-notify.json"
  export RESOLUTION_STATE_PATH="$STATE_DIR/resolution-matcher-state.json"
  export RESOLUTION_SHADOW_LOG="$STATE_DIR/resolution-matcher-shadow.jsonl"
  export OVERDUE_NOTIFY_STATE="$STATE_DIR/overdue-notifier.json"
  export DEDUP_SHADOW_LOG="$STATE_DIR/dedup-shadow.jsonl"
  export CLOSE_DUP_SHADOW_LOG="$STATE_DIR/close-duplicate-shadow.jsonl"
  export CLOSE_DUP_POINTER_STATE="$STATE_DIR/pointer-posted.json"

  # Stub openclaw/muso ahead of the real PATH — repo doctrine (this script
  # is pure-Python urllib and shells out to neither today, but the stub is
  # cheap insurance against a future edit silently gaining a live call).
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  for bin in openclaw muso; do
    cat > "$STUB_BIN/$bin" << 'STUBEOF'
#!/usr/bin/env bash
echo "STUB: $0 $*" >&2
exit 1
STUBEOF
    chmod +x "$STUB_BIN/$bin"
  done
  export PATH="$STUB_BIN:$PATH"
}

@test "syntax-checks" {
  run python3 -m py_compile "$CLOSEDUP"
  [ "$status" -eq 0 ]
}

@test "refuses to run without MUSOAI_INTERCOM_TOKEN" {
  run bash -c "unset MUSOAI_INTERCOM_TOKEN; python3 '$CLOSEDUP' </dev/null"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "MUSOAI_INTERCOM_TOKEN is required"
}

@test "tier_for: Tier A requires strictly we-spoke-last (lar > lcr, not >=)" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

older_gt = {"id": "O1", "lar": 200, "lcr": 100, "created_at": 1000}
kept = {"id": "K", "lar": 300, "lcr": 100, "created_at": 5000}
assert mod.tier_for(older_gt, kept) == "A", mod.tier_for(older_gt, kept)

older_eq = {"id": "O2", "lar": 100, "lcr": 100, "created_at": 1000}
assert mod.tier_for(older_eq, kept) is None, mod.tier_for(older_eq, kept)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "tier_for: Tier B window boundary — 14 days qualifies, 14 days + 1s excludes" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

older = {"id": "O", "lar": 0, "lcr": 0, "created_at": 1000}
kept_at_boundary = {"id": "K1", "lar": 50, "lcr": 10, "created_at": 1000 + 14 * 86400}
assert mod.tier_for(older, kept_at_boundary, window_days=14) == "B", \
    mod.tier_for(older, kept_at_boundary, window_days=14)

kept_over_boundary = {"id": "K2", "lar": 50, "lcr": 10, "created_at": 1000 + 14 * 86400 + 1}
assert mod.tier_for(older, kept_over_boundary, window_days=14) is None, \
    mod.tier_for(older, kept_over_boundary, window_days=14)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "group_duplicates: active exchange on the older thread is never closed" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

older_active = {"id": "O", "email": "x@y.com", "lar": 100, "lcr": 200,
                "created_at": 1000, "is_inbound": True}
kept = {"id": "K", "email": "x@y.com", "lar": 300, "lcr": 100,
        "created_at": 5000, "is_inbound": True}
groups = mod.group_duplicates([older_active, kept], set())
assert groups == [], groups
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "group_duplicates: keep = newest by created_at" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

old = {"id": "OLD", "email": "x@y.com", "lar": 100, "lcr": 50,
       "created_at": 1000, "is_inbound": True}
new = {"id": "NEW", "email": "x@y.com", "lar": 0, "lcr": 0,
       "created_at": 5000, "is_inbound": True}
groups = mod.group_duplicates([old, new], set())
assert len(groups) == 1, groups
assert groups[0]["kept"]["id"] == "NEW", groups
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "group_duplicates: equal created_at skips the pair (ambiguous keep)" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

a = {"id": "A", "email": "x@y.com", "lar": 100, "lcr": 50, "created_at": 1000, "is_inbound": True}
b = {"id": "B", "email": "x@y.com", "lar": 100, "lcr": 50, "created_at": 1000, "is_inbound": True}
groups = mod.group_duplicates([a, b], set())
assert groups == [], groups
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "group_duplicates: sibling-owned KEPT thread skips the whole group" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

older = {"id": "O", "email": "x@y.com", "lar": 200, "lcr": 100, "created_at": 1000, "is_inbound": True}
kept = {"id": "K", "email": "x@y.com", "lar": 300, "lcr": 100, "created_at": 5000, "is_inbound": True}
groups = mod.group_duplicates([older, kept], {"K"})
assert groups == [], groups
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "group_duplicates: fast-path-empty email never joins a group" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

a = {"id": "A", "email": "", "lar": 200, "lcr": 100, "created_at": 1000, "is_inbound": True}
b = {"id": "B", "email": "", "lar": 0, "lcr": 0, "created_at": 5000, "is_inbound": True}
groups = mod.group_duplicates([a, b], set())
assert groups == [], groups
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "kept_id shadow-log field never enters owned_ids (CRITICAL de-confliction invariant)" {
  echo '{"id": "CLOSED1", "closed_at": 100, "email": "a@b.com", "kept_id": "KEPT1", "tier": "A", "new_state": "closed"}' > "$CLOSE_DUP_SHADOW_LOG"
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
ids = mod.owned_ids({"close-duplicate": (os.environ["CLOSE_DUP_SHADOW_LOG"], "jsonl")})
assert "CLOSED1" in ids, ids
assert "KEPT1" not in ids, ids
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "sanity ceiling: more than 20 candidates closes nothing and exits non-zero" {
  run python3 - <<'PYEOF'
import os, sys
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

convs = []
for i in range(30):
    convs.append({"id": f"O{i}", "email": f"e{i}@x.com", "lar": 200, "lcr": 100,
                  "created_at": 1000, "is_inbound": True})
    convs.append({"id": f"K{i}", "email": f"e{i}@x.com", "lar": 300, "lcr": 100,
                  "created_at": 5000, "is_inbound": True})
mod.fetch_open_convs = lambda token: convs
mod.owned_ids = lambda paths: set()
closed = []
mod.close_conversation = lambda *a, **k: closed.append(1)
mod.post_slack_summary = lambda *a, **k: True
os.environ["MUSOAI_INTERCOM_TOKEN"] = "t"
sys.argv = ["m", "--apply"]
rc = mod.main()
assert rc != 0, rc
assert closed == [], closed
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "pointer_posted dedupe: a Tier B target already recorded as posted is never re-posted, close is retried" {
  run python3 - <<'PYEOF'
import os, sys
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

older = {"id": "O", "email": "x@y.com", "lar": 0, "lcr": 0, "created_at": 1000, "is_inbound": True}
kept = {"id": "K", "email": "x@y.com", "lar": 50, "lcr": 10, "created_at": 1000 + 86400, "is_inbound": True}
mod.fetch_open_convs = lambda token: [older, kept]
mod.owned_ids = lambda paths: set()
mod.reverify_still_valid = lambda *a, **k: True
mod.load_pointer_state = lambda: {"O": True}
saved = []
mod.save_pointer_state = lambda state: saved.append(state)
posted = []
mod.post_pointer_comment = lambda *a, **k: posted.append(1)
mod.close_conversation = lambda *a, **k: {"state": "closed"}

class FakeShadow:
    def write(self, s): pass
    def flush(self): pass
    def close(self): pass

mod.open_shadow_log = lambda: (FakeShadow(), "/fake/path")
mod.post_slack_summary = lambda *a, **k: True
os.environ["MUSOAI_INTERCOM_TOKEN"] = "t"
sys.argv = ["m", "--apply"]
rc = mod.main()
assert rc == 0, rc
assert posted == [], posted
assert saved == [], saved
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "--notify-candidates posts would-close pairs to Slack even on dry-run" {
  run python3 - <<'PYEOF'
import os, sys
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

older = {"id": "O", "email": "x@y.com", "lar": 200, "lcr": 100, "created_at": 1000, "is_inbound": True}
kept = {"id": "K", "email": "x@y.com", "lar": 300, "lcr": 100, "created_at": 5000, "is_inbound": True}
mod.fetch_open_convs = lambda token: [older, kept]
mod.owned_ids = lambda paths: set()
posted = []
mod.post_slack_summary = lambda text, *a, **k: posted.append(text) or True
os.environ["MUSOAI_INTERCOM_TOKEN"] = "t"
sys.argv = ["m", "--notify-candidates"]
rc = mod.main()
assert rc == 0, rc
assert len(posted) == 1, posted
assert "O" in posted[0] and "K" in posted[0], posted[0]
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "--apply is gated: without it, close_conversation is never called" {
  run python3 - <<'PYEOF'
import os, sys
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

older = {"id": "O", "email": "x@y.com", "lar": 200, "lcr": 100, "created_at": 1000, "is_inbound": True}
kept = {"id": "K", "email": "x@y.com", "lar": 300, "lcr": 100, "created_at": 5000, "is_inbound": True}
mod.fetch_open_convs = lambda token: [older, kept]
mod.owned_ids = lambda paths: set()
def boom(*a, **k):
    raise AssertionError("close_conversation must not be called without --apply")
mod.close_conversation = boom
os.environ["MUSOAI_INTERCOM_TOKEN"] = "t"
sys.argv = ["m"]
rc = mod.main()
assert rc == 0, rc
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "cross-customer / empty-email conversations never form a group" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

a = {"id": "A", "email": "one@x.com", "lar": 200, "lcr": 100, "created_at": 1000, "is_inbound": True}
b = {"id": "B", "email": "two@x.com", "lar": 0, "lcr": 0, "created_at": 5000, "is_inbound": True}
groups = mod.group_duplicates([a, b], set())
assert groups == [], groups
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "reverify_still_valid: empty confirm_email fails closed (does not pass as no-op)" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

older = {"id": "O", "email": "x@y.com", "lar": 200, "lcr": 100, "created_at": 1000}
kept = {"id": "K", "email": "x@y.com", "lar": 300, "lcr": 100, "created_at": 5000}
fresh_older = {"id": "O", "state": "open", "lar": 200, "lcr": 100, "created_at": 1000, "confirm_email": ""}
fresh_kept = {"id": "K", "state": "open", "lar": 300, "lcr": 100, "created_at": 5000, "confirm_email": "x@y.com"}
mod.get_conversation = lambda token, cid: fresh_older if cid == "O" else fresh_kept
assert mod.reverify_still_valid("t", older, kept, "A") is False
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "get_conversation: confirm_email comes from independent GET /contacts, not fast-path author email" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

conv_body = {
    "id": "O", "state": "open", "created_at": 1000,
    "statistics": {"last_admin_reply_at": 200, "last_contact_reply_at": 100},
    "source": {"author": {"type": "user", "email": "fast-path-stale@x.com"}},
    "contacts": {"contacts": [{"id": "C1"}]},
}
mod._retry_json = lambda req: conv_body
calls = []
def fake_get_contact(cid, token):
    calls.append(cid)
    return {"email": "true-contact-email@x.com"}
mod.get_contact = fake_get_contact
result = mod.get_conversation("t", "O")
assert calls == ["C1"], calls
assert result["confirm_email"] == "true-contact-email@x.com", result
assert result["confirm_email"] != "fast-path-stale@x.com"
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "apply mode: shadow log unopenable closes nothing and exits non-zero" {
  run python3 - <<'PYEOF'
import os, sys
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

older = {"id": "O", "email": "x@y.com", "lar": 200, "lcr": 100, "created_at": 1000, "is_inbound": True}
kept = {"id": "K", "email": "x@y.com", "lar": 300, "lcr": 100, "created_at": 5000, "is_inbound": True}
mod.fetch_open_convs = lambda token: [older, kept]
mod.owned_ids = lambda paths: set()
mod.reverify_still_valid = lambda *a, **k: True
closed = []
mod.close_conversation = lambda *a, **k: closed.append(1)
mod.open_shadow_log = lambda: (None, None)
mod.post_slack_summary = lambda *a, **k: True
os.environ["MUSOAI_INTERCOM_TOKEN"] = "t"
os.environ["INTERCOM_ADMIN_ID"] = "5763097"
sys.argv = ["m", "--apply"]
rc = mod.main()
assert rc != 0, rc
assert closed == [], closed
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "pointer marker persist failure skips post and close entirely" {
  run python3 - <<'PYEOF'
import os, sys
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

older = {"id": "O", "email": "x@y.com", "lar": 0, "lcr": 0, "created_at": 1000, "is_inbound": True}
kept = {"id": "K", "email": "x@y.com", "lar": 50, "lcr": 10, "created_at": 1000 + 86400, "is_inbound": True}
mod.fetch_open_convs = lambda token: [older, kept]
mod.owned_ids = lambda paths: set()
mod.reverify_still_valid = lambda *a, **k: True
mod.load_pointer_state = lambda: {}
mod.save_pointer_state = lambda state: False
posted = []
mod.post_pointer_comment = lambda *a, **k: posted.append(1)
closed = []
mod.close_conversation = lambda *a, **k: closed.append(1)

class FakeShadow:
    def write(self, s): pass
    def flush(self): pass
    def close(self): pass

mod.open_shadow_log = lambda: (FakeShadow(), "/fake/path")
mod.post_slack_summary = lambda *a, **k: True
os.environ["MUSOAI_INTERCOM_TOKEN"] = "t"
os.environ["INTERCOM_ADMIN_ID"] = "5763097"
sys.argv = ["m", "--apply"]
rc = mod.main()
assert rc != 0, rc
assert posted == [], posted
assert closed == [], closed
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}
