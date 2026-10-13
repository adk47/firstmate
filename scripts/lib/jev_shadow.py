#!/usr/bin/env python3
"""Shared subprocess wrapper around scripts/lib/jev.sh for Python callers.

Five Phase-2a support-timer scripts (cs-needs-human-digest.py,
close-resolved-conversations.py, resolve-notify.py,
close-duplicate-conversations.py, resolution-matcher.py) each need the same
thing: fire one shadow-only Jev judgment call AFTER their own deterministic
decision for an item, and let it affect NOTHING about that decision. This
module is the one place that logic lives.

Hard contract (all five callers depend on this, so it is enforced here, not
re-implemented five times):
  - shadow_judge() NEVER raises. Any failure (missing jev.sh, bad JSON,
    subprocess error, a build_state callable raising, anything) is caught,
    logged to stderr, and answered with None. `state` may be a zero-arg
    callable so that BUILDING it (e.g. an extra GET for message text) also
    runs inside this boundary, not in the caller before shadow_judge is
    even entered — see shadow_judge()'s docstring.
  - shadow_judge() NEVER writes to stdout. Several callers use stdout as a
    machine-readable channel (e.g. resolution-matcher.py's per-item JSON
    line), so any diagnostic goes to stderr only — mirroring jev.sh's own
    "humans on stderr" contract.
  - Every call is wall-clock bounded (`timeout_s`, default DEFAULT_TIMEOUT_S)
    via subprocess.run(timeout=...); a hang past that budget is treated
    exactly like any other failure — logged, returns None, never blocks the
    caller's own timer past its own budget.
  - A per-process call budget (JEV_SHADOW_MAX_CALLS, default
    DEFAULT_MAX_CALLS) bounds how many shadow calls one process makes, so a
    large batch (e.g. cs-needs-human-digest.py's open-conversation backlog)
    cannot add unbounded latency. Calls past the budget are skipped (counted,
    not attempted) with one summary line on stderr the first time the budget
    is hit, and a final summary at process exit if anything was skipped.

jev.sh itself is located from JEV_SH (env override, used by tests) or
relative to this file (../lib/jev.sh) by default.
"""
import atexit
import json
import os
import subprocess
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
_JEV_SH_DEFAULT = os.path.join(_HERE, "jev.sh")

# Default call budget. Each Phase-2a caller shadow-judges a bounded slice,
# never the raw backlog:
#   cs-needs-human-digest.py     CS_DIGEST_JEV_SAMPLE_SIZE default 25 (random
#                                 sample of the needs_human bucket, never the
#                                 rendered/ranked head -- see the script's own
#                                 header for why the head would bias the read)
#   close-resolved-conversations.py  CLOSE_RESOLVED_JEV_SAMPLE_SIZE default 25
#                                 (random sample of the full open-conversation
#                                 scan, not just the eligible-to-close slice)
#   resolve-notify.py            RESOLVE_NOTIFY_MAX default 25 (per-run cap)
#   close-duplicate-conversations.py  DUP_CEILING 20 (candidate ceiling)
#   resolution-matcher.py        RESOLUTION_MATCHER_MAX default 15 (act cap)
# 25 covers every one of those with headroom, without being large enough to
# let a mis-scoped caller turn a shadow call into an unbounded per-run cost.
DEFAULT_MAX_CALLS = 25
DEFAULT_TIMEOUT_S = 5

_call_count = 0
_skip_count = 0
_budget_warned = False
_atexit_registered = False


def _jev_sh():
    return os.environ.get("JEV_SH", _JEV_SH_DEFAULT)


def _max_calls():
    raw = os.environ.get("JEV_SHADOW_MAX_CALLS")
    if not raw:
        return DEFAULT_MAX_CALLS
    try:
        n = int(raw)
    except ValueError:
        return DEFAULT_MAX_CALLS
    return n if n > 0 else DEFAULT_MAX_CALLS


def _print_exit_summary():
    # Only fires if at least one call was skipped this process — a quiet
    # process (budget never hit) prints nothing extra at exit.
    if _skip_count > 0:
        print(f"jev_shadow: {_call_count} call(s) made, {_skip_count} "
              f"skipped this process (JEV_SHADOW_MAX_CALLS={_max_calls()})",
              file=sys.stderr)


def _ensure_atexit():
    global _atexit_registered
    if not _atexit_registered:
        atexit.register(_print_exit_summary)
        _atexit_registered = True


def shadow_judge(surface, item_id, state, questions, actual=None, timeout_s=None):
    """Fire one shadow Jev judgment. Returns the `answers` dict on rc 0,
    else None (failure, timeout, disabled, budget exhausted, or a
    build_state failure).

    Callers MUST treat the return value as informational only — Phase 2a is
    shadow-only, so nothing about the caller's own decision may depend on
    this call's outcome, and the call must happen strictly AFTER the
    caller's own decision is already made.

    `state` is either a plain JSON-able dict, OR a zero-arg callable
    (`build_state`) that RETURNS one. Pass a callable whenever building the
    state costs anything that can fail on its own (an extra network GET, a
    dict lookup on possibly-malformed data, ...) — the whole point of this
    module is a never-raise boundary around a Jev call, and a caller that
    builds its own state as an ARGUMENT (evaluated before shadow_judge is
    even entered) builds it OUTSIDE that boundary, defeating it. A
    build_state that raises is treated exactly like any other shadow
    failure: logged to stderr, returns None, and (since the exception fires
    after the budget slot is claimed below) counts against the call budget
    the same as a real call would.
    """
    global _call_count, _skip_count, _budget_warned
    try:
        _ensure_atexit()
        cap = _max_calls()
        if _call_count >= cap:
            _skip_count += 1
            if not _budget_warned:
                print(f"jev_shadow: JEV_SHADOW_MAX_CALLS ({cap}) reached — "
                      f"further shadow calls this process are skipped",
                      file=sys.stderr)
                _budget_warned = True
            return None
        _call_count += 1

        if callable(state):
            try:
                state = state()
            except Exception as e:  # noqa: BLE001 — never-raise boundary covers build_state too
                print(f"jev_shadow: build_state raised for surface={surface} "
                      f"item={item_id}: {type(e).__name__}: {e}", file=sys.stderr)
                return None
            if state is None:
                # build_state legitimately found nothing to judge (e.g. no
                # customer message part exists at all) — not a failure, so
                # no diagnostic line, but the budget slot claimed above still
                # stands (the GET/lookup it took to find out already ran).
                return None

        jev_sh = _jev_sh()
        if not os.path.isfile(jev_sh):
            print(f"jev_shadow: WARN jev.sh not found at {jev_sh} "
                  f"(surface={surface} item={item_id})", file=sys.stderr)
            return None

        wall_s = timeout_s if timeout_s is not None else DEFAULT_TIMEOUT_S

        with tempfile.TemporaryDirectory(prefix="jev-shadow-") as d:
            state_path = os.path.join(d, "state.json")
            questions_path = os.path.join(d, "questions.json")
            with open(state_path, "w") as f:
                json.dump(state, f)
            with open(questions_path, "w") as f:
                json.dump(questions, f)

            cmd = [jev_sh, "--surface", surface, "--item-id", str(item_id),
                   "--state-file", state_path, "--questions-file", questions_path]
            if actual is not None:
                actual_arg = actual if isinstance(actual, str) else json.dumps(actual)
                cmd += ["--actual", actual_arg]

            try:
                proc = subprocess.run(cmd, capture_output=True, text=True,
                                       timeout=wall_s)
            except subprocess.TimeoutExpired:
                print(f"jev_shadow: surface={surface} item={item_id} timed "
                      f"out after {wall_s}s", file=sys.stderr)
                return None
            except OSError as e:
                print(f"jev_shadow: surface={surface} item={item_id} could "
                      f"not run {jev_sh}: {type(e).__name__}: {e}",
                      file=sys.stderr)
                return None

            if proc.returncode != 0:
                detail = (proc.stderr or "").strip()[:200]
                print(f"jev_shadow: surface={surface} item={item_id} rc="
                      f"{proc.returncode}{': ' + detail if detail else ''}",
                      file=sys.stderr)
                return None

            try:
                answers = json.loads(proc.stdout)
            except ValueError:
                print(f"jev_shadow: surface={surface} item={item_id} "
                      f"produced non-JSON stdout", file=sys.stderr)
                return None
            if not isinstance(answers, dict):
                print(f"jev_shadow: surface={surface} item={item_id} "
                      f"answers was not an object", file=sys.stderr)
                return None
            return answers
    except Exception as e:  # noqa: BLE001 — the never-raise contract is load-bearing
        print(f"jev_shadow: unexpected error surface={surface} item={item_id}: "
              f"{type(e).__name__}: {e}", file=sys.stderr)
        return None
