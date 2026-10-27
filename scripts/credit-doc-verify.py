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


def log(msg: str) -> None:
    print(f"[credit-doc-verify] {msg}", file=sys.stderr)


def real_deps(store, *, intercom_fetch: bool = True):
    from credit_review import admin as admin_api
    from credit_verify.docverify import crosscheck as xc
    from credit_verify.docverify.extract import Extractor
    from credit_verify.docverify.runner import Deps
    from credit_verify.proof import intercom, sandbox, stage2
    admin = admin_api.AdminClient()
    tok = intercom.intercom_token() if intercom_fetch else None
    if intercom_fetch and not tok:
        log("no MUSOAI_INTERCOM_TOKEN: only cached attachments can be verified this run")
    return Deps(sandbox=sandbox.run, extractor=Extractor(store), net=xc.Net(),
                raw_credits=lambda tid: admin_api.track_raw_credits(admin, tid),
                requests=lambda ids: stage2.requests(ids), fetch=intercom.make_fetch(tok) if tok else None,
                dl=stage2.download)


def cmd_run(args: argparse.Namespace) -> int:
    from credit_verify.docverify import runner
    from credit_verify.docverify.store import DocVerifyStore
    if Path(KILL_SWITCH).exists():
        log(f"kill switch present at {KILL_SWITCH}; no doc-verify")
        print("NO_REPLY")
        return 0
    store = DocVerifyStore(args.store)
    stats, _ = runner.run(store, real_deps(store), proof_store=args.proof_store, since=args.since,
                          max_docs=args.max_docs, log=log)
    log("run " + json.dumps(stats.as_dict()))
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
