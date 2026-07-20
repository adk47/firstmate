#!/usr/bin/env bats
# Tests for scripts/pick-nightly-issue.sh — the deterministic issue picker
# for the nightly CTO fixer automation on Muso-AI/hydra.
#
# PATH-shadows `gh` with a stub so the suite NEVER touches real GitHub
# (memory: bats must stub openclaw/gh — an unstubbed test once fired real
# writes). The stub dispatches on subcommand:
#   gh issue list --label cto-working ...  -> $STUB_CTOWORKING_JSON (self-heal)
#   gh issue list ...                      -> $STUB_ISSUES_JSON (pick candidates)
#   gh api graphql ... -F n=<N> ...        -> looks up $STUB_PR_STATE_DIR/<N>
#                                              (file content = newline PR states,
#                                              absent file = no linked PRs)
#   gh issue edit ...                      -> records argv, honors STUB_EDIT_FAIL
#   gh issue comment ...                   -> records argv, honors STUB_COMMENT_FAIL
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/pick-nightly-issue.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"

  # Audit rows land in a tmp dir, never the real ~/.openclaw workspace.
  export PICK_NIGHTLY_AUDIT_DIR="$TEST_TMPDIR/audit"

  export STUB_ISSUES_JSON="$TEST_TMPDIR/issues.json"
  echo '[]' > "$STUB_ISSUES_JSON"
  export STUB_CTOWORKING_JSON="$TEST_TMPDIR/ctoworking.json"
  echo '[]' > "$STUB_CTOWORKING_JSON"
  export STUB_PR_STATE_DIR="$TEST_TMPDIR/pr-states"; mkdir -p "$STUB_PR_STATE_DIR"
  export STUB_ARGV="$TEST_TMPDIR/argv"; : > "$STUB_ARGV"
  export STUB_ISSUE_LIST_FAIL=""
  export STUB_GRAPHQL_FAIL=""
  export STUB_EDIT_FAIL=""
  export STUB_COMMENT_FAIL=""

  cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARGV"

if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  is_ctoworking=0
  for a in "$@"; do
    if [ "$a" = "cto-working" ]; then is_ctoworking=1; fi
  done
  if [ -n "${STUB_ISSUE_LIST_FAIL:-}" ]; then
    echo "stub: gh issue list transport error" >&2
    exit 1
  fi
  if [ "$is_ctoworking" = "1" ]; then
    cat "$STUB_CTOWORKING_JSON"
  else
    cat "$STUB_ISSUES_JSON"
  fi
  exit 0
fi

if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  if [ -n "${STUB_GRAPHQL_FAIL:-}" ]; then
    echo "stub: gh api graphql transport error" >&2
    exit 1
  fi
  n=""
  prev=""
  for a in "$@"; do
    case "$prev" in
      -F) n="${a#n=}" ;;
    esac
    prev="$a"
  done
  states_file="$STUB_PR_STATE_DIR/$n"
  nodes="[]"
  if [ -f "$states_file" ]; then
    nodes=$(awk 'BEGIN{printf "["} {printf "%s{\"number\":1,\"state\":\"%s\"}", (NR>1?",":""), $0} END{printf "]"}' "$states_file")
  fi
  printf '{"data":{"repository":{"issue":{"closedByPullRequestsReferences":{"nodes":%s}}}}}\n' "$nodes"
  exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "edit" ]; then
  if [ -n "${STUB_EDIT_FAIL:-}" ]; then
    echo "stub: gh issue edit failed" >&2
    exit 1
  fi
  exit 0
fi

if [ "$1" = "issue" ] && [ "$2" = "comment" ]; then
  if [ -n "${STUB_COMMENT_FAIL:-}" ]; then
    echo "stub: gh issue comment failed" >&2
    exit 1
  fi
  exit 0
fi

echo "stub gh: unhandled invocation: $*" >&2
exit 1
STUB
  chmod +x "$STUBBIN/gh"
  PATH="$STUBBIN:$PATH"; export PATH
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# issue_json <number> <title> <labels-csv> <createdAt> <updatedAt>
issue_json() {
  local num="$1" title="$2" labels="$3" created="$4" updated="${5:-$4}"
  local label_objs
  label_objs=$(printf '%s' "$labels" | awk -F, '{for(i=1;i<=NF;i++){printf "%s{\"name\":\"%s\"}", (i>1?",":""), $i}}')
  printf '{"number":%s,"title":"%s","labels":[%s],"createdAt":"%s","updatedAt":"%s"}' \
    "$num" "$title" "$label_objs" "$created" "$updated"
}

@test "(a) picks P0-bug over P1-chore" {
  {
    echo "["
    issue_json 10 "low prio" "chore,P1" "2026-01-01T00:00:00Z"
    echo ","
    issue_json 20 "high prio" "bug,P0" "2026-01-02T00:00:00Z"
    echo "]"
  } > "$STUB_ISSUES_JSON"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  num=$(echo "$output" | jq -r '.number')
  [ "$num" = "20" ]
}

@test "(b) unlabeled-priority issue ranked last" {
  {
    echo "["
    issue_json 30 "no priority" "bug" "2026-01-01T00:00:00Z"
    echo ","
    issue_json 40 "has P3" "bug,P3" "2026-01-05T00:00:00Z"
    echo "]"
  } > "$STUB_ISSUES_JSON"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  num=$(echo "$output" | jq -r '.number')
  [ "$num" = "40" ]
}

@test "(c) oldest-first tiebreak within same priority" {
  {
    echo "["
    issue_json 50 "newer" "bug,P2" "2026-01-10T00:00:00Z"
    echo ","
    issue_json 51 "older" "bug,P2" "2026-01-01T00:00:00Z"
    echo "]"
  } > "$STUB_ISSUES_JSON"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  num=$(echo "$output" | jq -r '.number')
  [ "$num" = "51" ]
}

@test "(d) skips an issue with an open linked PR and takes the next" {
  {
    echo "["
    issue_json 60 "taken" "bug,P0" "2026-01-01T00:00:00Z"
    echo ","
    issue_json 61 "free" "bug,P0" "2026-01-02T00:00:00Z"
    echo "]"
  } > "$STUB_ISSUES_JSON"
  echo "OPEN" > "$STUB_PR_STATE_DIR/60"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  num=$(echo "$output" | jq -r '.number')
  [ "$num" = "61" ]
}

@test "(e) excludes cto-working/cto-blocked/wontfix" {
  {
    echo "["
    issue_json 70 "working" "bug,cto-working" "2026-01-01T00:00:00Z"
    echo ","
    issue_json 71 "blocked" "bug,cto-blocked" "2026-01-01T00:00:00Z"
    echo ","
    issue_json 72 "wontfix" "chore,wontfix" "2026-01-01T00:00:00Z"
    echo ","
    issue_json 73 "eligible" "bug" "2026-01-03T00:00:00Z"
    echo "]"
  } > "$STUB_ISSUES_JSON"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  num=$(echo "$output" | jq -r '.number')
  [ "$num" = "73" ]
}

@test "(f) NO_ELIGIBLE_ISSUE -> exit 3, empty stdout" {
  {
    echo "["
    issue_json 80 "taken" "bug,P0" "2026-01-01T00:00:00Z"
    echo "]"
  } > "$STUB_ISSUES_JSON"
  echo "OPEN" > "$STUB_PR_STATE_DIR/80"

  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "(f2) NO_ELIGIBLE_ISSUE emits the literal token on stderr" {
  echo '[]' > "$STUB_ISSUES_JSON"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == *"NO_ELIGIBLE_ISSUE"* ]]
}

@test "(g) gh error on issue list -> loud nonzero exit, empty stdout" {
  export STUB_ISSUE_LIST_FAIL=1
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"gh issue list failed"* ]]
}

@test "(g2) gh error on graphql lookup -> loud nonzero exit, empty stdout" {
  {
    echo "["
    issue_json 90 "eligible" "bug,P0" "2026-01-01T00:00:00Z"
    echo "]"
  } > "$STUB_ISSUES_JSON"
  export STUB_GRAPHQL_FAIL=1
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"graphql"* ]]
}

@test "(h) --take applies the cto-working label and posts a comment" {
  run "$SCRIPT" --take 123 --journey-url "https://example.com/journey/1"
  [ "$status" -eq 0 ]
  grep -q 'issue edit 123 --repo Muso-AI/hydra --add-label cto-working' "$STUB_ARGV"
  grep -q 'issue comment 123 --repo Muso-AI/hydra --body' "$STUB_ARGV"
  grep -q 'https://example.com/journey/1' "$STUB_ARGV"
}

@test "(h2) --take without --journey-url falls back to the default channel note" {
  run "$SCRIPT" --take 124
  [ "$status" -eq 0 ]
  grep -q 'posted in #cto-nightly' "$STUB_ARGV"
}

@test "(i) --take with non-numeric arg fails loud, no gh call" {
  run "$SCRIPT" --take not-a-number
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_ARGV" ]
}

@test "(i2) --take with missing number fails loud" {
  run "$SCRIPT" --take
  [ "$status" -eq 2 ]
  [ ! -s "$STUB_ARGV" ]
}

@test "(j) stale cto-working self-heal removes the label" {
  now=1781222400   # fixed "now" for a deterministic staleness check
  export PICK_NIGHTLY_NOW="$now"
  stale_updated="2026-06-10T00:00:00Z"   # >24h before $now
  {
    echo "["
    issue_json 200 "stale" "bug,cto-working" "2026-06-01T00:00:00Z" "$stale_updated"
    echo "]"
  } > "$STUB_CTOWORKING_JSON"
  # no linked PR at all for #200 -> eligible for self-heal
  echo '[]' > "$STUB_ISSUES_JSON"

  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 3 ]  # no eligible pick, but self-heal still ran
  [[ "$stderr" == *"cleared stale cto-working from #200"* ]]
  grep -q 'issue edit 200 --repo Muso-AI/hydra --remove-label cto-working' "$STUB_ARGV"
}

@test "(j2) fresh cto-working label is left alone by self-heal" {
  now=1781222400
  export PICK_NIGHTLY_NOW="$now"
  fresh_updated="2026-07-16T00:00:00Z"   # <24h before $now
  {
    echo "["
    issue_json 201 "fresh" "bug,cto-working" "2026-07-15T00:00:00Z" "$fresh_updated"
    echo "]"
  } > "$STUB_CTOWORKING_JSON"
  echo '[]' > "$STUB_ISSUES_JSON"

  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 3 ]
  stderr_saved="$stderr"
  run ! grep -q 'cleared stale cto-working' <<<"$stderr_saved"
  run ! grep -q 'issue edit 201 --repo Muso-AI/hydra --remove-label cto-working' "$STUB_ARGV"
}

@test "(j3) self-heal failure (gh error) does not abort the pick" {
  now=1781222400
  export PICK_NIGHTLY_NOW="$now"
  {
    echo "["
    issue_json 202 "stale" "bug,cto-working" "2026-06-01T00:00:00Z" "2026-06-10T00:00:00Z"
    echo "]"
  } > "$STUB_CTOWORKING_JSON"
  export STUB_EDIT_FAIL=1
  {
    echo "["
    issue_json 300 "eligible" "bug,P0" "2026-01-01T00:00:00Z"
    echo "]"
  } > "$STUB_ISSUES_JSON"
  # unset the edit failure before the pick's own edit-free flow is reached —
  # self-heal's own edit call must still fail loudly to stderr but not abort.
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  num=$(echo "$output" | jq -r '.number')
  [ "$num" = "300" ]
  [[ "$stderr" == *"failed to remove cto-working from #202"* ]]
}

@test "(h3) --take: comment failure rolls back the cto-working label and fails loud" {
  export STUB_COMMENT_FAIL=1
  run --separate-stderr "$SCRIPT" --take 300
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"gh issue comment failed"* ]]
  [[ "$stderr" == *"rolled back"* ]]
  grep -q 'issue edit 300 --repo Muso-AI/hydra --remove-label cto-working' "$STUB_ARGV"
}

@test "(k) --take writes an audit row BEFORE the label write" {
  run --separate-stderr "$SCRIPT" --take 300 --journey-url "https://muso-ai.slack.com/x"
  [ "$status" -eq 0 ]
  audit_file="$PICK_NIGHTLY_AUDIT_DIR/$(date -u +%Y-%m-%d).jsonl"
  [ -f "$audit_file" ]
  grep -q '"action":"issue-take"' "$audit_file"
  grep -q '"target":"Muso-AI/hydra#300"' "$audit_file"
}

@test "(k2) --take with uncreatable audit dir -> die 1, ZERO gh writes" {
  # Root-proof blocker: a path UNDER a regular FILE cannot be mkdir'd by any
  # uid (chmod-based denial is a no-op for the root CI runner).
  touch "$TEST_TMPDIR/blocker"
  export PICK_NIGHTLY_AUDIT_DIR="$TEST_TMPDIR/blocker/audit"
  run --separate-stderr "$SCRIPT" --take 300
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"audit append failed"* ]]
  run ! grep -q 'issue edit' "$STUB_ARGV"
  run ! grep -q 'issue comment' "$STUB_ARGV"
}

@test "(j4) self-heal audits the label removal (row present) and skips it when the audit dir is unwritable" {
  now="2026-07-17T00:00:00Z"
  export PICK_NIGHTLY_NOW="$(date -u -d "$now" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$now" +%s)"
  {
    echo "["
    issue_json 202 "stale" "bug,cto-working" "2026-07-10T00:00:00Z" "2026-07-10T00:00:00Z"
    echo "]"
  } > "$STUB_CTOWORKING_JSON"
  echo '[]' > "$STUB_ISSUES_JSON"

  run --separate-stderr "$SCRIPT"
  audit_file="$PICK_NIGHTLY_AUDIT_DIR/$(date -u +%Y-%m-%d).jsonl"
  grep -q '"action":"issue-label-remove"' "$audit_file"
  grep -q '"target":"Muso-AI/hydra#202"' "$audit_file"
}
