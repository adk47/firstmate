#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# codex-quota-probe.sh — MEASURE a codex account's real quota.
#
# Runs the vendored `codex app-server` against a throwaway CODEX_HOME seeded
# with ONE account's access token and calls the JSON-RPC method
#   account/rateLimits/read
# which asks the Codex backend for that account's current rate limits without
# sending a model turn. Echoes one measurement row (see codex-quota.sh).
#
# WHY THIS EXISTS (incident 2026-08-05/06): hydra had no way to see a STANDBY
# account's quota. Rollouts carry no account identity on 7.x, so the standby
# number was inferred from whichever snapshot was freshest fleet-wide — which
# produced two accounts sharing a reset epoch to the second and a page claiming
# "every alternate account is known-capped" while two Pro subscriptions sat at
# 4% and 0%. This script replaces that inference with a measurement.
#
# METHOD NAME: it is `account/rateLimits/read`, NOT `account/rateLimits`.
# Verified live on codex-cli 0.144.3 — the bare name is rejected and the server
# helpfully enumerates the valid set. Re-verify on every codex bump.
#
# ── SAFETY ───────────────────────────────────────────────────────────────────
# Doctrine (CLAUDE.md): NEVER copy, seed, or fan-out codex credentials. OpenAI
# uses single-use ROTATING refresh tokens under a per-profile lock; a second
# independent holder that refreshes invalidates the chain and kills every codex
# agent at once (incidents 2026-05-29, 2026-06-08). This probe is safe not
# because it promises not to refresh but because it is STRUCTURALLY INCAPABLE
# of it. Five layers, in the order they fire:
#
#   1. The scratch store never contains a refresh token. auth.json is built by
#      whitelist `jq -n` (never copied from canonical) with the SAME sentinel
#      string codex-auth-sync.sh writes into every agent's codex-home. The
#      scratch home is therefore byte-shaped exactly like a per-agent store the
#      fleet already runs safely. If app-server tries to refresh, it POSTs the
#      sentinel, gets invalid_grant, and NOTHING rotates.
#   2. Never probe a token that could need refreshing. Accounts whose canonical
#      expiry is inside CODEX_PROBE_MIN_TOKEN_MIN are SKIPPED, so app-server's
#      pre-expiry refresh path is never entered in the first place.
#   3. The scratch path is guarded before anything is written — absolute, our
#      own basename, depth > 1, not a symlink. This script runs as root and
#      rm -rf's that path. Lifted from codex-reauth.sh's _assert_safe_scratch;
#      the basename marker is the load-bearing guard.
#   4. tmpfs. The default root is /run/hydra, so an access token never reaches
#      a disk block or a backup, and a hard reboot clears it regardless.
#   5. Destroy on EVERY exit path (trap), and verify BEFORE destroying:
#        (a) auth.json still carries the sentinel and the same access token —
#            a rewrite proves the refresh path was entered, which is a loud
#            failure, not a warning;
#        (b) the account's REAL canonical refresh token appears nowhere in the
#            scratch tree. It cannot — we never read it — but this is the
#            checked version of that claim rather than the asserted one.
#
# Usage:
#   codex-quota-probe.sh --account <profile-key|email>   # one account
#   codex-quota-probe.sh --all                           # every codex account
#   codex-quota-probe.sh --all --json                    # JSON instead of TSV
#
# Exit: 0 ok (rows on stdout) · 1 nothing measured · 2 misuse/preflight failure
#       9 SAFETY VIOLATION (scratch tampering or credential leak) — never
#         squash this one; it means the invariant above did not hold.
# ──────────────────────────────────────────────────────────────
set -uo pipefail
umask 077

CQP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=codex-quota.sh
. "$CQP_DIR/codex-quota.sh"
# shellcheck source=codex-auth-store.sh
. "$CQP_DIR/codex-auth-store.sh"

CQP_AUTH_STORE_EXPLICIT=0
[ "${CODEX_AUTH_STORE+x}" = x ] && CQP_AUTH_STORE_EXPLICIT=1
CANON="${CODEX_AUTH_STORE:-/root/.openclaw-main/agents/main/agent/auth-profiles.json}"
CQP_AUTH_PROFILE="${CQP_AUTH_PROFILE:-main}"
if [ "$CQP_AUTH_STORE_EXPLICIT" -eq 1 ]; then
  # shellcheck disable=SC2034 # Read by the sourced codex-auth-store helpers.
  CAS_LEGACY_JSON="$CANON"
fi
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-/root/.openclaw-main/npm/projects}"
# MUST match codex-auth-sync.sh:87 byte for byte. scripts/tests/codex-quota-probe.bats
# asserts that with a drift sentinel — if one file changes alone, CI fails.
CQP_SENTINEL_REFRESH="SYNC-MANAGED-NO-REFRESH-TOKEN"
# tmpfs by preference; mktemp's default (a real disk) only as a fallback for
# bats hosts that have no /run.
CODEX_PROBE_SCRATCH_ROOT="${CODEX_PROBE_SCRATCH_ROOT:-/run/hydra}"
# Layer 2: refuse to probe a token whose expiry is close enough that app-server
# might try to renew it. Deliberately far looser than codex-account-rotate.sh's
# 10-minute floor — a rotation must proceed, a measurement can always wait.
CODEX_PROBE_MIN_TOKEN_MIN="${CODEX_PROBE_MIN_TOKEN_MIN:-60}"
CODEX_PROBE_TIMEOUT="${CODEX_PROBE_TIMEOUT:-30}"
CODEX_PROBE_DISABLED_FLAG="${CODEX_PROBE_DISABLED_FLAG:-/etc/hydra/codex-quota-probe.disabled}"

CQP_LOGPREFIX="[codex-quota-probe $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
cqp_log() { echo "$CQP_LOGPREFIX $*" >&2; }

CQP_SCRATCH=""

# Layer 3 — refuse any scratch path we do not own. Runs BEFORE the first write
# and AGAIN at destroy time, because the env could not change but a symlink could.
_cqp_assert_safe_scratch() {
  local p="$1"
  case "$p" in
    /*) : ;;
    *)  cqp_log "FATAL: scratch must be an absolute path (got '$p')"; return 2 ;;
  esac
  case "$(basename "$p")" in
    codex-quota-probe*) : ;;
    *) cqp_log "FATAL: refusing '$p' — basename must start with 'codex-quota-probe' (this path is rm -rf'd as root)"; return 2 ;;
  esac
  case "${p#/}" in
    */*) : ;;
    *) cqp_log "FATAL: refusing top-level scratch path '$p'"; return 2 ;;
  esac
  if [ -L "$p" ]; then
    cqp_log "FATAL: '$p' is a symlink — refusing (cleanup would shred the target)"
    return 2
  fi
  return 0
}

# Layer 5 — shred + remove on every exit path.
_cqp_cleanup() {
  local p="$CQP_SCRATCH"
  [ -n "$p" ] || return 0
  CQP_SCRATCH=""
  _cqp_assert_safe_scratch "$p" || return 0
  [ -f "$p/auth.json" ] && { shred -u "$p/auth.json" 2>/dev/null || rm -f "$p/auth.json"; }
  rm -rf "$p" 2>/dev/null
}
# Signal handlers must TERMINATE, not just clean up. Bash resumes execution
# after an INT/TERM handler that merely returns — so a plain
# `trap _cqp_cleanup EXIT INT TERM` deletes auth.json and then falls straight
# into the post-probe verification below, which finds the credential gone,
# concludes it was rewritten, and returns rc 9. codex-quota-refresh.sh reacts to
# rc 9 by writing the persistent kill switch and paging a credential-rewrite
# alarm — so stopping a probe during a deploy or shutdown would FALSELY disable
# every later quota refresh until a human cleared the flag. Exit with the
# conventional 128+signo instead.
trap _cqp_cleanup EXIT
trap '_cqp_cleanup; exit 130' INT
trap '_cqp_cleanup; exit 143' TERM

# cqp_resolve_binary — newest vendored codex binary by mtime. A codex bump
# leaves the previous tree in place, so "first glob hit" would silently pin an
# old binary; same resolution shape as codex-reauth.sh.
#
# Avoid `find -printf '%T@'`: -printf is a GNU extension that BSD/macOS find
# does not support, and because the caller redirects stderr it fails SILENTLY
# there (empty output, rc 1) — which reads downstream as "no codex binary" and
# would take the whole measurement layer offline on a dev machine with no
# visible reason. Consume null-delimited paths directly, require an executable
# file, and retain the newest match.
cqp_resolve_binary() {
  local b="" candidate
  while IFS= read -r -d '' candidate; do
    [ -x "$candidate" ] || continue
    if [ -z "$b" ] || [ "$candidate" -nt "$b" ]; then b="$candidate"; fi
  done < <(find "$PLUGIN_ROOT" -type f \
    \( -path '*@openclaw/codex*' -o -path '*@openai/codex*' \) \
    -path '*vendor*' -name codex -print0 2>/dev/null)
  [ -n "$b" ] && [ -x "$b" ] || return 1
  printf '%s' "$b"
}

# cqp_preflight — fail LOUD if the subcommand we depend on is gone. A codex
# bump that renames `app-server` must page, not silently return "no data" that
# downstream reads as `unknown` forever.
cqp_preflight() {
  local bin="$1"
  "$bin" app-server --help >/dev/null 2>&1 || {
    cqp_log "FATAL: '$bin app-server' is not available — codex may have renamed the subcommand. Re-verify account/rateLimits/read on this codex version."
    return 2
  }
  return 0
}

# cqp_probe_account <profile-key> <binary>
# Echo ONE measurement row for the account, or nothing.
cqp_probe_account() {
  local key="$1" bin="$2"
  local access account expires now_ms min_exp_ms out row src sc
  access="$(cas_profile_field "$CQP_AUTH_PROFILE" "$key" access)" || {
    cqp_log "FATAL: canonical auth store became unreadable while reading $key"
    return 2
  }
  account="$(cas_profile_field "$CQP_AUTH_PROFILE" "$key" accountId)" || {
    cqp_log "FATAL: canonical auth store became unreadable while reading $key"
    return 2
  }
  if [ -z "$access" ]; then
    cqp_log "skip $key: no access token in canonical"
    return 1
  fi

  # Layer 2 — expiry margin.
  expires="$(cas_profile_field "$CQP_AUTH_PROFILE" "$key" expires)" || {
    cqp_log "FATAL: canonical auth store became unreadable while reading $key"
    return 2
  }
  [[ "$expires" =~ ^[0-9]+$ ]] || expires=0
  now_ms=$(( $(date +%s) * 1000 ))
  min_exp_ms=$(( now_ms + CODEX_PROBE_MIN_TOKEN_MIN * 60 * 1000 ))
  if [ "$expires" -le "$min_exp_ms" ]; then
    cqp_log "skip $key: token expires within ${CODEX_PROBE_MIN_TOKEN_MIN}min — probing could trigger a refresh (single-refresher invariant)"
    return 1
  fi

  # Layer 4 — scratch on tmpfs when available.
  mkdir -p "$CODEX_PROBE_SCRATCH_ROOT" 2>/dev/null && chmod 700 "$CODEX_PROBE_SCRATCH_ROOT" 2>/dev/null
  if [ -d "$CODEX_PROBE_SCRATCH_ROOT" ] && [ -w "$CODEX_PROBE_SCRATCH_ROOT" ]; then
    # mktemp-ok: handed to CQP_SCRATCH, removed by the _cqp_cleanup EXIT/INT/TERM traps armed below
    sc="$(mktemp -d "$CODEX_PROBE_SCRATCH_ROOT/codex-quota-probe.XXXXXX" 2>/dev/null)" || sc=""
  else
    sc=""
  fi
  # mktemp-ok: same CQP_SCRATCH hand-off as above
  [ -n "$sc" ] || sc="$(mktemp -d "${TMPDIR:-/tmp}/codex-quota-probe.XXXXXX" 2>/dev/null)" || {
    cqp_log "FATAL: cannot create scratch dir"; return 2; }

  _cqp_assert_safe_scratch "$sc" || { rm -rf "$sc" 2>/dev/null; return 2; }
  CQP_SCRATCH="$sc"
  # RE-ARM THE TRAP HERE, not just at file scope. Both callers invoke this
  # function inside a command substitution (`row="$(cqp_probe_account …)"`),
  # which runs it in a SUBSHELL — and a subshell gets its own copy of
  # CQP_SCRATCH, so the parent's file-scope trap fires with an empty value and
  # cleans up nothing. Proven: the parent's handler logs an empty path and the
  # scratch dir survives a SIGTERM delivered while `codex app-server` is
  # running. Every normal return path calls _cqp_cleanup explicitly, so only
  # SIGNALLED runs leaked — systemd stopping the unit, cron killing a slow
  # tick, an operator's Ctrl-C, a shutdown — each leaving one cleartext OAuth
  # access token in /run/hydra until reboot. Arming inside the subshell is what
  # makes Layer 5's "destroy on EVERY exit path" actually true.
  trap _cqp_cleanup EXIT
  trap '_cqp_cleanup; exit 130' INT
  trap '_cqp_cleanup; exit 143' TERM
  chmod 700 "$sc"

  # Keep the probe's own session history out of the fleet's rollout tree — and
  # out of anything cu_collect_rollouts could pick up.
  printf '%s\n' 'preferred_auth_method = "chatgpt"' > "$sc/config.toml"

  # Layer 1 — whitelist build, sentinel in the refresh slot. NEVER copy the
  # canonical object; only these fields ever leave it.
  #
  # The access token goes in via the ENVIRONMENT, never `--arg`. Anything in
  # argv lands in /proc/<pid>/cmdline, which is mode **444** on the deployed
  # hosts with no `hidepid` (verified on node-8), so any unprivileged local
  # process polling during the ~7s probe could read the token straight out of
  # jq's command line — defeating the 0700 tmpfs scratch entirely.
  # /proc/<pid>/environ is mode **400**, owner-only, and confirmed unreadable
  # by `nobody` on the same host. Only non-secret values stay in argv.
  if ! CQP_ACCESS="$access" jq -n --arg account "$account" \
             --arg sentinel "$CQP_SENTINEL_REFRESH" \
             --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '(env.CQP_ACCESS) as $access
         | {auth_mode: "chatgpt", OPENAI_API_KEY: null,
            tokens: {id_token: $access, access_token: $access,
                     refresh_token: $sentinel, account_id: $account},
            last_refresh: $now}' > "$sc/auth.json" 2>/dev/null; then
    cqp_log "FATAL: could not write scratch auth.json for $key"
    _cqp_cleanup; return 2
  fi
  chmod 600 "$sc/auth.json"

  out="$(
    {
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"hydra-quota-probe","title":"hydra","version":"1.0.0"}}}'
      sleep 1
      printf '%s\n' '{"jsonrpc":"2.0","method":"initialized"}'
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}'
      sleep 5
    } | ( cd "$sc" && CODEX_HOME="$sc" timeout "$CODEX_PROBE_TIMEOUT" "$bin" app-server 2>/dev/null )
  )" || true

  # ── Layer 5 verification, BEFORE destroying the evidence ──
  local cur_refresh cur_access
  cur_refresh="$(jq -r '.tokens.refresh_token // empty' "$sc/auth.json" 2>/dev/null)"
  cur_access="$(jq -r '.tokens.access_token // empty' "$sc/auth.json" 2>/dev/null)"
  if [ "$cur_refresh" != "$CQP_SENTINEL_REFRESH" ] || [ "$cur_access" != "$access" ]; then
    cqp_log "SAFETY VIOLATION: app-server REWROTE the scratch credential for $key — the refresh path was entered. Refusing to continue."
    _cqp_cleanup; return 9
  fi
  # (b) the real refresh token must appear nowhere in the scratch tree.
  local real_refresh
  real_refresh="$(cas_profile_field "$CQP_AUTH_PROFILE" "$key" refresh)" || {
    cqp_log "SAFETY VIOLATION: canonical auth store became unreadable while verifying the refresh-token boundary for $key"
    _cqp_cleanup; return 9
  }
  if [ -n "$real_refresh" ] && [ "$real_refresh" != "$CQP_SENTINEL_REFRESH" ]; then
    # Pattern via STDIN (`-f -`), not argv — same /proc/<pid>/cmdline exposure
    # as above, and it would be absurd for the check that proves the refresh
    # token did not leak to be the thing that leaks it.
    if printf '%s\n' "$real_refresh" | grep -raqFf - "$sc" 2>/dev/null; then
      cqp_log "SAFETY VIOLATION: the canonical refresh token for $key leaked into the scratch tree"
      _cqp_cleanup; return 9
    fi
  fi

  # An empty result from an EMPTY scratch home is itself the verdict: there was
  # no local cache to read, so no data means the RPC did not reach the backend.
  # Downstream keys off `source`, so both outcomes flow through the same code.
  src=probe-live
  row="$(printf '%s\n' "$out" | cq_parse_ratelimits "$src")"
  if [ -z "$row" ]; then
    cqp_log "no rate-limit result for $key (probe-empty: the RPC returned nothing measurable)"
    _cqp_cleanup
    return 1
  fi

  _cqp_cleanup
  printf '%s\n' "$row"
  return 0
}

# cqp_list_accounts — canonical codex profile keys, one per line.
cqp_list_accounts() {
  cas_list_canonical_keys "$CQP_AUTH_PROFILE"
}

# cqp_normalize_key <email-or-key>
cqp_normalize_key() {
  case "$1" in
    openai-codex:*) printf '%s' "$1" ;;
    *) printf 'openai-codex:%s' "$1" ;;
  esac
}

cqp_main() {
  local mode="" want="" json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --account) mode=one; want="${2:-}"; shift ;;
      --all)     mode=all ;;
      --json)    json=1 ;;
      -h|--help) sed -n '/^# Usage:/,/^# ─\{5,\}/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) cqp_log "unknown argument: $1"; return 2 ;;
    esac
    shift
  done
  [ -n "$mode" ] || { cqp_log "usage: --account <key|email> | --all"; return 2; }

  if [ -e "$CODEX_PROBE_DISABLED_FLAG" ]; then
    cqp_log "kill switch present ($CODEX_PROBE_DISABLED_FLAG) — not probing"
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { cqp_log "FATAL: jq not found"; return 2; }
  cas_store_available "$CQP_AUTH_PROFILE" || {
    cqp_log "FATAL: canonical auth store is missing, malformed, or unreadable"
    return 2
  }

  local bin
  bin="$(cqp_resolve_binary)" || { cqp_log "FATAL: no vendored codex binary under $PLUGIN_ROOT"; return 2; }
  cqp_preflight "$bin" || return 2

  local -a keys=()
  local listed
  if [ "$mode" = one ]; then
    keys=( "$(cqp_normalize_key "$want")" )
  else
    listed="$(cqp_list_accounts)" || {
      cqp_log "FATAL: canonical auth store became unreadable while listing accounts"
      return 2
    }
    while IFS= read -r k; do [ -n "$k" ] && keys+=("$k"); done <<< "$listed"
  fi
  [ "${#keys[@]}" -gt 0 ] || { cqp_log "no codex accounts in canonical"; return 1; }

  local key row rc any=0 out_json="[]"
  for key in "${keys[@]}"; do
    row="$(cqp_probe_account "$key" "$bin")"; rc=$?
    if [ "$rc" -eq 9 ]; then return 9; fi
    if [ "$rc" -eq 2 ]; then
      cqp_log "FATAL: canonical auth store became unreadable while probing $key"
      return 2
    fi
    [ "$rc" -eq 0 ] && [ -n "$row" ] || continue
    any=1
    if [ "$json" -eq 1 ]; then
      out_json="$(printf '%s' "$out_json" | jq -c --arg k "$key" --arg r "$row" '
        . + [ ($r | split("\t")) as $f | {
              account: $k, measured_at: ($f[0]|tonumber?),
              reached_type: $f[1],
              windows: ( [ {minutes: $f[2], used_percent: $f[3], resets_at: $f[4]},
                           {minutes: $f[5], used_percent: $f[6], resets_at: $f[7]} ]
                         | map(select(.minutes != "-")) ),
              source: $f[8], plan: $f[9] } ]')"
    else
      printf '%s\t%s\n' "$key" "$row"
    fi
  done

  [ "$json" -eq 1 ] && printf '%s\n' "$(printf '%s' "$out_json" | jq .)"
  [ "$any" -eq 1 ] || return 1
  return 0
}

# Only run when executed directly — this file is also sourced by the collector.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cqp_main "$@"
  exit $?
fi
