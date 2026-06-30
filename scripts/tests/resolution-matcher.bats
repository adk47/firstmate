#!/usr/bin/env bats

# CLI-level tests for resolution-matcher.py. The deep pure-logic + main()-flow
# coverage lives in tests/test_resolution_matcher.py (stdlib unittest); this bats
# suite locks the shell-boundary contract the unittest can't: it syntax-checks,
# runs the inline self-test, proves the env + host guards refuse cleanly, and
# proves a cold-start dry-run touches no real API and writes no state. A failing
# `muso`/`curl`/`openclaw` stub is on PATH so any accidental network/CLI call
# fails LOUD instead of hitting prod (the bats-must-stub-openclaw doctrine).

setup() {
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export MATCHER="$SCRIPTS_DIR/resolution-matcher.py"
  export STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  for cmd in muso openclaw curl; do
    cat > "$STUB_BIN/$cmd" <<STUB
#!/usr/bin/env bash
echo "STUBBED $cmd called in test — should not happen" >&2
exit 99
STUB
    chmod +x "$STUB_BIN/$cmd"
  done
  export PATH="$STUB_BIN:$PATH"
  export RESOLUTION_SKIP_HOST_GUARD=1
  export RESOLUTION_FEED_PATH="$BATS_TEST_TMPDIR/feed.jsonl"
  export RESOLUTION_STATE_PATH="$BATS_TEST_TMPDIR/state.json"
  export RESOLUTION_NOW=1782000000
}

@test "syntax-checks" {
  run python3 -m py_compile "$MATCHER"
  [ "$status" -eq 0 ]
}

@test "inline self-test passes" {
  run python3 "$MATCHER" --self-test
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "self-test ok"
}

@test "refuses to run without MUSOAI_INTERCOM_TOKEN" {
  run bash -c "unset MUSOAI_INTERCOM_TOKEN; python3 '$MATCHER' </dev/null"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "MUSOAI_INTERCOM_TOKEN is required"
}

@test "host guard refuses off ovh-node-8 (exit 0, no action)" {
  # CI bats run ON ovh-node-8, so the real hostname would PASS the guard — drive
  # main() in-process and monkeypatch gethostname so the guard actually fires
  # (mirror caroline-behavior-digest.bats). Never rely on the runner's hostname.
  run python3 - <<'PYEOF'
import os
from importlib import util
os.environ.pop("RESOLUTION_SKIP_HOST_GUARD", None)   # exercise the real guard
spec = util.spec_from_file_location("rm", os.environ["MATCHER"])
mod = util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.socket.gethostname = lambda: "some-other-host"
rc = mod.main([])
assert rc == 0, rc
print("guard-ok")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "not on ovh-node-8"
  echo "$output" | grep -qx "guard-ok"
}

@test "cold start with empty feed seeds nothing and writes no state in dry-run" {
  : > "$RESOLUTION_FEED_PATH"
  run bash -c "MUSOAI_INTERCOM_TOKEN=fake python3 '$MATCHER'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "SEEDED 0 open member"
  # dry-run must not persist state
  [ ! -f "$RESOLUTION_STATE_PATH" ]
}

@test "cold start with members sends nothing (no muso/intercom call)" {
  # one member with a cited entity; cold-start must seed + send 0 WITHOUT ever
  # shelling out to muso (the failing stub would surface as exit 99 / >0).
  printf '%s\n' '{"paged_at":1781996400,"issue_slug":"iss","title":"t","symptom":"s","members":[{"conv_id":"111","email":"a@b.com","cites":["track/78d7dcd3-3b1c-4aaa-bbbb-0123456789ab"],"age_hours":1}]}' > "$RESOLUTION_FEED_PATH"
  run bash -c "MUSOAI_INTERCOM_TOKEN=fake python3 '$MATCHER' --apply"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "SEEDED 1 open member"
}
