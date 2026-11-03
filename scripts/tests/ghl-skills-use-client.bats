#!/usr/bin/env bats
# Agent doctrine must call GHL through the canonical client, never an inline recipe (MUS-20383).
# Cloudflare 1010-bans urllib's default User-Agent; scripts/ghl.sh is the one place that sets a
# real one, so a skill that carries its own `curl .../<path>` recipe re-opens the outage.
# A bare base-URL mention (no path) is allowed. Python and docs/ are out of scope.
bats_require_minimum_version 1.5.0

REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

@test "no skill or workspace doc carries an inline services.leadconnectorhq.com/<path> call" {
  run git -C "$REPO" grep -nE 'services\.leadconnectorhq\.com/[A-Za-z]' -- \
    'workspaces/*/skills/**/*.md' 'workspaces/*/*.md' 'skills-all/**/*.md'
  if [ "$status" -ne 1 ]; then
    echo "inline GHL call(s) found; use /opt/hydra/scripts/ghl.sh instead:" >&3
    echo "$output" >&3
    return 1
  fi
}

# Doctrine files whose bash blocks call ghl.sh. Every fenced bash block that mentions
# scripts/ghl.sh is extracted raw (no placeholder substitution, fence indent removed).
# EXEMPT: the Scout discovery block is fail-open on purpose (any non-zero -> SKIP IN_GHL, ship the batch).
EXEMPT='workspaces/scout/skills/muso-outreach-discovery/SKILL.md'

setup() {
  BLOCKS="$BATS_TEST_TMPDIR/blocks"
  mkdir -p "$BLOCKS"
  git -C "$REPO" grep -lE 'scripts/ghl\.sh' -- 'workspaces/*/skills/**/*.md' 'workspaces/*/*.md' 'skills-all/**/*.md' \
    | grep -vxF "$EXEMPT" > "$BATS_TEST_TMPDIR/files"
  python3 -I - "$REPO" "$BATS_TEST_TMPDIR/files" "$BLOCKS" <<'PY'
import re, sys
repo, listing, out = sys.argv[1:4]
n = 0
for rel in open(listing).read().split():
    lines = open(f"{repo}/{rel}").read().split("\n")
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*)```(?:bash|sh)\s*$", lines[i])
        if not m:
            i += 1
            continue
        indent, j = m.group(1), i + 1
        while j < len(lines) and not re.match(r"^\s*```\s*$", lines[j]):
            j += 1
        body = [l[len(indent):] if l.startswith(indent) else l for l in lines[i + 1:j]]
        text = "\n".join(body) + "\n"
        if "scripts/ghl.sh" in text:
            n += 1
            open(f"{out}/{n:03d}.sh", "w").write(f"# {rel}:{i + 2}\n" + text)
        i = j + 1
PY
}

@test "the extractor finds the recipes (a bug that finds zero blocks must not read as green)" {
  n=$(ls "$BLOCKS" | wc -l)
  echo "extracted $n ghl.sh blocks" >&3
  [ "$n" -ge 12 ]
}

@test "every ghl.sh recipe block parses as written (bash -n on the raw text, unquoted <placeholder> paths fail here)" {
  bad=0
  for b in "$BLOCKS"/*.sh; do
    if ! err=$(bash -n "$b" 2>&1); then
      echo "SYNTAX: $(head -1 "$b"): $err" >&3
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}

# Stub ghl.sh: records the --data-file path it was given, exits $STUB_RC. Each block runs with its
# /opt/hydra/scripts/ghl.sh swapped for the stub; the block's own exit status must be ghl.sh's, and a
# --data-file payload must be gone afterwards (success and failure).
run_blocks_with_stub() {
  rc="$1"
  stub="$BATS_TEST_TMPDIR/ghl-stub.sh"
  cat > "$stub" <<'STUB'
#!/bin/bash
while [ $# -gt 0 ]; do
  [ "$1" = "--data-file" ] && echo "$2" >> "$STUB_LOG"
  shift
done
[ "$STUB_RC" -eq 0 ] && echo '{}'
exit "$STUB_RC"
STUB
  chmod +x "$stub"
  fail=0
  for b in "$BLOCKS"/*.sh; do
    sed "s#/opt/hydra/scripts/ghl\\.sh#$stub#g" "$b" > "$b.run"
    : > "$BATS_TEST_TMPDIR/stub.log"
    got=0
    STUB_RC="$rc" STUB_LOG="$BATS_TEST_TMPDIR/stub.log" bash "$b.run" >/dev/null 2>&1 || got=$?
    if [ "$got" -ne "$rc" ]; then
      echo "STATUS: $(head -1 "$b"): block exited $got, ghl.sh exited $rc" >&3
      fail=1
    fi
    while read -r f; do
      [ -z "$f" ] && continue
      if [ -e "$f" ]; then echo "LEFTOVER: $(head -1 "$b"): $f" >&3; rm -f "$f"; fail=1; fi
    done < "$BATS_TEST_TMPDIR/stub.log"
  done
  [ "$fail" -eq 0 ]
}

@test "a failing ghl.sh (exit 11) is the block's exit status and the payload file is gone" {
  run_blocks_with_stub 11
}

@test "a succeeding ghl.sh (exit 0) leaves the block at status 0 and the payload file gone" {
  run_blocks_with_stub 0
}

# The pipeline-stage fetch blocks embed a Python parser. Execute them against a stub 2xx body: they must
# print the stage ids, and a body the parser cannot read must make the block exit non-zero (a parser
# SyntaxError or bad JSON must never read as "ghl.sh succeeded, nothing to report").
run_pipeline_blocks() {
  body="$1"
  stub="$BATS_TEST_TMPDIR/ghl-body-stub.sh"
  printf '#!/bin/bash\nprintf "%%s" "$STUB_BODY"\n' > "$stub"
  chmod +x "$stub"
  found=0
  for b in "$BLOCKS"/*.sh; do
    grep -q 'opportunities/pipelines' "$b" && grep -q 'python3 -c' "$b" || continue
    found=$((found + 1))
    sed "s#/opt/hydra/scripts/ghl\\.sh#$stub#g" "$b" > "$b.run"
    got=0
    out=$(STUB_BODY="$body" bash "$b.run" 2>"$BATS_TEST_TMPDIR/err") || got=$?
    echo "$(head -1 "$b") rc=$got out=[$out] err=[$(head -c 200 "$BATS_TEST_TMPDIR/err")]" >&3
    BLOCK_RC[$found]="$got"
    BLOCK_OUT[$found]="$out"
  done
  [ "$found" -eq 2 ]
}

@test "pipeline-stage blocks print stage ids from a 2xx body and exit 0" {
  declare -a BLOCK_RC BLOCK_OUT
  run_pipeline_blocks '{"pipelines":[{"id":"GeSt85TueSvJ0SNFZXfQ","stages":[{"name":"Cold","id":"stage-out-1"}]},{"id":"AZa8jK5S7UyQ0fqfxzyB","stages":[{"name":"Churned","id":"stage-win-1"}]}]}'
  [ "${BLOCK_RC[1]}" -eq 0 ] && [ "${BLOCK_RC[2]}" -eq 0 ]
  all="${BLOCK_OUT[1]}${BLOCK_OUT[2]}"
  [[ "$all" == *stage-out-1* ]] && [[ "$all" == *stage-win-1* ]]
}

@test "pipeline-stage blocks exit non-zero when the 2xx body is not parseable" {
  declare -a BLOCK_RC BLOCK_OUT
  run_pipeline_blocks 'not json'
  [ "${BLOCK_RC[1]}" -ne 0 ] && [ "${BLOCK_RC[2]}" -ne 0 ]
}
