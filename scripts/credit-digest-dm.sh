#!/bin/bash
# credit-digest-dm.sh: credit gate #7 (Fable data/captain-calls-fable-d5/credit-gate-1019.md;
# firstmate 081, host decision (a)). At 08:00 New York the Ops SOUL cron fetches the
# credit-trust board's Block Kit digest (GET /api/digest/slack, H-DevOps #4242) and DMs it to
# Jan (Head of Operations, U038BM16T7W) as the operations bot. Read-only on the board; the
# veto / confirm buttons open the board, where core decides.
#
#   - Board: the in-cluster Service credit-trust-board.monitoring:3000. node-8's host resolver
#     does not know *.svc names, so the name is resolved against kube-dns (10.43.0.10);
#     CREDIT_DIGEST_BOARD_IP pins it.
#   - Auth: the board's agent token (Vault secret/k8s/monitoring/credit-trust-board key
#     agent_token) from CREDIT_DIGEST_ENV (/etc/hydra/credit-trust-board.env,
#     CREDIT_TRUST_BOARD_AGENT_TOKEN=...). Never printed or logged.
#   - 503 waiting_for_data (no ledger connected yet): nothing is sent (never an empty digest).
#   - Once per New York day (state file), kill switch /etc/hydra/credit-digest-dm.disabled.
# Stdout is the cron's announce channel: NO_REPLY when quiet; one line on a failure. Exit 1 on
# any failure that means Jan did not get a digest that was due.
set -euo pipefail

ENV_FILE="${CREDIT_DIGEST_ENV:-/etc/hydra/credit-trust-board.env}"
KILL="${CREDIT_DIGEST_KILL_SWITCH:-/etc/hydra/credit-digest-dm.disabled}"
STATE_DIR="${CREDIT_DIGEST_STATE_DIR:-/var/lib/hydra/credit-digest-dm}"
BOARD_HOST="${CREDIT_DIGEST_BOARD_HOST:-credit-trust-board.monitoring.svc.cluster.local}"
BOARD_PORT="${CREDIT_DIGEST_BOARD_PORT:-3000}"
KUBE_DNS="${CREDIT_DIGEST_KUBE_DNS:-10.43.0.10}"
JAN_UID="U038BM16T7W"
CURL_BIN="${CREDIT_DIGEST_CURL:-curl}"
SLACK_LIB="${CREDIT_DIGEST_SLACK_LIB:-/opt/hydra/scripts/lib/slack-notify.sh}"

say() { printf '%s\n' "$*"; }
fail() { say "credit digest DM to Jan NOT sent: $*"; exit 1; }

if [ -e "$KILL" ]; then say "NO_REPLY"; exit 0; fi
DAY="$(TZ=America/New_York date -d 'yesterday' +%F 2>/dev/null || TZ=America/New_York date -v-1d +%F)"
mkdir -p "$STATE_DIR"
# One DM per New York day even when runs overlap (a scheduler retry over a slow run, a manual
# rerun; QA @c7cef1e): an exclusive lock is held from the marker check through the send and the
# marker write. A second run waits, then sees the marker. flock(1) is on node-8; elsewhere
# (macOS dev) a mkdir lock does the same.
LOCK="$STATE_DIR/.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock -w 300 9 || fail "another digest run held the lock for 5 minutes"
else
  for _ in $(seq 1 300); do mkdir "$LOCK.d" 2>/dev/null && break; sleep 1; done
  [ -d "$LOCK.d" ] || fail "another digest run held the lock for 5 minutes"
  trap 'rmdir "$LOCK.d" 2>/dev/null' EXIT
fi
if [ -e "$STATE_DIR/sent-$DAY" ]; then say "NO_REPLY"; exit 0; fi

[ -r "$ENV_FILE" ] || fail "board agent token file $ENV_FILE is missing"
TOKEN="$(sed -n 's/^CREDIT_TRUST_BOARD_AGENT_TOKEN=//p' "$ENV_FILE" | head -1)"
[ -n "$TOKEN" ] || fail "CREDIT_TRUST_BOARD_AGENT_TOKEN is empty in $ENV_FILE"

# Resolve the Service name: the host resolver first, else one A query to kube-dns.
resolve() {
  local ip
  ip="$(getent hosts "$BOARD_HOST" 2>/dev/null | awk '{print $1; exit}')"
  if [ -z "$ip" ]; then
    ip="$(python3 - "$BOARD_HOST" "$KUBE_DNS" <<'PY'
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
)" || true
  fi
  printf '%s' "$ip"
}
IP="${CREDIT_DIGEST_BOARD_IP:-}"
[ -n "$IP" ] || IP="$(resolve)"
[ -n "$IP" ] || fail "cannot resolve $BOARD_HOST"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; rmdir "$LOCK.d" 2>/dev/null || true' EXIT
HDR="$TMP/h"; printf 'X-Credit-Trust-Token: %s\n' "$TOKEN" > "$HDR"; chmod 600 "$HDR"
CODE="$("$CURL_BIN" -sS -m 30 -o "$TMP/body.json" -w '%{http_code}' -H @"$HDR" \
  --resolve "$BOARD_HOST:$BOARD_PORT:$IP" "http://$BOARD_HOST:$BOARD_PORT/api/digest/slack?date=$DAY" 2>"$TMP/err")" \
  || fail "board unreachable ($(head -c 200 "$TMP/err"))"
if [ "$CODE" = "503" ] && jq -e '.error == "waiting_for_data"' "$TMP/body.json" >/dev/null 2>&1; then
  say "NO_REPLY"; exit 0
fi
[ "$CODE" = "200" ] || fail "board answered HTTP $CODE"
jq -e '(.blocks | type == "array" and length > 0) and (.text | type == "string" and length > 0)' "$TMP/body.json" >/dev/null \
  || fail "board digest payload has no text/blocks"

jq --arg ch "$JAN_UID" '{channel: $ch, text: .text, blocks: .blocks, unfurl_links: false}' "$TMP/body.json" > "$TMP/payload.json"
export SLACK_NOTIFY_BOT=operations SLACK_NOTIFY_REQUESTER="credit-digest-dm@hydra-ops"
# shellcheck source=/dev/null
. "$SLACK_LIB"
slack_notify_payload_file_status "$TMP/payload.json" || fail "Slack did not confirm the DM"
: > "$STATE_DIR/sent-$DAY"
say "NO_REPLY"
