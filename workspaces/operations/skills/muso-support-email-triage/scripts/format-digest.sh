#!/usr/bin/env bash
# Phase 3 format + emit (deterministic). Joins ${WORKDIR}/emails.json (fetch,
# authoritative for counts/subjects/senders/links) with ${WORKDIR}/verdicts.json
# (LLM-authored verdict/description/reason) by threadId, prints a Slack mrkdwn
# digest to stdout, then scrubs $WORKDIR.
#
# Outcomes:
#   - 0 threads             -> prints exactly NO_REPLY (cron stays silent).
#   - >=1 thread            -> prints header + one bullet per thread (cap 25 +
#                              "...and N more" overflow).
#   - reconciliation failure -> exits non-zero with a clear message; NEVER emits
#                              a partial/fabricated digest (Rule 13, fail loud).
#
# Requires $WORKDIR exported by preflight.sh.

set -euo pipefail

: "${WORKDIR:?WORKDIR not set — source preflight.sh first}"
EMAILS="${WORKDIR}/emails.json"
VERDICTS="${WORKDIR}/verdicts.json"

[ -f "$EMAILS" ] || { echo "format-digest: ${EMAILS} missing (fetch did not run)" >&2; exit 1; }
[ -f "$VERDICTS" ] || { echo "format-digest: ${VERDICTS} missing (classify step did not write it)" >&2; exit 1; }

# Emit digest to stdout (or NO_REPLY) and reconcile. Python exits non-zero on any
# malformed/unreconcilable input so the agent re-derives verdicts rather than
# shipping a wrong digest.
# Scrub customer PII only on the success path (the trailing rm below).
# preflight's INT/TERM trap covers interrupt/timeout; on a reconciliation
# failure `set -e` exits here, leaving the fetch data in place for the agent
# to re-derive verdicts and re-run.
python3 - "$EMAILS" "$VERDICTS" <<'PY'
import sys, json, re

emails_path, verdicts_path = sys.argv[1], sys.argv[2]
MAX_LINES = 25

def die(msg):
    print("format-digest: " + msg, file=sys.stderr)
    sys.exit(1)

try:
    with open(emails_path) as f:
        emails = json.load(f)
except (OSError, ValueError) as e:
    die("emails.json unreadable/malformed: %s" % e)

if not isinstance(emails, list):
    die("emails.json is not a JSON array")

# 0 threads -> silent.
if len(emails) == 0:
    print("NO_REPLY")
    sys.exit(0)

try:
    with open(verdicts_path) as f:
        verdicts = json.load(f)
except (OSError, ValueError) as e:
    die("verdicts.json unreadable/malformed: %s" % e)

if not isinstance(verdicts, list):
    die("verdicts.json is not a JSON array")

email_by_tid = {}
for e in emails:
    tid = e.get("threadId")
    if not tid:
        die("an emails.json entry is missing threadId")
    email_by_tid[tid] = e

verdict_by_tid = {}
for v in verdicts:
    tid = v.get("threadId")
    if not tid:
        die("a verdicts.json entry is missing threadId")
    if tid not in email_by_tid:
        die("verdicts.json references threadId %r not in emails.json (no fabricated rows)" % tid)
    vd = v.get("verdict")
    if vd not in ("caroline", "human"):
        die("verdicts.json threadId %r has invalid verdict %r (want caroline|human)" % (tid, vd))
    verdict_by_tid[tid] = v

# Every email thread must have exactly one verdict.
missing = [t for t in email_by_tid if t not in verdict_by_tid]
if missing:
    die("%d thread(s) in emails.json have no verdict: %s" % (len(missing), ", ".join(missing[:5])))

def slack_escape(s):
    # Per scripts/close-resolved-conversations.py:_slack_escape — escape & < >
    # in that exact order so the & in the entities is not re-escaped.
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def no_emdash(s):
    # No em-dashes in the output (Caroline voice rule). Normalize em/en dash and
    # the horizontal-bar variants to a plain hyphen.
    return re.sub(r"[‒–—―]", "-", str(s))

n = len(emails)
n_caroline = sum(1 for v in verdict_by_tid.values() if v["verdict"] == "caroline")
n_human = n - n_caroline

header = (":envelope: *support@ triage* · last 1h · %d new · "
          "%d Caroline-can-handle · %d need a human") % (n, n_caroline, n_human)
lines = [no_emdash(header)]

# Preserve emails.json order (fetch order = newest-first).
ordered_tids = [e["threadId"] for e in emails]
for tid in ordered_tids[:MAX_LINES]:
    e = email_by_tid[tid]
    v = verdict_by_tid[tid]
    url = e.get("url") or ""
    subject = no_emdash(slack_escape(e.get("subject") or "(no subject)"))
    desc = no_emdash(slack_escape(v.get("description") or ""))
    reason = no_emdash(slack_escape(v.get("reason") or ""))
    if v["verdict"] == "caroline":
        tag = ":white_check_mark: Caroline-can-handle"
    else:
        tag = ":raising_hand: needs a human"
    link = "<%s|%s>" % (url, subject) if url else subject
    lines.append("• %s - %s · %s (%s)" % (link, desc, tag, reason))

if n > MAX_LINES:
    lines.append("...and %d more" % (n - MAX_LINES))

print("\n".join(lines))
PY

rm -rf "$WORKDIR"
