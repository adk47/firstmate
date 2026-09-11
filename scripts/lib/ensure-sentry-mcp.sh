#!/usr/bin/env bash
set -uo pipefail
# ──────────────────────────────────────────────────────────────
# ensure-sentry-mcp.sh — converge `.mcp.servers.sentry` in the live main config.
#
# WHY THIS EXISTS
# ---------------
# The Sentry MCP server is registered at RUNTIME, because its entry carries an
# auth token that must never be committed. Runtime state on this box is not
# durable: on 2026-08-26 a failed deploy attempt fired rollback.sh, which
# restored the profile configs with a plain `cp` and destroyed the registration
# 17 hours after it was made. Nothing alerted; it was found by a dry-run
# failing days later.
#
# rollback.sh is fixed (scripts/lib/sync-profile-config.sh), but "we fixed the
# one cause we found" is exactly the assumption that failed last time. This
# healer makes the CAUSE IRRELEVANT: the secrets file is the source of truth and
# the config entry is derived from it, reconverged before every gateway start.
# Same shape as the codex auth model already in this repo, and the same doctrine
# as CLAUDE.md's "prose alone is not enforcement -- the script and watchdog are."
#
# SOURCE OF TRUTH
#   /opt/hydra/secrets/sentry.env   (root, 0600, SENTRY_API_TOKEN=...)
# Kept outside the workspace tree so agent sweeps and the hydra-audit snapshot
# cannot pick it up -- same placement as the existing mercury.env.
#
# WHY NOT THE CLI: `openclaw mcp set` refuses any config containing the legacy
# `plugins.installs` key, which openclaw-main.json still has. And it would not
# have helped -- it writes the same field a rollback overwrites. Durability was
# never a registration-method problem.
#
# WHY NOT AN ENV VAR IN THE CONFIG: openclaw does not expand ${VARS} in mcp
# headers (upstream #70901), so the literal string would be sent as the token.
#
# MODES
#   (no args)  converge. Exit 0 if already correct or successfully repaired.
#   --check    report only. 0 = present and well-formed, 1 = missing/malformed
#              (repairable), 2 = cannot tell (unreadable config, no token).
#
# NEVER blocks a gateway start: pre-start-heal invokes it report-only.
# ──────────────────────────────────────────────────────────────

ESM_TS() { date -u +%Y-%m-%dT%H:%M:%SZ; }
esm_log() { echo "[ensure-sentry-mcp $(ESM_TS)] $*"; }

ESM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESM_CFG="${ENSURE_SENTRY_MCP_CFG:-/root/.openclaw-main/openclaw.json}"
ESM_SECRETS="${ENSURE_SENTRY_MCP_SECRETS:-/opt/hydra/secrets/sentry.env}"
ESM_URL="${ENSURE_SENTRY_MCP_URL:-https://mcp.sentry.dev/mcp}"
ESM_ANNOUNCE="${ENSURE_SENTRY_MCP_ANNOUNCE:-$ESM_LIB_DIR/announce-legit-write.sh}"

# ── THE KILL SWITCH (PR #929, 2026-09-11) ────────────────────────────────────
# 0 = the sentry MCP server is DISABLED: this healer removes .mcp.servers.sentry
# from the live config instead of registering it. 1 = normal registration.
#
# WHY IT LIVES HERE and not in the repo config: `.mcp` is deliberately ABSENT
# from openclaw-main.json / openclaw-edge.json so the token never lands in git,
# AND scripts/lib/sync-profile-config.sh copies every field EXCEPT .mcp.servers
# (it emits "preserved N live MCP server(s)"), so a repo-config edit is
# discarded at deploy. On top of that THIS script re-registers the server on
# every main gateway start (openclaw-pre-start-heal.sh:124, ExecStartPre), so
# even removing the live entry by hand is undone at the next restart. The only
# place a PR can actually control the registration is this constant.
#
# WHY IT IS OFF: on openclaw >= 2026.8 any non-core-safe `tools.deny` marks an
# agent's codex harness restricted and kills its native web search
# (dist/selection-Bge6N4vD.js:789 — the test is satisfied by
# `!isKnownCoreToolId(name)` alone, so an exact-name deny behaves exactly like
# the `sentry__*` wildcard; there is no narrow-deny middle option). #929 removes
# those denies to restore web search, which would otherwise expose the
# write-capable `sentry__update_issue` to all nine agents. Disabling the server
# keeps the write surface at exactly what it is today — ZERO, since the server
# has not started since 2026-09-11 06:21:28Z ("[bundle-mcp] failed to start
# server \"sentry\": MCP tool listing timed out after 1500ms") and no agent,
# including deny-free cto/qa, carries a sentry__* tool in its catalog.
#
# COST, stated plainly: cto/qa Sentry triage stays off (already non-functional),
# and cto's #sentry-alerts binding (1d8d732d) now fails loudly instead of
# silently. Flip this back to 1 in a one-line PR once Aaron rules on whether
# fleet-wide `sentry__update_issue` access is acceptable.
#
# EDGE IS NOT AFFECTED (verified 2026-09-11, not assumed): this healer is gated
# to the main profile (openclaw-pre-start-heal.sh:124, `[ "$PROFILE" = "main" ]`)
# and the live edge config has no `.mcp.servers` at all.
ESM_ENABLED="${ENSURE_SENTRY_MCP_ENABLED:-0}"

# The lock-path helper lives in sync-profile-config.sh so the healer and the
# deploy/rollback sync compute the SAME path. Two writers agreeing on a lock by
# coincidence is not a lock. Fall back to the same formula if the lib is absent
# (standalone/test use) rather than silently running unlocked.
# shellcheck source=sync-profile-config.sh
if [ -r "$ESM_LIB_DIR/sync-profile-config.sh" ]; then
  . "$ESM_LIB_DIR/sync-profile-config.sh"
fi
if ! declare -F spc_config_lock_path >/dev/null 2>&1; then
  spc_config_lock_path() { printf '%s.writers.lock' "$1"; }
fi

# Read the token from the protected source of truth. Echoes it on stdout (never
# logs it) and returns non-zero when it cannot be read at all.
esm_secret_token() {
  [ -r "$ESM_SECRETS" ] || return 1
  local mode_bits
  mode_bits="$(stat -c %a "$ESM_SECRETS" 2>/dev/null || stat -f %Lp "$ESM_SECRETS" 2>/dev/null || echo unknown)"
  case "$mode_bits" in
    600|400) ;;
    *) esm_log "REFUSING: $ESM_SECRETS is mode $mode_bits — a credential readable beyond root is not one we will propagate."
       return 1 ;;
  esac
  sed -n 's/^[[:space:]]*SENTRY_API_TOKEN=//p' "$ESM_SECRETS" | head -1 | tr -d '"'"'"'' | tr -d '\r'
}

ensure_sentry_mcp_main() {
  local mode="${1:-converge}"

  command -v jq >/dev/null 2>&1 || { esm_log "ERROR: jq not found"; return 2; }

  if [ ! -r "$ESM_CFG" ]; then
    esm_log "ERROR: $ESM_CFG unreadable — cannot tell whether sentry is registered."
    return 2
  fi
  if ! jq -e . "$ESM_CFG" >/dev/null 2>&1; then
    esm_log "ERROR: $ESM_CFG is not valid JSON — refusing to touch it (pre-start-heal owns that repair)."
    return 2
  fi

  # ── Disabled: strip the entry instead of converging it ──────────────────────
  # Removes ONLY .mcp.servers.sentry; every other live MCP server is preserved
  # (del() on one key, never a rewrite of the block). Idempotent: when the entry
  # is already absent this writes nothing at all — no temp file, no announce, no
  # rename — so repeat ExecStartPre runs are silent no-ops rather than a write
  # storm against the audit watcher.
  if [ "$ESM_ENABLED" != "1" ]; then
    if ! jq -e 'has("mcp") and (.mcp | has("servers")) and (.mcp.servers | has("sentry"))' \
         "$ESM_CFG" >/dev/null 2>&1; then
      esm_log "OK: sentry MCP is disabled (ESM_ENABLED=$ESM_ENABLED) and already absent from $ESM_CFG — nothing to do."
      return 0
    fi
    # Exit 3, NOT 1. The watchdog's rc=1 branch means "registration drifted,
    # re-register it" and its Slack copy says so; in disabled mode running the
    # healer REMOVES the server, so reusing 1 would make the watchdog heal by
    # deleting while announcing that it re-registered — backwards, and exactly
    # the kind of silent contradiction this whole block exists to prevent.
    # A distinct code lets the caller word it correctly (QA #929 v3 finding 1).
    [ "$mode" = "--check" ] && { esm_log "VIOLATION: sentry MCP is disabled but still registered in $ESM_CFG."; return 3; }

    local _esm_lock_d
    _esm_lock_d="$(spc_config_lock_path "$ESM_CFG")"
    (
      exec 9>"$_esm_lock_d" || { esm_log "ERROR: cannot open lock $_esm_lock_d"; exit 2; }
      flock -w "${ENSURE_SENTRY_MCP_LOCK_WAIT:-60}" 9 || {
        esm_log "ERROR: timed out waiting for $_esm_lock_d — refusing to write unlocked"; exit 2; }

      local tmp_d others_before
      others_before="$(jq -r '[.mcp.servers | keys[] | select(. != "sentry")] | length' "$ESM_CFG" 2>/dev/null || echo 0)"
      tmp_d="$(mktemp -p "$(dirname "$ESM_CFG")")" || { esm_log "ERROR: mktemp failed"; exit 2; }

      if ! jq 'del(.mcp.servers.sentry)' "$ESM_CFG" > "$tmp_d"; then
        rm -f "$tmp_d"; esm_log "ERROR: jq del failed — live config untouched."; exit 2
      fi

      # Validate what we are about to install: sentry gone, every OTHER server
      # still present, agents.list intact. A del() that took the whole block with
      # it would strip unrelated servers silently.
      if ! jq -e --argjson n "$others_before" '
            ((.mcp.servers.sentry // null) == null)
            and (([.mcp.servers // {} | keys[]] | length) == $n)
            and ((.agents.list | type) == "array")
          ' "$tmp_d" >/dev/null 2>&1; then
        rm -f "$tmp_d"; esm_log "ERROR: rendered config failed validation — live config untouched."; exit 2
      fi

      if [ -x "$ESM_ANNOUNCE" ]; then
        if ! ANNOUNCE_SHA="$(sha256sum "$tmp_d" | awk '{print $1}')" \
             "$ESM_ANNOUNCE" ensure-sentry-mcp "$ESM_CFG"; then
          rm -f "$tmp_d"
          esm_log "ERROR: announce-legit-write failed — live config untouched (an unannounced write pages #clio_devops)."
          exit 2
        fi
      fi

      if ! mv "$tmp_d" "$ESM_CFG"; then
        rm -f "$tmp_d"; esm_log "ERROR: rename failed — live config untouched."; exit 2
      fi
      esm_log "DISABLED: removed sentry MCP from $ESM_CFG (${others_before} other MCP server(s) preserved)."
      exit 0
    )
    return $?
  fi

  # Well-formed means: right url AND a non-empty token. `test("^Sentry-Bearer")`
  # alone would pass a header of "Sentry-Bearer " with no token, which is a
  # config that looks registered and 401s on every call -- the exact trap the
  # original registration recipe hit.
  # `transport` is part of "healthy", not cosmetic: this repo REQUIRES
  # streamable-http (an mcp-remote/stdio entry spawns a subprocess trio that has
  # taken the gateway down before, which is why lint rejects it). An entry that
  # keeps the right url and a current token but loses its transport is unusable,
  # and without this clause --check exits 0 while pre-start-heal and the watchdog
  # both skip the repair.
  if jq -e --arg u "$ESM_URL" '
        (.mcp.servers.sentry.url == $u)
        and (.mcp.servers.sentry.transport == "streamable-http")
        and ((.mcp.servers.sentry.headers.Authorization // "") | test("^Sentry-Bearer .+$"))
      ' "$ESM_CFG" >/dev/null 2>&1; then
    # Well-formed is NOT the same as CURRENT. Checking only "url right, token
    # non-empty" means a rotated/revoked credential survives indefinitely: the
    # live config keeps the dead token, --check says OK, the watchdog says OK,
    # and every Sentry call 401s with nothing pointing at the cause. That is not
    # hypothetical -- the Sentry token was rotated on 2026-08-26 and the old one
    # revoked. Compare against the source of truth.
    local _want _have
    if ! _want="$(esm_secret_token)"; then
      esm_log "UNVERIFIABLE: $ESM_SECRETS unreadable — the entry looks well-formed but cannot be proven current."
      return 2
    fi
    if [ -z "$_want" ]; then
      esm_log "UNVERIFIABLE: $ESM_SECRETS has no SENTRY_API_TOKEN — cannot prove the live token is current."
      return 2
    fi
    _have="$(jq -r '.mcp.servers.sentry.headers.Authorization' "$ESM_CFG" 2>/dev/null | sed 's/^Sentry-Bearer //')"
    if [ "$_have" != "$_want" ]; then
      # Never log either value; the mismatch itself is the whole message.
      esm_log "DRIFT: the live token does not match $ESM_SECRETS (rotated credential still installed)."
      [ "$mode" = "--check" ] && return 1
    else
      # Log the healthy path in BOTH modes. Converge runs from
      # openclaw-pre-start-heal.sh, where silence-on-success made "the healer ran
      # and found nothing to do" indistinguishable from "the healer never ran" --
      # so the one state we most want to be able to assert after an incident was
      # the one state that left no trace.
      esm_log "OK: sentry MCP registered, well-formed and current."
      return 0
    fi
  fi

  if [ "$mode" = "--check" ]; then
    esm_log "DRIFT: .mcp.servers.sentry is missing or malformed in $ESM_CFG."
    return 1
  fi

  # --- converge ---------------------------------------------------------
  if [ ! -r "$ESM_SECRETS" ]; then
    esm_log "CANNOT HEAL: $ESM_SECRETS is absent. Create it (root, 0600) with SENTRY_API_TOKEN=<token>."
    return 2
  fi
  local mode_bits
  mode_bits="$(stat -c %a "$ESM_SECRETS" 2>/dev/null || stat -f %Lp "$ESM_SECRETS" 2>/dev/null || echo unknown)"
  case "$mode_bits" in
    600|400) ;;
    *) esm_log "REFUSING: $ESM_SECRETS is mode $mode_bits — a credential readable beyond root is not one we will propagate."
       return 2 ;;
  esac

  local tok
  tok="$(esm_secret_token)" || return 2
  if [ -z "$tok" ]; then
    esm_log "CANNOT HEAL: $ESM_SECRETS has no SENTRY_API_TOKEN value."
    return 2
  fi

  # EVERYTHING below is one read-modify-write against the live config, and
  # deploy/rollback does the same. Without a shared lock the loser's rename
  # silently discards the winner's work -- and because each rename is atomic, the
  # loser still reports success. That is how a "HEALED" log line can be followed
  # microseconds later by a config with no Sentry in it.
  local _esm_lock
  _esm_lock="$(spc_config_lock_path "$ESM_CFG")"
  (
    exec 9>"$_esm_lock" || { esm_log "ERROR: cannot open lock $_esm_lock"; exit 2; }
    flock -w "${ENSURE_SENTRY_MCP_LOCK_WAIT:-60}" 9 || {
      esm_log "ERROR: timed out waiting for $_esm_lock — refusing to write unlocked"; exit 2; }

  local tmp
  tmp="$(mktemp -p "$(dirname "$ESM_CFG")")" || { esm_log "ERROR: mktemp failed"; exit 2; }

  # The token goes through the ENVIRONMENT, never argv: /proc/<pid>/cmdline is
  # world-readable (0444) and every agent on this box runs as root with exec.
  # Note `-` vs `:-` is irrelevant here; what matters is that jq's `env.` only
  # sees EXPORTED vars, hence the inline assignment.
  if ! SENTRY_TOK="$tok" jq --arg u "$ESM_URL" '
        .mcp.servers.sentry = {
          transport: "streamable-http",
          url: $u,
          headers: { Authorization: ("Sentry-Bearer " + env.SENTRY_TOK) }
        }' "$ESM_CFG" > "$tmp"; then
    rm -f "$tmp"; esm_log "ERROR: jq transform failed — live config untouched."; exit 2
  fi

  # Validate what we are about to install, not what we intended to build.
  if ! jq -e --arg u "$ESM_URL" '
        (.mcp.servers.sentry.url == $u)
        and (.mcp.servers.sentry.transport == "streamable-http")
        and (.mcp.servers.sentry.headers.Authorization | test("^Sentry-Bearer .+$"))
        and ((.agents.list | type) == "array")
      ' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; esm_log "ERROR: rendered config failed validation — live config untouched."; exit 2
  fi

  if [ -x "$ESM_ANNOUNCE" ]; then
    if ! ANNOUNCE_SHA="$(sha256sum "$tmp" | awk '{print $1}')" \
         "$ESM_ANNOUNCE" ensure-sentry-mcp "$ESM_CFG"; then
      rm -f "$tmp"
      esm_log "ERROR: announce-legit-write failed — live config untouched (an unannounced write pages #clio_devops)."
      exit 2
    fi
  fi

  if ! mv "$tmp" "$ESM_CFG"; then
    rm -f "$tmp"; esm_log "ERROR: rename failed — live config untouched."; exit 2
  fi
  esm_log "HEALED: re-registered sentry MCP in $ESM_CFG from $ESM_SECRETS."
  exit 0
  )
}

# Executed directly (not sourced)?
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  ensure_sentry_mcp_main "${1:-converge}"
  exit $?
fi
