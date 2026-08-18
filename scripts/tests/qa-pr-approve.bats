#!/usr/bin/env bats
# Tests for scripts/qa-pr-approve.sh — the gated "approve-only" wrapper QA uses
# after a GO-verdict review. Every test PATH-shadows `gh` with a stub so the
# suite NEVER touches real GitHub (memory: bats must stub openclaw/gh — Clio's
# PR #245 fired 9 real Slack alerts from an unstubbed test).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-pr-approve.sh"

NICK="U0AL36NADEY"   # allowlisted requester (UNSCOPED)
AARON="U7RP6HKUZ"    # the other UNSCOPED approver
MARIIA="U03LP8YHLPK" # SCOPED: own azure-kirin PRs, Muso-AI/web-credits-next, base develop
SERHII="U03TYGJF1N3" # REMOVED from the allowlist 2026-08-13 — review-only now

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export QA_PR_APPROVE_LOG_DIR="$TEST_TMPDIR/api-logs/github"
  # Guard 8 state dir: left nonexistent by default = "no rebase-integrity
  # report" (external repo / pre-feature head), which must keep passing — every
  # pre-Guard-8 test in this file exercises exactly that path.
  export QA_REBASE_STATE_DIR="$TEST_TMPDIR/ri"
  export STUB_CALLS="$TEST_TMPDIR/gh-calls"
  : > "$STUB_CALLS"

  # Stub `gh`. Configurable via STUB_ME / STUB_AUTHOR / STUB_APPROVE_RC /
  # STUB_BAD_CHECKS / STUB_OPEN_BLOCKERS.
  #
  # Fixture-based jq coverage (Guard 6 / Guard 7):
  #   STUB_ROLLUP_JSON — if set, the stub extracts the script's actual --jq
  #     filter from its own args and runs it against this JSON via local jq,
  #     so the real filter string is exercised with no duplication/drift.
  #   STUB_THREADS_JSON — same idea for the graphql / Guard-7 path.
  # Fallback (STUB_ROLLUP_JSON/STUB_THREADS_JSON unset): echo the canned count,
  # keeping all existing canned-count tests unaffected.
  #
  # NOTE: production `gh` uses gojq; this stub runs local jq. The node-8 live
  # smoke covers the gojq path. Both should behave identically for the filters
  # used here (no gojq-specific extensions).
  #
  # NOTE — MODELLING AN ABSENT/NULL FIELD. `jq -nc --arg x "$V"` ALWAYS binds a
  # JSON STRING, so no value of an --arg-built stub can ever produce a JSON null.
  # That is why `STUB_AUTHOR=""` models "empty string", NOT "author: null", and
  # why the `// ""` guards in the script's shared author,baseRefName filter were
  # untested for a year: removing BOTH guards kept all 140 tests green. Use
  # STUB_AUTHOR_NULL=1 / STUB_BASE_NULL=1 (below) to emit a genuine null.
  #
  # AND the divergence that makes a naive null test assert the OPPOSITE of
  # production: this stub pipes through LOCAL `jq -r`, which prints the literal
  # 4-char string `null` for a null scalar, whereas real `gh --jq` prints an
  # EMPTY line. So a guardless filter yields author="null" here and author=""
  # under real gh. Both are wrong-and-dangerous in different ways ("null" sails
  # past `[ -n "$author" ]`), and the `// ""` guards make the two agree on "" —
  # which is exactly why the tests below assert the GUARDED behaviour (empty →
  # die 7 / fail-closed message) rather than asserting on the string "null".
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
# emit the argument that follows --jq in "$@"
_jqflt() { local p=""; for a in "$@"; do [ "$p" = "--jq" ] && { printf '%s' "$a"; return; }; p="$a"; done; }

sub="$1"; shift || true
case "$sub" in
  api)
    if [ "${1:-}" = "graphql" ]; then
      if [ -n "${STUB_THREADS_JSON:-}" ]; then
        _flt="$(_jqflt "$@")"
        if [ -n "$_flt" ]; then
          printf '%s' "$STUB_THREADS_JSON" | jq -r "$_flt"
        else
          # No --jq: emit the raw payload, exactly as real gh does. Guard 8 pipes
          # gh into a separate jq so it can pass the bot-login set via --argjson
          # (gh's own --jq takes no arguments).
          printf '%s' "$STUB_THREADS_JSON"
        fi
      else
        echo "${STUB_OPEN_BLOCKERS:-0}"                 # count of unresolved Critical/Important threads
      fi
    elif printf '%s\n' "$@" | grep -qE '^repos/[^/]+/[^/]+/pulls/[0-9]+/files\?per_page=100$'; then
      _args="$*"
      if printf '%s' "$_args" | grep -q -- '--paginate' \
        && printf '%s' "$_args" | grep -q -- '--slurp'; then
        echo "files-api-paginated-slurped" >> "$STUB_CALLS"
      fi
      _page1="${STUB_FILES_PAGE_1:-${STUB_FILES:-src/app.ts}}"
      _page2="${STUB_FILES_PAGE_2:-}"
      if [ -n "${STUB_FILES_JSON:-}" ]; then
        printf '%s' "$STUB_FILES_JSON"
      else
        jq -nc --arg p1 "$_page1" --arg p2 "$_page2" '
          ($p1 | split(" ") | map(select(length > 0) | {filename: ., status: "modified"})) as $a
          | ($p2 | split(" ") | map(select(length > 0) | {filename: ., status: "modified"})) as $b
          | if ($b | length) > 0 then [$a, $b] else [$a] end'
      fi
    else
      # No colon: an explicitly EMPTY STUB_ME must stay empty, so tests can model
      # `gh api user` 403ing under a GitHub App installation token. With `:-` an
      # empty value would silently fall back and the regression would go untested.
      echo "${STUB_ME-adk47}"                         # gh api user --jq .login
    fi ;;
  pr)
    action="$1"; shift || true
    case "$action" in
      view)
        if printf '%s ' "$@" | grep -q 'statusCheckRollup'; then
          # The stub serves DATA and lets the script do its own counting. It used
          # to echo a pre-counted number, which only worked while the count was
          # computed inside the gh --jq filter; Guard 6 now fetches the raw
          # rollup so it can exclude policy-listed advisory checks with a jq
          # --argjson (impossible through `gh --jq`). A stub that emulates the
          # implementation instead of the API silently stops testing it.
          if [ -n "${STUB_ROLLUP_JSON:-}" ]; then
            printf '%s' "$STUB_ROLLUP_JSON" | jq -r "$(_jqflt "$@")"
          else
            # Synthesize one passing check plus STUB_BAD_CHECKS failing ones.
            jq -rn --argjson n "${STUB_BAD_CHECKS:-0}" \
              '{statusCheckRollup:
                 ([{__typename:"CheckRun",name:"ci",conclusion:"SUCCESS"}]
                  + [range($n) | {__typename:"CheckRun",
                                  name:("failing-check-\(.)"),
                                  conclusion:"FAILURE"}])}' \
              | jq -r "$(_jqflt "$@")"
          fi
        elif printf '%s ' "$@" | grep -q 'headRefOid'; then
          echo "${STUB_HEAD_OID:-0123456789abcdef0123456789abcdef01234567}"  # Guard 8 report key
        elif printf '%s ' "$@" | grep -q -- 'changedFiles'; then
          _page1="${STUB_FILES_PAGE_1:-${STUB_FILES:-src/app.ts}}"
          _all="$_page1 ${STUB_FILES_PAGE_2:-}"
          set -- $_all
          echo "${STUB_CHANGED_COUNT:-$#}"
        elif printf '%s ' "$@" | grep -qE 'author|baseRefName'; then
          # Guard 3 + Guard 4b share ONE `--json author,baseRefName` call whose
          # --jq filter emits two lines. Serve the API SHAPE and run the
          # script's real filter through _jqflt, so the filter itself is
          # exercised rather than re-implemented here (same rationale as the
          # rollup arm). This arm must stay ABOVE nothing in particular, but it
          # must match BOTH field names: the joined args contain 'author', so a
          # separate baseRefName-only arm placed after it would be dead.
          #
          # `${STUB_BASE_REF-develop}` uses `-`, NOT `:-`: STUB_BASE_REF="" must
          # stay EMPTY so tests can model an unreadable base branch (Guard 4b
          # fails closed on it). Default is `develop` so the scoped happy path
          # needs no extra setup; unscoped requesters ignore the base entirely.
          # `${STUB_AUTHOR-nsollazzo}` likewise uses `-`: an explicitly EMPTY
          # STUB_AUTHOR models an author the API could not give us, which must
          # still die 7 now that the field shares a call with baseRefName.
          #
          # STUB_AUTHOR_NULL=1 / STUB_BASE_NULL=1 emit a GENUINE JSON null for
          # that field — the shape a deleted/ghost PR author really produces
          # ("author": null). --arg can never express this (see the NOTE in
          # setup()), so without these knobs the `// ""` guards are untestable.
          jq -nc --arg a "${STUB_AUTHOR-nsollazzo}" --arg b "${STUB_BASE_REF-develop}" \
            --argjson an "${STUB_AUTHOR_NULL:-0}" --argjson bn "${STUB_BASE_NULL:-0}" \
            '{author: (if $an == 1 then null else {login: $a} end),
              baseRefName: (if $bn == 1 then null else $b end)}' | jq -r "$(_jqflt "$@")"
        else
          echo "  reviewDecision=APPROVED  mergeStateStatus=CLEAN  state=OPEN"
        fi ;;
      review)
        echo "approve" >> "$STUB_CALLS"
        # prove the audit log already exists at approve time (log-before-write)
        [ -f "${QA_PR_APPROVE_LOG_DIR}/$(date -u +%F).jsonl" ] && echo "log-present-at-approve" >> "$STUB_CALLS"
        exit "${STUB_APPROVE_RC:-0}" ;;
    esac ;;
esac
STUB
  chmod +x "$STUBBIN/gh"
  export PATH="$STUBBIN:$PATH"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

logfile() { echo "$QA_PR_APPROVE_LOG_DIR/$(date -u +%F).jsonl"; }

# ---------------------------------------------------------------------------
# Existing canned-count tests (unchanged — stub fallback path)
# ---------------------------------------------------------------------------

@test "happy path: allowlisted requester, non-self author → approves once, logs first" {
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  # approved exactly once, never merged
  [ "$(grep -c '^approve$' "$STUB_CALLS")" -eq 1 ]
  # audit log written, with the expected shape
  grep -q '"action":"github_pr_approve"' "$(logfile)"
  grep -q '"target":"Muso-AI/core-backend#123"' "$(logfile)"
  # log existed BEFORE the approve call
  grep -q '^log-present-at-approve$' "$STUB_CALLS"
}

@test "self-approval blocked: author == gateway account → exit 4, never approves" {
  STUB_ME="adk47" STUB_AUTHOR="adk47" run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 4 ]
  [ ! -s "$STUB_CALLS" ] || ! grep -q '^approve$' "$STUB_CALLS"
}

@test "non-Muso-AI repo → exit 3, no approval, no log" {
  run "$SCRIPT" SomeOrg/secret 123 "$NICK"
  [ "$status" -eq 3 ]
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  [ ! -f "$(logfile)" ]
}

@test "requester not in allowlist → exit 5, no approval" {
  run "$SCRIPT" core-backend 123 "U999NOTALLOWED"
  [ "$status" -eq 5 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Scoped approval authority (2026-08-13, Nick-authorized)
#   Mariia (U03LP8YHLPK) may approve ONLY her own azure-kirin PRs in
#   Muso-AI/web-credits-next targeting base `develop`.
#   Serhii (U03TYGJF1N3) was REMOVED from the allowlist entirely.
#   Aaron / Nick stay unscoped.
# Every refusal below asserts the approve write never happened. `$STUB_CALLS`
# is created empty in setup(), so a plain grep is a real assertion.
# ---------------------------------------------------------------------------

@test "scoped: Mariia on web-credits-next, author azure-kirin, base develop → approves" {
  STUB_ME="adk47" STUB_AUTHOR="azure-kirin" STUB_BASE_REF="develop" \
    run "$SCRIPT" Muso-AI/web-credits-next 42 "$MARIIA"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^approve$' "$STUB_CALLS")" -eq 1 ]
  grep -q '"target":"Muso-AI/web-credits-next#42"' "$(logfile)"
  grep -q "\"requester\":\"$MARIIA\"" "$(logfile)"
}

@test "scoped: Mariia's own PR is NOT self-approval — Guard 3 compares author to \$me, not the requester" {
  # The whole point of the grant: she requests approval of a PR she authored.
  # Guard 3 must stay about the acting identity (adk47), not about her.
  STUB_ME="adk47" STUB_AUTHOR="azure-kirin" STUB_BASE_REF="develop" \
    run "$SCRIPT" Muso-AI/web-credits-next 43 "$MARIIA"
  [ "$status" -eq 0 ]
  if echo "$output" | grep -q 'self-approval'; then
    echo "Guard 3 fired on a scoped author's own PR — that conflates requester with acting identity" >&2; false
  fi
  [ "$(grep -c '^approve$' "$STUB_CALLS")" -eq 1 ]
}

@test "scoped: author login case is normalized — Azure-Kirin still approves" {
  STUB_ME="adk47" STUB_AUTHOR="Azure-Kirin" STUB_BASE_REF="develop" \
    run "$SCRIPT" Muso-AI/web-credits-next 44 "$MARIIA"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^approve$' "$STUB_CALLS")" -eq 1 ]
}

@test "scoped: Mariia on the right repo but base main → exit 5, no approval, no log" {
  STUB_ME="adk47" STUB_AUTHOR="azure-kirin" STUB_BASE_REF="main" \
    run "$SCRIPT" Muso-AI/web-credits-next 45 "$MARIIA"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'base branch must be develop'
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  [ ! -f "$(logfile)" ]
}

@test "scoped: Mariia on a DIFFERENT repo (octave-ui) → exit 5, no approval" {
  STUB_ME="adk47" STUB_AUTHOR="azure-kirin" STUB_BASE_REF="develop" \
    run "$SCRIPT" Muso-AI/octave-ui 46 "$MARIIA"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'repo must be Muso-AI/web-credits-next'
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  [ ! -f "$(logfile)" ]
}

@test "scoped: Mariia on web-credits-next/develop but SOMEONE ELSE authored it → exit 5" {
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BASE_REF="develop" \
    run "$SCRIPT" Muso-AI/web-credits-next 47 "$MARIIA"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'PR author must be azure-kirin'
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  [ ! -f "$(logfile)" ]
}

@test "scoped: FAIL CLOSED — unreadable base branch refuses (exit 5), never approves" {
  # STUB_BASE_REF="" models the API answering with a null/absent baseRefName.
  # An empty base is NOT evidence the scope is satisfied.
  STUB_ME="adk47" STUB_AUTHOR="azure-kirin" STUB_BASE_REF="" \
    run "$SCRIPT" Muso-AI/web-credits-next 48 "$MARIIA"
  [ "$status" -ne 0 ]
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'base branch could not be read'
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  [ ! -f "$(logfile)" ]
}

# ---------------------------------------------------------------------------
# Scope widened 2026-08-17: auth and ads-manager added, BOTH on base `main`
# while web-credits-next stays on `develop`. The per-repo base is the whole
# risk in this change — a copy-pasted `develop` would leave both new rows dead
# and the failure would be an exit 5 indistinguishable from "not allowlisted".
# So each new repo is pinned on BOTH sides: it approves on its own base, and it
# refuses on the other repo's base.
#
# NOTE these use `export` in the body rather than the `VAR=x run ...` prefix
# used above. The prefix form is not reliably delivered to the stub (it drops
# in roughly 1 run in 10 of the full suite) and it flakes TOWARD approval —
# the dangerous direction for a scope test, which would then pass while
# proving nothing.
# ---------------------------------------------------------------------------

@test "scoped: Mariia on auth, author azure-kirin, base main → approves" {
  export STUB_ME="adk47" STUB_AUTHOR="azure-kirin" STUB_BASE_REF="main"
  run "$SCRIPT" Muso-AI/auth 80 "$MARIIA"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^approve$' "$STUB_CALLS")" -eq 1 ]
  grep -q '"target":"Muso-AI/auth#80"' "$(logfile)"
  grep -q "\"requester\":\"$MARIIA\"" "$(logfile)"
}

@test "scoped: Mariia on ads-manager, author azure-kirin, base main → approves" {
  export STUB_ME="adk47" STUB_AUTHOR="azure-kirin" STUB_BASE_REF="main"
  run "$SCRIPT" Muso-AI/ads-manager 81 "$MARIIA"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^approve$' "$STUB_CALLS")" -eq 1 ]
  grep -q '"target":"Muso-AI/ads-manager#81"' "$(logfile)"
}

@test "scoped: Mariia on auth but base develop → exit 5 (the base is per-repo, not uniform)" {
  export STUB_ME="adk47" STUB_AUTHOR="azure-kirin" STUB_BASE_REF="develop"
  run "$SCRIPT" Muso-AI/auth 82 "$MARIIA"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'base branch must be main'
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  [ ! -f "$(logfile)" ]
}

@test "scoped: Mariia on ads-manager but base develop → exit 5" {
  export STUB_ME="adk47" STUB_AUTHOR="azure-kirin" STUB_BASE_REF="develop"
  run "$SCRIPT" Muso-AI/ads-manager 83 "$MARIIA"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'base branch must be main'
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  [ ! -f "$(logfile)" ]
}

@test "scoped: the widening does NOT loosen authorship — someone else's auth PR → exit 5" {
  export STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BASE_REF="main"
  run "$SCRIPT" Muso-AI/auth 84 "$MARIIA"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'PR author must be azure-kirin'
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  [ ! -f "$(logfile)" ]
}

@test "scoped: the widening adds exactly 3 repos — a 4th (octave-ui) still refuses on base main" {
  # Guards against a future edit that swaps the repo list for a wildcard.
  export STUB_ME="adk47" STUB_AUTHOR="azure-kirin" STUB_BASE_REF="main"
  run "$SCRIPT" Muso-AI/octave-ui 85 "$MARIIA"
  [ "$status" -eq 5 ]
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  [ ! -f "$(logfile)" ]
}

@test "removed: Serhii on hydra → exit 5 (was allowed before 2026-08-13), no approval, no log" {
  STUB_ME="adk47" STUB_AUTHOR="liflovs" QA_REBASE_REQUIRED_REPOS="other" \
    run "$SCRIPT" hydra 49 "$SERHII"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'is not authorized to approve PRs'
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  [ ! -f "$(logfile)" ]
}

@test "removed: Serhii on web-credits-next → exit 5 (not scoped in, either)" {
  STUB_ME="adk47" STUB_AUTHOR="liflovs" STUB_BASE_REF="develop" \
    run "$SCRIPT" Muso-AI/web-credits-next 50 "$SERHII"
  [ "$status" -eq 5 ]
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  [ ! -f "$(logfile)" ]
}

@test "removed: the exit-5 message must not claim Serhii is still allowed" {
  run "$SCRIPT" core-backend 123 "$SERHII"
  [ "$status" -eq 5 ]
  # The roster in the refusal text is the operator-facing contract.
  echo "$output" | grep -q 'unscoped: Aaron U7RP6HKUZ, Nick U0AL36NADEY'
  if echo "$output" | grep -q 'Aaron/Serhii/Nick'; then
    echo "refusal text still advertises the pre-2026-08-13 roster" >&2; false
  fi
  # Message text alone is not the point of the removal — assert the refusal is
  # REAL, exactly as every sibling refusal test does.
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  [ ! -f "$(logfile)" ]
}

# ---------------------------------------------------------------------------
# Guard 4b scope: an app/bot-decorated author must NOT satisfy a HUMAN scope
# entry. norm_login (right for Guards 3/3c/8, which collapse one bot identity's
# three spellings) WIDENS a scope entry: before this fix, STUB_AUTHOR of both
# "app/azure-kirin" and "azure-kirin[bot]" APPROVED on Mariia's UID.
# ---------------------------------------------------------------------------

@test "scoped: an 'app/'-decorated author does NOT match the human scope entry → exit 5, no approval" {
  STUB_ME="adk47" STUB_AUTHOR="app/azure-kirin" STUB_BASE_REF="develop" \
    run "$SCRIPT" Muso-AI/web-credits-next 60 "$MARIIA"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'App/bot decoration'
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  [ ! -f "$(logfile)" ]
}

@test "scoped: a '[bot]'-decorated author does NOT match the human scope entry → exit 5, no approval" {
  STUB_ME="adk47" STUB_AUTHOR="azure-kirin[bot]" STUB_BASE_REF="develop" \
    run "$SCRIPT" Muso-AI/web-credits-next 61 "$MARIIA"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'App/bot decoration'
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  [ ! -f "$(logfile)" ]
}

# ---------------------------------------------------------------------------
# A SCOPED principal must clear every OTHER guard too. Without these, a refactor
# could let a scoped requester skip CI-green / open-blockers / self-approval and
# the suite would stay green — the scoped tier is only as safe as the guards it
# still passes through. Mirrors the existing NICK cases, on Mariia's scope.
# ---------------------------------------------------------------------------

@test "scoped: Mariia in scope but CI not green → exit 8, no approval" {
  STUB_ME="adk47" STUB_AUTHOR="azure-kirin" STUB_BASE_REF="develop" STUB_BAD_CHECKS=2 \
    run "$SCRIPT" Muso-AI/web-credits-next 62 "$MARIIA"
  [ "$status" -eq 8 ]
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
}

@test "scoped: Mariia in scope but an unresolved blocking thread is open → exit 9, no approval" {
  STUB_ME="adk47" STUB_AUTHOR="azure-kirin" STUB_BASE_REF="develop" \
    STUB_BAD_CHECKS=0 STUB_OPEN_BLOCKERS=1 \
    run "$SCRIPT" Muso-AI/web-credits-next 63 "$MARIIA"
  [ "$status" -eq 9 ]
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
}

@test "scoped: Mariia in scope but the acting identity authored the PR → exit 4, no approval" {
  # Guard 3 is about $me, and it must still fire for a scoped requester.
  STUB_ME="azure-kirin" STUB_AUTHOR="azure-kirin" STUB_BASE_REF="develop" \
    run "$SCRIPT" Muso-AI/web-credits-next 64 "$MARIIA"
  [ "$status" -eq 4 ]
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
}

# ---------------------------------------------------------------------------
# Tier precedence: the tables are ADDITIVE GRANTS, not intersecting restrictions.
# Guard 4b's comment claimed "unscoped requesters never enter this block" while
# the loop ran unconditionally, so a UID in BOTH tables was silently DEMOTED to
# scoped-only — adding Nick to SCOPED_APPROVERS made `hydra 70 U0AL36NADEY` exit
# 5, i.e. an apparent widening actually REVOKED his org-wide authority.
# Pinned against a patched COPY of the script so the shipped tables stay honest.
# ---------------------------------------------------------------------------

# mk_variant <sed-script> — a patched copy of qa-pr-approve.sh that still finds
# its siblings (lib/, qa-gh.sh) via symlinks; POLICY comes from the env override.
mk_variant() {
  local dir="$TEST_TMPDIR/variant"
  mkdir -p "$dir"
  ln -s "$HYDRA_REPO/scripts/lib" "$dir/lib"
  ln -s "$HYDRA_REPO/scripts/qa-gh.sh" "$dir/qa-gh.sh"
  sed "$1" "$SCRIPT" > "$dir/qa-pr-approve.sh"
  chmod +x "$dir/qa-pr-approve.sh"
  printf '%s' "$dir/qa-pr-approve.sh"
}

@test "tiers: a UID in BOTH tables keeps UNSCOPED authority (Guard 4b is skipped, not applied)" {
  variant="$(mk_variant 's#^SCOPED_APPROVERS=(#SCOPED_APPROVERS=("U0AL36NADEY|Muso-AI/web-credits-next|azure-kirin|develop" #')"
  # Nick is now in BOTH tables. This PR is outside that scoped entry in every
  # field (hydra, author nsollazzo, base main) — his UNSCOPED grant must win.
  QA_APPROVAL_POLICY="$HYDRA_REPO/policies/qa-approval-policy.json" \
    STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BASE_REF="main" \
    QA_REBASE_REQUIRED_REPOS="other" run "$variant" hydra 70 "$NICK"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^approve$' "$STUB_CALLS")" -eq 1 ]
}

@test "tiers: both allowlist loops use the bash-3.2-safe empty-array expansion" {
  # SHAPE assertion, and it is load-bearing rather than pedantic: the two
  # behavioural tests below can only FAIL on bash 3.2, but CI runs Linux where
  # /bin/bash is bash 5 — there, a bare "${ARR[@]}" on an empty array is
  # perfectly legal, so the guard could be reverted with CI fully green. This
  # test fails on every bash, so the pin actually runs where it is enforced.
  local bare
  bare="$(grep -nE 'for (uid|spec) in "\$\{(UNSCOPED_UIDS|SCOPED_APPROVERS)\[@\]\}"' "$SCRIPT" || true)"
  if [ -n "$bare" ]; then
    echo "unguarded array expansion (crashes under set -u on bash 3.2): $bare" >&2; false
  fi
  [ "$(grep -cE '\$\{(UNSCOPED_UIDS|SCOPED_APPROVERS)\[@\]\+"\$\{(UNSCOPED_UIDS|SCOPED_APPROVERS)\[@\]\}"\}' "$SCRIPT")" -eq 3 ]
}

@test "tiers: emptying SCOPED_APPROVERS degrades to a clean die 5, never an unbound-variable crash" {
  # `set -u` + bash 3.2 (macOS /bin/bash) aborts on "${ARR[@]}" when ARR is
  # empty: exit 1, no message, no audit trail. Emptying a table is exactly the
  # edit the header block invites, so it must stay a graceful refusal.
  # NOTE: this can only go red on bash 3.2 — see the shape test above, which is
  # what pins the guard on CI's bash 5.
  # The table is a MULTI-LINE array (it holds one row per repo since
  # 2026-08-17), so emptying it means collapsing the whole block, not
  # rewriting one line: the old single-line `s#^SCOPED_APPROVERS=(.*#...#`
  # left the entry rows and the closing paren dangling. Within the block,
  # turn the opening line into the empty array and delete every other line.
  # Plain BRE — `(` and `)` are literal — so this works under BSD and GNU sed.
  variant="$(mk_variant '/^SCOPED_APPROVERS=(/,/^)$/{ s#^SCOPED_APPROVERS=($#SCOPED_APPROVERS=()#; /^SCOPED_APPROVERS=()$/!d; }')"
  QA_APPROVAL_POLICY="$HYDRA_REPO/policies/qa-approval-policy.json" \
    STUB_ME="adk47" STUB_AUTHOR="azure-kirin" STUB_BASE_REF="develop" \
    run /bin/bash "$variant" Muso-AI/web-credits-next 71 "$MARIIA"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'is not authorized to approve PRs'
  if echo "$output" | grep -q 'unbound variable'; then
    echo "empty SCOPED_APPROVERS crashed under set -u instead of refusing" >&2; false
  fi
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
}

@test "tiers: emptying UNSCOPED_UIDS degrades to a clean die 5, never an unbound-variable crash" {
  variant="$(mk_variant 's#^UNSCOPED_UIDS=(.*#UNSCOPED_UIDS=()#')"
  QA_APPROVAL_POLICY="$HYDRA_REPO/policies/qa-approval-policy.json" \
    STUB_ME="adk47" STUB_AUTHOR="nsollazzo" \
    run /bin/bash "$variant" core-backend 72 "$NICK"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'is not authorized to approve PRs'
  if echo "$output" | grep -q 'unbound variable'; then
    echo "empty UNSCOPED_UIDS crashed under set -u instead of refusing" >&2; false
  fi
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
}

@test "unscoped: Aaron approves on hydra with no scope conditions" {
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BASE_REF="literally-anything" \
    QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 51 "$AARON"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^approve$' "$STUB_CALLS")" -eq 1 ]
  grep -q "\"requester\":\"$AARON\"" "$(logfile)"
}

@test "unscoped: Nick approves on hydra with no scope conditions" {
  STUB_ME="adk47" STUB_AUTHOR="liflovs" STUB_BASE_REF="literally-anything" \
    QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 52 "$NICK"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^approve$' "$STUB_CALLS")" -eq 1 ]
}

@test "unscoped: an unreadable base branch does NOT block an unscoped requester" {
  # Guard 4b is scoped-only; base is irrelevant for Aaron/Nick and must not
  # become a new fail-closed surface for them.
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BASE_REF="" \
    run "$SCRIPT" core-backend 53 "$NICK"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^approve$' "$STUB_CALLS")" -eq 1 ]
}

@test "author read still dies 7 when the PR is unreadable, even though base is fetched with it" {
  STUB_ME="adk47" STUB_AUTHOR="" STUB_BASE_REF="develop" \
    run "$SCRIPT" core-backend 54 "$NICK"
  [ "$status" -eq 7 ]
  echo "$output" | grep -q 'could not read PR author'
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
}

# ---------------------------------------------------------------------------
# The `// ""` null guards in the shared `--json author,baseRefName` filter.
# A deleted/ghost PR author makes GitHub return `"author": null`. WITHOUT the
# guard the field arrives as the 4-char string "null" (this stub) or as an empty
# line (real gh) — and "null" sails straight past `[ -n "$author" ]`, so an
# UNSCOPED requester approves a PR whose author was never actually read.
# These two tests are the only thing pinning those guards: with them removed,
# both go red (mutation-verified). See the NOTE in setup() for why --arg-built
# stubs could never reach this shape.
# ---------------------------------------------------------------------------

@test "null guard: \"author\": null → exit 7, never approves (must not read as the string \"null\")" {
  # EXPORTED in the body, deliberately NOT the `VAR=x run ...` prefix the rest of
  # this file uses. These two tests reached the stub through that prefix and were
  # NON-DETERMINISTIC: ~10% of full-suite runs took the all-green path instead,
  # and the failure mode was the wrapper RECORDING AN APPROVAL. A flaky test is
  # bad; a flaky test whose flake direction is "approved" is a broken pin, and
  # these two are the only thing pinning the `// ""` guards.
  export STUB_ME="adk47" STUB_AUTHOR_NULL=1 STUB_BASE_REF="develop"
  run "$SCRIPT" core-backend 55 "$NICK"
  [ "$status" -eq 7 ]
  echo "$output" | grep -q 'could not read PR author'
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  [ ! -f "$(logfile)" ]
}

@test "null guard: \"baseRefName\": null → Guard 4b refuses the scoped requester (exit 5), never approves" {
  # The MESSAGE is load-bearing here, not just the exit code: without the guard
  # the base arrives as "null" and Guard 4b still exits 5 — but as a plain
  # mismatch ("must be develop (got null)"), not as the FAIL-CLOSED unreadable
  # path. Asserting the fail-closed wording is what makes this mutation-sensitive.
  # Exported in the body for the same reason as the test above.
  export STUB_ME="adk47" STUB_AUTHOR="azure-kirin" STUB_BASE_NULL=1
  run "$SCRIPT" Muso-AI/web-credits-next 56 "$MARIIA"
  [ "$status" -eq 5 ]
  echo "$output" | grep -q 'base branch could not be read'
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  [ ! -f "$(logfile)" ]
}

@test "owner/repo form with Muso-AI owner is accepted" {
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" run "$SCRIPT" Muso-AI/web-credits 7 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '"target":"Muso-AI/web-credits#7"' "$(logfile)"
}

@test "missing args → usage exit 2" {
  run "$SCRIPT" core-backend 123
  [ "$status" -eq 2 ]
}

@test "non-numeric PR number → usage exit 2" {
  run "$SCRIPT" core-backend not-a-number "$NICK"
  [ "$status" -eq 2 ]
}

@test "gh approve failure surfaces as exit 7" {
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_APPROVE_RC=1 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 7 ]
}

@test "CI not green → exit 8, never approves, never logs the approval" {
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=2 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "unresolved Critical/Important thread → exit 9, never approves" {
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_OPEN_BLOCKERS=1 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 9 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "#287 replay: CI green but a blocking thread open → exit 9, no approval" {
  # The exact shape that mis-approved #287: green CI, an unresolved 🔴/🟡 thread.
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_OPEN_BLOCKERS=4 \
    run "$SCRIPT" hydra 287 "$NICK"
  [ "$status" -eq 9 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Guard 6 fixture-based tests — real jq filter exercised against JSON shapes
# ---------------------------------------------------------------------------

@test "guard6/fixture: all green (CheckRun SUCCESS + StatusContext SUCCESS) → exit 0, approve recorded" {
  ROLLUP='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"StatusContext","context":"deploy/preview","state":"SUCCESS"}
  ]}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard6/fixture: pending CheckRun (IN_PROGRESS, conclusion null) → exit 8, no approve" {
  ROLLUP='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":null}
  ]}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard6/fixture: non-qa-review FAILURE → exit 8, no approve" {
  ROLLUP='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"unit-tests","status":"COMPLETED","conclusion":"FAILURE"}
  ]}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard6/fixture: qa-review FAILURE excluded, all others green → exit 0 (circular-dep exclusion), approve recorded" {
  ROLLUP='{"statusCheckRollup":[
    {"__typename":"StatusContext","context":"qa-review","state":"FAILURE"},
    {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"}
  ]}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard6/fixture: empty rollup → exit 8 (fail-closed: empty rollup is not proof CI ran) [QA #398]" {
  ROLLUP='{"statusCheckRollup":[]}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard6/fixture: rollup with ONLY an excluded qa-review check → exit 8 (no real checks present) [QA #398]" {
  ROLLUP='{"statusCheckRollup":[{"__typename":"StatusContext","context":"qa-review","state":"SUCCESS"}]}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Guard 7 fixture-based tests — real jq filter exercised against JSON shapes
# ---------------------------------------------------------------------------

# Helper: wrap nodes array in the full graphql response envelope Guard 7 expects
# Usage: STUB_THREADS_JSON="$(threads_json '[{...},{...}]')"
# (defined as a plain variable prefix in each test for portability)

@test "guard7/fixture: unresolved Critical (🔴) thread → exit 9, no approve" {
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":false,"comments":{"nodes":[{"body":"🔴 Critical: fix the null check"}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 9 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard7/fixture: unresolved Important (🟡) thread → exit 9, no approve" {
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":false,"comments":{"nodes":[{"body":"🟡 Important: consider edge case"}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 9 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard7/fixture: isResolved:true on 🔴 thread → exit 0 (resolved clears the block), approve recorded" {
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"comments":{"nodes":[{"body":"🔴 Critical: fix the null check"}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard7/fixture: 🟢 nice-to-have unresolved thread → exit 0 (only 🔴/🟡 block), approve recorded" {
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":false,"comments":{"nodes":[{"body":"🟢 Nice: consider extracting this helper"}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard7/fixture: unresolved thread with empty comments.nodes → exit 0 (no crash; safe // \"\")" {
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":false,"comments":{"nodes":[]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard7/fixture: hasNextPage:true (>100 threads) → exit 9 (fail-closed; a blocker could be on page 2) [QA #398]" {
  # Even with zero blockers visible on page 1, a second page means we cannot be sure.
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true},"nodes":[
    {"isResolved":true,"comments":{"nodes":[{"body":"all clear"}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 9 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Guard 8 — rebase-integrity report (scripts/check-rebase-integrity.sh hand-off)
# ---------------------------------------------------------------------------

HEAD_OID="0123456789abcdef0123456789abcdef01234567"   # stub default; sha7 = 0123456
MARKER="REBASE WARNING [0123456]"

ri_report() {  # <status> — write a well-formed per-head report Guard 8 keys on
  mkdir -p "$QA_REBASE_STATE_DIR"
  printf '{"repo":"Muso-AI/core-backend","pr":123,"head_sha":"%s","status":"%s"}' \
    "$HEAD_OID" "$1" > "$QA_REBASE_STATE_DIR/Muso-AI__core-backend-pr-123-${HEAD_OID}.json"
}

ri_report_raw() {  # <content> — write raw bytes (malformed-JSON cases)
  mkdir -p "$QA_REBASE_STATE_DIR"
  printf '%s' "$1" > "$QA_REBASE_STATE_DIR/Muso-AI__core-backend-pr-123-${HEAD_OID}.json"
}

NO_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'

@test "guard8: WARN report but no REBASE WARNING thread filed → exit 10, no approve" {
  ri_report WARN
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$NO_THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  echo "$output" | grep -q 'REBASE WARNING'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: WARN + QA-filed marker thread resolved by an INDEPENDENT human → approves (resolution is the ack)" {
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"resolvedBy":{"login":"aaronkaufman"},"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** PR deletes recent main work","author":{"login":"adk47"}}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: marker thread filed by someone OTHER than the gateway account → exit 10 (forged ack)" {
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** looks fine to me","author":{"login":"nsollazzo"}}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8/guard7 division of labor: WARN + marker thread UNRESOLVED → exit 9 (Guard 7 blocks first)" {
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":false,"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** PR deletes recent main work","author":{"login":"adk47"}}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 9 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: marker for a DIFFERENT head sha does not satisfy the WARN gate → exit 10" {
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"comments":{"nodes":[{"body":"🟡 **Important — REBASE WARNING [fffffff]** stale finding from an older push","author":{"login":"adk47"}}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

# --- Guard 8: staged rollout of the independence requirement -----------------
# The rule ships DISABLED so the PR introducing it is not judged against itself
# (a head created before the rule existed can never satisfy it). Default must be
# byte-for-byte the previous behaviour; these two tests pin both halves of that.

@test "guard8 rollout: flag OFF (default) → an author-resolved marker still approves" {
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"resolvedBy":{"login":"nsollazzo"},"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** PR deletes recent main work","author":{"login":"adk47"}}]}}
  ]}}}}}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8 rollout: flag OFF still requires the marker thread to EXIST" {
  # Disabling the independence check must not disable the gate itself.
  ri_report WARN
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$NO_THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

# --- Guard 8: the acknowledgment must come from an INDEPENDENT human ---------
# Observed on hydra#747: all eight REBASE WARNING threads were filed by the bot
# and resolved by the PR author, so the gate passed while nobody but the author
# had ever looked. The skill said "never resolve it yourself"; prose is not
# enforcement. These tests are that enforcement.

@test "guard8: marker thread resolved by the PR AUTHOR → exit 10 (self-certification)" {
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"resolvedBy":{"login":"nsollazzo"},"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** PR deletes recent main work","author":{"login":"adk47"}}]}}
  ]}}}}}'
  QA_REBASE_ACK_REQUIRE_INDEPENDENT=1 STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  echo "$output" | grep -q 'independent human'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: author self-resolves under a DIFFERENT-CASE login → still exit 10" {
  # GitHub logins are case-insensitive; a case-flipped resolver must not slip past.
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"resolvedBy":{"login":"NSollazzo"},"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** x","author":{"login":"adk47"}}]}}
  ]}}}}}'
  QA_REBASE_ACK_REQUIRE_INDEPENDENT=1 STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: marker thread resolved by the BOT ITSELF → exit 10 (QA cannot clear its own finding)" {
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"resolvedBy":{"login":"adk47"},"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** x","author":{"login":"adk47"}}]}}
  ]}}}}}'
  QA_REBASE_ACK_REQUIRE_INDEPENDENT=1 STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: bot resolving under the [bot]-suffixed login form → still exit 10" {
  # The resolver is normalised through the same norm/bot_logins set as the filer,
  # so app/x, x[bot] and x are all recognised as the bot.
  test_policy "$DEFAULT_POLICY"
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"resolvedBy":{"login":"muso-qa-bot[bot]"},"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** x","author":{"login":"muso-qa-bot"}}]}}
  ]}}}}}'
  QA_REBASE_ACK_REQUIRE_INDEPENDENT=1 STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: resolvedBy absent on a resolved thread → exit 10 (no resolver, no ack)" {
  # GraphQL can report isResolved with a null resolvedBy; that is not an ack.
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"resolvedBy":null,"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** x","author":{"login":"adk47"}}]}}
  ]}}}}}'
  QA_REBASE_ACK_REQUIRE_INDEPENDENT=1 STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: two marker threads, only one independently resolved → approves" {
  # A re-filed marker (same head) must not be blocked by a stale author-resolved
  # sibling: one genuine independent ack is enough.
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"resolvedBy":{"login":"nsollazzo"},"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** first pass","author":{"login":"adk47"}}]}},
    {"isResolved":true,"resolvedBy":{"login":"aaronkaufman"},"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** re-filed","author":{"login":"adk47"}}]}}
  ]}}}}}'
  QA_REBASE_ACK_REQUIRE_INDEPENDENT=1 STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: report status ERROR → exit 10 (rebase state unverified, fail closed)" {
  ri_report ERROR
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: malformed report JSON → exit 10 (fail closed)" {
  ri_report_raw 'this is not json'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: report interior fields mismatching the filename key → exit 10 (fail closed)" {
  ri_report_raw '{"repo":"Muso-AI/core-backend","pr":999,"head_sha":"0000000000000000000000000000000000000000","status":"CLEAN"}'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: CLEAN report → approves" {
  ri_report CLEAN
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: missing report file for an EXTERNAL repo (no analyzer in its CI) → approves" {
  # QA_REBASE_STATE_DIR exists but holds no report for this head
  mkdir -p "$QA_REBASE_STATE_DIR"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: missing report file for a REQUIRED repo (hydra) → exit 10 (failed hand-off is not clean)" {
  mkdir -p "$QA_REBASE_STATE_DIR"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    run "$SCRIPT" hydra 625 "$NICK"
  [ "$status" -eq 10 ]
  echo "$output" | grep -q 'no rebase-integrity report'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8: QA_REBASE_REQUIRED_REPOS is tunable — hydra not listed → missing report approves" {
  mkdir -p "$QA_REBASE_STATE_DIR"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 QA_REBASE_REQUIRED_REPOS="other-repo" \
    run "$SCRIPT" hydra 625 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Bot identity — the App-token migration
# ---------------------------------------------------------------------------
# `gh api user` returns 403 "Resource not accessible by integration" under a
# GitHub App installation token: there is no user behind an App token. The stub
# models that as empty output (STUB_ME="").

test_policy() {  # <json> — point the script at a throwaway policy
  printf '%s' "$1" > "$TEST_TMPDIR/policy.json"
  export QA_APPROVAL_POLICY="$TEST_TMPDIR/policy.json"
}

DEFAULT_POLICY='{"identity":{"bot_logins":["muso-qa-bot","muso-qa-bot[bot]","adk47"],"app_repos":[]},
  "author_deny":[],"require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'

@test "identity: gh api user 403s (App token) → falls back to a policy bot login, still approves" {
  test_policy "$DEFAULT_POLICY"
  STUB_ME="" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
  grep -q '"identity":"muso-qa-bot"' "$(logfile)"
}

@test "identity: Guard 3 fires on the app/<slug> author form gh actually returns" {
  # `gh pr view --json author` is GraphQL and returns "app/<slug>" — NOT the REST
  # "<slug>[bot]" form. Verified against Muso-AI/auth's dependabot PR 2026-07-27:
  # REST said "dependabot[bot]", gh pr view said "app/dependabot". Comparing raw
  # strings matches nothing, so norm_login() must collapse both.
  test_policy "$DEFAULT_POLICY"
  STUB_ME="" STUB_AUTHOR="app/muso-qa-bot" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 4 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "identity: Guard 3 also fires on the REST <slug>[bot] form" {
  test_policy "$DEFAULT_POLICY"
  STUB_ME="muso-qa-bot" STUB_AUTHOR="muso-qa-bot[bot]" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 4 ]
}

@test "guard3c: author_deny matches across app/ and [bot] forms too" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":["adk47"],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="app/adk47" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 12 ]
}

@test "guard3c: malformed author_deny → exit 12 (fail closed), not a silent pass" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":"adk47",
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="adk47" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 12 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Notice 3b — sensitive paths ALERT, they no longer block (changed 2026-08-03).
#
# These tests used to assert exit 11. They now assert that the SAME path is
# still DETECTED and named, and that the approval proceeds. The detection is
# the part worth keeping: if these stopped matching, the alert would go quiet
# and nobody would know the bot had approved a policy or credential change.
# ---------------------------------------------------------------------------

# assert_alerted <substring> — an alert was surfaced, and it mentions <substring>
assert_alerted() {
  echo "$output" | grep -q 'ALERT' || { echo "expected an ALERT, got: $output" >&2; return 1; }
  echo "$output" | grep -qF "$1" || { echo "ALERT did not mention '$1': $output" >&2; return 1; }
}

@test "notice3b: changed-file count mismatch → alerts, still approves (no longer fail-closed)" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":[".github/workflows/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="a.ts b.ts" STUB_CHANGED_COUNT=130 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  assert_alerted 'reports 130 changed files'
  grep -q '^approve$' "$STUB_CALLS"
}

@test "notice3b: count mismatch DOES still fail closed when sensitive_paths_blocking is set" {
  # The escape hatch: a path opted back into blocking cannot be verified on a
  # partial file list, so the wrapper must refuse rather than approve blind.
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":[".github/workflows/"]},
    "sensitive_paths_blocking":{"*":["secrets/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="a.ts b.ts" STUB_CHANGED_COUNT=130 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 11 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "notice3b: a path in sensitive_paths_blocking still refuses (exit 11)" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]},
    "sensitive_paths_blocking":{"*":["secrets/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="secrets/token.conf" run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 11 ]
  echo "$output" | grep -q 'BLOCKING sensitive path'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "alerts: the STDOUT replay is emitted, not just the inline stderr copy" {
  # bats merges stderr into $output, so assert_alerted alone is satisfied by
  # EITHER channel — the stdout replay block could be deleted with zero test
  # failures. That replay is what SKILL.md tells the agent to relay, and since
  # sensitive-path blocking was removed it IS the surviving protection.
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="policies/qa-approval-policy.json" \
    run --separate-stderr "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  # the authoritative list on STDOUT
  echo "$output" | grep -q '── 1 ALERT(S) on this run'
  echo "$output" | grep -qF 'policies/qa-approval-policy.json'
  # and the inline copy on STDERR, for the cron journal
  echo "$stderr" | grep -qF 'policies/qa-approval-policy.json'
}

@test "alerts: a REFUSAL still replays the alerts (they precede every guard that dies)" {
  # Every alert() call site is followed by refusal paths. Replaying only on the
  # success path dropped the alert exactly when a human was being pulled in.
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=1 \
    STUB_FILES="policies/qa-approval-policy.json" \
    run --separate-stderr "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  echo "$output" | grep -q 'ALERT(S) on this run'
  echo "$output" | grep -qF 'policies/qa-approval-policy.json'
}

@test "guard6: a PR editing .github/workflows/ gets NO advisory exemption" {
  # GitHub runs a same-repo PR's workflows from the PR HEAD, so job names are
  # author-controlled. Without this, naming a job "Deploy pre-flight — validate"
  # would exempt the entire validate job (skill-drift, secrets scan, JSON lint…)
  # and report green on a visibly red PR. Notice 3b no longer refuses on
  # .github/workflows/, so this is the gate that closes it.
  ROLLUP='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"pr-validate","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"Deploy pre-flight (rsync)","conclusion":"FAILURE"}]}'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]},
    "advisory_checks":{"*":["Deploy pre-flight"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    STUB_FILES=".github/workflows/pr-validate.yml" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard6: file-list failure + workflow-name spoof → NO exemption (exit 8)" {
  # The combined case. file_trouble() alerts but leaves changed_files UNSET, so a
  # gate written as `[ -n "$changed_files" ] && grep workflows` was SKIPPED on a
  # transient files-API failure and PRESERVED the exemption — a fail-open in the
  # gate whose whole job is closing one. Unknown file list ⇒ no exemption.
  ROLLUP='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"pr-validate","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"Deploy pre-flight — validate","conclusion":"FAILURE"}]}'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]},
    "advisory_checks":{"*":["Deploy pre-flight"]}}'
  # STUB_CHANGED_COUNT mismatches the returned list -> file_trouble -> unset list
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    STUB_FILES="a.ts b.ts" STUB_CHANGED_COUNT=99 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "alerts: a REFUSAL never claims the PR was approved" {
  # die() replays alerts, so any alert asserting "auto-approved" would be a lie
  # on every refusal path. Alert text must be state-neutral.
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=1 \
    STUB_FILES="policies/qa-approval-policy.json" \
    run --separate-stderr "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  # the alert still surfaces...
  echo "$output" | grep -qF 'policies/qa-approval-policy.json'
  # ...but never asserts an approval that did not happen
  if echo "$output" | grep -qiE 'was auto-approved|approved .*#123 with'; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard6 STABILITY: a PR NOT editing workflows keeps its advisory exemption" {
  ROLLUP='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"pr-validate","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"Deploy pre-flight (rsync)","conclusion":"FAILURE"}]}'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]},
    "advisory_checks":{"*":["Deploy pre-flight"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    STUB_FILES="src/app.ts" run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "notice3b: a MALFORMED sensitive_paths_blocking refuses (exit 11), never 'nothing blocks'" {
  # It is the only surviving hard path gate, so it must fail CLOSED. A
  # `(.key // []) || echo '[]'` read would collapse "malformed" into "empty" and
  # silently disable the last gate — the bug class lib/qa-policy.sh exists for.
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]},
    "sensitive_paths_blocking":"not-an-object"}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="src/app.ts" run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 11 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "notice3b: an ABSENT sensitive_paths_blocking is fine (readable, nothing blocks)" {
  # Stability pair: absent must stay distinguishable from malformed, or the
  # fail-closed read above would block every PR in the default config.
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="src/app.ts" run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

# --- the AUTHORITY SURFACE is blocking as SHIPPED (narrowed 2026-08-14) -------
# These run against the real policies/qa-approval-policy.json, not a synthetic
# one: the point is what the repo actually ships, since that is what decides
# whether a widening of the bot's own authority can be self-approved. The
# predecessor of this block asserted the key ships EMPTY — i.e. it encoded the
# gap. Aaron-only for the security surface: docs/reference/GOVERNANCE.md.

@test "authority: the SHIPPED policy blocks the files that decide who may approve" {
  pol="$HYDRA_REPO/policies/qa-approval-policy.json"
  run jq -e '
    (.sensitive_paths_blocking["Muso-AI/hydra"] // []) as $b
    | ([ "policies/qa-approval-policy.json", "scripts/qa-pr-approve.sh",
         "CODEOWNERS", ".github/CODEOWNERS", "docs/CODEOWNERS" ]
       | all(. as $p | $b | index($p) != null))' "$pol"
  [ "$status" -eq 0 ]
}

@test "authority: the SHIPPED policy does NOT re-block the alert-only paths" {
  # The 2026-08-03 change exists because a blanket refusal made the bot unusable.
  # Narrowing must stay narrow, so these must remain approvable.
  pol="$HYDRA_REPO/policies/qa-approval-policy.json"
  run jq -e '
    (.sensitive_paths_blocking["Muso-AI/hydra"] // []) as $b
    | ([ "scripts/deploy.sh", "scripts/qa-gh.sh", "scripts/qa-dispatch-pr-review.sh",
         "skills-all/muso-github-code-review/", "scripts/lib/qa-author-slack-uid.sh" ]
       | all(. as $p | $b | index($p) == null))' "$pol"
  [ "$status" -eq 0 ]
}

@test "authority: a PR touching qa-pr-approve.sh refuses (exit 11) under the SHIPPED policy" {
  QA_APPROVAL_POLICY="$HYDRA_REPO/policies/qa-approval-policy.json" \
    STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BASE_REF="main" STUB_BAD_CHECKS=0 \
    STUB_FILES="scripts/qa-pr-approve.sh" \
    QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 70 "$NICK"
  [ "$status" -eq 11 ]
  ! grep -q '^approve$' "$STUB_CALLS"
  echo "$output" | grep -qF 'scripts/qa-pr-approve.sh'
}

@test "authority: a PR touching the approval POLICY refuses (exit 11) under the SHIPPED policy" {
  QA_APPROVAL_POLICY="$HYDRA_REPO/policies/qa-approval-policy.json" \
    STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BASE_REF="main" STUB_BAD_CHECKS=0 \
    STUB_FILES="policies/qa-approval-policy.json" \
    QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 70 "$NICK"
  [ "$status" -eq 11 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "authority: a PR touching .github/CODEOWNERS refuses (exit 11) under the SHIPPED policy" {
  # CODEOWNERS decides who satisfies require_code_owner_reviews, and the bot
  # posts as adk47 — the universal code owner. Adding an owner is authority.
  QA_APPROVAL_POLICY="$HYDRA_REPO/policies/qa-approval-policy.json" \
    STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BASE_REF="main" STUB_BAD_CHECKS=0 \
    STUB_FILES=".github/CODEOWNERS" \
    QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 70 "$NICK"
  [ "$status" -eq 11 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "authority REGRESSION GUARD: deploy.sh is sensitive but still APPROVES (no blanket refusal)" {
  # If this ever flips to 11, someone re-broadened the blocking list and the bot
  # is on its way back to being unusable. That is the failure this test exists
  # to catch — it is not a happy-path duplicate of the cases above.
  QA_APPROVAL_POLICY="$HYDRA_REPO/policies/qa-approval-policy.json" \
    STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BASE_REF="main" STUB_BAD_CHECKS=0 \
    STUB_FILES="scripts/deploy.sh" \
    QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 70 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3b: >100 ordinary files from paginated REST → approves" {
  page1=""
  for i in $(seq 1 100); do page1="${page1}src/page-1-file-${i}.ts "; done
  page2=""
  for i in $(seq 1 35); do page2="${page2}src/page-2-file-${i}.ts "; done
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES_PAGE_1="$page1" STUB_FILES_PAGE_2="$page2" STUB_CHANGED_COUNT=135 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^files-api-paginated-slurped$' "$STUB_CALLS"
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3b: sensitive file on REST page 2 → exit 11 with the path" {
  page1=""
  for i in $(seq 1 100); do page1="${page1}src/page-1-file-${i}.ts "; done
  page2=""
  for i in $(seq 1 34); do page2="${page2}src/page-2-file-${i}.ts "; done
  page2="${page2}policies/qa-approval-policy.json"
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES_PAGE_1="$page1" STUB_FILES_PAGE_2="$page2" STUB_CHANGED_COUNT=135 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  assert_alerted 'policies/qa-approval-policy.json'
  grep -q '^approve$' "$STUB_CALLS"
}

@test "notice3b: rename out of a sensitive path still checks previous_filename → alerts" {
  files='[[{"filename":"src/app.ts","status":"modified"}],
    [{"filename":"archive/old-policy.json","previous_filename":"policies/qa-approval-policy.json","status":"renamed"}]]'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES_JSON="$files" STUB_CHANGED_COUNT=2 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  assert_alerted 'policies/qa-approval-policy.json'
  grep -q '^approve$' "$STUB_CALLS"
}

@test "notice3b: duplicate filename across REST pages → alerts, still approves" {
  files="$(jq -nc '
    ([range(1; 101) | {filename: ("src/file-" + tostring + ".ts"), status: "modified"}]) as $page1
    | [$page1, [{filename: "src/file-1.ts", status: "modified"}]]')"
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES_JSON="$files" STUB_CHANGED_COUNT=101 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  assert_alerted 'duplicate'
  grep -q '^approve$' "$STUB_CALLS"
}

@test "notice3b: empty filename in REST row → alerts, still approves" {
  files='[[{"filename":"","status":"modified"}]]'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES_JSON="$files" STUB_CHANGED_COUNT=1 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  assert_alerted 'parse'
  grep -q '^approve$' "$STUB_CALLS"
}

@test "notice3b: empty previous_filename on renamed REST row → alerts, still approves" {
  files='[[{"filename":"archive/policy.json","previous_filename":"","status":"renamed"}]]'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES_JSON="$files" STUB_CHANGED_COUNT=1 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  assert_alerted 'parse'
  grep -q '^approve$' "$STUB_CALLS"
}

@test "notice3b: unknown REST file status → alerts, still approves" {
  files='[[{"filename":"src/app.ts","status":"mystery"}]]'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES_JSON="$files" STUB_CHANGED_COUNT=1 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  assert_alerted 'parse'
  grep -q '^approve$' "$STUB_CALLS"
}

@test "notice3b: a DROPPED sensitive_paths key alerts (the guard is disabled fleet-wide)" {
  # Previously exit 11, on the reasoning that a dropped key must not silently
  # disable the guard. The guard no longer blocks, so the equivalent protection
  # is that the DEGRADATION IS ANNOUNCED rather than passing silently.
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[]}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  assert_alerted 'no sensitive_paths key at all'
  grep -q '^approve$' "$STUB_CALLS"
}

@test "notice3b STABILITY: a present-but-empty sensitive_paths does NOT cry wolf" {
  # Pairs with the test above. `{}` (or a repo with no entries) is normal
  # operation, not breakage — alerting there put a false "I am broken" line on
  # every single approval, which is how a real alert gets tuned out.
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  if echo "$output" | grep -q 'ALERT'; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  grep -q '^approve$' "$STUB_CALLS"
}

@test "identity: gh api user 403s AND Guard 8 WARN → marker thread still resolves (the \$me-empty bug)" {
  # Regression guard. Before the fix, an empty \$me made Guard 8 compare
  # .author.login against "", match nothing, and refuse EVERY WARN head.
  test_policy "$DEFAULT_POLICY"
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"resolvedBy":{"login":"aaronkaufman"},"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** rebase dropped work","author":{"login":"muso-qa-bot"}}]}}
  ]}}}}}'
  STUB_ME="" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "identity: a legacy marker thread filed by the OLD host account still counts (cutover/rollback)" {
  # PRs open across the cutover carry adk47-filed REBASE WARNING threads. If the
  # login test were a single value rather than the bot_logins set, those PRs
  # would strand at exit 10 the moment the App took over.
  test_policy "$DEFAULT_POLICY"
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"resolvedBy":{"login":"aaronkaufman"},"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** filed pre-cutover","author":{"login":"adk47"}}]}}
  ]}}}}}'
  STUB_ME="muso-qa-bot[bot]" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "identity: GraphQL Bot.login form (no [bot] suffix) matches the REST-form identity" {
  test_policy "$DEFAULT_POLICY"
  ri_report WARN
  THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"resolvedBy":{"login":"aaronkaufman"},"comments":{"nodes":[{"body":"🟡 **Important — '"$MARKER"'** x","author":{"login":"muso-qa-bot"}}]}}
  ]}}}}}'
  STUB_ME="muso-qa-bot[bot]" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
}

@test "self-approval still blocks when the acting identity authored the PR" {
  test_policy "$DEFAULT_POLICY"
  STUB_ME="muso-qa-bot[bot]" STUB_AUTHOR="muso-qa-bot[bot]" run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 4 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Guard 3b — sensitive paths (exit 11)
# ---------------------------------------------------------------------------

@test "notice3b: PR touching policies/ → approves, logs, and ALERTS by path" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"],"Muso-AI/hydra":["policies/","secrets/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="README.md policies/qa-approval-policy.json" \
    QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 700 "$NICK"
  [ "$status" -eq 0 ]
  assert_alerted 'policies/qa-approval-policy.json'
  grep -q '^approve$' "$STUB_CALLS"
  # Guard 5 still holds: an approval is logged before it is written.
  [ -f "$(logfile)" ]
}

@test "notice3b: the bot CAN now approve a change to its own approval script — but alerts" {
  # This is the self-reference that was deliberately given up on 2026-08-03.
  # The test exists to make that explicit rather than letting it look like an
  # oversight: if this ever silently stops alerting, the trade has gone bad.
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"],"Muso-AI/hydra":["scripts/qa-pr-approve.sh"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="scripts/qa-pr-approve.sh" \
    QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 701 "$NICK"
  [ "$status" -eq 0 ]
  assert_alerted 'scripts/qa-pr-approve.sh'
  grep -q '^approve$' "$STUB_CALLS"
}

@test "notice3b: sensitive paths are detected regardless of author" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":[".github/workflows/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES=".github/workflows/deploy.yml" run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  assert_alerted '.github/workflows/deploy.yml'
}

@test "guard3b: ordinary source paths are unaffected → approves" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":[".github/workflows/"],"Muso-AI/hydra":["policies/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="src/app.ts docs/README.md" run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "unreadable policy → refuses (fail closed) at the first guard that reads it, never approves" {
  # Guard 3c reads the policy before 3b does, and is itself fail-closed, so an
  # unreadable policy dies 12 rather than reaching 3b's exit 11. Either way the
  # invariant that matters holds: no approval without a readable policy.
  export QA_APPROVAL_POLICY="$TEST_TMPDIR/does-not-exist.json"
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 12 ]
  echo "$output" | grep -q 'fail closed'
  ! grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Guard 3c — author_deny (exit 12)
# ---------------------------------------------------------------------------

@test "guard3c: author in author_deny → exit 12, never approves" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":["adk47"],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="adk47" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 12 ]
  echo "$output" | grep -q 'author_deny'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3c: author_deny is case-insensitive (GitHub logins are)" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":["adk47"],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="ADK47" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 12 ]
}

@test "guard3c: flipping author_deny to [] lets the same PR through (the deliberate policy flip)" {
  test_policy "$DEFAULT_POLICY"
  STUB_ME="muso-qa-bot" STUB_AUTHOR="adk47" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Code-owner honesty
# ---------------------------------------------------------------------------

@test "codeowner note: SILENT when app_repos is empty (the host login IS the code owner)" {
  # The note used to fire for every repo in require_human_codeowner_repos, which
  # was false: with app_repos empty every call runs as the host account (adk47),
  # and CODEOWNERS grants `* @adk47`, so the approval DOES clear the code-owner
  # gate. Telling people otherwise sent them looking for a human they did not need.
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":["Muso-AI/hydra"],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 702 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
  ! echo "$output" | grep -q 'does NOT clear the code-owner gate'
}

@test "codeowner note: the condition requires BOTH lists, not just require_human_codeowner_repos" {
  # The App path itself is not exercisable here: a non-empty identity.app_repos
  # sends qa-gh.sh off to mint a real GitHub App installation token, which this
  # harness has no credentials for (that is why no other test sets it). So the
  # CONDITION is asserted directly — it is the part that regressed, and the part
  # that decides whether people are told to go find a human they do not need.
  cond='((.require_human_codeowner_repos // []) | index($r)) and ((.identity.app_repos // []) | index($r))'

  # app_repos empty → host identity (adk47, the universal code owner) → silent
  run jq -e --arg r "Muso-AI/hydra" "$cond" <<'P'
{"identity":{"app_repos":[]},"require_human_codeowner_repos":["Muso-AI/hydra"]}
P
  [ "$status" -ne 0 ]

  # repo served by the App → the App can never be a CODEOWNER → note fires
  run jq -e --arg r "Muso-AI/hydra" "$cond" <<'P'
{"identity":{"app_repos":["Muso-AI/hydra"]},"require_human_codeowner_repos":["Muso-AI/hydra"]}
P
  [ "$status" -eq 0 ]
}

@test "notice3b: a PR editing the reviewer SKILL is alerted on, and approved" {
  # The skill is as load-bearing as the wrapper: a PR that edits it to skip the
  # lens workflow, or to post qa-review=success directly, weakens the gate just
  # as effectively as editing qa-pr-approve.sh. That is now an ALERT rather than
  # a refusal, so the alert is the whole protection — it must keep firing.
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"],"Muso-AI/hydra":["skills-all/muso-github-code-review/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="skills-all/muso-github-code-review/SKILL.md" \
    QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 900 "$NICK"
  [ "$status" -eq 0 ]
  assert_alerted 'skills-all/muso-github-code-review/SKILL.md'
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3b: the SHIPPED policy actually covers the reviewer skill and the QA scripts" {
  # Guards the policy DATA, not just the code path — the entries above are the
  # whole protection, and a dropped line is silent.
  pol="$HYDRA_REPO/policies/qa-approval-policy.json"
  for p in "skills-all/muso-github-code-review/" "scripts/qa-pr-approve.sh" \
           "scripts/qa-gh.sh" "scripts/qa-review-status.sh" "policies/" "secrets/" "CODEOWNERS"; do
    run jq -e --arg p "$p" '(.sensitive_paths["Muso-AI/hydra"] // []) + (.sensitive_paths["*"] // []) | index($p)' "$pol"
    [ "$status" -eq 0 ]
  done
}

@test "notice3b: .github/CODEOWNERS is detected (GitHub honours it ABOVE the root file)" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"],"Muso-AI/hydra":["CODEOWNERS",".github/CODEOWNERS","docs/CODEOWNERS"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES=".github/CODEOWNERS" QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 901 "$NICK"
  [ "$status" -eq 0 ]
  assert_alerted '.github/CODEOWNERS'
}

@test "notice3b: docs/CODEOWNERS is detected too" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"],"Muso-AI/hydra":["CODEOWNERS",".github/CODEOWNERS","docs/CODEOWNERS"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_FILES="docs/CODEOWNERS" QA_REBASE_REQUIRED_REPOS="other" run "$SCRIPT" hydra 902 "$NICK"
  [ "$status" -eq 0 ]
  assert_alerted 'docs/CODEOWNERS'
}

# ---------------------------------------------------------------------------
# Guard 6 — advisory checks (added 2026-08-03)
# ---------------------------------------------------------------------------

@test "guard6: a RED advisory check no longer blocks — approves and alerts" {
  # hydra#780: verdict GO, 0 findings, blocked solely because the deploy
  # pre-flight rsync dry-run was red against live server state.
  ROLLUP='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"pr-validate","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"Deploy pre-flight (rsync --delete dry-run vs /opt/hydra/)","conclusion":"FAILURE"}]}'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]},
    "advisory_checks":{"*":["Deploy pre-flight"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  assert_alerted 'Deploy pre-flight'
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard6: a red NON-advisory check still refuses (exit 8)" {
  ROLLUP='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"pr-validate","conclusion":"FAILURE"},
    {"__typename":"CheckRun","name":"Deploy pre-flight (rsync)","conclusion":"FAILURE"}]}'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]},
    "advisory_checks":{"*":["Deploy pre-flight"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard6: with NO advisory_checks configured, a red deploy pre-flight still blocks" {
  # Stability pair for the discrimination test above: the exemption must come
  # from the policy, not from the check's name looking infrastructural.
  ROLLUP='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"pr-validate","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"Deploy pre-flight (rsync)","conclusion":"FAILURE"}]}'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
}

@test "guard6: an all-advisory rollup still refuses, and SAYS so accurately" {
  # Both this and the empty-rollup case refuse — neither proves CI gated the PR —
  # but they must not share a message. The old code answered "did CI run" from
  # the FILTERED array, so this case reported "no checks exist", which was false.
  ROLLUP='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"Deploy pre-flight (rsync)","conclusion":"SUCCESS"}]}'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]},
    "advisory_checks":{"*":["Deploy pre-flight"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  echo "$output" | grep -q 'advisory-exempt'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard6: a genuinely EMPTY rollup refuses with the no-checks message" {
  ROLLUP='{"statusCheckRollup":[]}'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]},
    "advisory_checks":{"*":["Deploy pre-flight"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  echo "$output" | grep -q 'no non-qa-review checks exist'
}

@test "guard6: advisory matching is startswith, NOT contains (author-controlled names)" {
  # .github/workflows/ is only alert-guarded now, so a PR can add a job. A
  # `contains` test would let "Sneaky Deploy pre-flight shim" buy an exemption.
  ROLLUP='{"statusCheckRollup":[
    {"__typename":"CheckRun","name":"pr-validate","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"Sneaky Deploy pre-flight shim","conclusion":"FAILURE"}]}'
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]},
    "advisory_checks":{"*":["Deploy pre-flight"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="nsollazzo" STUB_ROLLUP_JSON="$ROLLUP" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 8 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard6: the SHIPPED policy exempts the deploy pre-flight, per-repo" {
  pol="$HYDRA_REPO/policies/qa-approval-policy.json"
  run jq -e '(.advisory_checks["Muso-AI/hydra"] // []) | index("Deploy pre-flight")' "$pol"
  [ "$status" -eq 0 ]
}

@test "guard6: the SHIPPED policy names only REAL check names, never step names" {
  # A gate that is a STEP inside another job can never appear in the rollup —
  # only its enclosing job does. Listing one is dead config that reads as
  # protection. These are the check names hydra actually publishes.
  pol="$HYDRA_REPO/policies/qa-approval-policy.json"
  real='["Bats","Deploy pre-flight","Plugin tests","Python syntax check","Python unit tests","Shellcheck","pr-title","qa-review","validate"]'
  run jq -e --argjson real "$real" '
    [ (.advisory_checks // {}) | .[][] ]
    | all(. as $e | $real | any(startswith($e) or ($e | startswith(.))))' "$pol"
  [ "$status" -eq 0 ]
}

@test "guard6: the SHIPPED policy never exempts the validate job" {
  # validate carries the cron-orphan / doctrine / lint gates. Exempting it to
  # reach one live-state step inside it would silence all of them.
  pol="$HYDRA_REPO/policies/qa-approval-policy.json"
  run jq -e '[ (.advisory_checks // {}) | .[][] ] | any(. == "validate")' "$pol"
  [ "$status" -ne 0 ]
}

@test "guard3b: the SHIPPED policy covers all three GitHub CODEOWNERS locations" {
  pol="$HYDRA_REPO/policies/qa-approval-policy.json"
  for p in "CODEOWNERS" ".github/CODEOWNERS" "docs/CODEOWNERS"; do
    run jq -e --arg p "$p" '(.sensitive_paths["Muso-AI/hydra"] // []) | index($p)' "$pol"
    [ "$status" -eq 0 ]
  done
}

@test "guard3c: a MISSING author_deny key → exit 12 (absent must not read as empty allow-list)" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="adk47" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 12 ]
  echo "$output" | grep -q 'missing or null'
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard3c: a NULL author_deny → exit 12" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":null,
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="adk47" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 12 ]
}

@test "guard3c: an EXPLICIT [] is still honoured as the deliberate policy flip" {
  test_policy '{"identity":{"bot_logins":["muso-qa-bot"],"app_repos":[]},"author_deny":[],
    "require_human_codeowner_repos":[],"sensitive_paths":{"*":["nope/"]}}'
  STUB_ME="muso-qa-bot" STUB_AUTHOR="adk47" STUB_BAD_CHECKS=0 run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

# ---------------------------------------------------------------------------
# Guard 8 — cross-head ack carryover (warn_digest)
# A human resolving a REBASE WARNING judges CONTENT, not a sha. When a later
# head's report carries a byte-identical warn_digest, that judgement still
# applies, so the ack carries forward instead of re-filing. Everything else
# still fails closed. (70% of hydra's rebase-warned PRs re-filed across heads;
# PR #673 collected 11 acks — an ack treadmill trains rubber-stamping.)
# ---------------------------------------------------------------------------

PRIOR_OID="fedcba9876543210fedcba9876543210fedcba98"   # sha7 = fedcba9
DIG_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"   # 64 hex
DIG_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"   # 64 hex

ri_report_d() {  # <status> <warn_digest> [head_oid] — report carrying a digest
  local head="${3:-$HEAD_OID}"
  mkdir -p "$QA_REBASE_STATE_DIR"
  printf '{"repo":"Muso-AI/core-backend","pr":123,"head_sha":"%s","status":"%s","warn_digest":"%s"}' \
    "$head" "$1" "$2" > "$QA_REBASE_STATE_DIR/Muso-AI__core-backend-pr-123-${head}.json"
}

prior_thread() {  # <isResolved> <sha7> <filer> [resolvedBy-login]
  # resolvedBy omitted entirely when the 4th arg is absent — GraphQL reports a
  # resolved thread with a null resolvedBy, and the carryover must grade that
  # the same way the fresh-thread path does.
  local resolved_by=""
  if [ -n "${4:-}" ]; then
    resolved_by="$(printf '"resolvedBy":{"login":"%s"},' "$4")"
  fi
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":%s,%s"comments":{"nodes":[{"body":"🟡 **Important — REBASE WARNING [%s]** PR deletes recent main work","author":{"login":"%s"}}]}}]}}}}}' \
    "$1" "$resolved_by" "$2" "$3"
}

@test "guard8 carryover: prior head RESOLVED + identical warn_digest → approves without a new thread" {
  ri_report_d WARN "$DIG_A"                      # current head
  ri_report_d WARN "$DIG_A" "$PRIOR_OID"         # the acked head
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_THREADS_JSON="$(prior_thread true fedcba9 adk47)" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
  echo "$output" | grep -q 'carries forward'
}

@test "guard8 carryover: prior head resolved but DIFFERENT warn_digest → exit 10 (no inherited ack)" {
  ri_report_d WARN "$DIG_A"
  ri_report_d WARN "$DIG_B" "$PRIOR_OID"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_THREADS_JSON="$(prior_thread true fedcba9 adk47)" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8 carryover: identical digest but prior thread filed by a non-bot → exit 10 (forged ack)" {
  ri_report_d WARN "$DIG_A"
  ri_report_d WARN "$DIG_A" "$PRIOR_OID"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_THREADS_JSON="$(prior_thread true fedcba9 nsollazzo)" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8 carryover: identical digest but prior thread UNRESOLVED → blocked (Guard 7 first)" {
  ri_report_d WARN "$DIG_A"
  ri_report_d WARN "$DIG_A" "$PRIOR_OID"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_THREADS_JSON="$(prior_thread false fedcba9 adk47)" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 9 ]   # an unresolved 🟡 is Guard 7's to block; never an ack
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8 carryover: report predating the digest field (no warn_digest) → exit 10" {
  ri_report WARN                                  # legacy report, no warn_digest
  ri_report_d WARN "$DIG_A" "$PRIOR_OID"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_THREADS_JSON="$(prior_thread true fedcba9 adk47)" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8 carryover: no prior report at all → exit 10 (unchanged behaviour)" {
  ri_report_d WARN "$DIG_A"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 STUB_THREADS_JSON="$NO_THREADS" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

# --- carryover x staged independence rollout --------------------------------
# The carryover is the cheapest possible route around the independence rule: if
# a self-cleared ack carried forward, an author could self-resolve once on head
# A and ride it on every later head. These pin that the carried ack clears the
# SAME bar as a fresh one under each setting of the flag.

@test "guard8 carryover + INDEPENDENT=1: prior ack by an independent human → carries forward" {
  ri_report_d WARN "$DIG_A"
  ri_report_d WARN "$DIG_A" "$PRIOR_OID"
  QA_REBASE_ACK_REQUIRE_INDEPENDENT=1 STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_THREADS_JSON="$(prior_thread true fedcba9 adk47 aaronkaufman)" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
  echo "$output" | grep -q 'carries forward'
}

@test "guard8 carryover + INDEPENDENT=1: prior ack self-resolved by the PR AUTHOR → exit 10" {
  ri_report_d WARN "$DIG_A"
  ri_report_d WARN "$DIG_A" "$PRIOR_OID"
  QA_REBASE_ACK_REQUIRE_INDEPENDENT=1 STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_THREADS_JSON="$(prior_thread true fedcba9 adk47 nsollazzo)" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8 carryover + INDEPENDENT=1: prior ack resolved by the BOT → exit 10" {
  ri_report_d WARN "$DIG_A"
  ri_report_d WARN "$DIG_A" "$PRIOR_OID"
  QA_REBASE_ACK_REQUIRE_INDEPENDENT=1 STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_THREADS_JSON="$(prior_thread true fedcba9 adk47 adk47)" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8 carryover + INDEPENDENT=1: prior thread resolved with a NULL resolver → exit 10" {
  # No 4th arg ⇒ resolvedBy absent. Resolved-but-no-resolver is not an ack, and
  # it must not become one just because the ack is being carried rather than filed.
  ri_report_d WARN "$DIG_A"
  ri_report_d WARN "$DIG_A" "$PRIOR_OID"
  QA_REBASE_ACK_REQUIRE_INDEPENDENT=1 STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_THREADS_JSON="$(prior_thread true fedcba9 adk47)" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 10 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard8 carryover + INDEPENDENT=0: an author-resolved prior ack still carries (staged default)" {
  # Pins the rollout claim that the default is the PRE-independence behaviour:
  # the same fixture that exits 10 above must approve while the flag is off.
  # If this ever flips without the flag, the staged rollout has leaked.
  ri_report_d WARN "$DIG_A"
  ri_report_d WARN "$DIG_A" "$PRIOR_OID"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    STUB_THREADS_JSON="$(prior_thread true fedcba9 adk47 nsollazzo)" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}


# ---------------------------------------------------------------------------
# Guard 9 — blast radius (scripts/check-blast-radius.sh hand-off)
#
# SHIPPED DISABLED. The FIRST test below is the one that matters most for this
# change: with the flag at its default, behaviour must be byte-identical to
# before Guard 9 existed. Everything after it describes what happens once the
# follow-up sets QA_BLAST_RADIUS_GATE=1.
# ---------------------------------------------------------------------------

br_report() {  # <tier> [status] — well-formed per-head report Guard 9 keys on
  mkdir -p "$QA_BLAST_STATE_DIR"
  printf '{"repo":"Muso-AI/core-backend","pr":123,"head_sha":"%s","status":"%s","tier":"%s","signals":[{"id":"gate-edit","severity":"critical"}]}' \
    "$HEAD_OID" "${2:-OK}" "$1" \
    > "$QA_BLAST_STATE_DIR/Muso-AI__core-backend-pr-123-${HEAD_OID}.json"
}

br_report_raw() {  # <content> — raw bytes (malformed-JSON cases)
  mkdir -p "$QA_BLAST_STATE_DIR"
  printf '%s' "$1" > "$QA_BLAST_STATE_DIR/Muso-AI__core-backend-pr-123-${HEAD_OID}.json"
}

@test "guard9 INERT: flag unset + CRITICAL report → still approves (ships disabled)" {
  export QA_BLAST_STATE_DIR="$TEST_TMPDIR/br"
  br_report CRITICAL
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard9 INERT: flag unset + NO report at all → still approves" {
  export QA_BLAST_STATE_DIR="$TEST_TMPDIR/br-absent"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard9: enabled + CRITICAL → exit 13, never approves" {
  export QA_BLAST_STATE_DIR="$TEST_TMPDIR/br"
  br_report CRITICAL
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 QA_BLAST_RADIUS_GATE=1 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 13 ]
  if grep -q '^approve$' "$STUB_CALLS"; then echo "vacuous-negation guard: unexpected match" >&2; false; fi
  echo "$output" | grep -q 'blast radius is CRITICAL'
}

@test "guard9: enabled + CRITICAL names the critical signals in the refusal" {
  export QA_BLAST_STATE_DIR="$TEST_TMPDIR/br"
  br_report CRITICAL
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 QA_BLAST_RADIUS_GATE=1 \
    run "$SCRIPT" core-backend 123 "$NICK"
  echo "$output" | grep -q 'gate-edit'
}

@test "guard9: enabled + LOW → approves" {
  export QA_BLAST_STATE_DIR="$TEST_TMPDIR/br"
  br_report LOW
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 QA_BLAST_RADIUS_GATE=1 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard9: enabled + HIGH → approves (only CRITICAL holds)" {
  export QA_BLAST_STATE_DIR="$TEST_TMPDIR/br"
  br_report HIGH
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 QA_BLAST_RADIUS_GATE=1 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard9: enabled + missing report on a REQUIRED repo → exit 13 (fail closed)" {
  export QA_BLAST_STATE_DIR="$TEST_TMPDIR/br-absent"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 QA_BLAST_RADIUS_GATE=1 \
    QA_BLAST_REQUIRED_REPOS="core-backend" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 13 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard9: enabled + missing report on a NON-required repo → approves (no-data)" {
  # check-blast-radius.sh runs only in hydra's pr-validate.yml, but this script
  # approves every repo in the external allowlist. Without repo-gating, flipping
  # the flag would refuse EVERY core-backend approval on a report their CI never
  # writes. Guard 8 already carries exactly this list for the same reason.
  export QA_BLAST_STATE_DIR="$TEST_TMPDIR/br-absent"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 QA_BLAST_RADIUS_GATE=1 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard9: enabled + report whose interior .repo names a DIFFERENT repo → exit 13" {
  # Both report kinds share /var/lib/hydra-qa/ and the same filename key, so
  # .repo is the field that catches a cross-repo mis-file. Guard 8 checks it;
  # Guard 9's copy originally did not.
  export QA_BLAST_STATE_DIR="$TEST_TMPDIR/br"
  mkdir -p "$QA_BLAST_STATE_DIR"
  printf '{"repo":"Muso-AI/some-other-repo","pr":123,"head_sha":"%s","status":"OK","tier":"LOW","signals":[]}' \
    "$HEAD_OID" > "$QA_BLAST_STATE_DIR/Muso-AI__core-backend-pr-123-${HEAD_OID}.json"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 QA_BLAST_RADIUS_GATE=1 \
    QA_BLAST_REQUIRED_REPOS="core-backend" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 13 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard9: enabled + malformed JSON → exit 13 (fail closed)" {
  export QA_BLAST_STATE_DIR="$TEST_TMPDIR/br"
  br_report_raw 'this is not json'
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 QA_BLAST_RADIUS_GATE=1 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 13 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard9: enabled + status CLEAN → approves (the analyzer really emits CLEAN)" {
  # check-blast-radius.sh writes CLEAN when the diff is entirely generated paths.
  # Narrowing the case to OK) left every Guard 9 test green while a lockfile-only
  # hydra PR would refuse with "impact unverified".
  export QA_BLAST_STATE_DIR="$TEST_TMPDIR/br"
  br_report LOW CLEAN
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 QA_BLAST_RADIUS_GATE=1 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 0 ]
  grep -q '^approve$' "$STUB_CALLS"
}

@test "guard9: enabled + CRITICAL report with NO signals key → still exit 13" {
  # jq exits 5 on `[.signals[]]` over a null, and set -e killed the script before
  # die 13 — surfacing exit 5, which SKILL.md maps to "requester not authorized".
  export QA_BLAST_STATE_DIR="$TEST_TMPDIR/br"
  mkdir -p "$QA_BLAST_STATE_DIR"
  printf '{"repo":"Muso-AI/core-backend","pr":123,"head_sha":"%s","status":"OK","tier":"CRITICAL"}' \
    "$HEAD_OID" > "$QA_BLAST_STATE_DIR/Muso-AI__core-backend-pr-123-${HEAD_OID}.json"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 QA_BLAST_RADIUS_GATE=1 \
    QA_BLAST_REQUIRED_REPOS="core-backend" \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 13 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard9: enabled + status ERROR → exit 13 (impact unverified)" {
  export QA_BLAST_STATE_DIR="$TEST_TMPDIR/br"
  br_report UNKNOWN ERROR
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 QA_BLAST_RADIUS_GATE=1 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 13 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard9: enabled + interior head_sha mismatch → exit 13 (key-format drift)" {
  # A report whose FILENAME matches this head but whose body describes another.
  # Guard 8 carries the same cross-check for the same reason: without it, a key
  # convention change silently serves a stale report as if it were this head's.
  export QA_BLAST_STATE_DIR="$TEST_TMPDIR/br"
  mkdir -p "$QA_BLAST_STATE_DIR"
  printf '{"repo":"Muso-AI/core-backend","pr":123,"head_sha":"%s","status":"OK","tier":"LOW","signals":[]}' \
    "ffffffffffffffffffffffffffffffffffffffff" \
    > "$QA_BLAST_STATE_DIR/Muso-AI__core-backend-pr-123-${HEAD_OID}.json"
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 QA_BLAST_RADIUS_GATE=1 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 13 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}

@test "guard9: enabled + unrecognized tier → exit 13 (fail closed on the unknown)" {
  export QA_BLAST_STATE_DIR="$TEST_TMPDIR/br"
  br_report BANANAS
  STUB_ME="adk47" STUB_AUTHOR="nsollazzo" STUB_BAD_CHECKS=0 QA_BLAST_RADIUS_GATE=1 \
    run "$SCRIPT" core-backend 123 "$NICK"
  [ "$status" -eq 13 ]
  ! grep -q '^approve$' "$STUB_CALLS"
}
