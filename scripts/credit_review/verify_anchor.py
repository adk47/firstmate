#!/usr/bin/env python3
"""Server-side verification of a scale-drain approve anchor.

The drain's approve gate (``is_scale_drain_approval`` in ``muso-admin-api.sh``) used to
accept a caller-supplied digest on trust: ``SCALE_DRAIN=1``, ``--requester
scale-drain@hydra-ops`` and a syntactically valid ``drain-signal:...`` string were enough
to approve an arbitrary UUID. That is a labelled bypass, not a narrow one - anyone who can
invoke the wrapper could approve anything (QA review of hydra#1883, 2026-11-11).

This module is the fix. The wrapper calls it with the digest's parts and the request id it
is about to write, and it answers from a source the caller does not control:

  * **precedent** - ONE admin-API GET for the claimant's profile returns every request on
    that profile, including both the target and the anchor. The anchor must be
    ``approved`` and must match the target on claimant, track and claimed roles. A caller
    cannot make the API say a request is approved, so the check cannot be forged.
  * **proof_verdict** - the proof store is a root-owned SQLite file on the host, keyed
    by claim (one verdict per claimed role). The same ONE admin GET returns the request as
    it stands now; EVERY role it claims must have a verdict on file, and the newest
    verdict of every claim must be a decision (``GENUINE``/``VERIFIED``) resting on the
    anchored proof. A caller cannot write those rows, and cannot make the API drop a role
    from the request.
  * **duplicate** - the same GET; the named original must be decided and must be the same
    claim.

Cost: one GET per verified row, and only rows that write are verified. Measured on the
real snapshot of 2026-11-11 that is 3,294 approves out of 96,703 pending requests.

Both sources are PINNED. The admin API is read through the wrapper that sits beside this
file in the deployed tree (``ADMIN_SCRIPT``), and the batch client is loaded from this
file's own directory. Neither is taken from the environment: a caller who sets
``CREDIT_REVIEW_ADMIN_SCRIPT`` to anything else is REFUSED, because a verifier that reads
through a caller-chosen script is consuming a response the caller wrote (QA review 4 of
hydra#1883).

The wrapper runs this file as a script (``python3 -I verify_anchor.py``), so it must not
depend on a package context, on ``PYTHONPATH`` or on the working directory.

Exit codes: 0 verified, 1 refused (with the reason on stderr), 2 the check could not run,
3 refused because the request ALREADY holds the status this write would set. Every
non-zero code refuses the write, and a check that cannot run is a REFUSAL, never a pass.

Exit 3 is separate from exit 1 because the two mean different things to the drain. "The
request is already approved" is what a write of our own looks like after a crash between
the API call and the ledger commit; "the request was rejected" or "the anchor is not
approved" is a decision that is not ours to overwrite. The gate refuses both - it never
re-writes a decided request - but only the first is something ``scale_drain apply`` may
RECONCILE from its own intent row, with ``reconcile`` below (QA review 5 of hydra#1883).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

_HERE = Path(__file__).resolve().parent

#: The admin wrapper this verifier reads through. FIXED relative to this file: the
#: deployed tree is ``<root>/scripts/credit_review/verify_anchor.py`` beside
#: ``<root>/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh``, so on
#: node-8 this is ``/opt/hydra/workspaces/...``, the wrapper every other credit writer
#: uses. It is the same derivation the wrapper uses to find this file
#: (``scale_drain_root``), for the same reason: a location is not something a caller can
#: set, an environment variable is.
ADMIN_SCRIPT = str(_HERE.parents[1] / "workspaces" / "operations" / "skills"
                   / "muso-ops-admin" / "scripts" / "muso-admin-api.sh")

#: The variable every OTHER admin client honours as an override. Here it is a tripwire.
ADMIN_SCRIPT_ENV = "CREDIT_REVIEW_ADMIN_SCRIPT"

#: The proof store. Root-owned; the drain and this verifier run as root on node-8.
#:
#: The path is FIXED. ``CREDIT_PROOF_STORE`` / ``CREDIT_VERIFY_STATE_DIR`` are honoured by
#: the proof WRITER, but not here: they are caller-controlled, so a caller who can invoke
#: the wrapper could point this check at a SQLite file it wrote itself and fabricate a
#: GENUINE verdict. A caller-supplied override on the approval path is a forgeable
#: approval, which is the whole thing this module exists to prevent (QA review 3 of
#: hydra#1883, 2026-11-11). ``verify_proof`` still takes the path as an argument for unit
#: tests; the CLI never reads it from the environment.
PROOF_STORE = "/var/lib/hydra-credit-verify/proof.sqlite"

#: A verdict that is a decision. Mirrors ``scale_drain.PROOF_VERDICT_APPROVE``; a soft or
#: undetermined verdict is not an approval and must never verify one.
APPROVE_VERDICTS = ("GENUINE", "VERIFIED")

#: The statuses a request may be approved FROM. An already-decided target is not a
#: pending row the drain should be writing.
PENDING_STATUSES = ("user_verification_needed", "unverified")

#: A status that means a human (or a registered automation) already decided the request.
#: A duplicate close may only point at one of these.
DECIDED_STATUSES = ("approved", "rejected")

#: The status each rule's write sets. It is what tells "this write already happened" from
#: "somebody decided this request differently".
RULE_WRITES = {"precedent": "approved", "proof_verdict": "approved", "duplicate": "rejected"}

#: ``reconcile`` verdicts.
LANDED = "landed"            # the request holds our status, and the evidence says it is ours
NOT_LANDED = "not_landed"    # the request is still pending: the write never happened

#: How far the backend's clock may run behind this host's before a change it stamped is
#: read as older than our intent. Small on purpose: every second of tolerance is a second
#: in which someone else's decision, made just before our intent, would read as ours.
CLOCK_SKEW_SECONDS = 5


class Refused(Exception):
    """The anchor does not support the write. Exit 1."""


class AlreadyWritten(Refused):
    """The request already holds the status this write would set. Exit 3.

    Still a refusal: the gate does not re-write a decided request, and from here it cannot
    know who decided it. It is a distinct class so the caller can tell it from a refusal
    that says the write would be WRONG.
    """


class Elsewhere(Refused):
    """``reconcile``: the request was decided, and not by this decision.

    ``reason_code`` is what the drain records when it abandons the intent.
    """

    def __init__(self, reason_code: str, message: str):
        super().__init__(message)
        self.reason_code = reason_code


class Unavailable(Exception):
    """The check could not run. Exit 2 - a refusal, never a pass."""


def _batch_admin() -> Any:
    """``batch_admin``, loaded from THIS file's directory and from nowhere else.

    Not ``from . import batch_admin``: the wrapper executes this file as a script, where
    there is no parent package and that import raises ``ImportError`` - which is how both
    gates came to refuse every write in production while the suite stayed green (QA
    review 4 of hydra#1883). Not ``import credit_review.batch_admin`` either: that
    resolves through ``sys.path``, which a caller steers with ``PYTHONPATH`` or the
    working directory, and the batch client is what turns a script path into the admin
    response this module trusts.
    """
    name = "credit_review_verify_anchor_batch_admin"
    cached = sys.modules.get(name)
    if cached is not None:
        return cached
    path = _HERE / "batch_admin.py"
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise Unavailable(f"batch client {path} cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    # Registered before exec: dataclasses resolves a class's module through sys.modules.
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except Exception as exc:
        sys.modules.pop(name, None)
        raise Unavailable(f"batch client {path} cannot be loaded: {exc}") from exc
    return module


def pinned_admin() -> Any:
    """The ONE admin client the CLI verifies with: the pinned wrapper, or a refusal.

    A caller-supplied ``CREDIT_REVIEW_ADMIN_SCRIPT`` is refused, not ignored. Ignoring it
    would be enough to keep the read honest, but it would also let a caller who is trying
    to redirect the verifier see a green run and learn nothing; a refusal names the
    attempt in the wrapper's stderr and in the drain's error for that row. A value that
    resolves to the pinned wrapper is not a redirect and is let through, so a host that
    exports the canonical path for the other credit tools keeps working.
    """
    override = os.environ.get(ADMIN_SCRIPT_ENV)
    if override is not None and os.path.realpath(override) != os.path.realpath(ADMIN_SCRIPT):
        raise Refused(f"{ADMIN_SCRIPT_ENV} is set to {override!r}, but the verifier reads "
                      f"only through {ADMIN_SCRIPT}; a redirected admin source is not a "
                      "source")
    if not os.path.isfile(ADMIN_SCRIPT):
        raise Unavailable(f"admin wrapper {ADMIN_SCRIPT} does not exist")
    return _batch_admin().BatchAdmin(script=ADMIN_SCRIPT)


def _norm_roles(value: Any) -> list[str]:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            value = [value]
    if not isinstance(value, (list, tuple)):
        return []
    return sorted(str(v) for v in value)


def _profile_requests(admin: Any, profile_id: str) -> dict[str, dict[str, Any]]:
    """ONE GET for the claimant's profile, keyed by request id.

    ``profilesIds`` is the only filter core's list endpoint applies, and a filtered list
    is exempt from the unfiltered deep-paging cap, so this is one round trip for the whole
    profile rather than one per request.
    """
    data = admin.get("/admin/credit-requests",
                     {"profilesIds": profile_id, "limit": 200, "page": 1})
    items = data.get("items") if isinstance(data, dict) else None
    if not isinstance(items, list):
        raise Unavailable("credit-requests list has no items[]")
    return {str(it.get("id")): it for it in items if it.get("id")}


def _same_claim(anchor: dict[str, Any], target: dict[str, Any], anchor_id: str) -> None:
    """The anchor must be the SAME CLAIM: same claimant, same track, same roles.

    A class-level match would let one account's approval approve another account, which is
    the hole QA review 1 of hydra#1883 found.
    """
    for field, label in (("userId", "claimant"), ("trackId", "track")):
        if str(anchor.get(field) or "") != str(target.get(field) or ""):
            raise Refused(f"anchor {anchor_id} differs from the request on {label}")
    if _norm_roles(anchor.get("credits")) != _norm_roles(target.get("credits")):
        raise Refused(f"anchor {anchor_id} differs from the request on claimed roles")


def _status(item: dict[str, Any]) -> str:
    return str(item.get("status") or "").lower()


def _pending_target(by_id: dict[str, dict[str, Any]], request_id: str, profile_id: str,
                    what: str) -> dict[str, Any]:
    """The request this write is about, as the API reports it NOW - and still pending."""
    target = by_id.get(request_id)
    if target is None:
        raise Refused(f"request {request_id} is not on profile {profile_id}")
    target_status = _status(target)
    if target_status not in PENDING_STATUSES:
        if target_status == RULE_WRITES[what]:
            raise AlreadyWritten(
                f"request {request_id} is already {target_status}: there is nothing to "
                "write, and a decided request is never re-written. If this drain wrote "
                "it, `scale_drain apply` reconciles it from its intent row")
        raise Refused(f"request {request_id} is {target_status or 'unknown'}, not pending")
    return target


def _pair(admin: Any, request_id: str, anchor_id: str, profile_id: str,
          what: str) -> tuple[dict[str, Any], dict[str, Any]]:
    """ONE GET for the profile, then the target and the anchor out of it."""
    if not profile_id:
        raise Refused(f"{what} anchor carries no profile id")
    by_id = _profile_requests(admin, profile_id)
    target = _pending_target(by_id, request_id, profile_id, what)
    anchor = by_id.get(anchor_id)
    if anchor is None:
        raise Refused(f"anchor {anchor_id} is not on profile {profile_id}")
    return target, anchor


def _anchor_supports_precedent(anchor: dict[str, Any], target: dict[str, Any],
                               anchor_id: str) -> None:
    status = _status(anchor)
    if status != "approved":
        raise Refused(f"anchor {anchor_id} is {status or 'unknown'}, not approved")
    _same_claim(anchor, target, anchor_id)


def _original_supports_duplicate(original: dict[str, Any], target: dict[str, Any],
                                 original_id: str) -> None:
    status = _status(original)
    if status not in DECIDED_STATUSES:
        raise Refused(f"original {original_id} is {status or 'unknown'}, not decided")
    _same_claim(original, target, original_id)


#: What ``uncovered_holds`` returns for a verdict it cannot read. Unreadable is a hold:
#: "could not read the holds" must never come out as "there are none".
HOLD_UNREADABLE = "verdict_unreadable"

# The three facts core's guard holds an agent approval on (core-backend
# ``agentApprovalGuard.validatorConflict``; ``policy.validator_conflict`` is hydra's mirror).
# They are written again here because this file runs as a script (``python3 -I
# verify_anchor.py``) and ``policy.py`` has relative imports it cannot satisfy that way.
# ``test_verify_anchor.GuardReaderTests`` holds this reader and these numbers to policy's.
GUARD_HOLD_RULE_PREFIX = "review_"
GUARD_HOLD_RULE_MIN_SCORE = 30
GUARD_HOLD_ON_ERROR_KEY = "_hold_on_error"
GUARD_CLASS_C_TRACK_CREDIT = 70
GUARD_CLASS_C_COLLABORATIONS = 90


def _score(value: Any) -> float | None:
    """A rule score as the guard reads it: only a JSON number counts."""
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    return None


def guard_holds(vd: Any) -> bool:
    """Does core's guard hold an agent approval of a request carrying this verdict?

    True on any of: a ``review_*`` rule at 30 or more, the class C signature
    (``track_credit`` at 70 or more with ``collaborations`` at 90 or more), or
    ``rule_errors._hold_on_error``. A verdict the guard cannot read holds nothing there,
    so it is False here.
    """
    if not isinstance(vd, dict):
        return False
    errors = vd.get("rule_errors")
    if isinstance(errors, dict) and GUARD_HOLD_ON_ERROR_KEY in errors:
        return True
    rules = vd.get("rule_risk_percent")
    if not isinstance(rules, dict):
        return False
    track_credit = _score(rules.get("track_credit"))
    collaborations = _score(rules.get("collaborations"))
    if (track_credit is not None and collaborations is not None
            and track_credit >= GUARD_CLASS_C_TRACK_CREDIT
            and collaborations >= GUARD_CLASS_C_COLLABORATIONS):
        return True
    for name, value in rules.items():
        score = _score(value)
        if (str(name).startswith(GUARD_HOLD_RULE_PREFIX) and score is not None
                and score >= GUARD_HOLD_RULE_MIN_SCORE):
            return True
    return False


def uncovered_holds(vd: Any) -> list[str]:
    """The hold codes on a verdict that core's guard would NOT stop an approval on.

    Empty when the verdict lists no hold, and empty when the guard itself holds
    (``guard_holds``): core refuses that approval with ``validator_hold`` and
    ``scale_drain`` routes the refusal, so this code stays out of its way. Otherwise every
    listed code counts, whatever it is called and whatever it scored: on 2026-11-13 two
    requests carrying ``track_pending_capture`` at risk 100 were approved 17 minutes after
    the hold was set, because that verdict had none of the guard's three facts. A list
    that cannot be read is a hold (``HOLD_UNREADABLE``), under the same condition. A
    request with no verdict at all (``None``) carries no hold.
    """
    if vd is None:
        return []
    if not isinstance(vd, dict):
        return [HOLD_UNREADABLE]
    codes = vd.get("hold_reason_codes")
    if codes is None:
        return []
    held = sorted({str(c) for c in codes}) if isinstance(codes, list) else [HOLD_UNREADABLE]
    if not held or guard_holds(vd):
        return []
    return held


def _no_uncovered_hold(target: dict[str, Any], request_id: str) -> None:
    """An approve is refused while the request, as the API reports it NOW, carries a hold
    core's guard would not stop.

    The plan is built from a snapshot and already leaves out every such row the snapshot
    shows, so what this meets is a hold set after the snapshot. The admin list carries
    ``verificationData`` on every item (200 of 200 on 2026-11-13); an item without the
    field is a read this gate cannot make, not a request with no hold.
    """
    if "verificationData" not in target:
        raise Unavailable(f"request {request_id} was listed without verificationData, so "
                          "its holds cannot be read")
    codes = uncovered_holds(target["verificationData"])
    if codes:
        raise Refused(f"request {request_id} is on hold ({', '.join(codes)}) and core's "
                      "guard does not stop that hold: this drain does not approve it")


def verify_precedent(admin: Any, request_id: str, anchor_id: str, profile_id: str) -> None:
    target, anchor = _pair(admin, request_id, anchor_id, profile_id, "precedent")
    _no_uncovered_hold(target, request_id)
    _anchor_supports_precedent(anchor, target, anchor_id)


def verify_duplicate(admin: Any, request_id: str, original_id: str, profile_id: str) -> None:
    """A duplicate close is only justified if the named original is a DECIDED request for
    the same claim. QA review 2 of hydra#1883: the token alone let a caller close an
    unrelated pending request as a 'duplicate'."""
    target, original = _pair(admin, request_id, original_id, profile_id, "duplicate")
    _original_supports_duplicate(original, target, original_id)


#: How the proof store names a claim: ``<request id>#<Role>``. A request that claims no
#: role at all is analysed as the one claim ``<request id>#unknown``.
CLAIM_SEP = "#"
NO_ROLE = "unknown"


def _role_key(role: Any) -> str:
    return str(role or "").strip().lower()


def verify_proof(request_id: str, proof_id: str, store_path: str,
                 claimed_roles: Any) -> None:
    """The anchored proof is the standing approval of EVERY claim on this request.

    ``claimed_roles`` is what the request claims NOW, read from the admin API by the
    caller - never from the plan and never from the digest. It is required because the
    store can only say what it holds: a Composer+Producer request with one ``GENUINE``
    Composer verdict and no Producer row at all had nothing refusing in it, and the write
    approves the whole request (QA review 6 of hydra#1883). So a role the request claims
    with no verdict on file refuses, exactly as a soft verdict for it would.

    The store keys a verdict by claim, ``<request id>#<Role>``, one row per role (a bare
    request id is a verdict on the whole request). Matching the bare id alone found
    nothing on real data - every bound row carries a role - so this gate refused every
    proof approve it was ever asked about.

    For each claim the NEWEST verdict is the one that counts, and all of them must be an
    approval resting on the anchored proof. One role still ``SUSPECT``, or approved on a
    different document, refuses the whole request: the write approves the request, not a
    role of it.
    """
    if not request_id:
        raise Refused("no request id to look a verdict up for")
    if claimed_roles is None or isinstance(claimed_roles, (str, bytes)):
        raise Unavailable(f"the roles request {request_id} claims were not read, so the "
                          "proof cannot be checked against them")
    if not os.path.exists(store_path):
        raise Unavailable(f"proof store {store_path} does not exist")
    try:
        db = sqlite3.connect(f"file:{store_path}?mode=ro", uri=True)
    except sqlite3.Error as exc:
        raise Unavailable(f"proof store {store_path} unreadable: {exc}") from exc
    try:
        # By REQUEST, not by proof id. Selecting by proof id let a caller anchor on an old
        # GENUINE proof while a newer PLAUSIBLE analysis of the same request sat unread,
        # and the schema defaults request_id to '' so an unbound proof row could be
        # pointed at any pending target (QA review of hydra#1883, 2026-11-11). The prefix
        # is compared with substr, not LIKE: nothing in the id is a pattern.
        prefix = request_id + CLAIM_SEP
        rows = db.execute(
            "SELECT request_id, proof_id, verdict FROM verdicts"
            " WHERE request_id = ? OR substr(request_id, 1, ?) = ?"
            " ORDER BY created_at, id", (request_id, len(prefix), prefix)).fetchall()
    except sqlite3.Error as exc:
        raise Unavailable(f"proof store query failed: {exc}") from exc
    finally:
        db.close()
    if not rows:
        raise Refused(f"no verdict recorded for request {request_id}")
    newest: dict[str, tuple[str, str]] = {}
    for key, proof, verdict in rows:          # ascending, so the last one per claim wins
        newest[str(key)] = (str(proof or ""), str(verdict or ""))
    for key in sorted(newest):
        newest_proof, verdict = newest[key]
        claim = f"request {request_id}" if key == request_id else f"claim {key}"
        if newest_proof != proof_id:
            raise Refused(f"the newest verdict for {claim} is for proof "
                          f"{newest_proof or 'unknown'}, not the anchored {proof_id}")
        if verdict not in APPROVE_VERDICTS:
            raise Refused(f"newest verdict for {claim} is {verdict or 'unknown'}, "
                          "not an approval")
    # Every claim on file approves. Now the other direction: every role the request
    # claims must BE on file, under its own claim key. A verdict keyed by the bare
    # request id is held to the rule above like any other, but it does NOT stand in for a
    # role: stage 2 writes one row per role and no production row is keyed bare, so "one
    # row covers whatever the request claims" would be an exception with no caller, and
    # exactly the single row that approves any role set.
    on_file = {_role_key(key[len(prefix):]) for key in newest if key != request_id}
    wanted = {_role_key(r) for r in claimed_roles if _role_key(r)} or {NO_ROLE}
    missing = sorted(wanted - on_file)
    if missing:
        raise Refused(f"request {request_id} claims {', '.join(missing)} with no verdict "
                      f"on file; proof {proof_id} approves only "
                      f"{', '.join(sorted(on_file)) or 'no named role'}")


def verify_proof_live(admin: Any, request_id: str, proof_id: str, profile_id: str,
                      store_path: str) -> None:
    """A proof approve, checked against the request as it stands NOW.

    ONE GET for the claimant's profile, the same read the other two rules make. It
    supplies the two facts the proof store cannot: that the request is still pending (an
    already-approved one is ``AlreadyWritten``, as for a precedent), and the roles it
    claims, which the proof must cover in full.
    """
    if not profile_id:
        raise Refused("proof_verdict anchor carries no profile id, so the roles the "
                      "request claims cannot be read")
    target = _pending_target(_profile_requests(admin, profile_id), request_id, profile_id,
                             "proof_verdict")
    _no_uncovered_hold(target, request_id)
    verify_proof(request_id, proof_id, store_path, _norm_roles(target.get("credits")))


def _parse_ts(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        ts = datetime.fromisoformat(text)
    except ValueError:
        return None
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts.astimezone(timezone.utc)


def reconcile(rule: str, anchor: str, request_id: str, profile_id: str, *,
              planned_at: str, admin: Any = None, store_path: str = PROOF_STORE) -> str:
    """Did a write this drain INTENDED actually land? A read; it never writes.

    The drain records an intent row before it calls the API. A crash between the call and
    the ledger commit leaves that row unconfirmed, and the write gate cannot settle it:
    the gate refuses a request that is no longer pending, whoever moved it. This is the
    check that can, from the live request and the intent's own timestamp:

    * still pending -> ``NOT_LANDED``. The write never happened; the caller may retry it
      through the gate, which verifies the anchor in full.
    * holds the status this rule writes, was last changed NO EARLIER than the intent was
      recorded, and this decision's anchor still verifies the claim -> ``LANDED``.
    * decided any other way -> ``Elsewhere``, with a reason code. Not ours:
      ``target_<status>`` (decided differently - never overwritten),
      ``decided_before_intent`` (it already held the status before we planned to set it,
      so the gate refused our write and somebody else made the decision), or
      ``anchor_unverified`` (the gate could not have passed our write, so we did not make
      it).
    * anything unreadable -> ``Unavailable``. An unread request is not a landed write and
      not a refused one; the intent stays open.

    What this cannot see: the admin API names no actor. A request that somebody else moved
    to the same status AFTER our intent was recorded, on a claim our anchor also supports,
    is indistinguishable from our own write and is reported ``LANDED``. The caller records
    such a row as reconciled, never as written, so it can always be told apart.
    """
    writes = RULE_WRITES.get(rule)
    if writes is None:
        raise Refused(f"rule {rule!r} is not auto-approvable")
    planned = _parse_ts(planned_at)
    if planned is None:
        raise Unavailable(f"intent for request {request_id} carries no readable planned_at")
    if not profile_id:
        raise Unavailable(f"request {request_id} names no profile to read its live status "
                          "through")
    by_id = _profile_requests(pinned_admin() if admin is None else admin, profile_id)
    target = by_id.get(request_id)
    if target is None:
        raise Unavailable(f"request {request_id} is not in the requests read for profile "
                          f"{profile_id}; its live status is unread")
    status = _status(target)
    if status in PENDING_STATUSES:
        return NOT_LANDED
    if status not in DECIDED_STATUSES:
        # e.g. `processing`: not ours, and not a decision either. It may yet come back.
        raise Unavailable(f"request {request_id} is {status or 'unknown'}, neither pending "
                          "nor decided")
    if status != writes:
        raise Elsewhere(f"target_{status}",
                        f"request {request_id} is {status}, and this decision writes "
                        f"{writes}; a decided request is never overwritten")
    changed = _parse_ts(target.get("updatedAt"))
    if changed is None:
        raise Unavailable(f"request {request_id} is {status} but carries no readable "
                          "updatedAt, so when it was decided is unread")
    if changed < planned - timedelta(seconds=CLOCK_SKEW_SECONDS):
        raise Elsewhere("decided_before_intent",
                        f"request {request_id} has been {status} since "
                        f"{target.get('updatedAt')}, before this intent was recorded at "
                        f"{planned_at}")
    try:
        if rule == "proof_verdict":
            verify_proof(request_id, anchor, store_path,
                         _norm_roles(target.get("credits")))
        else:
            cited = by_id.get(anchor)
            if cited is None:
                raise Refused(f"anchor {anchor} is not on profile {profile_id}")
            if rule == "precedent":
                _anchor_supports_precedent(cited, target, anchor)
            else:
                _original_supports_duplicate(cited, target, anchor)
    except Refused as exc:
        raise Elsewhere("anchor_unverified",
                        f"request {request_id} is {status}, but this decision could not "
                        f"have written it: {exc}") from exc
    return LANDED


def verify(rule: str, anchor: str, request_id: str, profile_id: str, *,
           admin: Any = None, store_path: str = PROOF_STORE) -> None:
    if rule == "precedent":
        verify_precedent(pinned_admin() if admin is None else admin,
                         request_id, anchor, profile_id)
    elif rule == "proof_verdict":
        verify_proof_live(pinned_admin() if admin is None else admin,
                          request_id, anchor, profile_id, store_path)
    elif rule == "duplicate":
        verify_duplicate(pinned_admin() if admin is None else admin,
                         request_id, anchor, profile_id)
    else:
        raise Refused(f"rule {rule!r} is not auto-approvable")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--rule", required=True)
    ap.add_argument("--anchor", required=True)
    ap.add_argument("--request-id", required=True)
    ap.add_argument("--profile-id", default="")
    ap.add_argument("--proof-store", default=PROOF_STORE)
    args = ap.parse_args(argv)
    # The digest writes "-" for "no profile". It is not a profile id, and it must not
    # reach the API as a filter value.
    profile_id = "" if args.profile_id.strip() == "-" else args.profile_id.strip()
    try:
        verify(args.rule, args.anchor, args.request_id, profile_id,
               store_path=args.proof_store)
    except AlreadyWritten as exc:
        print(f"scale_drain: nothing to write: {exc}", file=sys.stderr)
        return 3
    except Refused as exc:
        print(f"scale_drain: anchor refused: {exc}", file=sys.stderr)
        return 1
    except Unavailable as exc:
        print(f"scale_drain: anchor could not be verified: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
