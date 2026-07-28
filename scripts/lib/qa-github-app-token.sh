#!/usr/bin/env bash
set -euo pipefail

# qa-github-app-token.sh — mint (and cache) a GitHub App installation token for
# the QA reviewer identity.
# ===========================================================================
# The QA agent's GitHub writes used to run as the ambient `gh` login on node-8,
# which is adk47 (Aaron's org-admin account). That made every review and approval
# read as Aaron, made the bot unable to approve Aaron's own PRs (GitHub blocks
# self-approval), and — least obviously — handed the automation Aaron's CODEOWNER
# authority over hydra's own `policies/` and `secrets/` (hydra sets
# require_code_owner_reviews and CODEOWNERS is `* @adk47`).
#
# This script mints a short-lived installation token for the `muso-qa-bot` App
# instead. The App's whole permission set is repo-scoped (pull_requests + statuses
# write, contents/checks/metadata read); it has NO org permissions and NO
# contents:write, so an approval is structurally not a merge.
#
# ── Why the key is a *.json file, not a *.pem ────────────────────────────────
# scripts/lib/ensure-secret-perms.sh (systemd ExecStartPre) re-tightens secret
# stores to 0600, and it globs "$SECRETS_DIR"/*.json ONLY — its header says a
# non-.json store requires widening that glob and documenting why. Wrapping the
# PEM in JSON inherits the 2026-06-15 fail-closed perms self-heal for free and
# matches the existing llm-provider-keys.json / google-sa-hydra.json convention.
#
# Key file shape (/opt/hydra/secrets/qa-bot-app.json, mode 0600):
#   { "app_id": "1234567",
#     "installation_id": "87654321",     # optional — resolved via the API if absent
#     "private_key": "-----BEGIN RSA PRIVATE KEY-----\n...\n" }
#
# ── Scoping ──────────────────────────────────────────────────────────────────
# With --repo, the token is minted with {"repositories":["<name>"]} so a token
# leaked from one review only opens that one repo. Verified against the REST docs:
# the endpoint takes a `repositories` array of NAMES (or `repository_ids`), needs
# JWT auth, and issues tokens that expire in one hour. Do NOT assume a token
# length — GitHub began rolling out a longer stateless `ghs_APPID_JWT` format in
# April 2026.
#
# Usage:   qa-github-app-token.sh [--repo <owner/name>]
#          qa-github-app-token.sh --jwt          # app-level JWT, for /app endpoints
# Output:  the installation token on stdout (exit 0). Nothing on stdout on error.
#
# --jwt exists so qa-bot-app-verify.sh can call /app and /app/installations
# without re-implementing RS256 signing. Never cached: it is valid 9 minutes and
# minting is cheap.
#
# Exit codes: 0 ok | 2 usage | 3 key-store missing/unreadable/malformed
#             4 JWT mint failed | 5 installation-token request failed
#             6 installation could not be resolved
#
# Env (mainly for tests):
#   HYDRA_SECRETS_DIR   dir holding qa-bot-app.json (default /opt/hydra/secrets)
#   QA_BOT_APP_KEY      full path to the key store (overrides the dir)
#   QA_BOT_TOKEN_CACHE  cache dir (default = the secrets dir, so the perms
#                       self-heal covers the cached tokens too)
#   QA_BOT_LOCK_DIR     dir for the flock file (default /run/hydra)
#   GITHUB_API          API base (default https://api.github.com)

_here_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="${HYDRA_SECRETS_DIR:-/opt/hydra/secrets}"
KEYFILE="${QA_BOT_APP_KEY:-$SECRETS_DIR/qa-bot-app.json}"
CACHE_DIR="${QA_BOT_TOKEN_CACHE:-$SECRETS_DIR}"
LOCK_DIR="${QA_BOT_LOCK_DIR:-/run/hydra}"
API="${GITHUB_API:-https://api.github.com}"

# Re-mint when less than this much life remains. A review runs under a 1200s
# dispatch timeout against a 3600s token, so a 600s floor means a token handed
# out here always outlives the call that uses it.
MIN_REMAINING_SECS=600

die() { echo "qa-github-app-token: $2" >&2; exit "$1"; }

repo_full=""
jwt_only=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo_full="${2:-}"; shift 2 || die 2 "--repo needs a value" ;;
    --jwt)  jwt_only=1; shift ;;
    -h|--help) die 2 "usage: qa-github-app-token.sh [--repo <owner/name>] | --jwt" ;;
    *) die 2 "unknown argument '$1'" ;;
  esac
done

[ -r "$KEYFILE" ] || die 3 "App key store $KEYFILE is missing or unreadable."

app_id="$(jq -r '.app_id // empty' "$KEYFILE" 2>/dev/null || true)"
installation_id="$(jq -r '.installation_id // empty' "$KEYFILE" 2>/dev/null || true)"
[ -n "$app_id" ] || die 3 "$KEYFILE has no .app_id."
jq -e '.private_key | type == "string" and (length > 0)' "$KEYFILE" >/dev/null 2>&1 \
  || die 3 "$KEYFILE has no usable .private_key."

# ISO-8601 -> epoch. The GNU-then-BSD date dance is already extracted; reuse it
# rather than adding a fifth copy (epoch.sh's own header tracks the others).
# iso_to_epoch returns nonzero and prints nothing on an unparseable value; the
# `|| printf ''` preserves this script's contract of always exiting 0 with empty
# output, which cached_token relies on.
# shellcheck source=epoch.sh
source "$_here_lib/epoch.sh"
to_epoch() { iso_to_epoch "$1" || printf ''; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# mint_jwt — RS256 JWT for the App itself. iat is backdated 60s to absorb clock
# skew (GitHub rejects a future iat) and exp is +540s, under the 600s ceiling.
mint_jwt() {
  local now header payload signing_input sig
  now="$(date -u +%s)"
  header='{"alg":"RS256","typ":"JWT"}'
  payload="$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$app_id")"
  signing_input="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
  # Sign from a process substitution rather than a temp file so the PEM never
  # lands on disk unprotected.
  sig="$(printf '%s' "$signing_input" \
    | openssl dgst -sha256 -sign <(jq -r '.private_key' "$KEYFILE") -binary 2>/dev/null \
    | b64url)" || return 1
  [ -n "$sig" ] || return 1
  printf '%s.%s' "$signing_input" "$sig"
}

# api_call <method> <auth> <path> [json-body] — echoes the body, returns non-zero
# on transport failure or non-2xx. The response is NEVER echoed on the failure
# path: it can carry a token.
api_call() {
  local method="$1" auth="$2" path="$3" body="${4:-}" out code
  local -a extra=()
  [ -n "$body" ] && extra=(-H "Content-Type: application/json" -d "$body")
  out="$(curl -sS -X "$method" "$API$path" \
    -H "Authorization: Bearer $auth" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${extra[@]}" -w $'\n%{http_code}' 2>/dev/null)" || return 1
  code="${out##*$'\n'}"
  case "$code" in 2*) printf '%s' "${out%$'\n'*}" ;; *) return 1 ;; esac
}

# ── --jwt: app-level token, no installation, no cache ------------------------
if [ "$jwt_only" = 1 ]; then
  jwt="$(mint_jwt)" || die 4 "could not sign the App JWT (is .private_key a valid RSA key?)."
  printf '%s\n' "$jwt"
  exit 0
fi

# ── cache -------------------------------------------------------------------
if [ -n "$repo_full" ]; then
  [[ "$repo_full" == */* ]] || die 2 "--repo must be owner/name, got '$repo_full'"
  cache_key="${repo_full%%/*}__${repo_full#*/}"
  repo_name="${repo_full#*/}"
else
  cache_key="all"
  repo_name=""
fi
cache_file="$CACHE_DIR/qa-bot-token-${cache_key}.json"

cached_token() {
  [ -r "$cache_file" ] || return 1
  local tok exp exp_epoch now
  tok="$(jq -r '.token // empty' "$cache_file" 2>/dev/null || true)"
  exp="$(jq -r '.expires_at // empty' "$cache_file" 2>/dev/null || true)"
  [ -n "$tok" ] && [ -n "$exp" ] || return 1
  exp_epoch="$(to_epoch "$exp")"
  [ -n "$exp_epoch" ] || return 1
  now="$(date -u +%s)"
  [ "$((exp_epoch - now))" -gt "$MIN_REMAINING_SECS" ] || return 1
  printf '%s' "$tok"
}

# Fast path: a still-fresh cached token, no lock needed.
if tok="$(cached_token)"; then printf '%s\n' "$tok"; exit 0; fi

# ── mint (serialized) --------------------------------------------------------
# qa-dispatch-pr-review.sh fires concurrent one-shot reviews, so parallel callers
# will race this. flock makes the loser wait and then hit the cache the winner
# just wrote, instead of both minting (and both rotating nothing, but wasting
# API calls and risking a torn read of the cache file).
mkdir -p "$LOCK_DIR" 2>/dev/null || LOCK_DIR="$CACHE_DIR"
exec 9>"$LOCK_DIR/qa-gh-token.lock" || die 5 "cannot open the token lock in $LOCK_DIR."
flock 9 || die 5 "cannot acquire the token lock."

# Re-check under the lock — the process we queued behind probably just minted.
if tok="$(cached_token)"; then printf '%s\n' "$tok"; exit 0; fi

jwt="$(mint_jwt)" || die 4 "could not sign the App JWT (is .private_key a valid RSA key?)."

if [ -z "$installation_id" ]; then
  # Not pinned in the key store — resolve the org installation via the JWT.
  installs="$(api_call GET "$jwt" "/app/installations")" \
    || die 6 "could not list App installations (is the App key valid?)."
  installation_id="$(printf '%s' "$installs" \
    | jq -r '[.[] | select(.account.login == "Muso-AI")] | .[0].id // empty' 2>/dev/null || true)"
  [ -n "$installation_id" ] || die 6 "the App is not installed on the Muso-AI org."
fi

if [ -n "$repo_name" ]; then
  body="$(jq -nc --arg r "$repo_name" '{repositories: [$r]}')"
else
  body='{}'
fi

resp="$(api_call POST "$jwt" "/app/installations/$installation_id/access_tokens" "$body")" \
  || die 5 "installation-token request failed for installation $installation_id${repo_name:+ (repo $repo_name)} — is the App installed on that repo?"

token="$(printf '%s' "$resp" | jq -r '.token // empty' 2>/dev/null || true)"
expires_at="$(printf '%s' "$resp" | jq -r '.expires_at // empty' 2>/dev/null || true)"
[ -n "$token" ] && [ -n "$expires_at" ] || die 5 "installation-token response had no token."

# Write the cache 0600-from-birth and atomically: a reader must never see a
# half-written file, and the token must never exist group-readable even briefly.
umask 077
tmp="$cache_file.tmp.$$"
if jq -nc --arg t "$token" --arg e "$expires_at" '{token:$t, expires_at:$e}' > "$tmp" 2>/dev/null \
   && mv -f "$tmp" "$cache_file" 2>/dev/null; then
  :
else
  rm -f "$tmp" 2>/dev/null || true
  echo "qa-github-app-token: WARNING: could not cache the token (continuing)" >&2
fi

printf '%s\n' "$token"
