#!/usr/bin/env bats
# Tests for scripts/check-mktemp-traps.sh — fails on a `mktemp -d` in scripts/**
# that has no cleanup trap naming its variable and no `mktemp-ok:` reason
# (MUS-5645: 450 anonymous /tmp/tmp.* dirs on node-8).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
GUARD="$HYDRA_REPO/scripts/check-mktemp-traps.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/mktemp-trap-guard.XXXXXX")"
  mkdir -p "$TEST_TMPDIR/scripts"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

run_guard() { MKTEMP_GUARD_ROOT="$TEST_TMPDIR" run "$GUARD"; }

@test "repo scripts/** is clean" {
  run "$GUARD"
  [ "$status" -eq 0 ]
}

@test "bare untrapped mktemp -d fails" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\necho hi\n' > "$TEST_TMPDIR/scripts/leaky.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"leaky.sh:2"* ]]
}

@test "EXIT trap naming the variable passes" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'rm -rf "$work"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/ok.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "trap handler function that removes the variable passes" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\nbye() { rm -rf "$work"; }\ntrap bye EXIT\n' > "$TEST_TMPDIR/scripts/fn.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "rm without any trap fails" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\nrm -rf "$work"\n' > "$TEST_TMPDIR/scripts/norap.sh"
  run_guard
  [ "$status" -eq 1 ]
}

@test "mktemp-ok comment on the previous line passes" {
  printf '#!/bin/bash\n# mktemp-ok: persists for the next run\nwork="$(mktemp -d)"\n' > "$TEST_TMPDIR/scripts/persist.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "mktemp -d inside a comment is ignored" {
  printf '#!/bin/bash\n# uses mktemp -d (mode 700)\n' > "$TEST_TMPDIR/scripts/c.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "scripts/tests fixtures are out of scope" {
  mkdir -p "$TEST_TMPDIR/scripts/tests"
  printf 'TEST_TMPDIR="$(mktemp -d)"\n' > "$TEST_TMPDIR/scripts/tests/x.bats"
  run_guard
  [ "$status" -eq 0 ]
}

@test "trapped handler that does not remove the variable fails even with an inline rm" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ncleanup() { :; }\ntrap cleanup EXIT\nrm -rf "$work"\n' > "$TEST_TMPDIR/scripts/emptyhandler.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"emptyhandler.sh:2"* ]]
}

@test "multi-line trapped handler that removes the variable passes" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ncleanup() {\n  rm -rf "$work"\n}\ntrap cleanup EXIT\n' > "$TEST_TMPDIR/scripts/ml.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "direct trap that only mentions the variable without rm fails" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'echo "$work" >/dev/null'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/echotrap.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"echotrap.sh:2"* ]]
}

@test "direct trap on ERR only (never fires on success) fails" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'rm -rf "$work"'"'"' ERR\n' > "$TEST_TMPDIR/scripts/errtrap.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"errtrap.sh:2"* ]]
}

@test "handler trapped on ERR only fails" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ncleanup() { rm -rf "$work"; }\ntrap cleanup ERR\n' > "$TEST_TMPDIR/scripts/errfn.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"errfn.sh:2"* ]]
}

@test "ERR trap whose trailing comment mentions EXIT fails" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'rm -rf "$work"'"'"' ERR # EXIT\n' > "$TEST_TMPDIR/scripts/cmt.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"cmt.sh:2"* ]]
}

@test "trap in a different function does not cover a second allocation" {
  cat > "$TEST_TMPDIR/scripts/twofn.sh" <<'SH'
#!/bin/bash
a() {
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
}
b() {
  work="$(mktemp -d)"
  echo hi
}
SH
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"twofn.sh:7"* ]]
  [[ "$output" != *"twofn.sh:3"* ]]
}

@test "function-keyword form (no parens) scopes per function" {
  cat > "$TEST_TMPDIR/scripts/kw.sh" <<'SH'
#!/bin/bash
function a {
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
}
function b {
  work="$(mktemp -d)"
  echo hi
}
SH
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"kw.sh:7"* ]]
  [[ "$output" != *"kw.sh:3"* ]]
}

@test "Allman-style braces scope per function" {
  cat > "$TEST_TMPDIR/scripts/allman.sh" <<'SH'
#!/bin/bash
a()
{
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
}
b()
{
  work="$(mktemp -d)"
  echo hi
}
SH
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"allman.sh:9"* ]]
  [[ "$output" != *"allman.sh:4"* ]]
}

@test "function-keyword and Allman functions that trap their own dir pass" {
  cat > "$TEST_TMPDIR/scripts/okforms.sh" <<'SH'
#!/bin/bash
function a {
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
}
b()
{
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
}
SH
  run_guard
  [ "$status" -eq 0 ]
}

@test "a same-line mktemp-ok does not waive the next allocation" {
  cat > "$TEST_TMPDIR/scripts/adjacent.sh" <<'SH'
#!/bin/bash
a=$(mktemp -d)   # mktemp-ok: persists by design
b=$(mktemp -d)
SH
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"adjacent.sh:3"* ]]
  [[ "$output" != *"adjacent.sh:2"* ]]
}

@test "a comment-only mktemp-ok on the previous line still waives" {
  cat > "$TEST_TMPDIR/scripts/prevline.sh" <<'SH'
#!/bin/bash
# mktemp-ok: persists by design
a=$(mktemp -d)
SH
  run_guard
  [ "$status" -eq 0 ]
}

@test "a missing scripts directory fails closed instead of passing" {
  rm -rf "$TEST_TMPDIR/scripts"
  run_guard
  [ "$status" -ne 0 ]
  [[ "$output" == *"no scripts directory"* ]]
}

@test "an unreadable scripts tree fails closed instead of scanning nothing" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory modes"
  mkdir "$TEST_TMPDIR/scripts/sealed"
  cat > "$TEST_TMPDIR/scripts/sealed/leaky.sh" <<'SH'
#!/bin/bash
d=$(mktemp -d)
SH
  chmod 000 "$TEST_TMPDIR/scripts/sealed"
  run_guard
  chmod 755 "$TEST_TMPDIR/scripts/sealed"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot enumerate"* ]]
}

@test "a quoted '#' earlier on the line does not hide the allocation" {
  cat > "$TEST_TMPDIR/scripts/hashq.sh" <<'SH'
#!/bin/bash
printf "#"; work="$(mktemp -d)"
SH
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"hashq.sh:2"* ]]
}

@test "mktemp-ok inside a quoted string is not a waiver" {
  cat > "$TEST_TMPDIR/scripts/waiverq.sh" <<'SH'
#!/bin/bash
printf "mktemp-ok: diagnostic"; work="$(mktemp -d)"
SH
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"waiverq.sh:2"* ]]
}

@test "EXIT appearing only in the trap action does not count (ERR-only trap leaks)" {
  cat > "$TEST_TMPDIR/scripts/erraction.sh" <<'SH'
#!/bin/bash
work="$(mktemp -d)"; trap 'echo EXIT; rm -rf "$work"' ERR
SH
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"erraction.sh:2"* ]]
}

@test "a quoted trap action with a real EXIT signal list still passes" {
  cat > "$TEST_TMPDIR/scripts/okq.sh" <<'SH'
#!/bin/bash
work="$(mktemp -d)"; trap "rm -rf \"$work\"" ERR EXIT
SH
  # one effective EXIT trap per script: Bash keeps only the last
  cat > "$TEST_TMPDIR/scripts/okq2.sh" <<'SH'
#!/bin/bash
d2="$(mktemp -d)"; trap -- 'rm -rf "$d2"' INT EXIT
SH
  run_guard
  [ "$status" -eq 0 ]
}

@test "a quoted brace in one function does not merge it with the next function's trap" {
  cat > "$TEST_TMPDIR/scripts/bracefn.sh" <<'SH'
#!/bin/bash
a() { printf "{"; d="$(mktemp -d)"; }
b() { d="x"; trap 'rm -rf "$d"' EXIT; }
SH
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"bracefn.sh:2"* ]]
}

@test "rm and the variable in different commands of a trap action do not count" {
  cat > "$TEST_TMPDIR/scripts/splitact.sh" <<'SH'
#!/bin/bash
work="$(mktemp -d)"; trap 'rm -rf /tmp/other; echo "$work" >/dev/null' EXIT
SH
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"splitact.sh:2"* ]]
}

@test "rm and the variable in different commands of a handler function do not count" {
  cat > "$TEST_TMPDIR/scripts/splitfn.sh" <<'SH'
#!/bin/bash
work="$(mktemp -d)"
bye() { rm -rf /tmp/other; echo "$work" >/dev/null; }
trap bye EXIT
SH
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"splitfn.sh:2"* ]]
}

@test "a multi-command trap action whose rm targets the variable still passes" {
  cat > "$TEST_TMPDIR/scripts/multi.sh" <<'SH'
#!/bin/bash
work="$(mktemp -d)"; trap 'echo bye; rm -rf "$work" && true' EXIT
SH
  cat > "$TEST_TMPDIR/scripts/multi2.sh" <<'SH'
#!/bin/bash
d2="$(mktemp -d)"
bye() {
  if [ -d "$d2" ]; then rm -rf "$d2"; fi
}
trap bye EXIT
SH
  run_guard
  [ "$status" -eq 0 ]
}

@test "an unmatched brace inside a heredoc body does not merge function scopes" {
  cat > "$TEST_TMPDIR/scripts/heredocfn.sh" <<'SH'
#!/bin/bash
a() {
  cat <<EOT
{
EOT
  work="$(mktemp -d)"
}
b() {
  work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
}
SH
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"heredocfn.sh:6"* ]]
}

@test "a quoted-delimiter and tab-stripped heredoc with a brace is skipped too" {
  printf '#!/bin/bash\na() {\n\tcat <<-'"'"'EOT'"'"'\n\t{\n\tEOT\n  work="$(mktemp -d)"\n}\nb() {\n  work="$(mktemp -d)"; trap '"'"'rm -rf "$work"'"'"' EXIT\n}\n' > "$TEST_TMPDIR/scripts/heredoc2.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"heredoc2.sh:6"* ]]
}

@test "a backslash-continued mktemp -d with no trap is flagged at its first line" {
  printf '#!/bin/bash\nwork="$(mktemp \\\n  -d)"\necho "$work"\n' > "$TEST_TMPDIR/scripts/cont.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"cont.sh:2"* ]]
}

@test "a continued mktemp -d whose variable is trapped on EXIT still passes" {
  printf '#!/bin/bash\nwork="$(mktemp \\\n  -d)"\ntrap '"'"'rm -rf "$work"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/contok.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "a continued mktemp -d with a mktemp-ok waiver on the continuation line passes" {
  printf '#!/bin/bash\nwork="$(mktemp \\\n  -d)" # mktemp-ok: short-lived\n' > "$TEST_TMPDIR/scripts/contw.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "top-level allocation with only a RETURN trap fails (RETURN never fires on script exit)" {
  printf '#!/bin/bash\nwork=$(mktemp -d)\ntrap '"'"'rm -rf "$work"'"'"' RETURN\n' > "$TEST_TMPDIR/scripts/topret.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"topret.sh:2"* ]]
}

@test "top-level allocation with an EXIT trap passes" {
  printf '#!/bin/bash\nwork=$(mktemp -d)\ntrap '"'"'rm -rf "$work"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/topexit.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "EXIT trap that removes only a child of the allocation fails (parent dir leaks)" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'rm -rf "$work/child"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/child.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"child.sh:2"* ]]
}

@test "EXIT trap removing \${work} braced and quoted still passes" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'rm -rf -- "${work}"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/braced.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "a later non-cleaning EXIT trap replaces the cleanup trap and fails" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'rm -rf "$work"'"'"' EXIT\ntrap '"'"'echo done'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/replaced.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"replaced.sh:2"* ]]
}

@test "trap - EXIT after the cleanup trap clears it and fails" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'rm -rf "$work"'"'"' EXIT\ntrap - EXIT\n' > "$TEST_TMPDIR/scripts/cleared.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"cleared.sh:2"* ]]
}

@test "a cleanup trap installed last (after a non-cleaning one) passes" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'echo hi'"'"' EXIT\ntrap '"'"'rm -rf "$work"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/lastok.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "a printed trap string is not a trap and fails" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\necho "trap '"'"'rm -rf $work'"'"' EXIT"\n' > "$TEST_TMPDIR/scripts/printed.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"printed.sh:2"* ]]
}

@test "a trap after then/&& on the same line still counts" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\n[ -n "$work" ] && trap '"'"'rm -rf "$work"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/andtrap.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "rm inside a case arm of the EXIT handler counts (qa-review-clone.sh shape)" {
  cat > "$TEST_TMPDIR/scripts/casearm.sh" <<'SH'
#!/bin/bash
CLONE_DIR="$(mktemp -d "$ROOT/x-XXXXXX")" || exit 1
cleanup() {
  case "$CLONE_DIR" in
    "$ROOT"/*-review-??????) rm -rf "$CLONE_DIR" ;;
  esac
}
trap cleanup EXIT
SH
  run_guard
  [ "$status" -eq 0 ]
}

@test "a case arm that removes a different path does not count" {
  cat > "$TEST_TMPDIR/scripts/casearm-other.sh" <<'SH'
#!/bin/bash
CLONE_DIR="$(mktemp -d)"
cleanup() {
  case "$1" in
    *) rm -rf "$OTHER" ;;
  esac
}
trap cleanup EXIT
SH
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"casearm-other.sh:2"* ]]
}

@test "a printed 'foo) rm -rf' string in the trap action is not a case arm" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'echo "foo) rm -rf $work"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/printarm.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"printarm.sh:2"* ]]
}

@test "two allocations on one line: the second leaks and fails" {
  printf '#!/bin/bash\na="$(mktemp -d)"; b="$(mktemp -d)"\ntrap '"'"'rm -rf "$a"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/two.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"two.sh:2"* ]]
}

@test "two allocations on one line, both cleaned by the trap, pass" {
  printf '#!/bin/bash\na="$(mktemp -d)"; b="$(mktemp -d)"\ntrap '"'"'rm -rf "$a" "$b"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/two-ok.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "second allocation on a line with no assignment fails closed" {
  printf '#!/bin/bash\na="$(mktemp -d)"; cp x "$(mktemp -d)"\ntrap '"'"'rm -rf "$a"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/bare2.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"bare2.sh:2"* ]]
}

@test "a file mktemp assignment does not pay for a bare dir allocation on the same line" {
  printf '#!/bin/bash\na="$(mktemp -d)"; b="$(mktemp)"; cp x "$(mktemp -d)"\ntrap '"'"'rm -rf "$a" "$b"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/filebare.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"filebare.sh:2"* ]]
}

@test "the same variable assigned twice on one line leaks the first dir" {
  printf '#!/bin/bash\na="$(mktemp -d)"; a="$(mktemp -d)"\ntrap '"'"'rm -rf "$a"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/dupvar.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"dupvar.sh:2"* ]]
}

@test "a dir allocation plus a file mktemp on one line, dir cleaned, passes" {
  printf '#!/bin/bash\na="$(mktemp -d)"; b="$(mktemp)"\ntrap '"'"'rm -rf "$a"; rm -f "$b"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/filedir-ok.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "a second EXIT trap on the same line replaces the cleanup and fails" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'rm -rf "$work"'"'"' EXIT; trap '"'"':'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/oneline-replace.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"oneline-replace.sh:2"* ]]
}

@test "trap - EXIT on the same line as the cleanup trap fails" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'rm -rf "$work"'"'"' EXIT; trap - EXIT\n' > "$TEST_TMPDIR/scripts/oneline-reset.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"oneline-reset.sh:2"* ]]
}

@test "a cleanup trap after a non-EXIT trap on the same line passes" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'echo int'"'"' INT; trap '"'"'rm -rf "$work"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/oneline-ok.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "a cleanup trap whose action prints a later trap command still passes" {
  printf '#!/bin/bash\nwork="$(mktemp -d)"\ntrap '"'"'rm -rf "$work"; echo "x; trap : EXIT"'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/oneline-printed.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "a later top-level EXIT trap replaces a function's EXIT cleanup and fails" {
  printf '#!/bin/bash\nf() {\n  work="$(mktemp -d)"\n  trap '"'"'rm -rf "$work"'"'"' EXIT\n}\nf\ntrap '"'"':'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/fn-replaced.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"fn-replaced.sh:3"* ]]
}

@test "a later top-level trap - EXIT also replaces a function's EXIT cleanup" {
  printf '#!/bin/bash\nf() {\n  work="$(mktemp -d)"\n  trap '"'"'rm -rf "$work"'"'"' EXIT\n}\nf\ntrap - EXIT\n' > "$TEST_TMPDIR/scripts/fn-reset.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"fn-reset.sh:3"* ]]
}

@test "a later top-level EXIT trap that still removes the dir passes" {
  printf '#!/bin/bash\nf() {\n  work="$(mktemp -d)"\n  trap '"'"'rm -rf "$work"'"'"' EXIT\n}\nf\ntrap '"'"'rm -rf "$work"; echo bye'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/fn-kept.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "a function RETURN cleanup is not replaced by a later top-level EXIT trap" {
  printf '#!/bin/bash\nf() {\n  local work\n  work="$(mktemp -d)"\n  trap '"'"'rm -rf "$work"'"'"' RETURN\n}\nf\ntrap '"'"':'"'"' EXIT\n' > "$TEST_TMPDIR/scripts/fn-return.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "a function called after a top-level alloc replaces its EXIT cleanup and fails" {
  printf '#!/bin/bash\nwork=$(mktemp -d)\ntrap '"'"'rm -rf "$work"'"'"' EXIT\ng() { trap : EXIT; }\ng\n' > "$TEST_TMPDIR/scripts/top-fn-replace.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"top-fn-replace.sh:2"* ]]
}

@test "a function that clears EXIT (trap - EXIT) after a top-level alloc fails" {
  printf '#!/bin/bash\nwork=$(mktemp -d)\ntrap '"'"'rm -rf "$work"'"'"' EXIT\ng() {\n  trap - EXIT\n}\ng\n' > "$TEST_TMPDIR/scripts/top-fn-clear.sh"
  run_guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"top-fn-clear.sh:2"* ]]
}

@test "a function whose EXIT trap still removes the top-level dir passes" {
  printf '#!/bin/bash\nwork=$(mktemp -d)\ntrap '"'"'rm -rf "$work"'"'"' EXIT\ng() { trap '"'"'rm -rf "$work"; echo bye'"'"' EXIT; }\ng\n' > "$TEST_TMPDIR/scripts/top-fn-keep.sh"
  run_guard
  [ "$status" -eq 0 ]
}

@test "a function with only a RETURN trap does not disturb the top-level EXIT cleanup" {
  printf '#!/bin/bash\nwork=$(mktemp -d)\ntrap '"'"'rm -rf "$work"'"'"' EXIT\ng() { trap : RETURN; }\ng\n' > "$TEST_TMPDIR/scripts/top-fn-return.sh"
  run_guard
  [ "$status" -eq 0 ]
}
