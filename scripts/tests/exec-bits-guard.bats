#!/usr/bin/env bats
# scripts/tests/exec-bits-guard.bats
#
# REGRESSION THIS SUITE EXISTS FOR (2026-09-22 08:00Z, hydra-daily-audit
# 203/EXEC): scripts/rollback.sh rsynced the last-known-good tree over
# /opt/hydra without repairing exec bits (deploy.sh:2318's `chmod +x
# "$DEPLOY_PATH"/scripts/*.sh "$DEPLOY_PATH"/scripts/*.py` has no rollback.sh
# equivalent), and scripts/hydra-daily-audit.py was committed 100644 — so it
# landed non-executable and hydra-daily-audit.service died 203/EXEC. The
# 08:29Z forward deploy re-fixed it only by accident (its own chmod +x line).
#
# This guard makes the CLASS of bug (a script a systemd unit or cron.d entry
# execs BY PATH, committed without the +x bit) fail CI instead of waiting for
# the next rollback to rediscover it. It does not hardcode the script list —
# scripts/lib/discover-exec-by-path-scripts.sh computes it from the live
# ExecStart=/cron.d generators in scripts/install-aux-units.sh +
# scripts/aux-units/*.service|*.path, so a newly added direct-exec unit is
# covered automatically.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DISCOVER="$HYDRA_REPO/scripts/lib/discover-exec-by-path-scripts.sh"

setup() {
  [ -x "$DISCOVER" ] || fail "discover-exec-by-path-scripts.sh missing or not executable at $DISCOVER"
  # shellcheck source=../lib/discover-exec-by-path-scripts.sh
  source "$DISCOVER"
}

@test "discovery finds at least the known ExecStart-by-path scripts" {
  local targets
  targets="$(discover_exec_by_path_scripts "$HYDRA_REPO")"
  [ -n "$targets" ]
  # Spot-check a few unrelated units/cron entries so a discovery regression
  # (e.g. a parser change that starts matching nothing) is caught even if the
  # mode-loop test below happens to pass on an empty list.
  echo "$targets" | grep -qx "scripts/hydra-daily-audit.py"
  echo "$targets" | grep -qx "scripts/openclaw-watchdog.sh"
  echo "$targets" | grep -qx "scripts/qa-review-reconcile.sh"
  # install-aux-units.sh:2452 -- ExecStart=/usr/bin/bash -lc '... exec
  # $HYDRA_ROOT/scripts/company-finder/refresh-dedupe-cache.sh': the
  # interpreter (`bash -lc`) is only opening a login shell; that shell's
  # `exec` then replaces itself with refresh-dedupe-cache.sh via execve(),
  # so it is by-path exec too, not interpreter-read. Discovery must catch
  # this "exec <script>" form inside an interpreter-prefixed ExecStart=
  # line, not just plain ExecStart=<script> lines (QA round 1 finding).
  echo "$targets" | grep -qx "scripts/company-finder/refresh-dedupe-cache.sh"
}

@test "discovery does NOT flag interpreter-invoked scripts (python3 foo.py needs no +x)" {
  local targets
  targets="$(discover_exec_by_path_scripts "$HYDRA_REPO")"
  # These are all `/usr/bin/python3 $HYDRA_ROOT/scripts/....py` in
  # install-aux-units.sh — the interpreter opens them for reading, so a
  # 100644 mode is correct and must never be flagged.
  #
  # NOTE: bare `! cmd | grep` is a Bats no-op (SC2314) — the `!` negates
  # the exit status of the *last* command in the pipeline as seen by the
  # shell, but Bats' `set -e`-adjacent error trap only inspects the
  # pipeline's own reported status via `run`, so an unwrapped `!` here
  # never fails the test even when the grep matches. Use `run !` instead.
  run ! grep -qx "scripts/caroline-behavior-digest.py" <<< "$targets"
  run ! grep -qx "scripts/cs-needs-human-digest.py" <<< "$targets"
  run ! grep -qx "scripts/close-resolved-conversations.py" <<< "$targets"
}

@test "discovery treats /usr/bin/env as a launcher, not an interpreter (env NAME=VALUE script.sh is by-path exec)" {
  # QA round-2 finding on this PR: `env` was in the same is_interpreter()
  # case list as python3/bash, so a generated unit like
  #   ExecStart=/usr/bin/env MODE=prod $HYDRA_ROOT/scripts/direct-via-env.sh
  # was skipped entirely -- env execve()s the script directly (after its
  # own NAME=VALUE assignments), so it needs +x same as a plain
  # ExecStart=<script> target, and a 100644 script in this shape would
  # pass this guard and then fail at runtime with 203/EXEC.
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts/aux-units"
  echo 'ExecStart=/usr/bin/env MODE=prod $HYDRA_ROOT/scripts/direct-via-env.sh' \
    > "$tmp/scripts/install-aux-units.sh"

  local targets
  targets="$(discover_exec_by_path_scripts "$tmp")"
  echo "$targets" | grep -qx "scripts/direct-via-env.sh"
  rm -rf "$tmp"
}

@test "discovery does NOT flag /usr/bin/env <interpreter> script (env bash foo.sh reads, not execs, the script)" {
  # The other half of the env fix: when env's own target is itself an
  # interpreter, that interpreter reads the script -- same as a plain
  # `bash foo.sh` ExecStart= line -- so the script must NOT be flagged.
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts/aux-units"
  echo 'ExecStart=/usr/bin/env bash $HYDRA_ROOT/scripts/via-env-bash.sh' \
    > "$tmp/scripts/install-aux-units.sh"

  local targets
  targets="$(discover_exec_by_path_scripts "$tmp")"
  run ! grep -qx "scripts/via-env-bash.sh" <<< "$targets"
  rm -rf "$tmp"
}

@test "discovery skips env options that take an operand (env -C DIR script.sh is by-path exec)" {
  # QA round-3 finding: the env walk assumed every option is operand-free, so
  # `env -C /opt/hydra script.sh` picked /opt/hydra as the command and never
  # discovered the script it execve()s. Covers -C/--chdir and -u/--unset.
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts/aux-units"
  printf '%s\n' \
    'ExecStart=/usr/bin/env -C /opt/hydra $HYDRA_ROOT/scripts/via-env-chdir.sh' \
    'ExecStart=/usr/bin/env --unset HOME MODE=prod $HYDRA_ROOT/scripts/via-env-unset.sh' \
    > "$tmp/scripts/install-aux-units.sh"

  local targets
  targets="$(discover_exec_by_path_scripts "$tmp")"
  echo "$targets" | grep -qx "scripts/via-env-chdir.sh"
  echo "$targets" | grep -qx "scripts/via-env-unset.sh"
  rm -rf "$tmp"
}

@test "discovery fails closed on env -S, whose re-split command it cannot follow" {
  # Guessing a command out of a -S string could skip a direct-exec target;
  # a non-zero exit makes the guard go red instead of passing silently.
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts/aux-units"
  echo "ExecStart=/usr/bin/env -S 'MODE=prod \$HYDRA_ROOT/scripts/via-env-split.sh'" \
    > "$tmp/scripts/install-aux-units.sh"

  run discover_exec_by_path_scripts "$tmp"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported env form"* ]]
  rm -rf "$tmp"
}

@test "discovery follows quoted targets in every form (exec \"\$HYDRA_ROOT/...\", \${HYDRA_ROOT}, quoted ExecStart)" {
  # QA round-4 finding: the exec regex excluded quote characters, so the
  # common `exec "$HYDRA_ROOT/scripts/foo.sh"` produced no target. Quoting is
  # stripped by ONE normalizer shared by the exec, direct and cron sites.
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts/aux-units"
  cat > "$tmp/scripts/install-aux-units.sh" <<'UNITS'
ExecStart=/usr/bin/bash -lc 'set -a; exec "$HYDRA_ROOT/scripts/q-double.sh"'
ExecStart=/usr/bin/bash -lc "exec '${HYDRA_ROOT}/scripts/q-braced.sh'"
ExecStart=/usr/bin/bash -lc 'exec "/opt/hydra/scripts/q-semicolon.py";'
ExecStart="$HYDRA_ROOT/scripts/q-direct.sh"
UNITS

  local targets
  targets="$(discover_exec_by_path_scripts "$tmp")"
  local want
  for want in q-double.sh q-braced.sh q-semicolon.py q-direct.sh; do
    echo "$targets" | grep -qx "scripts/$want"
  done
  rm -rf "$tmp"
}

@test "discovery fails closed on an option-led exec it cannot parse (exec -a NAME path)" {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts/aux-units"
  echo "ExecStart=/usr/bin/bash -lc 'exec -a worker \$HYDRA_ROOT/scripts/q-argv0.sh'" \
    > "$tmp/scripts/install-aux-units.sh"

  run discover_exec_by_path_scripts "$tmp"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported exec form"* ]]
  rm -rf "$tmp"
}

@test "discovery strips systemd executable prefixes (-, @, :, +, !, !!) before classifying" {
  # QA round-5 finding: `ExecStart=-$HYDRA_ROOT/scripts/x.sh` kept the `-` in
  # the token, so nothing was discovered and the guard passed a 100644 script.
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts/aux-units"
  cat > "$tmp/scripts/install-aux-units.sh" <<'UNITS'
ExecStart=-$HYDRA_ROOT/scripts/p-dash.sh
ExecStart=@$HYDRA_ROOT/scripts/p-at.sh argv0-name
ExecStartPre=+$HYDRA_ROOT/scripts/p-plus.sh
ExecStart=!!$HYDRA_ROOT/scripts/p-bangbang.sh
ExecStart=-:/opt/hydra/scripts/p-combo.py
ExecStart=-/usr/bin/bash -lc 'exec "$HYDRA_ROOT/scripts/p-interp.sh"'
UNITS

  local targets want
  targets="$(discover_exec_by_path_scripts "$tmp")"
  for want in p-dash.sh p-at.sh p-plus.sh p-bangbang.sh p-combo.py p-interp.sh; do
    echo "$targets" | grep -qx "scripts/$want"
  done
  rm -rf "$tmp"
}

@test "discovery fails closed on a prefix-only ExecStart token" {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts/aux-units"
  echo 'ExecStart=-@ $HYDRA_ROOT/scripts/p-split.sh' > "$tmp/scripts/install-aux-units.sh"

  run discover_exec_by_path_scripts "$tmp"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported ExecStart form"* ]]
  rm -rf "$tmp"
}

@test "discovery inspects every command in a ;-separated ExecStart (Type=oneshot)" {
  # QA round-6 finding: `ExecStart=/usr/bin/true ; $HYDRA_ROOT/scripts/x.sh`
  # classified only the first command. A `;` inside a quoted -lc string and an
  # escaped `\;` argument are NOT separators.
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts/aux-units"
  cat > "$tmp/scripts/install-aux-units.sh" <<'UNITS'
ExecStart=/usr/bin/true ; $HYDRA_ROOT/scripts/s-second.sh
ExecStart=-$HYDRA_ROOT/scripts/s-first.sh ; /usr/bin/bash -lc 'a ; exec "$HYDRA_ROOT/scripts/s-third.sh"'
ExecStart=/usr/bin/find /x -exec /bin/echo {} \; ; $HYDRA_ROOT/scripts/s-after-escaped.sh
ExecStart=/usr/bin/python3 $HYDRA_ROOT/scripts/s-read-only.py ; /usr/bin/true
UNITS

  local targets want
  targets="$(discover_exec_by_path_scripts "$tmp")"
  for want in s-second.sh s-first.sh s-third.sh s-after-escaped.sh; do
    echo "$targets" | grep -qx "scripts/$want"
  done
  # an interpreter-read script stays unflagged when it is not the first command
  run ! grep -qx "scripts/s-read-only.py" <<< "$targets"
  rm -rf "$tmp"
}

@test "discovery fails closed when exec hands off to env or an interpreter" {
  # QA round-7: `exec /usr/bin/env MODE=prod $HYDRA_ROOT/scripts/foo.sh` runs
  # foo.sh, but the exec token is env. Guessing past it is how every previous
  # round leaked, so a nested launcher is a hard failure, not a skip.
  local tmp form
  for form in \
    "ExecStart=/usr/bin/bash -lc 'exec /usr/bin/env MODE=prod \$HYDRA_ROOT/scripts/n-env.sh'" \
    "ExecStart=/usr/bin/bash -lc 'exec bash \$HYDRA_ROOT/scripts/n-bash.sh'"; do
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/scripts/aux-units"
    printf '%s\n' "$form" > "$tmp/scripts/install-aux-units.sh"
    run discover_exec_by_path_scripts "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported nested launcher after exec"* ]]
    rm -rf "$tmp"
  done
}

@test "discovery tokenizes on any horizontal whitespace (tabs, repeated spaces) in ExecStart and cron lines" {
  # QA round-7: a tab after an ExecStart target, or two spaces between cron
  # fields, is valid and used to return exit 0 with nothing discovered.
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/scripts/aux-units"
  printf 'ExecStart=$HYDRA_ROOT/scripts/w-tab.sh\t--flag\n' > "$tmp/scripts/install-aux-units.sh"
  printf 'ExecStart=/usr/bin/env\t\tMODE=prod   $HYDRA_ROOT/scripts/w-env-tabs.sh\n' >> "$tmp/scripts/install-aux-units.sh"
  printf '*/5  *  * *\t*  root  $HYDRA_ROOT/scripts/w-cron.sh\n' >> "$tmp/scripts/install-aux-units.sh"

  local targets want
  targets="$(discover_exec_by_path_scripts "$tmp")"
  for want in w-tab.sh w-env-tabs.sh w-cron.sh; do
    echo "$targets" | grep -qx "scripts/$want"
  done
  rm -rf "$tmp"
}

@test "every discovered ExecStart-by-path target is 100755 in the git index" {
  cd "$HYDRA_REPO"
  local targets not_exec=() t mode
  targets="$(discover_exec_by_path_scripts "$HYDRA_REPO")"
  [ -n "$targets" ] || fail "discovery returned nothing — parser likely broken, see the sibling test"

  while IFS= read -r t; do
    [ -n "$t" ] || continue
    mode="$(git ls-files -s -- "$t" | awk '{print $1}')"
    if [ -z "$mode" ]; then
      not_exec+=("$t (NOT TRACKED)")
    elif [ "$mode" != "100755" ]; then
      not_exec+=("$t ($mode)")
    fi
  done <<< "$targets"

  if [ "${#not_exec[@]}" -gt 0 ]; then
    printf 'ExecStart/cron.d targets missing the +x bit (100755) in the git index:\n' >&2
    printf '  %s\n' "${not_exec[@]}" >&2
    printf 'A script exec'"'"'d directly by systemd/cron (no interpreter in front of it)\n' >&2
    printf 'must be committed 100755, or a rollback/rsync lands it non-executable and the\n' >&2
    printf 'unit dies 203/EXEC (2026-09-22 hydra-daily-audit incident). Fix with:\n' >&2
    printf '  git update-index --chmod=+x <path>\n' >&2
    false
  fi
}
