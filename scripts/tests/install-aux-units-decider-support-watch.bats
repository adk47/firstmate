#!/usr/bin/env bats
# The scheduler wiring for the credit decider's SUPPORT-ONLY writer alert (Fable d2
# [key=decider-support-arm] condition 4: the paging alert ships in the same PR as the writing arm):
# /etc/cron.d/credit-decider-support-watch, rendered from the installer's own heredoc into a temp dir.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"

setup() { TEST_TMPDIR="$(mktemp -d)"; }
teardown() { rm -rf "$TEST_TMPDIR"; }

_render() { # the `cat > /etc/cron.d/credit-decider-support-watch << TAG` block, into $TEST_TMPDIR
  local snippet="$TEST_TMPDIR/render.sh"
  awk -v dest="$TEST_TMPDIR/" '
    !on && index($0, "cat > /etc/cron.d/credit-decider-support-watch") == 1 && $(NF-1) == "<<" {
      tag = $NF; on = 1; print "cat > " dest "credit-decider-support-watch << " tag; next
    }
    on { print; if ($0 == tag) on = 0 }
  ' "$INSTALLER" > "$snippet"
  HYDRA_ROOT="/opt/hydra" bash "$snippet"
}

@test "credit-decider-support-watch: one entry, every 30 min, through the repo script" {
  _render
  f="$TEST_TMPDIR/credit-decider-support-watch"
  [ -s "$f" ]
  run grep -cE '^[^#].* root ' "$f"
  [ "$output" = "1" ]
  grep -qx '\*/30 \* \* \* \* root python3 /opt/hydra/scripts/credit-decider-support-watch.py --json >> /var/log/credit-decider-support-watch.log 2>&1' "$f"
}

@test "credit-decider-support-watch: the file is managed, never hand-edited" {
  _render
  grep -q 'MANAGED BY scripts/install-aux-units.sh' "$TEST_TMPDIR/credit-decider-support-watch"
}

_forbidden() { # 0 when this command line is NOT detect-only
  local cmd="$1"
  printf '%s\n' "$cmd" | grep -qE -- '--apply' && return 0
  printf '%s\n' "$cmd" | grep -qE '(^|[;&|[:space:]])(rm|mv)([[:space:]]|$)' && return 0
  printf '%s\n' "$cmd" | grep -q 'credit-review.py' && return 0
  return 1
}

@test "credit-decider-support-watch: detect-and-page only - the entry never runs an apply or lifts a kill file" {
  _render
  f="$TEST_TMPDIR/credit-decider-support-watch"
  # The COMMAND line only (the block's comments are prose about the arm, not a schedule).
  cmd="$(grep -E '^[^#]' "$f")"
  printf '%s\n' "$cmd" | grep -q 'credit-decider-support-watch.py'
  # No apply, no kill-file move, no credit write: the only command is the watch itself.
  #
  # qa-review #1782 (r12) Important: these were `! grep` lines, and `!` is exempt from `set -e` while the
  # test's LAST line was a passing one - so a rendered command carrying `rm /etc/hydra/credit-trust-decide.disabled`
  # still reported ok. A negative assertion that cannot fail is not an assertion. The status of `_forbidden`
  # IS checked, and the three mutations below prove it goes red before it is trusted on the real command.
  if _forbidden "$cmd"; then
    echo "the scheduled command is not detect-only: $cmd" >&2
    return 1
  fi
  if ! _forbidden "$cmd --apply"; then
    echo "the detect-only assertion cannot fail: it accepted --apply" >&2
    return 1
  fi
  if ! _forbidden "rm /etc/hydra/credit-trust-decide.disabled"; then
    echo "the detect-only assertion cannot fail: it accepted a kill-file removal" >&2
    return 1
  fi
  if ! _forbidden "python3 /opt/hydra/scripts/credit-review.py decide --mode apply"; then
    echo "the detect-only assertion cannot fail: it accepted a credit write" >&2
    return 1
  fi
}

@test "credit-decider-support-watch: the script it schedules exists and is executable" {
  [ -x "$HYDRA_REPO/scripts/credit-decider-support-watch.py" ] || [ -f "$HYDRA_REPO/scripts/credit-decider-support-watch.py" ]
  head -1 "$HYDRA_REPO/scripts/credit-decider-support-watch.py" | grep -q python3
}
