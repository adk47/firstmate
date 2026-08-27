#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# sync-profile-config.sh — write a repo profile config over a live one WITHOUT
# destroying the runtime-registered `.mcp.servers` block.
#
# WHY THIS IS A SHARED LIB AND NOT AN INLINE BLOCK
# ------------------------------------------------
# It used to live only inside deploy.sh's sync_profile_config(). rollback.sh
# restored profile configs with a plain `cp` instead, so the FORWARD path
# preserved runtime MCP registrations and the ROLLBACK path silently destroyed
# them. On 2026-08-26 attempt 1 of deploy run 32933062895 failed, deploy.yml's
# `Rollback on failure` fired, and the live Sentry MCP registration (with its
# token, which is deliberately not in git) was wiped from /root/.openclaw-main.
# GitHub reported the run as "success" because attempt 2 passed, so nothing
# anywhere said the registration had been destroyed.
#
# Two copies of this rule drift; the drift WAS the bug. One implementation,
# both callers.
#
# CONTRACT
#   sync_profile_config <src> <dst> [announce_label]
#     src            repo/last-known-good profile config (authoritative for
#                    every field EXCEPT .mcp.servers)
#     dst            the live config to overwrite
#     announce_label label for announce-legit-write.sh so the config-write
#                    audit watcher does not page on a legitimate write
#                    (default: the caller's basename)
#   returns 0 on success, non-zero on failure. Callers decide how loud to be.
#   Emits "preserved N live MCP server(s) in <dst>" on stderr.
#
# NOTE FOR CALLERS: the result is deliberately NOT byte-identical to <src> when
# the live file carried MCP servers. Any caller asserting `cmp -s "$src" "$dst"`
# is asserting the bug. Check the return code instead.
# ──────────────────────────────────────────────────────────────

_SPC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# spc_config_lock_path <config-path> — the ONE lock every writer of a given live
# config must take.
#
# WHY: preserving `.mcp.servers` is a read-modify-write. Between this function's
# read of the live file and its atomic rename, another writer (the Sentry healer
# from a watchdog tick or an ExecStartPre) can land its own rename. Ours then
# overwrites it with a snapshot taken BEFORE it existed -- so the healer logs
# "HEALED", exits 0, and the registration is gone microseconds later. Atomic
# rename makes each write indivisible; it does NOT make read-then-write
# serialisable. Only a lock spanning read -> transform -> announce -> rename does.
#
# Derived from the config path so every writer computes the same path without
# passing it around, and kept OUT of the config's own inode (never lock the file
# you are about to replace by rename -- the lock would follow the old inode).
spc_config_lock_path() {
  printf '%s.writers.lock' "$1"
}

sync_profile_config() {
  local src="$1" dst="$2"
  local label="${3:-$(basename "${0:-sync-profile-config}")}"

  [ -f "$src" ] || { echo "  ERROR: source profile config $src not found" >&2; return 1; }
  mkdir -p "$(dirname "$dst")" || return 1

  # No live file: nothing to preserve, plain copy is correct and complete.
  if [ ! -f "$dst" ]; then
    cp "$src" "$dst" || return 1
    echo "  preserved 0 live MCP server(s) in $dst (no live file)" >&2
    return 0
  fi

  # Whole read-modify-write under ONE lock — see spc_config_lock_path above.
  local _spc_lock
  _spc_lock="$(spc_config_lock_path "$dst")"
  (
    exec 9>"$_spc_lock" || { echo "  ERROR: cannot open lock $_spc_lock" >&2; exit 1; }
    flock -w "${SPC_LOCK_WAIT:-60}" 9 || {
      echo "  ERROR: timed out waiting for $_spc_lock — refusing to write $dst unlocked" >&2
      exit 1; }

  SRC="$src" DST="$dst" LABEL="$label" \
  ANNOUNCE_HELPER="${SPC_ANNOUNCE_HELPER:-$_SPC_LIB_DIR/announce-legit-write.sh}" \
    python3 - <<'PYEOF'
import hashlib, json, os, subprocess, sys, tempfile, time
src_path = os.environ['SRC']
dst_path = os.environ['DST']
label = os.environ.get('LABEL', 'sync-profile-config')
announce_helper = os.environ.get('ANNOUNCE_HELPER', '')

def warn(msg):
    sys.stderr.write(f"  WARNING: {msg}\n")

with open(src_path) as f:
    repo_cfg = json.load(f)

live_cfg = None
try:
    with open(dst_path) as f:
        live_cfg = json.load(f)
except json.JSONDecodeError as e:
    # The live file is unparseable. Quarantine it before overwriting: it may
    # hold the ONLY copy of an auth token. Silently treating it as empty
    # destroys that permanently, which is the exact class of failure this
    # module exists to prevent.
    ts = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
    quarantine = f"{dst_path}.corrupted.{ts}"
    try:
        os.rename(dst_path, quarantine)
        warn(f"live config {dst_path} is not valid JSON ({e.msg}); "
             f"moved to {quarantine} before overwrite")
    except OSError as move_err:
        warn(f"live config {dst_path} is not valid JSON and could not be "
             f"quarantined ({move_err}); proceeding with repo copy")
    live_cfg = {}

preserved = {}
if isinstance(live_cfg, dict):
    mcp = live_cfg.get('mcp')
    if isinstance(mcp, dict):
        servers = mcp.get('servers')
        if isinstance(servers, dict):
            preserved = servers
        elif servers is not None:
            warn(f"live {dst_path} has non-dict .mcp.servers "
                 f"({type(servers).__name__}); ignoring, not preserving")
    elif mcp is not None:
        warn(f"live {dst_path} has non-dict .mcp "
             f"({type(mcp).__name__}); ignoring, not preserving")
else:
    warn(f"live {dst_path} parsed but root is not a JSON object; ignoring")

if preserved:
    repo_cfg.setdefault('mcp', {})['servers'] = preserved

# Atomic write so a concurrently-starting gateway cannot read a torn file.
tmp = tempfile.NamedTemporaryFile('w', dir=os.path.dirname(dst_path), delete=False)
try:
    json.dump(repo_cfg, tmp, indent=2)
    tmp.flush()
    os.fsync(tmp.fileno())
    tmp.close()
    # Announce BEFORE the rename so openclaw-config-write-audit.sh's
    # inotify-triggered alert can match on path+sha256 and suppress the
    # "out-of-band write" page.
    if announce_helper and os.path.isfile(announce_helper):
        with open(tmp.name, 'rb') as fh:
            sha = hashlib.sha256(fh.read()).hexdigest()
        subprocess.run(
            [announce_helper, label, dst_path],
            check=False,
            env={**os.environ, 'ANNOUNCE_SHA': sha},
        )
    os.replace(tmp.name, dst_path)
except Exception:
    try:
        os.unlink(tmp.name)
    except OSError:
        pass
    raise
sys.stderr.write(f"  preserved {len(preserved)} live MCP server(s) in {dst_path}\n")
PYEOF
  )
}
