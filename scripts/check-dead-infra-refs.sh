#!/usr/bin/env bash
set -euo pipefail

# Mechanical backstop: no agent-facing content may point at dead infrastructure.
#
# Incident (2026-07-24): the Finance agent's daily-dispute-handler cron followed
# skills-all/muso-stripe-disputes into a live "query Athena" section and died on
# AssumeRole InvalidClientTokenId. AWS was decommissioned 2026-05-31, Athena
# retired 2026-04-25, and the profile_v3_* stats tables are frozen — yet ~15
# skills still carried live Athena/AWS instructions. Prose != enforcement, so
# this gate fails CI when any live instruction surface points an agent at dead
# infra. The live replacement is OVH Trino via `muso query` (muso-query-writer).
#
# Two tiers:
#   Tier 1 — operational syntax (AssumeRole, boto3, real `aws <svc>` CLI calls,
#            AWS credential env vars, us-west-2, the clio-agent Athena
#            workgroup idiom) scanned across ALL files under skills-all/,
#            workspaces/, and cron-jobs.json.
#   Tier 2 — bare dead-infra words (athena, the AWS acronym, frozen
#            profile_v3_* tables) scanned only on doctrine surfaces: skill
#            SKILL.md/reference.md, skill scripts, workspace
#            SOUL/AGENTS/TOOLS/HEARTBEAT/INTEGRATIONS files, workspace skills,
#            and cron-jobs.json. Historical records (MEMORY.md, KT transcripts,
#            reference libraries) are deliberately NOT Tier-2 surfaces — they
#            are records, not instructions — but Tier 1 still covers them.
#
# False positives (migration tables, decommission records, "NEVER use" warnings)
# are exempted via .dead-infra-allowlist.txt:
#   <path-or-dir-prefix/> -- <comma-separated pattern keys> -- <reason>
# A stale entry (path gone, or no remaining match for any of its keys) fails CI
# so the allowlist can only shrink.

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ALLOWLIST="${DEAD_INFRA_ALLOWLIST:-$ROOT/.dead-infra-allowlist.txt}"

if [ ! -d "$ROOT/skills-all" ] || [ ! -d "$ROOT/workspaces" ]; then
  echo "Missing skills-all/ or workspaces/ under $ROOT (run from repo root, or set REPO_ROOT)." >&2
  exit 2
fi
if [ ! -f "$ALLOWLIST" ]; then
  echo "Missing allowlist $ALLOWLIST (set DEAD_INFRA_ALLOWLIST to override)." >&2
  exit 2
fi
cd "$ROOT"

# ---------------------------------------------------------------- patterns --
declare -A PAT
PAT[assumerole]='assume.?role'
PAT[boto3]='boto3'
PAT[awscli]='(^|[^[:alnum:]_./-])aws[[:space:]]+(athena|s3|s3api|lambda|sts|iam|ec2|ecs|eks|ecr|glue|logs|cloudwatch|cloudfront|dynamodb|rds|route53|sns|sqs|ssm|secretsmanager|elasticache|autoscaling|configure|sso)([^[:alnum:]]|$)'
PAT[awsenv]='AWS_(PROFILE|DEFAULT_PROFILE|ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN|ROLE_ARN|WEB_IDENTITY_TOKEN_FILE|SHARED_CREDENTIALS_FILE|CONFIG_FILE|DEFAULT_REGION|REGION)'
PAT[awsprofile]='--profile[ =]muso-readonly'
PAT[uswest2]='us-west-2'
PAT[workgroup]='work.?group.{0,40}clio-agent|clio-agent.{0,40}work.?group'
PAT[athena]='athena'
PAT[aws]='(^|[^[:alnum:]_])AWS([^[:alnum:]_]|$)'
PAT[v3]='profile_v3_(lifetime|tracks|\*)'

# Everything scans case-insensitively EXCEPT the aws-shaped keys, where case is
# the signal: shell invocations are lowercase (`aws athena …`), credential env
# vars and the bare acronym are uppercase, while prose naming the product
# ("AWS Athena was retired") must not trip the lowercase CLI pattern.
CASE_SENSITIVE=' awscli awsenv awsprofile aws '
TIER1_KEYS=(assumerole boto3 awscli awsenv awsprofile uswest2 workgroup)
TIER2_KEYS=(athena aws v3)

# --------------------------------------------------------------- file sets --
# Hit lines are parsed positionally as file:line:text, so a path containing a
# colon (or newline) would corrupt the split and could silently mis-attribute
# hits to an allowlisted path. No agent-facing file legitimately needs either.
if find skills-all workspaces \( -name '*:*' -o -name $'*\n*' \) -print -quit | grep -q .; then
  echo "Refusing to scan: a path under skills-all/ or workspaces/ contains ':' or a newline." >&2
  exit 2
fi

# shellcheck disable=SC2034  # consumed via nameref in scan()
mapfile -t TIER1_FILES < <(
  {
    find skills-all workspaces -type f
    if [ -f cron-jobs.json ]; then echo cron-jobs.json; fi
  } | LC_ALL=C sort
)
if [ "${#TIER1_FILES[@]}" -eq 0 ]; then
  echo "No files found under skills-all/ + workspaces/ — refusing to pass vacuously." >&2
  exit 2
fi

# shellcheck disable=SC2034  # consumed via nameref in scan()
mapfile -t TIER2_FILES < <(
  {
    find skills-all -mindepth 2 -maxdepth 2 \( -name 'SKILL.md' -o -name 'reference.md' \)
    find skills-all -type f -name '*.sh'
    find workspaces -mindepth 2 -maxdepth 2 -type f \
      \( -name 'SOUL.md' -o -name 'AGENTS.md' -o -name 'TOOLS.md' \
         -o -name 'HEARTBEAT.md' -o -name 'INTEGRATIONS.md' \)
    find workspaces -path '*/skills/*' -type f \
      \( -name 'SKILL.md' -o -name 'reference.md' -o -name '*.sh' \)
    if [ -f cron-jobs.json ]; then echo cron-jobs.json; fi
  } | LC_ALL=C sort -u
)

# ---------------------------------------------------------------- allowlist --
# Parsed into parallel arrays; usage tracked for the stale-entry rule.
AL_PATHS=() AL_KEYS=()
lineno=0
while IFS= read -r raw || [ -n "$raw" ]; do
  lineno=$((lineno + 1))
  case "$raw" in ''|'#'*) continue ;; esac
  case "$raw" in
    *' -- '*' -- '*) ;;
    *)
      echo "Malformed allowlist line $lineno (need '<path> -- <keys> -- <reason>'): $raw" >&2
      exit 2
      ;;
  esac
  path="${raw%% -- *}"
  rest="${raw#* -- }"
  keys="${rest%% -- *}"
  keys="${keys// /}"   # tolerate "athena, aws" — matcher compares exact ,key, tokens
  reason="${rest#* -- }"
  if [ -z "$path" ] || [ -z "$keys" ] || [ -z "$reason" ]; then
    echo "Malformed allowlist line $lineno (need '<path> -- <keys> -- <reason>'): $raw" >&2
    exit 2
  fi
  for k in ${keys//,/ }; do
    if [ -z "${PAT[$k]:-}" ]; then
      echo "Unknown pattern key '$k' on allowlist line $lineno (valid: ${!PAT[*]})." >&2
      exit 2
    fi
  done
  AL_PATHS+=("$path")
  AL_KEYS+=("$keys")
done <"$ALLOWLIST"

# allow_idx <file> <key> -> prints matching entry index, rc 0; rc 1 if none.
# First match wins: if a dir-prefix entry and an exact-file entry overlap on a
# key, only the earlier entry accrues ENTRY_USED — the later one goes stale-red,
# and removing it (it's redundant) is the correct remediation.
allow_idx() {
  local file="$1" key="$2" i
  for i in "${!AL_PATHS[@]}"; do
    case ",${AL_KEYS[$i]}," in *",$key,"*) ;; *) continue ;; esac
    case "${AL_PATHS[$i]}" in
      */) [[ "$file" == "${AL_PATHS[$i]}"* ]] && { echo "$i"; return 0; } ;;
      *)  [ "$file" = "${AL_PATHS[$i]}" ] && { echo "$i"; return 0; } ;;
    esac
  done
  return 1
}

# -------------------------------------------------------------------- scan --
declare -A ENTRY_USED
fail=0

scan() { # scan <tier-label> <files-array-name> <keys...>
  local label="$1"
  local -n _files="$2"
  shift 2
  local key rc hits idx
  [ "${#_files[@]}" -gt 0 ] || return 0
  for key in "$@"; do
    local ci=()
    case "$CASE_SENSITIVE" in *" $key "*) ;; *) ci=(-i) ;; esac
    rc=0
    hits="$(grep -nIHE "${ci[@]}" -e "${PAT[$key]}" -- "${_files[@]}")" || rc=$?
    if [ "$rc" -ge 2 ]; then
      # rc 1 = no match (fine); anything else = grep itself failed — refuse to
      # pass vacuously (same idiom as check-admin-api-doc-contract.sh).
      echo "grep failed (rc=$rc) while scanning pattern key '$key'." >&2
      exit 2
    fi
    [ -n "$hits" ] || continue
    while IFS= read -r hit; do
      local file="${hit%%:*}" rest="${hit#*:}"
      local line="${rest%%:*}" text="${rest#*:}"
      if idx="$(allow_idx "$file" "$key")"; then
        ENTRY_USED[$idx]=1
        continue
      fi
      echo "FAIL: $file:$line: [$key/$label] ${text#"${text%%[![:space:]]*}"}" >&2
      fail=1
    done <<<"$hits"
  done
}

scan tier1 TIER1_FILES "${TIER1_KEYS[@]}"
scan tier2 TIER2_FILES "${TIER2_KEYS[@]}"

# -------------------------------------------------------- stale allowlist --
for i in "${!AL_PATHS[@]}"; do
  p="${AL_PATHS[$i]}"
  if [ ! -e "$p" ]; then
    echo "FAIL: allowlist entry '$p' points at a nonexistent path — remove it." >&2
    fail=1
  elif [ -z "${ENTRY_USED[$i]:-}" ]; then
    hint=""
    if [ -d "$p" ] && [ "${p%/}" = "$p" ]; then
      hint=" (path is a directory but the entry lacks a trailing '/' — add one to make it a prefix)"
    fi
    echo "FAIL: allowlist entry '$p' (keys: ${AL_KEYS[$i]}) no longer matches anything — remove it.$hint" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Dead-infra references found (or stale allowlist entries). AWS is decommissioned" >&2
  echo "(2026-05-31), Athena is retired (2026-04-25), profile_v3_* tables are frozen." >&2
  echo "Fix: migrate the instruction to OVH Trino — \`muso query\` with modern names" >&2
  echo "(see skills-all/muso-query-writer; scripts/trino-query.sh only for legacy-named" >&2
  echo "SQL) — or, for genuinely historical/migration content, add a" >&2
  echo "'<path> -- <keys> -- <reason>' entry to .dead-infra-allowlist.txt." >&2
  exit 1
fi

echo "OK: no live dead-infra references (skills-all/, workspaces/, cron-jobs.json; allowlist clean)."
