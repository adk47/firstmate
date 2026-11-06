#!/usr/bin/env bash
set -euo pipefail

# check-review-reads-paginated.sh — fail when an agent-facing or scripted read of
# a PAGINATED review surface forgets `--paginate`.
#
# WHY (2026-11-03): `GET /repos/:o/:r/pulls/:n/reviews` returns 30 reviews per
# page, OLDEST FIRST, and an unpaginated read returns page 1 only. Three lanes
# concluded the QA bot had published a NO-GO with no finding text, when every one
# of those verdicts was fully written in a review body they could not see:
#
#   hydra#1545  NO-GO 06:37Z  review 37 of 55  (page 2)
#   hydra#1636  NO-GO 12:12Z  review 34 of 40  (page 2)
#   hydra#1643  NO-GO 15:42Z  review 39 of 39  (page 2)
#
# The readers were prose instructions in skills (`gh api .../reviews --jq
# 'max_by(.id)'` -> the newest review OF THE OLDEST 30) and hand-rolled loops.
# Prose alone is not enforcement: this gate is. Same shape as
# scripts/check-no-tmp-scratch.sh — it fails CI on the pattern, not on the
# incident ever recurring.
#
# Scope: agent-facing instruction surfaces (skills-all/, workspaces/*/AGENTS.md,
# .claude/agents/) and executed/executable scripts (scripts/**, minus tests).
# docs/ is deliberately out of scope: runbooks legitimately quote unpaginated
# reads as evidence of a past defect, and nothing executes them.
#
# A line is EXEMPT when it is
#   * a write or a single-object read (`--method POST`, `/replies`, `/statuses`,
#     `.../reviews/<id>`), which are not collections, or
#   * already paginated by `--paginate` IN THE COMMAND THAT READS IT, at the
#     same `$( )` depth as the surface. A `--paginate` in a trailing comment, in
#     a printed string, in a different command on the same line, or in an
#     unrelated command substitution is not a flag for this read and does not
#     exempt it (QA 2026-11-06) — or a GraphQL connection that reads
#     `pageInfo`/`hasNextPage`, or
#   * marked on its own line with `paginated-ok: <reason>` (or the HTML comment
#     `<!-- paginated-ok: reason -->` in markdown).
#
# A hand-rolled `per_page=` + `page=` loop is NOT exempt, even when it is
# correct: it is an OFFENDER and fails CI. Three static heuristics to certify
# one were each defeated by a counterexample (a literal `page=1`; a variable
# read once; an unrelated loop and increment elsewhere in the same file), so
# pattern matching cannot prove the loop consumes every page, and a false green
# here is the silent stale verdict this gate exists to prevent. A loop that is
# deliberately complete-or-loud states its reason on the read line with
# `paginated-ok:` instead (see scripts/qa-approval-retry.sh for the one
# measured instance, which is hand-paged on purpose to charge each request to
# the rest_calls budget — hydra#1119).
#
# ...UNLESS the paginated read also aggregates in `--jq`. gh applies `--jq` PER
# PAGE under `--paginate` (measured 2026-11-03: `?per_page=5 --paginate --jq
# length` prints 5,5,5,5,5,5,5,5,1), so `--paginate ... --jq 'max_by(.id)'`
# returns one winner PER PAGE and a caller taking the first result reads page 1
# — the same stale-read bug this gate exists to catch, wearing the fix's
# clothes. Such a read is an OFFENDER: slurp the unfiltered pages and aggregate
# locally (`... --paginate | jq -s 'add | max_by(.id)'`), or mark it
# `paginated-ok: <reason>` if page-local aggregation is genuinely intended.
#
# Usage: check-review-reads-paginated.sh [--quiet]
# Exit: 0 clean, 1 offenders found, 2 usage.

QUIET=0
case "${1:-}" in
  "") ;;
  --quiet) QUIET=1 ;;
  *) echo "usage: $0 [--quiet]" >&2; exit 2 ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "check-review-reads-paginated: not in a git repo" >&2; exit 2; }

cd "$repo_root"

files="$(
  git ls-files \
    ':(glob)skills-all/**' \
    ':(glob)workspaces/*/AGENTS.md' \
    ':(glob)workspaces/*/CLAUDE.md' \
    ':(glob).claude/agents/**' \
    ':(glob)scripts/**' \
    ':(exclude,glob)scripts/tests/**' \
    ':(exclude,glob)scripts/check-review-reads-paginated.sh' \
    2>/dev/null
)"

[ -n "$files" ] || { echo "check-review-reads-paginated: no files in scope" >&2; exit 0; }

# Continuation lines (a gh call split with a trailing backslash) are joined into
# one logical line first: `--paginate` on the next line still paginates.
report="$(
  printf '%s\n' "$files" | while IFS= read -r f; do
    [ -f "$f" ] || continue
    LC_ALL=C awk -v f="$f" '
      # A flag only counts when it is EXECUTED, and only for the command that
      # actually reads the surface. Two false greens proved that the raw line is
      # the wrong unit (QA 2026-11-06):
      #   gh api ".../reviews"  # --paginate is required, but missing
      #   noise="$(printf %s --paginate)"; gh api ".../reviews"
      # The first names the flag in a COMMENT; the second names it in a DIFFERENT
      # command on the same line. So a logical line is split into top-level
      # command segments (quote- and $( )-aware) and a segment only counts as
      # paginated when IT contains both the surface and an executable
      # --paginate. Within a segment, quoted literals are data (echo
      # "--paginate") and are dropped, EXCEPT inside a $( ) command
      # substitution, which is executed — that is the commonest real form,
      # raw="$(gh api --paginate ...)".
      # NOTE: no literal single quote may appear in this program — it would close
      # the shell string that delimits it — so the quote character is SQ.
      BEGIN {
        SQ = sprintf("%c", 39)
        DQ = sprintf("%c", 34)
        SURF = "repos/[^ ]*/(pulls|issues)/[^ ]*/(reviews|comments)|reviewThreads[ ]*\\([ ]*first:"
      }
      # Does the reviewThreads CONNECTION carry its own pageInfo? The proof has
      # to live inside that connection selection set: a sibling
      # reviews(first:1){pageInfo{hasNextPage}} in the same query says nothing
      # about whether reviewThreads was paged (QA 2026-11-06, review 20).
      # Brace-matched from the first { after the connection name.
      # pageInfo must sit at the CONNECTION level (depth 1 of its selection
      # set) and carry hasNextPage: a nested comments(last:100){pageInfo{
      # hasPreviousPage}} says nothing about whether the threads were paged.
      # EVERY reviewThreads connection in the unit must carry its own proof: a
      # query with `a:reviewThreads(first:100){pageInfo{hasNextPage}}` and
      # `b:reviewThreads(first:100){nodes{id}}` pages only `a`, and `b` still
      # truncates at 100 (QA 2026-11-06, review 21).
      function rt_proof(s,   p, from, rest, j, ch) {
        from = 1
        while (1) {
          rest = substr(s, from)
          p = index(rest, "reviewThreads")
          if (!p) return 1
          p = from + p - 1
          # Only a CONNECTION counts. A jq path such as
          # .data.repository.pullRequest.reviewThreads.pageInfo is a reference
          # to the result, not a second unpaginated read, so it is skipped.
          j = p + 13
          while (j <= length(s) && substr(s, j, 1) ~ /[ \t]/) j++
          ch = substr(s, j, 1)
          if ((ch == "(" || ch == "{") && !rt_one(s, p)) return 0
          from = p + 13
        }
      }
      function rt_one(s, p,   i, j, c, d, pd, ch, e, pe) {
        e = 0
        for (i = p; i <= length(s); i++) if (substr(s, i, 1) == "{") { e = i; break }
        if (!e) return 0
        d = 0
        for (i = e; i <= length(s); i++) {
          ch = substr(s, i, 1)
          if (ch == "{") { d++; continue }
          if (ch == "}") { d--; if (d == 0) return 0; continue }
          if (d != 1 || substr(s, i, 8) != "pageInfo") continue
          pe = 0
          for (j = i + 8; j <= length(s); j++) if (substr(s, j, 1) == "{") { pe = j; break }
          if (!pe) return 0
          pd = 0
          for (j = pe; j <= length(s); j++) {
            ch = substr(s, j, 1)
            if (ch == "{") pd++
            else if (ch == "}") { pd--; if (pd == 0) break }
          }
          if (pd != 0) return 0
          return (substr(s, pe, j - pe + 1) ~ /hasNextPage/)
        }
        return 0
      }
      # The text of a real shell comment on this line, or "". A marker printed
      # by a command is DATA, not an opt-out: `printf "paginated-ok: bypass";
      # gh api "repos/..."` must not exempt the read beside it (QA 2026-11-06,
      # review 21).
      function comment_text(l,   i, c, q, n) {
        q = ""; n = length(l)
        for (i = 1; i <= n; i++) {
          c = substr(l, i, 1)
          if (q != "") { if (c == q) q = ""; continue }
          if (c == "\"" || c == SQ) { q = c; continue }
          if (c == "#" && (i == 1 || substr(l, i - 1, 1) ~ /[ \t]/)) return substr(l, i + 1)
        }
        return ""
      }
      # Markdown files opt out with an HTML comment instead of a shell one.
      function html_comment(l,   out, i, c, q, n) {
        out = ""; q = ""; n = length(l)
        for (i = 1; i <= n; i++) {
          c = substr(l, i, 1)
          if (q != "") { if (c == q) q = ""; continue }
          if (c == "\"" || c == SQ) { q = c; continue }
          if (substr(l, i, 4) != "<!--") continue
          i += 4
          while (i <= n && substr(l, i, 3) != "-->") { out = out substr(l, i, 1); i++ }
          i += 2
          out = out " "
        }
        return out
      }
      function strip_comment(l,   out, i, c, q, n) {
        out = ""; q = ""; n = length(l)
        for (i = 1; i <= n; i++) {
          c = substr(l, i, 1)
          if (q != "") { out = out c; if (c == q) q = ""; continue }
          if (c == "\"" || c == SQ) { q = c; out = out c; continue }
          if (c == "#" && (i == 1 || substr(l, i - 1, 1) ~ /[ \t]/)) break
          out = out c
        }
        return out
      }
      # Split a logical line into command segments, newline-joined, at EVERY
      # $( ) depth: a `;` inside a substitution separates two commands just as
      # surely as one at the top level, and pairing a flag from the first with a
      # surface from the second is the same false green one level down
      # (QA 2026-11-06, review 16). $( ) depth is tracked even inside quotes,
      # because a substitution inside a double-quoted string is still executed.
      # Quote state is SUSPENDED inside $( ): in "$(...)" the outer quote does
      # not govern the body, so a quote inside the body must not be read as the
      # close of the outer one. QS is a depth-indexed stack of suspended quotes.
      function segments(l,   out, i, c, q, d, n) {
        out = ""; q = ""; d = 0; n = length(l)
        for (i = 1; i <= n; i++) {
          c = substr(l, i, 1)
          if (c == "$" && substr(l, i + 1, 1) == "(") { QS[d] = q; q = ""; d++; out = out "$("; i++; continue }
          if (c == ")" && d > 0) { d--; q = QS[d]; out = out c; continue }
          if (q != "") { out = out c; if (c == q) q = ""; continue }
          if (c == "\"" || c == SQ) { q = c; out = out c; continue }
          if (c == ";" || c == "|" || c == "&") { out = out "\n"; continue }
          out = out c
        }
        return out
      }
      # Deepest $( ) nesting on a segment, so the depth loop below is bounded by
      # the line instead of by a magic constant.
      # Backtick command substitution is a substitution too: `gh api "repos/..."
      # `printf --paginate`` runs printf, not a paginated read. An unescaped
      # backtick outside single quotes toggles one extra level of depth, so the
      # flag lands at a different depth from the surface. Escaped backticks
      # (\`) are literal and are what our Slack strings are full of.
      function max_depth(l,   i, c, d, bt, m, n) {
        d = 0; bt = 0; m = 0; n = length(l)
        for (i = 1; i <= n; i++) {
          c = substr(l, i, 1)
          if (c == "$" && substr(l, i + 1, 1) == "(") { d++; i++ }
          else if (c == ")" && d > 0) d--
          else if (c == "`" && substr(l, i - 1, 1) != "\\") bt = 1 - bt
          if (d + bt > m) m = d + bt
        }
        return m
      }
      # Text of ONE segment at EXACTLY depth D. keepq=1 keeps quoted literals so
      # the SURFACE can be matched (the URL is usually quoted); keepq=0 drops them
      # as data so a flag merely PRINTED in a string cannot count.
      #
      # Depth is what makes a flag belong to the right command. A flag and a
      # surface only pair up at the SAME depth:
      #   noise="$(printf %s --paginate)" gh api "repos/..."   flag d=1, surface d=0
      #   raw="$(gh api --paginate "repos/...")"               flag d=1, surface d=1
      #   raw="$(gh api "repos/..." $(printf --paginate))"     flag d=2, surface d=1
      # The first and third are unpaginated reads with a flag in an unrelated
      # substitution (QA 2026-11-06, review 15); the second is the commonest real
      # form. Bucketing "depth 0" vs "depth > 0" would let the third through, so
      # each depth is judged on its own.
      function depth_text(l, D, keepq,   out, i, c, q, d, bt, n, emit) {
        out = ""; q = ""; d = 0; bt = 0; n = length(l)
        for (i = 1; i <= n; i++) {
          c = substr(l, i, 1)
          if (c == "$" && substr(l, i + 1, 1) == "(") {
            if (d + bt == D) out = out "$("
            QS[d] = q; q = ""; d++
            i++
            continue
          }
          if (c == ")" && d > 0) {
            if (d + bt == D + 1) out = out c
            d--; q = QS[d]
            continue
          }
          if (c == "`" && q != SQ && substr(l, i - 1, 1) != "\\") { bt = 1 - bt; continue }
          emit = (d + bt == D)
          if (q != "") {
            if (c == q) { q = ""; if (keepq && emit) out = out c }
            else if (keepq && emit) out = out c
            continue
          }
          if (c == "\"" || c == SQ) {
            q = c
            if (keepq && emit) out = out c
            continue
          }
          if (emit) out = out c
        }
        return out
      }
      # Join backslash continuations first, then judge each logical line WITH a
      # lookahead window: a GraphQL connection is routinely split across lines,
      # and `pageInfo{ hasNextPage }` on the next line is still pagination.
      { phys[NR] = $0; if (index($0, "reviewThreads")) has_rt = 1 }
      END {
        # The heredoc and multi-line-quote pre-passes exist ONLY to bind a
        # GraphQL pageInfo proof to the query that carries it, so they are
        # skipped entirely for the great majority of files, which never mention
        # reviewThreads. That keeps the gate runtime where it was.
        if (!has_rt) { HDEND[0] = 0; QEND[0] = 0 }
        # Heredoc ranges, so a GraphQL query written as a heredoc body is judged
        # as ONE unit. Without this the proof window had to be a blind four-line
        # lookahead, which let a query on the NEXT line supply the proof for this
        # one (QA 2026-11-06, review 19). HDEND[i] = last physical line of the
        # heredoc containing line i, or 0 when line i is not in a heredoc.
        hd = 0
        for (i = 1; has_rt && i <= NR; i++) {
          if (hd) {
            HDEND[i] = hdend
            if (phys[i] == hdtag) hd = 0
            continue
          }
          p = index(phys[i], "<<")
          if (!p) continue
          rest = substr(phys[i], p + 2)
          sub(/^-/, "", rest)
          sub(/^[ \t]+/, "", rest)
          c0 = substr(rest, 1, 1)
          if (c0 == "\"" || c0 == SQ) rest = substr(rest, 2)
          if (!match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) continue
          t = substr(rest, 1, RLENGTH)
          hdend = 0
          for (j = i + 1; j <= NR; j++) if (phys[j] == t) { hdend = j; break }
          if (hdend) { hd = 1; hdtag = t; HDEND[i] = hdend }
        }
        # Multi-line quoted strings: a GraphQL query is just as often written as
        # a single-quoted string spanning several physical lines as it is as a
        # heredoc. QEND[i] = the line that closes the quote left open on line i.
        # Heredoc bodies are skipped: their contents are data, not shell quoting.
        inq = ""
        for (i = 1; has_rt && i <= NR; i++) {
          if (HDEND[i]) { QSTATE[i] = ""; continue }
          s = phys[i]
          # Fast path: a line with no comment marker and an even number of each
          # quote character cannot change the quote state. gsub counts at C
          # speed, which keeps the whole-file scan off the per-character loop
          # for the overwhelming majority of lines.
          if (inq == "" && index(s, "#") == 0) {
            if (index(s, SQ) == 0 && index(s, "\"") == 0) { QSTATE[i] = ""; continue }
            t = s; a = gsub(SQ, "", t)
            t = s; b = gsub(DQ, "", t)
            if (a % 2 == 0 && b % 2 == 0) { QSTATE[i] = ""; continue }
          }
          for (c = 1; c <= length(s); c++) {
            ch = substr(s, c, 1)
            if (inq == "") {
              if (ch == SQ || ch == "\"") inq = ch
              else if (ch == "#" && (c == 1 || substr(s, c - 1, 1) ~ /[ \t]/)) break
            } else if (ch == "\\" && inq == "\"") {
              c++
            } else if (ch == inq) {
              inq = ""
            }
          }
          QSTATE[i] = inq
        }
        nextq = 0
        for (i = has_rt ? NR : 0; i >= 1; i--) {
          if (QSTATE[i] == "") nextq = i
          else QEND[i] = nextq
        }
        n = 0
        for (i = 1; i <= NR; i++) {
          line = phys[i]
          startline = i
          while (line ~ /\\[ ]*$/ && i < NR) { line = line " " phys[++i] }
          n++; L[n] = line; S[n] = startline
        }
        # UEND[k] = last logical line of the unit that starts at logical line k:
        # the heredoc body or the multi-line quoted string when k is inside one,
        # otherwise k itself. This is what binds a GraphQL pageInfo proof to the
        # query that carries it, without a blind lookahead (QA 2026-11-06, r19).
        for (k = 1; k <= n; k++) {
          e = S[k]
          if (HDEND[S[k]]) e = HDEND[S[k]]
          else if (QEND[S[k]]) e = QEND[S[k]]
          UEND[k] = k
          for (m = k; m <= n && S[m] <= e; m++) UEND[k] = m
        }
        for (k = 1; k <= n; k++) {
          l = L[k]
          nc = strip_comment(l)      # executable text, comments gone
          # --- what counts as a collection READ of a paginated review surface ---
          if (nc !~ SURF) continue
          # GitHub REST paths all carry repos/; other APIs (paperclip /api/issues)
          # merely look similar. Markdown prose/table rows are not commands.
          if (nc !~ /repos\// && nc !~ /reviewThreads/) continue
          if (l ~ /^[ ]*[|>]/) continue
          # Comment lines in shell/python/queries are explanations, not calls.
          if (l ~ /^[ ]*(#|\/\/)/) continue
          # Writes and single-object reads are not collections. This is judged
          # per command below, on the segment and depth that actually carries the
          # surface: a POST elsewhere on the line must not exempt an unpaginated
          # GET (QA 2026-11-06, review 17).
          # reviewThreads: a nested comments(first:N) inside it is a single-object
          # read per thread; the connection itself needs pageInfo. Like the write
          # exemption, this is applied to the SEGMENT that carries reviewThreads,
          # never to the whole line: a graphql query on the same line must not
          # exempt a REST reviews read beside it, and a SECOND query that checks
          # pageInfo must not exempt the first one that does not (QA 2026-11-06,
          # review 18). The proof is read from that segment, plus the rest of the
          # heredoc body when the segment is inside one — never from a blind
          # lookahead, which let a query on the next line supply the proof for
          # this one (QA 2026-11-06, review 19). A query that continues onto the
          # next lines with a backslash is already one logical line here.
          # A deliberate exception always wins, and its reason is the review.
          # The marker is the one reviewable escape hatch, so it must actually
          # carry a reason: a bare `paginated-ok:` (or `paginated-ok: -->`)
          # says nothing a reviewer can weigh, so it does not exempt.
          # An HTML comment is a comment only in Markdown. In a shell script
          # `<!-- ... -->` is not a comment at all, so accepting it there would
          # let a read opt itself out with text the shell never treats as one.
          cm = comment_text(l)
          if (FILENAME ~ /[.]md$/) cm = cm " " html_comment(l)
          marked = (cm ~ /paginated-ok:[[:space:]]*[^[:space:]>-]/)
          # --paginate + an aggregating --jq is a page-local answer: the filter
          # runs once per page, so the newest review OF PAGE 1 wins and the
          # caller never sees page 2. Reject it instead of exempting the line.
          #
          # length belongs in this list: a map(select(...)) | length filter
          # counts PAGE 1 only, so a PR whose QA body sits on page 2 reads as zero
          # findings while the command looks paginated. That is the original bug
          # with a count in front of it. A genuinely per-element length read
          # (for example .[].body | length) streams and is safe, so a real one
          # exempts itself with paginated-ok:.
          # NOTE: never put a single quote in this awk program — it would close
          # the shell string that delimits the whole script.
          # Which command on this line actually paginates the read? A flag only
          # counts when it sits at the SAME $( ) depth as the surface it is
          # supposed to paginate, so a flag in a comment, in a sibling command,
          # or in an unrelated substitution does not exempt the read.
          nseg = split(segments(nc), SEG, "\n")
          # A trailing comment cannot say WHICH command it bounds, so an opt-out
          # is honoured only when the line carries exactly ONE review read.
          # Otherwise `gh api "repos/..."; gh api --paginate "repos/..." #
          # paginated-ok: ...` would exempt the first, unpaginated read
          # (QA 2026-11-06, review 22). Two reads on one opted-out line are
          # rejected outright rather than guessed at.
          # Count surface OCCURRENCES in the raw line, not segments: a quoted
          # bash -c payload holding two gh api reads is ONE segment but TWO
          # executable reads, and both fetch only page 1 (QA 2026-11-06, r23).
          if (marked) {
            nreads = 0; t = nc
            while (match(t, SURF)) { nreads++; t = substr(t, RSTART + RLENGTH) }
            if (nreads <= 1) continue
            marked = 0
          }
          paginated = 0; jqagg = 0; jqpart = ""; offender = 0; exempt = 0
          for (s = 1; s <= nseg; s++) {
            maxd = max_depth(SEG[s])
            for (D = 0; D <= maxd; D++) {
              r = depth_text(SEG[s], D, 1); e = depth_text(SEG[s], D, 0)
              if (r !~ SURF) continue
              if (r ~ /reviewThreads/) {
                proof = r
                for (w = k + 1; w <= UEND[k]; w++) proof = proof " " strip_comment(L[w])
                if (rt_proof(proof)) { exempt = 1; continue }
              }
              # A write or a single-object read is not a collection read, but
              # only the command that CARRIES the surface can say so.
              if (e ~ /--method[ ]+(POST|PATCH|PUT|DELETE)|-[A-Z][ ]+(POST|PATCH|PUT|DELETE)|\/replies|\/statuses[^a-zA-Z]/) { exempt = 1; continue }
              # The path is usually quoted, so this one reads the quote-KEEPING
              # text: keepq=0 drops the whole URL and the check would never fire.
              if (r ~ /(reviews|comments)\/[A-Za-z0-9$<_{]/) { exempt = 1; continue }
              if (e ~ /--paginate/) {
                paginated = 1
                if (e ~ /(--jq|-q)[ =]/) {
                  jqagg = 1; jqpart = SEG[s]
                  sub(/^.*(--jq|-q)[ =][ ]*/, "", jqpart)
                }
                continue
              }
              # A surface occurrence that is neither exempt nor paginated is an
              # unpaginated collection read, whatever else the line does.
              offender = 1
            }
          }
          if (jqagg && jqpart ~ /max_by|min_by|sort_by|group_by|unique_by|first|last|reduce|length|\.\[[0-9-]/) {
            printf "%s:%d: %s   [page-local --jq aggregate under --paginate]\n", f, S[k], l
            continue
          }
          # Already paginated — in the COMMAND, not in a comment or a sibling —
          # and nothing else on the line is an unpaginated read.
          if (paginated && !offender) continue
          # Hand-paged reads are NOT exempt. Proving statically that a hand-
          # rolled loop consumes every page is not possible, and three successive
          # heuristics were each defeated by a counterexample: a literal page=1
          # (round 4), a variable set once and read once (round 5), and an
          # unrelated loop plus increment elsewhere in the same file (round 6).
          # A false green here is the silent stale verdict this gate exists to
          # prevent, so this surface requires --paginate. A genuinely deliberate
          # bounded read (a sample, a page-1 existence probe) says so out loud
          # with paginated-ok: <reason>, which a reviewer can weigh.
          if (nc ~ /per_page=/ && nc ~ /[?&]page=/) {
            printf "%s:%d: %s   [hand-paged read: require --paginate, or opt out with paginated-ok: <reason>]\n", f, S[k], l
            continue
          }
          # One unpaginated collection read is enough, even if another command
          # on the same line is paginated or is a write.
          if (offender) {
            printf "%s:%d: %s\n", f, S[k], l
            continue
          }
          # Every occurrence of the surface on this line was a write or a
          # single-object read, so there is no collection read to paginate.
          if (exempt) continue
          printf "%s:%d: %s\n", f, S[k], l
        }
      }
    ' "$f"
  done
)"

if [ -n "$report" ]; then
  echo "::error::unpaginated read of a paginated review surface (see scripts/check-review-reads-paginated.sh):" >&2
  printf '%s\n' "$report" >&2
  echo "" >&2
  echo "Every one of these lists is paginated OLDEST FIRST (reviews at 30/page), so an" >&2
  echo "unpaginated read silently drops the NEWEST entries — which is how three lanes" >&2
  echo "concluded a NO-GO had no finding text on 2026-11-03. Add --paginate (and" >&2
  echo "?per_page=100), or mark a deliberate exception with 'paginated-ok: <reason>'." >&2
  echo "" >&2
  echo "A hand-paged loop is not accepted: a literal page=1, a variable read once," >&2
  echo "and an unrelated loop elsewhere in the file all read page 1 while looking" >&2
  echo "paginated, and no static check can prove the loop consumes every page." >&2
  echo "Use --paginate, or state a deliberate bounded read with paginated-ok:." >&2
  echo "" >&2
  echo "A line tagged [page-local --jq aggregate under --paginate] already paginates but" >&2
  echo "aggregates INSIDE --jq: gh runs that filter once per page, so max_by/first/.[0]" >&2
  echo "answers page 1 and the caller reads a stale verdict while believing it read" >&2
  echo "everything. Slurp the unfiltered pages and aggregate locally instead:" >&2
  echo "  gh api --paginate 'repos/\$R/pulls/\$P/reviews?per_page=100' | jq -s 'add | max_by(.id)'" >&2
  exit 1
fi

[ "$QUIET" -eq 1 ] || echo "check-review-reads-paginated: clean ($(printf '%s\n' "$files" | wc -l) files in scope)"
exit 0
