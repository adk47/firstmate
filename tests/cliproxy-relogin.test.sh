#!/usr/bin/env bash
# tests/cliproxy-relogin.test.sh - the re-login helper hands one account each to
# its owner: it mints a real approval URL through a pseudo-terminal (the Claude
# CLI prints nothing without one), holds that sign-in open, finishes it with the
# owner's pasted code, writes the credential without ever printing the token,
# verifies the account with one real request, archives the superseded 30-day
# credential, and records the login date the expiry alarm measures.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/cliproxy-relogin.sh"
TMP_ROOT=$(fm_test_tmproot cliproxy-relogin)
FIXTURE_TOKEN='sk-ant-oat01-fixtureTOKEN123'
NEXT_YEAR=$(date -u -d '+1 year' +%Y 2>/dev/null || date -u -v+1y +%Y)
TODAY=$(date -u +%Y-%m-%d)

home() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/auth" "$dir/config" "$dir/archive" "$dir/fakebin" "$dir/log"
  # The Claude CLI refuses to run outside a terminal, so the fixture asserts the
  # terminal too: a helper that pipes this process cannot pass this suite.
  cat > "$dir/fakebin/claude" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/log/claude"
if [ ! -t 1 ]; then
  printf '%s\n' 'setup-token needs a terminal' >&2
  exit 3
fi
printf '%s\n' 'Browser did not open. Open this URL to approve:'
printf '%s\n' 'https://claude.ai/oauth/authorize?code=fixture123&state=fixture'
tries=0
while [ "\$tries" -lt 3 ]; do
  printf '%s\n' 'Paste the code shown after approving:'
  if ! IFS= read -r line; then exit 1; fi
  case "\$line" in
    CODE-WRONG*) printf '%s\n' 'That code is not from this sign-in.' ;;
    *)
      printf '%s\n' 'Long-lived token created'
      printf '%s\n' '$FIXTURE_TOKEN'
      exit 0
      ;;
  esac
  tries=\$((tries + 1))
done
exit 1
SH
  chmod 0755 "$dir/fakebin/claude"
  cat > "$dir/fakebin/curl" <<SH
#!/usr/bin/env bash
out=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) out=\$2; shift 2 ;;
    -w) shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' '{"error":"fixture"}' > "\${out:-/dev/null}"
printf '%s' "\${CURL_CODE:-200}"
SH
  chmod 0755 "$dir/fakebin/curl"
  cat > "$dir/fakebin/dm.sh" <<SH
#!/usr/bin/env bash
{ printf 'TARGET=%s\n' "\$1"; cat; printf '%s\n' '---'; } >> "$dir/log/dm"
SH
  chmod 0755 "$dir/fakebin/dm.sh"
  cat > "$dir/config/cliproxy-login-registry.json" <<'SH'
{"_note":"human login date per Claude account","a@x.com":"2026-10-21","b@y.com":"2026-10-21"}
SH
  cat > "$dir/config/cliproxy-accounts.json" <<'SH'
{"a@x.com":{"owner":"aaron","dm":"aaron"},"b@y.com":{"owner":"steve","dm":"steve"}}
SH
  printf '%s\n' "$dir"
}

seed_oauth() {  # <dir>
  printf '%s\n' '{"email":"a@x.com","last_refresh":"2026-11-04T10:00:00Z","expired":"2026-11-04T18:00:00Z","refresh_token":"r-a"}' \
    > "$1/auth/claude-1111-a@x.com.json"
  printf '%s\n' '{"email":"b@y.com","last_refresh":"2026-11-04T10:00:00Z","expired":"2026-11-04T18:00:00Z","refresh_token":"r-b"}' \
    > "$1/auth/claude-2222-b@y.com.json"
}

run_helper() {  # <dir> [args...]
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" \
    FM_CLIPROXY_ARCHIVE_ROOT="$dir/archive" \
    FM_CLIPROXY_AUTH_DIR="$dir/auth" \
    FM_CLIPROXY_LOGIN_REGISTRY="$dir/config/cliproxy-login-registry.json" \
    FM_CLIPROXY_OWNER_MAP="$dir/config/cliproxy-accounts.json" \
    FM_CLIPROXY_CLAUDE_BIN="$dir/fakebin/claude" \
    FM_CLIPROXY_DM_CMD="$dir/fakebin/dm.sh" \
    CLIPROXY_API_KEY=fixture-key \
    FM_CLIPROXY_CONFIG="$dir/config/cliproxyapi.yaml" \
    "$HELPER" "$@"
}

registry_date() {  # <dir> <email>
  python3 - "$1/config/cliproxy-login-registry.json" "$2" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    print(json.load(handle).get(sys.argv[2], ""))
PY
}

kill_sessions() {  # <dir>: stop any handoff this suite left open
  local dir=$1
  pkill -f "cliproxy-setup-token-session.py --dir $dir/state/cliproxy-relogin/" 2>/dev/null || true
}

field() {  # <dir> <email> <field>
  local slug=${2//[^A-Za-z0-9.@_-]/-}
  head -1 -- "$1/state/cliproxy-relogin/$slug/$3" 2>/dev/null
}

# --- start hands each account to its own owner ------------------------------

DIR=$(home start)
seed_oauth "$DIR"
out=$(run_helper "$DIR" start --timeout 120 2>&1) || fail "start must mint a URL per account: $out"
assert_contains "$out" "https://claude.ai/oauth/authorize?code=fixture123" "a real approval URL is printed"
assert_contains "$out" "Claude pool re-login for aaron" "Aaron's handoff is addressed to him"
assert_contains "$out" "Claude pool re-login for steve" "the staff account's handoff is addressed to its owner"
assert_contains "$out" "Account: a@x.com" "the handoff names the account"
assert_contains "$out" "sent the aaron handoff to aaron" "the owner is DMed when a transport is configured"
assert_contains "$out" "sent the steve handoff to steve" "each owner is DMed separately"
assert_not_contains "$out" "$FIXTURE_TOKEN" "no token is printed"
[ "$(field "$DIR" a@x.com status)" = waiting ] || fail "the first account must be waiting for its code"
[ "$(field "$DIR" b@y.com status)" = waiting ] || fail "the second account must be waiting for its code"
assert_present "$DIR/state/cliproxy-relogin/a@x.com/url" "the account's URL is kept for a resend"
# Each owner's DM names only that owner's accounts.
dm_aaron=$(awk '/TARGET=aaron/,/^---$/' "$DIR/log/dm")
dm_steve=$(awk '/TARGET=steve/,/^---$/' "$DIR/log/dm")
assert_contains "$dm_aaron" "a@x.com" "Aaron's DM names his account"
assert_not_contains "$dm_aaron" "b@y.com" "Aaron's DM never names someone else's account"
assert_contains "$dm_steve" "b@y.com" "Steve's DM names his account"
assert_not_contains "$dm_steve" "a@x.com" "Steve's DM never names someone else's account"
assert_not_contains "$(cat "$DIR/log/dm")" "$FIXTURE_TOKEN" "no DM carries a token"
pass "start mints one URL per account and hands each to its owner"

# --- status tracks completion per account ----------------------------------

out=$(run_helper "$DIR" status 2>&1) || fail "status must run: $out"
assert_contains "$out" "waiting" "status reports the open handoffs"
assert_contains "$out" "a@x.com" "status lists every account"
assert_contains "$out" "steve" "status names each owner"
pass "status tracks each account separately"

# --- submit finishes one account, verified, archived, recorded -------------

out=$(run_helper "$DIR" submit a@x.com CODE-GOOD 2>&1) || fail "submit must finish a verified account: $out"
assert_contains "$out" "verification request answered 200" "the account is verified with one real request"
assert_contains "$out" "complete" "the account reports complete"
assert_not_contains "$out" "$FIXTURE_TOKEN" "submitting never prints the token"
assert_contains "$out" "archived the superseded credential" "the 30-day credential is archived"
credential="$DIR/auth/claude-setup-a@x.com.json"
assert_present "$credential" "the credential is written"
mode=$(stat -c %a "$credential" 2>/dev/null || stat -f %Lp "$credential" 2>/dev/null)
[ "$mode" = 600 ] || fail "the credential must be mode 600, got $mode"
body=$(cat "$credential")
assert_contains "$body" '"is_setup_token": true' "the credential is marked a setup token"
assert_contains "$body" "\"expired\": \"$NEXT_YEAR" "the credential expires in one year"
assert_not_contains "$body" 'refresh_token' "the credential carries no refresh token"
assert_present "$DIR/archive/$(date -u +%Y-%m-%d)/claude-1111-a@x.com.json" \
  "the superseded credential is archived rather than deleted"
assert_absent "$DIR/auth/claude-1111-a@x.com.json" "the superseded credential leaves the auth dir"
[ "$(registry_date "$DIR" a@x.com)" = "$TODAY" ] || fail "the login date is recorded for the finished account"
[ "$(registry_date "$DIR" b@y.com)" = 2026-10-21 ] || fail "the other account's login date is untouched"
assert_absent "$DIR/state/cliproxy-relogin/a@x.com/token" "the token file is consumed"
pass "submit writes, verifies, archives, and records one account"

# --- a rejected code is retryable, and the wrong account state is harmless --

set +e
out=$(run_helper "$DIR" submit b@y.com CODE-WRONG-1 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail "a rejected code must not report success"
assert_contains "$out" "rejected that code" "the failure says the code was rejected, not that the session died"
assert_not_contains "$out" "$FIXTURE_TOKEN" "a rejected code prints no token"
assert_absent "$DIR/auth/claude-setup-b@y.com.json" "a rejected code writes no credential"
out=$(run_helper "$DIR" submit b@y.com CODE-GOOD 2>&1) || fail "a second code must be accepted: $out"
assert_contains "$out" "complete" "the retried account completes"
assert_present "$DIR/auth/claude-setup-b@y.com.json" "the retried credential is written"
pass "a rejected code stays retryable"

# --- verify re-checks a completed account without touching it ---------------

out=$(run_helper "$DIR" verify a@x.com 2>&1) || fail "verify must succeed for a good pool: $out"
assert_contains "$out" "answered 200" "verify sends one real request"
assert_present "$DIR/auth/claude-setup-a@x.com.json" "verify leaves the credential in place"
pass "verify re-checks one account"

# --- a second start leaves finished accounts alone -------------------------

out=$(run_helper "$DIR" start --accounts a@x.com,b@y.com --timeout 60 2>&1) \
  || fail "a second start must succeed: $out"
assert_contains "$out" "a@x.com: already complete" "a finished account is not re-minted"
assert_contains "$out" "b@y.com: already complete" "every finished account is left alone"
assert_present "$DIR/auth/claude-setup-a@x.com.json" "the finished credential stays in place"
pass "a second start leaves finished accounts alone"

# --- no client key is reported, and nothing is left in the pool -------------

DIR=$(home nokey)
seed_oauth "$DIR"
run_helper "$DIR" start --accounts a@x.com --timeout 120 >/dev/null 2>&1 \
  || fail "start must mint a URL"
set +e
out=$(env PATH="$DIR/fakebin:$PATH" FM_HOME="$DIR" \
  FM_CLIPROXY_ARCHIVE_ROOT="$DIR/archive" FM_CLIPROXY_AUTH_DIR="$DIR/auth" \
  FM_CLIPROXY_LOGIN_REGISTRY="$DIR/config/cliproxy-login-registry.json" \
  FM_CLIPROXY_OWNER_MAP="$DIR/config/cliproxy-accounts.json" \
  FM_CLIPROXY_CLAUDE_BIN="$DIR/fakebin/claude" FM_CLIPROXY_DM_CMD="$DIR/fakebin/dm.sh" \
  FM_CLIPROXY_CONFIG="$DIR/config/no-such-config.yaml" \
  "$HELPER" submit a@x.com CODE-GOOD 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail "a missing client key must not report success"
assert_contains "$out" "no client API key found" "a missing client key is named, not guessed"
assert_absent "$DIR/auth/claude-setup-a@x.com.json" "an unverifiable credential does not stay in the pool"
pass "a missing client key is reported and nothing is left in the pool"

# --- a failed verification archives the new credential, keeps the old one ---

DIR=$(home unverified)
seed_oauth "$DIR"
run_helper "$DIR" start --accounts a@x.com --timeout 120 >/dev/null 2>&1 \
  || fail "start must mint a URL"
set +e
out=$(CURL_CODE=401 run_helper "$DIR" submit a@x.com CODE-GOOD 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || fail "a failed verification must not report success"
assert_contains "$out" "did not pass one real request" "the failure names the verification"
assert_absent "$DIR/auth/claude-setup-a@x.com.json" "the unverified credential does not stay in the pool"
assert_present "$DIR/auth/claude-1111-a@x.com.json" "the working 30-day credential is untouched"
[ "$(registry_date "$DIR" a@x.com)" = 2026-10-21 ] || fail "an unverified account's login date is not recorded"
pass "a failed verification archives the new credential and keeps the old one"

# --- dry run and --no-dm change nothing ------------------------------------

DIR=$(home dry)
seed_oauth "$DIR"
out=$(run_helper "$DIR" start --dry-run --timeout 60 2>&1) || fail "a dry run must succeed: $out"
assert_contains "$out" "would start a setup-token session" "the dry run says what it would start"
assert_contains "$out" "would write: $DIR/auth/claude-setup-a@x.com.json" "the dry run names the credential"
assert_absent "$DIR/log/claude" "the dry run starts no sign-in"
assert_absent "$DIR/log/dm" "the dry run sends no DM"
assert_absent "$DIR/state/cliproxy-relogin" "the dry run opens no session"

out=$(run_helper "$DIR" start --no-dm --timeout 60 2>&1) || fail "--no-dm must still mint a URL: $out"
assert_contains "$out" "handoff was printed and not sent" "--no-dm says nothing was sent"
assert_absent "$DIR/log/dm" "--no-dm sends no DM"
kill_sessions "$DIR"
pass "dry run and --no-dm change nothing they should not"

# --- the Codex login is delegated to CLIProxyAPI itself --------------------

DIR=$(home codex)
cat > "$DIR/fakebin/fake-proxy" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DIR/log/codex"
SH
chmod 0755 "$DIR/fakebin/fake-proxy"
printf '%s\n' 'auth-dir: stub' > "$DIR/config/cliproxyapi.yaml"

out=$(env PATH="$DIR/fakebin:$PATH" FM_HOME="$DIR" FM_CLIPROXY_BIN="$DIR/fakebin/fake-proxy" \
  FM_CLIPROXY_CONFIG="$DIR/config/cliproxyapi.yaml" "$HELPER" add-codex --dry-run 2>&1) \
  || fail "a Codex dry run must succeed: $out"
assert_contains "$out" "-codex-login -no-browser -config $DIR/config/cliproxyapi.yaml" \
  "the Codex dry run names the exact command"
assert_absent "$DIR/log/codex" "the Codex dry run starts nothing"

out=$(env PATH="$DIR/fakebin:$PATH" FM_HOME="$DIR" FM_CLIPROXY_BIN="$DIR/fakebin/fake-proxy" \
  FM_CLIPROXY_CONFIG="$DIR/config/cliproxyapi.yaml" "$HELPER" add-codex 2>&1) \
  || fail "the Codex login must run: $out"
assert_contains "$(cat "$DIR/log/codex")" "-codex-login -no-browser -config $DIR/config/cliproxyapi.yaml" \
  "the Codex login hands the flow to CLIProxyAPI"
pass "the Codex login is delegated to CLIProxyAPI"

printf 'all cliproxy-relogin tests passed\n'
