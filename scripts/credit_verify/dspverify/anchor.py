"""The server-side anchor record for an approval (Fable ruling l12-approvals-core = option A).

Core's approval guard admits an agent approval only on evidence a SERVER wrote, never on a value the
caller asserts. For an L12 tray approval, the verifier's capture job writes that evidence first: one
record per tray row, built here from the verifier's OWN standing verdict and packet (the same-run
Spotify + Tidal capture it requested), never from the tray.

  kind dsp_anchor      a person credit: built only when the verifier's verdict is APPROVE. The
                       record names the roles BOTH DSPs credit to the claimant's linked id
                       (approve_roles), with every role holder each capture listed.
  kind dsp_label_line  an org (label / publisher) credit: built only when the verifier classed the
                       row `org_label_anchor` (the org's distinctive name is on the track's ℗/©/label
                       line), the account holds a processed claim on the org profile and no
                       request-level guard blocked it. The line is a catalog read at read time,
                       not a same-run capture, and the record says so.

The tray's ruling id travels as METADATA only. The admitting values are the capture ids and reads,
the ISRCs the catalog holds for the track, and the verifier's verdict.

Record shape: docs/credit-verification/dsp-anchor-record.md (schema `dsp-anchor/1`).
"""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timedelta, timezone
from typing import Any

from . import VERSION, rules

SCHEMA = "dsp-anchor/1"
KIND_DSP = "dsp_anchor"
KIND_LABEL = "dsp_label_line"
WRITER = "credit-dsp-verify (credit-decider)"
# An anchor stands on a capture at most this old when the record is built (same-run: the capture
# job built the verdict from its own capture request; a record is refused past this age).
MAX_CAPTURE_AGE = timedelta(hours=24)


class AnchorRefused(ValueError):
    """The verifier's evidence does not support an anchor record for this row."""


def _ts(v: Any) -> datetime | None:
    if not isinstance(v, str) or not v:
        return None
    try:
        t = datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def canonical(record: dict[str, Any]) -> str:
    return json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False, default=str)


def record_sha256(record: dict[str, Any]) -> str:
    body = {k: v for k, v in record.items() if k != "record_sha256"}
    return hashlib.sha256(canonical(body).encode()).hexdigest()


def _holders(reading: dict[str, Any]) -> list[dict[str, Any]]:
    out = []
    for c in reading.get("credited_in_family") or []:
        if not isinstance(c, (list, tuple)) or len(c) < 3:
            continue
        out.append({"name": c[0], "credit": c[1], "is_claimant_linked_id": bool(c[2]),
                    "raw_id": c[3] if len(c) > 3 else None,
                    "catalog_profile_id": c[4] if len(c) > 4 else None})
    return out


def _source_block(source: str, reading: dict[str, Any]) -> dict[str, Any]:
    return {"source": source, "state": reading.get("state"), "helper_verdict": reading.get("helper_verdict"),
            "helper_reason": reading.get("helper_reason"), "complete_snapshot": reading.get("complete_snapshot"),
            "captured_at": reading.get("captured_at"), "capture_ids": list(reading.get("capture_ids") or []),
            "recordings": list(reading.get("recordings") or []), "role_holders": _holders(reading)}


def _base(packet: dict[str, Any], verdict: dict[str, Any], kind: str, ruling_id: str | None,
          now: datetime) -> dict[str, Any]:
    cap = packet.get("capture") or {}
    return {
        "schema": SCHEMA, "kind": kind,
        "request_id": packet.get("request_id"), "user_id": packet.get("user_id"),
        "profile_id": packet.get("profile_id"), "track_id": packet.get("track_id"),
        # Admitting identity of the recording: the ISRCs the CATALOG holds for the track's DSP
        # recordings (read by the capture job), never the request's own metadata.
        "isrcs": list(packet.get("isrcs") or []),
        "capture_request_id": cap.get("request_id"), "capture_requested_at": cap.get("requested_at"),
        "capture_read_at": cap.get("read_at"),
        "verifier": {"version": VERSION, "verdict": verdict.get("verdict"),
                     "reason_class": verdict.get("reason_class"), "reason": verdict.get("reason"),
                     "confidence": verdict.get("confidence"), "blockers": verdict.get("blockers") or []},
        "gate": packet.get("gate"), "flags": packet.get("flags"), "popularity": packet.get("popularity"),
        "written_by": WRITER, "built_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        # Metadata only: who ruled the tray. It is never the admitting value.
        "metadata": {"ruling_id": ruling_id},
    }


def _agrees(fresh: dict[str, Any], stored: dict[str, Any]) -> None:
    """The stored verdict must equal the one recomputed from its packet on every field a record
    stands on (QA @b6159bd: a stored DECLINE with an org_label_anchor class minted a record)."""
    for k in ("verdict", "reason_class"):
        if stored.get(k) != fresh.get(k):
            raise AnchorRefused(f"stored verdict does not match its packet ({k}: {stored.get(k)!r} vs {fresh.get(k)!r})")
    if sorted(stored.get("approve_roles") or []) != sorted(fresh.get("approve_roles") or []):
        raise AnchorRefused("stored verdict does not match its packet (approve_roles differ)")


def _fresh_enough(packet: dict[str, Any], now: datetime) -> None:
    req_at = _ts((packet.get("capture") or {}).get("requested_at"))
    if req_at is None:
        raise AnchorRefused("no capture request on the packet: nothing server-captured to anchor on")
    if now - req_at > MAX_CAPTURE_AGE:
        raise AnchorRefused(f"capture requested {req_at.isoformat()} is older than {MAX_CAPTURE_AGE}; re-capture")


def build_dsp_anchor(packet: dict[str, Any], verdict: dict[str, Any], *, ruling_id: str | None = None,
                     now: datetime | None = None) -> dict[str, Any]:
    """The dsp_anchor record, or AnchorRefused. The verdict is RE-COMPUTED from the packet here, so a
    stored verdict that drifted from its packet (or a hand-edited one) can never mint a record."""
    now = now or datetime.now(timezone.utc)
    fresh = rules.verify(packet).as_dict()
    if fresh["verdict"] != rules.APPROVE or verdict.get("verdict") != rules.APPROVE:
        raise AnchorRefused(f"verifier verdict is {fresh['verdict']} ({fresh['reason_class']}), not APPROVE")
    _agrees(fresh, verdict)
    _fresh_enough(packet, now)
    if not packet.get("isrcs"):
        raise AnchorRefused("the catalog holds no ISRC for the track's DSP recordings: nothing to bind the anchor to")
    roles = {}
    for role in fresh["approve_roles"]:
        srcs = ((((packet.get("capture") or {}).get("roles") or {}).get(role) or {}).get("sources") or {})
        blocks = [_source_block(s, srcs.get(s) or {}) for s in rules.SOURCES]
        both = all(b["state"] == "CAPTURED" and any(h["is_claimant_linked_id"] for h in b["role_holders"])
                   for b in blocks)
        if not both:                      # rules said both; the record must show it, or no record
            raise AnchorRefused(f"{role}: the capture blocks do not show both DSPs crediting the linked id")
        roles[role] = {"both_read": True, "sources": blocks}
    rec = _base(packet, fresh, KIND_DSP, ruling_id, now)
    rec.update(roles=fresh["approve_roles"], role_edit_roles=fresh["role_edit_roles"], role_evidence=roles,
               both_read=True,
               captured_at=max(b["captured_at"] for r in roles.values() for b in r["sources"] if b["captured_at"]))
    rec["record_sha256"] = record_sha256(rec)
    return rec


def build_label_anchor(packet: dict[str, Any], verdict: dict[str, Any], *, ruling_id: str | None = None,
                       now: datetime | None = None) -> dict[str, Any]:
    """The dsp_label_line record for an org credit, or AnchorRefused."""
    now = now or datetime.now(timezone.utc)
    fresh = rules.verify(packet).as_dict()
    org_roles = [r for r in fresh["roles"] if r["kind"] == "org"]
    if not org_roles or len(org_roles) != len(fresh["roles"]):
        raise AnchorRefused("not an organization-only credit request")
    if fresh["reason_class"] != "org_label_anchor" or verdict.get("reason_class") != "org_label_anchor":
        raise AnchorRefused(f"verifier class is {fresh['reason_class']}, not org_label_anchor")
    _agrees(fresh, verdict)
    if packet.get("profile_type") != "organization":
        raise AnchorRefused("the claimed profile is not an organization")
    if packet.get("org_claim_processed") is not True:
        raise AnchorRefused("the account holds no processed claim on the org profile")
    if fresh["blockers"]:
        raise AnchorRefused("request-level guards block it: " + "; ".join(fresh["blockers"])[:300])
    _fresh_enough(packet, now)
    facts = packet.get("recording_facts") or {}
    if facts.get("error") or not packet.get("isrcs"):
        raise AnchorRefused("catalog recording facts unreadable or no ISRC")
    status, hits = rules.org_string_match(str(packet.get("profile_name") or ""), facts.get("label_lines"))
    if status != "match":
        raise AnchorRefused(f"the org name is not on the catalog's DSP label lines ({status})")
    rec = _base(packet, fresh, KIND_LABEL, ruling_id, now)
    rec.update(roles=[r["role"] for r in org_roles], org_name=packet.get("profile_name"),
               label_lines=[x for x in facts.get("label_lines") or [] if x.get("string") in hits],
               label_lines_read_at=facts.get("read_at"), label_lines_fresh=bool(facts.get("label_lines_fresh")),
               both_read=False)
    rec["record_sha256"] = record_sha256(rec)
    return rec


def build(packet: dict[str, Any], verdict: dict[str, Any], **kw: Any) -> dict[str, Any]:
    """dsp_anchor for a person credit, dsp_label_line for an org credit."""
    if verdict.get("reason_class") == "org_label_anchor":
        return build_label_anchor(packet, verdict, **kw)
    return build_dsp_anchor(packet, verdict, **kw)
