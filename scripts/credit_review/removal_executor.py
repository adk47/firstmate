"""Credit-removal executor: the two intents of Fable's removal model, decided and written.

Design: `data/credit-removal-flow-fable-r2/report.md` §4 (the modal), §5 (AI placement), §6
(Caroline's scenarios), §7 (the plan). Doctrine: `docs/credit-verification/credit-removal.md`.

The customer makes ONE choice and both intents run through this one module, one ledger and one gate:

  hide_mine   "This is me, but hide it from my profile". The OWNER's right, no judgement, no
              verification, no catalog delete: `POST {HIDE_PATH}` writes the served-visibility hide
              (core C1's `profile_credit_hides` primitive) and nothing else. Reversible
              (`DELETE {HIDE_PATH}` = unhide).
  not_me      "This isn't me / I'm not on this track". Files a REMOVAL CLAIM on the C2 gate
              (`POST {REMOVAL_PATH}`), which hides the credit at once and decides on the
              deterministic public-credit rule; here we only file it, read it back, and report the
              state it is in. This executor never decides a removal: the gate does.
  proof       A follow-up proof LINK for a `not_me` request the gate answered `listed`: recorded in
              `credit_proof_verifications` (credit_review/proof_verifications.py), graded there, and
              POSTed to the gate's own proof route (`POST {PROOF_PATH}`) as evidence on the EXISTING
              claim. A graded proof is evidence, never an approval: the gate decides. Until that
              route answers, the row says `proof_awaiting_gate` and the drainer does not ask again.

WHAT THIS MODULE MAY NEVER DO (each pinned by a test in scripts/tests/test_credit_removal.py):
  * decide a removal itself, or call a catalog delete. It calls the hide route and the gate-request
    route and nothing else; there is no code path to `removeSongCredits`, to an admin credit PUT or
    to a credit-approval route.
  * act on a `hide_mine` for a profile the ticket's own verified account does not present: the
    drainer resolves identity (`credit_review.identity_resolver`) and this module refuses a row
    whose `identity_linked` is false. Identity NEVER comes from the customer's message text.
  * write without a live answer from the server AND a read-back that agrees. A route that is absent
    (C1/C2 are unmerged) is `authority_unavailable`; a 401/403 is `authority_refused`; a read-back
    that disagrees is `partial`. None of them is reported as done. A DRY run probes the route with a
    read-only GET, so the report says `authority_unavailable` while C1/C2 are absent instead of
    pretending a write would land.
  * park a ticket on a TRANSIENT failure. 2xx -> the outcome; 404/405 -> `authority_unavailable`
    (blocked); 401/403 -> `authority_refused` (blocked); other 4xx -> `refused` (blocked); 5xx or a
    wrapper that could not make the call (status 0) -> `transient`, which tags nothing and is retried
    on the next run.
  * re-file a removal claim that is already on file. A filed claim is READ (`removal_request`) and
    the gate's own state is adopted; only a row with no claim on file ever POSTs a claim, and the
    check is re-read under the write lock so two overlapping runs cannot both file one. A claim an
    operator WITHDREW is never re-filed: the reverted ticket is a human's (`needs_customer`). A proof
    that arrives afterwards goes to the proof route, once per (request, proof).
  * write anything while the registry entry is unapproved or the live flag is absent: `--apply` is
    refused, the run decides and reports only (the same deliberate non-automation as
    credit_review/correction_executor.py).

EVERY WRITE GOES TO THE ACTION LEDGER WITH AN INVERSE (captain 11-03: every action must be
revertible). `/var/lib/hydra/credit-removal/ledger.jsonl`, append-only, one line per decision and one
per write, each carrying `inverse` = the call that undoes it (`unhide`, or `withdraw` of the gate
request). An inverse is recorded ONLY on a line for a write THIS run performed: a run that merely
adopted a claim another run filed, or POSTed a proof onto it, records `none`, because `revert(run_id)`
undoes this run's writes and never another run's. `revert(run_id)` replays ONE inverse per row
newest-first (a `partial` write and an
`accepted` line with no outcome line are writes too), re-reads the server, appends `reverted` lines,
marks the run's proof rows reverted and re-opens the tickets so the next run sees them again.
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Protocol, Sequence

AUTOMATION_ID = "credit-removal-executor"
#: The identity every call is made under. core records it as the actor on the hide row and on the
#: gate request, so a customer-visible write is attributable to this automation and never to a human.
REQUESTER = "credit-removal@hydra-ops"
REGISTRY = os.environ.get("CREDIT_APPROVAL_REGISTRY", "/opt/hydra/policies/credit-approval-automation.json")
KILL_FILE = os.environ.get("CREDIT_REMOVAL_KILL_FILE", "/etc/hydra/credit-removal-executor.disabled")
#: A human's recorded answer to "may this automation write to core at all". Absent = decide and report.
LIVE_FLAG = os.environ.get("CREDIT_REMOVAL_LIVE_FLAG", "/etc/hydra/credit-removal-executor.live")
LEDGER_PATH = os.environ.get("CREDIT_REMOVAL_LEDGER", "/var/lib/hydra/credit-removal/ledger.jsonl")
#: The same host-wide credit-status write lock every other credit writer takes, so a hide never races
#: the decider, the fable executor or a wrapper-mediated close.
WRITE_LOCK = os.environ.get("CV_CREDIT_WRITE_LOCK_PATH", "/var/lib/hydra/credit-status-writes.lock")
ADMIN_SCRIPT = os.environ.get(
    "CREDIT_REVIEW_ADMIN_SCRIPT",
    "/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh")

#: C1's hide primitive, agent-facing twin of `POST/DELETE /v4/workspace/:ws/profile/:pid/credits/hide`
#: (report §7 C1). ONE place: if C1 lands with another shape, this line changes and nothing else does.
HIDE_PATH = "/admin/profile/{profile_id}/credits/hide"
#: C2's removal claim, agent-facing twin of the user DELETE route's `intent=not_me` path (report §7 C2).
REMOVAL_PATH = "/admin/profile/{profile_id}/credits/removal-requests"
#: C2's evidence route: a proof that arrives AFTER the claim is filed goes here, on that same request.
PROOF_PATH = "/admin/profile/{profile_id}/credits/removal-requests/{request_id}/proofs"
PROFILE_CREDITS_PATH = "/admin/profile/{profile_id}/credits"

#: `/admin/profile/:id/credits` is PAGE-based (it ignores `offset` and echoes page 1 back), so a
#: complete read is a page walk. One page is not the list: a credit on page 2+ would look absent, and
#: absent is how this module reads "not shown on the profile".
CREDITS_PAGE_LIMIT = 500
CREDITS_MAX_PAGES = 400

HIDE_INTENT, NOT_ME_INTENT = "hide_mine", "not_me"
INTENTS = (HIDE_INTENT, NOT_ME_INTENT)

#: Gate states that are a statement about the credit (everything else is treated as "still checking").
GATE_REMOVED, GATE_LISTED = "removed", "listed"
GATE_CHECKING, GATE_KEPT, GATE_DIFFERENT = "checking", "kept", "different_profile"

#: Disposition -> the ONE `customer-outcome:` tag the drainer applies (None = leave the ticket alone).
#: `complete` is only ever a customer-visible outcome that actually happened; `None` means the ticket
#: stays in the queue because the answer has not landed yet (a gate still checking, a proof we still
#: need), so no later run is locked out by a tag nobody earned.
TAG_FOR: dict[str, str | None] = {
    "hide": "complete",
    "removed": "complete",
    "no_change": "complete",
    "gate_filed": None,
    "checking": None,
    "proof_awaiting_gate": None,
    "transient": None,
    "lock_busy": None,
    "proof_required": "verification-required",
    "needs_customer": "needs-customer",
    "identity_unlinked": "needs-customer",
    "intent_unknown": "needs-customer",
    "track_unresolved": "needs-customer",
    "kept": "needs-customer",
    "authority_unavailable": "blocked",
    "authority_refused": "blocked",
    "refused": "blocked",
    "partial": "partial",
}
#: Dispositions whose tag is `None`: the answer has not landed, so the ticket stays in the queue.
#: Derived from `TAG_FOR` so the two can never drift.
IN_FLIGHT = tuple(d for d, tag in TAG_FOR.items() if tag is None)
#: Worst first: the FIRST terminal disposition present decides the ticket's one outcome. In-flight
#: rows never reach this ladder (see `ticket_outcome`): a ticket is tagged only when EVERY row is
#: final, so one track `kept` and another still being decided leaves the ticket in the queue. A tag is
#: DURABLE (`why_excluded` honours it on every later run), so tagging a ticket with a row still in
#: flight would strand that row's result forever.
OUTCOME_ORDER = ("partial", "authority_refused", "refused", "authority_unavailable",
                 "proof_required",
                 "identity_unlinked", "intent_unknown", "track_unresolved",
                 "needs_customer", "kept", "hide", "removed", "no_change")
#: The ledger line written the instant core answers 2xx, BEFORE the read-back (which can raise). One per
#: write attempt, so the cap counts writes and never double-counts the outcome line that follows.
ACCEPTED = "accepted"


class RowError(ValueError):
    """The rows file cannot be executed safely."""


class ApiError(RuntimeError):
    """A core call could not be made or answered."""


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ── policy ─────────────────────────────────────────────────────────────────
def registry_approved(path: str = REGISTRY) -> tuple[bool, str]:
    """The registry entry, re-read before every write. `approved:true` needs an approver AND a
    reference: a bare flag is not an approval (policies/credit-approval-automation.json)."""
    try:
        entry = json.loads(Path(path).read_text())["automations"][AUTOMATION_ID]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return False, f"registry entry {AUTOMATION_ID} unreadable: {type(exc).__name__}"
    if entry.get("approved") is not True:
        return False, f"registry entry {AUTOMATION_ID} is not approved"
    if not str(entry.get("approved_by") or "").strip() or not str(entry.get("approval_ref") or "").strip():
        return False, f"registry entry {AUTOMATION_ID} has no approved_by/approval_ref"
    return True, ""


def live_flag_present(path: str = LIVE_FLAG) -> bool:
    return Path(path).is_file()


def may_write(*, registry: str = REGISTRY, live_flag: str = LIVE_FLAG,
              kill_file: str = KILL_FILE) -> tuple[bool, str]:
    """(may this run write to core, why not). Every check must pass; the first failure names itself."""
    if Path(kill_file).exists():
        return False, f"kill file {kill_file} present"
    ok, why = registry_approved(registry)
    if not ok:
        return False, why
    if not live_flag_present(live_flag):
        return False, (f"live flag {live_flag} absent: core writes from this automation are off until a "
                       "human records that answer")
    return True, ""


# ── ledger ─────────────────────────────────────────────────────────────────
def ledger_append(rec: dict[str, Any], path: str = LEDGER_PATH) -> None:
    """One append-only line. fsync'd before returning: an accepted write that is not on disk cannot be
    reverted, and an un-revertible customer-visible write is exactly what the ledger exists to prevent."""
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps({**rec, "ts": rec.get("ts") or utcnow()}, sort_keys=True, separators=(",", ":"))
    with open(p, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")
        fh.flush()
        os.fsync(fh.fileno())


def ledger_lines(path: str = LEDGER_PATH) -> list[dict[str, Any]]:
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return []
    out = []
    for raw in text.splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            rec = json.loads(raw)
        except ValueError:
            continue
        if isinstance(rec, dict):
            out.append(rec)
    return out


TERMINAL = ("hide", "removed", "gate_filed", "checking", "proof_required", "kept", "no_change",
            "reverted", "withdrawn", "partial", "refused", "authority_refused",
            "authority_unavailable")
#: Ledger outcomes that mean a removal claim is already on file for this row: it is READ, never
#: re-filed. An `accepted` line with no outcome line (a crash mid-run) counts, because the POST landed.
CLAIM_FILED = ("accepted", "gate_filed", "checking", "proof_required", "kept", "partial")
#: The outcomes that actually speak about a claim. A read/write FAILURE (`refused`, `authority_*`) is
#: not claim state: it must leave the previous claim state in force, never erase a filed claim.
CLAIM_STATE = CLAIM_FILED + ("removed", "withdrawn", "reverted")
#: A claim an operator withdrew (or a revert undid) is a human's: the automation never re-files it.
_WITHDRAWN_WHY = ("the claim was withdrawn by a revert: this ticket is a human's, and the automation "
                  "never re-files a claim an operator withdrew")


def row_state(path: str = LEDGER_PATH) -> dict[str, dict[str, Any]]:
    """(row_key -> the LATEST record that states an outcome). Latest wins is what makes an append-only
    ledger a state machine: a `reverted` line after a `hide` line means the row is back where it started,
    so a re-run may hide it again instead of stalling on `already done` forever. A reverted `not_me`
    claim is the exception: it is a human's, and the automation never re-files it."""
    state: dict[str, dict[str, Any]] = {}
    for rec in ledger_lines(path):
        key = str(rec.get("row_key") or "")
        if key and rec.get("outcome") in TERMINAL:
            state[key] = rec
    return state


def row_attempted(row_key: str, path: str = LEDGER_PATH) -> bool:
    """Whether any ledger line exists for this row: a previous attempt, whatever its outcome. A POST
    whose response was lost leaves one, so the gate is read before a second claim is filed."""
    return any(str(r.get("row_key") or "") == row_key for r in ledger_lines(path))


def claim_state(row_key: str, path: str = LEDGER_PATH) -> str:
    """The NEWEST record for this row that says something about a claim, or "" when it has none. An
    `accepted` line with no outcome line (a crash mid-run) counts, because the POST landed. A
    `withdrawn`/`reverted` newest record means the claim is NOT on file: an operator withdrew it. A
    read/write failure is not claim state, so it never erases a claim that is on file."""
    newest = ""
    for rec in ledger_lines(path):
        if (str(rec.get("row_key") or "") == row_key
                and rec.get("outcome") in CLAIM_STATE):
            newest = str(rec.get("outcome") or "")
    return newest


@contextlib.contextmanager
def locked(path: str = WRITE_LOCK, wait_s: float = 600):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a+", encoding="utf-8") as fh:
        deadline = time.monotonic() + wait_s
        while True:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise TimeoutError(f"credit write lock {path} busy")
                time.sleep(1)
        try:
            yield
        finally:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


# ── rows ───────────────────────────────────────────────────────────────────
@dataclass
class Row:
    """One ticket x track x intent, as the drainer assembled it."""
    ticket_id: str
    profile_id: str
    intent: str
    track_id: str = ""
    track_name: str = ""
    conversation_id: str = ""
    account_id: str = ""
    #: True only when the drainer resolved the ticket's account from a VERIFIED account and found this
    #: profile among the profiles that account presents. The customer's text never sets it.
    identity_linked: bool = False
    #: The roles the profile holds on the track right now (read by the drainer). `not_me` covers every
    #: role the profile holds: there is no half-removal.
    roles: tuple[str, ...] = ()
    claimant_name: str = ""
    proof_urls: tuple[str, ...] = ()
    verbatim: str = ""

    @property
    def row_key(self) -> str:
        return f"{self.ticket_id}:{self.profile_id}:{self.track_id}:{self.intent}"

    def as_dict(self) -> dict[str, Any]:
        return dict(self.__dict__)


def _str(value: Any, limit: int = 200) -> str:
    return str(value or "").strip()[:limit]


def _tuple_of(value: Any, limit: int = 5) -> tuple[str, ...]:
    if isinstance(value, str):
        return (value.strip(),) if value.strip() else ()
    if isinstance(value, (list, tuple)):
        return tuple(str(v).strip() for v in value if str(v or "").strip())[:limit]
    return ()


def load_rows(path: str) -> tuple[Row, ...]:
    """Read the drainer's rows file. A malformed row REFUSES the whole file: a half-read batch would
    act on rows nobody asked about."""
    try:
        doc = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RowError(f"rows file unreadable: {type(exc).__name__}: {exc}") from exc
    raw = doc.get("rows") if isinstance(doc, dict) else doc
    if not isinstance(raw, list) or not raw:
        raise RowError("rows file has no rows")
    out: list[Row] = []
    for i, item in enumerate(raw):
        if not isinstance(item, dict):
            raise RowError(f"row {i} is not an object")
        ticket_id, profile_id = _str(item.get("ticket_id")), _str(item.get("profile_id"))
        intent = _str(item.get("intent")).lower()
        if not ticket_id or not profile_id:
            raise RowError(f"row {i} needs ticket_id and profile_id")
        if intent not in INTENTS:
            raise RowError(f"row {i} intent {intent!r} is not one of {INTENTS}")
        out.append(Row(
            ticket_id=ticket_id, profile_id=profile_id, intent=intent,
            track_id=_str(item.get("track_id")), track_name=_str(item.get("track_name")),
            conversation_id=_str(item.get("conversation_id")), account_id=_str(item.get("account_id")),
            identity_linked=bool(item.get("identity_linked")),
            roles=_tuple_of(item.get("roles"), 20),
            claimant_name=_str(item.get("claimant_name")),
            proof_urls=_tuple_of(item.get("proof_urls")),
            verbatim=_str(item.get("verbatim"), 300)))
    keys = [(r.row_key) for r in out]
    if len(keys) != len(set(keys)):
        raise RowError("rows file has a duplicate (ticket, profile, track, intent)")
    return tuple(out)


# ── the core surface ───────────────────────────────────────────────────────
@dataclass
class Response:
    status: int
    body: Any = None
    error: str = ""

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300

    def text(self) -> str:
        if isinstance(self.body, dict):
            for key in ("data", "message", "error", "detail", "state", "status"):
                if self.body.get(key):
                    return str(self.body[key])[:200]
        return str(self.body or self.error or "")[:200]


class Core(Protocol):
    def hide(self, profile_id: str, track_id: str, *, request_ref: str) -> Response: ...
    def unhide(self, profile_id: str, track_id: str, *, request_ref: str) -> Response: ...
    def file_removal_request(self, profile_id: str, track_id: str, roles: Sequence[str], *,
                             request_ref: str,
                             proofs: Sequence[dict[str, Any]] = ()) -> Response: ...
    def removal_request(self, profile_id: str, track_id: str) -> Response: ...
    def submit_removal_proof(self, profile_id: str, request_id: str, proof: dict[str, Any], *,
                             request_ref: str) -> Response: ...
    def probe(self, profile_id: str, track_id: str, intent: str) -> Response: ...
    def withdraw_removal_request(self, profile_id: str, request_id: str, *,
                                 request_ref: str) -> Response: ...
    def credits(self, profile_id: str, page: int = 1) -> Response: ...


class WrapperCore:
    """The core surface over `muso-admin-api.sh call` (login, token cache and service credentials stay
    in the wrapper; this class never sees or prints a credential).

    The wrapper on `main` takes `--requester` only. #1713 adds `--service` / `--request-ref`; until it
    lands, the ticket id travels where the wrapper already supports it (the path's query for a GET, the
    JSON body for a write) so core's audit trail still names the ticket.
    """

    def __init__(self, script: str = ADMIN_SCRIPT, timeout_s: int = 120,
                 run: Callable[..., Any] | None = None):
        self.script = script
        self.timeout_s = timeout_s
        self._run = run or subprocess.run

    def call(self, method: str, path: str, body: str = "") -> Response:
        argv = ["bash", self.script, "--requester", REQUESTER, "call", method, path]
        if body:
            argv.append(body)
        try:
            proc = self._run(argv, capture_output=True, text=True, timeout=self.timeout_s, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return Response(0, None, f"{type(exc).__name__}: {str(exc)[:200]}")
        if proc.returncode != 0:
            return Response(0, None, f"wrapper rc={proc.returncode}: {(proc.stderr or '').strip()[:300]}")
        try:
            envelope = json.loads((proc.stdout or "").strip().splitlines()[-1])
        except (ValueError, IndexError):
            return Response(0, None, "wrapper returned non-JSON")
        status = envelope.get("http_status") if isinstance(envelope, dict) else None
        try:
            return Response(int(status or 0), envelope.get("body"), "")
        except (TypeError, ValueError):
            return Response(0, envelope.get("body"), "unparseable http_status")

    def hide(self, profile_id: str, track_id: str, *, request_ref: str) -> Response:
        return self.call("POST", HIDE_PATH.format(profile_id=profile_id),
                         json.dumps({"trackId": track_id, "intent": HIDE_INTENT,
                                     "requestRef": request_ref}, separators=(",", ":")))

    def unhide(self, profile_id: str, track_id: str, *, request_ref: str) -> Response:
        return self.call("DELETE", HIDE_PATH.format(profile_id=profile_id),
                         json.dumps({"trackId": track_id, "intent": HIDE_INTENT,
                                     "requestRef": request_ref}, separators=(",", ":")))

    def file_removal_request(self, profile_id: str, track_id: str, roles: Sequence[str], *,
                             request_ref: str,
                             proofs: Sequence[dict[str, Any]] = ()) -> Response:
        """File (or re-file, when a proof arrived) the removal claim. The gate owns the decision; a
        proof is submitted as EVIDENCE on the same request so the gate re-checks with it."""
        return self.call("POST", REMOVAL_PATH.format(profile_id=profile_id),
                         json.dumps({"trackId": track_id, "intent": NOT_ME_INTENT,
                                     "roles": list(roles), "requestRef": request_ref,
                                     "source": "clickup", "proofs": list(proofs)},
                                    separators=(",", ":")))

    def removal_request(self, profile_id: str, track_id: str) -> Response:
        return self.call("GET", f"{REMOVAL_PATH.format(profile_id=profile_id)}?trackId={track_id}")

    def submit_removal_proof(self, profile_id: str, request_id: str, proof: dict[str, Any], *,
                             request_ref: str) -> Response:
        """Evidence on the EXISTING claim. Never a new claim: the gate owns the request."""
        body = {"trackId": proof.get("trackId", ""), "requestRef": request_ref,
                "proof": {k: proof.get(k) for k in ("kind", "url", "sha256", "grade", "gradedAt")}}
        return self.call("POST", PROOF_PATH.format(profile_id=profile_id, request_id=request_id),
                         json.dumps(body, separators=(",", ":")))

    def probe(self, profile_id: str, track_id: str, intent: str) -> Response:
        """A read-only GET on the route this row would write to. A 404 means the route is not deployed;
        a 405 means it exists and does not take GET (the hide route is POST-only)."""
        if intent == HIDE_INTENT:
            return self.call("GET", HIDE_PATH.format(profile_id=profile_id))
        return self.removal_request(profile_id, track_id)

    def withdraw_removal_request(self, profile_id: str, request_id: str, *,
                                 request_ref: str) -> Response:
        return self.call("DELETE", f"{REMOVAL_PATH.format(profile_id=profile_id)}/{request_id}",
                         json.dumps({"requestRef": request_ref}, separators=(",", ":")))

    def credits(self, profile_id: str, page: int = 1) -> Response:
        return self.call("GET", f"{PROFILE_CREDITS_PATH.format(profile_id=profile_id)}"
                                f"?limit={CREDITS_PAGE_LIMIT}&page={page}")


def _items(resp: Response) -> list[dict[str, Any]]:
    body = resp.body
    if isinstance(body, dict):
        for key in ("data", "items", "results"):
            value = body.get(key)
            if isinstance(value, list):
                return [i for i in value if isinstance(i, dict)]
            if isinstance(value, dict):
                for k2 in ("items", "results", "credits"):
                    if isinstance(value.get(k2), list):
                        return [i for i in value[k2] if isinstance(i, dict)]
        if isinstance(body.get("credits"), list):
            return [i for i in body["credits"] if isinstance(i, dict)]
    if isinstance(body, list):
        return [i for i in body if isinstance(i, dict)]
    return []


def _has_credit_list(resp: Response) -> bool:
    """Whether the answer actually CARRIES a credits list.

    A 200 whose body is empty or has no recognized envelope is NOT an empty profile. Absence is
    exactly how this module reads "not shown on the profile", so an unrecognizable body must never be
    read as "the track is gone": that would report a hide that never took as a success."""
    body = resp.body
    if isinstance(body, list):
        return True
    if not isinstance(body, dict):
        return False
    for key in ("data", "items", "results", "credits"):
        value = body.get(key)
        if isinstance(value, list):
            return True
        if isinstance(value, dict) and any(isinstance(value.get(k2), list)
                                           for k2 in ("items", "results", "credits")):
            return True
    return False


def _track_of(item: dict[str, Any]) -> str:
    for key in ("trackId", "track_id", "id"):
        if item.get(key):
            return str(item[key])
    return ""


def _flag_is_true(value: Any) -> bool:
    """A JSON boolean True, or the strings "true"/"1". `bool("false")` is True, so a string flag is
    never coerced: a hide that did not take effect must not read as hidden."""
    if value is True:
        return True
    return isinstance(value, str) and value.strip().lower() in ("true", "1")


def _hidden_of(item: dict[str, Any]) -> bool:
    """Whether the readback says this credit is hidden from the profile. C1 owns the field name; the
    three spellings it can plausibly use are all read, and a body that says none of them is NOT hidden
    as far as this module is concerned (a missing field never counts as proof of a hide)."""
    for key in ("hidden", "isHidden", "hiddenFromProfile"):
        if key in item:
            return _flag_is_true(item[key])
    return bool(item.get("hiddenAt"))


def _compare(row: Row, resp: Response) -> tuple[bool, str]:
    """(read-back agrees, why not). Only a failed read disagrees here; whether the credit is actually
    hidden is decided by `_readback_credit` from the row itself."""
    if not resp.ok:
        return False, f"readback HTTP {resp.status}: {resp.text()}"
    return True, ""


# ── one row ────────────────────────────────────────────────────────────────
@dataclass
class Result:
    dispositions: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    stopped: str = ""
    writes: int = 0

    def as_dict(self) -> dict[str, Any]:
        return {"dispositions": self.dispositions, "stopped": self.stopped, "writes": self.writes}


def _row_result(row: Row, disposition: str, why: str, *, proof: dict[str, Any] | None = None,
                **extra: Any) -> dict[str, Any]:
    verdict = str((proof or {}).get("verdict") or "")
    out = {"ticket_id": row.ticket_id, "profile_id": row.profile_id, "track_id": row.track_id,
           "intent": row.intent, "disposition": disposition, "why": why, "row_key": row.row_key,
           "proof_on_file": bool(row.proof_urls), "proof_verdict": verdict,
           "proof_retry": verdict == "unreadable"}
    out.update(extra)
    return out


def assess(row: Row, *, state: dict[str, dict[str, Any]], ledger: str = LEDGER_PATH) -> str:
    """Why this row is not written, or "" when it may be. The ladder is fixed; no rule guesses."""
    if not row.identity_linked:
        return "identity_unlinked"
    if row.intent not in INTENTS:
        return "intent_unknown"
    if row.intent in (HIDE_INTENT, NOT_ME_INTENT) and not row.track_id:
        return "track_unresolved"
    prior = state.get(row.row_key)
    if prior and prior.get("outcome") in ("hide", "removed"):
        # a filed claim is NOT done: it is re-read until the gate answers, because only the gate's own
        # state can say what happened to it
        return "no_change"
    return ""


def _transient(resp: Response) -> bool:
    """A failure that says nothing about the request: the wrapper could not make the call (status 0) or
    core answered 5xx. It is retried next run and never tags a ticket."""
    return resp.status == 0 or resp.status >= 500


def _credits_unanswered(resp: Response) -> bool:
    """Whether a credits answer did not actually ANSWER: a transport failure, a 5xx, or a 2xx with no
    recognizable credits list. A read-back answers by LISTING the profile's credits, and absence is how
    this module reads "not shown on the profile", so an unrecognizable body must never be allowed to
    prove a hide landed."""
    return _transient(resp) or (resp.ok and not _has_credit_list(resp))


def _transient_result(row: Row, resp: Response, run_id: str, ledger: str,
                      inverse: dict[str, Any] | None = None) -> dict[str, Any]:
    if resp.ok and not _has_credit_list(resp):
        why = (f"the credits read answered HTTP {resp.status} with no credits list, so absence proves "
               f"nothing and it is retried next run: {resp.text()}")
    else:
        why = (f"transient core failure (HTTP {resp.status or 'no answer'}), retried next run: "
               f"{resp.text()}")
    return _finish(row, "transient", _row_result(row, "transient", why),
                   run_id, ledger, inverse=inverse or {"action": "none"})


def _probe(row: Row, *, core: Core) -> tuple[str, str]:
    """(disposition, why) for a DRY run: a read-only GET on the route this row would write to, so the
    report says `authority_unavailable` while C1/C2 are absent instead of pretending a write would
    land. Nothing is written: no POST, no ledger line, no proof row."""
    resp = core.probe(row.profile_id, row.track_id, row.intent)
    if _transient(resp):
        return "transient", (f"transient core failure (HTTP {resp.status or 'no answer'}), "
                              f"retried next run: {resp.text()}")
    if resp.status == 404:
        return "authority_unavailable", (f"the route answered HTTP {resp.status}: C1/C2 is not "
                                         f"deployed here ({resp.text()})")
    if resp.status in (401, 403):
        return "authority_refused", f"HTTP {resp.status}: {resp.text()}"
    if resp.status == 405:
        return "", ""
    if not resp.ok:
        return "refused", f"HTTP {resp.status}: {resp.text()}"
    return "", ""


def execute_row(row: Row, *, core: Core, apply: bool, state: dict[str, dict[str, Any]],
                run_id: str, ledger: str = LEDGER_PATH, lock: Callable[..., Any] = locked,
                sleep: Callable[[float], None] = time.sleep, readback_wait_s: float = 2.0,
                readback_tries: int = 3) -> dict[str, Any]:
    """Decide and (when `apply`) write ONE row. Never raises on a server refusal: a refusal is a
    disposition with the server's own words, and it is on the ledger."""
    why = assess(row, state=state)
    if why:
        return _row_result(row, why, {
            "identity_unlinked": "the ticket's verified account does not own this profile",
            "intent_unknown": f"intent {row.intent!r} is not one of {INTENTS}",
            "track_unresolved": "the ticket's track did not resolve to one of the profile's credits",
            "no_change": "already done for this ticket/profile/track/intent (see the ledger)",
        }.get(why, why))

    if not apply:
        disposition, why = _probe(row, core=core)
        if disposition:
            return _row_result(row, disposition, why)
        return _row_result(row, "would_write", f"dry run: {row.intent}")

    # evidence first: a proof follow-up is recorded and graded BEFORE the gate is read, because the
    # graded verdict is what the gate's proof route receives. A `hide_mine` is not a grey case, so it
    # never spends a model call.
    proof: dict[str, Any] | None = None
    if row.intent == NOT_ME_INTENT and row.proof_urls:
        proof = _record_proof(row, run_id=run_id,
                              request_id=str((state.get(row.row_key) or {}).get("request_id") or ""))

    adopt = False
    known: Response | None = None
    try:
        with lock():
            if row.intent == NOT_ME_INTENT:
                prior = claim_state(row.row_key, ledger)
                if prior in ("withdrawn", "reverted"):
                    return _row_result(row, "needs_customer", _WITHDRAWN_WHY, proof=proof)
                adopt = prior in CLAIM_FILED
                if not adopt and row_attempted(row.row_key, ledger):
                    # a previous POST may have landed with its response lost: read the gate before
                    # filing a second claim for the same track. A read that FAILED is not "no claim".
                    known = core.removal_request(row.profile_id, row.track_id)
                    if _transient(known):
                        return _transient_result(row, known, run_id, ledger)
                    adopt = bool(known.ok and (_request_id_of(known) or _gate_state(known)))
            if not adopt:
                return _write(row, core=core, run_id=run_id, ledger=ledger, proof=proof,
                              sleep=sleep, readback_wait_s=readback_wait_s,
                              readback_tries=readback_tries)
    except TimeoutError as exc:
        return _row_result(row, "lock_busy", f"the credit write lock was busy: {exc}", proof=proof)
    return _read_gate(row, core=core, run_id=run_id, ledger=ledger, state=state, proof=proof,
                      lock=lock, known=known)


def _record_proof(row: Row, *, run_id: str, request_id: str = "") -> dict[str, Any]:
    from . import proof_verifications as pv  # noqa: PLC0415 - the store owns its own connection

    store = pv.Store()
    try:
        records = []
        for url in dict.fromkeys(row.proof_urls):
            if not row.claimant_name:
                # no baseline name to compare against: grading would answer "different person" out of
                # nothing, so the proof is recorded as pending and the next run retries
                records.append(pv.record_pending(
                    profile_id=row.profile_id, track_id=row.track_id, ticket_id=row.ticket_id,
                    request_id=request_id, conversation_id=row.conversation_id,
                    claimant_account_id=row.account_id, proof_url=url, run_id=run_id,
                    reason="claimant name unreadable", store=store))
                continue
            records.append(pv.grade(profile_id=row.profile_id, track_id=row.track_id,
                                    track_title=row.track_name, claimant_name=row.claimant_name,
                                    role_summary=", ".join(row.roles), ticket_id=row.ticket_id,
                                    request_id=request_id, conversation_id=row.conversation_id,
                                    claimant_account_id=row.account_id, proof_url=url,
                                    run_id=run_id, store=store))
        verdict, why = pv.verdict_for(records)
        return {"verdict": verdict, "why": why, "records": records}
    finally:
        store.close()


def _write(row: Row, *, core: Core, run_id: str, ledger: str, proof: dict[str, Any] | None,
           sleep: Callable[[float], None], readback_wait_s: float, readback_tries: int) -> dict[str, Any]:
    """The write itself, under the lock. Records an intent line BEFORE the call (so a crash mid-call is
    visible and revertible) and an outcome line after it."""
    checkpoint = row.profile_id
    ledger_append({"run_id": run_id, "row_key": row.row_key, "ticket_id": row.ticket_id,
                   "profile_id": row.profile_id, "track_id": row.track_id, "intent": row.intent,
                   "outcome": "reserved", "checkpoint": checkpoint}, ledger)
    if row.intent == HIDE_INTENT:
        resp = core.hide(row.profile_id, row.track_id, request_ref=row.ticket_id)
        inverse: dict[str, Any] = {"action": "unhide", "profile_id": row.profile_id,
                                   "track_id": row.track_id}
    else:
        resp = core.file_removal_request(row.profile_id, row.track_id, row.roles,
                                         request_ref=row.ticket_id, proofs=_proof_refs(proof))
        # a filed claim is undone by WITHDRAWING it, never by unhiding: the hide the gate applied
        # belongs to the gate. Without a request id there is nothing this module may undo.
        inverse = {"action": "none"}

    if resp.status in (404, 405):
        return _finish(row, "authority_unavailable", _row_result(
            row, "authority_unavailable",
            f"the route answered HTTP {resp.status}: C1/C2 is not deployed here ({resp.text()})",
            proof=proof), run_id, ledger, inverse={"action": "none"})
    if resp.status in (401, 403):
        return _finish(row, "authority_refused", _row_result(
            row, "authority_refused", f"HTTP {resp.status}: {resp.text()}", proof=proof),
            run_id, ledger, inverse={"action": "none"})
    if _transient(resp):
        return _transient_result(row, resp, run_id, ledger)
    if not resp.ok:
        return _finish(row, "refused", _row_result(
            row, "refused", f"HTTP {resp.status}: {resp.text()}", proof=proof), run_id, ledger,
            inverse={"action": "none"})

    # a 2xx is recorded the instant it lands: the readback can raise or disagree, and an accepted write
    # must never be invisible to the cap, to idempotency or to a revert
    request_id = _request_id_of(resp)
    if row.intent == NOT_ME_INTENT and request_id:
        inverse = {"action": "withdraw", "profile_id": row.profile_id, "track_id": row.track_id,
                   "request_id": request_id}
    ledger_append({"run_id": run_id, "row_key": row.row_key, "ticket_id": row.ticket_id,
                   "profile_id": row.profile_id, "track_id": row.track_id, "intent": row.intent,
                   "outcome": ACCEPTED, "accepted_status": resp.status,
                   "response": resp.text(), "inverse": inverse,
                   "request_id": request_id, "proof": (proof or {}).get("verdict", "")}, ledger)

    if row.intent == HIDE_INTENT:
        ok, why, last = _readback_credit(row, core=core, sleep=sleep, tries=readback_tries,
                                         wait_s=readback_wait_s)
        if not ok:
            if last is not None and _credits_unanswered(last):
                # the write landed; the read-back never answered. That says nothing about the hide, so
                # it is retried next run and never parks the ticket as `partial`.
                return _transient_result(row, last, run_id, ledger, inverse=inverse)
            return _finish(row, "partial", _row_result(row, "partial", f"hidden but not read back: {why}"),
                           run_id, ledger, inverse=inverse)
        return _finish(row, "hide", _row_result(row, "hide", "hidden from the profile (read back)"),
                       run_id, ledger, inverse=inverse)

    # the claim POST carried the GRADED proofs, so they are on the gate already
    for rec in _graded_records(proof):
        _mark_submitted(rec, run_id=run_id, request_id=request_id)
    grant = core.removal_request(row.profile_id, row.track_id)
    if _transient(grant):
        # the claim POST landed; the state read never answered. Retried next run, never parked.
        return _transient_result(row, grant, run_id, ledger, inverse=inverse)
    if not grant.ok:
        return _finish(row, "partial", _row_result(
            row, "partial", f"the gate request was accepted but its state is unreadable: HTTP {grant.status}"),
            run_id, ledger, inverse=inverse, request_id=request_id, proof=proof)
    request_id = request_id or _request_id_of(grant)
    if request_id:
        inverse = {"action": "withdraw", "profile_id": row.profile_id, "track_id": row.track_id,
                   "request_id": request_id}
    return _gate_outcome(row, grant, run_id=run_id, ledger=ledger, inverse=inverse,
                         request_id=request_id, proof=proof)


#: Ledger outcomes that mean our claim POST's fate is UNKNOWN: the run reserved the write and never
#: got a definite answer. Only these can make a live claim ours.
CLAIM_UNANSWERED = ("reserved", "transient")


def _claim_lines(row: Row, ledger: str) -> list[dict[str, Any]]:
    """Every ledger line for this row's `not_me` claim, oldest first."""
    return [rec for rec in ledger_lines(ledger)
            if rec.get("row_key") == row.row_key and rec.get("intent") == NOT_ME_INTENT]


def _filed_by_us(row: Row, ledger: str) -> str:
    """The run id that filed a claim now on the gate and never got an answer for it, else "".

    A `reserved` line is written the instant before the POST, so the LAST `reserved` line is the write
    attempt and the line after it is that attempt's answer. If the POST's response is lost (a timeout,
    a 5xx) the run records `transient` and no acknowledgement, so the ledger cannot say whether the
    claim landed - but a live claim on the gate is exactly what a landed POST looks like. Recording
    the withdraw inverse is then the REVERTIBLE reading, and the alternative is a claim this
    automation filed that no `--revert` can ever withdraw.

    A DEFINITE answer settles it the other way. `refused`/`authority_*` means core answered and did NOT
    file our claim, so a live claim on the gate is somebody else's and must stay inverse-free; an
    acknowledgement that NAMED the request means the run that got it already recorded the inverse on
    its own line.

    Only the attempt's own answer counts, never the newest line for the row: a run that adopts the
    claim and cannot name it yet records `gate_filed` with no id, and reading THAT as the answer would
    erase the ownership the attempt established and leave the claim un-revertible forever."""
    lines = _claim_lines(row, ledger)
    start = -1
    for i, rec in enumerate(lines):
        if rec.get("outcome") == "reserved":
            start = i
    if start < 0:
        return ""
    answer = lines[start + 1] if start + 1 < len(lines) else {}
    outcome = str(answer.get("outcome") or "")
    if not outcome or outcome in CLAIM_UNANSWERED:
        # the run died between the reservation and the answer, or the answer never came
        return str(lines[start].get("run_id") or "")
    # A 2xx whose body carried no request id is an acknowledgement we could not NAME: the run that got
    # it recorded `accepted` with `inverse: none`, and if it stopped before the read-back supplied the
    # id, the claim is ours and no `--revert` can withdraw it. An `accepted` line that DOES carry an id
    # already has the withdraw inverse on it, so it is not this case.
    if outcome == ACCEPTED and not str(answer.get("request_id") or ""):
        return str(lines[start].get("run_id") or "")
    return ""


def _bind_inverse(row: Row, *, owner: str, run_id: str, request_id: str,
                  inverse: dict[str, Any], ledger: str) -> None:
    """Give the run that FILED the claim the withdraw inverse it could not record itself.

    A claim whose POST response was lost is filed by a run that never learned its request id, so its
    own ledger line carries no inverse. A later run that reads the id back is the only one that can
    supply it, and `revert(run_id)` undoes a RUN's writes: without this line, `--revert <the run that
    filed it>` would report nothing undone while the claim stayed live. The line repeats the filing
    run's own answer (same outcome, same row) with the id and the inverse attached, so the ledger
    stays append-only and the row's state does not change."""
    lines = _claim_lines(row, ledger)
    for rec in lines:
        if (str(rec.get("run_id") or "") == owner
                and str((rec.get("inverse") or {}).get("action") or "") in ("unhide", "withdraw")):
            return  # the filing run already carries an undo for this row
    answer: dict[str, Any] = {}
    for i, rec in enumerate(lines):
        if rec.get("outcome") == "reserved" and str(rec.get("run_id") or "") == owner:
            answer = lines[i + 1] if i + 1 < len(lines) else {}
    if not answer:
        return
    ledger_append({**answer, "inverse": inverse, "request_id": request_id,
                   "bound_by": run_id}, ledger)


def _read_gate(row: Row, *, core: Core, run_id: str, ledger: str,
               state: dict[str, dict[str, Any]] | None = None,
               proof: dict[str, Any] | None = None,
               lock: Callable[..., Any] = locked,
               known: Response | None = None) -> dict[str, Any]:
    """Adopt the gate's own state for a claim that is already on file. NEVER re-files: the gate owns
    the request, and a second POST would be a second claim. A proof that arrived after the claim was
    filed is POSTed to the gate's proof route as evidence on that same request, once."""
    resp = known if known is not None else core.removal_request(row.profile_id, row.track_id)
    if resp.status in (404, 405):
        return _finish(row, "authority_unavailable", _row_result(
            row, "authority_unavailable",
            f"the route answered HTTP {resp.status}: C1/C2 is not deployed here ({resp.text()})",
            proof=proof), run_id, ledger, inverse={"action": "none"})
    if resp.status in (401, 403):
        return _finish(row, "authority_refused", _row_result(
            row, "authority_refused", f"HTTP {resp.status}: {resp.text()}", proof=proof),
            run_id, ledger, inverse={"action": "none"})
    if _transient(resp):
        return _transient_result(row, resp, run_id, ledger)
    if not resp.ok:
        return _finish(row, "refused", _row_result(
            row, "refused", f"HTTP {resp.status}: {resp.text()}", proof=proof), run_id, ledger,
            inverse={"action": "none"})
    request_id = (_request_id_of(resp)
                  or str(((state or {}).get(row.row_key) or {}).get("request_id") or ""))
    # A claim this run only READ is not this run's write: `revert(run_id)` undoes THIS run's writes, so
    # recording a withdraw for a claim we merely adopted would let reverting a proof-only run drop the
    # customer's removal request. The proof POST this run may make has no inverse of its own (the gate
    # keeps the evidence). The ONE exception is a claim this automation filed whose POST response was
    # lost: the ledger has our `reserved` line and no acknowledgement, so the claim is ours and must
    # stay revertible.
    inverse: dict[str, Any] = {"action": "none"}
    owner = _filed_by_us(row, ledger) if request_id else ""
    if request_id and owner:
        withdraw = {"action": "withdraw", "profile_id": row.profile_id, "track_id": row.track_id,
                    "request_id": request_id}
        if owner == run_id:
            inverse = withdraw
        else:
            # The claim is the FILING run's write, so that run is the one `--revert` must undo. This
            # run only READ the claim (and may have sent proof), so its own line records no undo:
            # giving it one would let reverting a read-only run withdraw the filing run's live claim.
            _bind_inverse(row, owner=owner, run_id=run_id, request_id=request_id,
                          inverse=withdraw, ledger=ledger)
    if request_id and _unsubmitted(proof, request_id):
        try:
            with lock():
                pending = _unsubmitted(proof, request_id)
                if pending:
                    return _submit_proofs(row, core=core, pending=pending, request_id=request_id,
                                          resp=resp, run_id=run_id, ledger=ledger, inverse=inverse,
                                          proof=proof)
        except TimeoutError as exc:
            return _row_result(row, "lock_busy", f"the credit write lock was busy: {exc}", proof=proof)
    return _gate_outcome(row, resp, run_id=run_id, ledger=ledger, inverse=inverse,
                         request_id=request_id, proof=proof)


def _submit_proofs(row: Row, *, core: Core, pending: list[dict[str, Any]], request_id: str,
                   resp: Response, run_id: str, ledger: str, inverse: dict[str, Any],
                   proof: dict[str, Any] | None) -> dict[str, Any]:
    """POST each new proof to the gate's proof route, under the write lock, then adopt the state the
    gate returns."""
    for rec in pending:
        sub = core.submit_removal_proof(row.profile_id, request_id, _proof_payload(row, rec),
                                        request_ref=row.ticket_id)
        if sub.status in (404, 405):
            return _finish(row, "proof_awaiting_gate", _row_result(
                row, "proof_awaiting_gate",
                f"proof received, graded {rec.get('verdict')}, awaiting gate: the proof route "
                f"answered HTTP {sub.status}", proof=proof), run_id, ledger, inverse=inverse,
                request_id=request_id, proof=proof)
        if sub.status == 409:
            for other in pending:
                _mark_submitted(other, run_id=run_id, request_id=request_id)
            return _gate_outcome(row, sub if _gate_state(sub) else resp, run_id=run_id,
                                 ledger=ledger, inverse=inverse, request_id=request_id,
                                 proof=proof)
        if _transient(sub):
            return _transient_result(row, sub, run_id, ledger, inverse=inverse)
        if not sub.ok:
            return _finish(row, "refused", _row_result(
                row, "refused", f"the proof route answered HTTP {sub.status}: {sub.text()}",
                proof=proof), run_id, ledger, inverse=inverse, request_id=request_id, proof=proof)
        _mark_submitted(rec, run_id=run_id, request_id=request_id)
        if _gate_state(sub):
            resp = sub
    return _gate_outcome(row, resp, run_id=run_id, ledger=ledger, inverse=inverse,
                         request_id=request_id, proof=proof)


def _unsubmitted(proof: dict[str, Any] | None, request_id: str) -> list[dict[str, Any]]:
    """The graded proof rows this run has that the gate has not been given yet. Deduped on the evidence
    itself (link + grade identity), both against the store and within this batch, so the same link
    listed twice on one ticket is submitted once."""
    from . import proof_verifications as pv  # noqa: PLC0415 - the store owns its own connection

    store = pv.Store()
    try:
        already = store.submitted_keys(request_id)
    finally:
        store.close()
    out: list[dict[str, Any]] = []
    for rec in (proof or {}).get("records") or []:
        key = (str(rec.get("proof_ref") or ""), str(rec.get("prompt_sha256") or ""))
        if rec.get("verdict") not in pv.GRADED:
            continue
        if key in already or key in {(str(r.get("proof_ref") or ""),
                                      str(r.get("prompt_sha256") or "")) for r in out}:
            continue
        if rec.get("submitted_at") and str(rec.get("request_id") or "") == request_id:
            # already POSTed to THIS request, so the gate has this evidence. A row submitted to a
            # DIFFERENT request is not evidence for this one - that request may have been withdrawn -
            # so it is submitted again rather than silently dropped.
            continue
        out.append(rec)
    return out


def _proof_payload(row: Row, rec: dict[str, Any]) -> dict[str, Any]:
    """One graded proof, in the shape the gate's proof route takes."""
    return {"trackId": row.track_id,
            "kind": rec.get("proof_kind") or "link",
            "url": rec.get("proof_ref") or "",
            "sha256": rec.get("prompt_sha256") or "",
            "grade": {"verdict": rec.get("verdict") or "",
                      "confidence": rec.get("confidence"),
                      "evidence": (rec.get("quoted_evidence") or "")[:300],
                      "grader": rec.get("model") or ""},
            "gradedAt": rec.get("graded_at") or ""}


def _mark_submitted(rec: dict[str, Any], *, run_id: str, request_id: str = "") -> None:
    from . import proof_verifications as pv  # noqa: PLC0415 - the store owns its own connection

    row_id = rec.get("id")
    if not row_id:
        return
    # The store holds ONE request per proof row, and the gate allows one live claim per
    # (profile, track), so the newest submission wins. Re-submitting to a NEW request must therefore
    # MOVE the row: leaving it naming the old request would make every later run see it as unsubmitted
    # for the new one and POST the same evidence again, forever.
    if not rec.get("submitted_at") or str(rec.get("request_id") or "") != request_id:
        pv.mark_submitted(int(row_id), run_id=run_id, request_id=request_id)
        rec["submitted_at"] = utcnow()
        rec["request_id"] = request_id


def _gate_outcome(row: Row, resp: Response, *, run_id: str, ledger: str, inverse: dict[str, Any],
                  request_id: str, proof: dict[str, Any] | None = None) -> dict[str, Any]:
    """The gate's own state, as a disposition. The ledger outcome is the DISPOSITION (so `row_state`
    sees it and the next run adopts it) and never the raw gate word."""
    st = _gate_state(resp)
    if st == GATE_REMOVED:
        return _finish(row, "removed", _row_result(row, "removed", "the gate removed the credit",
                                                   proof=proof),
                       run_id, ledger, inverse=inverse, request_id=request_id, proof=proof)
    if st in (GATE_LISTED, GATE_DIFFERENT, GATE_KEPT):
        disposition = "kept" if st == GATE_KEPT else "proof_required"
        return _finish(row, disposition, _row_result(
            row, disposition, f"the gate answered {st!r}", proof=proof), run_id, ledger,
            inverse=inverse, request_id=request_id, proof=proof)
    return _finish(row, "gate_filed", _row_result(
        row, "gate_filed", f"the gate request is filed and {st or 'unreadable'}", proof=proof),
        run_id, ledger, inverse=inverse, request_id=request_id, proof=proof)


def _graded_records(proof: dict[str, Any] | None) -> list[dict[str, Any]]:
    """The proof records that carry a GRADE. An ungraded (`pending`) record is reported, never sent to
    the gate as evidence and never recorded as submitted."""
    from . import proof_verifications as pv  # noqa: PLC0415 - the store owns its own connection

    return [r for r in (proof or {}).get("records") or [] if r.get("verdict") in pv.GRADED]


def _proof_refs(proof: dict[str, Any] | None) -> list[dict[str, Any]]:
    """The GRADED proof records, reduced to what the gate needs: the reference, its class and the
    verdict with the quoted passage. The full row stays in `credit_proof_verifications`."""
    return [{"kind": rec.get("proof_kind"), "ref": rec.get("proof_ref"),
             "host_class": rec.get("host_class") or "", "verdict": rec.get("verdict"),
             "confidence": rec.get("confidence"),
             "evidence": (rec.get("quoted_evidence") or "")[:300]}
            for rec in _graded_records(proof)]


def _request_id_of(resp: Response) -> str:
    body = resp.body
    if isinstance(body, dict):
        data = body.get("data") if isinstance(body.get("data"), dict) else body
        for key in ("requestId", "request_id", "id"):
            if data.get(key):
                return str(data[key])
    return ""


def _gate_state(resp: Response) -> str:
    body = resp.body
    if isinstance(body, dict):
        data = body.get("data") if isinstance(body.get("data"), dict) else body
        for key in ("state", "status", "gateState"):
            if data.get(key):
                value = str(data[key]).strip().lower()
                return {"pending": GATE_CHECKING, "checking": GATE_CHECKING,
                        "needs_proof": GATE_LISTED, "listed": GATE_LISTED}.get(value, value)
    return ""


#: Gate states that mean the claim is still LIVE, so a withdraw that answered 2xx did not take.
GATE_LIVE = (GATE_CHECKING, GATE_LISTED, GATE_KEPT, GATE_DIFFERENT)
#: Gate states that mean the claim is gone (a withdraw landed, or the gate finished it).
GATE_GONE = ("withdrawn", "cancelled", "canceled", "deleted", GATE_REMOVED)


def _undo_landed(core: Core, action: str, inverse: dict[str, Any]) -> tuple[bool, str]:
    """(the inverse actually took effect, why not).

    A 2xx is an ACKNOWLEDGEMENT, not proof. Core can accept an undo and not apply it, and recording
    `reverted` then would reopen the ticket while the credit is still hidden (or the claim still
    active) - the customer is told nothing and the row is never looked at again. So every undo is
    read back, and a read that disagrees or never answers stays `revert_failed`, which the next
    `--revert <run_id>` retries. Re-issuing an undo is safe: unhiding an unhidden credit and
    withdrawing a withdrawn claim are both no-ops."""
    profile_id = str(inverse.get("profile_id") or "")
    if action == "unhide":
        items, resp, complete = _all_credits(core, profile_id)
        if not resp.ok:
            return False, f"unhide not read back: HTTP {resp.status}: {resp.text()}"
        if not complete:
            return False, "unhide not read back: the credits list did not finish"
        track_id = str(inverse.get("track_id") or "")
        match = next((it for it in items if track_id and _track_of(it) == track_id), None)
        if match is not None and _hidden_of(match):
            return False, "the credit is still hidden after the unhide"
        return True, ""
    if action == "withdraw":
        resp = core.removal_request(profile_id, str(inverse.get("track_id") or ""))
        if resp.status == 404:
            return True, ""
        if not resp.ok:
            return False, f"withdraw not read back: HTTP {resp.status}: {resp.text()}"
        state = _gate_state(resp)
        if state in GATE_GONE:
            return True, ""
        if state in GATE_LIVE:
            return False, f"the claim is still {state} after the withdraw"
        return False, f"withdraw not read back: the gate answered {state or 'no state'!r}"
    return False, f"inverse {action or 'none'!r} is not executable"


def _all_credits(core: Core, profile_id: str) -> tuple[list[dict[str, Any]], Response, bool]:
    """(every credit on the profile, the last answer, whether the walk finished).

    Paged, because one page is not the list. `/admin/profile/:id/credits` IGNORES `offset` and echoes
    page 1 back, so the walk is page-based. Reading only page 1 is not a harmless truncation here:
    a credit on page 2+ looks ABSENT, and absent is exactly how this module reads "not shown on the
    profile", so a hide that did not take would read back as a success. A walk that cannot finish
    says so, and the caller treats it as a read that did not answer rather than as a short list."""
    out: list[dict[str, Any]] = []
    last: Response | None = None
    for page in range(1, CREDITS_MAX_PAGES + 1):
        resp = core.credits(profile_id, page=page)
        last = resp
        if not resp.ok:
            return out, resp, False
        if not _has_credit_list(resp):
            # nothing that looks like a credits list: the read did not answer, so absence proves nothing
            return out, resp, False
        items = _items(resp)
        out.extend(items)
        total = resp.body.get("total") if isinstance(resp.body, dict) else None
        if isinstance(total, int):
            if len(out) >= total:
                return out, resp, True
            if not items:
                return out, resp, False
            continue
        # No total: a page shorter than the limit is the last page.
        if len(items) < CREDITS_PAGE_LIMIT:
            return out, resp, True
    return out, last or Response(0, None, "no credits page answered"), False


def _readback_credit(row: Row, *, core: Core, sleep: Callable[[float], None], tries: int,
                     wait_s: float) -> tuple[bool, str, Response | None]:
    """(read-back agrees, why not, the last answer). Agrees with `_compare`: a credit that is ABSENT
    from the profile's list is not shown, so it is a success; a present row must carry a positive
    hidden marker. The last answer is returned so the caller can tell a read-back that DISAGREED (a
    real `partial`) from one that never answered (a `transient` the next run retries)."""
    why = "not attempted"
    last: Response | None = None
    for i in range(max(1, tries)):
        items, resp, complete = _all_credits(core, row.profile_id)
        last = resp
        ok, why = _compare(row, resp)
        if ok and not complete:
            # A truncated walk cannot say the credit is absent, and absent is how this module reads
            # "not shown". That is a read that did not answer, never a success.
            ok, why = False, "the credits list did not finish, so absence is not proof of a hide"
        if ok:
            match = next((it for it in items if row.track_id and _track_of(it) == row.track_id),
                         None)
            if match is None or _hidden_of(match):
                return True, "", resp
            why = "the credit is still shown on the profile"
        if i + 1 < tries:
            sleep(wait_s)
    return False, why, last


def _finish(row: Row, outcome: str, result: dict[str, Any], run_id: str, ledger: str,
            *, inverse: dict[str, Any], request_id: str = "",
            proof: dict[str, Any] | None = None) -> dict[str, Any]:
    """The row's outcome line. It carries the SAME inverse the accepted line does, so a revert replays
    exactly one undo per write no matter where a run stopped. `none` when this run wrote nothing that
    an inverse could undo (a claim somebody else filed, a proof POST)."""
    ledger_append({"run_id": run_id, "row_key": row.row_key, "ticket_id": row.ticket_id,
                   "profile_id": row.profile_id, "track_id": row.track_id, "intent": row.intent,
                   "outcome": outcome, "why": result.get("why", ""), "inverse": inverse,
                   "request_id": request_id, "proof": (proof or {}).get("verdict", "")}, ledger)
    return result


# ── the run ────────────────────────────────────────────────────────────────
def run(rows_path: str, *, apply: bool = False, limit: int | None = None,
        core: Core | None = None, ledger: str = LEDGER_PATH,
        registry: str = REGISTRY, live_flag: str = LIVE_FLAG, kill_file: str = KILL_FILE,
        lock: Callable[..., Any] = locked, sleep: Callable[[float], None] = time.sleep,
        log: Callable[[str], None] | None = None,
        now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
        run_id: str | None = None) -> Result:
    """One rows file. Dry run by default: every decision is made against the same facts and NOTHING is
    written (no core row, no ledger line, no proof row).

    `run_id` names this run in the ledger and is what `revert(run_id)` selects on. It defaults to the
    second-resolution timestamp, which is enough for the hourly cron but NOT for two runs that start in
    the same second (a manual `--ticket` run beside the cron): those would share one id and a single
    `--revert` would undo both runs' writes. A caller that already has a unique per-run name (the
    drainer's rows file) passes it here so the two can never collide."""
    log = log or (lambda msg: None)
    rows = load_rows(rows_path)
    if limit:
        rows = rows[:limit]
    res = Result()
    if Path(kill_file).exists():
        res.stopped = f"kill file {kill_file} present"
        return res
    if apply:
        ok, why = may_write(registry=registry, live_flag=live_flag, kill_file=kill_file)
        if not ok:
            res.stopped = why
            res.dispositions = {r.row_key: [_row_result(r, "authority_refused", why)] for r in rows}
            return res
    core = core or WrapperCore()
    state = row_state(ledger)
    run_id = run_id or now().strftime("%Y%m%dT%H%M%SZ")
    for row in rows:
        out = execute_row(row, core=core, apply=apply, state=state, run_id=run_id, ledger=ledger,
                          lock=lock, sleep=sleep)
        res.dispositions.setdefault(row.row_key, []).append(out)
        if apply:
            # refresh the state so a second row for the same key in this batch cannot double-write
            state = row_state(ledger)
        log(f"{row.ticket_id}: {row.intent}: {out.get('disposition')}: {out.get('why')}")
    res.writes = sum(1 for r in ledger_lines(ledger)
                     if str(r.get("run_id")) == run_id and r.get("outcome") == ACCEPTED)
    return res


# ── revert ─────────────────────────────────────────────────────────────────
#: Ledger outcomes a revert has already produced: never replayed again. A FAILED revert is not here,
#: so the next `--revert` falls through to the write it could not undo and retries it.
REVERTED = ("reverted", "withdrawn")


def revert(run_id: str, *, core: Core | None = None, ledger: str = LEDGER_PATH,
           registry: str = REGISTRY, live_flag: str = LIVE_FLAG,
           kill_file: str = KILL_FILE, proof_store: str | None = None,
           log: Callable[[str], None] | None = None,
           untag: Callable[[list[dict[str, Any]]], None] | None = None,
           lock: Callable[[], Any] = locked) -> dict[str, Any]:
    """Undo a run: replay ONE inverse per row newest-first, read every undo back, and append the lines.

    A `partial` write and an `accepted` line with no outcome line are writes too, so they are
    revertible; a row that already has an outcome line is not undone twice. The run's proof rows are
    marked reverted in the same pass.

    A revert is a WRITE, so it needs the same live answer the forward write did. A run that never
    wrote (a dry run, or a run where every row refused) produces nothing to revert and says so.

    It also takes the SAME shared credit-write lock the forward write takes, and holds it across the
    ledger read, every undo and the caller's `untag` hook. Without that, a concurrent apply run can
    read the credit as hidden, decide `no_change`, and tag the ticket `complete` while this revert is
    un-hiding it: the credit is visible again and the ticket says done. `untag` is a callback rather
    than the caller's own step so the ticket transition happens INSIDE the same critical section."""
    log = log or (lambda msg: None)
    if not str(run_id or "").strip():
        raise ValueError("a run id is required")
    ok, why = may_write(registry=registry, live_flag=live_flag, kill_file=kill_file)
    if not ok:
        return {"run_id": run_id, "stopped": why, "reverted": 0, "rows": []}
    core = core or WrapperCore()
    try:
        with lock():
            return _revert_locked(run_id, core=core, ledger=ledger, proof_store=proof_store,
                                  log=log, untag=untag)
    except TimeoutError as exc:
        return {"run_id": run_id, "stopped": f"the credit write lock was busy: {exc}",
                "reverted": 0, "rows": []}


def _revert_locked(run_id: str, *, core: Core, ledger: str, proof_store: str | None,
                   log: Callable[[str], None],
                   untag: Callable[[list[dict[str, Any]]], None] | None) -> dict[str, Any]:
    """The body of `revert`, run under the shared credit-write lock."""
    records = [r for r in ledger_lines(ledger) if str(r.get("run_id")) == run_id]
    by_key: dict[str, list[dict[str, Any]]] = {}
    for rec in records:
        key = str(rec.get("row_key") or "")
        if key:
            by_key.setdefault(key, []).append(rec)
    chosen: dict[str, dict[str, Any]] = {}
    for key, recs in by_key.items():
        if recs[-1].get("outcome") in REVERTED:
            continue
        for rec in reversed(recs):
            inverse = rec.get("inverse") if isinstance(rec.get("inverse"), dict) else {}
            if str(inverse.get("action") or "") in ("unhide", "withdraw"):
                chosen[key] = rec
                break
    undone: list[dict[str, Any]] = []
    for rec in chosen.values():
        inverse = rec.get("inverse") if isinstance(rec.get("inverse"), dict) else {}
        action = str(inverse.get("action") or "")
        try:
            if action == "unhide":
                resp = core.unhide(str(inverse.get("profile_id")), str(inverse.get("track_id")),
                                   request_ref=str(rec.get("ticket_id") or ""))
                if not resp.ok:
                    outcome, detail = "revert_failed", resp.text()
                else:
                    landed, why_not = _undo_landed(core, action, inverse)
                    outcome = "reverted" if landed else "revert_failed"
                    detail = "" if landed else why_not
            elif action == "withdraw" and rec.get("request_id"):
                resp = core.withdraw_removal_request(str(inverse.get("profile_id")),
                                                     str(rec["request_id"]),
                                                     request_ref=str(rec.get("ticket_id") or ""))
                if not resp.ok:
                    outcome, detail = "revert_failed", resp.text()
                else:
                    landed, why_not = _undo_landed(core, action, inverse)
                    outcome = "withdrawn" if landed else "revert_failed"
                    detail = "" if landed else why_not
            else:
                outcome, detail = "revert_skipped", f"inverse {action or 'none'!r} is not executable"
        except ApiError as exc:  # pragma: no cover - WrapperCore returns responses, never raises
            outcome, detail = "revert_failed", str(exc)[:200]
        ledger_append({"run_id": run_id, "row_key": rec.get("row_key"), "ticket_id": rec.get("ticket_id"),
                       "profile_id": rec.get("profile_id"), "track_id": rec.get("track_id"),
                       "intent": rec.get("intent"), "outcome": outcome,
                       "why": detail, "reverts": rec.get("outcome")}, ledger)
        undone.append({"row_key": rec.get("row_key"), "ticket_id": rec.get("ticket_id"),
                       "outcome": outcome, "why": detail})
        log(f"{rec.get('ticket_id')}: {outcome}")
    if untag is not None:
        # inside the lock: the ticket must not be re-tagged by a concurrent apply between the undo
        # landing and the tag coming off.
        done = [u for u in undone if u["outcome"] in ("reverted", "withdrawn")]
        if done:
            untag(done)
    from . import proof_verifications as pv  # noqa: PLC0415 - the store owns its own connection

    store = pv.Store(proof_store) if proof_store else pv.Store()
    try:
        proof_rows = pv.revert_run(run_id, by=REQUESTER, store=store)["reverted_rows"]
    finally:
        store.close()
    return {"run_id": run_id, "stopped": "",
            "reverted": len([u for u in undone if u["outcome"] in ("reverted", "withdrawn")]),
            "proof_rows_reverted": proof_rows, "rows": undone}


# ── ticket outcome (shared with the drainer) ───────────────────────────────
def ticket_outcome(dispositions: Iterable[str]) -> str | None:
    """ONE `customer-outcome:` name per ticket from its rows' dispositions, or None to leave it alone."""
    names = [str(d) for d in dispositions if d and d != "would_write"]
    if not names:
        return None
    ds = set(names)
    if ds & set(IN_FLIGHT):
        # An in-flight row outranks EVERY terminal tag, `partial` and the refusals included: the
        # ticket is tagged only when every row is final, or the in-flight claim's result would never
        # be read. The in-flight row is retried next run, and the digest still names it.
        return None
    for d in OUTCOME_ORDER:
        if d in ds:
            return TAG_FOR.get(d)
    return None
