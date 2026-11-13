#!/usr/bin/env bash
# replica-serve.sh - a drop-in for trino-query.sh (SQL on stdin, CSV on stdout) that answers from the send gate's
# per-person replica read when it holds the EXACT statement, and runs the real trino-query.sh otherwise.
#
# Only scripts/intercom-verify-request.sh points a helper at it, and only for the one gate call whose read it holds
# (credit_review/gate_facts.py; the why and the measurement: docs/credit-verification/gate-replica-read.md).
# Both paths below come from this file's own location, never from the caller: the real wrapper is the trino-query.sh
# beside it, and the logic is credit_review/replica_batch.py beside it. The one thing a caller names is WHERE the
# read is (REPLICA_BATCH_FACTS); a missing, stale or malformed one means every statement is run live.
set -uo pipefail
here="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
py=/usr/bin/python3; [ -x "$py" ] || py="$(command -v python3)"
exec "$py" -I "$here/credit_review/replica_batch.py" serve --live "$here/trino-query.sh"
