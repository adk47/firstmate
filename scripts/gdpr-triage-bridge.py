#!/usr/bin/env python3
"""Bridge the support@ triage digest to the GDPR erasure register.

The triage skill (workspaces/operations/skills/muso-support-email-triage) reads support@ mail
with an LLM and writes one verdict per thread. Its `human` class covers "formal
legal/privacy-rights deletion demands" and "Google de-indexing" -- requests the erasure
pipeline already owns. Before this bridge every one of them paged a human, including the ones
the register already held and was working: on 2026-11-07 the digest paged a human for the Jani
Lopez Torregrosa Art.17 request, which had been register #399 since 2026-11-06T20:13Z, had
already had two of its four pages hidden, and was waiting on a mail read the triage had just
done.

This step runs between the LLM verdicts and the digest. For each `human` verdict it asks the
register first, then the pipeline's own classifier, and records exactly ONE outcome:

  registered   the register already holds this thread (key gmail:support@muso.ai:<tid>). The
               digest shows the register number and the register's own next action. No human
               page: the pipeline owns it.
  filed        the register did not hold it and the pipeline's classifier says it is a request
               the register can act on. A candidate is pushed through `gdpr-pipeline.py
               intake`, which decides it in the same call, so the digest can show the verdict.
  refused      the pipeline was asked and refused. The digest pages a human and names the
               pipeline's own refusal, verbatim.
  withdrawn    the customer withdrew a request the register still holds open. The register has no
               cancellation transition, so a human must decide whether to stop its next action. The
               digest pages a human and says why.
  escalated    an open row was raised to legal_threat or dmca_takedown. Intake absorbs the escalation
               and the row's class changes, but a threat is not a self-serve pipeline item, so the
               digest still pages a human and names the class it came from.
  not_privacy  the pipeline's classifier says this is not a privacy request (a sales
               negotiation, a credit dispute). The triage's own `human` verdict stands.

Nothing here decides a class, a date or an identity. The class comes from
gdpr_pipeline.intake.classify (the ONE copy of the rules, read from legal-intake.py by AST),
the date from the support ledger's first_seen (or the triage's own UTC date when the ledger
has not caught up yet), and the identity from the pipeline's own decide step. This file only
routes.

Exit codes: 0 every human verdict got an outcome; 2 at least one could not be routed (the
digest still renders, and the un-routed ones page a human naming why). A read failure is
never a verdict.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from gdpr_pipeline import intake  # noqa: E402  (the ONE classifier)
from gdpr_pipeline import store as store_mod  # noqa: E402

PIPELINE = HERE / "gdpr-pipeline.py"
SUPPORT_LEDGER = Path(os.environ.get("GDPR_SUPPORT_LEDGER", "/root/fmc1-intake/support-ledger.json"))
SUPPORT_ALIAS = "support@muso.ai"

# The classes the register can ACT on. `privacy_access` is included because an Art.15 request is
# a real deliverable with its own due date (the pipeline short-circuits it to ACCESS); the rest
# of LEDGER_CLASSES (credit_dispute, other, security, spam) are things the register records but
# never acts on, so routing one would create a row that is filtered out on every pass -- worse
# than a refusal, because the lane would believe the request is registered and watched.
ROUTABLE = intake.ERASURE_CLASSES + ("privacy_access",)


# Classes a human must always read, whatever obligation the store maps them to. `legal_threat` and
# `dmca_takedown` are not something the pipeline answers on its own, so an open row of ANY obligation must not
# absorb them (QA #1858 r1).
HUMAN_ALWAYS = ("legal_threat", "dmca_takedown")

# Ownership is judged per OBLIGATION, not per thread (QA #1847 Critical): an Art.15 row answers an access
# request, it does not answer a deletion. The mapping itself lives in ONE place, `store.OBLIGATION_OF_CLASS` -
# a second copy here drifted the moment the store learned that a threat on a deletion thread IS that deletion
# escalating, and the drift was itself a finding (QA #1858 r3). Read it, never restate it.


def owns_obligation(existing: dict | None, incoming_class: str) -> bool:
    """Does the open row we already hold discharge the obligation THIS message asks for?

    A thread key identifies a conversation, not a statutory request (QA #1847). The case that bit: a customer sends
    an Art. 15 access request, then a deletion demand in the same thread. `actively_owned` saw an open row, the
    bridge reported `registered`, the digest removed the human page -- and no erasure row was ever created, so the
    deletion had no deadline and nothing watched it. The deletion was silently dropped.

    Deliberately conservative, because the classifier is keyword-based and a short follow-up ("any update?")
    classifies as `other`: anything that is not a DIFFERENT routable privacy obligation keeps today's behaviour. Only
    a clear, differently-classed privacy request falls through to intake, which then decides whether to file.
    """
    if incoming_class in HUMAN_ALWAYS:
        return False                     # a threat is never absorbed, whatever the store maps it to
    before = store_mod.obligation_of(str((existing or {}).get("class") or ""))
    after = store_mod.obligation_of(incoming_class)
    if not before or not after:
        return True                      # unknown either side: do not change the routing
    return before == after


def actively_owned(row: dict | None) -> bool:
    """Is the register still working this row?

    `upsert` treats an answered row (a written confirmation, or closed for any other reason) as
    the START of a new request, not as a match. This predicate is the same rule, so the bridge
    and the pipeline cannot disagree about whether a thread is handled: a closed row means the
    customer was answered, and a new message in that thread is a new request with its own
    deadline. Suppressing the page on a closed row would drop it silently.
    """
    return bool(row) and row.get("status") == "open" and not row.get("confirmed_at")

# gog returns a naive UTC timestamp with no seconds ("2026-11-07 22:09"); node-8 is UTC, so the
# value is UTC and only the seconds are missing. The ledger's first_seen is the authoritative
# form (RFC 2822 with GMT, full seconds) and is preferred whenever the thread is in it.
GOG_DATE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$")


def load_json(path: Path, what: str):
    try:
        with open(path) as f:
            return json.load(f)
    except OSError as exc:
        raise SystemExit(f"{what} unreadable: {exc}")
    except ValueError as exc:
        raise SystemExit(f"{what} is not valid JSON: {exc}")


def ledger_index(path: Path) -> dict:
    """{thread_id: row} from the support ledger, or {} when the ledger is absent.

    An absent ledger is not an error: the triage can see a thread the ledger has not picked up
    yet, and the bridge still files it from the triage's own data. A ledger that exists but
    cannot be parsed IS an error -- a half-read ledger would silently look like "no thread is
    registered", which is the fail-open this whole file exists to remove.
    """
    if not path.exists():
        return {}
    data = load_json(path, f"support ledger {path}")
    if not isinstance(data, dict):
        raise SystemExit(f"support ledger {path} is not a JSON object")
    out = {}
    for key, row in data.items():
        if not isinstance(row, dict):
            continue
        tid = row.get("thread")
        if not tid and isinstance(key, str) and ":" in key:
            tid = key.rsplit(":", 1)[-1]
        if tid:
            out[tid] = row
    return out


def received_at(tid: str, email: dict, ledger: dict, prefer_ledger: bool = True) -> tuple[str, str]:
    """(ISO-8601 Z, source). The ledger's first_seen wins for a FIRST request; the triage's own
    date is the fallback.

    `received_at` starts the 30-day statutory clock AND the 24-hour hide deadline, so it is
    never guessed: an unparseable value raises, and the caller turns that into a refusal that
    names the field rather than a row dated from whatever was to hand.

    `prefer_ledger=False` for a request that FOLLOWS a closed one, and that is load-bearing.
    support-intake preserves `first_seen` across rescans, so for a thread that came back it still
    holds the ORIGINAL message's date. Dating the new request from it makes `Store.upsert` see
    `received_at <= hit.received_at` and answer "unchanged" -- the new request is dropped -- or,
    when the new message does carry a page, opens a row whose 24-hour hide and 30-day reply
    deadlines are measured from the OLD request. The new message's own date is the only honest
    receipt time for a new request.
    """
    row = ledger.get(tid) or {}
    first_seen = row.get("first_seen")
    if prefer_ledger and first_seen:
        from email.utils import parsedate_to_datetime
        try:
            dt = parsedate_to_datetime(str(first_seen))
        except (TypeError, ValueError) as exc:
            raise ValueError(f"support ledger first_seen {first_seen!r} is not a date: {exc}")
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "support-ledger first_seen"
    raw = str(email.get("date") or "").strip()
    m = GOG_DATE_RE.match(raw)
    if not m:
        raise ValueError(f"the email's own date {raw!r} is not a UTC timestamp the register can date a "
                         f"request from (want YYYY-MM-DD HH:MM[:SS])")
    y, mo, d, h, mi, s = m.groups()
    return f"{y}-{mo}-{d}T{h}:{mi}:{s or '00'}Z", "triage email date (UTC, seconds truncated)"


def pages_for(tid: str, email: dict, ledger: dict) -> list[dict]:
    """Full-URL pages from the mail text, else the ledger's id prefixes.

    The register resolves an 8-char prefix only when the catalog matches it uniquely, so a
    prefix is a weaker page than a URL -- but it is what the ledger has, and the pipeline's own
    decide step is what turns either into a verdict. This function never decides.
    """
    pages = intake.pages_in(f"{email.get('subject') or ''}\n{email.get('body_excerpt') or ''}")
    if pages:
        return pages
    out = []
    for item in (ledger.get(tid) or {}).get("ids") or []:
        if isinstance(item, dict) and item.get("kind") and item.get("id"):
            out.append({"entity": str(item["kind"]).lower(), "id": str(item["id"]).lower()})
    return out


def requester_for(email: dict) -> tuple[str, str]:
    """(name, address) from the From header. The name is display text, never an identity claim."""
    raw = str(email.get("from") or "")
    m = re.match(r"^\s*(?:\"?([^\"<]*?)\"?\s*)?<([^>]+)>\s*$", raw)
    if m:
        return (m.group(1) or "").strip(), m.group(2).strip()
    if "@" in raw:
        return "", raw.strip()
    return "", ""


def file_candidate(candidate: dict, store_path: str | None) -> tuple[str, str]:
    """Push one candidate through the pipeline's own intake. Returns ("filed"|"refused", words).

    A subprocess, not an import: `intake` is the documented contract the notices@/legal@ reader
    already uses, and going through it means this lane cannot drift from that one.

    The verdict is the ROW, not the exit code. `intake` exits 2 when any read failed -- including
    a read that failed AFTER the row was created (a Trino prefix resolution, a hidden-list
    refresh). Reading that as a refusal would page a human for a request the register already
    holds, which is the exact defect this bridge exists to remove. So: row present -> filed, and
    the pipeline's error is carried as a warning; row absent -> refused, with its own words.
    """
    env = dict(os.environ)
    if store_path:
        env["GDPR_STORE"] = store_path
    try:
        proc = subprocess.run(
            [sys.executable, str(PIPELINE), "intake", "--candidate", "-"],
            input=json.dumps(candidate), capture_output=True, text=True, timeout=120, env=env,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return "refused", f"the erasure pipeline could not be run: {exc}"
    out = (proc.stdout or "").strip()
    err = (proc.stderr or "").strip()
    try:
        row = store_mod.Store(store_path or store_mod.DEFAULT_PATH).by_key_prefix(
            candidate["keys"][0], candidate.get("class") or "")
    except Exception as exc:  # noqa: BLE001
        return "refused", f"the register could not be re-read after filing: {exc}"
    # THE ROW HAS TO BE THIS CANDIDATE'S (QA #1847 r3). Testing only "some open row with this thread prefix
    # exists" reported `filed` when the intake subprocess had REFUSED before writing: an open row of another
    # obligation satisfies the prefix, the digest then removes the human page, and nothing records what was
    # actually asked. Class equality is the ownership test `upsert` itself uses to decide a row counts as this
    # request, so the bridge and the pipeline cannot disagree about whether the candidate landed.
    if actively_owned(row) and row.get("class") == candidate.get("class"):
        return "filed", out
    # An open row of a DIFFERENT obligation answers the prefix but not this request: say so, rather than
    # reporting a refusal as if the pipeline had rejected the request outright.
    if actively_owned(row):
        return "refused", (
            f"the register still holds an open {row.get('class') or 'row'} for this thread "
            f"(#{row.get('register_no') or row.get('id')}) and filing this {candidate.get('class')} did not "
            f"replace it, so this request has no row of its own: "
            f"{(err or out or f'gdpr-pipeline.py intake exited {proc.returncode}').strip()}")
    # The pipeline's own refusal, verbatim: the digest pages a human with this text, so it must
    # be the pipeline's reason and not a paraphrase of it.
    return "refused", (err or out or f"gdpr-pipeline.py intake exited {proc.returncode} with no message")


def register_no_from(output: str) -> str:
    m = re.search(r"-> register #(\d+)", output or "")
    return m.group(1) if m else ""


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--emails", required=True, help="the triage's emails.json")
    ap.add_argument("--verdicts", required=True, help="the triage's verdicts.json")
    ap.add_argument("--out", required=True, help="where to write the bridge result (JSON)")
    ap.add_argument("--store", default=None, help="override GDPR_STORE (tests)")
    ap.add_argument("--ledger", default=None, help="override the support ledger path (tests)")
    ap.add_argument("--dry-run", action="store_true", help="classify and look up, file nothing")
    a = ap.parse_args(argv)

    emails = load_json(Path(a.emails), "emails.json")
    verdicts = load_json(Path(a.verdicts), "verdicts.json")
    if not isinstance(emails, list) or not isinstance(verdicts, list):
        raise SystemExit("emails.json and verdicts.json must both be JSON arrays")

    ledger = ledger_index(Path(a.ledger) if a.ledger else SUPPORT_LEDGER)
    email_by_tid = {e.get("threadId"): e for e in emails if isinstance(e, dict) and e.get("threadId")}

    store_path = a.store or os.environ.get("GDPR_STORE") or store_mod.DEFAULT_PATH
    try:
        db = store_mod.Store(store_path)
    except Exception as exc:  # noqa: BLE001 - any store failure is "cannot answer", never "not registered"
        raise SystemExit(f"the erasure register at {store_path} could not be opened: {exc}")

    threads: dict[str, dict] = {}
    unrouted = 0
    for v in verdicts:
        if not isinstance(v, dict):
            continue
        tid = v.get("threadId")
        if not tid or v.get("verdict") != "human":
            continue
        email = email_by_tid.get(tid) or {}
        key = f"gmail:{SUPPORT_ALIAS}:{tid}"
        rec = {"key": key, "triage_reason": v.get("reason") or ""}

        # 1. The register already holds it. This is the case that paged a human for a request
        #    the pipeline had filed, decided and partly hidden.
        try:
            # by_key_prefix, not by_key: a thread that came back after its request was answered
            # carries a `:again:<ts>` key, and filing a second row for it would be a duplicate.
            existing = db.by_key_prefix(key)
        except Exception as exc:  # noqa: BLE001
            rec.update(outcome="refused",
                       reason=f"the erasure register could not be read ({exc}); this thread's state is "
                              f"unknown, so a human must look")
            threads[tid] = rec
            unrouted += 1
            continue
        # ONLY an actively-owned row suppresses the page. A CLOSED row means the customer was
        # already answered; if they write again that is a NEW request, and `upsert` would open a
        # fresh row with its own deadline. Short-circuiting on the closed row would drop it: the
        # digest would show the old register number, remove the human page, and nothing would
        # watch the new request. So a closed row falls through to intake, which decides.
        # Classify BEFORE the ownership check, so a differently-classed privacy request in an already-open thread
        # is not swallowed as `registered`. The classification is also what step 2 would have done, so this moves no
        # work: it is the same `intake.classify` call, just earlier. A classifier failure keeps the old behaviour
        # (the row is open, so the page stays suppressed) rather than filing on a guess.
        try:
            incoming_cls = intake.classify(email.get("subject") or "", email.get("body_excerpt") or "")
        except Exception:  # noqa: BLE001
            incoming_cls = ""

        # A WITHDRAWAL is not a request, and it must never be swallowed as `registered` (QA #1847 r5
        # Critical). `classify` reads "Do not delete my profile. I withdraw my request." as `other`, and
        # `owns_obligation` deliberately keeps today's routing when the incoming class is unknown -- so an
        # open erasure row answered it, the human page was removed, and the hide pipeline kept running
        # against a customer who had just withdrawn. The register has no cancellation transition, so this
        # outcome exists to page a human: only a human can stop a hide already in flight.
        body = email.get("body_excerpt") or ""
        try:
            # A withdrawal needs no deletion vocabulary when the row it cancels is already open: "I withdraw my
            # request. Please stop processing it." names the request in the inherited subject, so the deletion
            # word is not in the body at all (QA #1847 r5 Critical). Only this caller can see the open row, so
            # only this caller may act on the bare verb -- `classify` must not.
            # A message that still makes a live demand is NOT a withdrawal, whatever verb it opens with
            # (QA #1847 r8 Important). "I withdraw my complaint; please delete my profile." withdrew
            # something we do not track and then asked for a deletion: `classify` routes it as an erasure,
            # so the bridge must file it rather than page a human saying nothing new was filed. The verb
            # paths therefore only fire when classification found NO privacy duty in this message.
            no_new_duty = incoming_cls == "other"
            explicit = no_new_duty and intake.withdrawal_of_request(body)
            withdrew = intake.withdrawn_in_body(body) or explicit or (
                no_new_duty and (intake.withdrawal_signal(body) or intake.access_refused(body))
                and bool(store_mod.obligation_of(str((existing or {}).get("class") or ""))))
            asks_copy = intake.requests_access(email.get("subject") or "", body)
        except Exception:  # noqa: BLE001
            withdrew, asks_copy = False, False
        # An EXPLICIT withdrawal of a request pages a human even with no open row (QA #1847 r7 Critical).
        # Without that, a withdrawal on a thread whose row was already closed fell through to the filing
        # path and minted a FRESH erasure row, so the hide path could act against the very instruction that
        # cancelled it. `withdrawal_of_request` is narrow on purpose: the verb must be followed by a request
        # noun, so "cancel my subscription and delete my profile" is still a deletion demand.
        if withdrew and (actively_owned(existing) or explicit):
            held_row = existing or {}
            held = (f"while register #{held_row.get('register_no') or held_row.get('id')} "
                    f"({held_row.get('class') or 'row'}) is still open"
                    if actively_owned(existing) else "and no request of theirs is open")
            rec.update(outcome="withdrawn", class_=held_row.get("class") or "",
                       register_no=str(held_row.get("register_no") or ""),
                       reason=(f"the customer WITHDREW this request {held}. Nothing new was filed. The "
                               f"register has no cancellation, so a human must decide whether to stop any "
                               f"action already in flight"))
            threads[tid] = rec
            continue

        if actively_owned(existing) and owns_obligation(existing, incoming_cls):
            rec.update(outcome="registered",
                       register_no=str(existing.get("register_no") or ""),
                       class_=existing.get("class") or "",
                       status=existing.get("status") or "",
                       identity_verdict=existing.get("identity_verdict") or "",
                       action=existing.get("action") or "")
            # AN OPEN ROW DOES NOT COVER A DUTY IT DOES NOT HAVE (QA #1847 r5 Important). "Send me a copy of
            # my personal data and delete my profile." against an open erasure row returned `registered` here,
            # before the dual-duty filing below, so only the erasure row ever existed and the Art.15 answer had
            # no deadline. File the missing duty, or page the human who would otherwise never be asked.
            if asks_copy and store_mod.obligation_of(str(existing.get("class") or "")) == "erasure":
                extra = {
                    "keys": [key], "channel": "support", "class": "privacy_access",
                    "received_at": "", "pages": [],
                    "note": "filed by the support@ triage bridge: the same message asks for a copy",
                }
                try:
                    have_access = actively_owned(db.by_key_prefix(key, "privacy_access"))
                except Exception:  # noqa: BLE001
                    have_access = False
                if not have_access:
                    if a.dry_run:
                        rec["duties"] = [existing.get("class") or "", "privacy_access"]
                        rec["access_register_no"] = ""
                    else:
                        err = ""
                        try:
                            extra["received_at"], _src = received_at(tid, email, ledger, prefer_ledger=False)
                        except ValueError as exc:
                            err = str(exc)
                        if not extra["received_at"]:
                            a_outcome, a_message = "refused", err or "the request could not be dated"
                        else:
                            extra["pages"] = pages_for(tid, email, ledger)
                            _n, _addr = requester_for(email)
                            if _n:
                                extra["requester_name"] = _n
                            if _addr:
                                extra["requester_email"] = _addr
                            a_outcome, a_message = file_candidate(extra, a.store)
                        if a_outcome == "filed":
                            rec["access_register_no"] = register_no_from(a_message)
                            rec["duties"] = [existing.get("class") or "", "privacy_access"]
                        else:
                            rec["outcome"] = "refused"
                            rec["reason"] = (
                                f"register #{existing.get('register_no') or existing.get('id')} is open for the "
                                f"deletion, but this message also asks for a COPY and the privacy_access row was "
                                f"not filed ({a_message.splitlines()[0] if a_message else 'no message'}), so the "
                                f"access answer has no deadline and a human must own it")
                            unrouted += 1
            threads[tid] = rec
            continue

        # 2. Not in the register, or in it under a DIFFERENT obligation. Ask the pipeline's own classifier whether
        # it can act.
        try:
            cls = incoming_cls or intake.classify(email.get("subject") or "", email.get("body_excerpt") or "")
        except Exception as exc:  # noqa: BLE001
            rec.update(outcome="refused",
                       reason=f"the erasure classifier could not be run ({exc}); a human must read this one")
            threads[tid] = rec
            unrouted += 1
            continue
        if cls not in ROUTABLE:
            rec.update(outcome="not_privacy", class_=cls,
                       reason=f"the erasure register cannot act on this: its classifier reads it as "
                              f"{cls!r}, not a privacy request")
            threads[tid] = rec
            continue

        # 3. Build the candidate. Every field is either the pipeline's own or the mail's own.
        try:
            # No row at all = a first request, so the ledger's first_seen is authoritative. A
            # CLOSED row means this message is a NEW request: date it from the new email, never
            # from the ledger's preserved first_seen (see received_at). An actively-owned row
            # never reaches here -- it returned `registered` above.
            when, when_source = received_at(tid, email, ledger, prefer_ledger=existing is None)
        except ValueError as exc:
            rec.update(outcome="refused", class_=cls,
                       reason=f"the request could not be dated, so it was not filed: {exc}")
            threads[tid] = rec
            unrouted += 1
            continue
        name, addr = requester_for(email)
        candidate = {
            "keys": [key],
            "channel": "support",
            "class": cls,
            "received_at": when,
            "pages": pages_for(tid, email, ledger),
            "note": f"filed by the support@ triage bridge; received_at from {when_source}",
        }
        if name:
            candidate["requester_name"] = name
        if addr:
            candidate["requester_email"] = addr

        # ONE MESSAGE CAN OWE TWO DUTIES (QA #1847 r5 Important). "Send me a copy of my personal data and
        # delete my profile" is an Art.15 request AND an Art.17 demand. `classify` returns a single class, so
        # this lane filed only the erasure row and the access answer was tracked nowhere -- `run.intake_intercom`
        # files both, but that path is not the one support@ mail travels. File the second duty here.
        try:
            dual = cls in intake.ERASURE_CLASSES and intake.requests_access(
                email.get("subject") or "", email.get("body_excerpt") or "")
        except Exception:  # noqa: BLE001
            dual = False

        if a.dry_run:
            rec.update(outcome="filed", class_=cls, register_no="", dry_run=True,
                       reason=(f"would file as {cls} dated {when} ({when_source})"
                               + (" and also as privacy_access (the same message asks for a copy)" if dual else "")))
            if dual:
                rec["duties"] = [cls, "privacy_access"]
            threads[tid] = rec
            continue

        # An escalation of a row we already hold still needs a human even after intake has absorbed it: a legal
        # threat is not a self-serve pipeline item, and the row's class changing is not the same as someone
        # reading it. Recorded as its own outcome because `filed` removes the page.
        escalated_from = ((existing or {}).get("class") or "") if (
            actively_owned(existing) and cls in HUMAN_ALWAYS) else ""

        outcome, message = file_candidate(candidate, a.store)
        if outcome == "filed":
            rec.update(outcome=("escalated" if escalated_from else
                                "human_review" if cls in HUMAN_ALWAYS else "filed"), class_=cls,
                       register_no=register_no_from(message),
                       reason=message.splitlines()[0] if message else "")
            # A read that failed after the row was created is a warning, not a refusal: the
            # request is in the register and the pipeline re-reads on its next tick.
            warn = next((ln.strip() for ln in message.splitlines() if ln.startswith("ERROR")), "")
            if warn:
                rec["warning"] = warn
                print(f"bridge: {key}: filed, but the pipeline reported: {warn}", file=sys.stderr)
            # Re-read the row the pipeline just decided, so the digest shows the register's own
            # next action rather than the triage's guess at one. A read failure here is not a
            # filing failure -- the row exists -- so it only costs the action line.
            try:
                row = db.by_key_prefix(key)
            except Exception:  # noqa: BLE001
                row = None
            if row:
                rec["action"] = row.get("action") or ""
                rec["identity_verdict"] = row.get("identity_verdict") or ""
                rec["status"] = row.get("status") or ""
            if not escalated_from and cls in HUMAN_ALWAYS:
                # A FIRST-message threat or takedown has no prior row to escalate, but it is still not something
                # the pipeline answers on its own -- `filed` removed the human page and the digest said nothing
                # needed a human (QA #1858 r5).
                rec["reason"] = (
                    f"register #{rec.get('register_no') or '?'} holds this {cls} notice, but the pipeline does "
                    f"not answer a legal threat or a takedown notice on its own, so a human must read it")
            if escalated_from:
                rec["escalated_from"] = escalated_from
                rec["reason"] = (
                    f"register #{rec.get('register_no') or '?'} was an open {escalated_from} and this message "
                    f"escalated it to {cls}: the register holds no obligation key for {cls}, and a legal threat "
                    f"or takedown notice is not something the pipeline answers on its own, so a human must "
                    f"still read it")
        else:
            rec.update(outcome="refused", class_=cls, reason=message)

        # The second duty. If the erasure row landed but the access row did not, the digest still has to send a
        # human: an Art.15 request with no tracked deadline is an answer nobody owes.
        if dual:
            access = dict(candidate, **{"class": "privacy_access"})
            a_outcome, a_message = file_candidate(access, a.store)
            if a_outcome == "filed":
                rec["access_register_no"] = register_no_from(a_message)
                rec["duties"] = [rec.get("class") or cls, "privacy_access"]
            else:
                landed = rec.get("outcome") == "filed"
                rec["outcome"] = "refused"
                was = "filed" if landed else "not filed"
                rec["reason"] = (
                    f"the message asks for BOTH a copy (Art.15) and deletion (Art.17); the "
                    f"{cls} row was {was} but the privacy_access row "
                    f"was not ({a_message.splitlines()[0] if a_message else 'no message'}), so the access "
                    f"answer has no deadline and a human must own it")
                if landed:            # an already-refused erasure filing was counted once, above
                    unrouted += 1
        threads[tid] = rec

    counts = {"human": len(threads)}
    for rec in threads.values():
        counts[rec["outcome"]] = counts.get(rec["outcome"], 0) + 1
    result = {"threads": threads, "counts": counts,
              "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    Path(a.out).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"bridge: {counts.get('registered', 0)} already registered, {counts.get('filed', 0)} filed, "
          f"{counts.get('refused', 0)} refused, {counts.get('withdrawn', 0)} withdrawn, "
          f"{counts.get('not_privacy', 0)} not a privacy request",
          file=sys.stderr)
    return 2 if unrouted else 0


if __name__ == "__main__":
    sys.exit(main())
