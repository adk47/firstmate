"""Behavioral tests for scripts/close-stale-conversations.py.

This is a HUMAN-RUN (no timer) silent closer for the stale we-spoke-last
backlog: open inbound conversations where WE replied last and the customer
has been silent for more than STALE_DAYS (default 30). It silently closes on
--apply only. The safety-relevant invariants under test:

  - a customer still waiting is NEVER closed: customer-last (lcr >= lar) and
    never-replied (lar == 0) conversations are ineligible, and the ambiguous
    lar == lcr tie is treated as NOT-proven-admin-last;
  - staleness is strict (> STALE_DAYS since OUR last reply): a conversation
    whose customer went silent exactly STALE_DAYS ago is left alone, as is
    one we replied to recently even if the thread itself is ancient;
  - de-confliction is by CONVERSATION ID only, never email, against every
    sibling sweeper source; a corrupt/unreadable sibling source fails the
    whole run CLOSED (exit 4, zero closes) — never "no ownership";
  - dry-run performs ZERO Intercom writes and leaves a masked review export
    (no raw customer email ever reaches the export);
  - --apply respects --limit, hard-stops with zero closes when the candidate
    count exceeds the ceiling (default STALE_CEILING, --ceiling N overrides),
    and hard-stops when the shadow log cannot be opened;
  - every close is shadow-logged under the "id" key (so the ops-drain and
    dup-close sibling readers de-conflict against it as-is; the digest
    deliberately does NOT read it — reopened conversations must resurface);
  - a mid-drain transport error (connection reset, timeout) lands in the
    fail list instead of crashing the run;
  - a dry-run whose review export could not be written anywhere exits
    non-zero (the export is the supervised-drain review surface).

Stdlib unittest + stubs only — no network. Runs under BOTH `python3 -m
unittest tests.test_close_stale_conversations` (the CI py-tests convention)
and `python3 -m pytest tests/test_close_stale_conversations.py`.
"""
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import time
import unittest
from unittest import mock

_SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "scripts"
    / "close-stale-conversations.py"
)
_spec = importlib.util.spec_from_file_location("close_stale_conversations", _SCRIPT)
d = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(d)

# Anchor fixture timestamps to the real clock: main() computes staleness with
# time.time(), so a fixed far-future epoch would make "40 days old" fixtures
# not-yet-stale (or vice versa) depending on when the suite runs.
NOW = int(time.time())
DAY = 86400
STALE_SECS = 30 * DAY


def conv(cid="c1", email="alice@example.com", lar=0, lcr=0, created_at=0,
         is_inbound=True):
    return {"id": cid, "email": email, "lar": lar, "lcr": lcr,
            "created_at": created_at, "is_inbound": is_inbound}


def old_eligible(cid="c1", email="alice@example.com"):
    """An unambiguously eligible conversation: inbound, we spoke last,
    customer silent for ~40 days."""
    return conv(cid, email, lar=NOW - 40 * DAY, lcr=NOW - 50 * DAY,
                created_at=NOW - 60 * DAY)


class Eligibility(unittest.TestCase):
    def eligible(self, c, owned=frozenset(), now=NOW, stale_secs=STALE_SECS):
        return d.is_eligible(c, owned, now, stale_secs)

    def test_old_admin_last_is_eligible(self):
        self.assertTrue(self.eligible(old_eligible()))

    def test_customer_last_never_closed(self):
        c = conv(lar=NOW - 50 * DAY, lcr=NOW - 40 * DAY, created_at=NOW - 60 * DAY)
        self.assertFalse(self.eligible(c))

    def test_never_replied_never_closed(self):
        # lar == 0: the customer never got an answer at all — even at 100+
        # days this must never be silently buried.
        c = conv(lar=0, lcr=0, created_at=NOW - 115 * DAY)
        self.assertFalse(self.eligible(c))

    def test_second_granularity_tie_not_closed(self):
        # lar == lcr is an ambiguous ordering, not proven admin-last.
        t = NOW - 40 * DAY
        self.assertFalse(self.eligible(conv(lar=t, lcr=t, created_at=t - DAY)))

    def test_recent_admin_reply_not_closed_even_if_thread_ancient(self):
        # We replied 5 days ago to a 200-day-old thread: the customer has only
        # been silent 5 days — closing now would be premature.
        c = conv(lar=NOW - 5 * DAY, lcr=NOW - 200 * DAY, created_at=NOW - 200 * DAY)
        self.assertFalse(self.eligible(c))

    def test_boundary_exactly_stale_days_not_closed(self):
        # Strictly older than STALE_DAYS: silent for exactly 30d is NOT stale.
        c = conv(lar=NOW - STALE_SECS, lcr=NOW - 40 * DAY, created_at=NOW - 40 * DAY)
        self.assertFalse(self.eligible(c))

    def test_just_past_boundary_is_eligible(self):
        c = conv(lar=NOW - STALE_SECS - 1, lcr=NOW - 40 * DAY, created_at=NOW - 40 * DAY)
        self.assertTrue(self.eligible(c))

    def test_non_inbound_not_closed(self):
        c = old_eligible()
        c["is_inbound"] = False
        self.assertFalse(self.eligible(c))

    def test_owned_id_not_closed_but_email_match_is_fine(self):
        # De-confliction is by conversation ID only, never email: C1 is owned
        # and dropped; C2 shares the same customer email and still closes.
        owned = {"C1"}
        self.assertFalse(self.eligible(old_eligible("C1", "same@x.com"), owned))
        self.assertTrue(self.eligible(old_eligible("C2", "same@x.com"), owned))


class MaskEmail(unittest.TestCase):
    def test_masks_local_and_domain(self):
        self.assertEqual(d.mask_email("joe@example.com"), "j***@***")

    def test_empty_email(self):
        self.assertEqual(d.mask_email(""), "no email")


class SiblingState(unittest.TestCase):
    def test_missing_files_mean_no_ownership(self):
        paths = {"close-resolved": ("/nonexistent/nope.jsonl", "jsonl"),
                 "resolve-notify": ("/nonexistent/nope.json", "json")}
        owned = d.owned_ids_by_source(paths)
        self.assertEqual(owned, {"close-resolved": set(), "resolve-notify": set()})

    def test_corrupt_sibling_source_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = os.path.join(tmp, "shadow.jsonl")
            with open(bad, "w") as f:
                f.write('{"id": "C1"}\nnot json at all\n')
            with self.assertRaises(d.SiblingStateUnreadable):
                d.owned_ids_by_source({"close-resolved": (bad, "jsonl")})

    def test_all_id_key_variants_are_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "shadow.jsonl")
            with open(log, "w") as f:
                f.write('{"id": "C1"}\n{"conv_id": "C2"}\n{"conversation_id": "C3"}\n')
            owned = d.owned_ids_by_source({"x": (log, "jsonl")})
            self.assertEqual(owned["x"], {"C1", "C2", "C3"})


@contextlib.contextmanager
def _env(extra):
    with mock.patch.dict(os.environ, extra, clear=False):
        yield


def _run_main(argv, convs, tmp, close_mock=None, extra_env=None):
    """Run d.main(argv) with the network stubbed out and every state path
    pointed into tmp. Returns (exit_code, close_mock, stdout)."""
    close_mock = close_mock if close_mock is not None else mock.Mock(
        return_value={"state": "closed"})
    env = {
        "MUSOAI_INTERCOM_TOKEN": "tok",
        "CLOSE_STALE_SHADOW_LOG": os.path.join(tmp, "close-stale-shadow.jsonl"),
        "CLOSE_STALE_REVIEW_DIR": os.path.join(tmp, "review"),
        "CLOSE_SHADOW_LOG": os.path.join(tmp, "close-resolved-shadow.jsonl"),
        "RESOLVE_NOTIFY_STATE": os.path.join(tmp, "notified.json"),
        "RESOLUTION_STATE_PATH": os.path.join(tmp, "rm-state.json"),
        "RESOLUTION_SHADOW_LOG": os.path.join(tmp, "rm-shadow.jsonl"),
        "OVERDUE_NOTIFY_STATE": os.path.join(tmp, "overdue.json"),
        "CLOSE_DUP_SHADOW_LOG": os.path.join(tmp, "close-dup-shadow.jsonl"),
        "CLOSE_DUP_POINTER_STATE": os.path.join(tmp, "pointer.json"),
        "DEDUP_SHADOW_LOG": os.path.join(tmp, "dedup-shadow.jsonl"),
        "OPS_DRAIN_STATE": os.path.join(tmp, "acted.json"),
        "OPS_DRAIN_SHADOW_LOG": os.path.join(tmp, "ops-drain-shadow.jsonl"),
    }
    env.update(extra_env or {})
    out = io.StringIO()
    with _env(env), \
            mock.patch.object(d, "fetch_open_convs", return_value=convs), \
            mock.patch.object(d, "close_conversation", close_mock), \
            mock.patch.object(d, "post_slack_summary", mock.Mock(return_value=True)), \
            contextlib.redirect_stdout(out):
        code = d.main(argv)
    return code, close_mock, out.getvalue()


class DryRun(unittest.TestCase):
    def test_dry_run_makes_zero_writes_and_masked_export(self):
        with tempfile.TemporaryDirectory() as tmp:
            convs = [old_eligible("C1", "alice@example.com"),
                     conv("C2", "bob@x.com", lar=0, lcr=0, created_at=NOW - 90 * DAY)]
            code, close_mock, stdout = _run_main([], convs, tmp)
            self.assertEqual(code, 0)
            close_mock.assert_not_called()
            # no shadow log on dry-run
            self.assertFalse(os.path.exists(
                os.path.join(tmp, "close-stale-shadow.jsonl")))
            # masked review export exists, 0600, and never leaks a raw email
            review_dir = os.path.join(tmp, "review")
            files = os.listdir(review_dir)
            self.assertEqual(len(files), 1)
            path = os.path.join(review_dir, files[0])
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            with open(path) as f:
                raw = f.read()
            doc = json.loads(raw)
            self.assertEqual(doc["total"], 1)
            self.assertEqual(
                doc["candidates"][0]["conversation_id"], "C1")
            self.assertNotIn("alice@example.com", raw)
            self.assertIn("a***@***", raw)

    def test_dry_run_ok_even_over_ceiling(self):
        # The ceiling gates --apply only; a dry-run on a huge backlog must
        # still succeed and export the full list for review.
        with tempfile.TemporaryDirectory() as tmp:
            convs = [old_eligible(f"C{i}") for i in range(5)]
            code, close_mock, _ = _run_main(
                ["--ceiling", "2"], convs, tmp)
            self.assertEqual(code, 0)
            close_mock.assert_not_called()


class Apply(unittest.TestCase):
    def test_apply_closes_eligible_and_shadow_logs(self):
        with tempfile.TemporaryDirectory() as tmp:
            convs = [old_eligible("C1", "alice@example.com"),
                     conv("C2", lcr=NOW - DAY, lar=NOW - 2 * DAY,
                          created_at=NOW - 3 * DAY)]
            code, close_mock, _ = _run_main(["--apply"], convs, tmp)
            self.assertEqual(code, 0)
            self.assertEqual(close_mock.call_count, 1)
            self.assertEqual(close_mock.call_args[0][2], "C1")
            with open(os.path.join(tmp, "close-stale-shadow.jsonl")) as f:
                recs = [json.loads(line) for line in f]
            self.assertEqual(len(recs), 1)
            # "id" key on purpose: sibling readers de-conflict on id/conv_id.
            self.assertEqual(recs[0]["id"], "C1")
            self.assertEqual(recs[0]["email"], "alice@example.com")
            self.assertIn("closed_at", recs[0])
            self.assertIn("new_state", recs[0])

    def test_apply_respects_limit(self):
        with tempfile.TemporaryDirectory() as tmp:
            convs = [old_eligible(f"C{i}") for i in range(5)]
            code, close_mock, _ = _run_main(
                ["--apply", "--limit", "2"], convs, tmp)
            self.assertEqual(code, 0)
            self.assertEqual(close_mock.call_count, 2)

    def test_apply_over_ceiling_closes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            convs = [old_eligible(f"C{i}") for i in range(3)]
            code, close_mock, _ = _run_main(
                ["--apply", "--ceiling", "2"], convs, tmp)
            self.assertEqual(code, 2)
            close_mock.assert_not_called()

    def test_apply_ceiling_override_allows_supervised_drain(self):
        with tempfile.TemporaryDirectory() as tmp:
            convs = [old_eligible(f"C{i}") for i in range(3)]
            code, close_mock, _ = _run_main(
                ["--apply", "--ceiling", "10"], convs, tmp)
            self.assertEqual(code, 0)
            self.assertEqual(close_mock.call_count, 3)

    def test_apply_limit_within_ceiling_still_blocked_when_backlog_over(self):
        # The ceiling is a sanity check on the CANDIDATE count (grouping bug /
        # backlog surprise detector), not on the closes attempted — --limit
        # does not sneak an over-ceiling backlog past it.
        with tempfile.TemporaryDirectory() as tmp:
            convs = [old_eligible(f"C{i}") for i in range(3)]
            code, close_mock, _ = _run_main(
                ["--apply", "--ceiling", "2", "--limit", "1"], convs, tmp)
            self.assertEqual(code, 2)
            close_mock.assert_not_called()

    def test_close_failure_exits_3_but_others_still_close(self):
        with tempfile.TemporaryDirectory() as tmp:
            calls = {"n": 0}

            def flaky(token, admin_id, cid):
                calls["n"] += 1
                if cid == "C1":
                    raise ValueError("boom")
                return {"state": "closed"}

            convs = [old_eligible("C1"), old_eligible("C2")]
            code, _, _ = _run_main(
                ["--apply"], convs, tmp, close_mock=flaky)
            self.assertEqual(code, 3)
            self.assertEqual(calls["n"], 2)
            with open(os.path.join(tmp, "close-stale-shadow.jsonl")) as f:
                recs = [json.loads(line) for line in f]
            self.assertEqual([r["id"] for r in recs], ["C2"])

    def test_apply_hard_stops_when_shadow_log_unopenable(self):
        # open_shadow_log has a /tmp fallback, so force BOTH paths to fail by
        # stubbing it out entirely — an unrecordable close must never happen.
        with tempfile.TemporaryDirectory() as tmp:
            convs = [old_eligible("C1")]
            with mock.patch.object(d, "open_shadow_log",
                                   return_value=(None, None)):
                code, close_mock, _ = _run_main(["--apply"], convs, tmp)
            self.assertEqual(code, 1)
            close_mock.assert_not_called()

    def test_sibling_owned_conversation_never_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "close-dup-shadow.jsonl"), "w") as f:
                f.write(json.dumps({"id": "C1", "kept_id": "K1"}) + "\n")
            convs = [old_eligible("C1"), old_eligible("C2")]
            code, close_mock, _ = _run_main(["--apply"], convs, tmp)
            self.assertEqual(code, 0)
            self.assertEqual(close_mock.call_count, 1)
            self.assertEqual(close_mock.call_args[0][2], "C2")

    def test_own_shadow_log_is_idempotency_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "close-stale-shadow.jsonl"), "w") as f:
                f.write(json.dumps({"id": "C1", "closed_at": NOW}) + "\n")
            convs = [old_eligible("C1"), old_eligible("C2")]
            code, close_mock, _ = _run_main(["--apply"], convs, tmp)
            self.assertEqual(code, 0)
            self.assertEqual(close_mock.call_count, 1)
            self.assertEqual(close_mock.call_args[0][2], "C2")

    def test_transport_error_lands_in_fail_not_crash(self):
        # RemoteDisconnected/ConnectionResetError escape urllib's URLError
        # wrapping — a mid-drain blip must fail that one close, not the run.
        with tempfile.TemporaryDirectory() as tmp:
            def reset(token, admin_id, cid):
                if cid == "C1":
                    raise ConnectionResetError("Connection reset by peer")
                return {"state": "closed"}

            convs = [old_eligible("C1"), old_eligible("C2")]
            code, _, _ = _run_main(["--apply"], convs, tmp, close_mock=reset)
            self.assertEqual(code, 3)
            with open(os.path.join(tmp, "close-stale-shadow.jsonl")) as f:
                recs = [json.loads(line) for line in f]
            self.assertEqual([r["id"] for r in recs], ["C2"])

    def test_negative_limit_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            convs = [old_eligible("C1")]
            code, close_mock, _ = _run_main(
                ["--apply", "--limit", "-25"], convs, tmp)
            self.assertEqual(code, 1)
            close_mock.assert_not_called()

    def test_unknown_source_kind_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "whatever.jsonl")
            with open(path, "w") as f:
                f.write('{"id": "C1"}\n')
            with self.assertRaises(d.SiblingStateUnreadable):
                d.owned_ids_by_source({"x": (path, "jsonl-ops-drain")})

    def test_dry_run_exits_nonzero_when_export_lost(self):
        with tempfile.TemporaryDirectory() as tmp:
            convs = [old_eligible("C1")]
            with mock.patch.object(d, "write_review_export", return_value=None):
                code, close_mock, _ = _run_main([], convs, tmp)
            self.assertEqual(code, 1)
            close_mock.assert_not_called()

    def test_corrupt_sibling_state_fails_run_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "notified.json"), "w") as f:
                f.write("{corrupt")
            convs = [old_eligible("C1")]
            code, close_mock, _ = _run_main(["--apply"], convs, tmp)
            self.assertEqual(code, 4)
            close_mock.assert_not_called()


class EnvGates(unittest.TestCase):
    def test_missing_token_is_usage_error(self):
        env = {k: v for k, v in os.environ.items()
               if k != "MUSOAI_INTERCOM_TOKEN"}
        with mock.patch.dict(os.environ, env, clear=True):
            self.assertEqual(d.main([]), 1)

    def test_bad_stale_days_fails_loud(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, close_mock, _ = _run_main(
                [], [], tmp, extra_env={"STALE_DAYS": "banana"})
            self.assertEqual(code, 1)

    def test_zero_or_negative_stale_days_refused(self):
        # STALE_DAYS=0 would make EVERY we-spoke-last conversation eligible
        # the moment we reply — refuse loudly instead of mass-closing.
        with tempfile.TemporaryDirectory() as tmp:
            code, _, _ = _run_main([], [], tmp, extra_env={"STALE_DAYS": "0"})
            self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
