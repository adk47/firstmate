"""Run the per-file extraction in a sandbox.

Untrusted documents are parsed by C libraries (MuPDF, libpng/libjpeg,
tesseract), so each file is analysed in its own short-lived process. The
parent reads the file and hands its bytes to the child on stdin with the
request: the child never needs to open a host path.

  systemd (node-8 default, root + systemd): a transient service unit
      (`systemd-run --wait --pipe`) running as an unprivileged transient user
      (DynamicUser=yes) with /root, /home and /run/user hidden
      (ProtectHome=yes), PrivateNetwork=yes (no network at all), an empty
      capability set, NoNewPrivileges, ProtectSystem=strict, PrivateTmp,
      PrivateDevices, MemoryMax, a CPU quota and a hard RuntimeMaxSec. The
      code dir is bind-mounted read-only at CODE_DIR (the host path sits under
      the root-only /opt/hydra). A parser exploit can therefore read only
      world-readable host files and write only its private /tmp.
  rlimit (CI, laptops, non-root): a child process with RLIMIT_CPU / RLIMIT_AS /
      RLIMIT_FSIZE / RLIMIT_NOFILE, a wall-clock timeout, a scrubbed
      environment and a private temp cwd. No network namespace and no user
      separation: use only where the systemd mode is unavailable.

The child's environment carries no credentials (PATH, a temp HOME, and the
module path only). Mode: CREDIT_PROOF_SANDBOX=systemd|rlimit (default: systemd
when available).
"""

from __future__ import annotations

import base64
import json
import os
import resource
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

SCRIPTS = str(Path(__file__).resolve().parents[2])
WALL_S = int(os.environ.get("CREDIT_PROOF_WALL_S", "420"))  # a 76-page contract took ~230 s
CPU_S = int(os.environ.get("CREDIT_PROOF_CPU_S", "180"))
MEM_BYTES = int(os.environ.get("CREDIT_PROOF_MEM_MB", "2048")) * 1024 * 1024
MAX_BYTES = 25 * 1024 * 1024    # analyze.py reports a larger file as reject_too_large
CODE_DIR = "/tmp/code"  # tmp-ok: bind-mount target inside the unit's PrivateTmp, not a scratch path
# Host secret stores outside /root (ProtectHome=yes already hides /root).
SECRET_PATHS = ("/etc/openclaw", "/etc/hydra", "/opt/hydra/secrets")


class SandboxError(RuntimeError):
    pass


def mode() -> str:
    m = os.environ.get("CREDIT_PROOF_SANDBOX", "")
    if m in ("systemd", "rlimit"):
        return m
    if os.geteuid() == 0 and shutil.which("systemd-run") and os.path.isdir("/run/systemd/system"):
        return "systemd"
    return "rlimit"


def _limits() -> None:  # pragma: no cover - runs in the child
    for lim, val in ((resource.RLIMIT_CPU, CPU_S), (resource.RLIMIT_AS, MEM_BYTES),
                     (resource.RLIMIT_FSIZE, 256 * 1024 * 1024), (resource.RLIMIT_NOFILE, 256)):
        try:
            resource.setrlimit(lim, (val, val))
        except (ValueError, OSError):
            pass          # macOS refuses RLIMIT_AS; Linux (node-8, CI) applies all four
    os.setsid()


def systemd_argv(python: str) -> list[str]:
    """Transient-unit argv: an unprivileged transient user that sees no home
    directory, no network and only the code dir (read-only at CODE_DIR)."""
    props = [
        "DynamicUser=yes", "ProtectHome=yes",
        "PrivateNetwork=yes", "NoNewPrivileges=yes", "CapabilityBoundingSet=", "AmbientCapabilities=",
        "ProtectSystem=strict", "PrivateTmp=yes", "PrivateDevices=yes",
        "ProtectKernelTunables=yes", "ProtectKernelModules=yes", "ProtectControlGroups=yes",
        "RestrictAddressFamilies=AF_UNIX", "RestrictNamespaces=yes", "LockPersonality=yes",
        "MemoryDenyWriteExecute=no",   # numpy/OpenCV JIT-free but some BLAS builds need W^X off
        f"MemoryMax={MEM_BYTES}", "CPUQuota=100%", f"RuntimeMaxSec={WALL_S}", "TasksMax=32",
        # One thread per math library: OpenBLAS otherwise starts one per core
        # and dies against TasksMax (seen on node-8 as a SIGINT inside numpy).
        "Environment=OMP_THREAD_LIMIT=1", "Environment=OPENBLAS_NUM_THREADS=1", "Environment=OMP_NUM_THREADS=1",
        "Environment=MKL_NUM_THREADS=1", "Environment=HOME=/tmp",
        "WorkingDirectory=/tmp",
        f"BindReadOnlyPaths={SCRIPTS}:{CODE_DIR}",
    ]
    props += [f"InaccessiblePaths=-{p}" for p in SECRET_PATHS]
    argv = ["systemd-run", "--wait", "--pipe", "--quiet", "--collect", "--service-type=exec"]
    for p in props:
        argv += ["-p", p]
    # -I: isolated mode (no PYTHONPATH, no user site); the code dir is put on
    # sys.path explicitly.
    code = (f"import sys; sys.path.insert(0, {CODE_DIR!r}); "
            "from credit_verify.proof.analyze import main; sys.exit(main())")
    return argv + [python, "-I", "-c", code]


def run(path: str, declared: str | None, context: dict[str, Any],
        contexts: list[dict[str, Any]] | None = None, want_text: bool = False) -> dict[str, Any]:
    """`contexts`: check the one file against several claim contexts in a
    single sandboxed run (analyze.extract_bytes, `per_context`). `want_text`:
    also return the document's text, bounded (`doc_text`, doc-verify only)."""
    try:
        with open(path, "rb") as fh:
            data = fh.read(MAX_BYTES + 1)
    except OSError as exc:
        raise SandboxError(f"file unreadable: {type(exc).__name__}") from exc
    # `path` is only the label the child cites as evidence; it reads `data`.
    req = json.dumps({"path": os.path.abspath(path), "data": base64.b64encode(data).decode("ascii"),
                      "declared": declared, "context": context,
                      **({"contexts": contexts} if contexts else {}),
                      **({"want_text": True} if want_text else {})})
    m = mode()
    with tempfile.TemporaryDirectory(prefix="cvproof-") as tmp:
        if m == "systemd":
            argv = systemd_argv(sys.executable)
            env = {"PATH": "/usr/bin:/bin"}
            pre = None
        else:
            argv = [sys.executable, "-m", "credit_verify.proof.analyze"]
            env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "PYTHONPATH": SCRIPTS, "HOME": tmp,
                   "OMP_THREAD_LIMIT": "1", "OPENBLAS_NUM_THREADS": "1", "OMP_NUM_THREADS": "1", "TMPDIR": tmp}
            pre = _limits
        try:
            p = subprocess.run(argv, input=req, capture_output=True, text=True, timeout=WALL_S + 30, env=env,
                               cwd=tmp, preexec_fn=pre, check=False)
        except subprocess.TimeoutExpired as exc:
            raise SandboxError(f"analysis timed out after {WALL_S}s") from exc
    if p.returncode != 0:
        raise SandboxError(f"analysis process rc={p.returncode}: {p.stderr.strip()[-300:]}")
    try:
        return json.loads(p.stdout)
    except ValueError as exc:
        raise SandboxError(f"analysis returned no JSON: {p.stderr.strip()[-300:]}") from exc
