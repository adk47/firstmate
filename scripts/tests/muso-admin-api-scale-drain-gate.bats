#!/usr/bin/env bats
# Contract tests for is_scale_drain_approval() in muso-admin-api.sh.
#
# The drain is an autonomous approver, so it must satisfy the approve gate's
# evidence requirement rather than skip it. This predicate is that requirement:
# it admits exactly one caller and it PARSES the evidence digest. The anchor
# clause is the part that broke in review: a precedent approve anchors on the
# precedent request id (a UUID) but a proof-verdict approve anchors on the proof
# id, which is a sha256 hex digest (scripts/credit_verify/proof/store.py:37),
# not a UUID. A UUID-only regex silently refused every proof-verdict approve.
#
# Both copies of the wrapper must behave identically, so every case runs against
# both.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CANONICAL="$REPO_ROOT/skills-all/muso-ops-admin/scripts/muso-admin-api.sh"
  WORKSPACE="$REPO_ROOT/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"
  for f in "$CANONICAL" "$WORKSPACE"; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; return 1; }
  done

  export MUSO_OPS_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export OPS_RUNLOG_DIR="$BATS_TEST_TMPDIR/runlogs"
  mkdir -p "$OPS_RUNLOG_DIR"
  export MUSO_API_URL="http://127.0.0.1:0/none"
  export MUSO_ADMIN_EMAIL="test@example.com"
  export MUSO_ADMIN_PASSWORD="x"
  # The predicate reads the registry to confirm the drain is a recorded decision - the
  # registry of ITS OWN tree, never one an environment variable names (QA review 5 of
  # hydra#1883). So these cases set neither variable; the registry is a copy of the real
  # one placed in the scratch tree, at the path the predicate derives ($REGISTRY below).
  unset CREDIT_APPROVAL_REGISTRY HYDRA_ROOT
  export SCALE_DRAIN=1
  export REQUESTER_EMAIL="scale-drain@hydra-ops"
  unset CV_APPROVE_GATE_DISABLED

  # The approve path DELEGATES the anchor to credit_review.verify_anchor.py, which
  # answers from the admin API / the proof store. These cases pin the predicate's own
  # job - parse, shape, delegate - so the verifier is stubbed to record its argv.
  #
  # The predicate derives the verifier from ITS OWN location (not from HYDRA_ROOT, which
  # is caller-controlled), so the stub lives in a mirrored tree at the repo layout.
  # $TREE is a plain shell variable of this file: nothing the predicate can read.
  TREE="$BATS_TEST_TMPDIR/root"
  mkdir -p "$TREE/scripts/credit_review" "$TREE/policies"
  REGISTRY="$TREE/policies/credit-approval-automation.json"
  cp "$REPO_ROOT/policies/credit-approval-automation.json" "$REGISTRY"
  VERIFIER_ARGV="$BATS_TEST_TMPDIR/verifier-argv"
  cat > "$TREE/scripts/credit_review/verify_anchor.py" <<'STUB'
import json, os, sys
open(os.environ["VERIFIER_ARGV"], "w").write(json.dumps(sys.argv[1:]))
sys.exit(int(os.environ.get("VERIFIER_RC", "0")))
STUB
  export VERIFIER_ARGV
  export VERIFIER_RC=0
  # The drain's one write, an approval, is gated on a token file at ONE pinned path,
  # /etc/hydra/scale-drain.token, and the wrapper REFUSES a SCALE_DRAIN_TOKEN_FILE
  # override (QA review 4 of hydra#1883: a caller-selected file proved only that the
  # caller could read back a file it had just written). So a test cannot aim the real text at a
  # scratch file through the environment - that seam was the hole. The cases that need a
  # token instead run a copy in which that ONE literal is rewritten to $TOKEN_FILE
  # (materialise's third argument). The pin and the refusal of an override are asserted
  # against the UNMODIFIED text, further down.
  PINNED_TOKEN_FILE="/etc/hydra/scale-drain.token"
  TOKEN_FILE="$BATS_TEST_TMPDIR/scale-drain.token"
  printf 's3cret\n' > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  unset SCALE_DRAIN_TOKEN_FILE
  export SCALE_DRAIN_TOKEN="s3cret"
  TOKEN_OK=pass

  BODY='{"requestIds":["11111111-1111-1111-1111-111111111111"],"status":"approved"}'
  UUID_ANCHOR="11111111-1111-1111-1111-111111111111"
  PROFILE_ID="33333333-3333-4333-8333-333333333333"
  # A real proof id: sha256 of the bytes, 64 lowercase hex chars.
  PROOF_ANCHOR="9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f"
}

# The wrapper runs its CLI dispatcher at the bottom of the file, so sourcing it
# whole would execute `help` and exit. Materialise the REAL predicate text (not a
# copy) in a mirrored tree at the wrapper's own relative path, so the predicate's
# ${BASH_SOURCE[0]} walk finds the stub verifier exactly as it finds the real one in
# production. Nothing here is overridable by an environment variable - that is the
# point of the walk (QA review 3 of hydra#1883).
#
# $3, when given, is the scratch token file: the pinned path literal is rewritten to it,
# and the rewrite is CHECKED, so a reworded pin fails here instead of leaving these cases
# quietly reading the host's /etc/hydra.
materialise() {
  local wrapper="$1" fn="$2" token="${3:-}" rel target
  rel="${wrapper#"$REPO_ROOT"/}"
  target="$TREE/$rel"
  mkdir -p "$(dirname "$target")"
  {
    sed -n '/^scale_drain_root() {$/,/^}$/p' "$wrapper"
    sed -n '/^scale_drain_registry() {$/,/^}$/p' "$wrapper"
    sed -n '/^scale_drain_token_ok() {$/,/^}$/p' "$wrapper"
    sed -n "/^${fn}() {$/,/^}$/p" "$wrapper"
    printf '%s PUT "$1" "$2"\n' "$fn"
  } > "$target"
  if [[ -n "$token" ]]; then
    sed -i "s#local drain_token_file=\"$PINNED_TOKEN_FILE\"#local drain_token_file=\"$token\"#" "$target"
    grep -qF "local drain_token_file=\"$token\"" "$target" || {
      echo "materialise: $wrapper no longer pins the token path as a literal" >&2; return 1; }
    ! grep -qF "$PINNED_TOKEN_FILE" "$target" || {
      echo "materialise: $wrapper still names $PINNED_TOKEN_FILE after the rewrite" >&2; return 1; }
  fi
  chmod 755 "$target"
  printf '%s' "$target"
}

# Run the predicate against both wrapper copies; both must agree.
check_both() {
  local excerpt="$1" expect="$2"
  local f script
  for f in "$CANONICAL" "$WORKSPACE"; do
    script="$(materialise "$f" is_scale_drain_approval "$TOKEN_FILE")"
    EVIDENCE_EXCERPT="$excerpt" run bash "$script" /admin/credit-requests "$BODY"
    if [[ "$expect" == "pass" ]]; then
      [ "$status" -eq 0 ] || { echo "$f refused: $output" >&2; return 1; }
    elif [[ "$expect" == "owner" ]]; then
      [ "$status" -ne 0 ] || { echo "$f accepted without a root-owned token" >&2; return 1; }
      [[ "$output" == *"must be mode 600 owned by the drain's user"* ]] || {
        echo "$f refused for the wrong reason: $output" >&2; return 1; }
    else
      [ "$status" -ne 0 ] || { echo "$f accepted a bad digest" >&2; return 1; }
    fi
  done
}

@test "accepts a precedent approve anchored on a request UUID" {
  check_both "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" pass
}

@test "accepts a proof-verdict approve anchored on a sha256 proof id" {
  check_both "drain-signal:proof_verdict;proof_verdict_approve;v1;$PROOF_ANCHOR;$PROFILE_ID" pass
}

@test "delegates the anchor to the verifier with the parsed parts" {
  check_both "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" pass
  local argv
  argv="$(cat "$VERIFIER_ARGV")"
  [[ "$argv" == *'"--rule", "precedent"'* ]] || { echo "rule not passed: $argv" >&2; return 1; }
  [[ "$argv" == *"$UUID_ANCHOR"* ]] || { echo "anchor not passed: $argv" >&2; return 1; }
  [[ "$argv" == *"$PROFILE_ID"* ]] || { echo "profile not passed: $argv" >&2; return 1; }
}

@test "refuses when the verifier refuses the anchor" {
  VERIFIER_RC=1 check_both "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" fail
}

@test "refuses when the verifier cannot run" {
  VERIFIER_RC=2 check_both "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" fail
}

@test "refuses when the verifier is missing" {
  local f script
  for f in "$CANONICAL" "$WORKSPACE"; do
    rm -f "$TREE/scripts/credit_review/verify_anchor.py"
    script="$(materialise "$f" is_scale_drain_approval "$TOKEN_FILE")"
    EVIDENCE_EXCERPT="drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" run bash "$script" /admin/credit-requests "$BODY"
    [ "$status" -ne 0 ] || { echo "$f approved with no verifier" >&2; return 1; }
    # The tree is located BY its verifier, and the registry is pinned to that tree, so a
    # tree with no verifier is refused one step before the verifier call itself.
    [[ "$output" == *"cannot be located"* ]] || { echo "$f refused for the wrong reason: $output" >&2; return 1; }
  done
}

@test "refuses a batch body on one anchor" {
  local f
  for f in "$CANONICAL" "$WORKSPACE"; do
    EVIDENCE_EXCERPT="drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" run bash -c '
      eval "$(sed -n "/^is_scale_drain_approval() {$/,/^}$/p" "$1")"
      is_scale_drain_approval PUT /admin/credit-requests "$2"
    ' _ "$f" '{"requestIds":["11111111-1111-1111-1111-111111111111","22222222-2222-2222-2222-222222222222"],"status":"approved"}'
    [ "$status" -ne 0 ] || { echo "$f accepted a batch on one anchor" >&2; return 1; }
  done
}

@test "refuses a digest with no anchor" {
  check_both "drain-signal:precedent;precedent_match;v1;" fail
}

@test "refuses a malformed anchor" {
  check_both "drain-signal:precedent;precedent_match;v1;not-an-anchor" fail
}

@test "refuses a truncated proof id" {
  check_both "drain-signal:proof_verdict;proof_verdict_approve;v1;${PROOF_ANCHOR:0:32}" fail
}

@test "refuses a rule the ladder cannot approve on evidence" {
  check_both "drain-signal:ask;no_rule_matched;v1;$UUID_ANCHOR" fail
}

@test "refuses when the drain is not the requester" {
  export REQUESTER_EMAIL="someone-else@hydra-ops"
  check_both "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" fail
}

@test "refuses when SCALE_DRAIN is not set" {
  unset SCALE_DRAIN
  check_both "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" fail
}

@test "refuses when the registry entry is not approved" {
  unapprove_deployed_registry
  check_both "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" fail
}

# ── the registry is the deployed one, and a caller cannot name another ───────

# Flip the drain to approved:false in the registry of the tree the predicate lives in.
unapprove_deployed_registry() {
  python3 - "$REGISTRY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["automations"]["verification-scale-drain"]["approved"] = False
json.dump(d, open(sys.argv[1], "w"))
PY
}

# Run one predicate in both copies with extra environment; every run must be refused
# with $want in the output and must not reach the verifier.
denied_both() {
  local fn="$1" path="$2" body="$3" excerpt="$4" want="$5"; shift 5
  local f script
  for f in "$CANONICAL" "$WORKSPACE"; do
    rm -f "$VERIFIER_ARGV"
    script="$(materialise "$f" "$fn" "$TOKEN_FILE")"
    run env "$@" EVIDENCE_EXCERPT="$excerpt" bash "$script" "$path" "$body"
    [ "$status" -ne 0 ] || { echo "$f ($fn) accepted: $*" >&2; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "$f ($fn) refused for the wrong reason: $output" >&2; return 1; }
    [[ ! -e "$VERIFIER_ARGV" ]] || { echo "$f ($fn) reached the verifier: $*" >&2; return 1; }
  done
}

@test "a caller-supplied CREDIT_APPROVAL_REGISTRY is DENIED (the attack)" {
  # The deployed registry has NOT authorised the drain; the caller brings a registry
  # that says it has. Honouring it would approve on the caller's own word.
  local mine="$BATS_TEST_TMPDIR/mine.json"
  cp "$REGISTRY" "$mine"
  unapprove_deployed_registry
  denied_both is_scale_drain_approval /admin/credit-requests "$BODY" \
    "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" \
    "cannot be redirected" CREDIT_APPROVAL_REGISTRY="$mine"
}

@test "a caller-supplied HYDRA_ROOT is DENIED as a registry source" {
  local mine="$BATS_TEST_TMPDIR/their-root"
  mkdir -p "$mine/policies"
  cp "$REGISTRY" "$mine/policies/credit-approval-automation.json"
  unapprove_deployed_registry
  denied_both is_scale_drain_approval /admin/credit-requests "$BODY" \
    "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" \
    "cannot be redirected" HYDRA_ROOT="$mine"
}

@test "a registry override is DENIED even when the deployed registry approves" {
  # Denied, not ignored: the deployed registry says yes here, so a predicate that simply
  # read the pinned file and disregarded the variable would let this through.
  local mine="$BATS_TEST_TMPDIR/mine.json"
  cp "$REGISTRY" "$mine"
  check_both "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" pass
  denied_both is_scale_drain_approval /admin/credit-requests "$BODY" \
    "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" \
    "cannot be redirected" CREDIT_APPROVAL_REGISTRY="$mine"
}

@test "the deployed registry named explicitly is not a redirect" {
  # The operations wrapper defaults CREDIT_APPROVAL_REGISTRY at file scope for its other
  # predicates, and a host may export HYDRA_ROOT; a value that IS the pinned file is let
  # through, by any spelling of its path.
  local f script link="$BATS_TEST_TMPDIR/link-to-tree"
  ln -s "$TREE" "$link"
  for f in "$CANONICAL" "$WORKSPACE"; do
    script="$(materialise "$f" is_scale_drain_approval "$TOKEN_FILE")"
    for setting in "CREDIT_APPROVAL_REGISTRY=$REGISTRY" "HYDRA_ROOT=$TREE" \
                   "CREDIT_APPROVAL_REGISTRY=$link/policies/credit-approval-automation.json"; do
      run env "$setting" EVIDENCE_EXCERPT="drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" \
        bash "$script" /admin/credit-requests "$BODY"
      [ "$status" -eq 0 ] || { echo "$f refused $setting: $output" >&2; return 1; }
    done
  done
}

@test "the approval does not take the registry path from the environment" {
  local f fn body
  for f in "$CANONICAL" "$WORKSPACE"; do
    for fn in is_scale_drain_approval; do
      body="$(sed -n "/^${fn}() {\$/,/^}\$/p" "$f")"
      [[ -n "$body" ]] || { echo "$f: $fn not found" >&2; return 1; }
      ! grep -qE 'CREDIT_APPROVAL_REGISTRY|HYDRA_ROOT' <<<"$body" || {
        echo "$f: $fn reads a registry variable itself" >&2; return 1; }
      [ "$(grep -c 'registry="\$(scale_drain_registry)"' <<<"$body")" -eq 1 ] || {
        echo "$f: $fn does not take the registry from scale_drain_registry" >&2; return 1; }
    done
  done
}

@test "a symlink to the wrapper does not move the tree it trusts" {
  # A caller cannot edit the deployed tree, but it can make a symlink to the wrapper
  # inside a tree of its own - with its own verifier and its own registry beside it.
  local f script theirs="$BATS_TEST_TMPDIR/theirs" rel marker="$BATS_TEST_TMPDIR/their-verifier-ran"
  for f in "$CANONICAL" "$WORKSPACE"; do
    rm -rf "$theirs"; rm -f "$marker" "$VERIFIER_ARGV"
    script="$(materialise "$f" is_scale_drain_approval "$TOKEN_FILE")"
    rel="${f#"$REPO_ROOT"/}"
    mkdir -p "$theirs/$(dirname "$rel")" "$theirs/scripts/credit_review" "$theirs/policies"
    ln -s "$script" "$theirs/$rel"
    cp "$REGISTRY" "$theirs/policies/credit-approval-automation.json"
    printf 'open(%s, "w").close()\n' "\"$marker\"" > "$theirs/scripts/credit_review/verify_anchor.py"
    unapprove_deployed_registry
    EVIDENCE_EXCERPT="drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" \
      run bash "$theirs/$rel" /admin/credit-requests "$BODY"
    [ "$status" -ne 0 ] || { echo "$f approved from the caller's tree" >&2; return 1; }
    [[ "$output" == *"is not approved in $REGISTRY"* ]] || {
      echo "$f refused for the wrong reason: $output" >&2; return 1; }
    [[ ! -e "$marker" ]] || { echo "$f ran the caller's verifier" >&2; return 1; }
    cp "$REPO_ROOT/policies/credit-approval-automation.json" "$REGISTRY"
  done
}

# ── an approval presents the drain's identity too ───────────────────────────

@test "approve: a caller's own token is DENIED against the real pinned path" {
  # The unmodified text and an approve the verifier would pass. The caller holds nothing
  # at $PINNED_TOKEN_FILE, so the approval is refused before the verifier is asked.
  [[ ! -e "$PINNED_TOKEN_FILE" ]] || skip "$PINNED_TOKEN_FILE exists on this host"
  local f script
  for f in "$CANONICAL" "$WORKSPACE"; do
    script="$(materialise "$f" is_scale_drain_approval)"
    SCALE_DRAIN_TOKEN="attacker-chosen" \
      EVIDENCE_EXCERPT="drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" \
      run bash "$script" /admin/credit-requests "$BODY"
    [ "$status" -ne 0 ] || { echo "$f approved with no pinned token" >&2; return 1; }
    [[ "$output" == *"$PINNED_TOKEN_FILE is missing"*"an approval needs"* ]] || {
      echo "$f refused for the wrong reason: $output" >&2; return 1; }
    [[ ! -e "$VERIFIER_ARGV" ]] || { echo "$f reached the verifier with no token" >&2; return 1; }
  done
}

@test "approve: a caller-supplied SCALE_DRAIN_TOKEN_FILE is DENIED" {
  local forged="$BATS_TEST_TMPDIR/forged.token"
  printf 'forged\n' > "$forged"
  chmod 600 "$forged"
  # ...on its own file, on the very file the copy trusts, and when empty
  denied_both is_scale_drain_approval /admin/credit-requests "$BODY" \
    "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" \
    "cannot be redirected" SCALE_DRAIN_TOKEN_FILE="$forged" SCALE_DRAIN_TOKEN=forged
  denied_both is_scale_drain_approval /admin/credit-requests "$BODY" \
    "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" \
    "cannot be redirected" SCALE_DRAIN_TOKEN_FILE="$TOKEN_FILE"
  denied_both is_scale_drain_approval /admin/credit-requests "$BODY" \
    "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" \
    "cannot be redirected" SCALE_DRAIN_TOKEN_FILE=
}

@test "approve: a caller-supplied SCALE_DRAIN_TOKEN is DENIED" {
  local value
  for value in "attacker-chosen" "s3cret " "S3CRET" ""; do
    denied_both is_scale_drain_approval /admin/credit-requests "$BODY" \
      "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" \
      "SCALE_DRAIN_TOKEN does not match" SCALE_DRAIN_TOKEN="$value"
  done
}

@test "approve: an unset SCALE_DRAIN_TOKEN is refused" {
  denied_both is_scale_drain_approval /admin/credit-requests "$BODY" \
    "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" \
    "SCALE_DRAIN_TOKEN does not match" -u SCALE_DRAIN_TOKEN
}

@test "approve: a token file readable by others is refused" {
  chmod 644 "$TOKEN_FILE"
  denied_both is_scale_drain_approval /admin/credit-requests "$BODY" \
    "drain-signal:precedent;precedent_match;v1;$UUID_ANCHOR;$PROFILE_ID" \
    "must be mode 600"
}

# ── the token source is pinned: an override is DENIED, not merely ignored ────
#
# QA review 4 of hydra#1883. These run in two forms on purpose. Against the UNMODIFIED
# text they are the attack as a caller would mount it. Against the copy with a valid
# scratch token they prove the refusal is the override's doing: the same call passes one
# line earlier, so "ignored" and "denied" cannot be confused.

APPROVE_DIGEST_PARTS="drain-signal:precedent;precedent_match;v1"

@test "the wrapper pins the token path once and reads it from no variable" {
  local f body
  for f in "$CANONICAL" "$WORKSPACE"; do
    body="$(sed -n '/^scale_drain_token_ok() {$/,/^}$/p' "$f")"
    [[ "$body" == *"local drain_token_file=\"$PINNED_TOKEN_FILE\""* ]] || {
      echo "$f does not pin the token path to $PINNED_TOKEN_FILE" >&2; return 1; }
    [ "$(grep -c 'drain_token_file=' "$f")" -eq 1 ] || {
      echo "$f assigns the token path more than once" >&2; return 1; }
    ! grep -qE 'drain_token_file=.*\$' "$f" || {
      echo "$f derives the token path from a variable" >&2; return 1; }
    # the approval goes through that one check
    [ "$(sed -n '/^is_scale_drain_approval() {$/,/^}$/p' "$f" | grep -c '^    scale_drain_token_ok ".*" || return 1$')" -eq 1 ] || {
      echo "$f: is_scale_drain_approval does not require the token" >&2; return 1; }
  done
}

@test "approve: refuses when the token file is missing" {
  local f script
  for f in "$CANONICAL" "$WORKSPACE"; do
    rm -f "$VERIFIER_ARGV"
    script="$(materialise "$f" is_scale_drain_approval "$BATS_TEST_TMPDIR/absent.token")"
    EVIDENCE_EXCERPT="$APPROVE_DIGEST_PARTS;$UUID_ANCHOR;$PROFILE_ID" run bash "$script" /admin/credit-requests "$BODY"
    [ "$status" -ne 0 ] || { echo "$f approved with no token file" >&2; return 1; }
    [[ "$output" == *"root-only token"* ]] || { echo "$f refused for the wrong reason: $output" >&2; return 1; }
    [[ ! -e "$VERIFIER_ARGV" ]] || { echo "$f reached the verifier with no token file" >&2; return 1; }
  done
}

@test "approve: a caller-supplied SCALE_DRAIN_TOKEN_FILE is DENIED against the unmodified text (the attack)" {
  # The caller writes its own mode-600 file and presents its contents back: every check
  # the old gate made is satisfied, by a caller who holds no protected identity at all.
  local f script forged="$BATS_TEST_TMPDIR/forged.token"
  printf 'forged\n' > "$forged"
  chmod 600 "$forged"
  for f in "$CANONICAL" "$WORKSPACE"; do
    rm -f "$VERIFIER_ARGV"
    script="$(materialise "$f" is_scale_drain_approval)"
    SCALE_DRAIN_TOKEN_FILE="$forged" SCALE_DRAIN_TOKEN="forged" \
      EVIDENCE_EXCERPT="$APPROVE_DIGEST_PARTS;$UUID_ANCHOR;$PROFILE_ID" \
      run bash "$script" /admin/credit-requests "$BODY"
    [ "$status" -ne 0 ] || { echo "$f approved on a caller-selected token file" >&2; return 1; }
    [[ "$output" == *"SCALE_DRAIN_TOKEN_FILE is set"*"cannot be redirected"* ]] || {
      echo "$f refused for the wrong reason: $output" >&2; return 1; }
    [[ ! -e "$VERIFIER_ARGV" ]] || { echo "$f reached the verifier on a forged token" >&2; return 1; }
  done
}

@test "approve: a caller-supplied SCALE_DRAIN_TOKEN_FILE is DENIED even beside a valid token" {
  local f script
  for f in "$CANONICAL" "$WORKSPACE"; do
    script="$(materialise "$f" is_scale_drain_approval "$TOKEN_FILE")"
    # the control: this exact call is accepted...
    EVIDENCE_EXCERPT="$APPROVE_DIGEST_PARTS;$UUID_ANCHOR;$PROFILE_ID" \
      run bash "$script" /admin/credit-requests "$BODY"
    [ "$status" -eq 0 ] || { echo "$f refused the control: $output" >&2; return 1; }
    # ...and setting the variable is the ONLY difference, even to the very same file.
    rm -f "$VERIFIER_ARGV"
    SCALE_DRAIN_TOKEN_FILE="$TOKEN_FILE" \
      EVIDENCE_EXCERPT="$APPROVE_DIGEST_PARTS;$UUID_ANCHOR;$PROFILE_ID" \
      run bash "$script" /admin/credit-requests "$BODY"
    [ "$status" -ne 0 ] || { echo "$f ignored SCALE_DRAIN_TOKEN_FILE instead of refusing it" >&2; return 1; }
    [[ "$output" == *"SCALE_DRAIN_TOKEN_FILE is set"*"cannot be redirected"* ]] || {
      echo "$f refused for the wrong reason: $output" >&2; return 1; }
    [[ ! -e "$VERIFIER_ARGV" ]] || { echo "$f reached the verifier with the override set" >&2; return 1; }
  done
}

# ── the drain writes no `rejected`: there is no duplicate close ──────────────
#
# The drain used to close a duplicate of a decided request as `rejected` through a
# predicate of its own. core sends its rejection notice on every move to `rejected`
# and the closed row was read back as a refusal of the claim, so that write is gone.
# These cases hold the REAL reject gate, sourced whole from each wrapper: the drain's
# full identity (requester, SCALE_DRAIN, the digest the old predicate accepted) buys
# nothing, on either route the old close could have taken.

DUP_DIGEST_PARTS="drain-dup"

# The whole wrapper, copied into the scratch tree (stub verifier that says yes, the
# registry that approves the drain) with the pinned token literal rewritten to the
# scratch token. Everything the old predicate asked for is therefore PRESENT and valid:
# a refusal here is the gate's, not a missing token's or a failed verification's.
whole_wrapper_with_token() {
  local wrapper="$1" rel target
  rel="${wrapper#"$REPO_ROOT"/}"
  target="$TREE/$rel"
  mkdir -p "$(dirname "$target")"
  cp "$wrapper" "$target"
  sed -i "s#local drain_token_file=\"$PINNED_TOKEN_FILE\"#local drain_token_file=\"$TOKEN_FILE\"#" "$target"
  grep -qF "local drain_token_file=\"$TOKEN_FILE\"" "$target" || {
    echo "whole_wrapper_with_token: $wrapper no longer pins the token path as a literal" >&2; return 1; }
  printf '%s' "$target"
}

drain_reject_refused() {
  # $1 = wrapper, $2 = path, $3 = body. The wrapper is sourced whole, in its own shell.
  local wrapper="$1" path="$2" body="$3" audit="$BATS_TEST_TMPDIR/reject-audit.jsonl" script
  script="$(whole_wrapper_with_token "$wrapper")"
  rm -f "$audit" "$VERIFIER_ARGV"
  # The wrapper clears the requester and the evidence at file scope (they are CLI
  # flags), so they are set AFTER the source, as its own flag parsing would leave them.
  run env -u CONFIRMED_BY -u APPROVAL_MSG_ID \
    SCALE_DRAIN=1 SCALE_DRAIN_TOKEN=s3cret CREDIT_REJECT_AUDIT_PATH="$audit" \
    DRAIN_DIGEST="$DUP_DIGEST_PARTS:$UUID_ANCHOR;duplicate_of_decided;v1;$PROFILE_ID" \
    bash -c 'source "$1"
             REQUESTER_EMAIL="scale-drain@hydra-ops"; EVIDENCE_EXCERPT="$DRAIN_DIGEST"
             CONFIRMED_BY=""; APPROVAL_MSG_ID=""
             enforce_credit_reject_gate PUT "$2" "$3"' _ "$script" "$path" "$body"
  [ "$status" -ne 0 ] || { echo "$wrapper let the drain reject on $path" >&2; return 1; }
  [[ "$output" == *"MUSO_CREDIT_REJECT_APPROVAL_REQUIRED"* ]] || {
    echo "$wrapper refused for the wrong reason: $output" >&2; return 1; }
  [[ ! -e "$audit" ]] || { echo "$wrapper audited a drain reject as allowed: $(cat "$audit")" >&2; return 1; }
  [[ ! -e "$VERIFIER_ARGV" ]] || { echo "$wrapper asked the verifier about a reject" >&2; return 1; }
}

@test "a rejected body from the drain's identity is refused by the reject gate" {
  local f path
  local one='{"expectedStatus":"user_verification_needed","requestIds":["11111111-1111-1111-1111-111111111111"],"status":"rejected"}'
  local plain='{"requestIds":["11111111-1111-1111-1111-111111111111"],"status":"rejected"}'
  for f in "$CANONICAL" "$WORKSPACE"; do
    for path in /admin/credit-requests/conditional-status /admin/credit-requests; do
      drain_reject_refused "$f" "$path" "$one"
      drain_reject_refused "$f" "$path" "$plain"
    done
  done
}

@test "no wrapper defines a duplicate-close predicate" {
  local f names
  for f in "$CANONICAL" "$WORKSPACE"; do
    names="$(bash -c 'source "$1"; declare -F' _ "$f" | awk '{print $3}')"
    grep -qx 'is_scale_drain_approval' <<<"$names" || { echo "$f: the approval predicate is gone" >&2; return 1; }
    ! grep -qi 'duplicate' <<<"$names" || {
      echo "$f still defines: $(grep -i duplicate <<<"$names")" >&2; return 1; }
  done
}
