"""Read-only sources for the fraud lens (scripts/ops_intake/fraud.py).

Four narrow reads, each of which can fail and each of which then reports
``unmeasured`` instead of a clean-looking default:

* ``band_for_ids`` - the deployed lens (``credit_review.fraud_lens.default_lens``
  over the Trino replica): held / watchlisted / ask-only / clean.
* ``user_ids_for`` - which core users a profile / track / request id belongs to.
  The lens is keyed on user id, and an ask names profile ids, so this hop is
  load-bearing; no users found is ``unmeasured``, never "clean".
* ``reuse_signals`` - the proof store's H3 F2 evidence: the same document
  (sha256, normalised text, or pHash within distance) filed by ANOTHER account.
* ``register_verdict`` - the GDPR register's identity verdict for the page(s)
  the ask wants hidden. A profile with NO register row and one whose verdict is
  UNKNOWN both come back UNKNOWN on purpose: the 2026-11-04 census found a hide
  executed on an UNKNOWN identity, and the fix is for the router to ASK.
* ``requester_linked`` - does the target profile belong to the person asking?
  Core's ``claiming``/``users`` joined on the requester's Slack email. A match
  is a W2 refusal + page; an unreadable replica is ``unmeasured``.

Nothing here writes. Nothing here decides; ``fraud.evaluate`` does, from the
frame these functions fill.

Every id is validated first (a full UUID, an 8-hex prefix, or an Intercom
conversation id) and anything else is DROPPED and reported as unmeasured - on
every call, including a mixed one - so a value an ask carried can never become
SQL and a dropped id can never read as a measured check. The sqlite reads bind their ids as
parameters; the Trino callable takes SQL text only, so its IN-lists are built
from validated ids and refuse anything else.
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
from pathlib import Path
from typing import Any, Iterable, Sequence

GDPR_DB = os.environ.get("GDPR_STORE", "/var/lib/hydra-gdpr/erasure.sqlite")
PROOF_DB = os.environ.get(
    "CREDIT_PROOF_STORE",
    os.path.join(os.environ.get("CREDIT_VERIFY_STATE_DIR", "/var/lib/hydra-credit-verify"),
                 "proof.sqlite"))
PHASH_MAX_DISTANCE = 8   # mirrors credit_verify/proof/fingerprint.PHASH_MAX_DISTANCE's order of magnitude


UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
PREFIX_RE = re.compile(r"^[0-9a-f]{8}$")
INTERCOM_RE = re.compile(r"^\d{15,19}$")


def _chunked(xs: Sequence[str], n: int = 200) -> Iterable[list[str]]:
    for i in range(0, len(xs), n):
        yield list(xs[i:i + n])


def _safe_ids(ids: Sequence[str]) -> tuple[list[str], list[str]]:
    """Split ids into the shapes this module may query with, and the rest.

    Only a full UUID, an 8-hex prefix or an Intercom conversation id is ever
    handed to a query. Anything else is DROPPED and reported, so a value the ask
    carried can never become SQL.
    """
    accepted: list[str] = []
    rejected: list[str] = []
    for raw in ids:
        value = str(raw or "").strip().lower()
        if not value:
            continue
        if UUID_RE.match(value) or PREFIX_RE.match(value) or INTERCOM_RE.match(value):
            accepted.append(value)
        else:
            rejected.append(value[:40])
    return list(dict.fromkeys(accepted)), rejected


def _rejected_reasons(prefix: str, rejected: Sequence[str]) -> list[str]:
    return [f"{prefix}:rejected-id:{value}" for value in rejected]


def _sql_list(xs: Sequence[str]) -> str:
    """A quoted IN-list for the Trino callable, which takes SQL text only.

    Every element must already be a validated id (hex, dashes or digits), so no
    quote can reach the statement; anything else raises instead of being quoted.
    """
    for value in xs:
        if not (UUID_RE.match(value) or PREFIX_RE.match(value) or INTERCOM_RE.match(value)):
            raise ValueError(f"refusing to build SQL from an unvalidated id: {value[:40]!r}")
    return ",".join("'" + value + "'" for value in xs)


def _query():
    """The read-only Trino query callable, resolved lazily (tests inject their own)."""
    from credit_review import verify_notify  # noqa: PLC0415
    return verify_notify.trino


def user_ids_for(ids: Sequence[str], *, query=None) -> tuple[list[str], list[str]]:
    """Core user ids for any mix of profile uuids, track uuids and request uuids."""
    ids, rejected = _safe_ids(ids)
    rejected_reasons = _rejected_reasons("user_ids", rejected)
    if not ids:
        return [], ["user_ids:no-ids"] + rejected_reasons
    query = query or _query()
    found: set[str] = set()
    try:
        for chunk in _chunked(ids):
            lst = _sql_list(chunk)
            for (uid,) in query(
                "SELECT DISTINCT CAST(userid AS varchar) FROM postgresql_core.public.credit_requests "
                f"WHERE deletedat IS NULL AND (lower(CAST(id AS varchar)) IN ({lst}) "
                f"OR lower(CAST(profileid AS varchar)) IN ({lst}))"):
                if uid:
                    found.add(str(uid))
    except Exception as exc:  # noqa: BLE001
        return [], [f"user_ids:{type(exc).__name__}"] + rejected_reasons
    if not found:
        return [], ["user_ids:none-found"] + rejected_reasons
    return sorted(found), rejected_reasons


def band_for_ids(user_ids: Sequence[str], *, lens_fn=None) -> tuple[str | None, tuple[str, ...], list[str]]:
    """The deployed fraud lens for those users, collapsed to one band."""
    numeric = [str(u) for u in user_ids if str(u).isdigit()]
    if not numeric:
        return None, (), ["band:no-numeric-user"]
    try:
        if lens_fn is None:
            from credit_review import fraud_lens  # noqa: PLC0415
            lens_fn = fraud_lens.default_lens(_query())
        verdicts = lens_fn([int(u) for u in numeric])
    except Exception as exc:  # noqa: BLE001
        return None, (), [f"band:{type(exc).__name__}"]
    if not verdicts:
        return None, (), ["band:no-verdict"]
    held = sorted({r for v in verdicts.values() for r in (getattr(v, "held", ()) or ())})
    watch = sorted({r for v in verdicts.values() for r in (getattr(v, "watch", ()) or ())})
    if held:
        return "held", tuple(held), []
    if watch:
        return "watch", tuple(watch), []
    if all(getattr(v, "ask_only", False) for v in verdicts.values()):
        return "ask_only", (), []
    return "clean", (), []


def _phash_close(a: str | None, b: str | None) -> bool:
    if not a or not b:
        return False
    try:
        return bin(int(a, 16) ^ int(b, 16)).count("1") <= PHASH_MAX_DISTANCE
    except ValueError:
        return False


def reuse_signals(ids: Sequence[str], *, proof_db: str | Path | None = None) -> tuple[list[dict[str, Any]], list[str]]:
    """H3 F2: documents filed for these ids that another account already filed."""
    ids, rejected = _safe_ids(ids)
    rejected_reasons = _rejected_reasons("reuse", rejected)
    if not ids:
        return [], ["reuse:no-ids"] + rejected_reasons
    path = Path(proof_db or PROOF_DB)
    if not path.is_file():
        return [], ["reuse:proof-store-missing"] + rejected_reasons
    signals: list[dict[str, Any]] = []
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
        conn.row_factory = sqlite3.Row
        try:
            rows: list[sqlite3.Row] = []
            for chunk in _chunked(ids):
                placeholders = ",".join("?" for _ in chunk)
                rows.extend(conn.execute(
                    "SELECT user_id, file_sha256, conversation_id, candidate_request_ids_json "
                    "FROM proof_intake WHERE " + " OR ".join(
                        "instr(lower(candidate_request_ids_json), ?) > 0" for _ in chunk),
                    tuple(chunk)).fetchall())
                rows.extend(conn.execute(
                    "SELECT user_id, file_sha256, conversation_id, candidate_request_ids_json "
                    f"FROM proof_intake WHERE lower(conversation_id) IN ({placeholders})",
                    tuple(chunk)).fetchall())
            seen: set[tuple[str, str]] = set()
            for row in rows:
                sha = row["file_sha256"]
                if not sha or (str(row["user_id"]), sha) in seen:
                    continue
                seen.add((str(row["user_id"]), sha))
                others = conn.execute(
                    "SELECT DISTINCT user_id FROM proof_intake WHERE file_sha256=? AND user_id<>?",
                    (sha, row["user_id"])).fetchall()
                if others:
                    signals.append({"signal": "reused_by_another_account",
                                    "proof_sha256": sha,
                                    "other_user_ids": [str(o["user_id"]) for o in others]})
                    continue
                mine = conn.execute(
                    "SELECT phash, text_sha, track_key FROM fingerprints WHERE proof_id=?", (sha,)
                ).fetchall()
                for fp in mine:
                    cand = conn.execute(
                        "SELECT proof_id, phash, text_sha FROM fingerprints WHERE proof_id<>? "
                        "AND (text_sha=? OR track_key IS ?)",
                        (sha, fp["text_sha"], fp["track_key"])).fetchall()
                    for other in cand:
                        if other["text_sha"] and other["text_sha"] == fp["text_sha"]:
                            signals.append({"signal": "reused_by_another_account_same_claim",
                                            "proof_sha256": sha,
                                            "other_proof_sha256": other["proof_id"]})
                        elif _phash_close(fp["phash"], other["phash"]):
                            signals.append({"signal": "reused_by_another_account",
                                            "proof_sha256": sha,
                                            "other_proof_sha256": other["proof_id"],
                                            "how": "phash"})
        finally:
            conn.close()
    except Exception as exc:  # noqa: BLE001
        return [], [f"reuse:{type(exc).__name__}"] + rejected_reasons
    return signals, rejected_reasons


def _matched_asked(page_id: str, asked: Sequence[str]) -> list[str]:
    """Which asked ids this register page id answers for.

    Equality, or a truncated prefix of at least 8 characters - never a shorter
    run that would sweep in unrelated pages.
    """
    if not page_id:
        return []
    hits: list[str] = []
    for i in asked:
        if i == page_id:
            hits.append(i)
        elif min(len(i), len(page_id)) >= 8 and (
                page_id.startswith(i) or i.startswith(page_id)):
            hits.append(i)
    return hits


def register_verdict(ids: Sequence[str], *, gdpr_db: str | Path | None = None
                     ) -> tuple[str | None, tuple[str, ...], list[str]]:
    """The GDPR register's identity verdict for these page ids.

    ``verdict_detail`` is the per-page truth (``[{"id","verdict","why"}]``); a
    row's top-level verdict is the folded one. Missing row / no detail for the
    id / UNKNOWN all mean UNKNOWN, and the caller must ASK.
    """
    ids, rejected = _safe_ids(ids)
    rejected_reasons = _rejected_reasons("identity", rejected)
    if not ids:
        return None, (), ["identity:no-ids"] + rejected_reasons
    path = Path(gdpr_db or GDPR_DB)
    if not path.is_file():
        return None, (), ["identity:register-missing"] + rejected_reasons
    verdicts: list[tuple[str, str]] = []
    matched: set[str] = set()
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
        conn.row_factory = sqlite3.Row
        try:
            for row in conn.execute(
                    "SELECT register_no, identity_verdict, verdict_detail, pages, "
                    "removed_outside_process FROM erasure_requests"):
                detail = []
                try:
                    detail = json.loads(row["verdict_detail"] or "[]")
                except ValueError:
                    detail = []
                for entry in detail:
                    page_id = str(entry.get("id") or "").lower()
                    hits = _matched_asked(page_id, ids)
                    if hits:
                        matched.update(hits)
                        verdicts.append((str(entry.get("verdict") or "UNKNOWN"),
                                         f"register:{row['register_no']}"))
                if not detail:
                    try:
                        pages = json.loads(row["pages"] or "[]")
                    except ValueError:
                        pages = []
                    for page in pages:
                        page_id = str(page.get("id") or "").lower()
                        hits = _matched_asked(page_id, ids)
                        if hits:
                            matched.update(hits)
                            verdicts.append((str(row["identity_verdict"] or "UNKNOWN"),
                                             f"register:{row['register_no']}"))
        finally:
            conn.close()
    except Exception as exc:  # noqa: BLE001
        return None, (), [f"identity:{type(exc).__name__}"] + rejected_reasons
    unmatched = [i for i in ids if i not in matched]
    if unmatched:
        # A page the register does not name is UNKNOWN, never whatever its
        # neighbour was: one registered page must not carry an unregistered one.
        return ("UNKNOWN", tuple(f"identity:no-register-row:{i}" for i in unmatched),
                rejected_reasons)
    if not verdicts:
        return "UNKNOWN", ("identity:no-register-row",), rejected_reasons
    strongest = sorted({v for v, _ in verdicts})
    basis = tuple(sorted({b for _, b in verdicts}))
    if len(strongest) == 1:
        return strongest[0], basis, rejected_reasons
    if "UNKNOWN" in strongest:
        return "UNKNOWN", basis + ("identity:mixed-with-unknown",), rejected_reasons
    return _most_restrictive(strongest), basis + ("identity:mixed",), rejected_reasons


def _most_restrictive(verdicts: Sequence[str]) -> str:
    """The most restrictive verdict, by the register's own order.

    ``gdpr_pipeline.identity.ROW_ORDER`` is the canonical fold for this concept
    ("the most restrictive page wins"); a verdict it does not know is treated as
    the most restrictive of all, so an unknown word can never permit a hide.
    """
    from gdpr_pipeline import identity  # noqa: PLC0415

    known = [v for v in verdicts if v in identity.ROW_ORDER]
    if len(known) != len(verdicts):
        return "UNKNOWN"
    return min(known, key=identity.ROW_ORDER.index)


def requester_linked(requester_email: str | None, ids: Sequence[str], *,
                     query=None) -> tuple[bool | None, tuple[str, ...], list[str]]:
    """Does any target id belong to the account named by the requester's email?

    Profile ids resolve through ``claiming``; request ids through
    ``credit_requests.userid``. A census-dominant ask ("review the proof ...
    request 8f14e45f-...") names only a request, so resolving profiles alone
    left the conflict-of-interest check silently unmeasured.
    """
    wanted, rejected = _safe_ids(ids)
    rejected_reasons = _rejected_reasons("requester-link", rejected)
    if not wanted:
        return None, (), ["requester-link:no-ids"] + rejected_reasons
    if not requester_email:
        return None, (), ["requester-link:no-requester-email"] + rejected_reasons
    query = query or _query()
    email = requester_email.strip().lower()
    evidence: list[str] = []
    try:
        for chunk in _chunked(wanted):
            lst = _sql_list(chunk)
            for row_email, profile in query(
                    "SELECT DISTINCT lower(u.email), CAST(c.profileid AS varchar) "
                    "FROM postgresql_core.public.claiming c "
                    "JOIN postgresql_core.public.users u ON u.id = c.userid "
                    f"WHERE c.deletedat IS NULL AND lower(CAST(c.profileid AS varchar)) IN ({lst})"):
                if row_email and row_email.strip().lower() == email:
                    evidence.append(f"claim:{profile}")
            for row_email, request_id in query(
                    "SELECT DISTINCT lower(u.email), CAST(c.id AS varchar) "
                    "FROM postgresql_core.public.credit_requests c "
                    "JOIN postgresql_core.public.users u ON u.id = c.userid "
                    f"WHERE c.deletedat IS NULL AND lower(CAST(c.id AS varchar)) IN ({lst})"):
                if row_email and row_email.strip().lower() == email:
                    evidence.append(f"request:{request_id}")
    except Exception as exc:  # noqa: BLE001
        return None, (), [f"requester-link:{type(exc).__name__}"] + rejected_reasons
    return bool(evidence), tuple(sorted(set(evidence))), rejected_reasons
