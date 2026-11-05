#!/usr/bin/env python3
"""Refuse a production model route that is not ZDR, or that allows int4/int8.

Captain 2026-11-04: "we need [ZDR] ... only use the fastest cheapest ZDR
deepseek models ... make sure we aren't wasting money and protect our code".
Ruling: every production DeepSeek/GLM caller uses the ONE OpenRouter ZDR routing
block, and Fireworks is retired from production paths.

Two layers enforce it, and this script is the CONFIG layer:

  * runtime — ``scripts/lib/model_chain.py:validate_routing`` refuses a block
    that is not ZDR or that allows a lossy quantization, and ``call_deepseek``
    sends the validated block on every metered call. A caller cannot opt out.
  * config — this script. The OpenClaw gateways route through OpenRouter too,
    and their routing lives in JSON (``compat.openRouterRouting`` on the model
    entry), not in Python. A config edit that drops ``zdr`` or widens
    ``quantizations`` to int4/int8 would otherwise be invisible until a
    customer's document landed on a lossy host.

What it checks, per config file:

  1. every ``openrouter/<deepseek|z-ai|zai>/...`` model ref resolves to a
     catalog entry whose ``compat.openRouterRouting`` passes
     ``validate_routing`` (zdr true, data_collection deny, price sort,
     fp8/bf16/fp16 only, max_price capped);
  2. no ``fireworks/...`` model ref survives anywhere (retired 2026-11-04);
  3. every Python caller that builds an OpenRouter chat body references
     ``ZDR_ROUTING`` (a pin against a new call site being written without it).

Usage:  check-zdr-routing.py [config.json ...]
        (no args -> openclaw-main.json, openclaw-edge.json, cron-jobs.json,
         pods/*/openclaw-*.json from the repo root)
Exit:   0 clean, 1 violation, 2 unreadable input
"""

from __future__ import annotations

import glob
import json
import sys
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from lib.model_chain import UnsafeRouting, validate_routing  # noqa: E402

# Model families the ruling covers. A Claude/GPT ref is out of scope here: those
# stay on the token pool (CLIProxyAPI), not on OpenRouter routing.
ZDR_FAMILIES = ("deepseek/", "z-ai/", "zai/", "z-ai:", "thudm/", "qwen/")
RETIRED_PROVIDERS = ("fireworks/",)

# The PRODUCTION profile set. Pinned, not globbed: a renamed profile must be a
# red job, not a silently shorter check list (QA 2026-11-04). Every other pod
# under pods/*/openclaw-*.json that exists is checked IN ADDITION to these.
REQUIRED_CONFIGS = ("openclaw-main.json", "openclaw-edge.json", "cron-jobs.json",
                    "pods/qa-review-gateway/openclaw-qa.json")

# Every Python surface that builds an OpenRouter chat body, with a PROBE that
# returns the provider block it would actually send. A probe, not a grep for the
# token: deleting the assignment while keeping a comment that mentions
# ZDR_ROUTING left the old check green, and the legacy credit-judge direct
# transport would then have sent credit data with no filter at all (QA
# 2026-11-04). Each probe raises or returns an unsafe block and the guard fails.
def _probe_model_chain() -> Any:
    from lib import model_chain
    sent: dict[str, Any] = {}

    class _Resp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return json.dumps({"model": "m", "choices": [{"message": {"content": "ok"},
                                                             "finish_reason": "stop"}],
                               "usage": {}}).encode()

    def opener(req, timeout=None):
        sent["body"] = json.loads(req.data.decode())
        return _Resp()

    model_chain.call_deepseek([{"role": "user", "content": "probe"}], key="probe", opener=opener)
    return sent["body"].get("provider")


def _probe_credit_judge() -> Any:
    from credit_review.judge import Judge
    # "review" is the default decision mode; the payload builder is shared by
    # both modes, so one probe covers the block.
    body = Judge(web=False).payload("review", {})
    return body.get("provider")


def _probe_doc_verify() -> Any:
    from credit_verify.docverify import extract
    body = extract.request_body("deepseek/deepseek-v4.1-flash-1017",
                                [{"role": "user", "content": "probe"}])
    return body.get("provider")


PY_CALLERS = (
    ("scripts/lib/model_chain.py", _probe_model_chain),
    ("scripts/credit_verify/docverify/extract.py", _probe_doc_verify),
    ("scripts/credit_review/judge.py", _probe_credit_judge),
)


def default_configs() -> list[str]:
    """The required set plus any additional pod profile."""
    out = list(REQUIRED_CONFIGS)
    for path in sorted(glob.glob(str(ROOT / "pods" / "*" / "openclaw-*.json"))):
        rel = str(Path(path).relative_to(ROOT))
        if rel not in out:
            out.append(rel)
    return out


def walk_strings(node: Any) -> Iterable[str]:
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for v in node.values():
            yield from walk_strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk_strings(v)


def catalog(cfg: dict[str, Any]) -> tuple[dict[tuple[str, str], Any], list[str]]:
    """(provider key, model id) -> declared ``compat.openRouterRouting``.

    Keyed by the PROVIDER TOO, and duplicate ids are returned as problems.
    QA 2026-11-04 reproduced the collision this closes: with a flat
    ``model id -> routing`` map, an OpenRouter DeepSeek entry that LOST its
    routing was silently overwritten by any other provider declaring the same
    id with a valid block, and the guard reported clean while the live
    ``openrouter/deepseek/...`` route had no ZDR filter at all.
    """
    out: dict[tuple[str, str], Any] = {}
    duplicates: list[str] = []
    providers = ((cfg.get("models") or {}).get("providers") or {})
    for provider_key, provider in providers.items():
        for model in (provider or {}).get("models") or []:
            if not (isinstance(model, dict) and isinstance(model.get("id"), str)):
                continue
            key = (str(provider_key), model["id"])
            if key in out:
                duplicates.append(f"{provider_key}/{model['id']}")
            out[key] = (model.get("compat") or {}).get("openRouterRouting")
    return out, duplicates


def check_config(path: Path, inherited: dict[tuple[str, str], Any] | None = None) -> list[str]:
    """``inherited`` is the merged catalog of the PROFILE configs, for a file
    that declares no catalog of its own (cron-jobs.json references models the
    gateways define). A file that DOES declare a catalog is judged on its own,
    so one profile cannot mask another's missing routing."""
    problems: list[str] = []
    try:
        cfg = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"{path}: unreadable ({exc})"]
    if not isinstance(cfg, dict):
        return [f"{path}: not a JSON object"]

    own, duplicates = catalog(cfg)
    for dup in duplicates:
        # An ambiguous id means the guard cannot say which entry the runtime
        # resolves, so neither answer is trustworthy.
        problems.append(f"{path}: model id declared twice in the same provider: {dup}")
    lookup = own if own else (inherited or {})
    refs = sorted({s for s in walk_strings(cfg)
                   if s.startswith("openrouter/") or s.startswith(RETIRED_PROVIDERS)})
    for ref in refs:
        if ref.startswith(RETIRED_PROVIDERS):
            problems.append(f"{path}: retired provider still referenced: {ref} "
                            "(Fireworks is out of production paths; use "
                            "openrouter/deepseek/deepseek-v4.1-flash-1017)")
            continue
        model_id = ref[len("openrouter/"):]
        if not model_id.startswith(ZDR_FAMILIES):
            continue
        # The ref is `openrouter/<id>`; the catalog entry that governs it is the
        # one under the SAME provider key, never another provider's same id.
        if ("openrouter", model_id) not in lookup:
            problems.append(f"{path}: {ref} is not declared under the openrouter provider "
                            "in any model catalog, so it routes with no ZDR filter")
            continue
        routing = lookup[("openrouter", model_id)]
        if routing is None:
            problems.append(f"{path}: {ref} has no compat.openRouterRouting in its model "
                            "catalog entry, so it routes with no ZDR filter")
            continue
        try:
            validate_routing(routing)
        except UnsafeRouting as exc:
            problems.append(f"{path}: {ref} routing is unsafe: {exc}")
    return problems


def check_python_callers() -> list[str]:
    """Ask each caller what it would send, and judge the answer."""
    problems: list[str] = []
    for rel, probe in PY_CALLERS:
        if not (ROOT / rel).exists():
            problems.append(f"{rel}: missing (the caller it pins no longer exists)")
            continue
        try:
            block = probe()
        except Exception as exc:  # a caller that cannot be probed is not provably safe
            problems.append(f"{rel}: could not probe its outgoing provider block ({exc!r})")
            continue
        try:
            validate_routing(block)
        except UnsafeRouting as exc:
            problems.append(f"{rel}: sends an unsafe provider block: {exc}")
    return problems


def main(argv: list[str]) -> int:
    configs = argv or default_configs()
    if not configs:
        print("check-zdr-routing: no config files found", file=sys.stderr)
        return 2
    problems: list[str] = []
    paths: list[Path] = []
    for name in configs:
        path = Path(name)
        if not path.is_absolute():
            path = ROOT / path
        if not path.exists():
            # A missing EXPLICIT input is a failure, never a skip: a renamed
            # production profile would otherwise go unchecked while CI passed.
            problems.append(f"{name}: required config is missing (checked at {path})")
            continue
        paths.append(path)
    if not paths:
        # A guard that checked nothing must never report clean.
        print("check-zdr-routing: no config file could be read", file=sys.stderr)
        return 2
    # The profile configs own the model catalog; a cron file only references it.
    # The repo's own profiles are always in the pool, so checking cron-jobs.json
    # alone still resolves the models the gateways declare.
    inherited: dict[tuple[str, str], Any] = {}
    pool = list(paths) + [ROOT / p for p in default_configs()]
    for path in pool:
        try:
            found, _ = catalog(json.loads(path.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            continue
        inherited.update(found)
    for path in paths:
        problems += check_config(path, inherited)
    problems += check_python_callers()
    if problems:
        for p in problems:
            print(f"ERROR: {p}", file=sys.stderr)
        print(f"check-zdr-routing: {len(problems)} violation(s)", file=sys.stderr)
        return 1
    print(f"check-zdr-routing: clean ({len(configs)} config(s), {len(PY_CALLERS)} python caller(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
