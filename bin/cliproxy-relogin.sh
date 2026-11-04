#!/usr/bin/env bash
# cliproxy-relogin.sh - one re-login session for the CLIProxyAPI Claude pool,
# handed off per account to the person who owns that account, plus the Codex
# login.
#
# Usage:
#   cliproxy-relogin.sh start [--accounts a@x,b@y] [--dm|--no-dm]
#   cliproxy-relogin.sh urls                     print the pending handoffs by owner
#   cliproxy-relogin.sh status                   per-account completion, verification, credential
#   cliproxy-relogin.sh submit <email> <code>    finish one account with the owner's pasted code
#   cliproxy-relogin.sh verify <email>           re-run the one-request verification
#   cliproxy-relogin.sh add-codex                CLIProxyAPI's own Codex OAuth login
#   cliproxy-relogin.sh --dry-run <command>      print the plan and change nothing
#   cliproxy-relogin.sh --help                   print this help
#
# Common options:
#   --auth-dir DIR      credential directory (default ~/.cli-proxy-api)
#   --registry FILE     login-date registry (default <home>/config/cliproxy-login-registry.json)
#   --owner-map FILE    account -> owner and DM target (default <home>/config/cliproxy-accounts.json)
#   --state-dir DIR     session records (default <home>/state/cliproxy-relogin)
#   --proxy URL         proxy base URL for verification (default http://127.0.0.1:8317)
#   --probe-model ID    model for that verification request (default claude-haiku-4-5-20251001)
#   --api-key KEY       client key for verification; else the proxy config's first api-keys entry
#   --api-key-file FILE read that key from a file instead
#   --timeout SECS      how long a handed-off approval may stay open (default 259200, three days)
#
# WHY IT IS A HANDOFF AND NOT A WALK. Anthropic logins are human OAuth by design:
# the owner of each account has to approve it in a browser. The seven staff
# accounts therefore belong to seven people, and only Aaron's own three accounts
# and the Codex login belong to him. So `start` mints one approval URL per
# account, keeps that exact sign-in alive, and prints - or DMs - each owner their
# own URL; when the owner sends back the code their browser showed, `submit`
# feeds it to the sign-in that issued the URL, writes the credential, verifies
# that account, archives what it superseded, and records the login date the
# expiry alarm measures.
#
# WHY THE URL CANNOT JUST BE REGENERATED LATER. `claude setup-token` holds the
# OAuth state and PKCE verifier in its own process, so a code is only usable by
# the process that printed its URL. `start` therefore launches one supervisor per
# account through bin/cliproxy-setup-token-session.py, which gives the command a
# real pseudo-terminal (it refuses to run without one) and stays alive until the
# code arrives, the approval window closes, or the command fails. `status` says
# which sessions are still open, which is how completion is tracked per account.
# A session that expired is re-minted by `start --accounts <email>` alone.
#
# VERIFICATION. Every completed account gets exactly one real request through the
# proxy. The proxy routes round-robin and this deployment has no per-credential
# endpoint, so that request proves the proxy serves and the new credential did
# not break the pool; it cannot prove which account answered. A credential whose
# verification fails is archived instead of left in the pool, and its 30-day
# predecessor is left untouched.
#
# DELIVERY. `start` prints every handoff, and with FM_CLIPROXY_DM_CMD configured
# it also sends one message per owner: the command is invoked as
# `$FM_CLIPROXY_DM_CMD <dm-target>` with the message on standard input, bounded at
# 30 seconds, and a failure is reported rather than hidden. With no command
# configured nothing is sent and the run says so - it never claims a DM it did
# not send.
#
# THE OWNER MAP. config/cliproxy-accounts.json is local and gitignored:
#   {"steve@muso.ai": {"owner": "steve", "dm": "U0123ABCD"}}
# An account it does not name is handed to its own address, so a missing entry
# degrades to "told nobody in particular" rather than to silently skipping an
# account. The Codex login is always Aaron's.
#
# Environment:
#   FM_CLIPROXY_CLAUDE_BIN      the Claude Code CLI (default `claude`)
#   FM_CLIPROXY_BIN             CLIProxyAPI binary for the Codex login
#   FM_CLIPROXY_CONFIG          CLIProxyAPI config (default ~/.config/cliproxyapi/config.yaml)
#   FM_CLIPROXY_DM_CMD          DM transport for the handoff, e.g. a Slack bot wrapper
#   FM_CLIPROXY_AUTH_DIR, FM_CLIPROXY_ARCHIVE_ROOT, FM_CLIPROXY_LOGIN_REGISTRY, FM_CLIPROXY_OWNER_MAP
#
# Distribution note: it lives in bin/ as cliproxy-relogin.sh so it is part of the
# linted shell set (bin/*.sh). docs/scripts.md lists it.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE_HOME="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_HOME="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/cliproxy-creds-lib.sh
. "$SCRIPT_DIR/cliproxy-creds-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'cliproxy-relogin: %s\n' "$1" >&2
  exit 2
}

ACTION=
DRY_RUN=0
DM_MODE=auto
ACCOUNTS=
SUBMIT_EMAIL=
SUBMIT_CODE=
PROXY_URL=http://127.0.0.1:8317
PROBE_MODEL=${FM_CLIPROXY_PROBE_MODEL:-claude-haiku-4-5-20251001}
API_KEY=${CLIPROXY_API_KEY:-}
API_KEY_FILE=
TIMEOUT_SECS=${FM_CLIPROXY_TIMEOUT_SECS:-259200}

while [ "$#" -gt 0 ]; do
  case "$1" in
    start|urls|status|submit|verify|add-codex) ACTION=$1; shift ;;
    --add)
      [ "$#" -ge 2 ] || die "--add needs a provider"
      [ "$2" = codex ] || die "only --add codex is supported"
      ACTION=add-codex
      shift 2
      ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    --dm) DM_MODE=on; shift ;;
    --no-dm) DM_MODE=off; shift ;;
    --accounts) [ "$#" -ge 2 ] || die "--accounts needs a value"; ACCOUNTS=$2; shift 2 ;;
    --auth-dir) [ "$#" -ge 2 ] || die "--auth-dir needs a value"; FM_CLIPROXY_AUTH_DIR=$2; shift 2 ;;
    --registry) [ "$#" -ge 2 ] || die "--registry needs a value"; FM_CLIPROXY_LOGIN_REGISTRY=$2; shift 2 ;;
    --owner-map) [ "$#" -ge 2 ] || die "--owner-map needs a value"; FM_CLIPROXY_OWNER_MAP=$2; shift 2 ;;
    --state-dir) [ "$#" -ge 2 ] || die "--state-dir needs a value"; STATE_HOME=$2; shift 2 ;;
    --proxy) [ "$#" -ge 2 ] || die "--proxy needs a value"; PROXY_URL=${2%/}; shift 2 ;;
    --probe-model) [ "$#" -ge 2 ] || die "--probe-model needs a value"; PROBE_MODEL=$2; shift 2 ;;
    --api-key) [ "$#" -ge 2 ] || die "--api-key needs a value"; API_KEY=$2; shift 2 ;;
    --api-key-file) [ "$#" -ge 2 ] || die "--api-key-file needs a value"; API_KEY_FILE=$2; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || die "--timeout needs a value"; TIMEOUT_SECS=$2; shift 2 ;;
    -h|--help|help) usage; exit 0 ;;
    -*)
      die "unknown option: $1 (see --help)"
      ;;
    *)
      if [ -z "$SUBMIT_EMAIL" ]; then
        SUBMIT_EMAIL=$1
      elif [ -z "$SUBMIT_CODE" ]; then
        SUBMIT_CODE=$1
      else
        die "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[ -n "$ACTION" ] || { usage >&2; exit 2; }
case "$TIMEOUT_SECS" in ''|*[!0-9]*|0) die "--timeout must be a positive whole number of seconds" ;; esac
if [ "$ACTION" = add-codex ] && [ -z "$ACCOUNTS" ] && [ -z "$SUBMIT_EMAIL" ]; then
  :
elif [ "$ACTION" = submit ] && { [ -z "$SUBMIT_EMAIL" ] || [ -z "$SUBMIT_CODE" ]; }; then
  die "submit needs an account and the code from its owner"
elif [ "$ACTION" = verify ] && [ -z "$SUBMIT_EMAIL" ]; then
  die "verify needs an account"
fi

export FM_CLIPROXY_AUTH_DIR FM_CLIPROXY_LOGIN_REGISTRY

AUTH_DIR=$(cliproxy_auth_dir)
REGISTRY=$(cliproxy_login_registry)
OWNER_MAP=${FM_CLIPROXY_OWNER_MAP:-$CONFIG_HOME/cliproxy-accounts.json}
STATE_DIR=$STATE_HOME/cliproxy-relogin
CLAUDE_BIN=${FM_CLIPROXY_CLAUDE_BIN:-claude}
SUPERVISOR=$SCRIPT_DIR/cliproxy-setup-token-session.py
PROXY_CONFIG=${FM_CLIPROXY_CONFIG:-$HOME/.config/cliproxyapi/config.yaml}
PROXY_BIN=${FM_CLIPROXY_BIN:-}
if [ -z "$PROXY_BIN" ]; then
  if command -v cli-proxy-api >/dev/null 2>&1; then
    PROXY_BIN=cli-proxy-api
  else
    PROXY_BIN=$HOME/.local/bin/cli-proxy-api
  fi
fi
DM_CMD=${FM_CLIPROXY_DM_CMD:-}
TIMEOUT_BIN=$(command -v timeout 2>/dev/null || true)

say() { printf '%s\n' "$*"; }
session_dir() { printf '%s/%s\n' "$STATE_DIR" "$(cliproxy_email_slug "$1")"; }

# account_list: explicit --accounts in the given order, else the registry's own
# key order so the handoff walks the pool the way it was recorded.
account_list() {
  if [ -n "$ACCOUNTS" ]; then
    printf '%s\n' "$ACCOUNTS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
    return 0
  fi
  python3 - "$REGISTRY" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as handle:
        data = json.load(handle)
except (OSError, ValueError):
    data = {}
if not isinstance(data, dict):
    data = {}
for key in data:
    if not key.startswith("_"):
        print(key)
PY
}

# owner_of / dm_of: the account's owner and delivery target from the owner map,
# defaulting to the account address itself.
owner_map_field() {  # <email> <field>
  python3 - "$OWNER_MAP" "$1" "$2" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as handle:
        data = json.load(handle)
except (OSError, ValueError):
    data = {}
entry = data.get(sys.argv[2]) if isinstance(data, dict) else None
if isinstance(entry, dict):
    value = entry.get(sys.argv[3])
    if isinstance(value, str) and value.strip():
        print(value.strip())
        sys.exit(0)
if sys.argv[3] == "owner":
    print(sys.argv[2].split("@")[0])
PY
}

owner_of() { owner_map_field "$1" owner; }
dm_of() { local dm; dm=$(owner_map_field "$1" dm); printf '%s\n' "${dm:-$(owner_of "$1")}"; }

read_field() {  # <file> -> first line, empty when absent
  [ -f "$1" ] || return 0
  head -1 -- "$1" 2>/dev/null
}

# launch_session <email>: start one supervisor through a pty and wait for its URL.
launch_session() {
  local email=$1 dir owner
  dir=$(session_dir "$email")
  owner=$(owner_of "$email")
  if [ "$(read_field "$dir/status")" = complete ] && [ -f "$dir/credential" ]; then
    say "$email: already complete on $(read_field "$dir/completed"); 'verify $email' re-checks it"
    return 0
  fi
  if [ -f "$dir/url" ] && { [ "$(read_field "$dir/status")" = waiting ] || [ "$(read_field "$dir/status")" = submitted ]; }; then
    say "$email: a handoff is already open; run 'urls' to resend it"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    say "$email (owner $owner): would start a setup-token session and hand over its URL"
    say "  session dir: $dir"
    say "  would write: $(cliproxy_auth_dir)/claude-setup-$(cliproxy_email_slug "$email").json on approval"
    return 0
  fi
  rm -rf -- "$dir"
  (umask 077; mkdir -p "$dir") || return 1
  if command -v setsid >/dev/null 2>&1; then
    setsid python3 "$SUPERVISOR" --dir "$dir" --claude-bin "$CLAUDE_BIN" \
      --timeout-secs "$TIMEOUT_SECS" </dev/null >/dev/null 2>&1 &
  else
    nohup python3 "$SUPERVISOR" --dir "$dir" --claude-bin "$CLAUDE_BIN" \
      --timeout-secs "$TIMEOUT_SECS" </dev/null >/dev/null 2>&1 &
  fi
  local pid=$!
  disown "$pid" 2>/dev/null || true
  local waited=0
  while [ "$waited" -lt 60 ]; do
    if [ -f "$dir/url" ]; then
      say "$email (owner $owner): approval URL minted"
      return 0
    fi
    case "$(read_field "$dir/status")" in
      failed|expired)
        say "$email: the sign-in could not start; see $dir/log"
        return 1
        ;;
    esac
    sleep 1
    waited=$((waited + 1))
  done
  say "$email: no approval URL appeared within 60s; see $dir/log"
  return 1
}

# handoff_body <owner> <email...>: the message one owner receives.
handoff_body() {
  local owner=$1
  shift
  local email url
  say "Claude pool re-login for $owner"
  say ""
  for email in "$@"; do
    url=$(read_field "$(session_dir "$email")/url")
    say "Account: $email"
    say "Open this URL while signed in as $email:"
    say "  $url"
    say "Then send firstmate the code the page shows. It is good for one account only."
    say ""
  done
  say "The fleet's Claude pool needs each of these before Fri 14 Nov, or that account drops out of the pool."
}

# dm_send <target>: hand the message on stdin to the configured transport,
# bounded so a hung transport cannot hold the session. The command receives the
# delivery target as its first argument.
dm_send() {
  local target=$1
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" 30 sh -c "$DM_CMD \"\$1\"" _ "$target"
  else
    sh -c "$DM_CMD \"\$1\"" _ "$target"
  fi
}

# deliver <owner> <email...>: print the handoff and send it when a transport exists.
deliver() {
  local owner=$1 body target
  shift
  body=$(handoff_body "$owner" "$@")
  printf '%s\n' "$body"
  if [ "$DRY_RUN" = 1 ]; then
    return 0
  fi
  if [ "$DM_MODE" = off ] || [ -z "$DM_CMD" ]; then
    if [ "$DM_MODE" = off ]; then
      say "(delivery: --no-dm, so this handoff was printed and not sent)"
    else
      say "(delivery: no FM_CLIPROXY_DM_CMD configured, so this handoff was printed and not sent)"
    fi
    return 0
  fi
  target=$(dm_of "$1")
  if printf '%s\n' "$body" | dm_send "$target"; then
    say "(delivery: sent the $owner handoff to $target)"
  else
    say "(delivery: the DM command failed for $target, so this handoff is printed above and still unsent)"
  fi
}

action_start() {
  local email failed=0 started=()
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  command -v "$CLAUDE_BIN" >/dev/null 2>&1 || [ -x "$CLAUDE_BIN" ] \
    || die "$CLAUDE_BIN not found on PATH (set FM_CLIPROXY_CLAUDE_BIN)"
  [ -f "$SUPERVISOR" ] || die "session supervisor missing: $SUPERVISOR"
  local wanted=()
  while IFS= read -r email; do
    [ -n "$email" ] && wanted+=("$email")
  done < <(account_list)
  [ "${#wanted[@]}" -gt 0 ] || die "no accounts: $REGISTRY lists none, and no --accounts was given"

  local total=${#wanted[@]} index=0
  say "CLIProxyAPI pool re-login: $total account(s), auth dir $AUTH_DIR, sessions $STATE_DIR"
  for email in "${wanted[@]}"; do
    index=$((index + 1))
    say "[$index/$total] $email"
    launch_session "$email" || { failed=$((failed + 1)); continue; }
    started+=("$email")
  done
  [ "$DRY_RUN" = 1 ] || [ "${#started[@]}" -gt 0 ] || { say "no handoff could be started"; return 1; }

  # One message per owner, each naming only that owner's accounts.
  local owners=() owner
  for email in "${started[@]}"; do
    owner=$(owner_of "$email")
    case " ${owners[*]:-} " in *" $owner "*) ;; *) owners+=("$owner") ;; esac
  done
  for owner in "${owners[@]:-}"; do
    [ -n "$owner" ] || continue
    local mine=()
    for email in "${started[@]}"; do
      [ "$(owner_of "$email")" = "$owner" ] && mine+=("$email")
    done
    say ""
    deliver "$owner" "${mine[@]}"
  done
  say ""
  if [ "$failed" -gt 0 ]; then
    say "$failed of $total handoff(s) could not start."
    return 1
  fi
  say "handed off $total account(s); 'submit <email> <code>' finishes each one"
  say "the Codex login is Aaron's too: 'add-codex'"
  return 0
}

action_urls() {
  local email dir any=0
  while IFS= read -r email; do
    [ -n "$email" ] || continue
    dir=$(session_dir "$email")
    [ -f "$dir/url" ] || continue
    any=1
    printf '%s\t%s\t%s\t%s\n' "$(owner_of "$email")" "$email" "$(read_field "$dir/status")" "$(read_field "$dir/url")"
  done < <(account_list)
  if [ "$any" = 0 ]; then
    say "no handoff is open; run 'start' to mint one URL per account"
    return 1
  fi
  return 0
}

action_status() {
  local email dir state verified completed credential
  printf '%-26s %-10s %-11s %-9s %s\n' EMAIL OWNER STATE VERIFIED CREDENTIAL
  while IFS= read -r email; do
    [ -n "$email" ] || continue
    dir=$(session_dir "$email")
    state=$(read_field "$dir/status")
    [ -n "$state" ] || state=not-started
    verified=$(read_field "$dir/verified")
    [ -n "$verified" ] || verified=-
    completed=$(read_field "$dir/completed")
    credential=$(read_field "$dir/credential")
    [ -n "$credential" ] || credential=-
    printf '%-26s %-10s %-11s %-9s %s\n' "$email" "$(owner_of "$email")" "$state" "$verified" "$credential"
    [ -z "$completed" ] || printf '%30s completed %s\n' '' "$completed"
  done < <(account_list)
  [ -f "$OWNER_MAP" ] || {
    say ""
    say "no owner map at $OWNER_MAP: every account is handed to its own address"
  }
  say ""
  say "login dates are recorded in $REGISTRY; the expiry alarm measures them"
}

# proxy_api_key: read the first api-keys entry from the proxy config, never echoing it.
proxy_api_key() {
  local key
  if [ -n "$API_KEY" ]; then
    printf '%s\n' "$API_KEY"
    return 0
  fi
  if [ -n "$API_KEY_FILE" ]; then
    [ -r "$API_KEY_FILE" ] || return 1
    tr -d '\r\n' < "$API_KEY_FILE"
    return 0
  fi
  key=$(awk '
    /^api-keys:/ { inlist = 1; next }
    inlist && /^[[:space:]]*-[[:space:]]*/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/"/, ""); print; exit }
    inlist && /^[^[:space:]-]/ { exit }
  ' "$PROXY_CONFIG" 2>/dev/null)
  [ -n "$key" ] || return 1
  printf '%s\n' "$key"
}

# verify_account <email>: exactly one real request through the proxy.
verify_account() {
  local email=$1 dir key code body
  dir=$(session_dir "$email")
  (umask 077; mkdir -p "$dir") || return 1
  if [ "$DRY_RUN" = 1 ]; then
    say "$email: would send one real request through $PROXY_URL with $PROBE_MODEL"
    return 0
  fi
  key=$(proxy_api_key) || {
    printf 'nokey\n' > "$dir/verified" 2>/dev/null || true
    say "$email: no client API key found (pass --api-key, --api-key-file, or CLIPROXY_API_KEY)"
    return 1
  }
  body=$(mktemp "${TMPDIR:-/tmp}/cliproxy-verify.XXXXXX") || return 1
  code=$(curl -sS -o "$body" -w '%{http_code}' -m 60 \
    -X POST "$PROXY_URL/v1/messages" \
    -H "x-api-key: $key" \
    -H 'anthropic-version: 2023-06-01' \
    -H 'content-type: application/json' \
    --data-binary "{\"model\":\"$PROBE_MODEL\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}]}" \
    2>/dev/null)
  [ -n "$code" ] || code=none
  printf '%s\n' "$code" > "$dir/verified"
  if [ "$code" = 200 ]; then
    rm -f -- "$body"
    say "$email: verification request answered 200"
    return 0
  fi
  say "$email: verification request answered HTTP $code"
  case "$code" in
    401|403) say "  the proxy rejected the client key, so this proves nothing about the new credential" ;;
    400|404) say "  $PROBE_MODEL is probably not a model this deployment lists; re-run 'verify' with --probe-model <id> from GET /v1/models" ;;
    *) say "  $(head -c 300 "$body" 2>/dev/null | tr '\n' ' ')" ;;
  esac
  rm -f -- "$body"
  return 1
}

# superseded_files <email> <new-file>: the OAuth credentials this replacement retires.
superseded_files() {
  local email=$1 replacement=$2 path
  for path in "$AUTH_DIR"/claude-*.json; do
    [ -f "$path" ] || continue
    [ "$path" = "$replacement" ] && continue
    if python3 - "$path" "$email" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as handle:
        data = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)
if data.get("is_setup_token") or not data.get("refresh_token"):
    sys.exit(1)
if str(data.get("email") or "").strip().lower() != sys.argv[2].strip().lower():
    sys.exit(1)
PY
    then
      printf '%s\n' "$path"
    fi
  done
}

action_submit() {
  local email=$SUBMIT_EMAIL code=$SUBMIT_CODE dir token dest expired json path archived
  dir=$(session_dir "$email")
  [ -d "$dir" ] || die "no handoff is open for $email; run 'start --accounts $email'"
  [ -f "$dir/url" ] || die "the handoff for $email never produced a URL; run 'start --accounts $email'"
  case "$(read_field "$dir/status")" in
    complete) die "$email is already complete; 'verify $email' re-checks it" ;;
    expired|failed) die "the handoff for $email is $(read_field "$dir/status"); run 'start --accounts $email' to mint a new one" ;;
  esac
  if [ "$DRY_RUN" = 1 ]; then
    say "$email: would submit the owner's code to its open session, then write and verify the credential"
    return 0
  fi
  # The session reads the code file and removes it, so it is published by
  # rename: a half-written file must never be read as an empty code.
  local prior status_now waited=0
  prior=$(read_field "$dir/status")
  if ! printf '%s\n' "$code" | cliproxy_atomic_write "$dir/code"; then
    die "could not hand the code to the session for $email"
  fi
  # Wait for this attempt to be acknowledged before judging any verdict, so a
  # rejection left over from an earlier code is never read as this one's.
  while [ "$waited" -lt 30 ]; do
    status_now=$(read_field "$dir/status")
    [ "$status_now" != "$prior" ] && break
    sleep 1
    waited=$((waited + 1))
  done
  waited=0
  while [ "$waited" -lt 180 ]; do
    case "$(read_field "$dir/status")" in
      token-ready|rejected|failed|expired) break ;;
    esac
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$(read_field "$dir/status")" = "$prior" ] && [ "$prior" = rejected ]; then
    say "$email: the session never took the new code; check $dir/log"
    return 1
  fi
  case "$(read_field "$dir/status")" in
    token-ready) : ;;
    rejected)
      say "$email: the sign-in rejected that code; the handoff is still open, so send the right one with 'submit $email <code>'"
      return 1
      ;;
    *)
      say "$email: the sign-in did not produce a token ($(read_field "$dir/status"))"
      say "  see $dir/log; if that sign-in ended, re-mint its URL with 'start --accounts $email'"
      return 1
      ;;
  esac
  [ -f "$dir/token" ] || { say "$email: no token file was written"; return 1; }
  token=$(head -1 -- "$dir/token")
  rm -f -- "$dir/token"
  [ -n "$token" ] || { say "$email: the token file was empty"; return 1; }

  slug=$(cliproxy_email_slug "$email")
  dest="$AUTH_DIR/claude-setup-$slug.json"
  expired=$(date -u -d '+1 year' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v+1y +%Y-%m-%dT%H:%M:%SZ)
  (umask 077; mkdir -p "$AUTH_DIR") || return 1
  json=$(printf '%s' "$token" | cliproxy_json_setup_token "$email" "$expired") || {
    token=
    say "$email: could not build the credential; nothing was written"
    return 1
  }
  token=
  if ! printf '%s\n' "$json" | cliproxy_atomic_write "$dest"; then
    say "$email: could not write $dest"
    return 1
  fi
  json=
  printf '%s\n' "$dest" > "$dir/credential"
  say "$email: wrote $dest (expires $expired)"

  if ! verify_account "$email"; then
    archived=$(cliproxy_archive_move "$dest") || archived=
    printf 'failed\n' > "$dir/status"
    say "$email: a setup token did not pass one real request; ${archived:+moved it to $archived; }the 30-day credentials are untouched"
    return 1
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    archived=$(cliproxy_archive_move "$path") || { say "$email: could not archive $path"; return 1; }
    say "$email: archived the superseded credential to $archived"
  done < <(superseded_files "$email" "$dest")

  if ! cliproxy_registry_set "$email" "$(date -u +%Y-%m-%d)"; then
    say "$email: wrote the credential but could not record the login date in $REGISTRY"
    return 1
  fi
  printf 'complete\n' > "$dir/status"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$dir/completed"
  say "$email: complete - login date recorded, expiry alarm watching"
}

action_verify() {
  local email=$SUBMIT_EMAIL
  verify_account "$email"
}

action_add_codex() {
  [ -x "$PROXY_BIN" ] || command -v "$PROXY_BIN" >/dev/null 2>&1 \
    || die "CLIProxyAPI binary not found at $PROXY_BIN (set FM_CLIPROXY_BIN)"
  [ -r "$PROXY_CONFIG" ] || die "CLIProxyAPI config not readable at $PROXY_CONFIG (set FM_CLIPROXY_CONFIG)"
  if [ "$DRY_RUN" = 1 ]; then
    say "would run: $PROXY_BIN -codex-login -no-browser -config $PROXY_CONFIG"
    say "  CLIProxyAPI performs the Codex OAuth flow itself and writes its codex-*.json into $AUTH_DIR"
    return 0
  fi
  say "starting the Codex login through $PROXY_BIN; approve the URL it prints as Aaron's Codex account"
  "$PROXY_BIN" -codex-login -no-browser -config "$PROXY_CONFIG"
  return $?
}

case "$ACTION" in
  start) action_start ;;
  urls) action_urls ;;
  status) action_status ;;
  submit) action_submit ;;
  verify) action_verify ;;
  add-codex) action_add_codex ;;
  *) usage >&2; exit 2 ;;
esac
