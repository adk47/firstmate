#!/usr/bin/env bats
# Tests for scripts/lib/jev_shadow.py, the shared shadow_judge() wrapper the
# five Phase-2a support-timer scripts use. Hermetic: JEV_SH is pointed at a
# fake jev.sh (scripts/tests/fixtures/jev/fake-jev-sh.sh, mode selected via
# JEV_SHADOW_FAKE_MODE) so no real jev.sh / network / API key is involved.
# Each test loads the module fresh via importlib (module-level counters
# like _call_count must not leak between tests).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
JEV_SHADOW_PY="$HYDRA_REPO/scripts/lib/jev_shadow.py"
FAKE_JEV="$HYDRA_REPO/scripts/tests/fixtures/jev/fake-jev-sh.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  export JEV_SHADOW_PY FAKE_JEV
  export JEV_SH="$FAKE_JEV"
  export FAKE_JEV_CALL_MARKER="$TEST_TMPDIR/calls.log"
  unset JEV_SHADOW_MAX_CALLS || true
}

@test "syntax-checks" {
  run python3 -m py_compile "$JEV_SHADOW_PY"
  [ "$status" -eq 0 ]
}

@test "success: returns the answers dict, writes nothing to stdout" {
  export JEV_SHADOW_FAKE_MODE=ok
  run python3 - <<'PYEOF'
import io, os, sys
from importlib import util
spec = util.spec_from_file_location('jev_shadow', os.environ['JEV_SHADOW_PY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

captured = io.StringIO()
real_stdout = sys.stdout
sys.stdout = captured
try:
    result = mod.shadow_judge("resolve-notify", "conv1", {"foo": "bar"},
                               {"q1": {"type": "noul"}}, actual="sent")
finally:
    sys.stdout = real_stdout

assert captured.getvalue() == "", repr(captured.getvalue())
assert result == {"q1": {"answer": True, "probability": 0.9}}, result
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "success: forwards --actual on the fake jev.sh argv" {
  export JEV_SHADOW_FAKE_MODE=ok
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('jev_shadow', os.environ['JEV_SHADOW_PY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.shadow_judge("resolve-notify", "conv42", {}, {}, actual="suppressed:already-sent")
with open(os.environ['FAKE_JEV_CALL_MARKER']) as f:
    line = f.read()
assert "--actual suppressed:already-sent" in line, line
assert "--surface resolve-notify" in line, line
assert "--item-id conv42" in line, line
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "rc2 (failure exit): returns None, writes nothing to stdout" {
  export JEV_SHADOW_FAKE_MODE=rc2
  run python3 - <<'PYEOF'
import io, os, sys
from importlib import util
spec = util.spec_from_file_location('jev_shadow', os.environ['JEV_SHADOW_PY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

captured = io.StringIO()
real_stdout = sys.stdout
sys.stdout = captured
try:
    result = mod.shadow_judge("resolve-notify", "c1", {}, {})
finally:
    sys.stdout = real_stdout

assert captured.getvalue() == "", repr(captured.getvalue())
assert result is None, result
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "badjson stdout: returns None rather than raising" {
  export JEV_SHADOW_FAKE_MODE=badjson
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('jev_shadow', os.environ['JEV_SHADOW_PY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
result = mod.shadow_judge("resolve-notify", "c1", {}, {})
assert result is None, result
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "hang past timeout: returns None promptly (timeout_s honoured, does not block ~30s)" {
  export JEV_SHADOW_FAKE_MODE=hang
  run python3 - <<'PYEOF'
import os, time
from importlib import util
spec = util.spec_from_file_location('jev_shadow', os.environ['JEV_SHADOW_PY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
start = time.monotonic()
result = mod.shadow_judge("resolve-notify", "c1", {}, {}, timeout_s=1)
elapsed = time.monotonic() - start
assert result is None, result
assert elapsed < 10, elapsed
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "missing jev.sh: returns None rather than raising" {
  export JEV_SH="$TEST_TMPDIR/no-such-jev.sh"
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('jev_shadow', os.environ['JEV_SHADOW_PY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
result = mod.shadow_judge("resolve-notify", "c1", {}, {})
assert result is None, result
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "never raises: unserializable state is caught, not thrown" {
  export JEV_SHADOW_FAKE_MODE=ok
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('jev_shadow', os.environ['JEV_SHADOW_PY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

class Unserializable:
    pass

try:
    result = mod.shadow_judge("resolve-notify", "c1", {"bad": Unserializable()}, {})
except Exception as e:
    print("RAISED:", type(e).__name__, e)
    raise SystemExit(1)
assert result is None, result
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "budget: calls past JEV_SHADOW_MAX_CALLS are skipped and counted, one warn line on first skip" {
  export JEV_SHADOW_FAKE_MODE=ok
  export JEV_SHADOW_MAX_CALLS=2
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('jev_shadow', os.environ['JEV_SHADOW_PY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

r1 = mod.shadow_judge("resolve-notify", "c1", {}, {})
r2 = mod.shadow_judge("resolve-notify", "c2", {}, {})
r3 = mod.shadow_judge("resolve-notify", "c3", {}, {})
assert r1 is not None and r2 is not None, (r1, r2)
assert r3 is None, r3
assert mod._call_count == 2, mod._call_count
assert mod._skip_count == 1, mod._skip_count
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
  # Only 2 real invocations of the fake jev.sh happened (3rd was skipped, not attempted).
  [ "$(wc -l < "$FAKE_JEV_CALL_MARKER" | tr -d ' ')" -eq 2 ]
}

@test "exit summary: prints a skip summary on stderr at atexit when anything was skipped" {
  export JEV_SHADOW_FAKE_MODE=ok
  export JEV_SHADOW_MAX_CALLS=1
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('jev_shadow', os.environ['JEV_SHADOW_PY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.shadow_judge("resolve-notify", "c1", {}, {})
mod.shadow_judge("resolve-notify", "c2", {}, {})
mod._print_exit_summary()
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "1 call(s) made, 1 skipped"
}

@test "build_state: a callable state that raises is caught, returns None, and counts against budget" {
  export JEV_SHADOW_FAKE_MODE=ok
  export JEV_SHADOW_MAX_CALLS=1
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('jev_shadow', os.environ['JEV_SHADOW_PY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)

def boom():
    raise ConnectionResetError("simulated GET failure building state")

try:
    result = mod.shadow_judge("resolve-notify", "c1", boom, {})
except Exception as e:
    print("RAISED:", type(e).__name__, e)
    raise SystemExit(1)
assert result is None, result

# The raising build_state call still claimed the one budget slot (MAX_CALLS=1):
# a second call, even with a perfectly good dict state, must be skipped.
second = mod.shadow_judge("resolve-notify", "c2", {"ok": True}, {})
assert second is None, second
assert mod._skip_count == 1, mod._skip_count
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}

@test "build_state: a plain dict state still works (callable is optional, not required)" {
  export JEV_SHADOW_FAKE_MODE=ok
  run python3 - <<'PYEOF'
import os
from importlib import util
spec = util.spec_from_file_location('jev_shadow', os.environ['JEV_SHADOW_PY'])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
result = mod.shadow_judge("resolve-notify", "c1", {"plain": "dict"}, {})
assert result == {"q1": {"answer": True, "probability": 0.9}}, result
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ok
}
