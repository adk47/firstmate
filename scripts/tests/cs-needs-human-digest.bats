#!/usr/bin/env bats

# Tests for cs-needs-human-digest.py. Follows the overdue-verification-notifier
# harness: load the module via importlib and monkeypatch its module-level
# network functions (fetch_open_convs / post_slack_digest) so nothing touches
# a real API. The pure logic (bucket_conversations, owned_ids, mask_email) is
# driven directly.
#
# The module path is exported as $DIGEST and read inside drivers via
# os.environ['DIGEST'] so the python heredocs stay single-quoted (no bash
# interpolation of python braces/dollars).

setup() {
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export DIGEST="$SCRIPTS_DIR/cs-needs-human-digest.py"
  export STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STATE_DIR"
  export CLOSE_SHADOW_LOG="$STATE_DIR/close-resolved-shadow.jsonl"
  export RESOLVE_NOTIFY_STATE="$STATE_DIR/resolve-notify.json"
  export RESOLUTION_STATE_PATH="$STATE_DIR/resolution-matcher-state.json"
  export RESOLUTION_SHADOW_LOG="$STATE_DIR/resolution-matcher-shadow.jsonl"
  export OVERDUE_NOTIFY_STATE="$STATE_DIR/overdue-notifier.json"
  export DEDUP_SHADOW_LOG="$STATE_DIR/dedup-shadow.jsonl"
  export DIGEST_SKIP_HOST_GUARD=1
  # A fixed "now": 2026-06-17 12:00 UTC (a Wednesday).
  export DIGEST_NOW=1781784000
}

@test "syntax-checks" {
  run python3 -m py_compile "$DIGEST"
  [ "$status" -eq 0 ]
}

@test "inline self-test passes" {
  run python3 "$DIGEST" --self-test
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "self-test ok"
}

@test "refuses to run without MUSOAI_INTERCOM_TOKEN" {
  run bash -c "unset MUSOAI_INTERCOM_TOKEN; python3 '$DIGEST' </dev/null"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "MUSOAI_INTERCOM_TOKEN is required"
}

@test "host guard: refuses off ovh-node-8 unless skipped" {
  # The perceived hostname is injected via DIGEST_HOSTNAME_OVERRIDE so this
  # test controls the branch deterministically, regardless of the REAL host
  # the suite runs on (CI runs its bats job ON ovh-node-8 itself — relying on
  # socket.gethostname() here inverted this test's assumption on CI, since
  # unsetting the skip there would NOT refuse and would instead fall through
  # to the (stubbed-out) MUSOAI_INTERCOM_TOKEN check).
  run bash -c "unset DIGEST_SKIP_HOST_GUARD; MUSOAI_INTERCOM_TOKEN=t DIGEST_HOSTNAME_OVERRIDE=some-laptop python3 '$DIGEST' </dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "not on ovh-node-8"
}

@test "host guard: proceeds past the guard when the (injected) hostname IS ovh-node-8" {
  # All network stays stubbed by never providing a real token/network path —
  # this only proves the guard does NOT refuse (it falls through to the next
  # gate, the token check) once the hostname matches, exercising the OTHER
  # guard branch the test above doesn't cover.
  run bash -c "unset DIGEST_SKIP_HOST_GUARD MUSOAI_INTERCOM_TOKEN; DIGEST_HOSTNAME_OVERRIDE=ovh-node-8 python3 '$DIGEST' </dev/null"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "MUSOAI_INTERCOM_TOKEN is required"
  ! (echo "$output" | grep -qi "not on ovh-node-8")
}

@test "bucket_conversations: customer-last -> needs-human, admin-last -> needs-customer-input" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

def conv(cid, email, lar, lcr):
    return {"id": cid, "email": email, "lar": lar, "lcr": lcr, "url": ""}

customer_last = conv("C1", "a@b.com", 100, 200)   # customer replied after us
admin_last = conv("C2", "c@d.com", 300, 100)       # we replied after customer
buckets = mod.bucket_conversations([customer_last, admin_last], set())
assert [c["id"] for c in buckets["needs_human"]] == ["C1"], buckets["needs_human"]
assert [c["id"] for c in buckets["needs_customer_input"]] == ["C2"], buckets["needs_customer_input"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "bucket_conversations: never-replied (lar==0) counts as needs-human" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
never = {"id": "C1", "email": "a@b.com", "lar": 0, "lcr": 50, "url": ""}
buckets = mod.bucket_conversations([never], set())
assert [c["id"] for c in buckets["needs_human"]] == ["C1"], buckets
assert buckets["needs_customer_input"] == [], buckets
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "bucket_conversations: same email x2 open convs -> dup-candidate" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
d1 = {"id": "D1", "email": "dup@x.com", "lar": 100, "lcr": 200, "url": ""}
d2 = {"id": "D2", "email": "dup@x.com", "lar": 300, "lcr": 100, "url": ""}
solo = {"id": "S1", "email": "solo@x.com", "lar": 100, "lcr": 200, "url": ""}
buckets = mod.bucket_conversations([d1, d2, solo], set())
assert {c["id"] for c in buckets["dup_candidate"]} == {"D1", "D2"}, buckets["dup_candidate"]
assert "S1" not in {c["id"] for c in buckets["dup_candidate"]}, buckets["dup_candidate"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "needs-human is ranked oldest-waiting-first" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
recent = {"id": "R", "email": "r@x.com", "lar": 0, "lcr": 900, "url": ""}
oldest = {"id": "O", "email": "o@x.com", "lar": 0, "lcr": 100, "url": ""}
middle = {"id": "M", "email": "m@x.com", "lar": 0, "lcr": 500, "url": ""}
buckets = mod.bucket_conversations([recent, oldest, middle], set())
assert [c["id"] for c in buckets["needs_human"]] == ["O", "M", "R"], buckets["needs_human"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "never-replied conversations rank by created_at, not tied at the Unix epoch" {
  # KEY regression (waiting-timestamp finding): last_contact_reply_at == 0
  # for a never-replied (unanswered first message) conversation must NOT be
  # treated as "waiting since the epoch" — two such conversations created at
  # DIFFERENT times must rank in created_at order, never tied in API order.
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
older = {"id": "OLD", "email": "o@x.com", "lar": 0, "lcr": 0, "created_at": 1000, "url": ""}
newer = {"id": "NEW", "email": "n@x.com", "lar": 0, "lcr": 0, "created_at": 2000, "url": ""}
buckets = mod.bucket_conversations([newer, older], set())  # API order: NEW, OLD
assert [c["id"] for c in buckets["needs_human"]] == ["OLD", "NEW"], buckets["needs_human"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "never-replied conversation under 48h old is not flagged past-48h" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = 10_000_000
c = {"id": "NEW", "email": "n@x.com", "lar": 0, "lcr": 0,
     "created_at": now - (10 * 3600), "url": ""}
buckets = mod.bucket_conversations([c], set())
blocks = mod.build_digest_blocks(buckets, now_epoch=now)
assert "past 48h" not in str(blocks), blocks
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "never-replied conversation over 48h old IS flagged past-48h" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
now = 10_000_000
c = {"id": "OLD", "email": "o@x.com", "lar": 0, "lcr": 0,
     "created_at": now - (72 * 3600), "url": ""}
buckets = mod.bucket_conversations([c], set())
blocks = mod.build_digest_blocks(buckets, now_epoch=now)
assert "past 48h" in str(blocks), blocks
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "outbound admin-initiated 0/0 conversation lands in needs_customer_input, not needs_human" {
  # KEY regression (inbound-vs-outbound finding): lar==0 and lcr==0 is
  # ambiguous on its own now that this digest also covers outbound
  # (admin/bot/campaign-initiated) conversations — an outbound one with no
  # reply parts means WE are waiting on the customer, so it must land in
  # needs-customer-input, never needs-human.
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
outbound = {"id": "OUT", "email": "out@x.com", "lar": 0, "lcr": 0, "created_at": 0,
            "is_inbound": False, "url": ""}
buckets = mod.bucket_conversations([outbound], set())
assert buckets["needs_human"] == [], buckets["needs_human"]
assert [c["id"] for c in buckets["needs_customer_input"]] == ["OUT"], buckets["needs_customer_input"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "outbound bot-initiated 0/0 conversation also lands in needs_customer_input" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
bot_outbound = {"id": "BOT", "email": "bot@x.com", "lar": 0, "lcr": 0, "created_at": 0,
                "is_inbound": False, "url": ""}
buckets = mod.bucket_conversations([bot_outbound], set())
assert buckets["needs_human"] == [], buckets["needs_human"]
assert [c["id"] for c in buckets["needs_customer_input"]] == ["BOT"], buckets["needs_customer_input"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "inbound user-initiated 0/0 conversation stays needs_human" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
inbound = {"id": "IN", "email": "in@x.com", "lar": 0, "lcr": 0, "created_at": 0,
           "is_inbound": True, "url": ""}
buckets = mod.bucket_conversations([inbound], set())
assert [c["id"] for c in buckets["needs_human"]] == ["IN"], buckets["needs_human"]
assert buckets["needs_customer_input"] == [], buckets["needs_customer_input"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "fetch_open_convs preserves is_inbound derived from source.author.type" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

def fake_search(token, body):
    convs = [
        {"id": "BOT1", "source": {"author": {"type": "bot", "email": "bot@intercom.io"}},
         "contacts": {"contacts": []},
         "statistics": {"last_admin_reply_at": 0, "last_contact_reply_at": 0}},
        {"id": "USR1", "source": {"author": {"type": "user", "email": "u@x.com"}},
         "contacts": {"contacts": []},
         "statistics": {"last_admin_reply_at": 0, "last_contact_reply_at": 0}},
    ]
    return {"conversations": convs, "pages": {}}
mod.intercom_search = fake_search
out = mod.fetch_open_convs("tok")
by_id = {c["id"]: c for c in out}
assert by_id["BOT1"]["is_inbound"] is False, by_id["BOT1"]
assert by_id["USR1"]["is_inbound"] is True, by_id["USR1"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "is_inbound_conv: delivered_as is authoritative — customer_initiated is inbound regardless of author.type" {
  # KEY regression (delivered_as finding, verified against the Intercom 2.11
  # OpenAPI spec's conversation_source schema): a lead-authored conversation
  # explicitly marked customer_initiated must be inbound.
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
c = {"source": {"delivered_as": "customer_initiated", "author": {"type": "lead"}}}
assert mod.is_inbound_conv(c) is True, mod.is_inbound_conv(c)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "is_inbound_conv: admin_initiated / campaigns_initiated delivered_as are outbound" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
admin = {"source": {"delivered_as": "admin_initiated", "author": {"type": "admin"}}}
campaign = {"source": {"delivered_as": "campaigns_initiated", "author": {"type": "bot"}}}
assert mod.is_inbound_conv(admin) is False, mod.is_inbound_conv(admin)
assert mod.is_inbound_conv(campaign) is False, mod.is_inbound_conv(campaign)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "is_inbound_conv: delivered_as absent falls back to author.type customer roles (user/lead/contact)" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
for role in ("user", "lead", "contact"):
    c = {"source": {"author": {"type": role}}}
    assert mod.is_inbound_conv(c) is True, (role, mod.is_inbound_conv(c))
admin = {"source": {"author": {"type": "admin"}}}
assert mod.is_inbound_conv(admin) is False, mod.is_inbound_conv(admin)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "lead-initiated and contact-initiated 0/0 conversations land in needs_human, not needs_customer_input" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
lead = {"id": "LEAD1", "email": "lead@x.com", "lar": 0, "lcr": 0, "created_at": 0,
        "is_inbound": mod.is_inbound_conv({"source": {"author": {"type": "lead"}}}), "url": ""}
contact = {"id": "CONTACT1", "email": "contact@x.com", "lar": 0, "lcr": 0, "created_at": 0,
           "is_inbound": mod.is_inbound_conv({"source": {"author": {"type": "contact"}}}), "url": ""}
buckets = mod.bucket_conversations([lead, contact], set())
assert {c["id"] for c in buckets["needs_human"]} == {"LEAD1", "CONTACT1"}, buckets["needs_human"]
assert buckets["needs_customer_input"] == [], buckets["needs_customer_input"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "de-confliction: a conversation id in close-resolved-shadow.jsonl is excluded" {
  echo '{"id": "C1", "closed_at": 100, "email": "a@b.com", "new_state": "closed"}' > "$CLOSE_SHADOW_LOG"
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
c1 = {"id": "C1", "email": "a@b.com", "lar": 0, "lcr": 200, "url": ""}
c2 = {"id": "C2", "email": "c@d.com", "lar": 0, "lcr": 200, "url": ""}
ids = mod.owned_ids(mod.default_state_paths())
assert "C1" in ids, ids
buckets = mod.bucket_conversations([c1, c2], ids)
surfaced = {c["id"] for b in buckets.values() for c in b}
assert "C1" not in surfaced, surfaced
assert "C2" in surfaced, surfaced
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "de-confliction: a conv id owned by resolve-notify state (conv:<id> key) is excluded" {
  python3 -c "import json,os; json.dump({'conv:C1': 123}, open(os.environ['RESOLVE_NOTIFY_STATE'], 'w'))"
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
ids = mod.owned_ids(mod.default_state_paths())
assert "C1" in ids, ids
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "de-confliction: a conv id owned by resolution-matcher (state + shadow) is excluded" {
  python3 -c "import json,os; json.dump({'conv:C9': 1}, open(os.environ['RESOLUTION_STATE_PATH'], 'w'))"
  echo '{"conv_id": "C10", "issue_slug": "s", "email_acted": true}' > "$RESOLUTION_SHADOW_LOG"
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
ids = mod.owned_ids(mod.default_state_paths())
assert "C9" in ids and "C10" in ids, ids
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "de-confliction: a conv id owned by overdue-verification-notifier state is excluded" {
  python3 -c "import json,os; json.dump({'conv:C7': 1}, open(os.environ['OVERDUE_NOTIFY_STATE'], 'w'))"
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
ids = mod.owned_ids(mod.default_state_paths())
assert "C7" in ids, ids
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "de-confliction: missing / empty / corrupt state files never crash — treated as no ownership" {
  # None of the state files exist at all.
  rm -f "$CLOSE_SHADOW_LOG" "$RESOLVE_NOTIFY_STATE" "$RESOLUTION_STATE_PATH" \
        "$RESOLUTION_SHADOW_LOG" "$OVERDUE_NOTIFY_STATE" "$DEDUP_SHADOW_LOG"
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
ids = mod.owned_ids(mod.default_state_paths())
assert ids == set(), ids
print("ok-missing")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok-missing

  # A corrupt JSON state file and a malformed jsonl line must not crash either.
  printf 'not json{{{' > "$RESOLVE_NOTIFY_STATE"
  printf 'not json\n{"id": "C1", "email": "a@b.com"}\n' > "$CLOSE_SHADOW_LOG"
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
ids = mod.owned_ids(mod.default_state_paths())
# Corrupt resolve-notify state is skipped; the good close-resolved line still parses.
assert "C1" in ids, ids
print("ok-corrupt")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok-corrupt
}

@test "de-confliction: a returning customer's email in close-resolved-shadow.jsonl never excludes their NEW, un-owned conversation id" {
  # KEY regression (QA #691 finding, cs-ops-drain-spec.md commit 2c04734b):
  # de-confliction is by CONVERSATION ID ONLY. close-resolved-shadow.jsonl is
  # append-only and keeps every past close forever, so matching by email
  # would permanently hide a returning customer's brand-new, unrelated
  # conversation just because their email appears in some past closed one.
  echo '{"id": "C-OLD", "closed_at": 100, "email": "returning@x.com", "new_state": "closed"}' > "$CLOSE_SHADOW_LOG"
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
new_conv = {"id": "C-NEW", "email": "returning@x.com", "lar": 0, "lcr": 200, "url": ""}
ids = mod.owned_ids(mod.default_state_paths())
assert "C-OLD" in ids and "C-NEW" not in ids, ids
buckets = mod.bucket_conversations([new_conv], ids)
surfaced = {c["id"] for b in buckets.values() for c in b}
assert "C-NEW" in surfaced, surfaced
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "mask_email: masks PII as a***@***" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
assert mod.mask_email("joe@example.com") == "j***@***", mod.mask_email("joe@example.com")
assert mod.mask_email("") == "no email"
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "dry-run (no --post) prints the digest and posts nothing" {
  run python3 - <<'PYEOF'
import os, sys
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.fetch_open_convs = lambda token, limit=0: [
    {"id": "C1", "email": "a@b.com", "lar": 0, "lcr": 200, "url": ""}]
posted = []
mod.post_slack_digest = lambda *a, **k: posted.append(a) or True
os.environ["MUSOAI_INTERCOM_TOKEN"] = "t"
sys.argv = ["d"]
rc = mod.main()
assert rc == 0 and posted == [], (rc, posted)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
  echo "$output" | grep -qi "DRY-RUN"
}

@test "--post posts the rendered digest to Slack" {
  run python3 - <<'PYEOF'
import os, sys
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.fetch_open_convs = lambda token, limit=0: [
    {"id": "C1", "email": "a@b.com", "lar": 0, "lcr": 200, "url": ""}]
posted = []
mod.post_slack_digest = lambda blocks, text, channel, cfg, account: posted.append(
    (blocks, text, channel)) or True
os.environ["MUSOAI_INTERCOM_TOKEN"] = "t"
sys.argv = ["d", "--post"]
rc = mod.main()
assert rc == 0 and len(posted) == 1, (rc, posted)
blocks, text, channel = posted[0]
assert channel == mod.DEFAULT_SUMMARY_CHANNEL, channel
# PII must never leak into the posted text/blocks.
assert "a@b.com" not in text, text
assert "a@b.com" not in str(blocks), blocks
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "intercom_link: stable admin deeplink built from the conv id, independent of source.url" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
# Default workspace id.
assert mod.intercom_link("999") == \
    "https://app.intercom.com/a/inbox/dwjzhcge/inbox/conversation/999", mod.intercom_link("999")
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "intercom_link: INTERCOM_WORKSPACE_ID env overrides the default workspace" {
  run bash -c "INTERCOM_WORKSPACE_ID=custom123 python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
assert mod.intercom_link('42') == \
    'https://app.intercom.com/a/inbox/custom123/inbox/conversation/42', mod.intercom_link('42')
print('ok')
PYEOF"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "contact_email_of: bot/admin-initiated conversation still resolves the real customer email via a contact lookup" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

# The conversation's `contacts` field is a Contact Reference
# ({type, id, external_id} — NO email, per the Intercom 2.11 OpenAPI spec's
# contact_reference schema), so the real email only comes from a follow-up
# GET /contacts/{id}. Stub get_contact instead of inventing an email key on
# the reference itself.
fetched = []
def fake_get_contact(contact_id, token):
    fetched.append(contact_id)
    return {"type": "contact", "id": contact_id, "email": "Real.Customer@Example.com"}
mod.get_contact = fake_get_contact

# source.author is a bot (the conversation initiator) — not the customer.
bot_initiated = {"source": {"author": {"type": "bot", "email": "bot@intercom.io"}},
                  "contacts": {"contacts": [{"type": "contact", "id": "contact-1",
                                              "external_id": "70"}]}}
assert mod.contact_email_of(bot_initiated, "tok") == "real.customer@example.com", \
    mod.contact_email_of(bot_initiated, "tok")

# A verified user-type source.author is still a valid fallback when there is
# no contact reference at all.
user_initiated = {"source": {"author": {"type": "user", "email": "U@X.com"}},
                   "contacts": {"contacts": []}}
assert mod.contact_email_of(user_initiated, "tok") == "u@x.com", \
    mod.contact_email_of(user_initiated, "tok")

# Admin-initiated with no contacts references and no user-type author -> ""
# (fail open to empty rather than crash or falsely attribute the admin's email).
admin_only = {"source": {"author": {"type": "admin", "email": "staff@muso.ai"}},
              "contacts": {"contacts": []}}
assert mod.contact_email_of(admin_only, "tok") == "", mod.contact_email_of(admin_only, "tok")
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "contact_email_of: a missing/deleted (404) contact falls back gracefully, never crashes" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.get_contact = lambda contact_id, token: None  # 404 / deleted / transient failure
# A non-user author (bot) with no other signal must genuinely reach
# get_contact (a user-type author would take the N+1 fast path below and
# never call get_contact at all, which would defeat this test's purpose).
conv = {"source": {"author": {"type": "bot", "email": "bot@intercom.io"}},
        "contacts": {"contacts": [{"type": "contact", "id": "gone", "external_id": None}]}}
assert mod.contact_email_of(conv, "tok") == "", mod.contact_email_of(conv, "tok")
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "contact_email_of: user-type author takes the N+1 fast path — zero contact GETs" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
def boom(contact_id, token):
    raise AssertionError("get_contact must not be called for a user-type author")
mod.get_contact = boom
# A (misleading/incidental) contacts reference is also present — must still
# never trigger a GET when the author is a verified user-type contact.
conv = {"source": {"author": {"type": "user", "email": "Real@X.com"}},
        "contacts": {"contacts": [{"type": "contact", "id": "contact-1", "external_id": None}]}}
assert mod.contact_email_of(conv, "tok") == "real@x.com", mod.contact_email_of(conv, "tok")
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "contact_email_of: caches the contact lookup — the same contact id is fetched only once" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
fetched = []
def fake_get_contact(contact_id, token):
    fetched.append(contact_id)
    return {"type": "contact", "id": contact_id, "email": "shared@x.com"}
mod.get_contact = fake_get_contact
ref = {"type": "contact", "id": "shared-contact", "external_id": None}
conv_a = {"source": {"author": {"type": "bot"}}, "contacts": {"contacts": [ref]}}
conv_b = {"source": {"author": {"type": "bot"}}, "contacts": {"contacts": [ref]}}
assert mod.contact_email_of(conv_a, "tok") == "shared@x.com"
assert mod.contact_email_of(conv_b, "tok") == "shared@x.com"
assert fetched == ["shared-contact"], fetched  # fetched exactly once, not twice
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "get_contact: a 404 returns None and the run continues (benign miss)" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

def raise_404(*a, **k):
    raise mod.urllib.error.HTTPError("https://api.intercom.io/contacts/gone", 404, "Not Found", {}, None)
mod.urllib.request.urlopen = raise_404
assert mod.get_contact("gone", "tok") is None
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "get_contact: a 401 raises ContactLookupFailed immediately (systematic, not retryable)" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.time.sleep = lambda *a, **k: None

calls = []
def raise_401(*a, **k):
    calls.append(1)
    raise mod.urllib.error.HTTPError("https://api.intercom.io/contacts/x", 401, "Unauthorized", {}, None)
mod.urllib.request.urlopen = raise_401
try:
    mod.get_contact("c1", "tok")
    raise SystemExit("expected ContactLookupFailed")
except mod.ContactLookupFailed:
    pass
assert len(calls) == 1, calls  # not retried
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "get_contact: a 429 followed by success recovers (no exception)" {
  run python3 - <<'PYEOF'
import io, json, os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.time.sleep = lambda *a, **k: None

class FakeResp(io.BytesIO):
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return False

responses = [
    mod.urllib.error.HTTPError("https://api.intercom.io/contacts/x", 429, "Too Many Requests", {}, None),
    FakeResp(json.dumps({"type": "contact", "id": "c1", "email": "a@b.com"}).encode()),
]
def fake_urlopen(*a, **k):
    r = responses.pop(0)
    if isinstance(r, Exception):
        raise r
    return r
mod.urllib.request.urlopen = fake_urlopen
contact = mod.get_contact("c1", "tok")
assert contact == {"type": "contact", "id": "c1", "email": "a@b.com"}, contact
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "get_contact: a persistent 429/5xx raises ContactLookupFailed after retries are exhausted" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.time.sleep = lambda *a, **k: None

calls = []
def raise_503(*a, **k):
    calls.append(1)
    raise mod.urllib.error.HTTPError("https://api.intercom.io/contacts/x", 503, "Service Unavailable", {}, None)
mod.urllib.request.urlopen = raise_503
try:
    mod.get_contact("c1", "tok", attempts=3)
    raise SystemExit("expected ContactLookupFailed")
except mod.ContactLookupFailed:
    pass
assert len(calls) == 3, calls  # retried up to `attempts`
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "main: fails loud (exit 3) when contact lookup fails systematically" {
  run python3 - <<'PYEOF'
import os, sys
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

def raise_systematic(token, limit=0):
    raise mod.ContactLookupFailed("GET /contacts/x -> 401 (auth/permissions — not retryable)")
mod.fetch_open_convs = raise_systematic
os.environ["MUSOAI_INTERCOM_TOKEN"] = "t"
sys.argv = ["d"]
rc = mod.main()
assert rc == 3, rc
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "fetch_open_convs: uses contact_email_of (contact lookup, not the bare reference) to populate email" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

def fake_search(token, body):
    convs = [{"id": "C1",
              "source": {"author": {"type": "bot", "email": "bot@intercom.io"}},
              "contacts": {"contacts": [{"type": "contact", "id": "contact-1",
                                          "external_id": "70"}]},
              "statistics": {"last_admin_reply_at": 0, "last_contact_reply_at": 100}}]
    return {"conversations": convs, "pages": {}}
mod.intercom_search = fake_search
mod.get_contact = lambda contact_id, token: {"type": "contact", "id": contact_id, "email": "real@x.com"}
out = mod.fetch_open_convs("tok")
assert out[0]["email"] == "real@x.com", out
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "--post fails loud (non-zero exit) when the Slack post did not actually deliver" {
  run python3 - <<'PYEOF'
import os, sys
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.fetch_open_convs = lambda token, limit=0: [
    {"id": "C1", "email": "a@b.com", "lar": 0, "lcr": 200, "url": ""}]
# Simulate a missing-token/API/network failure inside post_slack_digest: it
# returns False (best-effort, no exception) — the CLI's whole job in --post
# mode is delivering the digest, so an undelivered run must not report "healthy".
mod.post_slack_digest = lambda *a, **k: False
os.environ["MUSOAI_INTERCOM_TOKEN"] = "t"
sys.argv = ["d", "--post"]
rc = mod.main()
assert rc != 0, rc
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "--limit caps the number of conversations scanned" {
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('d', os.environ['DIGEST'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

calls = []
def fake_search(token, body):
    calls.append(body)
    per_page = body["pagination"]["per_page"]
    convs = [{"id": f"C{i}", "source": {"author": {"type": "user", "email": "a@b.com"}},
              "statistics": {"last_admin_reply_at": 0, "last_contact_reply_at": 100}}
             for i in range(per_page)]
    return {"conversations": convs, "pages": {"next": {"starting_after": "X"}}}
mod.intercom_search = fake_search
out = mod.fetch_open_convs("tok", limit=5)
assert len(out) == 5, len(out)
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}
