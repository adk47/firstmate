"""Unit tests for scripts/lib/trino_sql_extract.py — the pure/offline
extraction layer for scripts/check-trino-sql.sh (the Trino SQL staleness
gate). Stdlib unittest only (no pytest, no network) — run by name in
pr-validate.yml:
  python3 -m unittest -v tests.test_trino_sql_extract
"""
import unittest

from scripts.lib import trino_sql_extract as tse


class SplitStatements(unittest.TestCase):
    def test_single_statement_no_trailing_semicolon(self):
        got = tse.split_statements("SELECT 1")
        self.assertEqual(got, [(1, "SELECT 1")])

    def test_splits_on_top_level_semicolons(self):
        got = tse.split_statements("SELECT 1; SELECT 2; SELECT 3;")
        self.assertEqual([s for _, s in got], ["SELECT 1", "SELECT 2", "SELECT 3"])

    def test_semicolon_inside_single_quoted_string_does_not_split(self):
        sql = "SELECT 'a;b' AS x; SELECT 2"
        got = tse.split_statements(sql)
        self.assertEqual([s for _, s in got], ["SELECT 'a;b' AS x", "SELECT 2"])

    def test_escaped_quote_inside_string_does_not_end_it_early(self):
        sql = "SELECT 'it''s; not a split' AS x; SELECT 2"
        got = tse.split_statements(sql)
        self.assertEqual(len(got), 2)
        self.assertIn("it''s; not a split", got[0][1])

    def test_semicolon_inside_double_quoted_identifier_does_not_split(self):
        sql = 'SELECT "weird;column" FROM t; SELECT 2'
        got = tse.split_statements(sql)
        self.assertEqual(len(got), 2)

    def test_semicolon_inside_line_comment_does_not_split(self):
        sql = "SELECT 1 -- comment with a ; in it\nWHERE true; SELECT 2"
        got = tse.split_statements(sql)
        self.assertEqual(len(got), 2)

    def test_semicolon_inside_block_comment_does_not_split(self):
        sql = "SELECT 1 /* block ; comment */ FROM t; SELECT 2"
        got = tse.split_statements(sql)
        self.assertEqual(len(got), 2)

    def test_empty_statements_are_dropped(self):
        got = tse.split_statements("SELECT 1;;;  ; SELECT 2;")
        self.assertEqual([s for _, s in got], ["SELECT 1", "SELECT 2"])

    def test_line_numbers_track_multiline_statements(self):
        sql = "SELECT 1\nFROM t;\nSELECT 2\nFROM u;"
        got = tse.split_statements(sql, start_line=10)
        self.assertEqual(got[0][0], 10)
        # The 2nd statement starts right after the ';' on the same physical
        # line as "FROM t;" (line 11) — its first real content line (12) is
        # what a human sees, but the split point itself is on line 11.
        self.assertEqual(got[1][0], 11)

    def test_the_safety_invariant_multi_statement_anti_example_fence(self):
        # Mirrors a real skills-all/ fence: a numbered walkthrough followed by
        # a deliberate BAD anti-example, all in one ```sql block joined by ';'.
        sql = (
            "SELECT 1 FROM small_table LIMIT 10;\n"
            "-- BAD: JOIN two massive tables without filters\n"
            "SELECT * FROM hive.a s JOIN hive.b t ON s.id = t.id;\n"
        )
        got = tse.split_statements(sql)
        self.assertEqual(len(got), 2)
        # Every returned statement must be independently EXPLAIN-able; none
        # may still carry an embedded ';' (which would let anything after
        # the first EXPLAIN-prefixed statement execute for real).
        for _, stmt in got:
            self.assertNotIn(";", stmt)


class NormalizeSql(unittest.TestCase):
    def test_collapses_whitespace(self):
        self.assertEqual(tse.normalize_sql("SELECT   1\n\nFROM   t"), "SELECT 1 FROM t")

    def test_strips_line_comments(self):
        self.assertEqual(
            tse.normalize_sql("SELECT 1 -- trailing comment\nFROM t"),
            "SELECT 1 FROM t",
        )

    def test_strips_block_comments(self):
        self.assertEqual(
            tse.normalize_sql("SELECT 1 /* explain this */ FROM t"),
            "SELECT 1 FROM t",
        )

    def test_reindentation_does_not_change_the_hash(self):
        a = tse.normalize_sql("SELECT 1\nFROM t\nWHERE x = 1")
        b = tse.normalize_sql("  SELECT 1\n    FROM t\n  WHERE x = 1  ")
        self.assertEqual(a, b)

    def test_editing_the_query_does_change_the_hash(self):
        a = tse.normalize_sql("SELECT 1 FROM t")
        b = tse.normalize_sql("SELECT 2 FROM t")
        self.assertNotEqual(a, b)

    def test_dash_dash_inside_a_string_literal_is_not_treated_as_a_comment(self):
        got = tse.normalize_sql("SELECT '--not a comment' AS x")
        self.assertIn("--not a comment", got)

    def test_stripped_comment_leaves_a_token_boundary(self):
        # Discrimination: a comment welded between two tokens must not fuse
        # them. `SELECT bad/*note*/FROM t` used to normalize to
        # `SELECT badFROM t` and collide with the genuinely different
        # statement below — letting an already-baselined commented form
        # absorb a newly-added failing one as pre-existing debt.
        self.assertEqual(tse.normalize_sql("SELECT bad/*note*/FROM t"), "SELECT bad FROM t")
        self.assertNotEqual(
            tse.normalize_sql("SELECT bad/*note*/FROM t"),
            tse.normalize_sql("SELECT badFROM t"),
        )

    def test_token_boundary_is_stable_against_ordinary_whitespace(self):
        # Stability pair: for comments that were ALREADY whitespace-separated
        # the inserted space must collapse away, so existing baseline hashes
        # do not churn. Without this pair the discrimination test above would
        # pass equally against a change that rewrote every hash.
        self.assertEqual(
            tse.normalize_sql("SELECT bad /* note */ FROM t"),
            tse.normalize_sql("SELECT bad FROM t"),
        )
        self.assertEqual(
            tse.normalize_sql("SELECT a -- note\nFROM t"),
            tse.normalize_sql("SELECT a FROM t"),
        )


class HasTopLevelSemicolon(unittest.TestCase):
    """THE safety invariant: the Trino CLI splits `--execute` on ';' and only
    the FIRST statement keeps the EXPLAIN prefix. Detection must key on the
    DELIMITER, not on how many non-empty statements survive splitting."""

    def test_leading_semicolon_is_detected(self):
        # The regression: split_statements() drops the empty first statement,
        # so this used to read as delimiter-free and was sent to Trino, which
        # would have EXECUTED the trailing SELECT unprefixed.
        self.assertTrue(tse.has_top_level_semicolon("; SELECT * FROM hive.dangerous"))

    def test_doubled_semicolon_is_detected(self):
        self.assertTrue(tse.has_top_level_semicolon("SELECT 1 ;; SELECT 2"))

    def test_ordinary_separator_is_detected(self):
        self.assertTrue(tse.has_top_level_semicolon("SELECT 1; SELECT 2"))

    def test_semicolon_inside_a_line_comment_is_not_a_delimiter(self):
        self.assertFalse(tse.has_top_level_semicolon("SELECT 1 -- a ; b"))

    def test_semicolon_inside_a_string_literal_is_not_a_delimiter(self):
        self.assertFalse(tse.has_top_level_semicolon("SELECT ';' AS x"))

    def test_semicolon_inside_a_block_comment_is_not_a_delimiter(self):
        self.assertFalse(tse.has_top_level_semicolon("SELECT 1 /* a ; b */ FROM t"))

    def test_clean_single_statement_has_none(self):
        self.assertFalse(tse.has_top_level_semicolon("SELECT 1 FROM t"))


class ExtractSqlFences(unittest.TestCase):
    def test_extracts_bare_sql_fence_with_no_runner(self):
        text = "# doc\n\n```sql\nSELECT 1 FROM t\n```\n"
        result = tse.extract_file("skills-all/x/SKILL.md", text)
        self.assertEqual(len(result.blocks), 1)
        self.assertEqual(result.blocks[0].sql, "SELECT 1 FROM t")
        self.assertIsNone(result.blocks[0].runner)

    def test_trailing_comment_only_fragment_after_final_semicolon_is_dropped(self):
        # Real regression: a fence ending "...LIKE '%x%';  -- Know what you're
        # dealing with" produced a trailing comment-only "statement" that
        # normalized to '' and hashed to sha1('') in the baseline.
        text = (
            "```sql\n"
            "SELECT 1 FROM t;\n"
            "-- trailing comment, no more SQL after it\n"
            "```\n"
        )
        result = tse.extract_file("skills-all/x/SKILL.md", text)
        self.assertEqual([b.sql for b in result.blocks], ["SELECT 1 FROM t"])

    def test_splits_multi_statement_sql_fence(self):
        text = "```sql\nSELECT 1;\nSELECT 2;\n```\n"
        result = tse.extract_file("skills-all/x/SKILL.md", text)
        self.assertEqual([b.sql for b in result.blocks], ["SELECT 1", "SELECT 2"])

    def test_skip_marker_declares_a_fence_out_of_scope(self):
        text = (
            "<!-- trino-sql-gate: skip (postgres DDL, not Trino) -->\n"
            "```sql\nCREATE ROLE readonly;\n```\n"
        )
        result = tse.extract_file("skills-all/x/SKILL.md", text)
        self.assertEqual(result.blocks, [])
        self.assertEqual(len(result.skipped_declared), 1)
        self.assertEqual(result.skipped_declared[0].reason, "postgres DDL, not Trino")

    def test_skip_marker_must_be_immediately_above_the_fence(self):
        text = (
            "<!-- trino-sql-gate: skip (postgres DDL, not Trino) -->\n"
            "some prose in between\n"
            "```sql\nSELECT 1\n```\n"
        )
        result = tse.extract_file("skills-all/x/SKILL.md", text)
        self.assertEqual(len(result.blocks), 1)
        self.assertEqual(result.skipped_declared, [])


class ExtractBashInvocations(unittest.TestCase):
    def test_trino_query_sh_quoted_arg(self):
        text = '```bash\nbash /opt/hydra/scripts/trino-query.sh "SELECT 1 FROM t"\n```\n'
        result = tse.extract_file("skills-all/x/SKILL.md", text)
        self.assertEqual(len(result.blocks), 1)
        self.assertEqual(result.blocks[0].sql, "SELECT 1 FROM t")
        self.assertEqual(result.blocks[0].runner, "trino-query.sh")

    def test_muso_query_quoted_arg(self):
        text = '```bash\nmuso query "SELECT 1 FROM t"\n```\n'
        result = tse.extract_file("skills-all/x/SKILL.md", text)
        self.assertEqual(result.blocks[0].runner, "muso-query")
        self.assertEqual(result.blocks[0].sql, "SELECT 1 FROM t")

    def test_muso_query_heredoc(self):
        text = "```bash\nmuso query - <<'SQL'\nSELECT id, email\nFROM users\nSQL\n```\n"
        result = tse.extract_file("skills-all/x/SKILL.md", text)
        self.assertEqual(len(result.blocks), 1)
        self.assertEqual(result.blocks[0].sql, "SELECT id, email\nFROM users")
        self.assertEqual(result.blocks[0].runner, "muso-query")

    def test_trino_query_sh_line_continuation_before_quote(self):
        text = (
            "```bash\n"
            "bash /opt/hydra/scripts/trino-query.sh \\\n"
            '  "SELECT * FROM t LIMIT 10"\n'
            "```\n"
        )
        result = tse.extract_file("skills-all/x/SKILL.md", text)
        self.assertEqual(len(result.blocks), 1)
        self.assertEqual(result.blocks[0].sql, "SELECT * FROM t LIMIT 10")

    def test_bash_comment_mentioning_the_runner_is_not_an_invocation(self):
        # Real regression: trino-schemas.md's prose comment
        # "# ...bash trino-query.sh \"<SQL>\" (it still rewrites)." was
        # matched as a live invocation and extracted the literal `<SQL>`.
        text = (
            "```bash\n"
            "# for saved queries, run bash trino-query.sh \"<SQL>\" (it rewrites)\n"
            'muso query "SELECT 1 FROM t"\n'
            "```\n"
        )
        result = tse.extract_file("skills-all/x/SKILL.md", text)
        self.assertEqual(len(result.blocks), 1)
        self.assertEqual(result.blocks[0].sql, "SELECT 1 FROM t")

    def test_plain_prose_bash_fence_with_no_invocation_yields_nothing(self):
        text = "```bash\necho hello world\n```\n"
        result = tse.extract_file("skills-all/x/SKILL.md", text)
        self.assertEqual(result.blocks, [])

    def test_sh_file_heredoc_is_scanned_directly_no_fence_needed(self):
        text = 'echo start\ntrino-query.sh <<\'SQL\'\nSELECT 1\nSQL\necho done\n'
        result = tse.extract_file("skills-all/x/run.sh", text)
        self.assertEqual(len(result.blocks), 1)
        self.assertEqual(result.blocks[0].sql, "SELECT 1")
        self.assertEqual(result.blocks[0].runner, "trino-query.sh")


class ExclusionAndDiscovery(unittest.TestCase):
    def test_saved_queries_tree_is_excluded_even_with_sql_fences(self):
        text = "```sql\nSELECT * FROM legacy_table\n```\n"
        result = tse.extract_file(
            "skills-all/muso-query-writer/saved-queries/misc/x.md", text
        )
        self.assertEqual(result.blocks, [])
        self.assertEqual(result.skipped_declared, [])

    def test_is_excluded_helper(self):
        self.assertTrue(
            tse._is_excluded("skills-all/muso-query-writer/saved-queries/misc/x.md")
        )
        self.assertFalse(tse._is_excluded("skills-all/muso-query-writer/reference.md"))


if __name__ == "__main__":
    unittest.main()
