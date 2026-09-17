#!/usr/bin/env bash
set -euo pipefail

# sync-platform-llms.sh -- keep Caroline current on platform.muso.ai.
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS
# Caroline's Platform knowledge was hand-copied into reference/api-access.md on
# 2026-07-01 and then rotted in place for ten weeks: it called Platform a
# "coming" self-service tier (it launched publicly on 2026-07-09) and quoted a
# ~$3,000 custom-contract ballpark that the 2026-08-06 commercial lock
# superseded. Customers were told both. The lesson is already written down in
# this repo, in support-changelog-sync.sh: "Hand-maintained is why it went
# stale."
#
# So the numbers are not copied here. They are fetched from the page the
# platform team already publishes for machine readers:
#   https://platform.muso.ai/llms-full.txt
# whose own header states the property that makes it safe to depend on --
# "Numbers come from the canonical pricing module -- never hardcoded"
# (platform-web app/llms.txt/route.ts). When pricing changes in that module,
# this feed changes with it.
#
# WHY THERE IS NO LEAK GATE AND NO PROMOTE FLOW
# support-changelog-sync.sh stages its output for human review because its input
# is author-controlled PR titles passed through a language model -- untrusted
# text that has never been read by anyone. This input is the opposite: it is
# first-party marketing/API copy that Muso already serves to the public
# internet. A human reviewed it when they shipped the page. Gating it again
# would only guarantee that Caroline's copy is older than the customer's.
#
# What DOES still apply, and is enforced below:
#   FAIL-CLOSED -- a failed, empty, truncated or unrecognisable fetch leaves the
#     previous file byte-for-byte intact and exits nonzero. Slightly stale
#     pricing is recoverable; an empty KB file, or a 404 body rendered as
#     product truth, is not.
#   THE CI BLOCKLIST RUNS HERE -- this file is rsync-excluded and never
#     committed, so the "CS agent reference file security scan" in
#     pr-validate.yml structurally cannot see it. The pattern is SHARED from
#     lib/cs-reference-blocklist.sh rather than copied, because two copies drift
#     and the drift would be silent on the unreviewed path.
#   NO EM-DASHES -- lint-no-em-dash.sh greps the workspaces/support DIRECTORY,
#     so it cannot see a server-generated file either. Honour the rule rather
#     than exploit the blind spot: em-dashes are normalised to " -- ".
#
# WHERE IT LANDS
# workspaces/support/reference/ is the ONLY directory Caroline's RAG index
# reads (openclaw-edge.json: support.memorySearch.extraPaths=["reference"]), and
# she runs on edge with tools.deny=["exec"] and no Slack bindings, so a file in
# that directory is the only way to reach her. That also means the deploy rsync
# would delete it: scripts/deploy.sh carries a matching
# --exclude='workspaces/support/reference/platform-api.md'.
#
# Usage:
#   sync-platform-llms.sh              # fetch, validate, install
#   sync-platform-llms.sh --dry-run    # render to stdout, write nothing
#   sync-platform-llms.sh --check      # exit 0 if the installed file is current
#   sync-platform-llms.sh --help
#
# Exit: 0 ok | 1 refused or drifted (file untouched) | 2 usage/config error.

URL="${PLATFORM_LLMS_URL:-https://platform.muso.ai/llms-full.txt}"
OUT="${PLATFORM_LLMS_OUT:-/opt/hydra/workspaces/support/reference/platform-api.md}"

# Size envelope. The floor rejects a truncated or empty response; the live body
# was 5,761 bytes on 2026-09-16, so 1200 leaves room for the page to shrink
# without admitting a stub. The ceiling bounds what lands in the RAG index if
# the route is ever replaced by something enormous.
MIN_BYTES="${PLATFORM_LLMS_MIN_BYTES:-1200}"
MAX_BYTES="${PLATFORM_LLMS_MAX_BYTES:-65536}"

# Sanity markers. A 404 page, a maintenance splash or a redirect body can clear
# a size check; none of them carry BOTH of these. They are the two most stable
# strings on the page: the API host and the auth header.
MARKER_HOST="api.platform.muso.ai/v1"
MARKER_AUTH="x-api-key"

CURL_TIMEOUT="${PLATFORM_LLMS_TIMEOUT:-25}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cs-reference-blocklist.sh
. "$SELF_DIR/lib/cs-reference-blocklist.sh"

MODE="install"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE="dry-run" ;;
    --check)   MODE="check" ;;
    # Print the header block, anchored on its LAST line rather than a line
    # count. A hardcoded range silently truncates or overshoots the moment
    # anyone adds a line to the comment block above, and no test would catch it.
    -h|--help) sed -n '/^# Exit:/q;p' "${BASH_SOURCE[0]}"; sed -n '/^# Exit:/p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "sync-platform-llms.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

# notify <text> -- best-effort Slack post to #cs_chats as the OPERATIONS bot.
#
# The channel and the bot are NOT independent knobs: the devops bot that
# slack-notify.sh defaults to is not a member of #cs_chats and its token cannot
# even resolve the ID, so the right channel with the wrong bot is a message
# nobody receives (learned the hard way by support-changelog-sync.sh).
#
# Both are set inside a SUBSHELL rather than as an env prefix on the call. An
# assignment prefixed to a shell FUNCTION persists in the calling shell in bash
# -- it does not scope the way it does for an external command -- so the prefix
# form would silently repoint any later slack_notify in this script.
#
# Never fails the caller: by the time either call site runs, the outcome it is
# reporting has already happened.
notify() {
  [ -z "${PLATFORM_LLMS_NO_NOTIFY:-}" ] || return 0
  [ -f "$SELF_DIR/lib/slack-notify.sh" ] || return 0
  # shellcheck source=lib/slack-notify.sh
  . "$SELF_DIR/lib/slack-notify.sh" 2>/dev/null || return 0
  command -v slack_notify >/dev/null 2>&1 || return 0
  (
    export SLACK_CHANNEL="${PLATFORM_LLMS_SLACK_CHANNEL:-C0ANM0PN9L5}"
    export SLACK_NOTIFY_BOT="${PLATFORM_LLMS_SLACK_BOT:-operations}"
    slack_notify "$1"
  ) >/dev/null 2>&1 || true
}

# die <reason> -- refuse, leaving the previous file in place, and SAY SO.
#
# A refusal that only writes stderr is a silent freeze: this runs as a
# Type=oneshot daily timer, so stderr is nobody's inbox, and the failure mode it
# produces -- Caroline confidently quoting last-known pricing forever -- is
# exactly the ten-week rot this script exists to end. support-changelog-sync.sh
# pages on the same reasoning. Only the INSTALL path pages: --dry-run and
# --check are run by a human who is already reading the output.
die() {
  echo "sync-platform-llms.sh: $*" >&2
  [ "$MODE" != "install" ] || notify ":warning: *Caroline's platform.muso.ai pricing/API feed did not update* on node-8 -- $*. She is still answering from the last good copy of \`$OUT\`, so her Platform figures are frozen at whatever it already said. Re-run: \`/opt/hydra/scripts/sync-platform-llms.sh --dry-run\`"
  exit 1
}

# The comparable part of a rendered file: everything from the '---' separator
# down, i.e. the fetched content without our provenance header. The header
# carries a render timestamp that changes every run, so comparing whole files
# would report drift on every invocation. Defined ONCE: --check and the
# changed-detection below must agree on what "the same content" means, and two
# copies of this would drift silently the day the separator changes.
body() { sed -n '/^---$/,$p' "$1"; }

TMPDIR_RUN="$(mktemp -d)"
# The staging name for the atomic install. It lives NEXT TO $OUT (rename is only
# atomic within a filesystem), which means it lives inside Caroline's
# reference/ directory -- a directory whose deploy rsync exclude is the exact
# name `platform-api.md`, not a prefix. A leftover `platform-api.md.tmp.<pid>`
# is therefore an untracked would-delete server file under workspaces/, which
# reds the Step 4a pre-flight on EVERY open PR until someone removes it by hand
# (see the exclude comment in scripts/deploy.sh). So it is reaped on every exit
# path, not just the happy one. Empty until the install step names it.
TMP_INSTALL=""
cleanup() { rm -rf "$TMPDIR_RUN"; [ -z "$TMP_INSTALL" ] || rm -f "$TMP_INSTALL"; }
# Armed INSIDE the script body, not only at file scope, so a signalled run still
# clears the scratch copies. INT/TERM get their OWN traps that EXIT: a handler
# that merely cleans up lets bash resume at the next command with the scratch
# dir already deleted, so a systemd TimeoutStartSec kill would carry on into the
# install step with no render to install.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
RAW="$TMPDIR_RUN/raw.txt"
RENDER="$TMPDIR_RUN/render.md"

# ── fetch ────────────────────────────────────────────────────────────────────
# --fail turns an HTTP 4xx/5xx into a nonzero exit instead of a saved error
# page. Without it a 404 body sails through to the sanity check, and relying on
# the marker check alone to catch it would be one gate deep.
if ! curl -sSL --fail -m "$CURL_TIMEOUT" "$URL" -o "$RAW" 2>"$TMPDIR_RUN/curl.err"; then
  die "fetch FAILED from $URL ($(tr -d '\n' <"$TMPDIR_RUN/curl.err")); previous file left untouched"
fi

# ── validate ─────────────────────────────────────────────────────────────────
bytes=$(wc -c <"$RAW" | tr -d ' ')
[ "$bytes" -ge "$MIN_BYTES" ] \
  || die "body is $bytes bytes, below the $MIN_BYTES floor (truncated or empty); previous file left untouched"
[ "$bytes" -le "$MAX_BYTES" ] \
  || die "body is $bytes bytes, above the $MAX_BYTES ceiling; previous file left untouched"

grep -qF "$MARKER_HOST" "$RAW" \
  || die "body does not contain '$MARKER_HOST' -- this is not the API guide; previous file left untouched"
grep -qF "$MARKER_AUTH" "$RAW" \
  || die "body does not contain '$MARKER_AUTH' -- this is not the API guide; previous file left untouched"

# ── render ───────────────────────────────────────────────────────────────────
# Em-dash (U+2014) -> " -- ", then collapse any doubled spacing the substitution
# introduced around an already-spaced dash.
normalise() {
  sed -e $'s/\xe2\x80\x94/ -- /g' -e 's/  *--  */ -- /g' -e 's/[[:space:]]*$//' "$1"
}

{
  cat <<EOF
# Muso Platform API -- live reference

GENERATED FILE. Do not edit by hand; edits are overwritten on the next sync.
Source: $URL (public page, refreshed automatically).
Rendered: $(date -u '+%Y-%m-%d %H:%M UTC')

This is the current, canonical description of the platform.muso.ai developer
platform, including live pricing. It is fetched from the page the platform team
publishes for machine readers, whose figures come from the pricing module rather
than being written by hand -- so the numbers below are what a customer sees on
the public pricing page today.

For how to USE this with a customer -- who Platform is for, the workspace-key vs
platform-key distinction, what to answer and what to route -- see platform.md.

---

EOF
  normalise "$RAW"
} >"$RENDER"

# ── the shared CI blocklist, on the path CI cannot reach ─────────────────────
# Scanned over the FETCHED BODY, not the rendered file. The remote body is the
# only untrusted part; the provenance header above is ours, and it embeds $URL,
# which on a developer checkout is a local path that can itself contain a
# blocklisted word (".../hydra/..."). Scanning the render made the gate fire on
# our own header -- a false positive that says nothing about what the source
# published.
if hits=$(cs_reference_blocklist_hits "$RAW"); then
  echo "sync-platform-llms.sh: REFUSED -- internal terms in the fetched body:" >&2
  echo "$hits" >&2
  die "the fetched body carries internal terms the CS blocklist refuses; previous file left untouched"
fi

# Belt and braces: assert the normalisation actually landed. A sed that silently
# failed to match would otherwise publish em-dashes into Caroline's surface.
if grep -q $'\xe2\x80\x94' "$RENDER"; then
  die "em-dash survived normalisation; refusing to publish"
fi

# ── act ──────────────────────────────────────────────────────────────────────
# NOTE: only dry-run and check have arms, and both exit inside them. MODE=install
# matches nothing and falls through past `esac` to the install logic below --
# there is deliberately no `install)` arm.
case "$MODE" in
  dry-run)
    cat "$RENDER"
    exit 0
    ;;
  check)
    [ -f "$OUT" ] || die "no installed file at $OUT"
    if diff -q <(body "$OUT") <(body "$RENDER") >/dev/null; then
      echo "OK: $OUT is current with $URL"
      exit 0
    fi
    echo "DRIFT: $OUT differs from $URL" >&2
    diff <(body "$OUT") <(body "$RENDER") >&2 || true
    exit 1
    ;;
esac

changed=1
if [ -f "$OUT" ]; then
  if diff -q <(body "$OUT") <(body "$RENDER") >/dev/null; then changed=0; fi
fi

mkdir -p "$(dirname "$OUT")"
# Atomic install: a reader (the RAG indexer) never sees a half-written file.
# TMP_INSTALL is assigned BEFORE the file exists so the EXIT trap reaps it even
# if `install` itself dies partway (see the trap comment above).
TMP_INSTALL="$OUT.tmp.$$"
install -m 644 "$RENDER" "$TMP_INSTALL"
mv -f "$TMP_INSTALL" "$OUT"
TMP_INSTALL=""

if [ "$changed" -eq 0 ]; then
  echo "OK: $OUT refreshed, content unchanged"
  exit 0
fi

echo "OK: $OUT updated from $URL (content CHANGED)"

# A content change means Caroline's pricing answers just changed with no human in
# the loop -- that is the trade-off this feed deliberately accepts, so it must at
# least be visible. Best-effort: the file is already installed by this point, so
# a Slack failure must not fail the run.
notify ":arrows_counterclockwise: Caroline's platform.muso.ai pricing/API feed just changed, straight from the public page with no human in the loop. Worth a skim: \`$OUT\` on node-8, or \`/opt/hydra/scripts/sync-platform-llms.sh --dry-run\`."
exit 0
