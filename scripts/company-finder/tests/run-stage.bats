#!/usr/bin/env bats

setup() {
  TEST_DIR="$(mktemp -d)"
  SUT="$BATS_TEST_DIRNAME/../run-stage.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "prep returns the target's complete stdout only after target exit" {
  target="$TEST_DIR/prep.sh"
  cat > "$target" <<'EOF'
#!/usr/bin/env bash
input="$(cat)"
sleep 0.05
jq -n --argjson input "$input" '{survivors:$input,rejects:{duplicates:[],dead:[],name_flags:[]},stats:{checked:($input|length)}}'
EOF
  chmod +x "$target"
  input="$TEST_DIR/input.json"
  printf '%s\n' '[{"name":"A","domain":"a.example","vertical":"Audio"}]' > "$input"

  run env COMPANY_FINDER_PREP_SCRIPT="$target" "$SUT" prep "$input"

  [ "$status" -eq 0 ]
  [ "$(jq '.survivors | length' <<<"$output")" -eq 1 ]
}

@test "finalize rejects canonically overlapping batch and reject domains before side effects" {
  target="$TEST_DIR/finalize.sh"
  marker="$TEST_DIR/invoked"
  cat > "$target" <<EOF
#!/usr/bin/env bash
touch "$marker"
EOF
  chmod +x "$target"
  input="$TEST_DIR/input.json"
  printf '%s\n' '{"batch":[{"domain":"example.com"}],"rejects":[{"domain":"EXAMPLE.COM (updated)"}]}' > "$input"

  run env COMPANY_FINDER_FINALIZE_SCRIPT="$target" "$SUT" finalize "$input"

  [ "$status" -eq 1 ]
  [[ "$output" == *'"error":"INVALID_FINAL_INPUT"'* ]]
  [ ! -e "$marker" ]
}

@test "finalize forwards a valid payload and trusted source to the target" {
  target="$TEST_DIR/finalize.sh"
  source_file="$TEST_DIR/source"
  cat > "$target" <<EOF
#!/usr/bin/env bash
printf '%s' "\$BATCH_SOURCE" > "$source_file"
cat >/dev/null
printf '%s\n' '{"posted":{"ts":"1","channel":"C"},"ledger":{"suggested":1,"rejects_recorded":0}}'
EOF
  chmod +x "$target"
  input="$TEST_DIR/input.json"
  printf '%s\n' '{"batch":[{"domain":"example.com"}],"rejects":[{"domain":"other.example"}]}' > "$input"

  run env COMPANY_FINDER_FINALIZE_SCRIPT="$target" "$SUT" finalize "$input" cron:company-finder-daily

  [ "$status" -eq 0 ]
  [ "$(cat "$source_file")" = "cron:company-finder-daily" ]
  [ "$(jq -r '.posted.ts' <<<"$output")" = "1" ]
}

@test "timeout kills the entire target process group before a descendant side effect" {
  target="$TEST_DIR/prep.sh"
  marker="$TEST_DIR/late-side-effect"
  cat > "$target" <<EOF
#!/usr/bin/env bash
( sleep 0.5; touch "$marker" ) &
wait
EOF
  chmod +x "$target"
  input="$TEST_DIR/input.json"
  printf '%s\n' '[]' > "$input"

  run env COMPANY_FINDER_PREP_SCRIPT="$target" COMPANY_FINDER_PREP_TIMEOUT=0.1s \
    "$SUT" prep "$input"
  sleep 0.7

  [ "$status" -eq 124 ]
  [ ! -e "$marker" ]
}
