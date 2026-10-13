#!/usr/bin/env bash
set -euo pipefail

# sync-help-centre.sh -- keep Caroline's help-centre corpus current.
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS
# The help centre lives on Intercom (https://help.muso.ai). Its llms.txt is the
# inventory of every public article; each article is also served as markdown at
# its URL. This script mirrors that into Caroline's RAG directory so she can
# answer from, and cite, the real articles instead of a hand-copied digest.
# Same shape and same reasoning as sync-platform-llms.sh and sync-app-pricing.sh:
# the content is fetched, never typed, and it is server-owned and untracked.
#
# WHAT IT WRITES (flat; one directory, no subdirs)
#   $OUT/hc-<id>.md       one per article. YAML frontmatter, then the body:
#                           title:         article title (first H1)
#                           canonical_url: the article URL WITHOUT the .md suffix
#                           source_sha:    sha256 of the raw fetched body
#   $OUT/hc-manifest.json the citation manifest. CONTRACT -- the citation gate
#                         (sibling card) validates against exactly this shape:
#                           { "generated_at": "<UTC ISO-8601>",
#                             "articles": { "<id>": { "slug": "<url slug>",
#                                                     "title": "<title>",
#                                                     "url":   "<canonical_url>" } } }
#                         <id> is the numeric prefix of the article URL slug and
#                         the <id> in hc-<id>.md; url equals canonical_url.
# Flat, not a subdir: extraPaths recursion is unproven and flat costs nothing.
#
# WHAT IS ENFORCED
#   ALL-OR-NOTHING -- any failed, empty or unrecognisable fetch (the inventory or
#     ANY single article), fewer than MIN_ARTICLES parsed articles, or a
#     blocklist hit leaves every existing file byte-for-byte intact and exits
#     non-zero. A partial fetch can never shrink the corpus.
#   BLOCKLIST -- the shared lib/cs-reference-blocklist.sh runs over every fetched
#     body before install. This is the gate of record: the CI reference scan
#     globs tracked files non-recursively and cannot see a generated file.
#   ONE RUN AT A TIME -- install takes a mkdir lock ($OUT.lock); an overlapping
#     run exits 1 without touching anything, a dead owner's lock is reaped.
#   HTTPS + OWN HOST ONLY -- the inventory is untrusted input. Every article URL
#     must start with URL_PREFIX (https://help.muso.ai/) or the run is refused,
#     and curl is limited to https. Redirects are followed by hand and each hop
#     must ALSO start with URL_PREFIX before it is requested. So a
#     poisoned llms.txt cannot make the host read file:// or an internal
#     endpoint into Caroline's index. Tests relax both via env.
#   NO SHRINK BY SURPRISE -- an installed article missing upstream is only
#     deleted when HELP_CENTRE_ALLOW_REMOVALS=1; otherwise the run is refused
#     (a truncated inventory above the floor must not delete valid files).
#   NO IMAGES -- Intercom image URLs are signed and expire in ~30 minutes; a
#     stored one is worse than none, so image markdown is stripped.
#   NO EM-DASHES -- lint-no-em-dash.sh cannot see a generated file; honour the
#     rule anyway: em-dashes become " -- ".
#   REWRITE ONLY ON CHANGE -- a run with unchanged upstream touches nothing
#     (generated_at is ignored when comparing).
#
# Usage:
#   sync-help-centre.sh              # fetch, validate, install
#   sync-help-centre.sh --dry-run    # render to a temp dir, write nothing to OUT
#   sync-help-centre.sh --check      # exit 0 if OUT is current; writes nothing
#   sync-help-centre.sh --help
#
# Env: HELP_CENTRE_LLMS_URL, HELP_CENTRE_OUT (always override OUT for local runs),
#      HELP_CENTRE_MIN_ARTICLES, HELP_CENTRE_TIMEOUT, HELP_CENTRE_NO_NOTIFY,
#      HELP_CENTRE_URL_PREFIX, HELP_CENTRE_CURL_PROTO (test-only relaxations),
#      HELP_CENTRE_ALLOW_REMOVALS=1 (intentional deletion of articles).
# Exit: 0 ok | 1 refused or drifted (files untouched) | 2 usage/config error.

URL="${HELP_CENTRE_LLMS_URL:-https://help.muso.ai/llms.txt}"
OUT="${HELP_CENTRE_OUT:-/opt/hydra/workspaces/support/reference}"
MIN_ARTICLES="${HELP_CENTRE_MIN_ARTICLES:-40}"
CURL_TIMEOUT="${HELP_CENTRE_TIMEOUT:-25}"
URL_PREFIX="${HELP_CENTRE_URL_PREFIX:-https://help.muso.ai/}"
CURL_PROTO="${HELP_CENTRE_CURL_PROTO:-=https}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cs-reference-blocklist.sh
. "$SELF_DIR/lib/cs-reference-blocklist.sh"

MODE="install"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE="dry-run" ;;
    --check)   MODE="check" ;;
    -h|--help) sed -n '/^# Exit:/q;p' "${BASH_SOURCE[0]}"; sed -n '/^# Exit:/p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "sync-help-centre.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

# notify <text> -- best-effort Slack post to #cs_chats as the OPERATIONS bot.
# Channel and bot are set in a subshell (see sync-platform-llms.sh for why).
notify() {
  [ -z "${HELP_CENTRE_NO_NOTIFY:-}" ] || return 0
  [ -f "$SELF_DIR/lib/slack-notify.sh" ] || return 0
  # shellcheck source=lib/slack-notify.sh
  . "$SELF_DIR/lib/slack-notify.sh" 2>/dev/null || return 0
  command -v slack_notify >/dev/null 2>&1 || return 0
  (
    export SLACK_CHANNEL="${HELP_CENTRE_SLACK_CHANNEL:-C0ANM0PN9L5}"
    export SLACK_NOTIFY_BOT="${HELP_CENTRE_SLACK_BOT:-operations}"
    slack_notify "$1"
  ) >/dev/null 2>&1 || true
}

# die <reason> -- refuse, leaving every existing file in place, and SAY SO.
# Only the install path pages; --dry-run and --check have a human reading.
die() {
  echo "sync-help-centre.sh: $*" >&2
  [ "$MODE" != "install" ] || notify ":warning: *Caroline's help-centre corpus did not update* on node-8 -- $*. She is still answering from the last good copy in \`$OUT\`. Re-run: \`/opt/hydra/scripts/sync-help-centre.sh --dry-run\`"
  exit 1
}

TMPDIR_RUN="$(mktemp -d)"
# Install stages next to the destination; reap any leftover on every exit path.
LOCK="$OUT.lock"; LOCK_HELD=""
cleanup() {
  rm -rf "${TMPDIR_RUN:?}"; rm -f "${OUT:?}"/hc-*.tmp."$$" 2>/dev/null || true
  [ -z "$LOCK_HELD" ] || rm -rf "${LOCK:?}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

RAW_DIR="$TMPDIR_RUN/raw"       # fetched bodies, <id>.md
REND="$TMPDIR_RUN/render"       # rendered output, same names as OUT
mkdir -p "$RAW_DIR" "$REND"

# fetch <url> <dest> -- follows redirects by hand so every hop is checked against
# URL_PREFIX BEFORE it is requested (curl -L would already have hit the other host).
fetch() {
  local url="$1" out code loc
  for _ in 1 2 3 4 5; do
    out=$(curl -sS --proto "$CURL_PROTO" -m "$CURL_TIMEOUT" -o "$2" -w '%{http_code} %{redirect_url}' "$url" 2>"$TMPDIR_RUN/curl.err") \
      || return 1
    code="${out%% *}"; loc="${out#* }"
    case "$code" in
      2??|000) return 0 ;;   # 000: file:// (test-only) has no HTTP status
      301|302|303|307|308)
        case "$loc" in
          "$URL_PREFIX"*) url="$loc" ;;
          *) echo "redirect from $url to '$loc' is outside $URL_PREFIX" >"$TMPDIR_RUN/curl.err"; return 1 ;;
        esac ;;
      *) echo "HTTP $code from $url" >"$TMPDIR_RUN/curl.err"; return 1 ;;
    esac
  done
  echo "too many redirects from $1" >"$TMPDIR_RUN/curl.err"; return 1
}

# One install at a time: two overlapping runs could otherwise interleave their
# per-file moves and publish articles and manifest from different snapshots.
# mkdir is the portable atomic lock (no flock on macOS); a dead owner's lock is reaped.
if [ "$MODE" = "install" ]; then
  if ! mkdir "$LOCK" 2>/dev/null; then
    # Stale = owner dead, or no pid ever written and the lock is over a minute old.
    lock_is_stale() {
      local pid; pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
      if [ -n "$pid" ]; then ! kill -0 "$pid" 2>/dev/null; else [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; fi
    }
    if ! lock_is_stale; then
      echo "sync-help-centre.sh: another run holds $LOCK; nothing done" >&2
      exit 1
    fi
    # Reclaiming is itself serialised by a second mkdir mutex and re-checked under it,
    # so two racers can never both remove the lock (one removing the other's fresh one).
    mkdir "$LOCK.reap" 2>/dev/null || die "another run is reclaiming $LOCK; nothing done"
    if lock_is_stale; then rm -rf "${LOCK:?}"; fi
    got=0; mkdir "$LOCK" 2>/dev/null || got=1
    rmdir "$LOCK.reap" 2>/dev/null || true
    [ "$got" -eq 0 ] || { echo "sync-help-centre.sh: lost the race for $LOCK; nothing done" >&2; exit 1; }
  fi
  LOCK_HELD=1
  echo $$ >"$LOCK/pid"
fi

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

# ── inventory ────────────────────────────────────────────────────────────────
fetch "$URL" "$TMPDIR_RUN/llms.txt" \
  || die "inventory fetch FAILED from $URL ($(tr -d '\n' <"$TMPDIR_RUN/curl.err")); existing corpus left untouched"

# Absolute article URLs: the target of each markdown link ending in .md. De-duped
# in inventory order.
grep -oE '\]\([a-zA-Z][a-zA-Z0-9+.-]*://[^ )]+\.md\)' "$TMPDIR_RUN/llms.txt" \
  | sed -e 's/^](//' -e 's/)$//' | awk '!seen[$0]++' >"$TMPDIR_RUN/urls" || true
touch "$TMPDIR_RUN/urls"
while IFS= read -r u; do
  case "$u" in
    "$URL_PREFIX"*) ;;
    *) die "inventory lists '$u' outside $URL_PREFIX; existing corpus left untouched" ;;
  esac
done <"$TMPDIR_RUN/urls"
count=$(wc -l <"$TMPDIR_RUN/urls" | tr -d ' ')
[ "$count" -ge "$MIN_ARTICLES" ] \
  || die "inventory parsed to $count articles, below the $MIN_ARTICLES floor (truncated or unrecognisable); existing corpus left untouched"

# ── fetch + render every article; any single failure aborts the whole run ────
normalise() {
  sed -e $'s/\xe2\x80\x94/ -- /g' -e 's/  *--  */ -- /g' -e 's/[[:space:]]*$//'
}
# yaml_quote <text> -- double-quoted YAML scalar.
yaml_quote() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }

: >"$TMPDIR_RUN/rows"   # id<TAB>slug<TAB>title<TAB>url
while IFS= read -r md_url; do
  last="${md_url##*/}"; last="${last%.md}"
  id="${last%%-*}"; slug="${last#*-}"
  case "$id" in ''|*[!0-9]*) die "article URL '$md_url' has no numeric id prefix; existing corpus left untouched" ;; esac
  [ ! -e "$RAW_DIR/$id.md" ] || die "duplicate article id $id in inventory; existing corpus left untouched"
  fetch "$md_url" "$RAW_DIR/$id.md" \
    || die "article fetch FAILED for $md_url ($(tr -d '\n' <"$TMPDIR_RUN/curl.err")); existing corpus left untouched"
  grep -q '[^[:space:]]' "$RAW_DIR/$id.md" \
    || die "article $md_url came back empty; existing corpus left untouched"

  if hits=$(cs_reference_blocklist_hits "$RAW_DIR/$id.md"); then
    echo "sync-help-centre.sh: REFUSED -- internal terms in $md_url:" >&2
    echo "$hits" >&2
    die "article $md_url carries internal terms the CS blocklist refuses; existing corpus left untouched"
  fi

  canonical="${md_url%.md}"
  title=$(grep -m1 '^# ' "$RAW_DIR/$id.md" | sed -e 's/^# *//' -e 's/\*\*//g' | normalise || true)
  [ -n "$title" ] \
    || die "article $md_url has no H1 (not an article body, e.g. a challenge page); existing corpus left untouched"
  {
    printf -- '---\ntitle: %s\ncanonical_url: %s\nsource_sha: "%s"\n---\n\n' \
      "$(yaml_quote "$title")" "$(yaml_quote "$canonical")" "$(sha256 "$RAW_DIR/$id.md")"
    sed -E 's/!\[[^]]*\]\([^)]*\)//g' "$RAW_DIR/$id.md" | normalise
  } >"$REND/hc-$id.md"
  if grep -q $'\xe2\x80\x94' "$REND/hc-$id.md"; then
    die "em-dash survived normalisation in article $id; refusing to publish"
  fi
  printf '%s\t%s\t%s\t%s\n' "$id" "$slug" "$title" "$canonical" >>"$TMPDIR_RUN/rows"
done <"$TMPDIR_RUN/urls"

# Manifest. python3 -I so JSON escaping is the library's job, not sed's.
python3 -I - "$TMPDIR_RUN/rows" "$REND/hc-manifest.json" <<'PY' || die "manifest render failed; existing corpus left untouched"
import json, sys, datetime
arts = {}
for line in open(sys.argv[1], encoding="utf-8"):
    id_, slug, title, url = line.rstrip("\n").split("\t")
    arts[id_] = {"slug": slug, "title": title, "url": url}
doc = {"generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "articles": arts}
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

# ── compare: article files byte-for-byte, manifest ignoring generated_at ─────
manifest_body() { python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));d.pop("generated_at",None);print(json.dumps(d,sort_keys=True))' "$1" 2>/dev/null || echo "unreadable"; }

# drift_list: files to write. stale_list: installed hc files upstream no longer lists.
drift_list=""; stale_list=""
for f in "$REND"/hc-*.md; do
  n=$(basename "$f")
  cmp -s "$f" "$OUT/$n" 2>/dev/null || drift_list="$drift_list $n"
done
if [ ! -f "$OUT/hc-manifest.json" ] \
   || [ "$(manifest_body "$OUT/hc-manifest.json")" != "$(manifest_body "$REND/hc-manifest.json")" ]; then
  drift_list="$drift_list hc-manifest.json"
fi
for f in "$OUT"/hc-*.md; do
  [ -e "$f" ] || continue
  [ -e "$REND/$(basename "$f")" ] || stale_list="$stale_list $(basename "$f")"
done

if [ -n "$stale_list" ] && [ "$MODE" = "install" ] && [ "${HELP_CENTRE_ALLOW_REMOVALS:-}" != "1" ]; then
  die "upstream no longer lists installed article(s):$stale_list; refusing to delete (a truncated inventory looks the same). If intentional, re-run with HELP_CENTRE_ALLOW_REMOVALS=1; existing corpus left untouched"
fi

case "$MODE" in
  dry-run)
    echo "DRY-RUN: $count articles rendered; would write:${drift_list:- (nothing)}; would delete:${stale_list:- (nothing)}"
    exit 0
    ;;
  check)
    if [ -z "$drift_list$stale_list" ]; then
      echo "OK: $OUT is current with $URL ($count articles)"
      exit 0
    fi
    echo "DRIFT: $OUT differs from $URL; changed:${drift_list:- (none)}; stale:${stale_list:- (none)}" >&2
    exit 1
    ;;
esac

if [ -z "$drift_list$stale_list" ]; then
  echo "OK: $OUT unchanged ($count articles); nothing rewritten"
  exit 0
fi

# ── install ──────────────────────────────────────────────────────────────────
# Everything above succeeded, so this is the only place OUT is mutated. Each file
# is staged next to its destination (rename is atomic only within a filesystem)
# and moved into place; the manifest goes last so it never names a file that is
# not there yet. Stale files go after, so the manifest never lists a deleted one.
mkdir -p "$OUT"
articles_to_write=$(printf '%s\n' $drift_list | grep -v '^hc-manifest.json$' || true)
manifest_to_write=$(printf '%s\n' $drift_list | grep '^hc-manifest.json$' || true)

# Any publish error (disk full, permissions, I/O) must not leave a mixed corpus:
# originals of everything we are about to replace or delete are copied aside first
# and put back on failure, and the failure pages like any other refusal.
BACKUP="$TMPDIR_RUN/backup"; mkdir -p "$BACKUP"
for n in $drift_list $stale_list; do
  if [ -e "$OUT/$n" ]; then cp -p "$OUT/$n" "$BACKUP/$n" || die "could not back up $n; existing corpus left untouched"; fi
done
# rollback sets ROLLBACK_FAILED to the files it could not put back (e.g. ENOSPC when
# an original is larger than its replacement), so die never claims a restore that failed.
ROLLBACK_FAILED=""
rollback() {
  local n
  for n in $drift_list $stale_list; do
    if [ -e "$BACKUP/$n" ]; then
      cp -p "$BACKUP/$n" "$OUT/$n" 2>/dev/null || ROLLBACK_FAILED="$ROLLBACK_FAILED $n"
    else
      rm -f "${OUT:?}/${n:?}" 2>/dev/null || ROLLBACK_FAILED="$ROLLBACK_FAILED $n"
    fi
  done
}
publish() {
  local n
  for n in $articles_to_write $manifest_to_write; do
    install -m 644 "$REND/$n" "$OUT/${n%.*}.tmp.$$" || return 1
    mv -f "$OUT/${n%.*}.tmp.$$" "$OUT/$n" || return 1
  done
  for n in $stale_list; do rm -f "${OUT:?}/${n:?}" || return 1; done
}
if ! publish; then
  rollback
  [ -z "$ROLLBACK_FAILED" ] || die "ROLLBACK INCOMPLETE:$ROLLBACK_FAILED; corpus is MIXED, repair by hand (publish failed part-way)"
  die "publish FAILED part-way; previous corpus restored"
fi

echo "OK: $OUT updated from $URL (CHANGED:${drift_list:- none}; removed:${stale_list:- none})"
notify ":arrows_counterclockwise: Caroline's help-centre corpus just changed, straight from help.muso.ai with no human in the loop (${count} articles). \`$OUT\` on node-8, or \`/opt/hydra/scripts/sync-help-centre.sh --dry-run\`."
exit 0
