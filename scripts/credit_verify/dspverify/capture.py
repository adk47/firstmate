"""Send pod_driver.py into an IDP catalog-admin pod and return its JSON (the fresh-capture hop).

The verifier's own process (a node-8 / cluster job, never Caroline) runs `kubectl exec` into a
Running `industry-proc-catalog-admin` pod in muso-prod with the driver source on stdin, exactly as
the Fable deciders' dsp3.py did on 2026-10-27. Read-only on credits: the only side effect of
`submit` is the instant-priority capture itself.
"""

from __future__ import annotations

import json
import os
import random
import shlex
import subprocess
from pathlib import Path
from typing import Any, Callable

DRIVER = Path(__file__).with_name("pod_driver.py")
KUBECTL = os.environ.get("CREDIT_DSP_KUBECTL", "kubectl")
NAMESPACE = os.environ.get("CREDIT_DSP_NAMESPACE", "muso-prod")
POD_PREFIX = os.environ.get("CREDIT_DSP_POD_PREFIX", "industry-proc-catalog-admin")
TIMEOUT_S = int(os.environ.get("CREDIT_DSP_EXEC_TIMEOUT_S", "1800"))
OUT_PREFIX = "DSP_CAPTURE_JSON="
BOOT = ("cd /code && python -c \"import sys,json; d=json.load(sys.stdin); ns={'__name__':'dsp'}; "
        "exec(d['driver'], ns); print(ns['OUT_PREFIX']+json.dumps(ns['main'](d), default=str))\"")

Run = Callable[..., "subprocess.CompletedProcess[str]"]


class CaptureError(RuntimeError):
    pass


def _run(argv: list[str], **kw: Any) -> "subprocess.CompletedProcess[str]":
    return subprocess.run(argv, capture_output=True, text=True, check=False, **kw)


def pick_pod(run: Run = _run) -> str:
    p = run(shlex.split(KUBECTL) + ["-n", NAMESPACE, "get", "pods", "--no-headers"], timeout=90)
    pods = [ln.split()[0] for ln in (p.stdout or "").splitlines()
            if ln.startswith(POD_PREFIX) and " Running " in f" {ln} "]
    if not pods:
        raise CaptureError(f"no {POD_PREFIX} pod Running in {NAMESPACE}")
    return random.choice(pods)


def call(mode: str, items: list[dict[str, Any]], run: Run = _run) -> list[dict[str, Any]]:
    """One exec: `mode` in (submit, read) for `items`; returns the driver's per-item rows."""
    if mode not in ("submit", "read"):
        raise ValueError(mode)
    pod = pick_pod(run)
    payload = json.dumps({"mode": mode, "driver": DRIVER.read_text(encoding="utf-8"), "items": items})
    p = run(shlex.split(KUBECTL) + ["-n", NAMESPACE, "exec", "-i", pod, "--", "sh", "-c", BOOT],
            input=payload, timeout=TIMEOUT_S)
    line = next((ln for ln in (p.stdout or "").splitlines() if ln.startswith(OUT_PREFIX)), None)
    if p.returncode or not line:
        raise CaptureError(f"{mode} on {pod}: rc={p.returncode} {(p.stderr or '')[-400:]}")
    body = json.loads(line[len(OUT_PREFIX):])
    rows = body.get("items") if isinstance(body, dict) else None
    if not isinstance(rows, list):
        raise CaptureError(f"{mode} on {pod}: no items[] in the answer")
    return rows
