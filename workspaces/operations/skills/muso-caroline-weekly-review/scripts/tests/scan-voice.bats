#!/usr/bin/env bats
load helpers

setup() { setup_skill_tmp; }
teardown() { teardown_skill_tmp; }

write_convs() { cat > "$WORKDIR/conversations.redacted.jsonl"; }

@test "flags a phrase-blacklist hit in a Caroline-authored body" {
  write_convs <<'EOF'
{"id":"100000000000001","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Great question! Let me check on that."}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.kind' "$WORKDIR/voice-scan.jsonl")" = "blacklist" ]
  [ "$(jq -r '.marker' "$WORKDIR/voice-scan.jsonl")" = "great-question" ]
  [ "$(jq -r '.conv' "$WORKDIR/voice-scan.jsonl")" = "100000000000001" ]
}

@test "emits one row per blacklist phrase in a body" {
  write_convs <<'EOF'
{"id":"200000000000002","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"I understand your frustration. I will investigate this."}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/voice-scan.jsonl")" -eq 2 ]
  grep -q 'understand-frustration' "$WORKDIR/voice-scan.jsonl"
  grep -q '"marker":"investigate"' "$WORKDIR/voice-scan.jsonl"
}

@test "counts em-dashes and en-dashes per body as dash rows" {
  write_convs <<'EOF'
{"id":"300000000000003","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Range 1–2 and — also — done."}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.marker=="em-dash").count' "$WORKDIR/voice-scan.jsonl")" = "2" ]
  [ "$(jq -r 'select(.marker=="en-dash").count' "$WORKDIR/voice-scan.jsonl")" = "1" ]
}

@test "ignores tells that appear only in a CUSTOMER (non-admin) part" {
  write_convs <<'EOF'
{"id":"400000000000004","parts":[{"author":{"type":"user","id":"x"},"body":"Great question — really? I understand your frustration."}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/voice-scan.jsonl")" -eq 0 ]
}

@test "ignores a Caroline reply that is on-voice (no dashes, no blacklist)" {
  write_convs <<'EOF'
{"id":"500000000000005","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Thanks for reaching out! Your export is ready to download."}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/voice-scan.jsonl")" -eq 0 ]
}

@test "exits 0 with empty output over many clean convs (no set -e abort)" {
  # THE regression this script exists for: the deterministic scan must NEVER abort
  # the run when there are zero voice issues. The prose-instructed inline grader did
  # (a no-match sub-command under set -euo pipefail killed the whole daily run).
  write_convs <<'EOF'
{"id":"600000000000001","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Happy to help, your data is updating now."}]}
{"id":"600000000000002","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"All set, let me know if anything else comes up."}]}
{"id":"600000000000003","parts":[{"author":{"type":"user","id":"y"},"body":"thanks so much"}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/voice-scan.jsonl")" -eq 0 ]
}

@test "a null/absent body does not crash the scan" {
  write_convs <<'EOF'
{"id":"700000000000007","parts":[{"author":{"type":"admin","id":"caroline-admin-123"}}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/voice-scan.jsonl")" -eq 0 ]
}

@test "a malformed redacted line fails loud (non-zero), not a silent empty scan" {
  # Regression (QA review, PR #431): a broken conversations.redacted.jsonl (or any jq
  # failure) must abort the run, NOT report an empty successful scan that lets
  # Dimension A score a false clean. jq exits 0 on a no-match, so there is no `|| true`
  # to mask a real failure.
  printf '%s\n' '{"id":"1","parts":[]}' 'this is not valid json' > "$WORKDIR/conversations.redacted.jsonl"
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -ne 0 ]
}

@test "no input file -> empty result, exits 0" {
  rm -f "$WORKDIR/conversations.redacted.jsonl"
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORKDIR/voice-scan.jsonl" 2>/dev/null || echo 0)" -eq 0 ]
}

# --- voice-summary.txt: the deterministic AGGREGATE the grader reads verbatim. ---
# scan-voice.sh emits per-hit rows (voice-scan.jsonl) AND a precomputed summary so the
# grader never aggregates the JSONL itself. Letting the LLM aggregate caused the
# 2026-06-04 shadow proof-run to error: the codex agent ran `group_by(.kind+":"+.marker)`
# over voice-scan.jsonl WITHOUT `-s`, jq threw "Cannot index string with string", and the
# whole daily run failed with nothing delivered (slurp must happen inside the script).

@test "voice-summary.txt aggregates em/en dash totals and distinct conv counts" {
  write_convs <<'EOF'
{"id":"111","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"a — b — c"},{"author":{"type":"admin","id":"caroline-admin-123"},"body":"one more —"}]}
{"id":"222","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"x – y – z – w"}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/voice-summary.txt" ]
  grep -qx 'em-dash: 3 tells across 1 convs' "$WORKDIR/voice-summary.txt"
  grep -qx 'en-dash: 3 tells across 1 convs' "$WORKDIR/voice-summary.txt"
  grep -qx 'dash-total: 6 tells' "$WORKDIR/voice-summary.txt"
  # conv 111 = 3 em-dash tells, conv 222 = 3 en-dash tells -> both surface in top-dash-convs
  grep -q '111(3)' "$WORKDIR/voice-summary.txt"
  grep -q '222(3)' "$WORKDIR/voice-summary.txt"
}

@test "voice-summary.txt tallies phrase-blacklist hits by marker" {
  write_convs <<'EOF'
{"id":"333","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Great question! I will investigate this."}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  grep -qx 'blacklist-total: 2' "$WORKDIR/voice-summary.txt"
  grep -q 'great-question:1' "$WORKDIR/voice-summary.txt"
  grep -q 'investigate:1' "$WORKDIR/voice-summary.txt"
}

@test "voice-summary.txt blacklist-by-marker counts HITS (rows), consistent with blacklist-total, when a marker repeats across parts in one conv" {
  # Regression (QA #432): blacklist-total counts rows and the rubric scores -1 PER hit
  # (per {kind:"blacklist"} row), so blacklist-by-marker must also be a hit count. Two
  # "Great question" hits in ONE conversation = 2 rows -> total 2 AND great-question:2,
  # not 1 (a distinct-conv count would disagree with the total and the score).
  write_convs <<'EOF'
{"id":"555","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Great question, let me look."},{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Great question again, checking now."}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -rs 'map(select(.kind=="blacklist"))|length' "$WORKDIR/voice-scan.jsonl")" -eq 2 ]
  grep -qx 'blacklist-total: 2' "$WORKDIR/voice-summary.txt"
  grep -q 'great-question:2' "$WORKDIR/voice-summary.txt"
}

@test "voice-summary.txt reports all-zero on a clean run" {
  write_convs <<'EOF'
{"id":"444","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"Thanks for reaching out, your export is ready."}]}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  grep -qx 'em-dash: 0 tells across 0 convs' "$WORKDIR/voice-summary.txt"
  grep -qx 'dash-total: 0 tells' "$WORKDIR/voice-summary.txt"
  grep -qx 'top-dash-convs: (none)' "$WORKDIR/voice-summary.txt"
  grep -qx 'blacklist-total: 0' "$WORKDIR/voice-summary.txt"
  grep -qx 'blacklist-by-marker: (none)' "$WORKDIR/voice-summary.txt"
}

@test "voice-summary.txt is written (all-zero) even when there is no input file" {
  rm -f "$WORKDIR/conversations.redacted.jsonl"
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/voice-summary.txt" ]
  grep -qx 'dash-total: 0 tells' "$WORKDIR/voice-summary.txt"
  grep -qx 'blacklist-total: 0' "$WORKDIR/voice-summary.txt"
}

# ─── Sanitizer attribution (v2) ──────────────────────────────────────────────
# sanitize-typography.ts swaps every em-dash Caroline writes to an en-dash BEFORE
# the reply ships, and this scan reads shipped bodies. Uncorrected, the en-dash
# tally is mostly our own guard's output and the em-dash tally is structurally ~0
# -- which is how the weekly roll-up reported "6 en-dash voice tells" and the
# improver opened PR #892 rewriting a SOUL.md rule that could not move it.
# These pin the correction.

write_audit() { cat > "$WORKDIR/audit.jsonl"; }

@test "en-dash tally subtracts the guard's own em-dash rewrites" {
  # 4 en-dashes shipped, 3 of which the guard created from Caroline's em-dashes.
  write_convs <<'EOF'
{"id":"111","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"a – b – c – d – e"}]}
EOF
  write_audit <<'EOF'
{"kind":"typography","conv":"111","count":3}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  grep -qx 'en-dash: 1 tells across 1 convs' "$WORKDIR/voice-summary.txt"
  grep -qx 'em-dash-rewritten: 3 tells across 1 convs' "$WORKDIR/voice-summary.txt"
  grep -qx 'sanitizer-attribution: available' "$WORKDIR/voice-summary.txt"
}

@test "a conversation whose en-dashes are ALL guard rewrites scores zero tells" {
  # This is the exact shape that produced the false finding: every en-dash in the
  # shipped body came from the sanitizer, so Caroline's en-dash tell count is 0.
  write_convs <<'EOF'
{"id":"222","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"x – y – z"}]}
EOF
  write_audit <<'EOF'
{"kind":"typography","conv":"222","count":2}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  grep -qx 'en-dash: 0 tells across 0 convs' "$WORKDIR/voice-summary.txt"
  grep -qx 'dash-total: 0 tells' "$WORKDIR/voice-summary.txt"
}

@test "rewrites exceeding the sampled bodies floor at zero, never negative" {
  # The journal window and the 200-conversation sample do not line up exactly, so
  # the guard can report more rewrites than the sampled bodies contain.
  write_convs <<'EOF'
{"id":"333","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"only – one"}]}
EOF
  write_audit <<'EOF'
{"kind":"typography","conv":"333","count":9}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  grep -qx 'en-dash: 0 tells across 0 convs' "$WORKDIR/voice-summary.txt"
}

@test "no audit file: attribution is 'unavailable', NOT a measured zero" {
  # An unmeasured zero and a measured zero are different facts. Printing 0 here is
  # what let the guardrail's output be read as Caroline's prose in the first place.
  write_convs <<'EOF'
{"id":"444","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"p – q"}]}
EOF
  rm -f "$WORKDIR/audit.jsonl"
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  grep -qx 'em-dash-rewritten: unavailable' "$WORKDIR/voice-summary.txt"
  grep -qx 'sanitizer-attribution: unavailable' "$WORKDIR/voice-summary.txt"
  # ...and the observed count is reported unadjusted rather than silently dropped.
  grep -qx 'en-dash: 1 tells across 1 convs' "$WORKDIR/voice-summary.txt"
}

@test "an unreadable journal (source=none) is unavailable even with an audit file" {
  # fetch-audit.sh writes an audit with no typography rows when no journal source
  # is readable, which is indistinguishable from a genuinely clean week.
  write_convs <<'EOF'
{"id":"555","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"m – n"}]}
EOF
  write_audit <<'EOF'
{"kind":"leak","marker":"x","snippet":"y"}
EOF
  export CAROLINE_REASONING_LEAK_SOURCE=none
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  grep -qx 'sanitizer-attribution: unavailable' "$WORKDIR/voice-summary.txt"
}

@test "an audit with a readable journal and no rewrites is a measured zero" {
  write_convs <<'EOF'
{"id":"666","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"r – s"}]}
EOF
  write_audit <<'EOF'
{"kind":"leak","marker":"x","snippet":"y"}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  grep -qx 'em-dash-rewritten: 0 tells across 0 convs' "$WORKDIR/voice-summary.txt"
  grep -qx 'sanitizer-attribution: available' "$WORKDIR/voice-summary.txt"
  grep -qx 'en-dash: 1 tells across 1 convs' "$WORKDIR/voice-summary.txt"
}

@test "the guard's per-CONVERSATION count is subtracted ONCE, not once per reply" {
  # scan-voice emits one row per Caroline PART; the typography audit line is per
  # CONVERSATION. Subtracting the conversation total from every part row
  # over-corrects by (parts - 1) x rewrites. Here: 3 replies, 4 en-dashes total,
  # 2 of them the guard's -- so 2 real tells, not 0.
  write_convs <<'EOF'
{"id":"777","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"a – b"},{"author":{"type":"admin","id":"caroline-admin-123"},"body":"c – d"},{"author":{"type":"admin","id":"caroline-admin-123"},"body":"e – f – g"}]}
EOF
  write_audit <<'EOF'
{"kind":"typography","conv":"777","count":2}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  grep -qx 'en-dash: 2 tells across 1 convs' "$WORKDIR/voice-summary.txt"
  grep -qx 'em-dash-rewritten: 2 tells across 1 convs' "$WORKDIR/voice-summary.txt"
}

@test "the syslog fallback source is unattributable, not a partial measurement" {
  # fetch-audit.sh's syslog branch has no --since window, so its typography rows
  # cover an unknown fraction of the scanned window. Subtracting that as if it
  # were the whole truth under-corrects and labels the result measured.
  write_convs <<'EOF'
{"id":"888","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"h – i – j"}]}
EOF
  write_audit <<'EOF'
{"kind":"typography","conv":"888","count":1}
EOF
  export CAROLINE_REASONING_LEAK_SOURCE=syslog
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  grep -qx 'sanitizer-attribution: unavailable' "$WORKDIR/voice-summary.txt"
  grep -qx 'em-dash-rewritten: unavailable' "$WORKDIR/voice-summary.txt"
  grep -qx 'en-dash: 2 tells across 1 convs' "$WORKDIR/voice-summary.txt"
}

@test "a malformed typography row degrades attribution to unavailable" {
  # Dropping an unparseable row shrinks the rewrite map while still reporting
  # `available`, so the unadjusted en-dashes get graded as Caroline's -- the
  # exact false-green this metric exists to remove.
  write_convs <<'EOF'
{"id":"777","parts":[{"author":{"type":"admin","id":"caroline-admin-123"},"body":"a – b – c"}]}
EOF
  write_audit <<'EOF'
{"kind":"typography","conv":"777","count":1}
{"kind":"typography_error","reason":"unparseable","sample":"[intercom:typography] conv= count="}
EOF
  run "$SCRIPTS_DIR/scan-voice.sh"
  [ "$status" -eq 0 ]
  grep -qx 'sanitizer-attribution: unavailable' "$WORKDIR/voice-summary.txt"
  grep -qx 'em-dash-rewritten: unavailable' "$WORKDIR/voice-summary.txt"
  # ...and the en-dash count is reported UNADJUSTED rather than partially corrected.
  grep -qx 'en-dash: 2 tells across 1 convs' "$WORKDIR/voice-summary.txt"
}
