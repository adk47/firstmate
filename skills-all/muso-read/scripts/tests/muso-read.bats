#!/usr/bin/env bats
# Hermetic tests for muso-read.sh — `muso` is PATH-shadowed by a stub that prints
# a marker, so we can assert whether the real binary was reached. ALLOW cases must
# reach the stub (marker present, exit 0); REJECT cases must exit non-zero WITHOUT
# the marker (the wrapper refused before invoking muso).

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../muso-read.sh"
  STUBBIN="$(mktemp -d)"
  cat > "$STUBBIN/muso" <<'STUB'
#!/usr/bin/env bash
# Echo the args; for `query -` also drain stdin so the pipe doesn't break.
if [ "${1:-}" = "query" ] && [ "${2:-}" = "-" ]; then
  cat >/dev/null
fi
echo "MUSO_CALLED: $*"
STUB
  chmod +x "$STUBBIN/muso"
  PATH="$STUBBIN:$PATH"
  export PATH
}

teardown() { rm -rf "$STUBBIN"; }

called()     { [[ "$output" == *"MUSO_CALLED"* ]]; }
not_called() { [[ "$output" != *"MUSO_CALLED"* ]]; }

# ---- usage ----------------------------------------------------------------
@test "--help exits 0 and prints usage, without calling muso" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"muso-read.sh"* ]]
  [[ "$output" == *"READ-ONLY"* ]]
  not_called
}

@test "no command exits 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  not_called
}

# ---- ALLOW: read commands -------------------------------------------------
@test "profiles search is allowed" {
  run bash "$SCRIPT" profiles search "drake" --json
  [ "$status" -eq 0 ]; called
  [[ "$output" == *"profiles search drake --json"* ]]
}

@test "profiles get is allowed" {
  run bash "$SCRIPT" profiles get 123 --json
  [ "$status" -eq 0 ]; called
}

@test "tracks/users/teams/claiming/albums reads are allowed" {
  run bash "$SCRIPT" tracks search "song"; [ "$status" -eq 0 ]; called
  run bash "$SCRIPT" users search "a@b.com"; [ "$status" -eq 0 ]; called
  run bash "$SCRIPT" teams get t1; [ "$status" -eq 0 ]; called
  run bash "$SCRIPT" claiming list; [ "$status" -eq 0 ]; called
  run bash "$SCRIPT" albums get al1; [ "$status" -eq 0 ]; called
}

@test "health, agent-docs, auth status, api --list-routes are allowed" {
  run bash "$SCRIPT" health; [ "$status" -eq 0 ]; called
  run bash "$SCRIPT" agent-docs; [ "$status" -eq 0 ]; called
  run bash "$SCRIPT" auth status --json; [ "$status" -eq 0 ]; called
  run bash "$SCRIPT" api --list-routes; [ "$status" -eq 0 ]; called
}

@test "api GET is allowed" {
  run bash "$SCRIPT" api GET '/admin/claiming?status=pending&limit=20' --json
  [ "$status" -eq 0 ]; called
}

@test "query SELECT / WITH / SHOW are allowed" {
  run bash "$SCRIPT" query "SELECT 1"; [ "$status" -eq 0 ]; called
  run bash "$SCRIPT" query "with x as (select 1) select * from x"; [ "$status" -eq 0 ]; called
  run bash "$SCRIPT" query "SHOW TABLES"; [ "$status" -eq 0 ]; called
}

@test "query - (stdin) SELECT is allowed and stdin is replayed" {
  run bash -c "printf 'SELECT count(*) FROM postgresql_core.public.users' | bash '$SCRIPT' query - --format json"
  [ "$status" -eq 0 ]; called
}

@test "query --format json BEFORE the SQL (documented flag-first form) is allowed" {
  run bash "$SCRIPT" query --format json "SELECT 1"
  [ "$status" -eq 0 ]; called
  [[ "$output" == *"SELECT 1"* ]]
}

@test "BYPASS GUARD: a smuggled second positional (extra SQL) is refused" {
  # The validator must not validate only the first positional while forwarding more.
  run bash "$SCRIPT" query "SELECT 1" "DELETE FROM users WHERE id=1"
  [ "$status" -eq 3 ]; not_called
}

@test "BYPASS GUARD: an unknown query flag is refused (no raw passthrough)" {
  run bash "$SCRIPT" query --some-sql-flag "DROP TABLE t" "SELECT 1"
  [ "$status" -eq 3 ]; not_called
}

@test "a column containing a verb substring is not falsely rejected" {
  # created_at / update_date are single words; whole-word guard must not trip.
  run bash "$SCRIPT" query "SELECT created_at, update_date FROM t"
  [ "$status" -eq 0 ]; called
}

# ---- ALLOW: nocodb reads (B2B-ADS-intelligence base) ----------------------
@test "nocodb whoami is allowed" {
  run bash "$SCRIPT" nocodb whoami
  [ "$status" -eq 0 ]; called
  [[ "$output" == *"nocodb whoami"* ]]
}

@test "nocodb tables list/get are allowed" {
  run bash "$SCRIPT" nocodb tables list; [ "$status" -eq 0 ]; called
  run bash "$SCRIPT" nocodb tables get --table m9vsbijhrr9ddeu; [ "$status" -eq 0 ]; called
}

@test "nocodb records list/get/count are allowed" {
  run bash "$SCRIPT" nocodb records list --table m9vsbijhrr9ddeu --where '(Status,eq,open)' --json
  [ "$status" -eq 0 ]; called
  run bash "$SCRIPT" nocodb records get --table m9vsbijhrr9ddeu --id 42; [ "$status" -eq 0 ]; called
  run bash "$SCRIPT" nocodb records count --table m9vsbijhrr9ddeu; [ "$status" -eq 0 ]; called
}

@test "nocodb raw GET is allowed" {
  run bash "$SCRIPT" nocodb raw GET /api/v2/meta/bases/p11hvpwapu4hv0x
  [ "$status" -eq 0 ]; called
}

@test "nocodb read with a --where value containing 'delete' is NOT falsely rejected" {
  # The nocodb branch gates on the verb position only — it must not keyword-scan
  # filter values the way the SQL `query` path scans statements.
  run bash "$SCRIPT" nocodb records list --table m9vsbijhrr9ddeu --where '(Note,like,%delete%)'
  [ "$status" -eq 0 ]; called
}

# ---- REJECT: writes & non-read commands -----------------------------------
@test "api POST/PUT/PATCH/DELETE are refused (muso never called)" {
  run bash "$SCRIPT" api POST /admin/x --data '{}'; [ "$status" -eq 3 ]; not_called
  run bash "$SCRIPT" api PUT /admin/x;             [ "$status" -eq 3 ]; not_called
  run bash "$SCRIPT" api PATCH /admin/x;           [ "$status" -eq 3 ]; not_called
  run bash "$SCRIPT" api DELETE /admin/x;          [ "$status" -eq 3 ]; not_called
}

@test "profiles merge / update are refused" {
  run bash "$SCRIPT" profiles merge --into a --from b; [ "$status" -eq 3 ]; not_called
  run bash "$SCRIPT" profiles update 1 --data '{}';    [ "$status" -eq 3 ]; not_called
}

@test "query DELETE/INSERT/UPDATE/DROP are refused" {
  run bash "$SCRIPT" query "DELETE FROM users";        [ "$status" -eq 3 ]; not_called
  run bash "$SCRIPT" query "INSERT INTO t VALUES (1)"; [ "$status" -eq 3 ]; not_called
  run bash "$SCRIPT" query "UPDATE t SET x=1";         [ "$status" -eq 3 ]; not_called
  run bash "$SCRIPT" query "DROP TABLE t";             [ "$status" -eq 3 ]; not_called
}

@test "multi-statement query is refused" {
  run bash "$SCRIPT" query "SELECT 1; DELETE FROM users"; [ "$status" -eq 3 ]; not_called
}

@test "a non-read first keyword is refused even with no write verb" {
  run bash "$SCRIPT" query "CALL system.runtime.kill_query('x')"; [ "$status" -eq 3 ]; not_called
}

@test "unknown / write subcommands are refused" {
  run bash "$SCRIPT" credit-requests set-status --status approved; [ "$status" -eq 3 ]; not_called
  run bash "$SCRIPT" frobnicate; [ "$status" -eq 3 ]; not_called
}

@test "nocodb record writes are refused (muso never called)" {
  run bash "$SCRIPT" nocodb records create --table m9 --data '{}'; [ "$status" -eq 3 ]; not_called
  run bash "$SCRIPT" nocodb records update --table m9 --data '[]'; [ "$status" -eq 3 ]; not_called
  run bash "$SCRIPT" nocodb records delete --table m9 --data '[]' --yes; [ "$status" -eq 3 ]; not_called
}

@test "nocodb table create/delete are refused" {
  run bash "$SCRIPT" nocodb tables create --base p11hvpwapu4hv0x --data '{}'; [ "$status" -eq 3 ]; not_called
  run bash "$SCRIPT" nocodb tables delete --table m9; [ "$status" -eq 3 ]; not_called
}

@test "nocodb raw with a non-GET method is refused" {
  run bash "$SCRIPT" nocodb raw POST /api/v2/meta/tables/m9/columns --data '{}'; [ "$status" -eq 3 ]; not_called
  run bash "$SCRIPT" nocodb raw PUT /api/v2/x;    [ "$status" -eq 3 ]; not_called
  run bash "$SCRIPT" nocodb raw PATCH /api/v2/x;  [ "$status" -eq 3 ]; not_called
  run bash "$SCRIPT" nocodb raw DELETE /api/v2/x; [ "$status" -eq 3 ]; not_called
}

@test "unknown nocodb subcommand is refused" {
  run bash "$SCRIPT" nocodb frobnicate; [ "$status" -eq 3 ]; not_called
}
