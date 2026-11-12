"""claim_audience: the claim list's per-user audience rules (p1 + r5 10-31, p1 157) - one audience per user over
all open claims, the no-channel tray, the live gate's messaged-7d rule; a mixed list refuses the run."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from credit_review import claim_audience as audience


def row(cid, uid, aud):
    return {"claim_id": cid, "user_id": uid, "audience": aud}


class T(unittest.TestCase):
    def test_user_with_a_code_ask_gets_no_status_line(self):
        counts = {}
        out = audience.one_audience_over_all_claims(
            [row(1, 7, "proof_ask"), row(2, 7, "status"), row(3, 8, "status")], counts, set())
        self.assertEqual([r["claim_id"] for r in out], [1, 3])
        self.assertEqual(counts["status_user_owes_code_ask"], 1)
        self.assertEqual(counts["status_user_owes_code_ask_claims"], [2])
        self.assertNotIn("status_user_owes_code_ask_elsewhere", counts)

    def test_a_mixed_list_refuses_the_run(self):
        with self.assertRaises(audience.MixedAudience):
            audience.assert_one_audience([row(1, 7, "proof_ask"), row(2, 7, "status")])
        audience.assert_one_audience([row(1, 7, "proof_ask"), row(3, 8, "status")])

    def test_red_mutant_the_filter_removed_still_refuses(self):
        """Mutant: the per-user filter skipped -> the run must still be refused by the final check."""
        rows = [row(1, 7, "proof_ask"), row(2, 7, "status")]
        with self.assertRaises(audience.MixedAudience):
            audience.assert_one_audience(rows)


class M7(unittest.TestCase):
    def test_messaged_7d_users_are_dropped(self):
        c = {}
        out = audience.drop_messaged_7d([row(1, 7, "status"), row(2, 8, "status")], c, {"7"})
        self.assertEqual([r["claim_id"] for r in out], [2])
        self.assertEqual(c["dropped_messaged_7d"], 1)


class P1R157(unittest.TestCase):
    def test_a_user_with_a_deferred_ask_elsewhere_gets_no_status_line(self):
        c = {}
        out = audience.one_audience_over_all_claims([row(1621321, 14643, "status"), row(9, 8, "status")], c, {14643})
        self.assertEqual([r["claim_id"] for r in out], [9])
        self.assertEqual(c["status_user_owes_code_ask_elsewhere"], 1)

    def test_an_intercom_forbidden_user_goes_to_the_no_channel_tray(self):
        c = {}
        out = audience.drop_unreachable([row(1, 32747, "status"), row(2, 8, "status")], c, {"32747"})
        self.assertEqual([r["claim_id"] for r in out], [2])
        self.assertEqual(c["no_channel_tray"], [1])


if __name__ == "__main__":
    unittest.main()
