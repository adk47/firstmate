#!/usr/bin/env bats
# Safety gate for Caroline's help-centre corpus (scripts/sync-help-centre.sh).
#
# The script reads the Intercom llms.txt inventory and writes one flat
# reference/hc-<id>.md per article plus reference/hc-manifest.json. Those files
# are server-generated and rsync-excluded, so the CI "CS agent reference file
# security scan" (non-recursive glob over TRACKED files) cannot see them: THIS
# suite is the gate of record for what reaches Caroline's RAG index.
#
# Every assertion uses `run` + an explicit status check (a bare `! cmd` is a
# no-op in bats unless it is the last line).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SYNC="$HYDRA_REPO/scripts/sync-help-centre.sh"

# make_site <count> -- fixture help centre: $SITE/llms.txt plus count articles
# with ids 1000..(1000+count-1), served over file:// URLs.
make_site() {
  local n="$1" i
  mkdir -p "$SITE/en/articles"
  {
    printf '# Muso.AI Help Center\n\n## Getting Started\n\n'
    for ((i = 0; i < n; i++)); do
      printf -- '- [Article %d](file://%s/en/articles/%d-article-%d.md): blurb\n' \
        "$i" "$SITE" $((1000 + i)) "$i"
      printf '# Article %d\n\nBody of article %d with an em\xe2\x80\x94dash.\n\n![](https://downloads.intercomcdn.com/i/o/x/%d/p.png?expires=1&amp;signature=abc)\n\nMore text.\n' \
        "$i" "$i" "$i" >"$SITE/en/articles/$((1000 + i))-article-$i.md"
    done
  } >"$SITE/llms.txt"
}

setup() {
  SITE="$BATS_TEST_TMPDIR/site"
  OUT="$BATS_TEST_TMPDIR/reference"
  mkdir -p "$OUT"
  export MUSO_BIN=/nonexistent   # hermetic: never post to Slack
  export HELP_CENTRE_NO_NOTIFY=1
  make_site 45
}

run_sync() {
  run env HELP_CENTRE_LLMS_URL="file://$SITE/llms.txt" HELP_CENTRE_OUT="$OUT" \
    HELP_CENTRE_URL_PREFIX="file://$SITE/" HELP_CENTRE_CURL_PROTO="=file" \
    bash "$SYNC" "$@"
}

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

snapshot() { (cd "$OUT" && find . -type f | LC_ALL=C sort | xargs -I{} shasum {} 2>/dev/null); }

@test "script exists and is executable" {
  [ -x "$SYNC" ]
}

@test "install writes one flat hc-<id>.md per article plus the manifest" {
  run_sync
  [ "$status" -eq 0 ]
  [ "$(ls "$OUT"/hc-*.md | wc -l | tr -d ' ')" -eq 45 ]
  [ -f "$OUT/hc-manifest.json" ]
  [ -f "$OUT/hc-1000.md" ]
  # nothing nested, nothing left behind
  [ -z "$(find "$OUT" -mindepth 1 -type d)" ]
  [ -z "$(ls "$OUT" | grep -v '^hc-')" ]
}

@test "frontmatter carries title, canonical_url (no .md) and source_sha" {
  run_sync
  [ "$status" -eq 0 ]
  head -1 "$OUT/hc-1003.md" | grep -qx -- '---'
  grep -qx 'title: "Article 3"' "$OUT/hc-1003.md"
  grep -qx "canonical_url: \"file://$SITE/en/articles/1003-article-3\"" "$OUT/hc-1003.md"
  grep -Eq '^source_sha: "?[0-9a-f]{64}"?$' "$OUT/hc-1003.md"
}

@test "manifest shape: articles keyed by id with slug, title, url" {
  run_sync
  [ "$status" -eq 0 ]
  run python3 -I - "$OUT/hc-manifest.json" "$SITE" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); site = sys.argv[2]
assert set(m) == {"generated_at", "articles"}, set(m)
assert m["generated_at"]
a = m["articles"]
assert len(a) == 45
e = a["1003"]
assert set(e) == {"slug", "title", "url"}, set(e)
assert e["slug"] == "article-3", e
assert e["title"] == "Article 3", e
assert e["url"] == f"file://{site}/en/articles/1003-article-3", e
PY
  [ "$status" -eq 0 ]
}

@test "manifest url equals the canonical_url in the matching article" {
  run_sync
  [ "$status" -eq 0 ]
  url=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["articles"]["1010"]["url"])' "$OUT/hc-manifest.json")
  grep -qxF "canonical_url: \"$url\"" "$OUT/hc-1010.md"
}

@test "image markdown is stripped" {
  run_sync
  [ "$status" -eq 0 ]
  run grep -rl 'intercomcdn\|!\[' "$OUT"
  [ "$status" -eq 1 ]
  grep -q 'More text.' "$OUT/hc-1000.md"
}

@test "em-dashes are normalised to ' -- '" {
  run_sync
  [ "$status" -eq 0 ]
  run grep -rl $'\xe2\x80\x94' "$OUT"
  [ "$status" -eq 1 ]
  grep -q 'an em -- dash' "$OUT/hc-1000.md"
}

@test "a second run with unchanged upstream rewrites nothing" {
  run_sync; [ "$status" -eq 0 ]
  before=$(snapshot)
  stamp=$(mtime "$OUT/hc-manifest.json")
  sleep 1.1
  run_sync; [ "$status" -eq 0 ]
  [ "$(snapshot)" = "$before" ]
  after=$(mtime "$OUT/hc-manifest.json")
  [ "$stamp" = "$after" ]
  [[ "$output" == *"unchanged"* ]]
}

@test "--check is 0 when current, non-zero and silent on disk when an article is dropped upstream" {
  run_sync; [ "$status" -eq 0 ]
  run_sync --check
  [ "$status" -eq 0 ]
  before=$(snapshot)
  grep -v 'article-7.md' "$SITE/llms.txt" >"$SITE/llms.new" && mv "$SITE/llms.new" "$SITE/llms.txt"
  run_sync --check
  [ "$status" -ne 0 ]
  [ "$(snapshot)" = "$before" ]
}

@test "--check is non-zero when nothing is installed yet" {
  run_sync --check
  [ "$status" -ne 0 ]
  [ -z "$(ls "$OUT")" ]
}

@test "--check is non-zero when an installed article body was edited" {
  run_sync; [ "$status" -eq 0 ]
  echo "tampered" >>"$OUT/hc-1002.md"
  run_sync --check
  [ "$status" -ne 0 ]
}

@test "--dry-run writes nothing to OUT" {
  run_sync --dry-run
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$OUT")" ]
}

@test "an upstream removal is refused by default and leaves the corpus intact" {
  run_sync; [ "$status" -eq 0 ]
  before=$(snapshot)
  grep -v 'article-7.md' "$SITE/llms.txt" >"$SITE/llms.new" && mv "$SITE/llms.new" "$SITE/llms.txt"
  run_sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"HELP_CENTRE_ALLOW_REMOVALS"* ]]
  [ "$(snapshot)" = "$before" ]
}

@test "a 45 -> 40 truncated inventory (above the floor) cannot delete valid articles" {
  run_sync; [ "$status" -eq 0 ]
  before=$(snapshot)
  head -n 44 "$SITE/llms.txt" >"$SITE/llms.new" && mv "$SITE/llms.new" "$SITE/llms.txt"
  [ "$(grep -c 'articles/' "$SITE/llms.txt")" -eq 40 ]
  run_sync
  [ "$status" -ne 0 ]
  [ "$(snapshot)" = "$before" ]
}

@test "an inventory URL outside the allowed prefix is refused before any fetch" {
  printf -- '- [Evil](file:///etc/hosts.md): x\n' >>"$SITE/llms.txt"
  run_sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside"* ]]
  [ -z "$(ls -A "$OUT")" ]
}

@test "production defaults reject file:// inventory URLs and fetch nothing" {
  run env HELP_CENTRE_LLMS_URL="file://$SITE/llms.txt" HELP_CENTRE_OUT="$OUT" HELP_CENTRE_NO_NOTIFY=1 \
    bash "$SYNC"
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$OUT")" ]
}

@test "an upstream removal deletes the stale hc file when HELP_CENTRE_ALLOW_REMOVALS=1" {
  run_sync; [ "$status" -eq 0 ]
  grep -v 'article-7.md' "$SITE/llms.txt" >"$SITE/llms.new" && mv "$SITE/llms.new" "$SITE/llms.txt"
  HELP_CENTRE_ALLOW_REMOVALS=1 run_sync; [ "$status" -eq 0 ]
  [ ! -e "$OUT/hc-1007.md" ]
  run python3 -I -c 'import json,sys;sys.exit(0 if "1007" not in json.load(open(sys.argv[1]))["articles"] else 1)' "$OUT/hc-manifest.json"
  [ "$status" -eq 0 ]
}

@test "one failing article fetch leaves the pre-existing corpus byte-for-byte intact" {
  run_sync; [ "$status" -eq 0 ]
  before=$(snapshot)
  # upstream content changes AND one article now 404s
  echo "new text" >>"$SITE/en/articles/1000-article-0.md"
  rm "$SITE/en/articles/1020-article-20.md"
  run_sync
  [ "$status" -ne 0 ]
  [ "$(snapshot)" = "$before" ]
}

@test "an empty article body leaves the corpus intact" {
  run_sync; [ "$status" -eq 0 ]
  before=$(snapshot)
  echo "changed" >>"$SITE/en/articles/1000-article-0.md"
  : >"$SITE/en/articles/1020-article-20.md"
  run_sync
  [ "$status" -ne 0 ]
  [ "$(snapshot)" = "$before" ]
}

@test "a 200-OK non-markdown body (no H1) leaves the corpus intact" {
  run_sync; [ "$status" -eq 0 ]
  before=$(snapshot)
  echo "changed" >>"$SITE/en/articles/1000-article-0.md"
  printf '<!DOCTYPE html><html><head><title>Just a moment...</title></head></html>\n' \
    >"$SITE/en/articles/1007-article-7.md"
  run_sync
  [ "$status" -ne 0 ]
  [ "$(snapshot)" = "$before" ]
}

@test "a failing inventory fetch leaves the corpus intact" {
  run_sync; [ "$status" -eq 0 ]
  before=$(snapshot)
  rm "$SITE/llms.txt"
  run_sync
  [ "$status" -ne 0 ]
  [ "$(snapshot)" = "$before" ]
}

@test "an inventory parsing to 39 articles refuses to install (floor is 40)" {
  make_site 39
  run_sync
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$OUT")" ]
  [[ "$output" == *"39"* ]]
}

@test "a shrunken inventory cannot shrink the corpus" {
  run_sync; [ "$status" -eq 0 ]
  before=$(snapshot)
  head -n 20 "$SITE/llms.txt" >"$SITE/llms.new" && mv "$SITE/llms.new" "$SITE/llms.txt"
  run_sync
  [ "$status" -ne 0 ]
  [ "$(snapshot)" = "$before" ]
}

@test "an inventory of exactly 40 installs" {
  make_site 40
  run_sync
  [ "$status" -eq 0 ]
  [ "$(ls "$OUT"/hc-*.md | wc -l | tr -d ' ')" -eq 40 ]
}

@test "a blocklisted term in one article refuses to install anything" {
  run_sync; [ "$status" -eq 0 ]
  before=$(snapshot)
  echo "We run on Kubernetes and Hetzner." >>"$SITE/en/articles/1015-article-15.md"
  echo "new text" >>"$SITE/en/articles/1000-article-0.md"
  run_sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"Kubernetes"* ]]
  [ "$(snapshot)" = "$before" ]
}

@test "a blocklisted term on first install installs nothing" {
  echo "Vault" >>"$SITE/en/articles/1015-article-15.md"
  run_sync
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$OUT")" ]
}

@test "no staging leftovers remain in OUT after success or refusal" {
  run_sync; [ "$status" -eq 0 ]
  echo "Docker" >>"$SITE/en/articles/1001-article-1.md"
  run_sync; [ "$status" -ne 0 ]
  [ -z "$(ls -A "$OUT" | grep -v '^hc-')" ]
  [ -z "$(ls -A "$OUT" | grep tmp)" ]
}

@test "HELP_CENTRE_OUT is honoured: a dry-run never touches the default path" {
  run env -u HELP_CENTRE_OUT HELP_CENTRE_LLMS_URL="file://$SITE/llms.txt" \
    HELP_CENTRE_URL_PREFIX="file://$SITE/" HELP_CENTRE_CURL_PROTO="=file" \
    bash "$SYNC" --dry-run
  [ "$status" -eq 0 ]
  run grep -n 'HELP_CENTRE_OUT:-' "$SYNC"
  [ "$status" -eq 0 ]
}

@test "unknown argument is a usage error" {
  run -2 env HELP_CENTRE_LLMS_URL=x HELP_CENTRE_OUT=x bash "$SYNC" --bogus
  [ "$status" -eq 2 ]
}

# serve_redirect -- local HTTP server: /en/articles/1003-article-3.md 302s to a
# different origin (127.0.0.1 vs localhost), everything else is served from $SITE.
serve_redirect() {
  cat >"$BATS_TEST_TMPDIR/srv.py" <<'PY'
import http.server, sys, os
site, port = sys.argv[1], int(sys.argv[2])
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(s, *a, **k): super().__init__(*a, directory=site, **k)
    def do_GET(s):
        if s.path.endswith('1003-article-3.md'):
            s.send_response(302); s.send_header('Location', 'http://127.0.0.1:%d/evil.md' % (port + 1)); s.end_headers()
        else: super().do_GET()
    def log_message(*a): pass
http.server.HTTPServer(('localhost', port), H).serve_forever()
PY
  PORT=$((20000 + RANDOM % 20000))
  python3 -I "$BATS_TEST_TMPDIR/srv.py" "$SITE" "$PORT" & SRV=$!
  sleep 1
}

@test "an article that redirects off the allowed prefix is refused and the corpus is intact" {
  serve_redirect
  sed -i.bak "s#file://$SITE/#http://localhost:$PORT/#" "$SITE/llms.txt"
  run env HELP_CENTRE_LLMS_URL="http://localhost:$PORT/llms.txt" HELP_CENTRE_OUT="$OUT" \
    HELP_CENTRE_URL_PREFIX="http://localhost:$PORT/" HELP_CENTRE_CURL_PROTO="=http" HELP_CENTRE_NO_NOTIFY=1 \
    bash "$SYNC"
  kill "$SRV" 2>/dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside"* ]]
  [ -z "$(ls -A "$OUT")" ]
}

@test "a live lock held by another run refuses to install and touches nothing" {
  mkdir "$OUT.lock"; sleep 30 & echo $! >"$OUT.lock/pid"; holder=$!
  run_sync
  kill "$holder" 2>/dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"another run"* ]]
  [ -z "$(ls -A "$OUT")" ]
}

@test "a stale lock from a dead run is reaped and the install proceeds and releases it" {
  mkdir "$OUT.lock"; echo 999999 >"$OUT.lock/pid"
  run_sync
  [ "$status" -eq 0 ]
  [ ! -e "$OUT.lock" ]
}

@test "a publish failure part-way restores the previous corpus byte-for-byte and refuses" {
  run_sync
  [ "$status" -eq 0 ]
  # upstream changes three articles, then the 2nd write of the next install fails
  for i in 3 4 5; do printf '# Article %d\n\nNEW body %d.\n' "$i" "$i" >"$SITE/en/articles/$((1000 + i))-article-$i.md"; done
  before="$(snapshot)"
  shim="$BATS_TEST_TMPDIR/shim"; mkdir -p "$shim"
  real_install="$(command -v install)"
  cat >"$shim/install" <<SH
#!/bin/bash
c=\$(cat "$BATS_TEST_TMPDIR/n" 2>/dev/null || echo 0); c=\$((c + 1)); echo "\$c" >"$BATS_TEST_TMPDIR/n"
[ "\$c" -ne 2 ] || { echo "install: simulated disk full" >&2; exit 1; }
exec "$real_install" "\$@"
SH
  chmod +x "$shim/install"
  run env PATH="$shim:$PATH" HELP_CENTRE_LLMS_URL="file://$SITE/llms.txt" HELP_CENTRE_OUT="$OUT" \
    HELP_CENTRE_URL_PREFIX="file://$SITE/" HELP_CENTRE_CURL_PROTO="=file" HELP_CENTRE_NO_NOTIFY=1 \
    bash "$SYNC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"publish FAILED"* ]]
  [ "$(snapshot)" = "$before" ]
  [ ! -e "$OUT.lock" ]
}

@test "a stale lock being reclaimed by another run is not stolen: refuse and touch nothing" {
  mkdir "$OUT.lock" "$OUT.lock.reap"; echo 999999 >"$OUT.lock/pid"
  run_sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"reclaiming"* ]]
  [ -d "$OUT.lock" ]
  [ -z "$(ls -A "$OUT")" ]
}

@test "a failed restore is reported as a MIXED corpus, never as 'previous corpus restored'" {
  run_sync
  [ "$status" -eq 0 ]
  for i in 3 4 5; do printf '# Article %d\n\nNEW body %d.\n' "$i" "$i" >"$SITE/en/articles/$((1000 + i))-article-$i.md"; done
  shim="$BATS_TEST_TMPDIR/shim"; mkdir -p "$shim"
  real_install="$(command -v install)"; real_cp="$(command -v cp)"
  cat >"$shim/install" <<SH
#!/bin/bash
c=\$(cat "$BATS_TEST_TMPDIR/n" 2>/dev/null || echo 0); c=\$((c + 1)); echo "\$c" >"$BATS_TEST_TMPDIR/n"
[ "\$c" -ne 2 ] || { echo "install: simulated disk full" >&2; exit 1; }
exec "$real_install" "\$@"
SH
  # restoring into OUT fails too (ENOSPC when an original is bigger than its replacement)
  cat >"$shim/cp" <<SH
#!/bin/bash
for a in "\$@"; do last="\$a"; done
case "\$last" in "$OUT"/*) echo "cp: simulated ENOSPC" >&2; exit 1 ;; esac
exec "$real_cp" "\$@"
SH
  chmod +x "$shim/install" "$shim/cp"
  run env PATH="$shim:$PATH" HELP_CENTRE_LLMS_URL="file://$SITE/llms.txt" HELP_CENTRE_OUT="$OUT" \
    HELP_CENTRE_URL_PREFIX="file://$SITE/" HELP_CENTRE_CURL_PROTO="=file" HELP_CENTRE_NO_NOTIFY=1 \
    bash "$SYNC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ROLLBACK INCOMPLETE"* ]]
  [[ "$output" == *"MIXED"* ]]
  [[ "$output" != *"previous corpus restored"* ]]
}

@test "reclaim re-checks staleness under the mutex: a lock another run just took is not deleted" {
  mkdir "$OUT.lock"; echo 999999 >"$OUT.lock/pid"
  sleep 60 & live=$!
  shim="$BATS_TEST_TMPDIR/shim"; mkdir -p "$shim"
  real_mkdir="$(command -v mkdir)"
  # when the script takes the .reap mutex, a racing run has already replaced the stale
  # lock with its own live one (the interleaving the re-check exists for)
  cat >"$shim/mkdir" <<SH
#!/bin/bash
if [ "\$1" = "$OUT.lock.reap" ]; then
  rm -rf "$OUT.lock"; "$real_mkdir" "$OUT.lock"; echo $live >"$OUT.lock/pid"
fi
exec "$real_mkdir" "\$@"
SH
  chmod +x "$shim/mkdir"
  run env PATH="$shim:$PATH" HELP_CENTRE_LLMS_URL="file://$SITE/llms.txt" HELP_CENTRE_OUT="$OUT" \
    HELP_CENTRE_URL_PREFIX="file://$SITE/" HELP_CENTRE_CURL_PROTO="=file" HELP_CENTRE_NO_NOTIFY=1 \
    bash "$SYNC"
  kill_status=0; [ "$(cat "$OUT.lock/pid" 2>/dev/null)" = "$live" ] || kill_status=1
  kill "$live" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"lost the race"* ]]
  [ "$kill_status" -eq 0 ]
  [ -z "$(ls -A "$OUT")" ]
}

@test "a lock with no pid yet is treated as live when fresh" {
  mkdir "$OUT.lock"
  run_sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"another run"* ]]
  [ -d "$OUT.lock" ]
}

@test "two simultaneous runs against a stale lock: both exit cleanly, corpus is complete" {
  mkdir "$OUT.lock"; echo 999999 >"$OUT.lock/pid"
  env HELP_CENTRE_LLMS_URL="file://$SITE/llms.txt" HELP_CENTRE_OUT="$OUT" HELP_CENTRE_URL_PREFIX="file://$SITE/" \
    HELP_CENTRE_CURL_PROTO="=file" HELP_CENTRE_NO_NOTIFY=1 bash "$SYNC" >/dev/null 2>&1 &
  p1=$!
  env HELP_CENTRE_LLMS_URL="file://$SITE/llms.txt" HELP_CENTRE_OUT="$OUT" HELP_CENTRE_URL_PREFIX="file://$SITE/" \
    HELP_CENTRE_CURL_PROTO="=file" HELP_CENTRE_NO_NOTIFY=1 bash "$SYNC" >/dev/null 2>&1 &
  p2=$!
  wait "$p1" || true; wait "$p2" || true
  [ ! -e "$OUT.lock" ]
  [ ! -e "$OUT.lock.reap" ]
  [ "$(ls "$OUT"/hc-*.md | wc -l | tr -d ' ')" -eq 45 ]
  run_sync
  [ "$status" -eq 0 ]
}
