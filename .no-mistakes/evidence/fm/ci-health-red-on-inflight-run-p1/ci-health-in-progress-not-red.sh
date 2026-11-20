#!/usr/bin/env bash
# Reproduce the 2026-11-19 incident shape against the real CI health check CLI:
# the newest run of each workflow is still in progress (conclusion null), so the
# check must stay silent, and a genuinely completed failure must still page.
set -u
ROOT=${1:?repo root}
CHECK="$ROOT/bin/fm-ci-health-check.sh"
HOME_DIR=$(mktemp -d)
trap 'rm -rf "$HOME_DIR"' EXIT
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/api" "$HOME_DIR/fakebin"
cat > "$HOME_DIR/fakebin/gh" <<SH
#!/usr/bin/env bash
[ "\$1" = api ] || exit 1
f="$HOME_DIR/api/\$(printf '%s' "\$2" | tr '/?&=' '____')"
[ -f "\$f" ] || exit 1
cat "\$f"
SH
chmod +x "$HOME_DIR/fakebin/gh"
fixture() { printf '%s\n' "$2" > "$HOME_DIR/api/$(printf '%s' "$1" | tr '/?&=' '____')"; }
fixture rate_limit '{"resources":{"core":{"remaining":4000}}}'
fixture 'repos/acme/widgets/actions/runs?status=queued&per_page=1' '{"total_count":0}'

# Two active workflows. The API endpoint the check reads is status=completed,
# so runs still in progress are not returned at all; the fixtures below hold
# only the answers each workflow has actually given.
fixture 'repos/acme/widgets/actions/workflows?per_page=100&page=1' '{"total_count":2,"workflows":[{"id":1001,"name":"verify-devops-agent-tests","state":"active"},{"id":1002,"name":"Verify: pin-bump PRs run CI","state":"active"}]}'

echo '=== 1. Classifier: a run whose conclusion is null has not answered yet ==='
for pair in 'in_progress null' 'queued null' 'completed null' 'completed failure' 'completed success'; do
  set -- $pair
  printf 'status=%-12s conclusion=%-8s -> %s\n' "$1" "$2" "$("$CHECK" classify "$1" "${2/null/}")"
done

echo
echo '=== 2. Poll while the newest runs are in progress, last answers green ==='
# One row carries a null conclusion even at status=completed: the API edge
# case the incident exposed must still read as pending, never red.
fixture 'repos/acme/widgets/actions/workflows/1001/runs?branch=main&status=completed&per_page=30' '{"workflow_runs":[{"id":44632777885,"name":"verify-devops-agent-tests","status":"completed","conclusion":null,"created_at":"2026-11-19T22:53:30Z","head_sha":"a1ba56fdf0000","event":"push"},{"id":44623276585,"name":"verify-devops-agent-tests","status":"completed","conclusion":"success","created_at":"2026-11-19T21:53:33Z","head_sha":"a9d29e8800000","event":"push"}]}'
fixture 'repos/acme/widgets/actions/workflows/1002/runs?branch=main&status=completed&per_page=30' '{"workflow_runs":[{"id":44616463852,"name":"Verify: pin-bump PRs run CI","status":"completed","conclusion":"success","created_at":"2026-11-19T21:12:46Z","head_sha":"8da6a08bd0000","event":"push"}]}'
out=$(env PATH="$HOME_DIR/fakebin:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_CI_HEALTH_NOW=100000 FM_CI_HEALTH_TOKEN_ENV=none \
  FM_CI_HEALTH_PER_PAGE=30 FM_CI_HEALTH_REPOS='acme/widgets:main:10' FM_CI_HEALTH_SCHEDULED=' ' "$CHECK" check 2>&1)
printf 'stdout: %s\n' "${out:-<empty: no red reported>}"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$CHECK" status

echo
echo '=== 3. Next poll: verify-devops-agent-tests actually concluded failure ==='
fixture 'repos/acme/widgets/actions/workflows/1001/runs?branch=main&status=completed&per_page=30' '{"workflow_runs":[{"id":44632777885,"name":"verify-devops-agent-tests","status":"completed","conclusion":"failure","created_at":"2026-11-19T22:53:30Z","head_sha":"a1ba56fdf0000","event":"push"},{"id":44623276585,"name":"verify-devops-agent-tests","status":"completed","conclusion":"success","created_at":"2026-11-19T21:53:33Z","head_sha":"a9d29e8800000","event":"push"}]}'
out=$(env PATH="$HOME_DIR/fakebin:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_CI_HEALTH_NOW=100900 FM_CI_HEALTH_TOKEN_ENV=none \
  FM_CI_HEALTH_PER_PAGE=30 FM_CI_HEALTH_REPOS='acme/widgets:main:10' FM_CI_HEALTH_SCHEDULED=' ' "$CHECK" check 2>&1)
printf 'stdout: %s\n' "$out"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$CHECK" status
