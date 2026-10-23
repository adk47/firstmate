#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# release-digest.sh — daily #releases roll-up of the last 24 h of releases,
# one section per project.
#
# Runs from hydra-release-digest.timer at 08:00 America/New_York (the IANA
# zone, so it tracks EDT/EST; never a fixed UTC offset). Reads the GitHub
# releases that release-watch cut for every ENABLED repo in
# lib/release-repos.sh, plus the plain-language highlights it stored, and
# renders them with lib/release_blockkit.py (--digest) -- the same renderer
# as the per-release post.
#
# An empty day still posts ONE quiet line: silence would be
# indistinguishable from a broken timer. Idempotent: one post per New York
# calendar day, recorded only after Slack confirmed it.
#
# The window is [last posted slot, the most recent 08:00 slot <= now): the
# upper bound is the SCHEDULED slot, never the wall clock, so a Persistent=true
# catch-up before 08:00 or a late run neither drops nor repeats releases. The
# lower bound is the slot in digest/last-posted, so a multi-day outage is
# reported in one window. A corrupt state value warns and falls back to the
# previous slot (never dies: a bad state file must not brick the digest).
# --dry-run reads that watermark so the preview is honest, and writes nothing.
#
# Usage:
#   ./scripts/release-digest.sh            # post today's digest
#   ./scripts/release-digest.sh --dry-run  # print the payload, post and
#                                          # record nothing
#
# Exit codes:
#   0  posted, already posted for this slot, or dry run
#   1  a real failure (bad config, unreachable GitHub, failed post)
#
# Env knobs:
#   RELEASES_SLACK_CHANNEL   target channel id. REQUIRED for a live post.
#   HYDRA_RELEASE_STATE_DIR  state root (default /var/lib/hydra-release)
#   DIGEST_NOW               ISO-8601 instant to use instead of now (tests)
# ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/release-repos.sh
source "$SCRIPT_DIR/lib/release-repos.sh"
# shellcheck source=lib/release-announce.sh
source "$SCRIPT_DIR/lib/release-announce.sh"

STATE_ROOT="${HYDRA_RELEASE_STATE_DIR:-/var/lib/hydra-release}"
HIGHLIGHTS_DIR="$STATE_ROOT/highlights"
DIGEST_STATE_DIR="$STATE_ROOT/digest"
LOCK_FILE="$STATE_ROOT/release-digest.lock"
BLOCKKIT="$SCRIPT_DIR/lib/release_blockkit.py"

DRY_RUN=0
log() { echo "[release-digest] $*" >&2; }
die() { echo "[release-digest] ERROR: $*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h) awk 'NR<5{next} /^# ───/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown flag: $arg" ;;
  esac
done

if [[ "$DRY_RUN" -eq 0 && -z "${RELEASES_SLACK_CHANNEL:-}" ]]; then
  die "RELEASES_SLACK_CHANNEL is unset. Set it in /etc/hydra/releases.env. Re-run with --dry-run to preview without it."
fi
for c in gh jq python3 flock; do
  command -v "$c" >/dev/null 2>&1 || die "$c not found"
done

NOW="${DIGEST_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
SLOT="$(python3 "$BLOCKKIT" --digest-slot-date "$NOW")" || die "cannot read DIGEST_NOW '$NOW'"

mkdir -p "$STATE_ROOT" "$DIGEST_STATE_DIR" "$HIGHLIGHTS_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || { log "another digest run holds the lock — skipping."; exit 0; }

# The watermark: the New York date of the last slot a digest was posted for.
SINCE="$(cat "$DIGEST_STATE_DIR/last-posted" 2>/dev/null || true)"
SINCE="${SINCE//[[:space:]]/}"
if [[ -n "$SINCE" ]] && { ! [[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! python3 "$BLOCKKIT" --digest-since "$SINCE"; }; then
  log "WARNING: digest/last-posted holds '$SINCE', not a date — falling back to the previous slot."
  SINCE=""
fi

# ISO dates compare lexicographically: stored >= SLOT also covers clock skew
# or a restored-from-backup value, which must not re-post or window backwards.
if [[ "$DRY_RUN" -eq 0 && -n "$SINCE" && ! "$SINCE" < "$SLOT" ]]; then
  log "digest for $SLOT already posted — nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# One JSON document: every enabled repo with its releases. A repo whose
# listing fails aborts the run -- a digest that says "no releases" because
# GitHub was unreachable would be a false statement.
#
# Release listings (bodies included) run to hundreds of KB, and Linux caps a
# SINGLE argv string at 128 KB (MAX_ARG_STRLEN): everything below moves
# through files and stdin, never through jq --argjson.
projects_files=()
n=0
while IFS= read -r key; do
  repo="$(release_repo_field "$key" repo)"
  emoji="$(release_repo_field "$key" emoji)"
  display="$(release_repo_field "$key" display)"
  rels="$WORK/rels-$n.json"
  gh api "repos/$repo/releases?per_page=100" \
    --jq '[.[] | {tag: .tag_name, url: .html_url, published_at: .published_at, body: (.body // ""), draft: .draft, prerelease: .prerelease}]' \
    > "$rels" || die "cannot list releases for $repo"
  jq -e 'type == "array"' "$rels" >/dev/null 2>&1 || die "unexpected release listing for $repo"
  # Attach the stored plain-language highlights, when release-watch kept them.
  hl_files=()
  while IFS= read -r tag; do
    hlf="$HIGHLIGHTS_DIR/${key}-${tag}.txt"
    [[ -r "$hlf" ]] || continue
    one="$WORK/hl-$n-${#hl_files[@]}.json"
    jq -Rn --arg t "$tag" '{($t): [inputs | select(length > 0)]}' < "$hlf" > "$one"
    hl_files+=("$one")
  done < <(jq -r '.[].tag' "$rels")
  if ((${#hl_files[@]})); then
    jq -s 'add' "${hl_files[@]}" > "$WORK/hl-$n.json"
  else
    echo '{}' > "$WORK/hl-$n.json"
  fi
  jq -c --arg k "$key" --arg r "$repo" --arg e "$emoji" --arg d "$display" --slurpfile h "$WORK/hl-$n.json" \
    '{key: $k, repo: $r, emoji: $e, display: $d,
      releases: [.[] | . + {highlights: ($h[0][.tag] // [])}]}' "$rels" > "$WORK/project-$n.json"
  projects_files+=("$WORK/project-$n.json")
  n=$((n + 1))
done < <(release_repo_keys --enabled-only)

if ((${#projects_files[@]})); then
  jq -s --arg now "$NOW" --arg ch "${RELEASES_SLACK_CHANNEL:-}" --arg since "$SINCE" \
    '{now: $now, since: $since, channel: $ch, projects: .}' "${projects_files[@]}" > "$WORK/in.json"
else
  jq -n --arg now "$NOW" --arg ch "${RELEASES_SLACK_CHANNEL:-}" --arg since "$SINCE" \
    '{now: $now, since: $since, channel: $ch, projects: []}' > "$WORK/in.json"
fi
python3 "$BLOCKKIT" --digest "$WORK/in.json" "$WORK/payload.json" || die "render failed"

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat "$WORK/payload.json"; echo
  exit 0
fi

release_announce_post "$WORK/payload.json" || die "Slack did not confirm the digest post"
printf '%s\n' "$SLOT" > "$DIGEST_STATE_DIR/last-posted"
log "posted digest for $SLOT."
