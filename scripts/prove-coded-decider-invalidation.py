#!/usr/bin/env python3
"""Prove the coded-decider invalidation path, on a deployed tree, without touching a single switch.

The resume condition written into /etc/hydra/credit-trust-score-approve.disabled (firstmate, 2026-11-06T08:2xZ):

    "both switches come off together, in one recorded step, only after the coded-decider invalidation path is
     proved (run twice, second invalidates first, no Errno 13)"

This script is that proof, and nothing else. It runs `credit_review.decide.run()` TWICE on ONE named fixture
(scripts/credit_review/fixtures/coded-decider-invalidation.json, a deployed path so the planner can run this on node-8) inside a sandbox, and asserts FROM THE OUTPUT - the coded
output document on disk, the ledger's write record, and `decide_coded_current()`'s own line - that:

  1. run 1 produces a CURRENT document for run_id R1;
  2. run 2 produces a CURRENT document for run_id R2 != R1, and the FIRST document is INVALIDATED: its exact bytes,
     put back on the path, read NOT CURRENT ("stale artifact") against the record run 2 left;
  3. no `Errno 13` (and no `Permission denied` of any kind) appears in any log line, write error, note or document
     from either run, and the writer never re-armed a kill switch.

Optional `--with-failed-refresh` adds a THIRD run whose refresh is made to fail with an INJECTED `[Errno 13]` on the
atomic replace - the exact error that armed the real switch on 2026-11-05 - and asserts the failure is CONTAINED:
the previous document is invalidated in place, the record says `fresh: false`, the probe says NOT CURRENT, and the
(sandboxed) kill switch is still NOT re-armed because invalidation succeeded. That leg is labelled as injected in the
transcript; the "no Errno 13" assertion in (3) is about runs 1 and 2 only.

`--host-probe [DIR]` adds the HOST leg the sandbox cannot stand in for: the two runs above prove the MECHANISM, but the
hold was armed by a permission failure, and permissions are a property of the real directory and the real user, not
of the code. The probe performs, in the LIVE output directory (default: the directory the tree's own default
CODED_DECIDER_OUT points at, /var/lib/hydra/credit-review), as the user running this script, exactly the writer's
ladder on PROBE-NAMED files: tmp + atomic replace (create), replace over an existing file (refresh), then the tree's
own `_invalidate_coded_output` on the probe, then unlink. It also reads (never writes) the live document's owner, mode
and `os.access` and requires that this user could write through it and could replace or unlink it (directory
write+search). Any Errno 13 here fails the proof. The probe never opens the live document for writing, removes its own
files, and refuses to run if the probe path would equal the live path. It must run as the user the decider cron runs
as (`--service-user`, default root: openclaw isolated command crons run inside the gateway), otherwise it would be
measuring somebody else's permissions, and it fails rather than report those.

What it can never do:
  * let decide.py remove, create or edit any file under /etc/hydra or /var/lib/hydra - every host path it
    knows (kill switches, write lock, coded output, paying-users, proof-on-file, stage-2 store, doc-approve
    freeze, ledger, re-arm sentinel, run log) is pointed INTO a temp sandbox before the module is imported,
    and the script refuses to start if any of them still resolves outside it. The files this script writes
    itself are the transcript, at --record, and (with --host-probe) probe-named files beside the live document,
    which it deletes again;
  * reach the admin API or a model - the fixture row carries a validator reject rule, so decide.run() HOLDS it before
    any catalog or judge call, and the admin object raises on first touch;
  * approve, support or ask anything - the runs are `--mode judge` (no core write, no ask, no notify) and in a
    sandbox ledger.

Exit 0 and a final `PROOF: PASS` line when every assertion holds; exit 1 and `PROOF: FAIL` with what was observed
otherwise; exit 2 when the proof could not be run at all. `--record PATH` writes the full transcript for a human.

Usage (on node-8, against the deployed tree):
    python3 /opt/hydra/scripts/prove-coded-decider-invalidation.py --tree /opt/hydra \
        --record /var/lib/hydra/credit-review/coded-invalidation-proof-$(date -u +%Y%m%dT%H%M%SZ).txt
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

HERE = Path(__file__).resolve().parent
DEFAULT_FIXTURE = HERE / "credit_review" / "fixtures" / "coded-decider-invalidation.json"
FORBIDDEN_PREFIXES = ("/etc/hydra", "/var/lib/hydra", "/var/lib/credit-trust", "/var/lib/hydra-credit-verify")
ERRNO13_MARKERS = ("Errno 13", "Permission denied")


class Transcript:
    def __init__(self, record: Path | None):
        self.lines: list[str] = []
        self.record = record
        self.failures: list[str] = []

    def say(self, line: str = "") -> None:
        self.lines.append(line)
        print(line, flush=True)

    def check(self, ok: bool, what: str, observed: str) -> bool:
        tag = "OK  " if ok else "FAIL"
        self.say(f"  [{tag}] {what}")
        self.say(f"         observed: {observed}")
        if not ok:
            self.failures.append(f"{what} -- observed: {observed}")
        return ok

    def flush(self) -> None:
        if self.record is None:
            return
        try:
            self.record.parent.mkdir(parents=True, exist_ok=True)
            self.record.write_text("\n".join(self.lines) + "\n", encoding="utf-8")
        except OSError as exc:
            print(f"WARNING: transcript not recorded at {self.record}: {exc}", file=sys.stderr)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class NoAdmin:
    """An admin client that proves it was never used: any attribute access is a failure of the proof."""

    def __getattr__(self, name: str) -> Any:
        raise AssertionError(f"the proof fixture must not reach the admin API, but decide.run() touched admin.{name}")


def sandbox_env(box: Path) -> dict[str, str]:
    """Every host path decide.py reads from the environment, pointed into the sandbox BEFORE import."""
    return {
        "CV_CODED_DECIDER_OUT": str(box / "fable-decider.coded-input.json"),
        "CREDIT_TRUST_DECIDE_KILL_SWITCH": str(box / "etc" / "credit-trust-decide.disabled"),
        "CREDIT_TRUST_JUDGE_KILL_SWITCH": str(box / "etc" / "credit-trust-judge.disabled"),
        "CREDIT_DOC_APPROVE_KILL_SWITCH": str(box / "etc" / "doc-approve.disabled"),
        "CREDIT_DOC_APPROVE_FREEZE": str(box / "credit-verify" / "doc-approve.frozen"),
        "CREDIT_TRUST_DECIDE_APPROVE_DISABLED": str(box / "etc" / "credit-trust-decide-approve.disabled"),
        "CREDIT_TRUST_PROVISIONAL_PAID_DISABLED": str(box / "etc" / "credit-trust-decide-provisional-paid.disabled"),
        "CV_CREDIT_WRITE_LOCK_PATH": str(box / "credit-status-writes.lock"),
        "CREDIT_TRUST_PAYING_USERS_FILE": str(box / "paying-users.json"),
        "CREDIT_TRUST_PROOF_ON_FILE": str(box / "proof-on-file.json"),
        "CREDIT_PROOF_STORE": str(box / "proof.sqlite"),
        "CREDIT_VERIFY_STATE_DIR": str(box / "credit-verify"),
        "CREDIT_DOC_VERIFY_STORE": str(box / "doc-verify.sqlite"),
        "CREDIT_REVIEW_LOG": str(box / "run.log"),
        "CREDIT_REVIEW_LEDGER": str(box / "ledger.sqlite3"),
        "CREDIT_TEST_ENV_DIR": str(box),
        "CREDIT_APPROVAL_REGISTRY": str(box / "credit-approval-automation.json"),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--tree", default=str(HERE.parent),
                    help="repo root whose scripts/credit_review/decide.py is under proof (default: this script's tree; "
                         "on node-8 pass /opt/hydra)")
    ap.add_argument("--fixture", default=None,
                    help="the one named fixture (JSON, key `rows`); default: scripts/credit_review/fixtures/"
                         "coded-decider-invalidation.json under --tree (the deployed copy), else this script's own")
    ap.add_argument("--record", default=None, help="write the transcript here for a human to read")
    ap.add_argument("--with-failed-refresh", action="store_true",
                    help="also run a third time with an INJECTED Errno 13 on the refresh and assert it is contained")
    ap.add_argument("--host-probe", nargs="?", const="", default=None, metavar="DIR",
                    help="also probe create/replace/invalidate permissions, as this user, on probe-named files in the "
                         "LIVE output directory (default DIR: where --tree's decide.py writes the coded output by "
                         "default); the leg the sandbox cannot stand in for")
    ap.add_argument("--service-user", default="root",
                    help="the user the decider cron runs as (openclaw isolated command crons run inside the gateway, "
                         "root on node-8); the host probe fails if it is not running as this user")
    args = ap.parse_args()

    t = Transcript(Path(args.record) if args.record else None)
    tree = Path(args.tree).resolve()
    decide_py = tree / "scripts" / "credit_review" / "decide.py"
    if args.fixture:
        fixture_path = Path(args.fixture).resolve()
    else:
        in_tree = tree / "scripts" / "credit_review" / "fixtures" / DEFAULT_FIXTURE.name
        fixture_path = in_tree if in_tree.is_file() else DEFAULT_FIXTURE.resolve()
    if not fixture_path.is_file():
        t.say(f"REFUSED: fixture {fixture_path} does not exist; the proof needs its one named fixture. Nothing ran.")
        t.flush()
        return 2
    box = Path(tempfile.mkdtemp(prefix="coded-invalidation-proof-"))
    rc = 2
    try:
        rc = prove(t, tree, decide_py, fixture_path, box, with_failed=args.with_failed_refresh,
                   host_probe_dir=args.host_probe, service_user=args.service_user)
    except Exception:  # noqa: BLE001 - the proof itself failing to run is reported, never hidden
        t.say("")
        t.say("PROOF COULD NOT RUN - exception escaped:")
        for line in traceback.format_exc().rstrip().splitlines():
            t.say("    " + line)
        t.say("PROOF: FAIL (exception; nothing is proved, no switch may be removed)")
        rc = 2
    finally:
        shutil.rmtree(box, ignore_errors=True)
        t.flush()
        if t.record is not None:
            print(f"transcript recorded at {t.record}", flush=True)
    return rc


def default_coded_out(src: str) -> Path | None:
    """The path the tree's decide.py writes the coded output to when CV_CODED_DECIDER_OUT is unset - read from the
    source, because this proof sets that variable before the import."""
    m = re.search(r'CODED_DECIDER_OUT\s*=\s*Path\(\s*os\.environ\.get\(\s*"CV_CODED_DECIDER_OUT"\s*,\s*"([^"]+)"', src)
    return Path(m.group(1)) if m else None


def host_probe(t: Transcript, decide: Any, live: Path, probe_dir: Path, service_user: str) -> None:
    """The writer's ladder, as this user, on probe-named files in the live directory. Read-only on the live document."""
    import pwd
    t.say("")
    t.say(f"── HOST PROBE: the writer's ladder as uid {os.geteuid()} on probe-named files in {probe_dir} ──")
    t.say("  (the sandbox runs above prove the mechanism; this leg measures the real directory's permissions for the "
          "real user, which is what armed the hold on 2026-11-05. The live document is read, never written.)")
    me = pwd.getpwuid(os.geteuid()).pw_name
    t.check(me == service_user, f"host probe runs as the decider's service user ({service_user})",
            f"euid={os.geteuid()} ({me}); pass --service-user if the cron runs as someone else")
    t.check(probe_dir.is_dir(), "the live output directory exists", f"dir={probe_dir} is_dir={probe_dir.is_dir()}")
    if not probe_dir.is_dir():
        return
    st_dir = probe_dir.stat()
    dir_ok = os.access(probe_dir, os.W_OK | os.X_OK)
    t.say(f"  dir: owner uid={st_dir.st_uid} mode={oct(st_dir.st_mode & 0o7777)}  access(W_OK|X_OK)={dir_ok}")
    t.check(dir_ok, "this user may create, replace and unlink entries in the live directory (rungs 1 and 3)",
            f"access={dir_ok}")
    if live.exists():
        st = live.stat()
        t.say(f"  live document {live}: owner uid={st.st_uid} mode={oct(st.st_mode & 0o7777)} size={st.st_size} "
              f"access(W_OK)={os.access(live, os.W_OK)}  (read only; its bytes are not touched)")
        t.check(os.access(live, os.W_OK), "this user may write THROUGH the live document (rung 2 of the ladder)",
                f"access(W_OK)={os.access(live, os.W_OK)} owner uid={st.st_uid} euid={os.geteuid()}")
    else:
        t.say(f"  live document {live}: absent (the first run will create it; creation is probed below)")
    stamp = f"{utc_now().replace(':', '')}-{os.getpid()}"
    probe = probe_dir / f".coded-invalidation-probe-{stamp}.json"
    tmp = probe_dir / f".coded-invalidation-probe-{stamp}.tmp"
    if probe.resolve() == live.resolve() or tmp.resolve() == live.resolve():
        t.check(False, "the probe path is not the live document", f"probe={probe} live={live}")
        return

    def step(what: str, fn: Callable[[], Any]) -> Any:
        try:
            out = fn()
        except OSError as exc:
            t.check(False, f"host probe: {what}", f"{type(exc).__name__}: {exc}")
            return None
        t.check(True, f"host probe: {what}", "ok")
        return out

    def create() -> None:
        tmp.write_text(json.dumps({"probe": stamp, "run_id": "probe", "executable": False}))
        os.replace(tmp, probe)

    def refresh() -> None:
        tmp.write_text(json.dumps({"probe": stamp, "run_id": "probe-2", "executable": False}))
        os.replace(tmp, probe)

    try:
        step("create by tmp + atomic replace (rung 1, first write)", create)
        step("refresh by tmp + atomic replace over the existing file (rung 1, every later run)", refresh)
        rung = step("invalidate with the tree's own _invalidate_coded_output (the ladder)",
                    lambda: decide._invalidate_coded_output(probe, "host probe"))
        t.check(rung in ("replace", "inplace", "unlink"),
                "the ladder reports the rung that worked (empty = every rung failed = the 2026-11-05 shape)",
                f"rung={rung!r}")
        if probe.exists():
            stub = json.loads(probe.read_text(encoding="utf-8"))
            t.check(stub.get("stale") is True and stub.get("executable") is False,
                    "the invalidation stub on the probe is stale and not executable",
                    f"stale={stub.get('stale')} executable={stub.get('executable')}")
            step("unlink the probe (rung 3)", probe.unlink)
    finally:
        for p in (tmp, probe):
            try:
                p.unlink()
            except FileNotFoundError:
                pass
            except OSError as exc:
                t.check(False, f"host probe cleanup: {p}", f"{type(exc).__name__}: {exc}")
        left = sorted(p.name for p in probe_dir.iterdir() if p.name.startswith(".coded-invalidation-probe-"))
        t.check(not left, "no probe file left in the live directory", f"left={left}")


def prove(t: Transcript, tree: Path, decide_py: Path, fixture_path: Path, box: Path, *, with_failed: bool,
          host_probe_dir: str | None = None, service_user: str = "root") -> int:
    t.say("=" * 100)
    t.say("CODED-DECIDER INVALIDATION PROOF (run twice; the second invalidates the first; no Errno 13)")
    t.say(f"started {utc_now()}  host={os.uname().nodename}  uid={os.getuid()}  python={sys.version.split()[0]}")
    t.say(f"tree under proof: {tree}")
    t.say(f"sandbox: {box}  (every host path decide.py knows is redirected here; nothing under /etc/hydra or "
          f"/var/lib/hydra is read or written by decide.py in this proof; outside the sandbox this script writes "
          f"the transcript at --record"
          f"{' and, for the host probe, probe-named files beside the live document that it deletes again' if host_probe_dir is not None else ''})")
    t.say(f"fixture: {fixture_path}")
    t.say("=" * 100)

    if not decide_py.is_file():
        t.say(f"PROOF: FAIL - no decider at {decide_py}")
        return 2
    deployed_sha = (tree / ".deployed-sha")
    if deployed_sha.is_file():
        t.say(f"tree .deployed-sha: {deployed_sha.read_text().strip()}")
    src = decide_py.read_text(encoding="utf-8")
    for needed in ("CODED_DECIDER_OUT", "def decide_coded_current(", "def _invalidate_coded_output(",
                   "def coded_output_is_current(", "CODED_OUTCOME_KEY"):
        if needed not in src:
            t.say(f"PROOF: FAIL - {decide_py} does not carry `{needed}`; the mechanism under proof is not on this tree")
            return 2
    t.say(f"decide.py sha256: {sha256(decide_py)}  (carries CODED_DECIDER_OUT, decide_coded_current, "
          f"_invalidate_coded_output, coded_output_is_current, CODED_OUTCOME_KEY)")

    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    rows = fixture.get("rows")
    if not isinstance(rows, list) or not rows:
        t.say("PROOF: FAIL - the fixture has no `rows`")
        return 2
    t.say(f"fixture rows: {len(rows)}  ids: {[r.get('id') for r in rows]}")

    # ── sandbox every host path BEFORE the import ────────────────────────────────────────────────────────────
    (box / "etc").mkdir(parents=True)
    (box / "credit-verify").mkdir(parents=True)
    env = sandbox_env(box)
    os.environ.update(env)
    (box / "credit-approval-automation.json").write_text(json.dumps({"automations": {}}))
    sys.path.insert(0, str(tree / "scripts"))
    for mod in [m for m in list(sys.modules) if m == "credit_review" or m.startswith("credit_review.")]:
        del sys.modules[mod]
    from credit_review import decide  # noqa: E402  (after the environment is sandboxed)
    from credit_review import runner  # noqa: E402
    from credit_review.ledger import Ledger  # noqa: E402

    decide.REARM_SENTINEL_FALLBACK = box / "credit-trust-decide.rearm-failed"
    decide.REGISTRY = box / "credit-approval-automation.json"
    host_paths = {
        "CODED_DECIDER_OUT": decide.CODED_DECIDER_OUT, "KILL_SWITCH": decide.KILL_SWITCH,
        "JUDGE_KILL_SWITCH": decide.JUDGE_KILL_SWITCH, "DOC_APPROVE_KILL": decide.DOC_APPROVE_KILL,
        "APPROVE_SWITCH": decide.APPROVE_SWITCH, "PROVISIONAL_PAID_SWITCH": decide.PROVISIONAL_PAID_SWITCH,
        "WRITE_LOCK": decide.WRITE_LOCK, "PAYING_USERS_FILE": decide.PAYING_USERS_FILE,
        "PROOF_ON_FILE": decide.PROOF_ON_FILE, "STAGE2_STORE": decide.STAGE2_STORE,
        "DOC_STORE": decide.DOC_STORE, "DOC_PROOF_STORE": decide.DOC_PROOF_STORE,
        "DOC_APPROVE_FREEZE": decide.doc_approve.FREEZE_PATH,
        "CREDIT_REVIEW_LEDGER": Path(os.environ.get("CREDIT_REVIEW_LEDGER",
                                                   "/var/lib/hydra/credit-review/ledger.sqlite3")),
        "REARM_SENTINEL_FALLBACK": decide.REARM_SENTINEL_FALLBACK, "REGISTRY": Path(decide.REGISTRY),
        "run log": Path(runner.LOG_PATH),
    }
    t.say("")
    t.say("sandbox map (each must resolve inside the sandbox, or the proof refuses to start):")
    leaked = []
    for name, p in host_paths.items():
        inside = str(Path(p).resolve()).startswith(str(box.resolve()))
        t.say(f"  {name:24s} -> {p}   {'(sandboxed)' if inside else '!! OUTSIDE THE SANDBOX'}")
        if not inside or str(p).startswith(FORBIDDEN_PREFIXES):
            leaked.append(name)
    if leaked:
        t.say(f"PROOF: FAIL - refusing to run: {leaked} would touch the host")
        return 2

    ledger = Ledger(str(box / "ledger.sqlite3"))
    db = ledger.db
    decide.ensure_schema(db)
    out_path = decide.CODED_DECIDER_OUT
    policy = decide.Policy.load()

    logged: list[str] = []
    real_log = decide.log

    def capture_log(msg: str) -> bool:
        logged.append(msg)
        return real_log(msg)
    decide.log = capture_log

    def coded_current() -> tuple[int, str]:
        said: list[str] = []
        rc = decide.decide_coded_current(db, path=out_path, out=said.append)
        return rc, " | ".join(said)

    def record() -> dict[str, Any]:
        row = db.execute("SELECT v FROM state WHERE k = ?", (decide.CODED_OUTCOME_KEY,)).fetchone()
        return json.loads(row[0]) if row else {}

    def read_doc() -> dict[str, Any]:
        return json.loads(out_path.read_text(encoding="utf-8"))

    def run_once(label: str) -> Any:
        t.say("")
        t.say(f"── {label}: decide.run(mode='judge', rows=<fixture>) at {utc_now()} ──")
        before = len(logged)
        res = decide.run(NoAdmin(), db, None, mode="judge", policy=policy, rows=list(rows))
        t.say(f"  run_id={res.run_id} mode={res.mode} scanned={res.scanned} approved={res.approved} "
              f"support={res.support} errors={res.errors} write_errors={res.write_errors} "
              f"never_lower_refusals={res.never_lower_refusals} coded_out={res.coded_out!r}")
        t.say(f"  note: {res.note!r}")
        for line in logged[before:]:
            t.say(f"  log: {line}")
        return res

    def observe_fresh(label: str, res: Any) -> tuple[dict[str, Any], dict[str, Any], str]:
        doc = read_doc()
        rec = record()
        digest = sha256(out_path)
        rc, said = coded_current()
        t.say(f"  document on disk: run_id={doc.get('run_id')} mode={doc.get('mode')} executable={doc.get('executable')} "
              f"stale={doc.get('stale')} counts={doc.get('counts')} written_at={doc.get('written_at')}")
        t.say(f"  ledger record {decide.CODED_OUTCOME_KEY}: {json.dumps(rec, sort_keys=True)}")
        t.say(f"  sha256(document) = {digest}")
        t.say(f"  decide_coded_current -> rc={rc}: {said}")
        t.check(res.mode == "judge" and res.scanned == len(rows), f"{label}: the run scanned the fixture in judge mode",
                f"mode={res.mode} scanned={res.scanned}")
        t.check(not res.write_errors, f"{label}: no write error", f"write_errors={res.write_errors}")
        t.check(res.coded_out == str(out_path), f"{label}: the run reports the coded output it wrote",
                f"coded_out={res.coded_out!r}")
        t.check(doc.get("run_id") == res.run_id, f"{label}: the document on disk is THIS run's",
                f"doc.run_id={doc.get('run_id')} res.run_id={res.run_id}")
        t.check(doc.get("executable") is False and not doc.get("stale"),
                f"{label}: a judge document is fresh and not executable (a measurement, not a licence)",
                f"executable={doc.get('executable')} stale={doc.get('stale')}")
        t.check(doc.get("counts", {}).get("total") == len(rows) and doc.get("counts", {}).get("hold") == len(rows),
                f"{label}: the fixture row was HELD by the validator reject rule (no catalog, no model)",
                f"counts={doc.get('counts')} decisions={[ (d.get('request_id'), d.get('decision'), d.get('reason')) for d in doc.get('decisions', [])]}")
        t.check(rec.get("run_id") == res.run_id and rec.get("fresh") is True and rec.get("sha256") == digest,
                f"{label}: the ledger record says fresh, for this run, with these bytes",
                f"record.run_id={rec.get('run_id')} fresh={rec.get('fresh')} sha_match={rec.get('sha256') == digest}")
        t.check(rc == 0 and said.startswith("CURRENT") and f"run {res.run_id} " in said,
                f"{label}: decide_coded_current says CURRENT for this run", f"rc={rc} line={said!r}")
        return doc, rec, digest

    # ── run 1 ────────────────────────────────────────────────────────────────────────────────────────────────
    res1 = run_once("RUN 1")
    doc1, rec1, sha1 = observe_fresh("run 1", res1)
    bytes1 = out_path.read_bytes()
    time.sleep(1.1)  # the run_id prefix is second-resolution; the uuid suffix already differs, this keeps written_at distinct too

    # ── run 2 ────────────────────────────────────────────────────────────────────────────────────────────────
    res2 = run_once("RUN 2")
    doc2, rec2, sha2 = observe_fresh("run 2", res2)
    bytes2 = out_path.read_bytes()

    t.say("")
    t.say("── does run 2 INVALIDATE run 1? (asserted from the output, not from the code) ──")
    t.check(res2.run_id != res1.run_id, "run 2 is a different run from run 1", f"R1={res1.run_id} R2={res2.run_id}")
    t.check(doc2.get("run_id") == res2.run_id and doc2.get("run_id") != doc1.get("run_id"),
            "the document on disk now carries run 2's id, not run 1's",
            f"disk.run_id={doc2.get('run_id')} R1={doc1.get('run_id')}")
    t.check(rec2.get("run_id") == res2.run_id and rec2.get("sha256") != sha1,
            "the ledger record now names run 2 and no longer the bytes run 1 wrote",
            f"record.run_id={rec2.get('run_id')} record.sha256={rec2.get('sha256')[:16]}... sha(run1)={sha1[:16]}...")
    # The decisive observation: put run 1's exact bytes back on the path (sandbox) and ask the consumer.
    out_path.write_bytes(bytes1)
    rc_back, said_back = coded_current()
    t.say(f"  run 1's exact bytes restored on the path; decide_coded_current -> rc={rc_back}: {said_back}")
    t.check(rc_back == 3 and said_back.startswith("NOT CURRENT"),
            "run 1's document, put back on disk, is REFUSED as NOT CURRENT against run 2's record (invalidated)",
            f"rc={rc_back} line={said_back!r}")
    t.check("stale artifact" in said_back or "not the bytes the run recorded" in said_back,
            "the refusal names the reason: the bytes are not the ones run 2 recorded",
            f"line={said_back!r}")
    out_path.write_bytes(bytes2)
    rc_fwd, said_fwd = coded_current()
    t.say(f"  run 2's bytes restored; decide_coded_current -> rc={rc_fwd}: {said_fwd}")
    t.check(rc_fwd == 0 and said_fwd.startswith("CURRENT") and f"run {res2.run_id} " in said_fwd,
            "run 2's own document reads CURRENT again", f"rc={rc_fwd} line={said_fwd!r}")
    leftovers = sorted(p.name for p in out_path.parent.iterdir() if ".tmp" in p.name or ".invalid" in p.name)
    t.check(not leftovers, "no temp or invalidation stub left beside the output", f"leftovers={leftovers}")

    # ── no Errno 13, anywhere, from runs 1 and 2 ────────────────────────────────────────────────────────────
    t.say("")
    t.say("── no Errno 13 (runs 1 and 2) ──")
    haystack: list[tuple[str, str]] = [(f"log[{i}]", m) for i, m in enumerate(logged)]
    haystack += [(f"run1.write_errors[{i}]", e) for i, e in enumerate(res1.write_errors)]
    haystack += [(f"run2.write_errors[{i}]", e) for i, e in enumerate(res2.write_errors)]
    haystack += [("run1.note", res1.note), ("run2.note", res2.note)]
    haystack += [("doc1", json.dumps(doc1)), ("doc2", json.dumps(doc2)),
                 ("record1", json.dumps(rec1)), ("record2", json.dumps(rec2))]
    run_log = Path(runner.LOG_PATH)
    if run_log.is_file():
        haystack += [(f"run.log[{i}]", line) for i, line in enumerate(run_log.read_text(encoding="utf-8").splitlines())]
    hits = [(where, text[:200]) for where, text in haystack if any(m in text for m in ERRNO13_MARKERS)]
    t.check(not hits, f"no {ERRNO13_MARKERS} in {len(haystack)} log lines / write errors / notes / documents / records",
            f"hits={hits}")
    t.check(not decide.KILL_SWITCH.exists(), "the (sandboxed) writer kill switch was NOT re-armed by either run",
            f"exists={decide.KILL_SWITCH.exists()} path={decide.KILL_SWITCH}")
    t.check(not decide.REARM_SENTINEL_FALLBACK.exists(), "no failed-re-arm sentinel was written",
            f"exists={decide.REARM_SENTINEL_FALLBACK.exists()}")

    # ── optional: an INJECTED Errno 13 on the refresh must be contained ─────────────────────────────────────
    if with_failed:
        t.say("")
        t.say("── RUN 3 (optional leg): the refresh FAILS with an INJECTED [Errno 13] on os.replace - the exact error "
              "that armed /etc/hydra/credit-trust-decide.disabled on 2026-11-05 - and must be CONTAINED ──")
        t.say("  (the Errno 13 below is injected by this proof on purpose; the assertion is that the invalidation "
              "ladder handles it, not that it is absent)")
        real_replace = os.replace
        injected: list[str] = []

        def failing_replace(src: Any, dst: Any, *a: Any, **kw: Any) -> None:
            if Path(dst) == out_path:
                injected.append(f"{src} -> {dst}")
                raise PermissionError(13, "Permission denied", str(dst))
            return real_replace(src, dst, *a, **kw)
        os.replace = failing_replace  # type: ignore[assignment]
        try:
            res3 = run_once("RUN 3 (injected failure)")
        finally:
            os.replace = real_replace  # type: ignore[assignment]
        doc3 = read_doc()
        rec3 = record()
        rc3, said3 = coded_current()
        t.say(f"  injected on: {injected}")
        t.say(f"  document on disk: stale={doc3.get('stale')} executable={doc3.get('executable')} "
              f"invalidated_because={doc3.get('invalidated_because')!r}")
        t.say(f"  ledger record: {json.dumps(rec3, sort_keys=True)}")
        t.say(f"  decide_coded_current -> rc={rc3}: {said3}")
        t.check(len(injected) >= 1, "the injected Errno 13 fired on the coded output's replace", f"injected={injected}")
        t.check(any("could not be written" in e for e in res3.write_errors),
                "run 3 booked the failed refresh as a write error (never raised)", f"write_errors={res3.write_errors}")
        t.check(doc3.get("stale") is True and doc3.get("executable") is False,
                "the previous document was INVALIDATED on disk (stale stub, not executable)",
                f"stale={doc3.get('stale')} executable={doc3.get('executable')} run_id={doc3.get('run_id')}")
        t.check(rec3.get("run_id") == res3.run_id and rec3.get("fresh") is False and rec3.get("survived") is False
                and rec3.get("invalidated_by") in ("inplace", "unlink"),
                "the ledger record says NOT fresh, invalidated by a lower rung, nothing survived",
                f"fresh={rec3.get('fresh')} survived={rec3.get('survived')} invalidated_by={rec3.get('invalidated_by')!r}")
        t.check(rc3 == 3 and said3.startswith("NOT CURRENT"),
                "decide_coded_current refuses the survivor as NOT CURRENT", f"rc={rc3} line={said3!r}")
        t.check(not decide.KILL_SWITCH.exists(),
                "the (sandboxed) kill switch was NOT re-armed: invalidation succeeded, so no previous permission survives",
                f"exists={decide.KILL_SWITCH.exists()}")
        t.check(not any("could NOT be invalidated" in e for e in res3.write_errors),
                "no 'could NOT be invalidated' refusal (that is the 2026-11-05 shape; it must not recur here)",
                f"write_errors={res3.write_errors}")

    # ── optional: the HOST leg - the real directory's permissions for the real user ──
    probed = ""
    if host_probe_dir is not None:
        live = default_coded_out(src)
        if live is None:
            t.check(False, "host probe: the tree's default CODED_DECIDER_OUT can be read from decide.py",
                    "no `CODED_DECIDER_OUT = Path(os.environ.get(\"CV_CODED_DECIDER_OUT\", \"...\"))` in the source")
        else:
            probe_dir = Path(host_probe_dir).resolve() if host_probe_dir else live.parent
            live_here = live if not host_probe_dir else probe_dir / live.name
            t.say("")
            t.say(f"tree default CODED_DECIDER_OUT: {live}  (probing {probe_dir}, live document {live_here})")
            host_probe(t, decide, live_here, probe_dir, service_user)
            probed = f"host probe in {probe_dir} as uid {os.geteuid()}: "

    # ── verdict ──────────────────────────────────────────────────────────────────────────────────────────────
    t.say("")
    t.say("=" * 100)
    t.say(f"host switches untouched by construction: every path above is under {box}; this proof has no code path "
          f"that removes, creates or edits a switch"
          f"{' (the host probe wrote and deleted probe-named files beside the live document)' if probed else ''}")
    if t.failures:
        t.say(f"PROOF: FAIL - {len(t.failures)} assertion(s) did not hold:")
        for f in t.failures:
            t.say(f"  - {f}")
        t.say("NO switch may be removed on this evidence.")
        return 1
    t.say(f"PROOF: PASS - run twice (R1={res1.run_id}, R2={res2.run_id}); the second invalidates the first; "
          f"no Errno 13; {probed + 'PASS' if probed else 'host probe NOT run'}.  finished {utc_now()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
