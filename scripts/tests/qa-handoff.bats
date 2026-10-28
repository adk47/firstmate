#!/usr/bin/env bats
# Unit tests for scripts/lib/qa-handoff.sh — the transport the QA hand-off rides on.
#
# The publisher/reader/guard suites exercise this library end-to-end, but three of
# its contracts are only visible HERE, and one of them shipped a publisher that
# failed on every real CI run while the whole suite passed:
#   1. QA_HANDOFF_GH is the gh INVOCATION PREFIX, not just the binary. The guard
#      passes `qa-gh.sh --repo <o/r>` (the shim consumes --repo to scope its
#      token) and `gh api` REJECTS that flag — so the prefix the caller installs
#      is the thing under test, not the binary.
#   2. A payload that cannot be decoded is "no hand-off", never a partial parse
#      and never a throw (every consumer is fail-closed on absence).
#   3. Encoding is deterministic (gzip -n): identical reports must produce an
#      identical body, so a re-publish is a no-op PATCH rather than churn.
#
# Never touches the network: the gh binary is a stub.

bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
LIB="$HYDRA_REPO/scripts/lib/qa-handoff.sh"

HEAD_OID="0123456789abcdef0123456789abcdef01234567"
PRIOR_OID="2222222222222222222222222222222222222222"
DIGEST="$(printf 'd%.0s' {1..64})"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  STUBBIN="$TEST_TMPDIR/bin"
  mkdir -p "$STUBBIN"
  cat >"$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${STUB_LOG:-/dev/null}"
# Model real gh exactly: `gh api` has no --repo flag. A stub that tolerated it
# is what hid the publisher bug this suite exists to pin.
if [ "${1:-}" = "--repo" ] && [ "${3:-}" = "api" ]; then
  echo "unknown flag: --repo" >&2; exit 1
fi
case "${1:-}" in
  api) shift; case "$*" in
         *"/comments?per_page=100"*) printf '%s' "${STUB_COMMENTS:-[]}" ;;
         *) echo "unexpected api: $*" >&2; exit 9 ;;
       esac ;;
  *) echo "unexpected gh: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$STUBBIN/gh"
  export STUB_LOG="$TEST_TMPDIR/calls"
  : >"$STUB_LOG"
  # The library's gh invocation prefix, defaulted HERE so no case in this file can
  # silently reach the real `gh` (one did: it read a live PR and returned nothing,
  # which looked like a broken selector). Tests that need a shim prefix override it.
  # shellcheck disable=SC2034  # consumed by scripts/lib/qa-handoff.sh
  QA_HANDOFF_GH=("$STUBBIN/gh")
}

teardown() { rm -rf "$TEST_TMPDIR"; }

report() {  # <head> [status] [digest]
  jq -nc --arg h "$1" --arg s "${2:-CLEAN}" --arg d "${3:-}" \
    '{repo: "Muso-AI/hydra", pr: 77, head_sha: $h, status: $s}
     + (if $d == "" then {} else {warn_digest: $d} end)'
}

comment() {  # <reports-json> <head> [login] [id] [created]
  local reports="$1" head="$2" login="${3:-github-actions[bot]}" id="${4:-1}"
  local created="${5:-2026-10-27T00:00:00Z}" payload b64
  payload="$(jq -cn --arg head "$head" --argjson reports "$reports" '
    {version: 1, repo: "Muso-AI/hydra", pr: 77, head_sha: $head,
     generated_at: "2026-10-27T00:00:00Z", reports: $reports, missing: []}')"
  b64="$(printf '%s' "$payload" | gzip -9 -n | base64 | tr -d '\n')"
  jq -nc --arg b "<!-- muso-qa-handoff v1 payload=$b64 -->" --arg l "$login" \
    --argjson i "$id" --arg c "$created" \
    '{id: $i, created_at: $c, user: {login: $l}, body: $b}'
}

# ── the invocation-prefix contract (the bug CI caught) ────────────────────

@test "the prefix the caller installs is what reaches gh — plain gh adds no --repo" {
  . "$LIB"
  STUB_COMMENTS='[]'
  QUA_HANDOFF=1
  QA_HANDOFF_GH=("$STUBBIN/gh")
  STUB_LOG="$STUB_LOG" qa_handoff_comments Muso-AI/hydra 77 >/dev/null
  run cat "$STUB_LOG"
  [ "$status" -eq 0 ]
  grep -qE '^api --paginate repos/Muso-AI/hydra/issues/77/comments' "$STUB_LOG"
  ! grep -q -- '--repo' "$STUB_LOG"
}

@test "the prefix the caller installs is what reaches gh — a shim prefix keeps its flags" {
  . "$LIB"
  # Stand in for scripts/qa-gh.sh, which CONSUMES --repo before exec'ing gh.
  cat >"$STUBBIN/shim" <<SHIM
#!/usr/bin/env bash
[ "\${1:-}" = "--repo" ] && shift 2
exec "$STUBBIN/gh" "\$@"
SHIM
  chmod +x "$STUBBIN/shim"
  STUB_COMMENTS='[]'
  QA_HANDOFF_GH=("$STUBBIN/shim" --repo "Muso-AI/hydra")
  qa_handoff_comments Muso-AI/hydra 77 >/dev/null
  grep -qE '^api --paginate repos/Muso-AI/hydra/issues/77/comments' "$STUB_LOG"
  ! grep -q -- '--repo' "$STUB_LOG"
}

@test "a prefix that passes --repo straight to gh fails closed (empty, no crash)" {
  . "$LIB"
  # The exact regression: gh api rejects --repo, so the fetch must yield nothing
  # rather than propagate an error into a `set -e` approval run.
  STUB_COMMENTS='[]'
  QA_HANDOFF_GH=("$STUBBIN/gh" --repo "Muso-AI/hydra")
  run qa_handoff_payloads Muso-AI/hydra 77
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── decoding / encoding ───────────────────────────────────────────────────

@test "decode refuses non-base64, non-gzip and non-JSON without output" {
  . "$LIB"
  for bad in 'not-base64!!' 'aGVsbG8=' "$(printf 'x' | gzip -9 -n | base64 | tr -d '\n')"; do
    run qa_handoff_decode "$bad"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}

@test "encode is deterministic, so a re-publish of identical reports is a no-op body" {
  . "$LIB"
  printf '%s' '{"a":1}' >"$TEST_TMPDIR/r.json"
  a="$(qa_handoff_encode "$TEST_TMPDIR/r.json")"
  b="$(qa_handoff_encode "$TEST_TMPDIR/r.json")"
  [ "$a" = "$b" ]
  [ "$(printf '%s' "$a" | base64 -d | gzip -dc)" = '{"a":1}' ]
}

# ── selection ─────────────────────────────────────────────────────────────

@test "payloads keep trusted hand-offs, drop untrusted and undecodable ones" {
  . "$LIB"
  QA_HANDOFF_GH=("$STUBBIN/gh")
  trusted="$(comment "$(jq -cn --argjson r "$(report "$HEAD_OID")" '{"rebase-integrity": $r}')" "$HEAD_OID" '' 1)"
  forged="$(comment "$(jq -cn --argjson r "$(report "$HEAD_OID")" '{"rebase-integrity": $r}')" "$HEAD_OID" 'nsollazzo' 2)"
  junk='{"id":3,"created_at":"2026-10-27T00:00:00Z","user":{"login":"github-actions[bot]"},"body":"<!-- muso-qa-handoff v1 payload=zzz -->"}'
  export STUB_COMMENTS="$(jq -cn --argjson a "$trusted" --argjson b "$forged" --argjson c "$junk" '[$a, $b, $c]')"
  run qa_handoff_payloads Muso-AI/hydra 77
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r 'select(.comment_id != "1") | .comment_id' | wc -l | tr -d ' ')" = "0" ]
  [ "$(printf '%s\n' "$output" | jq -r .comment_id)" = "1" ]
}

@test "the newest hand-off for a head wins when two exist" {
  . "$LIB"
  QA_HANDOFF_GH=("$STUBBIN/gh")
  old="$(comment "$(jq -cn --argjson r "$(report "$HEAD_OID" WARN "$DIGEST")" '{"rebase-integrity": $r}')" "$HEAD_OID" '' 1 2026-10-27T00:00:00Z)"
  new="$(comment "$(jq -cn --argjson r "$(report "$HEAD_OID" CLEAN)" '{"rebase-integrity": $r}')" "$HEAD_OID" '' 2 2026-10-27T01:00:00Z)"
  export STUB_COMMENTS="$(jq -cn --argjson a "$old" --argjson b "$new" '[$a, $b]')"
  all="$(qa_handoff_payloads Muso-AI/hydra 77)"
  [ "$(qa_handoff_report "$all" Muso-AI/hydra 77 rebase-integrity "$HEAD_OID" | jq -r .status)" = "CLEAN" ]
  # plural: EVERY same-head id, oldest first (the publisher deletes them all
  # before posting, so a failed re-publish can never leave stale evidence)
  [ "$(qa_handoff_comment_ids "$all" Muso-AI/hydra 77 "$HEAD_OID" | tr '\n' ' ')" = "1 2 " ]
}

@test "prior() lists OTHER heads only, and never a head with no report of that kind" {
  . "$LIB"
  prior_ok="$(comment "$(jq -cn --argjson r "$(report "$PRIOR_OID" WARN "$DIGEST")" '{"rebase-integrity": $r}')" "$PRIOR_OID" '' 1)"
  prior_br_only="$(comment "$(jq -cn --argjson r "$(report "3333333333333333333333333333333333333333")" '{"blast-radius": $r}')" "3333333333333333333333333333333333333333" '' 2)"
  current="$(comment "$(jq -cn --argjson r "$(report "$HEAD_OID")" '{"rebase-integrity": $r}')" "$HEAD_OID" '' 3)"
  export STUB_COMMENTS="$(jq -cn --argjson a "$prior_ok" --argjson b "$prior_br_only" --argjson c "$current" '[$a, $b, $c]')"
  all="$(qa_handoff_payloads Muso-AI/hydra 77)"
  # Call the REAL selector (it is pure: no gh involved), so a change in its
  # filter is caught here rather than re-implemented in the test.
  out="$(qa_handoff_prior "$all" Muso-AI/hydra 77 rebase-integrity "$HEAD_OID" | jq -r .head)"
  [ "$out" = "$PRIOR_OID" ]
  # ...and it must carry the report, not just the sha
  [ "$(qa_handoff_prior "$all" Muso-AI/hydra 77 rebase-integrity "$HEAD_OID" | jq -r .report.status)" = "WARN" ]
}

# ── the directory resolver ────────────────────────────────────────────────

@test "root(): QA_HANDOFF_ROOT wins and its subdirs are created" {
  . "$LIB"
  QA_HANDOFF_ROOT="$TEST_TMPDIR/pinned"
  [ "$(qa_handoff_root)" = "$TEST_TMPDIR/pinned" ]
  [ -d "$TEST_TMPDIR/pinned/rebase-integrity" ]
  [ -d "$TEST_TMPDIR/pinned/blast-radius" ]
}

# ── stale on-disk reports must not be republished ─────────────────────────

@test "clear_report removes THIS head's report only (a stale one must not survive a rerun)" {
  . "$LIB"
  root="$TEST_TMPDIR/state"
  mkdir -p "$root/rebase-integrity" "$root/blast-radius"
  mine="$root/rebase-integrity/Muso-AI__hydra-pr-77-${HEAD_OID}.json"
  other_head="$root/rebase-integrity/Muso-AI__hydra-pr-77-${PRIOR_OID}.json"
  other_pr="$root/rebase-integrity/Muso-AI__hydra-pr-78-${HEAD_OID}.json"
  other_kind="$root/blast-radius/Muso-AI__hydra-pr-77-${HEAD_OID}.json"
  printf '{"status":"CLEAN"}' | tee "$mine" "$other_head" "$other_pr" "$other_kind" >/dev/null
  qa_handoff_clear_report "$root" rebase-integrity Muso-AI/hydra 77 "$HEAD_OID"
  [ ! -e "$mine" ]
  # everything that is not this (kind, pr, head) triple stays
  [ -e "$other_head" ] && [ -e "$other_pr" ] && [ -e "$other_kind" ]
}

@test "clear_report is a no-op on a missing file and refuses a path-shaped argument" {
  . "$LIB"
  run qa_handoff_clear_report "$TEST_TMPDIR/state" rebase-integrity Muso-AI/hydra 77 "$HEAD_OID"
  [ "$status" -eq 0 ]
  # A non-hex "head" would make rm address something else entirely: refuse.
  run qa_handoff_clear_report "$TEST_TMPDIR/state" rebase-integrity Muso-AI/hydra 77 '../../etc/passwd'
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/state/rebase-integrity" ]
}

@test "the workflow clears each head's report BEFORE it runs the analyzer" {
  command -v python3 >/dev/null || skip "python3 unavailable"
  python3 - "$HYDRA_REPO" <<'PYEOF'
import sys, yaml
wf = yaml.safe_load(open(f"{sys.argv[1]}/.github/workflows/pr-validate.yml"))
for frag, env in (("check-rebase-integrity.sh", "RI_STATE_DIR"),
                  ("check-blast-radius.sh", "BR_STATE_DIR")):
    steps = [s for j in wf["jobs"].values() for s in j["steps"]
             if frag in (s.get("run") or "")]
    assert len(steps) == 1, f"expected one {frag} step, got {len(steps)}"
    body = steps[0]["run"]
    assert "qa_handoff_clear_report" in body, f"{frag} must clear the stale report first"
    assert body.index("qa_handoff_clear_report") < body.index(env), (
        f"{frag}: the clear must run BEFORE the analyzer, or a killed analyzer's "
        "predecessor report is still on disk when the publisher reads it")
PYEOF
}

@test "clear_report FAILS when the stale report cannot be removed (immutable/root-owned)" {
  . "$LIB"
  root="$TEST_TMPDIR/state"
  mkdir -p "$root/rebase-integrity"
  f="$root/rebase-integrity/Muso-AI__hydra-pr-77-${HEAD_OID}.json"
  printf '{"status":"CLEAN"}' >"$f"
  chmod 500 "$root/rebase-integrity"     # no write permission => unlink fails
  run qa_handoff_clear_report "$root" rebase-integrity Muso-AI/hydra 77 "$HEAD_OID"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'could not remove the stale'
  [ -e "$f" ]                            # still there, hence the refusal
  chmod 700 "$root/rebase-integrity"     # let teardown clean up
}

@test "a MALFORMED comment response is an unreadable list, not an empty one" {
  . "$LIB"
  # A 200 with a non-array body (an error object, a truncated page) must not read
  # as "there are no hand-offs" — that is how a stale CLEAN survives a rerun.
  export STUB_COMMENTS='{"message":"Bad gateway"}'
  # NOT in a command substitution: the rc lives in a global, and a subshell would
  # discard it (the publisher calls it the same way, for the same reason).
  qa_handoff_payloads Muso-AI/hydra 77 >"$TEST_TMPDIR/out" 2>/dev/null || true
  [ ! -s "$TEST_TMPDIR/out" ]
  [ "${QA_HANDOFF_READ_RC}" = "2" ]
}

@test "a readable empty list is a SUCCESSFUL read (no hand-offs is not an error)" {
  . "$LIB"
  export STUB_COMMENTS='[]'
  qa_handoff_payloads Muso-AI/hydra 77 >"$TEST_TMPDIR/out" 2>/dev/null || true
  [ ! -s "$TEST_TMPDIR/out" ]
  [ "${QA_HANDOFF_READ_RC}" = "0" ]
}

@test "the workflow fails the analyzer step when the stale-report clear fails" {
  command -v python3 >/dev/null || skip "python3 unavailable"
  python3 - "$HYDRA_REPO" <<'PYEOF'
import sys, yaml
wf = yaml.safe_load(open(f"{sys.argv[1]}/.github/workflows/pr-validate.yml"))
for frag in ("check-rebase-integrity.sh", "check-blast-radius.sh"):
    body = [s["run"] for j in wf["jobs"].values() for s in j["steps"]
            if frag in (s.get("run") or "")][0]
    clear = body.split("qa_handoff_clear_report", 1)[1]
    clear = clear.split(frag)[0]
    assert "||" in clear and "exit 1" in clear, (
        f"{frag}: a failed clear must FAIL the step, not warn — a surviving stale "
        "report is republished as this run's evidence")
PYEOF
}
