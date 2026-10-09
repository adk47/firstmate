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

fn_body() {
  awk -v fn="$2" '
    !inb && $0 ~ "^[[:space:]]*(function[[:space:]]+)?" fn "[[:space:]]*\\(\\)" { inb = 1 }
    inb { print; if ($0 ~ /^[[:space:]]*\}/ || (/\}[[:space:]]*$/ && /\{/)) inb = 0 }
  ' "$1"
}

while IFS= read -r f; do
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
          # a trap line that rm's the var, or `trap <fn> ...` where <fn> rm's it
          if grep -E '^[^#]*(^|[^A-Za-z_])trap[[:space:]]' "$f" | grep -E "$LIFECYCLE_SIG" | grep -E '(^|[^A-Za-z_])rm[[:space:]]' | grep -Eq "\\\$\{?$var([^A-Za-z0-9_]|\$)"; then ok=1; fi
          if [ "$ok" -eq 0 ]; then
            while IFS= read -r fn; do
              # the rm must sit inside the handler's own body (def line to first closing brace)
              if fn_body "$f" "$fn" | grep -E '(^|[^A-Za-z_])rm[[:space:]]' | grep -Eq "\\\$\{?$var([^A-Za-z0-9_]|\$)"; then ok=1; break; fi
            done < <(grep -E '^[^#]*(^|[^A-Za-z_])trap[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]' "$f" | grep -E "$LIFECYCLE_SIG" \
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
