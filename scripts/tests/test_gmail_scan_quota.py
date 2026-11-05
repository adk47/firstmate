"""gmail_scan.sh: honour Google's Retry-After, and never be a second support@ consumer.

2026-10-31: the hourly proof-feed scan, the hourly support@ intake cron and a manual scan shared one per-user
Gmail quota; a 429 storm kept cs-gmail stale and the fail-closed freshness gate blocked 89 paid uvn asks. The
backoff was 45 s x try (max ~15 min) while the retry-after kept moving to +9..+15 min, so the scan burned all
six attempts and died.

STDLIB ONLY (`python3 scripts/tests/test_gmail_scan_quota.py`), deliberately: this file pins the budget/backoff
behaviour that keeps a stale part honest, and while it was pytest-style `pr-validate` never ran it, so CI green
proved nothing about it (doc-verify, 2026-10-31). It is listed in the Python unit tests step.
"""
from __future__ import annotations

import fcntl
import json

RETRY_DEFAULT_S = 900        # mirrors gmail_scan.sh: a refusal with no Retry-after
RETRY_MAX_S = 6 * 3600       # mirrors gmail_scan.sh: the cap on any published window


def now_utc():
    import datetime as dt
    return dt.datetime.now(dt.timezone.utc)


def iso(stamp):
    """Parse the scan's published 'YYYY-MM-DDTHH:MM:SSZ' stamp into an aware datetime."""
    import datetime as dt
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            return dt.datetime.strptime(stamp, fmt).replace(tzinfo=dt.timezone.utc)
        except ValueError:
            continue
    raise AssertionError("unparseable backoff stamp: %r" % (stamp,))
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import uuid
import time
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SCAN = HERE.parent / "cs_proof_feed" / "gmail_scan.sh"


def fake_gog(directory, mode):
    """A gog stand-in: a 429 (Retry-after far in the past) or a clean page."""
    p = pathlib.Path(directory) / "gog"
    p.write_text(
        "#!/bin/bash\n"
        "case %r in\n"
        "  429) echo 'Google API error (429 rateLimitExceeded): User-rate limit exceeded. "
        "Retry after 2020-01-01T00:00:00.000Z' >&2; exit 7 ;;\n"
        "  page) echo '{\"messages\": []}'; exit 0 ;;\n"
        "esac\n" % mode
    )
    p.chmod(0o755)
    return p


def run_scan(directory, gog, env_extra=None):
    """Run the scan with the ONE test seam: CS_PROOF_FEED_TEST_SEAM, set to this test's own temp dir. No
    CS_PROOF_* env var moves a gate any more (r5), and BATS_TEST_TMPDIR is NOT a seam: it is inherited from any
    parent shell, so it could redirect the kill file, the lock and the state dir (QA on a2d87a1c9)."""
    d = pathlib.Path(directory)
    (d / "state").mkdir(exist_ok=True)
    env = dict(os.environ)
    env.pop("CS_PROOF_GMAIL_DIR", None)
    # The seam dir must LOOK like a bats temp root and belong to us, so the harness names its own temp
    # dirs bats-*; there is no separate seam directory to keep in sync with where the stand-in gog lives.
    env["CS_PROOF_FEED_TEST_SEAM"] = str(d)
    env.pop("BATS_TEST_TMPDIR", None)
    env.update(env_extra or {})
    return subprocess.run(["bash", str(SCAN), "atti", "newer_than:2d"], env=env,
                          capture_output=True, text=True, timeout=180)


class GmailScanQuota(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="bats-gmail-scan-")
        self.addCleanup(shutil.rmtree, self.dir, True)

    def log(self):
        return (pathlib.Path(self.dir) / "state" / "gmail" / "atti.log").read_text()

    def test_honours_a_future_retry_after_then_succeeds(self):
        """A FUTURE retry-after must actually be waited for, and the retry must then succeed.

        The first version used a past timestamp, which yields the same 1 s as the configured fallback, so it
        would still pass if timestamp handling regressed. This measures the wait (>= 3 s for a 429 naming
        now+3 s) and proves the retry recovers with DONE instead of dying after a fixed number of attempts.
        """
        gog = pathlib.Path(self.dir) / "gog"
        counter = pathlib.Path(self.dir) / "calls"
        gog.write_text("\n".join([
            "#!/bin/bash",
            "n=0",
            'if [ -f "%s" ]; then n=$(cat "%s"); fi' % (counter, counter),
            "n=$((n+1))",
            'echo $n > "%s"' % counter,
            "if [ $n -le 1 ]; then",
            '  when=$(python3 -c "import datetime as d;'
            "print((d.datetime.now(d.timezone.utc)+d.timedelta(seconds=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))"
            '")',
            '  echo "Google API error (429 rateLimitExceeded): User-rate limit exceeded. Retry after $when" >&2',
            "  exit 7",
            "fi",
            'echo \'{"messages": []}\'',
            "",
        ]))
        gog.chmod(0o755)
        started = time.time()
        r = run_scan(self.dir, gog)
        elapsed = time.time() - started
        log = self.log()
        self.assertEqual(r.returncode, 0, log)
        self.assertIn("retry-after honoured", log)
        self.assertGreaterEqual(elapsed, 3, "the future timestamp was not waited for")
        self.assertIn("DONE pages=1", log)

    def test_a_clean_page_still_ends_done(self):
        r = run_scan(self.dir, fake_gog(self.dir, "page"))
        self.assertEqual(r.returncode, 0, (r.stdout, r.stderr))
        self.assertIn("DONE pages=1", self.log())

    def test_saturated_quota_exits_cleanly_inside_the_outer_timeout(self):
        """A retry-after longer than the remaining budget exits 4 instead of sleeping into the 1500 s kill."""
        gog = fake_gog(self.dir, "429")
        gog.write_text(gog.read_text().replace("2020-01-01T00:00:00.000Z", "2099-01-01T00:00:00.000Z"))
        r = run_scan(self.dir, gog)
        log = self.log()
        self.assertEqual(r.returncode, 4, log)
        self.assertIn("QUOTA SATURATED", log)
        self.assertNotIn("DONE", log)

    def test_honours_the_shared_backoff_without_spending_a_request(self):
        """hydra #1567's backoff file: a scan inside the window makes no request at all."""
        import datetime as dt
        state = pathlib.Path(self.dir) / "backoff"
        state.mkdir(exist_ok=True)
        future = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        (state / "backoff.json").write_text(json.dumps({"until": future, "by": "test"}))
        r = run_scan(self.dir, fake_gog(self.dir, "page"))
        log = self.log()
        self.assertEqual(r.returncode, 4, log)
        self.assertIn("SHARED BACKOFF honoured", log)
        self.assertNotIn("DONE", log)

    def test_a_long_retry_after_is_never_quietly_shrunk_to_a_sleep_cap(self):
        """QA #1567 finding 3: a 30-minute Retry-after was capped at 900 s for the SLEEP while 1800 s was published
        to every other consumer, so the retry went out inside a window this file had just promised. The reported
        window must be the true one (the published window), and it stops rather than sleeping short."""
        import datetime as dt
        gog = pathlib.Path(self.dir) / "gog"
        when = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=1000)).strftime("%Y-%m-%dT%H:%M:%SZ")
        gog.write_text("#!/bin/bash\n"
                       "echo 'Google API error (429 rateLimitExceeded): User-rate limit exceeded. "
                       "Retry after %s' >&2\n"
                       "exit 7\n" % when)
        gog.chmod(0o755)
        r = run_scan(self.dir, gog)
        log = self.log()
        self.assertEqual(r.returncode, 4, log)
        self.assertRegex(log, r"retry-after 1\d{3}s exceeds the remaining budget")   # the TRUE window, not 900
        self.assertNotIn("retry-after 9", log)
        self.assertNotIn("DONE", log)

    def test_a_429_without_a_timestamp_never_retries_inside_the_published_window(self):
        """QA #1567 finding 3: the guard publishes a DEFAULT window when Google names no Retry-after, and the scan
        used to wait 45 s x try (0 s in tests) while that window stood - four retries inside a promise it had just
        made to every other support@ consumer. It now sleeps the published window or stops; either way it must not
        send a second request inside the window it published."""
        counter = pathlib.Path(self.dir) / "calls"
        gog = pathlib.Path(self.dir) / "gog"
        gog.write_text("\n".join([
            "#!/bin/bash",
            "n=0",
            'if [ -f "%s" ]; then n=$(cat "%s"); fi' % (counter, counter),
            "n=$((n+1))",
            'echo $n > "%s"' % counter,
            "echo 'Google API error (429 rateLimitExceeded): User-rate limit exceeded.' >&2",
            "exit 7",
            "",
        ]))
        gog.chmod(0o755)
        r = run_scan(self.dir, gog)
        log = self.log()
        self.assertEqual(r.returncode, 4, log)                  # a clean saturated stop, never six wasted attempts
        self.assertEqual(counter.read_text().strip(), "1", log)  # not one retry inside the published window
        self.assertIn("published window", log)
        self.assertNotIn("DONE", log)
        self.assertNotIn("FAILED page", log)
        published = json.loads((pathlib.Path(self.dir) / "backoff" / "backoff.json").read_text())
        self.assertIn("until", published)

    def test_a_saturated_exit_still_publishes_the_shared_window(self):
        """Exiting 4 must still publish backoff.json, or the next consumer spends a request rediscovering it."""
        gog = fake_gog(self.dir, "429")
        gog.write_text(gog.read_text().replace("2020-01-01T00:00:00.000Z", "2099-01-01T00:00:00.000Z"))
        state = pathlib.Path(self.dir) / "backoff"
        r = run_scan(self.dir, gog)
        log = self.log()
        self.assertEqual(r.returncode, 4, log)
        self.assertNotIn("DONE", log)
        published = json.loads((state / "backoff.json").read_text())
        # QA 11-03 23:21 (Fable r6): a far-future Retry-after must never be stored verbatim. Storing 2099
        # teaches every other support@ consumer a decades-long silence, and every log then reads quiet and
        # correct while nothing scans. The published window is capped at 6 h from now.
        self.assertFalse(published["until"].startswith("2099-01-01"),
                         "a 2099 retry-after was published verbatim: %r" % (published,))
        self.assertLessEqual((iso(published["until"]) - now_utc()).total_seconds(), RETRY_MAX_S + 120, published)
        self.assertGreater((iso(published["until"]) - now_utc()).total_seconds(), 0, published)

    def test_a_far_future_retry_after_is_capped_not_stored_verbatim(self):
        """The cap, measured: 2099 is 72 years away and must land 6 h out, not in 2099."""
        gog = fake_gog(self.dir, "429")
        gog.write_text(gog.read_text().replace("2020-01-01T00:00:00.000Z", "2099-01-01T00:00:00.000Z"))
        state = pathlib.Path(self.dir) / "backoff"
        run_scan(self.dir, gog)
        published = json.loads((state / "backoff.json").read_text())
        horizon = (iso(published["until"]) - now_utc()).total_seconds()
        self.assertLessEqual(horizon, RETRY_MAX_S + 120, published)
        self.assertGreaterEqual(horizon, RETRY_MAX_S - 120, published)

    def test_a_429_without_a_retry_after_still_publishes_a_bounded_window(self):
        """The other arm of the same hole: a refusal with no header used to publish NOTHING, so the next
        support@ caller spent a request to rediscover it. It publishes a default 15 minutes, bounded."""
        gog = pathlib.Path(self.dir) / "gog"
        gog.write_text("#!/bin/bash\n"
                       'echo "Google API error: 429 rateLimitExceeded: user-rate limit exceeded" >&2\n'
                       "exit 7\n")
        gog.chmod(0o755)
        state = pathlib.Path(self.dir) / "backoff"
        run_scan(self.dir, gog)
        published = json.loads((state / "backoff.json").read_text())
        horizon = (iso(published["until"]) - now_utc()).total_seconds()
        self.assertLessEqual(horizon, RETRY_DEFAULT_S + 120, published)
        self.assertGreaterEqual(horizon, RETRY_DEFAULT_S - 120, published)


    def test_every_429_publishes_the_window_even_when_the_wait_fits(self):
        """babysit-b1 on #1567: publishing only on the give-up path meant other callers learned the window
        AFTER this scan had already slept through it. Every 429 must publish."""
        import datetime as dt
        future = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=4)).strftime("%Y-%m-%dT%H:%M:%SZ")
        gog = fake_gog(self.dir, "429")
        gog.write_text(gog.read_text().replace("2020-01-01T00:00:00.000Z", future))
        state = pathlib.Path(self.dir) / "backoff"
        run_scan(self.dir, gog)
        published = json.loads((state / "backoff.json").read_text())
        # The guarantee this test protects is "a fitting 429 still publishes a window", not the literal stamp.
        # It cannot be a post-run horizon any more: with the seam's floor at 0 the scan WAITS the window out
        # and then succeeds, so by the time the test reads the file the horizon is spent by design (a floor of
        # 60 s made it un-waitable, which is why this was the only case that ever saw a positive horizon).
        # What must still hold: the file EXISTS - the bug was that nothing was written at all on a fitting
        # 429 - it names this scan, and a far-future stamp is still bounded, not stored verbatim.
        self.assertEqual(published.get("by"), "cs-proof-feed/gmail_scan.sh", published)
        horizon = (iso(published["until"]) - now_utc()).total_seconds()
        self.assertLessEqual(horizon, RETRY_MAX_S + 120, published)


    def test_a_non_quota_failure_does_not_set_the_host_wide_backoff(self):
        """QA: publishing 900 s for a network/auth error or invalid JSON silences every other support@ caller
        for the wrong reason. Only a QUOTA refusal may write the shared window."""
        gog = pathlib.Path(self.dir) / "gog"
        gog.write_text("#!/bin/bash\necho 'gog: connection reset by peer' >&2\nexit 7\n")
        gog.chmod(0o755)
        state = pathlib.Path(self.dir) / "backoff"
        run_scan(self.dir, gog)
        self.assertFalse((state / "backoff.json").exists(),
                         "a network failure wrote a host-wide quota backoff")


    def test_env_vars_cannot_move_the_scan_state(self):
        """RED MUTANT for the env-movability gate (r5): main.env is sourced by the scan, so any CS_PROOF_* the
        script still honoured would let whoever writes that file move the state, the lock or the binary. The
        scan must ignore them and write only where the BATS seam points."""
        hostile = pathlib.Path(self.dir) / "hostile"
        hostile.mkdir()
        r = run_scan(self.dir, fake_gog(self.dir, "page"),
                     {"CS_PROOF_GMAIL_DIR": str(hostile), "CS_PROOF_GOG": "/bin/false",
                      "CS_PROOF_GMAIL_BUDGET": "1", "CS_PROOF_LOCK_DIR": str(hostile)})
        self.assertEqual(r.returncode, 0, (r.stdout, r.stderr))
        self.assertIn("DONE pages=1", self.log())          # wrote to the seam dir
        self.assertEqual(list(hostile.iterdir()), [], "an env var moved the scan's state")

    def test_a_hostile_sourced_env_file_cannot_move_the_gate(self):
        """QA #1558 round 3 (93ba997): the gate constants used to be assigned BEFORE /etc/openclaw/main.env was
        sourced, so whoever writes that file could move LOCK_DIR (two "locked" support@ consumers on different
        inodes, one saturated quota) or BUDGET=1800 (the caller's 1500 s kill landing mid-scan). The file is
        still sourced - it carries gog's credentials - so this is not a "stop reading it" change: the gate
        values are simply assigned after it, and the start line now names the env file, the lock and the
        budget the run is really using, so a regression is visible instead of two logs both saying
        "lock held"."""
        hostile = pathlib.Path(self.dir) / "hostile"
        hostile.mkdir()
        marker = pathlib.Path(self.dir) / "hostile-gog-ran"
        evil_gog = hostile / "gog"
        evil_gog.write_text("#!/bin/bash\ntouch %s\nexit 0\n" % marker)
        evil_gog.chmod(0o755)
        (pathlib.Path(self.dir) / "main.env").write_text(
            "\n".join([
                "GOG=%s" % evil_gog,
                "LOCK_DIR=%s" % (hostile / "lock"),
                "STATE_DIR=%s" % (hostile / "state"),
                "BACKOFF_DIR=%s" % (hostile / "backoff"),
                "BUDGET=1800",
                "LOCK_WAIT=0",
                "PAGE_PAUSE=999",
                "FALLBACK_BACKOFF=999",
                "ACCOUNT=attacker@example.com",
                "",
            ])
        )
        r = run_scan(self.dir, fake_gog(self.dir, "page"))   # the seam's stand-in lives at $dir/gog
        log = self.log()
        self.assertEqual(r.returncode, 0, (r.stdout, r.stderr, log))
        self.assertIn("DONE pages=1", log)
        start = next(line for line in log.splitlines() if "(lock held)" in line)
        # the env file WAS sourced (its path is the one the run reports) ...
        self.assertIn("env=%s/main.env" % self.dir, start, start)
        # ... and every gate value is still the script's own, not the file's
        self.assertIn("lock=%s/lock/gmail-support.lock" % self.dir, start, start)
        self.assertIn("budget=20", start, start)
        self.assertFalse(marker.exists(), "main.env moved GOG: the hostile stand-in ran")
        self.assertFalse((hostile / "lock").exists(), "main.env moved LOCK_DIR")
        self.assertFalse((hostile / "state").exists(), "main.env moved STATE_DIR")
        self.assertFalse((hostile / "backoff").exists(), "main.env moved BACKOFF_DIR")

    def test_an_unwritable_lock_dir_refuses_rather_than_going_private(self):
        """RED MUTANT for the lock gate: a private-lock fallback would let two consumers each believe they hold
        the lock while writing different files. An unusable lock dir must exit 3, not scan alone."""
        (pathlib.Path(self.dir) / "lock").write_text("not a directory")
        r = run_scan(self.dir, fake_gog(self.dir, "page"))
        self.assertEqual(r.returncode, 3, (r.returncode, r.stdout, r.stderr))
        self.assertNotIn("DONE", self.log())


class SupportGmailLock(unittest.TestCase):
    """The lock is the ONE statement of "who may speak to support@'s Gmail right now"."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="bats-gmail-lock-")
        self.addCleanup(shutil.rmtree, self.dir, True)
        sys.path.insert(0, str(HERE.parent))
        from credit_verify.proof import gmail_intake as gi
        self.gi = gi
        self._orig_lock = gi._support_gmail_lock
        self._orig_run = gi.subprocess.run
        self.addCleanup(setattr, gi, "_support_gmail_lock", self._orig_lock)
        self.addCleanup(setattr, gi.subprocess, "run", self._orig_run)

        def _no_gog(*a, **k):
            raise AssertionError("test reached the real gog")

        gi.subprocess.run = _no_gog
        self.lockfile = os.path.join(self.dir, "gmail-support.lock")
        gi.SUPPORT_GMAIL_LOCK = self.lockfile

    def _hold(self):
        fh = open(self.lockfile, "w")
        fcntl.flock(fh, fcntl.LOCK_EX)
        return fh

    def test_the_intake_takes_the_same_lock(self):
        """The intake must not be a second concurrent support@ consumer."""
        holder = self._hold()
        try:
            with self.assertRaises(RuntimeError) as ctx:
                self.gi._support_gmail_lock(wait_s=0.5)
            self.assertIn("another support@ Gmail consumer", str(ctx.exception))
        finally:
            fcntl.flock(holder, fcntl.LOCK_UN)
            holder.close()

    def test_a_lock_it_cannot_take_is_a_refusal_never_an_unlocked_read(self):
        self.gi._support_gmail_lock = lambda *a, **k: None
        with self.assertRaises(RuntimeError) as ctx:
            self.gi.gog_raw("abc123", min_interval=0, **{"_last": [0.0]})
        self.assertIn("unlocked", str(ctx.exception))

    def test_the_intake_search_takes_the_lock_too(self):
        """QA: gog_raw (GET) was locked but recent.gog_search (SEARCH) was not - the one unlocked path."""
        from credit_verify.proof import recent
        orig = self._orig_lock
        self.gi._support_gmail_lock = lambda *a, **k: orig(wait_s=0.5)
        holder = self._hold()
        try:
            search = recent.gog_search()
            with self.assertRaises(RuntimeError) as ctx:
                search("newer_than:2d", "")
            message = str(ctx.exception)
            self.assertTrue("another support@ Gmail consumer" in message or "refusing to search" in message,
                            message)
        finally:
            fcntl.flock(holder, fcntl.LOCK_UN)
            holder.close()


class SharedLockIsTheOnlyPath(unittest.TestCase):
    """r5: the intake must not fall back to a private lock inode when the shared one is unusable."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="bats-gmail-lock2-")
        self.addCleanup(shutil.rmtree, self.dir, True)
        sys.path.insert(0, str(HERE.parent))
        from credit_verify.proof import gmail_intake as gi
        self.gi = gi
        self.addCleanup(setattr, gi, "SUPPORT_GMAIL_LOCK", gi.SUPPORT_GMAIL_LOCK)

    def test_an_unusable_shared_lock_is_a_refusal_not_a_private_one(self):
        # A file where the lock's parent directory should be: unusable for root too, so the test means the same
        # thing on a CI runner that happens to run as root.
        blocker = os.path.join(self.dir, "blocker")
        open(blocker, "w").close()
        self.gi.SUPPORT_GMAIL_LOCK = os.path.join(blocker, "lock", "gmail-support.lock")
        self.assertIsNone(self.gi._support_gmail_lock(wait_s=0.2),
                          "the intake fell back to a private lock instead of refusing")



class TheTestSeamCannotBeInherited(unittest.TestCase):
    """QA on a2d87a1c9 — Fable withdrew GO over this: the seam WAS BATS_TEST_TMPDIR, which is inherited from any
    parent shell (a bats-wrapped cron, an operator's tmux, a CI runner that happens to export it), so one stray
    value moved the readers-kill file, the shared lock, the state dir and the gog binary. That is precisely the
    "a gate the environment can move" class this script exists to close, sitting in the seam meant to close it.

    The seam is now CS_PROOF_FEED_TEST_SEAM, honoured only as an absolute path under a bats temp root that the
    caller owns, and refused with exit 2 otherwise — a refusal, not a silent fallback, so an inherited value can
    neither redirect a production gate nor quietly disarm it.
    """

    KNOBS = ("CS_PROOF_ENV", "CS_PROOF_GOG", "CS_PROOF_GMAIL_DIR", "CS_PROOF_GMAIL_ACCOUNT",
             "CS_PROOF_GMAIL_BACKOFF", "CS_PROOF_GMAIL_PAGE_PAUSE", "CS_PROOF_FEED_TEST_SEAM",
             "BATS_TEST_TMPDIR", "BATS_VERSION", "BATS_TEST_FILENAME")

    def resolve(self, extra_env):
        env = {k: v for k, v in os.environ.items() if k not in self.KNOBS}
        env.update(extra_env)
        return subprocess.run(["bash", str(SCAN), "--resolve-paths"], env=env, capture_output=True,
                              text=True, timeout=60)

    @staticmethod
    def paths(out):
        return dict(line.split("=", 1) for line in out.strip().splitlines() if "=" in line)

    def test_a_hostile_bats_test_tmpdir_in_a_non_bats_shell_moves_nothing(self):
        # The exact hostile environment QA described: a non-bats shell (no BATS_VERSION, no bats runner) that
        # exports BATS_TEST_TMPDIR. Every production path must survive it untouched.
        hostile = tempfile.mkdtemp(prefix="hostile-tmp-")
        self.addCleanup(shutil.rmtree, hostile, True)
        r = self.resolve({"BATS_TEST_TMPDIR": hostile, "TMPDIR": hostile})
        self.assertEqual(r.returncode, 0, (r.stdout, r.stderr))
        p = self.paths(r.stdout)
        self.assertEqual(p["kill"], "/etc/hydra/gmail-readers.disabled")
        self.assertEqual(p["state"], "/var/lib/hydra/cs-proof-feed")
        self.assertEqual(p["gmail"], "/var/lib/hydra/cs-proof-feed/gmail")
        self.assertEqual(p["lock"], "/run/hydra")
        self.assertEqual(p["backoff"], "/var/lib/hydra/gmail-support")
        self.assertEqual(p["gog"], "gog")          # the real binary on PATH, not the stand-in
        self.assertEqual(p["env"], "/etc/openclaw/main.env")

    def test_a_seam_outside_a_bats_root_is_refused_not_honoured(self):
        for bad in ("/etc", "/var/lib/hydra", "/tmp/not-a-bats-root", "/tmp/batsX"):
            r = self.resolve({"CS_PROOF_FEED_TEST_SEAM": bad})
            self.assertEqual(r.returncode, 2, (bad, r.stdout, r.stderr))
            self.assertIn("refused", r.stderr)
            self.assertEqual(r.stdout, "", "a refused seam must not resolve any path")

    def test_a_relative_seam_is_refused(self):
        r = self.resolve({"CS_PROOF_FEED_TEST_SEAM": "bats-relative"})
        self.assertEqual(r.returncode, 2, (r.stdout, r.stderr))
        self.assertIn("not an absolute path", r.stderr)

    def test_a_bats_root_that_is_not_owned_or_is_not_a_dir_is_refused(self):
        missing = "/tmp/bats-does-not-exist-" + uuid.uuid4().hex
        r = self.resolve({"CS_PROOF_FEED_TEST_SEAM": missing})
        self.assertEqual(r.returncode, 2, (r.stdout, r.stderr))
        self.assertIn("refused", r.stderr)

    def test_a_seam_under_a_bats_root_is_honoured(self):
        seam = tempfile.mkdtemp(prefix="bats-seam-")
        self.addCleanup(shutil.rmtree, seam, True)
        # ...even while a hostile BATS_TEST_TMPDIR points somewhere else entirely: the explicit seam is the only
        # thing that decides, and BATS_TEST_TMPDIR is inert.
        r = self.resolve({"CS_PROOF_FEED_TEST_SEAM": seam, "BATS_TEST_TMPDIR": "/etc"})
        self.assertEqual(r.returncode, 0, (r.stdout, r.stderr))
        p = self.paths(r.stdout)
        self.assertEqual(p["state"], os.path.join(seam, "state"))
        self.assertEqual(p["lock"], os.path.join(seam, "lock"))
        self.assertEqual(p["gog"], os.path.join(seam, "gog"))
        self.assertEqual(p["kill"], os.path.join(seam, "gmail-readers.disabled"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
