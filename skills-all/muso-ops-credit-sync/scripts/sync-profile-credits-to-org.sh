#!/usr/bin/env bash
# sync-profile-credits-to-org.sh — additive reconciliation of credits from a
# person profile onto an organization profile.
#
# There is NO native credit-copy / profile→org link endpoint in the admin API
# (the only primitives are tier-2 profile merge — wrong tool, the profiles
# must stay separate — and track-level credit add). This script implements
# the agreed interim until core-backend grows a native link (Serhii's track,
# 2026-06-09 EOD call): diff the person's credits against the org's and POST
# the missing (track, role) pairs onto the org profile.
#
# ADDITIVE-ONLY BY DESIGN: removal semantics were explicitly left undecided
# on the 2026-06-09 call, so this script NEVER issues a DELETE. Credits that
# exist on the org but not on the person are *reported* (org_only_extras),
# never removed.
#
# Usage:
#   sync-profile-credits-to-org.sh --from <person_profile_id> --to <org_profile_id>
#                                  --as-role <role|verbatim>
#                                  [--dry-run] [--requester <email>]
#   sync-profile-credits-to-org.sh --pairs-file <path> [--dry-run] [--requester <email>]
#
# --as-role is REQUIRED in single-pair mode and maps every synced credit to
# ONE role on the org (e.g. "Studio", the Organizations>Studio child in the
# catalog taxonomy — 128k existing credits). The keyword `verbatim` copies
# the person's roles unchanged — WRONG for org profiles (Jan, 2026-06-10:
# professional/artist roles like Primary Artist or Composer must never
# appear on an org page), so it must always be an explicit choice.
#
# --pairs-file lines: "<person_id> <org_id> <role> <label...>" (blank / #
# lines skipped). The role column is required, same semantics as --as-role.
#
# Env:
#   ADMIN_API_SCRIPT  override path to muso-admin-api.sh (tests)
#   SYNC_PAGE_LIMIT   credits-list page size (default 500; tests shrink it)
#   SYNC_SLEEP_SECS   pause between credit POSTs (default 0.2)
#
# Output: one JSON summary per pair on stdout. Exit 0 = all pairs synced
# (or dry-run completed), 1 = usage error, 2 = at least one pair failed.

set -euo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required but not found" >&2; exit 1; }

ADMIN_API_SCRIPT="${ADMIN_API_SCRIPT:-${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOWED_ROLES_FILE="${ALLOWED_ROLES_FILE:-${SCRIPT_DIR}/../config/allowed-org-roles.txt}"
SYNC_PAGE_LIMIT="${SYNC_PAGE_LIMIT:-500}"
SYNC_SLEEP_SECS="${SYNC_SLEEP_SECS:-0.2}"

FROM_ID=""
TO_ID=""
AS_ROLE=""
PAIRS_FILE=""
DRY_RUN=0
REQUESTER=""

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)       FROM_ID="${2:?--from needs a value}"; shift 2 ;;
        --to)         TO_ID="${2:?--to needs a value}"; shift 2 ;;
        --as-role)    AS_ROLE="${2:?--as-role needs a value}"; shift 2 ;;
        --pairs-file) PAIRS_FILE="${2:?--pairs-file needs a value}"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --requester)  REQUESTER="${2:?--requester needs a value}"; shift 2 ;;
        -h|--help)    usage ;;
        *) echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

[[ -f "$ADMIN_API_SCRIPT" ]] || { echo "ERROR: muso-admin-api.sh not found at ${ADMIN_API_SCRIPT}" >&2; exit 1; }

if [[ -n "$PAIRS_FILE" ]]; then
    [[ -z "$FROM_ID" && -z "$TO_ID" && -z "$AS_ROLE" ]] || { echo "ERROR: --pairs-file is mutually exclusive with --from/--to/--as-role" >&2; exit 1; }
    [[ -f "$PAIRS_FILE" ]] || { echo "ERROR: pairs file not found: ${PAIRS_FILE}" >&2; exit 1; }
else
    [[ -n "$FROM_ID" && -n "$TO_ID" ]] || usage
    # Mechanical enforcement of the role hard-rule: defaulting to verbatim
    # would silently copy professional/artist roles onto an org profile.
    [[ -n "$AS_ROLE" ]] || { echo "ERROR: --as-role is required (a role like 'Studio', or the explicit keyword 'verbatim')" >&2; exit 1; }
fi

api() {
    local method="$1" path="$2"
    if [[ -n "$REQUESTER" ]]; then
        bash "$ADMIN_API_SCRIPT" --requester "$REQUESTER" call "$method" "$path" "${3:-}"
    else
        bash "$ADMIN_API_SCRIPT" call "$method" "$path" "${3:-}"
    fi
}

# muso-admin-api.sh always exits 0 and wraps responses in
# {"http_status": N, "body": <json>} (or {"http_status": N, "raw": "<text>"}
# when the body isn't JSON). Unwrap: print the inner body on 2xx, fail
# otherwise — exit codes alone are NOT evidence the call succeeded.
unwrap_envelope() {
    python3 -c '
import json, sys
ctx = sys.argv[1]
try:
    env = json.load(sys.stdin)
except Exception as e:
    print(f"ERROR: {ctx}: admin API response is not JSON ({e})", file=sys.stderr)
    sys.exit(1)
if not isinstance(env, dict) or "http_status" not in env:
    print(f"ERROR: {ctx}: expected the muso-admin-api.sh envelope "
          f"{{http_status, body}}, got: {str(env)[:200]}", file=sys.stderr)
    sys.exit(1)
status = env["http_status"]
if not (isinstance(status, int) and 200 <= status < 300):
    detail = env.get("body", env.get("raw"))
    print(f"ERROR: {ctx}: HTTP {status} — {json.dumps(detail)[:300]}", file=sys.stderr)
    sys.exit(1)
if "body" not in env:
    raw = str(env.get("raw"))[:200]
    print(f"ERROR: {ctx}: HTTP {status} but the response body is not JSON "
          f"(raw: {raw}) — refusing to treat as success", file=sys.stderr)
    sys.exit(1)
json.dump(env["body"], sys.stdout)
' "$1"
}

# Fetch a profile and print "<name>\t<creditCount>" — fails loud on API error,
# non-2xx status, unexpected shape, or a merged-away profile.
resolve_profile() {
    local id="$1" body
    if ! body="$(api GET "/admin/profile/${id}" | unwrap_envelope "profile ${id}")"; then
        echo "ERROR: failed to resolve profile ${id} (see the error above for the actual cause)" >&2
        return 1
    fi
    printf '%s' "$body" | python3 -c '
import json, sys
pid = sys.argv[1]
p = json.load(sys.stdin)  # always unwrap_envelope output, valid JSON
if isinstance(p, dict) and isinstance(p.get("data"), dict):
    p = p["data"]
if not isinstance(p, dict) or not p:
    print(f"ERROR: profile {pid}: empty/unexpected response shape", file=sys.stderr)
    sys.exit(1)
# Field-name aliases are deliberate ONLY here: this guard refuses work, so a
# missed spelling fails open (sync proceeds) rather than crashing — cheap
# insurance, unlike the credits parser which is strict by design.
merged = p.get("mergedTo") or p.get("merged_to_id") or p.get("mergedToId")
if merged:
    print(f"ERROR: profile {pid} has been merged into {merged} — refusing to sync", file=sys.stderr)
    sys.exit(1)
name, count = p.get("name", "?"), p.get("creditCount", "?")
print(f"{name}\t{count}")
' "$id"
}

# Page through /admin/profile/<id>/credits and emit one "track_id<TAB>role"
# line per credit. Live contract (verified 2026-06-10): the unwrapped body is
# {result, code, data: {items: [...], limit, offset, total}}; each item has
# id (= trackId) and credits = non-empty list of role STRINGS. The parser is
# deliberately STRICT — exactly this shape, nothing else — so any backend
# contract change hits the loud error path instead of being half-parsed and
# mistaken for "profile has no credits".
#
# Pagination uses `page` (1-based) — the endpoint IGNORES `offset` (verified
# live: any offset echoes back 0 and returns page 1, which would silently
# truncate the sync to the first page). The loop is total-driven, advancing
# by the number of items the server actually returned, so a server-side
# `limit` cap can't cause silent truncation either.
fetch_credit_pairs() {
    local id="$1" page_no=1 collected=0 page out meta items_on_page total
    while :; do
        if ! page="$(api GET "/admin/profile/${id}/credits?limit=${SYNC_PAGE_LIMIT}&page=${page_no}" \
            | unwrap_envelope "credits page for ${id} page=${page_no}")"; then
            echo "ERROR: GET /admin/profile/${id}/credits page=${page_no} failed" >&2
            return 1
        fi
        out="$(printf '%s' "$page" | python3 -c '
import json, sys
pid, where = sys.argv[1], sys.argv[2]
body = json.load(sys.stdin)  # always unwrap_envelope output, valid JSON
def die(msg):
    print(f"ERROR: credits page for {pid} {where}: {msg}", file=sys.stderr)
    sys.exit(1)
data = body.get("data") if isinstance(body, dict) else None
if not isinstance(data, dict) or not isinstance(data.get("items"), list) \
        or not isinstance(data.get("total"), int) or data["total"] < 0:
    die(f"unrecognized response shape (expected data.items list + data.total int >= 0; "
        f"top-level keys: {sorted(body) if isinstance(body, dict) else type(body).__name__})")
items, total = data["items"], data["total"]
lines = [f"META\t{len(items)}\t{total}"]
for it in items:
    if not isinstance(it, dict) or not it.get("id"):
        die(f"item without id (keys: {sorted(it) if isinstance(it, dict) else type(it).__name__})")
    tid = it["id"]
    roles = it.get("credits")
    if not isinstance(roles, list) or not roles or not all(isinstance(r, str) and r for r in roles):
        die(f"track {tid}: credits is not a non-empty list of role strings ({roles!r})")
    for r in roles:
        lines.append(f"{tid}\t{r}")
print("\n".join(lines))
' "$id" "page ${page_no}")" || return 1
        meta="${out%%$'\n'*}"
        IFS=$'\t' read -r _ items_on_page total <<< "$meta"
        if [[ "$out" == *$'\n'* ]]; then
            printf '%s\n' "${out#*$'\n'}"
        fi
        collected=$(( collected + items_on_page ))
        page_no=$(( page_no + 1 ))
        if (( collected >= total )); then
            break
        fi
        # An empty page while collected < total means the credit list was
        # truncated server-side — consuming it as complete would mis-diff
        # (and on the org side, re-POST duplicates daily). Fail loud.
        if (( items_on_page == 0 )); then
            echo "ERROR: credits list for ${id} truncated: server returned an empty page at page=$(( page_no - 1 )) with only ${collected}/${total} credits collected" >&2
            return 1
        fi
    done
    return 0
}

sync_pair() {
    local from_id="$1" to_id="$2" as_role="$3" label="${4:-}"
    local from_meta to_meta workdir
    local added=0 failed=0

    if [[ "$from_id" == "$to_id" ]]; then
        echo "ERROR: --from and --to are the same profile (${from_id})" >&2
        return 1
    fi

    from_meta="$(resolve_profile "$from_id")" || return 1
    to_meta="$(resolve_profile "$to_id")" || return 1

    # The diff can run to thousands of (track, role) lines (Colin alone is
    # ~10k credits) — keep it in files, not shell variables: passing it via
    # the environment blows ARG_MAX on the summary step.
    workdir="$(mktemp -d)"
    # Expanding workdir now (not at trap time) is intentional.
    # shellcheck disable=SC2064
    trap "rm -rf '$workdir'" RETURN

    fetch_credit_pairs "$from_id" | sort -u > "$workdir/from_pairs" || return 1
    fetch_credit_pairs "$to_id"   | sort -u > "$workdir/to_pairs"   || return 1

    # With a role override, the expected org state is ONE <track, as_role>
    # credit per track the person is credited on, regardless of which (or
    # how many) roles the person holds there.
    # errexit is suppressed for this whole function (called under `|| rc=2`),
    # so every diff step is checked explicitly — an unchecked failure here
    # would yield empty missing/extras and a false "in sync" exit 0.
    if [[ "$as_role" != "verbatim" ]]; then
        AS_ROLE_VALUE="$as_role" awk -F'\t' -v OFS='\t' '{print $1, ENVIRON["AS_ROLE_VALUE"]}' \
            "$workdir/from_pairs" | sort -u > "$workdir/expected" \
            || { echo "ERROR: failed to build the expected credit set for ${to_id}" >&2; return 1; }
    else
        cp "$workdir/from_pairs" "$workdir/expected" \
            || { echo "ERROR: failed to build the expected credit set for ${to_id}" >&2; return 1; }
    fi

    comm -23 "$workdir/expected" "$workdir/to_pairs" > "$workdir/missing" \
        || { echo "ERROR: failed to diff credit sets (missing)" >&2; return 1; }
    comm -13 "$workdir/expected" "$workdir/to_pairs" > "$workdir/extras" \
        || { echo "ERROR: failed to diff credit sets (extras)" >&2; return 1; }

    if [[ "$DRY_RUN" -eq 0 && -s "$workdir/missing" ]]; then
        # Memoize the JSON body for consecutive identical roles (plain vars,
        # not an associative array — must run on bash 3.2 too): with
        # --as-role every credit shares one role, and ~10k python3 spawns
        # (one per credit) would roughly double the wall time of a
        # Colin-scale first sync. Sentinel start value cannot collide with a
        # real role (the parser guarantees roles are non-empty).
        local memo_role=$'\x01' memo_body=""
        while IFS=$'\t' read -r track_id role; do
            [[ -n "$track_id" ]] || continue
            if [[ "$role" != "$memo_role" ]]; then
                memo_role="$role"
                memo_body="$(python3 -c 'import json,sys; print(json.dumps({"role": sys.argv[1]}))' "$role")"
            fi
            if api POST "/admin/track/${track_id}/profile/${to_id}/credits" "$memo_body" \
                | unwrap_envelope "add credit track=${track_id}" >/dev/null; then
                added=$(( added + 1 ))
            else
                failed=$(( failed + 1 ))
                printf '%s\t%s\n' "$track_id" "$role" >> "$workdir/failed"
                echo "WARN: failed to add credit role='${role}' track=${track_id} to org ${to_id}" >&2
            fi
            sleep "$SYNC_SLEEP_SECS"
        done < "$workdir/missing"
    fi

    # Explicit failure check: this call sits inside `sync_pair ... || rc=2`
    # at the call sites, which suppresses set -e for the whole function — an
    # unchecked render failure would silently produce exit 0 with no summary.
    touch "$workdir/failed"
    if ! FROM_ID="$from_id" TO_ID="$to_id" LABEL="$label" AS_ROLE_OUT="$as_role" \
        FROM_META="$from_meta" TO_META="$to_meta" \
        MISSING_FILE="$workdir/missing" EXTRAS_FILE="$workdir/extras" ADDED="$added" \
        FAILED_FILE="$workdir/failed" DRY="$DRY_RUN" \
        python3 - <<'EOF'
import json, os
def read_pairs(path):
    with open(path) as f:
        return [l.rstrip("\n") for l in f if l.strip()]
missing = read_pairs(os.environ["MISSING_FILE"])
extras  = read_pairs(os.environ["EXTRAS_FILE"])
failed_pairs = [":".join(p.split("\t")) for p in read_pairs(os.environ["FAILED_FILE"])]
fmeta   = os.environ["FROM_META"].split("\t")
tmeta   = os.environ["TO_META"].split("\t")
dry     = os.environ["DRY"] == "1"
print(json.dumps({
    "label": os.environ["LABEL"] or None,
    "as_role": os.environ["AS_ROLE_OUT"],
    "from": {"id": os.environ["FROM_ID"], "name": fmeta[0], "creditCount": fmeta[1] if len(fmeta) > 1 else "?"},
    "to":   {"id": os.environ["TO_ID"],   "name": tmeta[0], "creditCount": tmeta[1] if len(tmeta) > 1 else "?"},
    "dry_run": dry,
    "missing_on_org": len(missing),
    "added": int(os.environ["ADDED"]),
    "failed": len(failed_pairs),
    "failed_pairs": failed_pairs,
    "org_only_extras": len(extras),
    "org_only_extras_detail": [dict(zip(("trackId", "role"), e.split("\t"))) for e in extras],
    "planned_adds": [dict(zip(("trackId", "role"), m.split("\t"))) for m in missing] if dry else None,
}, indent=2))
EOF
    then
        echo "ERROR: failed to render the sync summary for ${from_id} -> ${to_id}" >&2
        return 1
    fi

    if (( failed > 0 )); then
        return 2
    fi
    return 0
}

rc=0
if [[ -n "$PAIRS_FILE" ]]; then
    pair_count=0
    while read -r person org role label; do
        [[ -z "$person" || "$person" == \#* ]] && continue
        if [[ -z "$role" ]]; then
            echo "ERROR: pairs file line for ${person} is missing the role column (use a role like 'Studio', or 'verbatim')" >&2
            rc=2
            continue
        fi
        # Fail-closed role validation: `read` makes a forgotten role column
        # silently consume the label's first word as the role (e.g. role
        # "Colin"), and the additive-only design has no way to undo the
        # resulting bogus org credits. Standing pairs may only use roles
        # from the reviewed allowlist (or the explicit `verbatim` keyword).
        if [[ "$role" != "verbatim" ]]; then
            if [[ ! -f "$ALLOWED_ROLES_FILE" ]]; then
                echo "ERROR: allowed-org-roles file missing (${ALLOWED_ROLES_FILE}) — refusing to run standing pairs without it" >&2
                exit 1
            fi
            if ! sed 's/#.*//; s/[[:space:]]*$//; /^$/d' "$ALLOWED_ROLES_FILE" | grep -qFx -- "$role"; then
                echo "ERROR: pairs file role '${role}' for ${person} is not in ${ALLOWED_ROLES_FILE} — add it via PR if it is a real catalog role" >&2
                rc=2
                continue
            fi
        fi
        pair_count=$(( pair_count + 1 ))
        sync_pair "$person" "$org" "$role" "$label" || rc=2
    done < "$PAIRS_FILE"
    if (( pair_count == 0 )); then
        echo "ERROR: pairs file ${PAIRS_FILE} contains no sync pairs" >&2
        exit 1
    fi
else
    sync_pair "$FROM_ID" "$TO_ID" "$AS_ROLE" || rc=2
fi
exit "$rc"
