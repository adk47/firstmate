#!/usr/bin/env bats
# Drift guard: every autonomic fleet-health watchdog MUST carry the maintenance
# flag guard — either source lib/maintenance-flag.sh and call maintenance_active
# (bash), or shell out to `hydra-maintenance is-active` (the one python watchdog) —
# UNLESS it is listed, with a reason, in
# scripts/tests/fixtures/maintenance-guard-exempt.txt.
#
# This makes it structurally impossible to add a new watchdog that silently fights
# a planned maintenance window (openclaw-watchdog restarting the fleet mid-archive,
# a pager firing for a fleet that is down on purpose): a *-watchdog.{sh,py} that is
# neither guarded nor exempt fails CI, so exempting one is a conscious, reviewed
# decision. Mirrors the enumerate-all/assert-each pattern of
# qa-clean-merge-scratch.bats. See scripts/hydra-maintenance.sh.
bats_require_minimum_version 1.5.0

setup() {
  HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPTS="$HYDRA_REPO/scripts"
  EXEMPT_FILE="$SCRIPTS/tests/fixtures/maintenance-guard-exempt.txt"
}

# The set that MUST carry the guard:
#   (1) every scripts/*-watchdog.{sh,py}  — the naming convention we defend; a new
#       *-watchdog file is exactly the omission this test exists to catch.
#   (2) an explicit tail of autonomic fleet scripts that restart/RPC the fleet but
#       are NOT named *watchdog* (codex keepalive/refresh, peer-labels) — a
#       regression lock so they can't quietly lose the guard.
# The exempt file (business/prod watchdogs) is subtracted by the tests below.
#
# Limits (documented, not silent): this catches the common case — a new
# *-watchdog.{sh,py}. A future fleet-health script named neither *-watchdog* nor in
# the tail below would evade it, so the tail MUST grow when you add such a script.
# has_guard() ignores comments and requires the structural source+invocation, so a
# comment-only mention can't fool it; that the guard runs BEFORE the acting code is
# covered by the behavioral suites (maintenance-flag / openclaw-watchdog-liveness /
# intercom-intake-watchdog).
guarded_candidates() {
  local f
  for f in "$SCRIPTS"/*-watchdog.sh "$SCRIPTS"/*-watchdog.py; do
    [ -e "$f" ] && basename "$f"
  done
  printf '%s\n' codex-keepalive.sh codex-token-refresh.sh provision-peer-labels.sh
}

exempt_set() {
  # First whitespace token of each non-comment, non-blank line.
  grep -vE '^[[:space:]]*(#|$)' "$EXEMPT_FILE" | awk '{print $1}'
}

is_exempt() { printf '%s\n' "${EXEMPT[@]}" | grep -qxF "$1"; }

# Prove a script carries a REAL guard, not merely the token in a comment (a plain
# `grep token` would pass an unguarded watchdog that just mentions it in prose —
# the drift gate's whole job is to prevent that). Strip full-line comments first,
# then require the STRUCTURAL guard on the remaining code, distinguishing the two
# implementations:
#   bash   -> a `source …/maintenance-flag.sh` AND a `maintenance_active` invocation
#   python -> the `is-active` shell-out to hydra-maintenance
has_guard() {
  local f="$1"
  case "$f" in
    *.py)
      # Structural (AST): require an actual subprocess.* CALL that carries the
      # literal "is-active" as an argument — coupled, so neither a comment/bare
      # string (print("is-active")) nor an UNRELATED subprocess call
      # (subprocess.run(["systemctl", ...]) for the action path) satisfies it. A
      # file-wide grep can't couple these, especially across our multi-line call.
      python3 - "$f" <<'PY'
import ast, sys
try:
    tree = ast.parse(open(sys.argv[1]).read())
except Exception:
    sys.exit(1)
SUBPROC = {"run", "call", "check_call", "check_output", "Popen"}
# Resolve `import subprocess [as X]` so the receiver check accepts real aliases
# but not an unrelated object with a same-named method (e.g. monitor.run(...)).
aliases = {"subprocess"}
for n in ast.walk(tree):
    if isinstance(n, ast.Import):
        for a in n.names:
            if a.name == "subprocess":
                aliases.add(a.asname or a.name)
def is_subprocess_call(c):
    f = c.func
    return (isinstance(f, ast.Attribute) and f.attr in SUBPROC
            and isinstance(f.value, ast.Name) and f.value.id in aliases)
def argv_has_isactive(c):
    # "is-active" must be in the FIRST POSITIONAL arg (the command/argv), not in an
    # unrelated keyword value.
    return bool(c.args) and any(
        isinstance(a, ast.Constant) and a.value == "is-active" for a in ast.walk(c.args[0]))
calls = (n for n in ast.walk(tree) if isinstance(n, ast.Call))
sys.exit(0 if any(is_subprocess_call(c) and argv_has_isactive(c) for c in calls) else 1)
PY
      ;;
    *)
      # Anchor to STATEMENT start (after leading whitespace only), so a trailing
      # comment — `echo ok # source …maintenance-flag.sh` / `# maintenance_active` —
      # can't satisfy either grep. The real guard is a `source …maintenance-flag.sh`
      # statement plus a `maintenance_active` invocation (bare or `if maintenance_active`).
      grep -qE '^[[:space:]]*source[[:space:]].*maintenance-flag\.sh' "$f" \
        && grep -qE '^[[:space:]]*(if[[:space:]]+)?maintenance_active([[:space:]]|;|$)' "$f"
      ;;
  esac
}

@test "every non-exempt fleet-health watchdog carries the maintenance guard" {
  mapfile -t CANDIDATES < <(guarded_candidates | sort -u)
  [ "${#CANDIDATES[@]}" -gt 0 ]     # sanity: enumeration is non-empty (no vacuous pass)
  mapfile -t EXEMPT < <(exempt_set | sort -u)

  local name path missing=()
  for name in "${CANDIDATES[@]}"; do
    is_exempt "$name" && continue
    path="$SCRIPTS/$name"
    if [ ! -f "$path" ]; then
      missing+=("$name (referenced but not found)")
    elif ! has_guard "$path"; then
      missing+=("$name (no maintenance guard)")
    fi
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'UNGUARDED watchdog(s) — add the maintenance guard or list in %s:\n' "$EXEMPT_FILE"
    printf '  %s\n' "${missing[@]}"
    false
  fi
}

@test "exempt list has no rot: every exempt entry names a real script" {
  mapfile -t EXEMPT < <(exempt_set | sort -u)
  [ "${#EXEMPT[@]}" -gt 0 ]
  local name missing=()
  for name in "${EXEMPT[@]}"; do
    [ -f "$SCRIPTS/$name" ] || missing+=("$name")
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'exempt entry with no matching script (stale — remove it):\n'
    printf '  %s\n' "${missing[@]}"
    false
  fi
}

@test "no script is BOTH exempt and guarded-by-source (contradictory signal)" {
  mapfile -t EXEMPT < <(exempt_set | sort -u)
  local name bad=()
  for name in "${EXEMPT[@]}"; do
    [ -f "$SCRIPTS/$name" ] || continue
    has_guard "$SCRIPTS/$name" && bad+=("$name")
  done
  if [ "${#bad[@]}" -ne 0 ]; then
    printf 'exempt but ALSO carries the guard — pick one (guard it, or drop from exempt):\n'
    printf '  %s\n' "${bad[@]}"
    false
  fi
}

@test "has_guard requires a real guard, not a comment/string that merely mentions the token" {
  local fake="$BATS_TEST_TMPDIR/fake-watchdog.sh"
  # (bash) full-line comment mentioning both tokens -> must NOT count
  printf '#!/bin/bash\n# TODO: wire maintenance_active and the is-active shell-out\necho hi\n' > "$fake"
  run has_guard "$fake"; [ "$status" -ne 0 ]
  # (bash) TRAILING comments carrying the tokens on executable lines -> must NOT count
  printf '#!/bin/bash\necho ok # source "$D/lib/maintenance-flag.sh"\necho ok # maintenance_active\n' > "$fake"
  run has_guard "$fake"; [ "$status" -ne 0 ]
  # (bash) a real guard: source statement + invocation at statement start -> counts
  printf '#!/bin/bash\nsource "$D/lib/maintenance-flag.sh"\nif maintenance_active; then exit 0; fi\n' > "$fake"
  run has_guard "$fake"; [ "$status" -eq 0 ]

  local fpy="$BATS_TEST_TMPDIR/fake-watchdog.py"
  # (python) is-active only in a comment -> must NOT count
  printf '#!/usr/bin/env python3\n# calls hydra-maintenance is-active somewhere, maybe\nprint(1)\n' > "$fpy"
  run has_guard "$fpy"; [ "$status" -ne 0 ]
  # (python) is-active in a bare string literal, no subprocess call -> must NOT count
  printf '#!/usr/bin/env python3\nprint("is-active")\n' > "$fpy"
  run has_guard "$fpy"; [ "$status" -ne 0 ]
  # (python) decoy string/comment PLUS an UNRELATED subprocess call (the action
  # path) -> must NOT count: the literal isn't an arg to that call
  printf '#!/usr/bin/env python3\nimport subprocess\n# TODO: call "is-active"\nsubprocess.run(["systemctl", "restart", "x"])\n' > "$fpy"
  run has_guard "$fpy"; [ "$status" -ne 0 ]
  # (python) a NON-subprocess receiver with a same-named method -> must NOT count
  printf '#!/usr/bin/env python3\nmonitor.run(["is-active"])\n' > "$fpy"
  run has_guard "$fpy"; [ "$status" -ne 0 ]
  # (python) is-active only in an unrelated KEYWORD, not the argv positional -> must NOT count
  printf '#!/usr/bin/env python3\nimport subprocess\nsubprocess.run(["systemctl","restart"], text="is-active")\n' > "$fpy"
  run has_guard "$fpy"; [ "$status" -ne 0 ]
  # (python) a real shell-out: is-active is in the argv positional -> counts
  printf '#!/usr/bin/env python3\nimport subprocess\nsubprocess.run(["bash", h, "is-active"])\n' > "$fpy"
  run has_guard "$fpy"; [ "$status" -eq 0 ]
  # ...via an alias, and across multiple lines (matches the real watchdog shape)
  printf '#!/usr/bin/env python3\nimport subprocess as sp\nsp.run(\n    ["bash", h, "is-active"],\n    timeout=10,\n)\n' > "$fpy"
  run has_guard "$fpy"; [ "$status" -eq 0 ]
}
