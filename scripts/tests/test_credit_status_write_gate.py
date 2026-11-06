#!/usr/bin/env python3
"""Unit tests for scripts/lib/credit_status_write_gate.py — the scanner behind check-credit-status-writes.sh.

The bats suite drives the guard ENTRYPOINT on synthetic trees (that is where QA reproduced the false greens). These
tests pin the scanner itself, so a regression names the rule it broke rather than "exit 1 expected, got 0": each
evasion is one mutant that must be caught, and each near-miss (a read, a true notify flag, a similarly named key)
must not be.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

import credit_status_write_gate as gate  # noqa: E402


def caught(text: str) -> bool:
    return bool(gate.scan(text))


class DirectSqlWriteTests(unittest.TestCase):
    def test_one_line(self):
        self.assertTrue(caught("UPDATE credit_requests SET status = 'approved'"))

    def test_statement_broken_after_update(self):
        """QA #1578 mutant m1: the line grep saw 'UPDATE' and a different line saw the table."""
        self.assertTrue(caught('DB.execute("""UPDATE\n  credit_requests\n  SET status = %s""", (s,))'))

    def test_quoted_schema_and_table(self):
        """QA #1578 mutant m2: 'UPDATE "public"."credit_requests"' returned OK to a per-line grep."""
        self.assertTrue(caught('UPDATE "public"."credit_requests" SET status = 1'))

    def test_quoted_across_lines(self):
        self.assertTrue(caught('UPDATE\n  "public"\n  ."credit_requests"\n  SET status = 1'))

    def test_bracket_quoting(self):
        self.assertTrue(caught("UPDATE [credit_requests] SET status = 1"))

    def test_escaped_quotes_inside_a_template_literal(self):
        self.assertTrue(caught('sql`UPDATE \\"credit_requests\\" SET status = 1`'))

    def test_case_insensitive(self):
        self.assertTrue(caught("update PUBLIC.credit_requests set status = 1"))

    def test_select_is_not_a_write(self):
        self.assertFalse(caught("SELECT status FROM credit_requests WHERE id = 1"))

    def test_sequelize_model_write(self):
        self.assertTrue(caught('await CreditRequests.update({ status: "approved" }, { where })'))


class MongoWriteTests(unittest.TestCase):
    def test_one_line(self):
        self.assertTrue(caught('db.credit_requests.update_one({"_id": i}, {"$set": {"status": "approved"}})'))

    def test_collection_then_verb_on_the_next_line(self):
        """QA #1578 mutant m3: the collection ref on one line, '.updateMany(' on the next."""
        self.assertTrue(caught('coll = db["credit_requests"]\ncoll\n  .updateMany(query, update)'))

    def test_collection_variable_used_later(self):
        self.assertTrue(caught('c = db.collection("creditRequests")\nc.updateMany(q, u)'))

    def test_snake_case_and_bulk(self):
        self.assertTrue(caught("db.credit_requests.bulk_write(ops)"))
        self.assertTrue(caught("db.credit_requests.find_one_and_update(q, u)"))
        self.assertTrue(caught("db.creditRequests.replace_one(q, u)"))

    def test_find_is_not_a_write(self):
        self.assertFalse(caught('rows = db.credit_requests.find({"status": "approved"})'))

    def test_a_write_on_another_collection_is_not_ours(self):
        self.assertFalse(caught('db.artists.updateMany(q, u)'))


class CollectionCallReceivers(unittest.TestCase):
    """QA #1578 round 10: the `collection(...)` receiver needs a bracket depth, not a character class.

    Each of these ran GREEN through the real entrypoint at 7e4fab1d: the `[^()\n]*` argument class ended the
    receiver at the newline (or at the first nested paren of an options object), so the write verb was never bound to
    the credit-requests collection at all.
    """

    def test_newline_before_the_closing_paren(self):
        """The reproduced mutant: `db.collection(` NEWLINE `"credit_requests"` NEWLINE `).insertOne(`."""
        self.assertTrue(caught('db.collection(\n  "credit_requests"\n).insertOne({status: "approved"})'))

    def test_newline_after_the_open_paren(self):
        self.assertTrue(caught('db.collection(\n  "credit_requests").insertOne({status: "approved"})'))

    def test_options_object_containing_a_call(self):
        """Widening the class to `[^()]*` is defeated by a nested call in the options argument."""
        self.assertTrue(caught('db.collection("credit_requests", {validator: f()}).insertOne({status: "approved"})'))

    def test_options_object_literal(self):
        self.assertTrue(caught('db.collection("credit_requests", {validator: 1}).insertOne({status: "approved"})'))

    def test_get_collection_across_a_newline(self):
        self.assertTrue(caught('db.getCollection(\n  "credit_requests"\n).insertOne({status: "approved"})'))

    def test_constant_argument_across_a_newline(self):
        self.assertTrue(caught('const C = "credit_requests";\ndb.collection(\n  C\n).insertOne({status: "approved"})'))

    def test_a_read_through_collection_is_not_a_write(self):
        """Near-miss: reading through the same receiver must stay clean."""
        self.assertFalse(caught('db.collection(\n "credit_requests"\n).findOne({_id: 1})'))

    def test_a_write_on_another_collection_is_not_ours(self):
        self.assertFalse(caught('db.collection(\n "artists"\n).insertOne({status: "approved"})'))


class SilentMoveTests(unittest.TestCase):
    def test_json_and_keyword_forms(self):
        for body in ('{"requestIds": ids, "notify": false}', "{'notify': False}",
                     "call({ requestIds, notify: false })", "put(ids, notify=False)"):
            self.assertTrue(caught(body), body)

    def test_value_on_the_next_line(self):
        """QA #1578 mutant m4: '"notify":' with 'false' underneath."""
        self.assertTrue(caught('payload = {"requestIds": ids,\n           "notify":\n             false}'))

    def test_operator_on_the_next_line(self):
        self.assertTrue(caught("put(ids, notify\n  =False)"))

    def test_prose_mentioning_the_marker_is_not_a_write(self):
        """main's decision_told.py docstring explains the class ("under a notify:false re-drive marker"); a sentence is
        not a silent move, and the guard would be red on its own tree if it could not tell them apart."""
        self.assertFalse(caught("The class: requests decided under a notify:false re-drive marker (10-23 / 10-26)."))
        self.assertFalse(caught("# a notify: false marker means the transition notice never went out"))

    def test_true_and_lookalike_keys_are_not_silent(self):
        for body in ('{"notify": true}', '{"notify_all": False}', "notifyFalse = 1", "if args.no_notify: pass"):
            self.assertFalse(caught(body), body)


class ReportTests(unittest.TestCase):
    def test_the_line_reported_is_where_the_statement_starts(self):
        hits = gate.scan('x = 1\ny = 2\nDB.execute("""UPDATE\n  credit_requests SET status = 1""")')
        self.assertEqual([line for line, _ in hits], [3])

    def test_one_hit_per_rule_per_line(self):
        hits = gate.scan('UPDATE credit_requests SET status = 1; UPDATE credit_requests SET status = 2')
        self.assertEqual(len(hits), 1)

    def test_clean_file_has_no_hits(self):
        self.assertEqual(gate.scan('print("hello")\nrows = db.credit_requests.find({})\n'), [])


class CommentSeparators(unittest.TestCase):
    """QA #1578 (second round): a SQL/JS comment is a valid separator between the verb and the table name."""

    def test_a_block_comment_between_update_and_the_table_is_still_a_write(self):
        self.assertTrue(gate.scan("UPDATE /* decision repair */ credit_requests SET status = 'approved' WHERE id = 1;"))

    def test_a_line_comment_across_the_break_is_still_a_write(self):
        self.assertTrue(gate.scan("UPDATE -- repair\n credit_requests SET status = 'x'"))

    def test_a_comment_inside_a_qualified_quoted_name_is_still_a_write(self):
        self.assertTrue(gate.scan('UPDATE "public"./*x*/"credit_requests" SET a = 1'))

    def test_a_url_scheme_does_not_swallow_the_write_behind_it(self):
        """`//` may only be a comment when it is not part of `https://` - otherwise the line's code disappears."""
        self.assertTrue(gate.scan('const u = "https://a.example"; coll = db["credit_requests"]; coll.updateMany(q, u)'))

    def test_a_comment_between_notify_and_its_value_is_still_a_silent_move(self):
        """Same separator bug, one rule over: the notify rule keeps its quotes (prose) but not its comments (code)."""
        self.assertTrue(gate.scan("const body = { notify: /* decision repair */ false };"))
        self.assertTrue(gate.scan("const body = { notify: // repair\n false };"))
        self.assertTrue(gate.scan('payload = { "notify": /*x*/ false }'))

    def test_prose_and_a_notify_suffix_are_still_not_moves(self):
        self.assertEqual(gate.scan("x = 1  # prose: under a `notify:false` re-drive marker"), [])
        self.assertEqual(gate.scan("call(notify_all=True)"), [])

    def test_a_string_literal_containing_a_comment_marker_hides_nothing(self):
        """QA #1578 (round 4): the stripper ran on text whose quotes had already been dropped, so `"//"` read as a
        comment and erased the real write behind it."""
        self.assertTrue(gate.scan('const marker = "//"; db.credit_requests.updateOne(q, u);'))
        self.assertTrue(gate.scan('const marker = "//"; const body = { notify: false };'))
        self.assertTrue(gate.scan('const s = "/* x */"; const body = { notify: false };'))
        self.assertEqual(gate.scan('const s = "/* not a comment */"; coll.updateMany(q, u)'), [])

    def test_a_collection_alias_is_tracked_without_a_distance_limit(self):
        """QA #1578 (round 4): a 400-character window missed a normal delayed use of the alias."""
        body = 'coll = db["credit_requests"];\n' + "x = 0;\n" * 60 + "coll.updateMany(q, u);\n"
        hits = gate.scan(body)
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0][0], 62, "reported at the write, not at the assignment")
        self.assertEqual(gate.scan("coll.updateMany(q, u)  # never bound to credit_requests"), [])

    def test_a_multiline_collection_binding_binds_the_alias(self):
        """QA #1578 (round 5): `const coll = db[` NEWLINE `"credit_requests"` NEWLINE `];` - the RHS spans lines, so a
        `[^;\\n]*` binding stopped at the first newline and 90 lines later the write passed."""
        body = 'const coll = db[\n  "credit_requests"\n];\n' + "filler();\n" * 90 + "coll.updateMany(q, u);\n"
        hits = gate.scan(body)
        self.assertEqual([h[0] for h in hits], [94])
        # the binding is a STATEMENT, not a byte window: an alias bound to something else is never a hit
        self.assertEqual(gate.scan("x = 1\ny = 2\ncoll.updateMany(q, u)"), [])
        self.assertEqual(gate.scan("const m = {a: 1}; coll.updateMany(q, u)"), [])
        self.assertTrue(gate.scan("coll = db.collection('credit_requests')\ncoll.updateOne(q, u)"))

    def test_postgres_update_only_is_the_same_write(self):
        """QA #1578 (round 6): `UPDATE ONLY credit_requests SET status = ...` is a plain update of the table, and the
        rule required the name immediately after the verb."""
        self.assertTrue(gate.scan("UPDATE ONLY credit_requests SET status='approved' WHERE id=1;"))
        self.assertTrue(gate.scan("UPDATE /* repair */ ONLY /* x */ credit_requests SET status='approved';"))
        self.assertTrue(gate.scan('update only public."credit_requests" set a=1'))
        self.assertEqual(gate.scan("UPDATE ONLY some_other_table SET a=1"), [])

    def test_a_status_setting_insert_or_upsert_is_the_same_write(self):
        """QA #1578 (round 7): an INSERT that carries the status - and the ON CONFLICT ... DO UPDATE form - creates or
        flips a credit-request status exactly like an UPDATE."""
        self.assertTrue(gate.scan("INSERT INTO credit_requests (id, status) VALUES (42, 'approved') "
                                   "ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status;"))
        self.assertTrue(gate.scan("insert into public.credit_requests (status) values ('approved')"))
        self.assertTrue(gate.scan("MERGE INTO credit_requests c USING x ON c.id = x.id "
                                  "WHEN MATCHED THEN UPDATE SET status = 'approved'"))
        self.assertTrue(gate.scan("creditRequests.create({ id, status })"),
                        "the Sequelize row-creating verbs write the same column")
        self.assertEqual(gate.scan("INSERT INTO other_table (status) VALUES (1)"), [])
        self.assertEqual(gate.scan("INSERT INTO credit_requests_log (a) VALUES (1)"), [])

    def test_a_mongo_insert_is_the_same_write_as_an_update(self):
        """QA #1578 (round 8): the row IS a status, so `insertOne`/`insertMany` create an approved request exactly as an
        UPDATE flips one - and the driver's snake_case forms are the same call. The SQL INSERT was already refused, so
        leaving Mongo's insert verbs out was the same hole one API down."""
        self.assertTrue(gate.scan('db.credit_requests.insertOne({"id": 42, "status": "approved"})'))
        self.assertTrue(gate.scan('db["credit_requests"].insertMany([{"status": "approved"}])'))
        self.assertTrue(gate.scan('const coll = db.credit_requests;\ncoll.insert_one({ status: "approved" })'),
                        "the aliased insert is the same collection")
        self.assertFalse(gate.scan('db.other_collection.insertOne({"id": 42})'))

    def test_a_constant_backed_collection_binding_is_traced(self):
        """QA #1578 (round 9, finding 1): the collection name can arrive through a constant, so
        `db.collection(CREDIT_COLLECTION)` built a receiver no rule read and its insert was a false green."""
        body = ('const CREDIT_COLLECTION = "credit_requests";\n'
                'const requests = db.collection(CREDIT_COLLECTION);\n'
                'requests.insertOne({ status: "approved" });\n')
        hits = gate.scan(body)
        self.assertEqual([h[0] for h in hits], [3], body)
        # the same constant used inline, without an intermediate variable
        self.assertTrue(gate.scan('const C = "credit_requests";\ndb.collection(C).updateOne(q, u);'))
        # a constant for a DIFFERENT collection is not ours
        self.assertEqual(gate.scan('const C = "artists";\nconst c = db.collection(C);\nc.updateOne(q, u);'), [])

    def test_a_read_plus_an_unrelated_write_is_clean(self):
        """QA #1578 (round 9, finding 2): the 400-character window matched the next write verb regardless of which
        collection it was called on, so a legitimate read-plus-unrelated-write script failed the gate."""
        self.assertEqual(gate.scan('const rows = db.credit_requests.find({});\ndb.artists.updateOne(q, u);'), [])
        self.assertEqual(gate.scan('db.credit_requests.find({}).toArray();\ndb.artists.insertOne({id: 1});'), [])

    def test_a_sql_comment_right_after_a_token_is_still_a_comment(self):
        """QA #1578 (round 9, finding 3): PostgreSQL accepts `UPDATE--repair` NEWLINE `credit_requests ...`, and the
        stripper only recognized `--` after a fixed set of characters, so the dashes survived into the scan."""
        self.assertTrue(gate.scan("UPDATE--repair\ncredit_requests SET status='approved';"))
        self.assertTrue(gate.scan("UPDATE--repair\n  \"public\".\"credit_requests\" SET status='approved';"))

    def test_a_decrement_and_a_plain_comment_are_not_writes(self):
        self.assertEqual(gate.scan("i--; // decrement\n/* prose about credit_requests */"), [])

    def test_a_postfix_decrement_before_a_semicolon_does_not_blank_the_rest_of_the_line(self):
        """QA #1578 (round 12, Critical): `i-- ;` is valid JS, and the stripper read `--` + space as a SQL comment, so
        a same-line direct status write disappeared and the gate answered OK."""
        self.assertTrue(gate.scan('i-- ; db.credit_requests.updateOne({id: 1}, {$set: {status: "approved"}});'))
        self.assertTrue(gate.scan("let i = 1; i-- ; db.credit_requests.updateOne({}, {$set: {status: 'approved'}});"))

    def test_a_decrement_at_end_of_line_and_prose_comments_stay_clean(self):
        """The other direction: refusing a decrement or a comment that merely NAMES the collection is a false red."""
        self.assertEqual(gate.scan("let n = 3;\nwhile (n-- > 0) {}\nlet m = 2;\nm--\n"), [])
        self.assertEqual(gate.scan("-- a prose note about credit_requests\n// and one about credit_requests\n"), [])

    def test_a_sql_comment_starting_with_punctuation_after_a_token_is_still_a_comment(self):
        """`_dashes_are_a_sql_comment` decides on what FOLLOWS the dashes, so the round-9 case keeps working."""
        self.assertTrue(gate.scan("UPDATE--repair (see ticket)\ncredit_requests SET status='approved';"))

    # ── qa-review #1578 (r13): comment syntax belongs to the LANGUAGE, not to the character pair ────────────────
    def test_python_floor_division_is_not_a_comment(self):
        """QA's reproducer: `//` in Python is floor division, so blanking it hid a same-line Mongo write."""
        line = 'x = 4 // 2; db.credit_requests.update_one({"id": 1}, {"$set": {"status": "approved"}})'
        self.assertTrue(gate.scan(line, "probe.py"))
        self.assertEqual(gate.scan("x = 4 // 2\n"), [])

    def test_in_sql_the_dashes_are_always_a_comment(self):
        """QA's reproducer: `UPDATE-- ; repair` is valid SQL; the JS decrement heuristic made the table unmatched."""
        self.assertTrue(gate.scan("UPDATE-- ; repair\ncredit_requests SET status='approved';", "probe.sql"))
        self.assertTrue(gate.scan("UPDATE--;\ncredit_requests SET status='approved';", "probe.sql"))

    def test_the_language_gate_does_not_over_blank_the_other_way(self):
        # a `--` is NOT a comment in Python: leaving it visible is the direction that keeps a write in view
        self.assertTrue(gate.scan("x = 1 -- y; db.credit_requests.update_one({}, {})", "probe.py"))
        # ... and a real comment that only NAMES the patterns is still clean in both languages
        self.assertEqual(gate.scan("# UPDATE credit_requests / notify=False\n", "a.py"), [])
        self.assertEqual(gate.scan("// credit_requests.updateOne(...)\n", "a.js"), [])
        self.assertEqual(gate.scan("-- UPDATE credit_requests\n", "a.sql"), [])

    def test_an_unknown_suffix_keeps_the_pre_r13_behaviour(self):
        # No language is claimed for a path we cannot type, so nothing that could be code is blanked away.
        self.assertEqual(gate.scan("i-- ;\n"), [])
        self.assertTrue(gate.scan("i-- ; db.credit_requests.updateOne({}, {})"))

    # ── qa-review #1578 (r14): a MENTION is not a RECEIVER, and shell comments are comments ─────────────────────
    def test_a_mention_of_the_collection_does_not_bind_an_unrelated_receiver(self):
        """QA's reproducer: `_is_credit_expr` searched the whole RHS for the substring, so an options object that
        merely NAMED the collection bound `artists` to it and a write to `artists` failed the required CI gate."""
        body = ('const artists = db.collection("artists", {comment: "credit_requests"});\n'
                'artists.updateOne({}, {$set: {name: "x"}});\n')
        self.assertEqual(gate.scan(body, "probe.js"), [])
        # ... and the same near-miss through a constant that names the collection in a comment
        self.assertEqual(gate.scan('const C = "artists";\nconst a = db.collection(C, {note: "credit_requests"});\n'
                                   'a.updateOne(q, u);\n', "probe.js"), [])

    def test_the_receiver_forms_still_bind_after_the_mention_fix(self):
        """The other direction: the fix must not lose a real binding. Every receiver form the gate already knew
        still binds, including the bracket form whose name only appears after normalisation."""
        for body in ('const c = db.credit_requests;\nc.updateOne(q, u);\n',
                     'const c = db["credit_requests"];\nc.updateOne(q, u);\n',
                     'const c = db.collection("credit_requests");\nc.updateOne(q, u);\n',
                     'const C = "credit_requests";\nconst c = db.collection(C);\nc.updateOne(q, u);\n',
                     'const a = db.credit_requests;\nconst b = a;\nb.updateOne(q, u);\n'):
            self.assertTrue(gate.scan(body, "probe.js"), body)

    def test_a_shell_comment_is_a_comment(self):
        """QA's reproducer: `.sh` was classified as JS, `#` was never recognized, and a documentation comment that
        merely NAMED the patterns failed the required CI gate."""
        body = "#!/usr/bin/env bash\n# Example: UPDATE credit_requests SET status = 'approved'\necho hello\n"
        self.assertEqual(gate.scan(body, "probe.sh"), [])
        self.assertEqual(gate.scan("# notify: false is what core's PUT avoids\necho hi\n", "probe.bash"), [])
        self.assertEqual(gate.scan("# UPDATE credit_requests\nkey: value\n", "probe.yml"), [])

    # ── qa-review #1578 (r15): optional chaining, the bracket call, and a rebound alias ─────────────────────────
    def test_optional_chaining_is_the_same_write(self):
        """QA's reproducer: `?.` is not `.`, so the literal `.verb(` join missed a valid direct status write."""
        self.assertTrue(gate.scan('db.credit_requests?.updateOne({id: 1}, {$set: {status: "approved"}});', "p.js"))
        self.assertTrue(gate.scan('db.collection("credit_requests")?.updateOne({id: 1}, {$set: {status: "approved"}});',
                                  "p.js"))
        self.assertTrue(gate.scan('const c = db.credit_requests;\nc?.updateOne({}, {});', "p.js"))

    def test_the_bracket_call_is_the_same_write(self):
        """QA's reproducer: `db.credit_requests["updateOne"](...)` executes the write and passed the gate."""
        self.assertTrue(gate.scan('db.credit_requests["updateOne"]({id: 1}, {$set: {status: "approved"}});', "p.js"))
        self.assertTrue(gate.scan('db["credit_requests"]["updateOne"]({}, {});', "p.js"))

    def test_a_rebound_alias_is_not_ours(self):
        """QA's reproducer: the alias set only ever GREW, so a name rebound to another collection stayed an alias."""
        body = ('let coll = db.collection("credit_requests");\n'
                'coll = db.collection("artists");\n'
                'coll.updateOne({}, {$set: {name: "x"}});\n')
        self.assertEqual(gate.scan(body, "p.js"), [])
        # ... and the LAST binding still decides the other way: rebound TO credit is a hit
        body2 = ('let coll = db.collection("artists");\n'
                 'coll = db.collection("credit_requests");\n'
                 'coll.updateOne({}, {$set: {status: "approved"}});\n')
        self.assertTrue(gate.scan(body2, "p.js"))

    # ── qa-review #1578 (r16): the binding is resolved AT THE CALL SITE ─────────────────────────────────────────
    def test_a_write_BEFORE_a_rebind_is_still_caught(self):
        """QA's reproducer: keeping only the LAST binding hid an earlier write."""
        body = ('let coll = db.collection("credit_requests");\n'
                'coll.updateOne({}, {$set: {status: "approved"}});\n'
                'coll = db.collection("artists");\n')
        self.assertTrue(gate.scan(body, "p.js"))
        # ... and the write AFTER the rebind is still not ours
        body2 = ('let coll = db.collection("credit_requests");\n'
                 'coll = db.collection("artists");\n'
                 'coll.updateOne({}, {$set: {name: "x"}});\n')
        self.assertEqual(gate.scan(body2, "p.js"), [])

    def test_the_bracket_call_on_a_collection_receiver_and_an_alias(self):
        """QA's reproducer: `_collection_receiver_hits` checked only `.verb(`, and the alias matcher had no bracket
        form, so `db.collection("credit_requests")["updateOne"](...)` and `c["updateOne"](...)` scanned clean."""
        self.assertTrue(gate.scan('db.collection("credit_requests")["updateOne"]({}, {$set: {status: "approved"}});',
                                  "p.js"))
        self.assertTrue(gate.scan('const c = db.credit_requests;\nc["updateOne"]({}, {$set: {status: "approved"}});',
                                  "p.js"))
        self.assertTrue(gate.scan('const c = db.collection("credit_requests");\nc["updateOne"]({}, {});', "p.js"))

    # ── qa-review #1578 (r17): a transitive binding resolves against its source AT THAT POSITION ────────────────
    def test_a_transitive_alias_survives_its_source_being_reassigned(self):
        """QA's reproducer: `b` still holds the credit collection at runtime, but the global last-binding set said
        `a` was `artists`, so `b` was never an alias and the write scanned clean."""
        body = ('let a = db.collection("credit_requests");\n'
                'let b = a;\n'
                'a = db.collection("artists");\n'
                'b.updateOne({}, {$set: {status: "approved"}});\n')
        self.assertTrue(gate.scan(body, "p.js"))
        # ... and the inverse: `b` holds artists, so its write is not ours
        body2 = ('let a = db.collection("artists");\n'
                 'let b = a;\n'
                 'a = db.collection("credit_requests");\n'
                 'b.updateOne({}, {$set: {name: "x"}});\n')
        self.assertEqual(gate.scan(body2, "p.js"), [])

    # ── qa-review #1578 (r18): destructuring is a binding like any other, in source order ───────────────────────
    def test_a_destructured_alias_is_resolved_in_source_order(self):
        """QA's reproducer: destructuring matches were appended AFTER every ordinary assignment, so the forward pass
        saw them out of order and `b` resolved before `a` existed."""
        body = ('const {credit_requests: a} = db;\n'
                'const b = a;\n'
                'b.updateOne({}, {$set: {status: "approved"}});\n')
        self.assertTrue(gate.scan(body, "p.js"))
        # ... and a destructured alias to something else is not ours
        body2 = ('const {artists: a} = db;\n'
                 'const b = a;\n'
                 'b.updateOne({}, {$set: {name: "x"}});\n')
        self.assertEqual(gate.scan(body2, "p.js"), [])

    # ── qa-review #1578 (r19): ONE coordinate system for binding and call positions ─────────────────────────────
    def test_alias_positions_and_call_positions_share_one_coordinate_system(self):
        """QA's reproducer: bindings were recorded in `raw_code` (quotes intact) and compared with call positions in
        the quote-stripped `flat` string, so after enough quotes the offsets drifted and a real write stopped
        matching its own alias."""
        body = "\n".join(['const x%d = "";' % i for i in range(100)] +
                         ['const a = db.collection("credit_requests");',
                          'a.updateOne({}, {$set: {status: "approved"}});'])
        self.assertTrue(gate.scan(body, "p.js"))
        # ... and the same shape on an unrelated collection stays clean
        body2 = "\n".join(['const x%d = "";' % i for i in range(100)] +
                          ['const a = db.collection("artists");',
                           'a.updateOne({}, {$set: {name: "x"}});'])
        self.assertEqual(gate.scan(body2, "p.js"), [])

    # ── qa-review #1578 (r20): PyMongo's get_collection is the same receiver ────────────────────────────────────
    def test_get_collection_is_the_same_receiver(self):
        """QA's reproducer: PyMongo's `db.get_collection("credit_requests")` was not recognized."""
        self.assertTrue(gate.scan('db.get_collection("credit_requests").updateOne({}, {$set: {status: "approved"}});',
                                  "p.py"))
        self.assertTrue(gate.scan('c = db.get_collection("credit_requests")\nc.update_one({}, {})', "p.py"))

    # ── qa-review #1578 (r21): a quoted delimiter does not close the receiver ───────────────────────────────────
    def test_a_quoted_closing_delimiter_does_not_close_the_receiver(self):
        """QA's reproducer: the depth walk ran on the quote-stripped stream, so a `)` inside a string argument
        decremented the depth and the write verb fell outside the receiver."""
        for delim in (")", "}"):
            with self.subTest(delim=delim):
                self.assertTrue(caught(
                    'db.collection("credit_requests", {comment: "%s"})'
                    '.updateOne({}, {$set: {status: "approved"}})' % delim))

    def test_a_quoted_opening_delimiter_does_not_open_a_nested_scope(self):
        for delim in ("(", "{", "a, b"):
            with self.subTest(delim=delim):
                self.assertTrue(caught(
                    'db.collection("credit_requests", {comment: "%s"})'
                    '.insertOne({status: "approved"})' % delim))

    def test_a_literal_that_looks_like_a_receiver_is_not_one(self):
        """Near-miss: the mask must not turn string content into a receiver."""
        self.assertFalse(caught('const s = "db.collection(credit_requests).updateOne("; db.artists.updateOne({}, {})'))
        self.assertFalse(caught('db.collection("artists", {comment: ")"}).insertOne({status: "approved"})'))

    def test_a_quoted_delimiter_does_not_break_the_alias_binding(self):
        """The same mask feeds `_is_credit_expr`, so a quoted delimiter in the binding's options must not unbind it."""
        self.assertTrue(caught('const c = db.collection("credit_requests", {comment: ")"});\n'
                               'c.updateOne({}, {$set: {status: "approved"}})'))

    # ── qa-review #1578 (r22): a template interpolation is CODE, not string content ────────────────────────────
    def test_a_write_inside_a_template_interpolation_is_caught(self):
        """QA's reproducer: the whole backtick run was masked as string content, so `${...}` - which EXECUTES - hid
        the receiver completely and the entrypoint exited 0."""
        self.assertTrue(caught('const s = `${db.collection("credit_requests").updateOne({}, {$set: {status: "approved"}})}`;'))
        self.assertTrue(caught('const s = `${db.credit_requests.updateMany({}, {status: "approved"})}`;'))

    def test_a_write_inside_a_NESTED_template_interpolation_is_caught(self):
        """The body is ordinary JavaScript: a nested template, and a nested interpolation inside it, must not close
        the outer interpolation early."""
        self.assertTrue(caught('const l = `a ${f({b: `c ${db.collection("credit_requests").insertOne({})}`})}`;'))
        self.assertTrue(caught('const l = `a ${db.credit_requests.updateOne({}, {})}`;'))

    # ── qa-review #1578 (r23): an interpolation body is scanned as ordinary code ────────────────────────────────
    def test_a_quoted_delimiter_inside_an_interpolation_does_not_close_the_receiver(self):
        """QA's reproducer: r22 left the body unmarked but did not mark its OWN literals, so a quoted `)` inside the
        body closed the receiver at a data character and `.updateOne` fell outside it."""
        for delim in (")", "}"):
            with self.subTest(delim=delim):
                self.assertTrue(caught(
                    'const x = `${db.collection("credit_requests", {comment: "%s"})'
                    '.updateOne({}, {$set: {status: "approved"}})}`;' % delim))

    def test_a_comment_inside_an_interpolation_is_a_comment(self):
        """The body is code, so a comment in it is blanked - not swallowed as literal text that hides the verb."""
        self.assertTrue(caught('const x = `${db.collection("credit_requests") /* c */ '
                               '.updateOne({}, {$set: {status: "approved"}})}`;'))
        self.assertTrue(caught('const x = `${db.collection("credit_requests") // c\n'
                               '.updateOne({}, {$set: {status: "approved"}})}`;'))

    # ── qa-review #1578 (r24): an interpolation body may span newlines ─────────────────────────────────────────
    def test_a_multiline_interpolation_is_still_code(self):
        """QA's reproducer: the code walk returned at the interpolation's newline, so a `/* hi */` on the next line was
        not blanked and the receiver matcher could not join the collection call to `.updateOne`."""
        self.assertTrue(caught('const s = `${db.collection("credit_requests", {comment: ")"})\n'
                               ' /* hi */ .updateOne({}, {$set: {status: "approved"}})}`;'))
        self.assertTrue(caught('const s = `${db.collection("credit_requests")\n'
                               '.updateOne({}, {$set: {status: "approved"}})}`;'))

    def test_an_UNTERMINATED_interpolation_still_stops_at_the_newline(self):
        """Near-miss: the newline rule survives as the fallback, so a stray `${` cannot swallow the rest of the file."""
        self.assertFalse(caught('const l = `a ${b`;\ndb.collection("artists").insertOne({status: "approved"})'))

    def test_a_template_literal_does_not_wedge_the_scanner(self):
        """Near-miss: an unterminated interpolation, and literal text around an interpolation that merely NAMES the
        collection, must not be read as a write."""
        self.assertFalse(caught('const l = `a ${b`;\ndb.collection("artists").insertOne({status: "approved"})'))
        self.assertFalse(caught('const l = `credit_requests ${name} as a table name`;\n'
                                'db.artists.updateOne({}, {$set: {name: "x"}})'))
        self.assertTrue(caught('const l = `credit_requests`;\ndb.collection("credit_requests").updateOne({}, {})'))

    def test_a_shell_hash_that_is_not_a_comment_stays_visible(self):
        """POSIX: `#` starts a comment only at the start of a word, so `${var#prefix}` and `foo#bar` are code. A
        shell script that really writes the status is still refused."""
        self.assertTrue(gate.scan('psql -c "UPDATE credit_requests SET status = %s"\n' % "'approved'", "probe.sh"))
        self.assertTrue(gate.scan("echo ${x#credit_requests}; db.credit_requests.updateOne({}, {})\n", "probe.sh"))
        self.assertEqual(gate.scan("echo foo#credit_requests\n", "probe.sh"), [])


if __name__ == "__main__":
    unittest.main()
