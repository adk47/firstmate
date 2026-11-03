#!/usr/bin/env bash
# qa-pod-canary.sh — route ONE labelled PR's QA review to the qa-review-gateway pods
# (node8-to-pods T9 canary; program-lead-fable-p2 ruling §3(a), captain-approved 2026-10-28).
#
# SOURCED by .github/workflows/external-pr-review.yml right before it calls
# qa-dispatch-pr-review.sh:
#     source scripts/lib/qa-pod-canary.sh
#     qa_pod_canary_route "$REPO" "$PR"
#   -> rc 0 and NO env change  : the PR is not labelled  -> node-8 local path (unchanged)
#   -> rc 0 with exports       : labelled and resolved   -> QA_REVIEW_GATEWAY_URL,
#                                OPENCLAW_GATEWAY_URL and OPENCLAW_GATEWAY_TOKEN_FILE set
#   -> rc 1                    : labelled but unresolvable -> the caller FAILS the dispatch.
# A labelled PR never silently falls back to node-8: a canary that quietly ran on node-8
# would "pass" while proving nothing (the reconciler retries it after its grace window).
#
# Why a LABEL and not a repo variable: a variable flip is a click with no review and no
# diff; the label names exactly one PR, is visible on it, and removing it IS the revert
# (the next push dispatches locally). Unlabelled PRs take a byte-identical path.
#
# Address: the node-8 runner host does not resolve cluster DNS, so the URL is the
# Service's ClusterIP (routable from a k3s node), read at dispatch time. The token is the
# gateway's OWN in-cluster-minted Secret (never Caroline's), written to a 0600 file under
# $RUNNER_TEMP; it never enters argv or the log. qa_pod_canary_cleanup removes it.
#
# Env (tests): GH, KUBECTL, QA_POD_CANARY_LABEL (default qa-pod-canary),
#   QA_POD_CANARY_NS (default hydra-qa), QA_POD_CANARY_TMP (default $RUNNER_TEMP, else TMPDIR).

QA_POD_CANARY_LABEL="${QA_POD_CANARY_LABEL:-qa-pod-canary}"
QA_POD_CANARY_NS="${QA_POD_CANARY_NS:-hydra-qa}"
QA_POD_CANARY_TOKEN_FILE=""

_qpc_log() { echo "qa-pod-canary: $*" >&2; }

# qa_pod_canary_labelled <repo> <pr>: 0 labelled, 1 not labelled, 2 could not read labels.
qa_pod_canary_labelled() {
  local repo="$1" pr="$2" names
  names="$("${GH:-gh}" api "repos/${repo}/issues/${pr}/labels" --jq '.[].name' 2>/dev/null)" || return 2
  grep -qxF -- "$QA_POD_CANARY_LABEL" <<< "$names" && return 0
  return 1
}

qa_pod_canary_route() {
  local repo="$1" pr="$2" rc ip tmp tok
  qa_pod_canary_labelled "$repo" "$pr"; rc=$?
  case "$rc" in
    1) return 0 ;;
    # Unreadable labels: we cannot know whether the PR is the canary. The local path is the
    # pre-canary behaviour for every PR, so take it -- but say so, never silently.
    2) _qpc_log "could not read labels of ${repo}#${pr}; dispatching on the node-8 local path"; return 0 ;;
  esac
  ip="$("${KUBECTL:-kubectl}" -n "$QA_POD_CANARY_NS" get svc qa-review-gateway -o jsonpath='{.spec.clusterIP}' 2>/dev/null)" || ip=""
  if ! [[ "$ip" =~ ^10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    _qpc_log "${repo}#${pr} carries ${QA_POD_CANARY_LABEL} but Service ${QA_POD_CANARY_NS}/qa-review-gateway has no usable ClusterIP ('${ip}') -- refusing (no silent node-8 fallback)"
    return 1
  fi
  tmp="${QA_POD_CANARY_TMP:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
  QA_POD_CANARY_TOKEN_FILE="$(umask 077; mktemp "$tmp/qa-gw-token.XXXXXX")" || { _qpc_log "mktemp under $tmp failed"; return 1; }
  # base64 -d on a pipe: the token never reaches argv.
  if ! tok="$("${KUBECTL:-kubectl}" -n "$QA_POD_CANARY_NS" get secret qa-review-gateway-token -o jsonpath='{.data.token}' 2>/dev/null)" \
     || [ -z "$tok" ] || ! printf '%s' "$tok" | base64 -d > "$QA_POD_CANARY_TOKEN_FILE" 2>/dev/null \
     || [ ! -s "$QA_POD_CANARY_TOKEN_FILE" ]; then
    unset tok
    _qpc_log "${repo}#${pr} carries ${QA_POD_CANARY_LABEL} but Secret ${QA_POD_CANARY_NS}/qa-review-gateway-token is unreadable -- refusing"
    qa_pod_canary_cleanup
    return 1
  fi
  unset tok
  export QA_REVIEW_GATEWAY_URL="ws://${ip}:18789"
  export OPENCLAW_GATEWAY_URL="$QA_REVIEW_GATEWAY_URL"
  export OPENCLAW_GATEWAY_TOKEN_FILE="$QA_POD_CANARY_TOKEN_FILE"
  _qpc_log "${repo}#${pr} carries ${QA_POD_CANARY_LABEL}: routing this review to the qa-review-gateway pods (${QA_REVIEW_GATEWAY_URL})"
  return 0
}

qa_pod_canary_cleanup() {
  [ -n "${QA_POD_CANARY_TOKEN_FILE:-}" ] && rm -f "$QA_POD_CANARY_TOKEN_FILE"
  QA_POD_CANARY_TOKEN_FILE=""
  return 0
}
