#!/usr/bin/env bats

# Tests for notify-merged-customers.py. We exercise the arg-validation,
# stdin-handling, and dry-run-by-default behavior; the API plumbing is
# tested by running against stubbed urllib endpoints would require either
# monkeypatching urllib in-process or a richer fake server — out of scope
# for this PR. The bats here pin the safety contract: refuses to run
# without required env, defaults INTERCOM_ADMIN_ID to Caroline so the
# merge confirmation matches the rest of the Intercom thread, and refuses
# to do anything with no stdin.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  NOTIFY="$REPO_ROOT/scripts/dedup/sweeps/notify-merged-customers.py"
}

@test "notify-merged-customers syntax-checks" {
  run python3 -m py_compile "$NOTIFY"
  [ "$status" -eq 0 ]
}

@test "refuses to run without CLICKUP_API_KEY" {
  # Use bash subshell + unset for portability — macOS env has no -u.
  run bash -c "unset CLICKUP_API_KEY; MUSOAI_INTERCOM_TOKEN=fake python3 '$NOTIFY' </dev/null"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "env required.*CLICKUP_API_KEY"
}

@test "refuses to run without MUSOAI_INTERCOM_TOKEN" {
  run bash -c "unset MUSOAI_INTERCOM_TOKEN; CLICKUP_API_KEY=fake python3 '$NOTIFY' </dev/null"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "env required.*MUSOAI_INTERCOM_TOKEN"
}

@test "--apply without INTERCOM_ADMIN_ID uses Caroline default (no env error)" {
  # New contract: unset INTERCOM_ADMIN_ID falls back to CAROLINE_ADMIN_ID
  # (5763097) so the reply matches the rest of the Intercom thread.
  # Should NOT complain about a missing env var.
  run bash -c "unset INTERCOM_ADMIN_ID; CLICKUP_API_KEY=fake MUSOAI_INTERCOM_TOKEN=fake python3 '$NOTIFY' --apply </dev/null"
  # exits 1 because stdin is empty, NOT because of missing INTERCOM_ADMIN_ID
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no ticket ids on stdin"
  ! echo "$output" | grep -qi "env required.*INTERCOM_ADMIN_ID"
}

@test "allows dry-run (default) without INTERCOM_ADMIN_ID" {
  run bash -c "unset INTERCOM_ADMIN_ID; CLICKUP_API_KEY=fake MUSOAI_INTERCOM_TOKEN=fake python3 '$NOTIFY' </dev/null"
  # exits 1 because stdin is empty, NOT because of missing INTERCOM_ADMIN_ID
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no ticket ids on stdin"
  ! echo "$output" | grep -qi "env required.*INTERCOM_ADMIN_ID"
}

@test "exits 1 with no ticket ids on stdin" {
  run env CLICKUP_API_KEY=fake MUSOAI_INTERCOM_TOKEN=fake \
      python3 "$NOTIFY" </dev/null
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no ticket ids"
}

@test "parses AR block with ---ACTION-REQUEST--- delimiters (Caroline format)" {
  run python3 -c "
from importlib import util
spec = util.spec_from_file_location('n', '$NOTIFY')
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
desc = '''Some preamble.
---ACTION-REQUEST---
{\"customer_email\": \"e@x.com\", \"action_type\": \"profile-merge\"}
---END-ACTION-REQUEST---
trailing.'''
ar = mod.parse_action_request(desc)
assert ar == {'customer_email': 'e@x.com', 'action_type': 'profile-merge'}, ar
print('ok')
"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "per-conv dedup: second ticket for same conv skips with reason" {
  # Drive process() with two ticket ids resolving to the same conv. The
  # second should hit the _SEEN_CONVS guard and print 'already handled'.
  script=$(mktemp)
  cat > "$script" <<PYEOF
import sys, types, datetime as dt
from importlib import util
spec = util.spec_from_file_location('n', '$NOTIFY')
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

# Stub network methods.
mod.get_ticket = lambda tid, key: {
    'description': '''Some preamble.
---ACTION-REQUEST---
{"customer_email": "x@y.com", "customer_profile_id": "abc"}
---END-ACTION-REQUEST---''',
    'date_updated': '1716000000000',
}
mod.find_intercom_conv = lambda email, tok: {'id': 'CONV-1', 'updated_at': 1}
mod.check_admin_replied_since = lambda conv_id, merge_at, tok: False
mod.comment_and_close_ticket = lambda *a, **k: None

args = types.SimpleNamespace(apply=False)
env = {'CLICKUP_API_KEY': 'k', 'MUSOAI_INTERCOM_TOKEN': 'k', 'ADMIN_ID': None}
mod.process('T1', args, env)
mod.process('T2', args, env)
PYEOF
  run python3 "$script"
  rm -f "$script"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "CONV-1 already handled\|already handled in this run"
}

@test "--apply path posts the documented Intercom payload shape" {
  # Pins the field contract that customers actually receive. If a refactor
  # drops admin_id or flips message_type from "comment" to "note", this test
  # catches it before the next live run posts wrong-shape replies (or
  # silently leaves customers with no message at all).
  script=$(mktemp)
  cat > "$script" <<PYEOF
import sys, types, json
from importlib import util
spec = util.spec_from_file_location('n', '$NOTIFY')
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

captured = {}
def fake_http(method, url, headers, body=None, timeout=30):
    captured.setdefault('calls', []).append({'method': method, 'url': url, 'body': body})
    return 200, {}
mod.http = fake_http
mod.get_ticket = lambda tid, key: {
    'description': '''---ACTION-REQUEST---
{"customer_email": "x@y.com", "customer_profile_id": "abc"}
---END-ACTION-REQUEST---''',
    'date_updated': '1716000000000',
}
mod.find_intercom_conv = lambda email, tok: {'id': 'CONV-1', 'updated_at': 1}
mod.check_admin_replied_since = lambda conv_id, merge_at, tok: False

args = types.SimpleNamespace(apply=True)
env = {'CLICKUP_API_KEY': 'k', 'MUSOAI_INTERCOM_TOKEN': 't', 'ADMIN_ID': 'admin-42'}
mod.process('T1', args, env)

reply = [c for c in captured['calls'] if '/conversations/CONV-1/reply' in c['url']]
assert len(reply) == 1, 'expected exactly one reply call'
body = reply[0]['body']
assert body['message_type'] == 'comment', body
assert body['type'] == 'admin', body
assert body['admin_id'] == 'admin-42', body
assert body['body'] == mod.MESSAGE, body
print('ok')
PYEOF
  run python3 "$script"
  rm -f "$script"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "ok"
}

@test "_SEEN_CONVS is NOT marked when post_intercom_reply fails" {
  # Regression: previously _SEEN_CONVS.add() ran before the reply network
  # call. If the reply raised, a second ticket sharing the same conv would
  # hit the dedup guard and silently close without messaging the customer.
  script=$(mktemp)
  cat > "$script" <<PYEOF
import sys, types
from importlib import util
spec = util.spec_from_file_location('n', '$NOTIFY')
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

mod.get_ticket = lambda tid, key: {
    'description': '''---ACTION-REQUEST---
{"customer_email": "x@y.com", "customer_profile_id": "abc"}
---END-ACTION-REQUEST---''',
    'date_updated': '1716000000000',
}
mod.find_intercom_conv = lambda email, tok: {'id': 'CONV-1', 'updated_at': 1}
mod.check_admin_replied_since = lambda conv_id, merge_at, tok: False
def boom(*a, **k):
    raise RuntimeError('intercom 503')
mod.post_intercom_reply = boom
mod.comment_and_close_ticket = lambda *a, **k: None

args = types.SimpleNamespace(apply=True)
env = {'CLICKUP_API_KEY': 'k', 'MUSOAI_INTERCOM_TOKEN': 't', 'ADMIN_ID': 'admin-42'}
try:
    mod.process('T1', args, env)
except RuntimeError:
    pass
assert 'CONV-1' not in mod._SEEN_CONVS, 'conv was marked dedup despite failed reply'
print('ok')
PYEOF
  run python3 "$script"
  rm -f "$script"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "ok"
}

@test "empty-string INTERCOM_ADMIN_ID falls back to Caroline default" {
  # New contract: empty-string env collapses to CAROLINE_ADMIN_ID. The
  # `or CAROLINE_ADMIN_ID` fallback in main() handles both unset AND empty
  # string so a stale `INTERCOM_ADMIN_ID=` in a launcher script no longer
  # silently breaks the apply path mid-run.
  run bash -c "INTERCOM_ADMIN_ID='' CLICKUP_API_KEY=fake MUSOAI_INTERCOM_TOKEN=fake python3 '$NOTIFY' --apply </dev/null"
  # exits 1 because stdin is empty, NOT because of missing INTERCOM_ADMIN_ID
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no ticket ids on stdin"
  ! echo "$output" | grep -qi "env required.*INTERCOM_ADMIN_ID"
}

@test "--apply with no INTERCOM_ADMIN_ID posts admin_id == 5763097 (Caroline)" {
  # The behavior the fix actually exists to guarantee: the merge-done
  # reply lands under Caroline's admin id by default, matching the rest
  # of the Intercom thread. Stub network plumbing, drive main() with one
  # ticket id, capture the reply payload, and assert admin_id.
  script=$(mktemp)
  cat > "$script" <<PYEOF
import sys, types, json, os
from importlib import util
spec = util.spec_from_file_location('n', '$NOTIFY')
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

captured = {}
def fake_http(method, url, headers, body=None, timeout=30):
    captured.setdefault('calls', []).append({'method': method, 'url': url, 'body': body})
    return 200, {}
mod.http = fake_http
mod.get_ticket = lambda tid, key: {
    'description': '''---ACTION-REQUEST---
{"customer_email": "x@y.com", "customer_profile_id": "abc"}
---END-ACTION-REQUEST---''',
    'date_updated': '1716000000000',
}
mod.find_intercom_conv = lambda email, tok: {'id': 'CONV-1', 'updated_at': 1}
mod.check_admin_replied_since = lambda conv_id, merge_at, tok: False

sys.argv = ['notify', '--apply']
sys.stdin = type('S', (), {'__iter__': lambda self: iter(['T1\n'])})()
# Explicitly unset to exercise the Caroline default path.
os.environ.pop('INTERCOM_ADMIN_ID', None)
os.environ.update({'CLICKUP_API_KEY': 'k', 'MUSOAI_INTERCOM_TOKEN': 't'})

mod.main()

reply = [c for c in captured['calls'] if '/conversations/CONV-1/reply' in c['url']]
assert len(reply) == 1, 'expected exactly one reply call'
body = reply[0]['body']
assert body['admin_id'] == '5763097', body  # Caroline
assert body['admin_id'] == mod.CAROLINE_ADMIN_ID, body
print('ok')
PYEOF
  run python3 "$script"
  rm -f "$script"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "ok"
}

@test "explicit INTERCOM_ADMIN_ID override is IGNORED; the reply still posts as Caroline" {
  # Inverted 2026-09-01: this used to assert the override WON, which encoded
  # the defect we now forbid — an env var could move the customer-facing
  # posting identity onto a human. `/etc/openclaw/main.env` really does carry
  # a human's id, so any agent-invoked run inherited it. The identity is a
  # constant of the system (scripts/lib/intercom_identity.py), so a
  # non-Caroline value must be ignored and Caroline used instead. Pairs with
  # the test above to pin both halves of the env contract.
  script=$(mktemp)
  cat > "$script" <<PYEOF
import sys, types, json, os
from importlib import util
spec = util.spec_from_file_location('n', '$NOTIFY')
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

captured = {}
def fake_http(method, url, headers, body=None, timeout=30):
    captured.setdefault('calls', []).append({'method': method, 'url': url, 'body': body})
    return 200, {}
mod.http = fake_http
mod.get_ticket = lambda tid, key: {
    'description': '''---ACTION-REQUEST---
{"customer_email": "x@y.com", "customer_profile_id": "abc"}
---END-ACTION-REQUEST---''',
    'date_updated': '1716000000000',
}
mod.find_intercom_conv = lambda email, tok: {'id': 'CONV-1', 'updated_at': 1}
mod.check_admin_replied_since = lambda conv_id, merge_at, tok: False

sys.argv = ['notify', '--apply']
sys.stdin = type('S', (), {'__iter__': lambda self: iter(['T1\n'])})()
os.environ.update({
    'CLICKUP_API_KEY': 'k',
    'MUSOAI_INTERCOM_TOKEN': 't',
    'INTERCOM_ADMIN_ID': '9999999',
})

mod.main()

reply = [c for c in captured['calls'] if '/conversations/CONV-1/reply' in c['url']]
assert len(reply) == 1, 'expected exactly one reply call'
body = reply[0]['body']
assert body['admin_id'] == mod.CAROLINE_ADMIN_ID, body
assert body['admin_id'] != '9999999', body
print('ok')
PYEOF
  run python3 "$script"
  rm -f "$script"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "ok"
}

@test "exits 3 when a ticket fails during --apply" {
  # Regression: previously the main loop swallowed every exception and
  # exited 0, so cron saw "ok" on a fully-failed batch.
  script=$(mktemp)
  cat > "$script" <<PYEOF
import sys, types, urllib.error
from importlib import util
spec = util.spec_from_file_location('n', '$NOTIFY')
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
def boom(tid, key):
    raise RuntimeError('clickup 502')
mod.get_ticket = boom

sys.argv = ['notify', '--apply']
sys.stdin = type('S', (), {'__iter__': lambda self: iter(['T1\n', 'T2\n'])})()
import os
os.environ.update({'CLICKUP_API_KEY': 'k', 'MUSOAI_INTERCOM_TOKEN': 't', 'INTERCOM_ADMIN_ID': 'admin-42'})
try:
    mod.main()
except SystemExit as e:
    print(f'exit={e.code}')
PYEOF
  run python3 "$script"
  rm -f "$script"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "exit=3"
}

@test "parses AR block with triple-backtick json fence (legacy format)" {
  # Build the script in a tmp file so bats doesn't try to evaluate the
  # triple-backticks as a command substitution.
  script=$(mktemp)
  cat > "$script" <<PYEOF
from importlib import util
spec = util.spec_from_file_location('n', '$NOTIFY')
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
fence = chr(0x60) * 3
desc = "Some preamble.\n" + fence + "json\n{\"customer_email\": \"e@x.com\"}\n" + fence + "\n"
ar = mod.parse_action_request(desc)
assert ar == {'customer_email': 'e@x.com'}, ar
print('ok')
PYEOF
  run python3 "$script"
  rm -f "$script"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
