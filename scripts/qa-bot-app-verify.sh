#!/usr/bin/env bash
set -uo pipefail

# qa-bot-app-verify.sh — prove the muso-qa-bot GitHub App is wired correctly
# BEFORE anything starts depending on it. Run on node-8.
# ===========================================================================
# Read-only by default. It answers, with evidence rather than assumption:
#
#   1. is the key store present, 0600, and well-formed?
#   2. does the private key actually sign a JWT GitHub accepts?
#   3. is the App installed, and on which repos?
#   4. does it hold `pull_requests: write` and `statuses: write` on hydra?
#      <- the precondition for an approval or a status to COUNT; without them the
#      gate silently never satisfies. NOTE it must NOT hold contents write
#      (`push`): the manifest deliberately requests `contents: read` so that
#      approve is structurally not merge. Do not "fix" a failure here by
#      broadening the App to contents write — that would defeat a core safety
#      property of this change. `push` being false is CORRECT and expected.
#   5. what is the App's bot login, in both REST and GraphQL form?  <- these
#      differ ("name[bot]" vs "name") and Guard 8 matches on them
#   6. what is the app_id?  <- needed to pin the required check
#   7. what is the current wiring state (app_repos, auto-merge, required checks)?
#
#   --fix-installation-id   resolve the installation and write it into the key
#                           store. The only non-read-only action; it touches the
#                           local key file, never GitHub.
#
# Exit codes: 0 all checks passed | 1 one or more checks failed | 2 usage

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_SCRIPT="${QA_GH_TOKEN_SCRIPT:-$_here/lib/qa-github-app-token.sh}"
SECRETS_DIR="${HYDRA_SECRETS_DIR:-/opt/hydra/secrets}"
KEYFILE="${QA_BOT_APP_KEY:-$SECRETS_DIR/qa-bot-app.json}"
POLICY="${QA_APPROVAL_POLICY:-$_here/../policies/qa-approval-policy.json}"
API="${GITHUB_API:-https://api.github.com}"
TARGET_REPO="${QA_VERIFY_REPO:-Muso-AI/hydra}"

fix_install_id=0
case "${1:-}" in
  --fix-installation-id) fix_install_id=1 ;;
  "") ;;
  *) echo "usage: qa-bot-app-verify.sh [--fix-installation-id]" >&2; exit 2 ;;
esac

rc=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; rc=1; }
note() { printf '  ....  %s\n' "$1"; }

gh_get() {  # <bearer> <path> — GET with the standard header set
  curl -sS -H "Authorization: Bearer $1" \
       -H "Accept: application/vnd.github+json" \
       -H "X-GitHub-Api-Version: 2022-11-28" "$API$2" 2>/dev/null
}
jwt_api() { gh_get "$JWT" "$1"; }   # /app endpoints, authed with the app JWT
tok_api() { gh_get "$tok" "$1"; }   # repo endpoints, authed with the installation token

echo "== 1. key store =="
if [ ! -r "$KEYFILE" ]; then
  bad "$KEYFILE missing or unreadable — create the App first (scripts/qa-bot-app-register.py)"
  exit 1
fi
mode="$(stat -c '%a' "$KEYFILE" 2>/dev/null || stat -f '%Lp' "$KEYFILE" 2>/dev/null)"
if [ "$mode" = "600" ]; then
  ok "$KEYFILE is 0600"
else
  bad "$KEYFILE is $mode, expected 600 (run: chmod 600 $KEYFILE)"
fi
case "$KEYFILE" in
  *.json) ok "key store is *.json, so ensure-secret-perms.sh covers it" ;;
  *) bad "key store is not *.json — ensure-secret-perms.sh globs *.json only and will NOT re-tighten it" ;;
esac
app_id="$(jq -r '.app_id // empty' "$KEYFILE" 2>/dev/null)"
if [ -n "$app_id" ]; then
  ok "app_id present: $app_id"
else
  bad "no .app_id in $KEYFILE"
fi

echo "== 2. the private key signs a JWT GitHub accepts =="
JWT="$("$TOKEN_SCRIPT" --jwt 2>/dev/null)"
if [ -z "$JWT" ]; then
  bad "could not sign a JWT — is .private_key a valid RSA key?"
  exit 1
fi
app_json="$(jwt_api /app)"
app_slug="$(printf '%s' "$app_json" | jq -r '.slug // empty' 2>/dev/null)"
if [ -n "$app_slug" ]; then
  ok "GitHub accepted the JWT; app slug = $app_slug"
else
  bad "GitHub rejected the JWT: $(printf '%s' "$app_json" | jq -r '.message // .' 2>/dev/null | head -1)"
  exit 1
fi

echo "== 3. installation =="
installs="$(jwt_api /app/installations)"
inst_id="$(printf '%s' "$installs" | jq -r '[.[] | select(.account.login=="Muso-AI")] | .[0].id // empty' 2>/dev/null)"
if [ -n "$inst_id" ]; then
  ok "installed on the Muso-AI org (installation id $inst_id)"
  stored="$(jq -r '.installation_id // empty' "$KEYFILE" 2>/dev/null)"
  if [ "$stored" != "$inst_id" ]; then
    if [ "$fix_install_id" = 1 ]; then
      tmp="$KEYFILE.tmp.$$"
      # umask BEFORE the redirection: `> "$tmp"` creates the file at the process
      # umask (typically 0644), so chmod-after would leave the private key
      # world-readable for the whole jq write. 0600-from-birth, like every other
      # secret write in this change.
      if ( umask 077; jq --arg i "$inst_id" '.installation_id = $i' "$KEYFILE" > "$tmp" 2>/dev/null ) \
         && chmod 600 "$tmp" && mv -f "$tmp" "$KEYFILE"; then
        ok "wrote installation_id=$inst_id into the key store"
      else
        rm -f "$tmp" 2>/dev/null
        bad "could not write installation_id into $KEYFILE"
      fi
    else
      bad "key store installation_id='$stored' != $inst_id — re-run with --fix-installation-id"
    fi
  else
    ok "key store installation_id matches"
  fi
else
  bad "the App is not installed on the Muso-AI org — install it, selecting only $TARGET_REPO"
  exit 1
fi

echo "== 4. repo access and write permission on $TARGET_REPO =="
tok="$("$TOKEN_SCRIPT" --repo "$TARGET_REPO" 2>/dev/null)"
if [ -z "$tok" ]; then
  bad "could not mint an installation token scoped to $TARGET_REPO — is the App installed on it?"
else
  ok "minted a token scoped to $TARGET_REPO"
  # One fetch, reused by the auto-merge note in check 7.
  repo_json="$(tok_api "/repos/$TARGET_REPO")"
  # Check the GRANULAR App permissions, not the repo object's .permissions.push.
  # That field is the classic {admin,push,pull} content-write triad; this App
  # deliberately requests `contents: read`, so push is false even when the
  # permissions that actually matter here are granted. Asserting on push would
  # reject a correctly configured App. /installation returns what was granted.
  inst_perms="$(tok_api /installation | jq -c '.permissions // {}' 2>/dev/null)"
  [ -n "$inst_perms" ] && [ "$inst_perms" != "{}" ] || inst_perms="$(printf '%s' "$installs" \
    | jq -c --arg i "$inst_id" '[.[] | select((.id|tostring) == $i)][0].permissions // {}' 2>/dev/null)"
  pr_perm="$(printf '%s' "$inst_perms" | jq -r '.pull_requests // "none"' 2>/dev/null)"
  st_perm="$(printf '%s' "$inst_perms" | jq -r '.statuses // "none"' 2>/dev/null)"
  if [ "$pr_perm" = "write" ]; then
    ok "pull_requests: write — reviews and approvals will count"
  else
    bad "pull_requests is '$pr_perm', need write. A review from a read-only app does NOT satisfy branch protection."
  fi
  if [ "$st_perm" = "write" ]; then
    ok "statuses: write — the qa-review gate status can be posted"
  else
    bad "statuses is '$st_perm', need write. Without it the qa-review merge gate can never be satisfied."
  fi
fi

# $app_slug is non-empty here: the JWT check above exits 1 when it cannot resolve.
echo "== 5. bot login (both forms — Guard 8 matches on these) =="
note "REST form (statuses, reviews):   ${app_slug}[bot]"
note "GraphQL form (Bot { login }):    ${app_slug}"
cfg="$(jq -c '.identity.bot_logins // []' "$POLICY" 2>/dev/null || echo '[]')"
if printf '%s' "$cfg" | jq -e --arg a "${app_slug}[bot]" 'index($a)' >/dev/null 2>&1 \
   && printf '%s' "$cfg" | jq -e --arg a "$app_slug" 'index($a)' >/dev/null 2>&1; then
  ok "both forms are in policy .identity.bot_logins"
else
  bad "policy .identity.bot_logins=$cfg is missing one of the two forms — Guard 8 will silently match nothing"
fi

echo "== 6. pin value for the required check =="
note "app_id to pin qa-review to: $app_id"
note "  gh api -X PATCH repos/$TARGET_REPO/branches/main/protection/required_status_checks \\"
note "    -F strict=false -f 'checks[][context]=qa-review' -F 'checks[][app_id]=$app_id'"

echo "== 7. current wiring state =="
if jq -e --arg r "$TARGET_REPO" '(.identity.app_repos // []) | index($r)' "$POLICY" >/dev/null 2>&1; then
  ok "$TARGET_REPO is in policy .identity.app_repos — QA calls run as the App"
else
  note "$TARGET_REPO is NOT yet in .identity.app_repos — QA still runs as the host account (expected before cutover)"
fi
am="$(printf '%s' "${repo_json:-}" | jq -r '.allow_auto_merge' 2>/dev/null)"
note "allow_auto_merge = $am $( [ "$am" = "true" ] || echo '(enable when arming the gate)' )"
checks="$(tok_api "/repos/$TARGET_REPO/branches/main/protection" \
  | jq -c '(.required_status_checks.checks // []) | map({context, app_id})' 2>/dev/null)"
note "required status checks = ${checks:-<unreadable: needs admin scope, use the host account>}"

echo
[ "$rc" -eq 0 ] && echo "RESULT: all checks passed." || echo "RESULT: one or more checks FAILED (see above)."
exit "$rc"
