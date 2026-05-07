#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

# Tests for profile-audit.sh — Tier-0 8-gate per-profile bulk-approve audit.
#
# Stubbing strategy (per memory feedback_bats_must_stub_openclaw.md):
#   * Stub muso-admin-api.sh by setting ADMIN_API_SCRIPT to a fake bash that
#     reads pre-staged JSON fixtures from $TEST_TMPDIR. This script never
#     touches the network.
#   * Stub openclaw via PATH-shadow: $TEST_TMPDIR/bin/openclaw is a noop.
#     profile-audit.sh itself doesn't shell out to openclaw, but runlog.sh
#     and any defensive code that might add such a call would be caught.
#   * Stub runlog.sh too: it's a noop that records events to a log file we
#     can assert on.

setup() {
    setup_tmp_env

    SCRIPT="${BATS_TEST_DIRNAME}/../profile-audit.sh"
    [[ -x "$SCRIPT" ]] || { echo "SCRIPT missing or not executable: $SCRIPT" >&2; return 1; }

    # PATH-shadow openclaw (defense-in-depth — bats must never hit prod Slack).
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
echo "TEST: openclaw stub called with: $*" >&2
exit 0
STUB
    chmod +x "$TEST_TMPDIR/bin/openclaw"
    export PATH="$TEST_TMPDIR/bin:$PATH"

    # Fake admin API. Returns canned fixtures based on URL substring.
    # Two fixture files per profile_id: unverified.json and approved.json.
    # The fake script picks based on the path's status= component.
    export FIXTURE_DIR="$TEST_TMPDIR/fixtures"
    mkdir -p "$FIXTURE_DIR"

    export ADMIN_API_SCRIPT="$TEST_TMPDIR/fake-admin-api.sh"
    cat > "$ADMIN_API_SCRIPT" <<'STUB'
#!/usr/bin/env bash
# Fake muso-admin-api.sh. Args: call GET <path>
# Picks a fixture based on the status= and profilesIds= query params.
url="$3"
profile_id=$(printf '%s' "$url" | sed -n 's/.*profilesIds=\([^&]*\).*/\1/p')
status=$(printf '%s' "$url" | sed -n 's/.*status=\([^&]*\).*/\1/p')
fixture="${FIXTURE_DIR}/${profile_id}.${status}.json"
if [[ ! -f "$fixture" ]]; then
    # No fixture means empty result.
    echo '{"http_status":200,"body":{"result":"ok","code":200,"data":{"items":[]}}}'
    exit 0
fi
cat "$fixture"
STUB
    chmod +x "$ADMIN_API_SCRIPT"

    # Stub runlog.sh — capture events to a log file.
    export RUNLOG_LOG="$TEST_TMPDIR/runlog-events.log"
    : > "$RUNLOG_LOG"
    export RUNLOG_SH="$TEST_TMPDIR/fake-runlog.sh"
    cat > "$RUNLOG_SH" <<'STUB'
#!/usr/bin/env bash
# Fake runlog.sh — usage: runlog.sh event <run_id> <name> <json_payload>
if [[ "${1:-}" == "event" ]]; then
    printf '%s\t%s\t%s\n' "$3" "$4" "$5" >> "$RUNLOG_LOG"
fi
exit 0
STUB
    chmod +x "$RUNLOG_SH"

    # Tier-0 enabled by default; individual tests can unset.
    export OPS_TIER0_ENABLED=1
    export OPS_RUN_ID="20260506-120000-aaaaaa"
    # OPS_RUNLOG_DIR comes from setup_tmp_env.
}

teardown() { teardown_tmp_env; }

# ------------------------------------------------------------------
# Fixture builders. We build credits programmatically so each test can
# tweak one dimension (creditCount, popularity, source, signals, breadth,
# roles, artists, labels) without forking a full JSON blob.
# ------------------------------------------------------------------

# build_credit_json — emit one credit-row JSON.
# args (positional, all optional with sensible defaults):
#   $1 cr_id           default cr_<random>
#   $2 source          default "industry"  (G3 input)
#   $3 label           default "Acme Records"  (G8 input)
#   $4 roles_csv       default "Mastering"  (G6 + G5 breadth input)
#   $5 artist_names    default "Bram Fidder"  (G7 input; comma-separated)
#   $6 vel_pct         default 100   (G4 input — reject_high_velocity_profile)
#   $7 other_reject    default 0     (G4 input — any other reject_* signal)
#   $8 cc              default 694
#   $9 pop             default 68
build_credit_json() {
    local cr_id="${1:-cr_$RANDOM}"
    local source="${2:-industry}"
    local label="${3:-Acme Records}"
    local roles_csv="${4:-Mastering}"
    local artist_names="${5:-Bram Fidder}"
    local vel_pct="${6:-100}"
    local other_reject="${7:-0}"
    local cc="${8:-694}"
    local pop="${9:-68}"

    jq -n -c \
        --arg id "$cr_id" \
        --arg source "$source" \
        --arg label "$label" \
        --arg roles_csv "$roles_csv" \
        --arg artists_csv "$artist_names" \
        --argjson vel "$vel_pct" \
        --argjson other "$other_reject" \
        --argjson cc "$cc" \
        --argjson pop "$pop" '
        {
            id: $id,
            profileId: "p1",
            metadata: {source: $source, label: $label, isrc: "TEST"},
            verificationData: {
                rule_risk_percent: {
                    reject_high_velocity_profile: $vel,
                    reject_high_risk_profile: $other,
                    reject_artist_credit: 0,
                    reject_deleted_catalog_track: 0,
                    reject_individual_org_credit: 0,
                    reject_publisher_label_credit: 0,
                    approve_credit_exists: 100
                }
            },
            profile: {creditCount: $cc, popularity: $pop, name: "Test Profile"},
            credits: ($roles_csv | split(",") | map(gsub("^\\s+|\\s+$"; ""))),
            spotifyTrackArtists: ($artists_csv | split(",") | map({name: gsub("^\\s+|\\s+$"; "")}))
        }
        '
}

# build_envelope — wrap an array of credit JSONs in the admin-API envelope.
# args: <items_jsonl_file>  (one credit-row JSON per line; the function
# concatenates them into a JSON array)
build_envelope() {
    local items_file="$1"
    local items_array
    if [[ -s "$items_file" ]]; then
        items_array=$(jq -s -c '.' < "$items_file")
    else
        items_array='[]'
    fi
    jq -n -c --argjson items "$items_array" \
        '{http_status:200, body:{result:"ok", code:200, data:{items:$items}}}'
}

# stage_unverified — write the unverified.json fixture for $1=profile_id
# from a JSONL file at $2.
stage_unverified() { build_envelope "$2" > "${FIXTURE_DIR}/$1.unverified.json"; }
stage_approved()   { build_envelope "$2" > "${FIXTURE_DIR}/$1.approved.json"; }

# Convenience: stage N identical unverified credits via build_credit_json args.
# args: profile_id N source label roles_csv artists_csv vel other cc pop
seed_unverified_n() {
    local pid="$1" n="$2"; shift 2
    local f="$TEST_TMPDIR/unv.$pid.jsonl"
    : > "$f"
    for ((i=0; i<n; i++)); do
        build_credit_json "cr_u_${pid}_${i}" "$@" >> "$f"
    done
    stage_unverified "$pid" "$f"
}

# Approved corpus seeder — same shape, separate file.
seed_approved_n() {
    local pid="$1" n="$2"; shift 2
    local f="$TEST_TMPDIR/ap.$pid.jsonl"
    : > "$f"
    for ((i=0; i<n; i++)); do
        build_credit_json "cr_a_${pid}_${i}" "$@" >> "$f"
    done
    stage_approved "$pid" "$f"
}

# ------------------------------------------------------------------
# Disabled / arg validation
# ------------------------------------------------------------------

@test "Tier-0 disabled (OPS_TIER0_ENABLED unset) → exit 2" {
    unset OPS_TIER0_ENABLED
    run bash "$SCRIPT" some-profile-id
    [ "$status" -eq 2 ]
    [[ "$output" == *"Tier-0 disabled"* ]]
}

@test "Tier-0 disabled (OPS_TIER0_ENABLED=0) → exit 2" {
    export OPS_TIER0_ENABLED=0
    run bash "$SCRIPT" some-profile-id
    [ "$status" -eq 2 ]
}

@test "missing profile_id → exit 2" {
    run bash "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"profile_id"* ]] || [[ "$output" == *"usage"* ]]
}

@test "--batch mode rejected (Phase A) → exit 2" {
    run bash "$SCRIPT" --batch /tmp/queue.jsonl
    [ "$status" -eq 2 ]
    [[ "$output" == *"--batch is not implemented"* ]] || [[ "$output" == *"Phase A"* ]]
}

# ------------------------------------------------------------------
# PASS — Bram Fidder pattern
# ------------------------------------------------------------------

@test "PASS: Bram Fidder — 50 mastering credits, all velocity-only, industry-sourced" {
    seed_unverified_n p_bram 50 industry "DBT Empire" "Mastering" "Bram Fidder" 100 0 694 68
    seed_approved_n   p_bram 30 industry "DBT Empire" "Mastering" "Bram Fidder" 0   0 694 68

    run bash "$SCRIPT" p_bram
    [ "$status" -eq 0 ]
    # Receipt should be on stdout, single line.
    [[ "$output" == *"profile_audit:cc=694,pop=68,batch=50"* ]]
    [[ "$output" == *"industry=1.00"* ]]
    [[ "$output" == *"only_vel=1.00"* ]]
    [[ "$output" == *"br_max=1/1"* ]]
    [[ "$output" == *"roles_ok=1"* ]]

    # Runlog should have a tier0_audit_passed event with this profile_id.
    grep -q "tier0_audit_passed" "$RUNLOG_LOG"
    grep "tier0_audit_passed" "$RUNLOG_LOG" | grep -q "p_bram"
}

# ------------------------------------------------------------------
# G1 — creditCount
# ------------------------------------------------------------------

@test "FAIL G1: profile.creditCount=34 < 100" {
    seed_unverified_n p_low_cc 25 industry "Acme" "Mastering" "Some Artist" 100 0 34 70
    seed_approved_n   p_low_cc 10 industry "Acme" "Mastering" "Some Artist" 0   0 34 70

    run bash "$SCRIPT" p_low_cc
    [ "$status" -eq 1 ]
    grep -q "tier0_skipped_gate_fail" "$RUNLOG_LOG"
    grep "tier0_skipped_gate_fail" "$RUNLOG_LOG" | grep -q "g1_creditCount"
}

# ------------------------------------------------------------------
# G2 — popularity
# ------------------------------------------------------------------

@test "FAIL G2: profile.popularity=30 < 50" {
    seed_unverified_n p_low_pop 25 industry "Acme" "Mastering" "Some Artist" 100 0 200 30
    seed_approved_n   p_low_pop 10 industry "Acme" "Mastering" "Some Artist" 0   0 200 30

    run bash "$SCRIPT" p_low_pop
    [ "$status" -eq 1 ]
    grep "tier0_skipped_gate_fail" "$RUNLOG_LOG" | grep -q "g2_popularity"
}

# ------------------------------------------------------------------
# G3 — industry-source fraction
# ------------------------------------------------------------------

@test "FAIL G3: 60% spclient-sourced (< 70% industry threshold)" {
    # 25 unverified: 10 industry + 15 spclient = 40% industry < 0.70.
    pid=p_g3
    f="$TEST_TMPDIR/unv.$pid.jsonl"
    : > "$f"
    for i in $(seq 1 10); do
        build_credit_json "cr_i_$i" industry  "Acme" "Mastering" "Artist X" 100 0 694 68 >> "$f"
    done
    for i in $(seq 1 15); do
        build_credit_json "cr_s_$i" spclient  "Acme" "Mastering" "Artist X" 100 0 694 68 >> "$f"
    done
    stage_unverified "$pid" "$f"
    seed_approved_n "$pid" 5 industry "Acme" "Mastering" "Artist X" 0 0 694 68

    run bash "$SCRIPT" "$pid"
    [ "$status" -eq 1 ]
    grep "tier0_skipped_gate_fail" "$RUNLOG_LOG" | grep -q "g3_industry_fraction"
}

# ------------------------------------------------------------------
# G4 — only-velocity-flag fraction
# ------------------------------------------------------------------

@test "FAIL G4: 50% have multiple negative signals (only_velocity drops to 50%)" {
    pid=p_g4
    f="$TEST_TMPDIR/unv.$pid.jsonl"
    : > "$f"
    # 12 only-velocity (other_reject=0) + 13 with another reject_ flag firing
    for i in $(seq 1 12); do
        build_credit_json "cr_v_$i" industry "Acme" "Mastering" "X" 100 0  694 68 >> "$f"
    done
    for i in $(seq 1 13); do
        build_credit_json "cr_b_$i" industry "Acme" "Mastering" "X" 100 50 694 68 >> "$f"
    done
    stage_unverified "$pid" "$f"
    seed_approved_n "$pid" 5 industry "Acme" "Mastering" "X" 0 0 694 68

    run bash "$SCRIPT" "$pid"
    [ "$status" -eq 1 ]
    grep "tier0_skipped_gate_fail" "$RUNLOG_LOG" | grep -q "g4_only_velocity_fraction"
}

# ------------------------------------------------------------------
# G5 — profile-relative breadth (Ming Vauz: 11 vs 2)
# ------------------------------------------------------------------

@test "FAIL G5: unverified breadth 11 > approved breadth 2 + 1" {
    pid=p_g5
    # Unverified: each credit has 11 roles
    f="$TEST_TMPDIR/unv.$pid.jsonl"
    : > "$f"
    roles11="Mastering,Mixing,Producer,Songwriter,Composer,Vocalist,Guitarist,Bassist,Drummer,Pianist,DJ"
    for i in $(seq 1 25); do
        build_credit_json "cr_$i" industry "Acme" "$roles11" "X" 100 0 694 68 >> "$f"
    done
    stage_unverified "$pid" "$f"
    # Approved: each credit has 2 roles
    seed_approved_n "$pid" 10 industry "Acme" "Mastering,Mixing" "X" 0 0 694 68

    run bash "$SCRIPT" "$pid"
    [ "$status" -eq 1 ]
    grep "tier0_skipped_gate_fail" "$RUNLOG_LOG" | grep -q "g5_breadth"
}

# ------------------------------------------------------------------
# G6 — role subset
# ------------------------------------------------------------------

@test "FAIL G6: unverified has 'DJ' role not in approved corpus" {
    pid=p_g6
    seed_unverified_n "$pid" 25 industry "Acme" "DJ" "X" 100 0 694 68
    seed_approved_n   "$pid" 10 industry "Acme" "Mastering" "X" 0 0 694 68

    run bash "$SCRIPT" "$pid"
    [ "$status" -eq 1 ]
    grep "tier0_skipped_gate_fail" "$RUNLOG_LOG" | grep -q "g6_role_subset"
}

# ------------------------------------------------------------------
# G7 — artist overlap (Vrancis: 18%)
# ------------------------------------------------------------------

@test "FAIL G7: only 18% artist overlap (< 40% threshold)" {
    pid=p_g7
    # 25 unverified — 5 with overlapping artist "Common", 20 with unique
    f="$TEST_TMPDIR/unv.$pid.jsonl"
    : > "$f"
    for i in $(seq 1 5); do
        build_credit_json "cr_o_$i" industry "Acme" "Mastering" "Common Artist" 100 0 694 68 >> "$f"
    done
    for i in $(seq 1 20); do
        build_credit_json "cr_u_$i" industry "Acme" "Mastering" "Unique Artist $i" 100 0 694 68 >> "$f"
    done
    stage_unverified "$pid" "$f"
    seed_approved_n "$pid" 10 industry "Acme" "Mastering" "Common Artist" 0 0 694 68

    run bash "$SCRIPT" "$pid"
    [ "$status" -eq 1 ]
    grep "tier0_skipped_gate_fail" "$RUNLOG_LOG" | grep -q "g7_artist_overlap"
}

# ------------------------------------------------------------------
# G8 — label overlap
# ------------------------------------------------------------------

@test "FAIL G8: only 10% label overlap (< 30% threshold)" {
    pid=p_g8
    # 25 unverified, 23 with unique labels, 2 with the approved-corpus label
    f="$TEST_TMPDIR/unv.$pid.jsonl"
    : > "$f"
    for i in $(seq 1 2); do
        build_credit_json "cr_o_$i" industry "Acme Records" "Mastering" "Same Artist" 100 0 694 68 >> "$f"
    done
    for i in $(seq 1 23); do
        build_credit_json "cr_x_$i" industry "Random Label $i" "Mastering" "Same Artist" 100 0 694 68 >> "$f"
    done
    stage_unverified "$pid" "$f"
    seed_approved_n "$pid" 10 industry "Acme Records" "Mastering" "Same Artist" 0 0 694 68

    run bash "$SCRIPT" "$pid"
    [ "$status" -eq 1 ]
    grep "tier0_skipped_gate_fail" "$RUNLOG_LOG" | grep -q "g8_label_overlap"
}

# ------------------------------------------------------------------
# Skip — low volume
# ------------------------------------------------------------------

@test "SKIP: only 5 unverified credits (< CV_TIER0_MIN_BATCH=20)" {
    pid=p_low_vol
    seed_unverified_n "$pid" 5 industry "Acme" "Mastering" "X" 100 0 694 68
    seed_approved_n   "$pid" 10 industry "Acme" "Mastering" "X" 0 0 694 68

    run bash "$SCRIPT" "$pid"
    [ "$status" -eq 1 ]
    grep -q "tier0_skipped_low_volume" "$RUNLOG_LOG"
    # Should NOT have a gate_fail event — the low-volume short-circuit fires first.
    ! grep -q "tier0_skipped_gate_fail" "$RUNLOG_LOG"
}

# ------------------------------------------------------------------
# No corpus
# ------------------------------------------------------------------

@test "NO_CORPUS: passes G1-G4 but approved corpus is empty" {
    pid=p_no_corpus
    seed_unverified_n "$pid" 25 industry "Acme" "Mastering" "X" 100 0 694 68
    # Stage an empty approved fixture
    : > "$TEST_TMPDIR/empty.jsonl"
    stage_approved "$pid" "$TEST_TMPDIR/empty.jsonl"

    run bash "$SCRIPT" "$pid"
    [ "$status" -eq 1 ]
    grep -q "tier0_skipped_no_corpus" "$RUNLOG_LOG"
}
