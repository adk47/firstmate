"""The capability registry: repo truth and the host's runtime state.

Two files, one contract (request-sentinel-fable-s1 §2.3):

  policies/sentinel-capabilities.json          repo truth, CI-validated, PR-owned.
  /var/lib/hydra/sentinel/registry-state.json  the HOST's runtime state, written by
                                               sentinel-demote and by nothing else.

Why two: a demotion must take effect in seconds on the host and must also survive a
deploy (which rsyncs /opt/hydra from the repo). The host file is NOT under
/opt/hydra for exactly that reason — /var/lib is deploy-proof. The tick opens a PR
that mirrors the demotion into the repo file, so repo and host agree; until that PR
merges the host state is the stricter of the two, never the looser one.

THE INVARIANT: `effective_state()` takes the STRICTER of (repo, runtime). The
runtime file can therefore only ever DEMOTE a capability. A promotion is a PR that
changes the repo row AND a human deleting the runtime row + the kill file — the
"three independent stops" rule (registry state, kill file, the actor's own flag in
policies/credit-approval-automation.json) in executable form.
"""
from __future__ import annotations

import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

REPO_ROOT = Path(__file__).resolve().parents[2]
REGISTRY_DEFAULT = REPO_ROOT / "policies" / "sentinel-capabilities.json"
RUNTIME_STATE_DEFAULT = Path(
    os.environ.get("SENTINEL_RUNTIME_STATE", "/var/lib/hydra/sentinel/registry-state.json")
)

STATES = ("shadow", "canary", "live")
STRICTNESS = {"shadow": 0, "canary": 1, "live": 2}

# One step, always. §2.6: live -> canary/shadow automatically on triggers; §2.3's
# `on_trip` names a single hop, and a two-step "skip canary" demotion would take a
# capability from acting to silent without the canary rung ever being observed.
DEMOTION_STEPS = {"live": "canary", "canary": "shadow", "shadow": "shadow"}

# A kill file is only a kill file if it is a marker under /etc/hydra. Refusing
# anything else is what stops a doctored registry row from making this script write
# to an arbitrary path as root (the same class of bug as an unvalidated `rm` target).
KILL_FILE_RE = re.compile(r"^/etc/hydra/[A-Za-z0-9._-]+\.disabled$")


class RegistryError(RuntimeError):
    """The registry is missing or malformed. Never fatal to the host, always loud."""


class RegistryMissing(RegistryError):
    pass


class RegistryInvalid(RegistryError):
    pass


# ── loading ────────────────────────────────────────────────────────────────────
def load(path: Optional[os.PathLike | str] = None) -> List[Dict[str, Any]]:
    """Read and validate the repo registry. Raises RegistryMissing / RegistryInvalid."""
    p = Path(path) if path is not None else REGISTRY_DEFAULT
    try:
        raw = json.loads(p.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise RegistryMissing(f"{p}: capability registry does not exist ({exc})") from exc
    except (OSError, ValueError) as exc:
        raise RegistryInvalid(f"{p}: unreadable or not JSON ({exc})") from exc
    rows = raw.get("capabilities") if isinstance(raw, dict) else raw
    if not isinstance(rows, list) or not rows:
        raise RegistryInvalid(f"{p}: expected a non-empty list (or {{'capabilities': [...]}})")
    seen = set()
    out: List[Dict[str, Any]] = []
    for i, row in enumerate(rows):
        if not isinstance(row, dict):
            raise RegistryInvalid(f"{p}: row {i} is not an object")
        cap_id = row.get("id")
        if not isinstance(cap_id, str) or not cap_id.strip():
            raise RegistryInvalid(f"{p}: row {i} has no id")
        if cap_id in seen:
            raise RegistryInvalid(f"{p}: duplicate capability id {cap_id!r}")
        seen.add(cap_id)
        rollout = row.get("rollout")
        if not isinstance(rollout, dict) or rollout.get("state") not in STATES:
            raise RegistryInvalid(
                f"{p}: {cap_id}: rollout.state must be one of {STATES}, got "
                f"{None if not isinstance(rollout, dict) else rollout.get('state')!r}"
            )
        demotion = row.get("demotion")
        if not isinstance(demotion, dict):
            raise RegistryInvalid(f"{p}: {cap_id}: no demotion block — it cannot be demoted, so it must not be registered")
        out.append(row)
    return out


def kill_file_of(row: Dict[str, Any]) -> str:
    """The row's kill file, validated. Refuses to invent a path."""
    raw = str(row.get("kill_file") or "").strip()
    if not raw:
        raise RegistryInvalid(f"{row.get('id')}: no kill_file — a capability with no kill switch cannot be demoted")
    if not KILL_FILE_RE.match(raw):
        raise RegistryInvalid(
            f"{row.get('id')}: kill_file {raw!r} is not /etc/hydra/<name>.disabled "
            "(refusing to write outside the kill-file directory)"
        )
    return raw


# ── runtime state ──────────────────────────────────────────────────────────────
class RuntimeState:
    """`/var/lib/hydra/sentinel/registry-state.json` — host truth, deploy-proof."""

    def __init__(self, path: Optional[os.PathLike | str] = None):
        self.path = Path(path) if path is not None else RUNTIME_STATE_DEFAULT
        self.data: Dict[str, Any] = {"version": 1, "capabilities": {}}
        self.dirty = False

    # reading ------------------------------------------------------------------
    def load(self) -> "RuntimeState":
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return self
        except (OSError, ValueError) as exc:
            # A corrupt host state file must not become "everything is fine". The
            # caller treats this as an error and pages; refusing here keeps the
            # file untouched rather than overwriting evidence.
            raise RegistryInvalid(f"{self.path}: unreadable runtime state ({exc})") from exc
        self.data = self._validated(raw)
        return self

    def _validated(self, raw: Any) -> Dict[str, Any]:
        """Refuse any shape we did not write.

        A parseable-but-wrong file (`{}`, `{'capabilities': []}`, a state we do not
        know) used to fall through to the empty default — which reads as "nothing is
        demoted" and lets the next tick overwrite the file, silently re-arming a
        demoted capability. Corrupt host state is an ERROR the operator fixes, never a
        reset, so every unexpected shape raises instead of defaulting.
        """
        if not isinstance(raw, dict):
            raise RegistryInvalid(f"{self.path}: runtime state is {type(raw).__name__}, expected an object")
        caps = raw.get("capabilities")
        if not isinstance(caps, dict):
            raise RegistryInvalid(
                f"{self.path}: 'capabilities' must be an object, got "
                f"{'missing' if 'capabilities' not in raw else type(caps).__name__!r}; "
                "refusing to treat a corrupt host override as 'nothing demoted'"
            )
        for cap_id, ent in caps.items():
            if not isinstance(ent, dict):
                raise RegistryInvalid(f"{self.path}: capability {cap_id!r} is {type(ent).__name__}, expected an object")
            st = ent.get("state")
            # `state` is REQUIRED, not merely checked when present. An entry without one
            # (e.g. {"capabilities": {"x": {}}}) used to validate, and state_of() then
            # returned None — so the host demotion vanished and the row read at its repo
            # state (`live`) instead of the demoted one. A demotion we cannot see is a
            # demotion we silently undo.
            if st is None:
                raise RegistryInvalid(
                    f"{self.path}: capability {cap_id!r} has no 'state'; every entry must record one "
                    f"of {STATES} (a stateless entry reads as 'not demoted')"
                )
            if st not in STATES:
                raise RegistryInvalid(
                    f"{self.path}: capability {cap_id!r} has state {st!r}; expected one of {STATES} "
                    "(an unknown state would silently un-demote it)"
                )
        raw.setdefault("version", 1)
        return raw

    def entry(self, cap_id: str) -> Dict[str, Any]:
        caps = self.data.setdefault("capabilities", {})
        row = caps.get(cap_id)
        return row if isinstance(row, dict) else {}

    def state_of(self, cap_id: str) -> Optional[str]:
        st = self.entry(cap_id).get("state")
        return st if st in STATES else None

    # writing ------------------------------------------------------------------
    def set_state(self, cap_id: str, new_state: str, *, reason: str, at: str,
                  previous: Optional[str] = None, triggers: Optional[Dict[str, Any]] = None,
                  kill_file: Optional[str] = None, mirror_pr: Optional[str] = None) -> None:
        """Record a demotion. REFUSES to promote (see the module invariant)."""
        if new_state not in STATES:
            raise RegistryInvalid(f"unknown state {new_state!r}")
        current = self.state_of(cap_id)
        if current is not None and STRICTNESS[new_state] > STRICTNESS[current]:
            raise RegistryInvalid(
                f"{cap_id}: refusing to raise runtime state {current} -> {new_state}; "
                "promotion is a PR with a Fable ruling id, never a runtime write"
            )
        caps = self.data.setdefault("capabilities", {})
        ent = dict(caps.get(cap_id) or {})
        ent.update({
            "state": new_state,
            "since": at,
            "reason": reason,
            "previous": previous if previous is not None else current,
            "triggers": triggers or {},
            "updated_at": at,
            "demoted_by": "sentinel-demote",
        })
        if kill_file:
            ent["kill_file"] = kill_file
        if mirror_pr is not None:
            ent["mirror_pr"] = mirror_pr
        caps[cap_id] = ent
        self.dirty = True

    def set_mirror_pr(self, cap_id: str, url: str) -> None:
        """Attach the mirror PR to an entry that already records a demotion.

        Creating a state-less entry here would write a file this class's own validator
        rejects on the next load, so it is a programming error, not a fallback.
        """
        caps = self.data.setdefault("capabilities", {})
        existing = caps.get(cap_id)
        if not isinstance(existing, dict) or existing.get("state") not in STATES:
            raise RegistryInvalid(
                f"{cap_id}: no demotion recorded — set_state() must run before set_mirror_pr()"
            )
        ent = dict(existing)
        ent["mirror_pr"] = url
        caps[cap_id] = ent
        self.dirty = True

    def save(self) -> None:
        if not self.dirty:
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(self.path.parent, 0o700)
        except OSError:
            pass
        atomic_write_json(self.path, self.data)
        self.dirty = False


def atomic_write_json(path: Path, payload: Any, mode: int = 0o600) -> None:
    """tmp-in-same-dir + fsync + rename. A torn registry-state file would read as
    "no override" and un-demote every capability at once."""
    path = Path(path)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ── the (repo, runtime) join ───────────────────────────────────────────────────
def effective_state(row: Dict[str, Any], runtime: RuntimeState) -> str:
    """The stricter of repo `rollout.state` and the host override.

    A host file can therefore only demote: a repo row that a merged PR has already
    demoted is never raised back by a stale host row, and a host demotion is never
    undone by the deploy that rsyncs the older repo file over /opt/hydra.
    """
    repo = str((row.get("rollout") or {}).get("state") or "shadow")
    if repo not in STATES:
        repo = "shadow"  # fail strict on an unreadable row
    host = runtime.state_of(str(row.get("id")))
    if host is None:
        return repo
    return host if STRICTNESS[host] <= STRICTNESS[repo] else repo


def index_by_id(rows: Iterable[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    return {str(r["id"]): r for r in rows}


def attribution_map(rows: Iterable[Dict[str, Any]]) -> Dict[str, List[str]]:
    """`attribution.action_types` / `intercom_tags` -> capability id, for outcome rows
    that carry a type but not a capability id (ACTION-AUDIT's `action_type`, complaint
    tags). Ambiguous claims are dropped: two rows claiming one action type is a registry
    bug, and silently picking one would mis-attribute a demotion.

    `action.type` is deliberately NOT a key: it names the KIND of write (`core_write`,
    `hydra_executor`), not an action type like `credit.approve`. Keying on it would let
    one `core_write` row claim every unattributed core write in the fleet.
    """
    claims: Dict[str, List[str]] = {}
    for row in rows:
        cap = str(row["id"])
        attr = row.get("attribution") or {}
        keys: List[str] = []
        for k in ("action_types", "intercom_tags"):
            vals = attr.get(k) or []
            if isinstance(vals, str):
                vals = [vals]
            keys.extend(str(v) for v in vals)
        for k in keys:
            claims.setdefault(k, [])
            if cap not in claims[k]:
                claims[k].append(cap)
    return {k: v for k, v in claims.items() if len(v) == 1}
