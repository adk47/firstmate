#!/usr/bin/env bats
# The cancel page's delivery contract (firstmate churn-risk-signal-prevent-p1 item 4).
#
# Why this file exists: cancel_alert.commit() advances the watermark and writes the
# 30-day sent ledger, so it may only run after Slack CONFIRMED every post. The shell
# wrapper used to branch on slack_notify, which is best-effort by contract and always
# returns 0 — so a revoked token still committed, and the page was suppressed for
# alert.dedup_days. These cases execute the real wrapper against a stubbed `muso`
# (the delivery boundary) and a stubbed classifier (the data source), and assert the
# observable outcome: whether --commit ran at all.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

setup() {
  WORKDIR="$(mktemp -d)"
  export WORKDIR
  STUBDIR="$WORKDIR/bin"
  REAL_PYTHON="$(type -P python3)"
  export REAL_PYTHON
  mkdir -p "$STUBDIR" "$WORKDIR/state"

  cat > "$STUBDIR/python3" <<'STUB'
#!/usr/bin/env bash
# Fake the two classifier calls; everything else (the payload builder) is real python.
# The builder is the `python3 -` heredoc, and these knobs break it on demand.
if [ "$1" = "-" ] && [ -e "$WORKDIR/fail_builder" ]; then
  echo "simulated builder crash" >&2
  exit 1
fi
if [ "$1" = "-c" ]; then
  case "$2" in
    *"store"*"dir"*)                   echo "$WORKDIR/state" ;;
    *"unclassified"*)                  echo "${UNCLASSIFIED_STUB:-0}" ;;
    *"len("*)                          echo "${ALERTS_COUNT_STUB:-1}" ;;
    *"watermark"*)                     echo "2026-11-04T04:20:00Z" ;;
    *)                                 echo "" ;;
  esac
  exit 0
fi
case "$1" in
  */cancel_alert.py)
    shift
    printf '%s\n' "$*" >> "$WORKDIR/classifier.log"
    case " $* " in
      *" --alerts "*)
        if [ -e "$WORKDIR/alerts.json" ]; then
          cat "$WORKDIR/alerts.json"
        else
          printf '%s' '{"watermark":"2026-11-04T04:20:00Z","alerts":[{"user_id":7,"text":"paying user cancelled with an open credits issue","lane":"credit-review","tag":"churned:2026-11-04"}]}'
        fi
        ;;
      *" --commit "*)
        # the commit writes the watermark + sent ledger; a full/unwritable state
        # filesystem makes it fail AFTER the page is already out
        exit "${COMMIT_STUB_RC:-0}" ;;
    esac
    exit 0
    ;;
esac
exec "$REAL_PYTHON" "$@"
STUB
  chmod +x "$STUBDIR/python3"

  cat > "$STUBDIR/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORKDIR/muso.log"
exit "${MUSO_STUB_RC:-0}"
STUB
  chmod +x "$STUBDIR/muso"

  : > "$WORKDIR/main.env"
}

teardown() {
  rm -rf "$WORKDIR"
}

run_wrapper() {
  run env \
    PATH="$STUBDIR:$PATH" \
    HYDRA_ROOT="$HYDRA_REPO" \
    UNCLASSIFIED_STUB="${2:-0}" \
    ALERTS_COUNT_STUB="${3:-1}" \
    COMMIT_STUB_RC="${4:-0}" \
    MAIN_ENV="$WORKDIR/main.env" \
    SLACK_CHANNEL="C0TESTCHAN" \
    SLACK_NOTIFY_BOT="devops" \
    MUSO_SLACK_BOT_TOKEN_DEVOPS="stub-token" \
    MUSO_BIN="$STUBDIR/muso" \
    MUSO_STUB_RC="$1" \
    WORKDIR="$WORKDIR" \
    bash "$HYDRA_REPO/scripts/churn/cancel_with_open_issue.sh"
}

@test "a confirmed post commits the watermark and the sent ledger" {
  run_wrapper 0
  [ "$status" -eq 0 ]
  grep -q -- "--commit" "$WORKDIR/classifier.log"
  grep -q "paying user cancelled with an open credits issue" "$WORKDIR/muso.log"
}

@test "a failed post leaves the watermark and the sent ledger untouched" {
  run_wrapper 1
  [ "$status" -eq 1 ]
  # the page must retry next hour: no commit means no dedup entry for 30 days
  # (checked branch, not `! grep` as a bare command: bats reports the status of the
  # LAST line, so a trailing passing command made the prohibition vacuous - QA #1771)
  if grep -q -- "--commit" "$WORKDIR/classifier.log"; then
    echo "the wrapper committed after a failed post:"; cat "$WORKDIR/classifier.log"; false
  fi
  grep -q "post FAILED" <<< "$output"
}

@test "the payload reaches Slack on the policy channel, and is the rendered alert text" {
  run_wrapper 0
  [ "$status" -eq 0 ]
  grep -q -- "--channel C0TESTCHAN" "$WORKDIR/muso.log"
  grep -q -- "--text paying user cancelled with an open credits issue" "$WORKDIR/muso.log"
}

@test "a payload builder that fails posts nothing and commits nothing" {
  : > "$WORKDIR/fail_builder"
  run_wrapper 0
  [ "$status" -eq 1 ]
  if grep -q -- "--commit" "$WORKDIR/classifier.log"; then
    echo "the wrapper committed with no payload:"; cat "$WORKDIR/classifier.log"; false
  fi
  [ ! -s "$WORKDIR/muso.log" ]
  grep -q "FATAL could not build" <<< "$output"
}

@test "a canceller nobody could classify is reported and retried, not swallowed" {
  run_wrapper 0 1
  [ "$status" -eq 1 ]
  # a page may still have gone out for someone else, so the run commits; what must not
  # happen is the miss reading as a quiet hour
  grep -q -- "--commit" "$WORKDIR/classifier.log"
  grep -q "UNCLASSIFIED 1 canceller" <<< "$output"
}

@test "a confirmed post whose commit fails is reported as a failed tick" {
  # the page is already out; the commit that would suppress it for 30 days is not.
  # Reporting success here hides a re-page next hour behind a green cron log.
  run_wrapper 0 0 1 1
  [ "$status" -eq 1 ]
  grep -q "paying user cancelled with an open credits issue" "$WORKDIR/muso.log"
  grep -q "FATAL commit failed after delivery" <<< "$output"
}

@test "a quiet hour whose commit fails is reported as a failed tick" {
  run_wrapper 0 0 0 1
  [ "$status" -eq 1 ]
  [ ! -s "$WORKDIR/muso.log" ]
  grep -q "FATAL commit failed:" <<< "$output"
}

@test "an alert that produced no payload is not counted as delivered" {
  printf '%s' '{"watermark":"2026-11-04T04:20:00Z","alerts":[{"user_id":7,"text":"","lane":"credit-review","tag":"churned:2026-11-04"}]}' > "$WORKDIR/alerts.json"
  run_wrapper 0
  [ "$status" -eq 1 ]
  if grep -q -- "--commit" "$WORKDIR/classifier.log"; then
    echo "the wrapper committed an undelivered alert:"; cat "$WORKDIR/classifier.log"; false
  fi
  [ ! -s "$WORKDIR/muso.log" ]
  grep -q "FATAL built 0 of 1" <<< "$output"
}
