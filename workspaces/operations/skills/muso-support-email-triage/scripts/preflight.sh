#!/usr/bin/env bash
# Preflight for muso-support-email-triage. Sourceable so WORKDIR survives into
# the rest of the pipeline (preflight -> fetch -> classify -> format must run in
# one shell session).
#
# Exports on success:
#   WORKDIR — mktemp -d (mode 700); INT/TERM cleanup trap installed in the
#             CALLER's shell so an interrupted or cron-timed-out run scrubs the
#             customer PII written under it. Normal-path teardown is the caller's
#             final `rm -rf "$WORKDIR"` (done by format-digest.sh), because the
#             LLM classify step and Phase-3 reconciliation read the fetch data
#             between preflight and teardown.
#
# Does NOT handle GOG_KEYRING_PASSWORD: it is already in the gateway service env
# (/etc/openclaw/main.env) and inherited by the operations runtime; the
# b2b-reply-scanner and weekly-google-token-refresh crons rely on the same.

set -euo pipefail

# 0. One kill file for every support@ Gmail reader (firstmate 10-31: a deploy re-enables a disabled cron, an
# /etc file survives it). Present = this run reads nothing from support@.
# A constant, never an env var (r5 [key=unattended]: a kill path the environment can move is a bypass).
GMAIL_READERS_KILL="/etc/hydra/gmail-readers.disabled"
if [ -e "$GMAIL_READERS_KILL" ]; then
  echo "preflight failed: support@ Gmail readers disabled ($GMAIL_READERS_KILL)" >&2
  return 1 2>/dev/null || exit 1
fi

# 1. Required tools.
for tool in gog python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "preflight failed: missing required tool: $tool" >&2
    return 1 2>/dev/null || exit 1
  }
done

# 2. support@muso.ai must be authenticated in gog. Until the mailbox is
# provisioned this is the expected stop point — the skill surfaces the exact
# message below and halts (safe to ship pre-provisioning).
if ! gog auth list --json 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if "support@muso.ai" in [a.get("email") for a in d.get("accounts",[])] else 1)'; then
  echo "preflight failed: support@muso.ai not authenticated in gog (run: gog auth add support@muso.ai)" >&2
  return 1 2>/dev/null || exit 1
fi

# 3. WORKDIR — caller owns lifetime when sourced. The INT/TERM trap set while
# SOURCED lives in the caller's shell and fires on signal (not on this script's
# return), so downstream steps still see $WORKDIR but a killed/timed-out run no
# longer leaves customer email bodies in /tmp. When run as a subprocess (not
# sourced) we also clean on EXIT.
umask 077
WORKDIR=$(mktemp -d -t "support-triage-XXXXXX")
chmod 700 "$WORKDIR"
export WORKDIR
trap 'rm -rf "$WORKDIR"' INT TERM
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  trap 'rm -rf "$WORKDIR"' EXIT INT TERM
fi

echo "preflight: ok (workdir=$WORKDIR window=${SUPPORT_TRIAGE_WINDOW_MIN:-65}min)"
