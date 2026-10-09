#!/usr/bin/env bash
# scripts/check-mktemp-traps.sh — every `mktemp -d` in scripts/** must either
# be named in a cleanup `trap` (directly, or via a handler function that rm's
# it) or carry a `# mktemp-ok: <why>` comment on the same or previous line.
# Test fixtures (scripts/tests/**, *.bats) are out of scope.
# Exit 0 clean, 1 offenders listed. MKTEMP_GUARD_ROOT overrides the repo root.
set -u
ROOT="${MKTEMP_GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
rc=0
# a trap only counts if it fires on a normal exit; ERR/INT-only traps leak on success
LIFECYCLE_SIG='(^|[^A-Za-z_])(EXIT|RETURN)([^A-Za-z_]|$)'

# comment-stripped source ($#, ${#x} survive: '#' only counts after whitespace/;/start)
strip() { sed -E 's/(^|[[:space:];])#.*/\1/' "$1"; }

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
      t = $0; d += gsub(/\{/, "", t); d -= gsub(/\}/, "", t)
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

while IFS= read -r f; do
  src=$(strip "$f")
  prev=""
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    cur="$line"
    code="${cur%%#*}"
    if [[ "$code" =~ mktemp[[:space:]]+(-d|--directory|-[a-z]*d)([[:space:]]|\)|\"|$) ]]; then
      if [[ "$cur" == *"mktemp-ok:"* || "$prev" == *"mktemp-ok:"* ]]; then
        :
      else
        var=""
        [[ "$code" =~ ([A-Za-z_][A-Za-z0-9_]*)=[\"\']?\$\([[:space:]]*mktemp ]] && var="${BASH_REMATCH[1]}"
        ok=0
        if [ -n "$var" ]; then
          # cleanup evidence must sit in the allocation's own function, not elsewhere in the file
          scope=$(printf '%s\n' "$src" | region "$n")
          # a trap line that rm's the var, or `trap <fn> ...` where <fn> rm's it
          if printf '%s\n' "$scope" | grep -E '(^|[^A-Za-z_])trap[[:space:]]' | grep -E "$LIFECYCLE_SIG" | grep -E '(^|[^A-Za-z_])rm[[:space:]]' | grep -Eq "\\\$\{?$var([^A-Za-z0-9_]|\$)"; then ok=1; fi
          if [ "$ok" -eq 0 ]; then
            while IFS= read -r fn; do
              # the rm must sit inside the handler's own body (def line to first closing brace)
              if printf '%s\n' "$src" | fn_body "$fn" | grep -E '(^|[^A-Za-z_])rm[[:space:]]' | grep -Eq "\\\$\{?$var([^A-Za-z0-9_]|\$)"; then ok=1; break; fi
            done < <(printf '%s\n' "$scope" | grep -E '(^|[^A-Za-z_])trap[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]' | grep -E "$LIFECYCLE_SIG" \
                       | sed -E 's/.*trap[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]].*/\1/')
          fi
        fi
        if [ "$ok" -eq 0 ]; then
          echo "${f#"$ROOT"/}:$n: mktemp -d with no cleanup trap naming it (add one, or '# mktemp-ok: <why>')"
          rc=1
        fi
      fi
    fi
    prev="$cur"
  done < "$f"
done < <(find "$ROOT/scripts" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.mjs' \) \
           -not -path '*/tests/*' | sort)

exit "$rc"
