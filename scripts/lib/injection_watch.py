"""Prompt-injection watch, Python side (caroline-guard-g1; Fable security-arch-fable-s1 handoff-contract §6:
"flag + audit, never act").

The same rule set as plugins/intercom/src/injection-watch.ts (Caroline's Intercom inbound), applied to the text the
TypeScript side never sees: support@ email bodies and uploaded-proof text extracts (doc-verify reads them with a
model, so they are a prompt-injection surface). scripts/tests/injection-watch-parity.bats dumps both rule sets and
fails on any difference, so the two copies cannot drift.

DETECTION ONLY. ``record()`` never raises, never returns anything a caller may branch a decision on except for
logging, and never changes the text; callers keep their result byte-for-byte. Hits go to the shared ledger
(LEDGER_PATH, JSONL, 0600). ``digest()`` summarises the ledger (both writers) for the daily report;
``watch_candidates()`` lists contacts for the fraud-lens watchlist owner to review. Nothing here writes
policies/fraud-watchlist.json: that file is the approval-gated watchlist and changes only by a reviewed PR.

Constants, no env switches (standing rule): paths and thresholds change only by a reviewed PR.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

VERSION = "iw-2026-11-01.1"   # == INJECTION_WATCH_VERSION in injection-watch.ts (parity-checked)
LEDGER_PATH = Path("/var/lib/hydra/injection-watch/ledger.jsonl")
CANDIDATES_PATH = Path("/var/lib/hydra/injection-watch/watch-candidates.json")
SOURCES = ("intercom", "support_email", "proof_extract")
ZERO_WIDTH_MIN = 3
CANDIDATE_DAYS = 7
CANDIDATE_MIN_TURNS = 2       # medium+ hit-turns from one sender in CANDIDATE_DAYS (any high counts alone)

_STAFF = "jan|aaron|nick|nicholas|artem|clio|caroline|fable|ops|admin|support|muso"

# (rule, severity, source, flags) -- the regex SOURCES are byte-identical to injection-watch.ts except where a
# PY_OVERRIDES entry says otherwise (JS matches UTF-16 surrogates, Python matches code points).
RULES: tuple[tuple[str, str, str, str], ...] = (
    ("ignore_instructions", "high",
     r"\b(?:ignore|disregard|forget|override|bypass|skip)\b[^.\n]{0,40}\b(?:previous|prior|above|earlier|all|your|the|any|these|those)\b[^.\n]{0,25}\b(?:instructions?|prompts?|rules?|guidelines?|directives?|policies|polic(?:y)|system\s+message|guardrails?)\b",
     "i"),
    ("new_persona", "high",
     r"\bfrom\s+now\s+on,?\s+you\s+(?:are|will|must)\b|\byou\s+are\s+now\s+(?:a|an|in|the|my)\b|\bnew\s+(?:system\s+)?instructions?\s*:|\bpretend\s+(?:to\s+be|you\s+are)\b|\bact\s+as\s+(?:an?\s+)?(?:admin|administrator|developer|system|root|operator|superuser|unrestricted)\b",
     "i"),
    ("jailbreak_mode", "high",
     r"\b(?:developer|god|admin|debug|DAN|jailbreak|maintenance|sudo|unrestricted)\s+mode\b|\bdo\s+anything\s+now\b",
     "i"),
    ("prompt_extraction", "high",
     r"\b(?:reveal|print|show|repeat|output|dump|list|display|tell\s+me)\b[^.\n]{0,30}\b(?:system\s+prompt|your\s+(?:instructions|prompt|rules|tools|guidelines|configuration|config)|hidden\s+instructions|initial\s+prompt|raw\s+json|tool\s+list|available\s+tools)\b",
     "i"),
    ("role_marker", "high",
     r"(?:^|>)\s*(?:system|assistant|developer|tool)\s*:|<\|?(?:im_start|im_end|system|endoftext|eot_id|start_header_id)\|?>|\[/?(?:SYSTEM|INST|SYS|CONVERSATION_CONTEXT|CUSTOMER_MESSAGE|KNOWLEDGE_BASE|ATTACHMENT_STATUS|ROUTING|ADMIN)\]|</?(?:system|instructions?|admin|tool_call)>|#{2,}\s*(?:system|instructions?)\b",
     "im"),
    ("staff_impersonation", "medium",
     r"\b(?:it'?s|this\s+is|i\s+am|i'm|from|signed|regards,?|on\s+behalf\s+of)\s+(?:jan|aaron|nick|nicholas|artem|clio)\b|\b(?:jan|aaron|nick)\s+(?:said|told|approved|authori[sz]ed|ok'?d|okayed|asked\s+you|confirmed|wants\s+you)\b|\b(?:muso|the)\s+(?:ops|operations|admin|support|verification|engineering|management)\s+team\s+(?:said|told|approved|authori[sz]ed|asked\s+you|confirmed|instructed)\b|\bi\s*(?:'m|am)\s+(?:a|an|the)?\s*(?:muso\s+)?(?:admin|administrator|employee|staff\s+member|developer|engineer|moderator)\b|\bfrom:\s*[^\s@]+@muso\.ai\b",
     "i"),
    ("approval_command", "medium",
     r"\b(?:approved|verified|authori[sz]ed|confirmed)\s+by\s+(?:" + _STAFF + r"|the\s+team|management)\b|\b(?:auto-?approve|force[- ]approve|mark\s+(?:it|this|them|these|my\s+\w+)\s+as\s+(?:approved|verified))\b|\bapprove\b[^.\n]{0,40}\b(?:without|skip|bypass|override)\b|\byou\s+(?:are|have\s+been)\s+(?:authori[sz]ed|allowed|permitted|cleared)\s+to\s+(?:approve|verify|merge|delete|remove|refund)\b|\bAPPROVED\b",
     ""),
    ("tool_name", "medium",
     r"""\b(?:credits_verify|profiles_consolidate|profiles_claim_self|credit_verification_check|profile_claim_status|profile_credits_status|dedupe_check|remove_credits|credit_status_lookup|document_intake|merge_request_intake|credit_trust_handoff|merge_intake|proof_on_file|order_lookup|order_address_update|cancel_subscription|retention_offer_apply|founding_buyback_link|create_ticket|sessions_list|sessions_history|tool_call|function_call)\b|tools/invoke|/hooks/agent|"arguments"\s*:""",
     "i"),
    ("hidden_unicode", "high", r"[\u202A-\u202E\u2066-\u2069]|\uDB40[\uDC00-\uDC7F]", ""),
    ("hidden_markup", "medium",
     r"""<!--|display\s*:\s*none|visibility\s*:\s*hidden|font-size\s*:\s*0(?:\.\d+)?(?:px|pt|em)?\s*[;"']|color\s*:\s*(?:#fff(?:fff)?|white)\b|opacity\s*:\s*0(?:\.0+)?\s*[;"']""",
     "i"),
    ("base64_blob", "low", r"""(?:^|[\s"'(:,])[A-Za-z0-9+/]{120,}={0,2}(?=$|[\s"'),.])""", ""),
)
# Python matches code points: the Unicode tag block is U+E0000-U+E007F (JS sees it as a surrogate pair).
PY_OVERRIDES = {"hidden_unicode": r"[\u202A-\u202E\u2066-\u2069]|[\U000E0000-\U000E007F]"}
_ZERO_WIDTH = re.compile("[\u200B\u200C\u200E\u200F\u2060-\u2064\uFEFF]")


def _flags(f: str) -> int:
    return (re.I if "i" in f else 0) | (re.M if "m" in f else 0)


_COMPILED = [(name, sev, re.compile(PY_OVERRIDES.get(name, src), _flags(fl))) for name, sev, src, fl in RULES]


def _cut(s: str, n: int = 120) -> str:
    t = " ".join(s.split())
    return t if len(t) <= n else t[: n - 3] + "..."


def _decode_b64(blob: str) -> str:
    try:
        return base64.b64decode(blob.strip().lstrip("\"'(:,"), validate=False).decode("utf-8", "ignore")
    except (binascii.Error, ValueError):
        return ""


def scan(text: str) -> list[dict[str, str]]:
    """Every rule that matches, with its severity and a short excerpt. Pure."""
    t = (text or "")[:200_000]
    hits: list[dict[str, str]] = []
    for name, sev, rx in _COMPILED:
        m = rx.search(t)
        if not m:
            continue
        if name == "base64_blob":
            decoded = _decode_b64(m.group(0))
            if decoded and any(s == "high" and n != "base64_blob" and r.search(decoded) for n, s, r in _COMPILED):
                sev = "high"
        hits.append({"rule": name, "severity": sev, "excerpt": _cut(m.group(0))})
    zw = _ZERO_WIDTH.findall(t)
    if len(zw) >= ZERO_WIDTH_MIN:
        hits.append({"rule": "zero_width_run", "severity": "low", "excerpt": f"{len(zw)} zero-width chars"})
    return hits


def top_severity(hits: Iterable[dict[str, str]]) -> str | None:
    sevs = {h["severity"] for h in hits}
    for s in ("high", "medium", "low"):
        if s in sevs:
            return s
    return None


def email_sha256(email: str | None) -> str | None:
    e = (email or "").strip().lower()
    return hashlib.sha256(e.encode()).hexdigest() if "@" in e else None


def _ensure_leaf(path: Path) -> None:
    """Create only the leaf directory (0700), and only under an existing parent: never on a laptop / CI pod."""
    if not path.parent.exists() and path.parent.parent.exists():
        try:
            path.parent.mkdir(mode=0o700)
        except FileExistsError:
            pass


def append(row: dict[str, Any], ledger: Path = LEDGER_PATH) -> str | None:
    """Append one JSON row (0600, leaf dir 0700 created only under an existing parent). Never raises."""
    try:
        ledger = Path(ledger)
        _ensure_leaf(ledger)
        fd = os.open(ledger, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
        return None
    except Exception as e:  # noqa: BLE001 - detection must never break the caller
        return f"{type(e).__name__}: {e}"


def record(source: str, ref: str, text: str, *, email: str | None = None, contact_id: str | None = None,
           external_id: str | None = None, ledger: Path = LEDGER_PATH, now: datetime | None = None) -> list[dict[str, str]]:
    """Scan ``text`` and append a ledger row when anything matched. Returns the hits (for logging only).
    Never raises; the caller's own result must not depend on this call."""
    try:
        if source not in SOURCES:
            source = "proof_extract" if source.startswith("proof") else "support_email"
        hits = scan(text)
        sev = top_severity(hits)
        if sev:
            err = append({"ts": (now or datetime.now(timezone.utc)).isoformat().replace("+00:00", "Z"),
                    "kind": "inbound_injection", "source": source, "ref": str(ref), "contact_id": contact_id,
                    "contact_role": None, "external_id": external_id, "email_sha256": email_sha256(email),
                    "turn_id": None, "text_sha256": hashlib.sha256((text or "").encode("utf-8", "replace")).hexdigest(),
                    "severity": sev, "hits": hits, "classifier": None, "version": VERSION}, ledger)
            if err:
                # Detection stays non-blocking, but a lost audit row is never silent (QA on #1628): an actionable
                # line in the caller's journal; the daily digest separately probes ledger_writable and pages.
                print(f"[injection-watch:ALERT] ledger append FAILED ({err}); {sev} hit LOST source={source} ref={ref} "
                      f"rules={','.join(h['rule'] for h in hits)} ledger={ledger}", file=sys.stderr)
        return hits
    except Exception:  # noqa: BLE001
        return []


# --- digest + watch candidates -------------------------------------------------------------------------------

def _ts(row: dict[str, Any]) -> datetime | None:
    try:
        return datetime.fromisoformat(str(row.get("ts", "")).replace("Z", "+00:00"))
    except ValueError:
        return None


def read_ledger(ledger: Path = LEDGER_PATH, *, since: datetime | None = None) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    try:
        with open(ledger, encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue
                t = _ts(r)
                if since is None or (t is not None and t >= since):
                    rows.append(r)
    except FileNotFoundError:
        return []
    return rows


def dedupe(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Collapse RETRIES of one inbound turn, never two turns (QA on #1628).

    An inbound_injection row's identity is (source, ref, turn_id) when the writer knows the turn (Intercom part id),
    else (source, ref, text_sha256): a doc-verify retry or a re-filed support@ message re-reads the same text and
    counts once, while two different messages in one conversation stay two hit-turns. A row with neither field
    (written before they existed) is never collapsed. Every other kind (output_guard, output_note,
    classifier_unavailable, classifier_health) is one real event per row and is never collapsed."""
    seen: set[tuple[Any, ...]] = set()
    out = []
    for r in rows:
        if r.get("kind") == "inbound_injection":
            ident = ("turn", r["turn_id"]) if r.get("turn_id") else (("text", r["text_sha256"]) if r.get("text_sha256") else None)
            if ident is not None:
                key = (r.get("source"), str(r.get("ref")), ident)
                if key in seen:
                    continue
                seen.add(key)
        out.append(r)
    return out


def _sender(row: dict[str, Any]) -> str | None:
    return row.get("email_sha256") or (f"contact:{row['contact_id']}" if row.get("contact_id") else None)


def watch_candidates(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Senders worth a watchlist review: any high hit, or >= CANDIDATE_MIN_TURNS medium+ hit-turns."""
    by: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for r in rows:
        if r.get("kind") == "inbound_injection" and r.get("severity") in ("high", "medium") and _sender(r):
            by[_sender(r)].append(r)
    out = []
    for key, rs in by.items():
        if not (any(r["severity"] == "high" for r in rs) or len(rs) >= CANDIDATE_MIN_TURNS):
            continue
        ts = sorted(str(r.get("ts")) for r in rs)
        out.append({"sender": key, "email_sha256": rs[0].get("email_sha256"),
                    "contact_ids": sorted({str(r["contact_id"]) for r in rs if r.get("contact_id")}),
                    "external_ids": sorted({str(r["external_id"]) for r in rs if r.get("external_id")}),
                    "turns": len(rs), "high": sum(r["severity"] == "high" for r in rs),
                    "rules": sorted({h["rule"] for r in rs for h in r.get("hits", [])}),
                    "sources": sorted({r.get("source") for r in rs}), "refs": sorted({str(r.get("ref")) for r in rs})[:20],
                    "first": ts[0], "last": ts[-1]})
    return sorted(out, key=lambda c: (-c["high"], -c["turns"], c["sender"]))


def ledger_writable(ledger: Path = LEDGER_PATH) -> str | None:
    """None when a row could be appended right now (the file is opened for append, nothing is written)."""
    try:
        ledger = Path(ledger)
        _ensure_leaf(ledger)
        if not ledger.parent.exists():
            return f"ledger directory {ledger.parent} does not exist"
        fd = os.open(ledger, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        os.close(fd)
        return None
    except Exception as e:  # noqa: BLE001
        return f"{type(e).__name__}: {e}"


def digest(ledger: Path = LEDGER_PATH, *, hours: int = 24, now: datetime | None = None) -> dict[str, Any]:
    now = now or datetime.now(timezone.utc)
    day = dedupe(read_ledger(ledger, since=now - timedelta(hours=hours)))
    week = dedupe(read_ledger(ledger, since=now - timedelta(days=CANDIDATE_DAYS)))
    inj = [r for r in day if r.get("kind") == "inbound_injection"]
    blocks = [r for r in day if r.get("kind") == "output_guard"]
    notes = [r for r in day if r.get("kind") == "output_note"]
    # Every classifier call is counted in `classifier_health` window rows (clean traffic included), so an
    # outage that recovered before the daily probe still shows here.
    # Unavailable calls are persisted one row per call (survives idle periods and restarts); the 15-min
    # `classifier_health` windows carry totals only, for the "of N calls" context.
    health = [r for r in day if r.get("kind") == "classifier_health"]
    clf_calls = sum(int(r.get("calls") or 0) for r in health)
    clf_unavailable = sum(1 for r in day if r.get("kind") == "classifier_unavailable")
    writable_err = ledger_writable(ledger)
    return {
        "window_hours": hours,
        "ledger_writable": writable_err is None,
        "ledger_error": writable_err,
        "inbound": {"turns": len(inj), "by_severity": dict(Counter(r.get("severity") for r in inj)),
                    "by_source": dict(Counter(r.get("source") for r in inj)),
                    "by_rule": dict(Counter(h["rule"] for r in inj for h in r.get("hits", [])))},
        "output_guard": {"blocked": sum(1 for r in blocks if r.get("enforced")),
                         "shadow_blocked": sum(1 for r in blocks if not r.get("enforced")),
                         "by_rule": dict(Counter(f"{f.get('family')}/{f.get('rule')}" for r in blocks for f in r.get("flags", []))),
                         "conversations": sorted({str(r.get("ref")) for r in blocks})[:50],
                         "notes": dict(Counter(f.get("rule") for r in notes for f in r.get("flags", [])))},
        "classifier_calls": clf_calls,
        "classifier_unavailable": clf_unavailable,
        "classifier_health_windows": len(health),
        "watch_candidates": watch_candidates(week),
    }


def write_candidates(cands: list[dict[str, Any]], path: Path = CANDIDATES_PATH) -> str | None:
    try:
        path = Path(path)
        _ensure_leaf(path)
        tmp = path.with_suffix(".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"_doc": "Injection-watch senders for the fraud-lens watchlist owner to REVIEW. Not the watchlist: "
                               "promotion into policies/fraud-watchlist.json is a reviewed PR (email_sha256 is the same "
                               "normalisation as credit_review/watchlist.py).",
                       "version": VERSION, "candidates": cands}, f, indent=1)
        os.replace(tmp, path)
        return None
    except Exception as e:  # noqa: BLE001
        return f"{type(e).__name__}: {e}"


def dump_rules() -> list[dict[str, str]]:
    """The rule table as the parity check compares it (sources before PY_OVERRIDES)."""
    return [{"rule": n, "severity": s, "source": src, "flags": fl} for n, s, src, fl in RULES]
