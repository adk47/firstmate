#!/usr/bin/env bash
# Stub for muso-admin-api.sh. Returns canned admin-API profile responses.
# Real shape: {body: {data: {...camelCase fields...}}, http_status}.
set -euo pipefail
if [ "${1:-}" = "call" ] && [ "${2:-}" = "GET" ]; then
  path="${3:-}"
  case "$path" in
    /admin/profile/aaaa-aaaa)
      cat <<'EOF'
{"body":{"code":"OK","result":"ok","data":{"id":"aaaa-aaaa","name":"Ali Zain","legalName":"","knownAsNames":[],"rawProfiles":[{"source":"spotify","id":"abc"}],"ipis":[],"popularity":50,"creditCount":38,"country":"US","isClaimed":true,"claiming":{"userId":"12345","status":"processed"}}},"http_status":200}
EOF
      ;;
    /admin/profile/bbbb-bbbb)
      cat <<'EOF'
{"body":{"code":"OK","result":"ok","data":{"id":"bbbb-bbbb","name":"Ali Z.","legalName":"","knownAsNames":[],"rawProfiles":[{"source":"spotify","id":"abc"}],"ipis":[],"popularity":12,"creditCount":7,"country":"US","isClaimed":false,"claiming":null}},"http_status":200}
EOF
      ;;
    /admin/profile/eeee-eeee)
      cat <<'EOF'
{"body":{"code":"OK","result":"ok","data":{"id":"eeee-eeee","name":"No IDs","legalName":"","knownAsNames":[],"rawProfiles":[],"ipis":[],"popularity":0,"creditCount":0,"country":"US","isClaimed":false,"claiming":null}},"http_status":200}
EOF
      ;;
    *) echo "stub: unknown path $path" >&2; exit 1 ;;
  esac
fi
