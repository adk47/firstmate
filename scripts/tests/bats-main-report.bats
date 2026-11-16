#!/usr/bin/env bats
#
# bats-main-report.bats: what happens when "Bats on main" finishes
# (scripts/ci/bats-main-report.sh, scripts/ci/bats-main-report.py,
# .github/workflows/bats-main-report.yml).
#
# 2026-11-15. A pull request runs only the suites its change concerns, so the run
# on main is the only place some breaks show, and a red run nobody is told about
# is not a safety net. Every case here EXECUTES the shipped script against a
# stand-in GitHub API and Alertmanager (one local server) and a stand-in Slack (a
# `muso` that records what it was asked to send and answers as told). The last
# section breaks the scripts on a copy and requires a case to go red.
#
# NOBODY IS MENTIONED (firstmate on #2048, inbox 035; Aaron's rule: no Slack ping and
# no task to any person). A red main is a task for the `ci` lane: the BatsOnMainRed
# alert, owner=ci, which the lights dispatcher turns into one task. report() fails
# every case in which anything sent, to Slack or to Alertmanager, carries a mention
# or the Slack id of any person scripts/lib/slack-notify.sh knows.
#
# CONTAINMENT. Nothing here can post to Slack or to a real Alertmanager: MUSO_BIN is
# the stand-in, scripts/lib/slack-notify.sh refuses the installed muso under bats,
# and the Alertmanager address is pinned to the local server.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  ROOT="${REPORT_ROOT:-$REPO_ROOT}"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin"
  echo '{}' > "$T/routes.json"
  : > "$T/muso.log"; : > "$T/api.log"; : > "$T/am.log"
  cat > "$T/bin/muso" <<'SH'
#!/usr/bin/env bash
{ echo "--call--"; printf '%s\n' "$@"; } >> "$MUSO_LOG"
exit "${MUSO_STUB_RC:-0}"
SH
  chmod +x "$T/bin/muso"
  cat > "$T/api.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
routes, log, portfile, amlog = sys.argv[1:5]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        auth = "auth" if self.headers.get("Authorization") else "plain"
        open(log, "a").write(f"{auth} {self.path}\n")
        r = json.load(open(routes)).get(self.path)
        if r is None:
            self.send_response(404); self.end_headers(); return
        if r.get("refuse_auth") and auth == "auth":
            self.send_response(403); self.end_headers(); return
        self.send_response(r.get("status", 200))
        if "location" in r:
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}{r['location']}")
        self.end_headers()
        body = r["text"] if "text" in r else json.dumps(r.get("json", {}))
        self.wfile.write(body.encode())
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        open(log, "a").write(f"post {self.path}\n")
        if self.path != "/api/v2/alerts":
            self.send_response(404); self.end_headers(); return
        status = (json.load(open(routes)).get("POST /api/v2/alerts") or {}).get("status", 200)
        if status == 200:
            open(amlog, "a").write(body.replace("\n", " ") + "\n")
        self.send_response(status); self.end_headers()
s = HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_port))
s.serve_forever()
PY
  python3 "$T/api.py" "$T/routes.json" "$T/api.log" "$T/port" "$T/am.log" &
  API_PID=$!
  for _ in $(seq 1 100); do [ -s "$T/port" ] && break; sleep 0.05; done
  [ -s "$T/port" ]
  RESULT=failure; EVENT=push; RUN_NUMBER=10; HEAD=$(sha c); STUB_RC=0
  AM_IP=127.0.0.1; AM_HOST=alertmanager.invalid
}

teardown() { kill "$API_PID" 2>/dev/null || true; }

sha() { printf '%s' "$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1"; }

# route PATH SPEC: what the stand-in API answers for PATH.
route() {
  python3 - "$T/routes.json" "$1" "$2" <<'PY'
import json, sys
f, path, spec = sys.argv[1:4]
d = json.load(open(f)); d[path] = json.loads(spec); json.dump(d, open(f, "w"))
PY
}
R=/repos/o/r
# earlier 'NUMBER:ID:CONCLUSION:SHALETTER' ...: the finished runs of the workflow, as listed.
earlier() {
  local items="" spec n id c s
  for spec in "$@"; do
    IFS=: read -r n id c s <<<"$spec"
    items+="${items:+,}{\"run_number\":$n,\"id\":$id,\"conclusion\":\"$c\",\"head_sha\":\"$(sha "$s")\",\"run_attempt\":1}"
  done
  route "$R/actions/workflows/bats-main.yml/runs?branch=main&status=completed&per_page=50" "{\"json\":{\"workflow_runs\":[$items]}}"
}
# shard RUN JOBID CONCLUSION [started|waiting]: one job of a run. Call once per job.
shard() {
  local key="$R/actions/runs/$1/attempts/1/jobs?per_page=100"
  python3 - "$T/routes.json" "$key" "$2" "$3" "${4-started}" <<'PY'
import json, sys
f, key, jid, concl, state = sys.argv[1:6]
d = json.load(open(f))
jobs = d.setdefault(key, {"json": {"jobs": []}})["json"]["jobs"]
job = {"id": int(jid), "name": f"Bats, every suite ({len(jobs) + 1}/4)", "conclusion": concl}
if state == "started":
    job.update(runner_name="ovh-hydra-x", steps=[{"name": "Checkout"}])
else:
    job.update(runner_name="", steps=[])
jobs.append(job); json.dump(d, open(f, "w"))
PY
}
# joblog JOBID SUITE...: a failed job's log, one failing case per suite. The log is
# served the way GitHub serves it: a redirect to another host that refuses our token.
joblog() {
  local id="$1" text="" n=1 s; shift
  for s in "$@"; do
    text+="2026-11-15T18:00:0${n}.0000000Z ok $n fine"$'\n'
    text+="2026-11-15T18:00:0${n}.0000000Z not ok $((n + 10)) breaks"$'\n'
    text+="2026-11-15T18:00:0${n}.0000000Z # (from function \`helper' in file scripts/tests/helpers/h.bash, line 3,"$'\n'
    text+="2026-11-15T18:00:0${n}.0000000Z #  in test file $s, line 9)"$'\n'
    text+="2026-11-15T18:00:0${n}.0000000Z # not ok 1 a case of a bats run inside this case"$'\n'
    text+="2026-11-15T18:00:0${n}.0000000Z # # (in test file scripts/tests/nested.bats, line 3)"$'\n'
    n=$((n + 1))
  done
  route "$R/actions/jobs/$id/logs" "{\"status\":302,\"location\":\"/blob/$id\"}"
  route "/blob/$id" "$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1], "refuse_auth": True}))' "$text")"
}
# merged BASELETTER 'SHALETTER:LOGIN:BRANCH:TITLE' ...: what merged after the base, up to the
# head, oldest first. The compare route is paged like the real one: this is page 1.
# MERGED_TOTAL overrides the total the API claims ("none" leaves it out); MERGED_PAGE picks the page.
merged() {
  local base="$1" commits="" spec s login branch title n=0 total; shift
  for spec in "$@"; do
    IFS=: read -r s login branch title <<<"$spec"
    commits+="${commits:+,}$(python3 -c 'import json,sys; print(json.dumps({"sha": sys.argv[1], "commit": {"message": sys.argv[2] + "\n\nbody"}, "author": None}))' "$(sha "$s")" "$title")"
    route "$R/commits/$(sha "$s")/pulls" "$(python3 -c 'import json,sys; print(json.dumps({"json": [{"user": {"login": sys.argv[1]}, "head": {"ref": sys.argv[2]}, "html_url": sys.argv[3]}]}))' "$login" "$branch" "https://github.example/o/r/pull/$s")"
    n=$((n + 1))
  done
  total="\"total_commits\":${MERGED_TOTAL:-$n},"
  [ "${MERGED_TOTAL:-}" = none ] && total=""
  route "$R/compare/$(sha "$base")...$HEAD?per_page=100&page=${MERGED_PAGE:-1}" "{\"json\":{${total}\"commits\":[$commits]}}"
}
# full_page BASELETTER LOGIN TOTAL: page 1 of the interval, one hundred merges by LOGIN. Their
# pull requests are not served, so the author is read from the commit itself.
full_page() {
  route "$R/compare/$(sha "$1")...$HEAD?per_page=100&page=1" "$(python3 -c '
import json, sys
print(json.dumps({"json": {"total_commits": int(sys.argv[2]), "commits": [
    {"sha": f"{i:040x}", "commit": {"message": f"bulk {i}"}, "author": {"login": sys.argv[1]}} for i in range(1, 101)]}}))' "$2" "$3")"
}

# report: run the shipped script. $output is what it printed; $said is everything
# Slack was asked to send; $posts is how many messages that was; $alerts is every
# body Alertmanager accepted, one per line.
report() {
  run env -u GITHUB_ACTIONS \
    BATS_MAIN_API="http://127.0.0.1:$(cat "$T/port")" GH_TOKEN=tok REPO=o/r SERVER_URL=https://github.example \
    RUN_ID=100 RUN_ATTEMPT=1 RUN_NUMBER="$RUN_NUMBER" HEAD_SHA="$HEAD" EVENT="$EVENT" RESULT="$RESULT" \
    RUNNER_TEMP="$T" MUSO_BIN="$T/bin/muso" MUSO_LOG="$T/muso.log" MUSO_STUB_RC="$STUB_RC" \
    MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test MUSO_SLACK_ENV_FILE="$T/none.env" \
    BATS_MAIN_AM_IP="$AM_IP" BATS_MAIN_AM_HOST="$AM_HOST" BATS_MAIN_AM_PORT="$(cat "$T/port")" \
    BATS_MAIN_KUBE_DNS=127.0.0.1 \
    bash "$ROOT/scripts/ci/bats-main-report.sh"
  said=$(cat "$T/muso.log")
  posts=$(grep -c '^--call--$' "$T/muso.log" || true)
  alerts=$(cat "$T/am.log")
  nobody_mentioned
}

# nobody_mentioned: no mention, and no person's Slack id, in anything sent anywhere.
nobody_mentioned() {
  local ids
  ids=$(grep -oE '^SLACK_UID_[A-Z_]+="[UW][A-Z0-9]+"' "$REPO_ROOT/scripts/lib/slack-notify.sh" | sed 's/.*="\(.*\)"/\1/')
  [ -n "$ids" ] || { echo "no person's Slack id was found in scripts/lib/slack-notify.sh to check against"; return 1; }
  local id
  for id in $ids; do
    if grep -qF "$id" <<<"$said$alerts"; then echo "a person was named ($id): $said $alerts"; return 1; fi
  done
  if grep -qF '<@' <<<"$said$alerts"; then echo "a mention was sent: $said $alerts"; return 1; fi
  if grep -qE '<!(channel|here|everyone)>' <<<"$said$alerts"; then echo "a broadcast was sent: $said $alerts"; return 1; fi
}

says()   { grep -qF -- "$1" <<<"$said" || { echo "Slack was not told: $1"; echo "$said"; return 1; }; }
silent() { if grep -qF -- "$1" <<<"$said"; then echo "Slack was told: $1"; echo "$said"; return 1; fi; }

# last_alert: the last body Alertmanager accepted, as `state=firing|resolved` and
# one `label.K=V` / `ann.K=V` line each, into $got.
last_alert() {
  [ -n "$alerts" ] || { echo "no alert was posted; output: $output"; return 1; }
  got=$(python3 - "$T/am.log" <<'PY'
import json, sys, datetime as d
body = json.loads(open(sys.argv[1]).read().splitlines()[-1])
assert isinstance(body, list) and len(body) == 1, body
a = body[0]
assert "startsAt" not in a, "startsAt is Alertmanager's to keep"
end = d.datetime.strptime(a["endsAt"][:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=d.timezone.utc)
left = (end - d.datetime.now(d.timezone.utc)).total_seconds() / 3600
print("state=" + ("firing" if 25.5 < left <= 26 else "resolved" if left <= 0.01 else f"odd ({left:.2f} h left)"))
print(f"labels={len(a['labels'])}")
for k, v in sorted(a["labels"].items()): print(f"label.{k}={v}")
for k, v in sorted(a["annotations"].items()): print(f"ann.{k}=" + v.replace("\n", " | "))
print("generatorURL=" + a.get("generatorURL", ""))
PY
) || { echo "the alert does not parse: $got"; return 1; }
  # its identity: the same five labels on every run, or it is a different alert
  local want
  for want in labels=5 label.alertname=BatsOnMainRed label.owner=ci label.severity=warning label.namespace=ci label.repo=o/r; do
    grep -qx "$want" <<<"$got" || { echo "the alert lacks $want: $got"; return 1; }
  done
}
fires()      { last_alert || return 1; grep -qx state=firing <<<"$got" || { echo "not firing: $got"; return 1; }; }
resolves()   { last_alert || return 1; grep -qx state=resolved <<<"$got" || { echo "not resolved: $got"; return 1; }; }
no_alert()   { [ -z "$alerts" ] || { echo "an alert was posted: $alerts"; return 1; }; }
alert_says() { grep -qF -- "$1" <<<"$got" || { echo "the alert does not say $1: $got"; return 1; }; }

# A red run 100 (number 10) at head c, one failed shard with the given suites.
red_now() { shard 100 11 failure; shard 100 12 success; joblog 11 "$@"; }

# ── green ───────────────────────────────────────────────────────────────────

@test "green after green: nothing is said, and the alert is resolved all the same" {
  RESULT=success; earlier 9:90:success:b; report
  [ "$status" -eq 0 ]
  [ "$posts" -eq 0 ]
  resolves
  alert_says "ann.run_url=https://github.example/o/r/actions/runs/100"
  [[ "$output" == *"Resolved BatsOnMainRed"* ]]
}

@test "green after red: one line, and the alert is resolved" {
  RESULT=success; earlier 9:90:failure:b 8:80:success:a; report
  [ "$status" -eq 0 ]
  [ "$posts" -eq 1 ]
  says "Bats on main is green again"
  resolves
}

# ── red: a task for the ci lane, nobody mentioned ───────────────────────────

@test "red after green: the alert fires for the ci lane; the channel gets suites and merges, nobody mentioned" {
  earlier 9:90:success:b; red_now scripts/tests/alpha.bats scripts/tests/beta.bats
  merged b 'c:liflovs:fm/some-lane:fix(x): a change (#2050)'
  report
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$posts" -eq 1 ]
  says "Bats on main is red"
  says 'It is a task for the `ci` lane (alert `BatsOnMainRed`, owner=ci, dispatched by lights); nobody is mentioned.'
  says "2 case(s) in 2 suite(s)"
  says '`scripts/tests/alpha.bats`, `scripts/tests/beta.bats`'
  silent "nested.bats"
  says 'fix(x): a change (#2050), liflovs, branch `fm/some-lane`'
  says "https://github.example/o/r/actions/runs/100"
  silent "Could not read"
  fires
  alert_says "ann.summary=Bats on main in o/r is red at ccccccc: 2 case(s) in 2 suite(s); 1 merge(s) since the last green run"
  alert_says "ann.failing=scripts/tests/alpha.bats scripts/tests/beta.bats"
  alert_says "ann.merges=ccccccc fix(x): a change (#2050) (https://github.example/o/r/pull/c), liflovs, branch fm/some-lane"
  alert_says "ann.head=$HEAD"
  alert_says "generatorURL=https://github.example/o/r/actions/runs/100"
  [[ "$output" == *"Raised BatsOnMainRed (owner=ci)"* ]]
}

@test "a merge by a firstmate lane (adk47) is listed by login, and nobody is mentioned" {
  earlier 9:90:success:b; red_now scripts/tests/alpha.bats
  merged b 'c:adk47:fm/some-lane:fix(x): a change (#2050)'
  report
  [ "$status" -eq 0 ]
  says 'fix(x): a change (#2050), adk47, branch `fm/some-lane`'
  fires
  alert_says "(https://github.example/o/r/pull/c), adk47, branch fm/some-lane"
}

@test "Slack refuses the message: the alert was raised first, and the job fails" {
  STUB_RC=1; earlier 9:90:success:b; red_now scripts/tests/alpha.bats; merged b 'c:adk47:fm/x:t'
  report
  [ "$status" -eq 1 ]
  fires
  [[ "$output" == *"::error::"*"NOT posted to Slack"* ]]
}

@test "Alertmanager refuses the alert: the channel is told, and the job fails saying no lane has the task" {
  route "POST /api/v2/alerts" '{"status":500}'
  earlier 9:90:success:b; red_now scripts/tests/alpha.bats; merged b 'c:adk47:fm/x:t'
  report
  [ "$status" -eq 1 ]
  [ "$posts" -eq 1 ]
  no_alert
  grep -qx "post /api/v2/alerts" "$T/api.log"
  [[ "$output" == *"::error::"*"NOT accepted by Alertmanager"* ]]
  [[ "$output" == *"::error::"*"NOT raised, so no lane has the task"* ]]
}

@test "Alertmanager refuses the resolve on a green run: the job fails" {
  route "POST /api/v2/alerts" '{"status":503}'
  RESULT=success; earlier 9:90:success:b; report
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"*"did not land"* ]]
}

@test "Alertmanager cannot be found: the job fails rather than passing in silence" {
  AM_IP=; AM_HOST=no-such-alertmanager.invalid
  earlier 9:90:success:b; red_now scripts/tests/alpha.bats; merged b 'c:adk47:fm/x:t'
  report
  [ "$status" -eq 1 ]
  no_alert
  [[ "$output" == *"::error::"*"could not be resolved"* ]]
}

@test "Alertmanager is found through the host's resolver when no address is pinned" {
  AM_IP=; AM_HOST=127.0.0.1
  earlier 9:90:success:b; red_now scripts/tests/alpha.bats; merged b 'c:adk47:fm/x:t'
  report
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  fires
}

@test "a red main that repeats itself is one line, and the alert is raised again with the merges" {
  earlier 9:90:failure:b 8:80:success:a; red_now scripts/tests/alpha.bats
  shard 90 21 failure; joblog 21 scripts/tests/alpha.bats scripts/tests/beta.bats
  merged a 'c:adk47:fm/x:the break'
  report
  [ "$status" -eq 0 ]
  [ "$posts" -eq 1 ]
  says "Bats on main is still red"
  says "scripts/tests/alpha.bats"
  silent "the break"
  fires
  alert_says "the break"
}

@test "the job log is fetched from the other host without our token" {
  earlier 9:90:success:b; red_now scripts/tests/alpha.bats; merged b 'c:adk47:fm/x:t'
  report
  grep -qx "auth $R/actions/jobs/11/logs" "$T/api.log"
  grep -qx "plain /blob/11" "$T/api.log"
  ! grep -q "auth /blob/11" "$T/api.log" || return 1
}

@test "red after green on the same commit: the alert fires, and says why nothing merged" {
  HEAD=$(sha b); earlier 9:90:success:b; red_now scripts/tests/alpha.bats
  report
  says "nothing merged since the last green run"
  fires
  alert_says "nothing merged since the last green run"
}

@test "red with no earlier run at all: the alert still fires" {
  earlier; red_now scripts/tests/alpha.bats; report
  [ "$posts" -eq 1 ]
  says "no green run was found to count from"
  fires
}

@test "red after red, a suite that did not fail before: the full message again" {
  earlier 9:90:failure:b 8:80:success:a; red_now scripts/tests/alpha.bats scripts/tests/gamma.bats
  shard 90 21 failure; joblog 21 scripts/tests/alpha.bats
  merged a 'b:liflovs:fm/first:first break' 'c:adk47:fm/second:second break'
  report
  says "Bats on main is red"
  says "Main was already red in the run before this one"
  says "first break"
  says "second break"
  fires
  alert_says "scripts/tests/gamma.bats"
}

@test "red after red on the nightly run: the full message again" {
  EVENT=schedule; earlier 9:90:failure:b 8:80:success:a; red_now scripts/tests/alpha.bats
  shard 90 21 failure; joblog 21 scripts/tests/alpha.bats
  merged a 'c:adk47:fm/x:t'
  report
  says "Bats on main is red"
  silent "still red"
  fires
}

@test "red after red, the run before cannot be read: the full message, and what could not be read" {
  earlier 9:90:failure:b 8:80:success:a; red_now scripts/tests/alpha.bats
  route "$R/actions/runs/90/attempts/1/jobs?per_page=100" '{"status":500}'
  merged a 'c:adk47:fm/x:t'
  report
  says "Bats on main is red"
  says "Could not read: what failed in the run before"
  fires
  alert_says "Could not read: what failed in the run before"
}

@test "a shard that failed without a failing case: the full message names the shard" {
  earlier 9:90:failure:b 8:80:success:a
  shard 100 11 failure; route "$R/actions/jobs/11/logs" '{"text":"2026-11-15T18:00:00.0000000Z ##[error]3 bats case(s) SKIPPED on ovh-hydra\n"}'
  shard 90 21 failure; joblog 21 scripts/tests/alpha.bats
  merged a 'c:adk47:fm/x:t'
  report
  says "Bats on main is red"
  says "Failed without a failing case"
  says "Bats, every suite (1/4)"
  fires
}

@test "an earlier run that was cancelled is not 'the run before'" {
  earlier 9:90:cancelled:b 8:80:success:a; red_now scripts/tests/alpha.bats
  shard 90 21 failure; joblog 21 scripts/tests/alpha.bats
  merged a 'c:adk47:fm/x:t'
  report
  says "Bats on main is red"
  silent "already red"
  fires
}

@test "a newer run has finished: it is not 'the run before', and this late report leaves the alert alone" {
  earlier 12:120:failure:d 9:90:success:b; red_now scripts/tests/alpha.bats
  shard 120 31 failure; joblog 31 scripts/tests/alpha.bats
  merged b 'c:adk47:fm/x:t'
  report
  [ "$status" -eq 0 ]
  says "Bats on main is red"
  silent "still red"
  silent "already red"
  no_alert
  [[ "$output" == *"a newer run of main has finished"*"left alone"* ]]
}

@test "a late green report does not resolve the alert a newer red run raised" {
  RESULT=success; earlier 12:120:failure:d 9:90:failure:b 8:80:success:a
  report
  [ "$status" -eq 0 ]
  says "green again"
  no_alert
}

# QA on #2048 at e2b6d2f: a green report that finishes after a newer red one, while
# the runs API is down, cannot tell it is late. Unknown order is not "no newer run".
@test "a green report that cannot read the earlier runs leaves the alert alone, and the job fails" {
  RESULT=success
  route "$R/actions/workflows/bats-main.yml/runs?branch=main&status=completed&per_page=50" '{"status":502}'
  report
  [ "$status" -eq 1 ]
  [ "$posts" -eq 0 ]
  no_alert
  ! grep -q "^post /api/v2/alerts" "$T/api.log" || { echo "Alertmanager was posted to"; return 1; }
  [[ "$output" == *"the earlier runs could not be read"*"HTTP 502"* ]]
  [[ "$output" == *"::error::"*"it was NOT resolved. A later green run resolves it."* ]]
}

@test "the earlier runs come back: the next green run resolves the alert" {
  RESULT=success
  route "$R/actions/workflows/bats-main.yml/runs?branch=main&status=completed&per_page=50" '{"status":502}'
  report
  [ "$status" -eq 1 ]
  earlier 9:90:failure:b 8:80:success:a
  RUN_NUMBER=10; report
  [ "$status" -eq 0 ]
  resolves
}

@test "a run cancelled before any shard started says nothing and leaves the alert alone" {
  RESULT=cancelled; earlier 9:90:success:b
  shard 100 11 cancelled waiting; shard 100 12 cancelled waiting
  report
  [ "$status" -eq 0 ]
  [ "$posts" -eq 0 ]
  no_alert
  [[ "$output" == *"cancelled before any shard started"* ]]
}

@test "a run cancelled after a shard started is told as 'did not finish', and the alert fires" {
  RESULT=cancelled; earlier 9:90:success:b
  shard 100 11 cancelled started; route "$R/actions/jobs/11/logs" '{"text":"2026-11-15T18:00:00.0000000Z ok 1 fine\n"}'
  merged b 'c:adk47:fm/x:t'
  report
  [ "$posts" -eq 1 ]
  says "Bats on main did not finish"
  fires
  alert_says "ann.summary=Bats on main in o/r did not finish"
}

@test "the API is down on a red run: the alert fires, and both say what could not be read" {
  route "$R/actions/workflows/bats-main.yml/runs?branch=main&status=completed&per_page=50" '{"status":502}'
  route "$R/actions/runs/100/attempts/1/jobs?per_page=100" '{"status":502}'
  report
  [ "$status" -eq 0 ]
  [ "$posts" -eq 1 ]
  says "Could not read: the earlier runs"
  says "what failed"
  fires
  alert_says "Could not read: the earlier runs"
}

@test "a merge title or branch cannot ping anyone, and a long list of merges is cut" {
  earlier 9:90:success:b; red_now scripts/tests/alpha.bats
  merged b 'd:adk47:fm/1:one' 'e:adk47:fm/2:two' 'f:adk47:fm/3:three' '1:adk47:fm/4:four' '2:adk47:fm/5:five' \
    '3:adk47:fm/6:six' '4:adk47:fm/7:seven' '5:adk47:fm/8:eight' '6:adk47:<@U12345678>:nine' 'c:adk47:fm/10:<!channel> ten <@U87654321>'
  report
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  says "&lt;!channel&gt; ten &lt;@U87654321&gt;"
  says '`&lt;@U12345678&gt;`'
  says "and 2 earlier merge(s) not listed"
  silent " one,"
  fires
  alert_says "&lt;!channel&gt; ten &lt;@U87654321&gt;"
  alert_says "branch &lt;@U12345678&gt;"
}

# ── every merge is counted, not only the ones the message lists ─────────────
# QA finding on #2048: with ten merges since the last green run, the first version
# read the last eight only, so the first merge (as likely the break) was never seen.

@test "ten merges: the message lists eight and counts ten; the alert carries all ten" {
  earlier 9:90:success:b; red_now scripts/tests/alpha.bats
  merged b 'd:liflovs:fm/1:the break' 'e:adk47:fm/2:two' 'f:adk47:fm/3:three' '1:adk47:fm/4:four' '2:adk47:fm/5:five' \
    '3:adk47:fm/6:six' '4:adk47:fm/7:seven' '5:adk47:fm/8:eight' '6:adk47:fm/9:nine' 'c:adk47:fm/10:ten'
  report
  [ "$status" -eq 0 ]
  says "10 in all"
  silent "the break"
  says "and 2 earlier merge(s) not listed here"
  fires
  alert_says "10 merge(s) since the last green run"
  alert_says "ddddddd the break (https://github.example/o/r/pull/d), liflovs, branch fm/1"
  silent "Could not read"
}

@test "a merge whose author cannot be read is listed without one" {
  earlier 9:90:success:b; red_now scripts/tests/alpha.bats
  merged b 'd::fm/1:first' 'c:liflovs:fm/2:second'
  report
  says '`ddddddd` first, branch `fm/1`'
  says 'second, liflovs, branch `fm/2`'
  fires
}

@test "an interval longer than one page is read to its end" {
  earlier 9:90:success:b; red_now scripts/tests/alpha.bats
  full_page b Korpyc 101
  MERGED_PAGE=2 MERGED_TOTAL=101 merged b 'c:liflovs:fm/last:the last one'
  report
  [ "$status" -eq 0 ]
  says "101 in all"
  says "the last one"
  says "and 93 earlier merge(s) not listed here"
  silent "Could not read"
  fires
  alert_says "the last one"
}

@test "an interval that cannot be read to its end: both say so" {
  earlier 9:90:success:b; red_now scripts/tests/alpha.bats
  # the API says 150 merged; page 1 has one of them and page 2 is not served
  MERGED_TOTAL=150 merged b 'c:liflovs:fm/x:t'
  report
  says "Could not read: every merge since the last green run"
  fires
  alert_says "Could not read: every merge since the last green run"
  # the same when page 2 answers with nothing
  : > "$T/muso.log"
  route "$R/compare/$(sha b)...$HEAD?per_page=100&page=2" '{"json":{"total_commits":150,"commits":[]}}'
  report
  says "Could not read: every merge since the last green run"
}

@test "an interval whose size the API does not give is not read as whole" {
  earlier 9:90:success:b; red_now scripts/tests/alpha.bats
  MERGED_TOTAL=none merged b 'c:liflovs:fm/x:t'
  report
  says "Could not read: every merge since the last green run"
}

# ── a report that cannot be built or delivered ──────────────────────────────

@test "the report cannot be built on a red run: the alert fires with the run link, the channel is told, the job fails" {
  RUN_NUMBER=not-a-number; report
  [ "$status" -eq 1 ]
  [ "$posts" -eq 1 ]
  says "the report on it could not be built"
  says 'It is a task for the `ci` lane'
  says "https://github.example/o/r/actions/runs/100"
  fires
  alert_says "ann.run_url=https://github.example/o/r/actions/runs/100"
  alert_says "the report on it could not be built"
  [[ "$output" == *"::error::"*"BatsOnMainRed was raised with the run link instead"* ]]
}

@test "the report cannot be built and Alertmanager refuses: the job says only the channel was told" {
  RUN_NUMBER=not-a-number; route "POST /api/v2/alerts" '{"status":500}'; report
  [ "$status" -eq 1 ]
  [ "$posts" -eq 1 ]
  [[ "$output" == *"::error::"*"was NOT raised; only the channel was told"* ]]
}

@test "the report cannot be built and Slack refuses: the job says the message was not posted" {
  RUN_NUMBER=not-a-number; STUB_RC=1; report
  [ "$status" -eq 1 ]
  fires
  [[ "$output" == *"::error::"*"channel message was NOT posted"* ]]
}

@test "the report cannot be built on a green run: nothing is sent, the job still fails" {
  RUN_NUMBER=not-a-number; RESULT=success; report
  [ "$status" -eq 1 ]
  [ "$posts" -eq 0 ]
  no_alert
  [[ "$output" == *"::error::"*"the reporter is broken"* ]]
}

@test "no Slack token on the box: the job fails rather than passing in silence" {
  earlier 9:90:success:b; red_now scripts/tests/alpha.bats; merged b 'c:adk47:fm/x:t'
  run env -u MUSO_SLACK_BOT_TOKEN_DEVOPS BATS_MAIN_API="http://127.0.0.1:$(cat "$T/port")" GH_TOKEN=tok REPO=o/r \
    RUN_ID=100 RUN_ATTEMPT=1 RUN_NUMBER=10 HEAD_SHA="$HEAD" EVENT=push RESULT=failure RUNNER_TEMP="$T" \
    MUSO_BIN="$T/bin/muso" MUSO_LOG="$T/muso.log" MUSO_SLACK_ENV_FILE="$T/none.env" \
    BATS_MAIN_AM_IP=127.0.0.1 BATS_MAIN_AM_PORT="$(cat "$T/port")" \
    bash "$ROOT/scripts/ci/bats-main-report.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"*"NOT posted to Slack"* ]]
}

@test "the Slack notifier cannot be loaded: the job fails and says the channel could not be told" {
  earlier 9:90:success:b; red_now scripts/tests/alpha.bats; merged b 'c:adk47:fm/x:t'
  run env BATS_MAIN_REPORT_LIB="$T/no-such-notifier.sh" BATS_MAIN_API="http://127.0.0.1:$(cat "$T/port")" \
    GH_TOKEN=tok REPO=o/r SERVER_URL=https://github.example RUN_ID=100 RUN_ATTEMPT=1 RUN_NUMBER=10 \
    HEAD_SHA="$HEAD" EVENT=push RESULT=failure RUNNER_TEMP="$T" MUSO_BIN="$T/bin/muso" MUSO_LOG="$T/muso.log" \
    MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test MUSO_SLACK_ENV_FILE="$T/none.env" \
    BATS_MAIN_AM_IP=127.0.0.1 BATS_MAIN_AM_PORT="$(cat "$T/port")" \
    bash "$ROOT/scripts/ci/bats-main-report.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"*"the channel could not be told: the Slack notifier"*"https://github.example/o/r/actions/runs/100"* ]]
  [ "$(grep -c '^--call--$' "$T/muso.log" || true)" -eq 0 ]
}

# ── the workflow, and what the scripts do not use ───────────────────────────

@test "the report workflow reads the Bats-on-main workflow by its real name, on main, and runs the script" {
  run python3 - "$REPO_ROOT" <<'PY'
import sys, yaml
root = sys.argv[1]
main = yaml.safe_load(open(f"{root}/.github/workflows/bats-main.yml"))
rep = yaml.safe_load(open(f"{root}/.github/workflows/bats-main-report.yml"))
on = rep.get("on") or rep.get(True)
wr = on["workflow_run"]
assert wr["workflows"] == [main["name"]], (wr["workflows"], main["name"])
assert wr["types"] == ["completed"] and wr["branches"] == ["main"], wr
assert list(on) == ["workflow_run"], on
assert "concurrency" not in rep, "a report replaced while waiting loses a red run its alert"
assert rep["permissions"] == {"contents": "read", "actions": "read", "pull-requests": "read"}, rep["permissions"]
job = rep["jobs"]["report"]
assert job["runs-on"] == ["self-hosted", "hydra"], job["runs-on"]
assert not job.get("if") and not any(s.get("if") or s.get("continue-on-error") for s in job["steps"])
step = [s for s in job["steps"] if "bats-main-report.sh" in (s.get("run") or "")]
assert len(step) == 1 and step[0]["run"].strip() == "bash scripts/ci/bats-main-report.sh", step
want = {
    "GH_TOKEN": "github.token", "REPO": "github.repository", "SERVER_URL": "github.server_url",
    "RUN_ID": "github.event.workflow_run.id", "RUN_ATTEMPT": "github.event.workflow_run.run_attempt",
    "RUN_NUMBER": "github.event.workflow_run.run_number", "HEAD_SHA": "github.event.workflow_run.head_sha",
    "EVENT": "github.event.workflow_run.event", "RESULT": "github.event.workflow_run.conclusion",
}
got = {k: v.replace("${{", "").replace("}}", "").strip() for k, v in step[0]["env"].items()}
assert got == want, got
src = open(f"{root}/scripts/ci/bats-main-report.py").read()
assert 'WORKFLOW = "bats-main.yml"' in src
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the Alertmanager the script posts to is the cluster's own" {
  # the Service name and port match the ones H-DevOps' alert router reads
  # (scripts/devops-agent/alert-router.sh); kube-dns is the address the other hydra
  # scripts that resolve cluster names from node-8 use (scripts/credit-digest-dm.sh).
  grep -qF 'kube-prometheus-kube-prome-alertmanager.monitoring.svc.cluster.local' "$REPO_ROOT/scripts/ci/bats-main-report.sh"
  grep -qF 'BATS_MAIN_AM_PORT:-9093' "$REPO_ROOT/scripts/ci/bats-main-report.sh"
  grep -qF 'KUBE_DNS:-10.43.0.10}' "$REPO_ROOT/scripts/credit-digest-dm.sh"
  grep -qF 'BATS_MAIN_KUBE_DNS:-10.43.0.10}' "$REPO_ROOT/scripts/ci/bats-main-report.sh"
}

@test "no person is a fallback: the scripts use neither the Slack-id map nor the notifier that mentions people" {
  for f in scripts/ci/bats-main-report.sh scripts/ci/bats-main-report.py; do
    ! grep -nE 'qa-author-slack-uid|slack_notify_critical|SLACK_UID_|ONCALL|NOT_NAMED' "$REPO_ROOT/$f" | grep -v '^\s*[0-9]*:\s*#' || {
      echo "$f still reaches for a person"; return 1; }
  done
}

# ── the scripts, broken on purpose ──────────────────────────────────────────
# Each mutation is applied to a COPY, must change it, and must turn at least one
# case above red. A mutation that does not apply fails here rather than passing.

mutant_goes_red() {  # $1 = file under scripts/ci, $2 = python expression rewriting its source `s`
  local m="$BATS_TEST_TMPDIR/mutant"
  mkdir -p "$m/scripts"
  cp -r "$REPO_ROOT/scripts/ci" "$m/scripts/ci"
  ln -s "$REPO_ROOT/scripts/lib" "$m/scripts/lib"
  python3 - "$m/scripts/ci/$1" "$2" <<'PY'
import sys
path, edit = sys.argv[1:3]
s = open(path).read()
t = eval(edit)
assert t != s, "the mutation did not change the file"
open(path, "w").write(t)
PY
  local out rc
  out=$(REPORT_ROOT="$m" bats --filter-tags '!mutation' "$BATS_TEST_FILENAME" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then echo "every case stayed green with the script broken"; return 1; fi
  grep -q '^not ok' <<<"$out" || { echo "the run failed without a failing case: $out"; return 1; }
}
PY_=bats-main-report.py; SH_=bats-main-report.sh

# bats test_tags=mutation
@test "mutation: a copy of the unbroken scripts passes every case above" {
  m="$BATS_TEST_TMPDIR/copy"; mkdir -p "$m/scripts"
  cp -r "$REPO_ROOT/scripts/ci" "$m/scripts/ci"; ln -s "$REPO_ROOT/scripts/lib" "$m/scripts/lib"
  run env REPORT_ROOT="$m" bats --filter-tags '!mutation' "$BATS_TEST_FILENAME"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# bats test_tags=mutation
@test "mutation: the first red run is only a line" {
  mutant_goes_red "$PY_" 's.replace("    if before != \"red\":\n        return \"page\"", "    if before != \"red\":\n        return \"line\"")'
}

# bats test_tags=mutation
@test "mutation: a new failing suite on a red main is only a line" {
  mutant_goes_red "$PY_" 's.replace("    if not suites <= suites_before:\n        return \"page\"", "")'
}

# bats test_tags=mutation
@test "mutation: the nightly reminder is dropped" {
  mutant_goes_red "$PY_" 's.replace("    if event == \"schedule\":\n        return \"page\"\n", "")'
}

# bats test_tags=mutation
@test "mutation: what cannot be compared is taken as nothing new" {
  mutant_goes_red "$PY_" 's.replace("    if suites is None or suites_before is None:\n        return \"page\"", "    if suites is None or suites_before is None:\n        return \"line\"")'
}

# bats test_tags=mutation
@test "mutation: green after red says nothing" {
  mutant_goes_red "$PY_" 's.replace("return \"green-again\" if before == \"red\" else \"none\"", "return \"none\"")'
}

# bats test_tags=mutation
@test "mutation: every green run posts" {
  mutant_goes_red "$PY_" 's.replace("return \"green-again\" if before == \"red\" else \"none\"", "return \"green-again\"")'
}

# bats test_tags=mutation
@test "mutation: a cancelled earlier run counts as red" {
  mutant_goes_red "$PY_" 's.replace("\"startup_failure\": \"red\"}", "\"startup_failure\": \"red\", \"cancelled\": \"red\"}")'
}

# bats test_tags=mutation
@test "mutation: a later run counts as the run before" {
  mutant_goes_red "$PY_" 's.replace("    older = [r for r in runs if int(r[\"run_number\"]) < run_number]", "    older = list(runs)")'
}

# bats test_tags=mutation
@test "mutation: a run cancelled before it started is told as red" {
  mutant_goes_red "$PY_" 's.replace("if result == \"cancelled\" and not started:", "if False:")'
}

# bats test_tags=mutation
@test "mutation: a run cancelled after it started says nothing" {
  mutant_goes_red "$PY_" 's.replace("if result == \"cancelled\" and not started:", "if result == \"cancelled\":")'
}

# bats test_tags=mutation
@test "mutation: only the first page of merges is read" {
  mutant_goes_red "$PY_" 's.replace("for page in range(1, MAX_PAGES + 1):", "for page in range(1, 2):")'
}

# bats test_tags=mutation
@test "mutation: the merges read are not counted against the total" {
  mutant_goes_red "$PY_" 's.replace("    if not isinstance(total, int) or len(commits) != total:\n        whole = False", "    if False:\n        whole = False")'
}

# bats test_tags=mutation
@test "mutation: a shard that failed without a case is compared as if it had none" {
  mutant_goes_red "$PY_" 's.replace("suites = None if bare else found", "suites = found")'
}

# bats test_tags=mutation
@test "mutation: suites named inside a case's own output are counted" {
  mutant_goes_red "$PY_" 's.replace("SUITE = re.compile(rf\"(?m)^{STAMP}# +\\(?in test file ", "SUITE = re.compile(r\"in test file ")'
}

# bats test_tags=mutation
@test "mutation: our token is sent to the log host" {
  mutant_goes_red "$PY_" 's.replace("headers={\"User-Agent\": head[\"User-Agent\"]})", "headers=head)")'
}

# bats test_tags=mutation
@test "mutation: a merge title reaches the alert as written" {
  mutant_goes_red "$PY_" 's.replace("    ann = {k: clean(v) for k, v in ann.items()}\n", "")'
}

# bats test_tags=mutation
@test "mutation: a merge title is posted as written" {
  mutant_goes_red "$PY_" 's.replace("    return s.replace(\"&\", \"&amp;\").replace(\"<\", \"&lt;\").replace(\">\", \"&gt;\")", "    return s")'
}

# bats test_tags=mutation
@test "mutation: every merge is listed however many" {
  mutant_goes_red "$PY_" 's.replace("MAX_MERGES, MAX_SUITES = 8, 12", "MAX_MERGES, MAX_SUITES = 800, 12")'
}

# bats test_tags=mutation
@test "mutation: the merges are read for the listed eight only" {
  mutant_goes_red "$PY_" 's.replace("for m in landed[-MAX_ALERT_MERGES:])", "for m in landed[-MAX_MERGES:])")'
}

# bats test_tags=mutation
@test "mutation: an unread API is a reason to stay quiet" {
  mutant_goes_red "$PY_" 's.replace("        older, newer = None, None\n        unread.append(f\"the earlier runs ({e})\")", "        return 0")'
}

# bats test_tags=mutation
@test "mutation: a person is mentioned in the channel" {
  mutant_goes_red "$PY_" 's.replace("dispatched by lights); nobody is mentioned.\")", "dispatched by lights); nobody is mentioned. U0AL36NADEY\")")'
}

# bats test_tags=mutation
@test "mutation: a person is mentioned in the alert" {
  mutant_goes_red "$PY_" 's.replace("\"Fix it forward or revert. \" + (", "\"Fix it forward or revert. <@U7RP6HKUZ> \" + (")'
}

# bats test_tags=mutation
@test "mutation: the alert is raised only on the first red run" {
  mutant_goes_red "$PY_" 's.replace("        raise_alert(True, summary, description, found, landed)", "        if kind != \"line\":\n            raise_alert(True, summary, description, found, landed)")'
}

# bats test_tags=mutation
@test "mutation: the alert is resolved only on the first green run" {
  mutant_goes_red "$PY_" 's.replace("    if result == \"success\":\n        # resolved on EVERY", "    if kind == \"green-again\":\n        # resolved on EVERY")'
}

# bats test_tags=mutation
@test "mutation: a late report raises or resolves over a newer run's" {
  mutant_goes_red "$PY_" 's.replace("        if newer is True:\n            print(", "        if False:\n            print(")'
}

# bats test_tags=mutation
@test "mutation: runs that cannot be read count as 'no newer run'" {
  mutant_goes_red "$PY_" 's.replace("        older, newer = None, None\n", "        older, newer = None, False\n")'
}

# bats test_tags=mutation
@test "mutation: a green run of unknown order resolves anyway" {
  mutant_goes_red "$PY_" 's.replace("    if result == \"success\" and newer is None:\n", "    if False:\n")'
}

# bats test_tags=mutation
@test "mutation: an unknown order on a green run ends green" {
  mutant_goes_red "$SH_" 's.replace("  3)\n", "  3)\n    exit 0\n")'
}

# bats test_tags=mutation
@test "mutation: an unknown-order answer on a red run is taken as fine" {
  mutant_goes_red "$PY_" 's.replace("                return 0\n            suites = None if bare", "                return ORDER_UNKNOWN\n            suites = None if bare")'
}

# bats test_tags=mutation
@test "mutation: the alert never ends" {
  mutant_goes_red "$PY_" 's.replace("ALERT_HOURS = \"BatsOnMainRed\", \"ci\", \"warning\", 26", "ALERT_HOURS = \"BatsOnMainRed\", \"ci\", \"warning\", 2600")'
}

# bats test_tags=mutation
@test "mutation: a red alert is sent already resolved" {
  mutant_goes_red "$PY_" 's.replace("end = now + timedelta(hours=ALERT_HOURS) if firing else now", "end = now")'
}

# bats test_tags=mutation
@test "mutation: the alert sets its own start" {
  mutant_goes_red "$PY_" 's.replace("\"annotations\": ann, \"endsAt\"", "\"annotations\": ann, \"startsAt\": stamp(now), \"endsAt\"")'
}

# bats test_tags=mutation
@test "mutation: the commit becomes a label, so every run is a new alert" {
  mutant_goes_red "$PY_" 's.replace("\"namespace\": \"ci\", \"repo\": repo},", "\"namespace\": \"ci\", \"repo\": repo, \"head\": sha},")'
}

# bats test_tags=mutation
@test "mutation: the alert has no owner" {
  mutant_goes_red "$PY_" 's.replace("ALERTNAME, OWNER, SEVERITY, ALERT_HOURS = \"BatsOnMainRed\", \"ci\",", "ALERTNAME, OWNER, SEVERITY, ALERT_HOURS = \"BatsOnMainRed\", \"\",")'
}

# bats test_tags=mutation
@test "mutation: the red alert is never posted" {
  mutant_goes_red "$SH_" 's.replace("  10)\n    post_alert\n", "  10)\n")'
}

# bats test_tags=mutation
@test "mutation: the green resolve is never posted" {
  mutant_goes_red "$SH_" 's.replace("  0)\n    post_alert\n", "  0)\n")'
}

# bats test_tags=mutation
@test "mutation: an alert Alertmanager refused ends green" {
  mutant_goes_red "$SH_" 's.replace("      [ \"$alert_ok\" = 1 ] || die \"Bats on main finished", "      true || die \"Bats on main finished")'
}

# bats test_tags=mutation
@test "mutation: an HTTP error from Alertmanager is taken as accepted" {
  mutant_goes_red "$SH_" 's.replace("\"$CURL_BIN\" -sS --fail -m 20", "\"$CURL_BIN\" -sS -m 20")'
}

# bats test_tags=mutation
@test "mutation: the alert goes to the wrong endpoint" {
  mutant_goes_red "$SH_" 's.replace("/api/v2/alerts\"; then", "/api/v1/alerts\"; then")'
}

# bats test_tags=mutation
@test "mutation: the host's resolver is not asked" {
  mutant_goes_red "$SH_" 's.replace("ip=\"$(getent hosts", "ip=\"$(false && getent hosts")'
}

# bats test_tags=mutation
@test "mutation: an Alertmanager that cannot be found is passed over" {
  mutant_goes_red "$SH_" 's.replace("    alert_ok=0; return 1\n  fi\n  if", "    return 0\n  fi\n  if")'
}

# bats test_tags=mutation
@test "mutation: a message Slack refused ends green" {
  mutant_goes_red "$SH_" 's.replace("    die \"Bats on main finished '"'"'$RESULT'"'"' and the message above was NOT posted", "    exit 0; die \"Bats on main finished '"'"'$RESULT'"'"' and the message above was NOT posted")'
}

# bats test_tags=mutation
@test "mutation: the message goes through the notifier that never fails" {
  mutant_goes_red "$SH_" 's.replace("    if slack_notify_payload_file_status \"$payload\"; then\n      echo \"Posted", "    if slack_notify_payload_file \"$payload\"; then\n      echo \"Posted")'
}

# bats test_tags=mutation
@test "mutation: a report that cannot be built raises no alert" {
  mutant_goes_red "$SH_" 's.replace("PY\n    post_alert\n", "PY\n")'
}

# bats test_tags=mutation
@test "mutation: a report that cannot be built ends green" {
  mutant_goes_red "$SH_" 's.replace("  *)\n", "  *)\n    exit 0\n")'
}

# bats test_tags=mutation
@test "mutation: a broken reporter on a green run raises a red alert" {
  mutant_goes_red "$SH_" 's.replace("    if [ \"$RESULT\" = \"success\" ]; then", "    if false; then")'
}

# bats test_tags=mutation
@test "mutation: a missing notifier ends green" {
  mutant_goes_red "$SH_" 's.replace("  die \"Bats on main finished '"'"'$RESULT'"'"' and the channel could not be told: the Slack notifier", "  exit 0; die \"Bats on main finished '"'"'$RESULT'"'"' and the channel could not be told: the Slack notifier")'
}

# bats test_tags=mutation
@test "mutation: the fallback message mentions a person" {
  mutant_goes_red "$SH_" 's.replace("dispatched by lights); nobody is mentioned. Run: $RUN_URL\"", "dispatched by lights); nobody is mentioned. <@U0AL36NADEY> Run: $RUN_URL\"")'
}
