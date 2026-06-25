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
     (idempotent); dry_run (preview)). This is the AUTHORITATIVE per-verb OUTCOME
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
    notifies sent -- with a clarifier when 0 notifies despite auto-closes flags
    the resolve/overdue notifiers as still dry-run (--apply off).
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
import json
import os
import socket
import sys
import time
import urllib.error
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
               "preview": 0, "authorized": 0, "unclassified": 0} for v in VERBS}
    # Same shape, counting ONLY real-customer actors -- the smoke/test actors
    # (go-live probes: smoketest@, not-the-owner@) inflate the verb counts but are
    # not customer service; the DISPLAY uses per_verb_real, anomalies use per_verb.
    per_real = {v: {"success": 0, "route_to_human": 0, "backend_refused": 0,
                    "preview": 0, "authorized": 0, "unclassified": 0} for v in VERBS}
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
              "preview": 0, "authorized": 0, "unclassified": 0}
    totals_real = {"success": 0, "route_to_human": 0, "backend_refused": 0,
                   "preview": 0, "authorized": 0, "unclassified": 0}
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


def build_digest(s24, s7, s_all, ops, reopen_selfserve, reopen_done, reopen_close,
                 anomalies, prev7):
    """Compose the #cs_chats digest text. Pure (no I/O)."""
    crit, warn = anomalies
    lines = [":robot_face: *Caroline autonomy — daily behavior digest*"]

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
    # Disambiguate a 0-notify headline: 0 despite auto-closes means the resolve/
    # overdue notifiers are almost certainly still dry-run (--apply not enabled),
    # NOT that there was nothing to tell customers.
    if ops["notifies_7d"] == 0:
        if ops["closes_7d"] > 0:
            lines.append(
                f"_Note: 0 proactive notifies despite {ops['closes_7d']} auto-closes "
                "— the resolve/overdue notifiers are likely still dry-run (`--apply` "
                "off), so customers aren't getting a 'your request is done' note._")
        else:
            lines.append("_Note: 0 proactive notifies — nothing to notify yet._")

    lines.append("*Verb outcomes — real customers (24h):*")
    for v in VERBS:
        lines.append(_verb_line(v, s24["per_verb_real"][v]))

    lines.append(_uvn_line(s7["per_verb_real"]["credits_verify"],
                           s_all["per_verb_real"]["credits_verify"]))

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

    # build_digest with the new signature: dominant-action-first headline, the UVN
    # approve/route line, the reopen-after-auto-close line, and the dry-run notify
    # clarifier (0 notifies despite closes).
    txt = build_digest(s, s, s, {"closes_7d": 5, "notifies_7d": 0},
                       None, None, {"checked": 5, "reopened": 1, "errors": 0},
                       ([], []), {"success": 0})
    assert "5 conversation(s) auto-closed" in txt, ("headline leads with closes", txt)
    assert "UVN credit verification" in txt and "1 approved" in txt, ("UVN line", txt)
    assert "0 routed to a human" in txt, ("UVN route count", txt)
    assert "Reopen-after-auto-close" in txt and "1/5" in txt, ("close-reopen line", txt)
    assert "still dry-run" in txt, ("notify-dormant clarifier", txt)
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
    apply_ceiling = int(os.environ.get("CAROLINE_DIGEST_APPLY_CEILING", "40"))
    reopen_cap = int(os.environ.get("CAROLINE_DIGEST_REOPEN_MAX", "300"))

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
    rc = 0
    if args.post:
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

    text = build_digest(s24, s7, s_all, ops, reopen_selfserve, reopen_done,
                        reopen_close, anomalies, prev7)
    summary = {"now": now, "s24_totals": s24["totals"], "s7_totals": s7["totals"],
               "s7_totals_real": s7["totals_real"], "ops": ops,
               "uvn_7d": s7["per_verb_real"]["credits_verify"],
               "uvn_all": s_all["per_verb_real"]["credits_verify"],
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

    if crit:
        alert_ch = os.environ.get("CAROLINE_DIGEST_ALERT_CHANNEL", DEFAULT_ALERT_CHANNEL)
        mentions = (os.environ.get("CAROLINE_DIGEST_PAGE_MENTION", DEFAULT_PAGE_MENTION)).split()
        ping = " ".join(f"<@{m}>" for m in mentions if m)
        alert = (f":rotating_light: *Caroline autonomy — CRITICAL* {ping}\n"
                 + "\n".join(f"• {c}" for c in crit))
        if not post_slack(alert, alert_ch, cfg, account):
            rc = 3

    # snapshot the REAL-customer totals under a real-format-specific key -- the
    # headline's WoW delta is real-to-real and never reads a stale full-count snap.
    write_state(digest_state, {"snapshot7_real": s7["totals_real"], "ts": now})
    print(json.dumps(summary, sort_keys=True))
    return rc


if __name__ == "__main__":
    sys.exit(main())
