#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers

setup() {
  setup_tmp_env
  export OPS_RUN_DIR="$TEST_TMPDIR/run-state"
  # SCRIPTS_DIR is exported by helpers.bash and points at the scripts/ dir.
  # The skill root is its parent.
  export SKILL_DIR="$(dirname "$SCRIPTS_DIR")"
  mkdir -p "$OPS_RUN_DIR"
}
teardown() { teardown_tmp_env; }

# Seed a runlog with N profile_group_fetched events.
seed_runlog() {
  local count="$1"
  local rid="20260501-120000-aaaa00"
  local day="2026-05-01"
  mkdir -p "$OPS_RUNLOG_DIR/$day"
  local log="$OPS_RUNLOG_DIR/$day/$rid.jsonl"
  : > "$log"
  for ((i=1; i<=count; i++)); do
    local pid="profile-$(printf '%03d' "$i")"
    jq -n -c --arg ev profile_group_fetched --arg rid "$rid" --arg pid "$pid" --arg id "cr_$i" \
      '{event:$ev, run_id:$rid, ts:"2026-05-01T12:00:00Z", profile_id:$pid, cr_ids:[$id], count:1, credited_name:"Test Name", track_title:"Test Track", role:"Producer"}' >> "$log"
  done
  echo "$rid"
}

@test "dispatch: emits manifest with one entry per distinct profile" {
  RID=$(seed_runlog 3)
  run "$SCRIPTS_DIR/dispatch-investigations.sh" --run-id "$RID"
  [ "$status" -eq 0 ]
  count=$(echo "$output" | jq '.profiles | length')
  [ "$count" = "3" ]
  pool=$(echo "$output" | jq '.pool_size')
  [ "$pool" = "10" ]
}

@test "dispatch: each profile gets a prompt file with template content" {
  RID=$(seed_runlog 2)
  run "$SCRIPTS_DIR/dispatch-investigations.sh" --run-id "$RID"
  [ "$status" -eq 0 ]
  prompt_path=$(echo "$output" | jq -r '.profiles[0].prompt_path')
  [ -f "$prompt_path" ]
  # The template body should be present (look for the required-steps heading)
  grep -q "Required steps" "$prompt_path"
  # ENV header should mention this profile
  grep -q "profile-001" "$prompt_path"
}

@test "dispatch: env block includes all required vars" {
  RID=$(seed_runlog 1)
  run "$SCRIPTS_DIR/dispatch-investigations.sh" --run-id "$RID"
  [ "$status" -eq 0 ]
  envb=$(echo "$output" | jq -c '.profiles[0].env')
  for k in PROFILE_ID CR_IDS CREDITED_NAME TRACK_TITLE ROLE INVESTIGATION_OUT_FILE OPS_RUN_ID OPS_RUN_DIR; do
    echo "$envb" | jq -e --arg k "$k" '. | has($k)' >/dev/null
  done
}

@test "dispatch: --pool-size override is honored" {
  RID=$(seed_runlog 12)
  run "$SCRIPTS_DIR/dispatch-investigations.sh" --run-id "$RID" --pool-size 5
  [ "$status" -eq 0 ]
  pool=$(echo "$output" | jq '.pool_size')
  [ "$pool" = "5" ]
  # All 12 profiles still appear in the manifest — the agent pools the dispatch
  count=$(echo "$output" | jq '.profiles | length')
  [ "$count" = "12" ]
}

@test "dispatch: empty runlog yields exit 3" {
  rid="20260501-130000-empty0"
  day="2026-05-01"
  mkdir -p "$OPS_RUNLOG_DIR/$day"
  : > "$OPS_RUNLOG_DIR/$day/$rid.jsonl"
  run "$SCRIPTS_DIR/dispatch-investigations.sh" --run-id "$rid"
  [ "$status" -eq 3 ]
}

@test "collect: assembles ready + missing rows by reading per-profile JSONs" {
  RID=$(seed_runlog 3)
  # Run dispatch to materialize the directories
  "$SCRIPTS_DIR/dispatch-investigations.sh" --run-id "$RID" >/dev/null
  invest_dir="$OPS_RUN_DIR/investigations/$RID"
  # Drop a fake investigation result for profile-001 only
  jq -n -c '{verdict:"LEGITIMATE", reason:"found on 2 hosts", evidence_excerpts:[{host:"musicbrainz.org", url:"x", excerpt:"y"}, {host:"musicbrainz.org", url:"z", excerpt:"w"}], browser_load_urls:["x","z"], reasoning_summary:"test"}' \
    > "$invest_dir/profile-001.json"
  run "$SCRIPTS_DIR/collect-investigations.sh" --run-id "$RID"
  [ "$status" -eq 0 ]
  # 3 entries; one ready, two missing
  ready=$(echo "$output" | jq '[.[] | select(.status == "ready")] | length')
  missing=$(echo "$output" | jq '[.[] | select(.status == "missing")] | length')
  [ "$ready" = "1" ]
  [ "$missing" = "2" ]
  # Ready row carries the verdict
  v=$(echo "$output" | jq -r '.[] | select(.profile_id == "profile-001") | .verdict')
  [ "$v" = "LEGITIMATE" ]
}

@test "collect: --require-all returns exit 4 when any investigation missing" {
  RID=$(seed_runlog 2)
  "$SCRIPTS_DIR/dispatch-investigations.sh" --run-id "$RID" >/dev/null
  invest_dir="$OPS_RUN_DIR/investigations/$RID"
  # Only profile-001 has a result; profile-002 missing
  jq -n -c '{verdict:"LEGITIMATE"}' > "$invest_dir/profile-001.json"
  run "$SCRIPTS_DIR/collect-investigations.sh" --run-id "$RID" --require-all
  [ "$status" -eq 4 ]
}

# ---- PR #236 Phase 2: external-ID plumbing ----
# Seed runlog with profile_group_fetched events that carry credits[] arrays
# with per-credit spotify_id / isrc / apple_music_id / etc. so the dispatcher
# can pass them as direct-URL hints to build-search-url.sh.

seed_runlog_with_credits() {
  # Uses field names that match SKILL B2's grouping schema (verified against
  # live admin API 2026-05-01): spotify_track_id (NOT spotify_id), isrc,
  # spotify_artist_ids array, plus profile-level fields.
  local rid="20260501-140000-bbbb00"
  local day="2026-05-01"
  mkdir -p "$OPS_RUNLOG_DIR/$day"
  local log="$OPS_RUNLOG_DIR/$day/$rid.jsonl"
  : > "$log"
  jq -n -c --arg ev profile_group_fetched --arg rid "$rid" \
    '{event:$ev, run_id:$rid, ts:"2026-05-01T14:00:00Z",
      profile_id:"profile-with-ids", cr_ids:["cr_1","cr_2"], count:2,
      credited_name:"Pau Romero", track_title:"Yellow Sub", role:"Mixing",
      profile_name:"Pau Romero", profile_credit_count:42, profile_popularity:55,
      profile_spotify_id:"sp_artist_1",
      credits:[
        {cr_id:"cr_1", track_id:"trk_1",
         spotify_track_id:"08yIaY89bolvyQhIVLXJ5u",
         spotify_track_title:"Rolling Stones",
         spotify_artist_ids:["2EFpb61Lpi0l5ldOiqbZkK","51VUv5NmNQEO5TMGEaUXAJ"],
         isrc:"FR59R2646702", roles:["Mixing","Mastering","Engineer"]},
        {cr_id:"cr_2", track_id:"trk_2",
         spotify_track_id:null, spotify_artist_ids:[],
         isrc:"USRC22222222", roles:["Producer"]}
      ]}' >> "$log"
  echo "$rid"
}

@test "dispatch (Phase 2): env carries real-API field names (spotify_track_id, isrc, spotify_artist_id)" {
  RID=$(seed_runlog_with_credits)
  run "$SCRIPTS_DIR/dispatch-investigations.sh" --run-id "$RID"
  [ "$status" -eq 0 ]
  envb=$(echo "$output" | jq -c '.profiles[0].env')
  [ "$(echo "$envb" | jq -r '.SPOTIFY_TRACK_ID')"  = "08yIaY89bolvyQhIVLXJ5u" ]
  [ "$(echo "$envb" | jq -r '.SPOTIFY_ARTIST_ID')" = "2EFpb61Lpi0l5ldOiqbZkK" ]
  [ "$(echo "$envb" | jq -r '.ISRC')"              = "FR59R2646702" ]
  [ "$(echo "$envb" | jq -r '.TRACK_ID')"          = "trk_1" ]
  # Profile-level signals
  [ "$(echo "$envb" | jq -r '.PROFILE_NAME')"          = "Pau Romero" ]
  [ "$(echo "$envb" | jq -r '.PROFILE_SPOTIFY_ID')"    = "sp_artist_1" ]
  [ "$(echo "$envb" | jq -r '.PROFILE_CREDIT_COUNT')"  = "42" ]
  [ "$(echo "$envb" | jq -r '.PROFILE_POPULARITY')"    = "55" ]
}

@test "dispatch (Phase 2): API-absent fields stay empty (backwards-compat for future plumbing)" {
  RID=$(seed_runlog_with_credits)
  run "$SCRIPTS_DIR/dispatch-investigations.sh" --run-id "$RID"
  [ "$status" -eq 0 ]
  envb=$(echo "$output" | jq -c '.profiles[0].env')
  # API does not return these today — verify they emit empty (helper falls
  # back to encoded search URLs)
  [ "$(echo "$envb" | jq -r '.APPLE_MUSIC_ID')" = "" ]
  [ "$(echo "$envb" | jq -r '.MUSICBRAINZ_ID')" = "" ]
  [ "$(echo "$envb" | jq -r '.TIDAL_ID')"       = "" ]
  [ "$(echo "$envb" | jq -r '.DISCOGS_ID')"     = "" ]
}

@test "dispatch (Phase 2): CREDITS_JSON env preserves the full per-credit array" {
  RID=$(seed_runlog_with_credits)
  run "$SCRIPTS_DIR/dispatch-investigations.sh" --run-id "$RID"
  [ "$status" -eq 0 ]
  credits_str=$(echo "$output" | jq -r '.profiles[0].env.CREDITS_JSON')
  cr1=$(echo "$credits_str" | jq -r '.[0].cr_id')
  cr2=$(echo "$credits_str" | jq -r '.[1].cr_id')
  [ "$cr1" = "cr_1" ]
  [ "$cr2" = "cr_2" ]
  # Per-credit roles array preserved
  [ "$(echo "$credits_str" | jq -r '.[0].roles | join(",")')" = "Mixing,Mastering,Engineer" ]
}

@test "dispatch (Phase 2): missing credits[] degrades gracefully (empty IDs)" {
  RID=$(seed_runlog 1)
  run "$SCRIPTS_DIR/dispatch-investigations.sh" --run-id "$RID"
  [ "$status" -eq 0 ]
  envb=$(echo "$output" | jq -c '.profiles[0].env')
  [ "$(echo "$envb" | jq -r '.SPOTIFY_TRACK_ID')" = "" ]
  [ "$(echo "$envb" | jq -r '.ISRC')"             = "" ]
  [ "$(echo "$envb" | jq -r '.CREDITS_JSON')"     = "[]" ]
}
