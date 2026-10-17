#!/usr/bin/env python3
"""Credit trust system - hydra-side CLI (Fable design 2026-10-15; T01).

Subcommands:
  llm-probe   One model call through the ladder (or one named provider) with a
              fixed prompt; prints provider / model / latency / tokens / cost /
              citations / the codex argv + safety verdict, and writes the
              ledger row(s).  e.g.  credit-trust.py llm-probe --provider codex
  web-check   Server-fetched sources (MusicBrainz, Wikipedia, ...) judged by
              tool-less Codex: one credit claim -> verdict + VERIFIED quotes
              with URL + snapshot sha256.  Read-only; nothing is written to Muso.
  llm-calls   The latest rows of the append-only llm_calls ledger.

Every model call is one row in /var/lib/hydra/credit-trust/ledger.sqlite3
(table llm_calls: provider, model, prompt_sha256, tokens, cost, citations).
Design: docs/credit-verification/credit-trust-llm.md
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_trust.ledger import Ledger  # noqa: E402
from credit_trust.llm import DEFAULT_LADDER, Provider  # noqa: E402

PROBE_PROMPT = ("Who is credited for mixing on 'Birds of a Feather' by Billie Eilish? Answer with cited URLs")
PROBE_SCHEMA = {"type": "object", "additionalProperties": False,
                "required": ["answer", "credited_people", "sources"],
                "properties": {"answer": {"type": "string"},
                               "credited_people": {"type": "array", "items": {"type": "string"}},
                               "sources": {"type": "array", "items": {"type": "string"}}}}


def cmd_llm_probe(args: argparse.Namespace) -> int:
    ladder = DEFAULT_LADDER if args.provider == "ladder" else (args.provider,)
    web = bool(args.web)
    prov = Provider(Ledger(args.ledger), ladder=ladder, codex_model=args.model,
                    codex_web=True if (args.web and args.provider == "codex") else None)
    r = prov.judge(args.prompt, PROBE_SCHEMA, images=args.image or [], web=web, step="probe")
    meta = r.meta or {}
    out = {"ok": r.ok, "provider": r.provider, "model": r.model, "latency_ms": r.latency_ms,
           "tokens": r.tokens, "cost_usd": r.cost_usd, "citations": r.citations, "uncited_urls": r.uncited_urls,
           "prompt_sha256": r.prompt_sha256, "llm_call_id": r.llm_call_id, "error": r.error,
           "attempts": r.attempts, "answer": r.json}
    if r.provider == "codex":
        argv = meta.get("argv") or []
        out["codex"] = {"account": meta.get("account"), "codex_version": meta.get("codex_version"),
                        "run_as": meta.get("run_as"), "safety": meta.get("safety"),
                        "tool_census": meta.get("tool_census"),
                        "shell_disabled": _has_pair(argv, "--disable", "shell_tool"),
                        "read_only_sandbox": _has_pair(argv, "-s", "read-only"), "argv": argv}
    print(json.dumps(out, indent=1, ensure_ascii=False, default=str))
    return 0 if r.ok else 1


def cmd_web_check(args: argparse.Namespace) -> int:
    from credit_trust.credibility import FetchedSourcesJudge
    from credit_trust.websearch import Searcher
    evidence = {"claim": {"person_or_profile_name": args.person, "claimed_roles": args.role},
                "track": {"title": args.title, "artists": args.artist, "isrc": args.isrc,
                          "catalog_popularity": args.pop, "big_track": args.pop is None or args.pop >= 60},
                "trusted_catalog_credits_by_role": [], "profile": None, "rule_validator": None}
    prov = Provider(Ledger(args.ledger), ladder=("codex",), codex_model=args.model)
    j = FetchedSourcesJudge(prov, Searcher(snapshot_dir=args.snapshots, max_docs=args.max_docs), step="web_credibility")
    res = j.judge(args.mode, evidence)
    print(json.dumps(res.as_dict(), indent=1, ensure_ascii=False, default=str))
    return 0 if res.ok else 1


def cmd_llm_calls(args: argparse.Namespace) -> int:
    for row in Ledger(args.ledger).rows(since=args.since, limit=args.limit):
        d = dict(row)
        print(json.dumps({k: d[k] for k in ("id", "ts", "step", "provider", "outcome", "reason", "model",
                                            "prompt_sha256", "input_tokens", "output_tokens", "cost_usd",
                                            "latency_ms", "uncited_urls", "raw_path")}, default=str))
    return 0


def _has_pair(argv: list[str], flag: str, value: str) -> bool:
    return any(a == flag and b == value for a, b in zip(argv, argv[1:]))


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--ledger", default=None, help="llm_calls ledger (default /var/lib/hydra/credit-trust/ledger.sqlite3)")
    sub = p.add_subparsers(dest="cmd", required=True)

    pr = sub.add_parser("llm-probe")
    pr.add_argument("--provider", choices=["ladder", "codex", "jev"], default="ladder")
    pr.add_argument("--model", default=None, help="codex model (default $CREDIT_TRUST_CODEX_MODEL or gpt-6.1-sol)")
    pr.add_argument("--prompt", default=PROBE_PROMPT)
    pr.add_argument("--image", action="append", help="attach an image (repeatable)")
    w = pr.add_mutually_exclusive_group()
    w.add_argument("--web", dest="web", action="store_true", default=None,
                   help="ask for web search (codex: re-runs the headless-search check)")
    w.add_argument("--no-web", dest="web", action="store_false")
    pr.set_defaults(fn=cmd_llm_probe)

    wc = sub.add_parser("web-check")
    wc.add_argument("--person", required=True)
    wc.add_argument("--role", action="append", required=True)
    wc.add_argument("--title", required=True)
    wc.add_argument("--artist", action="append", default=[])
    wc.add_argument("--isrc", default=None)
    wc.add_argument("--pop", type=int, default=None)
    wc.add_argument("--mode", choices=["audit", "review"], default="review")
    wc.add_argument("--model", default=None)
    wc.add_argument("--max-docs", type=int, default=4)
    wc.add_argument("--snapshots", default="/var/lib/hydra/credit-trust/snapshots")
    wc.set_defaults(fn=cmd_web_check)

    lc = sub.add_parser("llm-calls")
    lc.add_argument("--since", default=None)
    lc.add_argument("--limit", type=int, default=20)
    lc.set_defaults(fn=cmd_llm_calls)
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
