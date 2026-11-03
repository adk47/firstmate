#!/usr/bin/env bash
# End-to-end demonstration of bin/fm-merge-queue.sh: one timer tick against a
# home whose queue file holds several merge-ready pull requests plus rows that
# must not land, then a second tick the same day.
#
# The forge is a local mock `gh` that answers the queue's own --json/--jq reads
# from per-PR fixtures, so the script's real jq filters and its real decision
# logic run unchanged. bin/fm-pr-merge.sh is stubbed (a real merge would need a
# live pull request); the stub records the exact argv it was handed.
set -u

ROOT=/home/aaron/.no-mistakes/worktrees/72295860b10d/01M6HMWX1R5S65JJZMPBFPGWR7
QUEUE_SCRIPT=$ROOT/bin/fm-merge-queue.sh
DEMO=$(mktemp -d "${TMPDIR:-/tmp}/fm-mq-demo.XXXXXX")

HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbc
HEAD_C=cccccccccccccccccccccccccccccccccccccccd
HEAD_D=ddddddddddddddddddddddddddddddddddddddde
HEAD_E=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeef
HEAD_F=ffffffffffffffffffffffffffffffffffffffa0
HEAD_G=9999999999999999999999999999999999999aab

say() { printf '\n=== %s ===\n' "$*"; }

mkdir -p "$DEMO"/{data,bin,state,fakebin,fixtures}

printf 'window=t\n' >"$DEMO/state/task-a.meta"
printf 'window=t\n' >"$DEMO/state/task-b.meta"

# --- the merge entrypoint the queue hands every merge to --------------------
cat >"$DEMO/bin/fm-pr-merge.sh" <<'SH'
#!/usr/bin/env bash
# Stand-in for bin/fm-pr-merge.sh: records the argv the queue handed it and
# reports the verified merge a live run would report.
printf '%s\n' "$*" >>"$FM_TEST_MERGE_LOG"
printf 'fm-pr-merge: verified merge of %s\n' "$2"
SH
chmod +x "$DEMO/bin/fm-pr-merge.sh"

# --- the forge mock: real gh --json/--jq semantics over local fixtures ------
cat >"$DEMO/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'gh %s\n' "$*" >>"$FM_TEST_GH_LOG"
url=
jqf=
prev=
for a in "$@"; do
  [ "$prev" = "--jq" ] && jqf=$a
  prev=$a
  case "$a" in https://github.com/*) url=$a ;; esac
done
num=${url##*/}
case "${1:-} ${2:-}" in
  "pr view")
    jq -r "$jqf" <"$FM_TEST_DIR/fixtures/pr-$num.json"
    ;;
  "pr checks")
    # gh pr checks exits 8 while a check is pending, 1 with no checks at all.
    jq -r "$jqf" <"$FM_TEST_DIR/fixtures/checks-$num.json"
    if grep -q '"bucket": *"pending"' "$FM_TEST_DIR/fixtures/checks-$num.json"; then
      exit 8
    fi
    ;;
esac
exit 0
SH
chmod +x "$DEMO/fakebin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$DEMO/fakebin/gh-axi"
chmod +x "$DEMO/fakebin/gh-axi"

# pr_fixture <number> <state> <head> <labels-json> <title> <body>
pr_fixture() {
  local n=$1 state=$2 head=$3 labels=$4 title=$5 body=$6
  jq -n --arg s "$state" --arg h "$head" --argjson l "$labels" \
    --arg t "$title" --arg b "$body" \
    '{state: $s, isDraft: false, headRefOid: $h, labels: $l, title: $t, body: $b}' \
    >"$DEMO/fixtures/pr-$n.json"
}

# checks_fixture <number> <name:bucket>...
checks_fixture() {
  local n=$1
  shift
  local json='[]' spec
  for spec in "$@"; do
    json=$(jq -c --arg name "${spec%%:*}" --arg bucket "${spec##*:}" \
      '. + [{name: $name, bucket: $bucket}]' <<<"$json")
  done
  printf '%s\n' "$json" >"$DEMO/fixtures/checks-$n.json"
}

pr_fixture 12 OPEN "$HEAD_A" '[]' 'Add widgets pager' 'Plain change, nothing fenced.'
checks_fixture 12 qa-review:pass build:pass lint:pass

pr_fixture 13 OPEN "$HEAD_B" '[]' 'Charge credits on retry' 'Touches the credit ledger.'
checks_fixture 13 qa-review:pass build:pass credit-approval-guard:fail

pr_fixture 14 OPEN "$HEAD_C" '[]' 'Adjust pricing copy' 'Customer copy tweak.'
checks_fixture 14 qa-review:pass build:pass
# fence it through its label
jq -c '.labels = [{name: "money"}]' "$DEMO/fixtures/pr-14.json" >"$DEMO/fixtures/pr-14.tmp" \
  && mv "$DEMO/fixtures/pr-14.tmp" "$DEMO/fixtures/pr-14.json"

pr_fixture 15 OPEN "$HEAD_D" '[]' 'Refactor loader' 'Head has moved since it was queued.'
checks_fixture 15 qa-review:pass build:pass

pr_fixture 16 OPEN "$HEAD_E" '[]' 'Tidy tests' 'Still running.'
checks_fixture 16 qa-review:pass build:pending

pr_fixture 17 OPEN "$HEAD_F" '[]' 'Rename helper' 'No QA review posted yet.'
checks_fixture 17 build:pass lint:pass

pr_fixture 19 OPEN "$HEAD_G" '[]' 'Add orders table' $'Adds the orders table.\n\nThis change ships the production DDL for orders.'
checks_fixture 19 qa-review:pass build:pass

# --- the queue the captain hand-wrote --------------------------------------
cat >"$DEMO/data/go-queue.txt" <<EOF
# owner: acme
# The captain's own notes survive every rewrite.

widgets 12 $HEAD_A task-a squash
widgets 13 $HEAD_B task-b squash
widgets 14 $HEAD_C task-a squash
widgets 15 1111111111 task-b squash
widgets 16 $HEAD_E task-a squash
widgets 17 $HEAD_F task-a squash
widgets 19 $HEAD_G task-b squash
EOF
chmod 0640 "$DEMO/data/go-queue.txt"

run_queue() {
  FM_HOME="$DEMO" FM_ROOT_OVERRIDE="$DEMO" \
    FM_TEST_MERGE_LOG="$DEMO/merge.log" FM_TEST_GH_LOG="$DEMO/gh.log" \
    FM_TEST_DIR="$DEMO" PATH="$DEMO/fakebin:$PATH" \
    "$QUEUE_SCRIPT" "$@"
}

say "0. the home's timer units (systemctl --user enable --now fm-merge-queue.timer)"
FM_HOME="$DEMO" FM_ROOT_OVERRIDE="$DEMO" "$QUEUE_SCRIPT" unit service
echo '---'
FM_HOME="$DEMO" FM_ROOT_OVERRIDE="$DEMO" "$QUEUE_SCRIPT" unit timer

say "1. what the captain queued by hand (data/go-queue.txt)"
cat "$DEMO/data/go-queue.txt"

say "2. tick 1: fm-merge-queue.sh run  (what the ten-minute timer executes)"
run_queue run
printf '\nexit status: %s\n' "$?"

say "3. what the merge entrypoint was handed (bin/fm-pr-merge.sh argv)"
cat "$DEMO/merge.log"

say "4. the queue file after the tick (hand-written comments kept)"
cat "$DEMO/data/go-queue.txt"

say "5. the ledger (every verdict, one line each)"
cat "$DEMO/state/merge-queue/ledger.tsv"

say "6. the ONE durable line the captain wakes to (state/.wake-queue)"
cat "$DEMO/state/.wake-queue"

say "7. the dated detail file the daily line points at"
DETAIL=$(sed -n 's/.*detail: \([^;]*\).*/\1/p' "$DEMO/state/.wake-queue")
cat "$DETAIL"

say "8. tick 2, ten minutes later on the same day"
run_queue run
printf '\nlines in the wake queue after tick 2: %s\n' \
  "$(wc -l <"$DEMO/state/.wake-queue" | tr -d ' ')"

say "9. fm-merge-queue.sh status (records only, no forge call)"
: >"$DEMO/gh.log"
run_queue status
printf '\nforge calls made by status: %s\n' "$(wc -l <"$DEMO/gh.log" | tr -d ' ')"

say "10. the queue the captain is left with"
cat "$DEMO/data/go-queue.txt"

say "11. the timer units parse as real systemd units"
mkdir -p "$DEMO/systemd"
FM_HOME="$DEMO" FM_ROOT_OVERRIDE="$DEMO" "$QUEUE_SCRIPT" unit service >"$DEMO/systemd/fm-merge-queue.service"
FM_HOME="$DEMO" FM_ROOT_OVERRIDE="$DEMO" "$QUEUE_SCRIPT" unit timer >"$DEMO/systemd/fm-merge-queue.timer"
for u in fm-merge-queue.service fm-merge-queue.timer; do
  out=$(systemd-analyze verify --man=no "$DEMO/systemd/$u" 2>&1)
  printf 'systemd-analyze verify %s: rc=%s %s\n' "$u" "$?" "${out:- (no diagnostics)}"
done
systemctl --user list-timers >/dev/null 2>&1 && echo 'systemd user manager reachable' || echo 'systemd user manager not reachable in this shell'

printf '\ndemo home: %s\n' "$DEMO"
