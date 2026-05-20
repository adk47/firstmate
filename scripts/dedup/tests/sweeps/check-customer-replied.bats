#!/usr/bin/env bats

# Pins the exit-code contract of check-customer-replied.py. close-merged-
# tickets.sh routes based on the distinction between exit 0/1/2; if a refactor
# silently inverts those, the customer-reply gate breaks and tickets either
# get closed without customer messages OR stay forever-open.
#
# We can't reach Intercom from CI, so we monkeypatch `api()` in-process via
# importlib and assert on the resulting SystemExit code.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/dedup/sweeps/check-customer-replied.py"
}

@test "exit 0 when admin reply found post-merge" {
  driver=$(mktemp)
  cat > "$driver" <<PYEOF
import sys, os
from importlib import util
os.environ['MUSOAI_INTERCOM_TOKEN'] = 'fake'
sys.argv = ['check-customer-replied.py', 'x@y.com', '2026-05-15 12:00:00 UTC']
# Cutoff = 2026-05-15 12:00 UTC -> unix ~1778846400.
spec = util.spec_from_file_location('c', '$SCRIPT')
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

calls = {'n': 0}
def fake_api(method, path, body=None, token=None):
    calls['n'] += 1
    if method == 'POST' and 'conversations/search' in path:
        return {'conversations': [{'id': 'C1', 'updated_at': 1778850000}]}
    # conv detail: admin reply AT 1778850000 > cutoff (1778846400)
    return {'conversation_parts': {'conversation_parts': [
        {'author': {'type': 'admin'}, 'created_at': 1778850000}
    ]}}
mod.api = fake_api
try:
    mod.main()
except SystemExit as e:
    print(f'exit={e.code}')
PYEOF
  run python3 "$driver"
  rm -f "$driver"
  echo "$output" | grep -qx "exit=0"
}

@test "exit 1 when admin reply only exists before merge" {
  driver=$(mktemp)
  cat > "$driver" <<PYEOF
import sys, os
from importlib import util
os.environ['MUSOAI_INTERCOM_TOKEN'] = 'fake'
sys.argv = ['check-customer-replied.py', 'x@y.com', '2026-05-15 12:00:00 UTC']
spec = util.spec_from_file_location('c', '$SCRIPT')
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

def fake_api(method, path, body=None, token=None):
    if method == 'POST' and 'conversations/search' in path:
        return {'conversations': [{'id': 'C1', 'updated_at': 1747000000}]}
    # Admin reply BEFORE the cutoff (1747000000 < 1778846400)
    return {'conversation_parts': {'conversation_parts': [
        {'author': {'type': 'admin'}, 'created_at': 1747000000}
    ]}}
mod.api = fake_api
try:
    mod.main()
except SystemExit as e:
    print(f'exit={e.code}')
PYEOF
  run python3 "$driver"
  rm -f "$driver"
  echo "$output" | grep -qx "exit=1"
}

@test "exit 2 when MUSOAI_INTERCOM_TOKEN unset" {
  run bash -c "unset MUSOAI_INTERCOM_TOKEN; python3 '$SCRIPT' x@y.com '2026-05-15 12:00:00 UTC'"
  [ "$status" -eq 2 ]
}

@test "exit 2 when Intercom search 401s (HTTPError on search)" {
  driver=$(mktemp)
  cat > "$driver" <<PYEOF
import sys, os, io, urllib.error
from importlib import util
os.environ['MUSOAI_INTERCOM_TOKEN'] = 'fake'
sys.argv = ['check-customer-replied.py', 'x@y.com', '2026-05-15 12:00:00 UTC']
spec = util.spec_from_file_location('c', '$SCRIPT')
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

def fake_api(method, path, body=None, token=None):
    raise urllib.error.HTTPError(url='x', code=401, msg='Unauthorized', hdrs=None, fp=io.BytesIO(b''))
mod.api = fake_api
try:
    mod.main()
except SystemExit as e:
    print(f'exit={e.code}')
PYEOF
  run python3 "$driver"
  rm -f "$driver"
  echo "$output" | grep -qx "exit=2"
}

@test "exit 2 when conv-detail fetch 503s on the conv carrying the admin reply" {
  # Regression: previously `except Exception: continue` swallowed the 5xx,
  # the loop ran out of candidates, and the script exited 1 — telling
  # close-merged-tickets.sh the customer wasn't told, when really we just
  # couldn't read the conv that proves they were.
  driver=$(mktemp)
  cat > "$driver" <<PYEOF
import sys, os, io, urllib.error
from importlib import util
os.environ['MUSOAI_INTERCOM_TOKEN'] = 'fake'
sys.argv = ['check-customer-replied.py', 'x@y.com', '2026-05-15 12:00:00 UTC']
spec = util.spec_from_file_location('c', '$SCRIPT')
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

def fake_api(method, path, body=None, token=None):
    if method == 'POST' and 'conversations/search' in path:
        return {'conversations': [{'id': 'C1', 'updated_at': 1747400000}]}
    raise urllib.error.HTTPError(url='x', code=503, msg='boom', hdrs=None, fp=io.BytesIO(b''))
mod.api = fake_api
try:
    mod.main()
except SystemExit as e:
    print(f'exit={e.code}')
PYEOF
  run python3 "$driver"
  rm -f "$driver"
  echo "$output" | grep -qx "exit=2"
}

@test "parses both 'YYYY-MM-DD HH:MM:SS UTC' and ISO-Z merge_at formats" {
  driver=$(mktemp)
  cat > "$driver" <<PYEOF
from importlib import util
spec = util.spec_from_file_location('c', '$SCRIPT')
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
a = mod.parse_ts('2026-05-15 12:00:00 UTC')
b = mod.parse_ts('2026-05-15T12:00:00Z')
assert a == b == 1778846400, (a, b)
print('ok')
PYEOF
  run python3 "$driver"
  rm -f "$driver"
  echo "$output" | grep -qx "ok"
}
