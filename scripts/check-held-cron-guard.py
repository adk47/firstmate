#!/usr/bin/env python3
"""Refuse any diff that arms a HELD cron or deletes a kill-file sentinel.

A held cron is one whose kill file is present on node-8 (/etc/hydra/<name>.disabled, placed by a human
for a reason the file states). The repo half of that fact is policies/held-crons.json; on a host where
/etc/hydra exists, every cron whose description names a present kill file is held too, registry or not.

Refused (exit 1), with the rule, the cron and the diff hunk named:
  R1  a held cron's `enabled` goes false -> true
  R2  a held cron's `schedule` changes
  R3  a held cron's `payload` (the command) changes
  R4  a held cron's row is deleted
  R5  a held-crons.json entry is removed or edited without the recorded step's key
  R6  an added code line deletes a kill-file sentinel: a delete verb (rm / unlink / os.remove / .unlink( / shred /
      truncate / missing_ok) on the same line as a sentinel path. Literal paths only: a path assembled from variables
      is not seen, so this is a tripwire for the obvious edit, not a proof of absence.
Exit 2 = could not read an input (base ref, JSON) - never a pass.

The ONE way through R1-R5 for a given cron: the same diff removes that cron's entry from policies/held-crons.json
AND cites the recorded step's evidence key, `[key=kill-lift-MMDD-HHMM]` (written by
scripts/credit-approve-hold-lift.sh), ON THE SAME LINE AS THAT CRON'S NAME, in a commit message of the range
(--base mode) or in HELD_CRON_LIFT_KEY=kill-lift-MMDD-HHMM:<cron-name>[,<cron-name>] (--staged mode, where there is
no message yet). A key is bound to the crons it names: one citation never lifts a second entry removed in the same
diff. And a citation is not evidence: the key must be backed by the EXECUTED step's record committed in the same diff
at data/kill-lift/<key>.evidence (the planner's evidence file after the human ran the step), which must carry a
`... lifted [key=<key>] ...` line AS ITS LAST record line AND name that cron's kill file. A key with no such record, or
a record that was only PLANNED or ROLLED BACK, is no key. And a committed record is still only a CLAIM: with --host
(the node-8 hand-off job, a required check) the lift is confirmed against the host itself - the kill file must be
absent under --etc-dir and the step's own record under --host-state-dir (/var/lib/hydra/credit-review, root 750,
written only by the step run as root) must be byte-identical to the committed copy. A PR can fabricate a text file;
it cannot remove a kill file on node-8 or write under that directory, so a fabricated record is red on the host run.
Without --host the guard says so (NOTE) and does not claim confirmation. R6 has no key: code that deletes a sentinel
is reviewed as code, with `# held-cron-guard: <reason>` on the line if it is meant.

Why this exists: on 2026-11-07 an automated review fix inside a print-only PR (hydra#1832, dd40d67e9) flipped
credit-trust-score-approve-15m to enabled:true "so the lift restores approvals". A human caught it. The next one
is caught here, before the commit exists (pre-commit) and before it can merge (PR Validation).

Usage:
  scripts/check-held-cron-guard.py --base origin/main        # CI (ARC pod): base...HEAD; a cited lift is noted, not confirmed
  scripts/check-held-cron-guard.py --base origin/main --host # CI (node-8 hand-off): the same, plus host confirmation
  scripts/check-held-cron-guard.py --staged                  # pre-commit: HEAD vs the index
  scripts/check-held-cron-guard.py --staged --repo DIR --etc-dir DIR   # bats drives the rules against a synthetic repo
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

CRON_FILE = "cron-jobs.json"
REGISTRY_FILE = "policies/held-crons.json"
KEY_RE = re.compile(r"\[key=(kill-lift-\d{4}-\d{4})\]")
ENV_KEY_RE = re.compile(r"^(kill-lift-\d{4}-\d{4}):([\w.-]+(?:,[\w.-]+)*)$")


EVIDENCE_DIR = "data/kill-lift"


def read_text_at(ref: str | None, path: str, cwd: Path, *, staged: bool = False) -> str | None:
    try:
        if staged:
            return git("show", f":{path}", cwd=cwd)
        if ref is None:
            p = cwd / path
            return p.read_text(encoding="utf-8") if p.exists() else None
        return git("show", f"{ref}:{path}", cwd=cwd)
    except subprocess.CalledProcessError as exc:
        err = (exc.stderr or "").lower()
        if "does not exist" in err or "exists on disk, but not in" in err or "path" in err and "not in" in err:
            return None
        raise


RECORD_LINE_RE = r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z (\S[^\[]*?) \[key=%s\] "


def lift_record(key: str, kill_file: str, text: str | None) -> str:
    """'' when the committed evidence proves the step COMPLETED for this kill file; else the reason it does not.

    The step script writes `lifted` as its LAST record line and only on exit 0; `ROLLED BACK`, `REFUSED` and every
    other outcome are written instead of it, never after it. So the proof is: the final record line for this key
    is `lifted`, and the file names the kill file. A `lifted` followed by anything is not a completed step."""
    if text is None:
        return f"no {EVIDENCE_DIR}/{key}.evidence in this tree"
    records = re.findall(RECORD_LINE_RE % re.escape(key), text, re.M)
    if not records:
        return f"{EVIDENCE_DIR}/{key}.evidence has no step record (the step was planned, not run)"
    if "lifted" not in records:
        return f"{EVIDENCE_DIR}/{key}.evidence has no 'lifted [key={key}]' line (the step ran but did not complete: {records[-1]})"
    if records[-1] != "lifted":
        return f"{EVIDENCE_DIR}/{key}.evidence ends in '{records[-1]}', not 'lifted' (the step did not complete)"
    if kill_file not in text:
        return f"{EVIDENCE_DIR}/{key}.evidence does not name {kill_file}"
    return ""


def host_confirms(key: str, kill_file: str, committed: str, etc_dir: Path, host_state: Path) -> str:
    """'' when THIS host agrees with the committed record; else why not. Only the step, run as root on the host,
    writes <host_state>/<key>.evidence (root 750 directory) and removes the kill file under <etc_dir>; a PR cannot
    fabricate either, so a committed record that matches the host's byte for byte is the executed step, and one that
    does not is a claim."""
    present = etc_dir / Path(kill_file).name
    if present.exists():
        return f"host {os.uname().nodename} still has {present}: the hold is ON, nothing was lifted"
    host_rec = host_state / f"{key}.evidence"
    if not host_rec.is_file():
        return f"host {os.uname().nodename} has no {host_rec}: the step never ran here"
    try:
        host_text = host_rec.read_text(encoding="utf-8")
    except OSError as exc:
        return f"host record {host_rec} unreadable ({exc})"
    if hashlib.sha256(host_text.encode()).hexdigest() != hashlib.sha256(committed.encode()).hexdigest():
        return (f"the committed {EVIDENCE_DIR}/{key}.evidence is not byte-identical to the host's {host_rec} "
                f"(sha256 {hashlib.sha256(committed.encode()).hexdigest()[:12]} vs "
                f"{hashlib.sha256(host_text.encode()).hexdigest()[:12]}): commit the host's file as it is")
    return ""


def citations_from_log(log: str, names: set[str]) -> dict[str, set[str]]:
    """name -> keys cited on a line that also names that cron. A key on a line naming no held cron binds to nothing."""
    out: dict[str, set[str]] = {}
    for line in log.splitlines():
        keys = KEY_RE.findall(line)
        if not keys:
            continue
        for n in names:
            if n in line:
                out.setdefault(n, set()).update(keys)
    return out


def citations_from_env(value: str) -> dict[str, set[str]]:
    m = ENV_KEY_RE.match(value)
    if not m:
        return {}
    return {n: {m.group(1)} for n in m.group(2).split(",")}
KILL_FILE_RE = re.compile(r"/etc/hydra/[\w.-]+\.disabled")
# R6: a deletion verb and a .disabled path on the same ADDED line. Tests and docs are not code that runs on the host.
DELETE_RE = re.compile(r"(\brm\b|\bunlink\b|os\.remove\b|\.unlink\(|\bshred\b|\btruncate\b|missing_ok)")
SENTINEL_RE = re.compile(r"\.disabled\b")
R6_SKIP_PREFIXES = ("docs/", "scripts/tests/", "plugins/intercom/redteam/", "data/")
R6_SKIP_SUFFIXES = (".md", ".bats", ".txt")
R6_OPT_OUT = "held-cron-guard:"


def git(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


def read_json_at(ref: str | None, path: str, cwd: Path, *, staged: bool = False) -> dict | None:
    """ref=None reads the working tree; staged reads the index (:path); else REF:path. Missing file -> None."""
    try:
        if staged:
            text = git("show", f":{path}", cwd=cwd)
        elif ref is None:
            p = cwd / path
            if not p.exists():
                return None
            text = p.read_text(encoding="utf-8")
        else:
            text = git("show", f"{ref}:{path}", cwd=cwd)
    except subprocess.CalledProcessError as exc:
        err = (exc.stderr or "").lower()
        if "does not exist" in err or "exists on disk, but not in" in err or "path" in err and "not in" in err:
            return None
        raise
    return json.loads(text)


def jobs_by_name(doc: dict | None) -> dict[str, dict]:
    if not doc:
        return {}
    return {j["name"]: j for j in doc.get("jobs", []) if "name" in j}


def registry_names(doc: dict | None) -> dict[str, dict]:
    if not doc:
        return {}
    return {e["name"]: e for e in doc.get("held", []) if "name" in e}


def held_on_host(jobs: dict[str, dict], etc_dir: Path) -> dict[str, str]:
    """name -> present kill file, for crons whose description names a kill file that exists under etc_dir."""
    out: dict[str, str] = {}
    if not etc_dir.is_dir():
        return out
    for name, j in jobs.items():
        for f in KILL_FILE_RE.findall(j.get("description", "")):
            if (etc_dir / Path(f).name).exists():
                out[name] = f
                break
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--base", help="base ref; compares BASE...HEAD")
    mode.add_argument("--staged", action="store_true", help="pre-commit: HEAD vs the index")
    ap.add_argument("--repo", default=".", help="repo root (default: .)")
    ap.add_argument("--etc-dir", default="/etc/hydra", help="host kill-file dir; absent = registry only")
    ap.add_argument("--host", action="store_true",
                    help="this run is ON the host the step ran on (node-8): a cited lift is confirmed only if the kill "
                         "file is absent here and the step's own record under --host-state-dir is byte-identical to "
                         "the committed copy. Without --host a cited lift is NOT confirmed, only noted; the node-8 "
                         "hand-off job is the required check that confirms it")
    ap.add_argument("--host-state-dir", default="/var/lib/hydra/credit-review",
                    help="where the step writes its record on the host (kill-lift-MMDD-HHMM.evidence)")
    args = ap.parse_args()
    cwd = Path(args.repo).resolve()
    etc_dir = Path(args.etc_dir)
    host_state = Path(args.host_state_dir)

    # ── inputs: base side, new side, the diff, and the cited keys ───────────────────────────────────────────
    try:
        if args.staged:
            base_ref = "HEAD"
            git("rev-parse", "--verify", "--quiet", "HEAD", cwd=cwd)
            old_jobs = jobs_by_name(read_json_at("HEAD", CRON_FILE, cwd))
            old_reg = registry_names(read_json_at("HEAD", REGISTRY_FILE, cwd))
            new_jobs = jobs_by_name(read_json_at(None, CRON_FILE, cwd, staged=True))
            new_reg = registry_names(read_json_at(None, REGISTRY_FILE, cwd, staged=True))
            diff = git("diff", "--cached", "--unified=0", "--no-color", cwd=cwd)
            log = ""
            new_ref, staged = None, True
            key_source = "HELD_CRON_LIFT_KEY=kill-lift-MMDD-HHMM:<cron-name>"
        else:
            git("rev-parse", "--verify", "--quiet", args.base, cwd=cwd)
            base_ref = git("merge-base", args.base, "HEAD", cwd=cwd).strip()
            old_jobs = jobs_by_name(read_json_at(base_ref, CRON_FILE, cwd))
            old_reg = registry_names(read_json_at(base_ref, REGISTRY_FILE, cwd))
            new_jobs = jobs_by_name(read_json_at("HEAD", CRON_FILE, cwd))
            new_reg = registry_names(read_json_at("HEAD", REGISTRY_FILE, cwd))
            diff = git("diff", "--unified=0", "--no-color", f"{base_ref}..HEAD", cwd=cwd)
            log = git("log", "--format=%B", f"{base_ref}..HEAD", cwd=cwd)
            new_ref, staged = "HEAD", False
            key_source = f"commit messages {base_ref[:12]}..HEAD, on the same line as the cron's name"
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        print(f"held-cron-guard: cannot read an input ({type(exc).__name__}: {detail.strip()}) - exit 2 is not a pass")
        return 2

    # ── who is held: base registry ∪ new registry ∪ host kill files (never only the new side: deleting the
    #    registry entry is itself the change under review) ──────────────────────────────────────────────────
    held: dict[str, str] = {}
    for name, e in {**old_reg, **new_reg}.items():
        held[name] = e.get("kill_file", "?")
    host_held = held_on_host({**old_jobs, **new_jobs}, etc_dir)
    warnings: list[str] = []
    for name, f in host_held.items():
        if name not in held:
            warnings.append(f"{name}: kill file {f} is present on this host but the cron is not in {REGISTRY_FILE}")
        held.setdefault(name, f)

    # ── the key: which crons are being lifted by the recorded step in THIS diff. A key is bound to the cron it is
    #    cited WITH (same commit-message line / the env value names it): a diff that removes two entries and cites
    #    one cron's key lifts that cron only; the other removal is R5. ──────────────────────────────────────────
    removed_entries = {n for n in old_reg if n not in new_reg}
    edited_entries = {n for n in old_reg if n in new_reg and old_reg[n] != new_reg[n]}
    citations = citations_from_log(log, set(held))
    for n, ks in citations_from_env(os.environ.get("HELD_CRON_LIFT_KEY", "")).items():
        citations.setdefault(n, set()).update(ks)
    # a citation lifts an entry only when the executed step's record is committed alongside it - and, on the host
    # (--host), only when the host agrees: the kill file is gone and the record the step wrote under --host-state-dir
    # is byte-identical to the committed copy. A committed text file alone is a claim; the host is the fact.
    lifted: set[str] = set()
    unbacked: dict[str, list[str]] = {}
    lift_keys: dict[str, str] = {}
    for n in sorted(removed_entries | edited_entries):
        kill_file = old_reg[n].get("kill_file", "")
        for k in sorted(citations.get(n, ())):
            committed = read_text_at(new_ref, f"{EVIDENCE_DIR}/{k}.evidence", cwd, staged=staged)
            why = lift_record(k, kill_file, committed)
            if not why and args.host:
                why = host_confirms(k, kill_file, committed or "", etc_dir, host_state)
            if not why:
                lifted.add(n)
                lift_keys[n] = k
                break
            unbacked.setdefault(n, []).append(why)
    keys: set[str] = set().union(*citations.values()) if citations else set()

    findings: list[str] = []

    # R5 before R1-R4: an entry leaving the registry without ITS key is the loophole itself
    for n in sorted(removed_entries | edited_entries):
        if n in lifted and n in edited_entries:
            findings.append(f"R5 {n}: the executed step's record is committed, so the entry leaves {REGISTRY_FILE}; an edited entry is not a lift")
            continue
        if n in lifted:
            continue
        if not citations.get(n):
            what = "removed from" if n in removed_entries else "edited in"
            findings.append(
                f"R5 {n}: entry {what} {REGISTRY_FILE} without the recorded step's key for THIS cron "
                f"([key=kill-lift-MMDD-HHMM] in {key_source}); lifting a hold is the recorded step, not an edit"
            )
        elif n in unbacked:
            findings.append(
                f"R5 {n}: key cited but not backed by the executed step's record: " + "; ".join(unbacked[n])
                + f". Commit the planner's evidence file (after the human ran the step) at {EVIDENCE_DIR}/<key>.evidence in the same diff"
            )

    for name in sorted(held):
        if name in lifted and name not in edited_entries:
            continue
        old = old_jobs.get(name)
        new = new_jobs.get(name)
        kf = held[name]
        if old is None and new is None:
            continue
        if old is not None and new is None:
            findings.append(f"R4 {name}: held cron (kill file {kf}) deleted from {CRON_FILE}")
            continue
        if old is None and new is not None:
            if new.get("enabled") is True:
                findings.append(f"R1 {name}: held cron (kill file {kf}) added with enabled:true")
            continue
        if old.get("enabled") is not True and new.get("enabled") is True:
            findings.append(
                f"R1 {name}: enabled {old.get('enabled')!r} -> true while its kill file {kf} is present; "
                f"the scheduler row is a stop, lifted only by the recorded step"
            )
        if old.get("schedule") != new.get("schedule"):
            findings.append(f"R2 {name}: schedule {old.get('schedule')!r} -> {new.get('schedule')!r} on a held cron")
        if old.get("payload") != new.get("payload"):
            findings.append(f"R3 {name}: payload (the command) changed on a held cron")

    # R6: added code lines that delete a sentinel
    current_file = ""
    for line in diff.splitlines():
        if line.startswith("+++ "):
            current_file = line[4:].removeprefix("b/").strip()
            continue
        if not line.startswith("+") or line.startswith("+++"):
            continue
        if current_file.startswith(R6_SKIP_PREFIXES) or current_file.endswith(R6_SKIP_SUFFIXES):
            continue
        body = line[1:]
        if R6_OPT_OUT in body:
            continue
        if SENTINEL_RE.search(body) and DELETE_RE.search(body):
            findings.append(f"R6 {current_file}: added line deletes a .disabled sentinel: {body.strip()[:160]}")

    # ── verdict ──────────────────────────────────────────────────────────────────────────────────────────────
    for w in warnings:
        print(f"held-cron-guard: WARNING {w}")
    if lifted:
        print(f"held-cron-guard: recorded step cited ({', '.join(sorted(keys))}); lifted in this diff: {', '.join(sorted(lifted))}")
        if args.host:
            print(f"held-cron-guard: HOST CONFIRMED on {os.uname().nodename}: kill file absent and the step's record under "
                  f"{host_state} is byte-identical to the committed copy for {', '.join(sorted(lift_keys.values()))}")
        else:
            print("held-cron-guard: NOTE this run cannot see the host, so the committed record is a CLAIM here; the "
                  "node-8 hand-off job runs this guard with --host and is the check that confirms the lift")
    if findings:
        print(f"held-cron-guard: REFUSED - {len(findings)} finding(s) against {base_ref[:12]}:")
        for f in findings:
            print(f"  - {f}")
        print("A held cron moves only by the recorded step (scripts/credit-approve-hold-lift.sh): remove its entry from")
        print(f"{REGISTRY_FILE} and cite [key=kill-lift-MMDD-HHMM] in the same diff. Do not bypass this guard.")
        return 1
    print(f"held-cron-guard: OK - {len(held)} held cron(s) untouched against {base_ref[:12]} ({len(host_held)} seen on host)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
