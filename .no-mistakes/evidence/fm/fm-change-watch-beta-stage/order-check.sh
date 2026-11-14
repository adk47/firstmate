#!/usr/bin/env bash
# Evidence driver: exercises the beta stage of bin/fm-change-watch.sh through its
# public CLI (register / verdict / status) and prints the real console output plus
# the files the stage persists. Lives in the evidence dir, never in the repo.
set -u
cd /home/aaron/.no-mistakes/worktrees/72295860b10d/01M7CWEZA2K1SJ3VVR0TZEJRQQ || exit 1
# shellcheck source=tests/lib.sh
. "$PWD/tests/lib.sh"
CW="$PWD/bin/fm-change-watch.sh"
TMP_ROOT=$(fm_test_tmproot evidence-beta)
PR_URL='https://github.com/Muso-AI/H-DevOps/pull/3317'
MANIFEST='k8s/prod/core-services/deployments.yaml'
new_world() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/forge/content" "$home/cluster"
  cat > "$home/arm.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CW_ARM_LOG"
STUB
  cat > "$home/send.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CW_SEND_LOG"
STUB
  chmod +x "$home/arm.sh" "$home/send.sh"
  printf '%s\n' "$home"
}

run_cw() {
  local home=$1 now=$2
  shift 2
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CW_NOW="$now" \
    FM_CW_FORGE_DIR="$home/forge" FM_CW_CLUSTER_DIR="${CW_CLUSTER_DIR-$home/cluster}" \
    FM_CW_ARM_CMD="$home/arm.sh" FM_CW_ARM_LOG="$home/arm.log" \
    FM_CW_SEND_CMD="$home/send.sh" FM_CW_SEND_LOG="$home/send.log" \
    FM_CW_TRACE="$home/trace" \
    FM_CW_NO_WIKI=1 FM_CW_SLEEP_CMD="${CW_SLEEP:-true}" \
    "$CW" "$@"
}

seed_pr() {
  local home=$1 manifest=$2 body=$3
  shift 3
  : > "$home/forge/files.txt"
  local f
  for f in "$@"; do printf '%s\n' "$f" >> "$home/forge/files.txt"; done
  printf '%s\n' 1790000000 > "$home/forge/merge-epoch"
  printf '%s\n' deadbeefcafe > "$home/forge/head-ref"
  mkdir -p "$home/forge/content/$(dirname "$manifest")"
  cp "$body" "$home/forge/content/$manifest"
}

cluster_world() {
  local home
  home=$(new_world "$1")
  mkdir -p "$home/bin" "$home/config" "$home/sentry"
  cat > "$home/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\t%s\n' "${KUBECONFIG:-}" "$*" >> "$FM_CW_SHIM_LOG"
case " $* " in
  *" --raw=/version "*) printf '{"gitVersion":"v1.31.0"}\n' ;;
  *" get deploy -A "*)
    [ -z "${FM_CW_SHIM_WORKLOADS:-}" ] || cat "$FM_CW_SHIM_WORKLOADS"
    ;;
  *" get pods "*)
    app=$(printf '%s' "$*" | sed -n 's/.*app=\([^ ]*\).*/\1/p')
    [ -z "${FM_CW_SHIM_PODS_FAIL:-}" ] || exit 1
    hash=${FM_CW_SHIM_HASH:-h1}
    if [ -n "${FM_CW_SHIM_HASH_FILE:-}" ] && [ -f "$FM_CW_SHIM_HASH_FILE" ]; then
      hash=$(cat "$FM_CW_SHIM_HASH_FILE")
    fi
    last='{}'
    [ -z "${FM_CW_SHIM_OOM_AT:-}" ] || last="{\"terminated\":{\"reason\":\"OOMKilled\",\"finishedAt\":\"$(date -u -d "@$FM_CW_SHIM_OOM_AT" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '1970-01-01T00:00:00Z')\"}}"
    printf '{"items":[{"metadata":{"name":"%s-1","labels":{"pod-template-hash":"%s"}},"spec":{"containers":[{"name":"c","image":"%s","resources":{"limits":{"memory":"512Mi"}}}]},"status":{"containerStatuses":[{"name":"c","restartCount":0,"lastState":%s}]}}]}\n' \
      "$app" "$hash" "${FM_CW_SHIM_IMAGE:-}" "$last"
    ;;
  *" top pods "*) printf '%s-1   c   100m   128Mi\n' "$(printf '%s' "$*" | sed -n 's/.*app=\([^ ]*\).*/\1/p')" ;;
  *" logs "*) : ;;
  *" set env "*) printf 'ENV=production\n' ;;
  *) exit 1 ;;
esac
SHIM
  chmod +x "$home/bin/kubectl"
  printf '%s\n' "$home"
}

beta_before_prod() {  # <trace-file>
  awk -F'\t' '
    $1 == "prod" && !seen_prod { seen_prod = NR }
    $1 == "beta" {
      seen_beta = 1
      if (seen_prod) {
        printf "beta read after the production read on line %d: %s %s\n", seen_prod, $2, $3
        bad = 1
        exit
      }
    }
    END {
      if (bad) exit
      if (!seen_beta) print "no beta read was made at all"
      else if (!seen_prod) print "no production read was made at all, so the ordering proves nothing"
      else print "ok"
    }
  ' "$1"
}

seed_beta_world() {
  local home
  home=$(cluster_world "$1")
  mkdir -p "$home/workloads"
  printf 'src/routes/credits.ts\n' > "$home/forge/files.txt"
  printf '%s\n' 1790000000 > "$home/forge/merge-epoch"
  printf '%s\n' deadbeef > "$home/forge/head-ref"
  : > "$home/forge/diff.txt"
  printf 'muso-prod\tcredits-gate\t2\tregistry.muso.ai/muso/web-credits-next:1.2.3\n' \
    > "$home/workloads/workloads"
  # The beta target runs the pre-merge pods until the rollout lands.
  printf 'h1\n' > "$home/hash"
  cat > "$home/rollout.sh" <<'SH'
#!/usr/bin/env bash
printf 'h2\n' > "$FM_CW_SHIM_HASH_FILE"
SH
  chmod +x "$home/rollout.sh"
  printf '%s\n' "$home"
}

run_beta() {
  local home=$1 now=$2
  shift 2
  CW_SLEEP="$home/rollout.sh" \
  PATH="$home/bin:$PATH" FM_CW_SHIM_LOG="$home/shim.log" \
  FM_CW_SHIM_WORKLOADS="$home/workloads/workloads" \
  FM_CW_SHIM_IMAGE='registry.muso.ai/muso/web-credits-next:1.2.3' \
  FM_CW_SHIM_HASH_FILE="$home/hash" \
  FM_CW_WORKLOADS_DIR="$home/workloads" \
  FM_CW_BETA_WAIT_ATTEMPTS="${BETA_ATTEMPTS:-5}" \
  run_cw "$home" "$now" "$@"
}

seed_beta_series() {
  printf '%s\n' "$3" > "$1/cluster/$2.muso-dev_credits-gate.baseline"
  printf '%s\n' "$4" > "$1/cluster/$2.muso-dev_credits-gate.sample"
}

seed_clean_beta() {
  seed_beta_series "$1" restarts 0 0
  seed_beta_series "$1" oomkilled 0 0
  seed_beta_series "$1" rss_ratio 0.4 0.4
  seed_beta_series "$1" http_5xx_per_min 0 0
  seed_beta_series "$1" p95_ms 100 100
}

seed_beta_regression() {
  seed_clean_beta "$1"
  seed_beta_series "$1" "$2" "$3" "$4"
}

# usage: order-check.sh <path-to-fm-change-watch.sh> <label>
# Runs only the ordering contract case: a web-credits-next route change must be
# read in beta before any production target, asserted from the FM_CW_TRACE record.
CW_UNDER_TEST=$1
label=$2
CW="$CW_UNDER_TEST"
export FM_ROOT_OVERRIDE=/home/aaron/.no-mistakes/worktrees/72295860b10d/01M7CWEZA2K1SJ3VVR0TZEJRQQ
printf '\n----- %s -----\n' "$label"
printf 'script under test: %s\n' "$CW_UNDER_TEST"
HOME_X=$(seed_beta_world x)
seed_clean_beta "$HOME_X"
printf 'registration line: '
run_beta "$HOME_X" 1790000000 register x \
  'https://github.com/Muso-AI/web-credits-next/pull/77' 2>&1 | tail -1
printf 'read order (count stage):\n'
cut -f1 "$HOME_X/trace" | uniq -c | sed 's/^/  /'
printf 'first read is a %s read of %s\n' \
  "$(head -1 "$HOME_X/trace" | cut -f1)" "$(head -1 "$HOME_X/trace" | cut -f3)"
printf 'beta_before_prod -> %s\n' "$(beta_before_prod "$HOME_X/trace")"
