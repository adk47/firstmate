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

  TEST_TMPDIR="$BATS_TEST_TMPDIR"
  export TEST_TMPDIR
  export FAKE_JEV="$SCRIPTS_DIR/tests/fixtures/jev/fake-jev-sh.sh"
  export REAL_JEV="$SCRIPTS_DIR/lib/jev.sh"
  # Throwaway shadow dir so dedupe-same-request wiring tests never touch a
  # real /var/lib/hydra-jev/shadow.
  export JEV_SHADOW_DIR="$BATS_TEST_TMPDIR/jev-shadow"
  mkdir -p "$JEV_SHADOW_DIR"

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
mod.load_pointer_state = lambda: {"O": "posted"}
saved = []
mod.save_pointer_state = lambda state: saved.append(state)
posted = []
mod.post_pointer_comment = lambda *a, **k: posted.append(1)
mod.get_conversation = lambda *a, **k: {"id": "O", "state": "open", "lcr": 0, "lar": 0,
                                         "confirm_email": "x@y.com"}
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

_close_dup_shadow_scenario() {
  # Drives one --apply run of a Tier A candidate (immediate close, no
  # pointer step) and writes the observable result (rc + closed ids) to
  # RESULT_FILE, deliberately separate from stdout/stderr — jev_shadow's own
  # diagnostic lines land on stderr and legitimately DIFFER per failure mode.
  # $1 = JEV_SH to use, $2 = JEV_DISABLED_FILE (optional).
  RESULT_FILE="$TEST_TMPDIR/close-dup-shadow-result.json"
  rm -f "$RESULT_FILE"
  JEV_SH="$1" JEV_DISABLED_FILE="${2:-}" RESULT_FILE="$RESULT_FILE" \
    python3 - > /dev/null 2>&1 <<'PYEOF'
import os, json, sys
from importlib import util
spec = util.spec_from_file_location('m', os.environ['CLOSEDUP'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

older = {"id": "O", "email": "x@y.com", "lar": 200, "lcr": 100, "created_at": 1000, "is_inbound": True}
kept = {"id": "K", "email": "x@y.com", "lar": 300, "lcr": 100, "created_at": 5000, "is_inbound": True}
mod.fetch_open_convs = lambda token: [older, kept]
mod.owned_ids = lambda paths: set()
mod.reverify_still_valid = lambda *a, **k: True

def fake_get_conversation(token, conv_id):
    body = "<p>my profile is wrong</p>" if conv_id == "O" else "<p>please fix my profile</p>"
    return {"id": conv_id, "state": "open", "lcr": 100, "lar": 200,
            "confirm_email": "x@y.com", "source_body": body}
mod.get_conversation = fake_get_conversation

closed = []
mod.close_conversation = lambda token, admin_id, conv_id: closed.append(conv_id) or {"state": "closed"}

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
with open(os.environ["RESULT_FILE"], "w") as f:
    json.dump({"rc": rc, "closed": closed}, f, sort_keys=True)
PYEOF
  cat "$RESULT_FILE"
}

@test "shadow wiring: dedupe-same-request jev call never changes which candidate closes (ok/rc2/hang/kill-switch all match)" {
  export JEV_SHADOW_FAKE_MODE=ok
  run _close_dup_shadow_scenario "$FAKE_JEV"
  [ "$status" -eq 0 ]
  BASELINE="$output"
  [ -n "$BASELINE" ]
  echo "$BASELINE" | grep -qF '"closed": ["O"]'  # sanity: this candidate did close

  export JEV_SHADOW_FAKE_MODE=rc2
  run _close_dup_shadow_scenario "$FAKE_JEV"
  [ "$status" -eq 0 ]
  [ "$output" = "$BASELINE" ]

  export JEV_SHADOW_FAKE_MODE=hang
  run _close_dup_shadow_scenario "$FAKE_JEV"
  [ "$status" -eq 0 ]
  [ "$output" = "$BASELINE" ]

  # Kill switch: real jev.sh, JEV_DISABLED_FILE present -> jev.sh itself exits 6.
  KS_FILE="$TEST_TMPDIR/jev.disabled"
  : > "$KS_FILE"
  run _close_dup_shadow_scenario "$REAL_JEV" "$KS_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "$BASELINE" ]
}

@test "shadow wiring: actual reflects the real tier, and bodies come from each thread's own source_body" {
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

def fake_get_conversation(token, conv_id):
    # Already plain text: this mock stands in for the real get_conversation,
    # which does its own HTML stripping before source_body is ever set
    # (see _strip_html), so the mock returns what that call would produce.
    body = "my profile is wrong" if conv_id == "O" else "please fix my profile"
    return {"id": conv_id, "state": "open", "lcr": 100, "lar": 200,
            "confirm_email": "x@y.com", "source_body": body}
mod.get_conversation = fake_get_conversation
mod.close_conversation = lambda token, admin_id, conv_id: {"state": "closed"}

class FakeShadow:
    def write(self, s): pass
    def flush(self): pass
    def close(self): pass
mod.open_shadow_log = lambda: (FakeShadow(), "/fake/path")
mod.post_slack_summary = lambda *a, **k: True

captured = []
# state is now a zero-arg build_state callable (built lazily inside
# shadow_judge's never-raise boundary), not a pre-built dict -- call it here
# to get the actual state this candidate would have been judged on.
mod.shadow_judge = lambda surface, item_id, state, questions, actual=None: (
    captured.append((surface, item_id, state() if callable(state) else state, actual)) or None)

os.environ["MUSOAI_INTERCOM_TOKEN"] = "t"
os.environ["INTERCOM_ADMIN_ID"] = "5763097"
sys.argv = ["m", "--apply"]
rc = mod.main()
assert rc == 0, rc
assert len(captured) == 1, captured
surface, item_id, state, actual = captured[0]
assert surface == "dedupe-same-request", surface
assert item_id == "O", item_id
assert actual == "A", actual
assert state == {"thread_a_first_message": "my profile is wrong",
                  "thread_b_first_message": "please fix my profile"}, state
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}

@test "build_state boundary: a get_conversation OSError while building shadow state never aborts the close" {
  # Regression for the exact bug class flagged in review: the two re-fetches
  # inside _dedupe_build_state used to run BEFORE shadow_judge was even
  # called, so an OSError (RemoteDisconnected / socket timeout -- neither
  # caught by get_conversation's own URLError/ValueError handling) would
  # raise straight through main()'s loop and abort a legitimate close.
  # Now that fetch lives inside shadow_judge's never-raise boundary, the
  # same OSError must leave `closed`/rc identical to the non-raising case.
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

def raising_get_conversation(token, conv_id):
    raise ConnectionResetError("simulated network failure fetching message body")
mod.get_conversation = raising_get_conversation

closed = []
mod.close_conversation = lambda token, admin_id, conv_id: closed.append(conv_id) or {"state": "closed"}

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
assert rc == 0, rc
assert closed == ["O"], closed  # the close still happens despite the shadow-state GET raising
print("ok")
PYEOF
  [ "$status" -eq 0 ]; echo "$output" | grep -qx ok
}
