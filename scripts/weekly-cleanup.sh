#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Weekly Server Cleanup (node-8)
#
# Reclaims the junk the box's native mechanisms miss. Survey
# 2026-06-10: /tmp was 19GB / 6090 entries (disk 77%), dominated
# by ~1GB PR-review clones. systemd-tmpfiles (`D /tmp ... 30d`)
# runs daily but ages on max(atime,mtime,ctime), and scanners keep
# refreshing atime/ctime on dead clone trees — so they never
# expire. This sweep keys on MTIME ONLY, which is only bumped by
# an actual write, so "nobody touched the content in N days" means
# dead. Categories:
#
#   1. /tmp depth-1 entries with mtime > TMP_AGE_DAYS (14d), minus
#      an exclude list (sockets, openclaw runtime files, locks) and
#      two rails: a dir containing ANY file fresher than the cutoff
#      is skipped (still in use), and a dir with a mountpoint under
#      it is never rm -rf'd.
#   2. Hot-patch backups: *.bak / *.bak.* / *.bak-* / *.orig files
#      older than BAK_AGE_DAYS (30d) under /opt/hydra and
#      /root/hydra-hotpatch-backups. Patterns are deliberately
#      tight (NOT *.bak* — that would eat foo.bakery.md) and match
#      the convention deploy.sh documents for hot-patch backups.
#      Safe without consulting git: the repo tracks no such file
#      (CI-gated by a bats invariant), and anything rsync-managed
#      is restored by the next deploy anyway.
#   3. apt-get autoremove --purge + autoclean.
#
# Out of scope: k8s/containerd state, journald (capped once via
# SystemMaxUse drop-in by install-aux-units.sh), /var/lib/hydra-release.
#
# Posts a Block Kit summary to #clio_devops on EVERY real run —
# weekly cadence is low-noise and a silently dead timer must not
# look like a quiet week.
#
# Runs Monday 04:30 UTC via hydra-weekly-cleanup.timer ON NODE-8
# (installed idempotently by scripts/install-aux-units.sh).
#
# Exit contract (mirrors hydra-release.service: never mask real
# breakage as success):
#   0  normal run — per-file rm errors are counted + reported in
#      the Slack summary, NOT unit failures (EBUSY races on /tmp
#      are routine weekly churn)
#   1  structural refusal (tmp root missing/symlinked/suspicious)
#      → systemd marks the service failed
#   2  usage error / missing dependency
#
# Flags:
#   --dry-run   walk everything and print would-delete lines; no
#               rm, no apt, no Slack, no lock.
#
# Env knobs (mainly for tests — defaults target production):
#   WEEKLY_CLEANUP_TMP_ROOT          default /tmp
#   WEEKLY_CLEANUP_TMP_AGE_DAYS      default 14
#   WEEKLY_CLEANUP_TMP_EXCLUDES     space-separated basename globs;
#                                    REPLACES the default list when set
#   WEEKLY_CLEANUP_BAK_ROOTS         default "/opt/hydra /root/hydra-hotpatch-backups"
#   WEEKLY_CLEANUP_BAK_AGE_DAYS      default 30
#   WEEKLY_CLEANUP_SKIP_APT          1 = skip apt-get step
#   WEEKLY_CLEANUP_SLACK_CHANNEL     default C0ADV2W76G4 (#clio_devops)
#   WEEKLY_CLEANUP_LOCKFILE          single-run lock
#   WEEKLY_CLEANUP_SKIP_HOST_GUARD   1 = skip the ovh-node-8 guard (tests)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[weekly-cleanup $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
TMP_ROOT="${WEEKLY_CLEANUP_TMP_ROOT:-/tmp}"
TMP_AGE_DAYS="${WEEKLY_CLEANUP_TMP_AGE_DAYS:-14}"
BAK_ROOTS="${WEEKLY_CLEANUP_BAK_ROOTS:-/opt/hydra /root/hydra-hotpatch-backups}"
BAK_AGE_DAYS="${WEEKLY_CLEANUP_BAK_AGE_DAYS:-30}"
SKIP_APT="${WEEKLY_CLEANUP_SKIP_APT:-0}"
LOCKFILE="${WEEKLY_CLEANUP_LOCKFILE:-/var/run/hydra-weekly-cleanup.lock}"
SKIP_HOST_GUARD="${WEEKLY_CLEANUP_SKIP_HOST_GUARD:-0}"
DRY_RUN=0

# slack-notify.sh reads this (target channel).
# Export before sourcing so its `:=` default doesn't override us.
export SLACK_CHANNEL="${WEEKLY_CLEANUP_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops

log() { echo "$LOGPREFIX $1"; }

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Locate the sibling Slack helper relative to THIS script so the
# cleanup works from /opt/hydra, a worktree, or a deploy mirror.
_CLEANUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slack-notify.sh
source "$_CLEANUP_DIR/lib/slack-notify.sh"

command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 required but not on PATH"; exit 2; }

# Exclude list: basename globs matched against depth-1 /tmp entries.
# Sockets/IPC dirs, openclaw runtime artifacts, and anything lock-shaped.
if [ -n "${WEEKLY_CLEANUP_TMP_EXCLUDES:-}" ]; then
  read -r -a TMP_EXCLUDES <<< "$WEEKLY_CLEANUP_TMP_EXCLUDES"
else
  TMP_EXCLUDES=(
    'systemd-private-*' '.X11-unix' '.ICE-unix' '.XIM-unix' '.font-unix'
    '.Test-unix' 'snap-private-tmp' 'tmux-*' 'ssh-*'
    'openclaw*' 'hydra-*.lock.d' '*.lock'
  )
fi

tmp_deleted=0; tmp_excluded=0; tmp_active=0; tmp_errors=0; tmp_freed_kb=0
bak_deleted=0; bak_errors=0; bak_freed_kb=0
apt_status="skipped"
sweep_status="skipped"

ERRORS_FILE="$(mktemp)"
PAYLOAD_FILE="$(mktemp)"
trap 'rm -f "$ERRORS_FILE" "$PAYLOAD_FILE"' EXIT

is_excluded() {
  local name="$1" g
  for g in "${TMP_EXCLUDES[@]}"; do
    # shellcheck disable=SC2254  # unquoted $g is the point: glob match
    case "$name" in $g) return 0 ;; esac
  done
  return 1
}

# True if any mountpoint lives strictly UNDER $1 (never rm -rf across it).
# Paths with spaces are octal-escaped in /proc/self/mounts so they can't
# match here — rm's --one-file-system is the backstop for that edge.
has_mount_under() {
  [ -r /proc/self/mounts ] || return 1
  awk -v p="$1/" 'index($2, p) == 1 { found = 1 } END { exit found ? 0 : 1 }' \
    /proc/self/mounts
}

# Size in KB, measured BEFORE rm; added to the freed total only if the rm
# succeeds. du-then-rm is at worst slightly stale for a still-growing file —
# fine for a Slack report (a df before/after delta would be polluted by every
# other writer on the box).
entry_kb() {
  local kb
  kb="$(du -sk --one-file-system -- "$1" 2>/dev/null | awk '{print $1}' || true)"
  echo "${kb:-0}"
}

# ──────────────────────────────────────────────────────────────
# Structural guard: refuse to run against a tmp root we didn't audit.
# ──────────────────────────────────────────────────────────────
guard_tmp_root() {
  if [ -z "$TMP_ROOT" ] || [ "$TMP_ROOT" = "/" ]; then
    log "FATAL: refusing to run with TMP_ROOT='$TMP_ROOT'"; exit 1
  fi
  TMP_ROOT="${TMP_ROOT%/}"
  if [ -L "$TMP_ROOT" ]; then
    log "FATAL: TMP_ROOT is a symlink: $TMP_ROOT"; exit 1
  fi
  if [ ! -d "$TMP_ROOT" ]; then
    log "FATAL: TMP_ROOT is not a directory: $TMP_ROOT"; exit 1
  fi
  local rp
  rp="$(realpath -- "$TMP_ROOT" 2>/dev/null)" || { log "FATAL: realpath failed for $TMP_ROOT"; exit 1; }
  if [ "$rp" != "$TMP_ROOT" ]; then
    log "FATAL: TMP_ROOT resolves elsewhere ($TMP_ROOT -> $rp)"; exit 1
  fi
}

# ──────────────────────────────────────────────────────────────
# Category 1: stale depth-1 /tmp entries (mtime-keyed)
# ──────────────────────────────────────────────────────────────
clean_tmp() {
  local cutoff_epoch p name kb err
  cutoff_epoch=$(( $(date +%s) - TMP_AGE_DAYS * 86400 ))
  while IFS= read -r -d '' p; do
    name="$(basename "$p")"
    if is_excluded "$name"; then
      tmp_excluded=$((tmp_excluded + 1)); continue
    fi
    if [ ! -L "$p" ] && [ -d "$p" ]; then
      # Active-content rail: the top dir is old, but anything fresh inside
      # means the tree is in use (e.g. a long-lived clone being rebased).
      if [ -n "$(find "$p" -xdev -newermt "@${cutoff_epoch}" -print -quit 2>/dev/null)" ]; then
        tmp_active=$((tmp_active + 1)); continue
      fi
      if has_mount_under "$p"; then
        tmp_errors=$((tmp_errors + 1))
        echo "mountpoint under candidate, skipped: $p" >> "$ERRORS_FILE"
        continue
      fi
    fi
    kb="$(entry_kb "$p")"
    if [ "$DRY_RUN" -eq 1 ]; then
      log "DRY-RUN: would delete $p (${kb} KB)"
      tmp_deleted=$((tmp_deleted + 1)); tmp_freed_kb=$((tmp_freed_kb + kb))
      continue
    fi
    if [ ! -L "$p" ] && [ -d "$p" ]; then
      err="$(rm -rf --one-file-system -- "$p" 2>&1)" || {
        tmp_errors=$((tmp_errors + 1))
        echo "rm failed: $p: ${err:0:200}" >> "$ERRORS_FILE"
        continue
      }
    else
      err="$(rm -f -- "$p" 2>&1)" || {
        tmp_errors=$((tmp_errors + 1))
        echo "rm failed: $p: ${err:0:200}" >> "$ERRORS_FILE"
        continue
      }
    fi
    tmp_deleted=$((tmp_deleted + 1)); tmp_freed_kb=$((tmp_freed_kb + kb))
  done < <(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -xdev -mtime +"$TMP_AGE_DAYS" -print0 2>/dev/null)
}

# ──────────────────────────────────────────────────────────────
# Category 2: aged hot-patch backups under one root
# ──────────────────────────────────────────────────────────────
clean_bak_root() {
  local root="$1" p kb err
  if [ ! -d "$root" ]; then
    log "bak root missing, skipped: $root"
    return 0
  fi
  while IFS= read -r -d '' p; do
    kb="$(entry_kb "$p")"
    if [ "$DRY_RUN" -eq 1 ]; then
      log "DRY-RUN: would delete $p (${kb} KB)"
      bak_deleted=$((bak_deleted + 1)); bak_freed_kb=$((bak_freed_kb + kb))
      continue
    fi
    err="$(rm -f -- "$p" 2>&1)" || {
      bak_errors=$((bak_errors + 1))
      echo "rm failed: $p: ${err:0:200}" >> "$ERRORS_FILE"
      continue
    }
    bak_deleted=$((bak_deleted + 1)); bak_freed_kb=$((bak_freed_kb + kb))
  done < <(find "$root" -xdev -type f \
      \( -name '*.bak' -o -name '*.bak.*' -o -name '*.bak-*' -o -name '*.orig' \) \
      -mtime +"$BAK_AGE_DAYS" -print0 2>/dev/null)
}

# ──────────────────────────────────────────────────────────────
# Category 3: apt junk
# ──────────────────────────────────────────────────────────────
run_apt() {
  if [ "$DRY_RUN" -eq 1 ]; then
    apt_status="skipped (dry-run)"
    log "DRY-RUN: would run apt-get autoremove --purge + autoclean"
    return 0
  fi
  if [ "$SKIP_APT" = "1" ]; then
    apt_status="skipped"
    return 0
  fi
  if apt-get -y autoremove --purge >/dev/null 2>&1 \
     && apt-get -y autoclean >/dev/null 2>&1; then
    apt_status="ok"
  else
    apt_status="failed"
    echo "apt-get autoremove/autoclean failed" >> "$ERRORS_FILE"
  fi
}

# ──────────────────────────────────────────────────────────────
# Category 4: stale agent git clones (workspaces/repos + */tmp).
# Policy + its own Slack summary live in sweep-workspace-clones.sh;
# this only wires it into the weekly cadence. WEEKLY_CLEANUP_SKIP_SWEEP=1
# opts out (the bats suite MUST set it — the CI runner is node-8, so an
# unstubbed test run would sweep the real workspace roots).
# ──────────────────────────────────────────────────────────────
run_clone_sweep() {
  if [ "${WEEKLY_CLEANUP_SKIP_SWEEP:-0}" = "1" ]; then
    sweep_status="skipped"
    return 0
  fi
  local sweep_flag="--apply"
  [ "$DRY_RUN" -eq 1 ] && sweep_flag="--dry-run"
  if "$_CLEANUP_DIR/sweep-workspace-clones.sh" "$sweep_flag"; then
    sweep_status="ok"
  else
    sweep_status="failed"
    echo "sweep-workspace-clones.sh failed" >> "$ERRORS_FILE"
  fi
}

# ──────────────────────────────────────────────────────────────
# Summary: stdout lines + Block Kit payload (real runs only)
# ──────────────────────────────────────────────────────────────
print_summary() {
  log "tmp: deleted=$tmp_deleted excluded=$tmp_excluded active_skipped=$tmp_active errors=$tmp_errors freed_kb=$tmp_freed_kb"
  log "bak: deleted=$bak_deleted errors=$bak_errors freed_kb=$bak_freed_kb"
  log "apt: $apt_status"
  log "clone-sweep: $sweep_status"
  log "TOTAL freed_kb=$((tmp_freed_kb + bak_freed_kb))"
}

# Build the exact Slack payload in Python — error strings contain quotes
# and backticks that would shatter a naive bash JSON interpolation.
build_payload() {
  TMP_DELETED="$tmp_deleted" TMP_EXCLUDED="$tmp_excluded" TMP_ACTIVE="$tmp_active" \
  TMP_ERRORS="$tmp_errors" TMP_FREED_KB="$tmp_freed_kb" TMP_AGE="$TMP_AGE_DAYS" \
  BAK_DELETED="$bak_deleted" BAK_ERRORS="$bak_errors" BAK_FREED_KB="$bak_freed_kb" \
  BAK_AGE="$BAK_AGE_DAYS" APT_STATUS="$apt_status" SWEEP_STATUS="$sweep_status" \
  ERRORS_FILE="$ERRORS_FILE" \
  PAYLOAD_OUT="$PAYLOAD_FILE" SLACK_CHANNEL="$SLACK_CHANNEL" python3 - <<'PYEOF'
import json, os

e = os.environ
td, te, ta, terr = (int(e[k]) for k in ("TMP_DELETED", "TMP_EXCLUDED", "TMP_ACTIVE", "TMP_ERRORS"))
bd, berr = int(e["BAK_DELETED"]), int(e["BAK_ERRORS"])
total_kb = int(e["TMP_FREED_KB"]) + int(e["BAK_FREED_KB"])
apt = e["APT_STATUS"]
errors = terr + berr

def human(kb):
    if kb >= 1024 * 1024:
        return f"{kb / 1024 / 1024:.1f} GB"
    if kb >= 1024:
        return f"{kb / 1024:.1f} MB"
    return f"{kb} KB"

text = (
    f":broom: weekly-cleanup node-8 — freed {human(total_kb)} | "
    f"tmp: deleted={td} excluded={te} active_skipped={ta} | "
    f"bak: deleted={bd} | apt: {apt} | errors={errors}"
)

blocks = [
    {"type": "header", "text": {"type": "plain_text", "text": "weekly server cleanup — node-8"}},
    {"type": "section", "fields": [
        {"type": "mrkdwn", "text": f"*Total freed:*\n{human(total_kb)}"},
        {"type": "mrkdwn", "text": f"*/tmp (mtime >{e['TMP_AGE']}d):*\n{td} deleted · {te} excluded · {ta} active-skipped"},
        {"type": "mrkdwn", "text": f"*.bak/.orig (>{e['BAK_AGE']}d):*\n{bd} deleted"},
        {"type": "mrkdwn", "text": f"*apt autoremove/clean:*\n{apt}"},
        {"type": "mrkdwn", "text": f"*clone sweep:*\n{e['SWEEP_STATUS']} (details in its own post)"},
    ]},
]

if errors:
    try:
        with open(e["ERRORS_FILE"]) as f:
            lines = [l.rstrip() for l in f if l.strip()][:10]
    except Exception:
        lines = []
    detail = "\n".join(f"• {l}" for l in lines) or "(no detail captured)"
    blocks.append({"type": "section", "text": {
        "type": "mrkdwn", "text": f":warning: {errors} error(s):\n{detail}"}})

with open(e["PAYLOAD_OUT"], "w") as f:
    json.dump({"channel": e["SLACK_CHANNEL"], "text": text, "blocks": blocks}, f)
PYEOF
}

# ──────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────

# Host guard: wrong node → no-op (prevents an orphaned timer from
# firing after a host migration). Skippable for tests.
if [ "$SKIP_HOST_GUARD" != "1" ] && ! hostname | grep -q '^ovh-node-8$'; then
  log "SKIP: hostname is not ovh-node-8 ($(hostname)) — script is node-8-specific"
  exit 0
fi

guard_tmp_root

# Single-run lock so overlapping invocations never double-delete/post.
if [ "$DRY_RUN" -eq 0 ]; then
  exec 9>"$LOCKFILE"
  flock -n 9 || { log "SKIP: another weekly-cleanup run holds $LOCKFILE"; exit 0; }
fi

clean_tmp
for root in $BAK_ROOTS; do
  clean_bak_root "$root"
done
run_apt
run_clone_sweep

print_summary

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN: no Slack post."
  exit 0
fi

build_payload
log "Posting summary to ${SLACK_CHANNEL}."
slack_notify_payload_file "$PAYLOAD_FILE"
