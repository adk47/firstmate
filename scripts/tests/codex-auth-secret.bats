#!/usr/bin/env bats
# Tests for scripts/codex-auth-secret.sh — the qa-review-gateway's codex auth
# carrier (node8-to-pods T9). Fixtures are REAL node:sqlite cells with the live
# 2026.8 schema; `openclaw --version` and `kubectl` are PATH stubs, so no test
# can touch a live gateway, a live cell or the cluster.
#
# The load-bearing property is the single-refresher invariant: a REAL refresh
# token must never reach the exported file, the Secret, or a pod's cell. Each
# guard has a mutation case below that proves the guard is what holds it.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/codex-auth-secret.sh"
SENTINEL="SYNC-MANAGED-NO-REFRESH-TOKEN"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export CODEX_AUTH_ROOT="$TEST_TMPDIR/root"
  mkdir -p "$CODEX_AUTH_ROOT/.openclaw-main/state" "$TEST_TMPDIR/bin" "$TEST_TMPDIR/pod/state"
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
if [ "$1" = "--version" ]; then echo "OpenClaw 2026.8.35 (test)"; exit 0; fi
echo "test stub: unexpected openclaw call ($*)" >&2; exit 99
STUB
  # kubectl stub: `create ... --dry-run` renders a fake manifest from the file it
  # was given (so the test can scan what would be applied); `label --local` and
  # `apply` copy stdin to $KUBE_APPLIED and record argv.
  export KUBE_ARGV="$TEST_TMPDIR/kube-argv" KUBE_APPLIED="$TEST_TMPDIR/kube-applied"
  cat > "$TEST_TMPDIR/bin/kubectl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$KUBE_ARGV"
case " $* " in
  *" create secret generic "*)
    for a in "$@"; do case "$a" in --from-file=*) f="${a#--from-file=}"; f="${f#*=}";; esac; done
    printf 'kind: Secret\ndata:\n  auth-profiles.store.json: %s\n' "$(base64 < "$f" | tr -d '\n')" ;;
  *" label "*) cat ;;
  *" apply "*) [ -n "${STUB_APPLY_FAIL:-}" ] && exit 1; cat > "$KUBE_APPLIED" ;;
esac
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw" "$TEST_TMPDIR/bin/kubectl"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/maintenance-flag"
  export CODEX_AUTH_SECRET_MIN_TOKEN_MIN=1440
  create_db "$CODEX_AUTH_ROOT/.openclaw-main/state/openclaw.sqlite"
  seed_main
}
teardown() { rm -rf "$TEST_TMPDIR"; }

jwt() {  # jwt <accountId> [exp-epoch-s]
  local hdr payload
  hdr="$(printf '{"alg":"RS256","typ":"JWT"}' | base64 | tr '+/' '-_' | tr -d '=\n')"
  payload="$(printf '{"https://api.openai.com/auth":{"chatgpt_account_id":"%s"},"exp":%s}' "$1" "${2:-4102444800}" | base64 | tr '+/' '-_' | tr -d '=\n')"
  printf '%s.%s.sig' "$hdr" "$payload"
}
create_db() {
  node --experimental-sqlite --no-warnings -e '
    const {DatabaseSync}=require("node:sqlite"); const db=new DatabaseSync(process.argv[1]);
    if (process.argv[2] !== "notable") db.exec("CREATE TABLE config_machine_state (state_key TEXT NOT NULL PRIMARY KEY, value_json TEXT NOT NULL, updated_at_ms INTEGER NOT NULL) STRICT");
    db.exec("create table if not exists other_table (k TEXT)");' "$1" "${2:-table}"
}
set_row() {  # set_row <db> <key> <json>
  node --experimental-sqlite --no-warnings -e '
    const {DatabaseSync}=require("node:sqlite"); const db=new DatabaseSync(process.argv[1]);
    db.prepare("insert into config_machine_state values (?,?,?) on conflict(state_key) do update set value_json=excluded.value_json").run(process.argv[2], process.argv[3], 1);' "$1" "$2" "$3"
}
read_row() {
  node --experimental-sqlite --no-warnings -e '
    const {DatabaseSync}=require("node:sqlite"); const db=new DatabaseSync(process.argv[1],{readOnly:true});
    const r=db.prepare("select value_json from config_machine_state where state_key=?").get(process.argv[2]);
    process.stdout.write(r ? r.value_json : "");' "$1" "$2"
}
profile_json() {  # <email> <acct> <refresh> [expires-ms] [access]
  local access="${5:-$(jwt "$2")}"
  printf '{"type":"oauth","provider":"openai","email":"%s","access":"%s","refresh":"%s","idToken":"id-%s","accountId":"%s","chatgptPlanType":"pro","expires":%s}' \
    "$1" "$access" "$3" "$1" "$2" "${4:-4102444800000}"
}
MAIN_DB() { printf '%s' "$CODEX_AUTH_ROOT/.openclaw-main/state/openclaw.sqlite"; }
seed_main() {
  set_row "$(MAIN_DB)" authProfiles.store "{\"version\":1,\"profiles\":{
    \"openai:aaron@muso.ai\":$(profile_json aaron@muso.ai acct-muso REAL-REFRESH-MUSO),
    \"openai:aaronkaufman@me.com\":$(profile_json aaronkaufman@me.com acct-me REAL-REFRESH-ME)}}"
}
no_real_refresh() {  # <file>: no REAL-REFRESH bytes anywhere
  if grep -q 'REAL-REFRESH' "$1"; then echo "REAL refresh token found in $1"; return 1; fi
}
b64d() { base64 -d 2>/dev/null || base64 -D; }

@test "export: sentinel-only payload with every account, no real refresh token, 0600" {
  run "$SCRIPT" export --out "$TEST_TMPDIR/out.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  no_real_refresh "$TEST_TMPDIR/out.json"
  [ "$(jq -r '.profiles | length' "$TEST_TMPDIR/out.json")" -eq 2 ]
  [ "$(jq -r '[.profiles[].refresh] | unique | join(",")' "$TEST_TMPDIR/out.json")" = "$SENTINEL" ]
  [ "$(jq -r '.profiles["openai:aaron@muso.ai"].access' "$TEST_TMPDIR/out.json")" = "$(jwt acct-muso)" ]
  # GNU first: on Linux `stat -f` is filesystem status and exits 0, so it must not lead.
  [ "$(stat -c '%a' "$TEST_TMPDIR/out.json" 2>/dev/null || stat -f '%Lp' "$TEST_TMPDIR/out.json")" = "600" ]
  [[ "$output" == *"EXPORTED"*"refresh=sentinel"* ]]
  [[ "$output" != *"$(jwt acct-muso)"* ]]   # no token on stdout/stderr
}

@test "export: the canonical cell is byte-identical afterwards (read-only on Caroline's store)" {
  before="$(read_row "$(MAIN_DB)" authProfiles.store | shasum -a 256)"
  run "$SCRIPT" export --out "$TEST_TMPDIR/out.json"
  [ "$status" -eq 0 ]
  [ "$(read_row "$(MAIN_DB)" authProfiles.store | shasum -a 256)" = "$before" ]
}

@test "export: a token inside the 1-day margin is REFUSED and nothing is written" {
  soon=$(( ($(date +%s) + 3600 * 5) * 1000 ))
  set_row "$(MAIN_DB)" authProfiles.store "{\"version\":1,\"profiles\":{\"openai:aaron@muso.ai\":$(profile_json aaron@muso.ai acct-muso REAL-REFRESH-MUSO "$soon")}}"
  run "$SCRIPT" export --out "$TEST_TMPDIR/out.json"
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_TMPDIR/out.json" ]
}

@test "export: a sentinel-bearing source (a mirror, not canonical) is refused" {
  set_row "$(MAIN_DB)" authProfiles.store "{\"version\":1,\"profiles\":{\"openai:aaron@muso.ai\":$(profile_json aaron@muso.ai acct-muso "$SENTINEL")}}"
  run "$SCRIPT" export --out "$TEST_TMPDIR/out.json"
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_TMPDIR/out.json" ]
}

@test "export: missing canonical cell is structural (exit 2)" {
  rm -f "$(MAIN_DB)"
  run "$SCRIPT" export --out "$TEST_TMPDIR/out.json"
  [ "$status" -eq 2 ]
}

@test "publish: applies ONE Secret hydra-qa/qa-codex-auth server-side; tokens never on kubectl argv" {
  run "$SCRIPT" publish
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q -- '-n hydra-qa create secret generic qa-codex-auth' "$KUBE_ARGV"
  grep -q -- 'apply --server-side --field-manager=codex-auth-secret-writer -f -' "$KUBE_ARGV"
  ! grep -q 'eyJ' "$KUBE_ARGV"
  payload="$(sed -n 's/^  auth-profiles.store.json: //p' "$KUBE_APPLIED" | b64d)"
  [ "$(jq -r '[.profiles[].refresh] | unique | join(",")' <<< "$payload")" = "$SENTINEL" ]
  ! grep -q 'REAL-REFRESH' <<< "$payload"
}

@test "publish: a refused export applies NOTHING (the old Secret keeps serving)" {
  set_row "$(MAIN_DB)" authProfiles.store "{\"version\":1,\"profiles\":{\"openai:aaron@muso.ai\":$(profile_json aaron@muso.ai acct-muso "$SENTINEL")}}"
  run "$SCRIPT" publish
  [ "$status" -ne 0 ]
  [ ! -e "$KUBE_APPLIED" ]
  if [ -e "$KUBE_ARGV" ]; then ! grep -q ' apply ' "$KUBE_ARGV"; fi
}

@test "publish: a failed kubectl apply is exit 2 (the CronJob run fails = the page)" {
  export STUB_APPLY_FAIL=1
  run "$SCRIPT" publish
  [ "$status" -eq 2 ]
}

@test "import: writes authProfiles.store + auth.sharedStore=state-db into the POD's cell" {
  "$SCRIPT" export --out "$TEST_TMPDIR/out.json"
  create_db "$TEST_TMPDIR/pod/state/openclaw.sqlite"
  OPENCLAW_STATE_DIR="$TEST_TMPDIR/pod" run "$SCRIPT" import --in "$TEST_TMPDIR/out.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(read_row "$TEST_TMPDIR/pod/state/openclaw.sqlite" auth.sharedStore)" = '{"location":"state-db"}' ]
  [ "$(read_row "$TEST_TMPDIR/pod/state/openclaw.sqlite" authProfiles.store | jq -r '.profiles | length')" -eq 2 ]
  read_row "$TEST_TMPDIR/pod/state/openclaw.sqlite" authProfiles.store > "$TEST_TMPDIR/pod-cell"
  no_real_refresh "$TEST_TMPDIR/pod-cell"
}

@test "import mutation: a payload carrying a REAL refresh token is refused whole, pod cell untouched" {
  "$SCRIPT" export --out "$TEST_TMPDIR/out.json"
  jq '.profiles["openai:aaron@muso.ai"].refresh = "REAL-REFRESH-MUSO"' "$TEST_TMPDIR/out.json" > "$TEST_TMPDIR/bad.json"
  ! cmp -s "$TEST_TMPDIR/out.json" "$TEST_TMPDIR/bad.json"   # the mutation applied
  create_db "$TEST_TMPDIR/pod/state/openclaw.sqlite"
  OPENCLAW_STATE_DIR="$TEST_TMPDIR/pod" run "$SCRIPT" import --in "$TEST_TMPDIR/bad.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT the sentinel"* ]]
  [ -z "$(read_row "$TEST_TMPDIR/pod/state/openclaw.sqlite" authProfiles.store)" ]
}

@test "import mutation: a non-whitelisted field (refresh_token smuggled) is refused" {
  "$SCRIPT" export --out "$TEST_TMPDIR/out.json"
  jq '.profiles["openai:aaron@muso.ai"].refresh_token = "REAL-REFRESH-MUSO"' "$TEST_TMPDIR/out.json" > "$TEST_TMPDIR/bad.json"
  create_db "$TEST_TMPDIR/pod/state/openclaw.sqlite"
  OPENCLAW_STATE_DIR="$TEST_TMPDIR/pod" run "$SCRIPT" import --in "$TEST_TMPDIR/bad.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-whitelisted"* ]]
}

@test "import mutation: accountId that does not match the token claim is refused (runtime would throw)" {
  "$SCRIPT" export --out "$TEST_TMPDIR/out.json"
  jq '.profiles["openai:aaron@muso.ai"].accountId = "acct-other"' "$TEST_TMPDIR/out.json" > "$TEST_TMPDIR/bad.json"
  create_db "$TEST_TMPDIR/pod/state/openclaw.sqlite"
  OPENCLAW_STATE_DIR="$TEST_TMPDIR/pod" run "$SCRIPT" import --in "$TEST_TMPDIR/bad.json"
  [ "$status" -eq 1 ]
}

@test "import: refuses a cell that already holds a REAL refresh token (independent chain) and leaves it" {
  "$SCRIPT" export --out "$TEST_TMPDIR/out.json"
  create_db "$TEST_TMPDIR/pod/state/openclaw.sqlite"
  set_row "$TEST_TMPDIR/pod/state/openclaw.sqlite" authProfiles.store "{\"version\":1,\"profiles\":{\"openai:x@y\":$(profile_json x@y acct-x REAL-REFRESH-X)}}"
  OPENCLAW_STATE_DIR="$TEST_TMPDIR/pod" run "$SCRIPT" import --in "$TEST_TMPDIR/out.json"
  [ "$status" -eq 1 ]
  read_row "$TEST_TMPDIR/pod/state/openclaw.sqlite" authProfiles.store | grep -q 'REAL-REFRESH-X'
}

@test "import: refuses a store owned by legacy-main, a missing table, Caroline's dirs, and no OPENCLAW_STATE_DIR" {
  "$SCRIPT" export --out "$TEST_TMPDIR/out.json"
  create_db "$TEST_TMPDIR/pod/state/openclaw.sqlite"
  set_row "$TEST_TMPDIR/pod/state/openclaw.sqlite" auth.sharedStore '{"location":"legacy-main"}'
  OPENCLAW_STATE_DIR="$TEST_TMPDIR/pod" run "$SCRIPT" import --in "$TEST_TMPDIR/out.json"
  [ "$status" -eq 1 ]
  mkdir -p "$TEST_TMPDIR/pod2/state"; create_db "$TEST_TMPDIR/pod2/state/openclaw.sqlite" notable
  OPENCLAW_STATE_DIR="$TEST_TMPDIR/pod2" run "$SCRIPT" import --in "$TEST_TMPDIR/out.json"
  [ "$status" -eq 2 ]
  OPENCLAW_STATE_DIR="/root/.openclaw-main" run "$SCRIPT" import --in "$TEST_TMPDIR/out.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Caroline state dir"* ]]
  run env -u OPENCLAW_STATE_DIR "$SCRIPT" import --in "$TEST_TMPDIR/out.json"
  [ "$status" -eq 2 ]
}

@test "verify: ok on a fresh export; refuses an expired payload at the 60-min pod margin" {
  "$SCRIPT" export --out "$TEST_TMPDIR/out.json"
  run "$SCRIPT" verify --in "$TEST_TMPDIR/out.json"
  [ "$status" -eq 0 ]
  jq '.profiles[].expires = 1000' "$TEST_TMPDIR/out.json" > "$TEST_TMPDIR/old.json"
  run "$SCRIPT" verify --in "$TEST_TMPDIR/old.json"
  [ "$status" -eq 1 ]
}
