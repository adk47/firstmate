#!/usr/bin/env python3
"""Doc-verify: never take a returned credit document at face value.

Design and operator view: docs/credit-verification/doc-verify.md.

Subcommands:
  run          Verify every document H3 judged for a linked credit request
               since the cutoff (the first run records it): extract the claims
               (OpenRouter deepseek-v4.1-flash-1017), forensics, independent
               cross-checks, outcome. What the cron runs.
  eval-select  Build the eval manifest on node-8: the likely-forged documents
               of the given users plus N known-good documents (not forged by
               H3, and the claimed credit already on Spotify/Tidal).
  eval         Verify the manifest's documents into a scratch store and print
               the results (markdown) and the metrics (JSON on stderr).
  summary      Outcome counts of the latest outcome per document and claim.

Writes only its own store (/var/lib/hydra-credit-verify/doc-verify.sqlite);
reads the H3 proof store read-only. No credit is changed and nothing is sent
to anybody (no issuer email, no customer copy). Kill switch:
/etc/hydra/credit-verify.disabled (shared with the H3 crons).

This script records outcomes and has no apply mode. Whether a recorded
outcome may approve a credit is decided in policy, not here: the
`document_small_track` entry of policies/credit-approval-automation.json,
read by credit_review/decide.py (`doc_class_active`).
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

KILL_SWITCH = os.environ.get("CREDIT_VERIFY_KILL_SWITCH", "/etc/hydra/credit-verify.disabled")
# blob-backfill's own stop. The cron's `enabled` flag lives in cron-jobs.json, which every deploy
# overwrites; this file is on the host and no deploy touches it. A constant: no env var moves it.
BACKFILL_KILL = "/etc/hydra/credit-doc-verify-blob-backfill.disabled"
PAYING_USERS = os.environ.get("CREDIT_TRUST_PAYING_USERS", "/var/lib/credit-trust/paying-users.json")


def log(msg: str) -> None:
    print(f"[credit-doc-verify] {msg}", file=sys.stderr)


def real_deps(store, *, intercom_fetch: bool = True, strict_pacing: bool = False):
    from credit_review import admin as admin_api
    from credit_verify.docverify import crosscheck as xc
    from credit_verify.docverify import name_index
    from credit_verify.docverify.extract import Extractor
    from credit_verify.docverify import runner
    from credit_verify.docverify.runner import Deps
    from credit_verify.proof import intercom, sandbox, stage2
    from credit_verify.docverify.pace import Pacer
    from credit_verify.docverify.blobs import BlobStore
    admin = admin_api.AdminClient()
    tok = intercom.intercom_token() if intercom_fetch else None
    if intercom_fetch and not tok:
        log("no MUSOAI_INTERCOM_TOKEN: only cached attachments can be verified this run")
    # 1 request/s per API across EVERY reader process on the host (run --workers N): MusicBrainz's
    # own limit, and Intercom/admin GETs kept at the single-reader rate (proof-loop lead 2026-10-28).
    mb, ic, ad, wb = (Pacer(n, 1.0, log=log, strict=strict_pacing)
                      for n in ("musicbrainz", "intercom", "admin", "wayback"))
    fetch = ic.paced(intercom.make_fetch(tok)) if tok else None
    return Deps(sandbox=sandbox.run, extractor=Extractor(store), net=xc.Net(mb_pacer=mb, archive_pacer=wb),
                raw_credits=lambda tid: store.cached_raw_credits(
                    tid, ad.paced(lambda t: admin_api.track_raw_credits(admin, t))),
                requests=lambda ids: stage2.requests(ids), fetch=fetch, dl=stage2.download,
                # The local name index (built from one Trino export per 6 h), never a scan per document.
                people_graph=name_index.lazy(log=log), blobs=BlobStore(),
                # a claimant's filing with no credit request is read for its extraction (the claim ladder's input)
                claimants=lambda: runner.claim_accounts(store, stage2.trino_query))


def paying_users() -> frozenset[int] | None:
    """Paid accounts (paid first); None when the export is unreadable (then oldest first)."""
    try:
        return frozenset(int(u) for u in json.loads(Path(PAYING_USERS).read_text())["ids"])
    except (OSError, ValueError, KeyError, TypeError) as exc:
        log(f"paying users unreadable ({type(exc).__name__}): filings are read oldest first")
        return None


def budgets(max_docs: int, n: int) -> list[int]:
    """`max_docs` split EXACTLY over n workers (QA #1433): the first max_docs % n get one more;
    the total is never above max_docs, and a worker with 0 is not started."""
    q, r = divmod(max(0, int(max_docs)), max(1, n))
    return [q + (1 if i < r else 0) for i in range(n)]


def worker_argv(args: argparse.Namespace, i: int, n: int, budget: int) -> list[str]:
    argv = [sys.executable, os.path.abspath(__file__)]
    if args.store:
        argv += ["--store", args.store]
    argv += ["--proof-store", args.proof_store, "run", "--max-docs", str(budget), "--shard", f"{i}/{n}"]
    return argv + (["--since", args.since] if args.since else []) + \
        (["--reread-carried"] if getattr(args, "reread_carried", False) else [])


def run_workers(args: argparse.Namespace, popen=None) -> int:
    """Start the workers and wait for all of them. ANY nonzero exit - including a negative one
    (killed by a signal, e.g. the OOM killer) - fails the run (QA #1433)."""
    import subprocess
    from credit_verify.docverify.pace import usable
    why = usable()
    if why:
        log(f"workers refused: the host-wide pace directory is unusable ({why}); parallel readers would "
            "multiply the API rate. Fix it or run one reader.")
        return 2
    popen = popen or subprocess.Popen
    plan = [(i, b) for i, b in enumerate(budgets(args.max_docs, args.workers)) if b > 0]
    procs = [(i, popen(worker_argv(args, i, args.workers, b))) for i, b in plan]
    rcs = {i: p.wait() for i, p in procs}
    bad = {i: rc for i, rc in rcs.items() if rc != 0}
    silent = sorted(i for i, rc in bad.items() if rc == EX_NO_TRACE)
    log(f"workers {args.workers}: started {len(plan)} (budgets {[b for _, b in plan]}), exit {rcs}"
        + (f"; FAILED shards {sorted(bad)}" if bad else "")
        + (f"; NO TRACE in shards {silent}: work reported that the store does not hold" if silent else ""))
    return 1 if bad else 0


def cmd_blob_backfill(args: argparse.Namespace) -> int:
    """Restore stored bytes for support@ email filings: the ONLY doc-verify path that calls Gmail (Fable 10-31)."""
    import sqlite3
    import time
    from datetime import datetime, timezone
    from credit_verify.docverify import backfill
    from credit_verify.docverify.blobs import BlobStore
    from credit_verify.docverify.store import DocVerifyStore
    from credit_verify.proof import gmail_intake
    for kill in (BACKFILL_KILL, KILL_SWITCH):
        # before any store is opened and before any fetch: a stopped run reads and writes nothing
        if Path(kill).exists():
            log(f"kill switch present at {kill}; no blob-backfill")
            print("NO_REPLY")
            return 0
    from credit_verify.proof.gmail_kill import GMAIL_READERS_KILL, gmail_readers_disabled
    if gmail_readers_disabled():
        log(f"support@ Gmail readers disabled ({GMAIL_READERS_KILL}); no blob-backfill")
        print("NO_REPLY")
        return 0
    if not hasattr(gmail_intake, "SUPPORT_GMAIL_LOCK"):
        # rule (2): every support@ Gmail call takes the shared lock (#1558); code without it never fetches
        log("blob-backfill refused: gmail_intake has no shared support@ Gmail lock on this deploy (#1558)")
        return 2
    store = DocVerifyStore(args.store)
    proof_db = sqlite3.connect(f"file:{args.proof_store}?mode=ro", uri=True)
    if args.intercom_max > 0:
        # QA #1563: registered Intercom blobs that are gone, restored from the filer's cache copy or ONE Intercom
        # fetch each (paced 1/s host-wide, the reader's pacer) - never by the reader itself
        from credit_verify.docverify.pace import Pacer
        from credit_verify.docverify.runner import CACHE_ROOT
        from credit_verify.proof import intercom, stage2
        tok = intercom.intercom_token()
        fetch = Pacer("intercom", 1.0, log=log).paced(intercom.make_fetch(tok)) if tok else None
        ist = backfill.restore_intercom(proof_db, store, BlobStore(), fetch=fetch, dl=stage2.download,
                                        cache_root=CACHE_ROOT, max_docs=args.intercom_max, log=log)
        log("blob-backfill intercom " + json.dumps(ist))
    st = backfill.backfill(proof_db, store, BlobStore(), fetch_raw=gmail_intake.gog_raw,
                           max_messages=args.max_messages, min_interval=60.0 / max(1, args.per_min),
                           now=lambda: datetime.now(timezone.utc), sleep=time.sleep, log=log)
    log("blob-backfill " + json.dumps(st))
    print("NO_REPLY")
    return EX_PROVIDER_DOWN if st["stopped"] and ("quota" in st["stopped"] or "backoff" in st["stopped"]) else 0


EX_PROVIDER_DOWN = 75        # EX_TEMPFAIL: the model provider refused (credit / auth / rate limit / cap / no key)
EX_NO_TRACE = 70             # EX_SOFTWARE: the run reports work that the store does not hold (runner.untraced)


def cmd_run(args: argparse.Namespace) -> int:
    import sqlite3
    from credit_verify.docverify import runner
    from credit_verify.docverify.store import DocVerifyStore
    if Path(KILL_SWITCH).exists():
        log(f"kill switch present at {KILL_SWITCH}; no doc-verify")
        print("NO_REPLY")
        return 0
    if args.workers > 1:
        # N independent workers, each owning the documents of its sha256 shard: a document is never
        # read by two workers; pacing (MusicBrainz, Intercom, admin) and the model's daily cap are
        # shared through the host and the store.
        rc = run_workers(args)
        print("NO_REPLY")
        return rc
    shard = None
    if args.shard:
        i, _, n = args.shard.partition("/")
        if not (i.isdigit() and n.isdigit() and 0 <= int(i) < int(n)):
            log(f"bad --shard {args.shard!r} (want i/n with 0 <= i < n)")
            return 2
        shard = (int(i), int(n))
    store = DocVerifyStore(args.store)
    stats, _ = runner.run(store, real_deps(store, strict_pacing=shard is not None), proof_store=args.proof_store,
                          since=args.since,
                          max_docs=args.max_docs, shard=shard, paying=paying_users(),
                          reread_carried=args.reread_carried, log=log)
    # the carried-set metric is a whole-store scan (~15 s on node-8): one shard reports it, not all of them
    extra = {"carried_remaining": store.carried_remaining()} \
        if args.reread_carried and (shard is None or shard[0] == 0) else {}
    # Read back what the run left on file, from the file: a run that judged and recorded nothing used to exit 0.
    # A store that cannot be read back is unmeasured, and unmeasured is a failure too, never "it wrote them".
    try:
        steps, outcomes = store.run_rows(stats.run_id)
        written: dict[str, int | None] = {"steps": steps, "outcomes": outcomes}
        silent = runner.untraced(stats, steps, outcomes)
    except sqlite3.Error as exc:
        written = {"steps": None, "outcomes": None}
        silent = (f"the rows of {stats.run_id} could not be read back from {store.path} "
                  f"({type(exc).__name__}: {str(exc)[:160]})")
    log("run " + json.dumps({**stats.as_dict(), "written": written, "shard": args.shard, **extra}))
    print("NO_REPLY")
    if silent:
        log(f"run FAILED: NO TRACE: {silent}")
    if stats.provider_down:
        # Fable b1 #1518: a run the provider refused is a FAILED run (a shard / the cron sees nonzero, the
        # unknown-share watchdog and the shard loop's back-off see it), never a quiet success
        log(f"run FAILED: provider down ({stats.provider_down})")
        return EX_PROVIDER_DOWN
    return EX_NO_TRACE if silent else 0


FORGED_SQL = ("SELECT DISTINCT proof_id, request_id || '#' || role, user_id FROM stage2_shadow WHERE user_id IN ({}) "
              "AND outcome='reject_hold' AND proof_id IS NOT NULL")
GOOD_SQL = ("SELECT s.proof_id, s.request_id, s.role, s.user_id FROM stage2_shadow s JOIN (SELECT request_id, role, "
            "MAX(id) id FROM stage2_shadow GROUP BY request_id, role) l USING(id) WHERE s.proof_id IS NOT NULL "
            "AND s.verdict IN ('GENUINE','VERIFIED','PLAUSIBLE','SUSPECT','INCONSISTENT') "
            "AND s.outcome != 'reject_hold'")


def cmd_eval_select(args: argparse.Namespace) -> int:
    from credit_review import admin as admin_api
    from credit_review.evidence import CONFIRMED, classify_roles
    from credit_verify.proof import stage2
    db = sqlite3.connect(f"file:{args.proof_store}?mode=ro", uri=True)
    users = [int(u) for u in args.forged_users.split(",") if u.strip()]
    manifest: dict[str, dict] = {}
    for proof_id, key, uid in db.execute(FORGED_SQL.format(",".join("?" * len(users))), users):
        m = manifest.setdefault(proof_id, {"label": "forged", "proof_id": proof_id, "user_id": uid, "keys": []})
        m["keys"].append(key)
    rows = db.execute(GOOD_SQL).fetchall()
    random.Random(args.seed).shuffle(rows)
    admin = admin_api.AdminClient()
    good, seen_users, gets, failed = 0, set(users), 0, 0
    by_req = {}
    for chunk in range(0, min(len(rows), args.scan), 200):
        by_req.update(stage2.requests(list({r[1] for r in rows[chunk:chunk + 200]})))
    credits: dict[str, list] = {}
    for proof_id, rid, role, uid in rows[:args.scan]:
        if good >= args.good or gets >= args.max_gets:
            break
        if uid in seen_users or proof_id in manifest or rid not in by_req:
            continue
        r = by_req[rid]
        if not r.track_id:
            continue
        if r.track_id not in credits:
            gets += 1
            try:
                credits[r.track_id] = admin_api.track_raw_credits(admin, r.track_id)
            except admin_api.AdminError as exc:
                failed += 1
                credits[r.track_id] = []
                if failed >= 5 and failed == gets:
                    log(f"admin API failing ({exc}); aborting the selection")
                    return 1
        if classify_roles([role], credits[r.track_id], r.names, set())[0].status != CONFIRMED:
            continue
        manifest[proof_id] = {"label": "good", "proof_id": proof_id, "user_id": uid, "keys": [f"{rid}#{role}"],
                              "why_good": "H3 not forged and the claimed credit is on Spotify/Tidal (trusted raw credits)"}
        seen_users.add(uid)
        good += 1
    out = list(manifest.values())
    Path(args.out).write_text(json.dumps(out, indent=1))
    log(f"manifest: {sum(1 for m in out if m['label'] == 'forged')} forged documents "
        f"({sum(len(m['keys']) for m in out if m['label'] == 'forged')} claims), {good} good; {gets} admin GETs, "
        f"{failed} failed")
    return 0


def cmd_eval(args: argparse.Namespace) -> int:
    from credit_verify.docverify import runner
    from credit_verify.docverify.store import DocVerifyStore
    manifest = json.loads(Path(args.manifest).read_text())
    store = DocVerifyStore(args.store)
    deps = real_deps(store)
    label = {m["proof_id"]: m["label"] for m in manifest}
    rows: list[dict] = []
    for m in manifest:                    # one document at a time: no account hold across users
        _, r = runner.run(store, deps, proof_store=args.proof_store, pairs={m["proof_id"]: m["keys"]}, log=log)
        if not r:
            r = [{"proof_id": m["proof_id"], "request_id": k.split("#")[0], "role": k.split("#")[1],
                  "user_id": m.get("user_id"), "outcome": "(retry: not finalised)", "reason": "", "checks": {},
                  "findings": []} for k in m["keys"]]
        rows += r
    print(eval_markdown(rows, label), end="")
    log("metrics " + json.dumps(eval_metrics(rows, label)))
    return 0


def eval_metrics(rows: list[dict], label: dict[str, str]) -> dict:
    out: dict = {}
    for lab in ("forged", "good"):
        mine = [r for r in rows if label.get(r["proof_id"]) == lab]
        docs = {r["proof_id"] for r in mine}
        by = {}
        for r in mine:
            by[r["outcome"]] = by.get(r["outcome"], 0) + 1
        out[lab] = {"documents": len(docs), "claims": len(mine), "outcomes": by}
    forged = [r for r in rows if label.get(r["proof_id"]) == "forged"]
    good = [r for r in rows if label.get(r["proof_id"]) == "good"]
    out["forged_caught"] = sum(r["outcome"] in ("forged", "forged_positive", "contradicted") for r in forged)
    out["forged_verified"] = sum(r["outcome"] == "verified" for r in forged)
    out["good_false_decline"] = sum(r["outcome"] in ("forged", "forged_positive", "contradicted") for r in good)
    out["good_verified"] = sum(r["outcome"] == "verified" for r in good)
    return out


def eval_markdown(rows: list[dict], label: dict[str, str]) -> str:
    lines = ["| label | user | proof | role | H3 | outcome | need | issuer (type) | sender domain | signatory | "
             "dsp | isrc | label | domain | signatory? | findings | reason |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in sorted(rows, key=lambda r: (label.get(r["proof_id"], ""), str(r.get("user_id")))):
        c = r.get("checks") or {}
        lines.append("| " + " | ".join(str(x).replace("|", "/") for x in (
            label.get(r["proof_id"]), r.get("user_id"), r["proof_id"][:10], r.get("role"), r.get("h3"),
            f"**{r['outcome']}**", r.get("need") or "", f"{r.get('issuer') or '-'} ({r.get('issuer_type') or '-'})",
            r.get("sender_domain") or "-", r.get("signatory") or "-", c.get("xc_dsp", "-"), c.get("xc_isrc", "-"),
            c.get("xc_label", "-"), c.get("xc_domain", "-"), c.get("xc_signatory", "-"),
            ", ".join(r.get("findings") or []) or "-", (r.get("reason") or "")[:220])) + " |")
    return "\n".join(lines) + "\n"


def cmd_l11_watch(args: argparse.Namespace) -> int:
    """The L11 24 h clean-read counts since the dv-2 deploy (read-only). Prints one line; --json the detail."""
    from credit_verify.docverify import l11
    from credit_verify.docverify.store import DocVerifyStore
    store = DocVerifyStore.read_only(args.store)       # a report: never writes
    # no file = UNKNOWN (never clean); an empty reviewed file = known zero
    flags = l11.parse_false_forged(Path(args.false_forged).read_text()) if args.false_forged else None
    w = l11.watch(store, since=args.since, false_forged=flags, dsp_store=args.dsp_store)
    print(json.dumps(w, indent=1, default=str) if args.json else l11.line(w))
    return 0


class ReadOnlyOutcomes:
    """latest_outcomes() of another doc-verify store (e.g. the 961-document backfill), opened read-only."""

    def __init__(self, path: str):
        self.db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        self.db.row_factory = sqlite3.Row

    def latest_outcomes(self) -> list:
        cols = {r[1] for r in self.db.execute("PRAGMA table_info(dv_outcomes)")}
        extra = "" if "intake_id" in cols else ", NULL AS intake_id"      # a store from before D2
        return self.db.execute(f"SELECT o.*{extra} FROM dv_outcomes o JOIN (SELECT MAX(id) id FROM dv_outcomes "
                               "GROUP BY proof_id, request_id, role) l USING(id)").fetchall()


def cmd_forged_tray(args: argparse.Namespace) -> int:
    """The fraud-deny tray. Reads the doc-verify store and proof_intake (read-only); writes two files."""
    import sqlite3
    from credit_verify.docverify import tray as tray_mod
    from credit_verify.docverify.store import DocVerifyStore, utcnow
    store = DocVerifyStore.read_only(args.store)       # a report: never writes (QA #1470)
    pdb = sqlite3.connect(f"file:{args.proof_store}?mode=ro", uri=True)

    def intake_of(iid: str) -> dict:
        row = pdb.execute("SELECT subject, received_at FROM proof_intake WHERE intake_id=?", (iid,)).fetchone()
        return {"subject": row[0], "received_at": row[1]} if row else {}
    rulings = tray_mod.parse_rulings(Path(args.rulings).read_text()) if args.rulings else {}
    also = [ReadOnlyOutcomes(p) for p in args.also_store or []]
    rows, short = tray_mod.forged_tray(store, intake_of=intake_of, rulings=rulings, also=also)
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    md = out / f"jan-forged-b{args.batch}.md"
    md.write_text(tray_mod.forged_markdown(rows, args.batch, utcnow(), short))
    # The executor's input is the deny rows only; short-of-positive rows never enter it.
    (out / f"jan-forged-b{args.batch}.json").write_text(json.dumps(rows, indent=1, default=str))
    (out / f"jan-forged-b{args.batch}-short.json").write_text(json.dumps(short, indent=1, default=str))
    log(f"forged tray b{args.batch}: {len(rows)} documents, {sum(r['executable'] for r in rows)} confirmed, "
        f"{len(short)} short of positive -> {md}")
    return 0


def cmd_junk_list(args: argparse.Namespace) -> int:
    """JUNK PROOF option C: per filed document its artifact kind -> purge list per user (SYS-001 apart) and the
    requests whose every filed document is junk (decline proposal, standard line, no ask). Read-only;
    writes the two files under --out-dir. The purge itself is ops-to-ovh-m1's feed change after Fable."""
    from credit_verify.docverify import artifacts
    from credit_verify.docverify.store import DEFAULT_PATH
    path = args.store or DEFAULT_PATH
    if not os.path.exists(path):
        log(f"junk-list: no doc-verify store at {path}")
        return 2
    # a report: read-only, never creates, alters or carries the store (QA #1470)
    store = argparse.Namespace(db=sqlite3.connect(f"file:{path}?mode=ro", uri=True))
    pdb = sqlite3.connect(f"file:{args.proof_store}?mode=ro", uri=True)
    from credit_verify.docverify.extract import _title_key
    from credit_verify.proof import stage2
    rows = artifacts.filed_rows(store.db, pdb, paying_users() or frozenset())
    junk_rids = sorted({rid for r in rows if r["artifact"] for rid in r["candidates"]})
    reqs = stage2.requests(junk_rids) if junk_rids else {}
    titles = {rid: _title_key(q.title) for rid, q in reqs.items()}
    # read at report time: only requests open and not deleted NOW (stage2.requests skips deleted ones)
    open_ids = {rid for rid, q in reqs.items() if str(q.status or "").lower() not in ("approved", "rejected")}
    out = artifacts.junk_list(rows, titles, open_ids)
    out["read"] = sum(1 for r in rows if r["read"])
    d = Path(args.out_dir)
    d.mkdir(parents=True, exist_ok=True)
    (d / f"junk-proof-b{args.batch}.json").write_text(json.dumps(out, indent=1, default=str))
    md = [f"# Junk proof (option C) b{args.batch}", "",
          f"{out['documents']} filed documents, {out['read']} read; **{out['junk_documents']} junk** "
          f"({', '.join(f'{k} {v}' for k, v in sorted(out['by_kind'].items())) or 'none'}); SYS-001 (Muso UI "
          f"screenshots) {out['sys_001']}; {out['text_checked']} classified with the full text, the rest by the "
          "stored-data rules (the reader records the full-text kind from now on).", "",
          f"Decline proposal (standard line, no ask; EVERY document filed for the request is junk AND a junk "
          f"document is tied to it - names its track, or its filing had <= {artifacts.SMALL_FILING} open requests): "
          f"{len(out['decline_requests'])} requests; held (untied, left pending): {len(out['held_untied'])}.", "", "| user | paid | junk documents | kinds |", "|---|---|---|---|"]
    md += [f"| {u['user_id']} | {'yes' if u['paid'] else 'no'} | {sum(u['counts'].values())} | "
           f"{', '.join(f'{k} {v}' for k, v in sorted(u['counts'].items()))} |" for u in out["users"]]
    # coverage (QA #1472): every filed document with its stated kind, junk or not, read or not
    md += ["", f"## Every filed document ({len(out['document_rows'])})", "",
           "| intake | user | kind | why | text checked | read |", "|---|---|---|---|---|---|"]
    md += [f"| {r['intake_id']} | {r['user_id']} | {r['artifact'] or '-'} | {r['why'] or ''} | "
           f"{'yes' if r['text_checked'] else 'no'} | {'yes' if r['read'] else 'no'} |" for r in out["document_rows"]]
    (d / f"junk-proof-b{args.batch}.md").write_text("\n".join(md) + "\n")
    log(f"junk proof b{args.batch}: {out['junk_documents']} junk of {out['read']} read; decline proposal "
        f"{len(out['decline_requests'])} requests -> {d}")
    return 0


def cmd_tray(args: argparse.Namespace) -> int:
    """Jan's tray + h2's need queue from the reader's latest outcomes. Writes only the three
    files under --out-dir; no status write, no hold, no message."""
    from credit_review import account_gate
    from credit_verify.docverify import tray as tray_mod
    from credit_verify.docverify.store import DocVerifyStore, utcnow
    from credit_verify.proof import stage2
    store = DocVerifyStore(args.store)

    def gate(uid: int) -> tuple[bool, str]:
        g = account_gate.check(int(uid))
        return g.allowed, g.why()

    def tracks(ids: list[str]) -> dict[str, str]:
        return {rid: r.title for rid, r in stage2.requests(ids).items()}
    t = tray_mod.build(store, gate=gate, tracks=tracks)
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    md = out / f"jan-docs-dv-b{args.batch}.md"
    md.write_text(tray_mod.markdown(t, args.batch, utcnow()))
    (out / f"need-queue-b{args.batch}.json").write_text(json.dumps(t.need, indent=1, default=str))
    (out / f"jan-proves-b{args.batch}.json").write_text(json.dumps(t.proves, indent=1, default=str))
    log(f"tray b{args.batch}: approve {len(t.approve)}, proves {len(t.proves)}, not approvable {len(t.not_approvable)}, forged "
        f"{len(t.decline['forged'])}, contradicted {len(t.decline['contradicted'])}, need {len(t.need)}, "
        f"retry {t.retry} -> {md}")
    return 0


def cmd_summary(args: argparse.Namespace) -> int:
    from credit_verify.docverify import VERSION
    from credit_verify.docverify.store import DocVerifyStore
    store = DocVerifyStore(args.store)
    rows = store.db.execute(
        "SELECT o.outcome, COUNT(*) FROM dv_outcomes o JOIN (SELECT proof_id, request_id, role, MAX(id) id FROM "
        "dv_outcomes WHERE version=? GROUP BY 1, 2, 3) l USING(id) GROUP BY 1", (VERSION,)).fetchall()
    print(json.dumps({"version": VERSION, "since": store.get_state("since"), "outcomes": dict(rows),
                      "spent_today_usd": round(store.spent_today_usd(), 4)}, indent=1))
    return 0


def cmd_challenge(args: argparse.Namespace) -> int:
    """F9: `issue` the request's challenge code (h2 calls it when it SENDS the need=distributor_dashboard_with_code
    ask; an active code is returned again), `void` an issued code whose ask was NOT sent (a hold after the preflight;
    exit 1 when nothing was voided), or `show` its codes. Prints JSON. Writes only dv_challenges."""
    from credit_verify.docverify.store import DocVerifyStore
    from credit_verify.proof import stage2
    store = DocVerifyStore(args.store)
    if args.action == "show":
        print(json.dumps(store.challenges(args.request), indent=1))
        return 0
    if args.action == "void":
        if not args.code:
            log("challenge void needs --code")
            return 2
        res = store.void_challenge(args.request, args.code, args.reason)
        print(json.dumps(res))
        return 0 if res["voided"] else 1
    uid = args.user
    if uid is None:
        req = stage2.requests([args.request]).get(args.request)
        if req is None:
            log(f"challenge: request {args.request} not found in core; nothing issued")
            return 2
        uid = req.user_id
    print(json.dumps(store.issue_challenge(args.request, uid)))
    return 0


def parser() -> argparse.ArgumentParser:
    from credit_verify.docverify.runner import PROOF_STORE
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--store", default=None, help="doc-verify store (default /var/lib/hydra-credit-verify/doc-verify.sqlite)")
    p.add_argument("--proof-store", default=PROOF_STORE, help="H3 proof store, read-only")
    sub = p.add_subparsers(dest="cmd", required=True)
    pr = sub.add_parser("run", help="verify documents judged since the cutoff (the cron)")
    pr.add_argument("--max-docs", type=int, default=30)
    pr.add_argument("--since", default=None, help="ISO time; overrides the stored cutoff for this run")
    pr.add_argument("--workers", type=int, default=1,
                    help="parallel readers, each on its own sha256 shard (paced and capped together)")
    pr.add_argument("--reread-carried", action="store_true",
                    help="read ONLY filings whose standing rows were carried into this VERSION without a read, and "
                         "re-read those claims under the current rule (Fable 134); paid first")
    pr.add_argument("--shard", default=None, help="i/n: this process is worker i of n (set by --workers)")
    pr.set_defaults(fn=cmd_run)
    ps = sub.add_parser("eval-select", help="build the eval manifest (node-8)")
    ps.add_argument("--forged-users", default="121667,184339")
    ps.add_argument("--good", type=int, default=20)
    ps.add_argument("--scan", type=int, default=600, help="stage-2 rows scanned for known-good candidates")
    ps.add_argument("--max-gets", type=int, default=150, help="admin raw-credit GETs at most")
    ps.add_argument("--seed", type=int, default=1026)
    ps.add_argument("--out", required=True)
    ps.set_defaults(fn=cmd_eval_select)
    pe = sub.add_parser("eval", help="verify the manifest into a scratch store; markdown on stdout")
    pe.add_argument("--manifest", required=True)
    pe.set_defaults(fn=cmd_eval)
    pf = sub.add_parser("forged-tray", help="jan-forged-bN.md/.json: forged_positive documents for Fable's ruling "
                                            "and t01b's executor (captain-1028-213x); writes only those two files")
    pf.add_argument("--batch", type=int, required=True)
    pf.add_argument("--out-dir", required=True)
    pf.add_argument("--rulings", help="file with Fable's lines 'ruling: forged-<sha8> confirm|not'")
    pf.add_argument("--also-store", action="append", help="another doc-verify store, read-only, whose `forged` "
                                                           "rows are listed as short of positive (never executable)")
    pf.set_defaults(fn=cmd_forged_tray)
    pl = sub.add_parser("l11-watch", help="L11 24 h clean-read counts since the dv-2 deploy (read-only)")
    pl.add_argument("--since", required=True, help="UTC time of the deploy that carried dv-2, e.g. 2026-10-29T04:20:00Z")
    pl.add_argument("--false-forged", help="the reviewed flag file: 'false-forged: <prefix>' or 'ruling: forged-<prefix> "
                    "not' lines (e.g. trays/rulings-forged.txt). Without it false forged is UNKNOWN and never clean")
    pl.add_argument("--json", action="store_true")
    pl.add_argument("--dsp-store", default="/var/lib/hydra-credit-verify/dsp-verify.sqlite",
                    help="the DSP verifier's store (D5b anchors, read-only); '' = none")
    pl.set_defaults(fn=cmd_l11_watch)
    pj = sub.add_parser("junk-list", help="JUNK PROOF option C: artifact kind per filed document -> purge list per "
                                          "user + decline proposal (read-only; writes two files)")
    pj.add_argument("--batch", type=int, required=True)
    pj.add_argument("--out-dir", required=True)
    pj.set_defaults(fn=cmd_junk_list)
    pc = sub.add_parser("challenge", help="F9 challenge code for a request: issue (when the ask is sent), void (the ask "
                                          "was not sent) or show")
    pc.add_argument("action", choices=("issue", "void", "show"))
    pc.add_argument("--code", help="void: the code to retire")
    pc.add_argument("--reason", default="held_send", help="void: why (recorded as consumed_by 'void:<reason>')")
    pc.add_argument("--request", required=True)
    pc.add_argument("--user", type=int, help="the request's account (default: read from core)")
    pc.set_defaults(fn=cmd_challenge)
    pt = sub.add_parser("tray", help="Jan's tray (jan-docs-dv-bN.md) + h2's need queue from the latest outcomes")
    pt.add_argument("--batch", type=int, required=True)
    pt.add_argument("--out-dir", required=True)
    pt.set_defaults(fn=cmd_tray)
    pb = sub.add_parser("blob-backfill", help="restore stored bytes of support@ email filings (paced, budgeted, "
                                              "shared Gmail lock, stops on quota): the reader never calls Gmail")
    pb.add_argument("--max-messages", type=int, default=30)
    pb.add_argument("--per-min", type=int, default=6, help="Gmail message fetches per minute (default 6)")
    pb.add_argument("--intercom-max", type=int, default=30,
                    help="registered Intercom blobs that are gone, restored per run (paced 1/s; 0 = skip)")
    pb.set_defaults(fn=cmd_blob_backfill)
    pm = sub.add_parser("summary", help="outcome counts")
    pm.set_defaults(fn=cmd_summary)
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.cmd == "eval" and not args.store:
        log("eval needs --store (a scratch store, never the live one)")
        return 2
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
