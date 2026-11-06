"""Mirror a HOST demotion into the repo registry via a PR.

The host state file (`registry-state.json`) is what stops a capability in seconds.
The repo file is what survives a deploy. A demotion that exists only on the host is a
switch in one place — the 2026-10-27 lesson — so every tick that demotes also opens a
PR that flips the same row in `policies/sentinel-capabilities.json`.

Why a dedicated checkout: /opt/hydra is the rsync target and has no `.git` (deploy.sh
excludes it). A service that tried to clone on first use would block on an auth
prompt, so the checkout at `/var/lib/hydra/sentinel/mirror-repo` is created by
`scripts/install-aux-units.sh` at deploy time and this module REFUSES loudly when it
is missing (same discipline as scripts/release-cron.sh).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence

MIRROR_REPO_DEFAULT = "/var/lib/hydra/sentinel/mirror-repo"
REGISTRY_REL = "policies/sentinel-capabilities.json"
GIT_AUTHOR = ("hydra-sentinel", "sentinel@hydra.local")


class MirrorUnavailable(RuntimeError):
    """No usable checkout, or a git/gh step failed. The host demotion already happened."""


def _run(runner, cmd: Sequence[str], cwd: Optional[str] = None) -> str:
    proc = runner(list(cmd), cwd=cwd, capture_output=True, text=True)
    rc = getattr(proc, "returncode", 0)
    out = (getattr(proc, "stdout", "") or "").strip()
    err = (getattr(proc, "stderr", "") or "").strip()
    if rc != 0:
        raise MirrorUnavailable(f"{' '.join(cmd[:4])}… failed rc={rc}: {err or out or 'no output'}")
    return out


# ── pure registry mutations (unit-testable, no git) ────────────────────────────
def remote_slug(repo: Path) -> str:
    """`owner/name` from the checkout's origin. An explicit `--repo` beats cwd
    inference, so the PR lands in the right repo even if the caller's cwd is elsewhere."""
    try:
        out = subprocess.run(["git", "-C", str(repo), "remote", "get-url", "origin"],
                             capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        raise MirrorUnavailable(f"cannot read origin from {repo}: {exc}") from exc
    url = (out.stdout or "").strip()
    if out.returncode != 0 or not url:
        raise MirrorUnavailable(f"cannot read origin from {repo}: {(out.stderr or '').strip()}")
    slug = url.rstrip("/")
    if slug.endswith(".git"):
        slug = slug[: -len(".git")]
    for sep in (":", "github.com/"):
        if sep in slug:
            slug = slug.split(sep, 1)[1]
    if slug.count("/") != 1:
        raise MirrorUnavailable(f"origin of {repo} is not an owner/name remote: {url}")
    return slug


def _as_doc(raw: Any) -> Dict[str, Any]:
    if isinstance(raw, list):
        return {"capabilities": raw}
    if isinstance(raw, dict) and isinstance(raw.get("capabilities"), list):
        return raw
    raise MirrorUnavailable("registry is neither a list nor {'capabilities': [...]}")


def apply_demotions(doc: Any, trips: Iterable[Any], at: str) -> Dict[str, Any]:
    """Flip `rollout.state` (+ record why) for every trip. Pure: returns a new doc."""
    out = json.loads(json.dumps(_as_doc(doc)))
    by_id = {str(r.get("id")): r for r in out["capabilities"] if isinstance(r, dict)}
    for t in trips:
        row = by_id.get(t.capability_id)
        if row is None:
            raise MirrorUnavailable(f"capability {t.capability_id} is not in the repo registry")
        rollout = row.setdefault("rollout", {})
        if rollout.get("state") != t.next_state:
            rollout["previous_state"] = rollout.get("state")
        rollout["state"] = t.next_state
        rollout["since"] = at
        rollout["demoted"] = {
            "at": at,
            "by": "sentinel-demote",
            "previous": t.prev_state,
            "triggers": list(t.reason_text),
            "counts": dict(t.counts),
            "kill_file": t.kill_file,
            "note": "automatic demotion; re-promotion is a PR with a Fable ruling id (demote.py promote)",
        }
    return out


def add_shadow_row(doc: Any, row: Dict[str, Any]) -> Dict[str, Any]:
    """Append a proposed capability in `shadow`. Refuses a duplicate id."""
    out = json.loads(json.dumps(_as_doc(doc)))
    caps = out["capabilities"]
    if any(str(r.get("id")) == str(row.get("id")) for r in caps if isinstance(r, dict)):
        raise MirrorUnavailable(f"capability {row.get('id')} already registered")
    caps.append(row)
    return out


# ── the PR ─────────────────────────────────────────────────────────────────────
def open_pr(*, title: str, body: str, branch: str, paths: Sequence[str], repo_dir: str,
            base: str = "main", runner=subprocess.run, dry_run: bool = False,
            prepare=None, log=print) -> str:
    """Refresh the mirror checkout, commit `paths`, push `branch`, open the PR.

    `prepare(repo_path)` runs AFTER the checkout is switched to `origin/<base>` and
    BEFORE `git add` — it is where the caller writes the files it wants committed.
    That order is load-bearing: writing the registry first and switching branches
    second makes git refuse the switch once a previous demotion's PR is still
    unmerged, because `origin/<base>` still carries the OLD blob and the dirty
    worktree would be overwritten ("Your local changes ... would be overwritten by
    checkout"). That is every second demotion, i.e. the mirror half of the feature
    dies on its second use — reproduced against a real origin.

    Returns the PR URL gh printed (exactly as printed — firstmate copies it rather than
    assembling one). With `dry_run` nothing is committed or pushed and the string is
    `DRY-RUN <branch>` so callers can render the body without side effects.
    """
    repo = Path(repo_dir)
    if dry_run:
        log(f"[mirror] dry-run: would commit {', '.join(paths)} on {branch} and open a PR against {base}")
        return f"DRY-RUN {branch}"
    if not (repo / ".git").exists():
        raise MirrorUnavailable(
            f"{repo} is not a git checkout; run scripts/install-aux-units.sh on node-8 "
            "(it clones the mirror repo at deploy time) — refusing to clone from a timer"
        )
    if shutil.which("gh") is None:
        raise MirrorUnavailable("gh is not on PATH; cannot open the mirror PR")

    _run(runner, ["git", "-C", str(repo), "fetch", "--quiet", "origin", base])
    # Discard anything a killed run left behind, so a crashed tick cannot wedge every
    # later one. Safe: the checkout is machine-owned scratch and each committed state
    # lives on its own pushed branch.
    _run(runner, ["git", "-C", str(repo), "reset", "--hard", "--quiet"])
    _run(runner, ["git", "-C", str(repo), "checkout", "--quiet", "-B", branch, f"origin/{base}"])
    if prepare is not None:
        prepare(repo)
    # Checked AFTER prepare, because prepare is what creates the files it wants committed
    # (a proposal adds `data/sentinel/proposals/<week>.md`, which is not on base yet).
    for rel in paths:
        if not (repo / rel).exists():
            raise MirrorUnavailable(f"expected {rel} in the mirror checkout after prepare")

    _run(runner, ["git", "-C", str(repo), "add", *paths])
    diff = runner(["git", "-C", str(repo), "status", "--porcelain", *paths], cwd=None,
                  capture_output=True, text=True)
    if not (getattr(diff, "stdout", "") or "").strip():
        raise MirrorUnavailable(f"nothing to commit on {branch} (the repo already has this state)")
    _run(runner, [
        "git", "-C", str(repo), "-c", f"user.name={GIT_AUTHOR[0]}", "-c", f"user.email={GIT_AUTHOR[1]}",
        "commit", "--quiet", "-m", title,
    ])
    _run(runner, ["git", "-C", str(repo), "push", "--quiet", "-u", "origin", branch])

    fd, body_path = tempfile.mkstemp(prefix="sentinel-pr-", suffix=".md")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(body)
        # cwd=str(repo) is load-bearing: `gh` would otherwise infer the repository from
        # the process cwd, and a systemd unit runs with cwd=/ — so `gh pr create` from the
        # timer would answer "not a git repository" and the mirror PR would never open.
        url = _run(runner, [
            "gh", "pr", "create", "--repo", remote_slug(repo),
            "--base", base, "--head", branch,
            "--title", title, "--body-file", body_path,
        ], cwd=str(repo))
    finally:
        try:
            os.unlink(body_path)
        except OSError:
            pass
    return url
