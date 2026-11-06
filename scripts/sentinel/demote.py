#!/usr/bin/env python3
"""sentinel-demote — automatic DEMOTION on bad outcomes. Promotion is never automatic.

    demote.py run     [--nightly|--fast] [--dry-run] [--json]     the tick
    demote.py digest  [--json]                                    the 7-day table
    demote.py promote --capability <id> [--ruling <id>]           parity report only
    demote.py propose [--week N] [--open-pr]                      weekly shadow proposal

Why demotion is a script and not a rule in a doc: request-sentinel-fable-s1 §2.3 —
"demotion is automatic and needs no one awake". The tick joins the last 7 days of
outcomes per registered capability (outcomes.py), and any tripped trigger:

  1. flips the HOST runtime state one step (live -> canary, canary -> shadow),
  2. drops the capability's kill file (`/etc/hydra/<name>.disabled` from the row),
  3. pages #clio_devops with counts and NO account names,
  4. opens a PR mirroring the demotion into `policies/sentinel-capabilities.json`.

Three independent stops (§2.3, security-arch): registry state, kill file, and the
actor's own flag in `policies/credit-approval-automation.json`. This script only ever
moves the first two; the flag is left to the PR reviewer on purpose. Any one of the
three stops the capability.

Exit codes (systemd): 0 = ran, nothing tripped. 10 = tripped, demotion acted
(SuccessExitStatus=10 in the .service — a demotion is not a failure). 2 = the
capability registry does not exist yet (sentinel-core-s0 has not landed it): a clean
skip, also in SuccessExitStatus, and NOT paged — paging a known-absent file would train
the channel to ignore alerts. 4 = the registry exists but cannot be used (malformed, or
an unreadable host runtime state): loud, pages, and stays a unit failure because it is a
defect nobody has fixed. 1 = internal error. 3 = the kill switch is present (log-only).

Kill switches: `/etc/hydra/sentinel-demote.disabled` stops THIS tick (and therefore
stops automatic demotion — it does not stop any capability). A capability's own kill
file is the stop for the capability.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

_SCRIPTS_DIR = Path(__file__).resolve().parents[1]
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from sentinel import mirror, outcomes, registry, report  # noqa: E402

# Where kill files land. The registry row names `/etc/hydra/<name>.disabled` (that shape is
# validated, never relaxed); KILL_ROOT only decides which DIRECTORY that name is written to.
# The unit never sets it — tests do, because a test must not touch the host's real levers.
KILL_ROOT = Path(os.environ.get("SENTINEL_KILL_ROOT", "/etc/hydra"))
DEMOTE_KILL_FILE = Path(os.environ.get("SENTINEL_DEMOTE_KILL_FILE", "/etc/hydra/sentinel-demote.disabled"))
SENTINEL_KILL_FILE = Path(os.environ.get("SENTINEL_KILL_FILE", "/etc/hydra/sentinel.disabled"))
DEMOTION_LOG = Path(os.environ.get("SENTINEL_DEMOTION_LOG", "/var/lib/hydra/sentinel/demotions.jsonl"))
BLIND_PAGE_STATE = Path(os.environ.get("SENTINEL_BLIND_PAGE_STATE", "/var/lib/hydra/sentinel/blind-page.json"))
# "I have successfully loaded a registry at least once." Written on every good load, so a
# registry that DISAPPEARS later is distinguishable from one that has not landed yet: the
# first is a post-deployment loss that leaves automatic demotion blind (page, exit 4), the
# second is the expected pre-S0 state (clean skip, exit 2). Without the marker both look
# identical, and a deleted or failed-to-deploy registry would skip silently forever.
REGISTRY_SEEN = Path(os.environ.get("SENTINEL_REGISTRY_SEEN", "/var/lib/hydra/sentinel/registry-seen"))
# ONE lock for every sentinel unit. The hourly --fast and the nightly ticks both load,
# mutate and save the whole runtime file and both use the same mirror checkout, so two
# overlapping runs lose data: fast loads {}, nightly demotes B and saves, fast then saves
# its own snapshot containing only A — B's host stop is silently re-armed until its
# mirror PR merges. Held across load -> evaluate -> save -> mirror PR.
LOCK_FILE = Path(os.environ.get("SENTINEL_LOCK_FILE", "/var/lib/hydra/sentinel/run.lock"))
LOCK_TIMEOUT_S = int(os.environ.get("SENTINEL_LOCK_TIMEOUT", "300"))
MIRROR_REPO = os.environ.get("SENTINEL_MIRROR_REPO", mirror.MIRROR_REPO_DEFAULT)
DEDUPE_HOURS = float(os.environ.get("SENTINEL_DEMOTE_DEDUPE_HOURS", "24"))
# `_open_mirror_pr` returns this instead of a URL when the mirror checkout already
# carries the demotion: no PR to open, and nothing went wrong.
REPO_ALREADY_AGREES = "already-in-repo"

EXIT_OK, EXIT_ERROR, EXIT_NO_REGISTRY, EXIT_KILLED, EXIT_TRIPPED = 0, 1, 2, 3, 10
# 4 = the registry exists but we cannot use it (malformed rows, or a host runtime state we
# cannot read). Deliberately a DIFFERENT code from 2: 2 is "S0 has not landed it yet", which
# the units treat as a clean skip, and folding a broken registry into it would make a real
# defect look like the same known-absent file forever.
EXIT_BAD_STATE = 4

FAST_RULES = ("audit_fail_any", "manipulated_7d")
OVERDUE_PCT_DEFAULT = report.OVERDUE_PCT_DEFAULT


# ── trips ──────────────────────────────────────────────────────────────────────
@dataclass
class Trip:
    capability_id: str
    prev_state: str
    next_state: str
    reasons: List[str] = field(default_factory=list)       # rule keys that fired
    reason_text: List[str] = field(default_factory=list)   # human readable, counters only
    counts: Dict[str, float] = field(default_factory=dict)
    kill_file: str = ""
    announce: bool = True
    row: Dict[str, Any] = field(default_factory=dict)
    # Set by cmd_run AFTER the write attempt (None = not attempted yet). The page must
    # never claim a kill file landed when it did not: that is a stop a human would then
    # not go looking for.
    kill_ok: Optional[bool] = None
    kill_detail: str = ""

    def as_dict(self) -> Dict[str, Any]:
        return {
            "capability_id": self.capability_id,
            "prev_state": self.prev_state,
            "next_state": self.next_state,
            "reasons": self.reasons,
            "reason_text": self.reason_text,
            "counts": self.counts,
            "kill_file": self.kill_file,
            "announce": self.announce,
            "kill_ok": self.kill_ok,
        }


def _num(v: Any) -> Optional[float]:
    """A comparable threshold, or None.

    Non-finite values are None on purpose. `json.loads` accepts the bare tokens NaN and
    Infinity, and every comparison against NaN is False, so a NaN threshold would sail
    through `count >= threshold` and ignore even 99 reverts. The CI gate refuses these too;
    this is the runtime half, because the host reads the file the gate does not own.
    """
    if v is None or isinstance(v, bool):
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def _rate(counts: Dict[str, float]) -> None:
    total = counts.get("day_rows") or 0
    counts["overdue_pct"] = round(100.0 * (counts.get("overdue_rows") or 0) / total, 2) if total else 0.0


def _rule_hits(d: Dict[str, Any], counts: Dict[str, float], *, fast: bool) -> Tuple[List[str], List[str]]:
    """(rule keys, human text). A rule with no threshold is not evaluated; a rule with
    no measurable source cannot fire (the digest marks the row UNMEASURED instead)."""
    reasons: List[str] = []
    texts: List[str] = []

    def add(key: str, text: str) -> None:
        reasons.append(key)
        texts.append(text)

    thresholds = (
        ("reverts_7d", "reverts_7d", counts.get("reverts_7d", 0)),
        ("manipulated_7d", "manipulated_7d", counts.get("manipulated_7d", 0)),
        ("contradicted_7d", "contradicted_7d", counts.get("contradicted_7d", 0)),
        ("complaints_7d", "complaints_7d", counts.get("complaints_7d", 0)),
        ("audit_fails_7d", "audit_fails_7d", counts.get("audit_fails_7d", 0)),
    )
    for key, label, value in thresholds:
        if fast and key not in FAST_RULES:
            continue
        thr = _num(d.get(key))
        if thr is None or thr <= 0:
            continue
        if (value or 0) >= thr:
            add(key, f"{label}={int(value or 0)}>= threshold {int(thr)}")

    # The overdue trigger (addendum 10-30): > 5 % of the day's rows waiting on us.
    if not fast and "day_rows" in counts and (counts.get("day_rows") or 0) > 0:
        thr = _num(d.get("overdue_pct"))
        thr = OVERDUE_PCT_DEFAULT if thr is None else thr
        if thr > 0 and (counts.get("overdue_pct") or 0) > thr:
            add("overdue_pct",
                f"waiting_on=us past due_at {counts['overdue_pct']:.2f}% "
                f"({int(counts.get('overdue_rows') or 0)}/{int(counts['day_rows'])}) > {thr:g}%")

    # `audit_fail_any`: ANY spot-audit fail or manipulated watcher verdict.
    if d.get("audit_fail_any") is True:
        fails = (counts.get("manipulated_7d", 0) or 0) + (counts.get("audit_fails_7d", 0) or 0)
        if fails >= 1:
            add("audit_fail_any",
                f"audit_fail_any (manipulated={int(counts.get('manipulated_7d', 0) or 0)}, "
                f"spot_fails={int(counts.get('audit_fails_7d', 0) or 0)})")
    return reasons, texts


def kill_file_on_disk(kill_path: str) -> Path:
    """The actual path a registry-declared kill file is written to (see KILL_ROOT)."""
    return KILL_ROOT / Path(kill_path).name


def _announce_needed(runtime: registry.RuntimeState, cap: str, prev: str, nxt: str,
                     kill_path: str, now: datetime) -> bool:
    """Never page/PR the same state twice inside the dedupe window."""
    if prev != nxt:
        return True
    if not kill_path or not kill_file_on_disk(kill_path).exists():
        return True
    last = runtime.entry(cap).get("last_demotion_at")
    if not last:
        return True
    try:
        return (now - outcomes.parse_utc(str(last))) >= timedelta(hours=DEDUPE_HOURS)
    except ValueError:
        return True


def evaluate(rows: Sequence[Dict[str, Any]], counters, runtime: registry.RuntimeState,
             *, fast: bool = False, now: Optional[datetime] = None) -> List[Trip]:
    now = now or datetime.now(timezone.utc)
    trips: List[Trip] = []
    for row in rows:
        cap = str(row["id"])
        counts = dict(counters.of(cap))
        _rate(counts)
        reasons, texts = _rule_hits(row.get("demotion") or {}, counts, fast=fast)
        if not reasons:
            continue
        prev = registry.effective_state(row, runtime)
        nxt = registry.DEMOTION_STEPS.get(prev, "shadow")
        try:
            kill_path = registry.kill_file_of(row)
        except registry.RegistryInvalid:
            kill_path = ""
        trips.append(Trip(
            capability_id=cap, prev_state=prev, next_state=nxt,
            reasons=reasons, reason_text=texts, counts=counts, kill_file=kill_path,
            announce=_announce_needed(runtime, cap, prev, nxt, kill_path, now) if kill_path else True,
            row=row,
        ))
    return trips


# ── the two stops this script owns ─────────────────────────────────────────────
def drop_kill_file(path: str, line: str) -> Tuple[bool, str]:
    """Create the kill file. Refuses any path outside /etc/hydra (registry.py checks the
    shape; this re-checks right before the write, because this runs as root)."""
    if not path:
        return False, "no kill_file in the registry row"
    if not registry.KILL_FILE_RE.match(path):
        return False, f"refusing to write {path!r}: not /etc/hydra/<name>.disabled"
    p = kill_file_on_disk(path)
    try:
        if KILL_ROOT != Path("/etc/hydra"):
            print(f"[demote] SENTINEL_KILL_ROOT={KILL_ROOT} (test redirect) — declared {path}", file=sys.stderr)
        p.parent.mkdir(parents=True, exist_ok=True)
        existed = p.exists()
        payload = f"# {line}\n" if not existed else (p.read_text(encoding='utf-8', errors='replace') + f"# {line}\n")
        tmp = p.with_suffix(p.suffix + ".tmp")
        tmp.write_text(payload, encoding="utf-8")
        os.chmod(tmp, 0o644)
        os.replace(tmp, p)
        return True, "already present; reason appended" if existed else "created"
    except OSError as exc:
        return False, f"could not write {path}: {exc}"


def _slack(text: str, critical: bool) -> bool:
    """Post through scripts/lib/slack-notify.sh — the gated muso CLI, one audit trail,
    and the bats test fence (hydra#1195). Never a hand-rolled HTTP post."""
    lib = _SCRIPTS_DIR / "lib" / "slack-notify.sh"
    if not lib.exists():
        print("[demote] slack-notify.sh missing; page not sent", file=sys.stderr)
        return False
    fn = "slack_notify_critical" if critical else "slack_notify"
    script = f'source "$1" && {fn} "$2"'
    try:
        proc = subprocess.run(["bash", "-c", script, "_", str(lib), text],
                              capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"[demote] page failed: {exc}", file=sys.stderr)
        return False
    if proc.returncode != 0:
        print(f"[demote] page exited {proc.returncode}: {(proc.stderr or proc.stdout).strip()[:400]}", file=sys.stderr)
    return proc.returncode == 0


def _append_demotion_log(entries: Iterable[Dict[str, Any]]) -> None:
    try:
        DEMOTION_LOG.parent.mkdir(parents=True, exist_ok=True)
        with DEMOTION_LOG.open("a", encoding="utf-8") as fh:
            for e in entries:
                fh.write(json.dumps(e, sort_keys=True) + "\n")
    except OSError as exc:  # the log is evidence, not the control — never fail the tick
        print(f"[demote] could not append {DEMOTION_LOG}: {exc}", file=sys.stderr)


def _blind_page_once(rows: Sequence[Dict[str, Any]], counters, now: datetime, *, enabled: bool) -> bool:
    """Page at most once a day when any registered capability has an unmeasurable
    trigger, or when there is no registry at all. Deduped on disk."""
    blind = {cap: b for cap, b in counters.blind.items() if b}
    if not blind:
        return False
    key = now.strftime("%Y-%m-%d")
    try:
        seen = json.loads(BLIND_PAGE_STATE.read_text(encoding="utf-8")).get("date")
    except (OSError, ValueError):
        seen = None
    if seen == key:
        return False
    if not enabled:
        return False
    lines = [":grey_question: *sentinel-demote: a demotion trigger has no source — it cannot fire*"]
    for cap in sorted(blind):
        lines.append(f"• `{cap}`: " + "; ".join(sorted(blind[cap].values())))
    lines.append("Unmeasured is not healthy: promotion is blocked for these rows until the source reports.")
    ok = _slack("\n".join(lines), critical=False)
    if ok:
        try:
            BLIND_PAGE_STATE.parent.mkdir(parents=True, exist_ok=True)
            registry.atomic_write_json(BLIND_PAGE_STATE, {"date": key, "at": outcomes.utc(now)})
        except OSError:
            pass
    return ok


# ── subcommands ────────────────────────────────────────────────────────────────
def _load(registry_path: Optional[str]) -> List[Dict[str, Any]]:
    return registry.load(registry_path)


def _states(rows: Sequence[Dict[str, Any]], runtime: registry.RuntimeState) -> Dict[str, str]:
    return {str(r["id"]): registry.effective_state(r, runtime) for r in rows}


def _eval_db(a) -> str:
    """The evaluation store: explicit flag > --paths-json override > the host default."""
    if getattr(a, "evaluations_db", None):
        return a.evaluations_db
    if getattr(a, "paths_json", None):
        try:
            override = json.loads(a.paths_json).get("evaluations_db")
        except ValueError:
            override = None
        if override:
            return override
    return outcomes.DEFAULT_PATHS["evaluations_db"]


def _stop_reason() -> Optional[str]:
    """Which kill switch is set, if any. BOTH are checked: the global one is the
    operator's "stop the whole sentinel" lever (data/sentinel/README.md) and a tick that
    ignored it would flip state and drop kill files under a global stop."""
    if SENTINEL_KILL_FILE.exists() or os.environ.get("SENTINEL_DISABLED"):
        return f"{SENTINEL_KILL_FILE} (whole sentinel)"
    if DEMOTE_KILL_FILE.exists() or os.environ.get("SENTINEL_DEMOTE_DISABLED"):
        return f"{DEMOTE_KILL_FILE} (automatic demotion)"
    return None


class HostLock:
    """Exclusive advisory lock serializing every sentinel tick on this host.

    flock, not a pid file: the kernel drops it when the process dies, so a killed tick
    cannot wedge the sentinel forever. Re-entrant within a process is NOT attempted —
    one tick takes it once.
    """

    def __init__(self, path: Optional[Path] = None, timeout: Optional[int] = None):
        # Resolved at call time, never as a default argument: a default would capture the
        # module constant at import and ignore any later rebinding (which is how the
        # tests redirect every other host path).
        self.path = Path(path) if path is not None else Path(LOCK_FILE)
        self.timeout = LOCK_TIMEOUT_S if timeout is None else timeout
        self._fh = None

    def __enter__(self) -> "HostLock":
        import fcntl
        import time
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self._fh = open(self.path, "a+")
        except OSError as exc:
            # An unusable lock is NOT a reason to skip quietly: skipping would switch the
            # whole sentinel off while looking healthy. Fail the unit instead, so
            # OnFailure pages and someone fixes the directory.
            raise LockUnavailable(f"cannot open the sentinel lock {self.path}: {exc}") from exc
        deadline = time.monotonic() + max(0, self.timeout)
        while True:
            try:
                fcntl.flock(self._fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError:
                if time.monotonic() >= deadline:
                    self._fh.close()
                    self._fh = None
                    raise LockBusy(f"another sentinel tick holds {self.path}")
                time.sleep(0.5)

    def __exit__(self, *exc) -> None:
        if self._fh is not None:
            import fcntl
            try:
                fcntl.flock(self._fh.fileno(), fcntl.LOCK_UN)
            finally:
                self._fh.close()
                self._fh = None


class LockBusy(RuntimeError):
    """Another tick is already running. Skipping is safe: it is doing the same join."""


class LockUnavailable(RuntimeError):
    """The lock itself cannot be taken (missing/unwritable state dir). Never a skip."""


def cmd_run(a, *, now: Optional[datetime] = None) -> int:
    now = now or datetime.now(timezone.utc)
    at = outcomes.utc(now)
    stop = _stop_reason()
    if stop:
        print(f"[demote] {stop} present — NOT evaluating: this tick changed nothing. "
              "No capability is stopped by this switch; it switches the DETECTOR off. "
              "Delete the file to re-arm — the digest keeps reporting UNMEASURED triggers "
              "while it is set, because a switched-off detector is not a healthy one.", file=sys.stderr)
        return EXIT_KILLED

    try:
        with HostLock():
            return _run_locked(a, now=now, at=at)
    except LockBusy as exc:
        # Not an error and not a page: the other tick is running the same 7-day join, so
        # this one has nothing to add and must not touch the shared runtime file.
        print(f"[demote] {exc} — skipping this tick; that tick is doing the same work.",
              file=sys.stderr)
        return EXIT_OK
    except LockUnavailable as exc:
        print(f"[demote] FATAL: {exc}", file=sys.stderr)
        print("[demote] refusing to run unserialized: two ticks writing the whole runtime "
              "file lose each other's demotions. Nothing was changed.", file=sys.stderr)
        return EXIT_ERROR


def _run_locked(a, *, now: datetime, at: str) -> int:
    try:
        rows = _load(a.registry)
    except registry.RegistryMissing as exc:
        # Two very different worlds, and they must not look the same:
        #   - never seen: sentinel-core-s0 has not landed the registry. Expected, clean
        #     skip (2 is in SuccessExitStatus=), and paging ~1/day about a file another
        #     task owns is how an alert channel gets ignored.
        #   - seen before, gone now: a deleted or failed-to-deploy registry. Automatic
        #     demotion is BLIND and nothing else would say so, so this pages and exits 4.
        print(f"[demote] {exc}", file=sys.stderr)
        if REGISTRY_SEEN.exists():
            print("[demote] FATAL: this host has loaded a registry before, so it is not "
                  "'not landed yet' — the registry is GONE. Automatic demotion is blind "
                  "until it is restored.", file=sys.stderr)
            if not a.no_page:
                _page_missing_registry_once(now, f"registry disappeared after a successful "
                                            f"load: {exc}", enabled=True)
            return EXIT_BAD_STATE
        print("[demote] nothing to do: the capability registry does not exist yet "
              "(sentinel-core-s0 owns it). Skipping cleanly; no capability was evaluated.",
              file=sys.stderr)
        return EXIT_NO_REGISTRY
    except registry.RegistryInvalid as exc:
        # Present but unusable is a REAL defect: someone shipped a registry this code
        # cannot read, and every capability in it is silently un-demotable.
        print(f"[demote] FATAL: {exc}", file=sys.stderr)
        if not a.no_page:
            _page_missing_registry_once(now, str(exc), enabled=True)
        return EXIT_BAD_STATE

    try:
        runtime = registry.RuntimeState(a.runtime_state).load()
    except registry.RegistryInvalid as exc:
        # A host state file we cannot understand is NOT "nothing is demoted": acting on
        # that reading would re-arm a demoted capability and overwrite the evidence.
        print(f"[demote] FATAL: {exc}", file=sys.stderr)
        print("[demote] refusing to act: fix or restore the host runtime state by hand. "
              "Nothing was written and no capability was changed.", file=sys.stderr)
        if not a.no_page:
            _page_missing_registry_once(now, f"host runtime state unusable: {exc}", enabled=True)
        return EXIT_BAD_STATE
    _mark_registry_seen()
    attribution = registry.attribution_map(rows)
    paths = dict(outcomes.DEFAULT_PATHS)
    if a.paths_json:
        paths.update(json.loads(a.paths_json))
    if a.registry_paths_disabled:
        paths = {}
    counters = outcomes.collect(paths=paths, attribution=attribution, now=now)
    outcomes.blind_counters(rows, counters)

    trips = evaluate(rows, counters, runtime, fast=a.fast, now=now)
    states = _states(rows, runtime)

    if a.dry_run:
        payload = {
            "at": at, "mode": "fast" if a.fast else "nightly", "dry_run": True,
            "trips": [t.as_dict() for t in trips],
            "sources": [s.as_dict() for s in counters.sources],
            "blind": counters.blind,
            "states": states,
        }
        print(json.dumps(payload, indent=2, sort_keys=True) if a.json else report.digest(rows, counters, states, at))
        return EXIT_TRIPPED if trips else EXIT_OK

    acted: List[Trip] = []
    for t in trips:
        if not t.kill_file:
            print(f"[demote] {t.capability_id}: registry row has no valid kill_file — "
                  f"state flip only, and the page says so", file=sys.stderr)
        ok, why = drop_kill_file(t.kill_file, f"sentinel-demote {at} {t.capability_id} "
                                              f"{t.prev_state}->{t.next_state} triggers={','.join(t.reasons)}")
        t.kill_ok, t.kill_detail = ok, why
        line = (f"[demote] {t.capability_id}: {t.prev_state} -> {t.next_state}; kill file {t.kill_file or '(none)'}: {why}")
        print(line, file=sys.stderr)
        if not ok:
            # A demotion whose kill file did not land is a HALF stop. Still flip the
            # state (the registry stop is independent), then page critical.
            _slack(f":rotating_light: sentinel-demote could not drop the kill file for "
                   f"`{t.capability_id}` ({why}). Registry state was still demoted "
                   f"{t.prev_state} → {t.next_state}. Fix the kill file by hand.", critical=True)
        runtime.set_state(
            t.capability_id, t.next_state, reason=", ".join(t.reasons), at=at,
            previous=t.prev_state, triggers=t.counts, kill_file=t.kill_file or None,
        )
        runtime.entry(t.capability_id)["last_demotion_at"] = at
        acted.append(t)
    runtime.save()

    if acted:
        entries = [dict(t.as_dict(), at=at) for t in acted]
        _append_demotion_log(entries)

    announce = [t for t in acted if t.announce]
    pr_url: Optional[str] = None
    state_changers = [t for t in announce if t.prev_state != t.next_state]
    if state_changers:
        pr_url = _open_mirror_pr(a, state_changers, at)
        if pr_url and pr_url != REPO_ALREADY_AGREES:
            for t in state_changers:
                runtime.set_mirror_pr(t.capability_id, pr_url)
            runtime.save()

    if announce and not a.no_page:
        text = report.demotion_page(announce, at)
        if pr_url and pr_url != REPO_ALREADY_AGREES:
            text += f"\nRepo mirror PR: {pr_url}"
        elif pr_url == REPO_ALREADY_AGREES:
            text += "\nThe repo registry already carries this state — no mirror PR needed."
        elif a.pr_dry_run:
            text += "\n:information_source: mirror PR body rendered to the unit log (`--pr-dry-run`); nothing pushed."
        else:
            text += "\n:warning: repo mirror PR was NOT opened — see the unit log (host state is authoritative until it is)."
        _slack(text, critical=True)

    if not a.no_page:
        _blind_page_once(rows, counters, now, enabled=True)

    if a.nightly or a.digest:
        text = report.digest(rows, counters, states, at)
        print(text)
        if a.nightly and not a.no_page:
            _slack(text, critical=False)

    if a.json:
        print(json.dumps({
            "at": at, "trips": [t.as_dict() for t in trips], "acted": len(acted),
            "mirror_pr": pr_url, "blind": counters.blind,
            "sources": [s.as_dict() for s in counters.sources],
        }, indent=2, sort_keys=True))
    return EXIT_TRIPPED if acted else EXIT_OK


def _open_mirror_pr(a, trips: Sequence[Trip], at: str) -> Optional[str]:
    """Mirror the demotion into the repo registry as a PR.

    The document is edited INSIDE `prepare`, i.e. after mirror.open_pr has switched the
    checkout to `origin/<base>`. Writing it first (the original order) made every second
    demotion fail: the previous demotion's branch is still checked out, `origin/<base>`
    still carries the old blob, and git refuses the switch over a dirty worktree.
    """
    if a.no_pr:
        return None
    repo_dir = a.mirror_repo
    doc_path = Path(repo_dir) / mirror.REGISTRY_REL

    if a.pr_dry_run:
        # Render the body only: no checkout switch, no write, no push.
        try:
            doc = mirror.apply_demotions(json.loads(doc_path.read_text(encoding="utf-8")), trips, at)
        except (OSError, ValueError, mirror.MirrorUnavailable) as exc:
            print(f"[demote] mirror PR skipped: {exc}", file=sys.stderr)
            return None
        del doc
        print(report.mirror_pr_body(trips, at, mirror.REGISTRY_REL))
        return None

    def prepare(repo: Path) -> None:
        target = repo / mirror.REGISTRY_REL
        doc = mirror.apply_demotions(json.loads(target.read_text(encoding="utf-8")), trips, at)
        registry.atomic_write_json(target, doc, mode=0o644)

    try:
        title = "fix(sentinel): demote " + ", ".join(t.capability_id for t in trips) + f" ({at[:10]})"
        branch = "sentinel/demote-" + at.replace("-", "").replace(":", "")
        url = mirror.open_pr(
            title=title, body=report.mirror_pr_body(trips, at, mirror.REGISTRY_REL),
            branch=branch, paths=[mirror.REGISTRY_REL], repo_dir=repo_dir, base=a.base,
            prepare=prepare,
        )
        print(f"[demote] mirror PR: {url}", file=sys.stderr)
        return url
    except (OSError, ValueError, mirror.MirrorUnavailable) as exc:
        if "nothing to commit" in str(exc):
            # The checkout already carries this state (an earlier tick's PR, or a merge
            # that landed between ticks). Nothing is wrong and there is nothing to open.
            print(f"[demote] mirror PR not needed: {exc}", file=sys.stderr)
            return REPO_ALREADY_AGREES
        print(f"[demote] mirror PR FAILED: {exc}", file=sys.stderr)
        _slack(f":warning: sentinel-demote demoted {', '.join(t.capability_id for t in trips)} on the host "
               f"but could NOT open the repo mirror PR ({exc}). The host state is authoritative; "
               "the repo still says live — open the PR by hand.", critical=False)
        return None


def _mark_registry_seen() -> None:
    """Record that a registry loaded. Best effort: a marker we cannot write must never
    stop a demotion, and the worst case is the old behaviour (a loss reads as pre-S0)."""
    try:
        REGISTRY_SEEN.parent.mkdir(parents=True, exist_ok=True)
        REGISTRY_SEEN.write_text(outcomes.utc(datetime.now(timezone.utc)) + "\n", encoding="utf-8")
    except OSError:
        pass


def _page_missing_registry_once(now: datetime, detail: str, *, enabled: bool) -> None:
    key = now.strftime("%Y-%m-%d")
    try:
        seen = json.loads(BLIND_PAGE_STATE.read_text(encoding="utf-8")).get("registry_date")
    except (OSError, ValueError):
        seen = None
    if seen == key or not enabled:
        return
    ok = _slack(
        ":grey_question: *sentinel-demote cannot demote anything: it has a registry it cannot "
        f"use.*\n{detail}\nThe automatic-demotion loop is BLIND until this is fixed, and exit "
        "code 4 keeps the unit failed on purpose. No capability's state was changed. (A registry "
        "that does not exist yet is different: that exits 2 and is a clean skip, not this page.)",
        critical=False,
    )
    if ok:
        try:
            prev = {}
            try:
                prev = json.loads(BLIND_PAGE_STATE.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                pass
            prev["registry_date"] = key
            BLIND_PAGE_STATE.parent.mkdir(parents=True, exist_ok=True)
            registry.atomic_write_json(BLIND_PAGE_STATE, prev)
        except OSError:
            pass


def cmd_digest(a, *, now: Optional[datetime] = None) -> int:
    now = now or datetime.now(timezone.utc)
    try:
        rows = _load(a.registry)
    except registry.RegistryError as exc:
        print(f"[demote] FATAL: {exc}", file=sys.stderr)
        return EXIT_NO_REGISTRY
    runtime = registry.RuntimeState(a.runtime_state).load()
    paths = dict(outcomes.DEFAULT_PATHS)
    if a.paths_json:
        paths.update(json.loads(a.paths_json))
    counters = outcomes.collect(paths=paths, attribution=registry.attribution_map(rows), now=now)
    outcomes.blind_counters(rows, counters)
    states = _states(rows, runtime)
    if a.json:
        print(json.dumps({
            "at": outcomes.utc(now), "states": states,
            "counters": counters.per_cap, "unattributed": counters.unattributed,
            "sources": [s.as_dict() for s in counters.sources], "blind": counters.blind,
        }, indent=2, sort_keys=True))
    else:
        print(report.digest(rows, counters, states, outcomes.utc(now)))
    return EXIT_OK


def cmd_promote(a, *, now: Optional[datetime] = None) -> int:
    """Render the parity report for a Fable ruling. NEVER changes state."""
    now = now or datetime.now(timezone.utc)
    try:
        rows = _load(a.registry)
    except registry.RegistryError as exc:
        print(f"[demote] FATAL: {exc}", file=sys.stderr)
        return EXIT_NO_REGISTRY
    row = registry.index_by_id(rows).get(a.capability)
    if row is None:
        print(f"[demote] no capability {a.capability!r} in the registry", file=sys.stderr)
        return EXIT_NO_REGISTRY
    runtime = registry.RuntimeState(a.runtime_state).load()
    paths = dict(outcomes.DEFAULT_PATHS)
    if a.paths_json:
        paths.update(json.loads(a.paths_json))
    counters = outcomes.collect(paths=paths, attribution=registry.attribution_map(rows), now=now)
    outcomes.blind_counters(rows, counters)
    rollout = row.get("rollout") or {}
    gates = _parity_gates(row, counters, rollout, a.ruling, now, _eval_db(a))
    report_text = report.parity_report(capability_id=a.capability, ruling=a.ruling, rollout=rollout,
                                       gates=gates, at=outcomes.utc(now))
    if a.json:
        print(json.dumps({"capability": a.capability, "ruling": a.ruling, "gates": gates,
                          "promotable": all(g.get("pass") for g in gates.values())},
                         indent=2, sort_keys=True))
    else:
        print(report_text)
    return EXIT_OK


# A percentage is only evidence if enough rows carry the comparison. One paired row out
# of 200 printed "100.00% agreement" and promoted; a store with no `band`/`decision`/
# `agreed` column printed "0 false acts of 0 RED/BLACK rows" and passed the same way.
# Both are the same defect: an absent measurement rendering as a clean one.
AGREEMENT_MIN_PAIRED = 100        # absolute floor: 1/1 is not 100% agreement
AGREEMENT_MIN_COVERAGE = 0.5      # paired rows must represent the window, not a corner


def _parity_gates(row: Dict[str, Any], counters, rollout: Dict[str, Any], ruling: Optional[str],
                  now: datetime, evaluations_db: Optional[str]) -> Dict[str, Dict[str, Any]]:
    gates: Dict[str, Dict[str, Any]] = {}

    def gate(name: str, requirement: str, measured: str, ok: bool) -> None:
        gates[name] = {"requirement": requirement, "measured": measured, "pass": bool(ok)}

    since = rollout.get("since")
    age_days = None
    if since:
        try:
            age_days = (now - outcomes.parse_utc(str(since))).total_seconds() / 86400.0
        except ValueError:
            age_days = None
    gate("evidence_window", ">= 7 days of shadow/canary evidence",
         f"rollout.since={since or 'MISSING'} → {age_days:.1f} d" if age_days is not None else "rollout.since MISSING",
         age_days is not None and age_days >= 7)

    stats = _evaluation_stats(row, evaluations_db, now)
    gate("evaluations", ">= 200 evaluations in the window",
         f"{stats['evaluations']} rows" if stats["measured"] else "UNMEASURED (no evaluation store)",
         stats["measured"] and stats["evaluations"] >= 200)
    requirement = (f">= 99 % agreement over >= {AGREEMENT_MIN_PAIRED} paired rows "
                   f"and >= {AGREEMENT_MIN_COVERAGE:.0%} of the window")
    if not stats["measured"]:
        gate("agreement", requirement, "UNMEASURED (no evaluation store)", False)
    elif not stats["agree_measured"]:
        gate("agreement", requirement,
             "UNMEASURED (the evaluation store has no agreed/outcome_agrees column, so "
             "no row can be compared)", False)
    elif not stats["paired"]:
        gate("agreement", requirement, "UNMEASURED (no paired outcome rows)", False)
    else:
        agreement = 100.0 * stats["agreed"] / stats["paired"]
        coverage = stats["paired"] / float(stats["evaluations"] or 1)
        enough = stats["paired"] >= AGREEMENT_MIN_PAIRED
        wide = coverage >= AGREEMENT_MIN_COVERAGE
        gate("agreement", requirement,
             f"{agreement:.2f}% over {stats['paired']} paired rows "
             f"({coverage:.0%} of {stats['evaluations']} evaluations)"
             + ("" if enough else f" — TOO FEW PAIRED ROWS (need {AGREEMENT_MIN_PAIRED})")
             + ("" if wide else f" — TOO SPARSE (need {AGREEMENT_MIN_COVERAGE:.0%})"),
             agreement >= 99.0 and enough and wide)
    if not stats["measured"]:
        gate("false_act", "0 actions on RED/BLACK bands", "UNMEASURED (no evaluation store)", False)
    elif not (stats["band_measured"] and stats["decision_measured"]):
        missing = [n for n, ok in (("band", stats["band_measured"]),
                                   ("decision", stats["decision_measured"])) if not ok]
        gate("false_act", "0 actions on RED/BLACK bands",
             f"UNMEASURED (the evaluation store has no {'/'.join(missing)} column, so a "
             "false act cannot be seen at all)", False)
    else:
        gate("false_act", "0 actions on RED/BLACK bands",
             f"{stats['false_acts']} false acts of {stats['high_band']} RED/BLACK rows",
             stats["false_acts"] == 0)
    cap_trips = stats["cap_trips"]
    gate("cap_trips", "0 blast-radius cap trips",
         f"{cap_trips} trip(s)" if cap_trips is not None else "UNMEASURED (no cap-trip store)",
         cap_trips is not None and cap_trips == 0)

    d = row.get("demotion") or {}
    counts = dict(counters.of(str(row["id"])))
    _rate(counts)
    fired, texts = _rule_hits(d, counts, fast=False)
    blind = counters.blind_for(str(row["id"]))
    gate("demotion_triggers", "0 demotion triggers in the last 7 d",
         "; ".join(texts) if texts else ("UNMEASURED: " + "; ".join(sorted(blind.values())) if blind else "0 triggers"),
         not fired and not blind)

    gate("ruling", "a Fable ruling id is cited",
         f"{ruling}" if ruling else f"rollout.approval_ref={rollout.get('approval_ref') or 'MISSING'}",
         bool(ruling or rollout.get("approval_ref")))
    return gates


def _evaluation_stats(row: Dict[str, Any], evaluations_db: Optional[str], now: datetime) -> Dict[str, Any]:
    """Read the sentinel evaluation store for this capability. Tolerant: every unknown
    is a `measured: False`, which blocks promotion rather than passing it."""
    path = evaluations_db or outcomes.DEFAULT_PATHS["evaluations_db"]
    out = {"measured": False, "evaluations": 0, "paired": 0, "agreed": 0,
           "high_band": 0, "false_acts": 0, "cap_trips": None,
           # Which comparison columns the store actually HAS. A gate may not report
           # "clean" off a column that is not there.
           "band_measured": False, "decision_measured": False, "agree_measured": False}
    conn = outcomes._ro(path)
    if conn is not None:
        try:
            tables = outcomes._tables(conn)
            table = "sentinel_evaluations" if "sentinel_evaluations" in tables else ("evaluations" if "evaluations" in tables else None)
            if table:
                cols = outcomes._cols(conn, table)
                cap_c = outcomes._pick(cols, "capability_id", "capability")
                at_c = outcomes._pick(cols, "at", "created_at")
                band_c = outcomes._pick(cols, "band")
                dec_c = outcomes._pick(cols, "decision")
                agree_c = outcomes._pick(cols, "agreed", "outcome_agrees")
                since = now - timedelta(days=7)
                if cap_c and at_c:
                    out["measured"] = True
                    out["band_measured"] = bool(band_c)
                    out["decision_measured"] = bool(dec_c)
                    out["agree_measured"] = bool(agree_c)
                    sql = f"SELECT {cap_c} AS cap, {at_c} AS at" \
                          f"{', ' + band_c + ' AS band' if band_c else ', NULL AS band'}" \
                          f"{', ' + dec_c + ' AS decision' if dec_c else ', NULL AS decision'}" \
                          f"{', ' + agree_c + ' AS agreed' if agree_c else ', NULL AS agreed'}" \
                          f" FROM {table}"
                    for r in conn.execute(sql):
                        if str(r["cap"]) != str(row["id"]):
                            continue
                        if not outcomes._within(r["at"], since, now):
                            continue
                        out["evaluations"] += 1
                        band = str(r["band"] or "").upper()
                        decision = str(r["decision"] or "")
                        if band in ("RED", "BLACK"):
                            out["high_band"] += 1
                            if decision in ("act", "act_after_proof", "shadow_would_act"):
                                out["false_acts"] += 1
                        if r["agreed"] is not None:
                            out["paired"] += 1
                            if int(r["agreed"] or 0) == 1:
                                out["agreed"] += 1
        finally:
            conn.close()
    trips, err = outcomes._read_jsonl(os.environ.get("SENTINEL_CAP_TRIPS_STORE",
                                                     "/var/lib/hydra/sentinel/cap-trips.jsonl"))
    if err is None and Path(os.environ.get("SENTINEL_CAP_TRIPS_STORE",
                                           "/var/lib/hydra/sentinel/cap-trips.jsonl")).exists():
        n = 0
        for t in trips:
            if str(t.get("capability_id")) != str(row["id"]):
                continue
            if outcomes._within(t.get("at") or t.get("ts"), now - timedelta(days=7), now):
                n += 1
        out["cap_trips"] = n
    return out


FORCED_HANDOFF_CLASSES = {"refund", "legal", "erasure", "credentials", "delete_irreversible"}
# The taxonomy is R1..R15 (report §1). Two of those classes exist only as a hand-off in
# every ruling so far (R7 = hide/takedown/erasure/DMCA/access, R9 = refund/chargeback),
# so a proposal in them is forced too. Belt AND braces: the word appears in `class` or
# `sub_class` OR the R-code is one of these — `scripts/check-sentinel-registry.py` re-checks the
# row this function produces, so a miss here is still caught at PR time.
FORCED_HANDOFF_RCODES = {"R7", "R9"}
FORCED_HANDOFF_TOKENS = ("refund", "chargeback", "legal", "lawsuit", "cease", "dmca",
                         "erasure", "gdpr", "art17", "takedown", "credential",
                         "delete", "irreversible")


def cmd_propose(a, *, now: Optional[datetime] = None) -> int:
    """Weekly: cluster unhandled/hand-off rows into proposals + shadow registry rows.

    De-identified features only (class, sub_class, requested action, counts) and a
    closed schema. Deterministic grouping — no model is called from this lane: the
    sentinel's AI plumbing (`sentinel_llm_calls`, the daily cap, `/etc/hydra/sentinel-llm.disabled`)
    belongs to S0's classifier and an AI output is data that code validates, so a
    proposal's text is a template, never a model's judgement.
    """
    now = now or datetime.now(timezone.utc)
    stop = _stop_reason()
    if stop:
        print(f"[propose] {stop} present — NOT proposing: the whole sentinel is stopped, so a "
              "proposal would be the only thing moving. Delete the file to re-arm.", file=sys.stderr)
        return EXIT_KILLED
    try:
        with HostLock():
            return _propose_locked(a, now=now)
    except LockBusy as exc:
        print(f"[propose] {exc} — skipping this tick; the demotion tick owns the checkout.",
              file=sys.stderr)
        return EXIT_OK
    except LockUnavailable as exc:
        print(f"[propose] FATAL: {exc}", file=sys.stderr)
        return EXIT_ERROR


def _propose_locked(a, *, now: datetime) -> int:
    week = a.week or f"{now.isocalendar()[0]}-W{now.isocalendar()[1]:02d}"
    db = _eval_db(a)
    clusters = _unhandled_clusters(db, now)
    if not clusters:
        print("[propose] no unhandled/handoff rows in the last 30 d (or no evaluation store); "
              "nothing proposed. An empty week is not a failure.", file=sys.stderr)
        return EXIT_OK
    out_dir = Path(a.out_dir)
    try:
        rows = _load(a.registry)
    except registry.RegistryError:
        rows = []
    written: List[str] = []
    out_dir.mkdir(parents=True, exist_ok=True)
    # Redaction can collapse two distinct raw clusters onto ONE published view (two prose
    # sub_classes both become `unknown`). Merge them instead of letting the second write
    # overwrite the first: volume is summed and the forced flag is OR-ed, which is the
    # conservative direction — one forced member makes the merged cluster forced.
    vocab = _vocabulary(rows)
    views: Dict[Tuple[str, str, Optional[str]], Dict[str, Any]] = {}
    for cluster in clusters:
        # The money/legal fence reads the RAW values. Redacting first would let a prose
        # sub_class hide a forced cluster from it: class `credit` survives as a code, so
        # `sub_class="refund request"` -> `unknown` would turn a refund into an ACTOR type.
        forced = _is_forced_class(cluster["class"], cluster["sub_class"],
                                  cluster.get("requested_action"))
        # Everything that leaves this process — the slug, the committed file, the PR body —
        # is built from the de-identified view, never from caller-supplied text.
        view = _deidentified(cluster, vocab)
        key = (view["class"], view["sub_class"], view["requested_action"])
        if key in views:
            views[key]["count_30d"] += int(cluster.get("count_30d") or 0)
            views[key]["_forced"] = views[key]["_forced"] or forced
        else:
            views[key] = {**view, "_forced": forced}
    for view in list(views.values())[: a.max_proposals]:
        forced = bool(view.pop("_forced"))
        slug = _slug(f"{view['class']}-{view['sub_class']}-{view['requested_action'] or 'unspecified'}")
        proposed = _proposed_row(view, slug, week, at=outcomes.utc(now), forced=forced)
        nearest = [r for r in rows if str(r.get("class") or "") == str(view["class"])]
        view["nearest_capability"] = str(nearest[0]["id"]) if len(nearest) == 1 else None
        view["forced_handoff"] = proposed["action"]["type"] == "handoff" and forced
        path = out_dir / f"{week}-{slug}.md"
        path.write_text(report.proposal_markdown(slug=slug, week=week, cluster=view,
                                                 proposed_row=proposed,
                                                 generated_at=outcomes.utc(now)), encoding="utf-8")
        written.append(str(path))
        if a.open_pr:
            _open_proposal_pr(a, at=outcomes.utc(now), rel_path=path.name, proposed=proposed)
    for w in written:
        print(w)
    return EXIT_OK


def _open_proposal_pr(a, *, at: str, rel_path: str, proposed: Dict[str, Any]) -> None:
    """Open the proposal PR. Both files are written INSIDE `prepare`, i.e. after
    mirror.open_pr has switched the checkout to `origin/<base>`.

    Writing them first (the original order) silently lost the registry row: open_pr
    resets the checkout, which discards a tracked edit while leaving the untracked
    proposal markdown in place — so the PR would carry only the .md while its body
    claimed it registered the capability. A PR that says it did something it did not is
    worse than no PR.
    """
    repo_dir = Path(a.mirror_repo)
    try:
        text = (Path(a.out_dir) / rel_path).read_text(encoding="utf-8")
    except OSError as exc:
        print(f"[propose] PR skipped for {rel_path}: {exc}", file=sys.stderr)
        return

    def prepare(repo: Path) -> None:
        doc = mirror.add_shadow_row(
            json.loads((repo / mirror.REGISTRY_REL).read_text(encoding="utf-8")), proposed)
        target = repo / "data" / "sentinel" / "proposals" / rel_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        registry.atomic_write_json(repo / mirror.REGISTRY_REL, doc, mode=0o644)

    try:
        url = mirror.open_pr(
            title=f"feat(sentinel): propose {proposed['id']} in shadow ({rel_path})",
            body=(
                f"## sentinel-propose: {proposed['id']} (shadow — nothing acts)\n\n"
                "A cluster of `unhandled` / hand-off rows from the last 30 days, rendered by"
                " deterministic code into the proposal below. **No model was called in this lane**,"
                " and the row is added in `shadow`, so it evaluates and decides nothing until a"
                " Fable ruling promotes it (`scripts/sentinel/demote.py promote`).\n\n"
                f"- Proposal file: `data/sentinel/proposals/{rel_path}`\n"
                f"- Registry row: `{mirror.REGISTRY_REL}` (state `shadow`, `approval_ref: null`)\n"
                f"- Forced to `handoff`: `{proposed.get('_forced_handoff')}`"
                " (money/legal/credentials/irreversible is decided by code, not by prose)\n\n---\n\n"
                + text
            ),
            branch="sentinel/propose-" + rel_path.replace(".md", ""),
            paths=[mirror.REGISTRY_REL, f"data/sentinel/proposals/{rel_path}"],
            repo_dir=str(repo_dir), base=a.base, prepare=prepare,
        )
        print(f"[propose] PR: {url}", file=sys.stderr)
    except (OSError, ValueError, mirror.MirrorUnavailable) as exc:
        print(f"[propose] PR skipped for {rel_path}: {exc}", file=sys.stderr)


def _unhandled_clusters(db: str, now: datetime) -> List[Dict[str, Any]]:
    conn = outcomes._ro(db)
    if conn is None:
        return []
    try:
        tables = outcomes._tables(conn)
        table = "sentinel_evaluations" if "sentinel_evaluations" in tables else ("evaluations" if "evaluations" in tables else None)
        if table is None:
            return []
        cols = outcomes._cols(conn, table)
        cls_c = outcomes._pick(cols, "class")
        sub_c = outcomes._pick(cols, "sub_class", "subclass")
        dec_c = outcomes._pick(cols, "decision")
        at_c = outcomes._pick(cols, "at", "created_at")
        act_c = outcomes._pick(cols, "requested_action", "action")
        if not (cls_c and dec_c and at_c):
            return []
        since = now - timedelta(days=30)
        groups: Dict[Tuple[str, str, str], int] = {}
        sql = (f"SELECT {cls_c} AS cls, {sub_c + ' AS sub' if sub_c else chr(39)+chr(39)+' AS sub'}, "
               f"{dec_c} AS decision, {at_c} AS at, {act_c + ' AS action' if act_c else 'NULL AS action'} FROM {table}")
        for r in conn.execute(sql):
            if not outcomes._within(r["at"], since, now):
                continue
            if str(r["decision"] or "").strip().lower() not in ("unhandled", "handoff"):
                continue
            key = (str(r["cls"] or "unknown"), str(r["sub"] or "unknown"), str(r["action"] or "unknown"))
            groups[key] = groups.get(key, 0) + 1
    finally:
        conn.close()
    clusters = []
    for (cls, sub, action), n in sorted(groups.items(), key=lambda kv: -kv[1]):
        clusters.append({"class": cls, "sub_class": sub, "requested_action": action,
                         "count_30d": n, "name": f"{cls} / {sub}"})
    return clusters


# What a proposed cluster would act as, deterministically — never a model's choice.
# Two keyings, because the taxonomy is R-codes (§2.5) while the hand-off fence is phrased
# in words (§2.6.3): try the R-code, then the class word, then default to `handoff`.
# A class that is not listed proposes `handoff` — the conservative direction.
CLASS_TYPE_DEFAULTS = {
    "R1": "hydra_executor", "R2": "core_write", "R3": "handoff", "R4": "hydra_executor",
    "R5": "handoff", "R6": "handoff", "R7": "handoff", "R8": "handoff", "R9": "handoff",
    "R10": "message_line", "R11": "core_write", "R12": "core_write", "R13": "core_write",
    "R14": "core_write", "R15": "handoff",
}
CLASS_WORD_TYPES = {
    "credit": "hydra_executor", "claim": "hydra_executor", "support": "message_line",
    "profile": "core_write", "analytics": "core_write", "entity": "core_write",
    "billing": "handoff", "merge": "handoff", "takedown": "handoff", "refund": "handoff",
    "legal": "handoff", "erasure": "handoff", "credentials": "handoff",
}


def _proposed_type(cls: str) -> str:
    key = str(cls).strip()
    if key.upper() in CLASS_TYPE_DEFAULTS:
        return CLASS_TYPE_DEFAULTS[key.upper()]
    return CLASS_WORD_TYPES.get(key.lower(), "handoff")


def _is_forced_class(cls: str, sub: str, action: Any = "") -> bool:
    """Is this cluster money / legal / credentials / irreversible? Code, not judgement.

    All three fields are read: a `credit` cluster whose sub_class is innocuous can still
    request a `refund`, and reading only class/sub_class proposed that as an ACTOR type.
    """
    if str(cls).strip().upper() in FORCED_HANDOFF_RCODES:
        return True
    blob = f"{cls} {sub} {action or ''}".lower()
    return any(tok in blob for tok in FORCED_HANDOFF_TOKENS)


def _proposed_row(cluster: Dict[str, Any], slug: str, week: str, at: str,
                  *, forced: Optional[bool] = None) -> Dict[str, Any]:
    # `forced` is passed in by the caller, which still holds the RAW cluster: the row is
    # built from the de-identified view, and the fence must not be re-derived from it.
    if forced is None:
        forced = _is_forced_class(cluster["class"], cluster["sub_class"],
                                  cluster.get("requested_action"))
    action_type = "handoff" if forced else _proposed_type(cluster["class"])
    return {
        "id": f"proposed.{cluster['class']}.{slug}"[:96],
        "class": cluster["class"],
        "sub_class": cluster["sub_class"],
        "action": {"type": action_type, "endpoint": None, "idempotent": None,
                   "requested": cluster["requested_action"]},
        "input_schema": None,
        "guards": ["band_allows"],
        "blast_radius": {"per_request_rows": 0, "per_user_day": 0, "per_profile_day": 0,
                         "fleet_day": 0, "max_target_popularity": 0},
        "reversibility": "irreversible" if forced else "reversible",
        "rollout": {"state": "shadow", "canary_modulo": None, "since": at,
                    "approval_ref": None, "proposed": week},
        "demotion": {"reverts_7d": 1, "contradicted_7d": 1, "audit_fail_any": True,
                     "complaints_7d": 3, "overdue_pct": 5, "on_trip": "canary"},
        "owner": "sentinel-propose",
        "kill_file": f"/etc/hydra/sentinel-{slug}.disabled",
        "links": {"credit_approval_automation": None, "proposal": f"data/sentinel/proposals/{week}-{slug}.md"},
        "_forced_handoff": forced,
    }


# A cluster field is published only when it is a member of a vocabulary this repo OWNS —
# never because it merely LOOKS like a code. The evaluation store is fed by callers, so
# `requested_action` can carry whatever a caller put there: an email, an account id, a
# UUID, a sentence. Shape cannot separate `user_12` from `R12`, so the boundary is
# membership: the class table below, or a class / sub_class / requested action that a
# reviewed registry row already declares. The vocabulary grows by a registry PR, never by
# whatever a caller wrote into the evaluation store (de-identified features only, §2.6).

def _vocabulary(rows: Sequence[Dict[str, Any]]) -> set:
    """The tokens a proposal may publish: the class table plus every declared registry value."""
    vocab = set(CLASS_TYPE_DEFAULTS) | set(CLASS_WORD_TYPES)
    for r in rows:
        if not isinstance(r, dict):
            continue
        for key in ("class", "sub_class"):
            v = str(r.get(key) or "").strip()
            if v:
                vocab.add(v)
        action = r.get("action")
        if isinstance(action, dict):
            for key in ("requested", "endpoint"):
                v = str(action.get(key) or "").strip()
                if v:
                    vocab.add(v)
    return vocab


def _code_token(value: Any, vocab: set) -> Optional[str]:
    """The value if the vocabulary names it, else None.

    Membership, not shape, is the de-identification boundary. Whitespace is refused too:
    a vocabulary member is a code, and a code never contains a newline that could break
    out of the markdown it is rendered into.
    """
    text = str(value or "").strip()
    if not text or any(c.isspace() for c in text):
        return None
    return text if text in vocab else None


def _deidentified(cluster: Dict[str, Any], vocab: set) -> Dict[str, Any]:
    """The publishable view of a cluster: vocabulary members only, never caller prose.

    `name` is rebuilt from the surviving values so a redacted field cannot ride along in
    the proposal's title, and `requested_action` becomes None rather than a redaction
    marker — the markdown says out loud that it was not published.
    """
    cls = _code_token(cluster.get("class"), vocab) or "unknown"
    sub = _code_token(cluster.get("sub_class"), vocab) or "unknown"
    return {**cluster, "class": cls, "sub_class": sub,
            "requested_action": _code_token(cluster.get("requested_action"), vocab),
            "name": f"{cls} / {sub}"}


def _slug(s: str) -> str:
    keep = [c.lower() if c.isalnum() else "-" for c in s]
    out = "".join(keep)
    while "--" in out:
        out = out.replace("--", "-")
    return out.strip("-")[:60] or "cluster"


# ── CLI ────────────────────────────────────────────────────────────────────────
def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description="sentinel-demote: automatic demotion, never promotion")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--registry", default=None, help=f"repo registry (default {registry.REGISTRY_DEFAULT})")
        p.add_argument("--runtime-state", default=None, help="host runtime state file")
        p.add_argument("--paths-json", default=None, help="JSON object overriding source paths (tests)")
        p.add_argument("--json", action="store_true")
        p.add_argument("--no-page", action="store_true", help="render but never post to Slack")
        p.add_argument("--evaluations-db", default=None)

    run = sub.add_parser("run", help="evaluate the 7-day window and demote on any trip")
    common(run)
    run.add_argument("--nightly", action="store_true", help="also print/post the digest (02:30Z unit)")
    run.add_argument("--fast", action="store_true", help="only the audit_fail_any / manipulated triggers (hourly unit)")
    run.add_argument("--digest", action="store_true", help="print the digest after acting")
    run.add_argument("--dry-run", action="store_true", help="change nothing; render what would happen")
    run.add_argument("--no-pr", action="store_true", help="do not open the repo mirror PR")
    run.add_argument("--pr-dry-run", action="store_true", help="render the mirror PR body, open nothing")
    run.add_argument("--mirror-repo", default=MIRROR_REPO)
    run.add_argument("--base", default="main")
    run.add_argument("--paths-disabled", dest="registry_paths_disabled", action="store_true",
                     help="collect nothing (every trigger unmeasured)")

    dg = sub.add_parser("digest", help="print the 7-day counters for every capability")
    common(dg)

    pr = sub.add_parser("promote", help="render the parity report for a Fable ruling (never flips state)")
    common(pr)
    pr.add_argument("--capability", required=True)
    pr.add_argument("--ruling", default=None, help="the Fable ruling id the PR will cite")

    pp = sub.add_parser("propose", help="weekly: cluster unhandled/handoff rows into proposals")
    common(pp)
    pp.add_argument("--week", default=None)
    pp.add_argument("--out-dir", default=str(_SCRIPTS_DIR.parent / "data" / "sentinel" / "proposals"))
    pp.add_argument("--max-proposals", type=int, default=5)
    pp.add_argument("--open-pr", action="store_true")
    pp.add_argument("--mirror-repo", default=MIRROR_REPO)
    pp.add_argument("--base", default="main")
    return ap


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.cmd == "run":
            return cmd_run(args)
        if args.cmd == "digest":
            return cmd_digest(args)
        if args.cmd == "promote":
            return cmd_promote(args)
        if args.cmd == "propose":
            return cmd_propose(args)
    except registry.RegistryMissing as exc:
        print(f"[demote] {exc}", file=sys.stderr)
        return EXIT_NO_REGISTRY
    except registry.RegistryInvalid as exc:
        print(f"[demote] FATAL: {exc}", file=sys.stderr)
        return EXIT_BAD_STATE
    except KeyboardInterrupt:
        return EXIT_ERROR
    return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
