#!/usr/bin/env python3
"""Stage-2 document verdicts as the release from the "proof on file" hold (read-only).

The decider holds every credit request whose user has ANY entry in the proof-on-file export
("proof on file: human review ... never ask again"), and the ask campaigns skip those users the
same way. Stage 2 (credit_verify/proof/stage2.py, shadow since 2026-10-20) reads the documents
on file against each held request and records one verdict per request and claimed role in the
proof store's `stage2_shadow` table. Fable's ruling of 2026-10-26 13:23Z (captain-asks-fable-r4
section H, GO 2; drain report data/verification-drain-d2/report.md section 1a) turns two of those
verdicts into a message:

  need_more    the document on file does not cover this track and role: the gap ask
               (intercom-verify-request.sh --campaign gap-ask, Fable's paragraph);
  no_document  nothing readable is on file for it: the already-approved uvn-status copy.

Every other verdict (review, reject_hold, human, undetermined, approve) stays with a human, and
a request with no verdict keeps the hold: mere entry existence is never read as "documents
covered it", and no verdict is never read as "nothing on file" (when in doubt, no ask).

A request is RELEASED to a campaign only when the latest verdict (current analyzer version) of
EVERY claimed role is that campaign's outcome. An account with any reject_hold verdict (a
document on file is likely forged) or an account-level `human` hold is never messaged.

Stdlib only and runnable as a CLI: the gate calls it as `python3 -I stage2_verdicts.py --db
<proof store> gap-credits --request-ids ...` (isolated mode, so no sibling import), and fills
the gap ask's <doc summary> from the store, never from its caller.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

PROOF_DB = os.environ.get("CREDIT_PROOF_STORE",
                          os.path.join(os.environ.get("CREDIT_VERIFY_STATE_DIR", "/var/lib/hydra-credit-verify"),
                                       "proof.sqlite"))
GAP = "need_more"
NO_DOCUMENT = "no_document"
# campaign -> the stage-2 outcome that releases a request to it
RELEASES = {"gap-ask": GAP, "uvn-status": NO_DOCUMENT}
ACCOUNT_HOLD_PREFIX = "account hold"
# The document kinds stage 2 records (credit_verify/proof/stage2.py KIND_LABEL); anything else is
# shown as a plain "document". The gate renders the words, this module only passes the key.
DOC_KINDS = ("split_sheet", "contract", "invoice", "letter_of_direction", "pro_portal", "distributor_portal",
             "dsp_for_artists", "daw_session", "catalog_page")
CHUNK = 400


class Stage2Error(RuntimeError):
    pass


def analyzer_version() -> str:
    """credit_verify.proof.FORENSICS_VERSION, read from the deployed tree (this file runs under
    `python3 -I`, which cannot import its siblings). Verdicts of another version are stale: a new
    analyzer re-judges every request (stage2.judged)."""
    src = Path(__file__).resolve().parents[1] / "credit_verify" / "proof" / "__init__.py"
    try:
        m = re.search(r'^FORENSICS_VERSION\s*=\s*"([^"]+)"', src.read_text(encoding="utf-8"), re.M)
    except OSError as exc:
        raise Stage2Error(f"cannot read the analyzer version from {src}: {exc}") from exc
    if not m:
        raise Stage2Error(f"no FORENSICS_VERSION in {src}")
    return m.group(1)


@dataclass(frozen=True)
class Verdict:
    request_id: str
    role: str
    user_id: int | None
    paid: int | None
    outcome: str
    reason: str
    doc_kind: str
    proof_id: str
    lists: tuple[str, ...]      # held catalog titles the best document names (never document text)
    judged_at: str


def _connect(path: str | None) -> sqlite3.Connection:
    p = path or PROOF_DB
    if not os.path.exists(p):
        raise Stage2Error(f"the proof store {p} is missing")
    try:
        db = sqlite3.connect(f"file:{p}?mode=ro", uri=True, timeout=30)
        db.row_factory = sqlite3.Row
        if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='stage2_shadow'").fetchone() is None:
            raise Stage2Error(f"the proof store {p} has no stage2_shadow table")
        return db
    except sqlite3.Error as exc:
        raise Stage2Error(f"the proof store {p} is unreadable: {exc}") from exc


def _lists(detail_json: str | None, proof_id: str | None) -> tuple[str, ...]:
    """The held titles the verdict's best document lists (stage 2 stores catalog titles there)."""
    try:
        docs = json.loads(detail_json or "[]")
    except ValueError:
        return ()
    for d in docs if isinstance(docs, list) else []:
        if isinstance(d, dict) and proof_id and d.get("proof_id") == proof_id:
            return tuple(str(t) for t in (d.get("lists") or []) if isinstance(t, str) and t.strip())
    return ()


LATEST = ("SELECT s.* FROM stage2_shadow s JOIN (SELECT request_id, role, MAX(id) id FROM stage2_shadow "
          "WHERE analyzer_version = ? {where} GROUP BY request_id, role) l USING(id)")


def load(path: str | None = None, *, request_ids: Iterable[str] | None = None,
         user_ids: Iterable[int] | None = None, version: str | None = None) -> dict[str, dict[str, Verdict]]:
    """{request id (lowercase): {role: latest Verdict}} under the current analyzer version, for
    the given request ids / user ids (all when neither is given). Stage2Error when the store
    cannot be read: callers then release nothing."""
    version = version or analyzer_version()
    db = _connect(path)
    out: dict[str, dict[str, Verdict]] = {}
    try:
        def take(where: str, params: list[Any]) -> None:
            for r in db.execute(LATEST.format(where=where), [version, *params]):
                rid = str(r["request_id"]).strip().lower()
                out.setdefault(rid, {})[str(r["role"])] = Verdict(
                    request_id=rid, role=str(r["role"]), user_id=r["user_id"], paid=r["paid"],
                    outcome=str(r["outcome"]), reason=str(r["reason"] or ""), doc_kind=str(r["doc_kind"] or ""),
                    proof_id=str(r["proof_id"] or ""), lists=_lists(r["detail_json"], r["proof_id"]),
                    judged_at=str(r["judged_at"] or ""))
        if request_ids is None and user_ids is None:
            take("", [])
        for key, col in ((request_ids, "request_id"), (user_ids, "user_id")):
            if key is None:
                continue
            vals = list(dict.fromkeys(str(x).strip().lower() if col == "request_id" else int(x) for x in key))
            for i in range(0, len(vals), CHUNK):
                chunk = vals[i:i + CHUNK]
                take(f"AND {'lower(request_id)' if col == 'request_id' else 'user_id'} IN ({','.join('?' * len(chunk))})",
                     chunk)
    except sqlite3.Error as exc:
        raise Stage2Error(f"the proof store is unreadable: {exc}") from exc
    finally:
        db.close()
    return out


def outcome_of(roles: dict[str, Verdict] | None) -> str:
    """The request's outcome when every role agrees, '' when it has none, 'mixed' otherwise."""
    if not roles:
        return ""
    got = {v.outcome for v in roles.values()}
    return got.pop() if len(got) == 1 else "mixed"


def account_held(verdicts: Iterable[Verdict]) -> bool:
    """An account stage 2 holds as a whole: any reject_hold (a likely-forged document), or a
    `human` verdict that is an account hold."""
    return any(v.outcome == "reject_hold" or (v.outcome == "human" and v.reason.startswith(ACCOUNT_HOLD_PREFIX))
               for v in verdicts)


def held_accounts(verdicts: dict[str, dict[str, Verdict]]) -> set[int]:
    by: dict[int, list[Verdict]] = {}
    for roles in verdicts.values():
        for v in roles.values():
            if v.user_id is not None:
                by.setdefault(int(v.user_id), []).append(v)
    return {u for u, vs in by.items() if account_held(vs)}


def released(verdicts: dict[str, dict[str, Verdict]], outcome: str) -> set[str]:
    """Request ids (lowercase) whose every role's latest verdict is `outcome`, on accounts that
    are not held."""
    held = held_accounts(verdicts)
    return {rid for rid, roles in verdicts.items() if outcome_of(roles) == outcome
            and not any(v.user_id is not None and int(v.user_id) in held for v in roles.values())}


def population(outcome: str, *, path: str | None = None, version: str | None = None) -> list[dict[str, Any]]:
    """The users a campaign may reach from the store, in the uvn_status list shape:
    [{user_id, paid, skip: None, request_ids}] with only the released request ids, paid users
    first, then by user id (a stable, live rebuild of the staged id list)."""
    verdicts = load(path, version=version)
    rel = released(verdicts, outcome)
    users: dict[int, dict[str, Any]] = {}
    for rid in sorted(rel):
        roles = verdicts[rid]
        v = next(iter(roles.values()))
        if v.user_id is None:
            continue
        u = users.setdefault(int(v.user_id), {"user_id": int(v.user_id), "paid": False, "skip": None,
                                              "request_ids": []})
        u["paid"] = u["paid"] or any(x.paid == 1 for x in roles.values())
        u["request_ids"].append(rid)
    return sorted(users.values(), key=lambda u: (not u["paid"], u["user_id"]))


def gap_credits(request_ids: list[str], *, outcome: str = GAP, user_id: str = "", path: str | None = None,
                version: str | None = None) -> dict[str, Any]:
    """The gate's check for one note: eligible only when every request id is released to
    `outcome`, belongs to `user_id`, and its account is not held. `credits` carries, per request,
    the roles and the best document's kind, proof id and listed titles (for <doc summary>)."""
    ids = [str(r).strip().lower() for r in request_ids if str(r).strip()]
    try:
        verdicts = load(path, request_ids=ids, version=version)
        account = load(path, user_ids=[int(user_id)], version=version) if str(user_id).strip().isdigit() else {}
    except Stage2Error as exc:
        return {"eligible": False, "reason": f"stage-2 verdicts unreadable: {exc}", "credits": {}}
    if not str(user_id).strip().isdigit():
        return {"eligible": False, "reason": "no Muso user id to match the stage-2 verdicts to", "credits": {}}
    if account_held([v for roles in account.values() for v in roles.values()]):
        return {"eligible": False, "reason": "stage 2 holds this account (a likely-forged document or an account hold): "
                                             "a human looks, nothing is sent", "credits": {}}
    bad, credits = [], {}
    for rid in ids:
        roles = verdicts.get(rid)
        got = outcome_of(roles)
        owners = {int(v.user_id) for v in (roles or {}).values() if v.user_id is not None}
        if got != outcome:
            bad.append(f"{rid} ({got or 'no verdict'})")
            continue
        if owners != {int(user_id)}:
            bad.append(f"{rid} (verdict is for another account)")
            continue
        best = sorted(roles.values(), key=lambda v: (v.doc_kind not in DOC_KINDS, v.role.casefold()))[0]
        credits[rid] = {"roles": sorted(roles), "doc_kind": best.doc_kind if best.doc_kind in DOC_KINDS else "",
                        "proof_id": best.proof_id, "lists": list(best.lists)[:10]}
    if bad:
        return {"eligible": False, "credits": {},
                "reason": f"not every credit's latest stage-2 verdict is {outcome}: " + ", ".join(bad[:5])}
    return {"eligible": True, "reason": "", "credits": credits}


def _main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="stage-2 verdict reads for the verify gate (JSON on stdout, read-only)")
    p.add_argument("--db", default=PROOF_DB)
    sub = p.add_subparsers(dest="op", required=True)
    g = sub.add_parser("gap-credits")
    g.add_argument("--request-ids", required=True)
    g.add_argument("--user-id", required=True)
    g.add_argument("--outcome", choices=sorted(set(RELEASES.values())), default=GAP)
    a = p.parse_args(argv)
    print(json.dumps(gap_credits([x for x in a.request_ids.split(",") if x], outcome=a.outcome, user_id=a.user_id,
                                 path=a.db)))
    return 0


if __name__ == "__main__":
    sys.exit(_main())
