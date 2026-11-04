#!/usr/bin/env bats
# The scheduler wiring for the durable claim-status wave (claim-lane-resume-c2, firstmate 040/042):
# /etc/cron.d/hydra-claim-status, rendered from the installer's own heredoc into a temp dir.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"

setup() { TEST_TMPDIR="$(mktemp -d)"; }
teardown() { rm -rf "$TEST_TMPDIR"; }

_render() { # the `cat > /etc/cron.d/hydra-claim-status << TAG` block, written into $TEST_TMPDIR
  local snippet="$TEST_TMPDIR/render.sh"
  awk -v dest="$TEST_TMPDIR/" '
    !on && index($0, "cat > /etc/cron.d/hydra-claim-status") == 1 && $(NF-1) == "<<" {
      tag = $NF; on = 1; print "cat > " dest "hydra-claim-status << " tag; next
    }
    on { print; if ($0 == tag) on = 0 }
  ' "$INSTALLER" > "$snippet"
  HYDRA_ROOT="/opt/hydra" bash "$snippet"
}

@test "hydra-claim-status: one daily DRY-RUN audit at 01:15Z through the repo wrapper - the sends come from the signed list" {
  _render
  f="$TEST_TMPDIR/hydra-claim-status"
  [ -s "$f" ]
  run grep -cE '^[^#].* root ' "$f"
  [ "$output" = "1" ]
  # G7 follow-up (Fable driver 11-03 20:2xZ): ONE SENDER PER FAMILY - the wave audits, the signed list sends.
  grep -qx '15 1 \* \* \* root MODE=dry-run /opt/hydra/scripts/claim-status-daily.sh >> /var/lib/hydra/credit-review/claim-status-daily.log 2>&1' "$f"
  ! grep -q 'MODE=apply' "$f"
  grep -q 'MANAGED BY scripts/install-aux-units.sh' "$f"
}

@test "the wrapper states the one-sender rule in its own header, not only in the installer" {
  grep -q 'ONE SENDER PER FAMILY' "$HYDRA_REPO/scripts/claim-status-daily.sh"
  grep -q 'MODE=dry-run' "$HYDRA_REPO/scripts/claim-status-daily.sh"
  grep -q '#1634' "$HYDRA_REPO/scripts/claim-status-daily.sh"
}

@test "the wrapper the cron runs is in the repo, executable, and names both stop switches" {
  [ -x "$HYDRA_REPO/scripts/claim-status-daily.sh" ]
  grep -q '/etc/hydra/claim-status-daily.disabled' "$HYDRA_REPO/scripts/claim-status-daily.sh"
  grep -q '/etc/hydra/credit-ops-notes.disabled' "$HYDRA_REPO/scripts/claim-status-daily.sh"
  grep -q 'chmod 644 /etc/cron.d/hydra-claim-status' "$INSTALLER"
}

@test "the wrapper refuses an unknown MODE before reading secrets" {
  run env MODE=send STATE_ROOT="$TEST_TMPDIR/s" MAIN_ENV=/nonexistent bash "$HYDRA_REPO/scripts/claim-status-daily.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"MODE must be apply or dry-run"* ]]
}

@test "the wrapper fails closed when main.env is unreadable (nothing runs)" {
  run env MODE=dry-run STATE_ROOT="$TEST_TMPDIR/s" MAIN_ENV="$TEST_TMPDIR/missing.env" HYDRA_ROOT="$TEST_TMPDIR/nohydra" bash "$HYDRA_REPO/scripts/claim-status-daily.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unreadable: nothing sent"* ]]
}

# r5 on #1741: this path DID NOT PAGE. `_page` was called here but defined ~3 lines below, so bash answered
# "command not found" on stderr, the run still exited 1, and the assertion above passed - a test that survives
# deletion of the feature's code. The page is now asserted, so the ordering cannot regress silently.
@test "the main.env-unreadable exit PAGES (the night that builds no list at all must not be silent)" {
  mkdir -p "$TEST_TMPDIR/root/scripts"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/pages"\n' "$TEST_TMPDIR" > "$TEST_TMPDIR/root/notify.sh"
  chmod +x "$TEST_TMPDIR/root/notify.sh"
  mkdir -p "$TEST_TMPDIR/s"
  run env MODE=dry-run STATE_ROOT="$TEST_TMPDIR/s" MAIN_ENV="$TEST_TMPDIR/missing.env" \
    HYDRA_ROOT="$TEST_TMPDIR/nohydra" CLAIM_STATUS_NOTIFY_BIN="$TEST_TMPDIR/root/notify.sh" \
    bash "$HYDRA_REPO/scripts/claim-status-daily.sh"
  [ "$status" -eq 1 ]
  [ -s "$TEST_TMPDIR/pages" ]                       # the page went, rather than 'command not found' on stderr
  grep -q 'rc=1' "$TEST_TMPDIR/pages"
  grep -q 'unreadable' "$TEST_TMPDIR/pages"
  ! [[ "$output" == *"command not found"* ]]
}

@test "a bad MODE pages (a misconfigured cron is a standstill, not a no-op)" {
  mkdir -p "$TEST_TMPDIR/root"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/pages"\n' "$TEST_TMPDIR" > "$TEST_TMPDIR/root/notify.sh"
  chmod +x "$TEST_TMPDIR/root/notify.sh"
  mkdir -p "$TEST_TMPDIR/s"
  run env MODE=send STATE_ROOT="$TEST_TMPDIR/s" MAIN_ENV=/nonexistent HYDRA_ROOT="$TEST_TMPDIR/nohydra" \
    CLAIM_STATUS_NOTIFY_BIN="$TEST_TMPDIR/root/notify.sh" bash "$HYDRA_REPO/scripts/claim-status-daily.sh"
  [ "$status" -eq 2 ]                               # the refusal still exits 2, before any secret is read
  [ -s "$TEST_TMPDIR/pages" ]
  grep -q 'rc=2' "$TEST_TMPDIR/pages"
  grep -q "MODE='send'" "$TEST_TMPDIR/pages"
}

# ── c2 follow-up (Fable driver 11-04 08:4xZ): rc != 0 PAGES; rc = 0 does not ────────────────────────────
_stub_tree() { # a HYDRA_ROOT whose credit-review.py exits $1, plus a notifier that records its argv
  local rc="$1"
  mkdir -p "$TEST_TMPDIR/root/scripts"
  printf '#!/usr/bin/env python3\nimport sys\nprint("AUDIT would_send 0")\nsys.exit(%s)\n' "$rc" \
    > "$TEST_TMPDIR/root/scripts/credit-review.py"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/pages"\nexit "${STUB_NOTIFY_RC:-0}"\n' "$TEST_TMPDIR" \
    > "$TEST_TMPDIR/root/notify.sh"
  chmod +x "$TEST_TMPDIR/root/notify.sh"
  mkdir -p "$TEST_TMPDIR/s"
  : > "$TEST_TMPDIR/main.env"
}

@test "a failed run pages once, with its rc and the run.log line, and keeps its own exit code" {
  _stub_tree 3
  echo 'claim-status-daily AUDIT {"unreadable_systemic_ratio": 0.71}' > "$TEST_TMPDIR/s/run.log"
  run env MODE=dry-run HYDRA_ROOT="$TEST_TMPDIR/root" STATE_ROOT="$TEST_TMPDIR/s" MAIN_ENV="$TEST_TMPDIR/main.env" \
    CLAIM_STATUS_NOTIFY_BIN="$TEST_TMPDIR/root/notify.sh" bash "$HYDRA_REPO/scripts/claim-status-daily.sh"
  [ "$status" -eq 3 ]                                  # the run's rc survives the page
  [ -s "$TEST_TMPDIR/pages" ]                          # the page actually went
  [ "$(wc -l < "$TEST_TMPDIR/pages")" = "1" ]          # ONE page per failed run
  grep -q '^critical' "$TEST_TMPDIR/pages"
  grep -q 'rc=3' "$TEST_TMPDIR/pages"
  grep -q 'unreadable_systemic_ratio' "$TEST_TMPDIR/pages"   # the reason travels, not just the code
  [[ "$output" == *"paged critical: rc=3"* ]]
}

@test "a clean run pages nobody (and the pager being absent is not the reason)" {
  _stub_tree 0
  run env MODE=dry-run HYDRA_ROOT="$TEST_TMPDIR/root" STATE_ROOT="$TEST_TMPDIR/s" MAIN_ENV="$TEST_TMPDIR/main.env" \
    CLAIM_STATUS_NOTIFY_BIN="$TEST_TMPDIR/root/notify.sh" bash "$HYDRA_REPO/scripts/claim-status-daily.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/pages" ]
  # the notifier is present and executable here, so 'no pages' means 'nothing to page', not 'no pager installed'
  [ -x "$TEST_TMPDIR/root/notify.sh" ]
  [[ "$output" != *"PAGE NOT SENT"* ]]
}

@test "a page that cannot be delivered is stated, never silent, and never rewrites the run's rc" {
  _stub_tree 1
  run env MODE=dry-run HYDRA_ROOT="$TEST_TMPDIR/root" STATE_ROOT="$TEST_TMPDIR/s" MAIN_ENV="$TEST_TMPDIR/main.env" \
    CLAIM_STATUS_NOTIFY_BIN="$TEST_TMPDIR/root/notify.sh" STUB_NOTIFY_RC=1 \
    bash "$HYDRA_REPO/scripts/claim-status-daily.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PAGE NOT DELIVERED"* ]]
  [[ "$output" == *"rc=1 stands"* ]]
}

@test "no notifier at all is a stated non-page, not a crash" {
  _stub_tree 1
  run env MODE=dry-run HYDRA_ROOT="$TEST_TMPDIR/root" STATE_ROOT="$TEST_TMPDIR/s" MAIN_ENV="$TEST_TMPDIR/main.env" \
    CLAIM_STATUS_NOTIFY_BIN="$TEST_TMPDIR/root/absent.sh" bash "$HYDRA_REPO/scripts/claim-status-daily.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PAGE NOT SENT (no notifier at"* ]]
}

@test "the one-sender cron line is untouched by the pager (a page is not a send)" {
  _render
  grep -qx '15 1 \* \* \* root MODE=dry-run /opt/hydra/scripts/claim-status-daily.sh >> /var/lib/hydra/credit-review/claim-status-daily.log 2>&1' "$TEST_TMPDIR/hydra-claim-status"
  ! grep -q 'MODE=apply' "$TEST_TMPDIR/hydra-claim-status"
}

# r5 on #1741 / QA's Important: an UNOPENABLE lock reported "another run holds it" and exited 0 - the audit did not
# run and the signal described a benign peer hold. Two cases, not one: without the second, the next fix inverts them
# and nothing notices.
_lock_notifier() {
  mkdir -p "$TEST_TMPDIR/root"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/pages"\n' "$TEST_TMPDIR" > "$TEST_TMPDIR/root/notify.sh"
  chmod +x "$TEST_TMPDIR/root/notify.sh"
  mkdir -p "$TEST_TMPDIR/s"
}

@test "an unopenable lock is a PAGED failure, not 'another run holds it'" {
  _lock_notifier
  mkdir -p "$TEST_TMPDIR/s/claim-status-daily.lock"        # the lock path is a directory: exec 9> cannot open it
  echo "runs:$(ls -d "$TEST_TMPDIR/s/claim-status-daily.lock" | wc -l)" > "$TEST_TMPDIR/root/marker"
  run env MODE=dry-run STATE_ROOT="$TEST_TMPDIR/s" MAIN_ENV="$TEST_TMPDIR/missing.env" \
    HYDRA_ROOT="$TEST_TMPDIR/nohydra" CLAIM_STATUS_NOTIFY_BIN="$TEST_TMPDIR/root/notify.sh" \
    bash "$HYDRA_REPO/scripts/claim-status-daily.sh"
  [ "$status" -eq 1 ]                                      # standing condition: it must NOT look like a clean run
  [ ! -e "$TEST_TMPDIR/root/credit-review.py" ]
  [[ "$output" == *"cannot open the lock"* ]]
  [[ "$output" != *"another claim-status-daily run holds"* ]]   # the false sentence is gone
  grep -q '^critical' "$TEST_TMPDIR/pages"
  grep -q 'unopenable' "$TEST_TMPDIR/pages"
}

@test "a lock that is genuinely HELD stays silent and exits 0 (it is benign and self-clearing)" {
  _lock_notifier
  : > "$TEST_TMPDIR/s/claim-status-daily.lock"
  flock -x "$TEST_TMPDIR/s/claim-status-daily.lock" -c 'sleep 3' &
  holder=$!
  sleep 0.5
  run env MODE=dry-run STATE_ROOT="$TEST_TMPDIR/s" MAIN_ENV="$TEST_TMPDIR/missing.env" \
    HYDRA_ROOT="$TEST_TMPDIR/nohydra" CLAIM_STATUS_NOTIFY_BIN="$TEST_TMPDIR/root/notify.sh" \
    bash "$HYDRA_REPO/scripts/claim-status-daily.sh"
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"another claim-status-daily run holds"* ]]
  [ ! -e "$TEST_TMPDIR/pages" ]                            # a peer hold pages NOBODY
}
