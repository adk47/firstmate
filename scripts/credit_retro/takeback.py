"""Role-scoped take-back: plan (dry-run), apply, read-back, revert.

The unit is a ROW = one (credit request, role). Only roles the f1 review
proved are in the manifest: a one-person role (Mixing / Mastering /
Immersive / Remastering) that a trusted source (Spotify / Tidal / MLC /
Jaxsta) credits to a different person, with a cited public-credit URL. Every
other role on the same request is never touched here.

Captain's delete rule (2026-10-15 ~20:00Z): "Deletes must confirm the credit
was removed from spotify or tidal first or prove that it is a different
profile in our system that the credit belongs to". The live GATE below
re-proves that at run time, row by row, immediately before the write:

  G1  the user is not excluded (user 15, Jay Baumgardner, is left alone)
  G2  the credit request still exists, is APPROVED, belongs to the same user,
      profile and track, and still carries the role
  G3  the claimant is not one of the track's own artists (a self-released
      artist's mixer is often the artist's legal name: alias risk)
  G4  the claimant still holds the role on the track (a live muso credit)
  G5  a trusted source credits the role to someone else and NOT to the
      claimant (by raw-profile link, display name, known-as, legal name):
      credit_review.evidence.classify_roles == CONTRADICTED
  G6  at least one person named in the manifest's evidence is still among
      those trusted holders (the cited URL still describes today's data)
  G7  a row resting on the trusted DSP credit alone (``trusted_dsp_only``) has
      a named person who is still a live holder in EACH of its cited Spotify/Tidal
      sources, the evidence URL's own source among them (``dsp_holder_vanished``
      otherwise)

The gate also RECORDS (never skips on) whether the role is the claimant's
last live credit on the track (``last_credit_on_track``): removing it also
drops the track's feed activity, which a revert does not bring back.

The gate also reads the LIVE exclusion sources, loaded fresh by every plan and apply run
(firstmate 020/021; the hand-set ``excluded`` flags stay, but are not enough). Before any
of the above: proof on file (credit-trust ``proof-on-file.json``), proof-tagged notes in
Caroline's send ledger and the committed doc-submitted manifest. Last, only for a row that
passed everything else and would be removed: org affiliation (credit-trust
``org-affiliation.json``): no verdict skips the row, and an affiliated user is human
review + a polite contact, never automatic. If a source cannot be read or is stale,
nothing is removed that run (which proof-on-file parts must be usable:
credit_review/proof_parts.py).

A row that fails any gate is SKIPPED with the reason, recorded, and left for
the verify waves. Nothing is retried around a gate.

The agent stages ONE approval set per user (core-backend #10597); Nick or Jan
decides each pair; ``apply``, from their own session, calls core-backend #10638
``POST /admin/credit-removals/:id/execute`` and sends the user's take-back notice
in the same step (firstmate 025/026). Execute spends only pairs whose own decision
is ``approved`` and removes each through ``removeTrackProfileCredits`` (a
credit_removal_events row, so the orphan reconciler never re-adds it; the
request's status is NOT changed). A set executes only once EVERY pair is decided:
core decisions are write-once, so what the execute spends cannot grow after the
live gate. Every pair a set would spend is re-proved live first; any failure
withholds the WHOLE set, never part of it. A 403 is recorded as
``refused``. Each pair is recorded as ``sent`` before the execute goes out; a lost
response (or a crash) is reconciled against live credits by apply, readback and
revert before anything is retried, reverted or reported done.

The displaced engineer's trusted credit is never written: trusted raw credits
coexist with the user claim, so "restoring" it means proving it is still
live after the removal, which the read-back does.
"""

from __future__ import annotations

import json
import os
import sqlite3
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlparse

from credit_review import affiliation, proof_parts
from credit_review.evidence import CONTRADICTED, classify_roles
from credit_review.roles import ONE_PERSON_FAMILIES, family_of, is_trusted_source, names_match

from .api import STAGE_PATH, ApiError, ReadApi
from .ledger import Ledger

EXCLUDED_USERS = frozenset({"15"})  # captain 2026-10-15 ~21:50Z: Jay Baumgardner's profile left alone
DECISION_REF = ("captain 2026-10-15 20:00Z delete rule + 22:02Z; firstmate decision 001 "
                "credit-retro-exec-r1 2026-10-15T23:09Z (role-scoped A, named-human X)")
RAW_PAGE = 200
RAW_MAX_PAGES = 10
REQUEST_SCAN_LIMIT = 100
PLAN_MAX_AGE_S = 24 * 3600
REMOVAL_KINDS = ("apply",)


# -- manifest ----------------------------------------------------------------

def load_manifest(path: str | Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if not line.strip():
                continue
            row = json.loads(line)
            for key in ("row_id", "request_id", "user_id", "profile_id", "track_id", "role", "evidence_url"):
                if not row.get(key):
                    raise ValueError(f"{path}:{n}: missing {key}")
            if family_of(row["role"]) not in ONE_PERSON_FAMILIES:
                raise ValueError(f"{path}:{n}: {row['role']!r} is not a one-person role; only those are taken back")
            if row["row_id"] in seen:
                raise ValueError(f"{path}:{n}: duplicate row_id {row['row_id']}")
            seen.add(row["row_id"])
            rows.append(row)
    return rows


EVIDENCE_KINDS = ("public_page", "trusted_dsp_only")
DSP_SOURCES = {"spotify": "Spotify", "tidal": "Tidal"}
DSP_HOSTS = {"open.spotify.com": "spotify", "listen.tidal.com": "tidal"}  # evidence URL host -> its source


def evidence_verified(row: dict[str, Any]) -> bool:
    """True when the row carries checked evidence for ITS OWN role: a public page of this
    track/release naming the other person in this role (``public_page``), or a current
    Spotify/Tidal credit on this recording naming them (``trusted_dsp_only``: sources only
    spotify/tidal, URL on open.spotify.com or listen.tidal.com and its source among them), with that URL as
    ``evidence_url``. Every name must be quoted in the recorded evidence note."""
    ev = row.get("evidence") if isinstance(row.get("evidence"), dict) else {}
    url = str(ev.get("url") or "")
    names = [str(n) for n in ev.get("names") or []]
    note = str(ev.get("note") or "").lower()
    if not (ev.get("verified") in EVIDENCE_KINDS and names and all(n and n.lower() in note for n in names)
            and url == row.get("evidence_url") and url.startswith("https://")):
        return False
    if ev.get("verified") == "trusted_dsp_only":
        sources = set(ev.get("sources") or [])
        return sources <= set(DSP_SOURCES) and DSP_HOSTS.get(urlparse(url).hostname or "") in sources
    return True


def evidence_label(row: dict[str, Any]) -> str:
    ev = row.get("evidence") or {}
    if ev.get("verified") == "trusted_dsp_only":
        return " and ".join(DSP_SOURCES[s] for s in DSP_SOURCES if s in (ev.get("sources") or [])) + " credits"
    return "public credits page"


def approval_ref(row: dict[str, Any], approval_id: str | None = None) -> str:
    """The full reference, kept in the ledger."""
    ref = f"{DECISION_REF} | {row['evidence_url']}"
    return f"credit-removal-approval {approval_id} | {ref}" if approval_id else ref


# -- live reads --------------------------------------------------------------

def find_request(api: ReadApi, row: dict[str, Any]) -> dict[str, Any] | None:
    data = api.get("/admin/credit-requests", {
        "profilesIds": row["profile_id"], "trackId": row["track_id"], "limit": REQUEST_SCAN_LIMIT})
    items = data.get("items") if isinstance(data, dict) else None
    if not isinstance(items, list):
        raise ApiError("credit-requests list has no items[]")
    return next((it for it in items if str(it.get("id")) == row["request_id"]), None)


def raw_credits(api: ReadApi, track_id: str, **filters: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for page in range(1, RAW_MAX_PAGES + 1):
        data = api.get(f"/admin/track/{track_id}/raw-credits", {**filters, "limit": RAW_PAGE, "page": page})
        items = data.get("items") if isinstance(data, dict) else None
        if not isinstance(items, list):
            raise ApiError("raw-credits has no items[]")
        out.extend(items)
        total = data.get("total")
        if not items or (isinstance(total, int) and len(out) >= total) or len(items) < RAW_PAGE:
            return out
    raise ApiError(f"raw-credits for {track_id} exceeded {RAW_MAX_PAGES} pages")


def claimant_identity(api: ReadApi, profile_id: str) -> tuple[list[str], set[tuple[str, str]], str]:
    doc = api.get(f"/admin/profile/{profile_id}")
    if not isinstance(doc, dict):
        raise ApiError("profile response is not an object")
    name = str(doc.get("name") or "")
    names = [name] + [str(a) for a in (doc.get("knownAsNames") or []) if a]
    if doc.get("legalName"):
        names.append(str(doc["legalName"]))
    if doc.get("firstName") and doc.get("lastName"):
        names.append(f"{doc['firstName']} {doc['lastName']}")
    keys = {(str(rp.get("source") or "").lower(), str(rp.get("id") or ""))
            for rp in (doc.get("rawProfiles") or []) if isinstance(rp, dict)}
    return [n for n in names if n], keys, name


def _holder(raw: dict[str, Any]) -> dict[str, str]:
    prof = raw.get("profile") or {}
    return {"source": str(prof.get("source") or "").lower(), "id": str(prof.get("id") or ""),
            "name": str(prof.get("name") or ""), "role": str(raw.get("credit") or "")}


def claimant_holds_any(raws: list[dict[str, Any]], profile_id: str) -> list[dict[str, str]]:
    return [h for h in map(_holder, raws) if h["source"] == "muso" and h["id"] == profile_id]


def claimant_holds(raws: list[dict[str, Any]], profile_id: str, family: str) -> list[dict[str, str]]:
    return [h for h in claimant_holds_any(raws, profile_id) if family_of(h["role"]) == family]


def trusted_holders(raws: list[dict[str, Any]], family: str) -> list[dict[str, str]]:
    seen: set[tuple[str, str]] = set()
    out = []
    for r in raws:
        h = _holder(r)
        if not is_trusted_source(h["source"]) or family_of(h["role"]) != family:
            continue
        if (h["source"], h["id"]) in seen:
            continue
        seen.add((h["source"], h["id"]))
        out.append(h)
    return out


# -- live exclusion sources (firstmate 020) -----------------------------------

PROOF_ON_FILE = os.environ.get("CREDIT_RETRO_PROOF_ON_FILE", "/var/lib/credit-trust/proof-on-file.json")
ORG_AFFILIATION = os.environ.get("CREDIT_RETRO_ORG_AFFILIATION", "/var/lib/credit-trust/org-affiliation.json")
PROOF_MAX_AGE = timedelta(hours=3)
CLOCK_SKEW = timedelta(minutes=5)  # a generated_at later than now + this is not "fresh", it is wrong
AFFILIATION_VERDICTS = affiliation.VERDICTS
AFFILIATED = affiliation.AFFILIATED


@dataclass
class Exclusions:
    """The live exclusion sources, read once per run. ``unavailable`` is the skip reason for
    every row when a source could not be read (nothing is removed that run)."""
    unavailable: str | None = None
    detail: str = ""
    proof_requests: dict[str, str] = field(default_factory=dict)
    proof_users: dict[str, str] = field(default_factory=dict)
    tagged_requests: set[str] = field(default_factory=set)
    tagged_accounts: set[str] = field(default_factory=set)
    doc_users: set[str] = field(default_factory=set)
    human_approved: set[str] = field(default_factory=set)
    affiliation: dict[str, dict[str, Any]] = field(default_factory=dict)


def require_fresh(generated_at: Any, now: datetime) -> None:
    """Raise ValueError unless ``generated_at`` is a timezone-aware time at most PROOF_MAX_AGE
    before ``now`` and no more than CLOCK_SKEW after it (a future stamp would otherwise stay
    "fresh" indefinitely while the data under it goes stale)."""
    generated = datetime.fromisoformat(str(generated_at).replace("Z", "+00:00"))
    if generated.tzinfo is None:
        raise ValueError(f"generated_at {generated_at} has no timezone")
    if now - generated > PROOF_MAX_AGE:
        raise ValueError(f"generated_at {generated_at} is older than {PROOF_MAX_AGE}")
    if generated - now > CLOCK_SKEW:
        raise ValueError(f"generated_at {generated_at} is in the future (more than {CLOCK_SKEW} ahead)")


def _read_proof_on_file(path: str, now: datetime) -> tuple[dict[str, str], dict[str, str]]:
    """(proof by request, proof by whole user). Which parts must be usable, and that a
    half-written export (a malformed entry, or ``users`` not the distinct user ids in
    entries[]) is refused whole, is credit_review.proof_parts (shared with the verify notes).
    Each part's freshness comes from its OWN generated_at; core carries no ``stale`` key, so
    requiring ``stale: false`` on every source would refuse every run (cs lane, firstmate 032)."""
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    require_fresh(doc["generated_at"], now)
    proof_parts.check(doc, now=now, max_age_h=PROOF_MAX_AGE.total_seconds() / 3600,
                      max_skew_h=CLOCK_SKEW.total_seconds() / 3600)
    proof_parts.check_entries(doc)
    by_request: dict[str, str] = {}
    by_user: dict[str, str] = {}
    for e in doc["entries"]:
        if (e.get("request_id") or "").strip():
            by_request[e["request_id"].strip()] = e["kind"]
        else:
            by_user[str(e["user_id"]).strip()] = e["kind"]
    return by_request, by_user


def _read_affiliation(path: str) -> dict[str, dict[str, Any]]:
    return affiliation.read(path)


def load_exclusions(*, proof_on_file: str = PROOF_ON_FILE, org_affiliation: str = ORG_AFFILIATION,
                    verify_db: str | None, doc_submitted: str | Path | None = None,
                    now: datetime | None = None) -> Exclusions:
    """Read every live exclusion source now. Never raises: a source that cannot be read (or
    proof-on-file older than 3h / with a required part unusable) makes ``unavailable`` the skip
    reason."""
    from . import waves  # noqa: PLC0415
    now = now or datetime.now(timezone.utc)
    try:
        proof_requests, proof_users = _read_proof_on_file(proof_on_file, now)
        engaged = waves.already_engaged(verify_db)
        if engaged is None:
            raise ValueError(f"send ledger {verify_db} is not readable")
        doc_users, human_approved = waves.load_doc_submitted(doc_submitted or waves.DOC_SUBMITTED)
    except (SystemExit, OSError, ValueError, KeyError, TypeError, AttributeError, sqlite3.Error) as exc:
        return Exclusions("proof_source_unavailable", str(exc))
    try:
        affiliation = _read_affiliation(org_affiliation)
    except (OSError, ValueError, TypeError) as exc:
        return Exclusions("affiliation_source_unavailable", str(exc))
    tagged_requests, tagged_accounts, _ = engaged
    return Exclusions(None, "", proof_requests, proof_users, tagged_requests, tagged_accounts,
                      doc_users, human_approved, affiliation)


def _excluded_live(excl: Exclusions, row: dict[str, Any], before: dict[str, Any]) -> str | None:
    """The skip reason from the live proof / document sources (no admin read), or None."""
    if excl.unavailable:
        before["exclusions_unavailable"] = excl.detail
        return excl.unavailable
    uid, rid = str(row["user_id"]), row["request_id"]
    kind = excl.proof_requests.get(rid) or excl.proof_users.get(uid)
    if kind:
        return f"proof_on_file:{kind}"
    if rid in excl.tagged_requests:
        return "proof_tagged"
    if uid in excl.doc_users:
        return "doc_submitted"
    if rid in excl.human_approved:
        return "human_approved_after_doc"
    return None


def _affiliation_hold(excl: Exclusions, row: dict[str, Any], before: dict[str, Any]) -> str | None:
    """For a row that passed every other gate: no verdict, or an affiliated user (human review +
    a polite contact, never automatic), holds it."""
    aff = excl.affiliation.get(str(row["user_id"]))
    if aff is not None:
        before["affiliation"] = {"verdict": aff.get("verdict"), "evidence": aff.get("evidence") or []}
    # The shared rule (credit_review.affiliation): no verdict, held, a partial check or an
    # affiliated verdict all hold the row for a human.
    return affiliation.hold_reason(excl.affiliation, row["user_id"], affiliation.ACTION_TRUSTED_REMOVAL)


# -- gate --------------------------------------------------------------------

@dataclass
class GateResult:
    ok: bool
    reason: str
    before: dict[str, Any] = field(default_factory=dict)


def gate(api: ReadApi, row: dict[str, Any], excl: Exclusions) -> GateResult:
    fam = family_of(row["role"])
    before: dict[str, Any] = {"manifest_displaced": row.get("displaced") or []}
    if str(row["user_id"]) in EXCLUDED_USERS:
        return GateResult(False, "excluded_user", before)
    if row.get("excluded"):
        return GateResult(False, "excluded_row", {**before, "excluded": row["excluded"]})
    if reason := _excluded_live(excl, row, before):
        return GateResult(False, reason, before)
    if not evidence_verified(row):
        # firstmate 012: the cited page must be this track/release and name the other
        # person in this role, or the trusted DSP credit stands alone; nothing else is removed
        return GateResult(False, "evidence_unverified", before)
    before["evidence"] = row["evidence"]
    try:
        req = find_request(api, row)
        if req is None:
            return GateResult(False, "request_not_found", before)
        before["request"] = {k: req.get(k) for k in ("id", "status", "userId", "profileId", "trackId",
                                                     "credits", "updatedAt", "spotifyTrackTitle")}
        if str(req.get("status")) != "approved":
            return GateResult(False, f"request_not_approved:{req.get('status')}", before)
        if str(req.get("userId")) != str(row["user_id"]):
            return GateResult(False, "user_mismatch", before)
        account = req.get("user") if isinstance(req.get("user"), dict) else {}
        if str(account.get("email") or "").lower() in excl.tagged_accounts:
            return GateResult(False, "proof_tagged", before)
        roles = [str(c) for c in (req.get("credits") or [])]
        if not any(c.strip().lower() == row["role"].strip().lower() for c in roles):
            return GateResult(False, "role_not_on_request", before)
        artists = [a for a in (req.get("spotifyTrackArtists") or []) if isinstance(a, dict)]
        if row["profile_id"] in {str(a.get("id")) for a in artists}:
            return GateResult(False, "claimant_is_track_artist", before)

        raws = raw_credits(api, row["track_id"], credit=row["role"])
        mine = claimant_holds(raws, row["profile_id"], fam)
        before["claimant_live"] = mine
        if not mine:
            return GateResult(False, "claimant_credit_already_gone", before)
        other = [h for h in claimant_holds_any(raw_credits(api, row["track_id"], profileId=row["profile_id"]),
                                               row["profile_id"]) if family_of(h["role"]) != fam]
        before["claimant_other_live"] = other
        before["last_credit_on_track"] = not other

        names, keys, display = claimant_identity(api, row["profile_id"])
        before["claimant_name"] = display
        # Same name as one of the track's artists (a second profile of a self-releasing
        # artist): the trusted "other" mixer is often that artist's legal name.
        if any(names_match(str(a.get("name") or ""), n) for a in artists for n in names):
            return GateResult(False, "claimant_is_track_artist", before)
        verdict = classify_roles([row["role"]], raws, names, keys)[0]
        holders = trusted_holders(raws, fam)
        before["trusted_holders"] = holders
        if verdict.status != CONTRADICTED:
            return GateResult(False, f"not_contradicted_live:{verdict.status}", before)
        named = row["evidence"]["names"]
        if not any(names_match(h["name"], d) for h in holders for d in named):
            return GateResult(False, "evidence_holder_changed", before)
        if row["evidence"]["verified"] == "trusted_dsp_only":
            # every cited source (the notice names each one; the URL's own source is among them)
            # must still credit a named person, not just any one of them
            if not all(any(h["source"] == src and names_match(h["name"], d) for h in holders for d in named)
                       for src in row["evidence"]["sources"]):
                return GateResult(False, "dsp_holder_vanished", before)
    except ApiError as exc:
        before["error"] = str(exc)
        return GateResult(False, "read_error", before)
    if reason := _affiliation_hold(excl, row, before):
        return GateResult(False, reason, before)
    return GateResult(True, "pass", before)


# -- commands ----------------------------------------------------------------

def _common(row: dict[str, Any]) -> dict[str, Any]:
    return {k: row[k] for k in ("row_id", "request_id", "user_id", "profile_id", "track_id", "role")}


def plan(api: ReadApi, ledger: Ledger, rows: list[dict[str, Any]], *, manifest: str,
         argv: list[str], excl: Exclusions, log: Callable[[str], None] = print) -> tuple[str, dict[str, int]]:
    run_id = ledger.start_run(kind="plan", actor=api.actor, manifest=manifest, argv=argv)
    counts: dict[str, int] = {}
    if excl.unavailable:
        log(f"{excl.unavailable}: {excl.detail}; nothing can be removed this run")
    for row in rows:
        res = gate(api, row, excl)
        outcome = "would_remove" if res.ok else "skip"
        key = outcome if res.ok else f"skip:{res.reason}"
        counts[key] = counts.get(key, 0) + 1
        last = res.ok and res.before.get("last_credit_on_track")
        if last:
            counts["would_remove_last_credit_on_track"] = counts.get("would_remove_last_credit_on_track", 0) + 1
        ledger.event(run_id, api.actor, **_common(row), action="gate", outcome=outcome, before=res.before,
                     evidence_url=row["evidence_url"], approval_ref=approval_ref(row), reason=res.reason)
        aff = (res.before.get("affiliation") or {}).get("verdict", "-")
        log(f"{outcome:13} {row['row_id']}  user={row['user_id']} affiliation={aff} {res.reason}"
            + (" (last credit on track)" if last else ""))
    ledger.finish_run(run_id, counts)
    return run_id, counts


def check_plan(ledger: Ledger, plan_run: str, manifest: str, *, now: float | None = None) -> None:
    """apply only executes a completed dry-run of the SAME manifest bytes."""
    from .ledger import sha256_file  # noqa: PLC0415
    run = ledger.run(plan_run)
    if run is None or run["kind"] != "plan":
        raise SystemExit(f"--plan {plan_run}: no such dry-run plan in the ledger; run `plan` first")
    if ledger.run_end(plan_run) is None:
        raise SystemExit(f"--plan {plan_run}: that dry-run did not finish")
    if run["manifest_sha256"] != sha256_file(manifest):
        raise SystemExit(f"--plan {plan_run}: the manifest changed since that dry-run; run `plan` again")
    from datetime import datetime  # noqa: PLC0415
    started = datetime.fromisoformat(run["started_at"].replace("Z", "+00:00")).timestamp()
    if (now or time.time()) - started > PLAN_MAX_AGE_S:
        raise SystemExit(f"--plan {plan_run}: older than 24h; run `plan` again")


def planned_rows(ledger: Ledger, plan_run: str, rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Only the rows the plan showed as would_remove: nothing the human never saw is removed."""
    by_id = {r["row_id"]: r for r in rows}
    return [by_id[e["row_id"]] for e in ledger.events(plan_run, "gate")
            if e["outcome"] == "would_remove" and e["row_id"] in by_id]


def _pair_key(profile_id: str, track_id: str, role: str) -> str:
    return f"{profile_id.strip().lower()}|{track_id.strip().lower()}|{role.strip().lower()}"


REASON_MAX = 2000  # core-backend #10597 normalize.js MAX_TEXT


def evidence_line(r: dict[str, Any]) -> str:
    """One pair's evidence, keyed so a reviewer can match it to the pair in the set. A row
    resting on the Spotify/Tidal credit alone says so (``evidence_class=dsp_track_level``):
    the #10597 stage body has no per-pair field for it."""
    dsp = ", evidence_class=dsp_track_level" if r["evidence"]["verified"] == "trusted_dsp_only" else ""
    return f"[{r['profile_id'][:8]}/{r['track_id'][:8]}/{r['role']}] ({evidence_label(r)}{dsp}) {r['evidence_url']}"


def chunk_for_reasons(rows: list[dict[str, Any]], head: str, limit: int = REASON_MAX) -> list[list[dict[str, Any]]]:
    """Split rows into sets so that EVERY pair's public-credit URL fits, untruncated, in
    its set's reason (Fable: an approval alone is never enough; the evidence must be
    attached). A profile+track's roles stay in one set."""
    by_pair: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for r in rows:
        by_pair.setdefault((r["profile_id"], r["track_id"]), []).append(r)
    chunks: list[list[dict[str, Any]]] = []
    cur: list[dict[str, Any]] = []
    size = len(head)
    for group in by_pair.values():
        add = sum(len(evidence_line(r)) + 2 for r in group)
        if len(head) + add > limit:
            raise SystemExit(f"evidence for {group[0]['row_id']} does not fit a set reason ({add} chars)")
        if cur and size + add > limit:
            chunks.append(cur)
            cur, size = [], len(head)
        cur.extend(group)
        size += add
    if cur:
        chunks.append(cur)
    return chunks


def stage(api, ledger: Ledger, rows: list[dict[str, Any]], *, manifest: str, plan_run: str, argv: list[str],
          log: Callable[[str], None] = print) -> tuple[str, dict[str, Any]]:
    """Stage the plan's would-remove rows as credit-removal approval sets (core-backend
    #10597 ``POST /admin/credit-removals``) for Nick or Jan to approve. Staging writes
    nothing destructive. ONE SET PER USER (firstmate 026): core #10638 execute spends every
    approved pair of a set at once, and the notice, the daily cap and every exclusion are
    per user, so one user's problem never blocks or forces another's removal. Every pair's
    public-credit URL is in its set's ``reason`` in full; a user whose evidence does not
    fit one set is not staged (``user_evidence_exceeds_one_set``) and goes to a human."""
    from .ledger import sha256_file  # noqa: PLC0415
    check_plan(ledger, plan_run, manifest)
    passing = planned_rows(ledger, plan_run, rows)
    if not passing:
        raise SystemExit(f"{plan_run}: no row passed the gate; nothing to stage")
    head = (f"{DECISION_REF}. Trusted public credits name a different person for each one-person role "
            f"below [profile/track/role] public-credit URL: ")
    by_user: dict[str, list[dict[str, Any]]] = {}
    for r in passing:
        by_user.setdefault(str(r["user_id"]), []).append(r)
    source = f"hydra credit-retro-r1 plan {plan_run}; manifest takeback-r1.jsonl sha256 {sha256_file(manifest)}"
    run_id = ledger.start_run(kind="stage", actor=api.actor, manifest=manifest, parent_run=plan_run, argv=argv)
    approvals: list[str] = []
    counts: dict[str, int] = {}
    for n, (uid, urows) in enumerate(sorted(by_user.items()), 1):
        try:
            chunks = chunk_for_reasons(urows, head)
        except SystemExit as exc:
            chunks, why = [], str(exc)
        else:
            why = "" if len(chunks) == 1 else f"{len(chunks)} sets needed"
        if why:
            for r in urows:
                ledger.event(run_id, api.actor, **_common(r), action="stage", outcome="skip",
                             evidence_url=r["evidence_url"], approval_ref=approval_ref(r),
                             reason=f"user_evidence_exceeds_one_set: {why}")
            counts["skip:user_evidence_exceeds_one_set"] = counts.get("skip:user_evidence_exceeds_one_set", 0) + len(urows)
            log(f"skip: user {uid}: evidence does not fit one set ({why}); route to a human")
            continue
        pairs: dict[tuple[str, str], list[str]] = {}
        for r in urows:
            pairs.setdefault((r["profile_id"], r["track_id"]), []).append(r["role"])
        body = {
            "kind": "credit_removal",
            "pairs": [{"profileId": p, "trackId": t, "roles": roles} for (p, t), roles in pairs.items()],
            "requestedForKind": "internal",
            "sourceRef": f"{source}; user {uid} (set {n}/{len(by_user)})",
            "reason": head + "; ".join(evidence_line(r) for r in urows),
        }
        assert len(body["reason"]) <= REASON_MAX
        status, resp = api.write("POST", STAGE_PATH, body)
        data = resp.get("data") if isinstance(resp, dict) and "data" in resp else resp
        approval_id = data.get("id") if isinstance(data, dict) and 200 <= status < 300 else None
        outcome = "staged" if approval_id else ("refused" if status == 403 else "error")
        if approval_id:
            approvals.append(approval_id)
        for r in urows:
            ledger.event(run_id, api.actor, **_common(r), action="stage", outcome=outcome, http_status=status,
                         after={"approval_id": approval_id} if approval_id else {"response": resp},
                         evidence_url=r["evidence_url"], approval_ref=approval_ref(r),
                         reason=f"credit-removal-approval {approval_id}" if approval_id else "stage failed")
        counts[outcome] = counts.get(outcome, 0) + len(urows)
        log(f"{outcome}: user {uid}, {len(urows)} roles as approval {approval_id or '-'} (HTTP {status})")
        if not approval_id:
            break
    counts["sets"] = len(approvals)
    ledger.finish_run(run_id, counts)
    return run_id, {"approval_ids": approvals, "counts": counts}


def set_problem(approval_id: str, data: Any) -> str | None:
    """Why a set as ``GET /admin/credit-removals/:id`` returned it cannot be executed, or None."""
    if not isinstance(data, dict) or data.get("status") != "approved":
        return (f"approval {approval_id} is {data.get('status') if isinstance(data, dict) else '?'}, "
                "not approved: Nick or Jan approves it first")
    exp = data.get("expiresAt")
    if exp and datetime.fromisoformat(str(exp).replace("Z", "+00:00")) <= datetime.now(timezone.utc):
        return f"approval {approval_id} expired at {exp}: stage again"
    return None


def approval_set(api: ReadApi, approval_id: str) -> dict[str, Any]:
    """An APPROVED, unexpired approval set as ``GET /admin/credit-removals/:id`` returns it."""
    data = api.get(f"{STAGE_PATH}/{approval_id}")
    if why := set_problem(approval_id, data):
        raise SystemExit(why)
    return data


def spendable_pairs(data: dict[str, Any]) -> list[dict[str, Any]]:
    """The pairs core #10638 execute would spend: the pair's OWN decision is ``approved``
    (Fable 024: a set is approved once any pair is) and it is not consumed yet."""
    return [p for p in data.get("pairs") or [] if p.get("decision") == "approved" and not p.get("consumedAt")]


def live_removed(api: ReadApi, e: dict[str, Any] | Any) -> bool | None:
    """True when the claimant no longer holds the role, False when they still do,
    None when the live read fails (the result stays unknown)."""
    try:
        raws = raw_credits(api, e["track_id"], profileId=e["profile_id"])
    except ApiError:
        return None
    return not claimant_holds(raws, e["profile_id"], family_of(e["role"]))


def reconcile(api: ReadApi, ledger: Ledger, apply_run: str, log: Callable[[str], None] = print) -> list[str]:
    """Resolve every removal of ``apply_run`` that went out with no known result (a
    crash or a lost response after sending) against live credits, and record the
    result in THAT run, so report, revert and the waves see the removal. Returns the
    row ids still unresolved (the live read failed too)."""
    left = []
    for e in ledger.unresolved_rows(apply_run):
        gone = live_removed(api, e)
        if gone is None:
            left.append(e["row_id"])
            continue
        ledger.event(apply_run, api.actor, row_id=e["row_id"], request_id=e["request_id"], user_id=e["user_id"],
                     profile_id=e["profile_id"], track_id=e["track_id"], role=e["role"], action="remove",
                     outcome="removed" if gone else "not_removed", before=json.loads(e["before_json"] or "{}"),
                     after={"reconciled": "live read"}, evidence_url=e["evidence_url"],
                     approval_ref=e["approval_ref"], reason=f"reconciled after unknown DELETE result ({e['outcome']})")
        log(f"reconciled    {e['row_id']}  {'removed' if gone else 'not_removed'} (run {apply_run})")
    return left


def reconcile_reverts(api: ReadApi, ledger: Ledger, apply_run: str,
                      log: Callable[[str], None] = print) -> list[str]:
    """Resolve every re-add (revert/restore POST) of ``apply_run`` that went out with no
    known result against live credits, recording the result in the revert run that sent
    it. Returns the row ids still unresolved."""
    left = []
    for e in ledger.unresolved_reverts(apply_run):
        gone = live_removed(api, e)
        if gone is None:
            left.append(e["row_id"])
            continue
        ledger.event(e["run_id"], api.actor, row_id=e["row_id"], request_id=e["request_id"], user_id=e["user_id"],
                     profile_id=e["profile_id"], track_id=e["track_id"], role=e["role"], action="revert",
                     outcome="not_re_added" if gone else "re_added", before=json.loads(e["before_json"] or "{}"),
                     after={"reconciled": "live read"}, evidence_url=e["evidence_url"],
                     approval_ref=e["approval_ref"], reason=f"reconciled after unknown re-add result ({e['outcome']})")
        log(f"reconciled    {e['row_id']}  {'not_re_added' if gone else 're_added'} (revert of {apply_run})")
    return left


def require_reconciled(api: ReadApi, ledger: Ledger, apply_runs: list[str], log: Callable[[str], None] = print) -> None:
    left = {run: ids for run in apply_runs if (ids := reconcile(api, ledger, run, log))}
    left_re = {run: ids for run in apply_runs if (ids := reconcile_reverts(api, ledger, run, log))}
    if left or left_re:
        raise SystemExit(f"results still unknown (live read failed): DELETE {left}, re-add {left_re}; re-run when "
                         "the admin API answers: nothing is retried, reverted, prepared or reported as complete "
                         "until they are known")


def account_of(api: ReadApi, rows: list[dict[str, Any]]) -> tuple[dict[str, Any] | None, str]:
    """The ACCOUNT (id, email, first name) on the first of ``rows``' credit requests that
    still exists AND still belongs to the planned user (request ``userId`` and its account
    id), for the take-back notice; never written to the ledger. A request that moved to
    another user never names the recipient. (None, reason) when no such request exists:
    ``user_mismatch`` if one exists but belongs to someone else, else ``request_not_found``."""
    reason = "request_not_found"
    for row in rows:
        req = find_request(api, row)
        if req is None:
            continue
        acct = req.get("user") if isinstance(req.get("user"), dict) else {}
        if not str(req.get("userId")) == str(acct.get("id")) == str(row["user_id"]):
            reason = "user_mismatch"
            continue
        return {"id": acct.get("id"), "email": acct.get("email"),
                "first_name": (str(acct.get("fullName") or "").split() or [None])[0]}, ""
    return None, reason


def notice_preflight(api: ReadApi, sender, rows: list[dict[str, Any]],
                     log: Callable[[str], None] = print) -> tuple[dict[str, dict[str, Any]], dict[str, str]]:
    """Before any execute: every user who may lose a role must be reachable through
    Caroline's gate with the fixed take-back notice, TODAY. Returns (user_id -> account,
    user_id -> skip reason for users whose roles are not removed this run: the gate would
    defer their notice, or none of their requests still belongs to them). Any other refusal
    refuses the whole run (captain via firstmate 012/014: never remove without the message
    going out)."""
    from . import notice  # noqa: PLC0415
    accounts: dict[str, dict[str, Any]] = {}
    held: dict[str, str] = {}
    problems = []
    for uid, rs in notice.by_user(rows).items():
        try:
            acct, why = account_of(api, rs)
        except ApiError as exc:
            problems.append(f"user {uid}: {exc}")
            continue
        if acct is None:
            held[uid] = why
            log(f"no request still owned by user {uid} ({why}): nothing of theirs is removed")
            continue
        if not acct["email"]:
            problems.append(f"user {uid}: no account email on the request")
            continue
        accounts[uid] = acct
        verdict, msg = sender.validate(notice.credits_file(acct, [notice.notice_credit(r) for r in rs]))
        if verdict == "deferred":
            held[uid] = "notice_would_defer"
            log(f"notice would defer for user {uid} ({msg}): their roles wait for a later run")
        elif verdict != "valid":
            problems.append(f"user {uid}: notice refused by the send gate: {msg}")
    if problems:
        raise SystemExit("take-back notices cannot be sent, so nothing is removed:\n  " + "\n  ".join(problems))
    log(f"notice preflight: {sum(1 for u in accounts if u not in held)} users reachable today "
        f"through {notice.CAMPAIGN}")
    return accounts, held


def unnotified_row_ids(ledger: Ledger, apply_run: str) -> list[str]:
    """Rows ``apply_run`` removed (incl. a later live reconcile), not re-added by a revert,
    and not covered by a ``sent`` take-back notice."""
    done = {rid for e in ledger.events(apply_run, "notify") if e["outcome"] == "sent"
            for rid in json.loads(e["after_json"] or "{}").get("row_ids", [])}
    reverted = ledger.reverted_row_ids(apply_run)
    return [e["row_id"] for e in ledger.removed_rows(apply_run)
            if e["row_id"] not in done and e["row_id"] not in reverted]


def require_notified(ledger: Ledger, apply_run: str) -> None:
    """Stop, loudly, while ``apply_run`` has a removed role whose take-back notice did not go
    out: the run is never reported as complete, and no new role is removed until it is sent."""
    owed = unnotified_row_ids(ledger, apply_run)
    if owed:
        raise SystemExit(f"apply run {apply_run} removed {len(owed)} role(s) whose take-back notice was not "
                         f"sent: {owed}. Nothing new is removed until it is: re-run `notify --run {apply_run}` "
                         "(a deferred notice goes on the next UTC day) or escalate to #clio_devops")


def send_notices(ledger: Ledger, apply_run: str, actor: str, sender, rows: list[dict[str, Any]],
                 accounts: dict[str, dict[str, Any]], log: Callable[[str], None] = print) -> dict[str, int]:
    """One notice per user for the roles ``apply_run`` removed that no notice covered yet
    (and no revert re-added). Recorded in the apply run (action ``notify``) with the
    human who approved the notice."""
    from . import notice  # noqa: PLC0415
    by_id = {r["row_id"]: r for r in rows}
    removed = [by_id[rid] for rid in unnotified_row_ids(ledger, apply_run) if rid in by_id]
    counts: dict[str, int] = {}
    for uid, rs in sorted(notice.by_user(removed).items()):
        acct = accounts.get(uid)
        if not acct:
            outcome, msg = "failed", "no account resolved for this user"
        else:
            outcome, msg = sender.send(notice.credits_file(acct, [notice.notice_credit(r) for r in rs]))
        counts[f"notice_{outcome}"] = counts.get(f"notice_{outcome}", 0) + 1
        ledger.event(apply_run, actor, row_id=f"user:{uid}", user_id=uid, action="notify", outcome=outcome,
                     after={"row_ids": [r["row_id"] for r in rs], "campaign": notice.CAMPAIGN, "detail": msg,
                            "approved_by": sender.approved_by},
                     reason="take-back notice")
        log(f"notice {outcome:8} user {uid}  {len(rs)} role(s)")
    return counts


EXECUTE_REMOVED = ("removed", "already_executed")
Index = dict[str, list[dict[str, Any]]]


def _key_of(p: dict[str, Any]) -> str:
    return _pair_key(p["profileId"], p["trackId"], p["role"])


def _index(rows: list[dict[str, Any]]) -> Index:
    """Rows by pair key. Two requests can claim the same profile/track/role (Fable: 161128's two
    "Autentica" requests): core holds ONE pair for them, and its result is every such row's result."""
    by_key: Index = {}
    for r in rows:
        by_key.setdefault(_pair_key(r["profile_id"], r["track_id"], r["role"]), []).append(r)
    return by_key


def _pair_row_id(p: dict[str, Any]) -> str:
    return f"pair:{p['profileId']}/{p['trackId']}/{p['role']}"


@dataclass
class ExecSet:
    """One user's approval set, mapped back to the plan's rows."""
    approval_id: str
    user_id: str = ""
    rows: list[dict[str, Any]] = field(default_factory=list)      # plan rows of the pairs execute would spend
    unknown: list[dict[str, Any]] = field(default_factory=list)   # spendable pairs that are no row of the plan
    consumed: list[dict[str, Any]] = field(default_factory=list)  # manifest rows of pairs consumed outside the tool
    withheld: str = ""                                             # why the WHOLE set is not executed


def _exec_sets(api: ReadApi, approvals: list[str], planned: Index, manifest_rows: Index) -> list[ExecSet]:
    """Read every set before anything is executed: a set must be approved and unexpired, belong
    to ONE user, every pair it would spend must be a row of this plan, and every pair must be
    decided. Core decisions are write-once (``decision IS NULL`` guards every decide path), so
    an undecided pair is the only way what the execute spends could grow after the live gate:
    a pair approved between the gate and the POST would be removed un-proved and unannounced."""
    out = []
    for aid in dict.fromkeys(approvals):
        data = approval_set(api, aid)
        spend = spendable_pairs(data)
        es = ExecSet(aid)
        es.unknown = [p for p in spend if _key_of(p) not in planned]
        es.rows = [r for p in spend for r in planned.get(_key_of(p), [])]
        es.consumed = [r for p in data.get("pairs") or [] if p.get("consumedAt")
                       for r in manifest_rows.get(_key_of(p), [])]
        users = {str(r["user_id"]) for r in es.rows}
        es.user_id = next(iter(users)) if len(users) == 1 else ",".join(sorted(users))
        if es.unknown:
            es.withheld = f"pair_not_in_plan:{len(es.unknown)}"
        elif len(users) > 1:
            es.withheld = "set_spans_users"
        elif any(p.get("decision") not in ("approved", "rejected") for p in data.get("pairs") or []):
            es.withheld = "pair_undecided"
        out.append(es)
    return out


def apply(api, ledger: Ledger, rows: list[dict[str, Any]], *, manifest: str, plan_run: str,
          argv: list[str], approvals: list[str], excl: Exclusions, sender=None,
          pause_s: float = 0.5, log: Callable[[str], None] = print) -> tuple[str, dict[str, int]]:
    """Execute approved take-back sets through core #10638 ``POST /admin/credit-removals/:id/execute``
    from the named human's own session, and send each user's take-back notice in the same step
    (firstmate 025/026). Per set (= one user): every pair it would spend is re-proved live (gate,
    proof on file, affiliation, evidence) and the user's notice is pre-flighted; ANY failure
    withholds the WHOLE set, never part of it, and routes it to the human with the reason (core
    cannot un-approve a decided pair). A set with any undecided pair is withheld
    (``pair_undecided``) until Nick/Jan decide every pair, so the execute spends exactly the pairs
    that were gated. The server spends only pairs whose own decision is ``approved``; a notice
    names only the pairs it reports removed.
    A pair consumed with no removal of this manifest's apply runs (executed outside the tool) is
    resolved by a live read and announced when gone."""
    from .ledger import sha256_file  # noqa: PLC0415
    check_plan(ledger, plan_run, manifest)
    if excl.unavailable:
        raise SystemExit(f"{excl.unavailable}: {excl.detail}; nothing is removed this run (firstmate 020)")
    if sender is None:
        raise SystemExit("apply needs the take-back notice sender (Caroline's gate): every removal tells its user")
    if not approvals:
        raise SystemExit("apply executes only sets Nick or Jan approved: run `stage`, get the set approved, "
                         "then pass --approval <id>")
    planned = _index(planned_rows(ledger, plan_run, rows))
    sets = _exec_sets(api, approvals, planned, _index(rows))
    # an earlier run's removal with no known result is resolved before anything is retried
    earlier_runs = ledger.apply_runs(sha256_file(manifest))
    require_reconciled(api, ledger, earlier_runs, log)
    # ...and a removal resolved only now (or whose notice failed) is announced before anything new
    counts: dict[str, int] = {}
    for prior in earlier_runs:
        for k, v in notify(api, ledger, prior, rows, sender, log).items():
            counts[f"earlier_{k}"] = counts.get(f"earlier_{k}", 0) + v
    ours = {e["row_id"] for prior in earlier_runs for e in ledger.removed_rows(prior)}
    for es in sets:
        es.consumed = [r for r in es.consumed if r["row_id"] not in ours]
    accounts, held = notice_preflight(api, sender, [r for es in sets if not es.withheld for r in es.rows]
                                      + [r for es in sets for r in es.consumed], log)
    for es in sets:
        if not es.withheld and es.user_id in held:
            es.withheld = held[es.user_id]
    run_id = ledger.start_run(kind="apply", actor=api.actor, manifest=manifest, parent_run=plan_run, argv=argv)

    def bump(key: str, n: int = 1) -> None:
        counts[key] = counts.get(key, 0) + n

    try:
        for es in sets:
            if not _execute_set(api, ledger, run_id, es, excl, bump, log):
                break
            time.sleep(pause_s)
    finally:
        try:
            # the removals that happened are announced, whatever stopped the loop
            counts.update(send_notices(ledger, run_id, api.actor, sender, rows, accounts, log))
        finally:
            ledger.finish_run(run_id, counts)
    require_notified(ledger, run_id)
    return run_id, counts


def _withhold(ledger: Ledger, run_id: str, actor: str, es: ExecSet, reasons: dict[str, str],
              befores: dict[str, dict[str, Any]], bump, log: Callable[[str], None]) -> None:
    """The WHOLE set stays unexecuted (approved, unspent until it expires); the human gets why."""
    for r in es.rows:
        why = reasons.get(r["row_id"]) or (es.withheld if not reasons else "with_set")
        ledger.event(run_id, actor, **_common(r), action="gate", outcome="withheld", before=befores.get(r["row_id"]),
                     evidence_url=r["evidence_url"], approval_ref=approval_ref(r, es.approval_id),
                     reason=why if why == es.withheld else f"{why} (set withheld: {es.withheld})")
        bump(f"withheld:{why}")
    for p in es.unknown:
        ledger.event(run_id, actor, row_id=_pair_row_id(p), user_id=es.user_id or None, profile_id=p["profileId"],
                     track_id=p["trackId"], role=p["role"], action="gate", outcome="withheld",
                     approval_ref=f"credit-removal-approval {es.approval_id}", reason="pair_not_in_plan")
        bump("withheld:pair_not_in_plan")
    bump("withheld_sets")
    log(f"WITHHELD      approval {es.approval_id} user {es.user_id}: {es.withheld} (whole set, nothing removed; "
        "Nick/Jan decide: it stays approved and unspent until it expires)")


def _resolve_consumed(api, ledger: Ledger, run_id: str, es: ExecSet, bump, log: Callable[[str], None]) -> None:
    """A pair consumed with no removal recorded by this manifest's apply runs was executed outside
    the tool (the board): the live credit decides. Gone is a removal, announced in this run;
    still credited is withheld for Nick/Jan; an unreadable credit stays unresolved."""
    for r in es.consumed:
        gone = live_removed(api, r)
        ref = approval_ref(r, es.approval_id)
        if gone is False:
            ledger.event(run_id, api.actor, **_common(r), action="gate", outcome="withheld",
                         evidence_url=r["evidence_url"], approval_ref=ref, reason="consumed_still_credited")
            bump("withheld:consumed_still_credited")
            log(f"WITHHELD      {r['row_id']}  approval {es.approval_id}: pair consumed outside credit-retro, "
                "credit still live; Nick/Jan decide")
            continue
        outcome = "removed" if gone else "indeterminate"
        ledger.event(run_id, api.actor, **_common(r), action="remove", outcome=outcome,
                     after={"executed_outside_tool": es.approval_id}, evidence_url=r["evidence_url"],
                     approval_ref=ref, reason="executed_outside_tool" + ("" if gone else "; live read failed"))
        bump(outcome)
        bump("executed_outside_tool")
        log(f"{outcome:13} {r['row_id']}  executed outside credit-retro (approval {es.approval_id})")


def _resolve_lost(api, ledger: Ledger, run_id: str, es: ExecSet, befores: dict[str, dict[str, Any]],
                  status: int | None, what: str, after: dict[str, Any], bump, log: Callable[[str], None]) -> None:
    """The execute's result is unknown: each pair's live credit decides."""
    for r in es.rows:
        gone = live_removed(api, r)
        outcome = "indeterminate" if gone is None else ("removed" if gone else "not_removed")
        _record_result(ledger, run_id, api.actor, es, r, befores, outcome, status, f"{what}; live read: {outcome}",
                       after, bump, log)


def _execute_set(api, ledger: Ledger, run_id: str, es: ExecSet, excl: Exclusions, bump,
                 log: Callable[[str], None]) -> bool:
    """Re-prove, then execute one set. Returns False when the run must stop (session refused,
    or no usable response from the server)."""
    _resolve_consumed(api, ledger, run_id, es, bump, log)
    if not es.rows and not es.unknown:
        log(f"nothing to spend in approval {es.approval_id} (every pair consumed or not approved)")
        return True
    reasons: dict[str, str] = {}
    befores: dict[str, dict[str, Any]] = {}
    if not es.withheld:
        for r in es.rows:
            res = gate(api, r, excl)  # re-proved immediately before the execute
            befores[r["row_id"]] = res.before
            if not res.ok:
                reasons[r["row_id"]] = res.reason
        if reasons:
            es.withheld = "live_gate:" + ",".join(sorted(set(reasons.values())))
    if es.withheld:
        _withhold(ledger, run_id, api.actor, es, reasons, befores, bump, log)
        return True
    for r in es.rows:
        ledger.event(run_id, api.actor, **_common(r), action="gate", outcome="pass", before=befores[r["row_id"]],
                     evidence_url=r["evidence_url"], approval_ref=approval_ref(r, es.approval_id), reason="")
        # intent first: a crash or a lost response leaves a `sent` row that reconcile resolves
        ledger.event(run_id, api.actor, **_common(r), action="remove", outcome="sent", before=befores[r["row_id"]],
                     evidence_url=r["evidence_url"], approval_ref=approval_ref(r, es.approval_id),
                     reason=f"execute sent ({es.approval_id})")
    try:
        status, body = api.write("POST", f"{STAGE_PATH}/{es.approval_id}/execute", {})
    except ApiError as exc:
        _resolve_lost(api, ledger, run_id, es, befores, None, "no execute response",
                      {"transport_error": str(exc)}, bump, log)
        log(f"transport error on approval {es.approval_id}; stopping. {exc}")
        bump("stopped_on_transport_error")
        return False
    err = body.get("errorCode") if isinstance(body, dict) else None
    if status == 403:
        for r in es.rows:
            _record_result(ledger, run_id, api.actor, es, r, befores, "refused", status, err or f"HTTP {status}",
                           {"response": body}, bump, log)
        # every refusal is about the SESSION (agent token, stale sign-in, impersonation)
        log("server refused the session; stopping. Sign in again (nick@/jan@) and re-run")
        bump("stopped_on_refusal")
        return False
    if not 200 <= status < 300:
        # a gateway error can arrive after core executed: a lost response, never a final error
        _resolve_lost(api, ledger, run_id, es, befores, status, f"execute HTTP {status}{(' ' + err) if err else ''}",
                      {"response": body}, bump, log)
        log(f"execute of approval {es.approval_id} answered HTTP {status}; resolved by live read; stopping")
        bump("stopped_on_error_response")
        return False
    data = body.get("data") if isinstance(body, dict) and "data" in body else body
    results = {_key_of(x): x for x in (data.get("results") if isinstance(data, dict) else None) or []}
    for r in es.rows:
        res = results.get(_pair_key(r["profile_id"], r["track_id"], r["role"])) or {}
        st = res.get("status") or "missing"
        if st in EXECUTE_REMOVED:
            outcome, why = "removed", f"execute {st}"
        else:
            # not spent, or spent with an unknown result: the live credit decides; never a notice on a guess
            gone = live_removed(api, r)
            outcome = "indeterminate" if gone is None else ("removed" if gone else
                                                            ("refused" if st == "refused" else "not_removed"))
            why = f"execute {st}{(' ' + res['code']) if res.get('code') else ''}; live read: {outcome}"
        _record_result(ledger, run_id, api.actor, es, r, befores, outcome, status, why,
                       {"execute": res} if outcome != "removed" else {"removal_event_id": res.get("removalEventId")},
                       bump, log)
    return True


def _record_result(ledger: Ledger, run_id: str, actor: str, es: ExecSet, r: dict[str, Any],
                   befores: dict[str, dict[str, Any]], outcome: str, status: int | None, reason: str,
                   after: dict[str, Any], bump, log: Callable[[str], None]) -> None:
    ledger.event(run_id, actor, **_common(r), action="remove", outcome=outcome, http_status=status,
                 before=befores.get(r["row_id"]), after=after, evidence_url=r["evidence_url"],
                 approval_ref=approval_ref(r, es.approval_id), reason=reason)
    bump(outcome)
    log(f"{outcome:13} {r['row_id']}  {reason}")


def notify(api: ReadApi, ledger: Ledger, apply_run: str, rows: list[dict[str, Any]], sender,
           log: Callable[[str], None] = print) -> dict[str, int]:
    """Send the take-back notices of ``apply_run`` that are still owed: deferred or failed
    sends, and removals a later live reconcile confirmed. Re-added roles are never announced.
    Raises SystemExit (``require_notified``) while any notice is still owed afterwards."""
    from . import notice  # noqa: PLC0415
    run = ledger.run(apply_run)
    if run is None or run["kind"] != "apply":
        raise SystemExit(f"{apply_run}: not an apply run")
    by_id = {r["row_id"]: r for r in rows}
    removed = [by_id[rid] for rid in unnotified_row_ids(ledger, apply_run) if rid in by_id]
    accounts = {}
    for uid, rs in notice.by_user(removed).items():
        if (acct := account_of(api, rs)[0]) is not None and acct["email"]:
            accounts[uid] = acct
    counts = send_notices(ledger, apply_run, api.actor, sender, rows, accounts, log)
    require_notified(ledger, apply_run)
    return counts


def readback(api: ReadApi, ledger: Ledger, apply_run: str, *, argv: list[str],
             log: Callable[[str], None] = print) -> tuple[str, dict[str, int]]:
    """After an apply: the claimant's role is gone, the trusted holders remain."""
    run = ledger.run(apply_run)
    if run is None or run["kind"] not in REMOVAL_KINDS + ("revert",):
        raise SystemExit(f"{apply_run}: not an apply or revert run")
    want_present = run["kind"] == "revert"
    if want_present:
        # resolve this revert's unknown re-adds (recorded in this run) before reading back
        require_reconciled(api, ledger, [run["parent_run"]], log)
        last: dict[str, Any] = {}
        for e in ledger.events(apply_run, "revert"):
            last[e["row_id"]] = e
        done = [e for e in last.values() if e["outcome"] == "re_added"]
    else:
        require_reconciled(api, ledger, [apply_run], log)
        done = ledger.removed_rows(apply_run)
    run_id = ledger.start_run(kind="readback", actor=api.actor, parent_run=apply_run, argv=argv)
    counts: dict[str, int] = {}
    for e in done:
        before = json.loads(e["before_json"] or "{}")
        fam = family_of(e["role"])
        after: dict[str, Any] = {}
        try:
            mine = claimant_holds(raw_credits(api, e["track_id"], profileId=e["profile_id"]), e["profile_id"], fam)
            holders = trusted_holders(raw_credits(api, e["track_id"], credit=e["role"]), fam)
        except ApiError as exc:
            outcome, after = "read_error", {"error": str(exc)}
        else:
            prior = [p for p in (before.get("trusted_holders") or []) if family_of(p.get("role", "")) == fam]
            missing = [p for p in prior if not any((p["source"], p["id"]) == (h["source"], h["id"]) for h in holders)]
            after = {"claimant_live": mine, "trusted_holders": holders, "trusted_missing": missing}
            claimant_ok = bool(mine) if want_present else not mine
            if want_present:
                outcome = "re_added_live" if claimant_ok else "pending"
            elif claimant_ok and not missing:
                outcome = "removed_trusted_intact"
            elif claimant_ok:
                outcome = "removed_trusted_changed"
            else:
                outcome = "pending"  # ingestion is asynchronous; re-run readback
        counts[outcome] = counts.get(outcome, 0) + 1
        ledger.event(run_id, api.actor, row_id=e["row_id"], request_id=e["request_id"], user_id=e["user_id"],
                     profile_id=e["profile_id"], track_id=e["track_id"], role=e["role"], action="readback",
                     outcome=outcome, before=before, after=after, evidence_url=e["evidence_url"],
                     approval_ref=e["approval_ref"])
        log(f"{outcome:24} {e['row_id']}")
    ledger.finish_run(run_id, counts)
    return run_id, counts


def revert(api, ledger: Ledger, apply_run: str, *, argv: list[str], pause_s: float = 0.5,
           requests: set[str] | None = None, ref: str | None = None,
           log: Callable[[str], None] = print) -> tuple[str, dict[str, int]]:
    """Re-add exactly the roles ``apply_run`` removed and no revert re-added yet.
    ``requests`` narrows it to some credit requests: that is the RESTORE path when
    valid proof arrives after removal."""
    run = ledger.run(apply_run)
    if run is None or run["kind"] not in REMOVAL_KINDS:
        raise SystemExit(f"{apply_run}: not an apply run")
    require_reconciled(api, ledger, [apply_run], log)
    already = ledger.reverted_row_ids(apply_run)
    todo = [e for e in ledger.removed_rows(apply_run) if e["row_id"] not in already
            and (requests is None or e["request_id"] in requests)]
    if requests is not None and not todo:
        raise SystemExit(f"{apply_run}: nothing removed (and not yet restored) for {sorted(requests)}")
    ref = ref or f"revert of {apply_run}"
    run_id = ledger.start_run(kind="revert", actor=api.actor, parent_run=apply_run, argv=argv)
    counts: dict[str, int] = {"already_reverted": len(already)} if already and requests is None else {}
    for e in todo:
        path = f"/admin/track/{e['track_id']}/profile/{e['profile_id']}/credits"
        common = dict(row_id=e["row_id"], request_id=e["request_id"], user_id=e["user_id"],
                      profile_id=e["profile_id"], track_id=e["track_id"], role=e["role"], action="revert",
                      before=json.loads(e["before_json"] or "{}"), evidence_url=e["evidence_url"], approval_ref=ref)
        # intent first: a crash or a lost response leaves a `sent` re-add that reconcile resolves
        ledger.event(run_id, api.actor, **common, outcome="sent", reason=f"re-add sent ({apply_run})")
        try:
            status, body = api.write("POST", path, {"credits": [e["role"]]}, headers={"X-Removal-Approval-Ref": ref})
        except ApiError as exc:
            gone = live_removed(api, e)
            outcome = "indeterminate" if gone is None else ("not_re_added" if gone else "re_added")
            ledger.event(run_id, api.actor, **common, outcome=outcome, after={"transport_error": str(exc)},
                         reason=f"no re-add response; live read: {outcome}")
            counts[outcome] = counts.get(outcome, 0) + 1
            log(f"{outcome:13} {e['row_id']}  transport error; stopping. {exc}")
            counts["stopped_on_transport_error"] = 1
            break
        outcome = "re_added" if 200 <= status < 300 else ("refused" if status == 403 else "error")
        counts[outcome] = counts.get(outcome, 0) + 1
        ledger.event(run_id, api.actor, **common, outcome=outcome, http_status=status,
                     after={"response": body if outcome != "re_added" else None}, reason=f"revert {apply_run}")
        log(f"{outcome:13} {e['row_id']}  HTTP {status}")
        time.sleep(pause_s)
    ledger.finish_run(run_id, counts)
    return run_id, counts


def report(ledger: Ledger, run_id: str, *, script: str = "/opt/hydra/scripts/credit-retro.py") -> dict[str, Any]:
    """Counts, every row the server refused or that errored, and the revert command."""
    run = ledger.run(run_id)
    if run is None:
        raise SystemExit(f"{run_id}: no such run")
    end = ledger.run_end(run_id)
    events = ledger.events(run_id)
    out: dict[str, Any] = {
        "run_id": run_id, "kind": run["kind"], "actor": run["actor"], "parent_run": run["parent_run"],
        "started_at": run["started_at"], "finished_at": end["finished_at"] if end else None,
        "counts": json.loads(end["counts_json"]) if end else None,
        "jsonl": str(ledger.jsonl_path(run_id)),
    }
    if run["kind"] in ("plan",) + REMOVAL_KINDS:
        # firstmate 020: affiliated users are human review + a polite contact, never automatic
        out["needs_human_review"] = [
            {"row_id": e["row_id"], "user_id": e["user_id"], "role": e["role"], "track_id": e["track_id"],
             "affiliation": json.loads(e["before_json"] or "{}").get("affiliation")}
            for e in events if e["action"] == "gate" and e["reason"] == "org_affiliated"]
    if run["kind"] in REMOVAL_KINDS:
        results = ledger.remove_results(run_id)
        removed = [e for e in results if e["outcome"] == "removed"]
        out["removed"] = len(removed)
        out["removed_users"] = len({e["user_id"] for e in removed})
        out["last_credit_on_track"] = [e["row_id"] for e in removed
                                       if json.loads(e["before_json"] or "{}").get("last_credit_on_track")]
        out["server_refused_or_error"] = [
            {"row_id": e["row_id"], "outcome": e["outcome"], "http_status": e["http_status"], "reason": e["reason"]}
            for e in results if e["outcome"] != "removed"]
        # sent / indeterminate: the removal went out with no known result; readback, revert or
        # the next apply reconciles them against live credits before anything else
        out["unresolved"] = [e["row_id"] for e in ledger.unresolved_rows(run_id)]
        # removed and still owed their take-back notice: the next apply or `notify --run` sends it
        out["unnotified"] = unnotified_row_ids(ledger, run_id)
        out["skipped"] = [{"row_id": e["row_id"], "reason": e["reason"]}
                          for e in events if e["action"] == "gate" and e["outcome"] in ("skip", "withheld")]
        # firstmate 026: a whole user set held back; Nick/Jan get the reason (it stays approved and unspent)
        out["withheld"] = [{"row_id": e["row_id"], "user_id": e["user_id"], "reason": e["reason"],
                            "approval": (e["approval_ref"] or "").split(" | ")[0]}
                           for e in events if e["action"] == "gate" and e["outcome"] == "withheld"]
        out["revert_command"] = f"python3 {script} revert --run {run_id} --login"
    return out
