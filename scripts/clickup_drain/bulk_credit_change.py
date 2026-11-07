#!/usr/bin/env python3
"""Drain `action:bulk-credit-change` tickets: one ticket = one bounded batch.

WHY THIS EXISTS
---------------
"Update credits on multiple tracks" is the ticket a customer files after pasting
a list of tracks and the roles they say are wrong. It is Tier 2, it has no
automatic executor, and it is the ticket shape most likely to be abandoned
halfway: a human opens N tracks and edits N credits by hand, stops when the
session ends, and the ticket keeps saying "to do" with some of the rows applied.
The board (list 901000600160, `tags[]=action:bulk-credit-change`, non-terminal)
measured 99 open on 2026-11-03; an earlier count of 149 could not be reproduced.

WHAT A RUN DOES, IN ORDER
-------------------------
  1. READ     the open `action:bulk-credit-change` tickets, oldest first, and
              parse `details.bulk_rows` out of the ticket's ACTION-REQUEST block
              (`clickup_drain/manifest.py`). A ticket with prose only is
              REFUSED and counted as `unparseable` — that count is the signal
              that says whether the intake or the executor is the problem.
  2. VALIDATE every row of the batch BEFORE any write: track exists, the profile
              exists and is not merged, the profile already holds a credit on
              that track (this is an EDIT, not a fabricated credit), and — when
              the ticket names `customer_profile_id` — every row targets that
              profile and no other. One bad row refuses the WHOLE batch with
              zero writes (`all-or-nothing at validation`).
  3. APPLY    the rows sequentially, one at a time, each with its own read-back.
              A row already holding the requested role is `already` (verified,
              zero writes). Otherwise the documented add goes out
              (`POST /admin/track/:t/profile/:p/credits {"role": …}`) and the
              role set is re-read. Rows are never applied in parallel: the read-
              backs have to be ordered or a later row's pre-image is a guess.
              A row that fails AFTER the write boundary stops the batch
              immediately and leaves the completed rows recorded.
  4. REPORT   one `customer-outcome:*` tag on the ticket, and nothing else:
                every requested row verified        -> `complete`
                some verified, some not             -> `partial` + ONE internal
                                                       comment naming only the
                                                       rows that did not land
                validation refused (zero writes)    -> `blocked`
                a removal was requested             -> `blocked`
              `partial` is a first-class outcome and NEVER a close. The
              reconciler reports it and leaves the ticket open, so it surfaces in
              the SLA digest instead of vanishing. `unparseable` writes no tag at
              all, so the ticket stays `waiting-on-us` and also surfaces.

WHAT A RUN NEVER DOES
---------------------
  * never writes a ClickUp status — the reconciler is the only close writer
  * never removes a credit (`remove: true` / `from_role` are refused; removals
    are core #10310 and a named human's own-login job)
  * never messages the customer: no row count, no timeline, no copy at all
  * never writes more than 3 tickets/run, 25 rows/ticket, or 100 credit writes
    per UTC day (shared with the correction executor; see `write_path.py`)

DRY RUN IS THE DEFAULT
----------------------
`--apply` is required to write anything. Without it nothing is written and the
run prints the per-bucket counts plus the manifest hit rate, which is the report
the captain asks for before a live batch.

USAGE
-----
  python3 scripts/clickup_drain/bulk_credit_change.py               # dry run
  python3 scripts/clickup_drain/bulk_credit_change.py --apply       # live
  python3 scripts/clickup_drain/bulk_credit_change.py --ticket 86a…  # one ticket
  python3 scripts/clickup_drain/bulk_credit_change.py --revert /var/lib/…/ledger.jsonl
     (PLAN ONLY: an undo is a removal, which the admin wrapper refuses to agents)

ENV
---
  CLICKUP_API_KEY          required for the board
  CLICKUP_LIST_ID          default 901000600160
  CLICKUP_DRAIN_STATE_DIR  default /var/lib/hydra/bulk-credit-change
  CLICKUP_DRAIN_ADMIN_SCRIPT  override the muso-admin-api.sh path (tests)
  CLICKUP_DRAIN_NOW        epoch override (tests)

EXIT CODES
----------
  0 clean (including "nothing to do" and "kill file present")
  1 usage / env error
  2 at least one ticket stopped mid-batch (a `partial` is a real outcome to look
    at, not a silent success)
  3 the run itself could not proceed (lock held, admin unreachable)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.parse
import uuid
from dataclasses import dataclass, field
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).resolve().parents[1]
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from lib.clickup_client import ClickUp, ClickUpRateLimited  # noqa: E402
from lib.customer_outcome import (  # noqa: E402
    OUTCOME_COMPLETE,
    outcome_tag,
    outcome_tags_of,
    customer_outcome_of,
)

from clickup_drain import manifest as mf  # noqa: E402
from clickup_drain.write_path import (  # noqa: E402
    AdminError,
    CreditAdmin,
    DailyCapReached,
    DrainBlocked,
    NotFound,
    Unavailable,
    WritePath,
    is_transient_status,
    is_unanswerable_status,
    add_role,
    profile_credit_roles,
    profile_status,
    plan_revert,
    track_exists,
    wait_for_role,
)

DEFAULT_LIST_ID = "901000600160"
ACTION_TYPE = "bulk-credit-change"

ACTION_TAG = f"action:{ACTION_TYPE}"

MAX_TICKETS_PER_RUN = 3
MAX_PAGES = 200
READBACK_ATTEMPTS = 6

# Outcomes that mean "this ticket has already been dealt with by this drainer".
# A `partial` is NOT re-picked: re-running it produces the same partial against
# the same live state, and with 3 tickets/run it would starve the queue. It goes
# to a human through the SLA digest instead.
TERMINAL_OUTCOMES = {
    OUTCOME_COMPLETE,
    "partial",
    "blocked",
    "not-applicable",
    "verification-required",
}

OUTCOME_PARTIAL = "partial"
OUTCOME_BLOCKED = "blocked"

STATE_DIR = os.environ.get("CLICKUP_DRAIN_STATE_DIR", "/var/lib/hydra/bulk-credit-change")
ATTEMPTS_PATH = os.path.join(STATE_DIR, "attempts.json")

RUN_EXIT_OK = 0
RUN_EXIT_USAGE = 1
RUN_EXIT_PARTIAL = 2
RUN_EXIT_BLOCKED = 3


# --------------------------------------------------------------------------
# ClickUp helpers
# --------------------------------------------------------------------------
def clickup_token() -> str:
    key = os.environ.get("CLICKUP_API_KEY", "").strip()
    if not key:
        raise SystemExit("CLICKUP_API_KEY is not set")
    return key


def task_text(task: dict) -> str:
    return str(task.get("description") or task.get("text_content") or "")


def task_tags(task: dict) -> set[str]:
    return {
        str(t.get("name", "")).strip().lower()
        for t in task.get("tags") or []
        if isinstance(t, dict)
    }


def has_action_tag(task: dict) -> bool:
    return ACTION_TAG in task_tags(task)


def already_attempted(task: dict) -> bool:
    """A ticket this drainer should not spend another slot on."""
    if customer_outcome_of(task) in TERMINAL_OUTCOMES:
        return True
    # Any *other* outcome tag (an invalid one) is still a marker someone else
    # set: leave it alone rather than overwrite an unknown decision.
    return bool(outcome_tags_of(task))


def valid_operator(value: str) -> bool:
    """A named human, as an email address.

    `--allow-tagged` overwrites a recorded decision, so the value is not a label
    we accept on trust: it has to look like a person's address, and it is written
    to the ledger together with the decision it replaced.
    """
    if not isinstance(value, str) or not value or value != value.strip():
        return False
    if any(ch.isspace() for ch in value):
        return False
    local, _, domain = value.partition("@")
    return bool(local) and "." in domain and not domain.startswith(".") \
        and not domain.endswith(".")


def override_operators_path() -> str:
    """Where the reviewed list of override-authorized humans lives.

    PINNED to the repo's policy file, deliberately with no environment override.
    An env var would make the allowlist replaceable at runtime: point it at a
    file containing `invented@example.com` and both `--allow-tagged` and
    `--clear-hold` accept an address nobody reviewed. The list is a reviewed
    artifact, so the only way to change it is a PR to the file itself. Tests
    inject a fixture through `load_override_operators(path=...)` or by patching
    this function, never through the process environment.
    """
    return str(Path(__file__).resolve().parents[2]
               / "policies" / "credit-override-operators.txt")


def load_override_operators(path: str | None = None) -> frozenset[str]:
    """The humans who may authorize an outcome override.

    `--operator` is a CLAIM, not a credential: a command-line flag cannot prove
    who typed it, and an email-shaped string is something anyone can invent. What
    code can do is refuse every name that is not on the reviewed list of people
    who own credit decisions, so an invented address cannot authorize replacing
    a human's hold. A missing or empty file fails CLOSED — no list, no override.
    """
    target = path or override_operators_path()
    try:
        with open(target, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return frozenset()
    return frozenset(
        line.strip().casefold() for line in lines
        if line.strip() and not line.strip().startswith("#")
    )


def override_operator_error(operator: str, allowlist: frozenset[str]) -> str | None:
    """Why this `--operator` may not authorize an override, or None if it may."""
    if not valid_operator(operator):
        return ("--allow-tagged overrides a recorded customer-outcome decision, so "
                "it requires --operator <email> naming the human taking that "
                f"decision (got {operator!r}); the override is written to the ledger")
    if operator.strip().casefold() not in allowlist:
        return (f"--operator {operator!r} is not on the override allowlist "
                f"({override_operators_path()}); an outcome override must be "
                "authorized by a named human on that list")
    return None


def select_tickets(
    tickets: list[dict], *, wanted: set[str] | None = None, allow_tagged: bool = False,
) -> tuple[list[dict], list[dict]]:
    """(selected, skipped_because_tagged).

    An explicit `--ticket` picks a ticket by NAME, which is how someone re-runs
    one by hand. That must not become a way around the outcome guard: a ticket
    already carrying `customer-outcome:verification-required` reflects a human
    decision, and re-running it could replace that with `complete` and have the
    reconciler announce it as resolved. Same guard as a scan, with one audited
    escape hatch (`--allow-tagged` + a named `--operator`).
    """
    if wanted is None:
        return [t for t in tickets if not already_attempted(t)], []
    named = [t for t in tickets if str(t.get("id")) in wanted]
    if allow_tagged:
        return named, []
    selected = [t for t in named if not already_attempted(t)]
    skipped = [t for t in named if already_attempted(t)]
    return selected, skipped


def fetch_open_tickets(client: ClickUp, list_id: str, limit: int) -> list[dict]:
    """Every open `action:bulk-credit-change` ticket, oldest first."""
    tasks = client.list_tasks(
        list_id,
        [
            ("archived", "false"),
            ("include_closed", "false"),
            ("subtasks", "false"),
            ("order_by", "created"),
            ("tags[]", ACTION_TAG),
        ],
        MAX_PAGES,
    )
    open_tasks = [t for t in tasks if has_action_tag(t) and not _is_closed(t)]
    open_tasks.sort(key=lambda t: int(t.get("date_created") or 0))
    return open_tasks if limit <= 0 else open_tasks[:limit]


def _is_closed(task: dict) -> bool:
    from lib.customer_outcome import workflow_terminal
    return workflow_terminal(task)


def _cu(client: ClickUp, method: str, path: str, body: dict | None = None):
    """ClickUp call whose transport failures surface as RuntimeError.

    `clickup_client.request` re-raises urllib's HTTPError for any non-429 error,
    which is an OSError and would otherwise escape every `except RuntimeError`
    in this module as a bare traceback from a cron run.
    """
    try:
        return client.request(method, path, body=body)
    except OSError as exc:  # urllib.error.HTTPError / URLError
        raise RuntimeError(f"clickup {method} {path} failed: {exc}") from exc


def post_comment(client: ClickUp, task_id: str, text: str) -> None:
    status, body = _cu(client, "POST", f"/task/{task_id}/comment",
                       {"comment_text": text, "notify_all": False})
    if status not in (200, 201):
        raise RuntimeError(f"clickup comment {task_id} -> {status}: {body}")


def read_task(client: ClickUp, task_id: str) -> dict:
    status, body = _cu(client, "GET", f"/task/{task_id}")
    if status != 200 or not isinstance(body, dict):
        raise RuntimeError(f"could not re-read ClickUp task {task_id} ({status})")
    return body


def ensure_ticket_unchanged(
    client: ClickUp, snapshot: dict, ticket_id: str, *, stage: str = "validating"
) -> None:
    """Refuse to act on a manifest the ticket no longer carries.

    The batch is planned from the snapshot the scan read. If the description
    changed since then, the rows are stale: applying them edits credits for a
    request that has been withdrawn or rewritten, and the outcome tag would
    then describe the OLD request on a ticket that now asks for something else.
    A failed re-read is an outage, not a verdict, so it is `Unavailable` (the
    ticket stays untagged and the next run retries) rather than a stop.

    Called twice, because the window is open at both ends: before the first
    write (nothing has happened yet) and before the outcome tag (rows may have
    landed, and the ledger is the record of them). `stage` only shapes the
    message.
    """
    try:
        fresh = read_task(client, ticket_id)
    except RuntimeError as exc:
        raise Unavailable(
            f"could not re-read {ticket_id} before writing ({exc}), so the ticket "
            "is left untagged for re-verification"
        ) from None
    if ticket_fingerprint(fresh) != ticket_fingerprint(snapshot):
        raise TicketChanged(
            f"{ticket_id} changed while this run was {stage} it — the manifest it "
            "was selected with is no longer the request on the ticket, so no "
            "outcome was tagged; any rows that landed are in the ledger"
        )


class TicketChanged(RuntimeError):
    """The ticket's request changed between selection and the outcome tag.

    The manifest this run validated is no longer what the ticket asks for, so
    applying it would edit credits nobody asked for and then label the NEW
    request with the OLD outcome. The run stops untagged and the next run works
    from what the ticket says now. Raised before the first write (nothing has
    happened) and again before the tag (rows may have landed; the ledger is the
    record of them, and a human reconciles the ticket).
    """


class OutcomeConflict(RuntimeError):
    """Someone else recorded a customer-outcome while this run was working.

    Not a failure of the batch: the rows may all have landed. It means the
    ticket is no longer ours to label, so the run leaves it exactly as the human
    left it and reports the conflict instead of tagging.
    """


def replace_customer_outcome(
    client: ClickUp,
    task_id: str,
    outcome: str,
    *,
    expected_existing: frozenset[str] | set[str] = frozenset(),
    allow_replace: bool = False,
    path: WritePath | None = None,
    run_id: str = "",
    operator: str = "",
    expected_fingerprint: str | None = None,
) -> None:
    """Set exactly one customer-outcome tag and prove it by re-reading.

    Never touches the workflow status: the reconciler owns that, and a drainer
    that closes its own tickets destroys the SLA digest that is supposed to
    surface the partials.

    `expected_existing` is the outcome tags the run SAW when it selected the
    ticket. A tag that appeared since then was set by a human while the batch
    was running, and replacing it would overwrite a live decision — the
    reconciler would then read our `complete` and announce a case a person had
    deliberately held. So an unexpected tag is a conflict, not something to
    delete. `allow_replace` is the audited `--allow-tagged --operator` escape
    hatch, where a named human owns the transition — and "audited" is literal:
    the override is written to the ledger BEFORE the tag is touched, naming the
    operator, the ticket and EVERY outcome tag it replaces. An override nobody
    can attribute afterwards is the same as no override at all.

    The audit covers both shapes of override, because they are the same act: a
    tag that appeared while the run was working (`foreign`) and a tag that was
    already on the ticket when `--ticket` selected it. Keying the audit on
    `foreign` alone would leave the second — the ordinary `--allow-tagged`
    case — replacing a human's hold with no record of who authorized it.

    The tag swap is ADD-then-REMOVE, never the reverse: a failed add must leave
    the previous outcome in place, and a failed remove must leave the ticket
    ambiguous (two tags, which `customer_outcome_of` reports as None so every
    consumer fails closed) rather than tagless. A tagless ticket is re-pickable
    by the next scan and the human's decision is simply gone.
    """
    desired = outcome_tag(outcome)
    current = read_task(client, task_id)
    # This read is the LAST one before the tag, and it is the only place that
    # sees the ticket as it is at tag time. Checking outcome tags alone is not
    # enough: support can rewrite the manifest between the pre-tag check and
    # here, and tagging `complete` would then answer the OLD request on a ticket
    # that now asks for something else — the next scan skips it and the
    # reconciler closes and notifies on work we never did.
    if expected_fingerprint is not None:
        fresh = ticket_fingerprint(current)
        if fresh != expected_fingerprint:
            raise TicketChanged(
                f"{task_id} changed between the pre-tag check and the tag itself "
                f"(fingerprint {expected_fingerprint} -> {fresh}) — no outcome was "
                "tagged; any rows that landed are in the ledger"
            )
    existing = outcome_tags_of(current)
    foreign = existing - set(expected_existing) - {desired}
    if foreign and not allow_replace:
        raise OutcomeConflict(
            f"{task_id} gained {', '.join(sorted(foreign))} while this run was "
            f"working; refusing to replace it with {desired} (a human decision "
            "outranks this drainer — re-run with --allow-tagged --operator <email> "
            "if that decision is yours to overwrite)"
        )
    replaced = existing - {desired}
    if allow_replace and replaced:
        if path is None:
            # An override with nowhere to record it is exactly the unaudited
            # replacement this guard exists to prevent. Refuse rather than
            # perform it quietly.
            raise RuntimeError(
                f"refusing to override {task_id}'s outcome without a ledger to "
                "record it in"
            )
        path.record({
            "run_id": run_id,
            "ticket_id": task_id,
            "phase": "override",
            "operator": operator,
            "previous_outcomes": sorted(replaced),
            "outcome": desired,
        })
    # ADD FIRST, REMOVE SECOND. The ticket must never be left with no outcome
    # tag: if the add fails, the human's hold is still there and nothing changed;
    # if a remove fails, the ticket carries two tags and `customer_outcome_of`
    # reports None, which every consumer treats as "not decided" (fail closed)
    # rather than as a close. Deleting first would let a failed add erase a live
    # decision, and the ledger cannot put a human's hold back on the ticket.
    if desired not in existing:
        status, body = _cu(client, "POST",
                           f"/task/{task_id}/tag/{urllib.parse.quote(desired, safe='')}")
        if status not in (200, 201):
            raise RuntimeError(f"clickup add outcome tag {task_id} -> {status}: {body}")
        if desired not in outcome_tags_of(read_task(client, task_id)):
            raise RuntimeError(
                f"customer-outcome add read-back failed on {task_id}: {desired} is "
                "not on the ticket (the previous outcome was left in place)"
            )
    for tag in sorted(replaced):
        status, body = _cu(client, "DELETE",
                           f"/task/{task_id}/tag/{urllib.parse.quote(tag, safe='')}")
        if status not in (200, 204):
            raise RuntimeError(f"clickup remove outcome tag {task_id} -> {status}: {body}")
    after = customer_outcome_of(read_task(client, task_id))
    if after != outcome:
        raise RuntimeError(
            f"customer-outcome read-back failed on {task_id}: wanted {outcome}, saw {after}"
        )


# --------------------------------------------------------------------------
# Row validation (no writes)
# --------------------------------------------------------------------------
@dataclass
class RowFindings:
    """What validation learned about one row. Doubles as the ledger pre-image."""

    row: mf.Row
    before_roles: list[str] = field(default_factory=list)
    satisfied: bool = False
    invalid: str | None = None

    def describe(self) -> dict:
        return {
            "track_id": self.row.track_id,
            "profile_id": self.row.profile_id,
            "role": self.row.role,
            "before_roles": list(self.before_roles),
            "satisfied": self.satisfied,
        }


def validate_batch(
    admin: CreditAdmin, parsed: mf.Manifest, sleep=time.sleep,
) -> tuple[list[RowFindings], str | None]:
    """Validate every row. Returns (findings, refusal).

    A refusal is a human-readable single line; when it is set the caller writes
    `customer-outcome:blocked` and NO write has happened. All-or-nothing is the
    point: a batch half-applied against a mistyped row is worse than a refused
    batch, because nothing downstream can tell which rows were intended.
    """
    ticket_profile = parsed.customer_profile_id
    findings: list[RowFindings] = []

    # Identity guard first: the manifest may not spread across profiles. The
    # manifest parser already guarantees ticket_profile is present.
    foreign = sorted({r.profile_id for r in parsed.rows if r.profile_id != ticket_profile})
    if foreign:
        return [], (
            f"manifest targets profile(s) {', '.join(foreign)} but the ticket "
            f"belongs to {ticket_profile} — refuse rather than edit another account"
        )

    tracks_checked: dict[str, str] = {}
    profiles_cache: dict[str, dict[str, list[str]]] = {}

    for row in parsed.rows:
        finding = RowFindings(row=row)

        # The profile's credit list FIRST: it is what decides whether this drainer
        # has anything to edit, and it is the evidence that settles a track read.
        if row.profile_id not in profiles_cache:
            ok, why = profile_status(admin, row.profile_id, sleep=sleep)
            if not ok:
                finding.invalid = why
                findings.append(finding)
                continue
            try:
                profiles_cache[row.profile_id] = profile_credit_roles(admin, row.profile_id)
            except NotFound as exc:
                # `profile_status` just read this profile successfully, so a 404
                # on its credits is an inconsistent API, not proof the request is
                # wrong. Recording it as an invalid row would tag the ticket
                # `blocked` and no later run would ever retry a valid request.
                raise Unavailable(
                    f"profile {row.profile_id} read fine but its credits returned "
                    f"404 ({exc}) — inconsistent admin state, retrying later"
                ) from exc
            except AdminError as exc:
                # A malformed credit list during a backend incident is not a bad
                # row: treat it as unreadable state so the ticket is retried.
                raise Unavailable(
                    f"credits for profile {row.profile_id} are not readable: {exc}"
                ) from exc
        credits = profiles_cache[row.profile_id]

        if row.track_id not in credits:
            finding.invalid = (
                "profile holds no credit on this track — this drainer edits an "
                "existing credit, a new one is a claim"
            )
            findings.append(finding)
            continue

        # The track read only matters once the profile says a credit is there. If
        # the two reads disagree, that is an inconsistent API, not a bad row:
        # retry later instead of writing a verdict nobody can undo.
        if row.track_id not in tracks_checked:
            ok, why = track_exists(admin, row.track_id, sleep=sleep)
            tracks_checked[row.track_id] = "" if ok else why
        if tracks_checked[row.track_id]:
            # The credit list above already proved this track is REFERENCED by the
            # profile, so a confirmed 404 from /admin/track cannot mean "no such
            # track" — that route answers 404 when its own catalog read fails.
            # Parking the ticket on that would be a verdict from an outage.
            raise Unavailable(
                f"track {row.track_id}: {tracks_checked[row.track_id]}, but profile "
                f"{row.profile_id} holds a credit on it — the two reads disagree, so "
                "this is not a verdict about the row"
            )

        finding.before_roles = list(credits[row.track_id])
        finding.satisfied = any(mf.same_role(r, row.role) for r in finding.before_roles)
        findings.append(finding)

    bad = [f for f in findings if f.invalid]
    if bad:
        named = "; ".join(
            f"{f.row.track_id}/{f.row.profile_id} role {f.row.role}: {f.invalid}" for f in bad[:5]
        )
        more = "" if len(bad) <= 5 else f" (+{len(bad) - 5} more)"
        return findings, f"{len(bad)} of {len(findings)} rows failed validation: {named}{more}"
    return findings, None


# --------------------------------------------------------------------------
# Application (writes, sequential)
# --------------------------------------------------------------------------
@dataclass
class RowResult:
    finding: RowFindings
    action: str          # already | add | none
    outcome: str         # verified | failed | refused | skipped
    detail: str = ""
    after_roles: list[str] = field(default_factory=list)


def apply_batch(
    admin: CreditAdmin,
    path: WritePath,
    *,
    run_id: str,
    ticket_id: str,
    findings: list[RowFindings],
    sleep=time.sleep,
    results: list[RowResult] | None = None,
    attempted: list[RowFindings] | None = None,
) -> tuple[list[RowResult], bool]:
    """Apply the rows in order. Returns (results, stopped_early).

    Three properties this loop is built around, all of them learned the hard way:

    1. **Ledger intent BEFORE the request.** A row that says "we are about to add
       this, pre-image was X" is written first, so a crash, a disk error or a
       read-back outage cannot leave a credit changed with no trace. The result
       row follows the POST.
    2. **Compare-and-set against the last observation, not the first.** Two rows
       may target the same credit with different roles (both are legitimate
       adds); after the first add lands, the second row's expected pre-image is
       advanced, or the CAS would refuse our own write.
    3. **"We could not read" is not a result.** An `Unavailable` read-back escapes
       rather than being recorded as `failed`, so the ticket keeps no tag and the
       next run re-verifies (the role is already there ⇒ `already` ⇒ complete).
    4. **`already` is re-read, never remembered.** `satisfied` came from a
       validation read that may be minutes old; a human can remove the role before
       the loop reaches the row. Calling that "already done" would tag a ticket
       complete while the requested role is absent, so every satisfied row is
       re-read and a vanished role stops the batch.
    5. **An uncertain POST is not a failure.** 408/425/429/5xx mean the write may
       have landed. Recording `failed` would `partial`-tag a ticket whose credit
       may be exactly right, and later runs skip it — so those escape as
       `Unavailable` with the uncertain outcome in the ledger.
    """
    # The caller may pass its own list so that a batch which dies mid-flight
    # still reports what it posted: an exception here is exactly when the
    # post-write ticket check matters most, and it cannot see rows it was never
    # handed.
    if results is None:
        results = []
    if attempted is None:
        attempted = []
    for index, finding in enumerate(findings):
        row = finding.row
        if finding.satisfied:
            # Re-read: the validation read can be minutes old, and "already done"
            # is a completion claim. A role a human removed meanwhile is not ours
            # to call satisfied.
            try:
                live = profile_credit_roles(admin, row.profile_id).get(row.track_id, [])
            except (AdminError, NotFound, Unavailable) as exc:
                raise Unavailable(
                    f"could not re-read profile {row.profile_id} track {row.track_id} "
                    f"to confirm an already-satisfied row: {exc}"
                ) from exc
            if not any(mf.same_role(r, row.role) for r in live):
                results.append(RowResult(
                    finding, "none", "failed",
                    detail=f"role {row.role} was present at validation and is gone now "
                           f"({live}) — a concurrent edit removed it, so this row is "
                           "not complete",
                    after_roles=list(live),
                ))
                path.record({"run_id": run_id, "ticket_id": ticket_id, "action": "none",
                             "phase": "result", "outcome": "failed",
                             "detail": "satisfied role vanished before application",
                             **finding.describe(), "after_roles": list(live),
                             "index": index})
                return results, True
            results.append(RowResult(finding, "already", "verified",
                                     after_roles=list(live)))
            path.record({
                "run_id": run_id, "ticket_id": ticket_id, "action": "already",
                "phase": "result", "outcome": "verified", **finding.describe(),
                "after_roles": list(live), "index": index,
            })
            for later in findings[index + 1:]:
                if (later.row.track_id, later.row.profile_id) == (row.track_id,
                                                                 row.profile_id):
                    later.before_roles = list(live)
                    later.satisfied = later.satisfied or any(
                        mf.same_role(r, later.row.role) for r in live
                    )
            continue

        # Compare-and-set: the pre-image we last observed must still be what is
        # there. A human editing the same credit meanwhile wins.
        try:
            live = profile_credit_roles(admin, row.profile_id).get(row.track_id, [])
        except (AdminError, NotFound, Unavailable) as exc:
            # We could not read the pre-image at all. Whatever we already wrote is
            # in the ledger, but the rest of the batch cannot be judged, and a
            # `partial` tag from an unreadable state is a verdict we did not earn.
            results.append(RowResult(finding, "none", "unverified",
                                     detail=f"pre-write read failed: {exc}"))
            path.record({"run_id": run_id, "ticket_id": ticket_id, "action": "none",
                         "phase": "result", "outcome": "unverified",
                         "detail": str(exc), **finding.describe(), "index": index})
            raise Unavailable(f"pre-write read failed: {exc}") from exc
        if sorted(live) != sorted(finding.before_roles):
            results.append(RowResult(
                finding, "none", "failed",
                detail=f"role set changed since validation (was {finding.before_roles}, "
                       f"now {live}) — refusing to write over a concurrent edit",
                after_roles=live,
            ))
            path.record({"run_id": run_id, "ticket_id": ticket_id, "action": "none",
                         "phase": "result", "outcome": "failed",
                         "detail": "compare-and-set mismatch",
                         **finding.describe(), "after_roles": live, "index": index})
            return results, True

        try:
            path.reserve_write()
        except DailyCapReached as exc:
            # Running out of shared budget is a DEFERRAL, not a fact about this
            # batch. Recording a refusal here would `partial`-tag a ticket that
            # was never written and is never retried, so the run stops with the
            # ticket untagged; whatever already landed stays in the ledger, and
            # tomorrow's run resumes the rows that are still missing.
            results.append(RowResult(finding, "none", "deferred", detail=str(exc)))
            path.record({
                "run_id": run_id, "ticket_id": ticket_id, "action": "none",
                "phase": "result", "outcome": "deferred", "detail": str(exc),
                **finding.describe(), "index": index,
            })
            raise

        # Intent first: if anything below dies, the ledger still says we wrote.
        path.record({
            "run_id": run_id, "ticket_id": ticket_id, "action": "add",
            "phase": "intent", "outcome": "attempted", **finding.describe(),
            "index": index,
        })

        # Recorded BEFORE the request: a POST that raises may still have landed,
        # and the caller needs to know a write was attempted to decide whether a
        # rewritten ticket has to be parked for a human.
        attempted.append(finding)
        try:
            env = add_role(admin, row.track_id, row.profile_id, row.role)
        except AdminError as exc:
            results.append(RowResult(finding, "add", "failed", detail=str(exc)))
            path.record({"run_id": run_id, "ticket_id": ticket_id, "action": "add",
                         "phase": "result", "outcome": "failed", "detail": str(exc),
                         **finding.describe(), "index": index})
            return results, True
        if not env.ok and is_unanswerable_status(env.status):
            # The admin could not answer: a blip (the write may or may not have
            # landed) or our own credentials being rejected (nothing landed).
            # Either way calling it `failed` would `partial`-tag a ticket whose
            # credit may be exactly right, and a tagged ticket is never looked at
            # again — so the ticket stays untagged and the next run re-verifies.
            if is_transient_status(env.status):
                why = (f"admin answered HTTP {env.status} — the write may or may "
                       "not have landed")
            else:
                why = (f"admin refused the write with HTTP {env.status} — our "
                       "credentials could not answer, so nothing was written")
            results.append(RowResult(
                finding, "add", "unverified", detail=why,
                after_roles=list(finding.before_roles),
            ))
            path.record({"run_id": run_id, "ticket_id": ticket_id, "action": "add",
                         "phase": "result", "outcome": "unverified",
                         "detail": why, "http_status": env.status,
                         **finding.describe(), "index": index})
            raise Unavailable(
                f"POST for {row.track_id}/{row.profile_id} answered HTTP {env.status} "
                f"({why}), so the ticket is left untagged for re-verification"
            )
        if not env.ok:
            results.append(RowResult(finding, "add", "failed",
                                     detail=f"admin answered HTTP {env.status}",
                                     after_roles=list(finding.before_roles)))
            path.record({"run_id": run_id, "ticket_id": ticket_id, "action": "add",
                         "phase": "result", "outcome": "failed",
                         "http_status": env.status, **finding.describe(), "index": index})
            return results, True

        try:
            seen = wait_for_role(admin, row.profile_id, row.track_id, row.role,
                                 attempts=READBACK_ATTEMPTS, sleep=sleep)
        except Unavailable as exc:
            results.append(RowResult(finding, "add", "unverified",
                                     detail=f"read-back unavailable: {exc}",
                                     after_roles=list(finding.before_roles)))
            path.record({
                "run_id": run_id, "ticket_id": ticket_id, "action": "add",
                "phase": "result", "outcome": "unverified", "detail": str(exc),
                "http_status": env.status, **finding.describe(), "index": index,
            })
            raise
        verified = bool(seen) and any(mf.same_role(r, row.role) for r in seen or [])
        results.append(RowResult(
            finding, "add", "verified" if verified else "failed",
            detail="" if verified else "role did not appear on read-back",
            after_roles=list(seen or []),
        ))
        path.record({
            "run_id": run_id, "ticket_id": ticket_id, "action": "add",
            "phase": "result", "outcome": "verified" if verified else "failed",
            "http_status": env.status, **finding.describe(),
            "after_roles": list(seen or []), "index": index,
        })
        if not verified:
            return results, True

        # Advance the expected pre-image for any later row on the same credit:
        # its CAS compares against what WE last observed, which now includes
        # this role.
        for later in findings[index + 1:]:
            if (later.row.track_id, later.row.profile_id) == (row.track_id, row.profile_id):
                later.before_roles = list(seen or [])
                later.satisfied = later.satisfied or any(
                    mf.same_role(r, later.row.role) for r in later.before_roles
                )

    return results, False


# --------------------------------------------------------------------------
# One ticket
# --------------------------------------------------------------------------
@dataclass
class TicketOutcome:
    ticket_id: str
    bucket: str                     # complete | partial | blocked | unparseable | …
    rows_requested: int = 0
    rows_verified: int = 0
    rows_written: int = 0
    detail: str = ""
    dry_run: bool = True

    def summary_line(self) -> str:
        return (
            f"{self.ticket_id}\t{self.bucket}\t"
            f"{self.rows_verified}/{self.rows_requested} verified\t"
            f"{self.rows_written} written"
            + (f"\t{self.detail}" if self.detail else "")
        )


def internal_comment(bucket: str, findings: list[RowFindings],
                     results: list[RowResult], detail: str) -> str:
    """Internal evidence only — never customer copy, never a row count to send.

    EVERY requested row appears exactly once: landed rows as verified, failed
    rows with their reason, and rows the batch never reached marked
    `not attempted`. A comment that silently omits the tail of the manifest is
    worse than no comment — the human reads it as the whole story.
    """
    def key(row: mf.Row) -> tuple[str, str, str]:
        return (row.track_id, row.profile_id, row.role.casefold())

    seen_results = {key(r.finding.row): r for r in results}
    lines = [
        f"**bulk-credit-change drain: {bucket}** (internal evidence, do not paste to the customer)",
    ]

    landed = [r for r in results if r.outcome == "verified"]
    if landed:
        lines.append(f"verified {len(landed)} row(s):")
        lines.extend(
            f"- {r.finding.row.track_id} · {r.finding.row.role} · "
            f"{'already held' if r.action == 'already' else 'added'}"
            for r in landed
        )

    missing: list[str] = []
    for finding in findings:
        row = finding.row
        result = seen_results.get(key(row))
        if result is None:
            missing.append(
                f"- {row.track_id} · {row.role} · not attempted (the batch stopped at an "
                "earlier row)"
            )
        elif result.outcome != "verified":
            missing.append(
                f"- {row.track_id} · {row.role} · {result.outcome}"
                + (f": {result.detail}" if result.detail else "")
            )
    if missing:
        lines.append(f"did NOT land {len(missing)} row(s) of {len(findings)}:")
        lines.extend(missing)

    if detail:
        lines.append(f"reason: {detail}")
    lines.append("No customer message is sent from this drainer.")
    return "\n".join(lines)


def hold_if_rewritten(
    client: ClickUp,
    ticket: dict,
    ticket_id: str,
    results: list[RowResult],
    holds_path: str | None,
    run_id: str,
    attempted: list[RowFindings] | None = None,
) -> TicketChanged | Unavailable | None:
    """Park the ticket if it was rewritten after we wrote to it.

    Called on BOTH exits from the batch: the normal one and the one where
    `apply_batch` raised. A batch that dies mid-flight (an outage, the daily cap,
    a kill file) can still have posted rows, and the ticket can have been
    rewritten while it ran — so the failure path needs the same check, or the
    next run applies the NEW manifest and tags `complete` over the old credit.

    A `TicketChanged` before any write is self-healing and records nothing.

    A re-read that FAILS is not self-healing either, once we have written. We
    cannot tell "the ticket is unchanged, ClickUp just blipped" from "support
    rewrote it while we were writing", and the two have opposite safe answers:
    retrying is right for the first and closes over an unintended credit for the
    second. So an unreadable post-write check parks the ticket too — the cost is
    a human clearing a hold that may not have been needed, against silently
    closing a ticket whose old credit is still on the profile.

    Returns the exception rather than raising it, so the caller decides: on the
    failure path the ORIGINAL exception is the one worth reporting (an outage is
    retryable, and replacing it with `changed` would hide why the batch
    stopped), while on the success path there is nothing else to raise.
    """
    try:
        ensure_ticket_unchanged(client, ticket, ticket_id, stage="applying")
    except (TicketChanged, Unavailable) as exc:
        posted = [r for r in results if r.action == "add"]
        rows = [{**r.finding.describe(), "outcome": r.outcome,
                 "after_roles": r.after_roles} for r in posted]
        if not rows and attempted:
            # A POST that raised may still have landed, so an attempted write is
            # enough to need a human — we cannot claim the profile is untouched.
            rows = [{**f.describe(), "outcome": "unverified",
                     "after_roles": list(f.before_roles)} for f in attempted]
        if rows and holds_path:
            record_hold(holds_path, ticket_id, run_id=run_id, reason=str(exc),
                        rows=rows)
        return exc
    return None


def run_ticket(
    admin: CreditAdmin,
    client: ClickUp,
    path: WritePath,
    *,
    ticket: dict,
    run_id: str,
    dry_run: bool,
    allow_replace: bool = False,
    operator: str = "",
    holds_path: str | None = None,
    sleep=time.sleep,
) -> TicketOutcome:
    ticket_id = str(ticket.get("id"))
    # What the scan saw. Any outcome tag that is not in here appeared while this
    # run was working, i.e. a human touched the ticket, and it is not ours to
    # overwrite (see `replace_customer_outcome`).
    seen_outcomes = frozenset(outcome_tags_of(ticket))
    try:
        parsed = mf.parse_manifest(task_text(ticket))
    except mf.ManifestError as exc:
        # `unparseable` and friends write NO tag on purpose: the ticket stays
        # waiting-on-us for the reconciler and surfaces in the SLA digest. A
        # removal request IS answered (`blocked`), because it is a real request
        # we are declining rather than an intake defect.
        bucket = (
            OUTCOME_BLOCKED if exc.reason in mf.REASONS_THAT_TAG_BLOCKED else exc.reason
        )
        detail = exc.detail if bucket != OUTCOME_BLOCKED else f"{exc.reason}: {exc.detail}"
        outcome = TicketOutcome(ticket_id, bucket, detail=detail, dry_run=dry_run)
        if bucket == OUTCOME_BLOCKED and not dry_run:
            # The refusal is about the request we READ. If support rewrote the
            # ticket since the scan — a removal request turned into a valid add
            # request — tagging `blocked` would answer a request nobody made and
            # the next scan would skip the real one forever.
            ensure_ticket_unchanged(client, ticket, ticket_id)
            # comment FIRST: a tagged ticket is skipped by later runs, so a tag
            # whose explanation never posted can never be explained
            post_comment(client, ticket_id,
                         internal_comment(OUTCOME_BLOCKED, [], [], detail))
            replace_customer_outcome(client, ticket_id, OUTCOME_BLOCKED,
                                     expected_existing=seen_outcomes,
                                     allow_replace=allow_replace,
                                     path=path, run_id=run_id, operator=operator,
                                     expected_fingerprint=ticket_fingerprint(ticket))
        return outcome

    findings, refusal = validate_batch(admin, parsed, sleep=sleep)
    if not dry_run:
        # The LAST read before the FIRST write is the ticket itself. Validation
        # takes real time (admin reads per row), and support can edit a ticket
        # while it runs: track A/Producer becomes track B/Mastering, and the
        # rows we just validated are a request nobody is making any more.
        ensure_ticket_unchanged(client, ticket, ticket_id)
    if refusal is not None:
        outcome = TicketOutcome(
            ticket_id, OUTCOME_BLOCKED,
            rows_requested=len(parsed.rows), detail=refusal, dry_run=dry_run,
        )
        if not dry_run:
            post_comment(client, ticket_id,
                         internal_comment(OUTCOME_BLOCKED, [], [], refusal))
            replace_customer_outcome(client, ticket_id, OUTCOME_BLOCKED,
                                     expected_existing=seen_outcomes,
                                     allow_replace=allow_replace,
                                     path=path, run_id=run_id, operator=operator,
                                     expected_fingerprint=ticket_fingerprint(ticket))
        return outcome

    results: list[RowResult] = []
    attempted: list[RowFindings] = []
    stopped = False
    if dry_run:
        results = [
            RowResult(f, "already" if f.satisfied else "add",
                      "verified" if f.satisfied else "would-write",
                      after_roles=list(f.before_roles))
            for f in findings
        ]
    else:
        try:
            results, stopped = apply_batch(
                admin, path, run_id=run_id, ticket_id=ticket_id,
                findings=findings, sleep=sleep, results=results,
                attempted=attempted,
            )
        except Exception:
            # The batch died part-way. Rows may have landed, and the ticket may
            # have been rewritten while it ran, so the post-write check has to
            # run here too — this is the path where a hold is most likely to be
            # needed and least likely to be reached.
            hold_if_rewritten(client, ticket, ticket_id, results, holds_path,
                              run_id, attempted)
            raise

    verified = [r for r in results if r.outcome == "verified"]
    written = [r for r in results if r.action == "add" and r.outcome == "verified"]
    pending = [r for r in results if r.action == "add"]

    if dry_run:
        # Nothing was attempted, so a bucket of `partial` here would be a lie
        # that makes every shadow run look broken. Say what WOULD happen.
        bucket = OUTCOME_COMPLETE if not pending else "would-complete"
        detail = ""
        if pending:
            detail = f"{len(pending)} row(s) would be written"
        return TicketOutcome(
            ticket_id, bucket,
            rows_requested=len(findings),
            rows_verified=len(verified),
            rows_written=0,
            detail=detail,
            dry_run=True,
        )

    everything = len(verified) == len(findings)
    bucket = OUTCOME_COMPLETE if everything else OUTCOME_PARTIAL
    detail = ""
    if not everything:
        detail = (
            f"{len(findings) - len(verified)} row(s) did not verify"
            + ("; batch stopped at the first failing row" if stopped else "")
        )

    if not dry_run:
        # The last read before the OUTCOME TAG is the ticket again. A batch takes
        # real time (a POST plus a read-back per row), and support can rewrite the
        # manifest in that window: the rows we just applied are then the OLD
        # request, and tagging `complete` would let the reconciler close and
        # notify on a request we never executed.
        # Writes may have landed, so leaving a rewritten ticket merely untagged
        # is not enough: the next run would apply the NEW manifest and tag
        # `complete` while the old credit is still on the profile. Park it.
        changed = hold_if_rewritten(
            client, ticket, ticket_id, results, holds_path, run_id, attempted
        )
        if changed is not None:
            raise changed

    try:
        if not everything:
            # evidence before the tag: once the tag lands the ticket is skipped,
            # so an unposted comment would leave a `partial` nobody can account
            # for
            post_comment(client, ticket_id,
                         internal_comment(bucket, findings, results, detail))
        replace_customer_outcome(client, ticket_id, bucket,
                                 expected_existing=seen_outcomes,
                                 allow_replace=allow_replace,
                                 path=path, run_id=run_id, operator=operator,
                                 expected_fingerprint=ticket_fingerprint(ticket))
    except TicketChanged:
        # The rewrite landed between the pre-tag check and the tag's own read.
        # Rows may have been written, so this is the same hold as any other
        # post-write rewrite: the next run must not apply the new manifest and
        # close over the old credit.
        hold_if_rewritten(client, ticket, ticket_id, results, holds_path,
                          run_id, attempted)
        raise

    return TicketOutcome(
        ticket_id, bucket,
        rows_requested=len(findings),
        rows_verified=len(verified),
        rows_written=len(written),
        detail=detail,
        dry_run=dry_run,
    )


# --------------------------------------------------------------------------
# Attempts state (keeps unparseable tickets from eating every run's 3 slots)
# --------------------------------------------------------------------------
def load_attempts(state_path: str) -> dict:
    try:
        with open(state_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def ticket_fingerprint(ticket: dict) -> str:
    """A short digest of the ticket text this run actually read.

    `attempts` exists so an unparseable ticket does not eat a slot on every run.
    But a ticket is not frozen: support can add the `details.bulk_rows` manifest
    to a ticket that was prose-only this morning, and a permanent skip would
    leave a now-executable ticket open and untagged forever. So the skip is
    keyed on the TEXT, not just the id: same text, same verdict, no re-try;
    changed text, one fresh attempt.
    """
    return hashlib.sha256(task_text(ticket).encode("utf-8")).hexdigest()[:16]


def already_tried_this_text(attempts: dict, ticket: dict) -> bool:
    """True only when this exact ticket text was already tried.

    An entry with no fingerprint predates this check, so it is re-tried once and
    re-recorded with one — the alternative is trusting a verdict we cannot tie
    to the text it was made about.
    """
    entry = attempts.get(str(ticket.get("id")))
    if not isinstance(entry, dict):
        return False
    return entry.get("fingerprint") == ticket_fingerprint(ticket)


def load_holds(state_path: str) -> dict:
    """Read the manual-reconciliation holds.

    Only an ABSENT file means "no holds". A file that exists but cannot be read
    or parsed is a hold set we cannot see, and reading it as empty would release
    every parked ticket at once: the next run would apply the replacement
    manifest and tag `complete` while the old credit is still on the profile.
    That is the same fail-closed rule as the write budget, for the same reason —
    unreadable state is not evidence of a clean state.
    """
    try:
        with open(state_path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return {}
    except (OSError, json.JSONDecodeError) as exc:
        raise DrainBlocked(
            f"hold state {state_path} exists but cannot be read ({exc}) — refusing "
            "to treat unreadable holds as no holds, because that would release "
            "every ticket parked for manual reconciliation"
        ) from exc
    if not isinstance(data, dict):
        raise DrainBlocked(
            f"hold state {state_path} is not a JSON object (got {type(data).__name__}) "
            "— refusing to treat unreadable holds as no holds"
        )
    return data


def save_holds(state_path: str, holds: dict) -> None:
    Path(state_path).parent.mkdir(parents=True, exist_ok=True)
    tmp = f"{state_path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(holds, fh, indent=2, sort_keys=True)
    os.replace(tmp, state_path)


def record_hold(state_path: str, ticket_id: str, *, run_id: str, reason: str,
                rows: list[dict]) -> None:
    """Park a ticket for a human because writes landed and the request moved.

    A `TicketChanged` raised BEFORE the first write is self-healing: nothing
    happened, and the next run reads the new text. Raised AFTER a write it is
    not: the old rows are on the customer's profile, and the next run would
    happily apply the NEW manifest and tag `complete` — closing a ticket whose
    unintended credit is still there. So the hold is durable state, not a log
    line, and every later run refuses the ticket until a human clears it.
    """
    holds = load_holds(state_path)
    holds[str(ticket_id)] = {
        "ts": int(time.time()),
        "run_id": run_id,
        "reason": reason[:400],
        "rows": rows,
    }
    save_holds(state_path, holds)


def peek_hold(state_path: str, ticket_id: str) -> dict | None:
    entry = load_holds(state_path).get(str(ticket_id))
    return entry if isinstance(entry, dict) else None


def clear_hold(state_path: str, ticket_id: str) -> dict | None:
    holds = load_holds(state_path)
    entry = holds.pop(str(ticket_id), None)
    if entry is not None:
        save_holds(state_path, holds)
    return entry if isinstance(entry, dict) else None


def save_attempts(state_path: str, attempts: dict) -> None:
    Path(state_path).parent.mkdir(parents=True, exist_ok=True)
    tmp = f"{state_path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(attempts, fh, indent=2, sort_keys=True)
    os.replace(tmp, state_path)


# --------------------------------------------------------------------------
# Revert (human path)
# --------------------------------------------------------------------------
def run_revert(admin: CreditAdmin, ledger_path: str) -> int:
    """PLAN ONLY. Prints the exact removal a human would run, newest first.

    This is not caution, it is what the executor can actually do: the deployed
    `muso-admin-api.sh` refuses every credit-removal DELETE in
    `enforce_removal_gate`, whatever the requester or environment claims, so an
    `--apply` here would be a documented command that always fails at the wrapper
    (or, worse, succeed against a fake and never in production). The plan is the
    useful half: it names the roles and the pre-images, and the human runs the
    approved removal path from their own session.
    """
    rows = plan_revert(ledger_path)
    if not rows:
        print(f"nothing to undo in {ledger_path}")
        return RUN_EXIT_OK

    reversed_rows = list(reversed(rows))
    print(f"WOULD REMOVE {len(reversed_rows)} role(s), newest first, from {ledger_path}")
    for entry in reversed_rows:
        track_id = entry.get("track_id")
        profile_id = entry.get("profile_id")
        role = entry.get("role")
        try:
            current = profile_credit_roles(admin, str(profile_id)).get(str(track_id), [])
        except (AdminError, NotFound, Unavailable) as exc:
            print(f"- {track_id} {role}: cannot read current state ({exc})")
            continue
        if not any(mf.same_role(r, str(role)) for r in current):
            print(f"- {track_id} {role}: already absent, nothing to undo")
            continue
        print(f"- {track_id} profile {profile_id}: remove {role} (currently {current})")

    print(
        "\nPLAN ONLY — this helper never removes a credit. The admin wrapper refuses\n"
        "credit-removal DELETEs for agents (muso-admin-api.sh enforce_removal_gate),\n"
        "so hand this list to a named human, who runs it from their own session via\n"
        "skills-all/muso-ops-tracks (Removal Requests)."
    )
    return RUN_EXIT_OK


def render_report(outcomes: list[TicketOutcome], *, scanned: int, candidates: int,
                  unparseable_total: int, kills: str | None, dry_run: bool, writes: int,
                  remaining: int, held: int = 0) -> str:
    buckets: dict[str, int] = {}
    for o in outcomes:
        buckets[o.bucket] = buckets.get(o.bucket, 0) + 1
    head = "DRY RUN — nothing was written" if dry_run else "APPLIED"
    lines = [
        f"bulk-credit-change drain: {head}",
        f"open tickets scanned: {scanned}",
        f"eligible (no outcome tag, not yet attempted): {candidates}",
        f"tickets taken this run: {len(outcomes)}"
        + (f" of {candidates} (cap {MAX_TICKETS_PER_RUN}/run)" if candidates else ""),
        f"manifest hit rate: {scanned - unparseable_total}/{scanned} parseable"
        + (f" ({unparseable_total} refused as unparseable)" if unparseable_total else ""),
        f"credit writes this run: {writes}; remaining today: {remaining}",
    ]
    if held:
        lines.append(
            f"held for manual reconciliation: {held} (writes landed, then the "
            "ticket was rewritten — clear with --clear-hold <id> --operator <email>)"
        )
    if kills:
        lines.append(f"STOPPED: {kills}")
    if buckets:
        lines.append("outcomes: " + ", ".join(f"{k}={v}" for k, v in sorted(buckets.items())))
    for o in outcomes:
        lines.append("  " + o.summary_line())
    return "\n".join(lines)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Drain action:bulk-credit-change tickets.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--apply", action="store_true",
                   help="write for real (default: dry run, nothing is written)")
    p.add_argument("--ticket", action="append", default=[],
                   help="only this ClickUp ticket id (repeatable)")
    p.add_argument("--max-tickets", type=int, default=MAX_TICKETS_PER_RUN,
                   help=f"tickets per run (hard cap {MAX_TICKETS_PER_RUN})")
    p.add_argument("--list-id", default=os.environ.get("CLICKUP_LIST_ID", DEFAULT_LIST_ID))
    p.add_argument("--limit", type=int, default=0,
                   help="dry-run only: scan at most this many open tickets (0 = all)")
    p.add_argument("--revert", metavar="LEDGER", default="",
                   help="plan (or with --apply, execute) the undo of a ledger")
    p.add_argument("--allow-tagged", action="store_true",
                   help="with --ticket: re-run a ticket that already carries a "
                        "customer-outcome tag (overwrites a recorded decision; "
                        "requires --operator)")
    p.add_argument("--operator", default="",
                   help="with --allow-tagged: the email of the human whose decision "
                        "this run is overwriting (recorded in the ledger)")
    p.add_argument("--clear-hold", action="append", default=[], metavar="TICKET_ID",
                   help="release a manual-reconciliation hold (repeatable; requires "
                        "--operator). The ticket is then eligible again on the next run")
    p.add_argument("--json", action="store_true", help="machine-readable summary")
    p.add_argument("--state-dir", default=STATE_DIR)
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    dry_run = not args.apply
    run_id = f"bulk-{int(time.time())}-{uuid.uuid4().hex[:8]}"
    attempts_path = os.path.join(args.state_dir, "attempts.json")
    holds_path = os.path.join(args.state_dir, "holds.json")

    admin = CreditAdmin(requester=os.environ.get("CLICKUP_DRAIN_REQUESTER")
                        or "clickup-drain@hydra-ops")

    if args.allow_tagged:
        problem = override_operator_error(args.operator, load_override_operators())
        if problem:
            print(problem, file=sys.stderr)
            return RUN_EXIT_USAGE

    if args.clear_hold:
        # Releasing a hold is a human decision: the ticket was parked because
        # writes landed and the request moved, so somebody has to have looked at
        # the profile. The operator is recorded in the ledger, not just printed.
        # The SAME reviewed allowlist as --allow-tagged, not just an email shape.
        # Releasing a hold hands the ticket back to the next armed run, which will
        # apply the replacement manifest — so it is the same act as overriding a
        # human's outcome tag, and `invented@example.com` is a well-formed address.
        problem = override_operator_error(args.operator, load_override_operators())
        if problem:
            print(f"--clear-hold releases a manual-reconciliation hold, so it "
                  f"requires an authorized operator: {problem}", file=sys.stderr)
            return RUN_EXIT_USAGE
        # dry_run=False on purpose: releasing a hold writes no credit, so the
        # audit row must land even in a dry run — it records a human's decision,
        # not a write this tool performed.
        path = WritePath(dry_run=False,
                         ledger_path=os.path.join(args.state_dir, "ledger.jsonl"))
        for ticket_id in args.clear_hold:
            entry = peek_hold(holds_path, ticket_id)
            if entry is None:
                print(f"{ticket_id}: no hold recorded", file=sys.stderr)
                continue
            # Record the release BEFORE dropping the hold. The other order has a
            # window where the ticket is eligible again and no durable record of
            # who released it exists: a failed ledger write would leave the next
            # run free to apply the replacement manifest with nothing to explain
            # why. An intent row that never got its release is visible; a release
            # that never got its row is not.
            path.record({
                "run_id": run_id, "ticket_id": ticket_id, "action": "none",
                "phase": "hold-cleared", "outcome": "released",
                "operator": args.operator, "held_since": entry.get("ts"),
                "held_run": entry.get("run_id"), "reason": entry.get("reason"),
            })
            clear_hold(holds_path, ticket_id)
            print(f"{ticket_id}: hold released by {args.operator}")
        return RUN_EXIT_OK

    if args.revert:
        if args.apply or args.operator:
            print(
                "--revert is plan-only: an undo is a credit REMOVAL, and the admin "
                "wrapper refuses removals for agents (core #10310). Drop --apply/"
                "--operator and hand the printed plan to a named human.",
                file=sys.stderr,
            )
            return RUN_EXIT_USAGE
        return run_revert(admin, args.revert)

    path = WritePath(dry_run=dry_run, ledger_path=os.path.join(args.state_dir, "ledger.jsonl"))
    kills = path.kill_reason()
    if kills:
        print(render_report([], scanned=0, candidates=0, unparseable_total=0, kills=kills,
                            dry_run=dry_run, writes=0, remaining=0))
        return RUN_EXIT_OK

    try:
        with path:
            return _run(args, admin, path, run_id=run_id, dry_run=dry_run,
                        attempts_path=attempts_path, holds_path=holds_path)
    except DrainBlocked as exc:
        print(render_report([], scanned=0, candidates=0, unparseable_total=0,
                            kills=str(exc), dry_run=dry_run, writes=0, remaining=0))
        return RUN_EXIT_BLOCKED


def _run(args, admin: CreditAdmin, path: WritePath, *, run_id: str, dry_run: bool,
         attempts_path: str, holds_path: str | None = None) -> int:
    client = ClickUp(clickup_token())
    attempts = load_attempts(attempts_path)
    holds = load_holds(holds_path) if holds_path else {}

    scan_cap = args.limit if args.limit > 0 else 0
    tickets = fetch_open_tickets(client, args.list_id, scan_cap)
    held_ids = {str(t.get("id")) for t in tickets if str(t.get("id")) in holds}

    unparseable = 0
    for t in tickets:
        if customer_outcome_of(t) in TERMINAL_OUTCOMES or outcome_tags_of(t):
            continue
        try:
            mf.parse_manifest(task_text(t))
        except mf.ManifestError as exc:
            if exc.reason != mf.REASON_REMOVAL_REFUSED:
                unparseable += 1

    if args.ticket:
        wanted = [t for t in args.ticket if t not in held_ids]
        for ticket_id in args.ticket:
            if ticket_id in held_ids:
                print(
                    f"{ticket_id}: NOT run — it is held for manual reconciliation "
                    f"({holds[ticket_id].get('reason', 'writes landed, then the ticket '
                    'was rewritten')}). Check the profile, then release it with "
                    "--clear-hold.",
                    file=sys.stderr,
                )
        eligible, skipped_tagged = select_tickets(
            tickets, wanted=set(wanted), allow_tagged=args.allow_tagged,
        )
        for t in skipped_tagged:
            print(
                f"{t.get('id')}: NOT run — it already carries "
                f"{outcome_tags_of(t) or 'a terminal status'}, which is a recorded "
                "decision. Re-run it only with --allow-tagged --operator <email>, "
                "which overwrites that decision.",
                file=sys.stderr,
            )
    else:
        # `attempts` keeps an unparseable ticket from eating a slot on every
        # later run: it is counted in the report, not re-tried — until its text
        # changes, which is how a ticket that gains a manifest gets picked up.
        eligible = [
            t for t in select_tickets(tickets)[0]
            if not already_tried_this_text(attempts, t)
            and str(t.get("id")) not in held_ids
        ]
    selected = eligible[: max(1, min(args.max_tickets, MAX_TICKETS_PER_RUN))]

    # `--allow-tagged` is only meaningful with an explicit `--ticket` (a scan
    # never picks a tagged ticket), so it must not silently disable the
    # concurrent-human guard for tickets this run found by scanning.
    allow_replace = bool(args.allow_tagged and args.ticket)

    outcomes: list[TicketOutcome] = []
    exit_code = RUN_EXIT_OK
    for ticket in selected:
        try:
            outcome = run_ticket(
                admin, client, path,
                ticket=ticket, run_id=run_id, dry_run=dry_run,
                allow_replace=allow_replace, operator=args.operator,
                holds_path=holds_path,
            )
        except OutcomeConflict as exc:
            # A human labelled the ticket while we were working. The rows may all
            # have landed, but the ticket is not ours to tag: leave their decision
            # alone, report it, and let the reconciler/SLA digest see it.
            print(f"{ticket.get('id')}: left alone — {exc}", file=sys.stderr)
            outcomes.append(TicketOutcome(
                str(ticket.get("id")), "conflict", detail=str(exc), dry_run=dry_run,
            ))
            exit_code = max(exit_code, RUN_EXIT_PARTIAL)
            continue
        except DrainBlocked:
            # A kill file landed mid-run (checked at every write boundary). Stop
            # the whole run and let main render the stop reason.
            raise
        except TicketChanged as exc:
            # Nothing was written, and the ticket now asks for something else.
            # No attempts entry: the next run must read the NEW text, and the
            # fingerprint skip is keyed on text, so it will.
            print(f"{ticket.get('id')}: changed — {exc}", file=sys.stderr)
            outcomes.append(TicketOutcome(
                str(ticket.get("id")), "changed", detail=str(exc), dry_run=dry_run,
            ))
            exit_code = max(exit_code, RUN_EXIT_PARTIAL)
            continue
        except (ClickUpRateLimited, AdminError, RuntimeError) as exc:
            print(f"{ticket.get('id')}: stopped — {exc}", file=sys.stderr)
            exit_code = RUN_EXIT_BLOCKED
            break
        outcomes.append(outcome)
        if outcome.bucket not in (OUTCOME_COMPLETE,):
            attempts[str(ticket.get("id"))] = {
                "ts": int(time.time()),
                "bucket": outcome.bucket,
                "detail": outcome.detail[:400],
                "fingerprint": ticket_fingerprint(ticket),
            }
            if outcome.bucket == OUTCOME_PARTIAL:
                exit_code = max(exit_code, RUN_EXIT_PARTIAL)

    if not dry_run:
        # Drop entries for tickets that left the queue (closed by the reconciler
        # or a human), so this file tracks the OPEN backlog and not all history.
        # Only safe on a full scan: --ticket/--limit would forget the rest.
        if not args.ticket and args.limit <= 0:
            open_ids = {str(t.get("id")) for t in tickets}
            attempts = {k: v for k, v in attempts.items() if k in open_ids}
        try:
            save_attempts(attempts_path, attempts)
        except OSError as exc:
            print(f"warning: could not persist attempts state: {exc}", file=sys.stderr)

    report = render_report(
        outcomes,
        scanned=len(tickets),
        candidates=len(eligible),
        unparseable_total=unparseable,
        kills=None,
        dry_run=dry_run,
        writes=path.writes_this_run,
        remaining=path.writes_remaining_today(),
        held=len(held_ids),
    )
    if args.json:
        print(json.dumps({
            "run_id": run_id,
            "dry_run": dry_run,
            "scanned": len(tickets),
            "unparseable": unparseable,
            "writes": path.writes_this_run,
            "remaining_today": path.writes_remaining_today(),
            "tickets": [o.__dict__ for o in outcomes],
        }, indent=2, sort_keys=True))
    else:
        print(report)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
