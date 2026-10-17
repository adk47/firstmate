#!/usr/bin/env bats
# Hermetic tests for fraud-cases-query.sh. Synthetic corpora live in a per-test tmp dir
# (FRAUD_CASES_DIR); the REAL corpus is only touched by the read-only tests at the bottom.

setup() {
  SKILL_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${SKILL_ROOT}/scripts/fraud-cases-query.sh"
  CASES="${BATS_TEST_TMPDIR}/cases"
  mkdir -p "$CASES"
  export FRAUD_CASES_DIR="$CASES"
}

# mkcase <file-stem> [sed-expr]  — writes a VALID case, then applies the optional sed mutation.
mkcase() {
  local stem="$1" mut="${2:-}" f="$CASES/$1.md"
  cat > "$f" <<CASE
---
id: "${stem}"
title: "Synthetic case ${stem}"
source: "repo_mined"
date_opened: "${stem:0:10}"
date_closed: null
vector: "credit_self_add"
signals: ["role_inflation", "bulk_self_additions"]
evidence_sources: ["docs/credit-verification/fraud-detection-spec.md"]
outcome: "inconclusive"
actions_taken: ["none"]
detector_factors_that_fired: ["role_inflation"]
what_would_have_caught_it_earlier: "A labeled outcome."
related_profiles: ["11111111-1111-1111-1111-111111111111"]
---

# Body

Ids and counts only.
CASE
  if [ -n "$mut" ]; then sed -i.bak -E "$mut" "$f" && rm -f "$f.bak"; fi
}

# ---- query behaviour -------------------------------------------------------------

@test "vector filter returns matching cases, exit 0" {
  mkcase 2026-01-01-a
  mkcase 2026-01-02-b 's/^vector: .*/vector: "referral_abuse"/'
  run bash "$SCRIPT" --vector credit_self_add
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-01-01-a"* ]]
  [[ "$output" != *"2026-01-02-b"* ]]
}

@test "output carries id, one-line summary and path" {
  mkcase 2026-01-01-a
  run bash "$SCRIPT" --vector credit_self_add
  [[ "$output" == *"2026-01-01-a"* ]]
  [[ "$output" == *"Synthetic case 2026-01-01-a"* ]]
  [[ "$output" == *"cases/2026-01-01-a.md"* ]]
}

@test "unknown vector exits non-zero" {
  mkcase 2026-01-01-a
  run bash "$SCRIPT" --vector nonsense
  [ "$status" -ne 0 ]
}

@test "unknown outcome exits non-zero" {
  mkcase 2026-01-01-a
  run bash "$SCRIPT" --outcome nonsense
  [ "$status" -ne 0 ]
}

@test "outcome and signal filters narrow the result, filters AND together" {
  mkcase 2026-01-01-a
  mkcase 2026-01-02-b 's/^outcome: .*/outcome: "confirmed_fraud"/; s/"bulk_self_additions"/"velocity"/'
  run bash "$SCRIPT" --outcome confirmed_fraud
  [[ "$output" == *"2026-01-02-b"* && "$output" != *"2026-01-01-a"* ]]
  run bash "$SCRIPT" --signal bulk_self_additions
  [[ "$output" == *"2026-01-01-a"* && "$output" != *"2026-01-02-b"* ]]
  run bash "$SCRIPT" --outcome confirmed_fraud --signal bulk_self_additions
  [ "$status" -eq 0 ]
  [[ "$output" != *"2026-01-0"* ]]
}

@test "unknown option exits non-zero" {
  mkcase 2026-01-01-a
  run bash "$SCRIPT" --frobnicate
  [ "$status" -ne 0 ]
}

# ---- validation: every one of these must go RED --------------------------------------

@test "valid corpus passes --validate" {
  mkcase 2026-01-01-a
  run bash "$SCRIPT" --validate
  [ "$status" -eq 0 ]
}

@test "vector outside the closed list fails validation" {
  mkcase 2026-01-01-a 's/^vector: .*/vector: "made_up_vector"/'
  run bash "$SCRIPT" --validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"vector"* ]]
}

@test "a query also refuses a corpus holding an invalid case (fail loud)" {
  mkcase 2026-01-01-a 's/^vector: .*/vector: "made_up_vector"/'
  run bash "$SCRIPT" --outcome inconclusive
  [ "$status" -ne 0 ]
}

@test "outcome outside the closed list fails validation" {
  mkcase 2026-01-01-a 's/^outcome: .*/outcome: "guilty"/'
  run bash "$SCRIPT" --validate
  [ "$status" -ne 0 ]
}

@test "detector factor outside the six known names fails validation" {
  mkcase 2026-01-01-a 's/^detector_factors_that_fired: .*/detector_factors_that_fired: ["vibes"]/'
  run bash "$SCRIPT" --validate
  [ "$status" -ne 0 ]
}

@test "missing required field fails validation" {
  mkcase 2026-01-01-a '/^what_would_have_caught_it_earlier:/d'
  run bash "$SCRIPT" --validate
  [ "$status" -ne 0 ]
}

@test "unknown frontmatter key fails validation" {
  mkcase 2026-01-01-a
  awk '/^related_profiles:/ { print "surprise: 1" } { print }' "$CASES/2026-01-01-a.md" > "$BATS_TEST_TMPDIR/x" && mv "$BATS_TEST_TMPDIR/x" "$CASES/2026-01-01-a.md"
  run bash "$SCRIPT" --validate
  [ "$status" -ne 0 ]
}

@test "id that differs from the filename fails validation" {
  mkcase 2026-01-01-a 's/^id: .*/id: "2026-01-01-other"/'
  run bash "$SCRIPT" --validate
  [ "$status" -ne 0 ]
}

@test "filename date that differs from date_opened fails validation" {
  mkcase 2026-01-01-a 's/^date_opened: .*/date_opened: "2026-02-02"/'
  run bash "$SCRIPT" --validate
  [ "$status" -ne 0 ]
}

@test "a frontmatter value that is not JSON fails validation" {
  mkcase 2026-01-01-a 's/^signals: .*/signals: [role_inflation, oops/'
  run bash "$SCRIPT" --validate
  [ "$status" -ne 0 ]
}

@test "an email address anywhere in a case fails validation (no PII)" {
  mkcase 2026-01-01-a
  printf '\nContact: someone@example.com\n' >> "$CASES/2026-01-01-a.md"
  run bash "$SCRIPT" --validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"email"* ]]
}

@test "a phone number anywhere in a case fails validation (no PII)" {
  mkcase 2026-01-01-a
  printf '\nCall +1 415 555 0199 or (415) 555-0199\n' >> "$CASES/2026-01-01-a.md"
  run bash "$SCRIPT" --validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"phone"* ]]
}

@test "ids, counts and dates are not mistaken for phone numbers" {
  mkcase 2026-01-01-a
  printf '\nUser 162720, 5,762 events, 246M streams, 2026-05-04, 11111111-1111-1111-1111-111111111111\n' >> "$CASES/2026-01-01-a.md"
  run bash "$SCRIPT" --validate
  [ "$status" -eq 0 ]
}

@test "source outside repo_mined|notion fails validation" {
  mkcase 2026-01-01-a 's/^source: .*/source: "rumour"/'
  run bash "$SCRIPT" --validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"source"* ]]
}

@test "notion is an accepted source" {
  mkcase 2026-01-01-a 's/^source: .*/source: "notion"/'
  run bash "$SCRIPT" --validate
  [ "$status" -eq 0 ]
}

@test "missing source fails validation" {
  mkcase 2026-01-01-a '/^source: /d'
  run bash "$SCRIPT" --validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing field: source"* ]]
}

@test "related_profiles must be ids, not free text" {
  mkcase 2026-01-01-a 's/^related_profiles: .*/related_profiles: ["Some Person"]/'
  run bash "$SCRIPT" --validate
  [ "$status" -ne 0 ]
}

@test "a case with an empty frontmatter block is rejected, not reported valid" {
  printf -- '---\n---\n\n# Body\n' > "$CASES/2026-01-01-empty.md"
  run bash "$SCRIPT" --validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"INVALID 2026-01-01-empty.md"* ]]
  [[ "$output" != *"OK:"* ]]
}

@test "empty corpus is an error, not a silent empty result" {
  run bash "$SCRIPT" --vector credit_self_add
  [ "$status" -ne 0 ]
}

# ---- read-only ---------------------------------------------------------------------

@test "script never writes: corpus checksum is unchanged by every mode" {
  mkcase 2026-01-01-a
  before=$(find "$CASES" -type f -exec cksum {} + | sort)
  bash "$SCRIPT" --vector credit_self_add >/dev/null
  bash "$SCRIPT" --validate >/dev/null
  bash "$SCRIPT" --index >/dev/null
  after=$(find "$CASES" -type f -exec cksum {} + | sort)
  [ "$before" = "$after" ]
  [ "$(ls "$CASES" | wc -l)" -eq 1 ]
}

@test "script source holds no network, DB or file-mutating command" {
  # comment lines stripped; a forbidden word only counts in command position
  local code forbidden
  code=$(grep -vE '^[[:space:]]*#' "$SCRIPT")
  forbidden='(^|[|;&(]|[$][(])[[:space:]]*(curl|wget|ssh|scp|psql|trino|nc|kubectl|rm|mv|cp|tee|git|sqlite3)([[:space:]]|$)'
  run grep -nE "$forbidden" <<<"$code"
  [ "$status" -ne 0 ]
}

# ---- the real corpus ---------------------------------------------------------------------

@test "REAL corpus: validates, holds at least the 6 seed cases" {
  unset FRAUD_CASES_DIR
  run bash "$SCRIPT" --validate
  [ "$status" -eq 0 ]
  [ "$(ls "$SKILL_ROOT"/cases/*.md | wc -l)" -ge 6 ]
}

@test "REAL corpus: --vector credit_self_add returns at least one case" {
  unset FRAUD_CASES_DIR
  cd "$SKILL_ROOT"
  run bash scripts/fraud-cases-query.sh --vector credit_self_add
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "REAL corpus: INDEX.md regenerate-and-diff is clean" {
  unset FRAUD_CASES_DIR
  run bash "$SCRIPT" --index
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") "$SKILL_ROOT/INDEX.md"
}

@test "REAL corpus: no email address and no name from the source docs" {
  # Emails: the same regex the validator uses. Names: every person/handle named in the source
  # documents this corpus was mined from (case-insensitive).
  run grep -rEn '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$SKILL_ROOT/cases"
  [ "$status" -ne 0 ]
  run grep -rniwE 'ahmed|ibrahim|maximilian|larson|veronica|earnhart|ramazan|pakir|pakır|rochester|ming|vauz|roberto|junior|javon|vrancis|ksj|hannah|baker|liza|basco|aaron|himoly|anamodyhiba|moodyhebah|rightstune|max1million' "$SKILL_ROOT/cases"
  [ "$status" -ne 0 ]
}
