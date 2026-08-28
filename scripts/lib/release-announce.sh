#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# release-announce.sh — sourced helper that renders a release into the
# #releases Block Kit message and posts it via the audited devops bot.
#
# Split out of release.sh so ONE renderer serves every repo. The payload
# is still built in Python rather than bash heredocs: commit subjects
# routinely carry apostrophes, quotes, backticks and em-dashes, and
# jq/heredoc escaping is what broke api-evidence.sh on 2026-05-07.
#
# Usage:
#   source /opt/hydra/scripts/lib/release-announce.sh
#   RA_EMOJI=🌐 RA_DISPLAY="muso.ai web" ... \
#     release_announce_build_payload /tmp/payload.json
#   release_announce_post /tmp/payload.json
#
# Inputs (env, all read by the builder):
#   RA_CHANNEL        target channel id (default: $SLACK_CHANNEL)
#   RA_EMOJI          leading glyph, e.g. 🌐
#   RA_DISPLAY        human name, e.g. "muso.ai web"
#   RA_VERSION        e.g. v2026.8.27
#   RA_RELEASE_URL    GitHub release page
#   RA_COMPARE_URL    GitHub compare view
#   RA_ROLLBACK_URL   runbook link for undoing this release
#   RA_NOTES_FILE     the markdown release notes release.sh rendered
#   RA_HIGHLIGHTS_FILE  optional; one plain-language highlight per line.
#                     When absent or empty the message degrades to the
#                     deterministic conventional-commit sections and says
#                     so. A release is NEVER left unannounced because the
#                     highlight-writing step failed (fail loud, not silent).
#   RA_STATS          optional context line, e.g. "38 PRs · 4 authors"
#   RA_FOOTER         optional footer, e.g. "prod-20260827-1035 · a1b2c3d"
# ──────────────────────────────────────────────────────────────

_RA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# release_announce_build_payload <out-file>
release_announce_build_payload() {
  local out="$1"
  [[ -n "$out" ]] || { echo "release_announce_build_payload: no output path" >&2; return 1; }
  [[ -r "${RA_NOTES_FILE:-}" ]] || { echo "release_announce_build_payload: RA_NOTES_FILE unreadable: ${RA_NOTES_FILE:-<unset>}" >&2; return 1; }

  RA_CHANNEL="${RA_CHANNEL:-${SLACK_CHANNEL:-}}" \
  python3 "$_RA_LIB_DIR/release_blockkit.py" "$out"
}

# release_announce_post <payload-file>
# Returns 0 ONLY on a post Slack confirmed. Delivery stays best-effort in
# POLICY -- the release is already tagged and published by the time we get
# here, so the caller deliberately continues on failure -- but the caller
# must be able to SEE the failure to log it. slack_notify_payload_file
# swallows the status and always returns 0, which made every
# `release_announce_post ... || warn` unreachable; the _status variant is
# the one that reports.
release_announce_post() {
  local payload="$1"
  # shellcheck source=slack-notify.sh
  source "$_RA_LIB_DIR/slack-notify.sh"
  slack_notify_payload_file_status "$payload"
}
