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
  # Empty stdin from a real empty file, NOT </dev/null: on 2026-10-09 node-8's
  # /dev/null (the host of every hydra CI runner) became a regular file that
  # collects whatever is written to it, so reading it fed junk "ticket ids" to
  # the script and these cases failed intermittently.
  EMPTY_STDIN="$BATS_TEST_TMPDIR/empty-stdin"
  : > "$EMPTY_STDIN"
}

@test "notify-merged-customers syntax-checks" {
  run python3 -m py_compile "$NOTIFY"
  [ "$status" -eq 0 ]
}

@test "refuses to run without CLICKUP_API_KEY" {
  # Use bash subshell + unset for portability — macOS env has no -u.
  run bash -c "unset CLICKUP_API_KEY; MUSOAI_INTERCOM_TOKEN=fake python3 '$NOTIFY' <'$EMPTY_STDIN'"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "env required.*CLICKUP_API_KEY"
}

@test "refuses to run without MUSOAI_INTERCOM_TOKEN" {
  run bash -c "unset MUSOAI_INTERCOM_TOKEN; CLICKUP_API_KEY=fake python3 '$NOTIFY' <'$EMPTY_STDIN'"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "env required.*MUSOAI_INTERCOM_TOKEN"
}

@test "--apply without INTERCOM_ADMIN_ID uses Caroline default (no env error)" {
  # New contract: unset INTERCOM_ADMIN_ID falls back to CAROLINE_ADMIN_ID
  # (5763097) so the reply matches the rest of the Intercom thread.
  # Should NOT complain about a missing env var.
  run bash -c "unset INTERCOM_ADMIN_ID; CLICKUP_API_KEY=fake MUSOAI_INTERCOM_TOKEN=fake python3 '$NOTIFY' --apply <'$EMPTY_STDIN'"
  # exits 1 because stdin is empty, NOT because of missing INTERCOM_ADMIN_ID
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no ticket ids on stdin"
  ! echo "$output" | grep -qi "env required.*INTERCOM_ADMIN_ID"
}

@test "allows dry-run (default) without INTERCOM_ADMIN_ID" {
  run bash -c "unset INTERCOM_ADMIN_ID; CLICKUP_API_KEY=fake MUSOAI_INTERCOM_TOKEN=fake python3 '$NOTIFY' <'$EMPTY_STDIN'"
  # exits 1 because stdin is empty, NOT because of missing INTERCOM_ADMIN_ID
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no ticket ids on stdin"
  ! echo "$output" | grep -qi "env required.*INTERCOM_ADMIN_ID"
}

@test "exits 1 with no ticket ids on stdin" {
  run env CLICKUP_API_KEY=fake MUSOAI_INTERCOM_TOKEN=fake \
      python3 "$NOTIFY" <"$EMPTY_STDIN"
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
  run bash -c "INTERCOM_ADMIN_ID='' CLICKUP_API_KEY=fake MUSOAI_INTERCOM_TOKEN=fake python3 '$NOTIFY' --apply <'$EMPTY_STDIN'"
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

@test "merge-outcome tagged ticket: deferred only when the approved merge-outcome-notify has told or will tell the customer" {
  script=$(mktemp)
  state="$BATS_TEST_TMPDIR/merge-outcome-state.json"
  cat > "$script" <<PYEOF
import sys, types, json, os, datetime as dt
os.environ['MERGE_OUTCOME_STATE'] = '$state'
from importlib import util
spec = util.spec_from_file_location('n', '$NOTIFY')
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

calls = []
def fake_http(method, url, headers, body=None, timeout=30):
    calls.append(url)
    return 200, {}
mod.http = fake_http
tags = {'v': []}
mod.get_ticket = lambda tid, key: {
    'id': tid,
    'tags': [{'name': t} for t in ['hydra-action-request', 'action:profile-merge'] + tags['v']],
    'description': '''**Conversation:** https://app.intercom.com/a/inbox/x/inbox/conversation/900
---ACTION-REQUEST---
{"customer_email": "x@y.com", "customer_profile_id": "abc"}
---END-ACTION-REQUEST---''',
    'date_updated': '1716000000000',
}
n = {'i': 0}
def conv(email, tok):
    n['i'] += 1
    return {'id': 'CONV-%d' % n['i'], 'updated_at': 1}
mod.find_intercom_conv = conv
mod.check_admin_replied_since = lambda conv_id, merge_at, tok: False
mod.comment_and_close_ticket = lambda *a, **k: calls.append('closed')

args = types.SimpleNamespace(apply=True)
env = {'CLICKUP_API_KEY': 'k', 'MUSOAI_INTERCOM_TOKEN': 't', 'ADMIN_ID': mod.CAROLINE_ADMIN_ID}
day = lambda ago: (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=ago)).strftime('%Y-%m-%d')

def legacy_sends(approved, ticket_tags, tid=None):
    calls.clear()
    tags['v'] = ticket_tags
    mod._merge_outcome_notify().MERGE_OUTCOME_COPY_APPROVED = approved
    mod.process(tid or 'T%d' % n['i'], args, env)
    sent = bool([c for c in calls if c.endswith('/reply')]) and 'closed' in calls
    assert sent or calls == [], calls
    return sent

fresh = ['merge-outcome:merged', 'merge-outcome-at:' + day(1)]
assert legacy_sends(False, fresh)
assert not legacy_sends(True, fresh)
assert not legacy_sends(True, ['merge-outcome:merged', 'merge-outcome-notified'])
assert legacy_sends(True, ['merge-outcome:merged'])
assert legacy_sends(True, ['merge-outcome:merged', 'merge-outcome-at:' + day(8)])
assert legacy_sends(True, ['merge-outcome:merged', 'merge-outcome-at:not-a-date'])
assert legacy_sends(True, ['merge-outcome:merged', 'merge-outcome-at:' + day(1), 'merge-outcome-at:' + day(2)])
assert legacy_sends(True, fresh + ['merge-outcome-notifier-skipped'])
open('$state', 'w').write(json.dumps({'tickets': {'SEEDED-1': 'seeded', 'SENT-1': 'sent'}}))
assert legacy_sends(True, fresh, 'SEEDED-1')
assert not legacy_sends(True, ['merge-outcome:merged', 'merge-outcome-at:' + day(9)], 'SENT-1')
assert not legacy_sends(True, fresh, 'OTHER-1')
# An unrelated merge on the same profile routes the ticket here, but THIS request was not merged:
# a needs-evidence, not-merged or ambiguous outcome never gets 'merge complete', fresh, stale,
# undated, approved or not.
for approved in (True, False):
    for outcome in (['merge-outcome:not-merged'], ['merge-outcome:needs-evidence'],
                    ['merge-outcome:merged', 'merge-outcome:not-merged']):
        for at in ([], ['merge-outcome-at:' + day(8)], ['merge-outcome-at:' + day(1)]):
            assert not legacy_sends(approved, outcome + at + ['merge-outcome-notifier-skipped']), (approved, outcome, at)
            assert not legacy_sends(approved, outcome + at), (approved, outcome, at)
print('ok')
PYEOF
  run python3 "$script"
  rm -f "$script"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "ok"
}

@test "while merge-outcome-notify is unapproved, posting on a merge-outcome tagged ticket also adds merge-outcome-notified (best effort); untagged tickets get no such tag" {
  script=$(mktemp)
  cat > "$script" <<PYEOF
import types
from importlib import util
spec = util.spec_from_file_location('n', '$NOTIFY')
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

calls = []
fail_tag = {'on': False}
def fake_http(method, url, headers, body=None, timeout=30):
    calls.append((method, url))
    if '/tag/merge-outcome-notified' in url and fail_tag['on']:
        return 500, {'err': 'boom'}
    return 200, {}
mod.http = fake_http
def ticket(tags):
    return lambda tid, key: {
        'tags': [{'name': t} for t in tags],
        'description': '''---ACTION-REQUEST---
{"customer_email": "x@y.com", "customer_profile_id": "abc"}
---END-ACTION-REQUEST---''',
        'date_updated': '1716000000000',
    }
n = {'i': 0}
def conv(email, tok):
    n['i'] += 1
    return {'id': 'CONV-%d' % n['i'], 'updated_at': 1}
mod.find_intercom_conv = conv
mod.check_admin_replied_since = lambda conv_id, merge_at, tok: False
args = types.SimpleNamespace(apply=True)
env = {'CLICKUP_API_KEY': 'k', 'MUSOAI_INTERCOM_TOKEN': 't', 'ADMIN_ID': mod.CAROLINE_ADMIN_ID}
mod._merge_outcome_notify().MERGE_OUTCOME_COPY_APPROVED = False
tagged = lambda: [u for m, u in calls if u.endswith('/task/T%s/tag/merge-outcome-notified' % n['t'])]
replied = lambda: [u for m, u in calls if u.endswith('/reply')]
resolved = lambda: [u for m, u in calls if m == 'PUT']

n['t'] = '1'; mod.get_ticket = ticket(['merge-outcome:merged'])
mod.process('T1', args, env)
assert len(replied()) == 1 and len(tagged()) == 1 and len(resolved()) == 1, calls

calls.clear(); n['t'] = '2'; fail_tag['on'] = True
mod.process('T2', args, env)
assert len(replied()) == 1 and len(tagged()) == 1 and len(resolved()) == 1, calls

calls.clear(); n['t'] = '3'; fail_tag['on'] = False; mod.get_ticket = ticket([])
mod.process('T3', args, env)
assert len(replied()) == 1 and not [u for m, u in calls if 'merge-outcome-notified' in u] and len(resolved()) == 1, calls
print('ok')
PYEOF
  run python3 "$script"
  rm -f "$script"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "ok"
}
