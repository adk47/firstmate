"""scripts/credit_review/core_notice.py: core's own notices hold a user from every hydra note (Fable sender map
2026-10-27 item 2). The fake replica answers the two SELECTs by table name. Stdlib only."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(HERE, "..", "credit_review", "core_notice.py")
spec = importlib.util.spec_from_file_location("core_notice", PATH)
cn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cn)
NOW = datetime(2026, 10, 27, 15, 0, tzinfo=timezone.utc)


def fake(requests, claims=()):
    """requests: [(uid, approvedNotice, proofRequest, infoRequest, updatedat)]; claims: [(uid, updatedat[, createdat])]."""
    def q(sql):
        if "credit_requests" in sql:
            return [[str(r[0]), *r[1:]] for r in requests]
        return [[str(c[0]), c[1], c[2] if len(c) > 2 else "2026-01-01 00:00:00.000"] for c in claims]
    return q


class ReasonsTest(unittest.TestCase):
    def why(self, requests, claims=(), ids=(1,)):
        # the boundary and parsing rules below are written against a 7-day window; the module's DEFAULT window is
        # node-8's (CORE_NOTICE_WINDOW_DAYS, 3 days: DefaultWindowTest), so these pass the week explicitly
        return cn.reasons_by_user(ids, query=fake(requests, claims), now=NOW, window=timedelta(days=7))

    def test_each_core_marker_within_7_days_holds(self):
        old = "2026-09-01 00:00:00.000"
        cases = {
            "approvedNotice within 7d": (1, '{"noticeSentAt":"2026-10-25T16:22:50.366Z"}', "", "", old),
            "proofRequest within 7d": (1, "", '{"noticeSentAt":"2026-10-21T00:00:01Z","x":1}', "", old),
            "infoRequest within 7d": (1, "", "", '{"sentAt":"2026-10-26T09:00:00Z"}', old),
            "credit request changed today": (1, "", "", "", "2026-10-27 08:00:00.000"),
        }
        for want, r in cases.items():
            self.assertEqual(self.why([r])[1], [want])
        self.assertEqual(self.why([(1, "", "", "", old)], claims=[(1, "2026-10-24 10:00:00.000")])[1],
                         ["claim updated within 7d"])

    def test_a_24_hour_window_holds_only_the_last_24_hours_and_names_its_window(self):
        # firstmate 034a: the ask (proof-need-ask) waits 24 hours after a core notice, not 7 days
        old = "2026-09-01 00:00:00.000"
        win = timedelta(hours=24)
        why = lambda r, claims=(): cn.reasons_by_user([1], query=fake([r], claims), now=NOW, window=win)[1]  # noqa: E731
        self.assertEqual(why((1, '{"noticeSentAt":"2026-10-25T16:22:50Z"}', "", "", old)), [])      # 46 h ago
        self.assertEqual(why((1, '{"noticeSentAt":"2026-10-26T15:30:00Z"}', "", "", old)), ["approvedNotice within 24h"])
        self.assertEqual(why((1, "", "", "", old), claims=[(1, "2026-10-24 10:00:00.000")]), [])
        self.assertEqual(why((1, "", "", "", old), claims=[(1, "2026-10-27 10:00:00.000")]), ["claim updated within 24h"])
        self.assertEqual(why((1, "", "", "", "2026-10-27 08:00:00.000")), ["credit request changed today"])

    def test_a_claim_never_touched_since_filing_is_not_a_notice(self):
        # p1 180: claims 1621336/1621425/1621613 were held only because they were FILED within 7 days
        old = "2026-09-01 00:00:00.000"
        filed = "2026-10-27 21:21:41.075000 UTC"
        self.assertEqual(self.why([(1, "", "", "", old)], claims=[(1, filed, filed)])[1], [])
        # touched after filing (a decision / code check) still holds, as does any other recent claim of the user
        self.assertEqual(self.why([(1, "", "", "", old)], claims=[(1, "2026-10-28 09:00:00.000 UTC", filed)])[1],
                         ["claim updated within 7d"])
        self.assertEqual(self.why([(1, "", "", "", old)], claims=[(1, filed, filed), (1, "2026-10-26 10:00:00.000", "2026-10-01 00:00:00.000")])[1],
                         ["claim updated within 7d"])

    def test_the_untouched_rule_is_claims_only_a_request_marker_still_counts(self):
        # r5 on #1498: a credit REQUEST never updated since it was created still holds on a core marker - the
        # updatedat == createdat exclusion applies to claim filings only
        filed = "2026-10-27 21:21:41.075000 UTC"
        filed = "2026-10-25 10:00:00.000 UTC"   # never updated since: updatedat == the marker time
        self.assertEqual(self.why([(1, "", '{"noticeSentAt":"2026-10-25T10:00:00Z"}', "", filed)])[1],
                         ["proofRequest within 7d"])
        self.assertEqual(self.why([(1, "", "", '{"sentAt":"2026-10-26T09:00:00Z"}', "2026-10-26 09:00:00.000")])[1],
                         ["infoRequest within 7d"])

    def test_offsets_are_honoured_at_the_7_day_boundary(self):
        # QA + Fable on #1397: at 2026-10-27T15:00Z, 2026-10-20T14:30:00-02:00 = 16:30Z is 6 d 22.5 h old (hold);
        # the prefix-only parser read it as 14:30Z, 7 d 0.5 h old (clear).
        old = "2026-09-01 00:00:00.000 UTC"
        for v, want in (('"2026-10-20T14:30:00-02:00"', ["approvedNotice within 7d"]),
                        ('"2026-10-20T14:30:00-0200"', ["approvedNotice within 7d"]),
                        ('"2026-10-20T14:30:00-02"', ["approvedNotice within 7d"]),
                        ('"2026-10-20T16:30:00+02:00"', []),          # 14:30Z: 7 d 0.5 h old
                        ('"2026-10-20T15:00:00.000Z"', ["approvedNotice within 7d"]),   # exactly 7 days
                        ('"2026-10-20T14:59:59.999999Z"', []),
                        ('"2026-10-20T15:00:00"', ["approvedNotice within 7d"])):      # no zone = UTC
            self.assertEqual(self.why([(1, '{"noticeSentAt":%s}' % v, "", "", old)])[1], want, v)
        # "changed today" is the UTC day: 2026-10-27T01:00+05:00 is 10-26 20:00Z (not today)
        self.assertEqual(self.why([(1, "", "", "", "2026-10-27 01:00:00.000 +05:00")])[1], [])
        self.assertEqual(self.why([(1, "", "", "", "2026-10-26 23:30:00.000 -02:00")])[1],
                         ["credit request changed today"])
        self.assertEqual(self.why([(1, "", "", "", old)], claims=[(1, "2026-10-20 16:00:00.000 -01:00")])[1],
                         ["claim updated within 7d"])

    def test_a_present_marker_without_a_readable_timestamp_is_unknown_not_clear(self):
        old = "2026-09-01 00:00:00.000 UTC"
        for blob in ('{"requested":true}', '{"noticeSentAt":"yesterday"}', '{"noticeSentAt":"2026-13-45T99:00:00Z"}',
                     # an old valid stamp never vouches for a broken one next to it (QA on #1397, both cases)
                     '{"at":"2026-01-01T00:00:00Z","noticeSentAt":"2026-10-32T10:00:00Z"}',
                     '{"createdAt":"2026-09-01T00:00:00Z","noticeSentAt":"bad"}',
                     '{"noticeSentAt":"2026-09-01T00:00:00Z junk"}',
                     '{"noticeSentAt":"x 2026-09-01T00:00:00Z"}',
                     '{"noticeSentAt":1761550000000}',
                     '{"nested":{"responseAt":"soon"},"at":"2026-01-01T00:00:00Z"}',
                     '{"noticeSentAt":"2026-09-01T00:00:00Z"', '[1,2]'):
            got = self.why([(1, "", blob, "", old)])[1]
            self.assertEqual(len(got), 1, blob)
            self.assertTrue(got[0].startswith(cn.UNKNOWN + "proofRequest"), got)
        self.assertTrue(self.why([(1, "", "", "", "garbage")])[1][0].startswith(cn.UNKNOWN))
        self.assertEqual(self.why([(1, "null", "", "", old)])[1], [])     # JSON null = no marker
        # null fields and non-timestamp fields are fine; a recent stamp in a nested timestamp field counts
        self.assertEqual(self.why([(1, '{"noticeSentAt":null,"at":"2026-09-01T00:00:00Z","reasons":["2026-10-26"]}',
                                    "", "", old)])[1], [])
        self.assertEqual(self.why([(1, "", '{"x":{"sentAt":"2026-10-26T00:00:00Z"}}', "", old)])[1],
                         ["proofRequest within 7d"])
        # timestamps inside lists are read too: a recent one holds, a broken one is unknown
        self.assertEqual(self.why([(1, '{"history":[{"sentAt":"2026-10-26T00:00:00Z"}]}', "", "", old)])[1],
                         ["approvedNotice within 7d"])
        self.assertTrue(self.why([(1, '{"at":"2026-01-01T00:00:00Z","history":[{"sentAt":"bad"}]}', "", "", old)]
                                 )[1][0].startswith(cn.UNKNOWN))
        # a plain column must be exactly one timestamp
        self.assertTrue(self.why([(1, "", "", "", old + " x")])[1][0].startswith(cn.UNKNOWN))

    def test_older_markers_and_other_users_are_clear(self):
        r = [(1, '{"noticeSentAt":"2026-10-19T23:59:59Z"}', '{"noticeSentAt":"2026-08-01T00:00:00Z"}', "",
              "2026-10-26 23:59:59.000"),
             (2, '{"noticeSentAt":"2026-10-27T09:00:00Z"}', "", "", "2026-10-27 09:00:00.000")]
        got = self.why(r, claims=[(1, "2026-10-10 00:00:00.000")], ids=(1,))
        self.assertEqual(got, {1: []})   # user 2's rows never leak onto user 1

    def test_a_malformed_replica_row_is_unreadable_not_clear(self):
        with self.assertRaises(cn.Unreadable):
            cn.reasons_by_user([1], query=lambda sql: [["1", "x"]], now=NOW)

    def test_email_lookup_is_validated_and_case_insensitive(self):
        seen = []
        def q(sql):
            seen.append(sql)
            return [["42"], ["43"]]
        self.assertEqual(cn.user_ids_for_email("Jane@Example.com", query=q), [42, 43])
        self.assertIn("lower(email) = 'jane@example.com'", seen[0])
        for bad in ("", "no-at-sign", "x'@y.com", "a b@c.com", "x@y"):
            with self.assertRaises(cn.Unreadable, msg=bad):
                cn.user_ids_for_email(bad, query=q)

    def test_unreadable_replica_raises(self):
        def broken(sql):
            raise cn.Unreadable("trino rc=2")
        with self.assertRaises(cn.Unreadable):
            cn.reasons_by_user([1], query=broken, now=NOW)


class DefaultWindowTest(unittest.TestCase):
    def test_the_module_reads_core_notice_window_days_default_three(self):
        code = ("import importlib.util,sys; s=importlib.util.spec_from_file_location('m', sys.argv[1]); "
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.WINDOW.total_seconds())")
        for env, want in (({}, 3 * 86400), ({"CORE_NOTICE_WINDOW_DAYS": "7"}, 7 * 86400),
                          ({"CORE_NOTICE_WINDOW_DAYS": "1.5"}, 1.5 * 86400)):
            e = {k: v for k, v in os.environ.items() if k != "CORE_NOTICE_WINDOW_DAYS"}
            e.update(env)
            out = subprocess.run([sys.executable, "-c", code, PATH], env=e, capture_output=True, text=True)
            self.assertEqual(float(out.stdout), want, out.stderr)

    def test_the_claim_lookback_covers_the_window_plus_a_day(self):
        """QA on #2132: the claim read looked back a fixed 8 days, so a longer window never saw an older claim update.
        The lookback is now the window + 1 day (whole days); a week keeps the old 8."""
        for window, days in ((timedelta(days=7), 8), (timedelta(days=3), 4), (timedelta(hours=24), 2),
                             (timedelta(hours=36), 3), (timedelta(hours=1), 2)):
            self.assertEqual(cn.claim_lookback_days(window), days, window)
            self.assertIn(f"INTERVAL '{days}' DAY", cn.statements("1", window)[1])
        # the read reasons_by_user sends is the statement for ITS window, and a claim updated inside it holds
        asked: list[str] = []
        upd = (NOW - timedelta(days=5)).strftime("%Y-%m-%d %H:%M:%S.000 UTC")

        def q(sql):
            asked.append(sql)
            return [["1", upd, "2026-01-01 00:00:00.000 UTC"]] if "claiming" in sql else []
        got = cn.reasons_by_user([1], query=q, now=NOW, window=timedelta(days=7))[1]
        self.assertEqual(got, ["claim updated within 7d"])
        self.assertIn("INTERVAL '8' DAY", [s for s in asked if "claiming" in s][0])
        asked.clear()
        self.assertEqual(cn.reasons_by_user([1], query=q, now=NOW, window=timedelta(days=3))[1], [])
        self.assertIn("INTERVAL '4' DAY", [s for s in asked if "claiming" in s][0])

    def test_a_window_outside_one_hour_to_seven_days_is_refused(self):
        for bad in (timedelta(days=8), timedelta(minutes=30)):
            with self.assertRaises(cn.Unreadable):
                cn.reasons_by_user([1], query=fake([]), now=NOW, window=bad)

    def test_the_default_window_names_itself_in_the_reasons(self):
        r = (1, '{"noticeSentAt":"2026-10-26T15:00:00Z"}', "", "", "2026-01-01 00:00:00.000")
        got = cn.reasons_by_user([1], query=fake([r]), now=NOW, window=timedelta(days=3))[1]
        self.assertEqual(got, ["approvedNotice within 72h"])


class CliTest(unittest.TestCase):
    """The CLI exit contract the gate relies on: 0 clear, 3 hold, 2 unknown (never clear)."""

    def run_cli(self, trino_body, *args, extra_env=None):
        t = tempfile.mkdtemp()
        stub = os.path.join(t, "trino")
        open(stub, "w").write("#!/usr/bin/env bash\n" + trino_body + "\n")
        os.chmod(stub, 0o755)
        env = dict(os.environ, CORE_NOTICE_TRINO=stub)
        env.pop("CORE_NOTICE_WINDOW_DAYS", None)
        env.update(extra_env or {})
        return subprocess.run([sys.executable, "-I", PATH, *args], env=env, capture_output=True, text=True), t

    def test_the_cli_takes_the_window_in_hours_and_refuses_one_outside_a_week(self):
        two_days = (datetime.now(timezone.utc) - timedelta(hours=48)).strftime("%Y-%m-%dT%H:%M:%SZ")
        body = ('grep -q claiming && exit 0; '
                f'echo \'"7","{{""noticeSentAt"":""{two_days}""}}","","","2020-01-01 00:00:00.000"\'')
        p, _ = self.run_cli(body, "check", "--user-id", "7")
        self.assertEqual(p.returncode, 3, p.stdout + p.stderr)                  # the default 3 days: held
        p, _ = self.run_cli(body, "check", "--user-id", "7", "--window-hours", "24")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)                  # 24 hours: clear
        for bad in ("0", "169"):
            p, _ = self.run_cli(body, "check", "--user-id", "7", "--window-hours", bad)
            self.assertEqual(p.returncode, 2, p.stdout + p.stderr)

    def test_the_default_window_is_node8s_three_days_and_follows_core_notice_window_days(self):
        """firstmate 045: node-8 ran a hand edit from 2026-11-10 16:45Z (WINDOW from CORE_NOTICE_WINDOW_DAYS, default 3
        days; 7 days deferred almost every candidate). Every caller that passes no --window-hours gets it; the flag's
        default follows the env. An env outside 1 hour..7 days (QA on #2132) refuses every read: exit 2, never a
        wrong window and never a silent default."""
        four_days = (datetime.now(timezone.utc) - timedelta(hours=96)).strftime("%Y-%m-%dT%H:%M:%SZ")
        body = ('grep -q claiming && exit 0; '
                f'echo \'"7","{{""noticeSentAt"":""{four_days}""}}","","","2020-01-01 00:00:00.000"\'')
        p, _ = self.run_cli(body, "check", "--user-id", "7")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)                  # 4 days ago, default 3 days: clear
        p, _ = self.run_cli(body, "check", "--user-id", "7", extra_env={"CORE_NOTICE_WINDOW_DAYS": "7"})
        self.assertEqual(p.returncode, 3, p.stdout + p.stderr)                  # the env's 7 days: held
        self.assertIn("approvedNotice within 7d", json.loads(p.stdout)["reasons"])
        p, _ = self.run_cli(body, "check", "--user-id", "7", "--window-hours", "24",
                            extra_env={"CORE_NOTICE_WINDOW_DAYS": "7"})
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)                  # the gate's 24 h still wins

    def test_an_env_window_outside_one_hour_to_seven_days_refuses_loudly(self):
        """QA on #2132: CORE_NOTICE_WINDOW_DAYS has the same bound as --window-hours (1..168 hours). Out of range or
        not a number: exit 2 with the reason, whatever --window-hours says - the config is wrong, so nothing is read."""
        body = 'grep -q claiming && exit 0; echo \'"7","","","","2020-01-01 00:00:00.000"\''
        for bad in ("10", "8", "0", "-1", "0.01", "three", "nan"):
            for extra in ((), ("--window-hours", "24")):
                p, _ = self.run_cli(body, "check", "--user-id", "7", *extra,
                                    extra_env={"CORE_NOTICE_WINDOW_DAYS": bad})
                self.assertEqual(p.returncode, 2, (bad, extra, p.stdout + p.stderr))
                out = json.loads(p.stdout)
                self.assertIsNone(out["hold"])
                self.assertIn("CORE_NOTICE_WINDOW_DAYS", out["reasons"][0])
        for edge in ("7", str(1 / 24)):                                         # the bounds themselves are taken
            p, _ = self.run_cli(body, "check", "--user-id", "7", extra_env={"CORE_NOTICE_WINDOW_DAYS": edge})
            self.assertEqual(p.returncode, 0, (edge, p.stdout + p.stderr))

    def test_exit_codes(self):
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        hold = 'grep -q claiming && exit 0; ' + f'echo \'"7","","","","{today} 01:00:00.000"\''
        p, _ = self.run_cli(hold, "check", "--user-id", "7")
        self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
        self.assertEqual(json.loads(p.stdout)["reason"], "core_notice_within_7d")
        p, _ = self.run_cli("cat >/dev/null; true", "check", "--user-id", "7")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        p, _ = self.run_cli("cat >/dev/null; exit 2", "check", "--user-id", "7")
        self.assertEqual(p.returncode, 2)
        p, _ = self.run_cli("true", "check", "--user-id", "")
        self.assertEqual(p.returncode, 2)
        # a present marker with no readable timestamp: check = unknown (2), never clear
        bad = 'q=$(cat); case "$q" in *claiming*) exit 0;; esac; echo \'"7","","{""requested"":true}","","2020-01-01 00:00:00.000 UTC"\''
        p, _ = self.run_cli(bad, "check", "--user-id", "7")
        self.assertEqual(p.returncode, 2, p.stdout + p.stderr)
        # by email: every matching account is checked; none -> clear; a bad email -> unknown
        by_email = ('q=$(cat); case "$q" in *public.users*) echo \'"7"\'; exit 0;; *claiming*) exit 0;; esac; '
                    + f'echo \'"7","","","","{today} 01:00:00.000"\'')
        p, _ = self.run_cli(by_email, "check", "--email", "jane@example.com")
        self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
        p, _ = self.run_cli("cat >/dev/null; true", "check", "--email", "jane@example.com")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        p, _ = self.run_cli("cat >/dev/null; true", "check", "--email", "x'@y.com")
        self.assertEqual(p.returncode, 2)

    def test_batch_writes_only_held_ids_and_fails_closed(self):
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        body = ('grep -q claiming && exit 0; '
                f'echo \'"7","","","","{today} 01:00:00.000"\'; echo \'"8","","","","2020-01-01 00:00:00.000"\'')
        t = tempfile.mkdtemp()
        users = os.path.join(t, "u.txt"); open(users, "w").write("7\n8\n")
        out = os.path.join(t, "held.txt")
        p, _ = self.run_cli(body, "batch", "--users-file", users, "--out", out)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(open(out).read(), "7\n")
        # batch: an unknown-marker user is HELD (counted), never cleared
        bad = ('q=$(cat); case "$q" in *claiming*) exit 0;; esac; '
               'echo \'"7","","{""requested"":true}","","2020-01-01 00:00:00.000 UTC"\'; '
               'echo \'"8","","","","2020-01-01 00:00:00.000 UTC"\'')
        p, _ = self.run_cli(bad, "batch", "--users-file", users, "--out", out)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(open(out).read(), "7\n")
        self.assertEqual(json.loads(p.stdout)["held_unknown_marker"], 1)
        p, _ = self.run_cli("cat >/dev/null; exit 2", "batch", "--users-file", users, "--out", out + "2")
        self.assertEqual(p.returncode, 2)
        self.assertFalse(os.path.exists(out + "2"))


if __name__ == "__main__":
    unittest.main()
