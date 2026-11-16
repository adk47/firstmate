#!/usr/bin/env python3
"""Run the deployed doc-verify reader over the 60 sampled claims, read-only (docverify-blind-60-r1).

Run on node-8 after `cases.json` is copied to WORK:

    ssh root@node-8 'nice -n 10 python3 - --emit' < run_reader.py > reader.json

It calls the real `runner.verify_document` for each case's one claim (`<request>#<role>`), with the
harness the blind check used (docverify-blind-check-r1, `tools/blind_check.py`):

  - doc-verify.sqlite and proof.sqlite are opened `mode=ro`, and `sqlite3.connect` is wrapped so a
    writable open of anything under the production state dir raises;
  - every step and outcome the reader writes goes to a scratch store per case in a temp dir;
  - blobs are read through a wrapper with no put and no quarantine;
  - NO model call: the extraction is a replay of the one production recorded for the document;
  - NO admin call: a track's Spotify/Tidal credits are a replay of production's stored read;
  - NO Intercom or Gmail fetch (`fetch=None, dl=None`): a document with no copy on disk is what the
    reader answers with no network.

Beside the re-run it records production's own standing outcome for the same claim (as of the draw's
CUTOFF, and the latest), so the re-run can be checked against what production said.

It never reads the judge's verdicts: they are on another machine and this file takes none.
"""
import collections
import dataclasses
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time

CUTOFF = "2026-11-15T01:23:59Z"
WORK = os.environ.get("DVB60_WORK", "/tmp/dvb60")
STATE = "/var/lib/hydra-credit-verify"
DV = os.path.join(STATE, "doc-verify.sqlite")
PROOF = os.path.join(STATE, "proof.sqlite")
NAMES = os.path.join(STATE, "name-index.sqlite")

BLOCKERS = (
    ("claims not extracted", "claims_not_extracted"),
    ("H3 verdict", "h3_not_approving"),
    ("forensic doubt", "forensic_doubt"),
    ("cross-check doubt", "cross_check_doubt"),
    ("no independent source confirms the credit", "no_independent_source"),
    ("the document itself does not name the claimant", "document_does_not_name_claim"),
    ("not a document of record", "not_a_document_of_record"),
    ("the document credits the claimant on other tracks", "claimant_on_other_tracks"),
    ("sender address unreadable", "sender_unreadable"),
    ("sender doubt", "sender_doubt"),
    ("account hold", "account_hold"),
    ("Spotify/Tidal credit this", "dsp_credits_someone_else"),
    ("two independent fraud signals", "fraud_pair"),
    ("forensics:", "hard_forensic_finding"),
    ("fabricated sender", "fabricated_sender"),
    ("independently confirmed by", "confirmed"),
)
TOOLING = (
    ("extraction did not run", "tooling_extraction_did_not_run"),
    ("H3 UNDETERMINED", "tooling_h3_undetermined"),
    ("H3 verdict missing", "tooling_h3_missing"),
    ("Spotify/Tidal credits unreadable", "tooling_dsp_unreadable"),
    ("not located", "tooling_not_located"),
)


def blockers(reason):
    reason = reason or ""
    table = TOOLING if reason.startswith("tooling:") else BLOCKERS
    return [code for phrase, code in table if phrase in reason] or ["other"]


def log(msg):
    print(f"[reader] {msg}", file=sys.stderr, flush=True)


def guard_sqlite():
    real = sqlite3.connect

    def connect(database, *a, **kw):
        s = str(database)
        if os.path.realpath(STATE) in os.path.realpath(s.replace("file:", "").split("?")[0]) and "mode=ro" not in s:
            raise RuntimeError(f"refusing a writable open of a production store: {s[:120]}")
        return real(database, *a, **kw)

    sqlite3.connect = connect


class ReadOnlyBlobs:
    def __init__(self, inner):
        self.inner = inner

    def has(self, sha):
        return self.inner.has(sha)

    def get(self, sha):
        return self.inner.get(sha)

    def put(self, sha, data):
        return None

    def quarantine(self, sha):
        return None


class Replay:
    def __init__(self, recorded):
        self.recorded = recorded

    def extract(self, text, meta, proof_id):
        from credit_verify.docverify.extract import Extraction
        d = self.recorded.get(proof_id)
        if d is None:
            raise RuntimeError("no recorded extraction to replay")
        names = {f.name for f in dataclasses.fields(Extraction)}
        return Extraction(**{k: v for k, v in d.items() if k in names})


class CreditsReplay:
    def __init__(self, dv):
        self.dv = dv
        self.missing = set()

    def __call__(self, track_id):
        row = self.dv.execute("SELECT items_json FROM dv_raw_credits WHERE track_id=?", (track_id,)).fetchone()
        if row is None:
            self.missing.add(track_id)
            raise RuntimeError("production recorded no raw credits for this track")
        items = json.loads(row[0])
        if not isinstance(items, list):
            raise RuntimeError("recorded raw credits are not a list")
        return items


def standing(dv, version, pid, rid, role, cutoff=None):
    q = "SELECT outcome FROM dv_outcomes WHERE proof_id=? AND request_id=? AND role=? AND version=?"
    args = [pid, rid, role, version]
    if cutoff:
        q += " AND at<=?"
        args.append(cutoff)
    row = dv.execute(q + " ORDER BY id DESC LIMIT 1", args).fetchone()
    return row[0] if row else None


def main():  # pragma: no cover - runs on node-8 only
    sys.path.insert(0, "/opt/hydra/scripts")
    guard_sqlite()
    from credit_verify.docverify import VERSION, intake_read, name_index, runner
    from credit_verify.docverify import crosscheck as xc
    from credit_verify.docverify.blobs import BlobStore
    from credit_verify.docverify.pace import Pacer
    from credit_verify.docverify.store import DocVerifyStore
    from credit_verify.proof import sandbox, stage2

    cases = json.load(open(os.path.join(WORK, "cases.json")))["cases"]
    dv = sqlite3.connect(f"file:{DV}?mode=ro", uri=True, timeout=120)
    proof_db = sqlite3.connect(f"file:{PROOF}?mode=ro", uri=True, timeout=120)
    held = set(DocVerifyStore.read_only(DV).held_users())
    blobs = ReadOnlyBlobs(BlobStore())
    credits = CreditsReplay(dv)
    recorded = {}
    pids = sorted({c["proof_id"] for c in cases})
    for pid, dj in dv.execute("SELECT proof_id, detail_json FROM dv_steps WHERE request_id='' AND step='extract' "
                              f"AND proof_id IN ({','.join('?' * len(pids))}) ORDER BY id", pids):
        try:
            recorded[pid] = json.loads(dj)
        except ValueError:
            continue
    rids = sorted({c["claim"]["request_id"] for c in cases if c.get("claim")})
    reqs = stage2.requests(rids)
    mb, wb = (Pacer(n, 1.0, log=log) for n in ("musicbrainz", "wayback"))
    names = name_index.LocalIndex(NAMES) if os.path.exists(NAMES) else None
    tmp = tempfile.mkdtemp(prefix="dvb60-reader-", dir="/dev/shm" if os.path.isdir("/dev/shm") else None)
    os.chmod(tmp, 0o700)
    out = {}
    try:
        for c in cases:
            cid, pid, claim = c["case"], c["proof_id"], c.get("claim")
            row = {"case": cid}
            if not claim:
                row.update({"outcome": None, "not_run": "no claim"})
                out[cid] = row
                continue
            rid, role = claim["request_id"], claim["role"]
            row["production_at_cutoff"] = standing(dv, VERSION, pid, rid, role, CUTOFF)
            row["production_latest"] = standing(dv, VERSION, pid, rid, role)
            r = reqs.get(rid)
            if r is None:
                row.update({"outcome": None, "not_run": "request not readable in core"})
                out[cid] = row
                continue
            irow = proof_db.execute(
                "SELECT intake_id, user_id, file_sha256, conversation_id, file_path, contact_h, "
                "candidate_request_ids_json, received_at, matched_by, reply_text_json FROM proof_intake "
                "WHERE file_sha256=? ORDER BY (instr(candidate_request_ids_json, ?) > 0) DESC, received_at DESC "
                "LIMIT 1", (pid, rid)).fetchone()
            intake = None
            if irow:
                try:
                    cands = [str(x) for x in json.loads(irow[6] or "[]") if x]
                except ValueError:
                    cands = []
                try:
                    reply = json.loads(irow[9] or "[]") or []
                except ValueError:
                    reply = []
                intake = intake_read.IntakeDoc(irow[0], int(irow[1] or 0), irow[2], str(irow[3] or ""), irow[4],
                                               irow[5] or "", cands or [rid], irow[7] or "", irow[8] or "",
                                               reply_text=reply if isinstance(reply, list) else [])
            store = DocVerifyStore(os.path.join(tmp, f"{cid}.sqlite"))
            deps = runner.Deps(
                sandbox=sandbox.run, extractor=Replay(recorded), net=xc.Net(mb_pacer=mb, archive_pacer=wb),
                raw_credits=credits, requests=lambda ids: {i: reqs[i] for i in ids if i in reqs},
                fetch=None, dl=None, people_graph=names, blobs=blobs,
                shadow_store=intake_read.ShadowProofStore.open(PROOF), claimants=None)
            stats = runner.Stats(run_id=f"dvb60-{cid}")
            t = time.time()
            try:
                rows = runner.verify_document(store, proof_db, pid, [f"{rid}#{role}"], deps, stats.run_id, stats,
                                              set(held), intake=intake)
                err = None
            except Exception as exc:  # noqa: BLE001 - recorded: the reader did not answer this case
                rows, err = [], f"{type(exc).__name__}: {str(exc)[:160]}"
            store.db.close()
            mine = [x for x in rows if x.get("role") == role] or rows
            if err or not mine:
                row.update({"outcome": None, "not_run": err or "the reader returned no outcome row"})
            else:
                x = mine[0]
                row.update({"outcome": x["outcome"], "h3": x.get("h3"), "blockers": blockers(x.get("reason")),
                            "reader_doc_type": x.get("doc_type"),
                            "reader_saw_support": bool(x.get("extracted_support"))})
            row["track_credits_replayed"] = r.track_id not in credits.missing
            row["seconds"] = round(time.time() - t, 1)
            out[cid] = row
            log(f"{cid}: {row.get('outcome') or row.get('not_run')} (production {row['production_at_cutoff']})")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    json.dump({"verifier_version": VERSION, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "outcomes": dict(collections.Counter(str(v.get("outcome")) for v in out.values())),
               "cases": out}, sys.stdout, indent=1, sort_keys=True)
    print()


if __name__ == "__main__" and "--emit" in sys.argv:  # pragma: no cover
    main()
