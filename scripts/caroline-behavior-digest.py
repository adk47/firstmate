#!/usr/bin/env python3
"""Daily digest of Caroline's autonomous self-serve behavior, so we can SEE how
she behaves with real users and iterate.

Caroline went 100% autonomous on the three self-serve WRITE verbs
(profiles_claim_self / credits_verify / profiles_consolidate) plus the proactive
resolve/overdue notifiers and the auto-close loop. Nothing trended what those
autonomous actions actually DID with customers. This read-only digest answers
"is autonomy working" once a day.

It joins TWO complementary, verified audit layers:

  1. /var/log/muso-ops/tier2-audit.jsonl -- the muso-cli capability gate's own
     decision log ({ts, env, actor_identity, tool, params, decision, result};
     decision vocab from muso-cli internal/policy/capability/audit.go v0.6.1:
     authorized -> applied | gate_refused; refused (route_to_human); noop
     (idempotent); dry_run (preview); shadow_would_merge/shadow_would_refuse
     (rename-merge shadow lane, informational)). This is the AUTHORITATIVE per-verb OUTCOME
     for calls that reached muso. It does NOT carry an Intercom conv-id, and it
     never sees a wrapper-side fail-close (the call never reached muso).
  2. /var/log/openclaw/customer-{credit-verify,profile-claim,profile-consolidate}.jsonl
     -- the hydra verb-WRAPPER audit ({ts, tool, mode, status, muso_exit,
     actor_identity, intercom_conv_id, ...}). It DOES carry intercom_conv_id (so
     reopen-after-self-serve is derivable) and the wrapper-side fail-close
     statuses (refused_no_approver / refused_no_requester / refused_no_muso)
     that never reach muso -- the misconfig signal. (The OPS_DRY_RUN kill switch
     is NOT audited: the wrappers _emit_error + exit BEFORE _audit, so no record
     exists -- the digest detects it directly from its own OPS_DRY_RUN env, which
     the systemd unit loads from edge.env, instead.)

Surfaces:
  * Per-verb OUTCOMES (24h) for REAL customers from the capability audit: success
    (applied/noop) vs route_to_human (refused) vs backend-refused (gate_refused).
    Smoke/test actors (go-live probes: smoketest@, not-the-owner@) are excluded
    from the displayed counts -- they are not customer service -- but are still
    fed to the anomaly checks. A climbing route_to_human% means Caroline keeps
    reaching for a verb she can't complete (retrain / retune the gate); a climbing
    backend-refused% means a backend break.
  * UVN credit verification (the credits_verify verb): how many credits Caroline
    AUTONOMOUSLY APPROVED vs routed to a human, 7d + all-time, real customers.
    (routed = the verb refused and handed off; it is NOT the same as 'asked the
    customer for more proof', a conversational step with no counter.)
  * ROUTE RECONCILIATION (7d, --post only): of the credits Caroline ROUTED to a
    human, how many a human LATER approved (recoverable IF catalog corroboration
    were broadened -- NOT proof she was wrong), how many are still pending, how many
    were withdrawn/reverted. This is the false-refusal audit the autonomy-improver
    requires before broadening the gate: it says whether the route rate is losing
    autonomy or protecting integrity. Looks up each routed request's CURRENT status
    through the read-only muso-read admin GET (no new credential); bounded, per-
    profile fail-soft. Skipped (rendered "not checked") in --check mode.
  * WHY she routed/refused: the top distinct `result` reasons.
  * REOPEN-AFTER-AUTO-CLOSE (7d): of conversations the auto-close loop silently
    closed, how many the customer replied to afterwards -- the quality signal on
    the dominant autonomous action (a premature/contested close). From the
    close-resolved shadow log (it carries the conv-id + closed_at).
  * REOPEN-AFTER-SELF-SERVE (7d): of conversations where Caroline APPLIED a verb,
    how many the customer replied to afterwards -- the strongest "was the write
    actually right" signal. From the wrapper audit (it carries the conv-id).
  * REOPEN-AFTER-DONE (7d): same, for conversations that got the resolve-notify
    "your request is sorted" note. Driven off the resolve-notify SEND LOG (the
    authoritative "a note actually went out" record), NOT notified.json -- whose
    conv:<id> keys also include cold-start seeds + dedupe suppressions that sent
    nothing and would deflate the rate.
  * OPS-RELIEF headline (dominant action first): conversations auto-closed,
    self-serve writes applied (real customers, week-over-week delta), proactive
    notifies sent -- with a clarifier when 0 notifies despite auto-closes, framed
    as the expected post-cold-start / no-new-resolutions state (and to verify
    --apply only if 0 persists), since the telemetry can't prove the notifiers are
    dry-run vs simply quiet.
  * A SAFETY-ANOMALY line. CRITICAL (also paged to #clio_devops with an
    @-mention): the OPS_DRY_RUN kill switch (read directly from env),
    wrapper-side misconfig (approver/requester/muso missing), an
    authorized-without-terminal gap (a crash
    between the cap-counting line and the mutation), an apply-rate above a
    conservative ceiling, or an unrecognized muso-cli decision (schema drift).

STRICTLY READ-ONLY: it READS the telemetry jsonl/logs + (in --post) GETs
Intercom conversations for reopen detection, and WRITES only its own tiny trend
state under /var/lib. It never writes the audit files, never calls muso, never
posts a customer-facing message.

Env:
  MUSOAI_INTERCOM_TOKEN          required for --post (reopen lookups)
  MUSO_OPS_STATE_DIR             optional, default /var/log/muso-ops
  CAROLINE_DIGEST_AUDIT          optional, default <state_dir>/tier2-audit.jsonl
  CAROLINE_DIGEST_WRAPPER_LOGS   optional, ':'-separated; default the three
                                 /var/log/openclaw/customer-*.jsonl verb audits
  RESOLVE_NOTIFY_LOG             optional, default /var/log/resolve-notify.log
  OVERDUE_NOTIFY_LOG             optional, default
                                 /var/log/overdue-verification-notifier.log
  CLOSE_RESOLVED_SHADOW          optional, default
                                 /var/log/close-resolved-shadow.jsonl
                                 (producer env is CLOSE_SHADOW_LOG; default matches)
  CAROLINE_DIGEST_STATE          optional, default
                                 /var/lib/caroline-behavior-digest/state.json
  CAROLINE_DIGEST_CHANNEL        optional, default C0ANM0PN9L5 (#cs_chats)
  CAROLINE_DIGEST_ALERT_CHANNEL  optional, default C0ADV2W76G4 (#clio_devops)
  CAROLINE_DIGEST_PAGE_MENTION   optional, default U0AL36NADEY (Nick), space-sep
  CAROLINE_DIGEST_SLACK_ACCOUNT  optional, default operations
  SLACK_NOTIFY_CONFIG            optional, default /root/.openclaw-main/openclaw.json
  CAROLINE_DIGEST_APPLY_CEILING  optional, default 40 (applies/24h before anomaly)
  CAROLINE_DIGEST_REOPEN_MAX     optional, default 300 (max Intercom GETs/run/source)
  CAROLINE_DIGEST_MUSO_READ      optional, default "muso-read.sh" -- command prefix
                                 (shlex-split) for the read-only muso-read admin GET
                                 used by route reconciliation; the systemd unit pins
                                 the deployed path
  CAROLINE_DIGEST_RECONCILE_MAX  optional, default 60 (max profiles reconciled/run)
  CAROLINE_DIGEST_NOW            optional, epoch override (tests)
  CAROLINE_DIGEST_SKIP_HOST_GUARD optional, "1" to run off ovh-node-8 (tests)

Flags:
  --post        build + post the digest to Slack and write trend state
                (default: --check -- compute + print one JSON line, no Slack,
                no state write, no network)
  --self-test   run the inline classifier self-test and exit

Exit codes: 0 ok; 1 usage/env error; 2 self-test failed; 3 Slack/Intercom API
error during --post.
"""
import argparse
import calendar
import contextlib
import io
import json
import os
import shlex
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

INTERCOM_API = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"
SLACK_API = "https://slack.com/api/chat.postMessage"

DEFAULT_CHANNEL = "C0ANM0PN9L5"        # #cs_chats
DEFAULT_ALERT_CHANNEL = "C0ADV2W76G4"  # #clio_devops
DEFAULT_PAGE_MENTION = "U0AL36NADEY"   # Nick

VERBS = ("profiles_claim_self", "credits_verify", "profiles_consolidate")

# muso-cli capability decision vocabulary (internal/policy/capability/audit.go).
SUCCESS = {"applied", "noop"}       # mutation accepted / idempotent already-done
ROUTED = {"refused"}                # route_to_human: capability check bounced pre-mutation
BACKEND_REFUSED = {"gate_refused"}  # checks passed, the backend itself rejected
PREVIEW = {"dry_run"}               # --dry-run suppressed: excluded from outcome rates
INTERMEDIATE = {"authorized"}       # cap-counting line; terminal is applied/gate_refused
# rename-merge SHADOW lane (audit.go): what the corroboration rule WOULD have done
# for a name-mismatched consolidation. No mutation, routes to a human regardless ->
# informational, excluded from outcome rates (like preview). Registered here so the
# new decision values are recognized and do NOT trip the schema-drift pager.
SHADOW = {"shadow_would_merge", "shadow_would_refuse"}

# Hydra verb-WRAPPER status vocabulary (verify-credit.sh / claim-self.sh /
# consolidate.sh _audit). These are emitted BEFORE the call reaches muso (or on
# the wrapper's interpretation of the result), so they are not in the muso audit.
# Wrapper-side fail-close statuses that ARE persisted (the wrapper _audit's them
# BEFORE _emit_error). ops_dry_run_set is deliberately NOT here: the OPS_DRY_RUN
# path _emit_error's + exits WITHOUT _audit, so it never lands in the wrapper logs
# -- the digest detects that kill switch directly from its own OPS_DRY_RUN env.
WRAPPER_MISCONFIG = {"refused_no_approver", "refused_no_requester", "refused_no_muso"}
WRAPPER_REFUSED = {"refused_route_to_human"}
WRAPPER_ERROR = {"muso_failed"}
WRAPPER_PREVIEW = {"dry_run"}
# A wrapper APPLY-mode record whose status is none of the above carries the raw
# muso success status (e.g. "verified" / "merged") => a real applied write.
# ops_dry_run_set listed explicitly so a (hypothetical) audited kill-switch record
# is never miscounted as a success.
WRAPPER_NONSUCCESS = (WRAPPER_MISCONFIG | WRAPPER_REFUSED | WRAPPER_ERROR
                      | WRAPPER_PREVIEW | {"ops_dry_run_set"})

GRACE = 300  # seconds: an authorized line this fresh may not have its terminal yet
DAY = 86400

DEFAULT_WRAPPER_LOGS = (
    "/var/log/openclaw/customer-credit-verify.jsonl",
    "/var/log/openclaw/customer-profile-claim.jsonl",
    "/var/log/openclaw/customer-profile-consolidate.jsonl",
)


# --------------------------------------------------------------------------
# Network seam (module-level so tests monkeypatch these, never real HTTP).
# --------------------------------------------------------------------------
def http(method, url, headers, body=None, timeout=30, attempts=4):
    """Single urllib wrapper with retry on transient URLErrors."""
    data = None
    hdrs = dict(headers)
    if body is not None:
        hdrs["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    for a in range(attempts):
        try:
            req = urllib.request.Request(url, data=data, method=method)
            for k, v in hdrs.items():
                req.add_header(k, v)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, json.loads(r.read() or b"null")
        except urllib.error.HTTPError:
            raise
        except (urllib.error.URLError, socket.timeout) as e:
            if a == attempts - 1:
                raise RuntimeError(f"{method} {url} failed after {attempts}: {e}")
            time.sleep(2 * (a + 1))


def get_conversation(conv_id, token):
    s, body = http("GET",
                   f"{INTERCOM_API}/conversations/{conv_id}?display_as=plaintext",
                   {"Authorization": f"Bearer {token}", "Accept": "application/json",
                    "Intercom-Version": INTERCOM_VERSION})
    if s != 200:
        raise RuntimeError(f"intercom get conv {conv_id} -> {s}")
    return body


# --------------------------------------------------------------------------
# Pure parsing/classification (directly unit-testable).
# --------------------------------------------------------------------------
def parse_ts(value):
    """Epoch seconds from an ISO8601-Z string or a numeric epoch (s or ms); None
    if unparseable."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return int(value / 1000) if value > 1e12 else int(value)
    s = str(value).strip()
    if not s:
        return None
    try:
        n = float(s)
        return int(n / 1000) if n > 1e12 else int(n)
    except ValueError:
        pass
    # ISO8601 UTC, e.g. 2026-06-25T01:16:09Z. timegm interprets the parsed fields
    # as UTC (mktime would assume LOCAL time + mishandle DST). Everything in scope
    # (capability audit, wrapper audits, send-logs, shadow log) is emitted with Z.
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%d %H:%M:%S"):
        try:
            return calendar.timegm(time.strptime(s, fmt))
        except (ValueError, OverflowError):
            continue
    return None


def classify(decision):
    """Map a muso-cli capability decision to an outcome bucket name."""
    d = str(decision or "")
    if d in SUCCESS:
        return "success"
    if d in ROUTED:
        return "route_to_human"
    if d in BACKEND_REFUSED:
        return "backend_refused"
    if d in PREVIEW:
        return "preview"
    if d in INTERMEDIATE:
        return "authorized"
    if d in SHADOW:
        return "shadow"
    return "unclassified"


def is_test_actor(actor):
    """Synthetic/test identities to exclude from real-customer counts."""
    a = str(actor or "").lower()
    return ("@example.com" in a or a.endswith("@example.org")
            or "not-the-owner" in a or a == "")


def read_jsonl(path):
    """(records, malformed_count). Tolerates a torn final line; missing -> ([],0)."""
    records, malformed = [], 0
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    records.append(json.loads(line))
                except ValueError:
                    malformed += 1
    except (FileNotFoundError, OSError):
        return [], 0
    return records, malformed


def read_sends(path):
    """[(conv_id, ts_epoch)] from a notifier send-log. Each real send is a
    '<ISO ts> sent conv=<id> ...' line (only _log_send writes that exact shape),
    so this is the AUTHORITATIVE 'a note actually went out' record -- unlike
    notified.json, whose conv:<id> keys also include cold-start seeds + dedupe
    suppressions that sent nothing and would deflate the reopen rate."""
    out = []
    try:
        with open(path) as f:
            for line in f:
                if " sent conv=" not in line:
                    continue
                ts = parse_ts(line.split(" ", 1)[0])
                conv = None
                for tok in line.split():
                    if tok.startswith("conv="):
                        conv = tok[len("conv="):]
                        break
                if ts is not None and conv:
                    out.append((conv, ts))
    except (FileNotFoundError, OSError):
        return []
    return out


def capability_records(audit_records):
    """Only the capability-verb records (the {tool} self-serve shape)."""
    return [r for r in audit_records
            if isinstance(r, dict) and r.get("tool") in VERBS]


def summarize(cap_records, now, window):
    """Pure: per-verb outcome counts + reasons + actors + anomaly inputs over the
    trailing `window` seconds ending at `now`, from the muso capability audit."""
    lo = now - window
    per = {v: {"success": 0, "route_to_human": 0, "backend_refused": 0,
               "preview": 0, "authorized": 0, "unclassified": 0, "shadow": 0} for v in VERBS}
    # Same shape, counting ONLY real-customer actors -- the smoke/test actors
    # (go-live probes: smoketest@, not-the-owner@) inflate the verb counts but are
    # not customer service; the DISPLAY uses per_verb_real, anomalies use per_verb.
    per_real = {v: {"success": 0, "route_to_human": 0, "backend_refused": 0,
                    "preview": 0, "authorized": 0, "unclassified": 0, "shadow": 0} for v in VERBS}
    reasons = {}
    reasons_real = {}  # route/refuse reasons for REAL customers only (display)
    real_actors = set()
    test_actors = set()
    unclassified_values = {}
    authorized_graced = 0  # authorized lines old enough that a terminal should exist
    for r in cap_records:
        tool = r.get("tool")
        if tool not in per:
            continue
        ts = parse_ts(r.get("ts"))
        if ts is None or ts < lo or ts >= now + 1:
            continue
        bucket = classify(r.get("decision"))
        per[tool][bucket] += 1
        if not is_test_actor(r.get("actor_identity")):
            per_real[tool][bucket] += 1
        if bucket == "authorized" and ts <= now - GRACE:
            authorized_graced += 1
        if bucket == "unclassified":
            v = str(r.get("decision"))
            unclassified_values[v] = unclassified_values.get(v, 0) + 1
        if bucket in ("route_to_human", "backend_refused"):
            res = str(r.get("result") or "(no detail)").strip()
            reasons[res] = reasons.get(res, 0) + 1
            if not is_test_actor(r.get("actor_identity")):
                reasons_real[res] = reasons_real.get(res, 0) + 1
        # An actor is "served" only on a TERMINAL real outcome -- a preview
        # (dry_run) or the non-terminal authorized cap-line is not service.
        if bucket in ("success", "route_to_human", "backend_refused", "unclassified"):
            actor = r.get("actor_identity")
            (test_actors if is_test_actor(actor) else real_actors).add(str(actor))

    totals = {"success": 0, "route_to_human": 0, "backend_refused": 0,
              "preview": 0, "authorized": 0, "unclassified": 0, "shadow": 0}
    totals_real = {"success": 0, "route_to_human": 0, "backend_refused": 0,
                   "preview": 0, "authorized": 0, "unclassified": 0, "shadow": 0}
    for v in VERBS:
        for k, n in per[v].items():
            totals[k] += n
        for k, n in per_real[v].items():
            totals_real[k] += n
    # Each authorized (cap line) should pair with a terminal applied/gate_refused.
    # Compare only GRACED authorized (>= GRACE old) against ALL in-window
    # terminals, so an in-flight write at digest time isn't a false crash gap.
    terminal_writes = totals["success"] + totals["backend_refused"]
    authorized_without_terminal = max(0, authorized_graced - terminal_writes)
    return {
        "per_verb": per,
        "per_verb_real": per_real,
        "totals": totals,
        "totals_real": totals_real,
        "reasons": reasons,
        "reasons_real": reasons_real,
        "real_actors": sorted(real_actors),
        "test_actors": sorted(test_actors),
        "unclassified_values": unclassified_values,
        "authorized_without_terminal": authorized_without_terminal,
    }


def read_wrapper_audits(paths, now, window):
    """Window-filtered hydra verb-WRAPPER audit records (they carry
    intercom_conv_id + the wrapper-side status). Each kept record gets a parsed
    `_ts`."""
    lo = now - window
    recs = []
    for p in paths:
        rs, _ = read_jsonl(p)
        for r in rs:
            if not isinstance(r, dict):
                continue
            ts = parse_ts(r.get("ts"))
            if ts is None or ts < lo or ts >= now + 1:
                continue
            r = dict(r)
            r["_ts"] = ts
            recs.append(r)
    return recs


def selfserve_reopen_events(wrapper_recs):
    """[(conv_id, applied_ts)] for APPLY-mode wrapper records that SUCCEEDED (the
    status is the raw muso success string -- not a preview/refusal/misconfig/
    error) and carry an intercom_conv_id."""
    events = []
    for r in wrapper_recs:
        if r.get("mode") != "apply":
            continue
        status = str(r.get("status") or "")
        if not status or status in WRAPPER_NONSUCCESS:
            continue
        conv = r.get("intercom_conv_id")
        if conv:
            events.append((str(conv), r["_ts"]))
    return events


def misconfig_counts(wrapper_recs):
    """status -> count for wrapper-side fail-closed misconfig (approver/requester/
    muso missing). The wrappers _audit these BEFORE exiting, so they appear in the
    wrapper logs but never reach muso; a run of them means an approval env or the
    muso binary went missing. (OPS_DRY_RUN is handled separately in main() -- it is
    NOT audited, so it cannot be counted from these logs.)"""
    out = {}
    for r in wrapper_recs:
        st = str(r.get("status") or "")
        if st in WRAPPER_MISCONFIG:
            out[st] = out.get(st, 0) + 1
    return out


def routed_credit_requests(wrapper_recs):
    """Real-customer credits_verify records the muso gate ROUTED to a human
    (wrapper status refused_route_to_human), each carrying the request_id +
    profile_id that verify-credit.sh _audit stamps. Returns [(request_id,
    profile_id)] deduped by request_id (latest attempt wins). Excluded:
    test/synthetic actors (go-live probes, not customer service) and any request
    with a LATER apply-mode success record -- a route Caroline subsequently retried
    and applied herself ended in autonomy, not a human hand-off, and counting its
    (now-approved) status as 'a human later approved it' would inflate exactly the
    recoverable/false-refusal stat the autonomy-improver gates loosening on."""
    latest = {}
    resolved = {}  # rid -> latest ts of an apply-mode success (ended in autonomy)
    for r in wrapper_recs:
        if r.get("tool") != "credits_verify":
            continue
        rid = str(r.get("request_id") or "")
        if not rid:
            continue
        status = str(r.get("status") or "")
        ts = r.get("_ts") or 0
        if r.get("mode") == "apply" and status and status not in WRAPPER_NONSUCCESS:
            resolved[rid] = max(ts, resolved.get(rid, 0))
            continue
        if status not in WRAPPER_REFUSED:
            continue
        if is_test_actor(r.get("actor_identity")):
            continue
        pid = str(r.get("profile_id") or "")
        if not pid:
            continue
        if rid not in latest or ts >= latest[rid][1]:
            latest[rid] = (pid, ts)
    return [(rid, pid) for rid, (pid, ts) in latest.items()
            if resolved.get(rid, -1) < ts]


# Reconciliation network seam (module-level so tests monkeypatch it, never a real
# subprocess). The reconciler reads a credit-request's CURRENT status through the
# SANCTIONED read-only muso-read wrapper (`muso-read.sh api GET <route> --json`) --
# reject-by-default, centrally authed via the deployed muso binary, so the digest
# gains NO new credential (it already only holds an Intercom read token).
def muso_read_api_get(route, wrapper):
    """Run the read-only muso-read wrapper for one admin-API GET route; return
    parsed JSON. `wrapper` is a command prefix (shlex-split); `route` is passed as
    a single argv element (list argv -> no shell, no injection). Raises on a
    non-zero exit or unparseable body -- the caller buckets that as an error."""
    argv = shlex.split(wrapper) + ["api", "GET", route, "--json"]
    out = subprocess.run(argv, capture_output=True, text=True, timeout=20)
    if out.returncode != 0:
        raise RuntimeError(
            f"muso-read exited {out.returncode}: {(out.stderr or '')[:200].strip()}")
    return json.loads(out.stdout or "null")


CR_PAGE_LIMIT = 1000  # one page per (profile,status); a FULL page = possible truncation


def credit_request_ids(profile_id, status, wrapper):
    """Set of credit-request ids for one profile filtered by `status`, via the
    read-only muso-read admin GET (the same
    /admin/credit-requests?profilesIds=&status= read credit_verification_check
    uses; `.data.items[].id` is the cr_id). Monkeypatched in tests. Returns a set
    of str. A full page raises (mirrors credit-verification-check's fetch-MAX+1
    truncation guard): silently missing a routed id off the page end would
    misbucket it as withdrawn/reverted -- better the profile lands in `errors`
    (visible as unresolved) than a corrupted false-refusal stat."""
    route = ("/admin/credit-requests?profilesIds="
             + urllib.parse.quote(str(profile_id), safe="")
             + "&status=" + urllib.parse.quote(str(status), safe="")
             + f"&limit={CR_PAGE_LIMIT}")
    body = muso_read_api_get(route, wrapper)
    # A 200 whose body lacks the expected .data.items ARRAY is schema drift, NOT
    # an empty result (mirrors credit-verification-check.ts): falling back to []
    # would misbucket every routed id on this profile as withdrawn/reverted.
    # Raise -> the profile lands in `errors` (visible as unresolved) instead.
    items = ((body or {}).get("data") or {}).get("items") if isinstance(body, dict) else None
    if not isinstance(items, list):
        raise RuntimeError(
            f"credit-requests response missing data.items for status={status}; "
            "schema drift -- refusing to bucket")
    if len(items) >= CR_PAGE_LIMIT:
        raise RuntimeError(
            f"credit-requests page full ({len(items)} >= {CR_PAGE_LIMIT}) for "
            f"status={status}; refusing a possibly-truncated bucket")
    return {str(it.get("id")) for it in items
            if isinstance(it, dict) and it.get("id")}


def reconcile_routes(routed, wrapper, cap):
    """Look up the CURRENT disposition of each routed credit and bucket it -- the
    'was the route recoverable?' signal (the false-refusal audit the improver skill
    requires before broadening the gate). For each routed (request_id, profile_id):
      approved -> a human LATER approved it. Recoverable IF catalog corroboration
                  were broadened; NOT proof Caroline was wrong -- the human may have
                  used external-catalog evidence she structurally cannot (and should
                  not) act on.
      pending  -> still user_verification_needed (no human decision yet).
      other    -> neither (reverted to unverified / withdrawn / not found).
    Grouped by profile (one approved + one UVN GET per profile), bounded to `cap`
    profiles; the overflow AND any per-profile lookup failure land in `errors` so
    truncation is VISIBLE, never a silent undercount. Returns
    {checked, approved, pending, other, errors}."""
    by_profile = {}
    for rid, pid in routed:
        by_profile.setdefault(pid, []).append(rid)
    res = {"checked": 0, "approved": 0, "pending": 0, "other": 0, "errors": 0}
    profiles = list(by_profile)
    for pid in profiles[:cap]:
        rids = by_profile[pid]
        try:
            approved_set = credit_request_ids(pid, "approved", wrapper)
            uvn_set = credit_request_ids(pid, "user_verification_needed", wrapper)
        except Exception:  # noqa: BLE001 -- one bad profile must not fail the digest
            res["errors"] += len(rids)
            continue
        for rid in rids:
            res["checked"] += 1
            if rid in approved_set:
                res["approved"] += 1
            elif rid in uvn_set:
                res["pending"] += 1
            else:
                res["other"] += 1
    for pid in profiles[cap:]:  # profiles beyond the cap -> visible as unresolved
        res["errors"] += len(by_profile[pid])
    return res


def reopen_rate(events, token, now, window, cap):
    """Of (conv_id, anchor_ts) events within `window`, how many had a customer
    (non-admin) message strictly AFTER anchor_ts. Returns (checked, reopened,
    errors), bounded to `cap` Intercom GETs, deduped by conv (latest anchor)."""
    lo = now - window
    latest = {}
    for conv_id, ts in events:
        if ts is None or ts < lo:
            continue
        if conv_id not in latest or ts > latest[conv_id]:
            latest[conv_id] = ts
    ordered = sorted(latest.items(), key=lambda kv: kv[1], reverse=True)
    checked, reopened, errors = 0, 0, 0
    for conv_id, anchor in ordered[:cap]:
        try:
            conv = get_conversation(conv_id, token)
        except Exception:  # noqa: BLE001 -- one bad conv must not fail the digest
            errors += 1
            continue
        checked += 1
        parts = (conv.get("conversation_parts") or {}).get("conversation_parts") or []
        for p in parts:
            a = p.get("author") or {}
            if a.get("type") != "user":
                continue
            pts = parse_ts(p.get("created_at"))
            if pts is not None and pts > anchor:
                reopened += 1
                break
    return checked, reopened, errors


def detect_anomalies(s24, misconfig24, kill_switch, malformed, apply_ceiling):
    """CRITICAL/WARN anomaly lists from the 24h capability summary, wrapper
    misconfig counts, and the OPS_DRY_RUN kill-switch state (read from env)."""
    crit, warn = [], []
    if kill_switch:
        crit.append("OPS_DRY_RUN=1 kill switch ACTIVE -- Caroline's autonomous "
                    "writes are PAUSED (every self-serve verb no-ops and routes to "
                    "a human); unset OPS_DRY_RUN in /etc/openclaw/edge.env + restart "
                    "openclaw-gateway-edge to resume.")
    if misconfig24:
        crit.append("wrapper-side fail-close in 24h "
                    f"{json.dumps(misconfig24, sort_keys=True)} -- an approval env "
                    "(MUSO_CAPABILITY_APPROVER/MUSO_REQUESTER) or the muso binary is "
                    "missing on edge; Caroline's autonomy is silently degraded "
                    "(every affected write fails closed)")
    if s24["unclassified_values"]:
        crit.append("unrecognized muso-cli decision value(s) "
                    f"{json.dumps(s24['unclassified_values'], sort_keys=True)} -- "
                    "capability-audit schema drift; the digest cannot classify "
                    "these outcomes (re-verify on the next muso-cli bump)")
    if s24["authorized_without_terminal"] >= 2:
        crit.append(f"{s24['authorized_without_terminal']} authorized capability "
                    "call(s) with NO terminal applied/gate_refused in 24h -- a "
                    "crash between the cap-counting line and the mutation (the "
                    "per-actor budget may be charged for a write that never landed)")
    applies = s24["totals"]["success"]
    if applies > apply_ceiling:
        crit.append(f"{applies} autonomous applies in 24h exceeds the ceiling "
                    f"({apply_ceiling}) -- possible runaway loop or injection")
    if s24["totals"]["backend_refused"] >= 4:
        warn.append(f"{s24['totals']['backend_refused']} gate_refused in 24h -- "
                    "ownership checks passed but the backend rejected the write")
    if malformed >= 5:
        warn.append(f"{malformed} malformed line(s) in the capability audit -- "
                    "log corruption or a partial write")
    return crit, warn


# --------------------------------------------------------------------------
# Persistent trend state (atomic; for week-over-week deltas).
# --------------------------------------------------------------------------
def load_state(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, OSError, ValueError):
        return {}


def write_state(path, state):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(state, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def append_history(path, row):
    """Append one row to the append-only trend log. True on success.

    state.json holds exactly ONE snapshot, so the week-over-week delta it feeds is
    a 1-lag diff with no trend behind it: nothing in the system could answer "is
    Caroline getting better". This log is the series. Append-only and best-effort
    -- a failure to record history must never fail a digest that already posted.
    """
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as f:
            f.write(json.dumps(row, sort_keys=True) + "\n")
        return True
    except OSError as exc:
        # Best-effort for the RUN -- a digest that already has its numbers must
        # still post -- but never silent. A read-only or full filesystem makes
        # every append fail while the log stays readable, so the series silently
        # stops growing and the trend reports a stale baseline forever.
        print(f"WARN: could not append to the trend history at {path}: "
              f"{type(exc).__name__}: {exc}. The series is NOT growing.",
              file=sys.stderr)
        return False


def load_history(path, cap=2000):
    """(rows, readable, writable). Newest last. Malformed LINES skipped, not fatal.

    `readable` separates "the log does not exist yet" (a young series, expected
    on a fresh box) from "it exists but cannot be read" (read-only dir, full
    disk, permissions). read_jsonl collapses both to [], so a permanently broken
    history rendered as "no four-week baseline yet" forever while the feature was
    dead. Non-fatal either way -- a digest that already has its numbers must
    still post -- but the caller can now say which one it is.

    Deliberately reuses read_jsonl rather than re-parsing: a second JSONL reader
    would drift from it, and read_jsonl already counts malformed lines for the
    anomaly path. The count is discarded here (a torn history row is not worth
    paging over) exactly as the other tolerant callers do.
    """
    # Writability matters as much as readability WHEN WE ARE GOING TO WRITE: a
    # readable-but-unwritable log never grows, so the baseline silently freezes
    # and the headline reports a stale trend forever. In --check nothing is
    # written, so an unwritable path says nothing about the series -- flagging it
    # there would emit a spurious warning on any host without the state dir.
    # Probed with os.access, which mutates nothing, so --check stays read-only.
    parent = os.path.dirname(path) or "."
    # For a missing log the question is "can we CREATE it here", so the parent
    # must be a directory AND writable. os.access alone is wrong: on a parent
    # that is a regular file it reports that FILE's writability and we would
    # call the log creatable when os.makedirs is going to raise
    # NotADirectoryError.
    writable = os.access(path, os.W_OK) if os.path.exists(path) \
        else (os.path.isdir(parent) and os.access(parent, os.W_OK))
    if not os.path.exists(path):
        return [], True, writable     # nothing recorded yet: legitimately young
    try:
        with open(path):
            pass
    except OSError:
        return [], False, writable    # exists but unreadable: broken, say so
    rows, _ = read_jsonl(path)
    return rows[-cap:], True, writable


def autonomy_rate(totals):
    """(applied, attempted, pct) over TERMINAL gated write outcomes, or pct=None.

    Attempted is applied + routed + backend-refused: the decisions that actually
    reached a verdict. previews/authorized/shadow are excluded because they are
    not outcomes. Returns pct=None on n=0 rather than 0.0 -- an unmeasured rate
    and a measured zero are different facts.
    """
    applied = totals.get("success", 0)
    attempted = applied + totals.get("route_to_human", 0) + totals.get("backend_refused", 0)
    if attempted <= 0:
        return applied, attempted, None
    return applied, attempted, 100.0 * applied / attempted


def history_baseline(history, now_ts, days=28, tolerance_days=7):
    """The recorded row closest to `days` ago, or None if the log does not reach
    back that far. Never extrapolates: no row in the window means no baseline."""
    target = now_ts - days * 86400
    best, best_gap = None, tolerance_days * 86400
    for row in history:
        ts = row.get("ts")
        if not isinstance(ts, (int, float)):
            continue
        gap = abs(ts - target)
        if gap <= best_gap:
            best, best_gap = row, gap
    return best


def autonomy_trend_line(totals_real, history, now_ts, history_readable=True):
    """The headline that answers "is this working": the share of gated write
    attempts Caroline completed herself, against a four-week-old baseline.

    Always renders the basis (n of m). A percentage without its denominator is
    exactly how 21-of-252 could be read as healthy.
    """
    applied, attempted, pct = autonomy_rate(totals_real)
    if pct is None:
        return "*Autonomy rate (7d):* no gated write attempts to measure."
    head = (f"*Autonomy rate (7d):* {pct:.0f}% of gated write attempts completed "
            f"without a human ({applied} of {attempted})")
    if not history_readable:
        # A log that cannot be read OR WRITTEN is not a young series. Either way
        # the trend is dead, and "no baseline yet" would hide that behind a
        # legitimate-looking message for as long as it stayed broken.
        return head + " — trend unavailable: the history log could not be read or written."
    base = history_baseline(history or [], now_ts)
    if base is None:
        return head + " — no four-week baseline yet."
    b_applied, b_attempted, b_pct = autonomy_rate(base.get("totals_real") or {})
    if b_pct is None:
        # A row exists; it just recorded no terminal outcomes. Saying "no
        # baseline yet" would misreport a measured week as a missing one.
        return head + " — the four-week baseline recorded no gated write attempts."
    arrow = "up" if pct > b_pct else ("down" if pct < b_pct else "flat")
    # Render the baseline's REAL age, not the nominal 28 days: history_baseline
    # accepts anything within a 7-day tolerance, so "four weeks ago" can be a
    # 21-day-old row. Never assert a number the data did not measure.
    b_ts = base.get("ts")
    age = (f"{int(round((now_ts - b_ts) / 86400.0))} days ago"
           if isinstance(b_ts, (int, float)) else "in the baseline week")
    return (head + f" — {arrow} from {b_pct:.0f}% ({b_applied} of {b_attempted}) "
            f"{age}.")


# --------------------------------------------------------------------------
# Slack.
# --------------------------------------------------------------------------
def slack_escape(s):
    """Escape Slack mrkdwn control chars in customer-derived text (& first)."""
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _read_slack_token(config_path, account):
    try:
        with open(config_path) as f:
            cfg = json.load(f)
        return cfg["channels"]["slack"]["accounts"][account]["botToken"]
    except (OSError, KeyError, ValueError, TypeError):
        return None


def post_slack(text, channel, config_path, account):
    token = _read_slack_token(config_path, account)
    if not token:
        print(f"WARN: no Slack token for '{account}' in {config_path}; post skipped",
              file=sys.stderr)
        return False
    s, body = http("POST", SLACK_API, {"Authorization": f"Bearer {token}"},
                   body={"channel": channel, "text": text,
                         "unfurl_links": False, "unfurl_media": False}, attempts=2)
    if not (isinstance(body, dict) and body.get("ok")):
        print(f"WARN: Slack post failed: {body}", file=sys.stderr)
        return False
    return True


# --------------------------------------------------------------------------
# Digest rendering.
# --------------------------------------------------------------------------
def _verb_line(name, c):
    done, routed, back, unk = (c["success"], c["route_to_human"],
                               c["backend_refused"], c["unclassified"])
    attempted = done + routed + back + unk
    if attempted == 0:
        return f"• `{name}`: no real attempts"
    pieces = [f"{done} done"]
    if routed:
        pieces.append(f"{routed} route-to-human")
    if back:
        pieces.append(f"{back} backend-refused")
    if unk:
        pieces.append(f"{unk} unclassified")
    return f"• `{name}`: {attempted} attempted — " + ", ".join(pieces)


def _delta(now_val, prev_val):
    if prev_val is None:
        return ""
    d = now_val - prev_val
    return f" ({'+' if d >= 0 else ''}{d} WoW)"


def _reopen_line(label, reopen):
    if reopen is None:
        return f"*{label} (7d):* not checked (--check mode)"
    if reopen["checked"] == 0:
        return f"*{label} (7d):* n=0 — none yet"
    pct = round(100.0 * reopen["reopened"] / reopen["checked"])
    return (f"*{label} (7d):* {reopen['reopened']}/{reopen['checked']} customers "
            f"replied afterwards (~{pct}%) — lower is better")


def _uvn_line(cv7, cva):
    """The UVN (user-verification-needed) credit flow, which is exactly the
    `credits_verify` verb: how many credits Caroline AUTONOMOUSLY APPROVED vs
    handed to a human, 7d + all-time, real customers only (the gate audit is
    authoritative). `routed` = the verb refused and routed to a human; it is NOT
    the same as 'asked the customer for more proof' (a conversational step with no
    counter). Caroline auto-approves ONLY catalog-corroborated credits."""
    return (f"*UVN credit verification (real customers):* "
            f"{cv7['success']} approved · {cv7['route_to_human']} routed to a human "
            f"in 7d  |  {cva['success']} approved · {cva['route_to_human']} routed "
            f"all-time. Auto-approve fires only on catalog-corroborated credits; "
            f"everything else is a human decision.")


def _reconcile_line(reconcile, routed_count):
    """Render the disposition of the credits Caroline ROUTED to a human -- the
    honest 'was the route recoverable?' number. Turns an ambiguous 'N routed' into
    'A a human later approved (recoverable) / P still pending / O withdrawn'.
    A COMPUTED reconciliation always renders, even if the capability audit's route
    count disagrees (the sources are different files; a rotated/lagging
    tier2-audit must not suppress a reconcile that was actually run -- the [n=...]
    tail carries the reconciled N). With none computed: routes -> an explicit
    'not checked' (never silently dropped); no routes -> no line."""
    if reconcile and (reconcile["checked"] or reconcile["errors"]):
        tail = f" [n={reconcile['checked']} checked"
        if reconcile["errors"]:
            tail += f", {reconcile['errors']} unresolved"
        tail += "]"
        return ("*Of the credits routed to a human (7d):* "
                f"{reconcile['approved']} later approved by a human "
                "(recoverable if catalog corroboration is broadened), "
                f"{reconcile['pending']} still pending review, "
                f"{reconcile['other']} withdrawn/reverted." + tail)
    if routed_count == 0:
        return None
    return ("*Of the credits routed to a human (7d):* disposition not checked "
            "(--check mode, reconciler unconfigured, or no matching wrapper "
            "records).")


def build_digest(s24, s7, s_all, ops, reopen_selfserve, reopen_done, reopen_close,
                 anomalies, prev7, reconcile=None, history=None, now_ts=None,
                 history_readable=True):
    """Compose the #cs_chats digest text. Pure (no I/O). `reconcile` (optional,
    trailing so the historical positional callers keep working) is the routed-credit
    disposition dict from reconcile_routes, or None -> the line renders 'not checked'."""
    crit, warn = anomalies
    lines = [":robot_face: *Caroline autonomy — daily behavior digest*"]

    # Lead with the trend, not a snapshot. The question this digest exists to
    # answer is "is the AI doing more of the work than it was", and a single
    # week's numbers cannot answer it.
    lines.append(autonomy_trend_line(s7["totals_real"], history,
                                     now_ts if now_ts is not None else time.time(),
                                     history_readable))

    # Lead with what she actually DID (the auto-close loop is the bulk of it), then
    # the self-serve WRITES. succ7 counts REAL customers only -- smoke probes are
    # not wins. (A 0 here means "0 wrong/forced writes + correct routing", not idle.)
    succ7 = s7["totals_real"]["success"]
    lines.append(
        f"*Autonomous wins (7d):* {ops['closes_7d']} conversation(s) auto-closed, "
        f"{succ7} self-serve write(s) applied"
        f"{_delta(succ7, (prev7 or {}).get('success'))}, "
        f"{ops['notifies_7d']} proactive notify(ies) sent.")
    nreal = len(s7["real_actors"])
    if nreal or len(s7["test_actors"]):
        lines.append(f"_{nreal} distinct real customer(s) served autonomously in 7d "
                     f"({len(s7['test_actors'])} test/synthetic excluded)._")
    # Reframe so the low self-serve-write count is not misread as idleness: the
    # auto-close loop + proactive notifies are the bulk of the autonomy, and the
    # credit routes below are integrity-holds (a human decides), not failed writes.
    lines.append("_Autonomy is mostly the auto-close loop + proactive notifies; "
                 "self-serve writes are the narrow \"act on the account\" slice, and "
                 "credit routes are integrity-holds (a human decides), not misses._")
    # Clarify a 0-notify headline WITHOUT over-claiming the cause. The digest can't
    # tell from telemetry whether the notifiers are dry-run or simply post-cold-start
    # with no NEW resolutions yet -- resolve-notify.py seeds its state on the first
    # run in BOTH modes (the cold-start write is ungated), so neither the send-log
    # nor the state file proves --apply is off. State the benign explanation + the
    # actionable fallback; don't assert dry-run.
    if ops["notifies_7d"] == 0:
        if ops["closes_7d"] > 0:
            lines.append(
                f"_Note: 0 proactive notifies despite {ops['closes_7d']} auto-closes "
                "— expected just after the notifiers' cold-start seed (they message "
                "only on NEW resolutions). If 0 persists for days, verify "
                "resolve-notify/overdue run with `--apply`._")
        else:
            lines.append("_Note: 0 proactive notifies — nothing to notify yet._")

    lines.append("*Verb outcomes — real customers (24h):*")
    for v in VERBS:
        lines.append(_verb_line(v, s24["per_verb_real"][v]))

    lines.append(_uvn_line(s7["per_verb_real"]["credits_verify"],
                           s_all["per_verb_real"]["credits_verify"]))
    # Reconcile the routed credits against the human's EVENTUAL decision -- the
    # number that tells whether the route rate is losing autonomy (a human later
    # approved what Caroline held) or protecting integrity (nobody could approve it).
    rline = _reconcile_line(reconcile,
                            s7["per_verb_real"]["credits_verify"]["route_to_human"])
    if rline:
        lines.append(rline)

    if s24["reasons_real"]:
        top = sorted(s24["reasons_real"].items(), key=lambda kv: kv[1], reverse=True)[:3]
        lines.append("*Why routed/refused — real customers (24h):*")
        for res, n in top:
            lines.append(f"  ◦ {n}× {slack_escape(res[:160])}")

    # Reopen-after-auto-close FIRST: the auto-close loop is the dominant action, so
    # its quality signal (did the customer reply right after we closed?) matters most.
    lines.append(_reopen_line("Reopen-after-auto-close", reopen_close))
    lines.append(_reopen_line("Reopen-after-self-serve", reopen_selfserve))
    lines.append(_reopen_line("Reopen-after-done", reopen_done))

    if crit:
        lines.append(":rotating_light: *SAFETY (critical):*")
        for c in crit:
            lines.append(f"  ‼️ {c}")
    if warn:
        lines.append(":warning: *Watch:*")
        for w in warn:
            lines.append(f"  • {w}")
    if not crit and not warn:
        lines.append("_No safety anomalies in the last 24h._")
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Inline self-test.
# --------------------------------------------------------------------------
def _iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def _self_test(now):
    assert parse_ts(1781784000) == 1781784000 and parse_ts(1781784000000) == 1781784000
    assert parse_ts("1781784000000") == 1781784000, "string ms epoch"
    assert classify("applied") == "success" and classify("noop") == "success"
    assert classify("refused") == "route_to_human"
    assert classify("gate_refused") == "backend_refused"
    assert classify("dry_run") == "preview" and classify("authorized") == "authorized"
    assert classify("totally_new_value") == "unclassified", "vocab drift must surface"
    assert classify("shadow_would_merge") == "shadow" and classify("shadow_would_refuse") == "shadow", \
        "rename-merge shadow decisions must classify as shadow, not trip schema drift"

    recs = [
        {"tool": "credits_verify", "decision": "authorized", "ts": _iso(now - 1000),
         "actor_identity": "a@b.com"},
        {"tool": "credits_verify", "decision": "applied", "ts": _iso(now - 999),
         "actor_identity": "a@b.com"},
        {"tool": "profiles_claim_self", "decision": "refused", "ts": _iso(now - 50),
         "actor_identity": "x@example.com", "result": "not the owner"},
        {"tool": "profiles_consolidate", "decision": "dry_run", "ts": _iso(now - 10),
         "actor_identity": "c@d.com"},
        {"tool": "order_lookup", "decision": "applied", "ts": _iso(now - 5),
         "actor_identity": "z@z.com"},  # non-verb tool: ignored
        {"tool": "credits_verify", "decision": "applied", "ts": _iso(now - 10 * DAY),
         "actor_identity": "old@b.com"},  # outside 24h
    ]
    caps = capability_records(recs)
    assert len(caps) == 5, caps
    s = summarize(caps, now, DAY)
    assert s["totals"]["success"] == 1 and s["totals"]["route_to_human"] == 1, s["totals"]
    assert s["totals"]["preview"] == 1 and s["totals"]["authorized"] == 1, s["totals"]
    assert s["authorized_without_terminal"] == 0, ("graced authorized paired", s)
    assert s["real_actors"] == ["a@b.com"], ("example.com + preview-only excluded", s["real_actors"])
    assert s["test_actors"] == ["x@example.com"], s["test_actors"]
    assert "not the owner" in s["reasons"], s["reasons"]
    assert summarize(caps, now, 7 * DAY)["totals"]["success"] == 1, "10d-old applied excluded from 7d"
    # Real-customer-only views: the test actor's refusal is excluded; the real apply stays.
    assert s["totals_real"]["success"] == 1, ("real applied kept", s["totals_real"])
    assert s["totals_real"]["route_to_human"] == 0, ("test-actor refusal excluded", s["totals_real"])
    assert s["per_verb_real"]["credits_verify"]["success"] == 1, s["per_verb_real"]
    assert s["per_verb_real"]["profiles_claim_self"]["route_to_human"] == 0, s["per_verb_real"]

    # authorized-without-terminal: GRACE protects an in-flight write; only an
    # OLD unpaired authorized (>= 2) is a crash anomaly.
    inflight = summarize(capability_records([
        {"tool": "credits_verify", "decision": "authorized", "ts": _iso(now - 10),
         "actor_identity": "a@b.com"}]), now, DAY)
    assert inflight["authorized_without_terminal"] == 0, ("fresh authorized graced", inflight)
    crash = summarize(capability_records([
        {"tool": "credits_verify", "decision": "authorized", "ts": _iso(now - 600),
         "actor_identity": "a@b.com"},
        {"tool": "credits_verify", "decision": "authorized", "ts": _iso(now - 600),
         "actor_identity": "b@b.com"}]), now, DAY)
    assert crash["authorized_without_terminal"] == 2, crash
    crit, _ = detect_anomalies(crash, {}, False, 0, 40)
    assert any("authorized" in c for c in crit), crit

    # misconfig (wrapper-side) is CRITICAL.
    cm, _ = detect_anomalies(summarize([], now, DAY), {"refused_no_approver": 3}, False, 0, 40)
    assert any("fail-close" in c for c in cm), cm

    # OPS_DRY_RUN kill switch (read from env, NOT a wrapper status) is CRITICAL.
    ck, _ = detect_anomalies(summarize([], now, DAY), {}, True, 0, 40)
    assert any("OPS_DRY_RUN" in c for c in ck), ck

    # unclassified decision -> critical schema-drift.
    drift = summarize(capability_records([
        {"tool": "credits_verify", "decision": "weird", "ts": _iso(now),
         "actor_identity": "a@b.com"}]), now, DAY)
    cd, _ = detect_anomalies(drift, {}, False, 0, 40)
    assert any("schema drift" in c for c in cd), cd

    # apply-ceiling -> critical; clean window -> nothing.
    big = dict(summarize([], now, DAY))
    big["totals"] = dict(big["totals"], success=99)
    cb, _ = detect_anomalies(big, {}, False, 0, 40)
    assert any("exceeds the ceiling" in c for c in cb), cb
    assert detect_anomalies(s, {}, False, 0, 40) == ([], []), "clean window must not page"

    # wrapper extraction: apply-success with conv-id -> reopen event; misconfig counted.
    wsample = [
        {"tool": "credits_verify", "mode": "apply", "status": "verified",
         "intercom_conv_id": "C1", "_ts": now - 100},
        {"tool": "credits_verify", "mode": "apply", "status": "muso_failed",
         "intercom_conv_id": "C2", "_ts": now - 90},  # not a success
        {"tool": "credits_verify", "mode": "dry-run", "status": "verified",
         "intercom_conv_id": "C3", "_ts": now - 80},  # not apply
        {"tool": "credits_verify", "mode": "apply", "status": "refused_no_approver",
         "intercom_conv_id": "C4", "_ts": now - 70},  # misconfig
    ]
    events = selfserve_reopen_events(wsample)
    assert events == [("C1", now - 100)], events

    # --- autonomy rate + trend ------------------------------------------------
    # The metric that answers "is the AI doing more of the work". n=0 must be
    # None, never 0.0: an unmeasured rate and a measured zero are different facts.
    assert autonomy_rate({"success": 21, "route_to_human": 221,
                          "backend_refused": 10})[2] is not None
    _a, _n, _p = autonomy_rate({"success": 21, "route_to_human": 221,
                                "backend_refused": 10})
    assert (_a, _n) == (21, 252) and abs(_p - 8.333) < 0.01, (_a, _n, _p)
    # previews/authorized/shadow are not outcomes and must not dilute the rate.
    assert autonomy_rate({"success": 1, "route_to_human": 1, "backend_refused": 0,
                          "preview": 98, "authorized": 50})[1] == 2
    assert autonomy_rate({"success": 0, "route_to_human": 0,
                          "backend_refused": 0})[2] is None

    # A baseline is only used when the log actually reaches back that far.
    _hist = [{"ts": now - 28 * DAY, "totals_real": {"success": 10, "route_to_human": 90,
                                                    "backend_refused": 0}}]
    assert history_baseline(_hist, now) is not None
    assert history_baseline([{"ts": now - 3 * DAY, "totals_real": {}}], now) is None
    assert history_baseline([], now) is None
    # Malformed rows are skipped, not fatal.
    assert history_baseline([{"ts": "nope"}], now) is None

    _line = autonomy_trend_line({"success": 21, "route_to_human": 221,
                                 "backend_refused": 10}, _hist, now)
    assert "21 of 252" in _line, _line          # always renders its basis
    assert "down from 10%" in _line, _line      # 8% now vs 10% four weeks ago
    _nb = autonomy_trend_line({"success": 1, "route_to_human": 1,
                               "backend_refused": 0}, [], now)
    assert "no four-week baseline yet" in _nb, _nb
    assert "1 of 2" in _nb, _nb
    # An UNREADABLE log must not read as a young series -- that hid a dead
    # feature behind a legitimate-looking message for as long as it stayed broken.
    _un = autonomy_trend_line({"success": 1, "route_to_human": 1,
                               "backend_refused": 0}, [], now,
                              history_readable=False)
    assert "trend unavailable" in _un, _un
    assert "no four-week baseline yet" not in _un, _un
    # Unwritable history. The failure is induced by putting the log UNDER A
    # FILE, so os.makedirs raises NotADirectoryError: a path like
    # /nonexistent/... is not a portable failure, because CI runs bats as ROOT
    # and root happily creates it at the filesystem root (it passed on a
    # read-only macOS root and failed on the Linux runner, while littering it).
    # Permissions are no good either -- root bypasses them.
    with tempfile.NamedTemporaryFile() as _f:
        _under_file = os.path.join(_f.name, "history.jsonl")
        # Missing file under a non-directory: readable-as-young, NOT writable.
        assert load_history(_under_file) == ([], True, False)
        # append_history reports failure rather than swallowing it. The inline
        # self-test runs on EVERY invocation, not just --self-test, so the
        # warning it deliberately emits must be captured -- otherwise it prints
        # on every real run and lands in the merged stdout+stderr that callers
        # parse as JSON (three digest tests went red exactly this way).
        _null = io.StringIO()
        with contextlib.redirect_stderr(_null):
            assert append_history(_under_file, {"ts": 1}) is False
        assert "NOT growing" in _null.getvalue(), _null.getvalue()
    # The baseline's REAL age is rendered, not the nominal 28 days: the lookup
    # accepts +-7 days, so a 21-day-old row must not be reported as four weeks.
    _hist21 = [{"ts": now - 21 * DAY, "totals_real": {"success": 10,
                                                     "route_to_human": 90,
                                                     "backend_refused": 0}}]
    _old = autonomy_trend_line({"success": 21, "route_to_human": 221,
                                "backend_refused": 10}, _hist21, now)
    assert "21 days ago" in _old, _old
    # A baseline row that recorded no terminal outcomes is NOT "no baseline yet".
    _empty_base = autonomy_trend_line(
        {"success": 21, "route_to_human": 221, "backend_refused": 10},
        [{"ts": now - 28 * DAY, "totals_real": {"preview": 5}}], now)
    assert "recorded no gated write attempts" in _empty_base, _empty_base
    assert "no four-week baseline yet" not in _empty_base, _empty_base
    mc = misconfig_counts(wsample)
    assert mc == {"refused_no_approver": 1}, mc

    # reopen_rate: a customer reply strictly after the anchor counts; admin does not.
    def fake_get(cid, tok):
        if cid == "C1":
            return {"conversation_parts": {"conversation_parts": [
                {"author": {"type": "user"}, "created_at": now - 50}]}}
        return {"conversation_parts": {"conversation_parts": [
            {"author": {"type": "admin"}, "created_at": now - 50}]}}
    saved = globals()["get_conversation"]
    globals()["get_conversation"] = fake_get
    try:
        checked, reopened, errors = reopen_rate(
            [("C1", now - 100), ("C9", now - 100)], "t", now, 7 * DAY, 50)
    finally:
        globals()["get_conversation"] = saved
    assert (checked, reopened, errors) == (2, 1, 0), (checked, reopened, errors)

    # routed_credit_requests: real routed credit records -> (request_id, profile_id),
    # deduped by request_id; excluded: test actors, non-routed/non-credit records,
    # and a route Caroline later RETRIED to an apply-success (ended in autonomy --
    # its approved status must not inflate the 'human later approved' stat).
    wrouted = [
        {"tool": "credits_verify", "status": "refused_route_to_human",
         "request_id": "R1", "profile_id": "P1", "actor_identity": "a@b.com", "_ts": now - 100},
        {"tool": "credits_verify", "status": "refused_route_to_human",
         "request_id": "R2", "profile_id": "P1", "actor_identity": "a@b.com", "_ts": now - 90},
        {"tool": "credits_verify", "status": "refused_route_to_human",  # test actor -> excluded
         "request_id": "R3", "profile_id": "P2", "actor_identity": "x@example.com", "_ts": now - 80},
        {"tool": "credits_verify", "status": "verified",  # not routed -> excluded
         "request_id": "R4", "profile_id": "P3", "actor_identity": "c@d.com", "_ts": now - 70},
        {"tool": "credits_verify", "status": "refused_route_to_human",  # routed...
         "request_id": "R5", "profile_id": "P4", "actor_identity": "e@f.com", "_ts": now - 60},
        {"tool": "credits_verify", "mode": "apply", "status": "verified",  # ...then retried OK
         "request_id": "R5", "profile_id": "P4", "actor_identity": "e@f.com", "_ts": now - 50},
    ]
    assert sorted(routed_credit_requests(wrouted)) == [("R1", "P1"), ("R2", "P1")], \
        routed_credit_requests(wrouted)
    # ...but an apply-success BEFORE the route (stale/idempotent noop, then a fresh
    # route) does NOT clear the route -- only a LATER success ends it in autonomy.
    wroute_after = [
        {"tool": "credits_verify", "mode": "apply", "status": "noop",
         "request_id": "R6", "profile_id": "P5", "actor_identity": "g@h.com", "_ts": now - 100},
        {"tool": "credits_verify", "status": "refused_route_to_human",
         "request_id": "R6", "profile_id": "P5", "actor_identity": "g@h.com", "_ts": now - 40},
    ]
    assert routed_credit_requests(wroute_after) == [("R6", "P5")], \
        routed_credit_requests(wroute_after)

    # reconcile_routes: monkeypatch the credit_request_ids seam (never a subprocess).
    # P1 has R1 approved + R2 still UVN; a profile whose lookup raises lands in errors;
    # profiles beyond the cap are surfaced as errors, never silently dropped.
    def fake_cr_ids(pid, status, wrapper):
        if pid == "P1" and status == "approved":
            return {"R1"}
        if pid == "P1" and status == "user_verification_needed":
            return {"R2"}
        raise RuntimeError("boom")
    saved_cr = globals()["credit_request_ids"]
    globals()["credit_request_ids"] = fake_cr_ids
    try:
        rec = reconcile_routes([("R1", "P1"), ("R2", "P1")], "x", 60)
        assert rec == {"checked": 2, "approved": 1, "pending": 1, "other": 0, "errors": 0}, rec
        rec_err = reconcile_routes([("RX", "PBAD")], "x", 60)  # lookup raises -> error, no crash
        assert rec_err["errors"] == 1 and rec_err["checked"] == 0, rec_err
        rec_cap = reconcile_routes([("R1", "P1"), ("RY", "PY")], "x", 1)  # cap -> overflow=error
        assert rec_cap["checked"] == 1 and rec_cap["errors"] >= 1, rec_cap
    finally:
        globals()["credit_request_ids"] = saved_cr

    # credit_request_ids: a 200 without a data.items ARRAY is schema drift and must
    # raise (-> profile lands in errors), never read as an empty/complete bucket;
    # a genuine empty list and a populated list parse normally.
    saved_get = globals()["muso_read_api_get"]
    responses = {}
    globals()["muso_read_api_get"] = lambda route, wrapper: responses["body"]
    try:
        for bad in (None, {}, {"data": {}}, {"data": {"items": "nope"}}, []):
            responses["body"] = bad
            try:
                credit_request_ids("P", "approved", "x")
                raise AssertionError(f"schema drift must raise, got body={bad!r}")
            except RuntimeError:
                pass
        responses["body"] = {"data": {"items": []}}
        assert credit_request_ids("P", "approved", "x") == set()
        responses["body"] = {"data": {"items": [{"id": "CR1"}, {"noid": 1}]}}
        assert credit_request_ids("P", "approved", "x") == {"CR1"}
    finally:
        globals()["muso_read_api_get"] = saved_get

    # _reconcile_line render: recoverable framing + counts; None/nothing-checked ->
    # explicit "not checked" (never silently dropped); 0 routed -> no line at all.
    assert _reconcile_line(None, 0) is None
    assert "not checked" in _reconcile_line(None, 3)
    rl = _reconcile_line({"checked": 2, "approved": 1, "pending": 1, "other": 0, "errors": 0}, 2)
    assert "1 later approved by a human" in rl and "recoverable" in rl, rl
    # A COMPUTED reconciliation renders even when the capability audit's route
    # count is 0 (different files can lag/rotate independently)...
    assert "later approved" in _reconcile_line(
        {"checked": 1, "approved": 1, "pending": 0, "other": 0, "errors": 0}, 0)
    # ...but an all-zero reconcile dict is 'nothing computed', not a disposition.
    assert _reconcile_line(
        {"checked": 0, "approved": 0, "pending": 0, "other": 0, "errors": 0}, 0) is None

    # build_digest with the new signature: dominant-action-first headline, the UVN
    # approve/route line, the reopen-after-auto-close line, and the 0-notify
    # clarifier (0 notifies despite closes) -- which must NOT assert "--apply off".
    txt = build_digest(s, s, s, {"closes_7d": 5, "notifies_7d": 0},
                       None, None, {"checked": 5, "reopened": 1, "errors": 0},
                       ([], []), {"success": 0})
    assert "5 conversation(s) auto-closed" in txt, ("headline leads with closes", txt)
    assert "UVN credit verification" in txt and "1 approved" in txt, ("UVN line", txt)
    assert "0 routed to a human" in txt, ("UVN route count", txt)
    assert "Reopen-after-auto-close" in txt and "1/5" in txt, ("close-reopen line", txt)
    assert "cold-start seed" in txt and "still dry-run" not in txt, ("0-notify clarifier", txt)
    assert "integrity-holds" in txt, ("autonomy reframe line present", txt)

    # build_digest with routes present: the reconcile line renders the recoverable
    # framing when a reconcile dict is supplied, and an explicit "not checked" when
    # None (routes present but disposition not looked up -- never silently dropped).
    routed_caps = capability_records([
        {"tool": "credits_verify", "decision": "refused", "ts": _iso(now - 30),
         "actor_identity": "real@cust.com", "result": "no corroboration"}])
    s_routed = summarize(routed_caps, now, DAY)
    assert s_routed["per_verb_real"]["credits_verify"]["route_to_human"] == 1, s_routed
    txt2 = build_digest(s_routed, s_routed, s_routed, {"closes_7d": 1, "notifies_7d": 1},
                        None, None, None, ([], []), {"success": 0},
                        reconcile={"checked": 1, "approved": 1, "pending": 0,
                                   "other": 0, "errors": 0})
    assert "1 later approved by a human" in txt2 and "recoverable" in txt2, ("reconcile line", txt2)
    txt3 = build_digest(s_routed, s_routed, s_routed, {"closes_7d": 1, "notifies_7d": 1},
                        None, None, None, ([], []), {"success": 0})
    assert "disposition not checked" in txt3, ("routes present + None reconcile -> not checked", txt3)
    return True


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--post", action="store_true",
                    help="post to Slack + write trend state (default: --check)")
    ap.add_argument("--self-test", action="store_true",
                    help="run the inline self-test and exit")
    args = ap.parse_args()

    now = int(os.environ.get("CAROLINE_DIGEST_NOW") or time.time())

    try:
        _self_test(now)
    except AssertionError as e:
        print(f"caroline-behavior-digest: SELF-TEST FAILED: {e}", file=sys.stderr)
        return 2
    if args.self_test:
        print("self-test ok")
        return 0

    if os.environ.get("CAROLINE_DIGEST_SKIP_HOST_GUARD") != "1" \
            and socket.gethostname() != "ovh-node-8":
        print("caroline-behavior-digest: not on ovh-node-8 — refusing "
              "(set CAROLINE_DIGEST_SKIP_HOST_GUARD=1 to override)", file=sys.stderr)
        return 0

    state_dir = os.environ.get("MUSO_OPS_STATE_DIR", "/var/log/muso-ops")
    audit_path = os.environ.get("CAROLINE_DIGEST_AUDIT",
                                os.path.join(state_dir, "tier2-audit.jsonl"))
    wrapper_logs = (os.environ["CAROLINE_DIGEST_WRAPPER_LOGS"].split(":")
                    if os.environ.get("CAROLINE_DIGEST_WRAPPER_LOGS")
                    else list(DEFAULT_WRAPPER_LOGS))
    shadow_path = os.environ.get("CLOSE_RESOLVED_SHADOW",
                                 "/var/log/close-resolved-shadow.jsonl")
    resolve_log = os.environ.get("RESOLVE_NOTIFY_LOG", "/var/log/resolve-notify.log")
    overdue_log = os.environ.get("OVERDUE_NOTIFY_LOG",
                                 "/var/log/overdue-verification-notifier.log")
    digest_state = os.environ.get("CAROLINE_DIGEST_STATE",
                                  "/var/lib/caroline-behavior-digest/state.json")
    # Append-only trend series. Lives beside state.json under /var/lib (NOT
    # /opt/hydra, which the deploy rsync overwrites).
    digest_history = os.environ.get("CAROLINE_DIGEST_HISTORY",
                                    "/var/lib/caroline-behavior-digest/history.jsonl")
    apply_ceiling = int(os.environ.get("CAROLINE_DIGEST_APPLY_CEILING", "40"))
    reopen_cap = int(os.environ.get("CAROLINE_DIGEST_REOPEN_MAX", "300"))
    # Route reconciliation (--post only): the read-only muso-read wrapper command
    # prefix + a per-run profile cap. Default assumes muso-read.sh is on PATH;
    # the systemd unit pins the deployed path. Empty -> reconciliation is skipped
    # (rendered as "not checked"), never a crash.
    muso_read_bin = os.environ.get("CAROLINE_DIGEST_MUSO_READ", "muso-read.sh")
    reconcile_cap = int(os.environ.get("CAROLINE_DIGEST_RECONCILE_MAX", "60"))

    audit, malformed = read_jsonl(audit_path)
    caps = capability_records(audit)
    s24 = summarize(caps, now, DAY)
    s7 = summarize(caps, now, 7 * DAY)
    # All-time (window=now -> lo=0): cumulative UVN approved/routed counts, so the
    # digest shows the running total alongside the 7d slice.
    s_all = summarize(caps, now, now)

    wrap24 = read_wrapper_audits(wrapper_logs, now, DAY)
    misconfig24 = misconfig_counts(wrap24)
    wrap7 = read_wrapper_audits(wrapper_logs, now, 7 * DAY)
    selfserve_events = selfserve_reopen_events(wrap7)
    routed7 = routed_credit_requests(wrap7)  # credits the muso gate routed to a human

    shadow, _ = read_jsonl(shadow_path)
    # close-resolved-conversations.py shadow-logs {id, closed_at(epoch), email,
    # new_state} -- the timestamp is closed_at, NOT ts (ts kept as a fallback so a
    # future format change degrades visibly, not to a silent 0).
    closes_7d = sum(1 for r in shadow if isinstance(r, dict)
                    and (parse_ts(r.get("closed_at") or r.get("ts")) or 0) >= now - 7 * DAY)
    # (conv_id, closed_at) for each auto-close in 7d -- feeds reopen-after-close,
    # the quality signal on the dominant autonomous action. A customer reply strictly
    # after we closed a resolved conversation = a premature/contested close.
    close_events = [(str(r["id"]), parse_ts(r.get("closed_at") or r.get("ts")))
                    for r in shadow if isinstance(r, dict) and r.get("id")
                    and (parse_ts(r.get("closed_at") or r.get("ts")) or 0) >= now - 7 * DAY]
    resolve_sends = [(c, t) for c, t in read_sends(resolve_log) if t >= now - 7 * DAY]
    overdue_sends = [(c, t) for c, t in read_sends(overdue_log) if t >= now - 7 * DAY]
    # Ops-relief counts ALL proactive notifies (both notifiers). But reopen-after-
    # DONE measures replies after the resolve-notify "your request is sorted" note
    # ONLY -- the overdue notifier sends a "still working / taken longer" SLA nudge,
    # which is NOT a "done" note, so mixing it would pollute the core quality signal.
    notifies_7d = len(resolve_sends) + len(overdue_sends)
    ops = {"closes_7d": closes_7d, "notifies_7d": notifies_7d}

    # OPS_DRY_RUN kill switch: the wrappers _emit_error + exit BEFORE _audit on
    # OPS_DRY_RUN=1, so it is never in the wrapper logs. Detect it directly from
    # this process's env -- the systemd unit loads /etc/openclaw/edge.env, where
    # the documented pause lever sets it.
    kill_switch = os.environ.get("OPS_DRY_RUN") == "1"
    anomalies = detect_anomalies(s24, misconfig24, kill_switch, malformed, apply_ceiling)
    crit, warn = anomalies
    # Read the REAL-format snapshot. A pre-this-change state file only has the old
    # full-count "snapshot7" key, so a freshly-deployed digest finds no prev and
    # shows no delta on its first run (correct) rather than subtracting a
    # full-count prev from a real-count current.
    prev7 = load_state(digest_state).get("snapshot7_real")

    reopen_selfserve = reopen_done = reopen_close = None
    reconcile = None
    rc = 0
    if args.post:
        # Reconcile routed credits against the human's eventual decision. Bounded,
        # read-only, per-profile try/except inside reconcile_routes; a total failure
        # here degrades to "not checked", never sinks the digest. The strip() guard
        # makes an EMPTY CAROLINE_DIGEST_MUSO_READ actually skip (reconcile stays
        # None -> "not checked"), instead of shlex-splitting to [] and exec'ing a
        # bare "api" off PATH with every route then shown as "unresolved".
        if routed7 and muso_read_bin.strip():
            try:
                reconcile = reconcile_routes(routed7, muso_read_bin, reconcile_cap)
            except Exception as ex:  # noqa: BLE001
                print(f"WARN: route reconciliation failed: {type(ex).__name__}: {ex}",
                      file=sys.stderr)
        token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
        if token:
            try:
                c, r, e = reopen_rate(selfserve_events, token, now, 7 * DAY, reopen_cap)
                reopen_selfserve = {"checked": c, "reopened": r, "errors": e}
                # resolve-notify sends ONLY (not overdue) -- see note above.
                c, r, e = reopen_rate(resolve_sends, token, now, 7 * DAY, reopen_cap)
                reopen_done = {"checked": c, "reopened": r, "errors": e}
                # the auto-close loop's quality signal.
                c, r, e = reopen_rate(close_events, token, now, 7 * DAY, reopen_cap)
                reopen_close = {"checked": c, "reopened": r, "errors": e}
            except Exception as ex:  # noqa: BLE001
                print(f"WARN: reopen lookup failed: {type(ex).__name__}: {ex}",
                      file=sys.stderr)
        else:
            print("WARN: MUSOAI_INTERCOM_TOKEN unset; reopen lookups skipped",
                  file=sys.stderr)
            reopen_selfserve = reopen_done = reopen_close = {
                "checked": 0, "reopened": 0, "errors": 0}

    history, hist_readable, hist_writable = load_history(digest_history)
    # An unwritable log only breaks the SERIES if this run was going to extend
    # it, which only --post does.
    history_ok = hist_readable and (hist_writable or not args.post)
    if not history_ok:
        why = "could not be read" if not hist_readable else "is not writable, so the series cannot grow"
        print(f"WARN: trend history at {digest_history} {why}; "
              "the digest will say the trend is unavailable rather than young",
              file=sys.stderr)
    text = build_digest(s24, s7, s_all, ops, reopen_selfserve, reopen_done,
                        reopen_close, anomalies, prev7, reconcile=reconcile,
                        history=history, now_ts=now,
                        history_readable=history_ok)
    summary = {"now": now, "s24_totals": s24["totals"], "s7_totals": s7["totals"],
               "s7_totals_real": s7["totals_real"], "ops": ops,
               "uvn_7d": s7["per_verb_real"]["credits_verify"],
               "uvn_all": s_all["per_verb_real"]["credits_verify"],
               "routed7_count": len(routed7), "route_reconcile": reconcile,
               "misconfig24": misconfig24, "kill_switch": kill_switch,
               "reopen_selfserve": reopen_selfserve, "reopen_done": reopen_done,
               "reopen_close": reopen_close,
               "critical": crit, "warn": warn, "malformed_audit_lines": malformed}
    if not args.post:
        print(json.dumps(summary, sort_keys=True))
        return 0

    channel = os.environ.get("CAROLINE_DIGEST_CHANNEL", DEFAULT_CHANNEL)
    cfg = os.environ.get("SLACK_NOTIFY_CONFIG", "/root/.openclaw-main/openclaw.json")
    account = os.environ.get("CAROLINE_DIGEST_SLACK_ACCOUNT", "operations")
    if not post_slack(text, channel, cfg, account):
        rc = 3

    # Resolved unconditionally: the failed-append alert below needs them too, and
    # they were previously bound only inside `if crit:`, so a run with no critical
    # anomaly would have raised NameError on that path.
    alert_ch = os.environ.get("CAROLINE_DIGEST_ALERT_CHANNEL", DEFAULT_ALERT_CHANNEL)
    mentions = (os.environ.get("CAROLINE_DIGEST_PAGE_MENTION", DEFAULT_PAGE_MENTION)).split()
    ping = " ".join(f"<@{m}>" for m in mentions if m)

    if crit:
        alert = (f":rotating_light: *Caroline autonomy — CRITICAL* {ping}\n"
                 + "\n".join(f"• {c}" for c in crit))
        if not post_slack(alert, alert_ch, cfg, account):
            rc = 3

    # snapshot the REAL-customer totals under a real-format-specific key -- the
    # headline's WoW delta is real-to-real and never reads a stale full-count snap.
    write_state(digest_state, {"snapshot7_real": s7["totals_real"], "ts": now})
    # ...and append the same measurement to the series. Recorded only on --post,
    # so a --check run (which the improver uses) can never pollute the trend with
    # an off-schedule sample.
    _applied, _attempted, _pct = autonomy_rate(s7["totals_real"])
    appended = append_history(digest_history, {
        "ts": now,
        "date": time.strftime("%Y-%m-%d", time.gmtime(now)),
        "iso_week": time.strftime("%G-W%V", time.gmtime(now)),
        "totals_real": s7["totals_real"],
        "autonomy_applied": _applied,
        "autonomy_attempted": _attempted,
        "autonomy_pct": round(_pct, 2) if _pct is not None else None,
        "closes_7d": ops.get("closes_7d"),
        "notifies_7d": ops.get("notifies_7d"),
    })
    # os.access can say writable while the write still fails (a full disk, a
    # quota, a filesystem that went read-only between the probe and the append).
    # The digest has already posted by now, so this cannot change the headline --
    # but an append that fails every day freezes the baseline forever, and only
    # stderr would record it. Alert, and make the exit code non-zero so the
    # systemd unit shows failed.
    if not appended:
        post_slack(f":warning: *Caroline autonomy trend is not being recorded* {ping}\n"
                   f"• `append_history` failed writing `{digest_history}` on {socket.gethostname()}. "
                   f"The digest still posted, but the series has stopped growing, so the "
                   f"four-week baseline will freeze and then silently go stale.",
                   alert_ch, cfg, account)
        rc = 3
    print(json.dumps(summary, sort_keys=True))
    return rc


if __name__ == "__main__":
    sys.exit(main())
