#!/bin/bash
# usage: gmail_scan.sh <prefix> <gmail query>   (read-only, paced, backoff on rate limit)
# support@muso.ai search for the proof-on-file feed (gmail_proof.py). Was /root/fmc1-gmail/scan.sh on
# node-8 (cs-systemic-issues-lane-c1); codified 2026-10-26 by ops-to-ovh-m1. Pages land in
# $CS_PROOF_GMAIL_DIR as <prefix>-<n>.json; the last line of <prefix>.log is "DONE pages=N" only when
# the scan finished. --timezone UTC: gog prints dates in host-local time by default, and
# gmail_proof.py / proof_export.py read them as UTC (proof_at). gog's credentials come from /etc/openclaw/main.env (never printed).
set -u
# The ONE support@ Gmail readers kill file (#1569; a constant, never an env var - r5 [key=unattended]). Present =
# no gog call at all; the scan does not finish (no DONE line), so cs-gmail stays stale and its gate holds.
GMAIL_READERS_KILL="/etc/hydra/gmail-readers.disabled"
# The GATE VALUES are constants, never env vars (r5), and they are assigned AFTER main.env is sourced.
# That order is the whole point: main.env supplies gog's credentials and may legitimately contain anything
# else, so assigning LOCK_DIR/BUDGET/etc BEFORE it - which this script used to do - let whoever writes that
# file move the lock inode (two "locked" support@ consumers, one quota) or set BUDGET=1800 (the caller's
# 1500 s kill landing mid-scan). A gate the environment can move is a gate an env var can open.
# The ONE seam is an EXPLICIT switch a test sets to ITS OWN temp dir: CS_PROOF_FEED_TEST_SEAM. It is NOT
# BATS_TEST_TMPDIR any more (QA on a2d87a1c9, Fable 05:3xZ withdrew GO over exactly this): that variable is
# inherited from any parent shell - a bats-wrapped cron, an operator's tmux, a CI runner that happens to export
# it - so a stray value moved the kill file, the lock, the state dir and the gog binary. That is the "a gate
# the environment can move" class this script exists to close, and it was in the seam meant to close it.
#
# The value is accepted only when it is an absolute path containing a `bats-` component, is a directory, and is
# owned by the caller. Anything else is refused LOUDLY with exit 2 rather than honoured: an inherited value
# must never be able to redirect a production gate, and it must never be able to silence the refusal either.
ENV_FILE=/etc/openclaw/main.env
TEST_SEAM=0
SEAM_ROOT="${CS_PROOF_FEED_TEST_SEAM:-}"
if [ -n "$SEAM_ROOT" ]; then
  case "$SEAM_ROOT" in
    /*) ;;
    *) echo "CS_PROOF_FEED_TEST_SEAM=$SEAM_ROOT refused: not an absolute path" >&2; exit 2 ;;
  esac
  if ! printf '%s' "$SEAM_ROOT" | grep -Eq '/bats-[A-Za-z0-9._-]+(/|$)'; then
    echo "CS_PROOF_FEED_TEST_SEAM=$SEAM_ROOT refused: not under a bats temp root" >&2
    exit 2
  fi
  if [ ! -d "$SEAM_ROOT" ] || [ ! -O "$SEAM_ROOT" ]; then
    echo "CS_PROOF_FEED_TEST_SEAM=$SEAM_ROOT refused: not a directory owned by this user" >&2
    exit 2
  fi
  TEST_SEAM=1
  # A test may hand the scan a hostile env file; when it does not write one, there is nothing to source.
  ENV_FILE="$SEAM_ROOT/main.env"
  [ -f "$ENV_FILE" ] || ENV_FILE=/dev/null
  GMAIL_READERS_KILL="$SEAM_ROOT/gmail-readers.disabled"
fi
# --resolve-paths prints where this run WOULD look and exits; it scans nothing and calls nothing. It exists so a
# test can assert that an inherited environment did not move a gate, which is otherwise unobservable from the
# outside (the paths only show up in a log line after a scan has already run).
REPORT_PATHS=0
[ "${1:-}" = "--resolve-paths" ] && REPORT_PATHS=1
# The readers kill file is checked AFTER the seam: a test must not inherit the host's kill file (CI would exit 4
# on every case), and no environment variable can point the check elsewhere. It is checked BEFORE the env
# file is sourced, so main.env cannot move the switch that silences every Gmail reader.
if [ -e "$GMAIL_READERS_KILL" ] && [ "$REPORT_PATHS" != 1 ]; then
  echo "support@ Gmail readers disabled ($GMAIL_READERS_KILL): no scan" >&2
  exit 4
fi
# shellcheck source=/dev/null  # host secrets file, not in the repo
[ -r "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
STATE_DIR=/var/lib/hydra/cs-proof-feed
GMAIL_DIR="$STATE_DIR/gmail"
LOCK_DIR=/run/hydra
BACKOFF_DIR=/var/lib/hydra/gmail-support
GOG=gog
ACCOUNT=support@muso.ai
BUDGET=1200         # total scan budget, under the callers' 1500 s kill (gmail_proof.py, cs-proof-feed.sh)
RETRY_MIN_S=60      # floor for a published window: a Retry-after already in the past must still silence a stampede
LOCK_WAIT=600       # capped at half the budget below, so a run that cannot lock still has time to scan
FALLBACK_BACKOFF=45 # 45 s x try when a 429 carries no parseable timestamp AND nothing was published
DEFAULT_BACKOFF_S=900  # the window a quota refusal publishes when Google names no Retry-after (gmail_quota's default)
PAGE_PAUSE=20       # between pages, also budgeted
if [ "$TEST_SEAM" = 1 ]; then
  STATE_DIR="$SEAM_ROOT/state"
  GMAIL_DIR="$STATE_DIR/gmail"
  LOCK_DIR="$SEAM_ROOT/lock"
  BACKOFF_DIR="$SEAM_ROOT/backoff"
  GOG="$SEAM_ROOT/gog"            # the stand-in lives here, so no env var names the binary
  # The pacing constants are shrunk too: a test that waits out real 45 s backoffs would take 15 minutes and get
  # killed by CI, and a killed test is indistinguishable from a passing one that never ran. Production never
  # takes this branch, so the real values stay as constants above.
  FALLBACK_BACKOFF=0   # no waiting at all in tests: the failure paths must be exercised, not slept through
  PAGE_PAUSE=0
  BUDGET=20          # so a long retry-after still exceeds "the remaining budget" and exercises exit 4
  # The floor is shrunk with the rest of the pacing: production clamps every published window to at least
  # 60 s (a matching stampede guard), but no test can wait a minute per case, and a case that cannot wait
  # cannot exercise the wait path at all - it would exit 4 for the wrong reason and pass anyway.
  RETRY_MIN_S=0
fi
if [ "$REPORT_PATHS" = 1 ]; then
  printf 'env=%s\nkill=%s\nstate=%s\ngmail=%s\nlock=%s\nbackoff=%s\ngog=%s\n' \
    "$ENV_FILE" "$GMAIL_READERS_KILL" "$STATE_DIR" "$GMAIL_DIR" "$LOCK_DIR" "$BACKOFF_DIR" "$GOG"
  exit 0
fi
O="$GMAIL_DIR"
P="${1:-}"; Q="${2:-}"; TOK=""; n=0
PAGE_OK='import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d, dict) and isinstance(d.get("messages"), list) else 1)'
case "$P" in ""|*[!A-Za-z0-9]*) echo "bad prefix" >&2; exit 2 ;; esac
mkdir -p "$O"
# The budget clock starts HERE, before the lock wait: the lock may take up to 600 s and the scan another
# 1200 s, which together would pass the callers' 1500 s outer kill. A scan killed from outside loses the
# pages it already wrote and spends the hourly budget, so the total must sit under that kill including the wait.
START_AT=$(date -u +%s)
LOCK="${LOCK_DIR}/gmail-support.lock"
# An unwritable lock dir is EXIT 3, not a private lock: a fallback lock means two consumers can each believe
# they hold "the" lock while writing to different files (r5). No fallback, no silent single-runner mode.
if ! { mkdir -p "$LOCK_DIR" 2>/dev/null && { true > "$LOCK"; } 2>/dev/null; }; then
  echo "$(date -u +%FT%TZ) lock dir $LOCK_DIR is not writable: refusing to scan without the shared lock" >> "$O/$P.log" 2>/dev/null || true
  exit 3
fi
exec 9>"$LOCK" || { echo "$(date -u +%FT%TZ) cannot open lock $LOCK" >> "$O/$P.log"; exit 3; }
BUDGET_TOTAL=$BUDGET
# the wait must leave at least half the budget for the scan itself, or the run starts doomed
[ "$LOCK_WAIT" -gt $(( BUDGET_TOTAL / 2 )) ] && LOCK_WAIT=$(( BUDGET_TOTAL / 2 ))
if ! flock -w "$LOCK_WAIT" 9; then
  echo "$(date -u +%FT%TZ) LOCKED another support@ Gmail scan holds $LOCK; refusing to add a second consumer" >> "$O/$P.log"
  exit 3
fi
# The start line records WHICH env file was sourced and WHICH lock inode and budget the run is actually
# using. A lock-gate regression is otherwise invisible: two consumers each hold "a" lock and both logs say
# "lock held".
rm -f "$O/$P"-*.json; echo "$(date -u +%FT%TZ) start $P (lock held) env=$ENV_FILE lock=$LOCK budget=$BUDGET" >> "$O/$P.log"
# Shared backoff (hydra #1567): every support@ caller reads /var/lib/hydra/gmail-support/backoff.json and
# honours {until} before it spends a request, so one caller's 429 teaches the others instead of each
# discovering the window with its own rejected call. Written below when we see a 429.
BACKOFF="${BACKOFF_DIR}/backoff.json"
# [key=sleep-the-window-you-published] (QA #1567 finding 3): a published window is a promise to EVERY support@
# consumer, this scan included. Reading it back is the only way to be sure the wait below covers what was written
# (the writer may keep an older, longer window, and the no-timestamp path publishes a DEFAULT it never named).
published_wait() {
  python3 -c 'import datetime as dt, json, sys
try:
    until = json.load(open(sys.argv[1])).get("until") or ""
    when = dt.datetime.strptime(until[:19].replace("Z", ""), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc)
    print(max(0, int((when - dt.datetime.now(dt.timezone.utc)).total_seconds()) + 5))
except Exception:
    print(0)' "$BACKOFF" 2>/dev/null || echo 0
}
backoff_wait=$(python3 -c 'import datetime as dt, json, sys
try:
    until = json.load(open(sys.argv[1])).get("until") or ""
    when = dt.datetime.strptime(until[:19].replace("Z", ""), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc)
    print(max(0, int((when - dt.datetime.now(dt.timezone.utc)).total_seconds()) + 5))
except Exception:
    print(0)' "$BACKOFF" 2>/dev/null || echo 0)
publish_backoff() {
  # The ONE place this scan publishes the shared window. r5: never shorten a standing backoff, and go through
  # hydra #1567's locked writer (gmail_quota.note_refusal) when it is importable; the local fallback keeps the
  # never-shorten rule. Called on EVERY refusal path, including the ones that exit 4 before scanning - a window
  # we do not publish is a request the next support@ consumer spends to rediscover it.
  python3 - "$O/$P.err" "$BACKOFF_DIR" "$DEFAULT_BACKOFF_S" "$RETRY_MIN_S" <<'NOTE_EOF' || true
import datetime as dt, json, os, re, sys
err, state_dir = sys.argv[1], sys.argv[2]
default_s, min_s = int(sys.argv[3]), int(sys.argv[4])
raw = ""
try:
    raw = open(err, errors="replace").read()
except OSError:
    pass
# ONLY a quota refusal may set the host-wide window. A gog network error, an expired token, or invalid JSON is
# a different fault: publishing 900 s for it would silence every other support@ caller for the wrong reason.
QUOTA_RE = re.compile(r"\b429\b|rateLimitExceeded|userRateLimitExceeded|quota|RESOURCE_EXHAUSTED|"
                      r"Too Many Requests|Retry after", re.I)
if not QUOTA_RE.search(raw):
    sys.exit(0)
now = dt.datetime.now(dt.timezone.utc)
# A PUBLISHED WINDOW IS ALWAYS FINITE (QA 11-03 23:21, Fable r6). Two holes closed here, both in the
# direction of "never scan again":
#   - a 429 WITHOUT "Retry after" used to publish nothing, so the next support@ caller spent a request to
#     rediscover the refusal it had just been told about. It now publishes a default 15 minutes.
#   - a "Retry after" far in the future used to be stored verbatim (the old test pinned until=2099), which
#     teaches every other caller a decades-long silence: every scan exits 4 without a request, the stamp is
#     left alone, and every log reads quiet and correct. It is capped at 6 hours.
# The cap lives HERE, at the only place this scan can publish a window, and it is applied to the text the
# shared writer parses - so #1567's locked writer still owns the file and still never shortens a window.
RETRY_DEFAULT_S = default_s  # 15 min: no Retry-after header at all
RETRY_MIN_S = min_s          # 1 min in production: a header already in the past still stops a stampede
RETRY_MAX_S = 6 * 3600       # 6 h: the longest silence a single refusal may ask of every consumer
m = re.search(r"Retry after (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})", raw)
if m:
    try:
        target = dt.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        target = None
    # Clamp into [now + 60 s, now + 6 h]: a header in the past must still silence a stampede for a minute
    # (publishing nothing is the hole), and a header far ahead may not silence the fleet forever.
    if target is None:
        target = now + dt.timedelta(seconds=RETRY_DEFAULT_S)
    lo = now + dt.timedelta(seconds=RETRY_MIN_S)
    hi = now + dt.timedelta(seconds=RETRY_MAX_S)
    target = min(max(target, lo), hi)
    until = target.strftime("%Y-%m-%dT%H:%M:%SZ")
    evidence = raw[:m.start()] + "Retry after " + until[:-1] + raw[m.end():]
else:
    until = (now + dt.timedelta(seconds=RETRY_DEFAULT_S)).strftime("%Y-%m-%dT%H:%M:%SZ")
    evidence = raw + "\nRetry after " + until[:-1] + "\n"
try:  # hydra #1567: the ONE backoff writer - locked, and it never shortens a standing window
    sys.path.insert(0, "/opt/hydra/scripts")
    from credit_verify.proof.gmail_quota import note_refusal
    # ...and pass OUR floor through: this scan already clamped the window above, and under the test
    # seam that floor is 0 - re-applying the module default (60 s) here would override the seam.
    note_refusal(evidence, "cs-proof-feed/gmail_scan.sh", now, state_dir, RETRY_MIN_S)
except Exception:
    os.makedirs(state_dir, exist_ok=True)
    path = os.path.join(state_dir, "backoff.json")
    try:
        cur = (json.load(open(path)) or {}).get("until") or ""
    except Exception:
        cur = ""
    if not (isinstance(cur, str) and cur >= until):   # never shorten
        with open(path, "w") as fh:
            json.dump({"until": until, "by": "cs-proof-feed/gmail_scan.sh"}, fh)
NOTE_EOF
}

if [ "${backoff_wait:-0}" -gt 0 ] 2>/dev/null; then
  left=$(( BUDGET - ( $(date -u +%s) - START_AT ) ))
  if [ "$backoff_wait" -ge "$left" ]; then
    echo "$(date -u +%FT%TZ) SHARED BACKOFF honoured: ${backoff_wait}s left in the window exceeds the remaining budget ${left}s - exiting without a request" >> "$O/$P.log"
    exit 4
  fi
  echo "$(date -u +%FT%TZ) shared backoff: sleeping ${backoff_wait}s before the first request" >> "$O/$P.log"
  sleep "$backoff_wait"
fi
# Total budget, in seconds, for the whole scan. gmail_proof.py times the scan out at 1500 s and
# cs-proof-feed.sh times the incremental step out at 1500 s: honouring a 20-minute retry-after and then
# a 10-minute one was killed from outside before it could recover, losing everything it had scanned.
# Staying under 1200 s leaves room to exit CLEANLY with "quota saturated" instead of being killed
# mid-page, so the caller keeps its stamp and the next hourly run retries against a fresh budget.
while :; do
  out=""
  for try in 1 2 3 4 5 6; do
    # A page counts only when gog exited 0 AND printed a result page ({"messages": [...]}, an
    # empty list on no matches). A failed search that prints a JSON error object must never be
    # written as a page, or the scan ends DONE with nothing in it and cs-gmail looks fresh (QA #1391).
    if [ -n "$TOK" ]; then
      out=$("$GOG" gmail messages search --account "$ACCOUNT" "$Q" --max 100 --page "$TOK" --json --timezone UTC 2>"$O/$P.err"); grc=$?
    else
      out=$("$GOG" gmail messages search --account "$ACCOUNT" "$Q" --max 100 --json --timezone UTC 2>"$O/$P.err"); grc=$?
    fi
    [ "$grc" -eq 0 ] && echo "$out" | python3 -c "$PAGE_OK" 2>/dev/null && break
    out=""
    # Google's 429 carries "Retry after <ISO8601>". Sleeping 45 s x try never outlasts it (the
    # retry-after kept moving to +9..+15 min while the quota stayed saturated), so the scan burned
    # its six attempts and died. Honour the timestamp instead, +5 s of slack, capped so a bad parse
    # cannot sleep for ever.
    wait_s=$(python3 -c 'import datetime as dt, re, sys
raw = ""
try:
    raw = open(sys.argv[1], errors="replace").read()
except OSError:
    pass
m = re.search(r"Retry after (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})", raw)
if m:
    when = dt.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc)
    print(max(1, int((when - dt.datetime.now(dt.timezone.utc)).total_seconds()) + 5))' "$O/$P.err" 2>/dev/null)
    if [ -n "${wait_s:-0}" ] && [ "${wait_s:-0}" -gt 0 ] 2>/dev/null; then
      # Publish even when the wait FITS: other support@ callers must learn the window now, not only when this
      # scan gives up (babysit-b1 on #1567).
      publish_backoff
      # The wait is the PUBLISHED window, never the parse capped at a constant: capping slept 900 s of a
      # 30-minute window and sent the next request 15 minutes inside it.
      need=$(published_wait)
      [ "${need:-0}" -gt 0 ] 2>/dev/null || need=$wait_s
      left=$(( BUDGET - ( $(date -u +%s) - START_AT ) ))
      if [ "$left" -le 0 ] || [ "$need" -ge "$left" ]; then
        # Exiting 4 (not 1) says "the quota is saturated, nothing was scanned": the stamp stays where it
        # was, no page file is written, and the feed never records freshness it did not earn.
        echo "$(date -u +%FT%TZ) QUOTA SATURATED after ${try} attempt(s); retry-after ${need}s exceeds the remaining budget ${left}s - exiting without touching the stamp" >> "$O/$P.log"
        exit 4
      fi
      echo "$(date -u +%FT%TZ) retry $try (gog rc=$grc): 429 retry-after honoured, sleeping ${need}s: $(head -c 100 "$O/$P.err")" >> "$O/$P.log"
      sleep "$need"
    else
      # The fallback path must respect the same budget: six 429s without a parseable Retry-after cost
      # 45*(1+..+6) = 945 s, and with a 600 s lock wait that reaches 1545 s against a 1500 s outer kill.
      # A 429 with no parseable timestamp still PUBLISHES a window (gmail_quota's DEFAULT_BACKOFF_S). Retrying after
      # 45 s x try ignored that window four times over, so the wait is now the published window itself.
      publish_backoff
      fb=$(published_wait)
      if [ "${fb:-0}" -le 0 ] 2>/dev/null; then
        # No window was written (a non-quota 429 shape): fall back to the bounded backoff, and start it over.
        publish_backoff
        fb=$((FALLBACK_BACKOFF*try))
        [ "$fb" -gt 0 ] || fb=$FALLBACK_BACKOFF
      fi
      left=$(( BUDGET - ( $(date -u +%s) - START_AT ) ))
      if [ "$left" -le 0 ] || [ "$fb" -ge "$left" ]; then
        echo "$(date -u +%FT%TZ) QUOTA SATURATED after ${try} attempt(s) with no Retry-after; the published window ${fb}s exceeds the remaining budget ${left}s - exiting without touching the stamp" >> "$O/$P.log"
        exit 4
      fi
      echo "$(date -u +%FT%TZ) retry $try (gog rc=$grc): sleeping the published window ${fb}s: $(head -c 120 "$O/$P.err")" >> "$O/$P.log"
      sleep "$fb"
    fi
  done
  [ -z "$out" ] && { echo "$(date -u +%FT%TZ) FAILED page $n" >> "$O/$P.log"; exit 1; }
  echo "$out" > "$O/$P-$n.json"; n=$((n+1))
  TOK=$(echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin).get('nextPageToken') or '')")
  [ -z "$TOK" ] && { echo "$(date -u +%FT%TZ) DONE pages=$n" >> "$O/$P.log"; exit 0; }
  # The pause between pages is part of the budget too: a pause that outlasts the remaining time used to be
  # slept anyway and the caller's 1500 s kill landed mid-pause, losing the run after a successful page.
  ppause=$PAGE_PAUSE
  pl=$(( BUDGET - ( $(date -u +%s) - START_AT ) ))
  if [ "$pl" -le 0 ] || [ "$ppause" -ge "$pl" ]; then
    echo "$(date -u +%FT%TZ) page pause ${ppause}s does not fit the remaining budget ${pl}s after page $n - stopping incomplete (no DONE, stamp untouched)" >> "$O/$P.log"
    exit 4
  fi
  sleep "$ppause"
done
