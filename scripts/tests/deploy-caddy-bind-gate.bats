#!/usr/bin/env bats
# scripts/deploy.sh caddy_deliver_and_gate_bind(): `gateway.bind: "loopback"`
# is only safe while Caddy is listening publicly and reverse-proxying to
# localhost. The bind lives in openclaw-*.json (which deploy.sh syncs) and the
# proxy lives in /etc/caddy/Caddyfile (which nothing deployed), so the required
# order "Caddy first, then the loopback bind" was enforced only by a PR
# description — while the REVERSE order shipped automatically on the next
# scheduled deploy and took the Control UI dark.
#
# Measured 2026-09-21: :18789 and :18810 served the Control UI to the public
# internet (HTTP 200, 18488 bytes, no WWW-Authenticate) because the live
# Caddyfile had been a 2-line `respond "MINIMAL_RESTART_OK" 200` stub since
# 2026-04-28 AND both gateways were bound to 0.0.0.0. Either alone is visible;
# together they hid an auth bypass for ~5 months.
#
# The function is extracted from deploy.sh the same way
# deploy-plugin-install-flags.bats does.
bats_require_minimum_version 1.5.0
HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DEPLOY_SH="$HYDRA_REPO/scripts/deploy.sh"

setup() {
  command -v caddy >/dev/null 2>&1 || skip "caddy not installed; the effective-route gate needs the real adapter"
  command -v jq    >/dev/null 2>&1 || skip "jq not installed"
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  awk '/^caddy_deliver_and_gate_bind\(\) \{$/,/^\}$/' "$DEPLOY_SH" > "$TEST_TMPDIR/fn.sh"
  [ -s "$TEST_TMPDIR/fn.sh" ] || { echo "extraction produced nothing — did the function move?" >&2; return 1; }
  grep -q '^}$' "$TEST_TMPDIR/fn.sh" || { echo "extraction missing the closing brace" >&2; return 1; }

  # deploy.sh's own helpers. `fail` must ABORT, like the real one, or a gate
  # that should have stopped the deploy would merely print and continue.
  log()  { echo "$*"; }
  fail() { echo "FAIL: $*"; exit 1; }
  export -f log fail 2>/dev/null || true

  # Never touch the real service. `caddy_reload` is a FUNCTION in deploy.sh
  # (not a command in a variable) because the pre-commit indirection gate
  # refuses a command word it cannot read statically -- so the seam is a
  # redefinition here rather than an env override.
  caddy_reload() { return 0; }

  DEPLOY_PATH="$TEST_TMPDIR/repo"; mkdir -p "$DEPLOY_PATH/infra/node-8"
  LIVE="$TEST_TMPDIR/Caddyfile"

  # A stubbed `caddy` that accepts by default. STUB_CADDY_INVALID makes
  # `validate` reject, which is the only way the install path can refuse.
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  # PASS-THROUGH wrapper, not a fake. `caddy adapt` must be the REAL thing:
  # the gate now asks Caddy for the effective routes, and a stub that answered
  # for it would be testing the stub. Only `validate` failure is injectable.
  REAL_CADDY="$(command -v caddy || true)"
  cat > "$STUBBIN/caddy" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "validate" ] && [ -n "\${STUB_CADDY_INVALID:-}" ]; then exit 1; fi
exec "$REAL_CADDY" "\$@"
STUB
  chmod +x "$STUBBIN/caddy"
  export PATH="$STUBBIN:$PATH"

  # shellcheck source=/dev/null
  source "$TEST_TMPDIR/fn.sh"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# _cfg <profile> <bind> <port>
_cfg() {
  local name=main; [ "$1" = edge ] && name=edge
  python3 - "$DEPLOY_PATH/openclaw-$name.json" "$2" "$3" <<'PY'
import json, sys
path, bind, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
json.dump({"gateway": {"bind": bind, "port": port}}, open(path, "w"))
PY
}

_stub_caddyfile()  { printf 'hydra.muso.ai {\n\trespond "MINIMAL_RESTART_OK" 200\n}\n' > "$LIVE"; }
_real_caddyfile()  { printf 'hydra.muso.ai {\n\treverse_proxy localhost:18789\n\treverse_proxy localhost:18810\n}\n' > "$LIVE"; }

# ── the no-op posture: this must land safely BEFORE the bind change ────────

@test "no Caddyfile in the repo and bind=lan: both halves no-op" {
  _cfg main lan 18789
  _stub_caddyfile
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to deliver"* ]]
  # The live file must be untouched — this block does not rewrite infra it
  # was not given.
  grep -q MINIMAL_RESTART_OK "$LIVE"
}

@test "bind=lan never consults Caddy at all" {
  # The gate is about a loopback bind. A lan bind is a separate (bad) state
  # that validate-config-matrix.sh owns; this block must not also fail on it,
  # or the fix could never be deployed in two steps.
  _cfg main lan 18789
  rm -f "$LIVE"
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Bind gate"* ]]
}

# ── the gate: the reverse order must be refused ────────────────────────────


@test "loopback bind with NO Caddyfile anywhere is REFUSED" {
  # Neither a live file nor a repo file: there is nothing reviewed to bind
  # behind, so the bind must not ship.
  _cfg main loopback 18789
  rm -f "$LIVE"
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no reviewed public entry point"* ]]
}









@test "TWO-RUN regression: a failed reload must not become a pass next run" {
  # QA finding on #994, and the nastiest shape. Run 1 installs the candidate
  # and the reload fails. If the candidate stayed installed, run 2 would see
  # `cmp -s` match, SKIP the reload, and then clear the bind gate off routing
  # Caddy never loaded — taking the UI dark on the retry.
  _cfg main loopback 18789
  _stub_caddyfile
  printf 'hydra.muso.ai {\n\treverse_proxy localhost:18789\n}\n' > "$DEPLOY_PATH/infra/node-8/Caddyfile"

  caddy_reload() { return 1; }
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"restored the previous file"* ]]
  # RUN 1 must have restored the stub, so run 2 cannot short-circuit.
  grep -q MINIMAL_RESTART_OK "$LIVE"

  # RUN 2, reload still failing: must fail again, never silently pass.
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 1 ]
  [[ "$output" != *"already matches the repo"* ]]

  # RUN 3, reload now works: installs and clears.
  caddy_reload() { return 0; }
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"loopback is safe"* ]]
}

@test "TWO-RUN regression: failed reload with NO PREDECESSOR removes the candidate" {
  # QA finding on #994: when $live did not exist, `backup` was empty, so a
  # failed reload left the candidate installed and the NEXT run skipped the
  # reload on byte equality. The reviewer reproduced run 2 returning success.
  _cfg main loopback 18789
  rm -f "$LIVE"
  printf 'hydra.muso.ai {\n\treverse_proxy localhost:18789\n}\n' > "$DEPLOY_PATH/infra/node-8/Caddyfile"

  caddy_reload() { return 1; }
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REMOVED"* ]]
  [ ! -f "$LIVE" ]                 # fail-closed: nothing to equality-match

  # RUN 2 with the reload still failing must fail again, not short-circuit.
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 1 ]
  [[ "$output" != *"already matches the repo"* ]]
}

@test "TWO-RUN regression: a FAILED RESTORE also leaves a fail-closed state" {
  # The other ignored branch: if restoring the backup fails, the candidate
  # must not survive to be equality-matched next run.
  _cfg main loopback 18789
  _stub_caddyfile
  printf 'hydra.muso.ai {\n\treverse_proxy localhost:18789\n}\n' > "$DEPLOY_PATH/infra/node-8/Caddyfile"

  caddy_reload() { return 1; }
  # Make the restore fail by stubbing install to refuse the restore call only.
  install() { case "$*" in *pre-deploy*) return 1 ;; esac; command install "$@"; }
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  unset -f install
  [ "$status" -eq 1 ]
  [ ! -f "$LIVE" ]                 # removed rather than left as the candidate
}


# ── delivery ordering: install happens BEFORE the gate ─────────────────────

@test "one deploy carrying BOTH the Caddyfile and the loopback bind succeeds" {
  # This is the whole point: install-then-gate means the correct order is
  # satisfied by construction, so #993 needs no manual step.
  _cfg main loopback 18789
  _stub_caddyfile
  printf 'hydra.muso.ai {\n\treverse_proxy localhost:18789\n}\n' > "$DEPLOY_PATH/infra/node-8/Caddyfile"
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed repo Caddyfile"* ]]
  [[ "$output" == *"loopback is safe"* ]]
  # and the stub is gone, with a backup kept
  ! grep -q MINIMAL_RESTART_OK "$LIVE"
  ls "$LIVE".pre-deploy-* >/dev/null
}

@test "an INVALID repo Caddyfile is refused and the live file survives" {
  _cfg main lan 18789
  _stub_caddyfile
  printf 'garbage {\n' > "$DEPLOY_PATH/infra/node-8/Caddyfile"
  STUB_CADDY_INVALID=1 run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"caddy validate rejected"* ]]
  # A rejected candidate must never have replaced a working live config.
  grep -q MINIMAL_RESTART_OK "$LIVE"
}

@test "an identical Caddyfile is not reinstalled or reloaded" {
  # Idempotence: a deploy that changes nothing must not bounce caddy.
  _cfg main lan 18789
  printf 'hydra.muso.ai {\n\treverse_proxy localhost:18789\n}\n' > "$LIVE"
  cp "$LIVE" "$DEPLOY_PATH/infra/node-8/Caddyfile"
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already matches the repo"* ]]
  ! ls "$LIVE".pre-deploy-* >/dev/null 2>&1
}

@test "a failed caddy reload fails the deploy" {
  # A silently-unreloaded Caddy is the stub state wearing a correct file.
  _cfg main lan 18789
  _stub_caddyfile
  printf 'hydra.muso.ai {\n\treverse_proxy localhost:18789\n}\n' > "$DEPLOY_PATH/infra/node-8/Caddyfile"
  caddy_reload() { return 1; }
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"caddy reload failed"* ]]
}

@test "an UNREADABLE profile config fails closed, it does not skip the gate" {
  # "We could not tell whether a loopback bind is shipping" must never read as
  # "no loopback bind is shipping".
  printf 'not json{' > "$DEPLOY_PATH/openclaw-main.json"
  _stub_caddyfile
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not read gateway.bind"* ]]
}

# -- the collapsed contract: loopback requires the REVIEWED Caddyfile --------
# Three review rounds produced six ways a Caddyfile can adapt cleanly and
# still not serve "/" (wrong site block, unimported snippet, path-scoped,
# after a terminal `respond`, non-loopback host with the right port). Each
# fix produced another evasion, so the contract changed rather than the
# implementation: `bind: loopback` is permitted only when the live Caddyfile
# is byte-identical to the repo's reviewed infra/node-8/Caddyfile.

@test "loopback is REFUSED when the repo carries no Caddyfile" {
  _cfg main loopback 18789
  _stub_caddyfile
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no reviewed public entry point"* ]]
}

@test "loopback is REFUSED when the live file differs from the repo's" {
  # The stub, a hand-edit, or a reload that did not take all land here.
  _cfg main loopback 18789
  _stub_caddyfile
  printf 'hydra.muso.ai {\n\treverse_proxy localhost:18789\n}\n' > "$DEPLOY_PATH/infra/node-8/Caddyfile"
  caddy_reload() { return 0; }
  # Make delivery a no-op so live stays the stub while the repo file exists.
  install() { case "$*" in *Caddyfile*) return 0 ;; esac; command install "$@"; }
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  unset -f install
  [ "$status" -eq 1 ]
  [[ "$output" == *"not byte-identical"* ]]
}

@test "loopback is ALLOWED once Caddy serves the reviewed repo Caddyfile" {
  _cfg main loopback 18789
  printf 'hydra.muso.ai {\n\treverse_proxy localhost:18789\n}\n' > "$DEPLOY_PATH/infra/node-8/Caddyfile"
  cp "$DEPLOY_PATH/infra/node-8/Caddyfile" "$LIVE"
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"serving the reviewed repo Caddyfile"* ]]
}

@test "one deploy carrying BOTH the Caddyfile and loopback still succeeds" {
  # Install-then-gate: delivery makes the files match, so the gate clears in
  # the SAME run. This is what lets #993 merge without a manual step.
  _cfg main loopback 18789
  _stub_caddyfile
  printf 'hydra.muso.ai {\n\treverse_proxy localhost:18789\n}\n' > "$DEPLOY_PATH/infra/node-8/Caddyfile"
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed repo Caddyfile"* ]]
  [[ "$output" == *"serving the reviewed repo Caddyfile"* ]]
}

@test "a non-loopback upstream in the REPO file is a review question, not a deploy guess" {
  # Documents the contract boundary deliberately: this file's CONTENT is
  # reviewed in git. The gate asserts identity, so a bad upstream here is
  # caught by human review of a tracked artifact rather than inferred at
  # 04:00 from whatever is on disk.
  _cfg main loopback 18789
  printf 'hydra.muso.ai {\n\treverse_proxy attacker.example:18789\n}\n' > "$DEPLOY_PATH/infra/node-8/Caddyfile"
  cp "$DEPLOY_PATH/infra/node-8/Caddyfile" "$LIVE"
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 0 ]
}

@test "equal files plus a FAILING reload must refuse the loopback deploy" {
  # QA finding on #994: byte equality on disk does not prove the running
  # process loaded it. Hand-copying the repo bytes over the live file while
  # Caddy still serves the prior stub used to skip the reload, pass the
  # identity check, and ship loopback against a stale in-memory config.
  _cfg main loopback 18789
  printf 'hydra.muso.ai {\n\treverse_proxy localhost:18789\n}\n' > "$DEPLOY_PATH/infra/node-8/Caddyfile"
  cp "$DEPLOY_PATH/infra/node-8/Caddyfile" "$LIVE"   # already identical

  caddy_reload() { return 1; }
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot prove Caddy is serving the reviewed config"* ]]
}

@test "equal files with a WORKING reload clears the gate and says it reloaded" {
  _cfg main loopback 18789
  printf 'hydra.muso.ai {\n\treverse_proxy localhost:18789\n}\n' > "$DEPLOY_PATH/infra/node-8/Caddyfile"
  cp "$DEPLOY_PATH/infra/node-8/Caddyfile" "$LIVE"
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"proven loaded"* ]]
  [[ "$output" == *"loopback is safe"* ]]
}

@test "bind=lan with an identical Caddyfile still does NOT reload (idempotence kept)" {
  # The forced reload is scoped to a loopback request only, so an ordinary
  # deploy does not bounce Caddy on every run.
  _cfg main lan 18789
  printf 'hydra.muso.ai {\n\treverse_proxy localhost:18789\n}\n' > "$DEPLOY_PATH/infra/node-8/Caddyfile"
  cp "$DEPLOY_PATH/infra/node-8/Caddyfile" "$LIVE"
  caddy_reload() { echo "RELOAD-CALLED"; return 0; }
  run caddy_deliver_and_gate_bind "$DEPLOY_PATH" "$LIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already matches the repo"* ]]
  [[ "$output" != *"RELOAD-CALLED"* ]]
}
