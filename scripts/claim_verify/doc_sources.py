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
from credit_review import doc_approve  # noqa: E402
from credit_verify.docverify import extract, gate, runner  # noqa: E402

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
          min_confidence: float, now: datetime | None = None) -> dict[str, Any]:
    claims, no_account = open_claims(run)
    if not proof_db.execute("SELECT 1 FROM proof_intake LIMIT 1").fetchone():
        raise RuntimeError("proof_intake read: no rows")       # an empty store is not "no documents"
    docs = documents(proof_db, doc_db, (c["user_id"] for c in claims))
    with_docs = [c for c in claims if docs.get(str(c["user_id"]))]
    decline: dict[int, dict] = {}
    for part in _chunks([c["claim_id"] for c in with_docs]):
        decline.update(snapshots(part, run))
    known = profiles_in_catalog(run, (c["profile_id"] for c in with_docs))
    titles = profile_titles(run, known)
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
        c["releases"] = None if c["profile_id"] not in known else {
            d["source_sha256"]: {"named": len(n), "on_profile": len(n & mine)}
            for d in docs[str(c["user_id"])] for n in [named_titles(d["extraction"], min_confidence)]}
        c["account_hold"] = None if held_ids is None else str(c["user_id"]) in held_ids
        c["code_found_other_claims"] = None if rows is None else sorted(
            x for x in found_by_profile.get(c["profile_id"], []) if x != cid)
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
            "open_claims_with_document": len(with_docs),
            "open_claims_without_document": len(claims) - len(with_docs),
            "claimants_with_document": len(users),
            "documents": sum(len(docs[u]) for u in users),
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


def read_live(args: argparse.Namespace, policy: dict[str, Any]) -> dict[str, Any]:
    return build(trino, doc_approve._ro(args.proof_store), doc_approve._ro(args.doc_store),
                 listed=claim_list_facts(args.claim_list), held=held_accounts(),
                 min_confidence=float(policy["min_confidence"]))


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
