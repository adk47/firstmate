"""The reader's trays for a named human (proof-loop lead [key=proof-loop-plan-1027] §1 DECIDE).

Agents never approve or reject; Jan does, from his own session. This module only SORTS the
reader's latest outcomes into the tray Jan works from, plus the per-need queue for h2's
(locked) ask campaign. It writes the two files it is asked to and nothing else: no status
write, no hold, no message.

  APPROVE (Jan)        `verified` AND a same-run Spotify+Tidal anchor (xc_dsp positive with a
                       fresh capture requested by the run, D5b) AND account_gate allow. A
                       `verified` row missing either is listed as not approvable, with why.
  FRAUD DENY           `forged_positive` (two independent fraud signal families, captain-1028-213x):
  (Fable -> t01b)      listed with both signals; the deny happens ONLY for a document Fable confirms
                       (ruling forged-<sha8>, `forged_tray`), through t01b's executor. Never here.
  HOLD                 `forged` (one signal) / `contradicted`: fraud-lens-monitor-f1 holds the account
  (f1 + Jan)           through the gate (a hold is not a verdict) - anything short of positive is a
                       hold, never a deny; the FIRST 20 per outcome are confirmed by a named human.
  NEED QUEUE (h2)      `unverifiable` with a `need` code: {user_id, request_id, need, track, role,
                       issuer, received_at}, one line per request and role.
  RETRY                `unknown`: counted, retried by the reader, never in a tray.
"""

from __future__ import annotations

import json
import re
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
    fraud_deny: list[dict[str, Any]] = field(default_factory=list)
    need: list[dict[str, Any]] = field(default_factory=list)
    retry: int = 0
    awaiting_reread: int = 0


REASON_CODE = "fraud_document"
# A ruling is a COMPLETE STANDALONE LINE, nothing before it and nothing after it (QA #1470 Critical: an
# unanchored match read (or an indented / code-block line) "Do NOT use ruling: forged-deadbeef confirm" or a quoted "> ruling: ..." as a confirm).
_RULING = re.compile(r"ruling:[ \t]*(forged-[0-9a-f]{8})[ \t]+(confirm|not)[ \t]*", re.I)
_FENCE = re.compile(r"^[ \t]*(```|~~~)")


def ruling_id(proof_id: str) -> str:
    return f"forged-{proof_id[:8].lower()}"


def sig_text(e: dict[str, Any]) -> str:
    where = []
    if e.get("fields"):
        where.append("field " + "/".join(e["fields"]))
    if e.get("page") is not None:
        where.append(f"page {e['page']}")
    if e.get("region"):
        where.append("region [" + ", ".join(f"{float(v):.0f}" for v in e["region"]) + "]")
    return f"{e['family']}: `{e['id'].split('@')[0]}`" + (f" ({'; '.join(where)})" if where else "")


def signals_text(sigs: Any) -> str:
    if isinstance(sigs, dict):                       # an older row: {family: [ids]}
        return "; ".join(f"{k}: {', '.join(v)}" for k, v in sorted(sigs.items()))
    return "; ".join(sig_text(e) for e in (sigs or []))


def parse_rulings(text: str) -> dict[str, str]:
    """Fable's lines `ruling: forged-<sha8> confirm|not` -> {ruling id: confirm|not}; the last line wins. Only a
    line that is exactly that counts: a quoted, negated, bulleted or embedded mention is never a ruling."""
    out: dict[str, str] = {}
    fenced = False
    for line in (text or "").replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if _FENCE.match(line):
            fenced = not fenced          # an example inside a fenced block is never a ruling (QA #1470)
            continue
        m = None if fenced else _RULING.fullmatch(line)
        if m:
            out[m.group(1).lower()] = m.group(2).lower()
    return out


def _rows(store: Any, outcome: str) -> list[Any]:
    return [r for r in store.latest_outcomes() if r["outcome"] == outcome]


def forged_tray(store: Any, *, intake_of: Callable[[str], dict[str, Any]], rulings: dict[str, str],
                also: list[Any] = ()) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """(deny rows, short-of-positive rows). One deny row per `forged_positive` DOCUMENT for Fable's
    ruling and t01b's executor (plan §d): `executable` only when its ruling is `confirm` AND the stored
    pair still meets the rule (gate.positive_pair over the quoted signals: two families, not one edit,
    tamper on a claim field when paired with a template). The action is always `reject`, reason code
    `fraud_document`, on exactly the requests the document was read against. Short-of-positive rows
    (`forged` with one signal, from this store and the read-only `also` stores, e.g. the 961-document
    backfill) are listed for the record and are NEVER executable: anything short of positive is a hold.
    Nothing is written here."""
    from .gate import CLAIM_FIELDS, positive_pair
    docs: dict[str, dict[str, Any]] = {}
    for r in _rows(store, "forged_positive"):
        detail = _detail(r)
        key = r["intake_id"] or r["proof_id"]
        d = docs.setdefault(key, {"ruling_id": ruling_id(r["proof_id"]), "proof_id": r["proof_id"],
                                  "intake_id": r["intake_id"], "user_id": r["user_id"],
                                  "conversation": r["source_ref"], "fraud_signals": detail.get("fraud_signals") or [],
                                  "fraud_pair": detail.get("fraud_pair") or [],
                                  "claim_fields": detail.get("claim_fields") or [], "requests": []})
        d["requests"].append({"request_id": r["request_id"], "role": r["role"], "outcome_id": r["id"],
                              "covers": bool(detail.get("covers"))})
    deny = []
    # A confirm covers ONE document (proof-loop lead 088): a ruling id shared by two different documents
    # (an 8-hex prefix collision) is ambiguous and makes neither executable.
    proofs_of: dict[str, set[str]] = {}
    for d in docs.values():
        proofs_of.setdefault(d["ruling_id"], set()).add(d["proof_id"])
    for d in sorted(docs.values(), key=lambda d: (d["ruling_id"], d["intake_id"] or "")):
        info = intake_of(d["intake_id"]) if d["intake_id"] else {}
        ruling = rulings.get(d["ruling_id"])
        sigs = d["fraud_signals"] if isinstance(d["fraud_signals"], list) else []
        pair = d["fraud_pair"] if isinstance(d["fraud_pair"], list) else []
        # The pair PRESENTED to Fable and exported to the executor must itself still pass the rule, and both of
        # its signals must be among the document's signals (QA #1470): never re-validated via another pair.
        pair_ok = len(pair) == 2 and all(e in sigs for e in pair) and \
            positive_pair(pair, d["claim_fields"] or CLAIM_FIELDS) is not None
        # every request of the row must carry the coverage mark (rows written before the rule do not: fail closed)
        covered = all(q.get("covers") for q in d["requests"])
        unique = len(proofs_of[d["ruling_id"]]) == 1
        ok = ruling == "confirm" and pair_ok and unique and covered
        deny.append({**d, "subject": info.get("subject") or "credit", "received_at": info.get("received_at"),
                     # the executor's input: the exact two signal names and the outcome rows that stand
                     "signal_ids": [e["id"] for e in d["fraud_pair"]],
                     "outcome_ids": [q["outcome_id"] for q in d["requests"]],
                     "action": "reject", "reason_code": REASON_CODE, "watch": True, "ruling": ruling,
                     "executable": ok,
                     "why_not": None if ok else
                     ("the stored signals no longer make a positive pair" if not pair_ok else
                      "written before the coverage rule (the document must name each request's track): re-read first"
                      if not covered else
                      "ruling id shared by another document: confirm per proof_id is ambiguous" if not unique else
                      "ruling 'not'" if ruling == "not" else "no Fable ruling yet")})
    short: dict[str, dict[str, Any]] = {}
    for src, st in [("live", store)] + [(f"also:{i}", x) for i, x in enumerate(also)]:
        for r in _rows(st, "forged"):
            key = r["intake_id"] or r["proof_id"]
            if key in docs or key in short:
                continue
            detail = _detail(r)
            sigs = detail.get("fraud_signals") or []
            short[key] = {"ruling_id": ruling_id(r["proof_id"]), "proof_id": r["proof_id"], "intake_id": r["intake_id"],
                          "user_id": r["user_id"], "conversation": r["source_ref"], "store": src,
                          "reason": r["reason"], "fraud_signals": sigs, "executable": False,
                          "why_not": "short of positive: " + (
                              f"{len({e['family'] for e in sigs if isinstance(e, dict)})} signal family"
                              if isinstance(sigs, list) and sigs else "no second independent signal") +
                          " - a hold, never a deny"}
    return deny, sorted(short.values(), key=lambda d: d["ruling_id"])


def _detail(r: Any) -> dict[str, Any]:
    try:
        return json.loads(r["detail_json"] or "{}")
    except ValueError:
        return {}


def forged_markdown(rows: list[dict[str, Any]], batch: int, generated_at: str,
                    short: list[dict[str, Any]] = ()) -> str:
    out = [f"# Fraud deny — doc-verify `forged_positive` b{batch} ({generated_at})", "",
           "Captain 2026-10-28 21:3xZ (captain-1028-213x): a document POSITIVELY proven forged - two independent "
           "fraud signals (R-C6, Fable [key=fraud-deny-families]: different families, not one edit, a tamper on a "
           "claim field when paired with a template) AND a Fable confirm on that document - has the credit "
           "request(s) or claim it supports rejected, reason code `fraud_document`, through t01b's executor only: "
           "standard decline line, audited, reversible, no account ban, no deletion, no extra message; the account "
           "goes on the fraud WATCH. Anything short of positive is a hold. **Fable: post `ruling: forged-<sha8> "
           "confirm|not` per row.**", "",
           f"**{len(rows)} documents / {sum(len(r['requests']) for r in rows)} requests; executable now "
           f"(confirmed): {sum(r['executable'] for r in rows)}. Short of positive (hold, listed): {len(short)}.**", ""]
    for r in rows:
        out += [f"## `{r['ruling_id']}` — user {r['user_id']} ({r['subject']}) — ruling: {r['ruling'] or 'PENDING'}", "",
                f"- document sha256 `{r['proof_id']}`, filing `{r['intake_id']}`, conversation `{r['conversation']}`, "
                f"received {r['received_at'] or '-'}"]
        out += [f"- **signal {n}** — {sig_text(e)}" for n, e in enumerate(r["fraud_pair"], 1)]
        others = [e for e in r["fraud_signals"] if isinstance(e, dict) and e not in r["fraud_pair"]]
        if others:
            out.append("- other signals: " + "; ".join(sig_text(e) for e in others))
        out += [f"- would reject ({REASON_CODE}): " + ", ".join(f"`{q['request_id']}` {q['role']}" for q in r["requests"]),
                f"- executable: **{'yes' if r['executable'] else 'no'}**" + (f" ({r['why_not']})" if r["why_not"] else ""), ""]
    if short:
        out += ["## Short of positive — HOLD, never denied (listed for the record)", ""]
        out += [f"- `{r['ruling_id']}` user {r['user_id']} ({r['store']}): {r['reason']}"
                + (f" — signals: {signals_text(r['fraud_signals'])}" if r["fraud_signals"] else "")
                + f" — {r['why_not']}" for r in short]
        out.append("")
    return "\n".join(out)


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
        elif o == "forged_positive":
            tray.fraud_deny.append({**base, "fraud_signals": detail.get("fraud_pair") or detail.get("fraud_signals") or [],
                                    "ruling_id": ruling_id(r["proof_id"])})
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
           f"FRAUD DENY (Fable confirm first) {len({a['proof'] for a in tray.fraud_deny})} documents / "
           f"HOLD forged {len(tray.decline['forged'])}, contradicted {len(tray.decline['contradicted'])} / "
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
    out += ["", "## FORGED — confirm? `forged_positive` (two independent signals; denied ONLY after the "
                "Fable ruling `forged-<sha8>` confirms the document, via `jan-forged-bN`)", ""]
    if tray.fraud_deny:
        out += ["| user | request | role | ruling id | signals | document |", "|---|---|---|---|---|---|"]
        out += [f"| {esc(a['user_id'])} | `{a['request_id']}` | {esc(a['role'])} | `{a['ruling_id']}` | "
                f"{esc(signals_text(a['fraud_signals']))} | `{esc(a['source_ref'])}` |" for a in tray.fraud_deny]
    else:
        out.append("None.")
    for o in ("forged", "contradicted"):
        out += ["", f"## HOLD — `{o}` (one signal or a DSP contradiction: fraud-lens holds through the gate; "
                    f"never denied on this; first {FIRST_HUMAN} each confirmed by a named human)", ""]
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
    if VERSION >= "dv-3":
        out += ["**`verified` before dv-3 is the real-not-proof class** (verifier-eval-v1 blind labels, 2026-10-28: "
                "116 of 140 dv-2 `verified` rows were documents that prove nothing - DSP/catalog panels, Muso UI, "
                "dashboards, chats - passed on H3 PLAUSIBLE + the Spotify/Tidal cross-check). None of them is in this "
                "tray; from dv-3 a `verified` needs the document itself to name the claimant in the role on the track "
                "AND to be a document of record.", ""]
    return "\n".join(out)
