"""Tests for scripts/lib/robot_mail.py — the shared demote-only robot-mail predicate (MUS-18980).

Fixtures are robot boilerplate only: no real customer name, address or message text.
Stdlib unittest, no network.
"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
from lib import robot_mail  # noqa: E402


class BodyMarkers(unittest.TestCase):
    def test_each_body_marker_demotes_regardless_of_sender(self):
        for marker in robot_mail.ROBOT_BODY_MARKERS:
            r = robot_mail.is_robot_mail("Re: ticket", f"Hello. {marker.upper()} here.",
                                         "person@gmail.com")
            self.assertEqual(r, (True, "robot:auto-reply-body"), marker)

    def test_zendesk_footer_needs_both_halves(self):
        both = "Thanks.\n  Delivered by Zendesk \n Type your reply above this line"
        self.assertEqual(robot_mail.is_robot_mail("s", both, "a@b.co"),
                         (True, "robot:auto-reply-body"))
        self.assertEqual(robot_mail.is_robot_mail("s", "sent: delivered by zendesk", "a@b.co"),
                         (False, None))
        self.assertEqual(robot_mail.is_robot_mail("s", "type your reply above this line", "a@b.co"),
                         (False, None))

    def test_plain_human_mail_is_not_robot(self):
        self.assertEqual(robot_mail.is_robot_mail("DMCA takedown", "remove my track", "a@b.co"),
                         (False, None))

    def test_none_inputs_do_not_raise(self):
        self.assertEqual(robot_mail.is_robot_mail(None, None, None), (False, None))


class DsnNeedsRobotSender(unittest.TestCase):
    def test_dsn_subject_with_robot_sender_demotes(self):
        for sender in ("MAILER-DAEMON@x.org", "postmaster@x.org", "no-reply@x.org",
                       "noreply@x.org", "do-not-reply@x.org"):
            for subj in ("Delivery Status Notification (Failure)", "Undeliverable: hi",
                         "Mail delivery failed: returning message"):
                self.assertEqual(robot_mail.is_robot_mail(subj, "body", sender),
                                 (True, "robot:dsn+robot-sender"), (sender, subj))

    def test_dsn_subject_from_a_human_sender_is_not_demoted(self):
        # 54 of 5,691 conversations in 90 d: all human forwards. They must still page.
        self.assertEqual(robot_mail.is_robot_mail("Fwd: Undeliverable: claim", "x", "jo@gmail.com"),
                         (False, None))

    def test_robot_sender_without_dsn_subject_is_not_demoted(self):
        self.assertEqual(robot_mail.is_robot_mail("Copyright claim", "x", "noreply@x.org"),
                         (False, None))


if __name__ == "__main__":
    unittest.main()
