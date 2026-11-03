#!/usr/bin/env bash
set -euo pipefail

# Mechanical backstop: no live agent instruction may tell an agent to
# `source ~/.zshrc` (or ~/.bashrc) to find a credential.
#
# Incident (2026-10-19): a fresh CMO session followed
# muso-outreach-ghl-sync/SKILL.md's `source ~/.zshrc && curl … $GHL_API_KEY`,
# found nothing (that file holds only openclaw completions and SNOVIO_*), filed
# a bogus `openclaw__secrets request` and blocked a draft batch. Gateway
# credentials live in the gateway env, not an interactive shell rc. Prose !=
# enforcement, so this gate fails CI when the executable instruction reappears.
#
# Scanned (agent-facing instruction surfaces only): skills-all/**,
# workspaces/*/skills/**, and workspaces/*/{SOUL,AGENTS,TOOLS,STARTUP,
# HEARTBEAT,IDENTITY,USER}.md. docs/ and scripts/ are never scanned.
# Deliberately NOT gated: the bare phrase "in ~/.zshrc" (location unknown for
# several vars — separate census); only `source`/`.` of an rc file is caught.
# Residual scope (a backstop against the form the skills taught, not a shell
# parser) — NOT gated: eval "$(cat ~/.zshrc)", source <(...), $(< ~/.zshrc),
# bash -ic / zsh -i, a variable-built path (f=~/.zshrc; source "$f"), and prose
# imperatives such as "Source `~/.zshrc` before calling" (census: MUS-14670).
#
# Exemptions live in .cred-location-allowlist.txt:
#   <path-or-dir-prefix/> -- <pattern key> -- <reason>
# Only paths OUTSIDE the scanned surfaces may be listed: an entry that covers
# any scanned file fails CI, so a live instruction can never be allowlisted
# into the gate. An entry is live only while its path exists and still contains
# a match for its key (checked directly, so entries for unscanned paths work
# too). A stale entry fails CI, so the allowlist can only shrink.

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ALLOWLIST="${CRED_LOCATION_ALLOWLIST:-$ROOT/.cred-location-allowlist.txt}"

if [ ! -d "$ROOT/skills-all" ] || [ ! -d "$ROOT/workspaces" ]; then
  echo "Missing skills-all/ or workspaces/ under $ROOT (run from repo root, or set REPO_ROOT)." >&2
  exit 2
fi
if [ ! -f "$ALLOWLIST" ]; then
  echo "Missing allowlist $ALLOWLIST (set CRED_LOCATION_ALLOWLIST to override)." >&2
  exit 2
fi
cd "$ROOT"

# ---------------------------------------------------------------- patterns --
declare -A PAT
# One key, a path class: any whitespace-free shell word ending in the rc name,
# after `source` or after a command-position `.`. Covers "$HOME"/.zshrc,
# "${HOME}"/.zshrc, $HOME/.zshrc, absolute /home/x/.bashrc, ~/'.zshrc' and
# `builtin|command source`. Prose such as "the source of truth is not ~/.zshrc"
# does not match (a space follows `of`). The matcher sees file:line:text, so
# the `:` before the text counts as a command-position delimiter.
W='["'"'"'$~{}[:alnum:]_./-]*'
PAT[sourcerc]="(^|[^[:alnum:]_])source[[:space:]]+${W}\\.(zshrc|bashrc)|(^|[:;&|(\`[:space:]])\\.[[:space:]]+${W}\\.(zshrc|bashrc)"

# Emit file:line:text with backslash-newline continuations joined; line is the
# FIRST physical line of the logical line. Portable awk (mawk on CI, BSD awk on
# macOS): no ENDFILE or gawk-isms. Binary files are skipped, as grep -I did.
joined() {
  local f
  for f in "$@"; do
    grep -qI . -- "$f" 2>/dev/null || continue
    printf '%s\n' "$f"
  done | while IFS= read -r f; do
    awk -v F="$f" '
      { if (!n) start = NR
        if (sub(/\\[[:space:]]*$/, "")) { buf = buf $0 " "; n = 1; next }
        print F ":" start ":" buf $0; buf = ""; n = 0 }
      END { if (n) print F ":" start ":" buf }' "$f"
  done
}

FIX="credentials come from the gateway env (/etc/openclaw/main.env, or edge.env for the CS/Intercom profile) — the gateway runs as a daemon and does not source an interactive shell."

# --------------------------------------------------------------- file sets --
# Hit lines are parsed positionally as file:line:text; refuse paths that would
# corrupt that split (same guard as check-dead-infra-refs.sh).
if find skills-all workspaces \( -name '*:*' -o -name $'*\n*' \) -print -quit | grep -q .; then
  echo "Refusing to scan: a path under skills-all/ or workspaces/ contains ':' or a newline." >&2
  exit 2
fi

mapfile -t FILES < <(
  {
    find skills-all -type f
    find workspaces -path '*/skills/*' -type f
    find workspaces -mindepth 2 -maxdepth 2 -type f \
      \( -name SOUL.md -o -name AGENTS.md -o -name TOOLS.md -o -name STARTUP.md \
         -o -name HEARTBEAT.md -o -name IDENTITY.md -o -name USER.md \)
  } | LC_ALL=C sort -u
)
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "No files found under skills-all/ + workspaces/ — refusing to pass vacuously." >&2
  exit 2
fi

# ---------------------------------------------------------------- allowlist --
AL_PATHS=() AL_KEYS=()
lineno=0
while IFS= read -r raw || [ -n "$raw" ]; do
  lineno=$((lineno + 1))
  case "$raw" in ''|'#'*) continue ;; esac
  case "$raw" in
    *' -- '*' -- '*) ;;
    *)
      echo "Malformed allowlist line $lineno (need '<path> -- <key> -- <reason>'): $raw" >&2
      exit 2
      ;;
  esac
  path="${raw%% -- *}"
  rest="${raw#* -- }"
  key="${rest%% -- *}"
  key="${key// /}"
  reason="${rest#* -- }"
  if [ -z "$path" ] || [ -z "$key" ] || [ -z "$reason" ]; then
    echo "Malformed allowlist line $lineno (need '<path> -- <key> -- <reason>'): $raw" >&2
    exit 2
  fi
  if [ -z "${PAT[$key]:-}" ]; then
    echo "Unknown pattern key '$key' on allowlist line $lineno (valid: ${!PAT[*]})." >&2
    exit 2
  fi
  AL_PATHS+=("$path")
  AL_KEYS+=("$key")
done <"$ALLOWLIST"

# -------------------------------------------------------------------- scan --
fail=0
for key in "${!PAT[@]}"; do
  rc=0
  hits="$(joined "${FILES[@]}" | grep -E -e "${PAT[$key]}")" || rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "grep failed (rc=$rc) while scanning pattern key '$key'." >&2
    exit 2
  fi
  [ -n "$hits" ] || continue
  while IFS= read -r hit; do
    file="${hit%%:*}" rest="${hit#*:}"
    line="${rest%%:*}" text="${rest#*:}"
    text="${text#"${text%%[![:space:]]*}"}"
    echo "FAIL: $file:$line: [$key] ${text:0:160}" >&2
    echo "      fix: $FIX" >&2
    fail=1
  done <<<"$hits"
done

# ------------------------------------------- no exemptions for live paths --
for i in "${!AL_PATHS[@]}"; do
  p="${AL_PATHS[$i]}"
  for f in "${FILES[@]}"; do
    if [ "$f" = "$p" ] || [[ "$f" == "${p%/}/"* ]]; then
      echo "FAIL: allowlist entry '$p' covers a scanned live-agent surface ($f) — fix the instruction instead of allowlisting it." >&2
      fail=1
      break
    fi
  done
done

# -------------------------------------------------------- stale allowlist --
for i in "${!AL_PATHS[@]}"; do
  p="${AL_PATHS[$i]}"
  if [ ! -e "$p" ]; then
    echo "FAIL: allowlist entry '$p' points at a nonexistent path — remove it." >&2
    fail=1
    continue
  fi
  rc=0
  mapfile -t AL_FILES < <(find "$p" -type f | LC_ALL=C sort)
  if [ "${#AL_FILES[@]}" -eq 0 ]; then
    rc=1
  else
    # No -q: it exits at the first match, joined() then dies of SIGPIPE and
    # pipefail turns that into a false rc=141 on a large allowlisted file.
    joined "${AL_FILES[@]}" | grep -E -e "${PAT[${AL_KEYS[$i]}]}" >/dev/null || rc=$?
  fi
  if [ "$rc" -ge 2 ]; then
    echo "grep failed (rc=$rc) while checking allowlist entry '$p'." >&2
    exit 2
  elif [ "$rc" -eq 1 ]; then
    echo "FAIL: allowlist entry '$p' (key: ${AL_KEYS[$i]}) no longer matches anything — remove it." >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Credential-location doctrine violated (or stale allowlist entries): $FIX" >&2
  echo "Historical/tool-deny content OUTSIDE the scanned surfaces may be recorded with a" >&2
  echo "'<path> -- <key> -- <reason>' entry in .cred-location-allowlist.txt." >&2
  exit 1
fi

echo "OK: no 'source ~/.zshrc' in live agent surfaces (skills-all/, workspaces/; allowlist clean)."
