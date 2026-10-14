#!/usr/bin/env bash
# scripts/check-mktemp-traps.sh — every `mktemp -d` in scripts/** must either
# be named in a cleanup `trap` (directly, or via a handler function that rm's
# it) or carry a `# mktemp-ok: <why>` comment on the same line or a comment-only previous line.
# Test fixtures (scripts/tests/**, *.bats) are out of scope.
# Exit 0 clean, 1 offenders listed. MKTEMP_GUARD_ROOT overrides the repo root.
set -u
ROOT="${MKTEMP_GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ -d "$ROOT/scripts" ] || { echo "check-mktemp-traps: no scripts directory under $ROOT" >&2; exit 2; }
rc=0
# enumerate up front: a find that errors (unreadable tree) must not pass as "nothing to check"
files=$(find "$ROOT/scripts" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.mjs' \) \
          -not -path '*/tests/*' 2>"${TMPDIR:-/tmp}/check-mktemp-traps.$$.err") || find_failed=1
if [ -s "${TMPDIR:-/tmp}/check-mktemp-traps.$$.err" ]; then find_failed=1; fi
rm -f "${TMPDIR:-/tmp}/check-mktemp-traps.$$.err"
if [ "${find_failed:-0}" -eq 1 ]; then echo "check-mktemp-traps: cannot enumerate $ROOT/scripts (unreadable path)" >&2; exit 2; fi
files=$(printf '%s\n' "$files" | sort)
# a trap only counts if it fires on a normal exit; ERR/INT-only traps leak on success.
# RETURN fires when a function returns, never on script exit, so it counts only inside a function.
SIG_TOP='(^|[^A-Za-z_])EXIT([^A-Za-z_]|$)'
SIG_FN='(^|[^A-Za-z_])(EXIT|RETURN)([^A-Za-z_]|$)'
FN_HEADER='^[[:space:]]*(function[[:space:]]+[A-Za-z_][A-Za-z0-9_:.-]*([[:space:]]|\(|$)|[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\))'

# split each line into code and comment, quote-aware ('#' inside '...' or "..." is data; it starts
# a comment only at line start or after whitespace/;). A backslash-continued command is joined onto its
# first line (continuation lines print empty) so `mktemp \<newline> -d` is matched like `mktemp -d`.
# Prints one line per input line for the chosen part.
split_comment() {
  awk -v part="$2" '
    {
      line = $0; code = ""; esc = 0; cmt = ""
      if (start == 0) q = ""   # a quote opened before a continuation stays open on the next line
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (esc) { esc = 0; code = code c; continue }
        if (c == "\\" && q != "\047") { esc = 1; code = code c; continue }
        if (q != "") { if (c == q) q = ""; code = code c; continue }
        if (c == "\"" || c == "\047") { q = c; code = code c; continue }
        if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[[:space:];]/)) { cmt = substr(line, i); break }
        code = code c
      }
      ocode[NR] = ""; ocmt[NR] = ""
      if (start == 0) start = NR
      if (esc) { sub(/\\$/, " ", code); ocode[start] = ocode[start] code; next }
      ocode[start] = ocode[start] code
      ocmt[start] = ocmt[start] cmt
      start = 0
    }
    END {
      for (i = 1; i <= NR; i++) print (part == "code" ? ocode[i] : ocmt[i])
    }' "$1"
}

# lines of the top-level function (name() {, function name {, or Allman) or top-level code enclosing line $1, from stdin
region() {
  awk -v n="$1" -v mode="${2:-lines}" '
    {
      l[NR] = $0
      # heredoc body is data: its braces never move scope depth
      if (hd != "") {
        t = $0; if (hdash) sub(/^\t+/, "", t)
        if (t == hd) hd = ""
        id[NR] = blk
        next
      }
      if (d == 0) {
        if ($0 ~ /^[[:space:]]*(function[[:space:]]+[A-Za-z_][A-Za-z0-9_:.-]*([[:space:]]|\(|$)|[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\))/) blk = NR
        else if ($0 !~ /^[[:space:]]*\{/) blk = 0   # Allman: a lone "{" keeps the function open
      }
      id[NR] = blk
      # count only braces outside quotes and not backslash-escaped: a quoted "{" is data, not scope
      q = ""; esc = 0
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (esc) { esc = 0; continue }
        if (c == "\\" && q != "\047") { esc = 1; continue }
        if (q != "") { if (c == q) q = ""; continue }
        if (c == "\"" || c == "\047") { q = c; continue }
        if (c == "{") d++; else if (c == "}") d--
      }
      if (d < 0) d = 0
      if (match($0, /<<-?[[:space:]]*["\047\\]?[A-Za-z_][A-Za-z0-9_]*/) && substr($0, RSTART - 1, 1) != "<") {
        s = substr($0, RSTART, RLENGTH)
        hdash = (s ~ /^<<-/)
        sub(/^<<-?[[:space:]]*["\047\\]?/, "", s)
        hd = s
      }
    }
    END {
      # mode "end": the line number where the enclosing block ends, not its lines
      if (mode == "end") { for (i = 1; i <= NR; i++) if (id[i] == id[n]) e = i; print e; exit }
      for (i = 1; i <= NR; i++) if (id[i] == id[n]) print l[i]
    }
  '
}

fn_body() {
  awk -v fn="$1" '
    !inb && ($0 ~ "^[[:space:]]*function[[:space:]]+" fn "([[:space:]]|\\(|$)" || $0 ~ "^[[:space:]]*" fn "[[:space:]]*\\(\\)") { inb = 1 }
    inb { print; if ($0 ~ /^[[:space:]]*\}/ || (/\}[[:space:]]*$/ && /\{/)) inb = 0 }
  '
}

# does a trap in $1 (a scope) arm cleanup on EXIT (or RETURN inside a function), with an action that rm's $2 (directly or via a handler fn)?
# The action and the trailing signal list are parsed apart: "EXIT" inside the action string arms nothing.
RE_Q1="^trap[[:space:]]+(--[[:space:]]+)?'([^']*)'[[:space:]]+([^;&|]*)"
RE_Q2='^trap[[:space:]]+(--[[:space:]]+)?"(([^"\\]|\\.)*)"[[:space:]]+([^;&|]*)'
RE_W="^trap[[:space:]]+(--[[:space:]]+)?([^[:space:]'\"]+)[[:space:]]+([^;&|]*)"
# an rm command (at a command start) that itself targets $1: split on ; & | first so an rm of
# something else plus a mention of $1 in another command is not cleanup evidence. The operand must be
# $1 itself: `rm -rf "$work/child"` leaves the allocated directory behind.
rm_targets() {
  # command starts: line start, { ( then do else, or a case arm `pattern)` (one token, so a printed "foo) rm" is not one)
  tr ';&|' '\n' | grep -E '(^|[{(]|(^|[[:space:]])(then|do|else)|^[[:space:]]*\(?[^[:space:]]+\))[[:space:]]*(command[[:space:]]+)?rm[[:space:]]' \
    | grep -Eq "[[:space:]'\"\\\\]\\\$\{?$1(:\?)?\}?['\"\\\\]*([[:space:]]|\$|[)}])"
}
# a trap only counts at a command start (a printed "trap ..." string arms nothing)
CMD_TRAP='(^|[;&|({]|[[:space:]](then|do|else))[[:space:]]*trap[[:space:]]'
# Bash keeps only the last trap per signal, so the verdict is the LAST trap in the scope that arms EXIT
# (or RETURN in a function): a later `trap 'echo done' EXIT` or `trap - EXIT` replaces the cleanup.
# TRAP_SEEN / TRAP_EXIT report on the last scan: a counting trap was parsed, and the winning one armed EXIT.
# $3=top forces the top-level signal set (used on the code that runs after a function returns).
trap_cleans() {
  local scope="$1" var="$2" line tl action sigs full fn m cleans verdict=1 sigre="$SIG_TOP"
  TRAP_SEEN=0; TRAP_EXIT=0
  # a function scope starts with its header line; top-level scope never does
  if [ "${3:-}" != top ] && [[ "$(printf '%s\n' "$scope" | head -n1)" =~ $FN_HEADER ]]; then sigre="$SIG_FN"; fi
  while IFS= read -r line; do
    # several traps can share a line: take them in execution order, each parsed from its own start
    while [[ "$line" =~ $CMD_TRAP ]]; do
      m="${BASH_REMATCH[0]}"; tl="trap ${line#*"$m"}"
      action=""; sigs=""; full=""
      if   [[ "$tl" =~ $RE_Q1 ]]; then full="${BASH_REMATCH[0]}"; action="${BASH_REMATCH[2]}"; sigs="${BASH_REMATCH[3]}"
      elif [[ "$tl" =~ $RE_Q2 ]]; then full="${BASH_REMATCH[0]}"; action="${BASH_REMATCH[2]}"; sigs="${BASH_REMATCH[4]}"
      elif [[ "$tl" =~ $RE_W  ]]; then full="${BASH_REMATCH[0]}"; action="${BASH_REMATCH[2]}"; sigs="${BASH_REMATCH[3]}"
      fi
      if [ -z "$full" ]; then line="${tl#trap}"; continue; fi
      line="${tl:${#full}}"
      printf '%s\n' "$sigs" | grep -Eq "$sigre" || continue
      TRAP_SEEN=1; TRAP_EXIT=0
      if printf '%s\n' "$sigs" | grep -Eq "$SIG_TOP"; then TRAP_EXIT=1; fi
      cleans=1
      if printf '%s\n' "$action" | rm_targets "$var"; then cleans=0; fi
      # handlers: every function the action calls; the rm must sit in that function's own body
      if [ "$cleans" -ne 0 ]; then
        for fn in $(printf '%s\n' "$action" | grep -Eo '(^|[;&[:space:]])[A-Za-z_][A-Za-z0-9_]*' | tr -d ';& \t'); do
          if printf '%s\n' "$src" | fn_body "$fn" | rm_targets "$var"; then cleans=0; break; fi
        done
      fi
      verdict=$cleans
    done
  done < <(printf '%s\n' "$scope" | grep -E '(^|[^A-Za-z_])trap[[:space:]]')
  return "$verdict"
}

while IFS= read -r f; do
  src=$(split_comment "$f" code)
  prev_code=""; prev_cmt=""
  n=0
  while IFS= read -r code <&3 && IFS= read -r cmt <&4; do
    n=$((n + 1))
    if [[ "$code" =~ mktemp[[:space:]]+(-d|--directory|-[a-z]*d)([[:space:]]|\)|\"|$) ]]; then
      # waiver lives in a real comment: this line's, or a comment-only previous line's
      if [[ "$cmt" == *"mktemp-ok:"* || ( "$prev_code" =~ ^[[:space:]]*$ && "$prev_cmt" == *"mktemp-ok:"* ) ]]; then
        :
      else
        # every allocation on the line needs its own assigned variable with its own cleanup:
        # more `mktemp -d` occurrences than distinct `VAR=$(mktemp -d` assignments fails closed
        allocs=$(printf '%s\n' "$code" | grep -Eo '(\$\(|`|^|[;&|({])[[:space:]]*(command[[:space:]]+)?mktemp[[:space:]]+(-d|--directory|-[a-z]*d)([[:space:]]|\)|"|$)' | wc -l)
        vars=$(printf '%s\n' "$code" | grep -Eo '[A-Za-z_][A-Za-z0-9_]*=["'"'"']?\$\([[:space:]]*(command[[:space:]]+)?mktemp[[:space:]]+(-d|--directory|-[a-z]*d)([[:space:]]|\)|"|$)' | sed -E 's/=.*//' | sort -u)
        nvars=$(printf '%s' "$vars" | grep -c . || true)
        ok=0
        if [ -n "$vars" ] && [ "$nvars" -ge "$allocs" ]; then
          # cleanup evidence must sit in the allocation's own function, not elsewhere in the file
          scope=$(printf '%s\n' "$src" | region "$n")
          ok=1
          for var in $vars; do
            trap_cleans "$scope" "$var" || { ok=0; break; }
            # an EXIT trap set inside a function is global: a later EXIT trap outside it replaces the cleanup
            if [ "$TRAP_EXIT" -eq 1 ] && [[ "$(printf '%s\n' "$scope" | head -n1)" =~ $FN_HEADER ]]; then
              rest=$(printf '%s\n' "$src" | tail -n +$(( $(printf '%s\n' "$src" | region "$n" end) + 1 )))
              if ! trap_cleans "$rest" "$var" top && [ "$TRAP_SEEN" -eq 1 ]; then ok=0; break; fi
            fi
            # mirror case: a top-level EXIT cleanup is replaced when any function in the file arms or clears EXIT
            # without removing the dir (fail closed: the function may run after the allocation)
            if [ "$TRAP_EXIT" -eq 1 ] && ! [[ "$(printf '%s\n' "$scope" | head -n1)" =~ $FN_HEADER ]]; then
              for fn in $(printf '%s\n' "$src" | grep -E "$FN_HEADER" | sed -E 's/^[[:space:]]*(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_:.-]*).*/\2/'); do
                fbody=$(printf '%s\n' "$src" | fn_body "$fn")
                if ! trap_cleans "$fbody" "$var" top && [ "$TRAP_SEEN" -eq 1 ]; then ok=0; break 2; fi
              done
            fi
          done
        fi
        if [ "$ok" -eq 0 ]; then
          # mktemp-ok: message text, not an allocation
          echo "${f#"$ROOT"/}:$n: mktemp -d with no cleanup trap naming it (add one, or '# mktemp-ok: <why>')"
          rc=1
        fi
      fi
    fi
    prev_code="$code"; prev_cmt="$cmt"
  done 3< <(split_comment "$f" code) 4< <(split_comment "$f" comment)
done <<< "$files"

exit "$rc"
