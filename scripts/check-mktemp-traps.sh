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
# a trap only counts if it fires on a normal exit; ERR/INT-only traps leak on success
LIFECYCLE_SIG='(^|[^A-Za-z_])(EXIT|RETURN)([^A-Za-z_]|$)'

# split each line into code and comment, quote-aware ('#' inside '...' or "..." is data; it starts
# a comment only at line start or after whitespace/;). Prints one line per input line for the chosen part.
split_comment() {
  awk -v part="$2" '
    {
      line = $0; code = ""; q = ""; esc = 0; cmt = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (esc) { esc = 0; code = code c; continue }
        if (c == "\\" && q != "\047") { esc = 1; code = code c; continue }
        if (q != "") { if (c == q) q = ""; code = code c; continue }
        if (c == "\"" || c == "\047") { q = c; code = code c; continue }
        if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[[:space:];]/)) { cmt = substr(line, i); break }
        code = code c
      }
      print (part == "code" ? code : cmt)
    }' "$1"
}

# lines of the top-level function (name() {, function name {, or Allman) or top-level code enclosing line $1, from stdin
region() {
  awk -v n="$1" '
    {
      l[NR] = $0
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
    }
    END { for (i = 1; i <= NR; i++) if (id[i] == id[n]) print l[i] }
  '
}

fn_body() {
  awk -v fn="$1" '
    !inb && ($0 ~ "^[[:space:]]*function[[:space:]]+" fn "([[:space:]]|\\(|$)" || $0 ~ "^[[:space:]]*" fn "[[:space:]]*\\(\\)") { inb = 1 }
    inb { print; if ($0 ~ /^[[:space:]]*\}/ || (/\}[[:space:]]*$/ && /\{/)) inb = 0 }
  '
}

# does a trap in $1 (a scope) arm cleanup on EXIT/RETURN, with an action that rm's $2 (directly or via a handler fn)?
# The action and the trailing signal list are parsed apart: "EXIT" inside the action string arms nothing.
RE_Q1="trap[[:space:]]+(--[[:space:]]+)?'([^']*)'[[:space:]]+([^;&|]*)"
RE_Q2='trap[[:space:]]+(--[[:space:]]+)?"(([^"\\]|\\.)*)"[[:space:]]+([^;&|]*)'
RE_W="trap[[:space:]]+(--[[:space:]]+)?([^[:space:]'\"]+)[[:space:]]+([^;&|]*)"
# an rm command (at a command start) that itself targets $1: split on ; & | first so an rm of
# something else plus a mention of $1 in another command is not cleanup evidence
rm_targets() {
  tr ';&|' '\n' | grep -E '(^|[{(]|(^|[[:space:]])(then|do|else))[[:space:]]*(command[[:space:]]+)?rm[[:space:]]' \
    | grep -Eq "\\\$\{?$1([^A-Za-z0-9_]|\$)"
}
trap_cleans() {
  local scope="$1" var="$2" tl action sigs fn
  while IFS= read -r tl; do
    action=""; sigs=""
    if   [[ "$tl" =~ $RE_Q1 ]]; then action="${BASH_REMATCH[2]}"; sigs="${BASH_REMATCH[3]}"
    elif [[ "$tl" =~ $RE_Q2 ]]; then action="${BASH_REMATCH[2]}"; sigs="${BASH_REMATCH[4]}"
    elif [[ "$tl" =~ $RE_W  ]]; then action="${BASH_REMATCH[2]}"; sigs="${BASH_REMATCH[3]}"
    else continue; fi
    printf '%s\n' "$sigs" | grep -Eq "$LIFECYCLE_SIG" || continue
    if printf '%s\n' "$action" | rm_targets "$var"; then return 0; fi
    # handlers: every function the action calls; the rm must sit in that function's own body
    for fn in $(printf '%s\n' "$action" | grep -Eo '(^|[;&[:space:]])[A-Za-z_][A-Za-z0-9_]*' | tr -d ';& \t'); do
      if printf '%s\n' "$src" | fn_body "$fn" | rm_targets "$var"; then return 0; fi
    done
  done < <(printf '%s\n' "$scope" | grep -E '(^|[^A-Za-z_])trap[[:space:]]')
  return 1
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
        var=""
        [[ "$code" =~ ([A-Za-z_][A-Za-z0-9_]*)=[\"\']?\$\([[:space:]]*mktemp ]] && var="${BASH_REMATCH[1]}"
        ok=0
        if [ -n "$var" ]; then
          # cleanup evidence must sit in the allocation's own function, not elsewhere in the file
          scope=$(printf '%s\n' "$src" | region "$n")
          if trap_cleans "$scope" "$var"; then ok=1; fi
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
