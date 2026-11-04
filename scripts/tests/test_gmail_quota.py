#!/usr/bin/env python3
"""support@ Gmail quota guard (firstmate 10-31): shared lock, host-wide Retry-After backoff, hourly budget, and
file-recent stopping on the first refusal with nothing dropped."""

from __future__ import annotations

import fcntl
import json
import os
import sys
import tempfile
import unittest
import unittest.mock
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from credit_verify.proof import gmail_intake  # noqa: E402
from credit_verify.proof import gmail_quota as gq  # noqa: E402

NOW = datetime(2026, 10, 31, 6, 0, tzinfo=timezone.utc)
REFUSAL = "gog rc=1: googleapi: Error 429: User-rate limit exceeded.  Retry after 2026-10-31T06:20:00.123Z"


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.state = os.path.join(self.td.name, "state")
        self.lock = os.path.join(self.td.name, "gmail-support.lock")
        # the ONE helper (#1558) reads its module constant at call time: point it at a temp file
        self._lp = unittest.mock.patch.object(gmail_intake, "SUPPORT_GMAIL_LOCK", self.lock)
        self._lp.start()
        self.now = NOW
        self.calls: list[str] = []
        # the hourly cap is a CONSTANT keyed by caller (r5): a test that wants a small one patches the table
        self._caps = unittest.mock.patch.dict(gq.HOURLY_CAP, {"file-recent": 100, "blob-backfill": 100})
        self._caps.start()

    def tearDown(self):
        self._caps.stop()
        self._lp.stop()
        self.td.cleanup()

    def g(self, fn=None, cap=100, lock=True):
        gq.HOURLY_CAP["file-recent"] = cap
        return gq.guarded("file-recent", fn or (lambda x: self.calls.append(x) or x), lock=lock,
                          now=lambda: self.now, state_dir=self.state)

    def test_a_quota_refusal_backs_off_every_caller_until_google_says(self):
        def refused(x):
            self.calls.append(x)
            raise RuntimeError(REFUSAL)
        with self.assertRaises(gq.GmailStop):
            self.g(refused)("m1")
        self.assertEqual(gq.backoff_until(self.now, self.state), "2026-10-31T06:20:01Z")
        other = gq.guarded("blob-backfill", lambda x: self.calls.append(x), now=lambda: self.now,
                           state_dir=self.state)
        with self.assertRaises(gq.GmailStop):
            other("m2")                                       # another caller: refused too, never called
        self.assertEqual(self.calls, ["m1"])
        self.now = datetime(2026, 10, 31, 6, 21, tzinfo=timezone.utc)
        self.assertEqual(self.g()("m3"), "m3")

    def test_a_standing_backoff_is_never_shortened(self):
        gq.note_refusal("429 Retry after 2026-10-31T07:00:00Z", "a", NOW, self.state)
        self.assertEqual(gq.note_refusal("429 Retry-After: 30", "b", NOW, self.state), "2026-10-31T07:00:01Z")

    def test_the_state_dir_is_a_constant_no_env_var_moves_it(self):
        import importlib.util
        os.environ["HYDRA_GMAIL_SUPPORT_STATE"] = self.state
        try:
            spec = importlib.util.spec_from_file_location("gq_env_probe", gq.__file__)
            m = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(m)
            self.assertEqual(m.STATE_DIR, "/var/lib/hydra/gmail-support")
        finally:
            del os.environ["HYDRA_GMAIL_SUPPORT_STATE"]
        self.assertNotIn("os.environ", Path(gq.__file__).read_text())

    def test_retry_after_forms(self):
        self.assertEqual(gq.retry_after_s("Retry after 2026-10-31T06:10:00Z", NOW), 601)
        self.assertEqual(gq.retry_after_s("Retry after 2026-10-31T05:00:00Z", NOW), 60)       # past: 60 s
        self.assertEqual(gq.retry_after_s("Retry after 2026-10-31T08:00:00+01:00", NOW), 3601)
        self.assertEqual(gq.retry_after_s("Retry-After: 120", NOW), 120)
        self.assertEqual(gq.retry_after_s("Error 429 rateLimitExceeded", NOW), 900)

    def test_a_far_future_retry_after_is_capped_not_believed(self):
        """Fable b1 on #1567: a window with no ceiling is a fleet-wide silence.

        `Retry-After: 2099` would publish a 73-year window, so every guarded caller refuses before spending a
        request, the stamp is never updated, and every log reads quiet and correct - the failure is invisible.
        The ceiling is #1558's (6 h), and the floor is #1558's (60 s) so a header already in the past still
        stops a stampede instead of publishing "now".
        """
        self.assertEqual(gq.retry_after_s("Retry after 2099-01-01T00:00:00Z", NOW), gq.RETRY_MAX_S)
        self.assertEqual(gq.retry_after_s("Retry-After: 999999", NOW), gq.RETRY_MAX_S)   # 11 days
        self.assertEqual(gq.retry_after_s("Retry-After: 0", NOW), gq.RETRY_MIN_S)
        self.assertEqual(gq.retry_after_s("Retry after 2020-01-01T00:00:00Z", NOW), gq.RETRY_MIN_S)
        # The default is inside the bounds, so an unparseable refusal is unchanged.
        self.assertEqual(gq.clamp_window(gq.DEFAULT_BACKOFF_S), gq.DEFAULT_BACKOFF_S)

    def test_the_hourly_budget_is_per_caller_and_resets_each_hour(self):
        f = self.g(cap=2)
        f("a")
        f("b")
        with self.assertRaises(gq.GmailStop):
            f("c")
        self.assertEqual(self.calls, ["a", "b"])
        other = gq.guarded("blob-backfill", lambda x: self.calls.append(x), now=lambda: self.now,
                           state_dir=self.state)
        other("d")                                                            # its own budget
        self.now = datetime(2026, 10, 31, 7, 0, tzinfo=timezone.utc)
        f("e")
        self.assertEqual(self.calls, ["a", "b", "d", "e"])

    def test_a_non_quota_error_is_raised_as_is_and_sets_no_backoff(self):
        def broken(x):
            raise RuntimeError("gog rc=2: message not found")
        with self.assertRaises(RuntimeError) as cm:
            self.g(broken)("m1")
        self.assertNotIsInstance(cm.exception, gq.GmailStop)
        self.assertIsNone(gq.backoff_until(self.now, self.state))

    def test_the_guard_takes_1558s_one_helper_not_a_copy(self):
        calls = []
        real = gmail_intake._support_gmail_lock

        def spy(wait_s=60.0):
            calls.append(wait_s)
            return real(wait_s)
        with unittest.mock.patch.object(gmail_intake, "_support_gmail_lock", spy):
            self.g()("m")
        self.assertEqual(len(calls), 1)
        self.assertFalse(hasattr(gq, "FALLBACK_LOCK"))                         # no second path of our own

    def test_no_openable_lock_fails_closed(self):
        with unittest.mock.patch.object(gmail_intake, "_support_gmail_lock", lambda wait_s=60.0: None):
            with self.assertRaises(gq.GmailStop):
                self.g()("m")
        self.assertEqual(self.calls, [])

    def test_the_call_runs_under_the_shared_lock_and_waits_for_its_holder(self):
        held = []

        def probe(x):
            fd = os.open(self.lock, os.O_RDWR)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                held.append(False)
            except OSError:
                held.append(True)                                             # ours: busy for anyone else
            finally:
                os.close(fd)
            return x
        self.g(probe)("m")
        self.assertEqual(held, [True])
        held.clear()
        self.g(probe, lock=False)("m")                                        # a callable that locks itself
        self.assertEqual(held, [False])
        fd = os.open(self.lock, os.O_CREAT | os.O_RDWR)
        fcntl.flock(fd, fcntl.LOCK_EX)                                        # the scan holds it
        try:
            with unittest.mock.patch.object(gmail_intake.time, "monotonic", side_effect=[0.0, 100.0]):
                with self.assertRaises(gq.GmailStop):
                    self.g()("m")
        finally:
            os.close(fd)


class TheWindowIsCheckedAgainUnderTheLock(unittest.TestCase):
    """QA #1567 findings 1 and 2: a window recorded while a caller waits for the lock, and a lock denial under
    lock=False that used to escape as a RuntimeError."""

    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.state = os.path.join(self.td.name, "state")
        self.lock = os.path.join(self.td.name, "gmail-support.lock")
        self._lp = unittest.mock.patch.object(gmail_intake, "SUPPORT_GMAIL_LOCK", self.lock)
        self._lp.start()
        self.now = NOW
        self.calls: list[str] = []
        self._caps = unittest.mock.patch.dict(gq.HOURLY_CAP, {"file-recent": 100, "blob-backfill": 100})
        self._caps.start()

    def tearDown(self):
        self._caps.stop()
        self._lp.stop()
        self.td.cleanup()

    def g(self, fn, lock=True):
        return gq.guarded("file-recent", fn, lock=lock, now=lambda: self.now, state_dir=self.state)

    def test_a_window_recorded_while_waiting_for_the_lock_is_honoured(self):
        # finding 1: the pre-lock check passes, then a DIFFERENT caller records a 429 while we queue. The request
        # must not go out inside that window.
        real = gmail_intake._support_gmail_lock

        def other_caller_refuses_first(wait_s=60.0):
            fh = real(wait_s)
            gq.note_refusal(REFUSAL, "cs-proof-feed/gmail_scan.sh", self.now, self.state)   # 06:20:01Z window
            return fh
        with unittest.mock.patch.object(gmail_intake, "_support_gmail_lock", other_caller_refuses_first):
            with self.assertRaises(gq.GmailStop):
                self.g(lambda x: self.calls.append(x) or x)("m1")
        self.assertEqual(self.calls, [])                                    # nothing was requested
        self.assertEqual(gq.backoff_until(self.now, self.state), "2026-10-31T06:20:01Z")
        # ...and the same for a callable that locks itself
        with unittest.mock.patch.object(gmail_intake, "_support_gmail_lock", other_caller_refuses_first):
            with self.assertRaises(gq.GmailStop):
                self.g(lambda x: self.calls.append(x) or x, lock=False)("m2")
        self.assertEqual(self.calls, [])

    def test_the_recheck_actually_runs_inside_the_lock_the_callable_takes(self):
        """QA #1567 finding 1, in the production shape: the SEARCH helper (recent.gog_search) takes the shared lock
        through hold_support_gmail_lock, so the wait is INSIDE the callable and a pre-call recheck cannot see a 429
        that another consumer records during it. The guard registers the recheck (AFTER_LOCK) and the lock holder
        runs it once the lock is ours - so the request never goes out inside the new window."""
        from credit_verify.proof.support_intake_lock import hold_support_gmail_lock
        real = gmail_intake._support_gmail_lock
        recorded = []

        def consumer_refuses_while_we_wait(wait_s=60.0):
            fh = real(wait_s)
            if not recorded:                      # the other consumer's run finishes the moment we get the lock
                recorded.append(True)
                gq.note_refusal(REFUSAL, "cs-proof-feed/gmail_scan.sh", self.now, self.state)
            return fh

        def search_like(x):                       # exactly gog_search's shape: the callable takes the lock itself
            return hold_support_gmail_lock(lambda: self.calls.append(x) or x)
        with unittest.mock.patch.object(gmail_intake, "_support_gmail_lock", consumer_refuses_while_we_wait):
            with self.assertRaises(gq.GmailStop):
                self.g(search_like, lock=False)("m1")
        self.assertEqual(recorded, [True])
        self.assertEqual(self.calls, [])                                    # no request inside the window
        self.assertEqual(gq.backoff_until(self.now, self.state), "2026-10-31T06:20:01Z")

    def test_the_real_gog_raw_path_rechecks_inside_the_lock_it_takes(self):
        """QA #1567 finding 1, round 2 — the PRODUCTION shape, not a stand-in.

        `credit-proof.py` wraps `gmail_intake.gog_raw` with `lock=False`, and `gog_raw` used to take
        `_support_gmail_lock()` directly, so the recheck the guard registers (AFTER_LOCK) was never run for the
        one callable that actually uses that path: the pre-lock check passed, the fetch waited up to 60 s for the
        lock, and a 429 another consumer recorded during that wait was never seen. The earlier case in this class
        used a `hold_support_gmail_lock` stand-in, which is why it stayed green while the real path leaked.

        This drives `gog_raw` itself: the lock wrapper records the refusal at the moment the lock is granted
        (i.e. while we were waiting), and the assertion is that NO gog request was issued.
        """
        real = gmail_intake._support_gmail_lock
        recorded = []
        ran = []

        def consumer_refuses_while_we_wait(wait_s=60.0):
            fh = real(wait_s)
            if not recorded:                      # the other consumer's run finishes the moment we get the lock
                recorded.append(True)
                gq.note_refusal(REFUSAL, "cs-proof-feed/gmail_scan.sh", self.now, self.state)
            return fh

        def fake_run(argv, **kw):                 # a gog call that must never happen
            ran.append(argv)
            raise AssertionError("gog was invoked inside a published backoff window")

        with unittest.mock.patch.object(gmail_intake, "_support_gmail_lock", consumer_refuses_while_we_wait), \
                unittest.mock.patch.object(gmail_intake.subprocess, "run", fake_run):
            with self.assertRaises(gq.GmailStop):
                self.g(gmail_intake.gog_raw, lock=False)("m1")
        self.assertEqual(recorded, [True])
        self.assertEqual(ran, [])                                           # no request inside the window
        self.assertEqual(gq.backoff_until(self.now, self.state), "2026-10-31T06:20:01Z")

    def test_gog_raw_still_refuses_when_no_lock_can_be_taken(self):
        """The delegation must not lose the fail-closed refusal: no lock at all is a typed GmailLockBusy, and the
        guard turns it into a stop (finding 2's contract, on the real path)."""
        ran = []

        def fake_run(argv, **kw):
            ran.append(argv)
            raise AssertionError("gog was invoked without the shared lock")

        with unittest.mock.patch.object(gmail_intake, "_support_gmail_lock", lambda *a, **k: None), \
                unittest.mock.patch.object(gmail_intake.subprocess, "run", fake_run):
            with self.assertRaises(gmail_intake.GmailLockBusy):
                gmail_intake.gog_raw("m1")
            with self.assertRaises(gq.GmailStop) as cm:
                self.g(gmail_intake.gog_raw, lock=False)("m1")
        self.assertIn("lock unavailable", str(cm.exception))
        self.assertEqual(ran, [])

    def test_a_denied_lock_under_lock_false_stops_the_run(self):
        # finding 2: lock=False means the callable takes the ONE shared lock. A denial must be a STOP, not a
        # RuntimeError that aborts a search and lets the fetch go on message by message.
        def cannot_lock(x):
            self.calls.append(x)
            raise gmail_intake.GmailLockBusy("another support@ Gmail consumer holds %s" % self.lock)
        with self.assertRaises(gq.GmailStop) as cm:
            self.g(cannot_lock, lock=False)("m1")
        self.assertIn("lock unavailable", str(cm.exception))
        self.assertNotIsInstance(cm.exception, gmail_intake.GmailLockBusy)
        # a genuine non-lock RuntimeError is still raised as-is, and sets no window
        def broken(x):
            raise RuntimeError("gog rc=2: message not found")
        with self.assertRaises(RuntimeError) as cm2:
            self.g(broken, lock=False)("m2")
        self.assertNotIsInstance(cm2.exception, gq.GmailStop)
        self.assertIsNone(gq.backoff_until(self.now, self.state))


class QuotaStateFailsClosedTests(unittest.TestCase):
    """QA #1567 round 2, finding 1: a state file that EXISTS but cannot be read or parsed must be a STOP.

    `_read()` answered `{}` for both absence and corruption, and the two are opposite signals: absence is the
    first run of every consumer, corruption is a guard that cannot learn the state it exists to enforce. An
    unreadable `backoff.json` read as "no window" (a request inside a 429 pause we had published), and a
    malformed `budget.json` read as "no calls this hour" (the 60/h cap resets). Both now refuse.
    """

    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.state = os.path.join(self.td.name, "state")
        os.makedirs(self.state, exist_ok=True)
        self.now = NOW

    def tearDown(self):
        self.td.cleanup()

    def _p(self, name):
        return os.path.join(self.state, name)

    def test_an_unparseable_backoff_file_stops_the_call(self):
        with open(self._p("backoff.json"), "w") as fh:
            fh.write('{"until": "2026-10-31T07:00:00Z"')       # truncated write: no window we can trust
        with self.assertRaises(gq.GmailStateUnreadable):
            gq.backoff_until(self.now, self.state)
        called = []
        g = gq.guarded("file-recent", lambda *a: called.append(a) or a, now=lambda: self.now,
                       state_dir=self.state)
        with self.assertRaises(gq.GmailStop):                   # a stop, and the request never goes out
            g("m1")
        self.assertEqual(called, [])

    def test_a_backoff_file_that_is_not_a_json_object_stops_the_call(self):
        with open(self._p("backoff.json"), "w") as fh:
            fh.write('["2026-10-31T07:00:00Z"]')                # a list is not the shape we wrote
        with self.assertRaises(gq.GmailStateUnreadable):
            gq.backoff_until(self.now, self.state)

    def test_an_unreadable_backoff_file_stops_the_call(self):
        os.makedirs(self._p("backoff.json"))                     # a directory where a file belongs: EISDIR
        with self.assertRaises(gq.GmailStateUnreadable):
            gq.backoff_until(self.now, self.state)

    def test_a_backoff_file_we_cannot_open_stops_the_call(self):
        with open(self._p("backoff.json"), "w") as fh:
            fh.write('{"until": "2026-10-31T07:00:00Z"}')
        os.chmod(self._p("backoff.json"), 0o000)
        try:
            if os.geteuid() == 0:                                # root reads anything: the branch is unreachable
                self.skipTest("running as root: a 000 file is still readable")
            with self.assertRaises(gq.GmailStateUnreadable):
                gq.backoff_until(self.now, self.state)
        finally:
            os.chmod(self._p("backoff.json"), 0o600)

    def test_a_malformed_budget_file_does_not_reset_the_hourly_cap(self):
        with open(self._p("budget.json"), "w") as fh:
            fh.write('{"hour": "2026-10-31T06", "calls": {')    # corrupt: the count is unknown, not zero
        with self.assertRaises(gq.GmailStateUnreadable):
            gq.take_budget("file-recent", 60, self.now, self.state)
        called = []
        g = gq.guarded("file-recent", lambda *a: called.append(a) or a, now=lambda: self.now,
                       state_dir=self.state)
        with self.assertRaises(gq.GmailStop):
            g("m1")
        self.assertEqual(called, [])

    def test_an_existing_empty_state_file_stops_the_call(self):
        """QA #1567 round 3: only a MISSING file is a first run. This module never writes an empty file
        (`_write` is tmp + `os.replace`), so an empty `backoff.json` is a torn write - and calling it "no
        window" is the fail-open the guard exists to prevent."""
        for content in ("", "   \n\t "):
            with open(self._p("backoff.json"), "w") as fh:
                fh.write(content)
            with self.assertRaises(gq.GmailStateUnreadable):
                gq.backoff_until(self.now, self.state)
            called = []
            g = gq.guarded("file-recent", lambda *a: called.append(a) or a, now=lambda: self.now,
                           state_dir=self.state)
            with self.assertRaises(gq.GmailStop):
                g("m1")
            self.assertEqual(called, [])

    def test_an_existing_empty_budget_file_does_not_reset_the_hourly_cap(self):
        with open(self._p("budget.json"), "w") as fh:
            fh.write("")
        with self.assertRaises(gq.GmailStateUnreadable):
            gq.take_budget("file-recent", 60, self.now, self.state)
        called = []
        g = gq.guarded("file-recent", lambda *a: called.append(a) or a, now=lambda: self.now,
                       state_dir=self.state)
        with self.assertRaises(gq.GmailStop):
            g("m1")
        self.assertEqual(called, [])

    def test_parseable_but_invalid_backoff_stops_the_call(self):
        """QA #1567 round 4: `{"until": null}` parses. Reading it as "no window" is the same fail-open
        one layer in, so an existing backoff.json must carry a usable ISO `until`."""
        for payload in ('{"until": null}', '{}', '{"until": ""}', '{"until": 1793805195929}',
                        '{"until": "2026-10-31 06:20", "by": "file-recent"}', '{"until": "not-a-time"}'):
            with open(self._p("backoff.json"), "w") as fh:
                fh.write(payload)
            with self.assertRaises(gq.GmailStateUnreadable, msg=payload):
                gq.backoff_until(self.now, self.state)
            called = []
            g = gq.guarded("file-recent", lambda *a: called.append(a) or a, now=lambda: self.now,
                           state_dir=self.state)
            with self.assertRaises(gq.GmailStop):
                g("m1")
            self.assertEqual(called, [], payload)

    def test_parseable_but_invalid_budget_does_not_reset_the_hourly_cap(self):
        """A same-hour object with missing/malformed `calls` read as "no calls yet" and reset the cap."""
        hour = self.now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H")
        for payload in ('{"hour": "%s"}' % hour,
                        '{"hour": "%s", "calls": null}' % hour,
                        '{"hour": "%s", "calls": []}' % hour,
                        '{"hour": "%s", "calls": {"file-recent": "59"}}' % hour,
                        '{"hour": "%s", "calls": {"file-recent": -3}}' % hour,
                        '{"hour": "garbage", "calls": {}}'):
            with open(self._p("budget.json"), "w") as fh:
                fh.write(payload)
            with self.assertRaises(gq.GmailStateUnreadable, msg=payload):
                gq.take_budget("file-recent", 60, self.now, self.state)
            called = []
            g = gq.guarded("file-recent", lambda *a: called.append(a) or a, now=lambda: self.now,
                           state_dir=self.state)
            with self.assertRaises(gq.GmailStop):
                g("m1")
            self.assertEqual(called, [], payload)

    def test_an_hour_that_is_thirteen_characters_but_not_an_hour_does_not_reset_the_cap(self):
        """QA #1567 round 5: length was the only test on `hour`. `2026-11-04Txx` is 13 characters, so it passed,
        compared unequal to the real hour, and `take_budget` read it as a NEW hour - resetting a spent ledger to
        zero. strptime alone is not enough either: it accepts `2026-11-4T9`, which is still a different STRING
        from the hour we compare against, so the canonical form is required too."""
        for bad in ("2026-11-04Txx", "2026-11-4T09", "2026-11-04T09x", "2026-13-04T09", "garbage-hour"):
            with open(self._p("budget.json"), "w") as fh:
                json.dump({"hour": bad, "calls": {"file-recent": 59}}, fh)
            with self.assertRaises(gq.GmailStateUnreadable, msg=bad):
                gq.take_budget("file-recent", 60, self.now, self.state)
            called = []
            g = gq.guarded("file-recent", lambda *a: called.append(a) or a, now=lambda: self.now,
                           state_dir=self.state)
            with self.assertRaises(gq.GmailStop):                 # a stop: the request never goes out
                g("m1")
            self.assertEqual(called, [], bad)

    def test_an_hour_stamped_in_the_future_does_not_reset_the_cap(self):
        """QA #1567 round 5, second half: a WELL-FORMED hour ahead of ours (clock rollback, a restored host, two
        boxes on one state dir) took the same reset path - spend the cap, correct the clock, spend it again.
        A future stamp is state we cannot reconcile, so it refuses and keeps the ledger."""
        future = (self.now.astimezone(timezone.utc) + timedelta(hours=3)).strftime("%Y-%m-%dT%H")
        with open(self._p("budget.json"), "w") as fh:
            json.dump({"hour": future, "calls": {"file-recent": 59}}, fh)
        with self.assertRaises(gq.GmailStateUnreadable):
            gq.take_budget("file-recent", 60, self.now, self.state)
        called = []
        g = gq.guarded("file-recent", lambda *a: called.append(a) or a, now=lambda: self.now,
                       state_dir=self.state)
        with self.assertRaises(gq.GmailStop):
            g("m1")
        self.assertEqual(called, [])
        with open(self._p("budget.json")) as fh:
            self.assertEqual(json.load(fh)["hour"], future)      # the ledger was NOT rewritten

    def test_a_valid_backoff_and_budget_still_run(self):
        """The other direction: correct state must not be refused, or the guard blocks everything."""
        with open(self._p("backoff.json"), "w") as fh:
            json.dump({"until": "2026-10-31T06:00:00Z", "by": "file-recent", "reason": "429"}, fh)
        self.assertIsNone(gq.backoff_until(self.now, self.state))     # a past window is no window
        hour = self.now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H")
        with open(self._p("budget.json"), "w") as fh:
            json.dump({"hour": hour, "calls": {"blob-backfill": 3}}, fh)
        self.assertTrue(gq.take_budget("file-recent", 60, self.now, self.state))

    def test_absence_is_still_the_first_run_not_a_stop(self):
        """The other half: a MISSING file must not be treated as corruption, or nothing ever runs."""
        self.assertIsNone(gq.backoff_until(self.now, self.state))       # no backoff.json at all
        self.assertTrue(gq.take_budget("file-recent", 60, self.now, self.state))  # no budget.json yet
        self.assertIsNone(gq.backoff_until(self.now, self.state))


class TheSearchPathTakesTheSameLockTests(unittest.TestCase):
    """QA #1567 finding 2, on the SEARCH path: `recent.gog_search` pages through support@ Gmail before any fetch,
    taking the shared lock itself. A lock that cannot be taken used to surface as a plain RuntimeError, which
    `recent_messages` does not catch - one search aborted and the run went on. It is a typed stop that holds the
    window."""

    def test_a_lock_that_cannot_be_taken_stops_the_search_and_holds_the_window(self):
        from credit_verify.proof import recent
        from credit_verify.proof.support_intake_lock import hold_support_gmail_lock
        td = tempfile.TemporaryDirectory()
        state = os.path.join(td.name, "state")
        caps = unittest.mock.patch.dict(gq.HOURLY_CAP, {"file-recent": 100})
        caps.start()
        try:
            def search_like(q, p):
                return hold_support_gmail_lock(lambda: {"messages": [{"id": "m1"}]})
            guarded_search = gq.guarded("file-recent", search_like, lock=False,
                                        now=lambda: NOW, state_dir=state)
            with unittest.mock.patch.object(gmail_intake, "SUPPORT_GMAIL_LOCK",
                                            "/proc/definitely-not-a-dir/gmail.lock"):
                with self.assertRaises(gmail_intake.GmailLockBusy):        # the TYPED denial, not a RuntimeError
                    hold_support_gmail_lock(lambda: None)
                self.assertIsInstance(gmail_intake.GmailLockBusy("x"), RuntimeError)
                with self.assertRaises(gq.GmailStop) as cm:
                    guarded_search("has:attachment after:1", "")
                self.assertIn("lock unavailable", str(cm.exception))
                ids, complete = recent.recent_messages(guarded_search, 1.0)
            self.assertEqual((ids, complete), ([], False))                  # nothing read, the window is HELD
            self.assertIsNone(gq.backoff_until(lambda: NOW, state))         # a busy lock is not a quota refusal
        finally:
            caps.stop()
            td.cleanup()


class FileRecentStopsTests(unittest.TestCase):
    """The hourly intake stops on the first refusal, keeps every message, and holds the window."""

    def test_a_refusal_mid_run_stops_fetching_and_carries_everything_untried(self):
        from credit_verify.proof import gmail_intake, recent
        from credit_verify.proof.store import ProofStore
        td = tempfile.mkdtemp()
        state, qstate, lock = (os.path.join(td, n) for n in ("recent.json", "q", "l"))
        lp = unittest.mock.patch.object(gmail_intake, "SUPPORT_GMAIL_LOCK", lock)
        lp.start()
        self.addCleanup(lp.stop)
        tried = []

        def raw(mid):
            tried.append(mid)
            if mid == "m1":
                raise RuntimeError(REFUSAL)
            raise AssertionError("never reached after the refusal")
        g = gq.guarded("file-recent", raw, now=lambda: NOW, state_dir=qstate)
        searches = []
        s = gq.guarded("file-recent", lambda q, p: searches.append(q) or {"messages": [
            {"id": f"m{i}"} for i in range(1, 5)]}, now=lambda: NOW, state_dir=qstate)
        store = ProofStore(":memory:")
        out = recent.run(state_path=state, hours=2, apply=True, now=10_000.0, conv_search=None, gmail_search=s,
                         max_messages=60, file_conversations=lambda c: {"deferred_conversations": []},
                         file_messages=lambda ids: gmail_intake.run(store, message_ids=ids, fetch=g,
                                                                    lookup=lambda a: [], open_rows=lambda u: {},
                                                                    apply=True))
        self.assertEqual(tried, ["m1"])                                       # stopped at the first refusal
        st = json.loads(Path(state).read_text())
        self.assertEqual(st["carry_messages"], ["m1", "m2", "m3", "m4"])      # nothing dropped
        self.assertFalse(out["window_advanced"])
        # the next hourly run inside the backoff: no search, no fetch, everything still carried
        out = recent.run(state_path=state, hours=2, apply=True, now=13_600.0, conv_search=None, gmail_search=s,
                         max_messages=60, file_conversations=lambda c: {"deferred_conversations": []},
                         file_messages=lambda ids: gmail_intake.run(store, message_ids=ids, fetch=g,
                                                                    lookup=lambda a: [], open_rows=lambda u: {},
                                                                    apply=True))
        self.assertEqual((len(searches), tried), (1, ["m1"]))
        self.assertEqual(json.loads(Path(state).read_text())["carry_messages"], ["m1", "m2", "m3", "m4"])

    def test_the_intake_loop_calls_fetch_once_after_a_stop(self):
        from credit_verify.proof import gmail_intake
        from credit_verify.proof.store import ProofStore
        calls = []

        def fetch(mid):
            calls.append(mid)
            raise gq.GmailStop("support@ Gmail backoff until later")
        st = gmail_intake.run(ProofStore(":memory:"), message_ids=["a", "b", "c"], fetch=fetch, lookup=lambda a: [],
                              open_rows=lambda u: {}, apply=True)
        self.assertEqual((calls, st["fetch_errors"]), (["a"], ["a: GmailStop", "b: GmailStop", "c: GmailStop"]))
        self.assertIn("backoff", st["stopped"])

    def test_a_stopped_search_holds_the_window(self):
        from credit_verify.proof import recent
        td = tempfile.mkdtemp()
        state = os.path.join(td, "recent.json")

        def search(q, p):
            raise gq.GmailStop("support@ Gmail backoff until later")
        out = recent.run(state_path=state, hours=2, apply=True, now=10_000.0, conv_search=None, gmail_search=search,
                         max_messages=60, file_conversations=lambda c: {"deferred_conversations": []},
                         file_messages=lambda ids: {"fetch_errors": []})
        self.assertEqual((out["complete"], out["window_advanced"]), (False, False))


if __name__ == "__main__":
    unittest.main()
