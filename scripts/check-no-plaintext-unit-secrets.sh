#!/usr/bin/env bash
# check-no-plaintext-unit-secrets.sh — no shipped systemd unit may carry a
# secret as an inline `Environment=` value.
#
# WHY THIS EXISTS (T13, node8-to-pods plan 2026-10-27)
#
# /etc/systemd/system/intercom-webhook.service.d/env.conf shipped the Intercom
# token, the Intercom webhook signing secret, the OpenClaw gateway token and a
# Notion token as plaintext `Environment=` lines — and a second copy as
# env.conf.bak.prod beside it. systemd's Environment= is not a secret store:
# the values appear in `systemctl show -p Environment`, `systemd-analyze dump`,
# /proc/<pid>/environ and every backup of /etc.
#
# Repo-side, the same trap is one careless heredoc away: scripts/install-aux-units.sh
# writes ~40 units on every deploy, so a secret pasted into a unit block there
# reaches node-8 automatically and lives in git forever. Prose is not
# enforcement, so this gate scans the unit surfaces that SHIP in this repo and
# fails CI on any inline secret. The runtime half is
# scripts/intercom-webhook-env.sh check (run at the end of every deploy), which
# proves the same invariant against the INSTALLED unit files.
#
# Scope (default): scripts/aux-units/** and scripts/install-aux-units.sh.
# Extra paths may be passed as arguments, and SECRET_SCAN_ROOT re-roots the
# scan (used by scripts/tests/check-no-plaintext-unit-secrets.bats).
#
# An `Environment=` line is a violation when BOTH hold:
#   1. the variable NAME says it is secret (token / secret / password /
#      api_key / credential / *_DSN / *_KEY); and
#   2. the VALUE is a literal — not empty, not `-`, not a systemd specifier
#      (`%`), not a shell expansion (`$`), and at least 8 characters.
#
# Exempt a legitimate non-secret with `# secret-ok: <why>` on the line or on a
# comment-only line directly above it. Every exemption is visible in review.
#
# The failure message names the file, the line and the VARIABLE — never the
# value, because a hit may be a live credential.
#
# Exit: 0 clean / 1 violations / 2 usage or unreadable tree.
set -uo pipefail

ROOT="${SECRET_SCAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# The SAME assignment parser the deploy-time check uses, so a multi-assignment
# `Environment=A=1 OPENCLAW_TOKEN=…` line cannot be clean for one and a secret
# for the other. See scripts/lib/systemd-env-assignments.sh for why.
# shellcheck source=scripts/lib/systemd-env-assignments.sh
source "$ROOT/scripts/lib/systemd-env-assignments.sh" || true
# A missing/broken parser must be LOUD, not a silent pass: without it rule 1 sees
# no assignments at all and every multi-assignment secret looks clean.
if ! command -v sdenv_assignments >/dev/null 2>&1; then
  echo "FATAL: could not load scripts/lib/systemd-env-assignments.sh — the assignment" >&2
  echo "       parser is what makes this gate more than a prefix match. Refusing to run." >&2
  exit 2
fi

DEFAULT_TARGETS=(scripts/aux-units scripts/install-aux-units.sh)
targets=("${@:-}")
explicit_targets=0
if [ -z "${targets[0]:-}" ]; then
  targets=("${DEFAULT_TARGETS[@]}")
else
  explicit_targets=1
fi

# The NAME predicate and the VALUE rule live ONCE in the shared lib (below),
# so the CI gate and the deploy-time check cannot drift again.

# Literal token shapes that are secrets regardless of the variable name. Kept
# short and specific: a shape that fires on ordinary text is a gate people turn
# off.
SHAPES=(
  '[A-Za-z0-9+/=]{6,}Oj[A-Za-z0-9+/=]{8,}'      # base64 body containing ":…" — e.g. tok:uuid:1:0
  'xox[abprs]-[A-Za-z0-9-]{10,}'                # Slack
  'ntn_[A-Za-z0-9]{10,}'                        # Notion
  'gh[pousr]_[A-Za-z0-9]{20,}'                  # GitHub
  'sk-[A-Za-z0-9_-]{20,}'                       # OpenAI / OpenRouter style
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'          # PEM
)

files=()
scanned_a_dir=0
for t in "${targets[@]}"; do
  p="$ROOT/$t"
  case "$t" in /*) p="$t" ;; esac
  if [ -d "$p" ]; then
    scanned_a_dir=1
    while IFS= read -r f; do files+=("$f"); done < <(find "$p" -type f | LC_ALL=C sort)
  elif [ -f "$p" ]; then
    files+=("$p")
  else
    echo "FATAL: scan target not found: $t (root $ROOT)" >&2
    exit 2
  fi
done
if [ "${#files[@]}" -eq 0 ]; then
  echo "FATAL: no files found to scan under: ${targets[*]} — refusing to pass vacuously." >&2
  exit 2
fi

# Every *.service we ship must be IN the scan. A file-extension rename, a move
# out of scripts/aux-units/, or a symlink the find skips would otherwise make
# this gate green while covering nothing — the "prose is not enforcement" failure
# mode, with the gate itself as the prose.
service_count=0
for f in "${files[@]}"; do
  case "$f" in *.service) service_count=$((service_count + 1)) ;; esac
done
if [ "$service_count" -eq 0 ] && [ "$scanned_a_dir" -eq 1 ] && [ "$explicit_targets" -eq 0 ]; then
  echo "FATAL: scanned ${#files[@]} file(s) but not one *.service under: ${targets[*]}" >&2
  echo "       This gate exists to cover shipped unit files; passing without one is vacuous." >&2
  exit 2
fi

rc=0

for f in "${files[@]}"; do
  rel="${f#"$ROOT"/}"
  declare -A flagged_lines=()

  # ── rule 1: every assignment systemd would apply ────────────────────────
  # Whole FILE, not line by line: systemd joins a line ending in an odd run of
  # backslashes with the next (`Environment=\` then `FOO_SECRET=…`), so a
  # physical-line parser certifies that unit clean (QA round 5). The parser also
  # handles several assignments per line, quoted values with spaces and tabs, and
  # reports the FIRST physical line of each logical line.
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    aln="${rec%%$'\t'*}"
    rest="${rec#*$'\t'}"
    name="${rest%%$'\t'*}"
    value="${rest#*$'\t'}"
    case "$name" in EnvironmentFile|Environment) continue ;; esac
    # POSITIVE allow-list for THIS unit's surfaces, decided on the NAME alone:
    # whatever the value parses to, anything outside the three non-secret knobs is
    # refused. The heuristic below keeps covering every other unit this repo ships.
    if case "$f" in */intercom-webhook.service) true ;; *) false ;; esac; then
      if ! sdenv_name_allowed_in_intercom_webhook_unit "$name"; then
        echo "FAIL: $rel:$aln names $name; intercom-webhook's allow-list is only" >&2
        echo "      ($SDENV_INTERCOM_WEBHOOK_ALLOWED_ENV). Credentials go in the EnvironmentFile." >&2
        rc=1
        flagged_lines["$aln"]=1
        continue
      fi
    fi
    sdenv_name_is_secret "$name" || continue
    sdenv_value_is_violation "$value" || continue

    # Exemption is read from the FILE (same line or the comment directly above).
    line_text="$(sed -n "${aln}p" "$f" 2>/dev/null || true)"
    prev_text=""
    if [ "$aln" -gt 1 ]; then prev_text="$(sed -n "$((aln - 1))p" "$f" 2>/dev/null || true)"; fi
    if printf '%s' "$line_text" | grep -q 'secret-ok:[[:space:]]*[^[:space:]]' \
       || printf '%s' "$prev_text" | grep -q 'secret-ok:[[:space:]]*[^[:space:]]'; then
      continue
    fi

    # NOTHING from the value reaches the log (QA): a diagnostic that interpolates
    # $value prints the credential into the CI log, the one place it must never
    # appear.
    if printf '%s' "$value" | grep -q '\$'; then
      echo "FAIL: $rel:$aln: secret-named $name is assigned a shell expansion in a unit surface." >&2
      echo "      An installer heredoc expands this at deploy time, so the installed unit holds the" >&2
      echo "      plaintext while this gate only saw a \$. Use EnvironmentFile= instead. Value not printed." >&2
    else
      echo "FAIL: $rel:$aln: inline secret value for $name in a unit Environment= assignment." >&2
      echo "      Move the value into a root-only EnvironmentFile (see scripts/intercom-webhook-env.sh)" >&2
      echo "      and leave only the variable NAME behind. Value not printed on purpose." >&2
    fi
    rc=1
    flagged_lines["$aln"]=1
  done < <(sdenv_assignments < "$f")

  # ── rule 2: a literal token shape anywhere in a unit surface ────────────
  lineno=0
  prev_comment=""
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line_flagged="${flagged_lines[$lineno]:-0}"
    # ── rule 2: a literal token shape anywhere in a unit surface ────────────
    # (skipped after rule 1 fired ON THIS LINE, so one hit is reported once)
    if [ "$line_flagged" -eq 0 ]; then
    for shape in "${SHAPES[@]}"; do
      if printf '%s' "$line" | grep -qE -- "$shape"; then
        if ! printf '%s' "$line" | grep -q 'secret-ok:[[:space:]]*[^[:space:]]' \
           && ! printf '%s' "$prev_comment" | grep -q 'secret-ok:[[:space:]]*[^[:space:]]'; then
          echo "FAIL: $rel:$lineno: literal credential shape ($shape) in a unit surface." >&2
          echo "      Value not printed on purpose. Rotate it if it is real; move it to Vault/ESO otherwise." >&2
          rc=1
          line_flagged=1
          break
        fi
      fi
    done
    fi

    # Comment-only lines seed the exemption for the line below. (No
    # `[[:space:]]*` here: in a bash case pattern that bracket-plus-star
    # requires at least one whitespace, so an unindented `#` would not match.)
    case "${line#"${line%%[![:space:]]*}"}" in
      '#'*) prev_comment="$line" ;;
      *)    prev_comment="" ;;
    esac
  done < "$f"
  unset flagged_lines
done

if [ "$rc" -eq 0 ]; then
  echo "OK: no plaintext secrets in shipped unit surfaces (${#files[@]} file(s) including $service_count *.service: ${targets[*]})."
fi
exit "$rc"
