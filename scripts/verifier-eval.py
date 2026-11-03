#!/usr/bin/env python3
"""verifier-eval: shared shadow evaluation for every Muso verifier (credits / claims / merges).

  build   --data DIR                 rebuild the frozen labelled sets (scripts/verifier_eval/sets/)
  run     [--verifier SPEC ...] [--verdicts SET:PATH ...] [--out DIR]
                                     replay verifiers in shadow; write verdicts.jsonl (audit rows),
                                     metrics.json, report.md, board.txt
  nightly [--root DIR]               every registered verifier + every recorded shadow log dropped in
                                     ROOT/inbox/<set>/*.jsonl; writes ROOT/<run_id>/ and ROOT/latest,
                                     appends ROOT/history.jsonl; exits 0 with a note when the kill
                                     switch /etc/hydra/verifier-eval.disabled exists
  list                               registered verifiers and set sizes

Shadow only: nothing here approves, declines, merges or messages anyone. Docs:
docs/credit-verification/verifier-eval.md
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verifier_eval import runner  # noqa: E402
from verifier_eval.verifiers import REGISTRY  # noqa: E402

DEFAULT_ROOT = os.environ.get("VERIFIER_EVAL_ROOT", "/var/lib/hydra/verifier-eval")
KEEP_RUNS = int(os.environ.get("VERIFIER_EVAL_KEEP_RUNS", "30"))


def _recorded(specs: list[str]) -> list[tuple[str, str, str]]:
    out = []
    for s in specs:
        set_name, _, path = s.partition(":")
        if set_name not in ("credits", "claims", "merges") or not path:
            raise SystemExit(f"--verdicts {s!r}: use <set>:<path.jsonl>")
        out.append((f"log:{Path(path).stem}", set_name, path))
    return out


def cmd_build(a: argparse.Namespace) -> int:
    from verifier_eval.build import build_all
    meta = build_all(Path(a.data).expanduser())
    print(json.dumps(meta, indent=1, default=str))
    return 0


def cmd_run(a: argparse.Namespace) -> int:
    specs = a.verifier or list(REGISTRY)
    recorded = _recorded(a.verdicts or []) + ([] if a.verifier or a.verdicts else runner.repo_recorded())
    summary = runner.run(specs, a.out, recorded=recorded)
    print((Path(a.out) / "board.txt").read_text().strip())
    print(f"report: {Path(a.out) / 'report.md'}")
    return 0 if all(r["clean"] or r["kind"] == "control" for r in summary["results"]) or not a.strict else 3


def cmd_nightly(a: argparse.Namespace) -> int:
    root = Path(a.root)
    if runner.kill_switch_on():
        print(f"verifier-eval: kill switch {runner.KILL_SWITCH} present - not running")
        return 0
    recorded = runner.repo_recorded()
    for set_name in ("credits", "claims", "merges"):
        for path in sorted(glob.glob(str(root / "inbox" / set_name / "*.jsonl"))):
            recorded.append((f"log:{Path(path).stem}", set_name, path))
    root.mkdir(parents=True, exist_ok=True)
    import time
    run_id = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out = root / run_id
    summary = runner.run(list(REGISTRY), out, recorded=recorded, run_id=run_id)
    latest = root / "latest"
    tmp = root / ".latest.tmp"
    if tmp.is_symlink() or tmp.exists():
        tmp.unlink()
    tmp.symlink_to(run_id)
    os.replace(tmp, latest)
    board = (out / "board.txt").read_text().strip()
    with open(root / "history.jsonl", "a", encoding="utf-8") as fh:
        fh.write(json.dumps({"run_id": run_id, "board": board,
                             "results": [{k: r[k] for k in ("verifier", "set", "kind", "clean")}
                                         | {"overall": r["overall"], "by_segment": r["by_segment"]}
                                         for r in summary["results"]]}) + "\n")
    # Retention: keep the newest KEEP_RUNS run directories (history.jsonl keeps every board line).
    runs = sorted(p for p in root.iterdir() if p.is_dir() and not p.is_symlink() and p.name[:2] == "20")
    for old in runs[:-KEEP_RUNS]:
        for f in old.iterdir():
            f.unlink()
        old.rmdir()
    print(board)
    return 0


def cmd_relabel_merges(a: argparse.Namespace) -> int:
    from verifier_eval.build import build_merges_relabel
    meta = build_merges_relabel(Path(a.facts), a.tag, strict_holds=not getattr(a, "assume_holds_absent_clean", False))
    print(json.dumps(meta, indent=1))
    return 0


def cmd_list(_a: argparse.Namespace) -> int:
    for name, r in REGISTRY.items():
        print(f"{name:32s} {r['set']:8s} {r['kind']}")
    for s in [v for b in ("credits", "claims", "merges") for v in runner.set_variants(b)]:
        try:
            print(f"set {s}: {len(runner.load_set(s))} items")
        except (OSError, ValueError) as exc:
            print(f"set {s}: UNAVAILABLE ({exc})")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--data", default="~/Projects/firstmate/data")
    r = sub.add_parser("run")
    r.add_argument("--verifier", action="append", help="registry name or <set>:<module>:<function>")
    r.add_argument("--verdicts", action="append", help="<set>:<shadow-log.jsonl> recorded by any verifier")
    r.add_argument("--out", default="verifier-eval-out", help="output dir (default ./verifier-eval-out)")
    r.add_argument("--strict", action="store_true", help="exit 3 when a non-control verifier is not clean")
    n = sub.add_parser("nightly")
    n.add_argument("--root", default=DEFAULT_ROOT)
    sub.add_parser("list")
    rm = sub.add_parser("relabel-merges", help="independent merges labels from a facts snapshot "
                                               "(scripts/verifier-eval-merge-facts.py) -> sets/merges@relabel-<tag>")
    rm.add_argument("--facts", required=True)
    rm.add_argument("--tag", required=True)
    rm.add_argument("--assume-holds-absent-clean", action="store_true",
                    help="sensitivity only: treat an unread legal-hold source as 'no holds' instead of "
                         "queued_review:LEGAL_HOLD_UNKNOWN (never the shipped labels)")
    a = ap.parse_args(argv)
    return {"build": cmd_build, "run": cmd_run, "nightly": cmd_nightly, "list": cmd_list,
            "relabel-merges": cmd_relabel_merges}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
