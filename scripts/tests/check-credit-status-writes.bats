#!/usr/bin/env bats
# Tests for check-credit-status-writes.sh: hydra code never writes a credit status directly and never moves one
# silently (Fable GO 2026-10-31). Hermetic: each test builds a synthetic tree (no git) and runs the guard on it.
# The real tree is guarded by the `validate-code` CI step that runs the script itself; scanning it here as well
# duplicated that work and timed out under the 2-CPU bats shard.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-credit-status-writes.sh"

setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/scripts/tests" "$T/workspaces/ops/scripts" "$T/policies"
  : > "$T/policies/credit-status-write-allowlist.txt"
  echo 'print("hello")' > "$T/scripts/ok.py"
}

teardown() { rm -rf "$T"; }

@test "validate-code still scans the real tree (the covering check for the removed case)" {
  # This suite no longer scans the real tree; the `validate-code` job of .github/workflows/pr-validate.yml is the
  # one remaining real-tree scan (`scripts/check-credit-status-writes.sh` at the repo root). Pin the step here so
  # a later edit that drops it fails CI instead of silently leaving hydra's credit-status writes unguarded.
  run awk '
    /^  [A-Za-z0-9_-]+:/ { job = $1; sub(":$", "", job) }
    job == "validate-code" && /bash scripts\/check-credit-status-writes\.sh/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$HYDRA_REPO/.github/workflows/pr-validate.yml"
  [ "$status" -eq 0 ]
}

@test "a clean synthetic tree passes" {
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ]
}

@test "a direct SQL write fails, in any quoting and case" {
  for line in 'UPDATE credit_requests SET status = 1' 'update "credit_requests" set status' \
              'q = "Update public.credit_requests SET x"' 'sql`UPDATE \"credit_requests\" SET`' \
              'UPDATE "public"."credit_requests" SET status = 1' 'UPDATE [credit_requests] SET status = 1'; do
    printf '%s\n' "$line" > "$T/workspaces/ops/scripts/w.js"
    run bash "$SCRIPT" --root "$T"
    [ "$status" -eq 1 ] || { echo "not caught: $line"; false; }
    [[ "$output" == *"direct credit-status write"* ]]
  done
}

@test "QA #1578: a statement broken across lines is one statement, not innocent lines" {
  # the exact evasions QA reproduced through this entrypoint: each returned OK before the scanner replaced the grep
  printf '%s\n' 'DB.execute("""UPDATE' '  "public"."credit_requests"' '  SET status = %s""")' > "$T/scripts/nl.py"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "not caught: multiline UPDATE"; false; }
  [[ "$output" == *"nl.py"*"direct credit-status write"* ]]
  rm "$T/scripts/nl.py"
  printf '%s\n' 'coll = db["credit_requests"]' 'coll' '  .updateMany(query, update)' > "$T/scripts/nlm.py"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "not caught: multiline .updateMany"; false; }
  [[ "$output" == *"Mongo credit-request write"* ]]
  rm "$T/scripts/nlm.py"
  printf '%s\n' 'payload = {"requestIds": ids,' '           "notify":' '             false}' > "$T/scripts/nln.py"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "not caught: multiline notify:false"; false; }
  [[ "$output" == *"silent credit move"* ]]
}

@test "QA #1578: the hit is reported at the line the statement starts on" {
  printf '%s\n' 'x = 1' 'y = 2' 'DB.execute("""UPDATE' '  credit_requests SET status = 1""")' > "$T/scripts/nl.py"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/nl.py:3 "* ]]
}

@test "a Sequelize model write fails" {
  echo 'await CreditRequests.update({ status: "approved" }, { where })' > "$T/scripts/w.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ]
}

@test "a Mongo write on a credit-requests collection fails; a read does not" {
  for line in 'db.credit_requests.update_one({"_id": i}, {"$set": {"status": "approved"}})' \
              'await db.collection("creditRequests").updateMany(q, { $set: { status: "rejected" } })' \
              'coll = db["credit_requests"]; coll.find_one_and_update(q, u)'; do
    printf '%s\n' "$line" > "$T/scripts/m.py"
    run bash "$SCRIPT" --root "$T"
    [ "$status" -eq 1 ] || { echo "not caught: $line"; false; }
    [[ "$output" == *"Mongo credit-request write"* ]]
  done
  echo 'rows = db.credit_requests.find({"status": "approved"})' > "$T/scripts/m.py"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ]
}

@test "red mutant: a direct write injected into a REAL hydra file turns the guard red" {
  mkdir -p "$T/scripts/credit_review"
  cp "$HYDRA_REPO/scripts/credit_review/fable_executor.py" "$T/scripts/credit_review/"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ]
  printf '\nDB.execute("UPDATE credit_requests SET status = %%s WHERE id = %%s", ("approved", rid))\n' \
    >> "$T/scripts/credit_review/fable_executor.py"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/credit_review/fable_executor.py"* ]]
}

@test "QA #1578 red mutant: the MULTILINE forms injected into a REAL hydra file turn the guard red" {
  mkdir -p "$T/scripts/credit_review"
  cp "$HYDRA_REPO/scripts/credit_review/fable_executor.py" "$T/scripts/credit_review/"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ]
  printf '\ncur.execute("""UPDATE\n  \"public\".\"credit_requests\"\n  SET status = %%s WHERE id = %%s""", ("approved", rid))\n' \
    >> "$T/scripts/credit_review/fable_executor.py"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "not caught: multiline UPDATE in a real file"; false; }
  [[ "$output" == *"scripts/credit_review/fable_executor.py"* ]]
  # and the silent move with its value on the next line, appended to the same real file
  cp "$HYDRA_REPO/scripts/credit_review/fable_executor.py" "$T/scripts/credit_review/fable_executor.py"
  printf '\nbody = {"requestIds": ids,\n        "notify":\n          false}\n' >> "$T/scripts/credit_review/fable_executor.py"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "not caught: multiline notify:false in a real file"; false; }
}

@test "a notify:false body fails in python, json and js forms" {
  for line in 'body = {"requestIds": ids, "status": "processing", "notify": False}' \
              "body = {'notify': False}" 'payload = {"notify":false}' 'call({ requestIds, notify: false })' \
              'put(ids, notify=False)'; do
    printf '%s\n' "$line" > "$T/scripts/m.py"
    run bash "$SCRIPT" --root "$T"
    [ "$status" -eq 1 ] || { echo "not caught: $line"; false; }
    [[ "$output" == *"silent credit move"* ]]
  done
}

@test "notify true, other keys and reads are not flagged" {
  printf '%s\n' 'body = {"notify": True}' 'x = {"notify_all": False}' 'SELECT status FROM credit_requests' \
                'if args.no_notify:' 'notifyFalse = 1' > "$T/scripts/ok2.py"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ]
}

@test "tests and docs are out of scope" {
  echo 'UPDATE credit_requests SET status' > "$T/scripts/tests/fixture.py"
  echo 'UPDATE credit_requests SET status' > "$T/scripts/notes.md"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ]
}

@test "an allowlisted file passes; the entry is exact" {
  echo 'UPDATE credit_requests SET status' > "$T/scripts/w.sql"
  echo 'scripts/w.sql   # reason: test' > "$T/policies/credit-status-write-allowlist.txt"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ]
  echo 'scripts/w' > "$T/policies/credit-status-write-allowlist.txt"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ]
}

@test "a missing allowlist is unreadable input" {
  rm "$T/policies/credit-status-write-allowlist.txt"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 2 ]
}

@test "a SQL comment between UPDATE and the table is caught through the entrypoint" {
  printf "UPDATE /* decision repair */ credit_requests SET status = 'approved' WHERE id = 1;\n" > "$T/scripts/probe.sql"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/probe.sql"* ]]
}

@test "a line comment across the break and a commented quoted name are caught too" {
  printf "UPDATE -- repair\n \"public\"./*x*/\"credit_requests\" SET status = 'x';\n" > "$T/scripts/probe2.sql"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"probe2.sql:1"* ]]
}

@test "a comment-separated notify:false is caught through the entrypoint" {
  printf "const body = { notify: /* decision repair */ false };\n" > "$T/scripts/probe.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"probe.js:1"* ]]
}

@test "a string literal containing // does not hide a same-line write" {
  printf 'const marker = "//"; db.credit_requests.updateOne(q, u);\n' > "$T/scripts/probe4.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"probe4.js:1"* ]]
}

@test "a collection alias is caught at any distance" {
  { printf 'coll = db["credit_requests"];\n'; for _ in $(seq 60); do printf 'x = 0;\n'; done
    printf 'coll.updateMany(q, u);\n'; } > "$T/scripts/probe5.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"probe5.js:62"* ]]
}

@test "a multiline collection binding still binds its alias" {
  { printf 'const coll = db[\n  "credit_requests"\n];\n'; for _ in $(seq 90); do printf 'filler();\n'; done
    printf 'coll.updateMany(q, u);\n'; } > "$T/scripts/probe6.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"probe6.js:94"* ]]
}

@test "a PostgreSQL UPDATE ONLY on the credit table is caught through the entrypoint" {
  printf "UPDATE ONLY credit_requests SET status='approved' WHERE id=1;\n" > "$T/scripts/probe7.sql"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"probe7.sql:1"* ]]
}

@test "a status-setting upsert is caught through the entrypoint" {
  printf "INSERT INTO credit_requests (id, status) VALUES (42, 'approved') ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status;\n" > "$T/scripts/probe8.sql"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"probe8.sql:1"* ]]
}

@test "probe9: a Mongo insertOne on the credit-requests collection is refused (QA #1578 r8)" {
  printf "db.credit_requests.insertOne({ id: 42, status: \"approved\" });\n" > "$T/scripts/probe9.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"probe9.js:1"* ]]
}

@test "probe10: an UPDATE with no space before a -- comment is refused (QA #1578 r9, finding 3)" {
  # PostgreSQL: `UPDATE--repair` NEWLINE `credit_requests SET status='approved';` IS an update of the table. The
  # stripper used to require one of a fixed set of characters BEFORE the `--`, and `E` is not in it, so the dashes
  # stayed in the text and `UPDATE\s+credit_requests` could not match across them.
  printf "UPDATE--repair\ncredit_requests SET status='approved';\n" > "$T/scripts/probe10.sql"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "not caught: UPDATE--repair"; false; }
  [[ "$output" == *"probe10.sql:1"* ]]
}

@test "probe11: a collection built from a constant is refused (QA #1578 r9, finding 1)" {
  printf 'const CREDIT_COLLECTION = "credit_requests";\nconst requests = db.collection(CREDIT_COLLECTION);\nrequests.insertOne({ status: "approved" });\n' > "$T/scripts/probe11.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "not caught: constant-backed receiver"; false; }
  [[ "$output" == *"probe11.js:3"* ]]
}

@test "probe12: a read plus an unrelated collection write is NOT a violation (QA #1578 r9, finding 2)" {
  # the 400-character window bound any write verb to any nearby mention of the collection, so a legitimate tracked
  # script that reads credit requests and writes an unrelated collection could not merge.
  printf 'const rows = db.credit_requests.find({});\ndb.artists.updateOne(q, u);\n' > "$T/scripts/probe12.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ] || { echo "false positive: read + unrelated write"; false; }
}

@test "probe13: a collection(...) call broken before its closing paren is refused (QA #1578 r10)" {
  # Reproduced through this entrypoint at 7e4fab1d: the receiver regex used a character class for the argument
  # list, so the newline before `)` ended the receiver and the insertOne was never bound to the collection.
  printf 'db.collection(\n  "credit_requests"\n).insertOne({ status: "approved" });\n' > "$T/scripts/probe13.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "not caught: newline before the closing paren"; false; }
  [[ "$output" == *"probe13.js:1"* ]]
}

@test "probe14: a collection(...) options object containing a call is refused (QA #1578 r10)" {
  # A character class cannot span a nested paren, so `[^()]*` is defeated by f() in the options argument.
  printf 'db.collection("credit_requests", { validator: f() }).insertOne({ status: "approved" });\n' > "$T/scripts/probe14.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "not caught: options object containing a call"; false; }
  [[ "$output" == *"probe14.js:1"* ]]
}

@test "probe15: a read through a broken collection(...) is NOT a violation (QA #1578 r10)" {
  printf 'const row = db.collection(\n  "credit_requests"\n).findOne({ _id: 1 });\n' > "$T/scripts/probe15.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ] || { echo "false positive: read through a broken collection call"; false; }
}

@test "probe16: a Python line-continuation binding still binds its alias (QA #1578 r11)" {
  # QA's r11 Critical named JavaScript, but that exact snippet is caught on c5334e65f through this entrypoint
  # (`Mongo credit-request write` at the write line). The SAME hole is real one language over: the RHS scan stopped
  # at the first newline at depth 0, so `c = \` NEWLINE `db.collection(...)` left `c` unbound, and the write verb ran
  # on a name the scanner did not know. Reproduced through this entrypoint at c5334e65f: exit 0, 542 files.
  printf 'c = \\\n    db.collection("credit_requests")\nc.update_one(q, {"status": "approved"})\n' > "$T/scripts/probe16.py"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "not caught: Python backslash continuation binding"; false; }
  [[ "$output" == *"probe16.py:3"* ]]
}

@test "probe17: a JS binding continued across a newline is refused (QA #1578 r11)" {
  # Regression guard for the form QA reported: it was already caught at c5334e65f, and it must stay caught.
  printf 'const c =\n  db.collection("credit_requests");\nc.updateOne(q, {status: "approved"});\n' > "$T/scripts/probe17.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "not caught: JS alias continued after ="; false; }
  [[ "$output" == *"probe17.js:3"* ]]
}

@test "probe18: a binding split by a comment is still bound (QA #1578 r11)" {
  printf 'const c = // the credit collection\n  db.collection("credit_requests");\nc.updateOne(q, {status: "approved"});\n' > "$T/scripts/probe18.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "not caught: comment between = and the collection call"; false; }
  [[ "$output" == *"probe18.js:3"* ]]
}

@test "probe19: a continued binding to an UNRELATED collection is NOT a violation (QA #1578 r11)" {
  # The continuation must not become a wildcard: the same shape against any other collection is a legal script.
  printf 'const c =\n  db.collection("artists");\nc.updateOne(q, {status: "approved"});\n' > "$T/scripts/probe19.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ] || { echo "false positive: continued binding to an unrelated collection"; false; }
}

@test "probe20: a JS postfix decrement must not blank a same-line status write (QA #1578 r12)" {
  # QA's exact reproducer: `i-- ;` is valid JavaScript, but the old stripper saw `--` followed by a SPACE and treated the
  # rest of the line as a SQL comment - the write vanished and the gate answered OK (exit 0) on a real violation.
  printf 'let i = 1; i-- ; db.credit_requests.updateOne({id: 1}, {$set: {status: "approved"}});\n' > "$T/scripts/probe20.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a postfix decrement hid a direct Mongo status write"; echo "$output"; false; }
  [[ "$output" == *"probe20.js:1"* ]]
}

@test "probe21: a decrement at end of line, and prose comments, are still NOT violations" {
  # The other direction: over-blanking is not the fix - a decrement and a prose comment that merely NAMES the collection
  # are legal, and a gate that refuses them is a gate someone mutes.
  printf 'let n = 3;\nwhile (n-- > 0) {}\nlet m = 2;\nm--\n-- a prose note about credit_requests\n// and one about credit_requests\n' > "$T/scripts/probe21.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ] || { echo "false positive on a decrement or a naming-only comment"; echo "$output"; false; }
}

@test "probe22: a token-adjacent SQL comment is still treated as a comment (QA #1578 r9 must not regress)" {
  printf 'UPDATE--repair\ncredit_requests SET status = %s;\n' "'approved'" > "$T/scripts/probe22.sql"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "regression: UPDATE--repair stopped being read as a comment"; echo "$output"; false; }
  [[ "$output" == *"probe22.sql"* ]]
}

@test "probe23: Python floor division is not a comment (QA #1578 r13)" {
  # QA's exact reproducer: `//` is FLOOR DIVISION in Python. It was blanked as a JS line comment, so the write after it
  # on the same line disappeared and the gate answered OK on a real violation.
  printf 'x = 4 // 2; db.credit_requests.update_one({"id": 1}, {"$set": {"status": "approved"}})\n' > "$T/scripts/probe23.py"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a Python floor division hid a Mongo status write"; echo "$output"; false; }
  [[ "$output" == *"probe23.py:1"* ]]
}

@test "probe24: in SQL the dashes are always a comment, whatever punctuation follows (QA #1578 r13)" {
  # QA's exact reproducer: `UPDATE-- ; repair` NEWLINE `credit_requests SET status='approved';` is a valid update. The
  # JS decrement heuristic called the dashes CODE because `;` follows them, so `\bupdate\s+` never matched the table.
  printf 'UPDATE-- ; repair\ncredit_requests SET status = %s;\n' "'approved'" > "$T/scripts/probe24.sql"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a punctuation-led SQL comment hid an UPDATE"; echo "$output"; false; }
  [[ "$output" == *"probe24.sql:1"* ]]
}

@test "probe25: a language that does not have that comment form still refuses, and comments that ARE comments stay clean" {
  # Over-blanking is the failure direction that hides a write, so a form that is not a comment in the file's language is
  # left alone (a `--` in Python stays visible), while a `#` in Python and a `//` in JS are real comments and a file that
  # only NAMES the patterns inside them is clean.
  printf 'x = 1 -- y; db.credit_requests.update_one({}, {"$set": {"status": "approved"}})\n' > "$T/scripts/probe25a.py"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a `--` in Python was blanked as if it were a SQL comment"; echo "$output"; false; }
  rm -f "$T/scripts/probe25a.py"
  printf '# a comment about UPDATE credit_requests and notify=False\ny = 7 // 2\n' > "$T/scripts/probe25b.py"
  printf '// a comment about credit_requests.updateOne(...)\nlet i = 0;\ni-- ;\n' > "$T/scripts/probe25c.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ] || { echo "false positive on a real comment"; echo "$output"; false; }
}

@test "probe26: a mention of the collection does not make an unrelated receiver ours (QA #1578 r14)" {
  # QA's exact reproducer: the alias resolver searched the whole right-hand side for the substring `credit_requests`,
  # so an options object that merely NAMED the collection bound `artists` to it and a write to `artists` - a legal
  # change - failed the required CI gate.
  printf 'const artists = db.collection("artists", {comment: "credit_requests"});\nartists.updateOne({}, {$set: {name: "x"}});\n' > "$T/scripts/probe26.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ] || { echo "false positive: a mention of the collection bound an unrelated receiver"; echo "$output"; false; }
  rm -f "$T/scripts/probe26.js"
  # ... and the fix must not lose a real binding: the bracket form only names the collection after normalisation
  printf 'const c = db["credit_requests"];\nc.updateOne(q, u);\n' > "$T/scripts/probe26b.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: the mention fix lost the bracket-form binding"; echo "$output"; false; }
  [[ "$output" == *"probe26b.js:2"* ]]
}

@test "probe27: a shell comment is a comment, and a shell write is still refused (QA #1578 r14)" {
  # QA's exact reproducer: `.sh` was classified as JS, `#` was never recognized, and a documentation comment that
  # merely NAMED the patterns failed the required CI gate. Allowlisting the file would also permit real writes.
  printf '#!/usr/bin/env bash\n# Example: UPDATE credit_requests SET status = %s\necho hello\n' "'approved'" > "$T/scripts/probe27.sh"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ] || { echo "false positive: a shell documentation comment failed the gate"; echo "$output"; false; }
  rm -f "$T/scripts/probe27.sh"
  # the other direction: a shell script that really writes the status is still a violation
  printf 'psql -c "UPDATE credit_requests SET status = %s"\n' "'approved'" > "$T/scripts/probe27b.sh"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a real write in a shell script was blanked away"; echo "$output"; false; }
  [[ "$output" == *"probe27b.sh:1"* ]]
}

@test "probe28: optional chaining and the bracket call are the same write (QA #1578 r15)" {
  # QA's exact reproducers: `?.` is not `.`, and `["updateOne"]` normalises to a bare word, so the literal `.verb(`
  # join missed both - each executes a direct status write when the collection exists.
  printf 'db.credit_requests?.updateOne({id: 1}, {$set: {status: "approved"}});\n' > "$T/scripts/probe28a.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: optional chaining hid a direct Mongo status write"; echo "$output"; false; }
  [[ "$output" == *"probe28a.js:1"* ]]
  rm -f "$T/scripts/probe28a.js"
  printf 'db.collection("credit_requests")?.updateOne({id: 1}, {$set: {status: "approved"}});\n' > "$T/scripts/probe28b.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: optional chaining on a collection() receiver"; echo "$output"; false; }
  rm -f "$T/scripts/probe28b.js"
  printf 'db.credit_requests["updateOne"]({id: 1}, {$set: {status: "approved"}});\n' > "$T/scripts/probe28c.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: the bracket call hid a direct Mongo status write"; echo "$output"; false; }
}

@test "probe29: a rebound alias to another collection is NOT a violation (QA #1578 r15)" {
  # QA's exact reproducer: the alias set only ever GREW, so `coll` stayed an alias after being rebound to `artists`
  # and a legitimate change failed the required CI gate.
  printf 'let coll = db.collection("credit_requests");\ncoll = db.collection("artists");\ncoll.updateOne({}, {$set: {name: "x"}});\n' > "$T/scripts/probe29.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ] || { echo "false positive: a rebound alias was still treated as the credit collection"; echo "$output"; false; }
  rm -f "$T/scripts/probe29.js"
  # ... and the LAST binding still decides the other way
  printf 'let coll = db.collection("artists");\ncoll = db.collection("credit_requests");\ncoll.updateOne({}, {$set: {status: "approved"}});\n' > "$T/scripts/probe29b.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a name rebound TO credit is a hit"; echo "$output"; false; }
}

@test "probe30: a write BEFORE a rebind is still caught (QA #1578 r16)" {
  # QA's exact reproducer: keeping only the LAST binding hid an earlier direct status write.
  printf 'let coll = db.collection("credit_requests");\ncoll.updateOne({}, {$set: {status: "approved"}});\ncoll = db.collection("artists");\n' > "$T/scripts/probe30.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a write before a rebind was hidden"; echo "$output"; false; }
  [[ "$output" == *"probe30.js:2"* ]]
}

@test "probe31: the bracket call on a collection() receiver and on an alias (QA #1578 r16)" {
  printf 'db.collection("credit_requests")["updateOne"]({}, {$set: {status: "approved"}});\n' > "$T/scripts/probe31a.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a bracket call on a collection() receiver"; echo "$output"; false; }
  rm -f "$T/scripts/probe31a.js"
  printf 'const c = db.credit_requests;\nc["updateOne"]({}, {$set: {status: "approved"}});\n' > "$T/scripts/probe31b.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a bracket call on a bound alias"; echo "$output"; false; }
}

@test "probe32: a transitive alias survives its source being reassigned (QA #1578 r17)" {
  # QA's exact reproducer: `b` still holds the credit collection at runtime, but the global last-binding set said
  # `a` was `artists`, so `b` was never an alias and the write scanned clean.
  printf 'let a = db.collection("credit_requests");\nlet b = a;\na = db.collection("artists");\nb.updateOne({}, {$set: {status: "approved"}});\n' > "$T/scripts/probe32.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a transitive alias lost its binding"; echo "$output"; false; }
  [[ "$output" == *"probe32.js:4"* ]]
  rm -f "$T/scripts/probe32.js"
  # ... and the inverse is not ours
  printf 'let a = db.collection("artists");\nlet b = a;\na = db.collection("credit_requests");\nb.updateOne({}, {$set: {name: "x"}});\n' > "$T/scripts/probe32b.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ] || { echo "false positive: a transitive alias to artists was treated as credit"; echo "$output"; false; }
}

@test "probe33: a destructured alias is resolved in source order (QA #1578 r18)" {
  # QA's exact reproducer: destructuring matches were appended AFTER every ordinary assignment, so the forward pass
  # saw them out of order and `b` resolved before `a` existed.
  printf 'const {credit_requests: a} = db;\nconst b = a;\nb.updateOne({}, {$set: {status: "approved"}});\n' > "$T/scripts/probe33.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a destructured alias was resolved out of order"; echo "$output"; false; }
  [[ "$output" == *"probe33.js:3"* ]]
}

@test "probe34: a FAILED file discovery is exit 2, never a clean gate (QA #1578 r18)" {
  # QA's exact reproducer: `mapfile -t files < <(git ls-files ...)` succeeds even when `git ls-files` fails, so a
  # corrupt or unreadable index made the required CI gate exit 0 with "0 tracked files scanned".
  printf 'UPDATE credit_requests SET status = %s\n' "'approved'" > "$T/scripts/probe34.sql"
  git -C "$T" init -q . 2>/dev/null || true
  git -C "$T" add -A >/dev/null 2>&1 || true
  run env GIT_INDEX_FILE="$T/no-such-index" bash "$SCRIPT" --root "$T"
  [ "$status" -eq 2 ] || { echo "FALSE GREEN: a failed discovery reported a clean gate (rc=$status)"; echo "$output"; false; }
  [[ "$output" == *"refusing to report a clean gate"* ]]
}

@test "probe35: alias and call positions share one coordinate system (QA #1578 r19)" {
  # QA's exact reproducer: bindings were recorded in `raw_code` (quotes intact) and compared with call positions in
  # the quote-stripped `flat` string, so after enough quotes the offsets drifted and a real write stopped matching.
  python3 - "$T/scripts/probe35.js" <<'PY'
import sys
lines = ['const x%d = "";' % i for i in range(100)]
lines.append('const a = db.collection("credit_requests");')
lines.append('a.updateOne({}, {$set: {status: "approved"}});')
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
PY
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: the alias offset drifted out of the call coordinate system"; echo "$output"; false; }
  [[ "$output" == *"probe35.js:102"* ]]
}

@test "probe36: PyMongo get_collection is the same receiver (QA #1578 r20)" {
  printf 'db.get_collection("credit_requests").updateOne({}, {$set: {status: "approved"}});\n' > "$T/scripts/probe36.py"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: db.get_collection() bypassed the gate"; echo "$output"; false; }
  [[ "$output" == *"probe36.py:1"* ]]
}

@test "probe38: a template interpolation is CODE, not string content (QA #1578 r22)" {
  # QA's reproducer: a template literal is a string, so the mask called the whole backtick run string CONTENT - and
  # `${db.collection("credit_requests").updateOne(...)}` is an expression that EXECUTES. The real entrypoint exited 0
  # with "OK: ... 1 tracked files scanned". The interpolation body is now scanned as code.
  cat > "$T/scripts/probe38.js" <<'JS'
const s = `${db.collection("credit_requests").updateOne({}, {$set: {status: "approved"}})}`;
JS
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: the interpolation body was masked as string content"; echo "$output"; false; }
  [[ "$output" == *"probe38.js:1"*"Mongo credit-request write"* ]]
  # the same write without the interpolation is a plain statement and must still be caught
  cat > "$T/scripts/probe38.js" <<'JS'
const t = `hello ${name}`;
db.collection("credit_requests").insertOne({status: "approved"});
JS
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a template literal broke the depth walk"; echo "$output"; false; }
  # a nested interpolation (a template inside a template) must not close the outer one early, and the literal text
  # around it stays literal: prose that NAMES the collection is not a receiver
  cat > "$T/scripts/probe38.js" <<'JS'
const label = `outer ${f({a: `inner ${g("}")}`})} credit_requests`;
db.collection("artists").updateOne({}, {$set: {name: "x"}});
JS
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ] || { echo "FALSE RED: a nested interpolation was read as a write"; echo "$output"; false; }
  # and a write inside a NESTED interpolation is still found
  cat > "$T/scripts/probe38.js" <<'JS'
const label = `outer ${f(`inner ${db.collection("credit_requests").updateOne({}, {})}`)}`;
JS
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a nested interpolation hid the write"; echo "$output"; false; }
}

@test "probe39: an interpolation body is scanned as ordinary code (QA #1578 r23)" {
  # QA's reproducer: r22 left the interpolation body unmarked but did not mark its OWN literals either, so a quoted
  # `)` inside the body closed the receiver at a data character and `.updateOne` fell outside it. The real entrypoint
  # exited 0 with "OK: ... 1 tracked files scanned".
  for delim in ')' '}'; do
    printf 'const x = `${db.collection("credit_requests", {comment: "%s"}).updateOne({}, {$set: {status: "approved"}})}`;\n' \
      "$delim" > "$T/scripts/probe39.js"
    run bash "$SCRIPT" --root "$T"
    [ "$status" -eq 1 ] || { echo "FALSE GREEN: a quoted '$delim' inside an interpolation closed the receiver"; echo "$output"; false; }
    [[ "$output" == *"probe39.js:1"*"Mongo credit-request write"* ]]
  done
  # a comment inside the interpolation is a COMMENT: it must be blanked, not swallow the write verb
  cat > "$T/scripts/probe39.js" <<'JS'
const x = `${db.collection("credit_requests") /* c */ .updateOne({}, {$set: {status: "approved"}})}`;
JS
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a block comment inside an interpolation hid the write"; echo "$output"; false; }
  cat > "$T/scripts/probe39.js" <<'JS'
const x = `${db.collection("credit_requests") // c
.updateOne({}, {$set: {status: "approved"}})}`;
JS
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a line comment inside an interpolation hid the write"; echo "$output"; false; }
  # near-miss: prose in the literal, and a read, stay clean
  cat > "$T/scripts/probe39.js" <<'JS'
const x = `credit_requests ${name} as a table name`;
db.collection("credit_requests").findOne({});
JS
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ] || { echo "FALSE RED: literal prose or a read was reported as a write"; echo "$output"; false; }
}

@test "probe40: an interpolation body may span newlines (QA #1578 r24)" {
  # QA's reproducer: `_blank_code` returned at the interpolation's newline, so a `/* hi */` on the next line was not
  # blanked as code and the receiver matcher could not join the collection call to `.updateOne`. The real entrypoint
  # exited 0 with "OK: ... 1 tracked files scanned".
  cat > "$T/scripts/probe40.js" <<'JS'
const s = `${db.collection("credit_requests", {comment: ")"})
 /* hi */ .updateOne({}, {$set: {status: "approved"}})}`;
JS
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a newline inside an interpolation stopped the code walk"; echo "$output"; false; }
  [[ "$output" == *"probe40.js:1"*"Mongo credit-request write"* ]]
  # the same write split across lines with no comment must be caught too
  cat > "$T/scripts/probe40.js" <<'JS'
const s = `${db.collection("credit_requests")
.updateOne({}, {$set: {status: "approved"}})}`;
JS
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 1 ] || { echo "FALSE GREEN: a multiline interpolation hid the write"; echo "$output"; false; }
  # near-miss: an UNTERMINATED interpolation still stops at the newline, so a stray `${` cannot swallow the file and
  # turn an unrelated write into a false positive
  cat > "$T/scripts/probe40.js" <<'JS'
const l = `a ${b`;
db.collection("artists").insertOne({status: "approved"});
JS
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ] || { echo "FALSE RED: an unterminated interpolation swallowed the rest of the file"; echo "$output"; false; }
}

@test "probe37: a quoted delimiter does not close the collection receiver (QA #1578 r21)" {
  # QA's exact reproducer: the depth walk ran on the NORMALISED stream, where the quotes are already gone, so a `)`
  # or `}` INSIDE a string argument decremented the depth and closed the receiver early. The write verb then sat
  # outside the receiver and the real entrypoint exited 0 with "OK: ... 1 tracked files scanned".
  for delim in ')' '}'; do
    printf 'db.collection("credit_requests", {comment: "%s"}).updateOne({}, {$set: {status: "approved"}});\n' \
      "$delim" > "$T/scripts/probe37.js"
    run bash "$SCRIPT" --root "$T"
    [ "$status" -eq 1 ] || { echo "FALSE GREEN: a quoted '$delim' closed the receiver"; echo "$output"; false; }
    [[ "$output" == *"probe37.js:1"*"Mongo credit-request write"* ]]
  done
  # the mirror: an opening bracket or an argument comma inside the literal must not open a new argument either
  for delim in '(' '{' 'a, b'; do
    printf 'db.collection("credit_requests", {comment: "%s"}).insertOne({status: "approved"});\n' \
      "$delim" > "$T/scripts/probe37.js"
    run bash "$SCRIPT" --root "$T"
    [ "$status" -eq 1 ] || { echo "FALSE GREEN: a quoted '$delim' broke the argument walk"; echo "$output"; false; }
  done
  # and a near-miss: a literal that merely LOOKS like a receiver is not one
  printf 'const s = "db.collection(credit_requests).updateOne(";\ndb.artists.updateOne({}, {});\n' \
    > "$T/scripts/probe37.js"
  run bash "$SCRIPT" --root "$T"
  [ "$status" -eq 0 ] || { echo "FALSE RED: a string literal was read as a receiver"; echo "$output"; false; }
}
