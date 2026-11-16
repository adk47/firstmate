"""The claim document ladder's reader: everything `doc_ladder` decides on, read once, read-only.

    python3 -m claim_verify.doc_sources --out SNAPSHOT.json     read only; decide nothing
    python3 -m claim_verify.doc_sources --tick                  the scheduled pass (claim-doc-ladder.timer)

One snapshot holds, for every OPEN claim whose claimant has a document on file:

  the claim         core `claiming` + the account's own names (`users`), through Trino
  its contradiction `decline_rules.live_snapshots` - the claim side's own fresh facts, the same
                    read the decline executor trusts
  its releases      the profile's catalog track titles (`matvw_profile_credit`), compared with the
                    tracks each document names under doc-verify's one title rule
  bound code        the scheduled claim list (`claim_list.LIVE_LIST`): which claims' codes were
                    found on a bound page
  account hold      the fraud lens's hold ledger, through its one reader
  the documents     `proof_intake` rows for the account (any subject), each with doc-verify's
                    newest recorded extraction, its blocking verdicts and how many OTHER accounts
                    filed the same bytes

Nothing here extracts: the extraction is the one doc-verify already recorded (`dv_steps`, step
`extract`), keyed by the document's sha256. A document doc-verify never read has no extraction and
the ladder says so (`unreadable: not_extracted`).

UNMEASURED IS NOT A PASS. A source that cannot be read is recorded as unread (`None`), which the
ladder turns into its own review reason; it is never written as "no hold" or "no code found". The
two reads the ladder cannot run without (open claims, the two stores) raise.

The snapshot holds names and document contents: it is written 0600 and belongs under
/var/lib/hydra/claim-doc-ladder, never in the repo.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Callable, Iterable

_SCRIPTS = Path(__file__).resolve().parents[1]
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))

from claim_verify import decline_rules, doc_ladder  # noqa: E402
from claim_verify import forms as forms_mod  # noqa: E402
from credit_review import doc_approve  # noqa: E402
from credit_verify.docverify import extract, gate, runner  # noqa: E402
from lib import page_identity  # noqa: E402

TRINO = "/opt/hydra/scripts/trino-query.sh"
CHUNK = 400
Run = Callable[[str], str]


def trino(sql: str) -> str:
    """Read-only query against the core replica; raw output, the shape `decline_rules` reads."""
    p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=900, check=False)
    if p.returncode != 0:
        raise RuntimeError(f"trino failed rc={p.returncode}: {p.stderr.strip()[-300:]}")
    return p.stdout


def _chunks(items: list[Any], n: int = CHUNK) -> Iterable[list[Any]]:
    for i in range(0, len(items), n):
        yield items[i:i + n]


def open_claims(run: Run) -> tuple[list[dict[str, Any]], list[int]]:
    """Every open claim with the account's own names, and the ids of the open claims that have no
    account at all (a team's claim: 522 of 3,270 on 2026-11-12). Those are counted, never dropped
    without a word; an account whose `users` row is gone is still listed, with no name (LEFT JOIN).
    A short row is an error, not a skipped claim."""
    statuses = ",".join(f"'{s}'" for s in decline_rules.OPEN_STATUSES)
    out: list[dict[str, Any]] = []
    no_account: list[int] = []
    for rec in decline_rules._rows(run(
            "select cast(c.id as varchar), cast(c.userid as varchar), lower(c.profileid), lower(c.profiletype), "
            "c.status, coalesce(u.firstname, ''), coalesce(u.lastname, ''), coalesce(u.fullname, '') "
            "from postgresql_core.public.claiming c left join postgresql_core.public.users u on u.id = c.userid "
            f"where c.deletedat is null and c.status in ({statuses})")):
        if len(rec) != 8:
            raise RuntimeError(f"open claims read: {len(rec)} columns, expected 8")
        cid, uid, pid, ptype, status, first, last, full = rec
        if not cid.isdigit():
            raise RuntimeError(f"open claims read: claim id {cid!r}")
        if not uid.isdigit():
            no_account.append(int(cid))        # a team's claim: no account, so no account's documents
            continue
        names = []
        for n in (full.strip(), f"{first.strip()} {last.strip()}".strip()):
            if n and n not in names:
                names.append(n)
        out.append({"claim_id": int(cid), "user_id": int(uid), "profile_id": pid, "profile_type": ptype,
                    "status": status, "claimant_names": names})
    if not out and not no_account:
        # the pass retires every standing decision the snapshot does not hold, so a read that
        # answered with nothing must never pass for "no claim is open"
        raise RuntimeError("open claims read: no rows")
    return out, no_account


def documents(proof_db: sqlite3.Connection, doc_db: sqlite3.Connection,
              user_ids: Iterable[int]) -> dict[str, list[dict[str, Any]]]:
    """user id -> the documents on file for that account, each with its recorded extraction."""
    users = sorted({int(u) for u in user_ids})
    rows: list[tuple] = []
    for part in _chunks(users):
        marks = ",".join("?" * len(part))
        rows += proof_db.execute(
            "SELECT intake_id, user_id, subject, file_sha256, file_path, received_at FROM proof_intake "
            f"WHERE user_id IN ({marks}) ORDER BY received_at, intake_id", part).fetchall()
    shas = sorted({str(r[3]).lower() for r in rows if r[3]})
    filers: dict[str, set[int]] = {}
    extraction: dict[str, tuple[str, Any]] = {}
    blocking: dict[str, set[str]] = {}
    not_json: set[str] = set()
    dv = SimpleNamespace(db=doc_db)        # all `runner.extract_settled` reads of a store
    for part in _chunks(shas):
        marks = ",".join("?" * len(part))
        for sha, uid in proof_db.execute(
                f"SELECT lower(file_sha256), user_id FROM proof_intake WHERE lower(file_sha256) IN ({marks})", part):
            filers.setdefault(sha, set()).add(int(uid))
        # the newest read that is an answer: a provider outage is neither an extraction nor a failure
        for sha, status, detail in doc_db.execute(
                "SELECT lower(proof_id), status, detail_json FROM dv_steps WHERE id IN (SELECT MAX(id) FROM dv_steps "
                f"WHERE step = 'extract' AND version = ? AND status IN ('ok', 'error') AND lower(proof_id) IN ({marks}) "
                "GROUP BY lower(proof_id))", [doc_approve.VERDICT_VERSION] + part):
            try:
                extraction[sha] = (status, json.loads(detail))
            except ValueError:
                extraction[sha] = ("error", {"ok": False, "error": "stored extraction is not JSON"})
                not_json.add(sha)
        # each (request, role)'s newest verdict: a role once blocked and never re-judged still blocks
        for sha, outcome in doc_db.execute(
                "SELECT lower(proof_id), outcome FROM dv_outcomes WHERE id IN (SELECT MAX(id) FROM dv_outcomes "
                f"WHERE version = ? AND lower(proof_id) IN ({marks}) GROUP BY lower(proof_id), request_id, role)",
                [doc_approve.VERDICT_VERSION] + part):
            if outcome in doc_approve.BLOCKING_VERDICTS:
                blocking.setdefault(sha, set()).add(outcome)
    out: dict[str, list[dict[str, Any]]] = {}
    for intake_id, uid, subject, sha, file_path, received_at in rows:
        sha = str(sha or "").lower()
        if not sha:
            continue
        status, body = extraction.get(sha, ("", None))
        error = str(body.get("error") or "") if isinstance(body, dict) else ""
        out.setdefault(str(int(uid)), []).append({
            # doc-verify's own answers, by its own rules: will it read this document again, and was a
            # failed read our tooling or the document. The ladder turns them into `awaiting_read`
            # (ours, no word to the claimant) or `resend`; it re-writes neither rule.
            "read_final": body is not None and runner.extract_settled(dv, sha),
            "tooling_error": status == "error" and (sha in not_json or error.startswith(gate.TOOLING_ERRORS)),
            "intake_id": intake_id, "source_sha256": sha, "received_at": received_at or "", "subject": subject or "",
            "has_bytes": bool(file_path), "extract_status": status, "extraction": body,
            "extractor": doc_approve.VERDICT_VERSION, "blocking_verdicts": sorted(blocking.get(sha, ())),
            "other_filers": len(filers.get(sha, set()) - {int(uid)})})
    return out


def profiles_in_catalog(run: Run, profile_ids: Iterable[str]) -> set[str]:
    """Which of these profile ids the catalog knows. `decline_rules.live_snapshots` leaves a claim
    out when its profile is not there; this read is what tells that apart from a failed read."""
    found: set[str] = set()
    for part in _chunks(sorted({p for p in profile_ids if decline_rules.PROFILE_ID.match(p or "")})):
        ids = ",".join(f"'{p}'" for p in part)
        for rec in decline_rules._rows(run(
                f"select lower(profile_id) from postgresql_catalog.public.catalog_profile where lower(profile_id) in ({ids})")):
            found.add(rec[0])
    return found


def profile_titles(run: Run, profile_ids: Iterable[str]) -> dict[str, set[str]]:
    """profile id -> the title keys of the tracks the catalog credits it on."""
    out: dict[str, set[str]] = {}
    for part in _chunks(sorted({p for p in profile_ids if decline_rules.PROFILE_ID.match(p or "")}), 100):
        ids = ",".join(f"'{p}'" for p in part)
        for rec in decline_rules._rows(run(
                "select distinct lower(profile_id), track_title from postgresql_catalog.public.matvw_profile_credit "
                f"where profile_id in ({ids}) and track_title is not null")):
            if len(rec) != 2:
                raise RuntimeError(f"profile titles read: {len(rec)} columns, expected 2")
            key = extract.title_key(rec[1])
            if key:
                out.setdefault(rec[0], set()).add(key)
    return out


SUPPLY_TABLE = "claim_doc_supplies"


def supplies(path: str, claim_ids: Iterable[int]) -> dict[int, list[dict[str, Any]]]:
    """claim id -> the forms its claimant supplied (email address, phone number, collaborator proof),
    oldest first, read read-only from the ladder's own store. A store that has never taken one has no
    such table, which is "nothing supplied", never an error."""
    ids = sorted({int(c) for c in claim_ids})
    out: dict[int, list[dict[str, Any]]] = {}
    if not ids or not os.path.exists(path):
        return out
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        db.row_factory = sqlite3.Row
        if not db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
                          (SUPPLY_TABLE,)).fetchone():
            return out
        for part in _chunks(ids):
            marks = ",".join("?" * len(part))
            for r in db.execute(f"SELECT claim_id, form, value, supplied_at, intake_id FROM {SUPPLY_TABLE} "
                                f"WHERE claim_id IN ({marks}) ORDER BY id", part):
                out.setdefault(int(r["claim_id"]), []).append(
                    {"form": r["form"], "value": r["value"], "supplied_at": r["supplied_at"],
                     "intake_id": r["intake_id"]})
    finally:
        db.close()
    return out


# How many live admin profiles one pass may read for a form's facts. The ask's form is chosen from
# these facts (`forms.offered`), so a claim we could not read is asked for a document - the form we
# can always check - never for a form nobody read.
MAX_FORM_READS = 500


def live_sites(profile_ids: list[str]) -> dict[str, str]:
    """{profile id: the website on the live admin profile}; the house reader for it (`profile_sites`
    reads the admin profile, never the catalog view, which ran four days behind)."""
    from gdpr_pipeline import sources as gdpr_sources  # noqa: PLC0415
    return gdpr_sources.profile_sites(list(profile_ids))


def collaborator_facts(run: Run, refs: Iterable[str]) -> dict[str, dict[str, Any]]:
    """{the reference a claimant sent: whether it is a Muso user, and the titles it is credited on}.

    A reference is matched the one way two page ids name one page (`page_identity.same_page`: equality,
    or a truncated id of 8+ characters, which is what a register row, a ticket or a pasted link holds),
    never by equality - a truncated id could never match one otherwise."""
    out: dict[str, dict[str, Any]] = {}
    for ref in sorted({(r or "").strip().lower() for r in refs}):
        if not ref or not forms_mod.PROFILE_ID.match(ref):
            continue
        rows = decline_rules._rows(run(
            "select lower(profile_id) from postgresql_catalog.public.catalog_profile "
            f"where lower(profile_id) like '{ref}%'"))
        hits = [r[0] for r in rows if len(r) == 1 and page_identity.same_page(ref, r[0])]
        if not hits:
            out[ref] = {"in_catalog": False, "held_by_account": None, "titles": []}   # measured: no user
            continue
        out[ref] = {"in_catalog": True, "held_by_account": held(ref, run),
                    "titles": sorted(profile_titles(run, [hits[0]]).get(hits[0], set()))}
    return out


def held(ref: str, run: Run) -> bool | None:
    """Whether that profile is HELD by an account - an existing Muso user, not a public catalog row.
    Core keeps the claim it granted on the profile (`claiming.status = 'processed'`); a read that
    fails answers None (unmeasured), never False, because 'we could not read it' is not 'nobody
    holds it'."""
    try:
        rows = decline_rules._rows(run(
            "select lower(profileid) from postgresql_core.public.claiming "
            f"where deletedat is null and status = 'processed' and lower(profileid) like '{ref}%'"))
    except Exception:  # noqa: BLE001 - unread is unread
        return None
    return any(len(r) == 1 and page_identity.same_page(ref, r[0]) for r in rows)


def account_emails(run: Run, user_ids: Iterable[str]) -> dict[str, tuple[str, bool]]:
    """{account user id: (its own address lower-cased, whether core CONFIRMED it)} - core's
    `users.email` / `users.emailconfirmed`, the mailbox the claimant signed up with, which is what the
    email form settles on (a domain alone only proves a domain, and an unconfirmed address is a typed
    string). A read that fails raises, so the caller records it unread rather than as "no address"."""
    ids = decline_rules._ids_sql((u for u in user_ids if str(u).isdigit()), quote=False)
    if not ids:
        return {}
    out: dict[str, tuple[str, bool]] = {}
    for rec in decline_rules._rows(run(
            "select cast(id as varchar), lower(coalesce(email, '')), cast(coalesce(emailconfirmed, false) as varchar) "
            f"from postgresql_core.public.users where id in ({ids})")):
        if len(rec) == 3:
            out[str(rec[0])] = (rec[1] or "", str(rec[2]).strip().lower() == "true")
    return out


def form_facts(run: Run, claims: list[dict[str, Any]], known: set[str], titles: dict[str, set[str]], *,
               sites: Callable[[list[str]], dict[str, str]] = live_sites,
               budget: int = MAX_FORM_READS, rotate: Iterable[str] = ()) -> tuple[dict[int, dict[str, Any]], dict[str, Any]]:
    """claim id -> the facts each new form's check reads, plus what the read cost.

    The facts are the profile's own host (the website on the live admin profile), its credited titles,
    and - for each collaborator a claimant named - whether that profile is a Muso user at all and the
    titles it is credited on, kept PER REF so a second collaborator is checked on its own facts.
    NOTHING publishes a profile phone number to us, so `profile_phones` is `None` (unread), and
    `forms.FORMS_WITHOUT_A_SOURCE` is what turns a supplied number into a measured NO.

    The live reads are bounded per pass (`budget`) and nothing is starved: a claim whose claimant
    supplied an address is always read (waiting on a fact we never read would wait forever), and the
    rest are taken oldest-supply-first, after last pass's reads (`rotate`), so a profile left out this
    pass is read on the next one. A claim whose profile was left out has no address facts, so
    `forms.offered` falls through to the next form whose facts were read (the document is the last
    rung of every order), and the count of them is reported, never silently dropped."""
    out: dict[int, dict[str, Any]] = {}
    spent: dict[str, Any] = {"hosts_read": 0, "hosts_unread": 0, "collaborators_read": 0,
                             "over_bound": 0, "claims": len(claims)}
    must: dict[str, str] = {}          # profile id -> the earliest supply that needs its host
    optional: dict[str, str] = {}
    for c in claims:
        pid = str(c.get("profile_id") or "").lower()
        if not pid:
            continue
        when = min((str(s.get("supplied_at") or "") for s in c.get("supplied_forms") or ()), default="")
        supplied = c.get("supplied_forms") or ()
        if any(s.get("form") == forms_mod.FORM_EMAIL for s in supplied):
            must[pid] = min(must.get(pid, when or "~"), when or "~")
        elif pid in known:
            optional[pid] = min(optional.get(pid, when or "~"), when or "~")
    read_before = {str(p).lower() for p in rotate}
    room = max(0, int(budget) - len(must))
    rest = sorted((p for p in optional if p not in must),
                  key=lambda p: (p in read_before, optional[p], p))[:room]
    asked = list(must) + rest
    # a profile the budget did not reach only if it was not also read for a claim that had to be:
    # `optional` includes a profile already in `must`, whose facts were delivered above
    spent["over_bound"] = max(0, len([p for p in optional if p not in must]) - len(rest))
    hosts: dict[str, str | None] = {}
    answer: dict[str, Any] = {}
    if asked:
        try:
            answer = sites(list(asked))
        except Exception:  # noqa: BLE001 - the whole batch unread is unread, never "no website"
            answer = {}
        if not isinstance(answer, dict):
            answer = {}
    for pid in asked:
        site = answer.get(pid, None)
        if isinstance(site, str):
            hosts[pid] = site
            spent["hosts_read"] += 1
        else:                          # absent from the answer, or the batch failed for it
            hosts[pid] = None
            spent["hosts_unread"] += 1
    refs = [str(s.get("value") or "").strip().lower() for c in claims
            for s in c.get("supplied_forms") or () if s.get("form") == forms_mod.FORM_COLLABORATOR]
    collabs = collaborator_facts(run, refs) if refs else {}
    # the account's own mailbox, READ BEFORE the offer: a verified address is half of what the email
    # check needs, so offering the form without it would ask for an answer that can never pass. One
    # batched read for every claim, not one per profile.
    emails: dict[str, tuple[str, bool]] | None = None
    try:
        emails = account_emails(run, [str(c.get("user_id") or "") for c in claims])
    except Exception:  # noqa: BLE001 - unread is unread, never "no address"
        emails = None
    spent["collaborators_read"] = len(collabs)
    spent["hosts_asked"] = list(asked)
    for c in claims:
        pid = str(c.get("profile_id") or "").lower()
        site = hosts.get(pid)
        facts: dict[str, Any] = {"claimed_profile_id": pid, "profile_phones": None,
                                 # a titles read is a catalog read: not in the catalog is a measured
                                 # "credited on nothing", never unread (that would wait forever)
                                 "profile_titles": sorted(titles.get(pid, ())),
                                 "collaborators": {}}
        facts["profile_hosts"] = None if site is None else ([forms_mod.host_of(site)] if forms_mod.host_of(site) else [])
        got = emails.get(str(c.get("user_id") or "")) if emails is not None else None
        # only the DIGEST travels: the check needs equality with the supplied address, and a digest
        # answers that without putting the account's address on a verdict row. `confirmed` is core's
        # own word that the mailbox answered, and an unread is `None`, never `False`.
        facts["account_email_confirmed"] = None if emails is None or got is None else bool(got[1])
        facts["account_email_sha256"] = (forms_mod.value_digest(forms_mod.FORM_EMAIL, got[0])
                                        if got and got[0] else None)
        # the DOMAIN, never the local part: the offer and the check both need to know whether this
        # mailbox's domain is one the profile publishes, and the domain is the readable half
        facts["account_email_domain"] = (got[0].rsplit("@", 1)[1]
                                         if got and got[0] and "@" in got[0] else None)
        for s in c.get("supplied_forms") or ():
            if s.get("form") != forms_mod.FORM_COLLABORATOR:
                continue
            ref = str(s.get("value") or "").strip().lower()
            if ref in collabs:
                facts["collaborators"][ref] = collabs[ref]
        out[int(c["claim_id"])] = facts
    return out, spent


def named_titles(extraction: Any, min_confidence: float) -> set[str]:
    """The title keys of the tracks a stored extraction names, at or above the confidence bar."""
    tracks = extraction.get("tracks") if isinstance(extraction, dict) else None
    keys = set()
    for t in tracks if isinstance(tracks, list) else []:
        if isinstance(t, dict) and doc_ladder._confidence(t.get("confidence")) >= min_confidence:
            key = extract.title_key(t.get("title") if isinstance(t.get("title"), str) else "")
            if key:
                keys.add(key)
    return keys


def claim_list_facts(path: str | None = None, *, now: datetime | None = None) -> tuple[dict[int, dict[str, Any]] | None, str]:
    """claim id -> its row in the scheduled claim list, or (None, why) when the list is unusable."""
    from credit_review import claim_list, claim_proof_ask  # noqa: PLC0415
    rows, why = claim_proof_ask.load_list(str(path or claim_list.LIVE_LIST), now=now, require_daily_check=False)
    if why:
        return None, why
    return {int(r["claim_id"]): r for r in rows if str(r.get("claim_id", "")).isdigit()}, ""


def held_accounts() -> tuple[set[str] | None, str]:
    """Account ids the fraud lens holds, or (None, why) when the ledger cannot be read."""
    from credit_review import claim_list  # noqa: PLC0415
    try:
        return set(claim_list.read_holds().ids), ""
    except claim_list.Unmeasured as exc:
        return None, str(exc)


def build(run: Run, proof_db: sqlite3.Connection, doc_db: sqlite3.Connection, *,
          listed: tuple[dict[int, dict[str, Any]] | None, str], held: tuple[set[str] | None, str],
          snapshots: Callable[[list[int], Run], dict[int, dict]] = decline_rules.live_snapshots,
          min_confidence: float, now: datetime | None = None,
          supplied: dict[int, list[dict[str, Any]]] | None = None,
          sites: Callable[[list[str]], dict[str, str]] = live_sites,
          claims_read: tuple[list[dict[str, Any]], list[int]] | None = None,
          rotate: Iterable[str] = ()) -> dict[str, Any]:
    claims, no_account = claims_read if claims_read is not None else open_claims(run)
    if not proof_db.execute("SELECT 1 FROM proof_intake LIMIT 1").fetchone():
        raise RuntimeError("proof_intake read: no rows")       # an empty store is not "no documents"
    docs = documents(proof_db, doc_db, (c["user_id"] for c in claims))
    forms_by_claim = supplied or {}
    # a claim is decided on its documents or on a form its claimant supplied: one with neither is not
    # in the population (no evidence, no decision) and is counted, never silently dropped
    with_docs = [c for c in claims if docs.get(str(c["user_id"])) or forms_by_claim.get(c["claim_id"])]
    decline: dict[int, dict] = {}
    for part in _chunks([c["claim_id"] for c in with_docs]):
        decline.update(snapshots(part, run))
    known = profiles_in_catalog(run, (c["profile_id"] for c in with_docs))
    titles = profile_titles(run, known)
    for c in with_docs:
        c["supplied_forms"] = list(forms_by_claim.get(c["claim_id"]) or [])
    facts, form_reads = form_facts(run, with_docs, known, titles, sites=sites, rotate=rotate)
    rows, list_why = listed
    held_ids, held_why = held
    found_by_profile: dict[str, list[int]] = {}
    for cid, r in (rows or {}).items():
        if r.get("code_found") is True:
            found_by_profile.setdefault(str(r.get("profile_id") or "").lower(), []).append(cid)
    for c in with_docs:
        cid = c["claim_id"]
        c["decline_snapshot"] = decline.get(cid)
        c["profile_in_catalog"] = c["profile_id"] in known
        mine = titles.get(c["profile_id"], set())
        # a claim whose only evidence is a supplied form has no documents of its own: that is
        # "no document names a release", never a missing key in the read
        c["releases"] = None if c["profile_id"] not in known else {
            d["source_sha256"]: {"named": len(n), "on_profile": len(n & mine)}
            for d in docs.get(str(c["user_id"])) or []
            for n in [named_titles(d["extraction"], min_confidence)]}
        c["account_hold"] = None if held_ids is None else str(c["user_id"]) in held_ids
        c["code_found_other_claims"] = None if rows is None else sorted(
            x for x in found_by_profile.get(c["profile_id"], []) if x != cid)
        c["form_facts"] = facts.get(cid) or {}
        paid = (rows or {}).get(cid, {}).get("paid")
        c["paid"] = paid if isinstance(paid, bool) else None
    users = {str(c["user_id"]) for c in with_docs}
    return {
        "version": doc_ladder.VERSION,
        "read_at": (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "claims": with_docs,
        "documents": {u: d for u, d in docs.items() if u in users},
        "sources": {
            "open_claims": len(claims) + len(no_account), "open_claims_without_account": len(no_account),
            "open_claims_with_document": sum(1 for c in with_docs if docs.get(str(c["user_id"]))),
            "open_claims_without_document": len(claims) - sum(1 for c in with_docs if docs.get(str(c["user_id"]))),
            "open_claims_with_supplied_form": sum(1 for c in with_docs if c["supplied_forms"]),
            "open_claims_decidable": len(with_docs),
            "form_hosts_read": form_reads.pop("hosts_asked", []),
            "form_hosts_answered": form_reads.pop("hosts_read", 0),
            **{f"form_{k}": v for k, v in form_reads.items()},
            "claimants_with_document": len(users),
            "documents": sum(len(docs.get(u) or []) for u in users),
            "profile_not_in_catalog": sum(1 for c in with_docs if not c["profile_in_catalog"]),
            "decline_snapshots_unread": sum(1 for c in with_docs
                                            if c["decline_snapshot"] is None and c["profile_in_catalog"]),
            "claim_list": list_why or "ok", "account_holds": held_why or "ok"},
    }


STATE_DIR = "/var/lib/hydra/claim-doc-ladder"


def write_private(path: Path, obj: Any) -> None:
    """0600, and replaced whole: a reader never sees half a file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, sort_keys=True)
    os.replace(tmp, path)


def tick(state_dir: str, policy: dict[str, Any], read: Callable[[], dict[str, Any]], *,
         kill_file: str = doc_ladder.KILL_FILE) -> tuple[int, dict[str, Any]]:
    """One scheduled pass: read, decide, record, re-derive. Returns (exit code, summary).

    The stop switch is a clean exit that records nothing. A read that does not answer raises: no
    snapshot is kept and nothing is recorded, so a failed read never looks like "no documents".
    A recorded decision that cannot be re-derived is exit 1 - the store is not evidence until it is."""
    if os.path.exists(kill_file):
        return 0, {"stopped": kill_file}
    snap = read()
    state = Path(state_dir)
    write_private(state / "snapshot.json", snap)
    db = doc_ladder.open_store(str(state / "decisions.sqlite"))
    try:
        out = doc_ladder.run(snap, policy, db)
        check = doc_ladder.verify(db)
        awaiting = doc_ladder.awaiting_age(db)
    finally:
        db.close()
    summary = {"read_at": snap["read_at"], "ladder_version": doc_ladder.VERSION, "sources": snap["sources"],
               **out, "awaiting": awaiting, "reproduced": check["reproduced"],
               "not_reproducible": [m["claim_id"] for m in check["mismatch"]]}
    write_private(state / "latest.json", summary)
    return (1 if check["mismatch"] else 0), summary


def last_host_reads(state_dir: str) -> list[str]:
    """The profiles the previous pass read a website for, so the next pass reads the others: the
    bound on live reads must not starve the same profiles every pass."""
    try:
        with open(Path(state_dir) / "latest.json", encoding="utf-8") as fh:
            ids = (json.load(fh).get("sources") or {}).get("form_hosts_read")
    except (OSError, ValueError):
        return []
    return [str(i) for i in ids] if isinstance(ids, list) else []


def read_live(args: argparse.Namespace, policy: dict[str, Any]) -> dict[str, Any]:
    """Read everything a pass decides on. The forms a claimant supplied are read from the ladder's own
    store first, so a claim whose only evidence is a form is in the population at all."""
    store = str(Path(args.state_dir) / "decisions.sqlite")
    proof_db, doc_db = doc_approve._ro(args.proof_store), doc_approve._ro(args.doc_store)
    claims_read = open_claims(trino)          # read once: the supplies are keyed by claim id
    supplied = supplies(store, (c["claim_id"] for c in claims_read[0]))
    return build(trino, proof_db, doc_db,
                 listed=claim_list_facts(args.claim_list), held=held_accounts(),
                 min_confidence=float(policy["min_confidence"]), supplied=supplied,
                 claims_read=claims_read, rotate=last_host_reads(args.state_dir))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", help="write the snapshot here and decide nothing")
    ap.add_argument("--tick", action="store_true", help="read, decide, record and re-derive under --state-dir")
    ap.add_argument("--state-dir", default=STATE_DIR)
    ap.add_argument("--proof-store", default=doc_approve.DEFAULT_PROOF_STORE)
    ap.add_argument("--doc-store", default=doc_approve.DEFAULT_DOC_STORE)
    ap.add_argument("--claim-list", default=None)
    ap.add_argument("--policy", default=str(doc_ladder.DEFAULT_POLICY))
    args = ap.parse_args(argv)
    if bool(args.out) == bool(args.tick):
        ap.error("exactly one of --out and --tick")
    policy = doc_ladder.load_policy(args.policy)
    if args.tick:
        rc, summary = tick(args.state_dir, policy, lambda: read_live(args, policy))
        print(json.dumps(summary, indent=2))
        return rc
    snap = read_live(args, policy)
    write_private(Path(args.out), snap)
    print(json.dumps(snap["sources"], indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
