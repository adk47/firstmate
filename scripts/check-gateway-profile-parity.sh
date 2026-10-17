#!/usr/bin/env bash
set -euo pipefail

# Gateway profile ENUMERATION-parity gate (MUS-2681, part of MUS-2654).
#
# What it proves: every openclaw-<profile>.json at the repo root is named in every
# enumerated deploy/ops list: the deploy.sh --target case arms, the `for profile in ...`
# word lists, CODEX_KEEPALIVE_PROFILES, PROFILES=(...), the provision-peer-labels case arms
# and deploy.yml's `options:`. Those enumerations are the semantics, so text decides them.
# `dev` has no repo config, so it is never enumerated. openclaw-server-backup-*.json are
# snapshots, not profiles.
#
# What it does NOT prove, and cannot: deploy.sh wires profiles through ~40 hardcoded
# `needs_target "main"` / `needs_target "edge"` branch pairs (config sync, soul validation,
# statedir pin, Step 6 restart/verify). This gate does not check them. The text cannot tell
# main-only by design (cron-jobs, Caroline RAG) from main-only by omission. Adding a profile
# still needs a manual pass over those branches. Structural fix: MUS-8070.
#
# REPO_ROOT overrides the tree (the bats suite points it at a fixture).

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

profiles=()
for cfg in "$ROOT"/openclaw-*.json; do
  [ -e "$cfg" ] || continue
  name="${cfg##*/openclaw-}"; name="${name%.json}"
  case "$name" in server-backup-*) continue ;; esac
  profiles+=("$name")
done
if [ "${#profiles[@]}" -eq 0 ]; then
  echo "FAIL: no openclaw-<profile>.json found under $ROOT" >&2
  exit 2
fi

fail=0
miss() { # <file> <profile> <why>
  echo "FAIL: $1: profile '$2' is missing" >&2
  echo "      why it is load-bearing: $3" >&2
  fail=1
}
need_file() {
  [ -f "$ROOT/$1" ] && return 0
  echo "FAIL: $1 not found under $ROOT" >&2
  fail=1
  return 1
}

# live_lines <file>: the file minus full-line and trailing comments. A commented-out wiring
# line (`# needs_target "qa"`, `: # needs_target "qa"`) is not wiring. A `#` only starts a
# comment at line start or after whitespace, so `$#` and `${#a}` survive.
live_lines() { sed -E 's/(^|[[:space:]])#.*$//' "$1"; }

# has_member <member>: stdin is an extracted list; true when <member> is exactly one of its
# words (split on whitespace, `|` and `,`). Exact comparison, not a pattern, so `qa-alt` is
# not `qa` and `openclaw-qa.json` is not `qa`: each site accepts ONE name form.
has_member() {
  local w
  while IFS= read -r w; do [ "$w" = "$1" ] && return 0; done < <(tr -s ' \t|,' '\n')
  return 1
}

# unparsable <list>: a list holding an expansion (`${qa:-}`, `$(...)`) or a quote (`"edge qa"`
# is ONE word) is not a literal enumeration, so it is refused rather than interpreted.
unparsable() { case "$1" in *'$'* | *'`'* | *'"'* | *"'"*) return 0 ;; esac; return 1; }

# member_for <profile> <bare|file>: the name form a site must use. Loops, case arms and
# workflow options enumerate bare names (`qa`); the config matrix enumerates filenames.
member_for() { if [ "$2" = file ]; then echo "openclaw-$1.json"; else echo "$1"; fi; }

# each_line <file> <profile> <bare|file> <line-anchor-ERE> <list-extract-sed> <why>: every line
# matching the anchor is parsed down to its list, and the site's member name must be one of that
# list's words. <list-extract-sed> is an ERE with one group that captures only the list
# (`for profile in X;`, `PROFILES=(X)`, `options: [X]`, the case-arm labels), so the profile
# appearing elsewhere on the line (`do echo qa; done`) does not count. A line the extract cannot
# parse fails closed. No matching line at all means the anchor was lost.
each_line() {
  local f="$ROOT/$1" p="$2" m lines line list
  m=$(member_for "$2" "$3")
  lines=$(live_lines "$f" | grep -E -- "$4" || true)
  if [ -z "$lines" ]; then
    miss "$1" "$p" "anchor /$4/ no longer exists, so this gate cannot see the list. $6"
    return
  fi
  while IFS= read -r line; do
    list=$(printf '%s\n' "$line" | sed -nE -- "s/$5/\\1/p")
    if unparsable "$list"; then list=; fi
    printf '%s\n' "$list" | has_member "$m" || miss "$1" "$p" "$6 (line: ${line#"${line%%[![:space:]]*}"})"
  done <<< "$lines"
}

# case_arm_labels <file> <case-line-ERE>: the arm labels at nesting depth 1 of the FIRST case
# block whose opener matches. Only that block is read, never the rest of the file, and a nested
# case inside an arm is skipped. Empty output means the block is gone.
case_arm_labels() {
  live_lines "$ROOT/$1" | awk -v open="$2" '
    !inside && $0 ~ open { inside = 1; depth = 1; next }
    !inside { next }
    /^[[:space:]]*case[[:space:]].*[[:space:]]in[[:space:]]*$/ { depth++; next }
    /^[[:space:]]*esac([[:space:];]|$)/ { depth--; if (depth == 0) exit; next }
    depth == 1 && /^[[:space:]]*[^[:space:])]+\)/ { sub(/^[[:space:]]*/, ""); sub(/\).*$/, ""); print }'
}

# arm_member <file> <profile> <case-line-ERE> <why>: <profile> is an arm label of that block.
arm_member() {
  local labels
  labels=$(case_arm_labels "$1" "$3")
  if unparsable "$labels"; then labels=; fi
  printf '%s\n' "$labels" | has_member "$2" || miss "$1" "$2" "$4"
}

for f in scripts/deploy.sh scripts/install-aux-units.sh scripts/openclaw-watchdog.sh \
  scripts/validate-config-matrix.sh scripts/provision-peer-labels.sh .github/workflows/deploy.yml; do
  need_file "$f" || true
done
[ "$fail" -eq 0 ] || exit 1

for p in "${profiles[@]}"; do
  each_line scripts/deploy.sh "$p" bare '\|all\) TARGET=' '^[[:space:]]*([^)]*)\).*' \
    "the --target arg parser rejects the profile, so it can never be deployed on its own"
  each_line scripts/deploy.sh "$p" bare '\|all\) ;;' '^[[:space:]]*([^)]*)\).*' \
    "the target-value validation rejects the profile ('deploy.sh --target $p' exits 1)"
  each_line scripts/deploy.sh "$p" bare 'for profile in (main|edge)\b' '^[[:space:]]*for profile in ([^;]*);.*' \
    "the plugin-install and Step 4c loops skip it, leaving its state dir without plugins or config"
  each_line scripts/install-aux-units.sh "$p" bare 'for profile in (main|edge)\b' '^[[:space:]]*for profile in ([^;]*);.*' \
    "its per-profile aux units/timers are never installed"
  each_line scripts/install-aux-units.sh "$p" bare 'CODEX_KEEPALIVE_PROFILES=' '.*CODEX_KEEPALIVE_PROFILES="([^"]*)".*' \
    "its Codex auth is never kept alive and expires"
  each_line scripts/openclaw-watchdog.sh "$p" bare 'for profile in (main|edge)\b' '^[[:space:]]*for profile in ([^;]*);.*' \
    "the watchdog never config-validates it, so a bad config is not caught before restart"
  each_line scripts/validate-config-matrix.sh "$p" file 'PROFILES=\([^)]' '.*PROFILES=\(([^)]*)\).*' \
    "its config is never run through the validation matrix"
  arm_member scripts/provision-peer-labels.sh "$p" "^[[:space:]]*case \"[\$]PROFILE\" in" \
    "provision-peer-labels exits 2 for this profile, so it gets no port or peer labels"
  each_line .github/workflows/deploy.yml "$p" bare 'options: \[' '.*options: \[([^]]*)\].*' \
    "the deploy workflow cannot target this profile"
done

[ "$fail" -eq 0 ] || exit 1
echo "profile enumeration parity OK (${profiles[*]})"
