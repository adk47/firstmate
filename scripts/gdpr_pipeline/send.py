"""The send path: one ledgered letter per request, through the approved writers only.

The copy is NOT composed here. `deliver` carries `copy.ASK[...]` / `copy.render_confirmation(...)` verbatim, so the
only thing this module decides is WHERE a letter goes and whether it may go at all.

Routing is by what the register actually recorded, and every route fails CLOSED:

  conversation_id (numeric)        -> scripts/intercom-ops-write.sh reply --customer-facing --approved-by <human>
                                      (the wrapper is the deterministic gate: pinned Caroline identity, internal-leak
                                      refusal, api-log row written BEFORE the POST, part_type checked after)
  channel=support + gmail_thread   -> gog gmail send --account support@muso.ai --thread-id <t> --reply-all
  anything else                    -> Unknown:  the legal@ / notices@ threads in this register live in mailboxes
                                      that are not authed in gog on node-8, so a letter to them cannot be threaded
                                      from here. Naming that is the point: a silent skip would leave the row looking
                                      "handled" while the customer waits.

WHY A LEDGER ROW BEFORE THE WRITE
`erasure_sends` is UNIQUE(request_id, kind), so a second attempt for the same request is a refusal rather than a
second letter, and the row is written in state `sending` BEFORE the adapter runs (the same posture as
intercom-ops-write.sh's api-log-before-POST). A crash between the two leaves a `sending` row a human can see; the
alternative -- write after the fact -- leaves a letter the register does not know about.

The gate (`copy.PIPELINE_SENDS_APPROVED`) and the human allowlist are enforced in the CLI, not here, so this module
can be exercised in full by the tests without a live send.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess

from .store import now_iso

INTERCOM_WRITER = "intercom-ops-write.sh"      # resolved next to the CLI (scripts/), never hand-typed
MAIL_ACCOUNT = "support@muso.ai"        # the ONE mailbox this host can write to (gog auth list)
GOG_ENV = ("GOG_KEYRING_PASSWORD",)     # gog cannot read its keyring without it
SEND_LOCK_ENV = "MUSOAI_INTERCOM_TOKEN"


class Unknown(Exception):
    """A route the pipeline cannot take, raised BEFORE the writer runs: nothing was sent, so a retry is safe once a
    human fixes the cause. The caller records it as `refused`/`failed`; it is never a silent skip."""


class Ambiguous(Exception):
    """The writer RAN and we cannot prove what it did: a timeout, a dropped connection, a non-zero exit after the
    request was built. The customer may have the letter, so this is NEVER a retry (Fable r5 finding 1: a retry after
    an ambiguous POST is two statutory letters for one request). It is recorded as `unknown` and a human reconciles."""


def body_sha(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def route(row: dict) -> tuple[str, str]:
    """(kind, target) for this request, or Unknown with the reason a human needs to fix."""
    conv = str(row.get("conversation_id") or "").strip()
    if conv:
        if not conv.isdigit():
            raise Unknown(f"conversation_id {conv!r} is not a numeric Intercom id")
        return "intercom", conv
    thread = str(row.get("gmail_thread") or "").strip()
    if thread:
        if row.get("channel") != "support":
            raise Unknown(f"{row.get('channel')} thread {thread} is in a mailbox gog cannot write on this host "
                          f"(only {MAIL_ACCOUNT} is authed); auth that mailbox or answer the customer on a "
                          f"conversation we can write to")
        return "mail", thread
    raise Unknown(f"no conversation_id and no gmail_thread (requester_email "
                  f"{row.get('requester_email') or '-'}): there is nothing to reply to, so a letter would have to "
                  f"open a new thread with copy nobody approved")


def _env_missing(names: tuple[str, ...]) -> str:
    return ", ".join(n for n in names if not os.environ.get(n))


def _with_key(key: str) -> dict:
    """Hand the letter's id to the writer through its ENVIRONMENT, not its argv: neither the Intercom writer nor gog
    has an idempotency flag, and inventing one would make every real send fail on "unknown argument" (checked:
    `gog gmail send --help` has no --header, and intercom-ops-write.sh dies on an unknown flag). The ledger row is the
    actual double-send guard; the id is what a human reconciling an `unknown` row goes looking for."""
    env = dict(os.environ)
    if key:
        env["MUSO_LETTER_ID"] = key
    return env


def idem_key(rid: int, kind: str, text: str) -> str:
    """The identity of ONE letter: this request, this kind of letter, this exact body. Recorded on the ledger row and
    handed to the writer, so a retry is recognisable as a retry of the same letter rather than a second one."""
    return hashlib.sha256(f"{rid}:{kind}:{body_sha(text)}".encode()).hexdigest()[:32]


def _intercom_send(conv: str, text: str, approved_by: str, dry_run: bool, key: str = "") -> str:
    """Post the approved copy as a customer-facing Intercom reply through the wrapper that gates it."""
    writer = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), INTERCOM_WRITER)
    if not os.path.exists(writer):
        raise Unknown(f"{INTERCOM_WRITER} is not installed next to the pipeline: refusing to hand-compose a reply")
    if dry_run:
        # The token is checked only where it is used: a dry run posts NOTHING, so requiring production credentials to
        # rehearse a batch would only stop an operator from rehearsing on a host that has no Intercom identity.
        return "dry-run"
    missing = _env_missing((SEND_LOCK_ENV,))
    if missing:
        raise Unknown(f"{missing} is not set: the Intercom writer cannot authenticate (the gateway exports it "
                      f"from /etc/openclaw/main.env)")
    cmd = ["bash", writer, "reply", "--conversation", conv, "--requested-by", approved_by,
           "--approved-by", approved_by, "--customer-facing", "--body", text]

    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=120, env=_with_key(key))
    except subprocess.TimeoutExpired as exc:
        # A timeout is raised BY subprocess.run, i.e. AFTER the wrapper was invoked, so it is a member of the
        # ambiguous family and not of the "nothing happened" one. Left to the generic handler it became `failed`,
        # which is retryable, and the retry is the second statutory letter (proved on the real route: 2 letters).
        raise Ambiguous(f"{INTERCOM_WRITER} timed out after {exc.timeout}s with the reply built: it may be posted, "
                        f"so this is never a retry") from exc
    if out.returncode != 0:
        # The writer already ran: Intercom may hold the reply. Ambiguous, never a retry.
        raise Ambiguous(f"{INTERCOM_WRITER} exited rc {out.returncode} after being invoked: "
                        f"{(out.stderr or out.stdout).strip()[:300]}")
    return (out.stdout.strip().splitlines() or ["posted"])[-1][:300]


def _subject_of(thread: dict) -> str:
    msgs = thread.get("messages") or []
    if not msgs:
        raise Unknown("the mail thread has no messages, so there is no subject to reply on")
    for h in (msgs[0].get("payload") or {}).get("headers") or []:
        if str(h.get("name", "")).lower() == "subject":
            s = str(h.get("value", "")).strip()
            return s if s.lower().startswith("re:") else "Re: " + s
    raise Unknown("the mail thread carries no Subject header")


def _mail_send(thread_id: str, text: str, approved_by: str, dry_run: bool, key: str = "") -> str:
    """Reply in the customer's own thread from support@ (the only mailbox gog can write here)."""
    missing = _env_missing(GOG_ENV)
    if missing:
        raise Unknown(f"{missing} is not set: gog cannot unlock its keyring (the gateway exports it from "
                      f"/etc/openclaw/main.env)")
    gog = shutil.which("gog")
    if not gog:
        raise Unknown("gog is not on PATH: no mail leaves this host without it")
    try:
        got = subprocess.run([gog, "gmail", "thread", "get", thread_id, "--account", MAIL_ACCOUNT, "-j"],
                             capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired as exc:
        # NOT ambiguous: this is a read, nothing has been written, so retrying is correct. Classified `Unknown`
        # explicitly so the ledger says "the thread read timed out" instead of showing a bare `failed`.
        raise Unknown(f"thread {thread_id}: the gog read timed out after {exc.timeout}s; nothing was written, "
                      f"so this is retryable") from exc
    if got.returncode != 0:
        raise Unknown(f"thread {thread_id} is not readable in {MAIL_ACCOUNT} ({(got.stderr or got.stdout).strip()[:200]}): "
                      f"replying there would open a new thread under copy nobody approved")
    try:
        thread = json.loads(got.stdout or "{}").get("thread") or {}
    except json.JSONDecodeError:
        raise Unknown(f"thread {thread_id}: gog returned unparseable JSON")
    subject = _subject_of(thread)
    if dry_run:
        return "dry-run"
    cmd = [gog, "gmail", "send", "--account", MAIL_ACCOUNT, "--thread-id", thread_id, "--reply-all",
           "--subject", subject, "--body", text]

    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=180, env=_with_key(key))
    except subprocess.TimeoutExpired as exc:
        raise Ambiguous(f"gog gmail send timed out after {exc.timeout}s with the message built: it may be in the "
                        f"thread, so this is never a retry") from exc
    if out.returncode != 0:
        # gog already ran: the message may be in the thread. Ambiguous, never a retry.
        raise Ambiguous(f"gog gmail send exited rc {out.returncode} after being invoked: "
                        f"{(out.stderr or out.stdout).strip()[:300]}")
    return (out.stdout.strip().splitlines() or ["sent"])[-1][:300]


def adapter(name: str):
    """Resolved at CALL time (not a module-level dict) so a test can patch one writer and the real code path
    still runs; a module-level dict freezes the function object and makes that patch a no-op."""
    return {"intercom": _intercom_send, "mail": _mail_send}[name]


def deliver(run, item: dict, kind: str, approved_by: str, dry_run: bool = False, slot: str | None = None) -> dict:
    """Send ONE approved letter for `item` (a row from Run.asks / Run.confirmations) and ledger it.

    `slot` is the ledger slot; it defaults to `kind`. It exists because a confirmation has TWO letters in its life: an
    INTERIM one, sent while the pages are not yet off the public view ("the remaining step is in progress"), and the
    FINAL one that says they no longer show the information. One slot for both meant the interim consumed the single
    `confirm` slot and stamped `confirmed_at`, so the final letter - the one that actually closes a statutory request -
    could never send (Fable r5 finding 2). The interim now lives in `confirm-interim` and does not stamp `confirmed_at`.

    Returns {"state": sent|failed|refused|skipped|unknown|dry-run, ...}. The invariants:
      - `sent` is final: a request that already has a sent letter in this slot is reported, never sent again.
      - `sending`/`unknown` are NOT retryable by the pipeline: the writer may have reached the customer, so a human
        resolves it. `unknown` is specifically the AMBIGUOUS case (timeout, dropped connection, non-zero exit after the
        writer ran): retrying it is how one request gets two statutory letters.
      - `failed` / `refused` ARE retryable (a mailbox got authed, a writer flaked before it ran), reusing the slot.
      - `dry-run` writes nothing at all: nothing left the host, so there is nothing to guard against."""
    rid = item["row"]
    slot = slot or kind
    who = f"#{item['register_no']}"
    prior = run.store.send_record(rid, slot)
    if prior and prior["state"] == "sent":
        run.log(f"{who} row {rid}: {slot} already sent on {prior['at'][:10]} via {prior['channel']} "
                f"({prior['target']}); not sent again")
        return {"state": "skipped", "why": f"already sent {prior['at'][:10]}", "ledger": prior}
    if prior and prior["state"] in ("sending", "unknown"):
        run.log(f"{who} row {rid}: a {slot} was claimed on {prior['at']} and is {prior['state']} - a letter may "
                f"already be out; a human resolves this row, the pipeline will not send a second one")
        return {"state": "skipped", "why": f"claimed {prior['at']} and {prior['state']} - unfinished, a letter may "
                                          f"be out", "ledger": prior}

    if item.get("refuse"):
        # A letter the register knows it must not send yet (unapproved copy the ruling requires). Ledgered as
        # `refused`, so it is retryable - once the copy is approved the same slot sends it - and never a silent skip.
        run.store.claim_send(rid, slot, "none", "", body_sha(item["text"]), approved_by, "refused",
                             detail=item["refuse"], idem=idem_key(rid, slot, item["text"]))
        run.log(f"{who} row {rid}: not sent ({item['refuse']})")
        return {"state": "refused", "why": item["refuse"]}

    row = run.store.get(rid) or {}
    try:
        channel, target = route(row)
    except Unknown as exc:
        run.store.claim_send(rid, slot, "none", "", body_sha(item["text"]), approved_by, "refused", detail=str(exc),
                             idem=idem_key(rid, slot, item["text"]))
        run.log(f"{who} row {rid}: not sent ({exc})")
        return {"state": "refused", "why": str(exc)}
    if dry_run:
        return {"state": "dry-run", "channel": channel, "target": target}

    key = idem_key(rid, slot, item["text"])
    # CLAIM BEFORE SEND, carrying the letter's id: from here on a second attempt sees a claim and stands down.
    run.store.claim_send(rid, slot, channel, target, body_sha(item["text"]), approved_by, "sending", idem=key)
    try:
        ref = adapter(channel)(target, item["text"], approved_by, dry_run=False, key=key)
    except Ambiguous as exc:
        # The writer ran. We cannot prove the customer did not get it, so this is NEVER a retry.
        detail = str(exc)[:500]
        run.store.finish_send(rid, slot, "unknown", detail=detail)
        run.fail(f"{kind} row {rid} via {channel} (AMBIGUOUS: not retried, reconcile by hand)", Exception(detail))
        return {"state": "unknown", "why": detail, "idem": key}
    except (Unknown, subprocess.SubprocessError, OSError) as exc:
        detail = str(exc)[:500]
        run.store.finish_send(rid, slot, "failed", detail=detail)
        run.fail(f"{kind} row {rid} via {channel}", Exception(detail))
        return {"state": "failed", "why": detail}

    run.store.finish_send(rid, slot, "sent", ref=ref)
    stamp = now_iso()
    if kind == "ask":
        run.store.update(rid, "ask", ask_sent_at=stamp, ask_ref=ref)
    elif slot == "confirm":
        run.store.update(rid, "confirmed", confirmed_at=stamp, confirm_ref=ref)
    else:
        # The interim letter records itself and nothing else: `confirmed_at` is what takes the row out of the
        # confirmation queue, and only the FINAL letter may do that.
        run.store.update(rid, "confirmed", interim_confirm_at=stamp, interim_confirm_ref=ref)
    return {"state": "sent", "channel": channel, "target": target, "ref": ref, "idem": key, "slot": slot}
