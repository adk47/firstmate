#!/usr/bin/env bash
set -euo pipefail

# HYDRA Daily Release
# ===================
# Cuts a release off main: generates notes from conventional commits since
# the last tag, drafts RELEASE_NOTES_DRAFT.md, opens it in $EDITOR, then
# tags + pushes + creates the GitHub release + pings Slack.
#
# Mirrors openclaw's pattern: tag directly off main, no release branches.
# Tag format: v2026.5.26 (single-digit month, matches openclaw).
#
# Usage:
#   ./scripts/release.sh              # uses today's date as the version
#   ./scripts/release.sh v2026.5.26.1 # hotfix-same-day override
#   ./scripts/release.sh --no-edit    # skip $EDITOR review (CI-friendly)
#   DRY_RUN=1 ./scripts/release.sh    # generate notes, skip tag/push/release
#
# Requires: gh CLI authenticated, clean working tree, on main.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYDRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# NOTE: the cd into the working checkout happens AFTER arg parsing --
# --workdir may point this run at another repo's managed checkout.

DRY_RUN="${DRY_RUN:-0}"

log() { echo "[release] $*"; }
die() { echo "[release] ERROR: $*" >&2; exit 1; }

# Distinct exit code for "no commits in range — nothing to release."
# This is the intentionally-quiet case (no notes ⇒ no release) and the
# cron's systemd service whitelists it via SuccessExitStatus=0 10 so
# quiet weekday mornings don't fire a unit-failed alert. All OTHER
# failure modes keep exit 1, so real failures stay loud (dirty tree,
# auth failure, tag already exists, gh release create failure, etc.).
# Caught in Clio's review of PR #340.
exit_no_release() { echo "[release] $*" >&2; exit 10; }

# ─── Parse args ─────────────────────────────────────────────────────
VERSION=""
NO_EDIT=0
FROM_REF=""
WORKDIR=""
EXPECT_REPO=""
NO_ANNOUNCE=0
AT_SHA=""
AUTO_SUFFIX=0
for arg in "$@"; do
  case "$arg" in
    --no-edit) NO_EDIT=1 ;;
    --from=*)  FROM_REF="${arg#--from=}" ;;
    --at=*)    AT_SHA="${arg#--at=}" ;;
    --auto-suffix) AUTO_SUFFIX=1 ;;
    --workdir=*) WORKDIR="${arg#--workdir=}" ;;
    --repo=*)  EXPECT_REPO="${arg#--repo=}" ;;
    --no-announce) NO_ANNOUNCE=1 ;;
    --help|-h)
      cat <<'USAGE'
Usage:
  ./scripts/release.sh                 cut today's release (v$(date +%Y.%-m.%-d))
  ./scripts/release.sh v2026.5.26.1    same-day hotfix override
  ./scripts/release.sh --no-edit       skip $EDITOR review
  ./scripts/release.sh --from=<ref>    explicit range start (bootstrap or override)
  ./scripts/release.sh --at=<sha>      tag this exact commit (must be on origin/main)
  ./scripts/release.sh --auto-suffix   append .N when today's tag already exists
  ./scripts/release.sh --workdir=<p>   cut the release in another repo's checkout
  ./scripts/release.sh --repo=<o/n>    assert the checkout really is this repo
  ./scripts/release.sh --no-announce   tag + publish, but post nothing to Slack
  DRY_RUN=1 ./scripts/release.sh       generate notes only, no tag/push/release

Mirrors openclaw: tag directly off main, no release branches. Requires gh
CLI authenticated, clean working tree on main, exactly matching origin/main.
First-ever release (no prior tag) requires --from=<ref> to scope the range.
USAGE
      exit 0 ;;
    -*)
      die "unknown flag: $arg" ;;
    *)
      [[ -z "$VERSION" ]] || die "version specified twice: $VERSION vs $arg"
      VERSION="$arg" ;;
  esac
done

# ─── Default version: v{Y}.{M}.{D} (no leading zero on month/day) ───
if [[ -z "$VERSION" ]]; then
  VERSION="v$(date -u +%Y.%-m.%-d)"
fi

# Sanity-check format: vYYYY.M.D[.N]
if [[ ! "$VERSION" =~ ^v[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}(\.[0-9]+)?$ ]]; then
  die "version '$VERSION' does not match vYYYY.M.D[.N]"
fi

# ─── Resolve the working checkout ───────────────────────────────────
# Default is hydra's own tree, which keeps every existing invocation
# (and release-cron.sh) behaving exactly as before. --workdir points the
# same machinery at another repo's managed checkout so one implementation
# cuts releases for web-credits-next / auth / hydra alike.
WORKDIR="${WORKDIR:-$HYDRA_ROOT}"
[[ -d "$WORKDIR/.git" ]] || die "--workdir '$WORKDIR' is not a git checkout"
cd "$WORKDIR"

# The draft is written INTO the checkout for hydra (where it is gitignored,
# .gitignore:151) so the documented RELEASE_NOTES_DRAFT.md path still holds.
# For any other repo it goes to a temp file instead: an untracked draft left
# behind by a mid-run failure would trip the dirty-tree check below and wedge
# every subsequent release of that repo.
if [[ "$WORKDIR" == "$HYDRA_ROOT" ]]; then
  DRAFT_FILE="$WORKDIR/RELEASE_NOTES_DRAFT.md"
else
  DRAFT_FILE="$(mktemp -t release-notes.XXXXXX.md)"
fi

# ─── Preflight ──────────────────────────────────────────────────────
log "Preflight checks..."

# Identify the repo from the checkout itself, then assert it against
# --repo when given. gh resolves nameWithOwner from the cwd's remote, so
# a --workdir pointing at the wrong tree would otherwise tag the wrong
# repository -- silently, and unrecoverably once the tag is pushed.
# No fallback default. A hardcoded `|| echo Muso-AI/hydra` made the --repo
# assertion below pass trivially whenever discovery FAILED and the expected
# repo was hydra -- an assertion that cannot fail is not an assertion, and
# this one guards which repository receives a tag that cannot be un-cut.
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
  || die "could not determine the repository for the checkout at $WORKDIR (is its origin set, and gh authenticated?)"
[[ -n "$REPO" ]] || die "gh returned an empty repository name for $WORKDIR — refusing to tag an unidentified repo."
if [[ -n "$EXPECT_REPO" && "$EXPECT_REPO" != "$REPO" ]]; then
  die "--repo says '$EXPECT_REPO' but the checkout at $WORKDIR is '$REPO'. Refusing to tag the wrong repository."
fi
log "  Repo: $REPO (checkout: $WORKDIR)"

if [[ -z "$AT_SHA" ]]; then
  branch=$(git rev-parse --abbrev-ref HEAD)
  if [[ "$branch" != "main" ]]; then
    die "must be on main (currently on '$branch'). Releases cut off main only."
  fi
fi

if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is dirty. Commit, stash, or clean up first."
fi

log "  Fetching origin/main..."
git fetch --tags origin main >/dev/null 2>&1 || die "git fetch failed. Check network / origin remote."

local_sha=$(git rev-parse HEAD)
remote_sha=$(git rev-parse origin/main)

if [[ -n "$AT_SHA" ]]; then
  # --at pins the commit that a deploy actually put into production.
  # main may legitimately have moved on since, so exact equality with
  # origin/main is the wrong gate here. The invariant that still MUST
  # hold is the one PR #330 cared about: never publish a tag pointing at
  # code that is not on origin/main. Ancestry is exactly that check.
  at_full=$(git rev-parse --verify --quiet "${AT_SHA}^{commit}") \
    || die "--at '$AT_SHA' does not resolve to a commit in this checkout"
  if [[ "$local_sha" != "$at_full" ]]; then
    die "--at pins $at_full but the checkout is at $local_sha. The caller must check out the pinned commit first."
  fi
  if ! git merge-base --is-ancestor "$at_full" "$remote_sha"; then
    die "--at commit $at_full is not reachable from origin/main. Refusing to tag code that is not on main."
  fi
  behind=$(git rev-list --count "${at_full}..${remote_sha}")
  log "  Pinned to $(git rev-parse --short "$at_full") (origin/main is $behind commit(s) ahead)"
else
  # Require exact equality with origin/main, not just "not behind". An
  # operator with a locally-committed-but-unpushed change on main would
  # otherwise pass the behind check, and `git push origin <tag>` would
  # attach those commits to the server as reachable-from-tag-only — i.e.
  # a release tag pointing at code that is NOT on origin/main's branch
  # ref. Caught in Clio's review of PR #330.
  if [[ "$local_sha" != "$remote_sha" ]]; then
    ahead=$(git rev-list --count origin/main..HEAD)
    behind=$(git rev-list --count HEAD..origin/main)
    die "local main must exactly match origin/main before release (ahead=$ahead, behind=$behind). Push or pull first."
  fi
fi

# ─── Same-day suffix resolution ────────────────────────────────────
# Per-deploy cadence means several releases can land on one date, so the
# documented vYYYY.M.D.N form has to be reachable without a human picking
# N. Walk upward from the base tag to the first name free BOTH locally and
# on origin -- checking only one of the two would push a tag that already
# exists remotely and fail after the notes were built.
tag_taken() {
  local candidate="$1"
  git rev-parse -q --verify "refs/tags/$candidate" >/dev/null 2>&1 && return 0
  git ls-remote --tags --exit-code origin "refs/tags/$candidate" >/dev/null 2>&1 && return 0
  return 1
}

if [[ "$AUTO_SUFFIX" -eq 1 ]]; then
  base="$VERSION"
  n=0
  while tag_taken "$VERSION"; do
    n=$(( n + 1 ))
    if [[ "$n" -gt 50 ]]; then
      die "more than 50 releases already tagged for ${base} today — refusing to keep incrementing."
    fi
    VERSION="${base}.${n}"
  done
  [[ "$VERSION" == "$base" ]] || log "  ${base} is taken; using $VERSION"
fi

if git rev-parse "$VERSION" >/dev/null 2>&1; then
  die "tag $VERSION already exists locally. Use a suffix like ${VERSION}.1 for a same-day hotfix."
fi

if git ls-remote --tags origin "refs/tags/$VERSION" | grep -q "$VERSION"; then
  die "tag $VERSION already exists on origin. Use a suffix like ${VERSION}.1."
fi

if ! command -v gh >/dev/null 2>&1; then
  die "gh CLI not found. brew install gh."
fi

if ! gh auth status >/dev/null 2>&1; then
  die "gh not authenticated. Run: gh auth login"
fi

log "  All preflight checks passed."

# ─── Range: <prior-ref>..HEAD ──────────────────────────────────────
# Precedence: explicit --from > most recent tag > error.
# Without a tag, RANGE=HEAD would walk the entire repo history into
# release notes (Clio review of PR #330) — refuse and force the
# operator to make a conscious bootstrap choice.
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [[ -n "$FROM_REF" ]]; then
  git rev-parse --verify "$FROM_REF" >/dev/null 2>&1 || die "--from ref '$FROM_REF' not found"
  PRIOR_REF="$FROM_REF"
  log "Range: ${PRIOR_REF}..HEAD (--from override)"
elif [[ -n "$LAST_TAG" ]]; then
  PRIOR_REF="$LAST_TAG"
  log "Range: ${PRIOR_REF}..HEAD"
else
  die "no prior tag found. Bootstrap by passing --from=<ref> (e.g. --from=\$(git rev-parse HEAD~1) or a baseline sha). This prevents publishing the entire repo history as the first release."
fi
RANGE="${PRIOR_REF}..HEAD"

# ─── Build the notes ────────────────────────────────────────────────
# Conventional-commit grouping. Bucket order (matches openclaw's visible
# precedence: features and fixes first, chores last).
declare -a FEAT_LINES=() FIX_LINES=() PERF_LINES=() REFACTOR_LINES=()
declare -a REVERT_LINES=() CHORE_LINES=() DOCS_LINES=() OTHER_LINES=()

while IFS= read -r subject; do
  [[ -z "$subject" ]] && continue
  # Strip the conventional-commit prefix from the visible bullet so the
  # bullet reads naturally ("monitor: codify webhook..." not
  # "fix(monitor): codify webhook...") — the section header already
  # carries the type. Keep PR number and original wording otherwise.
  case "$subject" in
    feat\(*|feat:*)            FEAT_LINES+=("${subject#feat}") ;;
    fix\(*|fix:*)              FIX_LINES+=("${subject#fix}") ;;
    perf\(*|perf:*)            PERF_LINES+=("${subject#perf}") ;;
    refactor\(*|refactor:*)    REFACTOR_LINES+=("${subject#refactor}") ;;
    revert\(*|revert:*|Revert*)REVERT_LINES+=("${subject#revert}") ;;
    chore\(*|chore:*)          CHORE_LINES+=("${subject#chore}") ;;
    docs\(*|docs:*)            DOCS_LINES+=("${subject#docs}") ;;
    # test/ci/build/style fold into Chores. Strip the type prefix so
    # render_bullet can clean up "(scope): " uniformly — without
    # this, "ci(pr-validate): foo" rendered as "ci(pr-validate: foo"
    # (unmatched paren) because render_bullet's `): ` → `: ` substitution
    # left the leading "(" intact when nothing stripped "ci" first.
    # Surfaced in v2026.5.26 DRY_RUN of PR #345's bullet.
    test\(*|test:*)            CHORE_LINES+=("${subject#test}") ;;
    ci\(*|ci:*)                CHORE_LINES+=("${subject#ci}") ;;
    build\(*|build:*)          CHORE_LINES+=("${subject#build}") ;;
    style\(*|style:*)          CHORE_LINES+=("${subject#style}") ;;
    Merge\ pull\ request*)     ;;  # squash absorbs these; drop any stragglers
    *)                         OTHER_LINES+=("$subject") ;;
  esac
done < <(git log "$RANGE" --pretty='tformat:%s' --no-merges)
# tformat (not format) emits a trailing newline after the last commit
# subject. Without it, `read -r` returns non-zero on the final line and
# the while loop exits before the body runs — silently dropping the last
# commit from every release (caught while validating Clio's PR #330
# review by smoke-testing with a one-commit range that produced
# "nothing to release").

# Normalize the leading "(scope): " / ": " into a clean " — scope: "
# style bullet so it reads as: "- monitor: codify webhook... (#322)"
render_bullet() {
  local line="$1"
  # Strip leading "(scope): " → "scope: "
  line="${line#:(}"
  line="${line/): /: }"
  # Strip leading ": " for non-scoped commits
  line="${line#: }"
  # Strip leading "(" if a non-scoped commit somehow slipped through
  line="${line#(}"
  echo "- ${line}"
}

emit_section() {
  local title="$1"; shift
  if [[ "$#" -gt 0 ]]; then
    printf '### %s\n\n' "$title"
    local l
    for l in "$@"; do render_bullet "$l"; done
    printf '\n'
  fi
}

# Build the diff link from PRIOR_REF (always set — see range section).
# Resolve PRIOR_REF for the GitHub compare URL: GitHub understands tag
# names and shas but NOT "HEAD~N" or other local-only refs. Keep tags
# readable in the URL; resolve everything else to a short sha. Surfaced
# in v2026.5.26 bootstrap DRY_RUN where --from=HEAD~11 produced a 404
# compare link.
# REPO was resolved and asserted up in the preflight section.
if git rev-parse --verify "refs/tags/${PRIOR_REF}" >/dev/null 2>&1; then
  PRIOR_URL_REF="$PRIOR_REF"
elif [[ "$PRIOR_REF" =~ ^[0-9a-f]{7,40}$ ]]; then
  PRIOR_URL_REF="$PRIOR_REF"
else
  PRIOR_URL_REF=$(git rev-parse --short "$PRIOR_REF")
fi
DIFF_LINE="**Full changelog**: https://github.com/${REPO}/compare/${PRIOR_URL_REF}...${VERSION}"

{
  printf '# %s\n\n' "$VERSION"
  emit_section "Features"      "${FEAT_LINES[@]+"${FEAT_LINES[@]}"}"
  emit_section "Fixes"         "${FIX_LINES[@]+"${FIX_LINES[@]}"}"
  emit_section "Performance"   "${PERF_LINES[@]+"${PERF_LINES[@]}"}"
  emit_section "Refactors"     "${REFACTOR_LINES[@]+"${REFACTOR_LINES[@]}"}"
  emit_section "Reverts"       "${REVERT_LINES[@]+"${REVERT_LINES[@]}"}"
  emit_section "Chores"        "${CHORE_LINES[@]+"${CHORE_LINES[@]}"}"
  emit_section "Docs"          "${DOCS_LINES[@]+"${DOCS_LINES[@]}"}"
  emit_section "Other"         "${OTHER_LINES[@]+"${OTHER_LINES[@]}"}"
  printf '%s\n' "$DIFF_LINE"
} > "$DRAFT_FILE"

TOTAL=$(( ${#FEAT_LINES[@]} + ${#FIX_LINES[@]} + ${#PERF_LINES[@]} + ${#REFACTOR_LINES[@]} \
       + ${#REVERT_LINES[@]} + ${#CHORE_LINES[@]} + ${#DOCS_LINES[@]} + ${#OTHER_LINES[@]} ))

if [[ "$TOTAL" -eq 0 ]]; then
  rm -f "$DRAFT_FILE"
  exit_no_release "no commits in $RANGE — nothing to release."
fi

log "Drafted $TOTAL commit(s) → $DRAFT_FILE"

# ─── Review in $EDITOR ─────────────────────────────────────────────
if [[ "$NO_EDIT" -ne 1 ]]; then
  : "${EDITOR:=vi}"
  log "Opening $DRAFT_FILE in \$EDITOR ($EDITOR)..."
  "$EDITOR" "$DRAFT_FILE"
fi

if [[ ! -s "$DRAFT_FILE" ]]; then
  die "$DRAFT_FILE is empty after edit. Aborting."
fi

# ─── Canonical URLs ────────────────────────────────────────────────
# Computed here, ABOVE the dry-run stop, so a dry run can hand a caller
# the exact links the real run would produce. A --dry-run render of the
# Slack message that carried different URLs than the live one would be
# worthless as a preview.
RELEASE_URL="https://github.com/${REPO}/releases/tag/${VERSION}"
COMPARE_URL="https://github.com/${REPO}/compare/${PRIOR_URL_REF}...${VERSION}"

# Hand the result back to a programmatic caller. release-watch.sh needs
# the version and the rendered notes to build its own Block Kit message;
# parsing them back out of this script's log would be brittle. The notes
# are COPIED out of the way so the caller owns a stable path that the
# unconditional draft cleanup below cannot pull out from under it.
emit_result() {
  [[ -n "${RELEASE_OUTPUT_FILE:-}" ]] || return 0
  local notes_keep
  notes_keep="$(mktemp -t release-notes-kept.XXXXXX.md)"
  cp "$DRAFT_FILE" "$notes_keep"
  {
    printf 'version=%s\n'      "$VERSION"
    printf 'repo=%s\n'         "$REPO"
    printf 'prior_ref=%s\n'    "$PRIOR_URL_REF"
    printf 'release_url=%s\n'  "$RELEASE_URL"
    printf 'compare_url=%s\n'  "$COMPARE_URL"
    printf 'notes_file=%s\n'   "$notes_keep"
    printf 'commit_count=%s\n' "$TOTAL"
    printf 'dry_run=%s\n'      "$DRY_RUN"
  } > "$RELEASE_OUTPUT_FILE"
  log "  Result written to $RELEASE_OUTPUT_FILE (notes: $notes_keep)"
}

# ─── Dry-run stop ──────────────────────────────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
  log "DRY_RUN=1 — stopping before tag/push/release."
  log "Notes preview:"
  echo "────────────────────────────────────────"
  cat "$DRAFT_FILE"
  echo "────────────────────────────────────────"
  emit_result
  rm -f "$DRAFT_FILE"
  log "Re-run without DRY_RUN=1 to ship."
  exit 0
fi

# ─── Tag + push + GH release ───────────────────────────────────────
log "Tagging $VERSION (annotated)..."
git tag -a "$VERSION" -m "$VERSION"

log "Pushing tag to origin..."
git push origin "$VERSION"

log "Creating GitHub release..."
if ! gh release create "$VERSION" --title "$VERSION" --notes-file "$DRAFT_FILE"; then
  echo
  echo "Tag $VERSION pushed but 'gh release create' failed."
  echo "Recover manually:"
  echo "  gh release create $VERSION --title $VERSION --notes-file $DRAFT_FILE"
  exit 1
fi

# ─── Slack announcement (#clio_devops via devops bot) ──────────────
# Block Kit message built from the post-edit DRAFT_FILE so it matches
# what was just published to GitHub. Best-effort: the release is
# already tagged + published by this point — a missing Slack post is
# annoying, not catastrophic. The whole block is wrapped in a subshell
# + `|| log ...` so payload-build errors, Python failures, or curl
# failures do NOT propagate to release.sh's exit status. Caught in
# Clio's review of PR #330.
# RELEASE_URL / COMPARE_URL were computed above the dry-run stop.
if [[ "$NO_ANNOUNCE" -eq 1 ]]; then
  log "  (--no-announce — the caller owns the Slack announcement)"
elif [[ -r "$HYDRA_ROOT/scripts/lib/slack-notify.sh" ]]; then
  (
    # shellcheck source=lib/slack-notify.sh
    source "$HYDRA_ROOT/scripts/lib/slack-notify.sh"

    SLACK_PAYLOAD_FILE=$(mktemp -t hydra-release-slack.XXXXXX.json)
    trap 'rm -f "$SLACK_PAYLOAD_FILE"' EXIT

    # Build the Block Kit payload in Python. Doing this in bash via
    # heredocs is a footgun — commit subjects routinely contain
    # apostrophes, quotes, backticks, and em-dashes; jq/heredoc
    # escaping bit us on 2026-05-07 (api-evidence.sh outage).
    python3 - "$DRAFT_FILE" "$SLACK_PAYLOAD_FILE" \
      "${SLACK_CHANNEL:-C0ADV2W76G4}" "$VERSION" "$REPO" \
      "$RELEASE_URL" "$COMPARE_URL" <<'PYEOF'
import json, re, sys

draft_path, out_path, channel, version, repo, release_url, compare_url = sys.argv[1:8]

with open(draft_path, "r", encoding="utf-8") as f:
    md = f.read()

# Parse the rendered markdown back into (section_title, [bullets]).
# Format produced by emit_section() is:
#   ### {title}
#   (blank line)
#   - bullet
#   - bullet
#   (blank line)
sections = []
current_title = None
current_bullets = []
for raw in md.splitlines():
    line = raw.rstrip()
    if line.startswith("### "):
        if current_title and current_bullets:
            sections.append((current_title, current_bullets))
        current_title = line[4:].strip()
        current_bullets = []
    elif line.startswith("- "):
        current_bullets.append(line[2:].strip())
if current_title and current_bullets:
    sections.append((current_title, current_bullets))

# Map section title -> emoji prefix for visual scanning.
EMOJI = {
    "Features":    ":sparkles:",
    "Fixes":       ":wrench:",
    "Performance": ":zap:",
    "Refactors":   ":recycle:",
    "Reverts":     ":rewind:",
    "Chores":      ":broom:",
    "Docs":        ":books:",
    "Other":       ":package:",
}

# Wrap (#NNN) refs in explicit links so they work regardless of whether
# the GitHub Slack app is installed in #clio_devops.
PR_RE = re.compile(r"\(#(\d+)\)")
def link_prs(text):
    return PR_RE.sub(
        lambda m: f"(<https://github.com/{repo}/pull/{m.group(1)}|#{m.group(1)}>)",
        text,
    )

blocks = []
blocks.append({
    "type": "header",
    "text": {"type": "plain_text", "text": f":ship: HYDRA {version}", "emoji": True},
})
blocks.append({
    "type": "section",
    "text": {
        "type": "mrkdwn",
        "text": f"<{release_url}|*View release on GitHub*>",
    },
})

# One section block per bucket. Slack section text limit is 3000 chars;
# truncate long buckets with a "+N more" footer rather than 400-erroring.
MAX_TEXT = 2800  # leave headroom for the bold header line
for title, bullets in sections:
    emoji = EMOJI.get(title, ":small_blue_diamond:")
    header_line = f"*{emoji} {title}*"
    rendered = [f"• {link_prs(b)}" for b in bullets]

    body = "\n".join(rendered)
    overflow = 0
    while len(header_line) + 2 + len(body) > MAX_TEXT and rendered:
        rendered.pop()
        overflow += 1
        body = "\n".join(rendered)
    if overflow:
        body = body + f"\n_…+{overflow} more (see release page)_"

    blocks.append({
        "type": "section",
        "text": {"type": "mrkdwn", "text": f"{header_line}\n{body}"},
    })

context_elements = [
    {"type": "mrkdwn", "text": f":memo: <{release_url}|Release notes>"},
]
if compare_url:
    context_elements.append({"type": "mrkdwn", "text": f":twisted_rightwards_arrows: <{compare_url}|Diff>"})
blocks.append({"type": "context", "elements": context_elements})

payload = {
    "channel": channel,
    "text": f":ship: HYDRA {version} — {release_url}",  # fallback for notifications
    "blocks": blocks,
    "unfurl_links": False,
    "unfurl_media": False,
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False)
PYEOF

    slack_notify_payload_file "$SLACK_PAYLOAD_FILE"
    rm -f "$SLACK_PAYLOAD_FILE"
    trap - EXIT
  ) || log "  (Slack announcement failed, non-fatal — release is live: ${RELEASE_URL})"
else
  log "  (slack-notify.sh not found — skipping Slack announcement; release is live regardless)"
fi

emit_result

# ─── Clean up the draft ────────────────────────────────────────────
rm -f "$DRAFT_FILE"

log "Done. ${VERSION} is live: https://github.com/${REPO}/releases/tag/${VERSION}"
