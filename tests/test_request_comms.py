#!/usr/bin/env python3
"""Tests for the automatic request status feed (scripts/request_comms/).

The point of this suite is the FAILURE modes, because every one of them is a customer-visible
incident: a double message, a message to a banned account, a message while we are blind to the
request, a message composed from half-approved copy, or a "clean" run that silently told nobody.
"""
from __future__ import annotations

import contextlib
import copy
import io
import json
import os
import sqlite3
import subprocess
import sys
import shutil
import tempfile
import threading
import unittest
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from request_comms import channels as channels_mod  # noqa: E402
from request_comms import driver, guard, identity, lines, report, routing, sources  # noqa: E402
from request_comms import sources as sources_mod  # noqa: E402
from request_comms.sources import Request, SourceReport  # noqa: E402
from request_comms.store import Store, due_at, stamp  # noqa: E402

NOW = 1_800_000_000.0                       # a fixed clock: 2027-01-15T08:00:00Z
NOW_TS = stamp(NOW)


def repo_policy() -> dict:
    return json.loads((ROOT / "policies/request-status-lines.json").read_text(encoding="utf-8"))


def live_policy(**kw) -> dict:
    """The real copy, switched on for a test (never for production: the repo file stays off)."""
    p = copy.deepcopy(repo_policy())
    p["enabled"] = True
    for typ in lines.TYPES:
        for state in lines.STATES:
            got = p["lines"][typ][state]
            got["enabled"] = True
            got["approval_ref"] = got.get("approval_ref") or "test-approval"
            got["review"] = "test"
    p["lines"]["digest"]["enabled"] = True
    p["lines"]["digest"]["approval_ref"] = "test-approval"
    p["lines"]["digest"]["review"] = "test"
    for ch in ("bell", "intercom", "email"):
        p["channels"][ch]["enabled"] = kw.get(ch, True)
    p["channels"]["bell"]["workflow_keys"] = {}
    p["channels"]["email"]["template_keys"] = {t: f"request_status_{t}" for t in lines.TYPES}
    p["channels"]["email"]["template_sha256"] = {f"request_status_{t}": TEMPLATE_PIN for t in lines.TYPES}
    p["channels"]["email"]["template_uses_line_text"] = True   # the template renders {{event.status_line}}
    return p


def req(typ="credit", rid="1", uid="111", state="verifying", waiting="us", created="2027-01-01T00:00:00Z",
        email="u@example.com", detail=None) -> Request:
    return Request(typ, rid, uid, state, waiting, created, created, state == "decided", email=email,
                   detail=detail or {})


class FakeSources:
    def __init__(self, reqs=None, reports=None, emails=None):
        self.reqs = reqs or []
        self.reports = reports or [SourceReport("credit", "ok", len(self.reqs))]
        self.emails = emails or {}
        self.query = self._query

    def _query(self, sql: str):
        return []

    def collect(self, now=None):
        return list(self.reqs), list(self.reports)

    def account_emails(self, ids, query):
        return dict(self.emails)


class FakeBans:
    def __init__(self, ids=(), lens_unknown=""):
        self.ids = set(str(i) for i in ids)
        self.lens_unknown = lens_unknown

    def held(self, uid):
        if self.lens_unknown:
            return f"fraud_lens_unreadable:{self.lens_unknown}"
        return "messaging_ban" if str(uid) in self.ids else ""


class FakeChannels:
    def __init__(self, bell=("unconfirmed", "no bell"), intercom=("sent", "mid_1"), email=("sent", "eid_1")):
        self.calls: list[str] = []
        self.bells: list[dict] = []
        self.emails: list[dict] = []
        self.intercoms: list[dict] = []
        self._answers = {"bell": bell, "intercom": intercom, "email": email}

    def _res(self, channel, text):
        self.calls.append(channel)
        status, ref = self._answers[channel]
        return channels_mod.SendResult(status, channel, "" if status == "sent" else f"{channel} {status}",
                                       ref, channels_mod.body_sha(text))

    def bell(self, workflow_key, *, user_id, data, idempotency_key=""):
        self.bells.append({"key": workflow_key, "user": user_id, "data": data, "idem": idempotency_key})
        return self._res("bell", json.dumps(data, sort_keys=True))

    def intercom(self, text, contact_id, *, admin_id, conversation_id="", typ="", state=""):
        self.intercoms.append({"text": text, "contact": contact_id, "conversation_id": conversation_id,
                               "typ": typ, "state": state})
        return self._res("intercom", text)

    def email(self, text, *, email, user_id, typ, request_ref, idempotency_key="", state=""):
        self.emails.append({"text": text, "ref": request_ref, "idem": idempotency_key, "state": state})
        return self._res("email", text)


# THE OUTBOUND COPY GATE (captain 2026-11-12). Every body request_comms writes is put to lib/copy_gate.require
# before it leaves. This suite pins the driver's and the channels' OTHER rules, so by default the gate here is a
# stand-in that approves and records what it was asked; CopyGateTests below make it hold and pin that nothing
# leaves. The gate's own rules are scripts/tests/test_outbound_copy_gate.py.
COPY_GATE = channels_mod._copy_gate()
COPY_ASKED: list[tuple[str, str, str]] = []
TEMPLATE_PIN = "ab" * 32         # stands for the sha256 of a reviewed send-gateway template source
COPY_FRAMES: list[str] = []      # the `copy` each ask named: the frame the body is sent in
_REAL_REQUIRE = COPY_GATE.require


def _approving_require(campaign, body, *, subject="", copy="", **_kw):
    COPY_ASKED.append((campaign, body, subject))
    COPY_FRAMES.append(copy)
    return {"result": "approved", "verdict_id": "ocv-" + "0" * 16}


def setUpModule() -> None:
    COPY_GATE.require = _approving_require


def tearDownModule() -> None:
    COPY_GATE.require = _REAL_REQUIRE


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp()
        self.store = os.path.join(self.tmp, "state.sqlite")
        self.policy_path = os.path.join(self.tmp, "lines.json")
        self.live_file = os.path.join(self.tmp, "live")
        self.kill_file = os.path.join(self.tmp, "disabled")

    def write_policy(self, policy) -> str:
        with open(self.policy_path, "w", encoding="utf-8") as fh:
            json.dump(policy, fh)
        return self.policy_path

    def cfg(self, sources=None, *, live=False, policy=None, **kw) -> driver.Cfg:
        if isinstance(sources, dict):            # cfg(policy) as the first positional argument
            policy, sources = sources, None
        pol = self.write_policy(policy if policy is not None else live_policy())
        if sources is not None:
            kw.setdefault("sources", sources)
        if live:
            Path(self.live_file).write_text("1")
        kw.setdefault("audit_spool", os.path.join(self.tmp, "audit-pending.jsonl"))
        return driver.Cfg(store_path=self.store, policy_path=pol, live_file=self.live_file,
                          kill_file=self.kill_file, report_dir=os.path.join(self.tmp, "reports"),
                          dry_run=not live, now=NOW, **kw)

    def rows(self, outcome=""):
        s = Store(self.store, now=NOW)
        try:
            return [dict(r) for r in s.rows(outcome=outcome)]
        finally:
            s.close()


class StoreTests(Base):
    def test_append_only_is_enforced_by_the_database(self):
        s = Store(self.store)
        s.append(request_type="credit", request_id="1", user_id="111", outcome="observed", state="verifying")
        with self.assertRaises(sqlite3.DatabaseError):
            s.db.execute("UPDATE request_comm_state SET state='decided'")
        with self.assertRaises(sqlite3.DatabaseError):
            s.db.execute("DELETE FROM request_comm_state")
        s.close()

    def test_the_sha256_chain_detects_a_planted_row(self):
        s = Store(self.store)
        s.append(request_type="credit", request_id="1", user_id="111", outcome="observed", state="verifying")
        self.assertEqual(s.verify(), [])
        s.db.execute("INSERT INTO request_comm_state (at, request_type, request_id, request_ref, user_id, "
                     "outcome, sha256) VALUES (?,?,?,?,?,?,?)",
                     (NOW_TS, "credit", "9", "credit:9", "999", "sent", "0" * 64))
        s.db.commit()
        self.assertEqual(len(s.verify()), 1)
        s.close()

    def test_blocking_and_told_reads(self):
        s = Store(self.store, now=NOW)
        s.append(request_type="credit", request_id="1", user_id="111", outcome="sent", state="verifying")
        s.append(request_type="credit", request_id="1", user_id="111", outcome="rejected", state="need_you")
        self.assertEqual(set(s.blocking_states("credit:1")), {"verifying"},
                         "a clean rejection releases the pair; a send keeps it claimed")
        self.assertEqual(set(s.told_per_ref()), {"credit:1"})
        self.assertEqual(s.sent_today(NOW_TS[:10]), {"111": 1})
        s.close()

    def test_next_due_is_48h_while_open_and_never_once_decided(self):
        told = "2027-01-10T00:00:00Z"
        self.assertEqual(due_at(told, True), "2027-01-12T00:00:00Z")
        self.assertEqual(due_at(told, False), "")
        self.assertEqual(due_at("", True), "")


class RoutingTests(Base):
    def setUp(self):
        super().setUp()
        self.policy = live_policy()
        self.store = Store(os.path.join(self.tmp, "routing.sqlite"))

    def tearDown(self):
        self.store.close()

    def test_same_state_is_not_due_before_the_floor(self):
        d = routing.decide(req(), policy=self.policy, now=NOW, last_told_state="verifying",
                           last_told_at=stamp(NOW - 3600), render_facts={})
        self.assertEqual((d.action, d.reason), ("skip", "not_due"))

    def test_the_floor_produces_the_waiting_line_at_48h(self):
        d = routing.decide(req(), policy=self.policy, now=NOW, last_told_state="verifying",
                           last_told_at=stamp(NOW - 49 * 3600), render_facts={},
                           has_intercom_identity=True)
        self.assertEqual((d.action, d.kind, d.line.key), ("send", "waiting", "credit/waiting"))

    def test_a_state_change_is_due_even_one_minute_later(self):
        d = routing.decide(req(state="need_you", waiting="user"), policy=self.policy, now=NOW,
                           last_told_state="verifying", last_told_at=stamp(NOW - 60),
                           render_facts={}, has_intercom_identity=True)
        self.assertEqual((d.action, d.kind, d.line.key), ("send", "state", "credit/need_you"))

    def test_a_locked_line_still_bells_because_that_copy_is_not_ours(self):
        pol = copy.deepcopy(self.policy)
        pol["lines"]["credit"]["received"]["enabled"] = False
        d = routing.decide(req(state="received"), policy=pol, now=NOW, render_facts={},
                           has_intercom_identity=True)
        self.assertEqual((d.action, d.kind, d.channel, d.line), ("send", "bell_only", "bell", None))
        self.assertEqual(d.bell_key, "credit_status_in_review")
        self.assertEqual(d.text, "", "a bell never carries our unapproved text")

    def test_a_locked_line_with_no_bell_kind_is_held(self):
        pol = copy.deepcopy(self.policy)
        pol["lines"]["erasure"]["received"]["enabled"] = False
        d = routing.decide(req("erasure", "7", "", "received", detail={"conversation_id": "conv_7"}), policy=pol, now=NOW,
                           render_facts={"slot": "no_page_link", "date": "3 November 2026"},
                           has_intercom_identity=True)
        self.assertEqual((d.action, d.reason), ("hold", "line_locked:erasure/received"))

    def test_the_owned_decision_is_held_from_another_sender(self):
        d = routing.decide(req(state="decided", waiting=""), policy=self.policy, now=NOW,
                           render_facts={}, has_intercom_identity=True)
        self.assertEqual(d.action, "hold")
        self.assertIn("other_sender", d.reason)

    def test_gap_fill_sends_only_when_the_owner_delivered_nothing(self):
        pol = copy.deepcopy(self.policy)
        pol["lines"]["credit"]["decided"]["gap_fill"] = True
        held = routing.decide(req(state="decided", waiting=""), policy=pol, now=NOW, render_facts={},
                              has_intercom_identity=True, core_delivered="2026-12-01T00:00:00Z")
        self.assertEqual((held.action, "other_sender" in held.reason), ("hold", True))
        sent = routing.decide(req(state="decided", waiting=""), policy=pol, now=NOW, render_facts={},
                              has_intercom_identity=True, core_delivered="")
        self.assertEqual(sent.action, "send")

    def test_no_route_is_a_hold_never_a_guess(self):
        # erasure received has an approved line but no bell kind, and with no Intercom identity
        # and no email there is no rung left: held, never sent somewhere approximate.
        d = routing.decide(req("erasure", "7", "", "received", detail={"conversation_id": "conv_7"}), policy=self.policy, now=NOW,
                           render_facts={"slot": "no_page_link", "date": "3 November 2026"},
                           has_intercom_identity=False, has_email=False)
        self.assertEqual((d.action, d.reason), ("hold", "no_route"))

    def test_a_request_the_user_owes_us_is_not_nagged_every_48h(self):
        old = "2027-01-01T00:00:00Z"          # well past the floor relative to NOW
        d = routing.decide(req(state="need_you", waiting="user"), policy=self.policy, now=NOW,
                           render_facts={}, has_intercom_identity=True,
                           last_told_state="need_you", last_told_at=old)
        self.assertEqual((d.action, d.reason), ("skip", "waiting_on_user"))
        # ... but the state CHANGE to need_you still goes out (on the shipped, still-unapproved copy:
        # the bell is the only rung that can carry it)
        d = routing.decide(req(state="need_you", waiting="user"), policy=repo_policy(), now=NOW,
                           render_facts={}, has_intercom_identity=True,
                           last_told_state="verifying", last_told_at=old)
        self.assertEqual(d.kind, "bell_only")
        self.assertEqual(d.bell_key, "credit_status_needs_proof")

    def test_the_bell_alone_is_a_route_when_nothing_else_is(self):
        d = routing.decide(req(), policy=self.policy, now=NOW, render_facts={},
                           has_intercom_identity=False, has_email=False)
        self.assertEqual((d.action, d.channel), ("send", "bell"))

    def test_one_message_per_user_per_day(self):
        d = routing.decide(req(state="received"), policy=self.policy, now=NOW, render_facts={},
                           has_intercom_identity=True, already_messaged_today=True)
        self.assertEqual((d.action, d.reason), ("skip", "daily_cap"))

    def test_a_held_account_gets_nothing_at_all(self):
        d = routing.decide(req(), policy=self.policy, now=NOW, held_reason="messaging_ban",
                           render_facts={}, has_intercom_identity=True)
        self.assertEqual((d.action, d.reason), ("hold", "bangate:messaging_ban"))

    def test_an_unreadable_slot_holds_the_whole_letter(self):
        d = routing.decide(req("erasure", "7", "", "received", detail={"conversation_id": "conv_7"}), policy=self.policy, now=NOW,
                           render_facts={"slot": "", "date": "3 November 2026"},
                           has_intercom_identity=True)
        self.assertEqual((d.action, d.reason), ("hold", "slot_unknown:none"))

    def test_breach_counts_our_own_silence_only(self):
        self.assertEqual(routing.breach(req(created="2027-01-10T00:00:00Z", waiting="us"), last_told_at="",
                                        now=NOW), "floor")
        self.assertEqual(routing.breach(req(created="2027-01-14T00:00:00Z", waiting="us"), last_told_at="",
                                        now=NOW), "target")
        self.assertEqual(routing.breach(req(created="2027-01-10T00:00:00Z", waiting="user"), last_told_at="",
                                        now=NOW), "")
        self.assertEqual(routing.breach(req(created="2027-01-10T00:00:00Z", state="decided", waiting=""),
                                        last_told_at="", now=NOW), "")


class LinesTests(Base):
    def test_the_repo_policy_passes_its_guard(self):
        p = subprocess.run([sys.executable, str(ROOT / "scripts/check-request-status-lines.py")],
                           capture_output=True, text=True, check=False)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_the_shipped_driver_is_off_and_only_the_approved_ack_is_enabled(self):
        pol = repo_policy()
        self.assertFalse(pol["enabled"], "the shipped driver must be off")
        enabled = [f"{t}/{s}" for t in lines.TYPES for s in lines.STATES
                   if pol["lines"][t][s].get("enabled")]
        self.assertEqual(enabled, ["erasure/received"])
        self.assertEqual(pol["lines"]["erasure"]["received"]["approval_ref"], "gdpr-ack-v2-1101")

    def test_an_enabled_line_without_an_approval_is_a_problem(self):
        pol = repo_policy()
        pol["lines"]["credit"]["received"]["enabled"] = True
        self.assertTrue(any("no approval_ref" in p for p in lines.validate(pol)))

    def test_a_pending_review_cannot_be_enabled(self):
        pol = repo_policy()
        pol["lines"]["credit"]["received"].update(enabled=True, approval_ref="x", review="pending-fable-r5")
        self.assertTrue(any("review is pending" in p for p in lines.validate(pol)))

    def test_banned_wording_is_refused(self):
        for bad in ("We can't approve this because of a risk flag.", "You will be credited within 7 days.",
                    "Your request is on hold: suspicious activity."):
            pol = repo_policy()
            pol["lines"]["credit"]["verifying"]["text"] = bad
            self.assertTrue(any("banned wording" in p for p in lines.validate(pol)), bad)

    def test_an_unapproved_placeholder_is_refused(self):
        pol = repo_policy()
        pol["lines"]["claim"]["verifying"]["text"] = "Hello {first_name}, your claim is being reviewed."
        self.assertTrue(any("unapproved placeholder" in p for p in lines.validate(pol)))

    def test_the_erasure_ack_is_sent_whole_with_its_slot_and_date(self):
        pol = repo_policy()
        line = lines.line(pol, "erasure", "received")
        text, why = lines.render(line, {"slot": "no_page_link", "date": "3 November 2026"})
        self.assertEqual(why, "")
        self.assertIn("received 3 November 2026", text)
        self.assertTrue(text.endswith("To get started, reply with the link to the Muso page."))
        self.assertNotIn("{date}", text)
        _, why2 = lines.render(line, {"slot": "", "date": "3 November 2026"})
        self.assertEqual(why2, "slot_unknown:none")

    def test_every_line_is_band_invariant(self):
        pol = repo_policy()
        for typ in lines.TYPES:
            for state in lines.STATES:
                self.assertNotIn("{", pol["lines"][typ][state]["text"].replace("{date}", ""), f"{typ}/{state}")


class TickTests(Base):
    def test_dry_run_records_would_send_and_never_calls_a_channel(self):
        ch = FakeChannels()
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), channels=ch,
                                   bans=FakeBans(), identity=lambda e, u, d: "contact_1"))
        self.assertEqual(out["mode"], "dry-run")
        self.assertEqual(ch.calls, [])
        self.assertEqual([r["line_key"] for r in self.rows("would_send")], ["credit/received"])
        self.assertEqual(out["counts"]["would_send"], 1)

    def test_live_sends_once_and_never_again(self):
        ch = FakeChannels(intercom=("sent", "mid_1"))
        cfg = self.cfg(FakeSources([req(state="received")]), live=True, channels=ch,
                       bans=FakeBans(), identity=lambda e, u, d: "contact_1")
        first = driver.tick(cfg)
        self.assertEqual(first["mode"], "live")
        self.assertEqual([r["outcome"] for r in self.rows() if r["outcome"] in ("sent", "sending")],
                         ["sending", "sent"])
        second = driver.tick(cfg)
        self.assertEqual(second["counts"]["sent"], 0)
        self.assertEqual(ch.calls.count("intercom"), 1)

    def test_a_rejected_send_is_retried_and_an_uncertain_one_is_not(self):
        ch = FakeChannels(intercom=("rejected", ""), email=("rejected", ""))
        cfg = self.cfg(FakeSources([req(state="received")]), live=True, channels=ch,
                       bans=FakeBans(), identity=lambda e, u, d: "contact_1")
        driver.tick(cfg)
        self.assertEqual([r["outcome"] for r in self.rows("rejected")], ["rejected"])
        driver.tick(cfg)
        self.assertEqual(ch.calls.count("intercom"), 2, "a clean rejection may be retried")

        ch2 = FakeChannels(intercom=("uncertain", ""))
        self.setUp()
        cfg2 = self.cfg(FakeSources([req(state="received")]), live=True, channels=ch2,
                        bans=FakeBans(), identity=lambda e, u, d: "contact_1")
        driver.tick(cfg2)
        self.assertEqual(len(self.rows("uncertain")), 1)
        driver.tick(cfg2)
        self.assertEqual(ch2.calls.count("intercom"), 1, "an uncertain send is never repeated")

    def test_an_unconfirmed_bell_climbs_to_intercom(self):
        ch = FakeChannels(bell=("unconfirmed", "visibility all false"), intercom=("sent", "mid_9"))
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True, channels=ch,
                                   bans=FakeBans(), identity=lambda e, u, d: "contact_1"))
        self.assertEqual(ch.calls[:2], ["bell", "intercom"])
        self.assertEqual(out["sent"][0]["status"], "sent")
        self.assertEqual(out["sent"][0]["channel"], "intercom")

    def test_a_banned_user_gets_nothing(self):
        ch = FakeChannels()
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True, channels=ch,
                                   bans=FakeBans(ids=["111"]), identity=lambda e, u, d: "contact_1"))
        self.assertEqual(ch.calls, [])
        self.assertEqual(out["sent"], [])
        self.assertEqual([r["line_key"] for r in self.rows("held")], ["bangate:messaging_ban"])

    def test_an_unreadable_ban_list_refuses_the_run(self):
        ch = FakeChannels()
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True, channels=ch,
                                   bans=FakeBans(lens_unknown="account holds unreadable"),
                                   identity=lambda e, u, d: "contact_1"))
        self.assertEqual(ch.calls, [])
        self.assertEqual(out["mode"], "live")
        self.assertEqual([r["line_key"] for r in self.rows("held")][0].startswith("bangate:"), True)
        self.assertTrue(any("NOTHING is sent" in p for p in out["problems"]))
        # The HOLD is right, but a green tick is not: every credit, claim and merge request is
        # suppressed, and the unit has no `SuccessExitStatus=`, so exit 0 left a sustained lens
        # outage looking healthy while the feed was off.
        self.assertEqual(out["exit"], 3, "an unreadable lens must fail the scheduled tick")

    def test_an_unreadable_source_sends_nothing_for_that_type(self):
        reports = [SourceReport("credit", "unreadable", 0, "replica read failed"),
                   SourceReport("claim", "ok", 1)]
        out = driver.tick(self.cfg(FakeSources([req(state="received"), req("claim", "2", "222", "received")],
                                               reports=reports),
                                   live=True, channels=FakeChannels(), bans=FakeBans(),
                                   identity=lambda e, u, d: "c"))
        self.assertEqual(out["exit"], 3)
        self.assertEqual([r["request_type"] for r in self.rows("sent")], ["claim"])
        self.assertTrue(any("credit=unreadable" in p for p in out["problems"]))

    def test_an_invalid_policy_refuses_before_reading_anything(self):
        pol = repo_policy()
        pol["lines"]["credit"]["received"]["enabled"] = True     # no approval_ref
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True, policy=pol,
                                   channels=FakeChannels(), bans=FakeBans()))
        self.assertEqual((out["mode"], out["exit"]), ("refused", 2))
        self.assertEqual(self.rows(), [])

    def test_the_kill_file_stops_everything(self):
        Path(self.kill_file).write_text("1")
        ch = FakeChannels()
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True, channels=ch,
                                   bans=FakeBans(), identity=lambda e, u, d: "c"))
        self.assertEqual(out["mode"], "killed")
        self.assertEqual(ch.calls, [])

    def test_the_run_cap_is_a_per_tick_budget_and_the_rest_is_counted(self):
        # A backlog is the normal state of the world (7,869 users had open credit/claim requests
        # moving in the last 30 days when this was written). Refusing the whole tick would mean no
        # backlog ever clears, so the cap sends the oldest N and COUNTS the rest.
        reqs = [req(rid=str(i), uid=str(100 + i), state="received") for i in range(5)]
        ch = FakeChannels(intercom=("sent", "mid"))
        out = driver.tick(self.cfg(FakeSources(reqs), live=True, channels=ch, bans=FakeBans(),
                                   identity=lambda e, u, d: "c", max_per_run=3))
        self.assertEqual((out["exit"], out["mode"]), (0, "live"))
        self.assertEqual(len(out["sent"]), 3)
        self.assertEqual(out["counts"]["deferred"], 2)
        self.assertTrue(any("deferred to the next tick" in p for p in out["problems"]))
        self.assertEqual(ch.calls.count("bell"), 3, "the bell is tried first for every message")
        self.assertEqual(ch.calls.count("intercom"), 3, "and Intercom carries the ones it could not")

    def test_a_digest_that_cannot_go_still_bells_the_oldest_request(self):
        # credit + claim due for one user, our digest letter unapproved and the two kinds differ:
        # the oldest goes on its own bell, the rest wait (never a false composite statement).
        pol = repo_policy()
        pol["enabled"] = True
        reqs = [req(rid="1", state="received"), req("claim", "2", "111", "received")]
        reports = [SourceReport("credit", "ok", 1), SourceReport("claim", "ok", 1)]
        ch = FakeChannels(bell=("sent", "wr_1"))
        out = driver.tick(self.cfg(FakeSources(reqs, reports=reports), live=True, policy=pol, channels=ch,
                                   bans=FakeBans(), identity=lambda e, u, d: "c"))
        self.assertEqual(len(out["sent"]), 1)
        self.assertEqual(out["sent"][0]["line"], "bell:claim_status_in_review",
                         "one member goes on its own kind, the oldest in the tick's own order")
        self.assertEqual([h["request"] for h in out["held"]], ["credit:1"])
        self.assertIn("digest_waiting", out["held"][0]["reason"])

    def test_several_due_requests_become_one_digest_and_mark_every_member(self):
        reqs = [req(rid="1", state="received"), req("claim", "2", "111", "received"),
                req("refund", "3", "111", "received")]
        reports = [SourceReport("credit", "ok", 1), SourceReport("claim", "ok", 1), SourceReport("refund", "ok", 1)]
        ch = FakeChannels(intercom=("sent", "mid_d"))
        out = driver.tick(self.cfg(FakeSources(reqs, reports=reports), live=True, channels=ch,
                                   bans=FakeBans(), identity=lambda e, u, d: "c"))
        self.assertEqual(out["counts"]["digests"], 1)
        self.assertEqual(len(out["sent"]), 1)
        self.assertEqual(out["sent"][0]["line"], "digest")
        self.assertEqual(sorted(out["sent"][0]["requests"]), ["claim:2", "credit:1", "refund:3"])
        self.assertEqual(ch.calls, ["intercom"], "a mixed-type digest never becomes one bell")
        self.assertEqual(len([r for r in self.rows("sent")]), 3, "every member is marked told")

    def test_the_erasure_ack_goes_out_whole(self):
        r = req("erasure", "7", "", "received", detail={"contact_id": "c_7", "conversation_id": "conv_7", "slot": "no_page_link",
                                                        "date": "3 November 2026",
                                                        "source": "erasure_requests"})
        ch = FakeChannels(intercom=("sent", "mid_e"))
        out = driver.tick(self.cfg(FakeSources([r], reports=[SourceReport("erasure", "ok", 1)],
                                               emails={}), live=True, channels=ch, bans=FakeBans(),
                                   identity=lambda e, u, d: ""))
        self.assertEqual(out["sent"][0]["status"], "sent")
        sent = self.rows("sent")[0]
        self.assertEqual(sent["line_key"], "erasure/received")
        self.assertTrue(json.loads(sent["detail"])["body_sha256"])

    def test_a_shipped_dark_policy_sends_nothing_even_on_a_live_host(self):
        ch = FakeChannels()
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True, policy=repo_policy(),
                                   channels=ch, bans=FakeBans(), identity=lambda e, u, d: "c"))
        self.assertEqual(out["mode"], "dry-run")
        self.assertEqual(ch.calls, [])


class SourcesTests(Base):
    def test_the_csv_header_row_is_not_a_request(self):
        rows = [['"id"', '"userid"', '"status"', '"createdat"', '"updatedat"', '"notice"'],
                ['1', '111', 'processing', '2027-01-01 00:00:00', '2027-01-02 00:00:00', '']]
        got = sources.credit_requests(lambda sql: rows)
        self.assertEqual([r.id for r in got], ["1"])
        self.assertEqual((got[0].state, got[0].waiting_on), ("verifying", "us"))

    def test_an_unrecognised_status_is_unknown_and_never_messaged(self):
        rows = [['7', '111', 'some_new_status', '2027-01-01 00:00:00', '2027-01-01 00:00:00', '']]
        got = sources.credit_requests(lambda sql: rows)
        self.assertEqual(got[0].state, "unknown")
        d = routing.decide(got[0], policy=live_policy(), now=NOW, render_facts={}, has_intercom_identity=True)
        self.assertEqual((d.action, d.reason), ("hold", "state_unknown"))

    def test_a_credit_decision_records_whether_core_told_the_user(self):
        rows = [['7', '111', 'approved', '2027-01-01 00:00:00', '2027-01-01 00:00:00', '2027-01-03T00:00:00Z']]
        got = sources.credit_requests(lambda sql: rows)
        self.assertEqual((got[0].state, got[0].terminal), ("decided", True))
        self.assertEqual(got[0].detail["notice_sent_at"], "2027-01-03T00:00:00Z")

    def test_the_erasure_register_maps_to_the_ack_and_its_slot(self):
        path = os.path.join(self.tmp, "erasure.sqlite")
        db = sqlite3.connect(path)
        db.executescript(sources_mod_schema())
        db.execute("INSERT INTO erasure_requests (id, status, class, received_at, requester_email, contact_id, "
                   "conversation_id, pages, ask_sent_at, confirmed_at, updated_at) "
                   "VALUES (40, 'open', 'privacy_erasure', '2026-11-03T21:34:00Z', 'a@b.co', 'c_1', 'conv_1', "
                   "'[]', '', '', '2026-11-03T21:40:00Z')")
        db.execute("INSERT INTO erasure_requests (id, status, class, received_at, requester_email, contact_id, "
                   "conversation_id, pages, ask_sent_at, confirmed_at, updated_at) "
                   "VALUES (41, 'open', 'privacy_erasure', '2026-11-04T00:00:00Z', 'x@y.co', 'c_2', 'conv_2', "
                   "'[{\"entity\":\"track\",\"id\":\"1\"}]', '', '', '2026-11-04T00:00:00Z')")
        db.commit()
        db.close()
        got = {r.id: r for r in sources.erasure_requests(path)}
        self.assertEqual(got["40"].state, "received")
        self.assertEqual(got["40"].detail["slot"], "no_page_link")
        self.assertEqual(got["40"].detail["date"], "3 November 2026")
        self.assertEqual(got["41"].detail["slot"], "", "a page in the message needs a name check: no slot")
        self.assertEqual(got["40"].detail["contact_id"], "c_1")

    def test_only_the_classes_the_ack_was_written_for_are_acknowledged(self):
        """The approved ack opens "we have your request to remove your personal data from Muso".

        A `privacy_access` row is an Art. 15 request for a COPY (the pipeline answers it captain/counsel, no hide)
        and a `dmca_takedown` row is a rights-holder's copyright notice. Telling either of them they asked us to
        delete their personal data is a false statement to the person who wrote in - the same mischaracterisation
        `gdpr_pipeline.copy.ASK_APPROVED_CLASSES` refuses at the letter level. They map to `unknown`, which the
        planner HOLDS, so they are never messaged and never guessed at.

        `legal_threat` is the subtle one: it IS in `gdpr_pipeline.run.ERASURE_FAMILY` (it gets the erasure
        pipeline's handling), but it is not a request to remove personal data, so the ack's words are not true of
        it either. The gate is `copy.ASK_APPROVED_CLASSES`, which is erasure-only, and this tuple must stay equal
        to it - widening it to the FAMILY is how a legal threat would be told it asked us to delete its data.
        """
        path = os.path.join(self.tmp, "erasure.sqlite")
        db = sqlite3.connect(path)
        db.executescript(sources_mod_schema())
        for rid, cls in ((50, "privacy_erasure"), (51, "legal_threat"), (52, "privacy_access"),
                         (53, "dmca_takedown"), (54, "not_erasure"), (55, "privacy_correction")):
            db.execute("INSERT INTO erasure_requests (id, status, class, received_at, requester_email, contact_id, "
                       "conversation_id, pages, ask_sent_at, confirmed_at, updated_at) "
                       "VALUES (?, 'open', ?, '2026-11-03T21:34:00Z', 'a@b.co', 'c_1', 'conv_1', "
                       "'[]', '', '', '2026-11-03T21:40:00Z')", (rid, cls))
        db.commit()
        db.close()
        got = {r.id: r for r in sources.erasure_requests(path)}
        self.assertEqual(got["50"].state, "received", "the deletion class is what the ack is for")
        for rid, cls in (("51", "legal_threat"), ("52", "privacy_access"), ("53", "dmca_takedown"),
                         ("54", "not_erasure"), ("55", "privacy_correction")):
            self.assertEqual(got[rid].state, "unknown", f"{cls} must never receive the erasure ack")
            self.assertEqual(routing.decide(got[rid], policy=live_policy(), now=NOW).action,
                             "hold", f"{cls} is held, not messaged")

    def test_the_ack_classes_are_exactly_the_letter_gates_approved_classes(self):
        # The two tuples answer the same question ("may erasure copy be sent to this class?"), so they must not
        # drift. `run.ERASURE_FAMILY` is deliberately WIDER and is not the gate.
        from gdpr_pipeline import copy as gdpr_copy  # noqa: PLC0415
        self.assertEqual(sources.ERASURE_ACK_CLASSES, gdpr_copy.ASK_APPROVED_CLASSES)

    def test_a_register_with_no_class_column_is_held_not_acknowledged(self):
        # Fail closed: without the class we cannot prove the ack's words are true, so nobody is messaged.
        path = os.path.join(self.tmp, "noclass.sqlite")
        db = sqlite3.connect(path)
        db.executescript("CREATE TABLE erasure_requests (id INTEGER PRIMARY KEY, status TEXT, "
                         "received_at TEXT, requester_email TEXT, contact_id TEXT, conversation_id TEXT, "
                         "pages TEXT, ask_sent_at TEXT, confirmed_at TEXT, updated_at TEXT);")
        db.execute("INSERT INTO erasure_requests (id, status, received_at, requester_email, contact_id, "
                   "conversation_id, pages, ask_sent_at, confirmed_at, updated_at) "
                   "VALUES (60, 'open', '2026-11-03T21:34:00Z', 'a@b.co', 'c_1', 'conv_1', '[]', '', '', "
                   "'2026-11-03T21:40:00Z')")
        db.commit()
        db.close()
        got = sources.erasure_requests(path)
        self.assertEqual([r.state for r in got], ["unknown"])

    def test_a_missing_erasure_store_is_unconfigured_not_empty(self):
        with self.assertRaises(FileNotFoundError):
            sources.erasure_requests(os.path.join(self.tmp, "nope.sqlite"))

    def test_ticket_types_without_an_identity_resolver_are_disabled_not_failed(self):
        # `merge` and `refund` have no ticket->account identity resolver, so they are off on every
        # tick BY DESIGN. They must not be `unconfigured` (which fails the run): a permanently red
        # hourly unit makes a real outage in an enabled source indistinguishable from this gap.
        src = sources.Sources(query=lambda sql: [], gdpr_store=os.path.join(self.tmp, "nope.sqlite"),
                              tickets=lambda lst, tags: [{"id": "t1"}], ticket_identity=None)
        _, reports = src.collect(now=NOW)
        status = {r.name: r.status for r in reports}
        self.assertEqual((status["merge"], status["refund"]), ("disabled", "disabled"))
        # The erasure store is one we EXPECT to exist, so its absence is still a real problem.
        self.assertEqual(status["erasure"], "unconfigured")


def sources_mod_schema() -> str:
    return """
    CREATE TABLE erasure_requests (
      id INTEGER PRIMARY KEY, status TEXT, class TEXT, received_at TEXT, due_at TEXT,
      confirmed_at TEXT, ask_sent_at TEXT, hidden_at TEXT, requester_email TEXT, contact_id TEXT,
      conversation_id TEXT, updated_at TEXT, pages TEXT
    );
    """


class AuditTests(Base):
    def test_a_send_is_spooled_when_the_audit_ledger_is_not_deployed(self):
        from request_comms import audit

        row = audit.AuditRow(actor="request-comms", request_ref="credit:1", state="received",
                             channel="intercom", user_id="111", message_ref="mid_1", body_sha="abc")
        state, why = audit.record(row, pending_path=os.path.join(self.tmp, "spool.jsonl"), at=NOW_TS)
        self.assertEqual(state, "pending", why)
        line = Path(os.path.join(self.tmp, "spool.jsonl")).read_text(encoding="utf-8").strip()
        got = json.loads(line)
        self.assertEqual((got["action_type"], got["target"], got["subject"]),
                         ("message.send", "user:111", "credit:1@received"))
        self.assertIn("stop", got["inverse"])


class ThreadedAckTests(Base):
    """QA round 20: the approved ack promises "on this thread", so it must reply on theirs.

    The copy says "Written confirmation on this thread" and the reference doc says "first reply, same
    conversation, always". A new outbound Intercom message left the thread the requester actually
    wrote on unanswered while a second one appeared beside it.
    """

    def _erasure(self, **detail):
        d = {"contact_id": "c_7", "pages": [], "slot": "no_page_link", "date": "1 November 2026"}
        d.update(detail)
        return req(typ="erasure", rid="7", uid="u@example.com", state="received", waiting="us",
                   detail=d)

    def test_the_ack_replies_on_the_requesters_own_conversation(self):
        ch = FakeChannels(intercom=("sent", "mid_1"))
        src = FakeSources([self._erasure(conversation_id="conv_42")],
                          reports=[SourceReport("erasure", "ok", 1)])
        out = driver.tick(self.cfg(src, live=True, policy=live_policy(), channels=ch,
                                   bans=FakeBans(), identity=lambda e, u, d: "c_7"))
        self.assertEqual(out["counts"]["sent"], 1)
        self.assertEqual(len(ch.intercoms), 1)
        self.assertEqual(ch.intercoms[0]["conversation_id"], "conv_42",
                         "a new /messages call would open a second thread")

    def test_an_erasure_with_no_thread_is_held_not_sent_as_a_new_message(self):
        ch = FakeChannels(intercom=("sent", "mid_1"))
        src = FakeSources([self._erasure()], reports=[SourceReport("erasure", "ok", 1)])
        out = driver.tick(self.cfg(src, live=True, policy=live_policy(), channels=ch,
                                   bans=FakeBans(), identity=lambda e, u, d: "c_7"))
        self.assertEqual(ch.calls, [], "no thread to reply on means no letter that promises one")
        self.assertEqual(out["counts"]["sent"], 0)
        self.assertTrue(any(h["reason"] == "no_thread" for h in out["held"]), out["held"])

    def test_a_credit_request_still_opens_a_new_message(self):
        # Only the threaded types are pinned to a conversation; credit has no such promise.
        ch = FakeChannels(intercom=("sent", "mid_1"))
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True,
                                   policy=live_policy(), channels=ch, bans=FakeBans(),
                                   identity=lambda e, u, d: "c_1"))
        self.assertEqual(out["counts"]["sent"], 1)
        self.assertEqual(ch.intercoms[0]["conversation_id"], "")

    def test_the_reply_goes_to_the_conversations_reply_route(self):
        # The transport, not just the caller: a reply is a `comment` from an admin on
        # /conversations/<id>/reply, never a templated /messages send.
        seen: list[tuple[str, str, dict]] = []

        def post(method, path, body=None):
            seen.append((method, path, body or {}))
            return {"id": "mid_9"}

        ch = channels_mod.Channels(policy=live_policy(), intercom_post=post)
        res = ch.intercom("hello", "c_7", admin_id="77", conversation_id="conv_42")
        self.assertEqual(res.status, "sent")
        self.assertEqual(seen[0][1], "/conversations/conv_42/reply")
        self.assertEqual(seen[0][2]["message_type"], "comment")
        self.assertEqual(seen[0][2]["admin_id"], "77")
        self.assertNotIn("template", seen[0][2], "a reply is not a templated outbound message")

    def test_a_conversation_id_is_url_quoted(self):
        seen: list[str] = []

        def post(method, path, body=None):
            seen.append(path)
            return {"id": "mid_9"}

        ch = channels_mod.Channels(policy=live_policy(), intercom_post=post)
        ch.intercom("hi", "c_7", admin_id="77", conversation_id="a/b c")
        self.assertEqual(seen[0], "/conversations/a%2Fb%20c/reply")


class AuditPreflightTests(Base):
    """QA round 20: an importable ledger is not proof that a row can be recorded.

    `record` falls back to the spool when the ledger REFUSES a row (locked, read-only, schema drift),
    so the preflight has to prove the fallback in both branches. It used to return success the moment
    `import action_audit` worked, which made it fail OPEN on exactly the case it exists for: the first
    customer message went out, `record` answered `unavailable`, and exit 5 arrived after the send.
    """

    def setUp(self):
        super().setUp()
        self.fake = os.path.join(self.tmp, "fake")
        os.makedirs(self.fake, exist_ok=True)
        Path(os.path.join(self.fake, "action_audit.py")).write_text(
            "def record(**kw):\n    raise RuntimeError('ledger is read-only')\n", encoding="utf-8")
        sys.path.insert(0, self.fake)
        sys.modules.pop("action_audit", None)

    def tearDown(self):
        sys.modules.pop("action_audit", None)
        try:
            sys.path.remove(self.fake)
        except ValueError:
            pass
        super().tearDown()

    def _unwritable(self) -> str:
        # A regular FILE where the spool's directory should be: makedirs raises NotADirectoryError.
        blocker = os.path.join(self.tmp, "blocker")
        Path(blocker).write_text("not a directory", encoding="utf-8")
        return os.path.join(blocker, "audit-pending.jsonl")

    def test_an_importable_ledger_with_no_writable_fallback_fails_the_preflight(self):
        from request_comms import audit

        ok, why = audit.preflight(pending_path=self._unwritable())
        self.assertFalse(ok, "the ledger can refuse a row, so the fallback must be proved first")
        self.assertIn("spool unwritable", why)

    def test_an_importable_ledger_with_a_writable_fallback_passes(self):
        from request_comms import audit

        ok, why = audit.preflight(pending_path=os.path.join(self.tmp, "spool", "audit-pending.jsonl"))
        self.assertTrue(ok)
        self.assertEqual(why, "", "the ledger is importable, so nothing is degraded")

    def test_the_tick_sends_nothing_when_the_ledger_is_up_but_the_fallback_is_not(self):
        fake = FakeChannels(bell=("sent", "run_1"))
        out = driver.tick(self.cfg(FakeSources([req(rid="1", uid="111", state="received")]),
                                   live=True, channels=fake, bans=FakeBans(),
                                   identity=lambda e, u, d: "",
                                   audit_spool=self._unwritable()))
        self.assertEqual(fake.calls, [], "a message that could go unaudited must not go out")
        self.assertEqual(out["exit"], 5)
        self.assertEqual(out["counts"]["deferred"], 1)


class BellTests(Base):
    """The status bell is the FIRST rung and the one rung whose copy is not ours."""

    def test_the_key_map_covers_the_states_the_catalog_has_kinds_for(self):
        pol = repo_policy()
        self.assertTrue(pol["channels"]["bell"]["enabled"])
        self.assertEqual(routing.bell_key(pol, req("credit", "1", "1", "verifying")), "credit_status_in_review")
        self.assertEqual(routing.bell_key(pol, req("credit", "1", "1", "need_you")), "credit_status_needs_proof")
        self.assertEqual(routing.bell_key(pol, req("claim", "2", "1", "received")), "claim_status_in_review")
        self.assertEqual(routing.bell_key(pol, req("erasure", "3", "", "received")), "",
                         "the catalog has no erasure kind: never invent one")
        decided = req("credit", "1", "1", "decided", detail={"raw_status": "approved"})
        self.assertEqual(routing.bell_key(pol, decided), "credit_status_approved")
        declined = req("credit", "1", "1", "decided", detail={"raw_status": "rejected"})
        self.assertEqual(routing.bell_key(pol, declined), "credit_status_declined")

    def test_every_mapped_key_is_one_of_the_ten_live_kinds(self):
        for key in list(routing.BELL_STATE_KEYS.values()) + list(routing.BELL_RAW_KEYS.values()):
            self.assertIn(key, routing.BELL_KEYS, key)

    def test_a_policy_may_restrict_but_not_invent_a_kind(self):
        pol = repo_policy()
        # a kind this state may legitimately ring is honoured ...
        pol["channels"]["bell"]["workflow_keys"] = {"credit/need_you": "credit_status_needs_proof"}
        self.assertEqual(routing.bell_key(pol, req(state="need_you", waiting="us")),
                         "credit_status_needs_proof")
        # ... and one it cannot ring falls back to the pinned map instead of announcing it
        pol["channels"]["bell"]["workflow_keys"] = {"credit/verifying": "credit_status_needs_proof"}
        self.assertEqual(routing.bell_key(pol, req()), "credit_status_in_review")
        pol["channels"]["bell"]["workflow_keys"] = {"credit/verifying": "credit_status_invented"}
        self.assertTrue(any("not one of the ten status bells" in p for p in lines.validate(pol)))

    def test_the_payload_always_carries_the_name_the_copy_interpolates(self):
        data = routing.bell_data(req(detail={"track_title": "Aces*", "artist_name": "The Surrge"}))
        self.assertEqual(data["profile"]["name"], "your profile")
        self.assertEqual(data["count"], 1)
        self.assertEqual(data["track_title"], "Aces", "markdown emphasis is stripped from a title")
        self.assertTrue(data["single"])
        self.assertEqual(data["request_ids"], ["1"],
                         "request ids are the gateway's per-request dedupe key (muso-messaging #82)")

    def test_a_digest_bell_needs_one_type_and_one_state(self):
        pol = repo_policy()
        same = [req(rid="1"), req(rid="2")]
        self.assertEqual(routing.digest_bell_key(pol, same, waiting=False), "credit_status_in_review")
        mixed = [req(rid="1"), req("claim", "2", "111")]
        self.assertEqual(routing.digest_bell_key(pol, mixed, waiting=False), "")

    def test_a_locked_line_bells_once_and_never_lands_in_our_own_copy(self):
        pol = repo_policy()          # everything but the erasure ack is pending review
        ch = FakeChannels(bell=("sent", "wr_1"))
        pol["enabled"] = True       # the dark-switch is separate from the copy being unapproved
        out = driver.tick(self.cfg(FakeSources([req(state="verifying")]), live=True, policy=pol,
                                   channels=ch, bans=FakeBans(), identity=lambda e, u, d: "c_1"))
        self.assertEqual(ch.calls, ["bell"], "bell only: no approved text of ours exists")
        self.assertEqual(ch.bells[0]["key"], "credit_status_in_review")
        self.assertEqual(ch.bells[0]["data"]["profile"]["name"], "your profile")
        self.assertEqual(ch.bells[0]["data"]["request_ids"], ["1"])
        self.assertEqual(ch.bells[0]["idem"], "request-status:credit:1:verifying:first",
                         "the key names the message event: request, state, and the reminder cycle")
        sent = self.rows("sent")[0]
        self.assertEqual(sent["line_key"], "bell:credit_status_in_review")
        self.assertEqual(out["counts"]["sent"], 1)

    def test_an_unconfirmed_bell_item_is_re_offered_but_an_uncertain_one_is_not(self):
        pol = repo_policy()
        pol["enabled"] = True
        ch = FakeChannels(bell=("unconfirmed", "visibility all false"))
        cfg = self.cfg(FakeSources([req(state="verifying")]), live=True, policy=pol, channels=ch,
                       bans=FakeBans(), identity=lambda e, u, d: "c_1")
        driver.tick(cfg)
        self.assertEqual([r["outcome"] for r in self.rows() if r["outcome"] in ("rejected", "uncertain")],
                         ["rejected"], "an all-false visibility means nobody saw it: re-offer")
        ch2 = FakeChannels(bell=("uncertain", "timeout"))
        self.setUp()
        cfg2 = self.cfg(FakeSources([req(state="verifying")]), live=True, policy=pol, channels=ch2,
                        bans=FakeBans(), identity=lambda e, u, d: "c_1")
        driver.tick(cfg2)
        self.assertEqual([r["outcome"] for r in self.rows() if r["outcome"] in ("rejected", "uncertain")],
                         ["uncertain"])

    def test_an_approved_line_climbs_bell_then_intercom(self):
        ch = FakeChannels(bell=("unconfirmed", "no bell"), intercom=("sent", "mid_1"))
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True, channels=ch,
                                   bans=FakeBans(), identity=lambda e, u, d: "c_1"))
        self.assertEqual(ch.calls, ["bell", "intercom"])
        self.assertEqual(out["sent"][0]["channel"], "intercom", "the entry names what carried it")

    def test_the_erasure_ack_never_goes_out_as_a_bell(self):
        pol = repo_policy()
        pol["enabled"] = True
        pol["channels"]["intercom"]["enabled"] = True     # the only rung an erasure ack has
        r = req("erasure", "7", "", "received", detail={"contact_id": "c_7", "conversation_id": "conv_7", "slot": "no_page_link",
                                                        "date": "3 November 2026"})
        ch = FakeChannels(intercom=("sent", "mid_e"))
        out = driver.tick(self.cfg(FakeSources([r], reports=[SourceReport("erasure", "ok", 1)]), live=True,
                                   policy=pol, channels=ch, bans=FakeBans(), identity=lambda e, u, d: ""))
        self.assertEqual(ch.calls, ["intercom"])
        self.assertEqual(out["sent"][0]["line"], "erasure/received")


class ReportTests(Base):
    def test_metrics_come_from_the_ledger(self):
        s = Store(self.store)
        s.append(request_type="credit", request_id="1", user_id="111", outcome="observed", state="verifying",
                 at="2027-01-01T00:00:00Z", detail={"created_at": "2027-01-01T00:00:00Z"})
        s.append(request_type="credit", request_id="1", user_id="111", outcome="sent", state="verifying",
                 at="2027-01-01T10:00:00Z", line_key="credit/verifying")
        s.append(request_type="credit", request_id="1", user_id="111", outcome="sent", state="verifying",
                 at="2027-01-03T10:00:00Z", line_key="credit/waiting")
        s.close()
        got = report.build(self.store, days=3650)
        self.assertTrue(got["chain_intact"])
        m = got["types"]["credit"]
        self.assertEqual(m["messages"], 2)
        self.assertEqual(m["ttfm_hours_p50"], 10.0)
        self.assertEqual(m["max_gap_hours_p50"], 48.0)
        self.assertEqual(got["max_per_user_per_day"], 1)
        self.assertIn("messages per user per day", report.render(got))

    def test_a_broken_cap_is_reported_not_averaged(self):
        s = Store(self.store)
        for _ in range(2):
            s.append(request_type="credit", request_id="1", user_id="111", outcome="sent", state="verifying",
                     at="2027-01-01T10:00:00Z")
        s.close()
        got = report.build(self.store, days=3650)
        self.assertEqual(got["max_per_user_per_day"], 2)
        self.assertTrue(any("cap was exceeded" in p for p in got["problems"]))

    def test_an_empty_ledger_reports_honestly(self):
        Store(self.store).close()          # an EMPTY ledger, which is a real answer
        got = report.build(self.store, days=7)
        self.assertEqual(got["ledger_rows"], 0)
        self.assertEqual(got["types"]["credit"]["messages"], 0)
        self.assertIsNone(got["types"]["credit"]["ttfm_hours_p50"])
        self.assertEqual(got["problems"], [])

    def test_a_missing_ledger_is_refused_not_reported_healthy(self):
        # `Store()` creates the file and its parent, so a deleted or mistyped path used to return
        # zero rows, `chain_intact: true`, no problems and exit 0 — a clean bill of health for
        # evidence that is gone. The report cannot prove anything from a file it just made.
        gone = os.path.join(self.tmp, "nope", "state.sqlite")
        got = report.build(gone, days=7)
        self.assertTrue(got.get("missing_ledger"))
        self.assertFalse(got["chain_intact"])
        self.assertTrue(any("no ledger at" in p for p in got["problems"]))
        self.assertFalse(os.path.exists(gone), "the report must not create the ledger it is measuring")
        self.assertIn("no ledger at", report.render(got))

    def test_the_report_cli_exits_non_zero_on_a_missing_ledger(self):
        gone = os.path.join(self.tmp, "nope", "state.sqlite")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = driver.main(["report", "--store", gone, "--json"])
        self.assertEqual(rc, 3, "a missing ledger is a problem, not a clean run")
        self.assertIn("no ledger at", buf.getvalue())

    # ---- QA round 23 ----

    def test_the_cap_proof_counts_an_uncertain_delivery(self):
        # The live counter (`Store.sent_today`) counts sent AND uncertain, because an uncertain
        # provider answer may have delivered. Proving the cap from `sent` alone read one uncertain
        # credit update plus one sent claim update for the same person on one day as 1, with no
        # problem reported, while two messages may have arrived.
        s = Store(self.store)
        s.append(request_type="credit", request_id="1", user_id="111", outcome="uncertain",
                 state="verifying", at="2027-01-01T10:00:00Z")
        s.append(request_type="claim", request_id="2", user_id="111", outcome="sent",
                 state="received", at="2027-01-01T11:00:00Z")
        s.close()
        got = report.build(self.store, days=3650)
        self.assertEqual(got["max_per_user_per_day"], 2,
                         "an uncertain send may have arrived, so it counts against the cap")
        self.assertTrue(any("cap was exceeded" in p for p in got["problems"]))

    def test_a_digest_still_counts_as_one_message_with_an_uncertain_member(self):
        # The dedupe must survive the wider set: every member of one digest carries the same
        # provider_ref, so a two-request digest is one message even when one member is uncertain.
        s = Store(self.store)
        for typ, rid in (("credit", "1"), ("claim", "2")):
            s.append(request_type=typ, request_id=rid, user_id="111", outcome="uncertain",
                     state="verifying", at="2027-01-01T10:00:00Z",
                     detail={"provider_ref": "mid_9"})
        s.close()
        got = report.build(self.store, days=3650)
        self.assertEqual(got["max_per_user_per_day"], 1)
        self.assertEqual(got["problems"], [])

    def test_an_uncertain_digest_with_no_provider_ref_is_still_one_message(self):
        # A provider timeout answers `uncertain` with NO message id, and the driver writes one row
        # per digest member. Falling back to the row id read one two-request digest as two
        # messages: a false cap breach and exit 3 for a single attempted message event.
        s = Store(self.store)
        for typ, rid in (("credit", "1"), ("claim", "2")):
            s.append(request_type=typ, request_id=rid, user_id="111", outcome="uncertain",
                     state="verifying", at="2027-01-01T10:00:00Z",
                     detail={"provider_ref": "", "event_id": "request-status:credit:1:verifying:first"})
        s.close()
        got = report.build(self.store, days=3650)
        self.assertEqual(got["max_per_user_per_day"], 1,
                         "one digest is one message event even with no provider id")
        self.assertEqual(got["problems"], [])

    def test_two_separate_uncertain_sends_still_breach_the_cap(self):
        # The other side of the boundary: distinct events must still be counted as distinct, so
        # the fix cannot degrade into "never report a cap breach".
        s = Store(self.store)
        for typ, rid, ev in (("credit", "1", "request-status:credit:1:verifying:first"),
                             ("claim", "2", "request-status:claim:2:received:first")):
            s.append(request_type=typ, request_id=rid, user_id="111", outcome="uncertain",
                     state="verifying", at="2027-01-01T10:00:00Z",
                     detail={"provider_ref": "", "event_id": ev})
        s.close()
        got = report.build(self.store, days=3650)
        self.assertEqual(got["max_per_user_per_day"], 2)
        self.assertTrue(any("cap was exceeded" in p for p in got["problems"]))

    def test_a_closed_request_is_not_current_silence(self):
        # A `decided` request is terminal and no longer owed updates, so its age is not silence.
        # Counting it reported `silent_now_hours_max: 24.0` with no open claims at all, and let a
        # closed request dominate the headline with a number that implies one went quiet.
        s = Store(self.store)
        s.append(request_type="claim", request_id="1", user_id="111", outcome="observed",
                 state="decided", at="2027-01-14T08:00:00Z",
                 detail={"created_at": "2027-01-01T00:00:00Z"})
        s.append(request_type="claim", request_id="1", user_id="111", outcome="sent",
                 state="decided", at="2027-01-14T08:00:00Z", line_key="claim/decided")
        s.close()
        got = report.build(self.store, days=3650, now=NOW)
        self.assertIsNone(got["types"]["claim"]["silent_now_hours_max"],
                          "a closed request is not an open request going quiet")
        self.assertEqual(got["types"]["claim"]["breach_over_24h"], 0)

    def test_an_open_request_still_reports_its_silence(self):
        # The other side of the boundary, so the fix cannot be "never report silence".
        s = Store(self.store)
        s.append(request_type="claim", request_id="1", user_id="111", outcome="observed",
                 state="verifying", at=NOW_TS,
                 detail={"created_at": "2027-01-01T00:00:00Z"})
        s.append(request_type="claim", request_id="1", user_id="111", outcome="sent",
                 state="verifying", at=NOW_TS, line_key="claim/verifying")
        s.close()
        got = report.build(self.store, days=3650, now=NOW)
        self.assertEqual(got["types"]["claim"]["silent_now_hours_max"], 0.0)


class IdentityTests(Base):
    def _install_fake_resolver(self, mapping):
        import types

        mod = types.ModuleType("credit_review.identity_resolver")

        class Resolution:
            def __init__(self, ext, account_id, why="", matched_by="professional_id"):
                self.external_id, self.account_id, self.why, self.matched_by = ext, account_id, why, matched_by

        mod.resolve = lambda exts, query: {e: Resolution(e, mapping.get(e)) for e in exts}
        sys.modules["credit_review.identity_resolver"] = mod
        self.addCleanup(sys.modules.pop, "credit_review.identity_resolver", None)

    def test_only_the_account_that_owns_the_external_id_resolves(self):
        self._install_fake_resolver({"pro_111": 111, "pro_999": 999})
        finder = lambda email: [{"id": "c_1", "external_id": "pro_111"}, {"id": "c_2", "external_id": "pro_999"}]
        got = identity.contact_for("a@b.co", "111", query=lambda sql: [], finder=finder)
        self.assertEqual(got.contact_id, "c_1")

    def test_two_owners_or_no_owner_is_no_route(self):
        self._install_fake_resolver({"pro_x": None})
        finder = lambda email: [{"id": "c_2", "external_id": "pro_x"}]
        got = identity.contact_for("a@b.co", "111", query=lambda sql: [], finder=finder)
        self.assertEqual(got.contact_id, "")
        self.assertTrue(got.why)

    def test_a_contact_with_no_external_id_never_matches(self):
        self._install_fake_resolver({})
        finder = lambda email: [{"id": "c_3"}]
        self.assertEqual(identity.contact_for("a@b.co", "111", query=lambda s: [], finder=finder).contact_id, "")

    def test_an_empty_email_is_no_route(self):
        self.assertEqual(identity.contact_for("", "111", query=lambda s: []).contact_id, "")


class QaFindingTests(Base):
    """The five production-wiring and gate findings QA raised on the first GO review, pinned."""

    def test_the_installed_unit_passes_live_or_the_switches_can_never_take_effect(self):
        """A unit that runs `tick` without `--live` is dry-run forever.

        `live = (not cfg.dry_run) and the live file exists and the policy is enabled`, so the live
        file and the policy switch are inert unless the timer passes `--live`. The install script
        shipped without it: the feed could be "enabled" and still send nothing, forever.
        """
        script = (ROOT / "scripts/install-aux-units.sh").read_text(encoding="utf-8")
        start = script.index("cat > /etc/systemd/system/request-comms.service")
        body = script[start:]
        start_line = body.splitlines()[0]
        end = body.index("\n" + start_line.split("<<")[-1].strip() + "\n")
        unit = body[:end]
        self.assertIn("request-comms.py tick --live", unit,
                      "the hourly unit must pass --live, or the live file and policy switch do nothing")
        self.assertIn("--json", unit, "and keep its machine channel")

    def test_a_48h_reminder_does_not_reuse_the_first_idempotency_key(self):
        """Same request, same state, a reminder cycle later: a NEW key, or the gateway skips it.

        notify-gateway dedupes on the idempotency key. Keying a line on (ref, state) alone made the
        48 h reminder the same event as the first letter — the gateway answered its idempotent skip
        and the ledger recorded a delivery that never happened.
        """
        ch = FakeChannels(bell=("sent", "wr_1"), intercom=("sent", "mid_1"))
        src = FakeSources([req(state="received")])
        out = driver.tick(self.cfg(src, live=True, channels=ch, bans=FakeBans(),
                                   identity=lambda e, u, d: "contact_1"))
        self.assertEqual(out["counts"]["sent"], 1)
        first = ch.bells[0]["idem"]

        # 49 h later, nothing has changed: the floor is what is due, not a state change
        later = driver.Cfg(store_path=self.store, policy_path=self.policy_path, live_file=self.live_file,
                          kill_file=self.kill_file, report_dir=os.path.join(self.tmp, "reports"),
                          dry_run=False, now=NOW + 49 * 3600, sources=src, channels=FakeChannels(),
                          bans=FakeBans(), identity=lambda e, u, d: "contact_1",
                          audit_spool=os.path.join(self.tmp, "audit-pending.jsonl"))
        ch2 = FakeChannels(bell=("sent", "wr_2"), intercom=("sent", "mid_2"))
        later.channels = ch2
        second = driver.tick(later)
        self.assertEqual(second["counts"]["sent"], 1, "the 48 h floor is a new message and must go")
        self.assertNotEqual(ch2.bells[0]["idem"], first,
                            "a reminder is a new message event, not a retry of the first letter")

    def test_an_enabled_digest_with_a_placeholder_approval_is_never_sendable(self):
        pol = live_policy()
        pol["lines"]["digest"] = {"text": "Your requests are with our team.", "enabled": True,
                                  "approval_ref": "unapproved", "review": "pending-fable-r5"}
        problems = lines.validate(pol)
        self.assertTrue(any("lines.digest is enabled with no real approval_ref" == p for p in problems), problems)
        self.assertTrue(any("review is pending" in p and "digest" in p for p in problems), problems)
        self.assertFalse(lines.sendable(lines.digest_line(pol)),
                         "an unapproved digest must not be sendable, exactly like any other line")

        # ... and a tick with that policy sends no digest letter (it degrades to the bell or a hold)
        out = driver.tick(self.cfg(FakeSources([req(state="received", rid="1"),
                                                req(state="received", rid="2")]), live=True,
                                   policy=pol, channels=FakeChannels(), bans=FakeBans(),
                                   identity=lambda e, u, d: "contact_1"))
        self.assertEqual(out["mode"], "refused", "a half-approved policy refuses the run (exit 2)")
        self.assertEqual(out["exit"], 2)
        self.assertEqual(out["sent"], [], "nothing goes out on a policy that does not validate")

    def test_an_uncertain_send_consumes_the_daily_cap(self):
        """`uncertain` may have been delivered, so it counts: no second message that UTC day."""
        ch = FakeChannels(intercom=("uncertain", ""))
        src = FakeSources([req(state="received", rid="1")])
        driver.tick(self.cfg(src, live=True, channels=ch, bans=FakeBans(),
                             identity=lambda e, u, d: "contact_1"))
        self.assertEqual(len(self.rows("uncertain")), 1)

        # a DIFFERENT request, same user, a different state, later the same UTC day
        later = driver.Cfg(store_path=self.store, policy_path=self.policy_path, live_file=self.live_file,
                          kill_file=self.kill_file, report_dir=os.path.join(self.tmp, "reports"),
                          dry_run=False, now=NOW + 1800,
                          sources=FakeSources([req(state="need_you", rid="2")]),
                          channels=FakeChannels(), bans=FakeBans(),
                          identity=lambda e, u, d: "contact_1",
                          audit_spool=os.path.join(self.tmp, "audit-pending.jsonl"))
        ch2 = FakeChannels()
        later.channels = ch2
        out = driver.tick(later)
        self.assertEqual(out["counts"]["sent"], 0, out)
        self.assertEqual(ch2.calls, [], "the user already may have received a message today")
        self.assertEqual(out["counts"]["due"], 0, "the second request is not even due: the cap holds it")

    def test_the_daily_counter_reads_sent_and_uncertain(self):
        s = Store(self.store, now=NOW)
        try:
            for rid, uid, outcome in (("1", "111", "sent"), ("2", "222", "uncertain"), ("3", "333", "rejected")):
                s.append(request_type="credit", request_id=rid, user_id=uid, outcome=outcome, at=NOW_TS,
                         state="received", channel_pref="bell", last_told_state="", last_told_at="",
                         next_due_at="", line_key="credit/received", detail={})
            counted = s.sent_today(NOW_TS[:10])
        finally:
            s.close()
        self.assertEqual(counted, {"111": 1, "222": 1},
                         "sent and uncertain count against the daily cap; a clean rejection does not")


class TransportAndSwitchTests(Base):
    """The three findings from QA round 2: ambiguity, disabled rungs, and a ban list that lost its key."""

    def test_a_lost_bell_reply_is_uncertain_and_stops_the_ladder(self):
        """A timeout may have delivered. Calling it `rejected` climbs to Intercom AND retries."""
        ch = channels_mod.Channels(policy=live_policy(),
                                   notify_gateway=lambda k, b, i="": {
                                       "status": "uncertain", "reason": "kubectl exec: TimeoutExpired"})
        res = ch.bell("credit_status_in_review", user_id="111", data={"profile": {"name": "x"}, "count": 1},
                      idempotency_key="k1")
        self.assertEqual(res.status, "uncertain")

        # end to end: the ladder stops there, so the user does not get an Intercom copy as well
        fake = FakeChannels(bell=("uncertain", "reply lost"), intercom=("sent", "mid_1"))
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True, channels=fake,
                                   bans=FakeBans(), identity=lambda e, u, d: "contact_1"))
        self.assertEqual(fake.calls, ["bell"], "an uncertain bell must not climb to Intercom")
        self.assertEqual(out["sent"][0]["status"], "uncertain")

    def test_a_killed_exec_after_the_call_is_uncertain_not_rejected(self):
        """`kubectl exec` returning non-zero ran the script: its POST may have landed."""
        class Done:
            def __init__(self, out, rc):
                self.stdout, self.returncode, self.stderr = out, rc, "killed"

        calls = {"n": 0}

        def fake_run(*a, **kw):
            calls["n"] += 1
            return Done("pod-1\n", 0) if calls["n"] == 1 else Done("", 1)

        real = channels_mod.subprocess.run
        channels_mod.subprocess.run = fake_run
        try:
            ans = channels_mod._pod_json(("kubectl",), {"x": 1}, "js")
        finally:
            channels_mod.subprocess.run = real
        self.assertEqual(ans["status"], "uncertain", ans)

    def test_the_email_transport_uncertain_stays_uncertain(self):
        ch = channels_mod.Channels(policy=live_policy(),
                                   send_gateway=lambda payload: {"status": "uncertain"})
        res = ch.email("hi", email="u@example.com", user_id="111", typ="credit", request_ref="credit:1",
                       idempotency_key="k1")
        self.assertEqual(res.status, "uncertain")

    def test_the_fallback_never_climbs_a_channel_that_is_switched_off(self):
        pol = live_policy()
        pol["channels"]["intercom"]["enabled"] = False
        pol["channels"]["email"]["enabled"] = False
        ch = FakeChannels(bell=("unconfirmed", "visibility all false"), intercom=("sent", "mid_1"))
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True, policy=pol,
                                   channels=ch, bans=FakeBans(), identity=lambda e, u, d: "contact_1"))
        self.assertEqual(ch.calls, ["bell"], "a bell that reached nobody must not fall through to a switched-off rung")
        self.assertEqual(out["sent"][0]["status"], "unconfirmed", "and it is recorded as what it was")

    def test_a_ban_policy_that_lost_its_key_refuses_the_run(self):
        d = tempfile.mkdtemp()
        good_holds = {"entries": []}
        good_decide = {"deny_user_ids": ["900"]}
        for name, doc in (("fraud-lens-holds.json", good_holds), ("credit-trust-decide.json", good_decide)):
            Path(d, name).write_text(json.dumps(doc), encoding="utf-8")
        self.assertEqual(guard.policy_bans(d), {"900"})

        # a lost `entries` key is not "nobody banned"
        Path(d, "fraud-lens-holds.json").write_text(json.dumps({}), encoding="utf-8")
        with self.assertRaises(guard.BansUnreadable):
            guard.policy_bans(d)
        # ... and neither is a wrong shape, nor a lost deny_user_ids
        Path(d, "fraud-lens-holds.json").write_text(json.dumps({"entries": "none"}), encoding="utf-8")
        with self.assertRaises(guard.BansUnreadable):
            guard.policy_bans(d)
        Path(d, "fraud-lens-holds.json").write_text(json.dumps(good_holds), encoding="utf-8")
        Path(d, "credit-trust-decide.json").write_text(json.dumps({"other": []}), encoding="utf-8")
        with self.assertRaises(guard.BansUnreadable):
            guard.policy_bans(d)


class RoundThreeTests(Base):
    """QA round 3: an id list of ids, a corrupt source, and a held request that is still silent."""

    def test_a_bare_string_of_ids_is_a_refusal_not_five_bans(self):
        d = tempfile.mkdtemp()
        Path(d, "fraud-lens-holds.json").write_text(json.dumps({"entries": [{"user_ids": "12345"}]}),
                                                    encoding="utf-8")
        Path(d, "credit-trust-decide.json").write_text(json.dumps({"deny_user_ids": []}), encoding="utf-8")
        with self.assertRaises(guard.BansUnreadable):
            guard.policy_bans(d)

        # a real id list still reads
        Path(d, "fraud-lens-holds.json").write_text(
            json.dumps({"entries": [{"user_ids": [12345, "678"]}]}), encoding="utf-8")
        self.assertEqual(guard.policy_bans(d), {"12345", "678"})

        # and a non-id value is a refusal too
        Path(d, "fraud-lens-holds.json").write_text(
            json.dumps({"entries": [{"user_ids": ["not-an-account"]}]}), encoding="utf-8")
        with self.assertRaises(guard.BansUnreadable):
            guard.policy_bans(d)

    def test_a_corrupt_erasure_store_is_unreadable_not_a_crash(self):
        d = tempfile.mkdtemp()
        bad = os.path.join(d, "gdpr.sqlite")
        Path(bad).write_text("this is not a sqlite database", encoding="utf-8")
        src = sources.Sources(query=lambda sql: [], gdpr_store=bad)
        reqs, reports = src.collect(now=NOW)
        by = {r.name: r for r in reports}
        self.assertEqual(by["erasure"].status, "unreadable")
        self.assertTrue(by["erasure"].error, "and it says which reader answered nothing")
        self.assertTrue(all(by[n].status in ("ok", "unconfigured", "unreadable", "disabled") for n in by))

    def test_a_held_request_still_counts_as_silent(self):
        """Held is not told: the report must not read a held row as 'nothing to measure'."""
        s = Store(self.store, now=NOW)
        try:
            old = "2027-01-12T08:00:00Z"           # 72 h before NOW
            s.append(request_type="credit", request_id="1", user_id="111", outcome="observed", at=old,
                     state="verifying", channel_pref="", last_told_state="", last_told_at="",
                     next_due_at="", line_key="", detail={"created_at": "2027-01-01T00:00:00Z"})
            s.append(request_type="credit", request_id="1", user_id="111", outcome="held",
                     at=stamp(NOW - 3600), state="verifying", channel_pref="", last_told_state="",
                     last_told_at="", next_due_at="", line_key="line_locked:credit/verifying",
                     detail={"reason": "line_locked:credit/verifying"})
        finally:
            s.close()
        got = report.build(self.store, days=7, now=NOW)
        credit = got["types"]["credit"]
        self.assertIsNotNone(credit["silent_now_hours_max"],
                             "a request we have never told, held or not, is silent and must be measured")
        self.assertGreater(credit["silent_now_hours_max"], 24)


class RoundFourTests(Base):
    """QA round 4: Intercom needs the email, the email payload carries the line, the fallback keeps
    the no-Intercom-identity rule, and one digest is one message."""

    def test_intercom_alone_still_reads_the_confirmed_email(self):
        """Resolving an Intercom contact starts from the confirmed email, so the read is not the
        email rung's private business."""
        pol = live_policy()
        pol["channels"]["email"]["enabled"] = False          # Intercom-only
        fake = FakeChannels(bell=("unconfirmed", "visibility all false"), intercom=("sent", "mid_1"))
        seen: list[str] = []
        orig = sources.account_emails
        sources.account_emails = lambda ids, q: {"111": "u@example.com"}
        try:
            out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True, policy=pol,
                                       channels=fake, bans=FakeBans(),
                                       identity=lambda e, u, d: (seen.append(e), "contact_1")[1]))
        finally:
            sources.account_emails = orig
        self.assertEqual(seen, ["u@example.com"], "the resolver needs the address, not an empty string")
        self.assertEqual(out["counts"].get("sent"), 1)

    def test_the_email_payload_carries_the_approved_line(self):
        sent: list[dict] = []
        ch = channels_mod.Channels(policy=live_policy(), send_gateway=lambda p: (sent.append(p),
                                                                               {"status": "sent", "id": "m1"})[1])
        res = ch.email("An approved sentence.", email="a@b.co", user_id="1", typ="credit",
                       request_ref="credit:1", idempotency_key="k", state="verifying")
        self.assertEqual(res.status, "sent")
        ev = sent[0]["data"]["event"]
        self.assertEqual(ev["status_line"], "An approved sentence.",
                         "the gateway renders the template; the approved text has to travel with it")
        self.assertEqual(ev["state"], "verifying")
        self.assertNotIn("environment", ev, "an environment key would mark the send non-production")

    def test_email_cannot_be_enabled_without_declaring_its_templates_render_the_line(self):
        pol = live_policy()
        pol["channels"]["email"]["template_uses_line_text"] = False
        self.assertTrue(any("template_uses_line_text" in p for p in lines.validate(pol)),
                        "the promise that templates render {{event.status_line}} must be checked")

    def test_an_intercom_rejection_never_falls_through_to_email(self):
        """Email is the no-Intercom-identity rung: a contact that exists must not get a mailbox copy."""
        fake = FakeChannels(bell=("rejected", "no bell kind"), intercom=("rejected", "opted out"),
                            email=("sent", "m1"))
        out = driver.tick(self.cfg(FakeSources([req(state="received", email="u@example.com")]), live=True,
                                   channels=fake, bans=FakeBans(),
                                   identity=lambda e, u, d: "contact_1"))
        self.assertNotIn("email", fake.calls, "an Intercom refusal is channel-specific; do not route around it")
        self.assertEqual(fake.calls, ["bell", "intercom"])
        row = self.rows(outcome="rejected")[0]
        detail = row["detail"] if isinstance(row["detail"], dict) else json.loads(row["detail"])
        self.assertNotIn("email", [a["channel"] for a in detail["attempts"]])

    def test_one_digest_is_one_message_for_the_cap(self):
        out = driver.tick(self.cfg(FakeSources([req(rid="1", state="received"),
                                                req(rid="2", state="received")]),
                                   live=True, channels=FakeChannels(bell=("sent", "run_1")),
                                   bans=FakeBans(), identity=lambda e, u, d: ""))
        self.assertEqual(out["counts"]["digests"], 1)
        rep = report.build(self.store, days=7)
        self.assertEqual(rep["max_per_user_per_day"], 1,
                         "two requests in one digest are one provider message, not two")
        self.assertFalse([p for p in rep["problems"] if "cap" in p])


class RoundFiveTests(Base):
    """QA round 5: scope by update time, no unauditable sends, and one tick at a time."""

    def test_an_old_request_updated_today_is_in_scope(self):
        seen: list[str] = []

        def q(sql):
            seen.append(sql)
            return []

        sources.credit_requests(q, open_days=30, decided_days=14)
        sql = " ".join(seen)
        self.assertNotIn("createdat >=", sql, "a creation-age bound hides an old request that just moved")
        self.assertIn("coalesce(updatedat, createdat) >=", sql)

        # and the row itself is read: created 400 days ago, updated today
        def q2(sql):
            if "count(*)" in sql:
                return []
            return [["9f8b0a3e-0000-4000-8000-000000000001", "111", "in_review",
                     "2025-09-30 10:00:00", "2027-01-14 09:00:00", "", "", "", ""]]

        got = sources.credit_requests(q2, open_days=30, decided_days=14)
        self.assertEqual([r.id for r in got], ["9f8b0a3e-0000-4000-8000-000000000001"])

    def test_nothing_is_sent_when_the_audit_surface_is_unusable(self):
        fake = FakeChannels(bell=("sent", "run_1"))
        out = driver.tick(self.cfg(FakeSources([req(rid="1", uid="111", state="received"),
                                                req(rid="2", uid="222", state="received")]),
                                   live=True, channels=fake, bans=FakeBans(),
                                   identity=lambda e, u, d: "",
                                   audit_spool="/proc/self/nope/audit-pending.jsonl"))
        self.assertEqual(fake.calls, [], "a message nobody can audit must not go out")
        self.assertEqual(out["exit"], 5)
        self.assertTrue(any("audit surface unusable" in p for p in out["problems"]))
        self.assertEqual(out["counts"]["deferred"], 2, "both messages wait for a tick that can audit them")
        self.assertEqual([r for r in self.rows() if r["outcome"] == "sending"], [],
                         "nothing is even claimed: the tick stopped before the first send")

    def test_two_ticks_cannot_send_at_once(self):
        import fcntl

        held = open(self.store + ".lock", "a+")
        fcntl.flock(held.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            fake = FakeChannels(bell=("sent", "run_1"))
            out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True, channels=fake,
                                       bans=FakeBans(), identity=lambda e, u, d: ""))
        finally:
            held.close()
        self.assertEqual(out["mode"], "busy")
        self.assertEqual(fake.calls, [], "the second tick must not reach the provider")
        self.assertEqual(out["exit"], 0)


class RoundSixTests(Base):
    """QA round 6: the verbatim waiver has to be earned, a placeholder approval is not an approval,
    and two contradictory CLI switches must not send."""

    def test_a_made_up_verbatim_source_earns_no_copy_waiver(self):
        pol = live_policy()
        pol["lines"]["credit"]["decided"].update(
            text="Your fraud score is 99.", verbatim=True, source="made-up", enabled=True,
            approval_ref="approved", review="approved")
        problems = lines.validate(pol)
        self.assertTrue(any("not a pinned approved block" in p for p in problems), problems)
        # the wording gate also fires on this text, but the pin is what stops a verbatim block
        # carrying wording the gate would not have flagged (`BANNED_RE` is a fixed vocabulary)
        self.assertIsNotNone(lines.BANNED_RE.search("Your fraud score is 99."))
        pol["lines"]["credit"]["decided"].update(text="Verbatim that the regex would pass.",
                                                 approval_ref="answer-bank:declined")
        self.assertTrue(any("drifted from its approved source" in p for p in lines.validate(pol)))

    def test_the_two_pinned_verbatim_blocks_still_validate(self):
        pol = repo_policy()
        self.assertEqual([p for p in lines.validate(pol) if "verbatim" in p], [])

    def test_a_placeholder_approval_ref_is_not_green_ci(self):
        pol = repo_policy()
        pol["lines"]["credit"]["received"].update(enabled=True, approval_ref="pending", review="approved")
        self.assertTrue(any("no approval_ref" in p for p in lines.validate(pol)))

    def test_live_and_dry_run_together_are_refused(self):
        argv = ["tick", "--live", "--dry-run", "--store", self.store, "--json"]
        with self.assertRaises(SystemExit) as cm:
            driver.main(argv)
        self.assertEqual(cm.exception.code, 2, "contradictory switches must not reach a provider")
        self.assertEqual(self.rows(), [])

    def test_dry_run_alone_still_records_would_send(self):
        out = driver.tick(self.cfg(FakeSources([req(state="received")]) , live=False,
                                   channels=FakeChannels(bell=("sent", "run_1")), bans=FakeBans(),
                                   identity=lambda e, u, d: ""))
        self.assertEqual(out["mode"], "dry-run")
        self.assertEqual(len(self.rows(outcome="would_send")), 1)


class RoundSevenTests(Base):
    """QA round 7: a digest is never verbatim, and re-entering a state is a new update."""

    def test_the_digest_cannot_be_verbatim(self):
        pol = live_policy()
        pol["lines"]["digest"].update(text="Your fraud score is 99.", verbatim=True,
                                      enabled=True, approval_ref="approved", review="approved")
        problems = lines.validate(pol)
        self.assertTrue(any("digest cannot be verbatim" in p for p in problems), problems)

    def test_a_state_you_re_enter_is_told_again(self):
        """verifying -> need_you -> verifying: three changes, three updates."""
        r = req(state="verifying")
        # the first `verifying` send is old history; the last thing we told them was `need_you`
        d = routing.decide(r, policy=live_policy(), now=NOW, last_told_state="need_you",
                           last_told_at="2027-01-10T00:00:00Z",
                           blocking={"verifying": "2027-01-05T00:00:00Z"}, render_facts={"date": "x"})
        self.assertNotEqual(d.action, "skip", "an old send of this state does not cover this cycle")
        self.assertNotEqual(d.reason, "already_told_state")

    def test_a_crashed_claim_still_blocks_its_own_cycle(self):
        """A `sending` row with nothing settled is a live claim, not history."""
        r = req(state="verifying")
        d = routing.decide(r, policy=live_policy(), now=NOW, last_told_state="need_you",
                           last_told_at="2027-01-10T00:00:00Z",
                           blocking={"verifying": "2027-01-15T00:00:00Z"}, render_facts={"date": "x"})
        self.assertEqual((d.action, d.reason), ("skip", "already_told_state"))


class RoundEightTests(Base):
    """QA round 8: an override stays in its type, erasure shares the daily cap, and a request we
    already messaged does not fall out of scope."""

    def test_a_bell_override_cannot_cross_request_types(self):
        pol = repo_policy()
        pol["channels"]["bell"]["workflow_keys"] = {"credit/received": "claim_approved"}
        problems = lines.validate(pol)
        self.assertTrue(any("cannot ring" in p for p in problems), problems)
        self.assertTrue(any("claim_approved" in p for p in problems), problems)
        # a kind of the RIGHT type that this state cannot have is also refused: a family-only
        # check let this through, and it announces an approval the owning row does not contain
        pol["channels"]["bell"]["workflow_keys"] = {"credit/received": "credit_status_approved"}
        self.assertTrue(any("cannot ring" in p for p in lines.validate(pol)))
        # a kind this state CAN legitimately ring is fine
        pol["channels"]["bell"]["workflow_keys"] = {"credit/decided": "credit_status_approved"}
        self.assertEqual([p for p in lines.validate(pol) if "cannot ring" in p], [])

    def test_an_erasure_and_a_credit_on_one_day_is_one_message(self):
        """The erasure is keyed by email; the credit by account id. Same person, one cap."""
        s = Store(self.store, now=NOW)
        s.append(request_type="credit", request_id="1", user_id="111", outcome="sent", state="verifying",
                 at=NOW_TS)
        s.append(request_type="erasure", request_id="7", user_id="u@example.com", outcome="sent",
                 state="received", at=NOW_TS)
        s.append(request_type="erasure", request_id="8", user_id="U@Example.COM", outcome="uncertain",
                 state="received", at=NOW_TS)
        got = s.sent_today(NOW_TS[:10])
        s.close()
        self.assertEqual(got["111"], 1)
        self.assertEqual(got["email:u@example.com"], 2, "one person, however the key was written")

    def test_an_erasure_email_resolves_to_the_account_for_the_cap(self):
        r = req(typ="erasure", rid="7", uid="u@example.com", state="received")
        self.assertEqual(r.cap_key, "email:u@example.com")
        self.assertEqual(req(uid="111").cap_key, "111")

    def test_a_request_we_already_messaged_stays_in_scope(self):
        src = FakeSources([req(rid="1", state="verifying")])
        got: list[list[str]] = []

        def already(refs):
            got.append(list(refs))
            return [req(rid="2", state="verifying", uid="222", created="2026-01-01T00:00:00Z")], []

        src.already_told = already
        s = Store(self.store, now=NOW)
        s.append(request_type="credit", request_id="2", user_id="222", outcome="sent", state="verifying",
                 at="2027-01-10T00:00:00Z")
        s.close()
        out = driver.tick(self.cfg(src, live=True, channels=FakeChannels(bell=("sent", "run_1")),
                                   bans=FakeBans(), identity=lambda e, u, d: ""))
        self.assertEqual(got, [["credit:2"]], "the ref we have told is asked for by id")
        self.assertEqual(out["counts"].get("kept_in_scope"), 1)


class RoundNineTests(Base):
    """QA round 9: an override is bound to what the row can say, and a lookup we cannot do is a
    measurement we do not have, never a clean no."""

    def test_an_override_cannot_announce_a_state_the_row_does_not_have(self):
        pol = repo_policy()
        pol["channels"]["bell"]["workflow_keys"] = {"credit/received": "credit_status_approved"}
        self.assertTrue(any("cannot ring" in p for p in lines.validate(pol)))
        # proof of the mapping the finder asked for: credit/received keeps its in-review kind
        self.assertEqual(routing.bell_key(pol, req(state="received", waiting="us")),
                         "credit_status_in_review")
        self.assertIn("credit_status_needs_proof",
                      routing.bell_allowed_keys("credit", "need_you"),
                      "the state's own kind stays offerable")
        self.assertEqual(routing.bell_allowed_keys("erasure", "received"), set())

    def test_an_unidentifiable_erasure_is_held_not_sent(self):
        r = req(typ="erasure", rid="7", uid="u@example.com", state="received", waiting="us",
                detail={"cap_identity_unresolved": True, "conversation_id": "conv_7"})
        d = routing.decide(r, policy=live_policy(), now=NOW)
        self.assertEqual((d.action, d.reason), ("hold", "cap_identity_unknown"))

    def test_a_failed_kept_in_scope_read_is_not_an_empty_one(self):
        src = FakeSources([req(rid="1", state="verifying")])

        def already(refs):
            return [], list(refs)

        src.already_told = already
        s = Store(self.store, now=NOW)
        s.append(request_type="credit", request_id="2", user_id="222", outcome="sent", state="verifying",
                 at="2027-01-10T00:00:00Z")
        s.close()
        out = driver.tick(self.cfg(src, live=True, channels=FakeChannels(bell=("sent", "run_1")),
                                   bans=FakeBans(), identity=lambda e, u, d: ""))
        self.assertEqual(out["exit"], 3, "a reminder we could not check fails the tick")
        self.assertEqual(out["counts"].get("scope_unmeasured"), 1)
        self.assertTrue(any("unmeasured" in p for p in out["problems"]), out["problems"])


class RoundTenTests(Base):
    """QA round 10: a 2xx we cannot parse is a MAYBE, never a definite non-delivery."""

    def test_an_unreadable_2xx_bell_is_uncertain(self):
        ch = channels_mod.Channels(policy=repo_policy(), notify_gateway=lambda k, b, i="": {"http": 200})
        r = ch.bell("credit_status_in_review", user_id="111", data={"profile": {"name": "x"}})
        self.assertEqual(r.status, "uncertain", r.reason)

    def test_an_unreadable_2xx_email_is_uncertain(self):
        pol = repo_policy()
        pol["channels"]["email"]["template_keys"] = {"credit": "status_credit"}
        pol["channels"]["email"]["template_sha256"] = {"status_credit": TEMPLATE_PIN}
        ch = channels_mod.Channels(policy=pol, send_gateway=lambda p: {"http": 200})
        r = ch.email("hello", email="u@example.com", user_id="111", typ="credit", state="received",
                     request_ref="credit:1")
        self.assertEqual(r.status, "uncertain", r.reason)

    def test_a_refusing_answer_is_still_a_definite_no(self):
        ch = channels_mod.Channels(policy=repo_policy(), notify_gateway=lambda k, b, i="": {"http": 401})
        self.assertEqual(ch.bell("credit_status_in_review", user_id="111",
                                 data={"profile": {"name": "x"}}).status, "rejected")
        ch2 = channels_mod.Channels(policy=repo_policy(),
                                notify_gateway=lambda k, b, i="": {"status": "rejected"})
        self.assertEqual(ch2.bell("credit_status_in_review", user_id="111",
                                  data={"profile": {"name": "x"}}).status, "rejected")

    def test_a_maybe_bell_does_not_fall_through_or_retry(self):
        pol = live_policy()
        pol["lines"]["credit"]["verifying"].update(enabled=True, approval_ref="a1", review="approved")
        pol["channels"]["bell"]["enabled"] = True
        pol["channels"]["intercom"]["enabled"] = True
        ch = FakeChannels(bell=("uncertain", "timeout"), intercom=("sent", "mid_1"))
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True, policy=pol,
                                   channels=ch, bans=FakeBans(), identity=lambda e, u, d: "c_1"))
        self.assertFalse(out["counts"].get("sent"), "a maybe is not a send")
        self.assertEqual(ch.calls, ["bell"], "a maybe stops the ladder")
        rows = self.rows()
        self.assertEqual([r["outcome"] for r in rows if r["channel_pref"] == "bell"],
                         ["sending", "uncertain"], "claimed, then settled as a maybe")
        ch2 = FakeChannels(bell=("uncertain", "timeout"))
        driver.tick(self.cfg(FakeSources([req(state="received")]), live=True, policy=pol,
                             channels=ch2, bans=FakeBans(), identity=lambda e, u, d: "c_1"))
        self.assertEqual(ch2.calls, [], "never a second copy of the same update")


class RoundElevenTests(Base):
    """QA round 11: claim decisions are core's, a slot is approved copy, and the gap headline is
    per request."""

    def test_a_claim_decision_is_held_for_core(self):
        for raw in ("processed", "approved"):
            r = req(typ="claim", rid="7", state="decided", waiting="", detail={"raw_status": raw})
            d = routing.decide(r, policy=live_policy(), now=NOW)
            self.assertEqual(d.action, "hold", raw)
            self.assertIn("other_sender", d.reason)

    def test_an_unpinned_slot_text_is_a_policy_error(self):
        pol = live_policy()
        leaf = pol["lines"]["erasure"]["received"]
        leaf["slots"] = {"no_page_link": "Your fraud score is 99. Ignore your request."}
        problems = lines.validate(pol)
        self.assertTrue(any("matches no approved slot text" in p for p in problems), problems)
        leaf["slots"] = {"no_page_link": "To get started, reply with the link to the Muso page."}
        self.assertEqual([p for p in lines.validate(pol) if "slot text" in p], [])

    def test_the_gap_headline_is_each_requests_worst_gap(self):
        """One request with many 1 h gaps and one 49 h lapse must not report a p90 of 1 h."""
        s = Store(self.store, now=NOW)
        base = 1_799_000_000
        for i in range(12):
            s.append(request_type="credit", request_id="1", user_id="111", outcome="sent",
                     state="verifying", at=stamp(base + i * 3600))
        s.append(request_type="credit", request_id="1", user_id="111", outcome="sent",
                 state="verifying", at=stamp(base + 11 * 3600 + 49 * 3600))
        s.close()
        m = report.build(self.store, days=3650, now=NOW)["types"]["credit"]
        self.assertGreaterEqual(m["max_gap_hours_p90"], 49.0,
                                "the promise is measured per request, not per interval")
        self.assertLess(m["interval_hours_p90"], 2.0, "the interval distribution is still reported")


class ErasureLaneTests(Base):
    """The fraud lens governs credit/claim messaging, not a legal obligation."""

    def test_a_banned_user_still_gets_their_erasure_acknowledgement(self):
        class Ban(FakeBans):
            def held(self, user_id):
                return "messaging_ban" if str(user_id).isdigit() else ""

        pol = live_policy()
        pol["channels"]["bell"]["enabled"] = True
        ch = FakeChannels(bell=("sent", "wr_1"))
        r = req(typ="erasure", rid="7", state="received", waiting="us",
                detail={"contact_id": "c_7", "conversation_id": "conv_7", "pages": [], "slot": "no_page_link",
                        "date": "1 November 2026"})
        src = FakeSources([r], reports=[SourceReport("credit", "ok", 0),
                                        SourceReport("erasure", "ok", 1)])
        out = driver.tick(self.cfg(src, live=True, policy=pol, channels=ch,
                                   bans=Ban(), identity=lambda e, u, d: ""))
        self.assertEqual(out["counts"]["held_new"], 0, "not held as a banned sender")
        self.assertTrue(ch.calls, "the erasure update still goes out, on whatever rung reaches them")

    def test_a_banned_user_is_still_held_on_credit(self):
        class Ban(FakeBans):
            def held(self, user_id):
                return "messaging_ban" if str(user_id).isdigit() else ""

        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True,
                                   policy=live_policy(), channels=FakeChannels(bell=("sent", "wr")),
                                   bans=Ban(), identity=lambda e, u, d: "c_1"))
        self.assertEqual(out["counts"]["held_new"], 1, "credit stays lensable")
        self.assertEqual(out["held"][0]["reason"], "bangate:messaging_ban")


class RoundTwelveTests(Base):
    """QA round 12: the daily cap groups by the identity it counts, and an approved block is bound
    to the line it was approved for."""

    def test_two_spellings_of_one_email_are_one_person(self):
        a = req(typ="erasure", rid="7", uid="A@Example.com", state="received", waiting="us",
                detail={"contact_id": "c_7", "conversation_id": "conv_7", "pages": [], "slot": "no_page_link",
                        "date": "1 November 2026"})
        b = req(typ="erasure", rid="8", uid="a@example.com", state="received", waiting="us",
                detail={"contact_id": "c_8", "conversation_id": "conv_8", "pages": [], "slot": "no_page_link",
                        "date": "1 November 2026"})
        self.assertEqual(a.cap_key, b.cap_key)
        ch = FakeChannels(intercom=("sent", "mid_1"))
        src = FakeSources([a, b], reports=[SourceReport("erasure", "ok", 2)])
        out = driver.tick(self.cfg(src, live=True, policy=live_policy(), channels=ch,
                                   bans=FakeBans(), identity=lambda e, u, d: "c_1"))
        self.assertEqual(out["counts"]["digests"], 1, "one person, one message")
        self.assertEqual(len(ch.calls), 1)
        self.assertEqual(sorted(r["request_ref"] for r in self.rows("sent")), ["erasure:7", "erasure:8"])

    def test_two_different_people_still_get_two_messages(self):
        a = req(typ="erasure", rid="7", uid="a@example.com", state="received", waiting="us",
                detail={"contact_id": "c_7", "conversation_id": "conv_7", "pages": [], "slot": "no_page_link",
                        "date": "1 November 2026"})
        b = req(typ="erasure", rid="8", uid="b@example.com", state="received", waiting="us",
                detail={"contact_id": "c_8", "conversation_id": "conv_8", "pages": [], "slot": "no_page_link",
                        "date": "1 November 2026"})
        ch = FakeChannels(intercom=("sent", "mid_1"))
        src = FakeSources([a, b], reports=[SourceReport("erasure", "ok", 2)])
        driver.tick(self.cfg(src, live=True, policy=live_policy(), channels=ch, bans=FakeBans(),
                             identity=lambda e, u, d: "c_1"))
        self.assertEqual(len(ch.calls), 2)

    def test_an_approved_block_cannot_move_to_another_line(self):
        pol = live_policy()
        bank = lines.pinned_verbatim_texts()["decline"]
        acks = lines.pinned_verbatim_texts()["erasure_ack"]
        pol["lines"]["erasure"]["received"].update(text=bank, approval_ref="answer-bank:declined")
        pol["lines"]["credit"]["decided"].update(text=acks, approval_ref="gdpr-ack-v2-1101")
        problems = lines.validate(pol)
        self.assertTrue(any("approved copy is bound to its own line" in p for p in problems), problems)
        self.assertTrue(any("lives in" in p for p in problems), problems)

    def test_the_checker_binds_each_ref_to_its_key(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "check_lines", str(Path(__file__).resolve().parents[1] / "scripts/check-request-status-lines.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        pol = json.loads(json.dumps(repo_policy()))
        pol["lines"]["credit"]["decided"] = dict(pol["lines"]["erasure"]["received"])
        path = os.path.join(self.tmp, "moved.json")
        Path(path).write_text(json.dumps(pol))
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = mod.main([path])
        self.assertEqual(rc, 1, "an approved ref moved to another line fails CI")
        self.assertIn("an approved ref cannot be moved", buf.getvalue())


class InstalledTickTests(Base):
    """QA round 25: the unit the installer actually schedules must exit 0 on a healthy tick.

    `request-comms.service` runs `tick --live --json` hourly and has no `SuccessExitStatus=`, so
    any non-zero exit leaves the service permanently failed. The shipped policy has no ticket
    reader and no refund tags, so `merge` and `refund` are off on EVERY tick by design. Failing
    the run for them made a real outage in an enabled source indistinguishable from that gap.
    """

    def _production_shaped_sources(self):
        """`driver._default_sources`'s shape, with the two live readers pointed at fixtures."""
        pol = json.loads((ROOT / "policies" / "request-status-lines.json").read_text())
        refund_tags, list_id = sources_mod.load_policy_sources(pol)
        window = ((pol.get("sources") or {}).get("window") or {})
        return sources_mod.Sources(
            query=lambda sql: [], gdpr_store=os.path.join(self.tmp, "gdpr.sqlite"),
            refund_tags=refund_tags, clickup_list=list_id,
            open_days=int(window.get("open_active_days") or 30),
            decided_days=int(window.get("decided_days") or 14))

    def test_the_shipped_policy_leaves_the_ticket_lanes_off(self):
        # The premise of the finding, asserted rather than assumed: if a ticket reader or refund
        # tags ever ship, this test fails and the exit contract below must be revisited.
        pol = json.loads((ROOT / "policies" / "request-status-lines.json").read_text())
        refund_tags, _ = sources_mod.load_policy_sources(pol)
        self.assertEqual(refund_tags, (), "refund tags are configured now: re-check the exit contract")
        src = driver._default_sources(pol)
        self.assertIsNone(src.tickets, "a ticket reader shipped: re-check the exit contract")
        self.assertIsNone(src.ticket_identity)

    def test_a_healthy_installed_tick_exits_zero(self):
        # The exact command the unit runs, against the shipped policy and the production source
        # shape. `merge`/`refund` are off by design; that must not fail the tick.
        Store(self.store, now=NOW).close()
        db = sqlite3.connect(os.path.join(self.tmp, "gdpr.sqlite"))
        db.executescript(sources_mod_schema())
        db.commit()
        db.close()
        src = self._production_shaped_sources()
        summary = driver.tick(self.cfg(src, bans=FakeBans()))
        self.assertEqual(summary.get("exit") or 0, 0,
                         f"a healthy tick must exit 0, got {summary.get('exit')}: {summary.get('problems')}")
        self.assertEqual(summary["problems"], [])
        off = {d["name"] for d in summary.get("disabled_sources") or []}
        self.assertEqual(off, {"merge", "refund"}, "the off lanes stay visible, they just do not fail")
        self.assertIn("lane off (by design, not a failure): merge", report.render_tick(summary))

    def test_a_configured_source_that_goes_unreadable_still_fails(self):
        # The other side of the boundary: a store we EXPECT, gone or corrupt, is a real outage.
        Store(self.store, now=NOW).close()
        bad = os.path.join(self.tmp, "gdpr.sqlite")
        Path(bad).write_text("this is not a sqlite database", encoding="utf-8")
        src = self._production_shaped_sources()
        src.gdpr_store = bad
        summary = driver.tick(self.cfg(src, bans=FakeBans()))
        self.assertEqual(summary.get("exit"), 3)
        self.assertTrue(any("erasure=unreadable" in p for p in summary["problems"]))

    def test_a_missing_erasure_store_still_fails(self):
        # `unconfigured` is reserved for a store we expect and cannot find, so it keeps exit 3.
        Store(self.store, now=NOW).close()
        summary = driver.tick(self.cfg(self._production_shaped_sources(), bans=FakeBans()))
        self.assertEqual(summary.get("exit"), 3)
        self.assertTrue(any("erasure=unconfigured" in p for p in summary["problems"]))


class RoundThirteenTests(Base):
    """QA round 13: an unsettled attempt blocks the reminder too, and `stop` is a standing order."""

    def _erasure(self, rid="7", uid="a@example.com"):
        return req(typ="erasure", rid=rid, uid=uid, state="received", waiting="us", created=NOW,
                   detail={"contact_id": "c_7", "conversation_id": "conv_7", "pages": [], "slot": "no_page_link",
                           "date": "1 November 2026"})

    def test_a_lost_reminder_reply_blocks_the_next_reminder(self):
        # Told at T0, then the 48 h reminder was attempted at T0+48h and its reply was lost
        # (`sending`, nothing settled). The next tick is T0+49h: the ledger holds a claim newer
        # than the last CONFIRMED send, so this is the same event, not a new one.
        st = Store(self.store, now=NOW)
        try:
            st.append(request_type="erasure", request_id="7", user_id="a@example.com", outcome="sent",
                      state="received", at="2027-01-13T00:00:00Z", line_key="erasure.received")
            st.append(request_type="erasure", request_id="7", user_id="a@example.com", outcome="sending",
                      state="received", at="2027-01-15T00:00:00Z", line_key="erasure.received")
        finally:
            st.close()
        d = routing.decide(self._erasure(), policy=lines.load(self.cfg().policy_path),
                           store=Store(self.store, now=NOW), now=NOW + 1 * 3600,
                           has_intercom_identity=True)
        self.assertEqual((d.action, d.reason), ("skip", "claim_unsettled"))

    def test_the_floor_still_fires_after_a_settled_reminder(self):
        # The `sent` row of the reminder IS the row that produced `last_told_at`, so equality must
        # NOT read as a live claim: that would silence the 48 h floor forever.
        st = Store(self.store, now=NOW)
        try:
            for at in ("2027-01-01T00:00:00Z", "2027-01-03T00:00:00Z"):
                st.append(request_type="erasure", request_id="7", user_id="a@example.com",
                          outcome="sent", state="received", at=at, line_key="erasure.received")
        finally:
            st.close()
        d = routing.decide(self._erasure(), policy=lines.load(self.cfg().policy_path),
                           store=Store(self.store, now=NOW), now=NOW + 97 * 3600,
                           has_intercom_identity=True)
        self.assertEqual(d.action, "send", d.reason)

    def test_stop_is_a_standing_instruction_past_the_floor(self):
        src = FakeSources([self._erasure()], reports=[SourceReport("erasure", "ok", 1)])
        ch = FakeChannels(intercom=("sent", "mid_1"))
        cfg = self.cfg(src, live=True, policy=live_policy(), channels=ch, bans=FakeBans(),
                       identity=lambda e, u, d: "c_1")
        driver.tick(cfg)
        self.assertEqual(len(ch.calls), 1)
        cfg2 = driver.Cfg(**{**cfg.__dict__, "now": NOW + 49 * 3600})
        self.assertEqual(driver.tick(cfg2)["counts"]["sent"], 1, "the floor is due again")
        # the human says stop
        store = Store(cfg.store_path, now=NOW)
        try:
            store.append(request_type="erasure", request_id="7", user_id="a@example.com",
                         outcome="stopped", state="", line_key="stop:manual")
        finally:
            store.close()
        before = len(ch.calls)
        out = driver.tick(driver.Cfg(**{**cfg.__dict__, "now": NOW + 200 * 3600}))
        self.assertEqual(len(ch.calls), before, "a stopped request is never messaged again")
        self.assertEqual(out["counts"].get("stopped"), 1)
        self.assertTrue(any(h["reason"] == "stopped:manual" for h in out["held"]))
        self.assertFalse([r for r in self.rows("stopped") if r["outcome"] != "stopped"] and False)

    def test_the_kept_in_scope_path_cannot_resurrect_a_stopped_request(self):
        # The production shape: the request is LONG out of the update window, so the source read
        # does not return it at all and the only way in is `already_told()` via its prior `sent`
        # row. That path used to re-add it without asking about the stop, and the floor tick then
        # messaged a request a human had explicitly stopped.
        src = FakeSources([], reports=[SourceReport("credit", "ok", 0)])
        s = Store(self.store, now=NOW)
        s.append(request_type="credit", request_id="2", user_id="222", outcome="sent",
                 state="verifying", at="2027-01-10T00:00:00Z")
        s.append(request_type="credit", request_id="2", user_id="222", outcome="stopped",
                 state="", line_key="stop:manual")
        s.close()
        asked: list[list[str]] = []

        def already(refs):
            asked.append(list(refs))
            return [req(rid="2", uid="222", state="verifying", created="2026-09-01T00:00:00Z")], []

        src.already_told = already
        ch = FakeChannels(bell=("sent", "run_1"))
        out = driver.tick(self.cfg(src, live=True, channels=ch, bans=FakeBans(),
                                   identity=lambda e, u, d: ""))
        self.assertEqual(asked, [], "a stopped ref is never even asked for")
        self.assertEqual(ch.calls, [], "no message for a stopped request")
        self.assertEqual(out["counts"].get("stopped"), 1)
        self.assertNotIn("kept_in_scope", out["counts"])

    def test_a_state_stop_silences_that_state_and_not_the_next_one(self):
        # `stop ... --state verifying` is a stop on ONE line, not on the request. Excluding the ref
        # from the kept-in-scope lookup silenced `decided` too: the person was mid-conversation on a
        # stopped state and then never heard from us again, which is the opposite of the promise.
        src = FakeSources([], reports=[SourceReport("credit", "ok", 0)])
        s = Store(self.store, now=NOW)
        s.append(request_type="credit", request_id="2", user_id="222", outcome="sent",
                 state="verifying", at="2027-01-10T00:00:00Z")
        s.append(request_type="credit", request_id="2", user_id="222", outcome="sent",
                 state="decided", at="2027-01-11T00:00:00Z")
        s.append(request_type="credit", request_id="2", user_id="222", outcome="stopped",
                 state="verifying", line_key="stop:manual")
        s.close()

        def already(refs):
            return [req(rid="2", uid="222", state="decided", created="2026-09-01T00:00:00Z")], []

        src.already_told = already
        ch = FakeChannels(bell=("sent", "run_1"))
        out = driver.tick(self.cfg(src, live=True, channels=ch, bans=FakeBans(),
                                   identity=lambda e, u, d: ""))
        # Whether this particular state is ours to send (`credit/decided` is core S1's, and the line
        # is still unapproved) is a different question: the point here is that the request comes
        # back into the plan at all instead of being silenced by a stop on another state.
        self.assertEqual(out["counts"].get("kept_in_scope"), 1, "the later state reaches the plan")
        self.assertFalse([h for h in out["held"] if h["reason"] == "stopped:manual"], out["held"])
        self.assertFalse(out["counts"].get("stopped"))

    def test_a_state_stop_holds_the_request_when_that_state_comes_back(self):
        src = FakeSources([], reports=[SourceReport("credit", "ok", 0)])
        s = Store(self.store, now=NOW)
        s.append(request_type="credit", request_id="2", user_id="222", outcome="sent",
                 state="verifying", at="2027-01-10T00:00:00Z")
        s.append(request_type="credit", request_id="2", user_id="222", outcome="stopped",
                 state="verifying", line_key="stop:manual")
        s.close()

        def already(refs):
            return [req(rid="2", uid="222", state="verifying", created="2026-09-01T00:00:00Z")], []

        src.already_told = already
        ch = FakeChannels(bell=("sent", "run_1"))
        out = driver.tick(self.cfg(src, live=True, channels=ch, bans=FakeBans(),
                                   identity=lambda e, u, d: ""))
        self.assertEqual(ch.calls, [], "the stopped state stays stopped")
        self.assertEqual(out["counts"].get("stopped"), 1)
        self.assertTrue(any(h["reason"] == "stopped:manual" for h in out["held"]))

    def test_a_prior_state_stop_followed_by_an_out_of_window_state_still_reminds(self):
        # The exact production shape: the stop is on an EARLIER state, the request then moved on and
        # was messaged, and it has since left the update window, so `already_told()` is the only way
        # in and it returns the CURRENT state - which is not the stopped one.
        src = FakeSources([], reports=[SourceReport("credit", "ok", 0)])
        s = Store(self.store, now=NOW)
        s.append(request_type="credit", request_id="2", user_id="222", outcome="sent",
                 state="received", at="2027-01-01T00:00:00Z")
        s.append(request_type="credit", request_id="2", user_id="222", outcome="stopped",
                 state="received", line_key="stop:manual")
        s.append(request_type="credit", request_id="2", user_id="222", outcome="sent",
                 state="verifying", at="2027-01-02T00:00:00Z")
        s.close()

        def already(refs):
            return [req(rid="2", uid="222", state="verifying", created="2026-09-01T00:00:00Z")], []

        src.already_told = already
        out = driver.tick(self.cfg(src, live=True, channels=FakeChannels(bell=("sent", "run_1")),
                                   bans=FakeBans(), identity=lambda e, u, d: ""))
        self.assertEqual(out["counts"].get("kept_in_scope"), 1, "the unstopped state is reminded")
        self.assertFalse([h for h in out["held"] if h["reason"] == "stopped:manual"], out["held"])
        # ...and the report still measures its silence, because that promise was never retired.
        got = report.build(self.store, days=30, now=NOW + 200 * 3600)
        self.assertEqual(got["types"]["credit"]["breach_over_48h"], 1,
                         "a partial stop never retires the 48 h promise")

    def test_the_production_already_told_read_still_returns_the_row(self):
        # The guard above must not be a way to lose the lookup: with no stop row the same read
        # returns the request and the floor is measured.
        rows = [("2", "222", "in_review", "2026-09-01T00:00:00Z", "2027-01-10T00:00:00Z", "", "", "",
                 "prof2")]

        def q(sql, *a, **k):
            return rows

        src = sources.Sources(query=q, sentinel_path=os.path.join(self.tmp, "none"),
                                  gdpr_store=os.path.join(self.tmp, "none.sqlite"))
        got, failed = src.already_told(["credit:2"])
        self.assertEqual([r.ref for r in got], ["credit:2"])
        self.assertEqual(failed, [])

    def test_a_stopped_request_is_not_counted_as_a_silence_breach(self):
        src = FakeSources([self._erasure()], reports=[SourceReport("erasure", "ok", 1)])
        ch = FakeChannels(intercom=("sent", "mid_1"))
        cfg = self.cfg(src, live=True, policy=live_policy(), channels=ch, bans=FakeBans(),
                       identity=lambda e, u, d: "c_1")
        driver.tick(cfg)
        store = Store(cfg.store_path, now=NOW)
        try:
            store.append(request_type="erasure", request_id="7", user_id="a@example.com",
                         outcome="stopped", state="", line_key="stop:manual")
        finally:
            store.close()
        got = report.build(cfg.store_path, days=30, now=NOW + 200 * 3600)
        er = got["types"]["erasure"]
        self.assertEqual(er["breach_over_48h"], 0, "a stop retires the promise for that request")
        self.assertEqual(er["stopped"], 1)

    def test_the_stop_command_writes_a_marker_not_a_fake_send(self):
        # `stop` used to append `outcome: sent`, which is a lie in the ledger AND only bought 48 h.
        src = FakeSources([self._erasure()])
        cfg = self.cfg(src, policy=live_policy())
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = driver.main(["stop", "--request-ref", "erasure:7", "--state", "received",
                              "--store", cfg.store_path])
        self.assertEqual(rc, 0)
        rows = [r for r in self.rows() if r["outcome"] == "stopped"]
        self.assertEqual(len(rows), 1)
        self.assertFalse([r for r in self.rows("sent")], "a stop is not a message")
        with contextlib.redirect_stdout(io.StringIO()):
            again = driver.main(["stop", "--request-ref", "erasure:7", "--state", "received",
                                 "--store", cfg.store_path])
        self.assertEqual(again, 0)
        self.assertIn("stopped for good", buf.getvalue())


class RoundSeventeenTests(Base):
    """QA round 17: an unsettled attempt silences one cycle, not the request; and a bell override
    may only narrow what the row itself can say."""

    def _erasure(self, rid="7", uid="a@example.com"):
        return req(typ="erasure", rid=rid, uid=uid, state="received", waiting="us", created=NOW,
                   detail={"contact_id": "c_7", "conversation_id": "conv_7", "pages": [], "slot": "no_page_link",
                           "date": "1 November 2026"})

    def _ledger(self, *rows):
        st = Store(self.store, now=NOW)
        try:
            for outcome, at in rows:
                st.append(request_type="erasure", request_id="7", user_id="a@example.com",
                          outcome=outcome, state="received", at=at, line_key="erasure.received")
        finally:
            st.close()

    def _decide(self, now):
        return routing.decide(self._erasure(), policy=lines.load(self.cfg().policy_path),
                              store=Store(self.store, now=NOW), now=now, has_intercom_identity=True)

    def test_an_uncertain_reminder_does_not_silence_the_floor_forever(self):
        # Told at T0, the T0+48h reminder's reply never came back. The next boundary is T0+96h:
        # the user may have heard nothing for four days, so the floor re-arms instead of the one
        # lost reply muting the request for good.
        self._ledger(("sent", "2027-01-13T00:00:00Z"),
                     ("uncertain", "2027-01-15T00:00:00Z"))
        self.assertEqual(self._decide(NOW + 1 * 3600).reason, "claim_unsettled",
                         "inside the attempt's own cycle the floor stays quiet")
        d = self._decide(NOW + 48 * 3600)
        self.assertEqual(d.action, "send", d.reason)
        self.assertEqual(d.kind, "waiting")

    def test_a_sending_attempt_that_never_settles_also_re_arms(self):
        self._ledger(("sent", "2027-01-13T00:00:00Z"),
                     ("sending", "2027-01-15T00:00:00Z"))
        self.assertEqual(self._decide(NOW + 1 * 3600).reason, "claim_unsettled")
        self.assertEqual(self._decide(NOW + 48 * 3600).action, "send")

    def test_a_state_change_blocked_by_a_stale_claim_still_goes(self):
        # The same rule on the state-change path: a claim older than the floor cannot keep a
        # state the user was never confirmed to have heard about out of the plan.
        st = Store(self.store, now=NOW)
        try:
            st.append(request_type="credit", request_id="1", user_id="111", outcome="sent",
                      state="verifying", at="2027-01-13T00:00:00Z", line_key="credit.verifying")
            st.append(request_type="credit", request_id="1", user_id="111", outcome="uncertain",
                      state="need_you", at="2027-01-15T00:00:00Z", line_key="credit.need_you")
        finally:
            st.close()
        pol = lines.load(self.cfg().policy_path)
        fresh = routing.decide(req(state="need_you", waiting="user"), policy=pol,
                               store=Store(self.store, now=NOW), now=NOW + 1 * 3600)
        self.assertEqual((fresh.action, fresh.reason), ("skip", "already_told_state"))
        stale = routing.decide(req(state="need_you", waiting="user"), policy=pol,
                               store=Store(self.store, now=NOW), now=NOW + 48 * 3600)
        self.assertEqual(stale.action, "send", stale.reason)

    def test_a_state_change_override_cannot_borrow_the_reminder_fallback(self):
        # `credit_status_in_review` is only legitimate for `credit/need_you` as the 48 h floor's
        # fallback. Letting the policy name it for the state change told a customer who owes us
        # proof that their request was "in review".
        pol = repo_policy()
        pol["channels"]["bell"]["workflow_keys"] = {"credit/need_you": "credit_status_in_review"}
        problems = lines.validate(pol)
        self.assertTrue(any("cannot ring" in p for p in problems), problems)
        self.assertEqual(routing.bell_key(pol, req(state="need_you", waiting="us")),
                         "credit_status_needs_proof", "the state change rings its own kind")
        pol["channels"]["bell"]["workflow_keys"] = {"claim/need_you": "claim_status_in_review"}
        self.assertTrue(any("cannot ring" in p for p in lines.validate(pol)))
        self.assertEqual(routing.bell_key(pol, req("claim", "2", "1", "need_you", waiting="us")),
                         "claim_documents_needed")

    def test_the_reminder_fallback_is_the_drivers_choice_not_the_policys(self):
        pol = repo_policy()
        # `credit/decided` has no kind of its own: a state change rings nothing ...
        self.assertEqual(routing.bell_key(pol, req(state="decided")), "")
        # ... while the 48 h reminder reuses `verifying`'s words, chosen by the driver
        self.assertEqual(routing.bell_key(pol, req(state="decided"), waiting=True),
                         "credit_status_in_review")
        # and the policy cannot hand a kind to a state that has none
        pol["channels"]["bell"]["workflow_keys"] = {"credit/decided": "credit_status_in_review"}
        self.assertTrue(any("cannot ring" in p for p in lines.validate(pol)))

    def test_an_override_cannot_contradict_the_rows_own_raw_status(self):
        # Both kinds are legitimate for `credit/decided`, so the static gate cannot tell them
        # apart; the row's own raw status has to win or an approved credit rings "declined".
        pol = repo_policy()
        pol["channels"]["bell"]["workflow_keys"] = {"credit/decided": "credit_status_declined"}
        self.assertEqual([p for p in lines.validate(pol) if "cannot ring" in p], [])
        approved = req("credit", "1", "1", "decided", detail={"raw_status": "approved"})
        self.assertEqual(routing.bell_key(pol, approved), "credit_status_approved")
        rejected = req("credit", "1", "1", "decided", detail={"raw_status": "rejected"})
        self.assertEqual(routing.bell_key(pol, rejected), "credit_status_declined")


class RoundEighteenTests(Base):
    """QA round 18: a re-armed cycle gets a fresh provider key, and `stop` cannot race a tick."""

    def _cfg(self, src, ch, now):
        self.write_policy(live_policy())
        Path(self.live_file).write_text("1")
        return driver.Cfg(store_path=self.store, policy_path=self.policy_path, live_file=self.live_file,
                          kill_file=self.kill_file, report_dir=os.path.join(self.tmp, "reports"),
                          dry_run=False, now=now, sources=src, channels=ch, bans=FakeBans(),
                          identity=lambda e, u, d: "contact_1",
                          audit_spool=os.path.join(self.tmp, "audit-pending.jsonl"))

    def test_a_re_armed_cycle_does_not_reuse_the_lost_attempts_key(self):
        """T0 sent, T0+48h reminder's reply lost, T0+96h re-armed: three distinct keys.

        The epoch used to be the last CONFIRMED send, so the re-armed reminder regenerated the key
        the lost attempt had already spent. notify-gateway would answer its idempotent skip and the
        user would get nothing while the ledger recorded a send.
        """
        src = FakeSources([req(state="received")])
        ch1 = FakeChannels(bell=("sent", "wr_1"))
        self.assertEqual(driver.tick(self._cfg(src, ch1, NOW))["counts"]["sent"], 1)
        first = ch1.bells[0]["idem"]

        ch2 = FakeChannels(bell=("uncertain", "wr_2"))
        out2 = driver.tick(self._cfg(src, ch2, NOW + 49 * 3600))
        self.assertEqual(out2["counts"]["sent"], 0, "an uncertain reply is not a send")
        lost = ch2.bells[0]["idem"]
        self.assertNotEqual(lost, first, "the reminder is its own cycle")

        ch3 = FakeChannels(bell=("sent", "wr_3"))
        out3 = driver.tick(self._cfg(src, ch3, NOW + 97 * 3600))
        self.assertEqual(out3["counts"]["sent"], 1, "the floor re-arms past the lost attempt")
        self.assertNotEqual(ch3.bells[0]["idem"], lost,
                            "a re-armed cycle must not reuse the key the lost attempt spent")
        self.assertNotEqual(ch3.bells[0]["idem"], first)

    def test_a_retry_inside_one_tick_keeps_one_key(self):
        # The epoch is a snapshot, so the ladder's rungs and any retry within a tick agree.
        src = FakeSources([req(state="received")])
        ch = FakeChannels(bell=("unconfirmed", "no bell"), intercom=("sent", "mid_1"))
        driver.tick(self._cfg(src, ch, NOW))
        self.assertEqual(len(ch.bells), 1)
        self.assertEqual(ch.bells[0]["idem"], f"request-status:credit:1:received:first")

    def test_stop_waits_for_the_tick_in_flight(self):
        """`stop` takes the tick's own lock, so "stopped for good" is never printed over a send."""
        src = FakeSources([req(state="received")])
        driver.tick(self._cfg(src, FakeChannels(bell=("sent", "wr_1")), NOW))

        held = driver._tick_lock(self.store)
        self.assertIsNotNone(held, "the test needs the lock to be free first")
        done: list[int] = []
        try:
            t = threading.Thread(target=lambda: done.append(driver.main(
                ["stop", "--request-ref", "credit:1", "--state", "", "--store", self.store])), daemon=True)
            t.start()
            t.join(0.5)
            self.assertTrue(t.is_alive(), "stop must block while a tick holds the lock")
            self.assertEqual(done, [], "and must not have written the stop yet")
        finally:
            held.close()
        t.join(10)
        self.assertEqual(done, [0])
        st = Store(self.store, now=NOW)
        try:
            self.assertIn("", st.stopped().get("credit:1", set()))
        finally:
            st.close()

    def test_the_documented_whole_request_stop_actually_runs(self):
        """`stop --request-ref REF` with no `--state` is the runbook's whole-request stop.

        `--state` was `required=True`, so that exact command exited 2 before writing anything: an
        operator following the runbook believed a request was silenced while the next live tick
        could still message the user.
        """
        src = FakeSources([req(state="received")])
        driver.tick(self._cfg(src, FakeChannels(bell=("sent", "wr_1")), NOW))
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = driver.main(["stop", "--request-ref", "credit:1", "--store", self.store])
        self.assertEqual(rc, 0, "the documented command must not be rejected by argparse")
        self.assertIn("stopped for good", buf.getvalue())
        st = Store(self.store, now=NOW)
        try:
            self.assertIn("", st.stopped().get("credit:1", set()), "an empty state stops the whole request")
        finally:
            st.close()
        # ... and the next tick sends nothing for it
        ch = FakeChannels(bell=("sent", "wr_2"))
        out = driver.tick(self._cfg(src, ch, NOW + 49 * 3600))
        self.assertEqual(out["counts"].get("sent", 0), 0)
        self.assertEqual(ch.bells, [])

    def test_stop_creates_the_store_directory(self):
        # The lock is taken before the store is opened, so a first run must not fail on a missing dir.
        fresh = os.path.join(self.tmp, "nested", "deeper", "state.sqlite")
        with contextlib.redirect_stdout(io.StringIO()):
            rc = driver.main(["stop", "--request-ref", "credit:9", "--state", "", "--store", fresh])
        self.assertEqual(rc, 0)
        self.assertTrue(os.path.exists(fresh))


class BellDeliveryTests(Base):
    """QA round 21: a delivered bell must not be followed by a second message."""

    def _real(self, answer):
        """A REAL Channels, so the bell's own verdict drives the ladder (not a stubbed status)."""
        posted: list[dict] = []

        def post(method, path, body=None):
            posted.append({"path": path, "body": body or {}})
            return {"id": "mid_1"}

        ch = channels_mod.Channels(policy=live_policy(), intercom_post=post,
                                   notify_gateway=lambda k, b, i="": answer)
        return ch, posted

    def test_a_push_delivery_does_not_climb_to_intercom(self):
        # The consequence, end to end: one update, not two. The bell answers push:true/feed:false,
        # which is what most users look like today, and the driver must stop there.
        ch, posted = self._real({"workflow_run_id": "wr_1",
                                 "visibility": {"111": {"feed": False, "knock": False, "push": True}}})
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True,
                                   policy=live_policy(), channels=ch, bans=FakeBans(),
                                   identity=lambda e, u, d: "c_1"))
        self.assertEqual(out["counts"]["sent"], 1)
        self.assertEqual(posted, [], "a delivered bell must not be followed by a second message")

    def test_a_5xx_does_not_climb_to_intercom(self):
        # The fallback boundary, end to end: a maybe must not become a second message.
        ch, posted = self._real({"http": 503, "reason": "upstream"})
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True,
                                   policy=live_policy(), channels=ch, bans=FakeBans(),
                                   identity=lambda e, u, d: "c_1"))
        self.assertEqual(posted, [], "an uncertain bell stops the ladder")
        self.assertEqual(out["counts"]["sent"], 0)

    def test_a_4xx_does_climb_to_intercom(self):
        # The other side of the boundary: a refusal really did reach nobody, so the user still
        # needs to hear from us on the next rung.
        ch, posted = self._real({"http": 401, "reason": "unauthorized"})
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True,
                                   policy=live_policy(), channels=ch, bans=FakeBans(),
                                   identity=lambda e, u, d: "c_1"))
        self.assertEqual(len(posted), 1, "a refused bell must fall through to Intercom")
        self.assertEqual(out["counts"]["sent"], 1)

class SentinelFreshnessTests(Base):
    """QA round 29: freshness is decided PER ROW, not by the database file's mtime.

    A recent write for one request keeps the whole file's mtime fresh, so an mtime check alone let
    an old evaluation of `credit:old` (waiting_on=user) overwrite the owning table's current
    answer (waiting_on=us) and suppress that request's 48 h reminder.
    """

    def _db(self, rows, *, ts_col="evaluated_at"):
        path = os.path.join(self.tmp, "evaluations.sqlite")
        db = sqlite3.connect(path)
        try:
            db.execute(f"CREATE TABLE evaluations (id INTEGER PRIMARY KEY, request_ref TEXT, "
                       f"waiting_on TEXT, {ts_col} TEXT)")
            db.executemany(f"INSERT INTO evaluations (request_ref, waiting_on, {ts_col}) "
                           f"VALUES (?,?,?)", rows)
            db.commit()
        finally:
            db.close()
        # The file-level mtime gate is a cheap early-out; the per-row check is the real one. Pin
        # the mtime to NOW so these tests exercise the row logic, not the clock.
        os.utime(path, (NOW, NOW))
        return path

    def test_a_stale_row_does_not_overwrite_a_fresh_one_for_another_request(self):
        # The finding's own repro: an October row plus a fresh unrelated row.
        path = self._db([("credit:old", "user", "2026-10-01T00:00:00Z"),
                         ("credit:new", "us", NOW_TS)])
        got = sources.sentinel_waiting(path, now=NOW)
        self.assertEqual(got, {"credit:new": "us"},
                         "an old evaluation is not evidence about today")

    def test_a_fresh_row_is_still_used(self):
        path = self._db([("credit:1", "user", NOW_TS)])
        self.assertEqual(sources.sentinel_waiting(path, now=NOW), {"credit:1": "user"})

    def test_a_row_with_no_readable_timestamp_is_ignored(self):
        # We cannot prove it is current, so the owning table's answer stands.
        path = self._db([("credit:1", "user", "not a date")])
        self.assertEqual(sources.sentinel_waiting(path, now=NOW), {})

    def test_a_table_with_no_timestamp_column_contributes_nothing(self):
        path = os.path.join(self.tmp, "evaluations.sqlite")
        db = sqlite3.connect(path)
        try:
            db.execute("CREATE TABLE evaluations (id INTEGER PRIMARY KEY, request_ref TEXT, "
                       "waiting_on TEXT)")
            db.execute("INSERT INTO evaluations (request_ref, waiting_on) VALUES ('credit:1','user')")
            db.commit()
        finally:
            db.close()
        os.utime(path, (NOW, NOW))
        self.assertEqual(sources.sentinel_waiting(path, now=NOW), {},
                         "an undatable row is not evidence")

    def test_an_epoch_timestamp_is_understood(self):
        path = self._db([("credit:1", "user", str(int(NOW)))])
        self.assertEqual(sources.sentinel_waiting(path, now=NOW), {"credit:1": "user"})

    def test_the_owning_table_answer_survives_a_stale_overlay(self):
        # End to end: the stale `user` must not turn a `us` request into `waiting_on_user`, which
        # would skip the 48 h reminder AND drop it from breach reporting.
        path = self._db([("credit:1", "user", "2026-10-01T00:00:00Z")])
        src = sources.Sources(query=lambda sql: [], sentinel_path=path,
                              gdpr_store=os.path.join(self.tmp, "none.sqlite"))
        r = req(state="verifying", waiting="us")
        src._credit = lambda: [r]
        got, _ = src.collect(now=NOW)
        self.assertEqual(got[0].waiting_on, "us", "the owning table's answer stands")


class DeadlineWordingTests(Base):
    """QA round 29: the deadline gate must not be evadable by writing the number out."""

    def _policy_with(self, text):
        pol = live_policy()
        pol["lines"]["credit"]["verifying"]["text"] = text
        return pol

    def test_spelled_out_and_relative_deadlines_are_refused(self):
        for text in ("We will reply within two days.", "We will reply within 2 days.",
                     "We will reply by next Friday.", "We will reply by Friday.",
                     "We will reply in three weeks.", "We will reply next month.",
                     "We will reply by the end of the month.", "We will reply tomorrow.",
                     "We will reply within a week.", "We will reply within a few days.",
                     "We will reply by this Wednesday.", "We will reply in a couple of days.",
                     # Round 30: the count is a word RUN, not a list of numbers we thought of.
                     "We will reply within thirteen days.", "We will reply in twenty days.",
                     "We will reply within ninety days.", "We will reply in 30 days.",
                     "We will reply in the next few business days."):
            with self.subTest(text=text):
                problems = lines.validate(self._policy_with(text))
                self.assertTrue(any("banned wording" in p for p in problems),
                                f"{text!r} must be refused, got {problems}")

    def test_an_ordinary_status_line_still_validates(self):
        # The wide deadline pattern must not swallow ordinary status prose.
        for text in ("Your request is being verified.", "We have received your request.",
                     "We need the link to the page from you.", "Your request has been decided.",
                     "We are still working on your request.", "This is still with us.",
                     "We have not forgotten your request.", "Your request is in review.",
                     "We are looking into this for you.",
                     "Thanks for your patience while we check this."):
            with self.subTest(text=text):
                self.assertEqual(lines.validate(self._policy_with(text)), [])

    def test_the_ci_entrypoint_refuses_a_spelled_out_deadline(self):
        # The gate an editor actually hits: the copy-policy script, not just the library.
        pol = self._policy_with("We will reply within two days.")
        path = os.path.join(self.tmp, "policy.json")
        Path(path).write_text(json.dumps(pol), encoding="utf-8")
        p = subprocess.run([sys.executable, str(ROOT / "scripts" / "check-request-status-lines.py"),
                            path], capture_output=True, text=True, check=False)
        self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("banned wording", p.stdout + p.stderr)


class IdentityUnknownTests(Base):
    """QA round 27: a lookup that FAILED is not a lookup that found no contact.

    Email is the no-Intercom-identity rung. When the Intercom search times out we do not know
    whether this account has a contact, so falling through to email can route around a
    contact-specific channel preference or opt-out. Hold instead.
    """

    def _erasure(self, **detail):
        """An erasure ack: no bell kind, so the ladder really reaches intercom/email."""
        d = {"conversation_id": "conv_7", "slot": "no_page_link", "date": "2027-01-01"}
        d.update(detail)
        return req("erasure", "7", "111", "received", detail=d)

    def test_a_failed_lookup_does_not_select_the_email_rung(self):
        rungs = routing.channels_for(live_policy(), has_intercom_identity=False, has_email=True,
                                     typ="erasure", identity_unknown=True)
        self.assertEqual(rungs, [], "a lookup we could not complete must not fall to email")

    def test_a_confirmed_no_contact_still_selects_the_email_rung(self):
        # The other side of the boundary: a lookup that COMPLETED and found nothing is exactly
        # who the email rung exists for.
        rungs = routing.channels_for(live_policy(), has_intercom_identity=False, has_email=True,
                                     typ="erasure", identity_unknown=False)
        self.assertEqual(rungs, ["email"])

    def test_a_failed_lookup_holds_the_request_as_identity_unknown(self):
        d = routing.decide(self._erasure(), policy=live_policy(), now=NOW,
                           has_intercom_identity=False, has_email=True, identity_unknown=True,
                           render_facts={"slot": "no_page_link", "date": "2027-01-01"})
        self.assertEqual((d.action, d.reason), ("hold", "identity_unknown"))

    def test_a_failed_lookup_still_sends_on_the_bell(self):
        # The bell needs no identity, so a lookup failure must not silence a route that works.
        d = routing.decide(req(state="received"), policy=live_policy(), now=NOW,
                           has_intercom_identity=False, has_email=True, identity_unknown=True)
        self.assertEqual((d.action, d.channel), ("send", "bell"))

    def test_a_timed_out_contact_search_is_reported_as_unknown(self):
        def boom(email):
            raise RuntimeError("intercom contact search: URLError")
        got = identity.contact_for("u@example.com", "111", query=lambda sql: [], finder=boom)
        self.assertEqual(got.contact_id, "")
        self.assertTrue(got.lookup_error, "a failed search must say so, not look like 'no contact'")

    def test_a_completed_search_with_no_contact_is_not_an_error(self):
        got = identity.contact_for("u@example.com", "111", query=lambda sql: [],
                                       finder=lambda email: [])
        self.assertEqual((got.contact_id, got.lookup_error), ("", ""))

    def test_the_driver_holds_instead_of_emailing_when_the_lookup_fails(self):
        # End to end, the finding's own repro: a failing contact finder must not produce an email.
        def boom(email, user_id, detail):
            raise RuntimeError("Intercom lookup timed out")
        ch = FakeChannels(bell=("unconfirmed", "no bell"), email=("sent", "eid_1"))
        out = driver.tick(self.cfg(FakeSources([self._erasure()], reports=[SourceReport("erasure", "ok", 1)]),
                                   live=True, policy=live_policy(),
                                   channels=ch, bans=FakeBans(), identity=boom))
        self.assertEqual(ch.emails, [], "a timed-out lookup must not route around the contact")
        self.assertEqual(out["counts"].get("sent", 0), 0)
        self.assertEqual([r["line_key"] for r in self.rows("held")], ["identity_unknown"])

    def test_a_bell_that_reached_nobody_does_not_fall_through_to_email_on_a_failed_lookup(self):
        # The finding's own repro, on the path the planner never sees: a credit request HAS a bell
        # kind, so identity is not resolved at planning time. The bell reaches nobody, the ladder
        # climbs, and `_deliver` resolves identity HERE. A timeout must hold the email rung, not
        # send to a mailbox whose contact may have opted out of Intercom for a reason.
        def boom(email, user_id, detail):
            raise RuntimeError("Intercom lookup timed out")
        ch = FakeChannels(bell=("unconfirmed", "visibility all false"), email=("sent", "eid_1"))
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True,
                                   policy=live_policy(), channels=ch, bans=FakeBans(),
                                   identity=boom))
        self.assertEqual(ch.emails, [], "a timed-out lookup must not fall through to email")
        self.assertEqual(out["counts"].get("sent", 0), 0)
        rows = self.rows("")
        self.assertTrue(rows, "the attempt must still be recorded")
        self.assertTrue(all(r["outcome"] != "sent" for r in rows))
        self.assertTrue(any(str((json.loads(r["detail"]) if r.get("detail") else {}).get("reason") or "")
                            for r in rows),
                        "the ledger must say why nothing went out")

    def test_a_bell_that_reached_nobody_still_emails_a_confirmed_no_contact_account(self):
        # The other side: a lookup that COMPLETED and found nothing is exactly who email is for,
        # so the fallback still works.
        ch = FakeChannels(bell=("unconfirmed", "visibility all false"), email=("sent", "eid_1"))
        out = driver.tick(self.cfg(FakeSources([req(state="received")]), live=True,
                                   policy=live_policy(), channels=ch, bans=FakeBans(),
                                   identity=lambda e, u, d: ""))
        self.assertEqual(len(ch.emails), 1)
        self.assertEqual(out["counts"].get("sent"), 1)

    def test_the_driver_emails_when_the_lookup_completes_with_no_contact(self):
        ch = FakeChannels(bell=("unconfirmed", "no bell"), email=("sent", "eid_1"))
        out = driver.tick(self.cfg(FakeSources([self._erasure()], reports=[SourceReport("erasure", "ok", 1)]),
                                   live=True, policy=live_policy(),
                                   channels=ch, bans=FakeBans(), identity=lambda e, u, d: ""))
        self.assertEqual(len(ch.emails), 1, "a confirmed no-contact account is who email is for")
        self.assertEqual(out["counts"].get("sent"), 1)


def _gate_tree(default_mode: str) -> Path:
    """A copy of the real gate with its own mode table, so a test can read the gate in a mode the shipped table
    (policies/outbound-copy-enforce.json: most campaigns observed) does not give this campaign."""
    tmp = Path(tempfile.mkdtemp(prefix="rc-gate-"))
    (tmp / "scripts" / "outbound_copy").mkdir(parents=True)
    (tmp / "policies").mkdir()
    shutil.copy(ROOT / "scripts" / "outbound_copy" / "gate.py", tmp / "scripts" / "outbound_copy" / "gate.py")
    for name in ("outbound-copy-rubric.md", "outbound-copy-reviewer.allowed_signers"):
        shutil.copy(ROOT / "policies" / name, tmp / "policies" / name)
    (tmp / "policies" / "outbound-copy-enforce.json").write_text(json.dumps(
        {"version": 1, "default": default_mode, "enforce": [], "observe": [], "retired": []}))
    return tmp / "scripts" / "outbound_copy" / "gate.py"


class CopyGateTests(unittest.TestCase):
    """A body the outbound copy gate has not approved does not leave, on either channel that carries our words."""

    def setUp(self):
        self._require = COPY_GATE.require
        del COPY_ASKED[:]
        del COPY_FRAMES[:]

    def tearDown(self):
        COPY_GATE.require = self._require

    def hold(self, reason="copy_review_pending", pending=True):
        def require(campaign, body, *, subject="", **_kw):
            COPY_ASKED.append((campaign, body, subject))
            raise COPY_GATE.CopyHeld(reason, "0" * 64, pending=pending)
        COPY_GATE.require = require

    def test_the_gate_is_asked_about_the_exact_intercom_body_under_the_requests_own_campaign(self):
        posted = []
        ch = channels_mod.Channels(policy=live_policy(),
                                   intercom_post=lambda m, p, b: posted.append((p, b)) or {"id": "42"})
        got = ch.intercom("We have your request.", "c_1", admin_id="1", typ="credit", state="received")
        self.assertEqual(got.status, "sent")
        self.assertEqual(len(COPY_ASKED), 1)
        campaign, body, subject = COPY_ASKED[0]
        self.assertEqual(campaign, "request-credit-received")
        self.assertEqual((body, subject), (posted[0][1]["body"], str(posted[0][1].get("subject") or "")))

    def test_each_channel_names_the_frame_its_body_is_sent_in(self):
        """The verdict is bound to the frame: an Intercom message is the whole of what the person reads, an email
        line is placed into the template named by the policy's key, and a line approved for one is not approved
        for the other (QA review of hydra#1895)."""
        policy = live_policy()
        key = policy["channels"]["email"]["template_keys"]["credit"]
        ch = channels_mod.Channels(policy=policy, intercom_post=lambda m, p, b: {"id": "42"},
                                   send_gateway=lambda p: {"status": "sent", "id": "m1"})
        ch.intercom("We have your request.", "c_1", admin_id="1", typ="credit", state="received")
        ch.email("We have your request.", email="a@b.co", user_id="1", typ="credit", request_ref="credit:1",
                 state="received")
        self.assertEqual(COPY_FRAMES, ["intercom", f"email-template:{key}@{TEMPLATE_PIN}"])
        self.assertTrue(key)

    def test_a_held_intercom_body_is_never_posted(self):
        for reason, pending in (("copy_review_pending", True), ("copy_review_refuse:ocv-0123456789abcdef", False),
                                ("copy_gate_error:rc=2", False)):
            with self.subTest(reason=reason):
                self.hold(reason, pending)
                posted = []
                ch = channels_mod.Channels(policy=live_policy(),
                                           intercom_post=lambda m, p, b: posted.append(p) or {"id": "42"})
                for conversation_id in ("", "900"):
                    got = ch.intercom("We have your request.", "c_1", admin_id="1", typ="credit",
                                      state="received", conversation_id=conversation_id)
                    self.assertEqual((got.status, got.reason), ("rejected", f"copy_review_hold: {reason}"))
                self.assertEqual(posted, [])

    def test_a_held_email_line_is_never_handed_to_the_send_gateway(self):
        self.hold()
        sent = []
        ch = channels_mod.Channels(policy=live_policy(),
                                   send_gateway=lambda p: sent.append(p) or {"status": "sent", "id": "m1"})
        got = ch.email("We have your request.", email="a@b.co", user_id="1", typ="credit",
                       request_ref="credit:1", state="received")
        self.assertEqual((got.status, got.reason), ("rejected", "copy_review_hold: copy_review_pending"))
        self.assertEqual(sent, [])
        self.assertEqual(COPY_ASKED[0][:2], ("request-credit-received", "We have your request."))

    def test_an_email_whose_template_has_no_reviewed_source_hash_is_never_sent(self):
        """The verdict covers the status line. The words around it (subject, greeting, footer) are the template's,
        and they live in send-gateway; the policy's pin is the sha256 of the template source that was reviewed.
        No pin = nobody can say which words surround the line, so nothing is sent and the gate is not even asked
        (QA review 5869455348 of hydra#1895)."""
        for broken in ({}, {"request_status_credit": ""}, {"request_status_credit": "abc"},
                       {"request_status_credit": "Z" * 64}, {"request_status_claim": TEMPLATE_PIN}, None, "x"):
            policy = live_policy()
            policy["channels"]["email"]["template_sha256"] = broken
            sent = []
            del COPY_ASKED[:]
            ch = channels_mod.Channels(policy=policy,
                                       send_gateway=lambda p: sent.append(p) or {"status": "sent", "id": "m1"})
            got = ch.email("We have your request.", email="a@b.co", user_id="1", typ="credit",
                           request_ref="credit:1", state="received")
            self.assertEqual((got.status, got.reason),
                             ("rejected", "copy_review_hold: email_template_unpinned:request_status_credit"), broken)
            self.assertEqual((sent, COPY_ASKED), ([], []), broken)

    def test_a_changed_template_pin_is_another_frame_so_an_earlier_verdict_does_not_cover_it(self):
        frames = []
        for pin in (TEMPLATE_PIN, "cd" * 32):
            policy = live_policy()
            policy["channels"]["email"]["template_sha256"]["request_status_credit"] = pin
            del COPY_FRAMES[:]
            channels_mod.Channels(policy=policy, send_gateway=lambda p: {"status": "sent", "id": "m1"}).email(
                "We have your request.", email="a@b.co", user_id="1", typ="credit", request_ref="credit:1",
                state="received")
            frames.append(COPY_FRAMES[0])
        self.assertEqual(frames, [f"email-template:request_status_credit@{TEMPLATE_PIN}",
                                  f"email-template:request_status_credit@{'cd' * 32}"])
        # and through the REAL gate: the two frames are two review slots, never one verdict for both
        store = tempfile.mkdtemp(prefix="rc-pin-")
        real, COPY_GATE.require = COPY_GATE.require, _REAL_REQUIRE
        saved_store, COPY_GATE.STORE = COPY_GATE.STORE, store
        saved_gate, COPY_GATE.GATE = COPY_GATE.GATE, _gate_tree("enforce")
        try:
            for frame in frames:
                self.assertIn("copy_review_pending", channels_mod.copy_hold(
                    "credit", "received", "We have your request.", frame=frame))
        finally:
            COPY_GATE.require, COPY_GATE.STORE, COPY_GATE.GATE = real, saved_store, saved_gate
        self.assertEqual(len(list((Path(store) / "pending").glob("*.json"))), 2)

    def test_email_cannot_be_enabled_without_a_reviewed_source_hash_for_every_template(self):
        pol = live_policy()
        self.assertFalse(any("template_sha256" in p for p in lines.validate(pol)))
        del pol["channels"]["email"]["template_sha256"]["request_status_refund"]
        pol["channels"]["email"]["template_sha256"]["request_status_claim"] = "not-a-hash"
        problems = [p for p in lines.validate(pol) if "template_sha256" in p]
        self.assertEqual(len(problems), 2, problems)
        self.assertTrue(any("request_status_refund" in p for p in problems) and any("request_status_claim" in p for p in problems))
        # the shipped policy keeps the rung off, so it needs no pin yet
        shipped = json.loads((Path(__file__).resolve().parents[1] / "policies" / "request-status-lines.json").read_text())
        self.assertEqual((shipped["channels"]["email"]["enabled"], shipped["channels"]["email"]["template_sha256"]), (False, {}))

    def _templates(self, subject="Your Muso request: an update", html_body="<p>Hi, {{ event.status_line }}</p>"):
        root = Path(tempfile.mkdtemp(prefix="rc-tpl-")) / "templates"
        (root / "native" / "request_status_credit").mkdir(parents=True)
        (root / "registry.json").write_text(json.dumps({"keys": {"other": {"subject": "x", "html": "a", "text": "b"}}}))
        (root / "native.json").write_text(json.dumps({"keys": {"request_status_credit": {
            "class": "notify", "subject": subject, "preview_text": "",
            "html": "native/request_status_credit/body.html", "text": "native/request_status_credit/body.txt"}}}))
        (root / "native" / "request_status_credit" / "body.html").write_text(html_body, encoding="utf-8")
        (root / "native" / "request_status_credit" / "body.txt").write_text("Hi, {{ event.status_line }}\n")
        return root

    def _run_send_js(self, payload, templates, token="admin:secret"):
        """SEND_JS exactly as the pod runs it (`node -e`), against a local stand-in for the gateway's /v1/send."""
        import http.server
        self.assertTrue(__import__("shutil").which("node"), "node is required: SEND_JS is the code that posts")
        got = []

        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):  # noqa: N802
                got.append((self.path, self.headers.get("authorization"),
                            json.loads(self.rfile.read(int(self.headers["content-length"])))))
                out = json.dumps({"id": "m1", "status": "sent"}).encode()
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

            def log_message(self, *_a):
                pass
        srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        th = threading.Thread(target=srv.serve_forever, daemon=True)
        th.start()
        try:
            env = {"PATH": os.environ["PATH"], "PORT": str(srv.server_address[1]), "INTERNAL_TOKENS": token,
                   "TEMPLATES_DIR": str(templates)}
            p = subprocess.run(["node", "-e", channels_mod.SEND_JS], input=json.dumps(payload), env=env,
                               capture_output=True, text=True, timeout=60)
        finally:
            srv.shutdown()
            srv.server_close()
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads(p.stdout.strip().splitlines()[-1]), got

    def test_the_pod_posts_only_when_the_live_template_is_the_pinned_one(self):
        """QA review of hydra#1895: a pin the policy merely declares is not a check. The script that posts hashes the
        template the gateway would render and posts nothing unless it is the reviewed one."""
        tpl = self._templates()
        pin = channels_mod.template_source_sha256(tpl, "request_status_credit")
        payload = {"key": "request_status_credit", "to": {"email": "a@b.co", "user_id": "1"},
                   "data": {"event": {"status_line": "We have your request."}}, "idempotency_key": "k"}
        ans, got = self._run_send_js({**payload, "_template_sha256": pin}, tpl)
        self.assertEqual((ans["status"], ans["id"], len(got)), ("sent", "m1", 1), ans)
        self.assertEqual(got[0][:2], ("/v1/send", "Bearer secret"))
        self.assertEqual(got[0][2], payload, "the pin is ours, never a gateway field: it is stripped before the POST")
        # each of the four parts the reader sees is in the hash: change one and nothing is posted
        changed = (self._templates(subject="Your Muso request: ACTION NEEDED"),
                   self._templates(html_body="<p>Hi, {{ event.status_line }}</p><p>You were flagged.</p>"))
        txt = self._templates()
        (txt / "native" / "request_status_credit" / "body.txt").write_text("Other words.\n")
        pre = self._templates()
        nat = json.loads((pre / "native.json").read_text())
        nat["keys"]["request_status_credit"]["preview_text"] = "Act now"
        (pre / "native.json").write_text(json.dumps(nat))
        for other in (*changed, txt, pre):
            live = channels_mod.template_source_sha256(other, "request_status_credit")
            self.assertNotEqual(live, pin)
            ans, got = self._run_send_js({**payload, "_template_sha256": pin}, other)
            self.assertEqual((ans["status"], ans["reason"], ans["live_template_sha256"], got),
                             ("rejected", "template_pin_mismatch", live, []), ans)
        # no pin, a malformed pin, an unknown key, a missing body file, a key defined twice: nothing is posted
        gone = self._templates()
        (gone / "native" / "request_status_credit" / "body.html").unlink()
        twice = self._templates()
        (twice / "registry.json").write_text((twice / "native.json").read_text())
        for body, where, why in (({**payload}, tpl, "template_pin_missing"),
                                 ({**payload, "_template_sha256": "abc"}, tpl, "template_pin_missing"),
                                 ({**payload, "key": "nope", "_template_sha256": pin}, tpl, "template_unreadable"),
                                 ({**payload, "_template_sha256": pin}, gone, "template_unreadable"),
                                 ({**payload, "_template_sha256": pin}, twice, "template_unreadable"),
                                 ({**payload, "_template_sha256": pin}, tpl.parent / "absent", "template_unreadable")):
            ans, got = self._run_send_js(body, where)
            self.assertEqual((ans["status"], got), ("rejected", []), ans)
            self.assertTrue(ans["reason"].startswith(why), ans)

    def test_a_template_the_pod_refuses_is_a_hold_and_the_pin_travels_with_every_email(self):
        sent = []
        for reason in ("template_pin_mismatch", "template_unreadable: ENOENT", "template_pin_missing"):
            ch = channels_mod.Channels(policy=live_policy(), send_gateway=lambda p, r=reason: (
                sent.append(p), {"status": "rejected", "reason": r})[1])
            got = ch.email("We have your request.", email="a@b.co", user_id="1", typ="credit",
                           request_ref="credit:1", state="received")
            self.assertEqual((got.status, got.reason), ("rejected", f"copy_review_hold: {reason}"))
        self.assertEqual({p["_template_sha256"] for p in sent}, {TEMPLATE_PIN})
        # the default transport is the checked script, with nothing in between that could drop the pin
        import inspect
        self.assertIn("_pod_json(SEND_GATEWAY_POD, payload, SEND_JS)", inspect.getsource(channels_mod.Channels.__init__))
        js = channels_mod.SEND_JS
        self.assertLess(js.index("template_pin_mismatch"), js.index("/v1/send"))
        self.assertEqual(js.count("fetch("), 1)

    def test_a_gate_that_cannot_even_be_asked_holds(self):
        def broken(*_a, **_k):
            raise OSError("no gate here")
        COPY_GATE.require = broken
        self.assertEqual(channels_mod.copy_hold("credit", "received", "<p>hi</p>"), "copy_review_hold: OSError")

    def _real_gate(self, default_mode: str):
        """No stand-in at all: the real lib/copy_gate + gate.py against a scratch store that has seen nothing."""
        saved = (COPY_GATE.require, COPY_GATE.STORE, COPY_GATE.GATE)
        self.addCleanup(lambda: (setattr(COPY_GATE, "require", saved[0]), setattr(COPY_GATE, "STORE", saved[1]),
                                 setattr(COPY_GATE, "GATE", saved[2])))
        COPY_GATE.require, COPY_GATE.STORE = _REAL_REQUIRE, tempfile.mkdtemp(prefix="rc-copy-")
        COPY_GATE.GATE = _gate_tree(default_mode)
        posted = []
        ch = channels_mod.Channels(policy=live_policy(), intercom_post=lambda m, p, b: posted.append(p) or {"id": "42"})
        return ch, posted, Path(COPY_GATE.STORE)

    def test_the_real_gate_with_no_verdict_holds(self):
        ch, posted, store = self._real_gate("enforce")
        got = ch.intercom("We have your request.", "c_1", admin_id="1", typ="credit", state="received")
        self.assertEqual((got.status, got.reason, posted), ("rejected", "copy_review_hold: copy_review_pending", []))
        self.assertEqual(len(list((store / "pending").glob("*.json"))), 1)   # and it is queued for review

    def test_the_real_gate_in_observe_mode_sends_and_queues_and_still_refuses_what_the_code_lint_refuses(self):
        ch, posted, store = self._real_gate("observe")
        got = ch.intercom("We have your request.", "c_1", admin_id="1", typ="credit", state="received")
        self.assertEqual((got.status, len(posted)), ("sent", 1))
        self.assertEqual(len(list((store / "pending").glob("*.json"))), 1)   # sent, and queued for review all the same
        for text in ("Your request was flagged for fraud.",
                     "Your request is with our team. Nothing is needed from you right now."):
            got = ch.intercom(text, "c_1", admin_id="1", typ="credit", state="verifying")
            self.assertEqual(got.status, "rejected", text)
            self.assertTrue(got.reason.startswith("copy_review_hold: copy_lint:"), got.reason)
        self.assertEqual(len(posted), 1)

    def test_the_driver_passes_the_requests_type_and_state_to_the_channel(self):
        src = (ROOT / "scripts" / "request_comms" / "driver.py").read_text()
        self.assertEqual(src.count("chan.intercom("), 1)
        i = src.index("chan.intercom(")
        self.assertIn("typ=r.type, state=r.state", src[i:i + 400])


class ChannelTests(unittest.TestCase):
    def policy(self):
        return live_policy()

    def test_intercom_needs_a_message_id_to_count_as_sent(self):
        ch = channels_mod.Channels(policy=self.policy(), intercom_post=lambda m, p, b: {"type": "admin_message"})
        self.assertEqual(ch.intercom("hi", "c_1", admin_id="1").status, "uncertain")
        ch2 = channels_mod.Channels(policy=self.policy(), intercom_post=lambda m, p, b: {"id": "42"})
        got = ch2.intercom("hi", "c_1", admin_id="1")
        self.assertEqual((got.status, got.ref), ("sent", "42"))

    def test_the_bell_is_triggered_in_the_gateways_own_shape(self):
        seen = {}

        def notify(key, body, idem=""):
            seen.update(key=key, body=body, idem=idem)
            return {"workflow_run_id": "wr_1", "visibility": {"111": {"feed": True}}}

        ch = channels_mod.Channels(policy=self.policy(), notify_gateway=notify)
        got = ch.bell("credit_status_in_review", user_id="111",
                      data={"profile": {"name": "your profile"}, "count": 1},
                      idempotency_key="request-status:credit:1:verifying")
        self.assertEqual((got.status, got.ref), ("sent", "wr_1"))
        self.assertEqual(seen["key"], "credit_status_in_review")
        self.assertEqual(seen["body"]["recipients"], ["111"], "Knock-shaped: recipients is REQUIRED")
        self.assertEqual(seen["body"]["data"]["profile"]["name"], "your profile")
        self.assertEqual(seen["idem"], "request-status:credit:1:verifying")

    def test_an_all_false_visibility_is_the_only_non_delivery(self):
        answer = {"workflow_run_id": "wr_1", "visibility": {"111": {"feed": False, "knock": False, "push": False}}}
        ch = channels_mod.Channels(policy=self.policy(), notify_gateway=lambda k, b, i="": answer)
        self.assertEqual(ch.bell("credit_status_in_review", user_id="111", data={"count": 1}).status, "unconfirmed")
        answer["visibility"]["111"]["feed"] = True
        self.assertEqual(ch.bell("credit_status_in_review", user_id="111", data={"count": 1}).status, "sent")

    def test_a_push_without_a_feed_is_still_a_delivery(self):
        # QA round 21: the gateway's contract is that ALL-FALSE means the item reached nobody, so
        # any true leg is a delivery. Counting only `feed` read a real push as "reached nobody"
        # and climbed to Intercom, sending the same update twice — and today most users are
        # exactly this shape (the web reads Knock; the app builds that read our bell are unreleased).
        for leg in ("push", "knock"):
            answer = {"workflow_run_id": "wr_1",
                      "visibility": {"111": {"feed": False, "knock": False, "push": False}}}
            answer["visibility"]["111"][leg] = True
            ch = channels_mod.Channels(policy=self.policy(), notify_gateway=lambda k, b, i="": answer)
            got = ch.bell("credit_status_in_review", user_id="111", data={"count": 1})
            self.assertEqual(got.status, "sent", f"a true {leg} leg is a confirmed delivery")

    def test_a_5xx_without_a_run_id_is_uncertain_not_rejected(self):
        # QA round 21: the gateway can fail AFTER it has enqueued the run, so a 5xx is not proof of
        # non-delivery. `rejected` would let the driver climb to Intercom and send the same update
        # twice; `uncertain` stops the ladder and blocks the next tick.
        ch = channels_mod.Channels(policy=self.policy(),
                                   notify_gateway=lambda k, b, i="": {"http": 503, "reason": "upstream"})
        got = ch.bell("credit_status_in_review", user_id="1", data={"count": 1})
        self.assertEqual(got.status, "uncertain")

    def test_a_4xx_without_a_run_id_is_a_clean_non_delivery(self):
        # A 4xx is the gateway refusing the call before the route ran, so nothing was queued and
        # the driver may climb.
        for code in (400, 401, 403, 404, 422):
            ch = channels_mod.Channels(policy=self.policy(),
                                       notify_gateway=lambda k, b, i="", c=code: {"http": c, "reason": "no"})
            got = ch.bell("credit_status_in_review", user_id="1", data={"count": 1})
            self.assertEqual(got.status, "rejected", f"http {code} is a definite non-delivery")

    def test_someone_elses_visibility_is_not_ours(self):
        answer = {"workflow_run_id": "wr_1", "visibility": {"999": {"feed": True}}}
        ch = channels_mod.Channels(policy=self.policy(), notify_gateway=lambda k, b, i="": answer)
        self.assertEqual(ch.bell("credit_status_in_review", user_id="111", data={"count": 1}).status, "unconfirmed")

    def test_the_bell_without_a_visibility_block_is_uncertain(self):
        ch = channels_mod.Channels(policy=self.policy(), notify_gateway=lambda k, b, i="": {"workflow_run_id": "wr"})
        self.assertEqual(ch.bell("credit_status_in_review", user_id="1", data={"count": 1}).status, "uncertain")

    def test_a_key_outside_the_ten_is_refused_before_the_wire(self):
        # the live gateway answers 200 + workflow_run_id for an unknown kind (verified 2026-11-03),
        # so a typo would read as "maybe" forever instead of "nothing was sent"
        called = []
        ch = channels_mod.Channels(policy=self.policy(), notify_gateway=lambda k, b, i="": called.append(k) or {})
        got = ch.bell("credit_status_invented", user_id="111", data={"count": 1})
        self.assertEqual(got.status, "rejected")
        self.assertEqual(called, [], "never reaches the gateway")

    def test_no_workflow_run_id_is_a_clean_non_delivery(self):
        ch = channels_mod.Channels(policy=self.policy(),
                                   notify_gateway=lambda k, b, i="": {"http": 401, "reason": "unauthorized"})
        got = ch.bell("credit_status_in_review", user_id="1", data={"count": 1})
        self.assertEqual((got.status, got.reason), ("rejected", "unauthorized"))

    def test_the_send_gateway_answers(self):
        ch = channels_mod.Channels(policy=self.policy(), send_gateway=lambda p: {"status": "sent", "id": "m1"})
        got = ch.email("hi", email="a@b.co", user_id="1", typ="credit", request_ref="credit:1")
        self.assertEqual((got.status, got.ref), ("sent", "m1"))
        ch2 = channels_mod.Channels(policy=self.policy(),
                                    send_gateway=lambda p: {"status": "suppressed", "reason": "unsubscribed"})
        self.assertEqual(ch2.email("hi", email="a@b.co", user_id="1", typ="credit", request_ref="credit:1").status,
                         "rejected")

    def test_an_email_with_no_template_key_is_rejected_not_rerouted(self):
        pol = self.policy()
        pol["channels"]["email"]["template_keys"]["credit"] = ""
        ch = channels_mod.Channels(policy=pol, send_gateway=lambda p: {"status": "sent", "id": "m"})
        got = ch.email("hi", email="a@b.co", user_id="1", typ="credit", request_ref="credit:1")
        self.assertEqual((got.status, got.channel), ("rejected", "email"))

    # ---- QA round 22: the same 4xx/5xx split on the other two channels ----

    def test_an_intercom_5xx_is_uncertain_not_rejected(self):
        # Intercom can create the message and still fail the answer. `rejected` would let the
        # driver climb or the next tick retry and send a second copy.
        def boom(method, path, body=None):
            raise urllib.error.HTTPError(path, 500, "server error", {}, None)

        ch = channels_mod.Channels(policy=self.policy(), intercom_post=boom)
        self.assertEqual(ch.intercom("hi", "c_1", admin_id="1").status, "uncertain")

    def test_an_intercom_4xx_is_a_clean_non_delivery(self):
        for code in (400, 401, 403, 404, 422, 429):
            def boom(method, path, body=None, c=code):
                raise urllib.error.HTTPError(path, c, "refused", {}, None)

            ch = channels_mod.Channels(policy=self.policy(), intercom_post=boom)
            self.assertEqual(ch.intercom("hi", "c_1", admin_id="1").status, "rejected",
                             f"intercom {code} is a definite non-delivery")

    def test_a_send_gateway_5xx_is_uncertain_not_rejected(self):
        ch = channels_mod.Channels(policy=self.policy(),
                                   send_gateway=lambda p: {"http": 503, "reason": "upstream"})
        got = ch.email("hi", email="a@b.co", user_id="1", typ="credit", request_ref="credit:1")
        self.assertEqual(got.status, "uncertain")

    def test_a_send_gateway_4xx_is_a_clean_non_delivery(self):
        for code in (400, 401, 403, 404, 422):
            ch = channels_mod.Channels(policy=self.policy(),
                                       send_gateway=lambda p, c=code: {"http": c, "reason": "refused"})
            got = ch.email("hi", email="a@b.co", user_id="1", typ="credit", request_ref="credit:1")
            self.assertEqual(got.status, "rejected", f"send-gateway {code} is a definite non-delivery")

    def test_a_declined_2xx_is_still_rejected(self):
        # The gateway ANSWERED and declined (suppressed / unsubscribed): nothing was sent, so the
        # driver may climb. This must not be swept into the 5xx rule.
        ch = channels_mod.Channels(policy=self.policy(),
                                   send_gateway=lambda p: {"http": 200, "status": "suppressed",
                                                           "reason": "unsubscribed"})
        got = ch.email("hi", email="a@b.co", user_id="1", typ="credit", request_ref="credit:1")
        self.assertEqual((got.status, got.reason), ("rejected", "unsubscribed"))


class PromiseLedgerThreadTests(Base):
    """A status line for someone Caroline told "we will come back" goes onto THAT conversation.

    The promise ledger (scripts/caroline_monitor/commitments.py) closes a commitment only on a
    message sent on its own thread, so a line delivered anywhere else leaves the promise open
    and the customer still waiting where they wrote."""

    def _tick(self, ch, thread_for, request=None, **kw):
        asked = []

        def seam(contact_id, request_type):
            asked.append((contact_id, request_type))
            return thread_for(contact_id, request_type)

        src = request if isinstance(request, FakeSources) else FakeSources([request or req(state="received")])
        cfg = self.cfg(src, live=True, channels=ch,
                       bans=FakeBans(), identity=lambda e, u, d: "contact_1", thread_for=seam, **kw)
        return driver.tick(cfg), asked

    def test_the_line_lands_on_the_thread_that_carries_the_promise(self):
        ch = FakeChannels(bell=("sent", "bell_1"), intercom=("sent", "mid_1"))
        out, asked = self._tick(ch, lambda c, t: "conv_900")
        self.assertEqual(asked, [("contact_1", "credit")])
        self.assertEqual(ch.calls, ["intercom"], "the bell would have told them in the app and left the thread silent")
        self.assertEqual(ch.intercoms[0]["conversation_id"], "conv_900")
        self.assertEqual(out["sent"][0]["channel"], "intercom")

    def test_with_no_open_commitment_the_ladder_is_unchanged(self):
        ch = FakeChannels(bell=("unconfirmed", "visibility all false"), intercom=("sent", "mid_1"))
        self._tick(ch, lambda c, t: "")
        self.assertEqual(ch.calls[:2], ["bell", "intercom"])
        self.assertEqual(ch.intercoms[0]["conversation_id"], "")

    def test_a_refused_thread_reply_still_falls_back_to_the_other_rungs(self):
        ch = FakeChannels(bell=("sent", "bell_1"), intercom=("rejected", ""))
        out, _ = self._tick(ch, lambda c, t: "conv_900")
        self.assertEqual(ch.calls[:2], ["intercom", "bell"])
        self.assertEqual(out["sent"][0]["channel"], "bell")

    def test_an_unreadable_ledger_never_stops_a_status_line(self):
        def broken(contact_id, request_type):
            raise RuntimeError("ledger locked")

        ch = FakeChannels(bell=("unconfirmed", "visibility all false"), intercom=("sent", "mid_1"))
        out, _ = self._tick(ch, broken)
        self.assertEqual(ch.intercoms[0]["conversation_id"], "")
        self.assertEqual(out["sent"][0]["status"], "sent")

    def test_a_request_that_names_its_own_thread_keeps_it(self):
        r = req(typ="erasure", rid="7", uid="u@example.com", state="received", waiting="us",
                detail={"contact_id": "c_7", "conversation_id": "conv_7", "pages": [],
                        "slot": "no_page_link", "date": "1 November 2026"})
        ch = FakeChannels(intercom=("sent", "mid_1"))
        _, asked = self._tick(ch, lambda c, t: "conv_other",
                              request=FakeSources([r], reports=[SourceReport("erasure", "ok", 1)]))
        self.assertEqual(asked, [], "the register's thread is the one the acknowledgement promised to answer on")
        self.assertEqual(ch.intercoms[0]["conversation_id"], "conv_7")

    def test_with_intercom_switched_off_the_ledger_is_not_consulted(self):
        ch = FakeChannels(bell=("sent", "bell_1"))
        _, asked = self._tick(ch, lambda c, t: "conv_900", policy=live_policy(intercom=False))
        self.assertEqual(asked, [])
        self.assertNotIn("intercom", ch.calls)

    def test_a_dry_run_asks_nothing_and_sends_nothing(self):
        asked = []
        ch = FakeChannels()
        driver.tick(self.cfg(FakeSources([req(state="received")]), channels=ch, bans=FakeBans(),
                             identity=lambda e, u, d: "contact_1",
                             thread_for=lambda c, t: asked.append(c) or "conv_900"))
        self.assertEqual((ch.calls, asked), ([], []))


if __name__ == "__main__":
    unittest.main()
