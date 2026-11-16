#!/usr/bin/env bash
# bats-main-report.sh: raise or resolve the BatsOnMainRed alert for a finished "Bats on
# main" run, post what it found to the channel, and fail when either did not land.
#
# 2026-11-15. Run by .github/workflows/bats-main-report.yml on node-8, the one CI
# host that holds the Slack bot token (the pods that run Bats deliberately carry
# none). scripts/ci/bats-main-report.py decides what is said; this delivers it.
#
# NOBODY IS MENTIONED (firstmate on #2048, inbox 035, 2026-11-15; Aaron's rule: no
# Slack ping and no task to any person). A red main is a task for the `ci` lane, and
# the task path is Alertmanager: the alert carries owner=ci, and the lights second
# mate's dispatcher turns it into one task. So the alert is posted FIRST, and the
# channel message (which mentions nobody) after it. Neither the Slack-id map nor
# slack_notify_critical_status (which mentions people) is used here.
#
# Alertmanager is the in-cluster Service below. node-8 is a K3s node, so its host
# reaches the ClusterIP, but its resolver does not know *.svc names: the name is
# looked up with one A query to kube-dns, the way scripts/credit-digest-dm.sh does,
# and BATS_MAIN_AM_IP pins the address.
#
# A report that cannot report its own failure is the same silence one level up, so:
#   - an alert Alertmanager did not accept, or a message Slack did not confirm,
#     fails this job with an ::error::;
#   - when the report cannot be built at all and the run was not green, the alert is
#     raised anyway with the run link, the channel is told, and the job still fails,
#     so the broken reporter is seen too.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${BATS_MAIN_REPORT_LIB:-$HERE/../lib/slack-notify.sh}"
AM_HOST="${BATS_MAIN_AM_HOST:-kube-prometheus-kube-prome-alertmanager.monitoring.svc.cluster.local}"
AM_PORT="${BATS_MAIN_AM_PORT:-9093}"
KUBE_DNS="${BATS_MAIN_KUBE_DNS:-10.43.0.10}"
CURL_BIN="${BATS_MAIN_CURL:-curl}"
RESULT="${RESULT:-}"
RUN_URL="${SERVER_URL:-https://github.com}/${REPO:-}/actions/runs/${RUN_ID:-}"

die() { echo "::error::$1"; exit 1; }

# shellcheck source=/dev/null
[ -r "$LIB" ] && . "$LIB"
if ! command -v slack_notify_payload_file_status >/dev/null 2>&1; then
  die "Bats on main finished '$RESULT' and the channel could not be told: the Slack notifier ($LIB) did not load. Run: $RUN_URL"
fi

payload="$(mktemp "${RUNNER_TEMP:-/tmp}/bats-main-report.XXXXXX")" \
  || die "Bats on main finished '$RESULT' and nothing could be told: mktemp failed. Run: $RUN_URL"
alert="$payload.alert"
trap 'rm -f "$payload" "$alert"' EXIT

# am_ip: the Alertmanager Service's address (the host resolver first, else kube-dns).
am_ip() {
  local ip="${BATS_MAIN_AM_IP:-}"
  [ -n "$ip" ] || ip="$(getent hosts "$AM_HOST" 2>/dev/null | awk '{print $1; exit}')"
  [ -n "$ip" ] || ip="$(python3 - "$AM_HOST" "$KUBE_DNS" <<'PY' 2>/dev/null
import random, socket, struct, sys
name, server = sys.argv[1], sys.argv[2]
qid = random.randint(0, 65535)
q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0) + b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0" + struct.pack(">HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3); s.sendto(q, (server, 53))
r, _ = s.recvfrom(2048)
if struct.unpack(">H", r[:2])[0] != qid: sys.exit(1)
an = struct.unpack(">H", r[6:8])[0]; i = 12
while r[i]: i += r[i] + 1
i += 5
for _ in range(an):
    i += 2 if r[i] & 0xC0 == 0xC0 else (r.index(b"\0", i) + 1 - i)
    t, _, _, ln = struct.unpack(">HHIH", r[i:i + 10]); i += 10
    if t == 1 and ln == 4: print(socket.inet_ntoa(r[i:i + 4])); sys.exit(0)
    i += ln
sys.exit(1)
PY
)"
  printf '%s' "$ip"
}

# post_alert: hand the alert file to Alertmanager. 0 only when it answered 2xx.
alert_ok=1
post_alert() {
  [ -s "$alert" ] || return 0
  local ip
  ip="$(am_ip)"
  if [ -z "$ip" ]; then
    echo "::error::the BatsOnMainRed alert was NOT raised: $AM_HOST could not be resolved (kube-dns $KUBE_DNS)."
    alert_ok=0; return 1
  fi
  if "$CURL_BIN" -sS --fail -m 20 -o /dev/null -H 'Content-Type: application/json' \
       --data-binary @"$alert" "http://$ip:$AM_PORT/api/v2/alerts"; then
    if grep -q '"endsAt"' "$alert" && python3 -c 'import json,sys,datetime as d; a=json.load(open(sys.argv[1]))[0]; sys.exit(0 if d.datetime.strptime(a["endsAt"][:19],"%Y-%m-%dT%H:%M:%S").replace(tzinfo=d.timezone.utc) > d.datetime.now(d.timezone.utc) else 1)' "$alert"; then
      echo "Raised BatsOnMainRed (owner=ci) in Alertmanager: the ci lane gets it through lights."
    else
      echo "Resolved BatsOnMainRed in Alertmanager."
    fi
    return 0
  fi
  echo "::error::the BatsOnMainRed alert was NOT accepted by Alertmanager at $ip:$AM_PORT."
  alert_ok=0; return 1
}

SLACK_CHANNEL="${SLACK_CHANNEL:-}" python3 "$HERE/bats-main-report.py" --out "$payload" --alert "$alert"
rc=$?

case "$rc" in
  0)
    post_alert
    [ "$alert_ok" = 1 ] || die "Bats on main finished '$RESULT' and the alert above did not land. Run: $RUN_URL"
    exit 0
    ;;
  10)
    post_alert
    if slack_notify_payload_file_status "$payload"; then
      echo "Posted to Slack."
      [ "$alert_ok" = 1 ] || die "Bats on main finished '$RESULT': the channel was told, but the BatsOnMainRed alert was NOT raised, so no lane has the task. Run: $RUN_URL"
      exit 0
    fi
    die "Bats on main finished '$RESULT' and the message above was NOT posted to Slack. Check MUSO_SLACK_BOT_TOKEN_DEVOPS in /etc/openclaw/main.env on node-8. Run: $RUN_URL"
    ;;
  3)
    # A green run whose order could not be read (QA on #2048 at e2b6d2f): resolving
    # could clear a NEWER red run's alert, so nothing is posted and the job fails, so
    # the unresolved alert is seen. The next green run resolves it.
    [ "$RESULT" = "success" ] \
      || die "the report answered 'order unknown' (exit 3) on a '$RESULT' run, which only a green run may; the reporter is broken. Run: $RUN_URL"
    die "Bats on main is green, but the earlier runs could not be read, so it is unknown whether a newer red run raised BatsOnMainRed; it was NOT resolved. A later green run resolves it. Run: $RUN_URL"
    ;;
  *)
    if [ "$RESULT" = "success" ]; then
      die "the report on a green Bats on main run could not be built (exit $rc), so BatsOnMainRed was not resolved and the reporter is broken. Run: $RUN_URL"
    fi
    why="the report on it could not be built, so what failed and what merged are not listed"
    export RESULT RUN_URL
    TEXT=":red_circle: *Bats on main finished '$RESULT'* and $why. It is a task for the \`ci\` lane (alert \`BatsOnMainRed\`, owner=ci, dispatched by lights); nobody is mentioned. Run: $RUN_URL" \
      WHY="$why" REPO="${REPO:-}" HEAD_SHA="${HEAD_SHA:-}" \
      CHANNEL="${SLACK_CHANNEL:-}" python3 - "$alert" "$payload" <<'PY' \
      || die "Bats on main finished '$RESULT', the report could not be built (exit $rc) and neither could the fallback alert, so nothing was told. Run: $RUN_URL"
import json, os, sys
from datetime import datetime, timedelta, timezone
e = os.environ
end = (datetime.now(timezone.utc) + timedelta(hours=26)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
json.dump([{"labels": {"alertname": "BatsOnMainRed", "owner": "ci", "severity": "warning", "namespace": "ci", "repo": e["REPO"]},
            "annotations": {"summary": f"Bats on main in {e['REPO']} finished {e['RESULT']} at {e['HEAD_SHA'][:7]} ({e['WHY']})",
                            "description": f"Open the run, then fix it forward or revert. Run: {e['RUN_URL']}",
                            "run_url": e["RUN_URL"], "head": e["HEAD_SHA"]},
            "endsAt": end, "generatorURL": e["RUN_URL"]}], open(sys.argv[1], "w"))
json.dump({"channel": e["CHANNEL"], "text": e["TEXT"]}, open(sys.argv[2], "w"))
PY
    post_alert
    if slack_notify_payload_file_status "$payload"; then
      [ "$alert_ok" = 1 ] && die "the report could not be built (exit $rc). BatsOnMainRed was raised with the run link instead, and the channel was told. Run: $RUN_URL"
      die "the report could not be built (exit $rc) and the BatsOnMainRed alert was NOT raised; only the channel was told. Run: $RUN_URL"
    fi
    die "Bats on main finished '$RESULT', the report could not be built (exit $rc) and the channel message was NOT posted. Run: $RUN_URL"
    ;;
esac
