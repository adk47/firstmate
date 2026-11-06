#!/usr/bin/env bats
# Tests for scripts/qa-findings.sh — the paginated QA-verdict reader.
#
# The regression: `GET /repos/:o/:r/pulls/:n/reviews` pages at 30, OLDEST FIRST,
# so an unpaginated read of a long PR cannot see the newest verdict. Three lanes
# read that as "the QA bot published no finding text" on 2026-11-03 (#1545 = 55
# reviews, #1636 = 40, #1643 = 39). These tests pin the properties that make that
# misread impossible to repeat: the reader pages, it REPORTS the page the finding
# text is on, it reads the head from the PR (not from the newest review), and it
# does not let a human's later review replace the QA verdict.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-findings.sh"

QA_MARKER='🤖 **Muso QA Bot** (automated review)'
PR_HEAD="4228a7b1752842ff7295325704b9cf9627ba8fbc"
PRIOR_HEAD="1f91b6100000000000000000000000000000abcd"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/pages"

  # Build N reviews. Every review carries a body unless its index is in the
  # "bodyless" set. Reviews at index >= first_body carry finding text, so "the
  # finding is only on page 2" is expressible. `--head-sha` stamps the head.
  cat > "$TEST_TMPDIR/make_fixture.py" <<'PY'
import json, sys
total = int(sys.argv[1]); first_body = int(sys.argv[2])
head = sys.argv[3]; out = sys.argv[4]
login = sys.argv[5] if len(sys.argv) > 5 else "adk47"
marker = "🤖 **Muso QA Bot** (automated review)"
revs = []
for i in range(1, total + 1):
    has_body = i >= first_body
    revs.append({
        "id": 5000 + i,
        "user": {"login": login},
        "state": "COMMENTED",
        "submitted_at": "2026-11-03T%02d:%02d:00Z" % (i // 60, i % 60),
        "commit_id": head,
        "html_url": "https://github.com/Muso-AI/hydra/pull/1643#pullrequestreview-%d" % (5754000000 + i),
        "body": (marker + "\n\n**Verdict: NO-GO** finding set %d" % i) if has_body else "",
    })
json.dump(revs, open(out, "w"))
PY

  make_fixture() { # <total> <first_body_index> <head-sha> [login]
    python3 "$TEST_TMPDIR/make_fixture.py" "$1" "$2" "$3" \
      "$TEST_TMPDIR/all.json" "${4:-adk47}"
  }

  # The gh stub: emulates --paginate by emitting one JSON array per page of 30.
  # The PR's CURRENT head is $STUB_PR_HEAD (defaults to the fixture head), so a
  # test can make every review belong to a PRIOR head without touching them.
  cat > "$TEST_TMPDIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_TMPDIR/gh-calls"
url=""; paginate=0; jqf=""
while [ $# -gt 0 ]; do
  case "$1" in
    api) shift ;;
    --paginate) paginate=1; shift ;;
    --jq) jqf="${2:-}"; shift 2 ;;
    *) [ -z "$url" ] && url="$1"; shift ;;
  esac
done
case "$url" in
  */pulls/1643/reviews*)
    [ -n "${STUB_REVIEWS_FAIL:-}" ] && { echo "HTTP 502" >&2; exit 1; }
    [ -n "${STUB_REVIEWS_GARBAGE:-}" ] && { printf '%s\n' '{"message":"Not Found"}'; exit 0; }
    python3 - "$TEST_TMPDIR/all.json" "$paginate" <<'PY'
import json, sys
revs = json.load(open(sys.argv[1]))
if sys.argv[2] != "1":
    print(json.dumps(revs[:30]))
else:
    for s in range(0, len(revs), 30):
        print(json.dumps(revs[s:s+30]))
PY
    ;;
  */statuses*)
    python3 - "$TEST_TMPDIR/statuses.json" <<'PY'
import json, os, sys
print(open(sys.argv[1]).read() if os.path.exists(sys.argv[1]) else "[]")
PY
    ;;
  */pulls/1643)
    [ -n "${STUB_PR_FAIL:-}" ] && { echo "HTTP 502" >&2; exit 1; }
    # emulate `gh api ... --jq '.head.sha'`: bare sha when --jq is present.
    if [ -n "$jqf" ]; then
      printf '%s\n' "${STUB_PR_HEAD:-4228a7b1752842ff7295325704b9cf9627ba8fbc}"
    else
      printf '{"head":{"sha":"%s"}}\n' "${STUB_PR_HEAD:-4228a7b1752842ff7295325704b9cf9627ba8fbc}"
    fi
    ;;
  *) echo "stub: unexpected url $url" >&2; exit 1 ;;
esac
STUB
  chmod +x "$TEST_TMPDIR/gh"
  export QA_FINDINGS_GH="$TEST_TMPDIR/gh"
  # Keep the author allowlist deterministic: the repo's own policy is not read.
  export QA_APPROVAL_POLICY="$TEST_TMPDIR/no-such-policy.json"

  cat > "$TEST_TMPDIR/statuses.json" <<'JSON'
[{"context":"qa-review","state":"failure","description":"NO-GO — 2 blocking Important findings","created_at":"2026-11-03T15:06:20Z","target_url":"https://github.com/Muso-AI/hydra/pull/1643/files"}]
JSON

  export T="$TEST_TMPDIR"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

@test "finds a verdict that lives on page 2 and says which page it is on" {
  make_fixture 39 39 "$PR_HEAD"   # findings only on review #39 = page 2
  run "$SCRIPT" Muso-AI/hydra 1643
  [ "$status" -eq 0 ]
  [[ "$output" == *"39 review(s)"* ]]
  [[ "$output" == *"page 2"* ]]
  [[ "$output" == *"finding set 39"* ]]
  [[ "$output" == *"pullrequestreview-5754000039"* ]]
  # The status description is surfaced too — that is all a reader had before.
  [[ "$output" == *"NO-GO — 2 blocking Important findings"* ]]
  # The reader really paginated (page 2 was requested of the stub in one call).
  grep -q -- "--paginate" "$TEST_TMPDIR/gh-calls"
  # ...and it never filters inside gh's --jq (that would run per page).
  ! grep -q -- "--paginate.*--jq" "$TEST_TMPDIR/gh-calls"
}

@test "an unpaginated read of the same PR would have missed it" {
  make_fixture 39 39 "$PR_HEAD"
  python3 - "$TEST_TMPDIR/all.json" <<'PY'
import json, sys
revs = json.load(open(sys.argv[1]))[:30]
assert all(not r["body"] for r in revs), "fixture is wrong: page 1 should be bodyless"
PY
  run "$SCRIPT" Muso-AI/hydra 1643
  [ "$status" -eq 0 ]
  [[ "$output" == *"finding set 39"* ]]
}

@test "--json exposes the page and permalink for machine relay" {
  make_fixture 39 39 "$PR_HEAD"
  run "$SCRIPT" Muso-AI/hydra 1643 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reviews_total == 39' >/dev/null
  echo "$output" | jq -e '.review_pages == 2' >/dev/null
  echo "$output" | jq -e '.latest.page == 2' >/dev/null
  echo "$output" | jq -e '.latest.review_index == 39' >/dev/null
  echo "$output" | jq -e '.latest.on_head == true' >/dev/null
  echo "$output" | jq -e '.latest.author_trusted == true' >/dev/null
  echo "$output" | jq -e '.latest.body | test("finding set 39")' >/dev/null
  echo "$output" | jq -e '.statuses[0].description | test("NO-GO")' >/dev/null
  # the head came from the PR, not from the newest review
  echo "$output" | jq -e --arg h "$PR_HEAD" '.head == $h and .head_source == "pr"' >/dev/null
  echo "$output" | jq -e '.reason == "ok" and .on_head == true' >/dev/null
}

@test "newest verdict wins, and a short PR keeps working" {
  make_fixture 3 1 "$PR_HEAD"
  run "$SCRIPT" Muso-AI/hydra 1643 --limit 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"finding set 3"* ]]
  [[ "$output" != *"finding set 1"* ]]
}

@test "--head restricts to reviews stamped on that head" {
  make_fixture 5 1 "$PR_HEAD"
  python3 - "$TEST_TMPDIR/all.json" <<'PY'
import json, sys
p = sys.argv[1]
revs = json.load(open(p))
# the newest review belongs to a DIFFERENT head
revs[-1]["commit_id"] = "de" * 20
revs[-1]["body"] = "🤖 **Muso QA Bot** (automated review)\n\nstale verdict from another head"
json.dump(revs, open(p, "w"))
PY
  run "$SCRIPT" Muso-AI/hydra 1643 --head "$PR_HEAD" --limit 1
  [ "$status" -eq 0 ]
  [[ "$output" != *"stale verdict"* ]]
  [[ "$output" == *"finding set 4"* ]]
}

# ── Finding: a prior-head verdict must never be presented as the current one ──
@test "a prior-head-only PR exits 5 and labels the text PRIOR HEAD" {
  make_fixture 5 1 "$PRIOR_HEAD"          # every review is on the prior head
  run "$SCRIPT" Muso-AI/hydra 1643        # ...but the PR head is PR_HEAD
  [ "$status" -eq 5 ]
  [[ "$output" == *"PRIOR HEAD"* ]]
  [[ "$output" == *"finding set 5"* ]]
  [[ "$output" == *"NO QA REVIEW BODY ON THE REQUESTED HEAD"* ]]
  [[ "$output" == *"Re-run QA"* ]]
}

@test "an explicit --head with no review on it exits 5 and does not fall back silently" {
  make_fixture 5 1 "$PRIOR_HEAD"
  run "$SCRIPT" Muso-AI/hydra 1643 --head "$PR_HEAD"
  [ "$status" -eq 5 ]
  [[ "$output" == *"PRIOR HEAD"* ]]
  [[ "$output" == *"(explicit)"* ]]
}

@test "--json on a prior-head-only PR reports reason prior_head_only and latest null" {
  make_fixture 5 1 "$PRIOR_HEAD"
  run "$SCRIPT" Muso-AI/hydra 1643 --json
  [ "$status" -eq 5 ]
  echo "$output" | jq -e '.reason == "prior_head_only"' >/dev/null
  echo "$output" | jq -e '.latest == null' >/dev/null
  echo "$output" | jq -e '.on_head == false' >/dev/null
  echo "$output" | jq -e --arg h "$PRIOR_HEAD" '.prior_head.head == $h' >/dev/null
  echo "$output" | jq -e '.prior_head.candidates | length > 0' >/dev/null
}

@test "an unreadable PR head is a READ FAILURE unless --head is given" {
  make_fixture 5 1 "$PR_HEAD"
  export STUB_PR_FAIL=1
  run "$SCRIPT" Muso-AI/hydra 1643
  [ "$status" -eq 3 ]
  [[ "$output" == *"could not read the current head"* ]]
  # an explicit head needs no PR read, so this still works
  run "$SCRIPT" Muso-AI/hydra 1643 --head "$PR_HEAD"
  [ "$status" -eq 0 ]
}

# ── Finding: non-QA text must not replace the QA verdict ──────────────────────
@test "a human review posted after QA does not replace the verdict" {
  make_fixture 5 1 "$PR_HEAD"
  python3 - "$TEST_TMPDIR/all.json" <<'PY'
import json, sys
p = sys.argv[1]
revs = json.load(open(p))
# a person reviews the same commit AFTER the bot — highest id, no QA marker
revs.append({
    "id": 9999, "user": {"login": "a-human"}, "state": "COMMENTED",
    "submitted_at": "2026-11-03T20:00:00Z", "commit_id": revs[-1]["commit_id"],
    "html_url": "https://github.com/Muso-AI/hydra/pull/1643#pullrequestreview-9999",
    "body": "looks good to me, but I am not the QA bot",
})
json.dump(revs, open(p, "w"))
PY
  run "$SCRIPT" Muso-AI/hydra 1643 --limit 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"finding set 5"* ]]
  [[ "$output" != *"not the QA bot"* ]]
}

@test "a QA marker from an unlisted login is NOT the verdict: exit 6, text printed" {
  make_fixture 3 1 "$PR_HEAD" "not-in-the-allowlist"
  run "$SCRIPT" Muso-AI/hydra 1643 --limit 1
  [ "$status" -eq 6 ]
  [[ "$output" == *"NEWEST OCCURRENCE IS FROM AN UNLISTED AUTHOR"* ]]
  [[ "$output" == *"UNTRUSTED AUTHOR"* ]]
  [[ "$output" == *"--any-author"* ]]
  # the text is NOT thrown away — it is printed so a human can read it
  [[ "$output" == *"finding set 3"* ]]
}

@test "a newer unlisted marker outranks an older trusted one on the same head" {
  # Round 7's finding: order decides within a head. An allowlisted GO followed by
  # an unlisted NO-GO on the SAME commit means the GO is the stale body. Exit 6
  # and print the newer text — and do NOT hide the older trusted text either, so
  # a human can read both and see why the verdict is ambiguous. A person merely
  # quoting the marker therefore cannot BECOME the verdict (it stays flagged as
  # untrusted), but it is surfaced rather than silently dropped.
  make_fixture 3 1 "$PR_HEAD"
  python3 - "$TEST_TMPDIR/all.json" <<'PY'
import json, sys
p = sys.argv[1]
revs = json.load(open(p))
revs.append({
    "id": 9999, "user": {"login": "a-human"}, "state": "COMMENTED",
    "submitted_at": "2026-11-03T20:00:00Z", "commit_id": revs[-1]["commit_id"],
    "html_url": "https://github.com/Muso-AI/hydra/pull/1643#pullrequestreview-9999",
    "body": "🤖 **Muso QA Bot** (automated review)\n\n**Verdict: NO-GO** I am a human quoting the marker",
})
json.dump(revs, open(p, "w"))
PY
  run "$SCRIPT" Muso-AI/hydra 1643 --limit 1
  [ "$status" -eq 6 ]
  [[ "$output" == *"NEWEST OCCURRENCE IS FROM AN UNLISTED AUTHOR"* ]]
  # the newer unlisted text IS printed, and flagged as untrusted
  [[ "$output" == *"I am a human quoting the marker"* ]]
  [[ "$output" == *"UNTRUSTED AUTHOR"* ]]
  # the older trusted text is NOT hidden either
  [[ "$output" == *"finding set 3"* ]]
  # --json agrees: latest is the untrusted one, so a caller cannot read a stale GO
  run "$SCRIPT" Muso-AI/hydra 1643 --limit 1 --json
  [ "$status" -eq 6 ]
  echo "$output" | jq -e '.reason == "untrusted_author_only"' >/dev/null
  echo "$output" | jq -e '.latest_untrusted == true' >/dev/null
  echo "$output" | jq -e '.latest.body | test("I am a human quoting the marker")' >/dev/null
  # the trusted review is still reachable in candidates
  echo "$output" | jq -e '[.candidates[] | select(.author_trusted)] | length > 0' >/dev/null
}

@test "the newest same-head marker decides even when the trusted one is newer" {
  # The mirror case: an unlisted NO-GO first, then an allowlisted GO on the same
  # head. Here the trusted text IS the newest word, so normal mode exits 0 and
  # prints it without flagging.
  make_fixture 3 1 "$PR_HEAD"
  python3 - "$TEST_TMPDIR/all.json" <<'PY'
import json, sys
p = sys.argv[1]
revs = json.load(open(p))
revs.insert(0, {
    "id": 9998, "user": {"login": "not-in-the-allowlist"}, "state": "COMMENTED",
    "submitted_at": "2026-11-03T19:00:00Z", "commit_id": revs[0]["commit_id"],
    "html_url": "https://github.com/Muso-AI/hydra/pull/1643#pullrequestreview-9998",
    "body": "🤖 **Muso QA Bot** (automated review)\n\n**Verdict: NO-GO** an earlier unlisted marker",
})
json.dump(revs, open(p, "w"))
PY
  run "$SCRIPT" Muso-AI/hydra 1643 --limit 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"finding set 3"* ]]
  run "$SCRIPT" Muso-AI/hydra 1643 --limit 1 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reason == "ok"' >/dev/null
  echo "$output" | jq -e '.latest.author_trusted == true' >/dev/null
}

@test "--any-author accepts a review with no QA marker" {
  make_fixture 3 1 "$PR_HEAD"
  python3 - "$TEST_TMPDIR/all.json" <<'PY'
import json, sys
p = sys.argv[1]
revs = json.load(open(p))
for r in revs:
    r["body"] = "plain prose, no marker %d" % r["id"]
json.dump(revs, open(p, "w"))
PY
  run "$SCRIPT" Muso-AI/hydra 1643
  [ "$status" -eq 4 ]
  run "$SCRIPT" Muso-AI/hydra 1643 --any-author
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: --any-author"* ]]
}

@test "--limit 0 is rejected, because 0 would hide the text instead of limiting it" {
  # Round 3: --limit 0 passed numeric validation, sliced on_head+prior to empty,
  # and reported exit 4 "status-only" on a PR that HAS finding text. A display
  # knob must never be able to turn "text exists" into "no findings".
  make_fixture 39 39 "$PR_HEAD"
  run "$SCRIPT" Muso-AI/hydra 1643 --limit 0
  [ "$status" -eq 2 ]
  [[ "$output" == *"positive integer"* ]]
  [ ! -f "$TEST_TMPDIR/gh-calls" ]   # rejected before any API call
}

@test "existence is computed before display slicing: a small --limit still finds page-2 text" {
  # The other half of round 3: counts came from the SLICED arrays, so the limit
  # decided whether a finding "existed". Existence is now computed on the full
  # lists; --limit only trims what is printed.
  make_fixture 39 39 "$PR_HEAD"
  run "$SCRIPT" Muso-AI/hydra 1643 --limit 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"finding set 39"* ]]
}

@test "existence is computed before display slicing on a prior-head-only PR too" {
  # The same bug on the prior-head branch: --limit 0 used to slice `prior` empty
  # and exit 4 "no review body" when prior-head text existed. With the fix the
  # prior-head case still reports exit 5 at a small limit.
  make_fixture 2 1 "$PRIOR_HEAD"     # every review stamped on the prior head
  run "$SCRIPT" Muso-AI/hydra 1643 --limit 1
  [ "$status" -eq 5 ]
  [[ "$output" == *"PRIOR HEAD"* ]]
  [[ "$output" == *"finding set 2"* ]]
}

@test "current-head untrusted text outranks prior-head trusted text" {
  # Round 3: the allowlisted bot reviewed the PRIOR head and an unlisted login
  # posted marker text on the CURRENT head. The prior_found branch won first, so
  # the script exited 5 printing only PRIOR HEAD and the finding on the head
  # under review was invisible. The current head is what was asked about.
  make_fixture 2 1 "$PRIOR_HEAD"        # trusted bot text, but on the prior head
  python3 - "$TEST_TMPDIR/all.json" <<'PY'
import json, sys
p = sys.argv[1]
revs = json.load(open(p))
revs.append({
    "id": 9999, "user": {"login": "a-human"}, "state": "COMMENTED",
    "submitted_at": "2026-11-03T21:00:00Z",
    "commit_id": "4228a7b1752842ff7295325704b9cf9627ba8fbc",
    "html_url": "https://github.com/Muso-AI/hydra/pull/1643#pullrequestreview-9999",
    "body": "🤖 **Muso QA Bot** (automated review)\n\n**Verdict: NO-GO** current head finding set 9999",
})
json.dump(revs, open(p, "w"))
PY
  run "$SCRIPT" Muso-AI/hydra 1643
  [ "$status" -eq 6 ]
  # the CURRENT head's text is what gets printed...
  [[ "$output" == *"current head finding set 9999"* ]]
  [[ "$output" == *"ON THE REQUESTED HEAD"* ]]
  # ...the prior-head text is not silently presented as the answer...
  [[ "$output" != *"--- PRIOR HEAD review"* ]]
  # ...and the prior text is still pointed at rather than lost.
  [[ "$output" == *"NOTE: trusted QA text also exists on PRIOR head"* ]]
}

@test "untrusted text that exists only on prior heads is reported, not swallowed" {
  # The last branch: no trusted text anywhere, and the marker text is both
  # unlisted AND superseded. Exiting 4 would claim "no review body exists"; the
  # text does exist and a human needs to see why it is not the verdict.
  make_fixture 2 1 "$PRIOR_HEAD" "not-in-the-allowlist"
  run "$SCRIPT" Muso-AI/hydra 1643
  [ "$status" -eq 6 ]
  [[ "$output" == *"ONLY ON PRIOR HEADS"* ]]
  [[ "$output" == *"PRIOR HEAD UNTRUSTED AUTHOR"* ]]
  [[ "$output" == *"finding set 2"* ]]
  run "$SCRIPT" Muso-AI/hydra 1643 --json
  [ "$status" -eq 6 ]
  [[ "$output" == *"untrusted_author_prior_head_only"* ]]
}

@test "no review body anywhere exits 4 and says the verdict is status-only" {
  make_fixture 12 99 "$PR_HEAD"   # nobody has a body
  run "$SCRIPT" Muso-AI/hydra 1643
  [ "$status" -eq 4 ]
  [[ "$output" == *"NO QA REVIEW BODY"* ]]
  [[ "$output" == *"status-only"* ]]
  # ...and it still shows the status so the caller can relay the description.
  [[ "$output" == *"NO-GO — 2 blocking Important findings"* ]]
}

@test "an unreadable reviews list is a READ FAILURE, never 'no findings'" {
  make_fixture 39 39 "$PR_HEAD"
  export STUB_REVIEWS_FAIL=1
  run "$SCRIPT" Muso-AI/hydra 1643
  [ "$status" -eq 3 ]
  [[ "$output" == *"unreadable"* ]]
  [[ "$output" != *"NO QA REVIEW BODY"* ]]
}

@test "an error object instead of a page is a read failure, not an empty list" {
  export STUB_REVIEWS_GARBAGE=1
  run "$SCRIPT" Muso-AI/hydra 1643
  [ "$status" -eq 3 ]
  [[ "$output" == *"did not parse"* ]]
}

@test "rejects a bad repo, a non-numeric PR and a bad head before any API call" {
  run "$SCRIPT" not-a-repo 1643
  [ "$status" -eq 2 ]
  run "$SCRIPT" Muso-AI/hydra abc
  [ "$status" -eq 2 ]
  run "$SCRIPT" Muso-AI/hydra 1643 --head zzz
  [ "$status" -eq 2 ]
  [ ! -f "$TEST_TMPDIR/gh-calls" ]
}

@test "reads the policy's bot_logins when the policy is present" {
  make_fixture 3 1 "$PR_HEAD" "policy-listed-bot"
  cat > "$TEST_TMPDIR/policy.json" <<'JSON'
{"version":1,"identity":{"bot_logins":["muso-qa-bot","policy-listed-bot"]}}
JSON
  export QA_APPROVAL_POLICY="$TEST_TMPDIR/policy.json"
  run "$SCRIPT" Muso-AI/hydra 1643 --limit 1
  [ "$status" -eq 0 ]
  [[ "$output" != *"UNTRUSTED AUTHOR"* ]]
  # ...and a login NOT in that policy's list is still rejected, loudly
  make_fixture 3 1 "$PR_HEAD" "adk47"
  run "$SCRIPT" Muso-AI/hydra 1643 --limit 1
  [ "$status" -eq 6 ]
  [[ "$output" == *"UNTRUSTED AUTHOR"* ]]
}

@test "a newer unlisted marker on a PRIOR head outranks an older trusted one there" {
  # Round 9's finding: the human-readable prior-head path used to let an older
  # trusted GO win over a newer unlisted NO-GO on that same prior head. Order
  # decides there too, so exit 6 prints the newer text AND the older trusted text.
  make_fixture 2 1 "$PRIOR_HEAD"            # trusted bodies, all on the prior head
  python3 - "$TEST_TMPDIR/all.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
revs = json.load(open(p))
revs.append({
    "id": 9997, "user": {"login": "not-in-the-allowlist"}, "state": "COMMENTED",
    "submitted_at": "2026-11-03T21:00:00Z", "commit_id": revs[-1]["commit_id"],
    "html_url": "https://github.com/Muso-AI/hydra/pull/1643#pullrequestreview-9997",
    "body": "\U0001F916 **Muso QA Bot** (automated review)\n\n**Verdict: NO-GO** a newer unlisted prior marker",
})
json.dump(revs, open(p, "w"))
PYEOF
  run "$SCRIPT" Muso-AI/hydra 1643 --limit 1
  [ "$status" -eq 6 ]
  # the newer unlisted text is printed and flagged
  [[ "$output" == *"a newer unlisted prior marker"* ]]
  [[ "$output" == *"PRIOR HEAD UNTRUSTED AUTHOR"* ]]
  # ...and the older trusted text on that prior head is not hidden either
  [[ "$output" == *"finding set 2"* ]]
  [[ "$output" == *"OLDER TRUSTED ON THAT PRIOR HEAD"* ]]
  # --json agrees with the human path: exit 6, not 5
  run "$SCRIPT" Muso-AI/hydra 1643 --limit 1 --json
  [ "$status" -eq 6 ]
  echo "$output" | jq -e '.reason == "untrusted_author_prior_head_only"' >/dev/null
  echo "$output" | jq -e '.prior_head.candidates | length > 0' >/dev/null
}
