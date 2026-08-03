#!/usr/bin/env bats
# Tests for check-collaborator-doctrine.sh: the mechanical backstop that keeps the
# derived-table doctrine (catalog_profile_collaboration is rebuilt from track co-credits,
# so hand-written SQL is silently reverted) from regressing out of
# skills-all/muso-ops-collaborators/SKILL.md, and that stops ANY skill doc from handing
# agents write-SQL against the collaboration / aggregation serving tables.
#
# Hermetic: builds a throwaway repo tree (skills-all/ + workspaces/) under a temp dir and
# points the guard at it via REPO_ROOT, so a test never edits the tracked sources. The
# real doctrine skill is copied in so the positive anchors resolve.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-collaborator-doctrine.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  mkdir -p "$TEST_TMPDIR/skills-all/muso-ops-collaborators" \
           "$TEST_TMPDIR/workspaces/someagent/skills/some-skill"
  cp "$HYDRA_REPO/skills-all/muso-ops-collaborators/SKILL.md" \
     "$TEST_TMPDIR/skills-all/muso-ops-collaborators/SKILL.md"
  OTHER_SKILL="$TEST_TMPDIR/workspaces/someagent/skills/some-skill/SKILL.md"
  printf -- '---\nname: some-skill\n---\n\nNothing forbidden here.\n' > "$OTHER_SKILL"
  export REPO_ROOT="$TEST_TMPDIR"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# write_other <body> — replace the innocent sibling skill's body.
write_other() {
  printf -- '---\nname: some-skill\n---\n\n%s\n' "$1" > "$OTHER_SKILL"
}

@test "passes on a clean tree" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

# --- negative scan: write-SQL in ANY other skill doc -------------------------
# SQL keywords are case-insensitive to the engine and agents write them in every
# casing. An uppercase-only guard passed the most common spelling while still
# claiming to reject direct writes.

@test "rejects UPPERCASE DELETE FROM a serving table" {
  write_other 'DELETE FROM catalog_profile_collaboration WHERE profile_id = 1;'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

@test "rejects lowercase delete from a serving table" {
  write_other 'delete from catalog_profile_collaboration where profile_id = 1;'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

@test "rejects MixedCase Delete From a serving table" {
  write_other 'Delete From catalog_profile_collaboration Where profile_id = 1;'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

@test "rejects lowercase insert into a serving table" {
  write_other 'insert into catalog_profile_aggregations (profile_id) values (1);'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

@test "rejects lowercase update ... set on a serving table" {
  write_other 'update catalog_profile_aggregations set collaborations_count = 0;'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

# Verb coverage: the guard claims to reject ANY direct write, so TRUNCATE and
# Postgres MERGE INTO must not slip past it. Both are fully destructive against a
# table that is rebuilt from source.

@test "rejects TRUNCATE TABLE on a serving table" {
  write_other 'TRUNCATE TABLE catalog_profile_collaboration;'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

@test "rejects bare truncate (no TABLE keyword) on a serving table" {
  write_other 'truncate catalog_profile_aggregations;'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

@test "rejects MERGE INTO a serving table" {
  write_other 'MERGE INTO catalog_profile_aggregations t USING src s ON t.id = s.id;'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

@test "rejects lowercase merge into a serving table" {
  write_other 'merge into catalog_profile_collaboration t using src s on t.id = s.id;'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

@test "rejects DROP TABLE on a serving table" {
  write_other 'DROP TABLE catalog_profile_collaboration;'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

@test "rejects ALTER TABLE on a serving table" {
  write_other 'ALTER TABLE catalog_profile_aggregations ADD COLUMN x int;'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

@test "does not trip on prose using truncate/merge as ordinary English" {
  write_other 'We truncate the report at 30 rows, then merge the collaborator counts by hand.'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "rejects write-SQL split across lines (file is flattened before matching)" {
  write_other '```
DELETE FROM
  catalog_profile_collaboration
WHERE bucket = 1;
```'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

# COPY is a real Postgres bulk-load mutation, but bare `COPY <table> FROM` also
# matches ordinary prose ("copy catalog_profile_collaboration rows from Trino"),
# which is why it was initially left out. Anchoring on a real COPY *source*
# (STDIN / PROGRAM / a quoted path) gets the true positive without the prose one.

@test "rejects COPY ... FROM STDIN into a serving table" {
  write_other 'COPY catalog_profile_collaboration (profile_id, collaborator_id) FROM STDIN;'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

@test "rejects lowercase copy ... from stdin" {
  write_other 'copy catalog_profile_collaboration (profile_id) from stdin;'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "rejects schema-qualified COPY ... FROM PROGRAM" {
  write_other 'COPY public.catalog_profile_aggregations FROM PROGRAM $$curl http://x$$;'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "rejects COPY ... FROM a quoted path" {
  write_other "COPY catalog_profile_collaboration FROM '/tmp/rows.csv';"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "does NOT trip on prose using copy/from as ordinary English" {
  write_other 'We copy catalog_profile_collaboration rows from Trino every morning.'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "does NOT trip on COPY ... TO (that direction is a read)" {
  write_other "COPY catalog_profile_collaboration TO '/tmp/out.csv';"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "allows a plain SELECT against a serving table" {
  write_other 'muso query "SELECT count(*) FROM catalog_profile_collaboration WHERE bucket = 29"'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "allows prose that merely mentions updating a serving table" {
  write_other 'The offline Spark job will update catalog_profile_aggregations later.'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "allows write-SQL against an unrelated table" {
  write_other 'DELETE FROM some_other_table WHERE id = 1;'
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

# --- the doctrine skill's own exemption -------------------------------------

@test "the doctrine skill may quote the DELETE predicate (that quotation is the deterrent)" {
  # It ships with the real predicate in its RED LINE section and must still pass.
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "a sanctioned workspace COPY of the doctrine skill is exempt too (path-shape match)" {
  mkdir -p "$TEST_TMPDIR/workspaces/operations/skills/muso-ops-collaborators"
  cp "$HYDRA_REPO/skills-all/muso-ops-collaborators/SKILL.md" \
     "$TEST_TMPDIR/workspaces/operations/skills/muso-ops-collaborators/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

# The doctrine skill is NOT path-exempt from the negative scan — only its one
# sanctioned quotation (the writer's parameterized DELETE predicate) is redacted.
# A path-wide exemption would leave the very skill that owns collaborator-removal
# requests unguarded: a later edit could keep every positive anchor and still add
# a fresh forbidden statement with CI green.

# append_to <file> <sql> — add a fenced SQL block to an existing skill doc.
append_to() {
  printf '\n```\n%s\n```\n' "$2" >> "$1"
}

@test "doctrine skill is still scanned: a SECOND forbidden statement fails" {
  append_to "$TEST_TMPDIR/skills-all/muso-ops-collaborators/SKILL.md" \
    'INSERT INTO catalog_profile_collaboration (profile_id) VALUES (1);'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

@test "doctrine skill is still scanned: an added TRUNCATE fails" {
  append_to "$TEST_TMPDIR/skills-all/muso-ops-collaborators/SKILL.md" \
    'TRUNCATE TABLE catalog_profile_aggregations;'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

@test "a sanctioned workspace COPY of the doctrine skill is scanned too" {
  mkdir -p "$TEST_TMPDIR/workspaces/operations/skills/muso-ops-collaborators"
  cp "$HYDRA_REPO/skills-all/muso-ops-collaborators/SKILL.md" \
     "$TEST_TMPDIR/workspaces/operations/skills/muso-ops-collaborators/SKILL.md"
  append_to "$TEST_TMPDIR/workspaces/operations/skills/muso-ops-collaborators/SKILL.md" \
    'DELETE FROM catalog_profile_aggregations WHERE profile_id = 1;'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

# The exemption is an EXACT literal match on the sanctioned quotation, not a
# line-range delete. A range would also erase everything BETWEEN its anchors, so
# forbidden SQL parked inside the quoted block would be redacted before the scan
# and CI would stay green — a bypass in the one file the exemption exists for.

# inject_inside_quote <sql> — insert a statement between the sanctioned block's
# DELETE line and its WHERE line, i.e. strictly inside the old range.
inject_inside_quote() {
  python3 - "$TEST_TMPDIR/skills-all/muso-ops-collaborators/SKILL.md" "$1" <<'PY'
import sys
p, sql = sys.argv[1], sys.argv[2]
L = open(p).read().split("\n")
for i, l in enumerate(L):
    if l.strip() == "DELETE FROM catalog_profile_collaboration":
        L.insert(i + 1, sql)
        break
else:
    raise SystemExit("sanctioned quote opener not found")
open(p, "w").write("\n".join(L))
PY
}

@test "forbidden SQL injected INSIDE the sanctioned quote is still caught" {
  inject_inside_quote 'TRUNCATE TABLE catalog_profile_aggregations;'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

@test "an INSERT injected inside the sanctioned quote is still caught" {
  inject_inside_quote 'INSERT INTO catalog_profile_collaboration (profile_id) VALUES (1);'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write-SQL"* ]]
}

@test "reformatting the sanctioned quote fails CLOSED (exemption must be updated deliberately)" {
  local skill="$TEST_TMPDIR/skills-all/muso-ops-collaborators/SKILL.md"
  perl -0pi -e 's/WHERE bucket = %s/WHERE  bucket = %s/' "$skill"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

# --- positive anchors on the doctrine skill ---------------------------------

@test "fails if the derived-table framing is removed" {
  local skill="$TEST_TMPDIR/skills-all/muso-ops-collaborators/SKILL.md"
  grep -vF -- "The collaborators list is derived" "$skill" > "$skill.tmp"
  mv "$skill.tmp" "$skill"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if the RED LINE heading is removed" {
  local skill="$TEST_TMPDIR/skills-all/muso-ops-collaborators/SKILL.md"
  grep -vF -- "RED LINE — never write SQL against these tables" "$skill" > "$skill.tmp"
  mv "$skill.tmp" "$skill"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

@test "fails if the no-pair-suppression statement is removed" {
  local skill="$TEST_TMPDIR/skills-all/muso-ops-collaborators/SKILL.md"
  grep -vF -- "DOES NOT EXIST" "$skill" > "$skill.tmp"
  mv "$skill.tmp" "$skill"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
}

# --- fail-closed behaviour ---------------------------------------------------

@test "refuses to pass vacuously when the doctrine skill is missing" {
  rm -f "$TEST_TMPDIR/skills-all/muso-ops-collaborators/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "refuses to pass vacuously when there are no SKILL.md files at all" {
  rm -rf "$TEST_TMPDIR/workspaces" "$TEST_TMPDIR/skills-all"
  mkdir -p "$TEST_TMPDIR/workspaces" "$TEST_TMPDIR/skills-all"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}
