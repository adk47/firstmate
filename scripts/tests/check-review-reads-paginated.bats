#!/usr/bin/env bats
# Tests for scripts/check-review-reads-paginated.sh — the CI gate that keeps a
# paginated review surface from being read unpaginated.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
GATE="$HYDRA_REPO/scripts/check-review-reads-paginated.sh"

setup() {
  WORK="$(mktemp -d)"; export WORK
  cd "$WORK" || return 1
  git init -q .
  git config user.email t@t; git config user.name t
  mkdir -p scripts skills-all/x .claude/agents
}
teardown() {
  cd /
  rm -rf "$WORK"
}

# Write a file, stage+commit everything, run the gate.
run_gate_with() { # <path> <content>
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
  git add -A >/dev/null 2>&1
  git commit -qm fixture >/dev/null 2>&1
  run bash "$GATE"
}

@test "clean: an already-paginated read passes" {
  run_gate_with scripts/ok.sh 'gh api --paginate "repos/$R/pulls/$P/reviews?per_page=100" --jq ".[].body"'
  [ "$status" -eq 0 ]
}

@test "clean: a paginated read slurped into local jq passes" {
  run_gate_with scripts/slurp.sh 'gh api --paginate "repos/$R/pulls/$P/reviews?per_page=100" | jq -s "add | [.[]|select(.user.login!=\"$ME\")]|max_by(.id)"'
  [ "$status" -eq 0 ]
}

@test "clean: a paginated element-wise --jq read passes" {
  run_gate_with scripts/elem.sh 'gh api --paginate "repos/$R/pulls/$P/reviews?per_page=100" --jq ".[]|.body"'
  [ "$status" -eq 0 ]
}

@test "fails: a hand-paged loop is not --paginate" {
  # Rounds 4-6 kept trying to prove a hand-paged read was a complete loop and
  # were defeated three times (literal page=1; a variable read once; an
  # unrelated loop elsewhere in the file). This surface now requires --paginate.
  run_gate_with scripts/loop.sh 'page=1
while :; do
  gh api "repos/$r/pulls/$p/reviews?per_page=100&page=$page" >> out.json
  page=$((page + 1))
done'
  [ "$status" -eq 1 ]
  [[ "$output" == *"hand-paged read: require --paginate"* ]]
}

@test "fails: the round 6 false green — unrelated loop and increment in the file" {
  # The gate once printed clean for exactly this fixture: one page-1 read
  # followed by a loop and an increment that touch the counter, but not this
  # call. When the verdict is review 101 the reader still sees page 1 only.
  run_gate_with scripts/unrelated.sh 'page=1
gh api "repos/$r/pulls/$p/reviews?per_page=100&page=$page"
for x in a b; do echo "$x"; done
page=$((page + 1))'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/unrelated.sh:2"* ]]
  [[ "$output" == *"hand-paged read: require --paginate"* ]]
}

@test "fails: a single explicit page read is not pagination" {
  run_gate_with scripts/onepage.sh 'gh api "repos/$r/pulls/$p/reviews?per_page=100&page=1"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/onepage.sh:1"* ]]
  [[ "$output" == *"hand-paged read: require --paginate"* ]]
}

@test "fails: a variable page value read once is not pagination" {
  run_gate_with scripts/varset.sh 'page=1
gh api "repos/$r/pulls/$p/reviews?per_page=100&page=$page"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"hand-paged read: require --paginate"* ]]
}

@test "clean: a deliberate bounded read states its reason" {
  # The only accepted hand-paged form is the one a reviewer can weigh: an
  # explicit reason on the line.
  run_gate_with scripts/bounded.sh 'for page in 1 2 3; do
  gh api "repos/$r/pulls/$p/reviews?per_page=100&page=$page"  # paginated-ok: bounded sample, page 1 is enough
done'
  [ "$status" -eq 0 ]
}

@test "clean: continuation line carrying --paginate passes" {
  run_gate_with scripts/cont.sh 'gh api "repos/$r/pulls/$p/reviews" \
  --paginate --jq ".[].body"'
  [ "$status" -eq 0 ]
}

@test "clean: writes, replies, statuses and single-object reads are not collections" {
  run_gate_with scripts/writes.sh 'gh api "repos/$r/pulls/$p/reviews" --method POST --input x'
  run_gate_with scripts/reply.sh 'gh api "repos/$r/pulls/$p/comments/123/replies" --method POST -f body=hi'
  run_gate_with scripts/single.sh 'gh api "repos/$r/pulls/$p/reviews/$ID" --jq .body'
  run_gate_with scripts/statuses.sh 'gh api "repos/$r/commits/$sha/statuses"'
  [ "$status" -eq 0 ]
}

@test "clean: reviewThreads with pageInfo in the window passes" {
  run_gate_with scripts/gql.sh 'gql='"'"'
query{ repository(owner:$o,name:$r){ pullRequest(number:$p){
  reviewThreads(first:100){
    pageInfo{ hasNextPage }
    nodes{ isResolved }
  } } } }'"'"'
gh api graphql -f query="$gql"'
  [ "$status" -eq 0 ]
}

@test "clean: prose, tables and comments are not commands" {
  run_gate_with skills-all/x/SKILL.md '# a note about `repos/o/r/pulls/1/reviews` in prose'
  run_gate_with skills-all/x/SKILL.md '| the batched review | `qa-gh.sh ... api .../pulls/$PR/reviews` | identity shim |'
  run_gate_with scripts/note.sh '# real gap: pulls/<n>/reviews was read unpaginated on 2026-08-17'
  run_gate_with scripts/intake.py 'self.call("POST", f"/api/issues/{issue_id}/comments", {"body": body})'
  [ "$status" -eq 0 ]
}

@test "fails: a bare paginated-ok marker carries no reason" {
  # The marker is the only escape hatch left, so an empty one must not work:
  # otherwise any one-shot read exempts itself by typing the word.
  run_gate_with scripts/bare.sh 'gh api "repos/$r/pulls/$p/reviews?per_page=100&page=1"  # paginated-ok:'
  [ "$status" -eq 1 ]
  [[ "$output" == *"hand-paged read: require --paginate"* ]]
}

@test "fails: a paginated-ok marker that only closes an html comment" {
  run_gate_with scripts/baremd.sh 'gh api "repos/$r/pulls/$p/reviews?per_page=100&page=1"  <!-- paginated-ok: -->'
  [ "$status" -eq 1 ]
  [[ "$output" == *"hand-paged read: require --paginate"* ]]
}

@test "clean: an explicit paginated-ok marker passes" {
  run_gate_with scripts/marked.sh 'gh api "repos/$r/pulls/$p/reviews" --jq .[0]  # paginated-ok: single page by contract (test fixture)'
  [ "$status" -eq 0 ]
}

@test "fails: the babysit bug — unpaginated reviews read" {
  run_gate_with skills-all/x/SKILL.md 'gh api "repos/$REPO/pulls/$PR/reviews" --jq "[.[]|select(.user.login!=\"$ME\")]|max_by(.id)"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills-all/x/SKILL.md:1"* ]]
  [[ "$output" == *"OLDEST FIRST"* ]]
}

@test "fails: unpaginated issues comments read" {
  run_gate_with scripts/c.sh 'gh api "repos/$r/issues/$p/comments" --jq ".[].body"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/c.sh:1"* ]]
}

@test "fails: reviewThreads without pageInfo" {
  run_gate_with skills-all/x/SKILL.md 'gh api graphql -f query='"'query{ repository(owner:\$o,name:\$r){ pullRequest(number:\$p){ reviewThreads(first:100){ nodes{ id } } } } }'"''
  [ "$status" -eq 1 ]
  [[ "$output" == *"reviewThreads"* ]]
}

@test "fails: --paginate with an aggregating --jq is page-local, not paginated" {
  # gh applies --jq PER PAGE under --paginate (measured 2026-11-03:
  # `?per_page=5 --paginate --jq length` prints 5 5 5 5 5 5 5 5 1). So this
  # returns the newest review OF PAGE 1 — the same stale-read bug this gate
  # exists to catch, wearing the fix's clothes.
  run_gate_with scripts/maxby.sh 'gh api --paginate "repos/$R/pulls/$P/reviews?per_page=100" --jq "[.[]|select(.user.login!=\"$ME\")]|max_by(.id)"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/maxby.sh:1"* ]]
  [[ "$output" == *"page-local --jq aggregate under --paginate"* ]]
  [[ "$output" == *"jq -s"* ]]
}

@test "fails: --paginate with a page-local count (map|length) is not paginated" {
  # A count is the same trap with arithmetic in front of it: `map(select(...)) | length`
  # under --paginate returns ONE COUNT PER PAGE. A PR whose QA body sits on page 2
  # reads as zero findings, and the command looks paginated while doing it.
  run_gate_with scripts/count.sh 'gh api --paginate "repos/$R/pulls/$P/reviews?per_page=100" --jq "map(select(.body != \"\")) | length"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/count.sh:1"* ]]
  [[ "$output" == *"page-local --jq aggregate under --paginate"* ]]
}

@test "fails: --paginate with --jq .[0] takes page 1 only" {
  run_gate_with scripts/first.sh 'gh api --paginate "repos/$R/pulls/$P/reviews?per_page=100" --jq ".[0].body"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"page-local --jq aggregate under --paginate"* ]]
}

@test "clean: the aggregate case is exempt when marked paginated-ok" {
  run_gate_with scripts/markedagg.sh 'gh api --paginate "repos/$R/pulls/$P/reviews?per_page=100" --jq "max_by(.id)"  # paginated-ok: page-local by contract (test fixture)'
  [ "$status" -eq 0 ]
}

@test "fails: an unpaginated read hidden behind a continuation" {
  run_gate_with scripts/multi.sh 'gh api "repos/$r/pulls/$p/reviews" \
  --jq ".[].body"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/multi.sh:1"* ]]
}

@test "fails: --paginate named only in a trailing comment (QA 2026-11-06)" {
  # The gate matched the raw line, so a comment ABOUT pagination exempted an
  # unpaginated read. Reproduced by QA against the previous head: the gate
  # printed clean for exactly this fixture while gh would fetch page 1 only.
  run_gate_with scripts/comment.sh 'gh api "repos/$r/pulls/$p/reviews"  # --paginate is required, but missing'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/comment.sh:1"* ]]
}

@test "fails: --paginate printed in a string is not a flag" {
  run_gate_with scripts/echoed.sh 'echo "repos/$r/pulls/$p/reviews --paginate"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/echoed.sh:1"* ]]
}

@test "fails: --paginate in an UNRELATED substitution on the same line (QA 2026-11-06)" {
  # QA review 14 reproducer. The previous fix kept the whole line whenever it
  # contained any $(, so a substitution that merely PRINTS the flag exempted a
  # later unpaginated read on the same line. A flag only counts for the command
  # segment that actually reads the surface.
  run_gate_with scripts/noise.sh 'noise="$(printf %s --paginate)"; gh api "repos/$r/pulls/$p/reviews"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/noise.sh:1"* ]]
}

@test "fails: --paginate in an env-assignment substitution prefix (QA 2026-11-06 r15)" {
  # QA review 15 reproducer. No `;` here, so the line is ONE command segment: an
  # assignment prefix plus `gh`. Segmenting alone cannot isolate the flag, so a
  # flag only counts at the SAME $( ) depth as the surface it paginates.
  run_gate_with scripts/prefix.sh 'noise="$(printf %s --paginate)" gh api "repos/$r/pulls/$p/reviews"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/prefix.sh:1"* ]]
}

@test "fails: --paginate generated by a substitution argument does not count" {
  run_gate_with scripts/argsubst.sh 'gh api "repos/$r/pulls/$p/reviews" $(printf --paginate)'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/argsubst.sh:1"* ]]
}

@test "fails: an opt-out does not cover two reads inside a quoted bash -c (QA 2026-11-06 r23)" {
  # QA review 23 reproducer. A quoted payload is ONE segment but TWO
  # executable reads, so the count is over surface occurrences, not segments.
  run_gate_with scripts/bashc.sh 'bash -c '\''gh api "repos/$r/pulls/$p/reviews"; gh api "repos/$r/pulls/$p/reviews"'\'' # paginated-ok: first read deliberately bounded'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/bashc.sh:1"* ]]
}

@test "clean: an opt-out covers a single read inside a quoted bash -c" {
  run_gate_with scripts/bashc1.sh 'bash -c '\''gh api "repos/$r/pulls/$p/reviews"'\'' # paginated-ok: single page by contract'
  [ "$status" -eq 0 ]
}

@test "fails: an opt-out does not cover a second read on the same line (QA 2026-11-06 r22)" {
  # QA review 22 reproducer. A trailing comment cannot say which command it
  # bounds, so an opted-out line carrying two review reads is rejected.
  run_gate_with scripts/twoopt.sh 'gh api "repos/$r/pulls/$p/reviews"; gh api --paginate "repos/$r/pulls/$p/reviews" # paginated-ok: second read intentionally bounded'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/twoopt.sh:1"* ]]
}

@test "fails: an opt-out does not cover a second read in the other order" {
  run_gate_with scripts/twoopt2.sh 'gh api --paginate "repos/$r/pulls/$p/reviews"; gh api "repos/$r/pulls/$p/reviews" # paginated-ok: second read intentionally bounded'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/twoopt2.sh:1"* ]]
}

@test "fails: an opt-out does not cover two unpaginated reads" {
  run_gate_with scripts/twoopt3.sh 'gh api "repos/$r/pulls/$p/reviews"; gh api "repos/$r/pulls/$p/reviews" # paginated-ok: both bounded'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/twoopt3.sh:1"* ]]
}

@test "clean: an opt-out still covers a single read with trailing shell syntax" {
  # The real hand-paged loop in scripts/qa-approval-retry.sh ends in
  # `|| { ...; break; }`, which is a second SEGMENT but not a second read.
  run_gate_with scripts/oneopt.sh 'pg="$(gh api "repos/$r/pulls/$p/reviews?per_page=100&page=$page")" || { x=1; break; }  # paginated-ok: complete-or-loud hand-paged loop'
  [ "$status" -eq 0 ]
}

@test "fails: one paginated alias does not cover a second reviewThreads (QA 2026-11-06 r21)" {
  # QA review 21 reproducer. Every connection needs its own proof.
  run_gate_with scripts/alias.sh 'gh api graphql -f query="x{a:reviewThreads(first:100){pageInfo{hasNextPage}} b:reviewThreads(first:100){nodes{id}}}"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/alias.sh:1"* ]]
}

@test "fails: an unpaginated alias before a paginated one is still caught" {
  run_gate_with scripts/alias2.sh 'gh api graphql -f query="x{a:reviewThreads(first:100){nodes{id}} b:reviewThreads(first:100){pageInfo{hasNextPage}}}"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/alias2.sh:1"* ]]
}

@test "passes: both aliases carry their own pageInfo" {
  run_gate_with scripts/alias3.sh 'gh api graphql -f query="x{a:reviewThreads(first:100){pageInfo{hasNextPage}} b:reviewThreads(first:100){pageInfo{hasNextPage}}}"'
  [ "$status" -eq 0 ]
}

@test "passes: a jq path reference to reviewThreads is not a second connection" {
  # The real skills read the connection once and then address it by path in
  # --jq; that path is a reference to the result, not another unpaginated read.
  run_gate_with scripts/jqpath.sh 'gh api graphql -f query="x{reviewThreads(first:100){pageInfo{hasNextPage} nodes{id}}}" --jq ".data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage"'
  [ "$status" -eq 0 ]
}

@test "fails: a PRINTED paginated-ok marker is not an opt-out (QA 2026-11-06 r21)" {
  # QA review 21 reproducer. The marker must be a real comment, not data.
  run_gate_with scripts/printed.sh 'printf "paginated-ok: bypass"; gh api "repos/$r/pulls/$p/reviews"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/printed.sh:1"* ]]
}

@test "fails: an echoed paginated-ok marker is not an opt-out" {
  run_gate_with scripts/echoed.sh 'echo "paginated-ok: bypass" && gh api "repos/$r/pulls/$p/reviews"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/echoed.sh:1"* ]]
}

@test "clean: an html-comment paginated-ok marker with a reason passes in markdown" {
  run_gate_with skills-all/marked/SKILL.md 'gh api "repos/$r/pulls/$p/reviews"  <!-- paginated-ok: single page by contract (test fixture) -->'
  [ "$status" -eq 0 ]
}

@test "fails: an html-comment marker is not a shell comment" {
  # In a shell script `<!-- ... -->` is not a comment, so it cannot opt out.
  run_gate_with scripts/htmlmarker.sh 'gh api "repos/$r/pulls/$p/reviews"  <!-- paginated-ok: single page by contract -->'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/htmlmarker.sh:1"* ]]
}

@test "fails: a sibling connection's pageInfo does not paginate reviewThreads (QA 2026-11-06 r20)" {
  # QA review 20 reproducer. Both connections are in ONE query, so the proof
  # must be inside the reviewThreads selection set, not merely in the query.
  run_gate_with scripts/sibling.sh 'gh api graphql -f query="x{reviewThreads(first:100){nodes{id}} reviews(first:1){pageInfo{hasNextPage}}}"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/sibling.sh:1"* ]]
}

@test "fails: a sibling connection's pageInfo before reviewThreads does not count" {
  run_gate_with scripts/sibling2.sh 'gh api graphql -f query="x{reviews(first:1){pageInfo{hasNextPage}} reviewThreads(first:100){nodes{id}}}"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/sibling2.sh:1"* ]]
}

@test "fails: a nested comments pageInfo does not paginate reviewThreads" {
  # The real queries carry comments(last:100){pageInfo{hasPreviousPage}} inside
  # reviewThreads; that is a different connection and proves nothing.
  run_gate_with scripts/nested.sh 'gh api graphql -f query="x{reviewThreads(first:100){nodes{comments(last:100){pageInfo{hasPreviousPage}}}}}"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/nested.sh:1"* ]]
}

@test "passes: pageInfo at the reviewThreads level with a nested comments pageInfo" {
  run_gate_with scripts/nested2.sh 'gh api graphql -f query="x{reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved comments(last:100){pageInfo{hasPreviousPage}}}}}"'
  [ "$status" -eq 0 ]
}

@test "fails: a query on the NEXT line does not supply the pageInfo proof (QA 2026-11-06 r19)" {
  # QA review 19 reproducer. The proof window used to be a blind four-line
  # lookahead, so an unrelated query on the following line exempted this one.
  run_gate_with scripts/twolines.sh 'gh api graphql -f query="x{reviewThreads(first:100){nodes{id}}}"
gh api graphql -f query="x{reviews(first:1){pageInfo{hasNextPage}}}"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/twolines.sh:1"* ]]
}

@test "passes: a heredoc query carrying pageInfo is exempt" {
  local body="read -r -d '' gql <<'GQL' || true
query{ reviewThreads(first:100){
  pageInfo{ hasNextPage }
} }
GQL
gh api graphql -f query=\"\$gql\""
  run_gate_with scripts/hd.sh "$body"
  [ "$status" -eq 0 ]
}

@test "fails: a heredoc query without pageInfo is not exempt" {
  local body="read -r -d '' gql <<'GQL' || true
query{ reviewThreads(first:100){
  nodes{ id }
} }
GQL
gh api graphql -f query=\"\$gql\""
  run_gate_with scripts/hd2.sh "$body"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/hd2.sh:2"* ]]
}

@test "passes: a multi-line quoted query carrying pageInfo is exempt" {
  local body="gql='query{ reviewThreads(first:100){
  pageInfo{ hasNextPage }
} }'
gh api graphql -f query=\"\$gql\""
  run_gate_with scripts/ml.sh "$body"
  [ "$status" -eq 0 ]
}

@test "fails: a multi-line quoted query without pageInfo is not exempt" {
  local body="gql='query{ reviewThreads(first:100){
  nodes{ id }
} }'
gh api graphql -f query=\"\$gql\""
  run_gate_with scripts/ml2.sh "$body"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/ml2.sh:1"* ]]
}

@test "fails: a second graphql query's pageInfo does not exempt the first (QA 2026-11-06 r18)" {
  # QA review 18 reproducer. The pageInfo proof must come from the SAME
  # reviewThreads command, not from anywhere on the line.
  run_gate_with scripts/gql2.sh 'gh api graphql -f query="query{repository(owner:x,name:y){pullRequest(number:1){reviewThreads(first:100){nodes{id}}}}}"; gh api graphql -f query="query{repository(owner:x,name:y){pullRequest(number:1){reviews(first:1){pageInfo{hasNextPage}}}}}"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/gql2.sh:1"* ]]
}

@test "fails: a reviewThreads query without pageInfo is not exempt by a sibling one" {
  run_gate_with scripts/gql3.sh 'gh api graphql -f query="x{reviewThreads(first:100){nodes{id}}}"; gh api graphql -f query="x{reviewThreads(first:100){pageInfo{hasNextPage}}}"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/gql3.sh:1"* ]]
}

@test "fails: a graphql reviewThreads query on the same line does not exempt a REST read" {
  # Same family as review 17: the reviewThreads exemption was line-level too.
  run_gate_with scripts/gqlmix.sh 'gh api "repos/$r/pulls/$p/reviews"; gh api graphql -f query="x{reviewThreads(first:100){pageInfo{hasNextPage}}}"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/gqlmix.sh:1"* ]]
}

@test "passes: a graphql reviewThreads query with pageInfo is exempt" {
  run_gate_with scripts/gql.sh 'gh api graphql -f query="x{reviewThreads(first:100){pageInfo{hasNextPage}}}"'
  [ "$status" -eq 0 ]
}

@test "fails: a POST on the same line does not exempt an unpaginated GET (QA 2026-11-06 r17)" {
  # QA review 17 reproducer. The write/single-object exemption used to run on
  # the whole logical line, before segmentation, so a write anywhere on the line
  # suppressed an unpaginated collection read.
  run_gate_with scripts/mixed.sh 'gh api "repos/$r/pulls/$p/reviews"; gh api "repos/$r/pulls/$p/reviews" --method POST --input payload'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/mixed.sh:1"* ]]
}

@test "fails: a single-object read on the same line does not exempt an unpaginated GET" {
  run_gate_with scripts/mixed2.sh 'gh api "repos/$r/pulls/$p/reviews"; gh api "repos/$r/pulls/$p/reviews/123"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/mixed2.sh:1"* ]]
}

@test "fails: a POST before an unpaginated GET on the same line does not exempt it" {
  run_gate_with scripts/mixed3.sh 'gh api "repos/$r/pulls/$p/reviews" --method POST; gh api "repos/$r/pulls/$p/reviews"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/mixed3.sh:1"* ]]
}

@test "passes: a write and a single-object read on one line are both exempt" {
  run_gate_with scripts/mixed4.sh 'gh api "repos/$r/pulls/$p/reviews" --method POST --input payload; gh api "repos/$r/pulls/$p/reviews/9"'
  [ "$status" -eq 0 ]
}

@test "passes: a quoted single-object review read is exempt" {
  run_gate_with scripts/single.sh 'gh api "repos/$REPO/pulls/$PR/reviews/<REVIEW_ID>" --jq ".body"'
  [ "$status" -eq 0 ]
}

@test "fails: --paginate in a BACKTICK substitution does not count" {
  # Backticks are command substitution too, so the flag belongs to printf.
  run_gate_with scripts/bt.sh 'gh api "repos/$r/pulls/$p/reviews" `printf --paginate`'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/bt.sh:1"* ]]
}

@test "fails: --paginate in a backtick substitution nested in a command substitution does not count" {
  run_gate_with scripts/bt2.sh 'raw="$(gh api "repos/$r/pulls/$p/reviews" `printf --paginate`)"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/bt2.sh:1"* ]]
}

@test "passes: escaped backticks in a Slack string are literal, not substitutions" {
  run_gate_with scripts/bt3.sh 'slack_notify_critical "see \`maxEntries\` and \`maxDiskBytes\`"'
  [ "$status" -eq 0 ]
}

@test "fails: --paginate in a sibling command INSIDE a substitution (QA 2026-11-06 r16)" {
  # QA review 16 reproducer. A `;` inside a $( ) separates two commands just as
  # surely as one at the top level, so segments() splits at every depth.
  run_gate_with scripts/insubst.sh 'raw="$(printf %s --paginate; gh api "repos/$r/pulls/$p/reviews")"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/insubst.sh:1"* ]]
}

@test "fails: --paginate after the read inside a substitution does not count" {
  run_gate_with scripts/aftersubst.sh 'raw="$(gh api "repos/$r/pulls/$p/reviews"; printf --paginate)"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/aftersubst.sh:1"* ]]
}

@test "fails: --paginate in a NESTED substitution does not count" {
  # Bucketing "depth 0" vs "depth > 0" would let this through: the surface is at
  # depth 1 and the flag at depth 2, but both land in the same bucket. Each depth
  # is judged on its own.
  run_gate_with scripts/nested.sh 'raw="$(gh api "repos/$r/pulls/$p/reviews" $(printf --paginate))"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/nested.sh:1"* ]]
}

@test "fails: --paginate in a sibling command does not exempt the read" {
  run_gate_with scripts/sibling.sh 'x=$(true); gh api "repos/$r/pulls/$p/reviews"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/sibling.sh:1"* ]]
}

@test "clean: --paginate in a sibling command still counts for its own read" {
  run_gate_with scripts/siblingok.sh 'x=$(true); gh api --paginate "repos/$r/pulls/$p/reviews"'
  [ "$status" -eq 0 ]
}

@test "clean: --paginate inside a quoted command substitution still counts" {
  # The commonest real form: the whole command sits inside double quotes and is
  # executed. Dropping quoted text wholesale would fail every one of these.
  run_gate_with scripts/subst.sh 'raw="$(gh api --paginate "repos/$r/pulls/$p/reviews?per_page=100" 2>/dev/null)"'
  [ "$status" -eq 0 ]
}

@test "clean: docs/ is out of scope (runbooks quote past defects)" {
  mkdir -p docs
  run_gate_with docs/x.md 'gh api "repos/$r/pulls/$p/reviews" --jq .[0]'
  [ "$status" -eq 0 ]
}

@test "the real repo is clean" {
  cd "$HYDRA_REPO" || return 1
  run bash "$GATE" --quiet
  [ "$status" -eq 0 ]
}
