#!/usr/bin/env bats
# Tests for scripts/downgrade-openclaw-runtime.sh — the manual runtime rollback
# helper, specifically its 2026.8+ -> 2026.7.1 path (QA finding, PR #899):
#   - an auto-selected 8.x rollback must REFUSE unless the operator restores the
#     pre-8.1 archive before any restart (--state-archive) or takes the restart
#     away from the helper (--no-restart);
#   - --no-restart must downgrade binary + plugins and leave gateways STOPPED
#     (no start, no smoke);
#   - the interactive confirmation must abort when fed a here-doc line (the
#     exact way the runbook used to invoke it) and be skipped by --yes.
# Every external effect is PATH-shadowed (hostname, systemctl, npm, openclaw)
# and the script's sibling helpers (smoke-test.sh, lib/ensure-codex-auth.sh)
# are replaced by recorders in a private copy of the scripts dir.
bats_require_minimum_version 1.5.0
HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/scripts/lib" "$TEST_TMPDIR/sanity" "$TEST_TMPDIR/restore-root"
  cp "$HYDRA_REPO/scripts/downgrade-openclaw-runtime.sh" "$TEST_TMPDIR/scripts/"
  cp "$HYDRA_REPO/scripts/lib/version-compare.sh" "$TEST_TMPDIR/scripts/lib/"
  CALLS="$TEST_TMPDIR/calls"; export CALLS
  rec() { # <name> — a recorder stub on PATH or in the scripts dir
    cat > "$1" <<'STUB'
#!/bin/bash
echo "$(basename "$0") $*" >> "$CALLS"
STUB
    chmod +x "$1"
  }
  rec "$TEST_TMPDIR/scripts/smoke-test.sh"
  rec "$TEST_TMPDIR/scripts/lib/ensure-codex-auth.sh"
  rec "$TEST_TMPDIR/bin/systemctl"
  rec "$TEST_TMPDIR/bin/npm"
  printf '#!/bin/bash\necho node-8\n' > "$TEST_TMPDIR/bin/hostname"; chmod +x "$TEST_TMPDIR/bin/hostname"
  # openclaw stub: --version reports the INSTALLED version; after `npm install -g`
  # has been recorded it reports the target (the script re-reads it).
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
echo "openclaw $*" >> "$CALLS"
if [ "$1" = "--version" ]; then
  if grep -q "npm install -g openclaw@" "$CALLS" 2>/dev/null; then
    v=$(grep -o "npm install -g openclaw@[0-9.]*" "$CALLS" | tail -1 | sed 's/.*@//'); echo "OpenClaw $v (test)"
  elif [ -n "${FAKE_OPENCLAW_VERSION_LINE+x}" ]; then printf '%s\n' "$FAKE_OPENCLAW_VERSION_LINE"
  else echo "OpenClaw ${FAKE_OPENCLAW_VERSION:-2026.8.2} (test)"; fi
  exit 0
fi
# plugins install: ENFORCE the real CLI contract, so a missing/extra flag is a
# refusal here exactly as it is on the box — 2026.8+ refuses an install without
# --accept-capabilities; 7.x rejects the option as unknown.
case " $* " in *" plugins install "*)
  v=$(printf '%s\n' "$@" | grep -oE '@openclaw/[a-z]+@[0-9.]+' | sed 's/.*@//')
  major=${v%%.*}; minor=$(echo "$v" | cut -d. -f2)
  if [ "$major" -gt 2026 ] || { [ "$major" -eq 2026 ] && [ "$minor" -ge 8 ]; }; then
    case " $* " in *" --accept-capabilities "*) ;; *) echo "error: plugin declares capabilities; pass --accept-capabilities to acknowledge" >&2; exit 1;; esac
  else
    case " $* " in *" --accept-capabilities "*) echo "error: unknown option '--accept-capabilities'" >&2; exit 1;; esac
  fi
  # a real install lands a plugin tree INSIDE the profile state dir; mirror that so the
  # tests can see whether a later state-dir swap wiped it
  prof=$2; pkg=$(printf '%s\n' "$@" | grep -oE '@openclaw/[a-z]+' | head -1 | sed 's|@openclaw/||')
  root="${DOWNGRADE_RESTORE_ROOT:-/}/.openclaw-$prof/npm/projects"
  # --force REPLACES the registered tree for this package (openclaw drops the superseded generation)
  [ -d "$root" ] && find "$root" -maxdepth 1 -type d -name "openclaw-$pkg-*" -exec rm -rf {} +
  d="$root/openclaw-$pkg-test/node_modules/@openclaw/$pkg"
  mkdir -p "$d" && printf '{"name":"@openclaw/%s","version":"%s"}\n' "$pkg" "$v" > "$d/package.json"
  exit 0;;
esac
# plugins list --json: report whatever version was last installed for that pkg
case " $* " in *" plugins list "*)
  v=$(grep -o "plugins install @openclaw/[a-z]*@[0-9.]*" "$CALLS" | tail -1 | sed 's/.*@//')
  echo "{\"plugins\":[{\"id\":\"slack\",\"version\":\"$v\"},{\"id\":\"codex\",\"version\":\"$v\"}]}"; exit 0;;
esac
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
  export DOWNGRADE_SANITY_DIR="$TEST_TMPDIR/sanity" DOWNGRADE_RESTORE_ROOT="$TEST_TMPDIR/restore-root"
  unset CI GITHUB_ACTIONS HYDRA_AUTO_ROLLBACK
  SCRIPT="$TEST_TMPDIR/scripts/downgrade-openclaw-runtime.sh"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "auto 2026.8+ -> 7.1 rollback REFUSES without --state-archive or --no-restart, before touching anything" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  run "$SCRIPT" --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires --state-archive"* ]]
  [[ "$output" == *"--no-restart"* ]]
  if grep -qE "^(systemctl|npm) " "$CALLS" 2>/dev/null; then echo "NEGATED ASSERTION FAILED: grep -qE '^(systemctl|npm) ' '$CALLS' 2>/dev/null" >&2; false; fi
}

seed_restored_71_tree() { # <profile> — a restored pre-8.1 tree: a state DB WITHOUT the 2.0 cell table
  mkdir -p "$TEST_TMPDIR/restore-root/.openclaw-$1/state"
  node --experimental-sqlite --no-warnings -e 'const {DatabaseSync}=require("node:sqlite"); new DatabaseSync(process.argv[1]).exec("CREATE TABLE cron_jobs (id TEXT PRIMARY KEY)")' "$TEST_TMPDIR/restore-root/.openclaw-$1/state/openclaw.sqlite"
}

@test "--yes --no-restart: downgrades binary + lockstep plugins to 2026.7.1, leaves gateways STOPPED, no smoke" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  seed_restored_71_tree main; seed_restored_71_tree edge
  run "$SCRIPT" --yes --no-restart
  [ "$status" -eq 0 ]
  grep -q "^npm install -g openclaw@2026.7.1" "$CALLS"
  grep -qE "^openclaw --profile main plugins install @openclaw/slack@2026.7.1 --force --pin$" "$CALLS"
  grep -qE "^openclaw --profile main plugins install @openclaw/codex@2026.7.1 --force --pin$" "$CALLS"
  if grep -q "accept-capabilities" "$CALLS"; then echo "NEGATED ASSERTION FAILED: grep -q 'accept-capabilities' '$CALLS'" >&2; false; fi
  grep -q "^systemctl stop openclaw-gateway-main" "$CALLS"
  if grep -q "^systemctl start" "$CALLS"; then echo "NEGATED ASSERTION FAILED: grep -q '^systemctl start' '$CALLS'" >&2; false; fi
  if grep -q "^smoke-test.sh" "$CALLS"; then echo "NEGATED ASSERTION FAILED: grep -q '^smoke-test.sh' '$CALLS'" >&2; false; fi
  [[ "$output" == *"gateways left STOPPED"* ]]
}

@test "the runbook's old shape (no --yes, stdin is a here-doc line) aborts at the prompt and changes nothing" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  seed_restored_71_tree main; seed_restored_71_tree edge   # so the run reaches the PROMPT (the restore gate passes)
  run bash -c "printf 'systemctl start openclaw-gateway-main\n' | '$SCRIPT' --no-restart"
  [ "$status" -eq 1 ]
  [[ "$output" == *"aborted by operator"* ]]
  if grep -qE "^(systemctl|npm) " "$CALLS" 2>/dev/null; then echo "NEGATED ASSERTION FAILED: grep -qE '^(systemctl|npm) ' '$CALLS' 2>/dev/null" >&2; false; fi
}

@test "--state-archive path: stop -> downgrade -> restore -> start -> smoke, in that order" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  for d in .openclaw-main .openclaw-edge; do
    mkdir -p "$TEST_TMPDIR/src/$d/agents"; echo '{"pre":"8.1"}' > "$TEST_TMPDIR/src/$d/openclaw.json"
    # the archive carries the FORMER plugin trees (a stale generation) — a restore after the
    # plugin pin would silently put these back in place of the freshly pinned ones
    for pkg in slack codex; do mkdir -p "$TEST_TMPDIR/src/$d/npm/projects/openclaw-$pkg-old/node_modules/@openclaw/$pkg"; printf '{"name":"@openclaw/%s","version":"2026.5.27"}\n' "$pkg" > "$TEST_TMPDIR/src/$d/npm/projects/openclaw-$pkg-old/node_modules/@openclaw/$pkg/package.json"; done
  done
  tar -C "$TEST_TMPDIR/src" -czf "$TEST_TMPDIR/pre81.tgz" .openclaw-main .openclaw-edge
  # the LIVE tree is 2026.8-migrated: files the archive never contained must NOT survive
  for d in .openclaw-main .openclaw-edge; do mkdir -p "$TEST_TMPDIR/restore-root/$d/state"; echo migrated > "$TEST_TMPDIR/restore-root/$d/state/openclaw.sqlite"; echo x > "$TEST_TMPDIR/restore-root/$d/MIGRATED-8.2"; done
  run "$SCRIPT" --yes --state-archive "$TEST_TMPDIR/pre81.tgz"
  [ "$status" -eq 0 ]
  for d in .openclaw-main .openclaw-edge; do
    grep -q '"pre":"8.1"' "$TEST_TMPDIR/restore-root/$d/openclaw.json"
    [ ! -e "$TEST_TMPDIR/restore-root/$d/MIGRATED-8.2" ]
    [ ! -e "$TEST_TMPDIR/restore-root/$d/state/openclaw.sqlite" ]
    # the plugins pinned by this run must be the ones ON DISK after the swap — the
    # archive's stale 2026.5.27 trees must not have survived over them
    for pkg in slack codex; do
      f=$(find "$TEST_TMPDIR/restore-root/$d/npm" -path "*@openclaw/$pkg/package.json" -print -quit)
      [ -n "$f" ] && grep -q '"version":"2026.7.1"' "$f"
      if grep -rq '"version":"2026.5.27"' "$TEST_TMPDIR/restore-root/$d/npm"; then echo "NEGATED ASSERTION FAILED: grep -rq ''version':'2026.5.27'' '$TEST_TMPDIR/restore-root/$d/npm'" >&2; false; fi
    done
  done
  [ -z "$(ls -d "$TEST_TMPDIR"/restore-root/pre81-restore.* 2>/dev/null)" ]   # temp root cleaned
  # order: the restore must land before any start
  stop_ln=$(grep -n "^systemctl stop openclaw-gateway-main" "$CALLS" | head -1 | cut -d: -f1)
  npm_ln=$(grep -n "^npm install -g" "$CALLS" | head -1 | cut -d: -f1)
  start_ln=$(grep -n "^systemctl start openclaw-gateway-main" "$CALLS" | head -1 | cut -d: -f1)
  smoke_ln=$(grep -n "^smoke-test.sh" "$CALLS" | head -1 | cut -d: -f1)
  [ "$stop_ln" -lt "$npm_ln" ] && [ "$npm_ln" -lt "$start_ln" ] && [ "$start_ln" -lt "$smoke_ln" ]
}

@test "explicit --to below 2026.8 on a 7.x runtime keeps the old behaviour (no archive required)" {
  export FAKE_OPENCLAW_VERSION="2026.7.1"
  run "$SCRIPT" --to 2026.5.27 --yes
  [ "$status" -eq 0 ]
  grep -q "^npm install -g openclaw@2026.5.27" "$CALLS"
  grep -q "^systemctl start openclaw-gateway-main" "$CALLS"
}

# ── QA round 5: the refusal must key on (source, destination), not on auto-selection ──

@test "explicit --to 2026.7.1 from a 2026.8.x runtime REFUSES without --state-archive/--no-restart (no bypass)" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  run "$SCRIPT" --to 2026.7.1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires --state-archive"* ]]
  if grep -qE "^(systemctl|npm) " "$CALLS" 2>/dev/null; then echo "NEGATED ASSERTION FAILED: grep -qE '^(systemctl|npm) ' '$CALLS' 2>/dev/null" >&2; false; fi
}

@test "explicit --to 2026.5.27 from a 2026.8.x runtime also REFUSES (any destination below 2026.8)" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  run "$SCRIPT" --to 2026.5.27 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires --state-archive"* ]]
}

@test "explicit --to 2026.7.1 from 2026.8.x WITH --no-restart proceeds (binary + plugins only)" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  seed_restored_71_tree main; seed_restored_71_tree edge
  run "$SCRIPT" --to 2026.7.1 --yes --no-restart
  [ "$status" -eq 0 ]
  grep -q "^npm install -g openclaw@2026.7.1" "$CALLS"
  if grep -q "^systemctl start" "$CALLS"; then echo "NEGATED ASSERTION FAILED: grep -q '^systemctl start' '$CALLS'" >&2; false; fi
}

@test "an 8.x -> 8.x move (--to 2026.8.1 from 2026.8.2) is NOT a 2.0 rollback and needs no archive" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  run "$SCRIPT" --to 2026.8.1 --yes
  [ "$status" -eq 0 ]
  grep -q "^npm install -g openclaw@2026.8.1" "$CALLS"
  # an 8.x CLI REFUSES the install without the capability ack: the exact argv must carry it
  for pkg in slack codex; do for p in main edge; do
    grep -qE "^openclaw --profile $p plugins install @openclaw/$pkg@2026.8.1 --force --pin --accept-capabilities$" "$CALLS"
  done; done
  grep -q "^systemctl start openclaw-gateway-main" "$CALLS"
}

# ── MUS-5212: intra-8.x state-schema boundary (2026.8.35 mutates shared state) ──

@test "8.35 -> 8.2 REFUSES without --state-archive/--no-restart and names the 2026.8.35 boundary, before touching anything" {
  export FAKE_OPENCLAW_VERSION="2026.8.35"
  run "$SCRIPT" --to 2026.8.2 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires --state-archive"* ]]
  [[ "$output" == *"2026.8.35"* ]]
  if grep -qE "^(systemctl|npm) " "$CALLS" 2>/dev/null; then echo "NEGATED ASSERTION FAILED: grep -qE '^(systemctl|npm) ' '$CALLS' 2>/dev/null" >&2; false; fi
}

@test "8.35 -> 8.2 with --no-restart still REFUSES: no probe can prove a tree is pre-8.35, so only --state-archive satisfies it; no mutation" {
  export FAKE_OPENCLAW_VERSION="2026.8.35"
  run "$SCRIPT" --to 2026.8.2 --yes --no-restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires --state-archive"* ]]
  [[ "$output" == *"2026.8.35"* ]]
  if grep -qE "^(systemctl|npm) " "$CALLS" 2>/dev/null; then echo "NEGATED ASSERTION FAILED: grep -qE '^(systemctl|npm) ' '$CALLS' 2>/dev/null" >&2; false; fi
}

@test "8.35 -> 8.2 with --state-archive satisfies the guard (reaches the archive preflight, not the refusal)" {
  export FAKE_OPENCLAW_VERSION="2026.8.35"
  run "$SCRIPT" --to 2026.8.2 --yes --state-archive "$TEST_TMPDIR/no-such-archive.tgz"
  [[ "$output" != *"requires --state-archive"* ]]
  [[ "$output" == *"state-archive not found"* ]]
}

@test "8.35 -> 7.1 still REFUSES (the 2.0 boundary is unchanged)" {
  export FAKE_OPENCLAW_VERSION="2026.8.35"
  run "$SCRIPT" --to 2026.7.1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"rolling back from a 2026.8+ runtime requires --state-archive <pre-8.1 cold archive>"* ]]
}

@test "8.2 -> 8.2 is not a downgrade across any boundary and needs no archive" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  run "$SCRIPT" --to 2026.8.2 --yes
  [ "$status" -eq 0 ]
  grep -q "^systemctl start openclaw-gateway-main" "$CALLS"
}

@test "a FORWARD move 8.2 -> 8.35 is not guarded (the guard is for downgrades only)" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  run "$SCRIPT" --to 2026.8.35 --yes
  [ "$status" -eq 0 ]
  grep -q "^npm install -g openclaw@2026.8.35" "$CALLS"
}

@test "8.36 -> 8.35 stays on the same side of every boundary and needs no archive" {
  export FAKE_OPENCLAW_VERSION="2026.8.36"
  run "$SCRIPT" --to 2026.8.35 --yes
  [ "$status" -eq 0 ]
}

# ── QA round 9 ───────────────────────────────────────────────────────────────

@test "EMPTY openclaw --version: refuses before choosing a target; no npm/systemctl mutation" {
  export FAKE_OPENCLAW_VERSION_LINE=""
  run "$SCRIPT" --to 2026.7.1 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot determine the installed openclaw version"* ]]
  if grep -qE "^(systemctl|npm) " "$CALLS" 2>/dev/null; then echo "NEGATED ASSERTION FAILED: grep -qE '^(systemctl|npm) ' '$CALLS' 2>/dev/null" >&2; false; fi
}

@test "GARBAGE openclaw --version: refuses even with --yes --no-restart (an unidentified runtime is not a 7.x runtime)" {
  export FAKE_OPENCLAW_VERSION_LINE="OpenClaw banana (broken)"
  run "$SCRIPT" --yes --no-restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot determine the installed openclaw version"* ]]
  if grep -qE "^(systemctl|npm) " "$CALLS" 2>/dev/null; then echo "NEGATED ASSERTION FAILED: grep -qE '^(systemctl|npm) ' '$CALLS' 2>/dev/null" >&2; false; fi
}

@test "--state-archive REFUSES an archive missing a targeted profile tree, and leaves the live tree untouched" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  mkdir -p "$TEST_TMPDIR/src/.openclaw-main/agents"; echo '{"pre":"8.1"}' > "$TEST_TMPDIR/src/.openclaw-main/openclaw.json"
  tar -C "$TEST_TMPDIR/src" -czf "$TEST_TMPDIR/main-only.tgz" .openclaw-main
  mkdir -p "$TEST_TMPDIR/restore-root/.openclaw-edge"; echo live > "$TEST_TMPDIR/restore-root/.openclaw-edge/LIVE"
  run "$SCRIPT" --yes --state-archive "$TEST_TMPDIR/main-only.tgz"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no usable .openclaw-edge tree"* ]]
  [[ "$output" == *"the fleet is untouched"* ]]
  [ -e "$TEST_TMPDIR/restore-root/.openclaw-edge/LIVE" ]
  if grep -qE "^(npm|systemctl) " "$CALLS" 2>/dev/null; then echo "mutation recorded before preflight refusal" >&2; false; fi
  if grep -q "^systemctl start" "$CALLS"; then echo "NEGATED ASSERTION FAILED: grep -q '^systemctl start' '$CALLS'" >&2; false; fi
}

# ── QA round 13: --no-restart must not pin plugins into a tree the caller will replace ──

seed_live_82_tree() { # <profile> — a 2.0-migrated live tree (carries the shared-auth cell table)
  mkdir -p "$TEST_TMPDIR/restore-root/.openclaw-$1/state"
  node --experimental-sqlite --no-warnings -e '
    const {DatabaseSync}=require("node:sqlite"); const db=new DatabaseSync(process.argv[1]);
    db.exec("CREATE TABLE config_machine_state (state_key TEXT PRIMARY KEY, value_json TEXT, updated_at_ms INTEGER)");' \
    "$TEST_TMPDIR/restore-root/.openclaw-$1/state/openclaw.sqlite"
}

@test "--no-restart on a still-migrated 8.x tree REFUSES before any mutation (state must be restored first)" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  seed_live_82_tree main; seed_live_82_tree edge
  run "$SCRIPT" --to 2026.5.27 --yes --no-restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires the pre-8.1 state to be restored BEFORE"* ]]
  if grep -qE "^(npm|systemctl) " "$CALLS" 2>/dev/null; then echo "NEGATED ASSERTION FAILED: grep -qE '^(npm|systemctl) ' '$CALLS' 2>/dev/null" >&2; false; fi
  if grep -q "plugins install" "$CALLS" 2>/dev/null; then echo "NEGATED ASSERTION FAILED: grep -q 'plugins install' '$CALLS' 2>/dev/null" >&2; false; fi
}

@test "documented flow: archive restored FIRST, then --no-restart pins plugins INTO the restored tree (on-disk versions are the target)" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  # the operator's restore (runbook Rollback block): pre-8.1 trees with the FORMER plugin generation
  for d in .openclaw-main .openclaw-edge; do
    mkdir -p "$TEST_TMPDIR/restore-root/$d/agents/main/sessions" "$TEST_TMPDIR/restore-root/$d/state"; echo '{"pre":"8.1"}' > "$TEST_TMPDIR/restore-root/$d/openclaw.json"; echo '{}' > "$TEST_TMPDIR/restore-root/$d/agents/main/sessions/sessions.json"
    node --experimental-sqlite --no-warnings -e 'const {DatabaseSync}=require("node:sqlite"); new DatabaseSync(process.argv[1]).exec("CREATE TABLE cron_jobs (id TEXT PRIMARY KEY)")' "$TEST_TMPDIR/restore-root/$d/state/openclaw.sqlite"   # a 7.1-shaped DB: no 2.0 cell table
    for pkg in slack codex; do mkdir -p "$TEST_TMPDIR/restore-root/$d/npm/projects/openclaw-$pkg-old/node_modules/@openclaw/$pkg"; printf '{"name":"@openclaw/%s","version":"2026.7.1"}\n' "$pkg" > "$TEST_TMPDIR/restore-root/$d/npm/projects/openclaw-$pkg-old/node_modules/@openclaw/$pkg/package.json"; done
  done
  run "$SCRIPT" --to 2026.5.27 --yes --no-restart
  [ "$status" -eq 0 ]
  [[ "$output" == *"Do NOT restore state after this point"* ]]
  for d in .openclaw-main .openclaw-edge; do for pkg in slack codex; do
    f=$(find "$TEST_TMPDIR/restore-root/$d/npm" -path "*@openclaw/$pkg/package.json" -print -quit)
    [ -n "$f" ] && grep -q '"version":"2026.5.27"' "$f"
    if grep -rq '"version":"2026.7.1"' "$TEST_TMPDIR/restore-root/$d/npm"; then echo "NEGATED ASSERTION FAILED: grep -rq ''version':'2026.7.1'' '$TEST_TMPDIR/restore-root/$d/npm'" >&2; false; fi
  done; done
  if grep -q "^systemctl start" "$CALLS"; then echo "NEGATED ASSERTION FAILED: grep -q '^systemctl start' '$CALLS'" >&2; false; fi
}

# ── QA round 14 ──────────────────────────────────────────────────────────────

@test "--no-restart with a CORRUPT/unreadable live state DB refuses (unverifiable is not restored); no mutation" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  for d in .openclaw-main .openclaw-edge; do mkdir -p "$TEST_TMPDIR/restore-root/$d/state"; head -c 4096 /dev/urandom > "$TEST_TMPDIR/restore-root/$d/state/openclaw.sqlite"; done
  run "$SCRIPT" --to 2026.7.1 --yes --no-restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"unreadable/corrupt"* ]]
  if grep -qE "^(npm|systemctl) " "$CALLS" 2>/dev/null; then echo "mutation recorded" >&2; false; fi
}

@test "--state-archive: a TRUNCATED archive refuses in preflight — gateways never stopped, npm never called" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  mkdir -p "$TEST_TMPDIR/src/.openclaw-main/agents"; echo '{"pre":"8.1"}' > "$TEST_TMPDIR/src/.openclaw-main/openclaw.json"
  tar -C "$TEST_TMPDIR/src" -czf "$TEST_TMPDIR/full.tgz" .openclaw-main
  head -c 100 "$TEST_TMPDIR/full.tgz" > "$TEST_TMPDIR/truncated.tgz"
  run "$SCRIPT" --yes --state-archive "$TEST_TMPDIR/truncated.tgz"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not extract"* ]]
  if grep -qE "^(npm|systemctl) " "$CALLS" 2>/dev/null; then echo "mutation recorded" >&2; false; fi
  [ -z "$(ls -d "$TEST_TMPDIR"/restore-root/pre81-restore.* 2>/dev/null)" ]
}

@test "--no-restart with NO state DB at all refuses (a missing DB is not proof of a restore); no mutation" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  mkdir -p "$TEST_TMPDIR/restore-root/.openclaw-main" "$TEST_TMPDIR/restore-root/.openclaw-edge"
  run "$SCRIPT" --to 2026.7.1 --yes --no-restart
  [ "$status" -eq 1 ]
  [[ "$output" == *"has NO state/openclaw.sqlite"* ]]
  if grep -qE "^(npm|systemctl) " "$CALLS" 2>/dev/null; then echo "mutation recorded" >&2; false; fi
}
