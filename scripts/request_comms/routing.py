#!/usr/bin/env python3
"""Which request gets a message, on which channel, and why not when it doesn't.

The order is the captain's, and it is a ladder because each rung is a weaker guarantee:

  **in-app bell (always) -> Intercom (only when the contact resolves to THIS account by the r5
  identity rules) -> email (send-gateway, only when there is no Intercom identity)**

"Bell always" is an attempt, never an assumption: the bell answers `visibility` per user and an
all-false answer means the item reached nobody (see the notify-gateway trigger contract). When
the bell cannot confirm, the Intercom rung still goes — the user hearing on one channel beats a
strict "one channel only" rule, and every rung is its own ledger row.

Hard stops, in the order they are checked (each one is a `held` row with its reason, never a
silent drop):

  1. the fraud lens / watchlist / decider deny-list holds the account -> NOTHING is sent, ever;
     an unreadable lens is the same as held (fail closed).
  2. the owning source could not be read for this type -> no message (the run says UNKNOWN).
  3. the (request, state) pair was already claimed or sent -> nothing to say twice. A claim
     (`sending`/`uncertain`, no settled reply) holds for one cycle only: past `FLOOR_HOURS` from
     the attempt the floor re-arms, because a lost reply must not mute a request forever.
  4. the line is not approved yet (enabled:false / no approval_ref) -> held, `line_locked`.
  5. another sender already owns this state (core's S1/S2 for a credit decision, the merge
     outcome notifier for a merge, the legal hand-off for the erasure confirmation) -> held,
     `other_sender`. This is the sender-map rule, and it is why a status driver does not double
     the product's own notices.
  6. no channel could carry it -> held, `no_route`.

The bell is also the ONE rung whose copy is not ours: each kind's words live in notify-gateway's
catalog (`statusBell(...)`) and are rendered from the payload we trigger it with, so a bell can go
out BEFORE our own Intercom/email copy is approved. That is what the `bell_only` decision below
means: the words are approved upstream (muso-messaging #66 + the catalog's own tests), we only
choose WHICH kind and WHEN. Nothing else may be sent on a locked line — a bell never carries
`lines.text`.

The 48 h floor is a STATE, not a separate mechanism: `waiting` is the line the driver uses when
nothing changed and the request is still with us past `next_due_at`. It is the honest fallback,
never the target — the same overdue row is counted as a BREACH in the report, because the
captain's rule for our own side is 24 h.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from . import lines
from .sources import Request
from .store import Store, due_at, iso

FLOOR_HOURS = 48                     # the hard floor while a request is open
TARGET_HOURS = 24                    # the captain's rule for our own side (breach threshold)
OTHER_SENDER = {
    "credit": "core S1/S2 (the product's own decision notice)",
    "claim": "core S1 (`profile_claim_accepted` / `profile_claim_rejected`)",
    "merge": "merge-outcome-notify (S5 owns the merge outcome)",
    "erasure": "legal hand-off (the written confirmation is the team's letter, never this driver)",
}
# The states core/merge/legal already say out loud. Claim decisions belong here for the same reason
# credit ones do: core's own S1 route (`profile_claim_accepted` / `profile_claim_rejected`) is the
# sender of record, so a second "your claim was approved" from this driver is a double.
# Types whose approved copy is written for a THREAD ("on this thread"), so the Intercom rung must
# reply on the requester's own conversation rather than open a new one.
THREADED_TYPES = ("erasure",)

OTHER_SENDER_STATE = {("credit", "decided"), ("claim", "decided"), ("merge", "decided"),
                      ("erasure", "decided")}

# The ten status bells that exist in BOTH Novu environments (notify-gateway workflows/catalog.ts,
# `bellKind: true`, pinned by `bash scripts/ops/status-bell-check.sh` in muso-messaging). A key
# outside this set is a policy ERROR, not a rung that silently never fires.
BELL_KEYS = frozenset({
    "credit_status_in_review", "credit_status_needs_proof", "credit_status_doc_received",
    "credit_status_approved", "credit_status_declined",
    "claim_status_in_review", "claim_documents_needed", "claim_approved",
    "profile_merge_queued", "profile_merge_done",
})
# The bell kind for each (type, state), refineable by the owning row's RAW status. `credit/decided`
# and `claim/decided` are mapped because the key set demands an answer, but they are held by
# OTHER_SENDER above: core owns the decision notice. Nothing here bypasses a hold.
BELL_STATE_KEYS = {
    ("credit", "received"): "credit_status_in_review",
    ("credit", "verifying"): "credit_status_in_review",
    ("credit", "need_you"): "credit_status_needs_proof",
    ("claim", "received"): "claim_status_in_review",
    ("claim", "verifying"): "claim_status_in_review",
    ("claim", "need_you"): "claim_documents_needed",
    ("merge", "received"): "profile_merge_queued",
    ("merge", "verifying"): "profile_merge_queued",
    ("merge", "decided"): "profile_merge_done",
}
BELL_RAW_KEYS = {
    ("credit", "approved"): "credit_status_approved",
    ("credit", "rejected"): "credit_status_declined",
    ("credit", "withdrawn"): "credit_status_declined",
    ("credit", "doc_received"): "credit_status_doc_received",
    ("claim", "approved"): "claim_approved",
    ("claim", "processed"): "claim_approved",
}
# The notify-gateway kinds are named per request type, and that naming is the ONLY thing stopping a
# policy override from telling a credit requester that their claim was approved: the global set of
# ten is not enough, because every key in it is valid for SOME state.
BELL_FAMILY = {"credit": "credit_status_", "claim": "claim_", "merge": "profile_merge_"}

# `waiting` (the 48 h floor) reuses the kind the state itself would use; there is no separate
# "still waiting" bell and inventing one would be new copy nobody approved.
BELL_FALLBACK_STATE = "verifying"


@dataclass
class Decision:
    action: str                      # send | hold | skip
    reason: str = ""
    channel: str = ""
    line: lines.Line | None = None
    kind: str = "state"              # state | waiting | digest | bell_only
    text: str = ""                   # the exact bytes (slots/date rendered), '' unless action=send
    bell_key: str = ""               # the notify-gateway workflow key ('' = no bell rung)


def bell_key(policy: dict[str, Any], req: Request, *, waiting: bool = False) -> str:
    """Which bell kind tells this user about this state, or '' when the set has no kind for it.

    The workflow key comes from the pinned map above; the policy may RESTRICT it
    (`channels.bell.workflow_keys` maps `type/state` -> key and must name a real kind) but never
    invent one.
    """
    if not lines.channel_conf(policy, "bell").get("enabled"):
        return ""
    raw = str((req.detail or {}).get("raw_status") or "").lower()
    raw_kind = BELL_RAW_KEYS.get((req.type, raw), "") if raw else ""
    override = ((lines.channel_conf(policy, "bell").get("workflow_keys") or {}).get(f"{req.type}/{req.state}")
                or "")
    # An override is a RESTRICTION, so it may only narrow what the row itself can say. When the
    # owning row carries a raw status that already names a kind, an override naming a DIFFERENT
    # kind of the same state is not a restriction, it is a contradiction: `credit/decided` can
    # legitimately ring either `credit_status_approved` or `credit_status_declined`, so a static
    # gate cannot tell them apart and the row's own raw status has to win.
    if override and bell_override_allowed(req.type, str(override), req.state):
        if not raw_kind or str(override) == raw_kind:
            return str(override)
    # An override this state cannot ring is a policy error at validate() time; if one gets here
    # anyway (an old policy file, a caller that skipped validation) fall back to the pinned map
    # rather than announce a state the owning row does not have.
    if raw_kind:
        return raw_kind
    state = BELL_FALLBACK_STATE if waiting else req.state
    return BELL_STATE_KEYS.get((req.type, state), "")


def bell_allowed_keys(typ: str, state: str) -> set[str]:
    """The kinds a `(type, state)` can legitimately ring ON A STATE CHANGE.

    A family check is not enough: `credit_status_approved` is a credit kind, so a family-only rule
    let `credit/received -> credit_status_approved` validate and announce an approval the row does
    not contain. The allowed set is the kind the default mapping gives that state, plus the kinds
    of the raw statuses that MEAN that state.

    The 48 h floor's fallback kind is deliberately NOT in this set. It exists so a REMINDER can
    reuse `verifying`'s words when the state has no kind of its own; offering it to a state change
    let `credit/need_you -> credit_status_in_review` validate, and the customer would hear "in
    review" when the row says they owe us proof. The fallback is chosen by the driver for
    reminders only, never by the policy.
    """
    typ, state = str(typ or "").strip().lower(), str(state or "").strip().lower()
    if typ not in BELL_FAMILY:
        return set()                       # erasure / refund: no bell exists, so no override
    out: set[str] = set()
    k = BELL_STATE_KEYS.get((typ, state))
    if k:
        out.add(k)
    from .sources import CLAIM_STATES, CREDIT_STATES  # noqa: PLC0415 — one-way, keeps imports flat

    for (t, raw), kind in BELL_RAW_KEYS.items():
        table = CREDIT_STATES if t == "credit" else CLAIM_STATES
        got = table.get(raw)
        if t == typ and got and str(got[0]) == state:
            out.add(kind)
    return out


def bell_override_allowed(typ: str, key: str, state: str = "") -> bool:
    """True when `key` is a kind this `(type, state)` can legitimately ring."""
    key = str(key or "").strip()
    fam = BELL_FAMILY.get(str(typ or "").strip().lower(), "")
    if not (fam and key.startswith(fam)):
        return False
    return key in bell_allowed_keys(typ, state)


def bell_data(req: Request, *, count: int = 1, request_ids: list[str] | None = None) -> dict[str, Any]:
    """The payload a status bell renders from (catalog.ts render functions).

    `profile.name` is interpolated into every one of the ten kinds, so it is ALWAYS present:
    hydra has no profile-name reader for the core replica (there is no name column in postgres),
    and a missing name renders `for **** is with our team`. `"your profile"` is true, band-
    invariant, and reads correctly in all ten. Track fields are only passed when they look like
    text, because the catalog renders them inside markdown emphasis.
    """
    name = _safe(str((req.detail or {}).get("profile_name") or "")) or "your profile"
    data: dict[str, Any] = {"profile": {"name": name}, "count": max(1, int(count))}
    # `request_ids` is not decoration: notify-gateway's per-request dedupe (muso-messaging #82) reads
    # `data.request_ids` and, when a caller omits them, falls back to PROFILE scope — which would
    # suppress a legitimate bell (or let ours double the product event's own more-info-needed bell)
    # for the whole profile instead of the one request. Both senders must name the requests.
    ids = [str(x) for x in (request_ids if request_ids is not None else [req.id]) if str(x or "")]
    if ids:
        data["request_ids"] = ids
    title = _safe(str((req.detail or {}).get("track_title") or ""))
    artist = _safe(str((req.detail or {}).get("artist_name") or ""))
    if count == 1 and title:
        data.update({"single": True, "track_title": title, "artist_name": artist})
    merged = _safe(str((req.detail or {}).get("merged_profile_name") or ""))
    if merged:
        data["merged_profile"] = {"name": merged}
    return data


def _safe(v: str) -> str:
    """Trim, collapse whitespace, drop markdown emphasis characters and cap the length."""
    out = " ".join(v.split())[:120]
    return "".join(ch for ch in out if ch not in "*_`[]<>|")


LADDER = ("bell", "intercom", "email")


def enabled_rungs(policy: dict[str, Any]) -> set[str]:
    """The channels switched ON in the policy. `channels_for` picks the FIRST rung to try; this is
    what the fallback is allowed to climb afterwards — a bell that reached nobody must not fall
    through to a channel an operator has switched off."""
    return {c for c in LADDER if lines.channel_conf(policy, c).get("enabled") is True}


def channels_for(policy: dict[str, Any], *, has_intercom_identity: bool, has_email: bool,
                 typ: str, bell: str = "", identity_unknown: bool = False) -> list[str]:
    """The rungs this request can actually climb, in order.

    The bell rung needs a KIND, not just the switch: a state the catalog has no bell for (an
    erasure, a refund) must not be counted as a route, or the driver would report `send` and then
    find nothing to carry it.

    `identity_unknown` means the Intercom lookup FAILED, which is not the same answer as "this
    account has no Intercom contact". Email is the no-Intercom-identity rung, so a lookup we could
    not complete must not fall through to it: the user may well have a contact with a
    channel-specific preference or opt-out, and a timeout would route around it.
    """
    out: list[str] = []
    if bell and lines.channel_conf(policy, "bell").get("enabled"):
        out.append("bell")
    if has_intercom_identity and lines.channel_conf(policy, "intercom").get("enabled"):
        out.append("intercom")
    if (not has_intercom_identity and not identity_unknown and has_email
            and lines.channel_conf(policy, "email").get("enabled")):
        keys = lines.channel_conf(policy, "email").get("template_keys") or {}
        if str(keys.get(typ) or "").strip():
            out.append("email")
    return out


def is_due(*, state: str, last_told_state: str, last_told_at: str, terminal: bool,
           now: float) -> bool:
    """Due = the state changed since we last told them, OR the 48 h clock ran out while open."""
    if terminal and state == last_told_state:
        return False
    if state != last_told_state:
        return True
    if terminal or not last_told_at:
        return False
    at = iso(last_told_at)
    return bool(at) and (now - at.timestamp()) >= FLOOR_HOURS * 3600


def decide(req: Request, *, policy: dict[str, Any], store: Store | None = None, now: float,
           held_reason: str = "", has_intercom_identity: bool = False, has_email: bool = False,
           already_messaged_today: bool = False, core_delivered: str = "",
           last_told_state: str = "", last_told_at: str = "",
           blocking: dict[str, str] | set[str] | None = None,
           render_facts: dict[str, Any] | None = None,
           identity_unknown: bool = False) -> Decision:
    """One request, in or out. `held_reason` is the fraud-lens verdict ('' = not held).

    The told/blocking facts come from the caller (it reads them once per tick); a `store` is
    only a convenience for one-off callers such as the report.
    """
    if held_reason:
        return Decision("hold", f"bangate:{held_reason}")
    if req.state == "unknown":
        return Decision("hold", "state_unknown")
    if req.type in THREADED_TYPES and not str((req.detail or {}).get("conversation_id") or "").strip():
        # The approved acknowledgement promises "Written confirmation on this thread" and the
        # reference doc says "first reply, same conversation, always". A new outbound message would
        # leave the thread they actually wrote on unanswered while a second one appeared beside it,
        # so with no thread to reply on we HOLD rather than send a letter that breaks its own
        # promise. Held, not dropped: the row stays visible and the reason is recorded.
        return Decision("hold", "no_thread")
    if (req.detail or {}).get("cap_identity_unresolved"):
        # One message per person per day: if we cannot say whether this IS the same person who
        # already heard from us today, the honest answer is to wait, not to send a second time.
        return Decision("hold", "cap_identity_unknown")
    if store is not None:
        told = store.told_per_ref().get(req.ref)
        last_told_state = last_told_state or (str(told["state"]) if told else "")
        last_told_at = last_told_at or (str(told["at"]) if told else "")
        blocking = blocking if blocking is not None else store.blocking_states(req.ref)
    if not is_due(state=req.state, last_told_state=last_told_state, last_told_at=last_told_at,
                  terminal=req.terminal, now=now):
        return Decision("skip", "not_due")

    waiting = req.state == last_told_state          # nothing changed: this is the 48 h floor
    if waiting and req.waiting_on == "user":
        # They owe us something, not the other way round: our silence is not the failure the 48 h
        # floor exists for, and a `needs_proof` bell every two days is a nag, not an update. The
        # state CHANGE still goes (that is the first notice); only the repeat is suppressed.
        return Decision("skip", "waiting_on_user")
    # A claim for THIS state that is newer than the last CONFIRMED (sent) row is unsettled: either
    # an attempt whose reply was lost or one that is still in flight. It blocks the state change AND
    # the 48 h reminder - a reminder re-derived from a 49-hour-old send would otherwise post a
    # second copy of an update we already tried to send (`waiting` used to skip this check entirely).
    #
    # Strictly newer is the test, not `>=`: the settled `sent` row IS the row that produced
    # `last_told_at`, so treating equality as a claim would silence the floor forever. An older
    # claim is history - `verifying -> need_you -> verifying` is two changes and both go out.
    claim_is_live = False
    if isinstance(blocking, dict):
        claimed_at = str(blocking.get(req.state) or "")
        if claimed_at and claimed_at > (last_told_at or ""):
            # ... but a claim is not a promise kept forever. An attempt whose reply never came back
            # (`sending`/`uncertain`) silences THIS cycle only. Once the floor has run out again
            # since the attempt, the user may have heard nothing for 96 h, so the honest move is to
            # try again rather than let one lost reply mute the request permanently. An unreadable
            # stamp cannot establish a live cycle either, and the promise to the user outranks a
            # possible duplicate.
            at = iso(claimed_at)
            claim_is_live = at is not None and (now - at.timestamp()) < FLOOR_HOURS * 3600
    elif blocking and req.state in blocking:      # a bare set (old callers): treat as a live claim
        claim_is_live = True
    if claim_is_live:
        return Decision("skip", "already_told_state" if not waiting else "claim_unsettled")
    key_state = "waiting" if waiting else req.state
    line = lines.line(policy, req.type, key_state)
    bell = bell_key(policy, req, waiting=waiting)
    # Another sender owns this state unless the line was reviewed as a GAP FILL and that sender
    # provably delivered nothing (core's notice markers, the merge outcome notifier's own record).
    if (req.type, req.state) in OTHER_SENDER_STATE and not (line and line.gap_fill and not core_delivered):
        return Decision("hold", f"other_sender:{OTHER_SENDER.get(req.type, 'core S1/S2')}", bell_key=bell)
    if line is not None and lines.sendable(line):
        text, why = lines.render(line, render_facts or {})
        if why:
            return Decision("hold", why, line=line, bell_key=bell)
    else:
        # Our own copy for this state is not approved yet. The bell's copy is not ours (it lives in
        # the notify-gateway catalog and is approved there), so a bell may still go — and ONLY a
        # bell: no text of ours exists to send anywhere else.
        if bell:
            if already_messaged_today:
                return Decision("skip", "daily_cap", kind="bell_only", bell_key=bell)
            return Decision("send", "", "bell", None, "bell_only", "", bell)
        return Decision("hold", f"line_locked:{line.key}" if line else f"no_line:{req.type}/{key_state}",
                        line=line, bell_key=bell)
    rungs = channels_for(policy, has_intercom_identity=has_intercom_identity,
                         has_email=has_email, typ=req.type, bell=bell,
                         identity_unknown=identity_unknown)
    if not rungs:
        # A failed lookup is a reason to WAIT, not a reason to say there is no route: the next tick
        # may resolve it, and the row stays visible with the real cause recorded.
        return Decision("hold", "identity_unknown" if identity_unknown else "no_route",
                        line=line, bell_key=bell)
    if already_messaged_today:
        # One message per user per UTC day across every request and every sender. More than one
        # due request becomes ONE digest line, decided by the caller (it can see the whole tick).
        return Decision("skip", "daily_cap", line=line, kind="waiting" if waiting else "state",
                        bell_key=bell)
    return Decision("send", "", rungs[0], line, "waiting" if waiting else "state", text, bell)


def digest_for(reqs: list[Request], *, policy: dict[str, Any], has_intercom_identity: bool,
               has_email: bool, render_facts: dict[str, Any] | None = None,
               waiting: bool = False, identity_unknown: bool = False) -> Decision:
    """ONE line for a user with more than one due request (never 300 messages)."""
    bell = digest_bell_key(policy, reqs, waiting=waiting)
    line = lines.digest_line(policy)
    if line is None or not lines.sendable(line):
        if bell:      # the bell's copy is upstream's; only OUR digest letter is unapproved
            return Decision("send", "", "bell", None, "bell_only", "", bell)
        return Decision("hold", "line_locked:digest", bell_key=bell)
    text, why = lines.render(line, render_facts or {})
    if why:
        return Decision("hold", why, line=line)
    typ = sorted({r.type for r in reqs})[0]
    rungs = channels_for(policy, has_intercom_identity=has_intercom_identity, has_email=has_email,
                         typ=typ, bell=bell, identity_unknown=identity_unknown)
    if not rungs:
        return Decision("hold", "identity_unknown" if identity_unknown else "no_route",
                        line=line, bell_key=bell)
    return Decision("send", "", rungs[0], line, "digest", text, bell)


def digest_bell_key(policy: dict[str, Any], reqs: list[Request], *, waiting: bool = False) -> str:
    """A bell kind for a digest ONLY when every member is the same type and state.

    `credit_status_in_review` says "N credit submissions ... are with our team": a mixed digest
    would state something false about the claim inside it, so a mixed group never becomes one
    bell (the caller sends the oldest pair instead and the rest wait a day).
    """
    if len({(r.type, r.state) for r in reqs}) != 1:
        return ""
    return bell_key(policy, reqs[0], waiting=waiting)


def next_due(state: str, last_told_at: str, terminal: bool) -> str:
    return due_at(last_told_at, not terminal, hours=FLOOR_HOURS)


def breach(req: Request, *, last_told_at: str, now: float, target_hours: int = TARGET_HOURS) -> str:
    """'' when fine; `target` past 24 h; `floor` past 48 h. Waiting-on-us rows past 24 h are the
    captain's breach — the 48 h line is what we send, not what we are allowed."""
    if req.terminal or req.waiting_on == "user":
        return ""
    at = iso(last_told_at) or iso(req.created_at)
    if at is None:
        return ""
    hours = (now - at.timestamp()) / 3600.0
    if hours >= FLOOR_HOURS:
        return "floor"
    if hours >= target_hours:
        return "target"
    return ""
