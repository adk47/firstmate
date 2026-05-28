#!/usr/bin/env bash
# remove-credits.sh – Caroline self-service track removal from a customer's own profile.
#
# Architecture: bash-only mutation surface for capability A of the
# customer-credit-removal skill. The plugin's MusoAdminClient stays GET-only;
# this script is the single audit + cap-enforcement surface for destructive
# customer-initiated track removals.
#
# Invoked by Caroline via `exec bash <this>`. Fixed argv contract – no
# free-form parameters reach this script through a tool schema. The agent
# assembles a plain-text tracks file (one "Artist - Title" per line) and
# passes its path.
#
# Required env (set by the openclaw gateway unit):
#   MUSO_API_URL, MUSO_ADMIN_EMAIL, MUSO_ADMIN_PASSWORD  (passed through to
#                                                          muso-admin-api.sh)
#   MUSOAI_INTERCOM_TOKEN          required when --intercom-conv-id is passed
#                                  (always required under --apply)
#
# Required argv:
#   --profile-id <uuid>            Target profile UUID (from the URL the customer pasted)
#   --requester-email <email>      Verified Intercom contact email
#   --tracks-file <path>           Plain text file, one "Artist - Title" per line
#   --intercom-conv-id <id>        REQUIRED when --apply is set. Used to verify
#                                  --requester-email matches the Intercom contact's
#                                  source.author.email. Optional in dry-run mode but
#                                  recommended (the dry-run row is keyed by it).
#
# Optional argv:
#   --apply                        Real apply. Default is dry-run (no DELETEs issued).
#                                  Requires (a) --intercom-conv-id, (b) the email
#                                  passed must match Intercom's stored author.email
#                                  for that conversation, and (c) every track being
#                                  removed must have a matching `would_remove` row
#                                  in the audit log from within the last 15 minutes.
#
# Audit log:
#   /var/log/openclaw/customer-credit-removal.jsonl  (per-row JSONL)
#
# Output (stdout):
#   Single JSON object summarizing per-row resolution + actions taken.
#   See the inline `jq -nc` block at the end of the script for the shape.
#   Always emits JSON on success or failure.

set -euo pipefail
# Propagate failures from command substitutions (`$(...)`) when running on
# bash 4.4+. macOS dev hosts have bash 3.2 which doesn't support this option;
# in that case we silently fall back to the default behavior (the explicit
# `|| echo 0` fallbacks on every jq -r extraction are the load-bearing
# defense – inherit_errexit is belt-and-suspenders for hydra prod).
shopt -s inherit_errexit 2>/dev/null || true

# --- Constants / caps ---
MAX_PER_REQUEST=50
MAX_PER_CUSTOMER_PER_DAY=100
AUDIT_LOG="${CCR_AUDIT_LOG:-/var/log/openclaw/customer-credit-removal.jsonl}"

# Dry-run-before-apply window. The apply gate scans the audit log for a
# matching `would_remove` row from the last N seconds. 15 min is long enough
# for the customer-confirmation round-trip in a typical Intercom thread, short
# enough that a stale preview from yesterday can't be replayed.
DRY_RUN_RECENCY_SECS="${CCR_DRY_RUN_RECENCY_SECS:-900}"

# Intercom API base. Override is for tests; in prod the env is fine.
INTERCOM_API_BASE="${CCR_INTERCOM_API_BASE:-https://api.intercom.io}"

# Ownership-check field paths. Source of truth:
# reference_muso_admin_api_profile_fields.md (recon-confirmed 2026-05-25).
# Update both this script AND the SKILL.md prose if the API ever changes.
JQ_IS_CLAIMED='.body.data.isClaimed'
JQ_OWNER_EMAILS='[.body.data.workspaces[]? | select(.isClaimed==true) | .email]'

# --- Locate muso-admin-api.sh ---
# Hydra deploy syncs the repo into /opt/hydra (DEPLOY_PATH default per
# scripts/deploy.sh:21). The skill canonically lives in /opt/hydra/skills-all/
# after deploy. The /root/hydra-src tree exists but is stale on node-8 – do
# NOT prefer it: an out-of-date muso-admin-api.sh there would bypass newer
# admin-wrapper guards (e.g., the OPS_DRY_RUN refusal added 2026-05-26).
MUSO_ADMIN_API="${MUSO_ADMIN_API_SCRIPT:-/opt/hydra/skills-all/muso-ops-admin/scripts/muso-admin-api.sh}"
if [[ ! -f "$MUSO_ADMIN_API" ]]; then
  # Workspace shadow path (used in some divergent profiles per
  # .skill-workspace-divergence.txt). Prefer over the stale /root/hydra-src.
  MUSO_ADMIN_API="${MUSO_ADMIN_API:-/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh}"
fi
if [[ ! -f "$MUSO_ADMIN_API" ]]; then
  # Last-resort fallback for non-prod hosts (dev macs, CI). Skips
  # /root/hydra-src entirely to avoid silently picking up stale code.
  MUSO_ADMIN_API="$(find /opt -name muso-admin-api.sh -path '*/muso-ops-admin/*' 2>/dev/null | head -1 || true)"
fi

# --- Helpers ---

_now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

# Emit a single JSON line to stdout. Always exits 0 from the script's
# perspective so the agent can read structured output (the agent's stderr
# capture is harder to reason about than its stdout JSON).
_emit_error() {
  local error="$1" detail="${2:-}"
  jq -n -c --arg error "$error" --arg detail "$detail" \
    '{ok:false, error:$error, detail:(if $detail=="" then null else $detail end)}'
}

# Probe the audit log location is writable. Called at script start before any
# destructive action; refuses fail-closed if the audit surface is broken.
# Repo precedent for this fail-closed pattern: muso-admin-api.sh's
# enforce_tier2_approval_gate (cannot proceed without audit trail).
_audit_probe() {
  local audit_dir
  audit_dir="$(dirname "$AUDIT_LOG")"
  mkdir -p "$audit_dir" 2>/dev/null || return 1
  # Touch + zero-append confirms both create and write perms in one shot.
  touch "$AUDIT_LOG" 2>/dev/null || return 1
  printf '' >> "$AUDIT_LOG" 2>/dev/null || return 1
  return 0
}

# Append a JSONL audit row. Never fails the script if the log dir is
# unwritable – write a stderr warning so any silent-failure mode surfaces
# via the TS-layer stderr capture. The fail-closed gate is `_audit_probe`
# at script start; this helper is intentionally lenient mid-run so a
# refusal path never gets clobbered by a transient append failure.
_audit() {
  local status="$1" track_id="${2:-}" title="${3:-}" reason="${4:-}" http_status="${5:-}"
  local audit_dir
  audit_dir="$(dirname "$AUDIT_LOG")"
  mkdir -p "$audit_dir" 2>/dev/null || {
    echo "WARN: could not create audit dir $audit_dir; audit line LOST for status=$status" >&2
    return 0
  }
  local line
  line=$(jq -n -c \
    --arg ts "$(_now_iso)" \
    --arg profile_id "$profile_id" \
    --arg requester_email "$requester_email_lc" \
    --arg intercom_conv_id "$intercom_conv_id" \
    --arg mode "$mode" \
    --arg status "$status" \
    --arg track_id "$track_id" \
    --arg title "$title" \
    --arg reason "$reason" \
    --arg http_status "$http_status" \
    '{
      ts: $ts,
      profile_id: $profile_id,
      requester_email: $requester_email,
      intercom_conv_id: (if $intercom_conv_id == "" then null else $intercom_conv_id end),
      mode: $mode,
      status: $status,
      track_id: (if $track_id == "" then null else $track_id end),
      title: (if $title == "" then null else $title end),
      reason: (if $reason == "" then null else $reason end),
      http_status: (if $http_status == "" then null else ($http_status | tonumber? // $http_status) end)
    }')
  printf '%s\n' "$line" >> "$AUDIT_LOG" 2>/dev/null || {
    echo "WARN: could not append to $AUDIT_LOG; audit line LOST" >&2
  }
}

# Normalize "Artist - Title (Feat. X)" → "artist - title" for matching.
# Strips both "(feat. ...)" and "(ft. ...)" variants case-insensitively.
_normalize() {
  printf %s "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/\(feat\.?[[:space:]]+[^)]+\)//g' \
    | sed -E 's/\(ft\.?[[:space:]]+[^)]+\)//g' \
    | sed -E 's/[[:space:]]+/ /g' \
    | sed -E 's/^ +//; s/ +$//'
}

# Verify the customer's --requester-email matches what Intercom has on file
# for the conversation's contact. Closes the message-text-injection vector:
# the regex extractor on the upstream agent side can be fooled into pinning
# an arbitrary email from the customer's typed text, so we re-fetch the
# trusted email server-side from Intercom's contact record.
#
# Returns 0 if matched, 1 on any mismatch / lookup failure. Writes nothing
# to stdout (caller handles the refusal envelope).
_verify_intercom_email() {
  local conv_id="$1" claimed_email_lc="$2"
  [[ -n "$conv_id" ]] || return 1
  [[ -n "${MUSOAI_INTERCOM_TOKEN:-}" ]] || {
    echo "WARN: MUSOAI_INTERCOM_TOKEN not set; cannot verify Intercom author.email" >&2
    return 1
  }
  local resp
  resp=$(curl -sS --max-time 10 \
    -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
    -H "Accept: application/json" \
    -H "Intercom-Version: 2.10" \
    "${INTERCOM_API_BASE}/conversations/${conv_id}?display_as=plaintext" 2>/dev/null) \
    || return 1
  local author_email_lc
  author_email_lc=$(printf %s "$resp" | jq -r '.source.author.email // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')
  [[ -n "$author_email_lc" ]] || return 1
  [[ "$author_email_lc" == "$claimed_email_lc" ]]
}

# Audit-log scan: confirm a recent `would_remove` row exists for every
# track_id we're about to apply. Enforces the dry-run-before-apply rule
# mechanically (SKILL.md prose alone is not enforcement – per
# feedback_llm_instruction_insufficient.md).
#
# Args: profile_id requester_email_lc track_id  →  returns 0 if matched, 1 if not
_recent_dry_run_exists() {
  local profile_id="$1" requester_email_lc="$2" track_id="$3"
  [[ -f "$AUDIT_LOG" ]] || return 1
  local cutoff_epoch
  cutoff_epoch=$(( $(date -u +%s) - DRY_RUN_RECENCY_SECS ))
  # Date math via jq – fromdateiso8601 is POSIX-portable.
  jq -e --arg profile_id "$profile_id" \
        --arg email "$requester_email_lc" \
        --arg track_id "$track_id" \
        --argjson cutoff "$cutoff_epoch" '
    select(.profile_id == $profile_id
           and (.requester_email // "" | ascii_downcase) == $email
           and .track_id == $track_id
           and .status == "would_remove"
           and (.ts | fromdateiso8601) >= $cutoff)
  ' "$AUDIT_LOG" >/dev/null 2>&1
}

# --- Argv parsing ---
profile_id=""
requester_email=""
tracks_file=""
intercom_conv_id=""
apply=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile-id)        profile_id="${2:-}"; shift 2 ;;
    --requester-email)   requester_email="${2:-}"; shift 2 ;;
    --tracks-file)       tracks_file="${2:-}"; shift 2 ;;
    --intercom-conv-id)  intercom_conv_id="${2:-}"; shift 2 ;;
    --apply)             apply=1; shift ;;
    --dry-run)           apply=0; shift ;;
    -h|--help)
      cat <<'EOF'
remove-credits.sh – Caroline self-service track removal

Required:
  --profile-id <uuid>            Target profile UUID (from the URL the customer pasted)
  --requester-email <email>      Verified Intercom contact email
  --tracks-file <path>           Plain text, one "Artist - Title" per line

Optional:
  --apply                        Real apply. Default is dry-run.
  --intercom-conv-id <id>        Optional in dry-run; REQUIRED with --apply
                                 (used to cross-check requester-email against
                                 Intercom's contact author.email).

Caps: 50 tracks per request, 100 per requester per day (apply-mode only).
Refuses on: unclaimed profile, multi-claimed profile, email mismatch,
production-side role on the requested track (producer-profile guard),
OPS_DRY_RUN=1 in env (would short-circuit DELETEs into synthetic 200s).
Output: JSON to stdout.
EOF
      exit 0 ;;
    *)
      _emit_error "unknown_arg" "$1"
      exit 0 ;;
  esac
done

mode="dry-run"; (( apply == 1 )) && mode="apply"

# --- Arg validation ---
[[ -n "$profile_id"       ]] || { _emit_error "missing_arg" "--profile-id";       exit 0; }
[[ -n "$requester_email"  ]] || { _emit_error "missing_arg" "--requester-email";  exit 0; }
[[ -n "$tracks_file"      ]] || { _emit_error "missing_arg" "--tracks-file";      exit 0; }
[[ -f "$tracks_file"      ]] || { _emit_error "tracks_file_missing" "$tracks_file"; exit 0; }

if ! [[ "$profile_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  _emit_error "invalid_profile_id" "$profile_id"; exit 0
fi

if ! [[ "$requester_email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
  _emit_error "invalid_requester_email" "redacted"; exit 0
fi

# When supplied, intercom_conv_id is interpolated directly into the Intercom
# GET URL – restrict to a safe alphanumeric character set so a poisoned
# value can't change URL semantics (e.g., '?', '/', '#', encoded escapes).
# Intercom conv IDs in practice are short numeric strings.
if [[ -n "$intercom_conv_id" ]] && ! [[ "$intercom_conv_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
  _emit_error "invalid_intercom_conv_id" "redacted"; exit 0
fi

requester_email_lc="$(printf %s "$requester_email" | tr '[:upper:]' '[:lower:]')"

# Defense-in-depth gate: OPS_DRY_RUN=1 in env makes muso-admin-api.sh
# short-circuit ALL non-GET methods with a synthetic {"http_status":200,
# "dryRun":true,"wouldHaveExecuted":true} response. Without an explicit
# refusal here, a real --apply call would parade through DELETE-handling
# logic, see "200", audit `status:"removed"`, and report success to the
# customer – but no credit would have actually been deleted. This silent
# integrity drift is the worst-case failure mode for this script.
# Pass-3 DELETE handling also reads `.dryRun` per-row as a second line.
if [[ "${OPS_DRY_RUN:-0}" == "1" ]]; then
  _emit_error "ops_dry_run_set" "OPS_DRY_RUN=1 is set in env; refusing – would short-circuit DELETEs into synthetic 200s"
  exit 0
fi

# Fail-closed if the audit surface isn't writable. The dry-run-before-apply
# gate, per-day cap, and forensic trail all depend on the audit log. No
# audit = no destructive action.
if ! _audit_probe; then
  _emit_error "audit_unwritable" "cannot write to $AUDIT_LOG; refusing"
  exit 0
fi

# Hardening 1: --intercom-conv-id is REQUIRED whenever --apply is set.
# Closes the message-text-injection vector by forcing us to fetch the
# trusted email from Intercom's contact record instead of trusting whatever
# string the upstream extractor pinned from message text.
if (( apply == 1 )) && [[ -z "$intercom_conv_id" ]]; then
  _audit "refused_intercom_conv_id_required" "" "" "apply_without_conv_id"
  _emit_error "intercom_conv_id_required" "--apply requires --intercom-conv-id so we can verify the customer's email against Intercom's contact record"
  exit 0
fi

# Read input – strip blank lines + dedupe while preserving first-seen order.
# Portable read loop (bash 3.2 on macOS doesn't have mapfile).
# Also strip trailing \r so CRLF-pasted track lists from Windows clipboards
# don't get treated as distinct values from the LF-canonical credits.
input_lines=()
while IFS= read -r _ln; do
  input_lines+=("$_ln")
done < <(awk '{sub(/\r$/, ""); if (NF && !seen[$0]++) print}' "$tracks_file")
input_count=${#input_lines[@]}

(( input_count > 0 )) || { _emit_error "empty_tracks_file" "no non-blank lines"; exit 0; }
if (( input_count > MAX_PER_REQUEST )); then
  _emit_error "cap_exceeded_per_request" "got $input_count, max $MAX_PER_REQUEST"
  exit 0
fi

# Per-day cap – count today's status=removed entries for this requester.
# Scoped to apply mode only: dry-run is preview-shaped and should never
# refuse a customer at 95/100 from seeing what the next 6 would do.
# Uses `jq -R 'fromjson?'` so a single corrupted JSONL line in the audit
# log skips silently rather than aborting the whole script under
# set -euo pipefail / inherit_errexit.
if (( apply == 1 )); then
  today="$(date -u +%Y-%m-%d)"
  today_count=0
  if [[ -f "$AUDIT_LOG" ]]; then
    today_count=$(jq -R --arg email "$requester_email_lc" --arg today "$today" '
      fromjson?
      | select(.requester_email == $email)
      | select(.ts | startswith($today))
      | select(.status == "removed")
      | 1
    ' "$AUDIT_LOG" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  fi
  if (( today_count + input_count > MAX_PER_CUSTOMER_PER_DAY )); then
    _emit_error "cap_exceeded_per_day" "removed_today=$today_count requested=$input_count cap=$MAX_PER_CUSTOMER_PER_DAY"
    exit 0
  fi
fi

# --- Ownership check ---
# Late-check the admin-script presence so pure-argv refusals don't depend on
# the script being present (e.g., bats unit tests without prod layout).
[[ -f "$MUSO_ADMIN_API" ]] || { _emit_error "missing_admin_api_script" "muso-admin-api.sh not found"; exit 0; }

profile_json="$(bash "$MUSO_ADMIN_API" call GET "/admin/profile/$profile_id" 2>/dev/null || true)"
# `|| echo 0` guards against jq parse error if cmd_call emitted malformed
# JSON (curl transport failure can produce literal `{"http_status": , ...}`).
http_status="$(printf %s "$profile_json" | jq -r '.http_status // 0' 2>/dev/null || echo 0)"
if [[ "$http_status" != "200" ]]; then
  _audit "refused_profile_lookup_failed" "" "" "" "$http_status"
  _emit_error "profile_lookup_failed" "HTTP $http_status"
  exit 0
fi

is_claimed="$(printf %s "$profile_json" | jq -r "$JQ_IS_CLAIMED")"
if [[ "$is_claimed" != "true" ]]; then
  _audit "refused_profile_unclaimed"
  _emit_error "profile_unclaimed" "profile is not claimed; cannot self-service"
  exit 0
fi

owner_emails_json="$(printf %s "$profile_json" | jq -c "$JQ_OWNER_EMAILS")"
owner_count="$(printf %s "$owner_emails_json" | jq -r 'length')"
if (( owner_count == 0 )); then
  _audit "refused_no_claimed_workspace" "" "" "owner_count=0"
  _emit_error "no_claimed_workspace" "profile.isClaimed=true but no workspace has isClaimed=true"
  exit 0
fi
if (( owner_count > 1 )); then
  _audit "refused_profile_multi_claimed" "" "" "owner_count=$owner_count"
  _emit_error "profile_multi_claimed" "$owner_count claimed workspaces; manual review required"
  exit 0
fi

owner_email="$(printf %s "$owner_emails_json" | jq -r '.[0]')"
owner_email_lc="$(printf %s "$owner_email" | tr '[:upper:]' '[:lower:]')"
if [[ "$owner_email_lc" != "$requester_email_lc" ]]; then
  _audit "refused_owner_mismatch" "" "" "owner_present=$([ -n "$owner_email" ] && echo true || echo false)"
  _emit_error "owner_mismatch" "requester email does not match the profile's claimed owner"
  exit 0
fi

# --- Intercom author.email verification (Hardening 1) ---
# Whenever a conv_id is passed, cross-check the customer's email against
# Intercom's stored author.email. On --apply this is mandatory; on dry-run
# it's just opportunistic (catches injection before the customer ever sees
# the preview). If the conv_id is missing in dry-run, we accept the regex-
# extracted email and the apply-gate above will catch any attempt to escalate.
if [[ -n "$intercom_conv_id" ]]; then
  if ! _verify_intercom_email "$intercom_conv_id" "$requester_email_lc"; then
    _audit "refused_intercom_email_mismatch" "" "" "intercom_conv=$intercom_conv_id"
    _emit_error "intercom_email_mismatch" "the email passed doesn't match the Intercom contact for this conversation"
    exit 0
  fi
fi

# --- Tmpfiles for large JSON blobs ---
# Profiles can have hundreds of credits; passing the combined JSON through
# bash --argjson hits ARG_MAX (~128KB on Linux). Stream through files instead.
tmp_dir="$(mktemp -d -t ccr.XXXXXX)"
trap 'rm -rf "$tmp_dir"' EXIT
credits_file="$tmp_dir/credits.json"
lookup_file="$tmp_dir/lookup.json"
echo '[]' > "$credits_file"

# --- List profile credits (paginate via tmpfiles) ---
limit=500
offset=0
while :; do
  page_json="$(bash "$MUSO_ADMIN_API" call GET "/admin/profile/$profile_id/credits?limit=$limit&offset=$offset" 2>/dev/null || true)"
  page_status="$(printf %s "$page_json" | jq -r '.http_status // 0' 2>/dev/null || echo 0)"
  if [[ "$page_status" != "200" ]]; then
    _emit_error "credits_list_failed" "HTTP $page_status at offset=$offset"
    exit 0
  fi
  printf %s "$page_json" | jq -c '.body.data.items // []' > "$tmp_dir/page.json"
  jq -s 'add' "$credits_file" "$tmp_dir/page.json" > "$credits_file.new"
  mv "$credits_file.new" "$credits_file"
  # Field name on the admin/profile/{id}/credits endpoint is `totalCount`
  # (per shared-reference/muso-api-catalog.md:727 and profile-status.ts).
  # Older drafts read `.total`, which silently returned 0 on real responses
  # and truncated pagination after page 1 for profiles with >500 credits.
  # Fall back to `.total` for forward-compat in case the field gets renamed
  # again, and to the page item count as a last-resort `hasMoreToLoad`
  # equivalent.
  total="$(printf %s "$page_json" | jq -r '.body.data.totalCount // .body.data.total // 0' 2>/dev/null || echo 0)"
  page_items="$(jq 'length' < "$tmp_dir/page.json" 2>/dev/null || echo 0)"
  offset=$(( offset + limit ))
  (( offset >= total )) && break
  # If the API didn't give us a totalCount AND the last page was shorter
  # than `limit`, we've exhausted the list. Belt-and-braces against
  # missing/zero totalCount values.
  (( page_items < limit )) && break
  # Safety: never paginate past 20 pages (= 10k credits). If a profile has
  # more than that, something is unusual and we should refuse rather than
  # silently process.
  (( offset >= 20 * limit )) && { _emit_error "credits_list_too_large" "total=$total exceeds 10000"; exit 0; }
done

# --- Title-to-trackId resolution ---
# Build normalized lookup ONCE from the credits file, then per-row match
# reads via stdin redirect – no argv blowup.
# `roles` captures the profile owner's role(s) on each track; the producer-
# role guard below refuses removal when any production-side role is present
# (Alexxx false-positive pattern, ticket 869ck6tv6).
jq -c '
  [ .[] | {
    id: .id,
    title: .title,
    artists: [.artists[]?.name // empty],
    roles: [
      .credits[]?
      | if type == "string" then .
        elif type == "object" then (.child // .role // .name // "")
        else "" end
      | select(. != "")
    ],
    n_title: (.title // "" | ascii_downcase
              | gsub("\\(feat\\.?\\s+[^)]+\\)"; "")
              | gsub("\\(ft\\.?\\s+[^)]+\\)"; "")
              | gsub("\\s+"; " ")
              | gsub("^\\s+|\\s+$"; "")),
    n_artists: [ .artists[]?.name // empty
                 | ascii_downcase
                 | gsub("\\s+"; " ")
                 | gsub("^\\s+|\\s+$"; "") ]
  }]
' < "$credits_file" > "$lookup_file"

# Per-row processing.
# Pass 1 – resolution + dry-run audit. For apply mode, exactly-one-match rows
# get queued into the pending_apply arrays; we DO NOT issue any DELETE in
# pass 1 so we can preflight the whole batch against the dry-run-recency
# gate before any destructive call fires.
# Production-side roles where the profile owner's credit is legitimate
# regardless of who the primary artist on the track is. The Alexxx pattern
# (ticket 869ck6tv6) showed that "primary artist isn't the profile owner"
# is NOT sufficient to remove a credit when the owner is e.g. the producer.
# Matches against the same role labels documented in customer-credit-removal
# SKILL.md and action-request SKILL.md (Producer-profile guardrail).
PRODUCTION_ROLES_RE='^(Producer|Co-Producer|Songwriter|Composer|Lyricist|Mixing|Mixing Engineer|Mastering|Mastering Engineer|Engineer|Recording Engineer|Arranger)$'

results_json='[]'
removed=0; not_found=0; ambiguous=0; errors=0; already_removed=0; refused_role=0

# Parallel arrays (bash 3.2-compatible) holding the tracks queued for apply.
pending_apply_lines=()
pending_apply_track_ids=()
pending_apply_titles=()

for raw_line in "${input_lines[@]}"; do
  # Parse "Artist - Title" – split on first " - ".
  customer_artist=""
  customer_title="$raw_line"
  if [[ "$raw_line" == *" - "* ]]; then
    customer_artist="${raw_line%% - *}"
    customer_title="${raw_line#* - }"
  fi
  n_artist="$(_normalize "$customer_artist")"
  n_title="$(_normalize "$customer_title")"

  # Match: same normalized title, AND any artist on the credit matches the
  # normalized customer artist (when one was provided). Read lookup from
  # file to avoid argv overflow on large credit lists.
  matches_json="$(jq -c \
    --arg n_title "$n_title" \
    --arg n_artist "$n_artist" '
    [ .[] | select(.n_title == $n_title)
          | select($n_artist == "" or (.n_artists | index($n_artist)))
    ]
  ' < "$lookup_file")"
  match_count="$(printf %s "$matches_json" | jq 'length')"

  if (( match_count == 0 )); then
    not_found=$(( not_found + 1 ))
    _audit "not_found" "" "$raw_line" "no_title_artist_match_on_profile"
    results_json="$(jq -nc \
      --argjson r "$results_json" \
      --arg input "$raw_line" \
      '$r + [{input:$input, status:"not_found", reason:"no_match_on_profile"}]')"
    continue
  fi

  if (( match_count > 1 )); then
    ambiguous=$(( ambiguous + 1 ))
    candidates="$(printf %s "$matches_json" | jq -c '[ .[] | {id, title} ]')"
    _audit "ambiguous" "" "$raw_line" "match_count=$match_count"
    results_json="$(jq -nc \
      --argjson r "$results_json" \
      --argjson c "$candidates" \
      --arg input "$raw_line" \
      '$r + [{input:$input, status:"ambiguous", candidates:$c}]')"
    continue
  fi

  # Exactly one match.
  track_id="$(printf %s "$matches_json" | jq -r '.[0].id')"
  match_title="$(printf %s "$matches_json" | jq -r '.[0].title')"

  # Defense-in-depth: the track_id is interpolated into the DELETE URL;
  # validate the shape returned by the API before we use it. Catches an
  # upstream API regression where `.id` might be missing, an object, or
  # contain URL-control characters.
  if ! [[ "$track_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    errors=$(( errors + 1 ))
    _audit "error" "" "$raw_line" "unexpected_track_id_shape"
    results_json="$(jq -nc \
      --argjson r "$results_json" \
      --arg input "$raw_line" \
      '$r + [{input:$input, status:"error", reason:"unexpected_track_id_shape"}]')"
    continue
  fi

  # Producer-role guard: refuse if the profile owner has a production-side
  # role on this track. Forces the customer through action-request for
  # role-aware ops review instead of mechanical removal – closes the
  # Alexxx false-positive pattern at the mechanical layer (the SKILL.md
  # prose-only check was deemed insufficient per
  # feedback_llm_instruction_insufficient.md).
  matched_roles_csv="$(printf %s "$matches_json" | jq -r '.[0].roles[]?' 2>/dev/null | paste -sd ',' -)"
  hit_production_role=0
  if [[ -n "$matched_roles_csv" ]]; then
    while IFS= read -r role; do
      [[ -n "$role" ]] || continue
      if [[ "$role" =~ $PRODUCTION_ROLES_RE ]]; then
        hit_production_role=1
        break
      fi
    done < <(printf %s "$matches_json" | jq -r '.[0].roles[]?')
  fi
  if (( hit_production_role == 1 )); then
    refused_role=$(( refused_role + 1 ))
    _audit "refused_production_role_on_track" "$track_id" "$match_title" "roles=$matched_roles_csv"
    results_json="$(jq -nc \
      --argjson r "$results_json" \
      --arg input "$raw_line" \
      --arg track_id "$track_id" \
      --arg match_title "$match_title" \
      --arg roles "$matched_roles_csv" \
      '$r + [{input:$input, matched_track_id:$track_id, matched_title:$match_title, status:"refused_production_role_on_track", roles:$roles}]')"
    continue
  fi

  if (( apply == 0 )); then
    # Dry-run: record the intent (this row is what the apply-gate will look
    # for later to confirm a prior dry-run happened).
    _audit "would_remove" "$track_id" "$match_title"
    results_json="$(jq -nc \
      --argjson r "$results_json" \
      --arg input "$raw_line" \
      --arg track_id "$track_id" \
      --arg match_title "$match_title" \
      '$r + [{input:$input, matched_track_id:$track_id, matched_title:$match_title, status:"would_remove"}]')"
    continue
  fi

  # Apply mode: queue, don't act yet.
  pending_apply_lines+=("$raw_line")
  pending_apply_track_ids+=("$track_id")
  pending_apply_titles+=("$match_title")
done

# Pass 2 – dry-run-before-apply gate (Hardening 2). Only in apply mode.
# Every track in the pending queue must have a `would_remove` audit row
# from this same (profile_id, requester_email) within DRY_RUN_RECENCY_SECS.
# Refuse the WHOLE batch atomically if any track is missing its dry-run –
# never partial-apply.
if (( apply == 1 )) && (( ${#pending_apply_track_ids[@]} > 0 )); then
  missing_dry_run=()
  for i in "${!pending_apply_track_ids[@]}"; do
    if ! _recent_dry_run_exists "$profile_id" "$requester_email_lc" "${pending_apply_track_ids[$i]}"; then
      missing_dry_run+=("${pending_apply_track_ids[$i]}")
    fi
  done
  if (( ${#missing_dry_run[@]} > 0 )); then
    # Build a JSON array of the missing track IDs for the audit + response.
    missing_json="$(printf '%s\n' "${missing_dry_run[@]}" | jq -R . | jq -sc .)"
    _audit "refused_dry_run_required" "" "" "missing_count=${#missing_dry_run[@]}"
    jq -nc \
      --arg error "dry_run_required" \
      --arg detail "every track must have a matching dry-run within the last $(( DRY_RUN_RECENCY_SECS / 60 )) min; missing $(( ${#missing_dry_run[@]} )) of $(( ${#pending_apply_track_ids[@]} ))" \
      --argjson missing "$missing_json" \
      '{ok:false, error:$error, detail:$detail, missing_track_ids:$missing}'
    exit 0
  fi
fi

# Pass 3 – issue DELETEs (apply mode only). Preflight passed; safe to act.
for i in "${!pending_apply_track_ids[@]}"; do
  raw_line="${pending_apply_lines[$i]}"
  track_id="${pending_apply_track_ids[$i]}"
  match_title="${pending_apply_titles[$i]}"

  del_json="$(bash "$MUSO_ADMIN_API" call DELETE "/admin/track/$track_id/profile/$profile_id/credits" 2>/dev/null || true)"
  del_status="$(printf %s "$del_json" | jq -r '.http_status // 0' 2>/dev/null || echo 0)"
  # Second line of defense against the OPS_DRY_RUN=1 trapdoor: even if the
  # env var was set between the script-start check and now (or the admin
  # script ever changes its short-circuit behavior), refuse any synthetic
  # 200 carrying dryRun=true. Real DELETE responses do not include this key.
  del_dry="$(printf %s "$del_json" | jq -r '.dryRun // false' 2>/dev/null || echo false)"
  if [[ "$del_dry" == "true" ]]; then
    errors=$(( errors + 1 ))
    _audit "error" "$track_id" "$match_title" "upstream_dry_run_short_circuit" "$del_status"
    results_json="$(jq -nc \
      --argjson r "$results_json" \
      --arg input "$raw_line" \
      --arg track_id "$track_id" \
      --arg match_title "$match_title" \
      '$r + [{input:$input, matched_track_id:$track_id, matched_title:$match_title, status:"error", reason:"upstream_dry_run_short_circuit"}]')"
    continue
  fi

  case "$del_status" in
    200|204)
      removed=$(( removed + 1 ))
      _audit "removed" "$track_id" "$match_title" "" "$del_status"
      results_json="$(jq -nc \
        --argjson r "$results_json" \
        --arg input "$raw_line" \
        --arg track_id "$track_id" \
        --arg match_title "$match_title" \
        --arg http_status "$del_status" \
        '$r + [{input:$input, matched_track_id:$track_id, matched_title:$match_title, status:"removed", http_status:($http_status|tonumber)}]')"
      ;;
    404)
      # Idempotency: track wasn't on the profile (or already removed).
      already_removed=$(( already_removed + 1 ))
      _audit "already_removed" "$track_id" "$match_title" "" "$del_status"
      results_json="$(jq -nc \
        --argjson r "$results_json" \
        --arg input "$raw_line" \
        --arg track_id "$track_id" \
        --arg match_title "$match_title" \
        '$r + [{input:$input, matched_track_id:$track_id, matched_title:$match_title, status:"already_removed"}]')"
      ;;
    *)
      errors=$(( errors + 1 ))
      # Capture the upstream error body so Caroline can route on specific
      # 4xx shapes. Known case: the admin DELETE rejects primary-artist
      # role removal with 400 unless `?force=true` is appended; surfacing
      # the body text makes that visible in the action-request ticket
      # instead of looking like a generic failure.
      del_body_text="$(printf %s "$del_json" | jq -r '.body | if type=="object" then (tostring) else (. // "") end' 2>/dev/null || echo "")"
      del_body_snippet="${del_body_text:0:200}"
      _audit "error" "$track_id" "$match_title" "delete_http_${del_status}|${del_body_snippet}" "$del_status"
      results_json="$(jq -nc \
        --argjson r "$results_json" \
        --arg input "$raw_line" \
        --arg track_id "$track_id" \
        --arg match_title "$match_title" \
        --arg http_status "$del_status" \
        --arg upstream_body "$del_body_snippet" \
        '$r + [{input:$input, matched_track_id:$track_id, matched_title:$match_title, status:"error", http_status:($http_status|tonumber? // 0), upstream_body:(if $upstream_body=="" then null else $upstream_body end)}]')"
      ;;
  esac
done

# --- Final summary ---
jq -nc \
  --arg mode "$mode" \
  --arg profile_id "$profile_id" \
  --arg owner_email "$owner_email" \
  --argjson results "$results_json" \
  --argjson requested "$input_count" \
  --argjson removed "$removed" \
  --argjson already_removed "$already_removed" \
  --argjson not_found "$not_found" \
  --argjson ambiguous "$ambiguous" \
  --argjson errors "$errors" \
  --argjson refused_role "$refused_role" \
  '{
    ok: true,
    mode: $mode,
    profile_id: $profile_id,
    owner_email: $owner_email,
    ownership_check: "passed",
    results: $results,
    summary: {
      requested: $requested,
      removed: $removed,
      already_removed: $already_removed,
      not_found: $not_found,
      ambiguous: $ambiguous,
      errors: $errors,
      refused_production_role_on_track: $refused_role
    }
  }'
