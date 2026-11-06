"""Shared primitives for the ClickUp support-board drainers.

WHAT A DRAINER IS
-----------------
One module per `action:<type>` queue on the User Requests board
(901000600160). It resolves the identity on the ticket, reads the real state of
that request out of the system that owns it (read-only), and writes the single
tag that records what the customer was told. It never sends a message, never
writes a ClickUp status and never decides an approval — those are owned by
`resolve-notify.py` / `close-resolved-conversations.py` (customer copy) and by
`clickup-reconcile.py` (status), both already live.

This module holds only the things EVERY drainer must do byte-identically:

* identity from the #417 custom fields — the ids below mirror
  `plugins/support-tools/src/index.ts`, `scripts/clickup-todo-dedupe.py`,
  `scripts/close-resolved-conversations.py` and `scripts/lib/intercom_link.py`;
  a divergent id silently matches nothing, which reads as "no request".
* a JSONL ledger written BEFORE the network call and updated after it, so a run
  that dies mid-batch still leaves what `--revert` needs.
* a tag writer that reads the ticket back: ClickUp returning 200 is not proof
  that the tag landed, and a drainer's whole output is the tag.
* the run cap, the kill file, and the shared write lock.

WHY THE STATUS FILTER IS EXPLICIT
---------------------------------
Measured 2026-11-03 on the live board: `include_closed=false` alone returned 456
`action:profile-claim` tickets, 218 of them already `resolved` — the board's
`resolved` is a "done"-type status and that parameter does not exclude it. So a
drainer asks for the three open statuses by name and refuses to act on a partial
scan (a truncated scan looks exactly like "no work left").
"""
from __future__ import annotations

import contextlib
import datetime as dt
import fcntl
import json
import os
import pathlib
import sys
import urllib.error

SCRIPTS_DIR = pathlib.Path(__file__).resolve().parents[1]
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from lib import clickup_client  # noqa: E402
from lib.intercom_link import conv_id_of  # noqa: E402

CLICKUP_API = "https://api.clickup.com/api/v2"
CLICKUP_TASK_URL = "https://app.clickup.com/t/{}"
# User Requests board (the support board every producer files into).
LIST_ID = os.environ.get("CLICKUP_DRAIN_LIST", "901000600160")

# Identity keys — byte-identical to the producers'. Changing one here silently
# stops matching tickets; `tests/test_clickup_drain_common.py` pins the literals.
USER_EMAIL_FIELD = os.environ.get(
    "CLICKUP_USER_EMAIL_FIELD_ID", "e8618c74-d065-4b75-9a5a-86d658392409")
PROFILE_ID_FIELD = os.environ.get(
    "CLICKUP_PROFILE_ID_FIELD_ID", "347d23bf-ed7b-40c2-bd10-5bd6ac7210b1")
INTERCOM_LINK_FIELD = os.environ.get(
    "CLICKUP_INTERCOM_LINK_FIELD_ID", "c32dbf6e-f680-4ff1-a532-192bb96245c3")

# The three statuses a drainer may act on. `resolved` / `impossible` are
# terminal and belong to the reconciler and the stale sweep.
WORKFLOW_OPEN = ("to do", "in progress", "waiting")

ACTION_TAG_PREFIX = "action:"


class Surprise(RuntimeError):
    """Something that must stop the run: a drainer never writes past a surprise."""


class CapReached(RuntimeError):
    """The run's write budget is spent."""


class LockHeld(RuntimeError):
    """Another writer (claim_executor, a second drainer) holds the shared lock."""


# ───────────────────────── identity ─────────────────────────


def clickup_token() -> str:
    """The board token. Same two names every other ClickUp caller accepts."""
    tok = os.environ.get("CLICKUP_API_KEY") or os.environ.get("MUSOAI_CLICKUP_API_KEY")
    if not tok:
        raise Surprise("CLICKUP_API_KEY or MUSOAI_CLICKUP_API_KEY is required")
    return tok


def tag_names(task) -> list[str]:
    return [str(t.get("name") or "") for t in task.get("tags") or [] if isinstance(t, dict)]


def has_tag(task, name: str) -> bool:
    return name in tag_names(task)


def action_type(task):
    """The `action:<type>` tag — the queue a ticket belongs to."""
    for name in tag_names(task):
        if name.startswith(ACTION_TAG_PREFIX):
            return name[len(ACTION_TAG_PREFIX):]
    return None


def field_value(task, field_id):
    for cf in task.get("custom_fields") or []:
        if not isinstance(cf, dict) or cf.get("id") != field_id:
            continue
        value = cf.get("value")
        if isinstance(value, str):
            value = value.strip()
        if value not in (None, ""):
            return str(value)
    return None


def identity_of(task) -> dict:
    """The three identity keys the #417-era producers write."""
    email = field_value(task, USER_EMAIL_FIELD)
    profile = field_value(task, PROFILE_ID_FIELD)
    return {
        "email": (email or "").lower() or None,
        "profile_id": (profile or "").lower() or None,
        "intercom_conversation": conv_id_of(task),
    }


def created_s(task) -> int | None:
    try:
        return int(task.get("date_created")) // 1000
    except (TypeError, ValueError):
        return None


def status_of(task) -> str:
    return str((task.get("status") or {}).get("status") or "").strip().lower()


def open_queue_params(action: str) -> list[tuple[str, str]]:
    """Query params for one queue's OPEN tickets.

    `tags[]` filters the queue; the three `statuses[]` entries are what keeps
    closed tickets out (see the module docstring — `include_closed=false` does
    not). Subtasks are excluded: a subtask is not a customer request.
    """
    params = [("tags[]", f"{ACTION_TAG_PREFIX}{action}"), ("subtasks", "false")]
    params.extend(("statuses[]", s) for s in WORKFLOW_OPEN)
    return params


def fetch_queue(client, action: str, *, max_pages: int = 60) -> list[dict]:
    """Every open ticket in one queue. Raises rather than return a partial scan."""
    return client.list_tasks(LIST_ID, open_queue_params(action), max_pages)


def read_task(client, ticket_id) -> dict:
    """Read one ticket back. A 200 is not proof the field changed."""
    status, body = client.request("GET", f"/task/{ticket_id}")
    if status != 200 or not isinstance(body, dict):
        raise Surprise(f"read-back of task {ticket_id} answered {status}")
    return body


# ───────────────────────── time + files ─────────────────────────


def now_iso(now: dt.datetime | None = None) -> str:
    return (now or dt.datetime.now(dt.UTC)).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_json_atomic(path, value) -> None:
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp{os.getpid()}")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(value, fh, separators=(",", ":"), sort_keys=True)
    os.replace(tmp, path)


def read_jsonl(path) -> list[dict]:
    """Every JSON object in a JSONL file; a missing file is empty, a bad line is a Surprise.

    A half-written or corrupt ledger must stop a revert, not be skipped: the
    alternative is deleting tags a later run cannot account for.
    """
    out, path = [], pathlib.Path(path)
    if not path.exists():
        return out
    with open(path, encoding="utf-8") as fh:
        for line_no, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError as exc:
                raise Surprise(f"{path}:{line_no} is not JSON ({exc})") from exc
            if isinstance(rec, dict):
                out.append(rec)
    return out


class Ledger:
    """Append-only JSONL, one row per attempted write, with the BEFORE state.

    The intent row is written BEFORE the network call: a batch that dies halfway
    must still leave enough on disk to undo what it did.
    """

    def __init__(self, path):
        self.path = pathlib.Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def write(self, record: dict) -> None:
        with open(self.path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False,
                                separators=(",", ":"), sort_keys=True) + "\n")


# ───────────────────────── safety rails ─────────────────────────


def kill_file_present(path) -> bool:
    return bool(path) and pathlib.Path(path).exists()


@contextlib.contextmanager
def shared_write_lock(path):
    """Hold the shared claim/credit write lock, or raise LockHeld.

    `claim_executor` writes the claim tray and this package hands it rows, so the
    two must not run concurrently. Non-blocking on purpose: a drainer that waits
    for the executor would spend its hour queued behind it.
    """
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fh = open(path, "a+")
    try:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            raise LockHeld(f"{path} is held by another writer") from exc
        yield path
    finally:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        finally:
            fh.close()


# ───────────────────────── tag writes ─────────────────────────


def stale_reason(task, bucket: str, extra: dict) -> str | None:
    """Why this ticket no longer matches the decision that planned a tag write.

    The scan happens once and the writes come later, so a human can close the
    ticket, retag it out of the queue, or change its Profile ID/email in between.
    The tag derived from the OLD ticket would then mark a closed or reassigned
    ticket complete and hand it to downstream customer-outcome handling, so the
    pre-write GET revalidates the decision instead of only checking the tag is
    absent (QA finding, PR #1712 — `TagWriter.add`).
    """
    queue = extra.get("queue")
    if queue and action_type(task) != queue:
        return f"left the action:{queue} queue (action={action_type(task) or 'none'})"
    # Enforced ALWAYS, not only when the caller passed an expectation: a tag write
    # on a closed ticket is wrong no matter who planned it.
    status = status_of(task)
    if status not in WORKFLOW_OPEN:
        return f"status moved to {status or 'empty'} since the scan"
    ident = identity_of(task)
    if "profile_id" in extra:
        expected_profile = (extra.get("profile_id") or "").lower() or None
        if expected_profile != ident["profile_id"]:
            return (f"profile id changed since the scan "
                    f"({expected_profile or 'none'} -> {ident['profile_id'] or 'none'})")
    if "email" in extra:
        expected_email = (extra.get("email") or "").lower() or None
        if expected_email != ident["email"]:
            return (f"email changed since the scan "
                    f"({expected_email or 'none'} -> {ident['email'] or 'none'})")
    return None


class TagWriter:
    """Add one tag per ticket, capped, ledgered before the call, verified after it.

    Every write is idempotent (a tag already on the ticket is reported, never
    re-posted) and reversible (`revert_ledger` deletes exactly the tags whose
    ledger row says they were absent before and landed after).
    """

    def __init__(self, client, ledger: Ledger, *, max_writes: int, run_id: str,
                 now=now_iso):
        self.client = client
        self.ledger = ledger
        self.max_writes = max_writes
        self.run_id = run_id
        self.now = now
        self.written = 0

    def remaining(self) -> int:
        return max(self.max_writes - self.written, 0)

    def add(self, ticket_id, tag: str, *, bucket: str, evidence: str,
            claims: tuple = (), extra: dict | None = None,
            revalidate=None) -> str:
        """-> 'written' | 'already-present' | 'stale'. Raises CapReached / Surprise.

        The pre-write GET does more than look for the tag: `stale_reason` confirms
        the ticket still carries the queue's action tag, is still open, and still
        has the identity the decision was derived from. `revalidate` lets the
        caller re-read its own evidence — the drainer re-queries the claim table
        so a claim submitted after the scan cannot be labelled "never claimed" —
        and a non-empty reason skips the write and says why in the ledger.
        """
        extra = dict(extra or {})
        task = read_task(self.client, ticket_id)
        if has_tag(task, tag):
            return "already-present"
        reason = stale_reason(task, bucket, extra)
        if reason is None and revalidate is not None:
            try:
                reason = revalidate()
            except Surprise:
                raise
            except Exception as exc:  # noqa: BLE001 - unreadable evidence is never "go ahead"
                raise Surprise(f"revalidation of {ticket_id} failed: "
                               f"{type(exc).__name__}: {str(exc)[:200]}") from exc
        if reason:
            self.ledger.write({"ts": self.now(), "run_id": self.run_id,
                               "ticket_id": ticket_id, "bucket": bucket, "tag": tag,
                               "evidence": evidence[:600], "claim_ids": list(claims),
                               "action": "stale-skip", "result": "skipped",
                               "reason": str(reason)[:300], "status_before": status_of(task),
                               **extra})
            return "stale"
        if self.remaining() <= 0:
            raise CapReached(f"{self.max_writes} tag writes used")
        base = {"ts": self.now(), "run_id": self.run_id, "ticket_id": ticket_id,
                "bucket": bucket, "tag": tag, "evidence": evidence[:600],
                "claim_ids": list(claims), "tag_present_before": False,
                "status_before": status_of(task), **extra}
        self.ledger.write({**base, "action": "add-tag", "result": "pending"})
        try:
            status, _body = self.client.request("POST", f"/task/{ticket_id}/tag/{tag}")
        except clickup_client.ClickUpRateLimited as exc:
            # A 429 is refused before ClickUp acts, so the tag did NOT land: the
            # row is terminal and `--revert` needs no reconciliation for it.
            self.ledger.write({**base, "action": "add-tag", "result": "rate-limited"})
            raise Surprise(f"tag write on {ticket_id} was rate-limited") from exc
        except urllib.error.HTTPError as exc:  # a 4xx/5xx is not retried here
            self.ledger.write({**base, "action": "add-tag", "result": f"http-{exc.code}"})
            raise Surprise(f"tag write on {ticket_id} answered HTTP {exc.code}") from exc
        except (urllib.error.URLError, OSError, RuntimeError) as exc:
            # Every response was lost. `clickup_client` exhausts its transport
            # retries into a bare RuntimeError, which used to escape this handler
            # and leave only the `pending` row above: `--revert` then reported "no
            # candidates" while the customer-outcome tag was live. The POST may or
            # may not have been applied, so the ledger says `ambiguous` and
            # `revert_ledger` reconciles it against the board (QA finding, PR
            # #1712: an applied tag escaping the revert ledger).
            self.ledger.write({**base, "action": "add-tag",
                               "result": f"ambiguous:{type(exc).__name__}"})
            raise Surprise(f"tag write on {ticket_id} failed ambiguously: "
                           f"{type(exc).__name__}: {str(exc)[:200]}") from exc
        if status not in (200, 201):
            self.ledger.write({**base, "action": "add-tag", "result": f"http-{status}"})
            raise Surprise(f"tag write on {ticket_id} answered {status}")
        self.ledger.write({**base, "action": "add-tag", "result": f"http-{status}"})
        after = read_task(self.client, ticket_id)
        ok = has_tag(after, tag)
        self.ledger.write({**base, "action": "read-back", "result": "verified" if ok else "missing"})
        if not ok:
            raise Surprise(f"tag `{tag}` did not land on {ticket_id} (read back absent)")
        self.written += 1
        return "written"

    def remove(self, ticket_id, tag: str, *, reason: str, extra: dict | None = None) -> str:
        """Delete one tag (the revert path). -> 'removed' | 'already-absent'."""
        task = read_task(self.client, ticket_id)
        if not has_tag(task, tag):
            # The tag is already gone, but that is a TERMINAL fact about this add
            # and it has to reach the ledger. Returning without a row left the
            # original `read-back: verified` add as the newest word on disk, so a
            # SECOND `--revert` still saw it as ours and deleted a tag a human had
            # re-added in between (QA finding, PR #1712).
            self.ledger.write({"ts": self.now(), "run_id": self.run_id,
                               "ticket_id": ticket_id, "tag": tag,
                               "action": "remove-tag", "result": "already-absent",
                               "reason": reason, **(extra or {})})
            return "already-absent"
        base = {"ts": self.now(), "run_id": self.run_id, "ticket_id": ticket_id,
                "tag": tag, "action": "remove-tag", "reason": reason, **(extra or {})}
        self.ledger.write({**base, "result": "pending"})
        try:
            status, _body = self.client.request("DELETE", f"/task/{ticket_id}/tag/{tag}")
        except clickup_client.ClickUpRateLimited as exc:
            self.ledger.write({**base, "result": "rate-limited"})
            raise Surprise(f"tag removal on {ticket_id} was rate-limited") from exc
        except urllib.error.HTTPError as exc:
            self.ledger.write({**base, "result": f"http-{exc.code}"})
            raise Surprise(f"tag removal on {ticket_id} answered HTTP {exc.code}") from exc
        except (urllib.error.URLError, OSError, RuntimeError) as exc:
            # Same contract as the add path: a lost DELETE response is ambiguous.
            # Nothing is claimed about the outcome — the add stays a candidate and
            # the next revert reads the ticket before it decides (`remove()` always
            # GETs first, so a retry converges either way).
            self.ledger.write({**base, "result": f"ambiguous:{type(exc).__name__}"})
            raise Surprise(f"tag removal on {ticket_id} failed ambiguously: "
                           f"{type(exc).__name__}") from exc
        if status not in (200, 204):
            self.ledger.write({**base, "result": f"http-{status}"})
            raise Surprise(f"tag removal on {ticket_id} answered {status}")
        self.ledger.write({**base, "result": f"http-{status}"})
        # A 2xx is not proof the tag is gone — same no-op-success class as the add
        # path. Without this read-back a revert could report success, keep the
        # customer-outcome tag live, and suppress the candidate on every later run
        # (QA finding, PR #1712).
        after = read_task(self.client, ticket_id)
        gone = not has_tag(after, tag)
        self.ledger.write({**base, "action": "remove-read-back",
                           "result": "verified" if gone else "still-present"})
        if not gone:
            raise Surprise(f"tag `{tag}` is still on {ticket_id} after a {status} delete")
        return "removed"


def revert_ledger(ledger_path, client, *, writer: TagWriter, dry_run: bool = True) -> dict:
    """Delete the tags THIS ledger added AND verified, newest row last.

    A tag is a revert candidate only when the ledger proves the whole story, read
    in order:

      1. `add-tag` … `tag_present_before: false`, `result: http-2xx` — we asked,
         and the API said yes;
      2. a following `read-back` … `result: verified` for the same ticket+tag —
         the tag is actually there.

    Step 2 is NOT paperwork. ClickUp can answer 200 without applying the tag; when
    that happened, `add()` already raised, and a HUMAN may later add that same tag
    for their own reason. Keying revert on the 200 alone would delete the human's
    tag and leave the ledger claiming an undo that never happened (QA finding,
    PR #1712 — `test_revert_ignores_an_add_that_never_read_back`). A `read-back`
    that says `missing` clears the candidate.

    A tag another surface already had (`tag_present_before: true`) is never
    touched. A tag this ledger already removed is skipped — UNLESS a later add of
    the same ticket+tag read back `verified` again, which clears the earlier
    `remove-tag` marker and makes it a candidate again (otherwise a re-added tag
    was invisible to `--revert` while the ledger looked complete; QA finding,
    PR #1712).

    A `remove-tag` only counts once a following `remove-read-back` says
    `verified`: ClickUp can answer 2xx and leave the tag in place, and a removal
    that did not land must stay retryable instead of being reported as an undo.

    A row with NO terminal answer — `pending` (the process died between the POST
    and the ledger update) or `ambiguous:<Error>` (every response was lost) — is
    reconciled against ClickUp with one GET before the rollback is called
    complete: present means it is a candidate, absent means there is nothing to
    undo, unreadable is an error and a non-zero exit. Without that read a lost
    response let an applied tag escape the ledger entirely, so `--revert`
    reported no candidates while the customer-outcome tag was still live
    (QA finding, PR #1712). `ambiguous_live` in the report counts the candidates
    that only the live read could prove.

    Trays are files and are not executed by anything here, so they need no undo;
    the report says so instead of pretending there is more.
    """
    rows = read_jsonl(ledger_path)
    verified: dict[tuple, dict] = {}
    unverified: dict[tuple, dict] = {}
    removed: dict[tuple, dict] = {}
    removal_pending: dict[tuple, dict] = {}
    ambiguous: dict[tuple, dict] = {}
    ignored = 0
    for rec in rows:
        key = (rec.get("ticket_id"), rec.get("tag"))
        action, result = rec.get("action"), str(rec.get("result", ""))
        if action == "add-tag" and rec.get("tag_present_before") is False:
            # A new add attempt re-owns the tag. An earlier verified removal settles
            # THAT add, not this one; keeping the marker made a later lost-response
            # add invisible, so a dry run reported `candidates: 0` with the tag
            # present (QA finding, QA round 10).
            removed.pop(key, None)
            # `tag_present_before: false` is also PROOF the tag was absent at this
            # instant, so any earlier verified add of the same ticket+tag is stale
            # ownership: that tag is gone. Keeping it let a failed retry (ClickUp
            # answers 200 and applies nothing) leave the OLD verified row standing,
            # so a tag a human later restored was deleted by `--revert` as ours
            # (QA finding, PR #1712). Ownership is promoted only by THIS attempt's
            # own verified read-back, below.
            verified.pop(key, None)
            if result.startswith("http-2"):
                unverified[key] = rec
                ambiguous.pop(key, None)
            elif result == "pending" or result.startswith(("ambiguous:", "error:")):
                # No terminal answer: the tag may or may not have landed.
                ambiguous[key] = rec
                unverified.pop(key, None)
            elif result.startswith("http-5"):
                # A 5xx is NOT a refusal. ClickUp can fail AFTER it committed the
                # write (a post-commit server error), so "definitely absent" let
                # `--revert` report no candidate while the tag was live (QA
                # finding, PR #1712). Reconcile it against the board like a lost
                # response.
                ambiguous[key] = rec
                unverified.pop(key, None)
            else:
                # 4xx / rate-limited: ClickUp refused it before acting.
                unverified.pop(key, None)
                ambiguous.pop(key, None)
        elif action == "read-back" and key in unverified:
            if result == "verified":
                verified[key] = unverified.pop(key)
                # A verified add AFTER an earlier revert owns the tag again: the
                # stale `removed` marker would hide it and leave the new tag in
                # place on a revert (QA finding, PR #1712).
                removed.pop(key, None)
                ambiguous.pop(key, None)
            else:
                unverified.pop(key)
                ambiguous.pop(key, None)   # a live read saw no tag: nothing to undo
                verified.pop(key, None)    # ...and nothing of ours is there to own
                ignored += 1
        elif action == "remove-tag" and result == "already-absent":
            # A live read saw the tag gone: the add it settles is settled, and a
            # human's later re-add is not ours to delete. Without this row a
            # second `--revert` re-deleted a tag a human had restored (QA
            # finding, PR #1712).
            removed[key] = rec
            verified.pop(key, None)
            unverified.pop(key, None)
            ambiguous.pop(key, None)
        elif action == "remove-tag" and result.startswith("http-2"):
            removal_pending[key] = rec
        elif action == "remove-read-back" and key in removal_pending:
            base_rec = removal_pending.pop(key)
            if result == "verified":
                removed[key] = base_rec
                verified.pop(key, None)
                unverified.pop(key, None)
                ambiguous.pop(key, None)   # the tag is gone: the add is settled
            else:
                ignored += 1      # the tag is still there: the add stays retryable
    # A 2xx add with NO `read-back` row at all is the same uncertainty as a
    # `pending` one: ClickUp accepted the POST, but nothing on disk says the tag
    # landed — the process died, or the read-back GET failed, between the two
    # rows. Counting it as "ignored" let `--revert` report `candidates: 0`,
    # `errors: []` while the customer-outcome tag was live (QA finding, PR
    # #1712). It is reconciled against the board below, exactly like a lost
    # response. `unverified` entries whose read-back said `missing` were already
    # popped above, so what is left here is only the interrupted case.
    for key, rec in unverified.items():
        ambiguous.setdefault(key, rec)
    unverified.clear()
    out = {"ledger": str(ledger_path), "candidates": 0, "removed": 0,
           "already_absent": 0, "skipped_already_reverted": 0, "errors": [],
           "unverified_adds_ignored": ignored,
           "unverified_removals_ignored": len(removal_pending),
           "ambiguous_reconciled": 0, "ambiguous_live": 0, "ambiguous_absent": 0,
           "dry_run": dry_run}
    # An `add-tag` row can stop at `pending` (the process died between the POST and
    # the ledger update), at `ambiguous:<Error>` (every response was lost), or at
    # `http-2xx` with no read-back row (the process died, or the GET failed, after
    # ClickUp accepted the write). None of them proves the tag landed; none proves
    # it did not. Ignoring them reports
    # "no candidates" while a live customer-outcome tag stays on the ticket, so
    # `--revert` exits 0 and the rollback looks complete. Assuming they landed
    # deletes a tag a human may have added in the same window. So look: one GET per
    # unresolved intent, in a dry run too — a dry run that under-reports a
    # candidate is the same lie, and a GET mutates nothing.
    for key, rec in list(ambiguous.items()):
        if key in removed:               # a verified removal already settled it
            continue
        try:
            task = read_task(client, rec["ticket_id"])
        except (Surprise, OSError, RuntimeError) as exc:
            # An unreadable board is not permission to call the rollback done.
            out["errors"].append(f"cannot reconcile the lost write of `{rec['tag']}` "
                                 f"on {rec['ticket_id']}: "
                                 f"{type(exc).__name__}: {str(exc)[:200]}")
            continue
        out["ambiguous_reconciled"] += 1
        if has_tag(task, rec["tag"]):
            verified[key] = rec
            out["ambiguous_live"] += 1
        else:
            out["ambiguous_absent"] += 1
    added = verified
    for key, rec in added.items():
        if key in removed:
            out["skipped_already_reverted"] += 1
            continue
        out["candidates"] += 1
        if dry_run:
            continue
        try:
            result = writer.remove(rec["ticket_id"], rec["tag"], reason="revert",
                                   extra={"source_ledger": str(ledger_path),
                                          "source_run_id": rec.get("run_id")})
        except Surprise as exc:
            out["errors"].append(str(exc))
            break
        out["removed" if result == "removed" else "already_absent"] += 1
    return out
