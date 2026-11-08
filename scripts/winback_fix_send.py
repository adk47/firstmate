#!/usr/bin/env python3
"""winback_fix_send.py — one personalized note per user whose fix was Seen. Nobody else.

Stage 3 of 3 (rulings R2, R5, R6). This is the only script that can produce a customer message,
and it can only produce one from a ticket that ``fix_readback.py`` marked Seen with evidence. It
renders the fixed copy from ``policies/winback-fix.json``, runs the guard chain, applies the
exclusion list, and then claims the one message this campaign may ever send that user in its own
ledger AND writes the hand-off manifest in a single transaction - it does not send. The single
sender seat (``verify-sla-driver-fable-d2``) owns sending, the fleet daily cap and the gateway's
own gates (suppression, unsubscribe, marketing frequency, one-per-day).

A guard that refuses a body refuses the BATCH: the fault is in the copy or the policy, not in any
user, so nothing is sent, no ticket is marked ineligible, and a corrected policy can send tomorrow.
The one exception is the sentence quoted from a human reply (cause class ``other``): a violation
that lives inside that quote belongs to that answer, so only that user's ticket is closed and the
rest of the batch continues. A render refusal that is a POLICY gap (a missing slug, link, amount or
GO) is recorded on the ticket and leaves it sendable; only a per-user dead end (no approved credit,
no answer to quote) closes a ticket as ineligible. A manifest that cannot be written rolls the
claims back with it, and one that cannot be published after the commit releases them, so no user's
one message is spent on a batch that never reached the sender seat.

Three independent switches must all be on before a manifest is written, and a dry run is the
default:

    1 policys template.enabled == true  AND template.fable_go_ref is set   (the Fable GO)
    2 --live on the command line
    3 the live flag file exists (/etc/hydra/winback-fix.live)

    ./scripts/winback_fix_send.py                     # dry run: render + guard + counts
    ./scripts/winback_fix_send.py --render-proof 6    # the six FIX_LINE variants, for copy review
    ./scripts/winback_fix_send.py --dry-run --limit 5 # read five real bodies on stderr
    ./scripts/winback_fix_send.py --live              # hand a batch to the sender seat

Exit codes: 0 nothing to send / dry run ok, 1 the ledger or policy could not be read, 2 the
live switches are not all on, or a guard or a policy gap refused the whole batch (nothing sent,
no ticket moved), 3 every candidate was held (with the reason counts on stderr - a run that holds
everyone is a signal, not a no-op), 4 the manifest could not be written or published (the ledger
claims rolled back or were released).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from churn import audience, cli, coupons, guards, model, readback, render, tickets  # noqa: E402

PROOF_EVIDENCE = {
    "credits_not_approved": {"credits_approved": 3, "credits_declined": 1},
    "proof_sent_no_update": {"credits_approved": 2},
    "merge_claim_stuck": {"merge_claim_result": "merge"},
    "analytics_stale_wrong": {"platform": "Spotify", "as_of": "2026-11-02"},
    "billing_confusion": {"refund_amount": "49.00"},
    "other": {},
}
PROOF_REPLY = (
    "You were right that the two profiles are the same person, and I am sorry it took us this long to "
    "say so. I have merged the second profile into the one you log in with, moved every credit across, "
    "and the duplicate no longer appears in search results when anyone looks for your name anywhere on "
    "the platform, so everything now sits on the account you actually use. Nothing else about your "
    "account changed."
)


def _switches(policy: dict[str, Any], *, live_flag: Path) -> tuple[bool, list[str]]:
    """(may write a manifest, reasons it may not)."""
    template = policy.get("template") or {}
    why: list[str] = []
    if not template.get("enabled"):
        why.append("policy template.enabled is false (Fable GO not recorded)")
    if not str(template.get("fable_go_ref") or "").strip():
        why.append("policy template.fable_go_ref is empty (the GO reference is part of the switch)")
    if not live_flag.exists():
        why.append(f"live flag {live_flag} does not exist")
    return (not why), why


def render_proof(policy: dict[str, Any], *, count: int) -> int:
    """Render the six FIX_LINE variants from labelled example evidence, for copy review only."""
    print("# wb_fix_1 rendered proof - EXAMPLE read-back values; no user was messaged.\n")
    for cause in model.CLASSES[: max(count, 1)]:
        ticket = _Stub(ticket_id=f"proof-{cause}", user_id="proof", primary_class=cause, lane="proof",
                       cancel_at=time.time() - 30 * 86400,
                       candidate={"plan": "muso_team_pro_graduated_monthly", "reason": "cancellation_requested"})
        rendered = render.render(ticket=ticket, policy=policy, recipient={"first_name": "Sam"},
                                 human_reply=PROOF_REPLY if cause == "other" else None)
        verdict = guards.check_rendered(rendered, policy)
        print(f"## {cause}  (guard: {'pass' if verdict.ok else 'BLOCKED'})\n")
        print(f"Subject: {rendered.subject}\n")
        print((rendered.body or "(refused: " + str(rendered.ineligible_reason) + ")") + "\n")
        if not verdict.ok:
            print(f"guard violations: {verdict.reason()}\n")
    print("_Rendered by scripts/winback_fix_send.py --render-proof. Evidence values are examples; the "
          "real numbers come from each user's read-back, and a variant whose numbers cannot be filled "
          "makes that user INELIGIBLE rather than sending a guess._")
    return 0


class _Stub:
    """A ticket-shaped object for the render proof (no ledger, no user)."""

    def __init__(self, **kw: Any):
        self.ticket_id = kw["ticket_id"]
        self.user_id = kw["user_id"]
        self.primary_class = kw["primary_class"]
        self.lane = kw["lane"]
        self.cancel_at = kw["cancel_at"]
        self.candidate = kw["candidate"]
        self.readback = PROOF_EVIDENCE.get(kw["primary_class"], {})
        self.mrr_cents = 4900
        self.tier = "T2-open-told-wait"


def main(argv: list[str] | None = None) -> int:
    ap = cli.add_common(argparse.ArgumentParser(description="Render, guard, ledger and hand off wb_fix_1."))
    ap.add_argument("--live", action="store_true", help="actually write a hand-off manifest (needs all switches)")
    ap.add_argument("--dry-run", action="store_true", help="the default; kept so a cron line can be explicit")
    ap.add_argument("--limit", type=int, default=0, help="at most N messages this run")
    ap.add_argument("--render-proof", type=int, default=0, metavar="N",
                    help="print rendered variants from example evidence and exit (copy review)")
    ap.add_argument("--live-flag", default=None, help="live flag path (default: /etc/hydra/winback-fix.live)")
    ap.add_argument("--ledger", default=None, help="credit-review ledger path")
    ap.add_argument("--show", type=int, default=0, help="print the first N rendered bodies to stderr")
    ap.add_argument("--no-people-lookup", action="store_true",
                    help="skip the core read (dry runs without Trino); refuses to go --live")
    args = ap.parse_args(argv)

    policy = cli.load_policy(args.policy)
    if args.render_proof:
        return render_proof(policy, count=args.render_proof)

    state_dir = cli.state_dir(policy, args.state_dir)
    db_path = state_dir / "tickets.sqlite"
    if not db_path.exists():
        cli.log(f"no ledger at {db_path}: nothing has been routed yet")
        return 1

    flag = cli.live_flag(policy, args.live_flag)
    may_write, why = _switches(policy, live_flag=flag)
    live = bool(args.live) and not args.dry_run
    if live and args.no_people_lookup:
        cli.log("--live with --no-people-lookup would message unvetted users: refusing")
        cli.emit({"stage": "send", "live_refused": ["--live with --no-people-lookup"], "handoff": None})
        return 2
    if live and not may_write:
        for reason in why:
            cli.log(f"live refused: {reason}")
        cli.emit({"stage": "send", "live_refused": why, "handoff": None})
        return 2

    now = time.time()
    window = int((policy.get("windows") or {}).get("fix_eligible_days") or 7)
    cap = int(((policy.get("caps") or {}).get("per_run") or 0))
    limit = args.limit or cap or 0

    sources = readback.Sources(ledger=args.ledger or readback.LEDGER_DEFAULT)
    with tickets.TicketStore(db_path) as store:
        eligible = store.eligible(window, now=now)
        people: dict[str, audience.Recipient] = {}
        batch = None
        if eligible and not args.no_people_lookup:
            try:
                people = audience.resolve_people([t.user_id for t in eligible], run_sql=sources.run_sql)
            except Exception as exc:  # noqa: BLE001 - a core read we do not control
                cli.log(f"core read failed, holding every candidate: {type(exc).__name__}: {exc}")
                cli.emit({"stage": "send", "held": {"core_read_failed": len(eligible)}, "handoff": None})
                return 3
        if not eligible:
            doc = {"stage": "send", "at": now, "live": live, "dry_run": not live,
                   "switches": {"may_write": may_write, "why_not": why},
                   "eligible_tickets": 0, "send": 0, "hold": {}, "holdout": 0,
                   "render_or_guard_refused": {}, "handoff": None,
                   "sender_seat": (policy.get("sender_seat") or {}).get("owner"), "coupons": {},
                   **_coupon_report([], {})}
            cli.emit(doc)
            cli.log(f"nothing is Seen and inside the {window}-day window: no message is owed to anyone")
            return 0
        try:
            watchlist = _watchlist(policy)
            verdicts = _affiliation(policy)
        except SystemExit as exc:
            if live:
                raise
            # A rehearsal on a host without the trust inputs still has to be honest: everyone is
            # held, and the reason is on the record. It just must not consume a ledger row.
            cli.log(f"trust inputs unavailable ({exc}); every candidate is held")
            cli.emit({"stage": "send", "live": False, "eligible_tickets": len(eligible), "send": 0,
                      "hold": {f"unreadable: {exc}": len(eligible)}, "handoff": None})
            return 3
        batch = audience.select(
            eligible, policy=policy, people=people, watchlist=watchlist, verdicts=verdicts,
            already_messaged=store.messaged, cap=limit or None,
        )

        messages: list[dict[str, Any]] = []
        claims: list[tuple[dict[str, Any], tickets.Ticket]] = []
        refused: dict[str, int] = {}
        fixable_gaps: dict[str, int] = {}
        batch_refusals: list[str] = []
        coupon_verdicts: dict[str, int] = {}
        coupon_check = coupons.CouponCheck(run=None if live else coupons.offline)
        for decision in batch.send:
            ticket = next(t for t in eligible if str(t.user_id) == decision.user_id)
            regional_coupon = _regional_coupon(ticket, coupon_check)
            if regional_coupon:
                coupon_verdicts[regional_coupon] = coupon_verdicts.get(regional_coupon, 0) + 1
            rendered = render.render(ticket=ticket, policy=policy,
                                     recipient={"first_name": (decision.recipient.first_name
                                                               if decision.recipient else "")},
                                     human_reply=(ticket.readback or {}).get("human_reply"),
                                     regional_coupon=regional_coupon)
            if not rendered.eligible:
                reason = str(rendered.ineligible_reason or "render ineligible")
                if rendered.ineligible_fixable:
                    # A policy gap: fixable by editing the copy, so the ticket stays sendable and
                    # the reason is on the record rather than closing the user out for good.
                    fixable_gaps[reason] = fixable_gaps.get(reason, 0) + 1
                    if live:
                        store.note(ticket.ticket_id, event="render:policy-gap", detail={"reason": reason})
                    continue
                refused[reason] = refused.get(reason, 0) + 1
                if live:
                    store.mark_ineligible(ticket.ticket_id, reason=reason, evidence=ticket.readback or {})
                continue
            verdict = guards.check_rendered(rendered, policy)
            if not verdict.ok:
                fault = guards.quoted_fragment_fault(rendered, policy)
                if fault:
                    refused[fault] = refused.get(fault, 0) + 1
                    if live:
                        store.mark_ineligible(ticket.ticket_id, reason=fault,
                                              evidence=ticket.readback or {})
                    continue
                batch_refusals.append(verdict.reason()[:200])
                continue
            body_sha = hashlib.sha256(f"{rendered.subject}\n{rendered.body}".encode()).hexdigest()
            if args.show and len(messages) < args.show:
                print(f"--- {decision.user_id} ({ticket.primary_class}) ---\n"
                      f"Subject: {rendered.subject}\n\n{rendered.body}\n", file=sys.stderr)
            message = {
                "user_id": decision.user_id,
                "ticket_id": ticket.ticket_id,
                "cause_class": ticket.primary_class,
                "tier": ticket.tier,
                "list_mrr_cents": ticket.mrr_cents,
                "email": (decision.recipient.email if decision.recipient else ""),
                "first_name": rendered_body_first_name(rendered, decision),
                "subject": rendered.subject,
                "body": rendered.body,
                "coupon": rendered.coupon,
                "regional_coupon": regional_coupon,
                "variant": rendered.variant,
                "body_sha256": body_sha,
                "guards": verdict.as_dict(),
            }
            messages.append(message)
            claims.append((message, ticket))

        if batch_refusals or (fixable_gaps and not messages):
            # A guard failure or a policy gap is a property of the COPY or the POLICY, not of the
            # user: refusing the batch (and touching no ticket) keeps them message-eligible once
            # the copy is fixed, instead of burning a batch of people to a permanent `ineligible`.
            doc = {
                "stage": "send",
                "at": now,
                "live": live,
                "dry_run": not live,
                "switches": {"may_write": may_write, "why_not": why},
                "eligible_tickets": len(eligible),
                "send": 0,
                "hold": batch.reasons(),
                "holdout": len(batch.holdout),
                "refused": ["refused the batch: " + reason for reason in batch_refusals[:20]],
                "policy_gaps": dict(sorted(fixable_gaps.items())),
                "render_or_guard_refused": dict(sorted(refused.items(), key=lambda kv: (-kv[1], kv[0]))),
                "handoff": None,
                "sender_seat": (policy.get("sender_seat") or {}).get("owner"),
                "coupons": {},
                "refused_reason": ("the batch was refused: "
                                   + (batch_refusals[0] if batch_refusals
                                      else next(iter(fixable_gaps), "a policy gap"))),
                **_coupon_report([], {}),
            }
            for reason in batch_refusals[:20]:
                cli.log(f"guard refused the batch, so nothing is sent and no ticket moved: {reason}")
            for reason, count in sorted(fixable_gaps.items()):
                cli.log(f"policy gap held {count} ticket(s) with no message and no state change: {reason}")
            if not args.dry_run:
                cli.write_report(doc, state=state_dir, name="send-live" if live else "send-rehearsal")
            cli.emit(doc)
            return 2

        handoff = None
        staged: Path | None = None
        claimed: list[dict[str, Any]] = []
        committed = False
        if messages and live and may_write:
            try:
                with store.transaction():
                    claimed = [m for m, ticket in claims
                               if store.ledger_row(user_id=m["user_id"], ticket=ticket,
                                                   body_sha256=m["body_sha256"], state="handed",
                                                   detail="handed to sender seat", now=now, commit=False)]
                    if claimed:
                        staged = _write_manifest(claimed, policy=policy, state_dir=state_dir, now=now)
                committed = True
                if len(claimed) < len(messages):
                    refused["campaign_once"] = refused.get("campaign_once", 0) + (len(messages) - len(claimed))
                messages = claimed
                if staged is not None:
                    handoff = _publish_manifest(staged)
                    staged = None
            except (OSError, sqlite3.Error) as exc:
                # A manifest that never became visible must not consume anyone's one message: the
                # claims roll back with a write that failed inside the transaction, and a publish
                # that failed after the commit releases the rows it had already claimed.
                if staged is not None:
                    try:
                        staged.unlink()
                    except OSError:
                        pass
                if committed and claimed:
                    store.release_claims(
                        [m["user_id"] for m in claimed], now=now,
                        detail=f"the hand-off manifest could not be published: {type(exc).__name__}")
                cli.log(f"the hand-off manifest could not be written ({type(exc).__name__}: {exc}): "
                        "no message was handed off and no ledger row was claimed")
                doc = {
                    "stage": "send",
                    "at": now,
                    "live": live,
                    "dry_run": False,
                    "manifest_refused": f"{type(exc).__name__}: {exc}",
                    "switches": {"may_write": may_write, "why_not": why},
                    "eligible_tickets": len(eligible),
                    "send": 0,
                    "hold": batch.reasons(),
                    "holdout": len(batch.holdout),
                    "policy_gaps": dict(sorted(fixable_gaps.items())),
                    "render_or_guard_refused": dict(sorted(refused.items(), key=lambda kv: (-kv[1], kv[0]))),
                    "handoff": None,
                    "sender_seat": (policy.get("sender_seat") or {}).get("owner"),
                    "coupons": {},
                    "refused_reason": f"the hand-off manifest could not be written: {type(exc).__name__}: {exc}",
                    **_coupon_report([], {}),
                }
                cli.write_report(doc, state=state_dir, name="send-live")
                cli.emit(doc)
                return 4
        doc = {
            "stage": "send",
            "at": now,
            "live": live,
            "dry_run": not live,
            "switches": {"may_write": may_write, "why_not": why},
            "eligible_tickets": len(eligible),
            "send": len(messages),
            "hold": batch.reasons(),
            "holdout": len(batch.holdout),
            "policy_gaps": dict(sorted(fixable_gaps.items())),
            "render_or_guard_refused": dict(sorted(refused.items(), key=lambda kv: (-kv[1], kv[0]))),
            "handoff": str(handoff) if handoff else None,
            "sender_seat": (policy.get("sender_seat") or {}).get("owner"),
            "coupons": _coupon_counts(messages),
            **_coupon_report(messages, coupon_verdicts),
        }
        if not args.dry_run:
            # A rehearsal must never overwrite the record of a live hand-off (or the reverse):
            # "what did we actually send" is answered from this file after the fact.
            cli.write_report(doc, state=state_dir, name="send-live" if live else "send-rehearsal")
        cli.emit(doc)
    cli.log(f"{'handed off' if live else 'would send'} {len(messages)} of {len(eligible)} Seen tickets "
            f"(holdout {len(batch.holdout)}, held {sum(batch.reasons().values())}, refused {sum(refused.values())})")
    if eligible and not messages and batch.reasons():
        return 3
    return 0


def rendered_body_first_name(rendered: Any, decision: audience.Decision) -> str:
    """The greeting name we actually rendered with (not necessarily the core first name)."""
    return render.first_name(decision.recipient.first_name if decision.recipient else "")


def _regional_coupon(ticket: Any, check: coupons.CouponCheck) -> str | None:
    """The at-send coupon verdict for a Regional Discount ticket, or None for everyone else."""
    cand = dict(getattr(ticket, "candidate", None) or {})
    discount = str(cand.get("discount") or "")
    if "regional" not in discount.lower():
        return None
    return check.verdict(cand.get("customer_id"), discount)


def _coupon_report(messages: list[dict[str, Any]], verdicts: dict[str, int]) -> dict[str, int]:
    """The Fable owner's first-day numbers: who got the regional sentence and who did not."""
    return {
        "sent_with_suffix": sum(1 for m in messages if m.get("regional_coupon") == coupons.HELD),
        "sent_without_suffix": sum(1 for m in messages
                                   if m.get("regional_coupon") in (coupons.LAPSED, coupons.UNVERIFIED)),
        "held_coupon_lapsed": verdicts.get(coupons.LAPSED, 0),
        "coupon_unverified": verdicts.get(coupons.UNVERIFIED, 0),
    }


def _coupon_counts(messages: list[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for m in messages:
        key = str(m.get("coupon") or "none")
        counts[key] = counts.get(key, 0) + 1
    return dict(sorted(counts.items()))


def _watchlist(policy: dict[str, Any]) -> Any:
    """policies/fraud-watchlist.json. A malformed or missing watchlist is FATAL (never 'nobody')."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from credit_review import watchlist as watchlist_mod  # noqa: PLC0415

    try:
        return watchlist_mod.load()
    except ValueError as exc:
        raise SystemExit(f"fraud watchlist unusable, refusing to send: {exc}") from exc


def _affiliation(policy: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """The affiliation verdicts. Unreadable is fatal: unknown affiliation is never a pass."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from credit_review import affiliation  # noqa: PLC0415

    try:
        return affiliation.read()
    except (OSError, ValueError) as exc:
        raise SystemExit(f"org-affiliation verdicts unusable, refusing to send: {exc}") from exc


def _write_manifest(messages: list[dict[str, Any]], *, policy: dict[str, Any], state_dir: Path,
                    now: float) -> Path:
    """Stage the hand-off to the single sender seat. 0600: it is the only file with bodies + addresses.

    Returns the staged path; ``_publish_manifest`` gives it the name the sender seat reads, and
    only after the claims that produced it are committed.
    """
    handoff_dir = state_dir / str((policy.get("sender_seat") or {}).get("handoff_dir") or "outbound")
    handoff_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now))
    # Two live batches can start inside the same second; a stamp-only name made the second
    # hand-off overwrite the first, and one batch's claims then pointed at no file.
    path = handoff_dir / f"wb_fix_1-{stamp}-{os.urandom(4).hex()}.json"
    doc = {
        "campaign": "wb_fix_1",
        "created_at": now,
        "policy_sha256": hashlib.sha256(
            json.dumps(policy, sort_keys=True).encode()).hexdigest(),
        "sender_seat": (policy.get("sender_seat") or {}).get("owner"),
        "send_from": "the sender seat only: this file is a hand-off, not a send",
        "gateway_owns": ["suppression", "unsubscribe", "marketing_7d", "one_per_day"],
        "count": len(messages),
        "messages": messages,
    }
    tmp = path.with_suffix(".json.tmp")
    # O_EXCL: a name collision must fail the batch (and release its claims), never truncate a
    # hand-off another run already staged.
    fd = os.open(tmp, os.O_CREAT | os.O_WRONLY | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(doc, indent=1, sort_keys=True) + "\n")
    os.chmod(tmp, 0o600)
    return tmp


def _publish_manifest(staged: Path) -> Path:
    """Make the staged hand-off visible to the sender seat, only once its claims are committed."""
    final = staged.with_suffix("")
    os.replace(staged, final)
    return final


if __name__ == "__main__":
    raise SystemExit(main())
