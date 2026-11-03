#!/usr/bin/env python3
"""DSP evidence verifier for pending credit requests - SHADOW ONLY.

Design, rules and the process split: docs/credit-verification/dsp-evidence-verifier.md.

Subcommands:
  submit           File fresh Spotify + Tidal captures (IDP helpers.fresh_capture, instant priority)
                   for pending requests, paid first then oldest, grouped per user.
  verify           Read every open capture, build each request's evidence packet (core + catalog +
                   account gate + watchlist/deny + duplicate + capture) and log the verdict.
  run              submit, then verify (the job's one-shot; a capture is read again by the next run
                   until it closes).
  verify-packets   Verdicts for ready-made packets (JSON list or JSONL, file or '-'), one JSON line
                   per verdict on stdout. No network. The verifier-eval-v1 entry point.
  anchors          For an APPROVE tray (JSON {action, rows:[{request_id, ruling_id, roles?}]}), build the
                   server-side anchor record per row (kind dsp_anchor / dsp_label_line, schema dsp-anchor/1)
                   from the verifier's OWN standing verdict and packet, never from the tray; log every
                   record or refusal to dsp_anchors and print them as JSONL. Fable ruling
                   l12-approvals-core = A. `--write` is refused: core has no anchor endpoint yet.
  d5b              D5b (Fable 171): every request doc-verify reads `verified` gets a same-run capture (submit,
                   unless one is open or a final verdict is < 24 h old), verify reads it, and an APPROVE verdict
                   gets its dsp-anchor/1 record built locally. A document never upgrades a WAIT.
  link-proposals   Profile-link proposals, SHADOW (Fable [key=profile-link-anchor]): read this store READ-ONLY
                   and propose a DSP contributor id for the presented profile only when unambiguous
                   (dspverify/link_proposal.py); rows go to `link_proposals` in the decider ledger. Never core.
  link-queue       The shadow proposals as a blind JSONL queue for verifier-eval-v1 (no basis, no confidence).
  link-score       Score verifier-eval-v1's labels ({proposal_id: correct|wrong|unsure}) against the bar.
  export           The standing (latest) verdict per request as JSONL on stdout.
  summary          Counts of the standing verdicts (by verdict, class, need, anchor, paid).

Writes only its own store (/var/lib/hydra-credit-verify/dsp-verify.sqlite). Never writes to core,
never messages anyone, never approves / declines / merges: there is no apply mode. The only side
effect outside the store is the fresh capture itself (a raw refresh, like any capture).
Kill switches: /etc/hydra/credit-dsp-verify.disabled, and the shared /etc/hydra/credit-verify.disabled.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

KILL_SWITCHES = (os.environ.get("CREDIT_DSP_VERIFY_KILL_SWITCH", "/etc/hydra/credit-dsp-verify.disabled"),
                 os.environ.get("CREDIT_VERIFY_KILL_SWITCH", "/etc/hydra/credit-verify.disabled"))


def log(msg: str) -> None:
    print(f"[credit-dsp-verify] {msg}", file=sys.stderr)


def killed() -> str | None:
    return next((p for p in KILL_SWITCHES if p and Path(p).exists()), None)


class PacedAdmin:
    """Every admin GET through the HOST-WIDE admin pacer (1/s across every process, shared with the doc-verify
    readers; 2026-10-30 05:13Z: an unpaced paid-queue submit beside 4 reader shards got HTTP 429)."""

    def __init__(self, admin):
        from credit_verify.docverify.pace import Pacer
        self._admin, self._pacer = admin, Pacer("admin", 1.0, log=log)

    def get(self, path, params=None):
        self._pacer.wait()
        return self._admin.get(path, params)

    def __getattr__(self, name):
        return getattr(self._admin, name)


def real_deps():
    from credit_review import account_gate
    from credit_review import admin as admin_api
    from credit_review import watchlist
    from credit_review.decide import Policy, paying_users
    from credit_verify.dspverify import capture
    from credit_verify.dspverify.runner import Deps, trino_open_requests, trino_org_claim
    from credit_verify.proof.stage2 import trino_query
    pol = Policy.load()                    # deny lists + the fraud watchlist; missing/malformed = fatal
    wl = watchlist.load(required=True)     # the watchlist on its own, so its flag is recorded per row
    paying, why = paying_users()
    if paying is None:
        log(f"paying status unknown ({why}): plain oldest-first order")
    return Deps(admin=PacedAdmin(admin_api.AdminClient()), capture=capture.call, gate=account_gate.Cached(),
                deny_user_ids=frozenset(pol.deny_user_ids), deny_profile_ids=frozenset(pol.deny_profile_ids),
                watch_user_ids=frozenset(wl.user_ids),
                watch_profile_ids=frozenset(str(x).lower() for x in wl.profile_ids),
                paying=paying, org_claim=trino_org_claim(trino_query),
                select=trino_open_requests(trino_query), log=log)


def cmd_submit(args: argparse.Namespace) -> int:
    from credit_verify.dspverify import runner
    from credit_verify.dspverify.store import Store
    if (k := killed()):
        log(f"kill switch present at {k}; nothing submitted")
        print("NO_REPLY")
        return 0
    only = None
    if args.tray:
        # Every row of the tray, whatever its action: a reject tray is checked too (an anchored row
        # is refused from a reject tray and goes to the approve path, Fable junk-b1).
        tray = json.loads(Path(args.tray).read_text(encoding="utf-8"))
        only = {str(r["request_id"]).lower() for r in tray.get("rows") or [] if isinstance(r, dict) and r.get("request_id")}
        log(f"tray {args.tray}: {len(only)} rows")
    runner.submit(Store(args.store), real_deps(), max_requests=args.max_requests, only=only)
    print("NO_REPLY")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    from credit_verify.dspverify import runner
    from credit_verify.dspverify.store import Store
    if (k := killed()):
        log(f"kill switch present at {k}; nothing verified")
        print("NO_REPLY")
        return 0
    runner.verify(Store(args.store), real_deps(), max_groups=args.max_groups)
    print("NO_REPLY")
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    from credit_verify.dspverify import runner
    from credit_verify.dspverify.store import Store
    if (k := killed()):
        log(f"kill switch present at {k}; no run")
        print("NO_REPLY")
        return 0
    store, deps = Store(args.store), real_deps()
    runner.verify(store, deps, max_groups=args.max_groups)       # read what earlier runs filed
    runner.submit(store, deps, max_requests=args.max_requests)   # then file the next captures
    print("NO_REPLY")
    return 0


def cmd_d5b(args: argparse.Namespace) -> int:
    """D5b (Fable 171): same-run captures + anchors for doc-verify's verified requests (see dspverify/d5b.py)."""
    from credit_verify.dspverify import d5b
    from credit_verify.dspverify.store import Store
    if (k := killed()):
        log(f"kill switch present at {k}; no d5b run")
        print("NO_REPLY")
        return 0
    d5b.run(Store(args.store), real_deps(), dv_path=args.doc_verify_store, max_groups=args.max_groups,
            max_requests=args.max_requests, pending_max=args.max_requests, log=log)
    print("NO_REPLY")
    return 0


def read_packets(path: str) -> list[dict]:
    text = sys.stdin.read() if path == "-" else Path(path).read_text(encoding="utf-8")
    text = text.strip()
    if not text:
        return []
    if text.startswith("["):
        return json.loads(text)
    return [json.loads(ln) for ln in text.splitlines() if ln.strip()]


def cmd_verify_packets(args: argparse.Namespace) -> int:
    from credit_verify.dspverify import runner
    from credit_verify.dspverify.store import Store
    store = Store(args.store) if args.log else None
    for v in runner.verify_packets(read_packets(args.packets), store):
        print(json.dumps(v, ensure_ascii=False, default=str))
    return 0


def cmd_anchors(args: argparse.Namespace) -> int:
    from credit_verify.dspverify import runner
    from credit_verify.dspverify.store import Store
    if (k := killed()):
        log(f"kill switch present at {k}; no anchors")
        return 0
    if args.write:
        log("--write refused: core has no server-side anchor endpoint yet (Fable l12-approvals-core step 3: the "
            "core PR for the anchor table / proof kind comes first). Records are built and logged locally only.")
        return 2
    _, out = runner.build_anchors(Store(args.store), json.loads(Path(args.tray).read_text(encoding="utf-8")), log=log)
    for o in out:
        print(json.dumps(o, ensure_ascii=False, default=str))
    return 0


def cmd_link_proposals(args: argparse.Namespace) -> int:
    """SHADOW link proposals. Reads the V9 store read-only; writes only link_proposals / link_runs."""
    from credit_verify.dspverify import VERSION, link_proposal
    from credit_verify.dspverify.store import DEFAULT_PATH
    if (k := killed()):
        log(f"kill switch present at {k}; no link proposals")
        print("NO_REPLY")
        return 0
    claim = None
    if not args.no_claim_lookup:
        from credit_verify.dspverify.runner import trino_org_claim
        from credit_verify.proof.stage2 import trino_query
        claim = trino_org_claim(trino_query)       # any failure = None = no claim evidence (never a proposal)
    c = link_proposal.run(args.store or DEFAULT_PATH, args.ledger, claim_lookup=claim, dry_run=args.dry_run, log=log)
    log(f"V9 version {VERSION}, rule {link_proposal.RULE_VERSION}")
    print(json.dumps(c, indent=1, sort_keys=True, default=str) if args.dry_run or args.json else "NO_REPLY")
    return 0


def cmd_link_queue(args: argparse.Namespace) -> int:
    from credit_verify.dspverify import link_proposal
    db = link_proposal.open_ledger(args.ledger)
    for row in link_proposal.blind_queue(db):
        print(json.dumps(row, ensure_ascii=False, default=str))
    return 0


def cmd_link_score(args: argparse.Namespace) -> int:
    from credit_verify.dspverify import link_proposal
    labels = json.loads(Path(args.labels).read_text(encoding="utf-8"))
    if not isinstance(labels, dict):
        log("labels must be a JSON object {proposal_id: correct|wrong|unsure}")
        return 2
    out = link_proposal.score(link_proposal.open_ledger(args.ledger), {str(k): v for k, v in labels.items()})
    print(json.dumps(out, indent=1, sort_keys=True))
    return 0 if out["bar_met"] else 1


def cmd_export(args: argparse.Namespace) -> int:
    from credit_verify.dspverify.store import Store, export_jsonl
    for line in export_jsonl(Store(args.store).latest()):
        print(line)
    return 0


def cmd_summary(args: argparse.Namespace) -> int:
    from credit_verify.dspverify.store import Store
    print(json.dumps(Store(args.store).summary(), indent=1, sort_keys=True))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--store", default=None, help="shadow store path (default $CREDIT_DSP_VERIFY_STORE)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("submit")
    s.add_argument("--max-requests", type=int, default=300)
    s.set_defaults(fn=cmd_submit)
    s.add_argument("--tray", default=None, help="only this approve tray's request ids")
    s = sub.add_parser("verify")
    s.add_argument("--max-groups", type=int, default=200)
    s.set_defaults(fn=cmd_verify)
    s = sub.add_parser("run")
    s.add_argument("--max-requests", type=int, default=300)
    s.add_argument("--max-groups", type=int, default=200)
    s.set_defaults(fn=cmd_run)
    s = sub.add_parser("d5b", help="D5b: capture + anchor doc-verify's verified requests (own store only)")
    s.add_argument("--doc-verify-store", default="/var/lib/hydra-credit-verify/doc-verify.sqlite")
    s.add_argument("--max-requests", type=int, default=300)
    s.add_argument("--max-groups", type=int, default=200)
    s.set_defaults(fn=cmd_d5b)
    s = sub.add_parser("verify-packets")
    s.add_argument("packets", help="JSON list or JSONL file of packets, or '-' for stdin")
    s.add_argument("--log", action="store_true", help="also log the verdicts to the shadow store")
    s.set_defaults(fn=cmd_verify_packets)
    s = sub.add_parser("anchors")
    s.add_argument("--tray", required=True)
    s.add_argument("--write", action="store_true", help="refused until core's anchor endpoint exists")
    s.set_defaults(fn=cmd_anchors)
    s = sub.add_parser("link-proposals", help="SHADOW profile-link proposals (decider ledger only, never core)")
    s.add_argument("--ledger", default=None, help="decider ledger (default $CREDIT_REVIEW_LEDGER)")
    s.add_argument("--dry-run", action="store_true", help="print what would be recorded; write nothing")
    s.add_argument("--no-claim-lookup", action="store_true",
                   help="skip the Trino processed-claim read (the one-track + claim basis then never applies)")
    s.add_argument("--json", action="store_true", help="print the run counts")
    s.set_defaults(fn=cmd_link_proposals)
    s = sub.add_parser("link-queue", help="blind JSONL queue of shadow proposals for verifier-eval-v1")
    s.add_argument("--ledger", default=None)
    s.set_defaults(fn=cmd_link_queue)
    s = sub.add_parser("link-score", help="score labels against the 24 h / 0-wrong bar (exit 1 = bar not met)")
    s.add_argument("--ledger", default=None)
    s.add_argument("--labels", required=True)
    s.set_defaults(fn=cmd_link_score)
    sub.add_parser("export").set_defaults(fn=cmd_export)
    sub.add_parser("summary").set_defaults(fn=cmd_summary)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
