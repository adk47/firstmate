"""The reader's trays for a named human (proof-loop lead [key=proof-loop-plan-1027] §1 DECIDE).

Agents never approve or reject; Jan does, from his own session. This module only SORTS the
reader's latest outcomes into the tray Jan works from, plus the per-need queue for h2's
(locked) ask campaign. It writes the two files it is asked to and nothing else: no status
write, no hold, no message.

  APPROVE (Jan)        `verified` AND a same-run Spotify+Tidal anchor (xc_dsp positive with a
                       fresh capture requested by the run, D5b) AND account_gate allow. A
                       `verified` row missing either is listed as not approvable, with why.
  HOLD + DECLINE       `forged` / `contradicted`: fraud-lens-monitor-f1 holds the account through
  (f1 + Jan)           the gate (a hold is not a verdict); Jan declines; the FIRST 20 per outcome
                       are each confirmed by a named human before any decline.
  NEED QUEUE (h2)      `unverifiable` with a `need` code: {user_id, request_id, need, track, role,
                       issuer, received_at}, one line per request and role.
  RETRY                `unknown`: counted, retried by the reader, never in a tray.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Callable

FIRST_HUMAN = 20

Gate = Callable[[int], tuple[bool, str]]           # user id -> (allow, why)
Tracks = Callable[[list[str]], dict[str, str]]     # request ids -> track title


@dataclass
class Tray:
    approve: list[dict[str, Any]] = field(default_factory=list)
    not_approvable: list[dict[str, Any]] = field(default_factory=list)
    decline: dict[str, list[dict[str, Any]]] = field(default_factory=lambda: {"forged": [], "contradicted": []})
    need: list[dict[str, Any]] = field(default_factory=list)
    retry: int = 0
    awaiting_reread: int = 0


def _dsp_anchor(store: Any, proof_id: str, key: str) -> tuple[bool, str]:
    row = store.db.execute("SELECT status, detail_json FROM dv_steps WHERE proof_id=? AND request_id=? AND "
                           "step='xc_dsp' ORDER BY id DESC LIMIT 1", (proof_id, key)).fetchone()
    if row is None:
        return False, "no Spotify/Tidal check recorded"
    status, detail = row[0], json.loads(row[1] or "{}")
    if status != "positive":
        return False, f"Spotify/Tidal check {status}"
    if not detail.get("fresh_since"):
        return False, "Spotify/Tidal credit is from Muso's stored capture, not a same-run capture (D5b not wired)"
    anchor = detail.get("fresh_anchor") or {}
    missing = [d for d in ("spotify", "tidal") if anchor.get(d) is not True]
    if missing:
        return False, f"no fresh {' or '.join(missing)} capture crediting the claimant since {detail['fresh_since']}"
    return True, f"Spotify and Tidal both credit the claimant on captures since {detail['fresh_since']}"


def build(store: Any, *, gate: Gate, tracks: Tracks) -> Tray:
    tray = Tray()
    rows = store.latest_outcomes()
    titles = tracks(sorted({r["request_id"] for r in rows})) if rows else {}
    for r in rows:
        key = f"{r['request_id']}#{r['role']}"
        try:
            detail = json.loads(r["detail_json"] or "{}")
        except ValueError:                      # a detail cut at 20k characters: the row still sorts
            detail = {}
        base = {"user_id": r["user_id"], "request_id": r["request_id"], "role": r["role"],
                "track": titles.get(r["request_id"]), "proof": r["proof_id"][:12], "intake_id": r["intake_id"],
                "source_ref": r["source_ref"], "issuer": (detail.get("issuer") or {}).get("name"),
                "received_at": detail.get("received_at"), "reason": r["reason"]}
        o = r["outcome"]
        if o == "verified":
            anchored, why_a = _dsp_anchor(store, r["proof_id"], key)
            allow, why_g = gate(r["user_id"]) if r["user_id"] else (False, "no account id")
            if anchored and allow:
                tray.approve.append({**base, "anchor": why_a, "gate": why_g})
            else:
                tray.not_approvable.append({**base, "why": "; ".join(w for ok, w in ((anchored, why_a), (allow, why_g))
                                                                     if not ok)})
        elif o in ("forged", "contradicted"):
            lst = tray.decline[o]
            lst.append({**base, "first_20_human": len(lst) < FIRST_HUMAN})
        elif o == "unverifiable" and r["need"]:
            tray.need.append({"user_id": r["user_id"], "request_id": r["request_id"], "need": r["need"],
                              "track": titles.get(r["request_id"]), "role": r["role"], "issuer": base["issuer"],
                              "received_at": base["received_at"]})
        elif o == "unknown":
            tray.retry += 1
    tray.awaiting_reread = store.awaiting_reread() if hasattr(store, "awaiting_reread") else 0
    return tray


def markdown(tray: Tray, batch: int, generated_at: str) -> str:
    def esc(v: Any) -> str:
        return str(v if v is not None else "-").replace("|", "/")[:160]
    out = [f"# Jan — doc-verify tray b{batch} ({generated_at})", "",
           "Sorted from the reader's latest outcomes (`doc-verify.sqlite`). **Nothing here has been written to "
           "core**: approvals and declines are Jan's, from his own session. Rule: proof-loop lead "
           "`[key=proof-loop-plan-1027]` §1 DECIDE; registry approval L11a still required for any automated path.",
           "", f"**Totals: APPROVE {len(tray.approve)} / not approvable (verified) {len(tray.not_approvable)} / "
           f"HOLD+DECLINE forged {len(tray.decline['forged'])}, contradicted {len(tray.decline['contradicted'])} / "
           f"NEED queue {len(tray.need)} / retry {tray.retry}.**", "",
           "## APPROVE — `verified` + same-run Spotify/Tidal anchor + account gate allow", ""]
    if tray.approve:
        out += ["| user | request | track | role | anchor | gate | document |", "|---|---|---|---|---|---|---|"]
        out += [f"| {esc(a['user_id'])} | `{a['request_id']}` | {esc(a['track'])} | {esc(a['role'])} | "
                f"{esc(a['anchor'])} | {esc(a['gate'])} | `{esc(a['source_ref'])}` |" for a in tray.approve]
    else:
        out.append("None.")
    out += ["", "## `verified` but NOT approvable (why)", ""]
    if tray.not_approvable:
        out += ["| user | request | track | role | why | document |", "|---|---|---|---|---|---|"]
        out += [f"| {esc(a['user_id'])} | `{a['request_id']}` | {esc(a['track'])} | {esc(a['role'])} | "
                f"{esc(a['why'])} | `{esc(a['source_ref'])}` |" for a in tray.not_approvable]
    else:
        out.append("None.")
    for o in ("forged", "contradicted"):
        out += ["", f"## HOLD + DECLINE — `{o}` (fraud-lens holds through the gate; Jan declines; first "
                    f"{FIRST_HUMAN} each confirmed by a named human)", ""]
        if tray.decline[o]:
            out += ["| user | request | track | role | first 20 | reason | document |", "|---|---|---|---|---|---|---|"]
            out += [f"| {esc(a['user_id'])} | `{a['request_id']}` | {esc(a['track'])} | {esc(a['role'])} | "
                    f"{'yes' if a['first_20_human'] else 'no'} | {esc(a['reason'])} | `{esc(a['source_ref'])}` |"
                    for a in tray.decline[o]]
        else:
            out.append("None.")
    out += ["", f"## NEED queue for h2 ({len(tray.need)} rows; the JSON file carries every row)", "",
            "| need | rows |", "|---|---|"]
    counts: dict[str, int] = {}
    for n in tray.need:
        counts[n["need"]] = counts.get(n["need"], 0) + 1
    out += [f"| `{k}` | {v} |" for k, v in sorted(counts.items())] or ["| - | 0 |"]
    out += ["", f"`unknown` (tooling, retried by the reader, never asked): {tray.retry}.", ""]
    from . import VERSION
    out += [f"Rule version `{VERSION}`. {tray.awaiting_reread} document(s) read under an older rule version await "
            "the reader's re-read; their old outcomes (e.g. a `forged` from a misread sender address) are shadow "
            "and appear in no section of this tray.", ""]
    return "\n".join(out)
