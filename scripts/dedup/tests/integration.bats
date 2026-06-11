#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  STUBS="$REPO_ROOT/scripts/dedup/tests/stubs"
  chmod +x "$STUBS"/*
  export MUSO_BIN="$STUBS/muso"
  CLI="$REPO_ROOT/scripts/dedup/find-dupes.sh"
}

@test "--profile mode finds the stubbed dupe" {
  run bash "$CLI" --profile aaaa-aaaa
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "hard_dupe" ]
  [ "$(echo "$output" | jq -r '.detected_via')" = "profile" ]
}

@test "--email mode resolves email to profile and finds dupe" {
  run bash "$CLI" --email nick@muso.ai
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verdict' | head -n 1)" = "hard_dupe" ]
}

@test "--catalog mode emits hard_dupe rows from stubbed cluster" {
  # bats `run` merges stdout+stderr; split them so we can pin "no stderr
  # noise" as well as the verdict shape. Regression: previously the RETURN
  # trap on a local seen_pairs spat "unbound variable" to stderr while
  # still exiting 0, and the original test silently tolerated it.
  outfile=$(mktemp); errfile=$(mktemp)
  bash "$CLI" --catalog --limit 5 >"$outfile" 2>"$errfile"
  status=$?
  out=$(cat "$outfile"); err=$(cat "$errfile")
  rm -f "$outfile" "$errfile"
  [ "$status" -eq 0 ]
  [ "$(echo "$out" | jq -r '.verdict' | head -n 1)" = "hard_dupe" ]
  # Stderr must be free of bash-level errors. The script CAN emit
  # informational warnings, so we only fail on a real shell error pattern.
  ! echo "$err" | grep -qE 'unbound variable|: command not found|syntax error'
}

@test "--profile mode emits spec §7 stderr line when input has no external IDs" {
  run bash -c "bash '$CLI' --profile eeee-eeee 2>&1 >/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"profile eeee-eeee has no profile-level external identifiers; no hard match possible"* ]]
}

@test "--name mode resolves name to UUIDs and pair-scores against implicit anchor" {
  run bash "$CLI" --name "Ali Zain" --limit 5
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.verdict')" = "hard_dupe" ]
  [ "$(echo "$output" | jq -r '.detected_via')" = "name" ]
  [ "$(echo "$output" | jq -r '.search_name')" = "Ali Zain" ]
  [ "$(echo "$output" | jq -r '.anchor_profile_id')" = "aaaa-aaaa" ]
}

@test "--name mode with --anchor scores everything against the named anchor" {
  run bash "$CLI" --name "Ali Zain" --anchor bbbb-bbbb
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.anchor_profile_id')" = "bbbb-bbbb" ]
}

@test "fetch-profile exits 4 when muso exits non-zero (auth/transport failure)" {
  stub_dir=$(mktemp -d)
  cat > "$stub_dir/muso" <<'STUB'
#!/usr/bin/env bash
echo '{"error":{"code":"auth_required","message":"not logged in"}}' >&2
exit 4
STUB
  chmod +x "$stub_dir/muso"
  MUSO_BIN="$stub_dir/muso" run bash "$REPO_ROOT/scripts/dedup/lib/fetch-profile.sh" aaaa-aaaa
  rm -rf "$stub_dir"
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "muso api call failed"
}

@test "fetch-profile exits 4 on exit-0 response without a .data object (phantom-sibling guard)" {
  stub_dir=$(mktemp -d)
  cat > "$stub_dir/muso" <<'STUB'
#!/usr/bin/env bash
echo '{"items":[],"count":0}'
exit 0
STUB
  chmod +x "$stub_dir/muso"
  MUSO_BIN="$stub_dir/muso" run bash "$REPO_ROOT/scripts/dedup/lib/fetch-profile.sh" aaaa-aaaa
  rm -rf "$stub_dir"
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "no .data object"
}
