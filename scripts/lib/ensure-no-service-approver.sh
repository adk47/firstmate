#!/usr/bin/env bash
# ensure-no-service-approver.sh — keep Caroline's approval-tier writes shut across deploys.
#
# Why (firstmate stop switch, 2026-10-27): the synthetic service approver
# `caroline-autonomous` let the edge support agent approve credits (credits_verify),
# merge profiles (profiles_consolidate) and verify claims (profiles_claim_self) with
# no person in the loop. Firstmate removed it from node-8 at 09:31Z; the 13:16Z
# deploy re-installed it from the repo, and Caroline made 8 more credits_verify
# calls that afternoon (core refused every one). Captain order 2026-10-26 23:30Z:
# nothing approves without a recorded decision.
#
# Three surfaces carry it, and all three must stay empty:
#   1. the repo source  workspaces/operations/skills/muso-ops-admin/config/capability-approvers.txt
#   2. the installed    /root/.config/muso/capability-approvers.txt (deploy.sh renders 1 -> 2)
#   3. the edge env     /etc/openclaw/edge.env MUSO_CAPABILITY_APPROVER= (verify-credit.sh /
#                       consolidate.sh pass it as --confirmed-by; unset = no_approver, fail closed)
#
# Modes:
#   --check-repo FILE   exit 1 if FILE lists any approver (non-comment, non-blank line).
#                       PR Validation runs this on the repo source.
#   --check-host        read-only: exit 1 if surface 2 lists an approver or surface 3 sets
#                       MUSO_CAPABILITY_APPROVER. For watchdogs and post-deploy checks.
#   --verify-installed  deploy, after the render: exit 1 if surface 2 lists an approver.
#   --strip-edge-env    deploy: remove a MUSO_CAPABILITY_APPROVER line from edge.env
#                       (timestamped backup, same mode, atomic rename). The edge gateway reads
#                       its env at start, so the deploy's gateway restart drops it from the
#                       process; until then the empty installed file already refuses every
#                       --confirmed-by, so the switch holds either way.
#
# Paths are overridable for tests: CAP_APPROVERS_DEST, EDGE_ENV_FILE.
# Exit: 0 clean / 1 violation (or refused) / 2 usage or unreadable input.
set -euo pipefail

DEST="${CAP_APPROVERS_DEST:-/root/.config/muso/capability-approvers.txt}"
EDGE_ENV="${EDGE_ENV_FILE:-/etc/openclaw/edge.env}"

# Approver entries: every line that is not blank and not a comment. Echoes them (one per line).
entries() {
  local f="$1"
  # A missing file is "no approver" for the installed copy (muso-cli fails closed on it too).
  [ -e "$f" ] || return 0
  [ -r "$f" ] || { echo "unreadable: $f" >&2; return 2; }
  grep -vE '^[[:space:]]*(#|$)' "$f" || true
}

has_env_approver() {
  [ -e "$EDGE_ENV" ] || return 1
  [ -r "$EDGE_ENV" ] || { echo "unreadable: $EDGE_ENV" >&2; return 2; }
  grep -qE '^[[:space:]]*(export[[:space:]]+)?MUSO_CAPABILITY_APPROVER=' "$EDGE_ENV"
}

check_repo() {
  local f="$1" e
  [ -r "$f" ] || { echo "ensure-no-service-approver: repo source missing or unreadable: $f" >&2; return 2; }
  e=$(entries "$f") || return 2
  if [ -n "$e" ]; then
    echo "ensure-no-service-approver: VIOLATION: $f lists $(printf '%s\n' "$e" | wc -l | tr -d ' ') approver(s): $(printf '%s' "$e" | tr '\n' ' ')" >&2
    echo "  Caroline's approval-tier writes stay shut (captain 2026-10-26 23:30Z). Remove the entry; re-opening is a recorded captain decision." >&2
    return 1
  fi
  echo "ensure-no-service-approver: repo source clean ($f)"
}

check_host() {
  local bad=0 e rc=0
  e=$(entries "$DEST") || return 2
  if [ -n "$e" ]; then
    echo "ensure-no-service-approver: VIOLATION: installed $DEST lists: $(printf '%s' "$e" | tr '\n' ' ')" >&2
    bad=1
  fi
  has_env_approver || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "ensure-no-service-approver: VIOLATION: $EDGE_ENV sets MUSO_CAPABILITY_APPROVER" >&2
    bad=1
  elif [ "$rc" -eq 2 ]; then
    return 2
  fi
  [ "$bad" -eq 0 ] && echo "ensure-no-service-approver: host clean ($DEST, $EDGE_ENV)"
  return "$bad"
}

strip_env() {
  local rc=0 ts tmp mode
  has_env_approver || rc=$?
  [ "$rc" -eq 2 ] && return 2
  if [ "$rc" -ne 0 ]; then
    echo "ensure-no-service-approver: $EDGE_ENV has no MUSO_CAPABILITY_APPROVER (nothing to do)"
    return 0
  fi
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  cp -p "$EDGE_ENV" "$EDGE_ENV.bak-no-service-approver-$ts"
  tmp=$(mktemp "$EDGE_ENV.tmp.XXXXXX")
  grep -vE '^[[:space:]]*(export[[:space:]]+)?MUSO_CAPABILITY_APPROVER=' "$EDGE_ENV" > "$tmp" || true
  mode=$(stat -c '%a' "$EDGE_ENV" 2>/dev/null || stat -f '%Lp' "$EDGE_ENV")
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$EDGE_ENV"
  echo "ensure-no-service-approver: removed MUSO_CAPABILITY_APPROVER from $EDGE_ENV (backup $EDGE_ENV.bak-no-service-approver-$ts; takes effect at the edge gateway restart)"
}

case "${1:-}" in
  --check-repo)
    [ -n "${2:-}" ] || { echo "usage: $0 --check-repo FILE" >&2; exit 2; }
    check_repo "$2"
    ;;
  --check-host)
    check_host
    ;;
  --verify-installed)
    e=$(entries "$DEST") || exit 2
    if [ -n "$e" ]; then
      echo "ensure-no-service-approver: VIOLATION: installed $DEST lists: $(printf '%s' "$e" | tr '\n' ' ')" >&2
      exit 1
    fi
    echo "ensure-no-service-approver: installed $DEST lists no approver"
    ;;
  --strip-edge-env)
    strip_env
    ;;
  *)
    echo "usage: $0 --check-repo FILE | --check-host | --verify-installed | --strip-edge-env" >&2
    exit 2
    ;;
esac
