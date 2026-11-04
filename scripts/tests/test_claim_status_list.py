"""claim_status_list (the durable claim-status wave's list builder) and credit-review.py claim-status-daily.

WS2 lead (firstmate 042): the approved status note ("nothing else is needed from you right now") goes only
to holds and organizations WITH a bindable page; band B/C persons, no-bindable-page claimants, unreadable or
gone profiles are excluded and counted."""
from __future__ import annotations

import credit_test_env  # noqa: F401,E402 - first: test logs never reach the production run.log
import importlib.util
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import claim_status_list as csl  # noqa: E402

NOW = datetime(2026, 10, 28, 1, 15, tzinfo=timezone.utc)
SPOTIFY = "4Z8W4fKeB5YxbusRsdQVPb"


class FakeTrino:
    """Answers the builder's queries from small in-memory tables, keyed by a distinctive substring."""

    def __init__(self, *, pending, claims=(), credit=(), seats=(), recent=(), paid=(), competing_paid=(), past_due=(), no_renew=()):
        self.pending, self.claims, self.credit, self.seats = list(pending), list(claims), list(credit), list(seats)
        self.recent, self.paid, self.competing_paid = list(recent), list(paid), list(competing_paid)
        self.past_due, self.no_renew = list(past_due), list(no_renew)
        self.sql: list[str] = []

    def __call__(self, sql: str):
        self.sql.append(sql)
        if "status = 'pending'" in sql and "FROM postgresql_core.public.claiming" in sql and "profileid IN" not in sql:
            return [tuple(map(str, r)) for r in self.pending]
        if "subscriptions" in sql:
            if "'past_due'" in sql:   # the paying-workspace read: (team, status, autoRenew)
                return ([(t, "active", "false" if t in self.no_renew else "true") for t in self.paid]
                        + [(t, "past_due", "") for t in self.past_due])
            return [(t, "active") for t in self.competing_paid]
        if "status IN ('pending','processed','reverted')" in sql:
            return [tuple(map(str, r)) for r in self.claims]
        if "credit_requests" in sql:
            return [tuple(map(str, r)) for r in self.credit]
        if "roster_seats" in sql:
            return [tuple(map(str, r)) for r in self.seats]
        if "createdat >=" in sql:
            return [tuple(map(str, r)) for r in self.recent]
        raise AssertionError(f"unexpected query: {sql[:120]}")


def prof(pid, *, name="Big Star", sub="artist", website=None, spotify=None, instagram=None, twitter=None, tiktok=None,
         deleted=False):
    raws = [{"source": "spotify", "id": spotify}] if spotify else []
    return {"id": pid, "name": name, "subType": sub, "deleted": deleted, "merged": False, "rawProfiles": raws,
            "links": {"website": website, "instagram": instagram, "twitter": twitter, "tiktok": tiktok, "youtube": None}}


# pending rows: (id, user_id, team_id, profile_id, profile_type, created_at)
def pend(cid, uid, pid, ptype="artist", team="t-free"):
    return (cid, uid, team, pid, ptype, "2026-10-20 10:00:00.000 UTC")


class BoundSurfaceTests(unittest.TestCase):
    """The core claimProofChallenge.surfacesFor rules, bound side, ported 1:1."""

    def test_each_catalog_surface_counts_and_junk_does_not(self):
        self.assertTrue(csl.bound_surfaces(prof("p", spotify=SPOTIFY)))
        self.assertTrue(csl.bound_surfaces(prof("p", website="https://www.artist-site.com/about")))
        self.assertTrue(csl.bound_surfaces(prof("p", instagram="https://instagram.com/real_artist/")))
        self.assertEqual(csl.bound_surfaces(prof("p", spotify="belikada_music")), [])         # handle-shaped raw: not readable
        self.assertEqual(csl.bound_surfaces(prof("p", instagram="https://www.instagram.com/p/C1xYz/")), [])  # a post names no account
        self.assertEqual(csl.bound_surfaces(prof("p", instagram="https://evil.example/instagram.com/x")), [])
        self.assertEqual(csl.bound_surfaces(prof("p")), [])

    def test_parsers_anchor_on_the_host(self):
        self.assertEqual(csl.x_handle("https://x.com/someone"), "someone")
        self.assertIsNone(csl.x_handle("https://evil.example/x.com/@victim"))
        self.assertEqual(csl.tiktok_handle("https://www.tiktok.com/@a.b."), "a.b")
        self.assertEqual(csl.youtube_channel_id("https://youtube.com/channel/UC1234567890"), "UC1234567890")
        self.assertEqual(csl.registrable_host("www.Site.COM."), "site.com")
        self.assertIsNone(csl.registrable_host("ftp://site.com"))


class BuildTests(unittest.TestCase):
    def build(self, trino, profiles):
        return csl.build(query=trino, read_profile=lambda pid: profiles.get(pid), now=NOW)

    def test_only_holds_and_organizations_with_a_bindable_page_are_listed(self):
        trino = FakeTrino(
            pending=[pend(1, 11, "p-h3"), pend(2, 12, "p-org", "organization", team="t-paid"), pend(3, 13, "p-bc"),
                     pend(4, 14, "p-h9"), pend(5, 15, "p-org-nopage", "organization"), pend(6, 16, "p-h3-nopage"),
                     pend(7, 17, "p-gone", "organization"), pend(8, 18, "p-unread", "organization")],
            # another user's processed claim on p-h3 / p-h3-nopage (another workspace)
            claims=[(1, 11, "t-free", "p-h3", "pending"), (90, 99, "t-other", "p-h3", "processed"),
                    (6, 16, "t-free", "p-h3-nopage", "pending"), (91, 98, "t-x", "p-h3-nopage", "pending")],
            # user 14 filed 4 other claims in the last 7 days -> H9
            recent=[(4, 14, "p-h9", "artist")] + [(40 + i, 14, f"q{i}", "artist") for i in range(4)],
            paid=["t-paid"])
        profiles = {"p-h3": prof("p-h3", spotify=SPOTIFY), "p-org": prof("p-org", sub="organization", website="label.com"),
                    "p-bc": prof("p-bc", spotify=SPOTIFY), "p-h9": prof("p-h9", instagram="instagram.com/h9artist"),
                    "p-org-nopage": prof("p-org-nopage", sub="organization"), "p-h3-nopage": prof("p-h3-nopage"),
                    "p-gone": prof("p-gone", sub="organization", website="x.com", deleted=True)}
        doc = self.build(trino, profiles)
        listed = {c["claim_id"]: c for c in doc["claims"]}
        self.assertEqual(sorted(listed), [1, 2, 4])
        self.assertEqual(listed[1]["reason"], "hold:H3")
        self.assertEqual(listed[4]["reason"], "hold:H9")
        self.assertEqual(listed[2]["reason"], "organization")
        self.assertTrue(listed[2]["paid"])
        self.assertFalse(listed[1]["paid"])
        self.assertTrue(all(c["audience"] == "status" and c["profile_name"] and c["profile_url"].endswith(c["profile_id"])
                            for c in doc["claims"]))
        self.assertEqual(doc["counts"], {"pending": 8, "hold": 2, "organization": 1, "bc_person_excluded": 1,
                                         "no_bindable_page": 2, "profile_unreadable": 1, "profile_gone": 1,
                                         "listed": 3, "listed_paid": 1, "listed_at_risk": 0})

    def test_an_outage_fails_early_in_the_loop_not_after_every_profile_is_read(self):
        """QA on #1406 @4493585c: the guard ran only after the whole loop, so a stalled catalog (45 s/read over ~1,473
        pending) kept the daily job "running" for ~18 h before it could say CATALOG_UNREADABLE. Once the systemic
        share is met the verdict cannot change, only be delayed - the build must fail there and then."""
        pids = [f"p-{i}" for i in range(300)]
        trino = FakeTrino(pending=[pend(i + 1, 100 + i, pid, "organization", team="t") for i, pid in enumerate(pids)])
        reads = []

        def never_reads(pid):
            reads.append(pid)
            return None
        with self.assertRaises(csl.CatalogUnreadable):
            csl.build(query=trino, read_profile=never_reads, now=NOW)
        # the earliest the 50 % verdict can be certain is 150 of 300: the point is that it stops THERE, not at 300,
        # and that the ratio check is cheap (every CATASTROPHE_CHECK_EVERY reads) while the TIME budget is per read
        self.assertEqual(len(reads), 150)

    def test_a_build_that_outspends_its_budget_fails_loudly_with_no_list(self):
        """A stalled catalog is not a slow queue: past CLAIM_BUILD_BUDGET_S the run is FAILED, which is a different
        answer from an empty list (and from CatalogUnreadable, which is about unreadable share)."""
        trino = FakeTrino(pending=[pend(1, 11, "p-org", "organization"), pend(2, 12, "p-org2", "organization")])
        profiles = {"p-org": prof("p-org", sub="organization", website="label.com"), "p-org2": prof("p-org2", sub="organization")}
        with mock.patch.object(csl, "CLAIM_BUILD_BUDGET_S", -1):     # any elapsed time is over budget
            with self.assertRaises(csl.BuildTooSlow) as ctx:
                csl.build(query=trino, read_profile=lambda pid: profiles.get(pid), now=NOW)
        self.assertIn("outspent", str(ctx.exception))

    def test_a_catalog_outage_fails_the_build_instead_of_returning_an_empty_list(self):
        """r3 on #1406: every pending profile unreadable is an outage, not an empty queue - build() must raise,
        not hand the wave a list that makes it exit 0 having told nobody."""
        trino = FakeTrino(pending=[pend(2, 12, "p-org", "organization"), pend(3, 13, "p-org2", "organization")])
        with self.assertRaises(csl.CatalogUnreadable) as ctx:
            self.build(trino, {})                       # catalog unreadable for every profile
        self.assertEqual(ctx.exception.counts["pending"], 2)
        self.assertEqual(ctx.exception.counts["profile_unreadable"], 2)
        self.assertIn("CATALOG_UNREADABLE", str(ctx.exception))

    def test_half_the_pending_claims_unreadable_is_already_systemic(self):
        trino = FakeTrino(pending=[pend(2, 12, "p-org", "organization"), pend(3, 13, "p-org2", "organization")])
        with self.assertRaises(csl.CatalogUnreadable):
            self.build(trino, {"p-org": prof("p-org", sub="organization", website="label.com")})

    def test_a_minority_of_unreadable_profiles_stays_a_per_claim_unknown(self):
        """One unreadable profile among many is a transient read failure: it is excluded per claim (UNKNOWN
        never sends) and the rest of the wave still runs."""
        trino = FakeTrino(pending=[pend(2, 12, "p-org", "organization"), pend(3, 13, "p-org2", "organization"),
                                   pend(4, 14, "p-org3", "organization")])
        doc = self.build(trino, {"p-org": None, "p-org2": prof("p-org2", sub="organization", website="a.com"),
                                 "p-org3": prof("p-org3", sub="organization", website="b.com")})
        self.assertEqual(sorted(c["claim_id"] for c in doc["claims"]), [3, 4])
        self.assertEqual(doc["counts"]["profile_unreadable"], 1)

    def test_an_empty_queue_is_not_an_outage(self):
        doc = self.build(FakeTrino(pending=[]), {})
        self.assertEqual(doc["claims"], [])
        self.assertEqual(doc["counts"]["profile_unreadable"], 0)

    def test_band_bc_persons_are_never_listed(self):
        trino = FakeTrino(pending=[pend(3, 13, "p-bc")])
        doc = self.build(trino, {"p-bc": prof("p-bc", spotify=SPOTIFY)})
        self.assertEqual(doc["claims"], [])
        self.assertEqual(doc["counts"]["bc_person_excluded"], 1)

    def test_a_claim_typed_artist_on_a_catalog_organization_is_an_organization(self):
        """QA on #1406 @68159ae4: the catalog subType decides too, so the catalog is read before the B/C exclusion."""
        trino = FakeTrino(pending=[pend(9, 19, "p-cat-org", "artist")])
        doc = self.build(trino, {"p-cat-org": prof("p-cat-org", sub="organization", website="label.com")})
        self.assertEqual([(c["claim_id"], c["reason"]) for c in doc["claims"]], [(9, "organization")])

    def test_x_or_tiktok_only_is_no_bindable_page(self):
        """QA on #1406 @68159ae4: X / TikTok posts cannot prove a claim (core #10762), so they are not a page."""
        trino = FakeTrino(pending=[pend(2, 12, "p-x", "organization"), pend(3, 13, "p-tt", "organization")])
        doc = self.build(trino, {"p-x": prof("p-x", sub="organization", twitter="https://x.com/label"),
                                 "p-tt": prof("p-tt", sub="organization", tiktok="https://www.tiktok.com/@label")})
        self.assertEqual(doc["claims"], [])
        self.assertEqual(doc["counts"]["no_bindable_page"], 2)
        self.assertEqual(csl.bound_surfaces(prof("p", twitter="https://x.com/a", tiktok="https://tiktok.com/@a")), [])

    def test_competing_credit_request_seat_or_paying_competitor_is_H3_the_claimant_themself_is_not(self):
        trino = FakeTrino(
            pending=[pend(1, 11, "p1"), pend(2, 12, "p2"), pend(3, 13, "p3"), pend(4, 14, "p4")],
            claims=[(1, 11, "t-free", "p1", "pending"), (70, 11, "t-free", "p1", "reverted"),   # own earlier claim: not competing
                    (3, 13, "t-free", "p3", "pending"), (80, 77, "t-paying", "p3", "pending")],
            credit=[("p2", 55)], seats=[("p4", "t-seat", 66), ("p1", "t-free", 99)],                # p1's seat is the claimant's own workspace
            competing_paid=["t-paying"])
        profiles = {p: prof(p, spotify=SPOTIFY) for p in ("p1", "p2", "p3", "p4")}
        doc = self.build(trino, profiles)
        self.assertEqual(sorted(c["claim_id"] for c in doc["claims"]), [2, 3, 4])
        self.assertEqual(doc["counts"]["bc_person_excluded"], 1)

    def test_velocity_counts_unrelated_artists_too(self):
        trino = FakeTrino(pending=[pend(1, 11, "p1")],
                          recent=[(1, 11, "p1", "artist"), (5, 11, "q1", "artist"), (6, 11, "q2", "professional")])
        doc = self.build(trino, {"p1": prof("p1", spotify=SPOTIFY)})
        self.assertEqual([c["reason"] for c in doc["claims"]], ["hold:H9"])   # 2 unrelated artists > 1

    def test_the_list_is_what_run_status_reads(self):
        from credit_review import claim_proof_ask
        trino = FakeTrino(pending=[pend(2, 12, "p-org", "organization")])
        doc = self.build(trino, {"p-org": prof("p-org", sub="organization", website="label.com")})
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "l.json"
            p.write_text(json.dumps(doc), encoding="utf-8")
            claims, why = claim_proof_ask.load_list(str(p), now=NOW, require_daily_check=False)
        self.assertEqual(why, "")
        self.assertTrue(all(claim_proof_ask.is_status_audience(c) for c in claims))


def _cli():
    spec = importlib.util.spec_from_file_location("credit_review_cli_csd", ROOT / "scripts" / "credit-review.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class DailyCommandTests(unittest.TestCase):
    def setUp(self):
        self.cli = _cli()
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def args(self, **kw):
        import argparse
        return argparse.Namespace(mode=kw.get("mode", "dry-run"), segments=kw.get("segments", ["paid", "free"]),
                                  max_users=kw.get("max_users", 400), list=str(self.dir / "list.json"))

    def test_either_kill_switch_stops_before_anything_is_built(self):
        for name in ("CLAIM_STATUS_DAILY_KILL_SWITCH", "CREDIT_OPS_NOTES_KILL_SWITCH"):
            ks = self.dir / f"{name}.disabled"
            ks.touch()
            with mock.patch.object(self.cli, name, ks), \
                    mock.patch.object(self.cli.claim_status_list, "build", side_effect=AssertionError("built")):
                self.assertEqual(self.cli.cmd_claim_status_daily(self.args()), 0)
            ks.unlink()

    def test_a_list_that_cannot_be_built_sends_nothing_and_fails(self):
        with mock.patch.object(self.cli, "CLAIM_STATUS_DAILY_KILL_SWITCH", self.dir / "no"), \
                mock.patch.object(self.cli, "CREDIT_OPS_NOTES_KILL_SWITCH", self.dir / "no2"), \
                mock.patch.object(self.cli.claim_status_list, "build", side_effect=RuntimeError("trino down")), \
                mock.patch.object(self.cli.claim_proof_ask, "run_status", side_effect=AssertionError("sent")):
            self.assertEqual(self.cli.cmd_claim_status_daily(self.args()), 1)

    def test_a_catalog_outage_exits_non_zero_with_catalog_unreadable_and_sends_nothing(self):
        """The finding was the COMMAND's exit code: run_status was handed an empty list and returned 0."""
        import io, contextlib
        from credit_review.claim_status_list import CatalogUnreadable
        out = io.StringIO()
        with mock.patch.object(self.cli, "CLAIM_STATUS_DAILY_KILL_SWITCH", self.dir / "no"), \
                mock.patch.object(self.cli, "CREDIT_OPS_NOTES_KILL_SWITCH", self.dir / "no2"), \
                mock.patch.object(self.cli.claim_status_list, "build",
                                  side_effect=CatalogUnreadable({"pending": 10, "profile_unreadable": 9})), \
                mock.patch.object(self.cli.claim_proof_ask, "run_status", side_effect=AssertionError("sent")), \
                contextlib.redirect_stdout(out):
            rc = self.cli.cmd_claim_status_daily(self.args())
        self.assertEqual(rc, 3)
        self.assertIn("CATALOG_UNREADABLE", out.getvalue())
        self.assertIn("9 of 10", out.getvalue())
        self.assertFalse((self.dir / "list.json").exists())   # nothing was even written to the list path

    def test_the_run_log_line_is_labelled_AUDIT_so_counts_are_never_read_as_sends(self):
        """QA on #1406 @396a700a: with the cron on MODE=dry-run the wave delivers nothing, and the one line an
        operator greps must SAY so - 'claim-status-daily AUDIT {...}', never a line that reads like a delivery."""
        from credit_review.claim_proof_ask import ClaimReport
        logged = []
        doc = {"generated_at": "2026-10-28T01:15:00Z", "counts": {"listed": 0}, "claims": []}
        with mock.patch.object(self.cli, "CLAIM_STATUS_DAILY_KILL_SWITCH", self.dir / "no"), \
                mock.patch.object(self.cli, "CREDIT_OPS_NOTES_KILL_SWITCH", self.dir / "no2"), \
                mock.patch.object(self.cli.claim_status_list, "build", return_value=doc), \
                mock.patch.object(self.cli.claim_proof_ask, "run_status", return_value=ClaimReport()), \
                mock.patch.object(self.cli, "log", side_effect=logged.append):
            self.assertEqual(self.cli.cmd_claim_status_daily(self.args()), 0)
        self.assertTrue(logged)
        line = [l for l in logged if l.startswith("claim-status-daily")][-1]
        self.assertTrue(line.startswith("claim-status-daily AUDIT {"), line)
        self.assertEqual(json.loads(line.split(" AUDIT ", 1)[1])["mode"], "dry-run")

    def test_a_dry_run_logs_the_would_send_count_not_only_sent(self):
        """QA on #1406 @4493585c: in a dry-run the gate validates the note and accepts the recipient, but sent_notes
        stays 0 - so the audit's headline number (what WOULD go out) was logged as "sent: 0" every night."""
        from credit_review.claim_proof_ask import ClaimReport
        logged = []
        doc = {"generated_at": "2026-10-28T01:15:00Z", "counts": {"listed": 9}, "claims": []}
        with mock.patch.object(self.cli, "CLAIM_STATUS_DAILY_KILL_SWITCH", self.dir / "no"), \
                mock.patch.object(self.cli, "CREDIT_OPS_NOTES_KILL_SWITCH", self.dir / "no2"), \
                mock.patch.object(self.cli.claim_status_list, "build", return_value=doc), \
                mock.patch.object(self.cli.claim_proof_ask, "run_status",
                                  return_value=ClaimReport(validated=7, recipient_ok=2)), \
                mock.patch.object(self.cli, "log", side_effect=logged.append):
            self.assertEqual(self.cli.cmd_claim_status_daily(self.args()), 0)
        line = json.loads([l for l in logged if l.startswith("claim-status-daily AUDIT")][-1].split(" AUDIT ", 1)[1])
        self.assertEqual((line["mode"], line["segments"]["paid"]["sent"], line["segments"]["paid"]["would_send"]),
                         ("dry-run", 0, 9))

    def test_paid_then_free_and_the_health_guard_stops_the_free_segment(self):
        from credit_review.claim_proof_ask import ClaimReport
        calls = []

        def fake_run_status(**kw):
            calls.append(kw["segment"])
            r = ClaimReport()
            r.sent_notes = 3
            return r
        doc = {"generated_at": "2026-10-28T01:15:00Z", "counts": {"listed": 3}, "claims": []}
        with mock.patch.object(self.cli, "CLAIM_STATUS_DAILY_KILL_SWITCH", self.dir / "no"), \
                mock.patch.object(self.cli, "CREDIT_OPS_NOTES_KILL_SWITCH", self.dir / "no2"), \
                mock.patch.object(self.cli.claim_status_list, "build", return_value=doc), \
                mock.patch.object(self.cli.claim_proof_ask, "run_status", side_effect=fake_run_status), \
                mock.patch.object(self.cli, "_claim_status_health", return_value=(3, '{"verdict":"stop"}')):
            rc = self.cli.cmd_claim_status_daily(self.args(mode="apply"))
        self.assertEqual(calls, ["paid"])          # free never ran after the guard said stop
        self.assertEqual(rc, 1)
        self.assertEqual(json.loads((self.dir / "list.json").read_text())["counts"], {"listed": 3})

    def test_an_unreadable_health_check_is_a_stop_never_a_pass(self):
        self.cli.HEALTH_CHECK = self.dir / "missing-health-check.py"
        rc, _ = self.cli._claim_status_health("2026-10-28T01:15")
        self.assertNotEqual(rc, 0)



class AtRiskOrderTests(unittest.TestCase):
    """Fable [key=pro-at-risk]: paying claimants with a live churn signal (past_due, or autoRenew false) go first.
    Only the order changes, never who is listed."""

    def test_at_risk_is_marked_and_ordered_first_inside_the_paid_segment(self):
        from credit_review import claim_proof_ask
        trino = FakeTrino(pending=[pend(1, 11, "p1", "organization", team="t-paid"),
                                   pend(2, 12, "p2", "organization", team="t-due"),
                                   pend(3, 13, "p3", "organization", team="t-cancel"),
                                   pend(4, 14, "p4", "organization")],
                          paid=["t-paid", "t-cancel"], past_due=["t-due"], no_renew=["t-cancel"])
        doc = csl.build(query=trino, read_profile=lambda pid: prof(pid, sub="organization", website="label.com"), now=NOW)
        by = {c["claim_id"]: c for c in doc["claims"]}
        self.assertEqual([(i, by[i]["paid"], by[i]["at_risk"], by[i]["priority"]) for i in (1, 2, 3, 4)],
                         [(1, True, False, 1), (2, True, True, 0), (3, True, True, 0), (4, False, False, 2)])
        self.assertEqual(doc["counts"]["listed_at_risk"], 2)
        self.assertEqual(len(doc["claims"]), 4)                     # nobody added or dropped by the ordering
        # run_status walks the paid segment at-risk first, then oldest claim
        order = sorted((c for c in doc["claims"] if c["paid"]), key=lambda c: (claim_proof_ask._priority(c), c["claim_id"]))
        self.assertEqual([c["claim_id"] for c in order], [2, 3, 1])

    def test_a_list_without_priority_keeps_the_oldest_claim_first_order(self):
        from credit_review import claim_proof_ask
        rows = [{"claim_id": 9}, {"claim_id": 3, "priority": "junk"}, {"claim_id": 5}]
        self.assertEqual([c["claim_id"] for c in sorted(rows, key=lambda c: (claim_proof_ask._priority(c), c["claim_id"]))], [3, 5, 9])


if __name__ == "__main__":
    unittest.main()
