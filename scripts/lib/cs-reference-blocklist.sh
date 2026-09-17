#!/usr/bin/env bash
# Internal terms that must NEVER appear in Caroline's customer-facing reference
# files (workspaces/support/reference/*.md).
#
# WHY THIS IS A LIBRARY AND NOT TWO COPIES
# The list is enforced on two different paths that cannot see each other:
#   1. CI -- the "CS agent reference file security scan" step in
#      .github/workflows/pr-validate.yml, over the COMMITTED files.
#   2. The cron path -- scripts/sync-platform-llms.sh, which writes a GENERATED
#      file straight onto the server. That file is rsync-excluded and never
#      committed, so CI structurally cannot protect it.
# A second copy of the pattern would drift the moment either side gained a term,
# and the drift would be silent on exactly the path with no human review.
#
# MATCHING IS WORD-BOUNDARY, NOT SUBSTRING. An earlier revision used substring
# matching and tripped on ordinary English: "weeks" contains "EKS", "block"
# contains "BLoC", "archive" contains "Hive". Callers must apply \b...\b (the
# anchors require GNU grep, which is what runs in ubuntu-latest; BSD grep on a
# developer Mac also supports -E with \b).

CS_REFERENCE_BLOCKLIST_TERMS="PostgreSQL|MongoDB|Mongo|Vault|Kubernetes|kubectl|k3s|k8s|Docker|Airflow|Spark|Trino|MinIO|Hive|OVH|OVHcloud|Hetzner|EKS|Aurora|Jenkins|SQS|Flutter|BLoC|Dart|HYDRA|NemoClaw|OpenClaw|CLIProxyAPI|Landlock|seccomp|vRack|WireGuard|node-[1-8]|ovh-node|Cilium|Longhorn|etcd|Prometheus|Grafana|Loki|seccomp"

# The anchored pattern callers should hand to `grep -iE`.
CS_REFERENCE_BLOCKLIST_PATTERN="\\b(${CS_REFERENCE_BLOCKLIST_TERMS})\\b"

# cs_reference_blocklist_hits <file> -- print "line:match" for every blocklist
# hit in <file>. Exit 0 if any hit was found, 1 if the file is clean, so callers
# read it as "did this leak?".
#
# A grep ERROR (exit >= 2: unreadable file, or a malformed regex the moment
# someone adds a term with an unbalanced bracket) is reported as a HIT, not as
# "clean". Returning grep's status verbatim would make both call sites fail
# OPEN -- CI would print "CLEAN:" for every file and the cron path would publish
# whatever it fetched -- and a gate that silently skips what it cannot parse is
# worse than no gate, because it still reads green.
cs_reference_blocklist_hits() {
  local out rc=0
  out=$(grep -inE "$CS_REFERENCE_BLOCKLIST_PATTERN" "$1") || rc=$?
  case "$rc" in
    0) printf '%s\n' "$out"; return 0 ;;
    1) return 1 ;;
    *) printf 'ERROR: blocklist scan failed (grep exit %s) on %s -- treating as a leak\n' "$rc" "$1"; return 0 ;;
  esac
}
