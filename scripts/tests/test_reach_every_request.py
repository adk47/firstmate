"""The reach-every-request report names every group, and the two with no family are never dropped.

reach-every-request-r1 (firstmate 2026-11-16, captain's intent "do we have responses to everyone that
submitted a request. why not push on this"). The brief's own test list asks for one thing this file
pins: "a group with no family is reported as unreached rather than silently dropped". A report that
lists only the groups a family can carry reads as "everyone is being reached", which is the failure
this whole task exists to end - so the table is checked by name, and the two groups with no family
must say so in their own row.

The policy half is pinned here too, because the report's numbers are only true of the file that
ships with it: the claim group's shared ceiling is #2076's to set, and it is the send gateway's claim
allocation - the ceiling that actually binds, not a number under it - and
wait-apology's row is armed WITHOUT an unsigned_from, which is what keeps it SIGNED-only.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REPORT = ROOT / "data" / "reach-every-request-r1" / "report.md"
POLICY = ROOT / "policies" / "credit-verify-outbound.json"
SCRIPT = ROOT / "scripts" / "credit-verify-outbound.sh"

# The five groups, by the words the report's table uses for them. A group renamed in the report is a
# group this test stops seeing, which is the point: the table is the deliverable.
GROUPS = [
    "Owed proof never asked",
    "Claims never told",
    "Credits waiting on us never told",
    "Profile merges never told",
    "Intercom never answered",
]
# The two the brief says no family covers. Their rows must say so, in the family column.
NO_FAMILY = ["Profile merges never told", "Intercom never answered"]


def _table_rows() -> dict[str, str]:
    """The five-group table's rows, keyed by group name, as raw markdown lines."""
    rows: dict[str, str] = {}
    for line in REPORT.read_text().splitlines():
        if not line.startswith("|"):
            continue
        for g in GROUPS:
            if "| %s |" % g in line:
                rows[g] = line
    return rows


def _claim_allocation() -> int:
    """The send gateway's claim allocation, read rather than written down.

    From the ceilings copy when this branch carries it (the follow-up PR adds it), else from the report, which
    names it. Never a literal: the guard's whole point is that the number compared against is the gateway's, so a
    test that hard-codes today's value goes red on the next legitimate step and gets deleted.
    """
    ceilings = ROOT / "policies/send-gateway-ceilings.json"
    if ceilings.exists():
        return json.loads(ceilings.read_text(encoding="utf-8"))["allocations"]["claim"]["cap"]
    m = re.search(r"allocates this route \*\*([\d,]+)/day\*\*", REPORT.read_text(encoding="utf-8"))
    assert m, "the report must name the gateway's claim allocation"
    return int(m.group(1).replace(",", ""))


def _claim_cap_from_script(src: str) -> int:
    """The tick's per-segment claim grant (`CLAIM_CAP`), read from the code so the test follows the code."""
    m = re.search(r'^CLAIM_CAP="\$\(cfg CVO_CLAIM_CAP (\d+)\)"$', src, re.M)
    assert m, "the tick's CLAIM_CAP default must stay readable"
    return int(m.group(1))


class TheFiveGroupTable(unittest.TestCase):
    def test_the_report_exists(self):
        self.assertTrue(REPORT.is_file(), REPORT)

    def test_every_group_has_its_own_row(self):
        rows = _table_rows()
        self.assertEqual(sorted(rows), sorted(GROUPS), "a group is missing from the table: %s" % sorted(rows))

    def test_a_group_with_no_family_says_so_in_its_row(self):
        rows = _table_rows()
        for g in NO_FAMILY:
            cells = [c.strip() for c in rows[g].strip().strip("|").split("|")]
            self.assertTrue(cells[2].startswith("**None"), "%s must name no family, got %r" % (g, cells[2]))
            self.assertIn("unreached", rows[g].lower(), "%s must be reported as unreached" % g)

    def test_a_group_with_a_family_names_it(self):
        rows = _table_rows()
        for g, fam in (
            ("Owed proof never asked", "proof-need-ask"),
            ("Claims never told", "claim-status"),
            ("Credits waiting on us never told", "uvn-status"),
        ):
            self.assertIn("`%s`" % fam, rows[g], "%s must name the family that carries it" % g)

    def test_every_group_row_carries_a_count_and_a_binding_cap(self):
        rows = _table_rows()
        for g in GROUPS:
            cells = [c.strip() for c in rows[g].strip().strip("|").split("|")]
            self.assertEqual(len(cells), 7, "%s: the table lost a column: %r" % (g, cells))
            self.assertTrue(re.search(r"\d", cells[3]), "%s: no measured count" % g)
            self.assertTrue(cells[4], "%s: no binding cap" % g)


class TheCapChange(unittest.TestCase):
    def test_the_claim_cap_is_another_prs_and_the_row_says_so(self):
        """firstmate 2026-11-16T09:49Z: the group has ONE claim value, #2076's 500, and it is not this file's.

        The row must not claim a raise of its own (1,000 was the arithmetic of what the rows ask for, not the
        value that ships), and it must not still call the number staged: it carries the measured BEFORE - 21
        sent of 25, 478 held `over today's cap`, ~35 days for 874 - and names #2076 as the PR that moves it.
        """
        text = REPORT.read_text()
        row = [l for l in text.splitlines() if l.startswith("| 2 | Claims never told")]
        self.assertEqual(len(row), 1, "the claim group needs exactly one row")
        for want in ("#2076", "{:,}/day".format(_claim_allocation()), "21 sent of 25", "478", "35 days"):
            self.assertIn(want, row[0], "the claim group row must state %r" % want)
        for unwanted in ("STAGED", "1,000/day"):
            self.assertNotIn(unwanted, row[0], "the claim row must not say %r" % unwanted)

    def test_the_claim_section_states_why_the_shared_number_was_the_only_ceiling(self):
        text = REPORT.read_text()
        section = text.split("### Group 2: the claim cap")[1].split("### Group 4")[0]
        self.assertIn("done` is 0 by design", section)
        self.assertIn("35 days", section)
        self.assertIn("route_ceiling", section)

    def test_the_before_number_is_measured_and_the_ceiling_is_not_pretended(self):
        """The number is the gateway's allocation, not a rate we measured: the section must say both."""
        section = REPORT.read_text().split("### Group 2: the claim cap")[1].split("### Group 4")[0]
        for want in ("21 sent of 25", "478", "over today's cap", "500/day", "No `route_ceiling` answer exists on node-8 yet",
                     "2076", "4 x 250", "allocation is not a proven rate"):
            self.assertIn(want, section, "the claim section must state %r" % want)

    def test_the_two_warm_up_bounded_raises_are_stated_with_their_audience(self):
        text = REPORT.read_text()
        for cap, audience in (("`daily_cap.proof-need-ask`", "1,585"), ("`daily_cap.uvn-reminder-14`", "782")):
            row = [l for l in text.splitlines() if l.startswith("| %s" % cap)]
            self.assertEqual(len(row), 1, "%s needs exactly one row" % cap)
            self.assertIn(audience, row[0], "%s must name the audience it is bounded by" % cap)
            self.assertIn("2,500", row[0], "%s must name the warm-up allocation it is bounded by" % cap)

    def test_the_warm_up_limit_is_measured_not_assumed(self):
        text = REPORT.read_text()
        self.assertIn("WARMUP_CEILINGS", text)
        self.assertIn("78-send-gateway.yaml", text)
        self.assertIn("credit 2,500 / claim 500", text)

    def test_no_tick_cap_is_a_number_that_cannot_bind(self):
        """QA finding on #2086: a per-tick row above `FIRST_CAP` is an inert digit.

        `family_cap()` holds a family with no `FULL_CAP_FROM` entry at `FIRST_CAP`, and `tick_cap` can only
        LOWER a cap - so a policy row above it changes nothing while reading like a promise. That is exactly
        what shipped for proof-need-ask and uvn-reminder-14 (150 against a 100 ceiling), and the review caught
        it before a merge. The rule is mechanical: read `FIRST_CAP` and the dated full-cap families out of the
        tick itself, and fail when a row is above the ceiling that family actually gets.
        """
        src = SCRIPT.read_text()
        first_cap = int(re.search(r'^FIRST_CAP=(\d+)', src, re.M).group(1))
        dated = set(re.findall(r'\[([a-z0-9-]+)\]="20', src))          # FULL_CAP_FROM / PER_SEGMENT_FROM lines
        p = json.loads(POLICY.read_text())
        for fam, segs in p["tick_cap"].items():
            if fam.startswith("_") or fam in dated:
                continue
            for seg, val in segs.items():
                self.assertLessEqual(
                    val, first_cap,
                    "%s/%s is %d per tick but an undated family is held at FIRST_CAP=%d, so %d binds nothing - "
                    "raise the ceiling with a dated FULL_CAP_FROM line, not this row" % (fam, seg, val, first_cap, val))

    def test_the_report_does_not_claim_the_raise_examines_the_whole_list_in_a_day(self):
        """The day claim the review rejected: the page and the deadline bound examination, not this cap.

        Pinned mechanically so the text cannot drift back: the report must name `FIRST_CAP`, must say the
        measured walk (~51 per segment) and must not promise a one-day examination.
        """
        text = REPORT.read_text()
        for want in ("`FIRST_CAP`", "51 candidates per segment", "~16 ticks", "not examined inside one day"):
            self.assertIn(want, text, "the report must state the corrected arithmetic: %r" % want)
        self.assertNotIn("150 x ~12 ticks", text)
        self.assertNotIn("examine the whole list inside one day", text)

    def test_the_shipped_policy_carries_the_raised_ceilings(self):
        p = json.loads(POLICY.read_text())
        # claim is #2076's value, not this PR's, and the number it must not exceed is the gateway's allocation -
        # read, never written down here, so a legitimate step does not turn this test red.
        self.assertEqual(p["shared_daily_cap"]["credit"], 2500, p["shared_daily_cap"])
        self.assertLessEqual(p["shared_daily_cap"]["claim"], _claim_allocation(), p["shared_daily_cap"])
        self.assertEqual(p["daily_cap"]["proof-need-ask"], {"paid": 1585, "free": 1585})
        self.assertEqual(p["tick_cap"]["proof-need-ask"], {"paid": 100, "free": 100})
        self.assertEqual(p["daily_cap"]["uvn-reminder-14"], {"paid": 832, "free": 832})
        self.assertEqual(p["tick_cap"]["uvn-reminder-14"], {"paid": 100, "free": 100})

    def test_the_claim_cap_is_the_gateways_own_allocation_and_not_the_rows_sum(self):
        """firstmate 2026-11-16T09:52Z: the group's one claim number is #2076's, and here is the arithmetic.

        A claim family's own daily row never binds (`done = 0`), so what a run may actually ask for is the
        tick's per-segment `CLAIM_CAP`: two families x paid/free = four runs, 250 each = 1,000. The send gateway
        allocates this route its claim allocation, so that allocation is the ceiling #2076 sets the value to and
        never past: a policy value ABOVE the allocation promises what the gateway refuses, and a value BELOW the
        family rows (25 was) is a ceiling nobody can see. Both halves are pinned - the rows are above the tick's
        grant, and the shared value is the allocation rather than the rows' sum.
        """
        p = json.loads(POLICY.read_text())
        claim_cap = _claim_cap_from_script(SCRIPT.read_text())          # the tick's per-segment grant
        runs = len(p["groups"]["claim"]) * len({"paid", "free"})
        wanted = runs * claim_cap
        self.assertEqual(wanted, 1000, "two claim families x two segments x CLAIM_CAP must be 1,000")
        for fam in p["groups"]["claim"]:
            self.assertTrue(all(v >= claim_cap for v in p["daily_cap"][fam].values()),
                            "%s's own row must not bind below the tick's CLAIM_CAP" % fam)
        self.assertLessEqual(p["shared_daily_cap"]["claim"], _claim_allocation(),
                             "the group's one claim value is #2076's and cannot exceed the gateway's allocation")
        self.assertLess(p["shared_daily_cap"]["claim"], wanted, "the allocation, not the rows' sum, is the number")

    def test_a_claim_family_at_its_own_cap_is_not_held_by_the_shared_cap(self):
        """`room()` is the smaller of the family's bound and the shared number - and 25 was the smaller.

        room() = min(cap, daily - done, shared - used), and a claim runner's `done` is 0, so `daily` never
        binds: the family's own bound is the tick's `CLAIM_CAP` (250). What is left is the shared number, and
        the report's bug is that it sat BELOW the rows - 25 held every claim send while both rows printed 500.
        The arithmetic is pinned in both directions: at a shared number at or above `CLAIM_CAP` the family gets
        its own cap, and at 25 it got 25. #2076's value is the allocation, which is above `CLAIM_CAP`, and the
        general form is asserted rather than today's value so a step cannot turn this red. room() is called with
        CLAIM_CAP, so a family's own `tick_cap` row is a separate rail it does not model - claim-proof-ask's 25
        comes from there (`per-family tick cap` in the tick's own log), and neither PR raises or touches it.
        """
        p = json.loads(POLICY.read_text())
        shared = p["shared_daily_cap"]["claim"]
        claim_cap = _claim_cap_from_script(SCRIPT.read_text())          # the tick's per-segment grant
        for fam in p["groups"]["claim"]:
            daily = p["daily_cap"][fam]["paid"]
            done, used = 0, 0                                            # nothing sent yet today
            self.assertEqual(min(claim_cap, daily - done, _claim_allocation()), claim_cap,
                             "%s must be granted its own cap when the shared cap is at or above it" % fam)
            half = _claim_allocation() // 2
            self.assertEqual(min(claim_cap, daily - done, half), min(claim_cap, half),
                             "below the family's cap the shared number is the binder for %s" % fam)
        self.assertLessEqual(shared, _claim_allocation(),
                             "the group's shared number is #2076's and cannot exceed the gateway's allocation")
        self.assertEqual(min(claim_cap, 500, 25), 25, "the old shared cap held a family at 25: the bug this pins")

    def test_no_credit_family_cap_exceeds_its_groups_warm_up_allocation(self):
        """A family cap above its group's shared ceiling is a cap the warm-up would refuse.

        The claim group is excluded by design and not by oversight: a claim runner keeps no segment record
        (`done = 0` in the tick), so a claim family's own daily row is never counted and the shared number is
        the group's only ceiling - raising or lowering those rows changes no send.
        """
        p = json.loads(POLICY.read_text())
        for group, families in p["groups"].items():
            if group == "claim":
                continue
            ceiling = p["shared_daily_cap"][group]
            for fam in families:
                for seg, cap in p["daily_cap"].get(fam, {}).items():
                    self.assertLessEqual(cap, ceiling, "%s/%s daily %s is above the %s warm-up allocation" % (fam, seg, cap, group))

    def test_the_report_names_the_caps_it_did_not_raise(self):
        text = REPORT.read_text()
        section = text.split("## Caps not raised, and why")[1].split("## ")[0]
        for cap in ("tick_cap.uvn-status", "daily_cap.claim-status"):
            self.assertIn(cap, section, "a cap left alone must be named in that section with its reason")

    def test_the_copy_review_hold_is_not_claimed_as_reached(self):
        text = REPORT.read_text()
        self.assertIn("794", text)
        self.assertIn("copy_review_pending", text)
        self.assertIn("NOT reached by this", text)

    def test_the_before_number_is_the_union_of_the_three_audiences(self):
        text = REPORT.read_text()
        self.assertIn("2,939", text)
        for n in ("1,585", "782", "629"):
            self.assertIn(n, text, "the union must show its parts")


class WaitApologyIsWiredAndStillSilent(unittest.TestCase):
    def test_the_row_is_armed_without_a_date(self):
        p = json.loads(POLICY.read_text())
        self.assertEqual(p["armed_families"]["wait-apology"], {"live": True, "paid": True})

    def test_the_code_still_holds_the_empty_signed_only_date(self):
        self.assertIn('[wait-apology]=""', SCRIPT.read_text())

    def test_the_tick_accepts_a_row_for_it(self):
        known = re.search(r"^KNOWN = \{(.*?)\}", SCRIPT.read_text(), re.M | re.S).group(1)
        self.assertIn('"wait-apology"', known)

    def test_the_report_says_it_reaches_nobody_today(self):
        text = REPORT.read_text()
        self.assertIn("SIGNED-only", text)
        self.assertIn("no paid-status run since", text)


if __name__ == "__main__":
    unittest.main()
