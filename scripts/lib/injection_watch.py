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
import time
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

# A reader must not report a quiet window just because the prune renamed the live file mid-read, so the listing is
# retried a bounded number of times before it refuses (QA on #1665, review 5770078247).
LEDGER_READ_ATTEMPTS = 5
LEDGER_READ_BACKOFF_SECONDS = 0.01

VERSION = "iw-2026-11-04.6"   # == INJECTION_WATCH_VERSION in injection-watch.ts (parity-checked)
LEDGER_PATH = Path("/var/lib/hydra/injection-watch/ledger.jsonl")
# Retention and both writers coordinate through ONE filesystem lock: prune deletes a sealed generation only while it
# holds this directory, and both writers append only while they hold it (QA on #1665: an age check followed by an
# unlink cannot be made safe against a writer that still has the old inode open, so the two are serialized instead).
# "create a directory" is atomic and available to Python and Node alike, which a shared flock would not be.
LEDGER_LOCK_SUFFIX = ".ledger.lock"   # the lock lives next to the ledger; == LEDGER_LOCK_SUFFIX in the TS copy
# The lock is the FAST path, not the guarantee: the guarantee is that a generation is never unlinked while any process
# still holds a descriptor on it (`_open_inodes`, checked immediately before each unlink). That is why every timeout
# below may be generous without putting a row at risk -- a stolen or bypassed lock can only cost ordering, never data.
LOCK_STALE_SECONDS = 300.0          # no heartbeat for this long = the holder died; steal it
LOCK_HEARTBEAT_SECONDS = 5.0        # a holder that is still working touches the lock this often, so it is never stolen
LOCK_WRITE_TIMEOUT = 5.0            # a writer waits this long, then appends anyway (a lost hit is worse)
LOCK_PRUNE_SECONDS = 30.0           # the pruner waits longer, and PAGES instead of skipping retention
CANDIDATES_PATH = Path("/var/lib/hydra/injection-watch/watch-candidates.json")
# Retention (Fable s1 on #1665): this PR is the first thing writing customer-derived text to the ledger, so it has
# to expire on its own. The daily run prunes rows older than this; the TS side carries the same number as
# LEDGER_RETENTION_DAYS and the parity test pins the two equal, so neither side can believe a different lifetime.
RETENTION_DAYS = 30
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


# Masked context window for HIGH hits: bounded, PII-redacted, one line. Same constants as the TypeScript side.
CONTEXT_RADIUS = 60
CONTEXT_MAX = 160
CONTEXT_SNAP = 32
_MASK_EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
# A phone has an international prefix or real separators: a bare digit run is an order/credit id, not a phone.
_MASK_PHONE = re.compile(r"\+\d[\d\s().-]{6,}\d|\(?\d{2,4}\)?[\s.-]\d{2,4}[\s.-]\d{2,4}")
# No word boundary: an ORDER-123456789 or AB123456789 keeps its digits inside a token (QA on #1665).
_MASK_LONG_NUMBER = re.compile(r"\d{6,}")
# A claim code carries no long digit run at all (XK4F7Q), so it needs its own pass: any 6+ character token with both
# a digit and a capital is treated as a code (Fable s1 on #1665). Over-redacting a review excerpt is safe.
_MASK_CODE_TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")


def _pad_mask(kind: str, length: int) -> str:
    """A redaction of EXACTLY ``length`` characters: the tag plus fillers, or fillers when it is too short to name.

    Keeping the length is what lets a window be taken over MASKED text while still using the original offsets, so a
    slice can never cut an identifier in half (QA on #1665: a phone starting before the window survived as a
    fragment at the left edge). Same rule as padMask in injection-watch.ts.
    """
    tag = f"[{kind}]"
    return tag + "#" * (length - len(tag)) if length >= len(tag) else "#" * length


def _mask_code(m: "re.Match[str]") -> str:
    tok = m.group(0)
    if len(tok) >= 6 and any(c.isdigit() for c in tok) and any(c.isupper() for c in tok):
        return _pad_mask("code", len(tok))
    return tok


def mask_pii(s: str) -> str:
    """Redact the identifiers a hit may carry: emails, phone-like runs, then any 6+ digit run. Deterministic.

    The output is the SAME LENGTH as the input, so masking can run over the whole text BEFORE any window is taken
    (a fragment of an identifier that starts outside the window must never survive). Mirrors maskPii in the TS copy.
    """
    t = _MASK_EMAIL.sub(lambda m: _pad_mask("email", len(m.group(0))), s or "")
    t = _MASK_PHONE.sub(lambda m: _pad_mask("phone", len(m.group(0))), t)
    return _MASK_CODE_TOKEN.sub(_mask_code, _MASK_LONG_NUMBER.sub(lambda m: _pad_mask("number", len(m.group(0))), t))


def _bound_context(body: str) -> str:
    """Cut to CONTEXT_MAX on a WORD boundary, then drop a trailing digit run: a hard character cut can split
    "…or +1 (555)" out of a masked phone and leak a fragment of it into the ledger."""
    if len(body) <= CONTEXT_MAX:
        return body
    head = re.sub(r"\s+\S*$", "", body[: CONTEXT_MAX - 3])
    return re.sub(r"[\s(]*[+\d][\d().\s-]*$", "", head) + "..."


def _snap_window(text: str, frm: int, to: int, index: int, end: int) -> tuple[int, int]:
    """Widen a window to word boundaries (at most CONTEXT_SNAP chars): slicing mid-token can cut a phone."""
    floor = max(0, index - CONTEXT_RADIUS - CONTEXT_SNAP)
    while frm > floor and not text[frm - 1].isspace():
        frm -= 1
    ceiling = min(len(text), end + CONTEXT_RADIUS + CONTEXT_SNAP)
    while to < ceiling and to < len(text) and not text[to - 1].isspace():
        to += 1
    return frm, to


def masked_context(text: str, index: int, length: int) -> str:
    """The masked window around a match at ``index`` (length ``length``), bounded, one line.

    Mask the WHOLE text first, then window the masked string. Masking after the slice is what let a phone starting
    before the window survive as a fragment ("010-9999") in the 30-day ledger (QA on #1665); masking first makes that
    impossible, and mask_pii is length-preserving so these offsets are still the original ones."""
    masked = mask_pii(text)
    frm, to = _snap_window(masked, max(0, index - CONTEXT_RADIUS), min(len(masked), index + length + CONTEXT_RADIUS),
                           index, index + length)
    body = " ".join(masked[frm:to].split())
    # Belt and braces at BOTH edges: a fragment of a digit run must never be the first or last thing kept.
    safe = re.sub(r"^[\s()]*[+\d][\d().\s-]*(?=\s|$)", "", re.sub(r"[\s(]*[+\d][\d().\s-]*$", "", body)).strip() \
        or body
    return ("..." if frm > 0 else "") + _bound_context(safe) + ("..." if to < len(text) else "")


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
        hit = {"rule": name, "severity": sev, "excerpt": _cut(m.group(0))}
        # HIGH hits only: the ledger is otherwise deliberately text-free, and review needs a sentence,
        # not a bare "Assistant:" (firstmate decision 2026-11-03).
        if sev == "high":
            hit["context"] = masked_context(t, m.start(), len(m.group(0)))
        hits.append(hit)
    zw = _ZERO_WIDTH.findall(t)
    if len(zw) >= ZERO_WIDTH_MIN:
        hits.append({"rule": "zero_width_run", "severity": "low", "excerpt": f"{len(zw)} zero-width chars"})
    return hits


def recent_hits(ledger: Path = LEDGER_PATH, *, hours: int = 24, severity: str | None = None,
                on_error: str = "empty") -> list[dict[str, Any]]:
    """Inbound hit-turns from the last ``hours``, newest last, with their masked context when the row has one.

    The review surface for a HIGH hit: the ledger holds a rule name, a text hash and (HIGH only) a short masked
    window, so this is the only way to see WHAT triggered it. Read-only; never raises."""
    out: list[dict[str, Any]] = []
    try:
        if not ledger_files(ledger):        # the live file may be gone right after a seal; sealed rows still count
            raise FileNotFoundError(f"ledger not found: {ledger}")
        cut = datetime.now(timezone.utc) - timedelta(hours=hours)
        for row in read_ledger(ledger):
            if row.get("kind") != "inbound_injection":
                continue
            ts = _ts(row)
            if ts is None or ts < cut or (severity and row.get("severity") != severity):
                continue
            out.append({"ts": row.get("ts"), "source": row.get("source"), "ref": row.get("ref"),
                        "severity": row.get("severity"), "text_sha256": row.get("text_sha256"),
                        "hits": [{"rule": h.get("rule"), "severity": h.get("severity"), "context": h.get("context")}
                                 for h in row.get("hits") or []]})
    except Exception as e:  # noqa: BLE001
        # A reviewer who cannot read the ledger must not see the same empty answer as a quiet day
        # (QA on #1665): callers that print for a human pass on_error="raise".
        if on_error == "raise":
            raise
        print(f"[injection-watch:ALERT] ledger read FAILED ({type(e).__name__}: {e}); hits unknown, not empty",
              file=sys.stderr)
        return out
    return out


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
    """Append one JSON row (0600, leaf dir 0700 created only under an existing parent). Never raises.

    The open/write/close happens under the shared ledger lock, which is what makes the prune's unlink safe: a
    writer cannot be mid-append while a generation is deleted. If the lock cannot be taken the row is STILL
    written (a dropped hit is worse than one unserialised append) and the fact is reported on stderr."""
    try:
        ledger = Path(ledger)
        _ensure_leaf(ledger)
        lock = ledger_lock(ledger)
        locked = lock.acquire()
        try:
            if not locked:
                print(f"[injection-watch:ALERT] ledger lock busy ({lock.dir.name}); appending WITHOUT it: "
                      "a concurrent prune could delete the generation this row lands in", file=sys.stderr)
            fd = os.open(ledger, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            with os.fdopen(fd, "a", encoding="utf-8") as f:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
        finally:
            lock.release()
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

class LedgerLock:
    """Serialize the ledger appenders against the retention prune.

    A delete cannot be made safe against an appender by checking timestamps: whichever order the check and the unlink
    take, a writer that already has the old inode open can append in between and that row becomes unreachable (QA on
    #1665 reproduced exactly that). So the two take turns instead, on the one primitive both languages have: an
    atomic directory creation (`os.mkdir` / `fs.mkdir`). An append opens, writes and closes inside the lock; the
    prune decides and unlinks inside the same lock, so no append is ever in flight across a delete.

    Nothing here touches rows. A lock older than ``LOCK_STALE_SECONDS`` is a crashed holder's and is stolen. When
    the lock cannot be had in time the caller decides what matters: `append()` appends anyway and says so on stderr
    (losing a hit is worse than one unserialised row), while `prune_ledger()` raises so the daily run pages instead
    of reporting a retention window it did not enforce.
    """

    def __init__(self, ledger: Path | str = LEDGER_PATH, *, timeout: float | None = None) -> None:
        self.ledger = Path(ledger)
        self.dir = self.ledger.with_name(f"{self.ledger.name}{LEDGER_LOCK_SUFFIX}")
        self.timeout = LOCK_WRITE_TIMEOUT if timeout is None else timeout   # resolved per call, never frozen
        self.held = False

    def acquire(self) -> bool:
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                os.mkdir(self.dir, 0o700)
                self.held = True
                return True
            except FileExistsError:
                try:
                    age = time.time() - os.stat(self.dir).st_mtime
                except OSError:
                    age = 0.0
                if age > LOCK_STALE_SECONDS:          # a crashed holder left it behind
                    try:
                        os.rmdir(self.dir)
                    except OSError:
                        pass
                    continue
                if time.monotonic() >= deadline:
                    return False
                time.sleep(0.005)
            except OSError:
                return False                         # cannot lock at all (no dir / permissions)

    def heartbeat(self) -> None:
        """Refresh the lock's mtime, so a holder that is still WORKING is never mistaken for a crashed one.

        The prune touches this between generations; without it a long prune would look dead after
        ``LOCK_STALE_SECONDS`` and a reader of the lock would steal it while the work was still running (QA on #1665).
        """
        if self.held:
            try:
                os.utime(self.dir, None)
            except OSError:
                pass

    def release(self) -> None:
        if not self.held:
            return
        self.held = False
        try:
            os.rmdir(self.dir)
        except OSError:
            pass

    def __enter__(self) -> "LedgerLock":
        self.acquire()
        return self

    def __exit__(self, *_exc: object) -> None:
        self.release()


def ledger_lock(ledger: Path | str = LEDGER_PATH, *, timeout: float | None = None) -> LedgerLock:
    """The one lock both writers and the prune share."""
    return LedgerLock(ledger, timeout=timeout)


def ledger_files(ledger: Path | str = LEDGER_PATH) -> list[Path]:
    """Every file the ledger currently consists of, oldest name first: the live file plus its sealed generations.

    Retention never rewrites a file a writer may be appending to (QA on #1665, 2026-11-03): the only way a row
    can be lost is if it is written into a file nobody reads or into one that is deleted. Sealing keeps both
    impossible -- a row appended to the just-sealed generation is still read, and a row appended to the fresh
    live file was never at risk. Sealed generations are only deleted whole, and only once everything in them is
    older than the retention window."""
    live = Path(ledger)
    sealed = _sealed_generations(live)
    try:
        os.stat(live)                       # not Path.exists(): that answers False on EACCES/EIO, i.e. "not there"
    except FileNotFoundError:
        return sealed                       # the live file may be gone right after a seal; sealed rows still count
    except OSError as e:
        raise OSError(f"cannot stat the live ledger at {live}: {e}") from e
    return sealed + [live]                  # seal order: oldest generation first


def _sealed_generations(live: Path) -> list[Path]:
    """The sealed generations beside ``live``, oldest name first.

    Anything that matches is returned, whatever it is: a generation that became unreadable or is not a regular file
    must SURFACE as an error rather than be filtered out of the ledger set (QA on #1665, finding 2).

    A listing that FAILS is an error, never an empty set (QA on #1665, review 5773297425). It used to fall back to
    ``[]``, which reads as "this ledger has no sealed generations" -- so a sealed HIGH hit disappeared from
    ``read_ledger``/``digest``/``hits`` while the live file stayed readable, and the day looked quiet. Only a MISSING
    directory means there is no ledger here; anything else means "I could not look", which the callers turn into an
    explicit error (``hits`` exits 2, the digest reports ``ledger_error`` with the counts absent, the prune exits 3
    and pages)."""
    parent = live.parent
    try:
        entries = list(os.scandir(parent))
    except FileNotFoundError:
        return []
    except OSError as e:
        raise OSError(f"cannot list the ledger generations in {parent}: {e}") from e
    prefix = f"{live.name}.sealed-"
    return sorted(Path(entry.path) for entry in entries if entry.name.startswith(prefix) and entry.name != live.name)


def _open_inodes() -> set[tuple[int, int]] | None:
    """(device, inode) of every file a live process holds a descriptor on; ``None`` when that cannot be determined.

    This is what makes deletion safe regardless of any lock timing (QA on #1665): a row can only be lost if the file it
    was written into is unlinked while a writer still has that inode open, and on Linux such a descriptor is visible in
    /proc. So the prune refuses to unlink anything in this set -- and when /proc cannot be read it refuses to unlink at
    all and says so, because "I could not check" is not "nobody holds it".
    """
    held: set[tuple[int, int]] = set()
    try:
        procs = os.listdir("/proc")
    except OSError:
        return None
    for pid in procs:
        if not pid.isdigit():
            continue
        try:
            fds = os.listdir(f"/proc/{pid}/fd")
        except OSError:
            continue                          # the process exited, or it is another user's: not ours to inspect
        for fd in fds:
            try:
                st = os.stat(f"/proc/{pid}/fd/{fd}")
            except OSError:
                continue                      # closed between listing and stat
            held.add((st.st_dev, st.st_ino))
    return held


def _held_open(p: Path, held: set[tuple[int, int]] | None) -> bool:
    """Whether ``p``'s inode is somebody's open descriptor. Unknown (``held is None``) counts as held: never delete."""
    if held is None:
        return True
    try:
        st = p.stat()
    except OSError:
        return False                          # already gone: nothing to protect
    return (st.st_dev, st.st_ino) in held


def _file_age(p: Path) -> tuple[datetime | None, bool]:
    """(newest dated row in the file, whether any row could not be dated). Undated rows protect the file."""
    newest: datetime | None = None
    undated = False
    try:
        f = open(p, encoding="utf-8")
    except FileNotFoundError:
        return None, True                     # vanished (a concurrent prune deleted it): nothing to judge
    except OSError as e:
        # Unreadable is NOT "empty" and NOT "keep silently": the daily retention run must page (QA on #1665).
        raise OSError(f"cannot read ledger generation {p}: {e}") from e
    with f:
        for line in f:
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                undated = True
                continue
            ts = _ts(row if isinstance(row, dict) else {})
            if ts is None:
                undated = True
            elif newest is None or ts > newest:
                newest = ts
    return newest, undated


def prune_ledger(ledger: Path = LEDGER_PATH, *, days: int = RETENTION_DAYS,
                 now: datetime | None = None) -> dict[str, Any]:
    """Enforce the retention window WITHOUT rewriting any file a writer can append to.

    Two steps, both crash-safe and both safe against concurrent appends:
      1. SEAL the live file: rename it to ``<name>.sealed-<UTC timestamp>``. A rename never drops bytes. A writer
         that already had the old inode open appends into the sealed generation, which readers still read; a
         writer that opens the path afterwards creates a fresh live file. Nothing can be lost in the window.
      2. DELETE whole sealed generations whose NEWEST content (max row timestamp, and the file's own mtime, so a
         late append also protects it) is older than the cut. A file is never partially rewritten, so an old row
         and a fresh row in the same generation resolve to "keep the file", never "keep the fresh row only".

    Sealing normalises the generation's mtime to its NEWEST row, so the same run that seals an all-old file also
    deletes it: a row is dropped on the first run after it passes the window (no age laundering). A LATE append
    updates the mtime again, which is what keeps a generation alive when a writer wrote into it after the seal.

    A row that cannot be dated keeps its whole generation alive: retention is a bound on age, and deleting evidence
    we cannot date is worse than holding it. Raises on an unreadable/unwritable ledger (or a live path that is not a
    regular file) so the daily run can page instead of silently dropping the bound.

    The pass runs under the shared ledger lock, which the writers also hold while they append, so an age check
    followed by an unlink cannot normally have an append in between (QA on #1665, finding 1). A lock that cannot be
    taken raises, because a prune that did not run is a privacy regression, not a quiet success.

    THE LOCK IS NOT THE GUARANTEE, though -- any timeout can be beaten by a slow or loaded machine (QA on #1665,
    finding 3: "the lock is stolen after 15s, even if prune is still active, and writers append without the lock
    after 5s"). The guarantee is ``_open_inodes``: a generation whose inode any live process still holds a descriptor
    on is KEPT, whatever the lock did. Deleting such a file is the only way an appended row could vanish, so with
    this check no ordering, no steal and no bypass can lose one -- a stolen lock can only cost ordering. A holder
    heartbeats the lock while it works, so it is not mistaken for a crashed one in the first place."""
    ledger = Path(ledger)
    cut = (now or datetime.now(timezone.utc)) - timedelta(days=days)
    report: dict[str, Any] = {"dropped": 0, "kept": 0, "days": days, "sealed": None,
                              "files_dropped": 0, "files_kept": 0,
                              # A generation somebody still holds open is KEPT (an in-flight append would be lost
                              # otherwise); a generation whose holders could not be determined at all is kept too and
                              # reported separately, because "I could not check" must never read as "nobody holds it".
                              "held_open_files": 0, "unverified_files": 0}
    if not ledger.parent.exists():
        # No ledger directory means no ledger and no writer that could create one (a writer makes the leaf itself
        # first), so there is nothing to expire and no lock to take. NOT a silent skip: there is simply no text here.
        return report
    lock = ledger_lock(ledger, timeout=LOCK_PRUNE_SECONDS)
    if not lock.acquire():
        raise TimeoutError(f"ledger lock {lock.dir} is held after {LOCK_PRUNE_SECONDS:g}s; retention NOT enforced")
    try:
        return _prune_locked(ledger, lock=lock, cut=cut, days=days, now=now)
    finally:
        lock.release()


def _prune_locked(ledger: Path, *, lock: "LedgerLock", cut: datetime, days: int,
                  now: datetime | None) -> dict[str, Any]:
    """The prune itself, with the shared ledger lock held by the caller. Never called any other way."""
    report: dict[str, Any] = {"dropped": 0, "kept": 0, "days": days, "sealed": None,
                              "files_dropped": 0, "files_kept": 0,
                              # A generation somebody still holds open is KEPT (an in-flight append would be lost
                              # otherwise); a generation whose holders could not be determined at all is kept too and
                              # reported separately, because "I could not check" must never read as "nobody holds it".
                              "held_open_files": 0, "unverified_files": 0}
    if ledger.exists() and not ledger.is_file():
        # Never rename or unlink something that is not a regular file (QA on #1665): page instead.
        raise IsADirectoryError(f"ledger is not a regular file: {ledger}")
    # 1. seal the live generation
    if ledger.exists() and ledger.stat().st_size > 0:
        stamp = (now or datetime.now(timezone.utc)).strftime("%Y%m%dT%H%M%SZ")
        sealed = ledger.with_name(f"{ledger.name}.sealed-{stamp}")
        n = 1
        while sealed.exists():                # never clobber an earlier seal in the same second
            n += 1
            sealed = ledger.with_name(f"{ledger.name}.sealed-{stamp}-{n}")
        os.rename(ledger, sealed)
        os.chmod(sealed, 0o600)
        # Normalise the sealed generation's mtime to its NEWEST row. The mtime is otherwise proof of age only for a
        # LATE append (a writer that had the old inode open writes after the rename, updating mtime); leaving it at
        # seal time would make every generation look fresh forever, so nothing would ever expire.
        newest, _undated = _file_age(sealed)
        if newest is not None:
            os.utime(sealed, (newest.timestamp(), newest.timestamp()))
        report["sealed"] = sealed.name
    # 2. delete sealed generations that are entirely past the window.
    # Read /proc ONCE, AFTER the seal: any writer that opened the live file before the rename still holds that inode
    # and is in this set, and no NEW descriptor can appear on a sealed generation afterwards (writers only ever open
    # the live path). So membership here is exactly "an append could still be landing in this file" (QA on #1665).
    held = _open_inodes()
    for p in ledger_files(ledger):
        lock.heartbeat()                      # still working: never stolen as a crashed holder's
        newest, undated = _file_age(p)
        if undated and newest is None:
            report["files_kept"] += 1         # nothing datable: keep (evidence rule)
            continue
        try:
            mtime = datetime.fromtimestamp(p.stat().st_mtime, tz=timezone.utc)
        except OSError:
            report["files_kept"] += 1
            continue
        ref = newest if newest is not None else cut
        if ref < mtime:
            ref = mtime                       # a late append into a sealed generation protects it
        if undated or ref >= cut or p == ledger:
            report["files_kept"] += 1
            continue
        # THE guarantee (QA on #1665, finding 3): never unlink an inode a writer still holds open. Whatever the lock
        # did or did not do -- stolen as stale, bypassed after the writer's timeout, held by a process we cannot see --
        # an append in flight keeps its descriptor, so this check is independent of every timing assumption above.
        if _held_open(p, held):
            if held is None:
                report["unverified_files"] += 1   # /proc unreadable: kept, and loud (never read as "nobody holds it")
            else:
                report["held_open_files"] += 1    # an append is in flight: keep it, delete it on a later run
            report["files_kept"] += 1
            continue
        # Count first, and let an unreadable file RAISE (a generation we cannot read is not "kept silently": the
        # daily run must page). Only a failed unlink is a keep, and a file another prune already removed is a no-op.
        try:
            _ident, generation_lines = read_generation(p)
        except _Vanished:
            lines_in_file = []          # sealed or deleted by a concurrent pass: nothing left to count under p
        else:
            lines_in_file = generation_lines
        rows_in_file = sum(1 for line in lines_in_file if line.strip())
        try:
            os.unlink(p)
        except FileNotFoundError:
            report["files_kept"] += 1
            continue
        except OSError:
            report["files_kept"] += 1         # could not delete: report the file as kept, never as dropped
            continue
        report["dropped"] += rows_in_file
        report["files_dropped"] += 1
    # 3. report what the ledger still holds
    report["kept"] = len(ledger_lines(ledger))
    return report


def _ts(row: dict[str, Any]) -> datetime | None:
    try:
        return datetime.fromisoformat(str(row.get("ts", "")).replace("Z", "+00:00"))
    except ValueError:
        return None


class _Vanished(Exception):
    """A generation named by ``ledger_files`` was gone by the time it was opened: the prune sealed it under a new
    name (or deleted it). Not an error on its own -- the reading pass re-lists and reads what it has not read."""


def read_generation(path: Path) -> tuple[tuple[int, int], list[str]]:
    """(identity, lines) for one generation, opened ONCE so the identity is the inode actually read.

    The identity is (st_dev, st_ino), not the path, because the prune RENAMES the live file: the same inode then
    answers to a different name, and a path-keyed reader would either miss it (the QA finding) or read it twice."""
    try:
        fd = os.open(path, os.O_RDONLY)
    except FileNotFoundError as e:
        raise _Vanished(str(path)) from e
    except OSError as e:
        # An unreadable generation must never look like an empty one (QA on #1665, finding 2).
        raise OSError(f"cannot read ledger generation {path}: {e}") from e
    try:
        # A directory reaches here (os.open accepts one), so the NOT-A-FILE case must raise the same loud error as
        # any other unreadable generation rather than surface a raw errno about a file descriptor.
        with os.fdopen(fd, encoding="utf-8") as f:
            st = os.fstat(f.fileno())
            return (st.st_dev, st.st_ino), f.read().splitlines()
    except OSError as e:
        raise OSError(f"cannot read ledger generation {path}: {e}") from e


def ledger_lines(ledger: Path = LEDGER_PATH) -> list[str]:
    """Every non-empty line of the WHOLE ledger, read so a seal or a delete in the middle cannot HIDE a row.

    ``ledger_files`` is a snapshot, and the daily prune renames the live path (seal) or deletes a whole old
    generation at any moment. Reading a snapshotted path that has just been renamed finds nothing, which used to
    read as "no hits today" while the row sat in the generation it had become (QA on #1665, review 5770078247;
    reproduced: 0 rows during the seal, 1 row immediately after). So a pass that finds a vanished path RE-LISTS and
    reads whatever it has not read yet, keyed by inode so a renamed generation is read exactly once.

    A vanished read is not the only shape of this race, so the LISTING is iterated to a fixed point as well.
    ``ledger_files`` is two steps -- it collects the sealed names, then appends the live file if it still exists --
    so a rename landing between them yields an EMPTY list: the sealed name was collected before the rename, and the
    live path was gone after it. Nothing vanished, so a vanished-read-only retry returned ``[]`` for a ledger that
    held a HIGH hit (QA on #1665, review 5772461331). Two consecutive identical listings mean the prune is not in
    the middle of a move, so the pass completes; any difference re-reads what is new.

    Bounded, and never silent: if the ledger keeps changing under us for LEDGER_READ_ATTEMPTS passes we raise, which
    the callers turn into an explicit error -- a reader that cannot say what is in the ledger must say so rather
    than report a quiet window."""
    seen: set[tuple[int, int]] = set()
    out: list[str] = []
    previous: list[str] | None = None
    for attempt in range(LEDGER_READ_ATTEMPTS):
        listing = [str(p) for p in ledger_files(ledger)]
        vanished = False
        for path in (Path(p) for p in listing):
            try:
                ident, lines = read_generation(path)
            except _Vanished:
                vanished = True          # sealed or pruned between the listing and the open: re-list, try again
                continue
            if ident in seen:            # the same inode we already read, now under a different name
                continue
            seen.add(ident)
            out.extend(line for line in lines if line.strip())
        # A CHANGED listing means the prune moved the ledger during this pass (a seal, or a delete of an old
        # generation), so the next pass reads whatever appeared; the same listing twice cannot hide a row.
        if not vanished and listing == previous:
            return out
        previous = listing
        if attempt + 1 < LEDGER_READ_ATTEMPTS:
            time.sleep(LEDGER_READ_BACKOFF_SECONDS)
    raise OSError(f"the ledger at {ledger} kept changing while it was read "
                  f"({LEDGER_READ_ATTEMPTS} listing attempts); refusing to answer from a partial read")


def read_ledger(ledger: Path = LEDGER_PATH, *, since: datetime | None = None) -> list[dict[str, Any]]:
    """Every row in the live file and all sealed generations (seal order), filtered by ``since``.

    Raises when a generation exists but cannot be read: callers that print for a human must not turn that into
    ``[]`` (it is the difference between a quiet day and an unknown one)."""
    rows: list[dict[str, Any]] = []
    for line in ledger_lines(ledger):
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = _ts(r)
        if since is None or (t is not None and t >= since):
            rows.append(r)
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
    try:
        day = dedupe(read_ledger(ledger, since=now - timedelta(hours=hours)))
        week = dedupe(read_ledger(ledger, since=now - timedelta(days=CANDIDATE_DAYS)))
    except OSError as e:
        # A generation that exists but cannot be read is an UNKNOWN day, never a quiet one (QA on #1665): report the
        # error and let the caller page. Numbers are omitted rather than zeroed, so nothing reads as "no hits".
        return {"window_hours": hours, "ledger_writable": False, "ledger_error": f"{type(e).__name__}: {e}",
                "inbound": None, "output_guard": None, "classifier_calls": None,
                "classifier_unavailable": None, "classifier_health_windows": None, "watch_candidates": None}
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
