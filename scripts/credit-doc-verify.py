#!/usr/bin/env python3
"""Doc-verify: never take a returned credit document at face value - SHADOW.

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
PAYING_USERS = os.environ.get("CREDIT_TRUST_PAYING_USERS", "/var/lib/credit-trust/paying-users.json")


def log(msg: str) -> None:
    print(f"[credit-doc-verify] {msg}", file=sys.stderr)


def real_deps(store, *, intercom_fetch: bool = True, strict_pacing: bool = False):
    from credit_review import admin as admin_api
    from credit_verify.docverify import crosscheck as xc
    from credit_verify.docverify import intel
    from credit_verify.docverify.extract import Extractor
    from credit_verify.docverify.runner import Deps
    from credit_verify.proof import intercom, sandbox, stage2
    from credit_verify.docverify.pace import Pacer
    admin = admin_api.AdminClient()
    tok = intercom.intercom_token() if intercom_fetch else None
    if intercom_fetch and not tok:
        log("no MUSOAI_INTERCOM_TOKEN: only cached attachments can be verified this run")
    # 1 request/s per API across EVERY reader process on the host (run --workers N): MusicBrainz's
    # own limit, and Intercom/admin GETs kept at the single-reader rate (proof-loop lead 2026-10-28).
    mb, ic, ad = (Pacer(n, 1.0, log=log, strict=strict_pacing) for n in ("musicbrainz", "intercom", "admin"))
    fetch = ic.paced(intercom.make_fetch(tok)) if tok else None
    return Deps(sandbox=sandbox.run, extractor=Extractor(store), net=xc.Net(mb_pacer=mb),
                raw_credits=lambda tid: store.cached_raw_credits(
                    tid, ad.paced(lambda t: admin_api.track_raw_credits(admin, t))),
                requests=lambda ids: stage2.requests(ids), fetch=fetch, dl=stage2.download,
                people_graph=intel.trino_name_index(stage2.trino_query), gmail_raw=_gmail_raw())


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
    return argv + (["--since", args.since] if args.since else [])


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
    log(f"workers {args.workers}: started {len(plan)} (budgets {[b for _, b in plan]}), exit {rcs}"
        + (f"; FAILED shards {sorted(bad)}" if bad else ""))
    return 1 if bad else 0


def _gmail_raw():
    from credit_verify.proof.gmail_intake import gog_raw
    return gog_raw


def cmd_run(args: argparse.Namespace) -> int:
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
                          max_docs=args.max_docs, shard=shard, paying=paying_users(), log=log)
    log("run " + json.dumps({**stats.as_dict(), "shard": args.shard}))
    print("NO_REPLY")
    return 0


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
    out["forged_caught"] = sum(r["outcome"] in ("forged", "contradicted") for r in forged)
    out["forged_verified"] = sum(r["outcome"] == "verified" for r in forged)
    out["good_false_decline"] = sum(r["outcome"] in ("forged", "contradicted") for r in good)
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


def cmd_tray(args: argparse.Namespace) -> int:
    """Jan's tray + h2's need queue from the reader's latest outcomes. Writes only the two
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
    log(f"tray b{args.batch}: approve {len(t.approve)}, not approvable {len(t.not_approvable)}, forged "
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
    pt = sub.add_parser("tray", help="Jan's tray (jan-docs-dv-bN.md) + h2's need queue from the latest outcomes")
    pt.add_argument("--batch", type=int, required=True)
    pt.add_argument("--out-dir", required=True)
    pt.set_defaults(fn=cmd_tray)
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
