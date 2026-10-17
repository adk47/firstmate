#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# codex-judge-exec.sh — ONE tool-less Codex model call on the ChatGPT
# subscription, for the credit-trust judge (scripts/credit_trust/llm.py).
#
# Reads the prompt on STDIN, runs the vendored `codex exec --json` against a
# throwaway CODEX_HOME seeded with ONE account's ACCESS token, and prints the
# JSONL event stream on stdout. Logs go to stderr. A JSON metadata file
# (--meta-out) records the argv, account, codex version, tool-item census and
# the credential-safety verdict, so the caller can audit every call.
#
# WHY NOT AN OPENCLAW AGENT TURN: the judge reads attacker-controlled input
# (claim titles, profile names, web pages, user documents). An agent turn has
# `exec`; a prompt injection there is a shell. This is a direct model call with
# the shell tool and every other tool feature OFF, a read-only sandbox, an empty
# working dir, no user config and no rules.
# The tool census below CHECKS that rather than asserting it, on the session
# ROLLOUT (not the --json summary): any tool call other than a web search that
# was not refused fails the call (rc 4), and the caller discards its answer.
#
# NOT --ephemeral, on purpose (T01 spike, 2026-10-15, codex-cli 0.156.1): with
# gpt-6-sol/-luna and gpt-5.6-sol, codex routes tools through Code Mode — the
# model calls a JS `exec` tool (`tools.web__run(...)`). Those calls appear ONLY
# in the rollout under CODEX_HOME/sessions; the --json event stream showed just
# the final message. --ephemeral would delete the one record that proves no tool
# ran. The rollout lives in the tmpfs scratch home and is shredded with it.
# Code Mode's host binary is not installed and `code_mode_host` is disabled
# below, so those attempts fail closed ("code-mode host is disabled") — which
# also means headless web search is NOT available on this CLI; see
# docs/credit-verification/credit-trust-llm.md.
#
# CREDENTIAL SAFETY — the codex-quota-probe.sh pattern, reused, not re-written:
#   * auth.json is built by whitelist jq with the SYNC-MANAGED-NO-REFRESH-TOKEN
#     sentinel in the refresh slot. The real refresh token is never read except
#     for the post-run leak check, and never written anywhere.
#   * accounts whose token expires inside CODEX_PROBE_MIN_TOKEN_MIN are skipped
#     (no pre-expiry refresh path is ever entered);
#   * scratch on tmpfs (/run/hydra), basename-guarded, shredded on every exit;
#   * after the run: auth.json must still carry the sentinel and the same
#     access token, and the real refresh token must appear nowhere in the
#     scratch tree — otherwise rc 9 (SAFETY VIOLATION), never squashed.
#   * the model process runs as the unprivileged CODEX_JUDGE_USER (hydra-judge,
#     created by deploy.sh), with a scrubbed environment. Running it as root is
#     refused.
#
# QUOTA GUARD: reads the MEASURED row codex-quota-refresh.sh writes for the
# active account. `unknown` (never measured / stale / lapsed) or a live load
# above CREDIT_TRUST_CODEX_MAX_LOAD_PCT (80) → rc 3, no call. This script never
# rotates accounts and never touches the active-account state file.
#
# Usage:
#   codex-judge-exec.sh --schema <file.json> [--model <id>] [--web|--no-web]
#       [--image <file>]... [--timeout <s>] [--meta-out <file>]
#       [--keep-session <dir>]   # debug: copy the rollout out before shredding
#       [--print-argv]           # print the codex argv (one per line) and exit 0
#   prompt on STDIN.
#
# Exit: 0 ok · 1 codex failed / timed out / no final message · 2 misuse or
#       preflight · 3 skipped (quota unknown/high, token near expiry, kill
#       switch) · 4 tool violation (a non-web tool ran; answer must be dropped)
#       · 9 SAFETY VIOLATION (credential rewritten or leaked).
# ──────────────────────────────────────────────────────────────
set -uo pipefail
umask 077

CJE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# codex-quota-probe.sh is sourced for cqp_resolve_binary, the sentinel, the
# PLUGIN_ROOT/auth-store selection and (through it) codex-quota.sh +
# codex-auth-store.sh. Sourcing never runs its main.
# shellcheck source=codex-quota-probe.sh
. "$CJE_DIR/codex-quota-probe.sh"

CODEX_JUDGE_USER="${CODEX_JUDGE_USER:-hydra-judge}"
# Our own tmpfs root (0711), NOT /run/hydra: the quota probe chmods that 0700
# on every run, and the judge user must be able to traverse to its scratch.
CODEX_JUDGE_SCRATCH_ROOT="${CODEX_JUDGE_SCRATCH_ROOT:-/run/hydra-judge}"
# /root is 0700, so the judge user cannot exec the vendored binary in place.
# A root-owned, read-only copy of the vendor tree is staged here once per codex
# version (keyed on the binary's size+mtime) and older copies are removed.
CODEX_JUDGE_BIN_CACHE="${CODEX_JUDGE_BIN_CACHE:-/var/lib/hydra-judge/codex}"
CODEX_JUDGE_DISABLED_FLAG="${CODEX_JUDGE_DISABLED_FLAG:-/etc/hydra/credit-trust-codex.disabled}"
CODEX_ACTIVE_ACCOUNT_FILE="${CODEX_ACTIVE_ACCOUNT_FILE:-/var/lib/hydra/codex-active-account}"
CODEX_USAGE_ARCHIVE_DIR="${CODEX_USAGE_ARCHIVE_DIR:-/var/lib/hydra/codex-usage}"
CREDIT_TRUST_CODEX_MAX_LOAD_PCT="${CREDIT_TRUST_CODEX_MAX_LOAD_PCT:-80}"
CREDIT_TRUST_CODEX_MODEL="${CREDIT_TRUST_CODEX_MODEL:-gpt-6.1-sol}"
# How web search is switched on for `codex exec` 0.156.1, which has no
# --search flag. Verified in the T01 spike (see docs/credit-verification/
# credit-trust-llm.md); override if a codex bump renames the key.
CODEX_JUDGE_WEB_CONFIG="${CODEX_JUDGE_WEB_CONFIG:-web_search=\"live\"}"

# Every tool-bearing feature codex 0.156.1 ships enabled by default. Disabling
# a feature the binary does not know is a warning, not an error, so the list
# can only over-disable. shell_tool is the load-bearing one and is asserted by
# the Python tests; the rest close the browser/computer/MCP/app/agent surfaces.
CODEX_JUDGE_DISABLE_FEATURES=(
  shell_tool unified_exec unified_exec_tty shell_snapshot apps plugins remote_plugin
  browser_use browser_use_external browser_use_full_cdp_access in_app_browser
  computer_use image_generation multi_agent hooks skill_search
  skill_mcp_dependency_install sleep_tool tool_suggest view_image goals
  code_mode_host workspace_dependencies tool_call_mcp_elicitation
  realtime_conversation worktrees
)

# Rollout response items that are allowed. A tool call of any other type
# (custom_tool_call / function_call / local_shell_call / …) is a violation
# unless its output is one of the refusal strings below — a call the runtime
# refused never ran. Anything else fails closed with rc 4.
CODEX_JUDGE_ALLOWED_ITEMS='["message","reasoning","web_search_call"]'
CODEX_JUDGE_REFUSALS='["code-mode host is disabled"]'

CJE_LOGPREFIX="[codex-judge-exec $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
cje_log() { echo "$CJE_LOGPREFIX $*" >&2; }

CJE_SCRATCH=""

_cje_assert_safe_scratch() {
  local p="$1"
  case "$p" in /*) : ;; *) cje_log "FATAL: scratch must be absolute (got '$p')"; return 2 ;; esac
  case "$(basename "$p")" in
    codex-judge-exec.*) : ;;
    *) cje_log "FATAL: refusing '$p' — basename must start with 'codex-judge-exec.' (this path is rm -rf'd)"; return 2 ;;
  esac
  case "${p#/}" in */*) : ;; *) cje_log "FATAL: refusing top-level scratch '$p'"; return 2 ;; esac
  if [ -L "$p" ]; then cje_log "FATAL: '$p' is a symlink — refusing"; return 2; fi
  return 0
}

_cje_cleanup() {
  local p="$CJE_SCRATCH"
  [ -n "$p" ] || return 0
  CJE_SCRATCH=""
  _cje_assert_safe_scratch "$p" || return 0
  [ -f "$p/home/auth.json" ] && { shred -u "$p/home/auth.json" 2>/dev/null || rm -f "$p/home/auth.json"; }
  rm -rf "$p" 2>/dev/null
}
trap _cje_cleanup EXIT
trap '_cje_cleanup; exit 130' INT
trap '_cje_cleanup; exit 143' TERM

# cje_active_key — the account the fleet runs on (the deploy-proof state file),
# validated against the canonical store. Never the default when the file is
# unreadable: an account we cannot name is an account we cannot quota-check.
cje_active_key() {
  local key listed
  [ -r "$CODEX_ACTIVE_ACCOUNT_FILE" ] || return 1
  key="$(head -n1 "$CODEX_ACTIVE_ACCOUNT_FILE" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$key" ] || return 1
  key="$(cqp_normalize_key "$key")"
  listed="$(cqp_list_accounts)" || return 1
  printf '%s\n' "$listed" | grep -qxF "$key" || return 1
  printf '%s' "$key"
}

# cje_quota_gate <key> — echo "<state> <load>"; rc 0 when the call may go.
cje_quota_gate() {
  local key="$1" row state load
  row="$(cq_measure_read "$CODEX_USAGE_ARCHIVE_DIR" "$key" 2>/dev/null)" || row=""
  state="$(cq_row_state "$row" 100)"
  load="$(cq_row_load "$row" 2>/dev/null)" || load="-"
  printf '%s %s' "$state" "$load"
  [ "$state" != unknown ] || return 1
  awk -v p="$load" -v m="$CREDIT_TRUST_CODEX_MAX_LOAD_PCT" 'BEGIN{exit !(p+0 <= m+0)}'
}

# cje_build_argv <home> <work> <schema> <model> <web 0|1> <out> [images...]
# Fills the global CJE_ARGV. Pure — the tests and --print-argv read it.
cje_build_argv() {
  local home="$1" work="$2" schema="$3" model="$4" web="$5" out="$6"; shift 6
  local f img
  # Images FIRST: `-i <FILE>...` is multi-valued and would swallow a following
  # positional (the trailing `-`), so it must be followed by a flag.
  CJE_ARGV=(exec)
  for img in "$@"; do CJE_ARGV+=(-i "$img"); done
  CJE_ARGV+=(--json --output-schema "$schema" -s read-only
            --ignore-user-config --ignore-rules --skip-git-repo-check
            -C "$work" -m "$model" -o "$out"
            -c 'approval_policy="never"' -c 'project_doc_max_bytes=0'
            -c 'mcp_servers={}' -c 'history.persistence="none"')
  for f in "${CODEX_JUDGE_DISABLE_FEATURES[@]}"; do CJE_ARGV+=(--disable "$f"); done
  if [ "$web" = 1 ]; then
    local -a webcfg=()
    IFS=';' read -r -a webcfg <<<"$CODEX_JUDGE_WEB_CONFIG"
    for f in "${webcfg[@]}"; do [ -n "$f" ] && CJE_ARGV+=(-c "$f"); done
  else
    CJE_ARGV+=(-c 'web_search="disabled"')
  fi
  CJE_ARGV+=(-)   # prompt from stdin, never argv (/proc/<pid>/cmdline is world-readable)
  : "$home"
}

# cje_tool_census <sessions-dir> — echo
#   {"types":{type:n},"blocked":[name...],"violations":[...],"web_queries":[...]}
# from the rollout file(s). No rollout = nothing proves the call was tool-less,
# so that is itself a violation.
cje_tool_census() {
  local dir="$1" files
  files="$(find "$dir" -type f -name 'rollout-*.jsonl' 2>/dev/null)"
  if [ -z "$files" ]; then
    printf '{"types":{},"blocked":[],"violations":["no_rollout"],"web_queries":[]}'
    return 0
  fi
  # shellcheck disable=SC2086 # one rollout per call; paths are mktemp-generated
  jq -cs --argjson allowed "$CODEX_JUDGE_ALLOWED_ITEMS" --argjson refusals "$CODEX_JUDGE_REFUSALS" '
    [ .[] | select(type == "object" and .type == "response_item") | .payload | select(type == "object") ] as $items
    | ( [ $items[] | select((.type // "") | endswith("_output")) | {key: (.call_id // ""), value: ((.output // "") | tostring)} ]
        | from_entries ) as $out
    | [ $items[] | select(((.type // "") | endswith("_output")) | not) ] as $calls
    | [ $calls[] | select(. as $c | $allowed | index($c.type // "") | not) ] as $tools
    | { types: ($calls | group_by(.type // "unknown") | map({((.[0].type) // "unknown"): length}) | add // {}),
        blocked: [ $tools[] | select(($out[.call_id // ""] // null) as $o | $o != null and ($refusals | index($o))) | (.name // .type) ],
        violations: ([ $tools[] | select(($out[.call_id // ""] // null) as $o | $o == null or (($refusals | index($o)) | not)) | (.name // .type) ] | unique),
        web_queries: [ $calls[] | select(.type == "web_search_call") | (.action.query // .action.queries // null) | select(. != null) ] }
  ' $files 2>/dev/null || printf '{"types":{},"blocked":[],"violations":["unparseable_rollout"],"web_queries":[]}'
}

# cje_stage_binary <vendored-bin> — echo the path the judge user executes.
# Non-root callers (dev, tests) run the binary in place.
cje_stage_binary() {
  local bin="$1" vendor key dest tmp old
  if [ "$(id -u)" -ne 0 ]; then printf '%s' "$bin"; return 0; fi
  vendor="$(dirname "$(dirname "$bin")")"
  key="$(stat -c '%s-%Y' "$bin" 2>/dev/null)" || return 1
  dest="$CODEX_JUDGE_BIN_CACHE/$key"
  if [ ! -x "$dest/bin/codex" ]; then
    install -d -m 755 "$CODEX_JUDGE_BIN_CACHE" || return 1
    tmp="$CODEX_JUDGE_BIN_CACHE/.stage.$$"
    rm -rf "$tmp"
    if ! { cp -a "$vendor" "$tmp" && chown -R root:root "$tmp" && chmod -R go-w "$tmp" && chmod 755 "$tmp"; }; then
      rm -rf "$tmp"; return 1
    fi
    # A concurrent call may have staged the same key first; that copy is as good.
    mv -T "$tmp" "$dest" 2>/dev/null || { rm -rf "$tmp"; [ -x "$dest/bin/codex" ] || return 1; }
    cmp -s "$bin" "$dest/bin/codex" || { cje_log "FATAL: staged codex differs from $bin"; rm -rf "$dest"; return 1; }
    for old in "$CODEX_JUDGE_BIN_CACHE"/*; do
      [ -d "$old" ] && [ "$old" != "$dest" ] && rm -rf "$old"
    done
  fi
  printf '%s' "$dest/bin/codex"
}

# cje_run_as <user> <cmd...> — drop to the unprivileged judge user with a
# scrubbed environment. Refuses to run the model as root.
cje_run_as() {
  local user="$1"; shift
  if [ "$(id -u)" -eq 0 ]; then
    id "$user" >/dev/null 2>&1 || { cje_log "FATAL: judge user '$user' does not exist (deploy.sh creates hydra-judge)"; return 2; }
    [ "$(id -u "$user")" -ne 0 ] || { cje_log "FATAL: judge user '$user' is root — refusing"; return 2; }
    if command -v setpriv >/dev/null 2>&1; then
      setpriv --reuid="$(id -u "$user")" --regid="$(id -g "$user")" --clear-groups -- "$@"
    else
      runuser -u "$user" -- "$@"
    fi
  else
    "$@"
  fi
}

cje_main() {
  local schema="" model="$CREDIT_TRUST_CODEX_MODEL" web=1 timeout_s=90 meta_out="" keep="" print_argv=0
  local -a images=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --schema) schema="${2:-}"; shift ;;
      --model) model="${2:-}"; shift ;;
      --web) web=1 ;;
      --no-web) web=0 ;;
      --image) images+=("${2:-}"); shift ;;
      --timeout) timeout_s="${2:-}"; shift ;;
      --meta-out) meta_out="${2:-}"; shift ;;
      --keep-session) keep="${2:-}"; shift ;;
      --print-argv) print_argv=1 ;;
      -h|--help) sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) cje_log "unknown argument: $1"; return 2 ;;
    esac
    shift
  done
  [[ "$timeout_s" =~ ^[0-9]+$ ]] && [ "$timeout_s" -gt 0 ] || { cje_log "--timeout must be a positive integer"; return 2; }
  [[ "$model" =~ ^[A-Za-z0-9._:-]+$ ]] || { cje_log "invalid --model"; return 2; }

  if [ "$print_argv" = 1 ]; then
    cje_build_argv /HOME /WORK "${schema:-/SCHEMA}" "$model" "$web" /OUT "${images[@]}"
    printf '%s\n' "${CJE_ARGV[@]}"
    return 0
  fi

  [ -n "$schema" ] && [ -r "$schema" ] || { cje_log "--schema <file> is required and must be readable"; return 2; }
  jq -e 'type == "object"' "$schema" >/dev/null 2>&1 || { cje_log "schema is not a JSON object"; return 2; }
  local img
  for img in "${images[@]}"; do [ -r "$img" ] && [ -f "$img" ] || { cje_log "image not readable: $img"; return 2; }; done

  if [ -e "$CODEX_JUDGE_DISABLED_FLAG" ]; then cje_log "kill switch present ($CODEX_JUDGE_DISABLED_FLAG) — skipping codex"; return 3; fi
  if [ -e "$CODEX_PROBE_DISABLED_FLAG" ]; then
    cje_log "quota probe kill switch present ($CODEX_PROBE_DISABLED_FLAG) — quota is unknown fleet-wide; skipping codex"; return 3
  fi
  command -v jq >/dev/null 2>&1 || { cje_log "FATAL: jq not found"; return 2; }
  cas_store_available "$CQP_AUTH_PROFILE" || { cje_log "FATAL: canonical auth store unavailable"; return 2; }

  local key gate
  key="$(cje_active_key)" || { cje_log "skip: active codex account unknown (no readable $CODEX_ACTIVE_ACCOUNT_FILE naming a canonical profile)"; return 3; }
  gate="$(cje_quota_gate "$key")" || {
    cje_log "provider_skipped=codex reason=quota account=$key state/load=$gate (max ${CREDIT_TRUST_CODEX_MAX_LOAD_PCT}%)"; return 3; }

  local access account expires now_ms min_exp_ms
  access="$(cas_profile_field "$CQP_AUTH_PROFILE" "$key" access)" || { cje_log "FATAL: auth store unreadable"; return 2; }
  account="$(cas_profile_field "$CQP_AUTH_PROFILE" "$key" accountId)" || { cje_log "FATAL: auth store unreadable"; return 2; }
  expires="$(cas_profile_field "$CQP_AUTH_PROFILE" "$key" expires)" || { cje_log "FATAL: auth store unreadable"; return 2; }
  [ -n "$access" ] || { cje_log "skip: no access token for $key"; return 3; }
  [[ "$expires" =~ ^[0-9]+$ ]] || expires=0
  now_ms=$(( $(date +%s) * 1000 ))
  min_exp_ms=$(( now_ms + CODEX_PROBE_MIN_TOKEN_MIN * 60 * 1000 ))
  if [ "$expires" -le "$min_exp_ms" ]; then
    cje_log "skip: $key token expires within ${CODEX_PROBE_MIN_TOKEN_MIN}min (single-refresher invariant)"; return 3
  fi

  local bin version
  bin="$(cqp_resolve_binary)" || { cje_log "FATAL: no vendored codex binary under $PLUGIN_ROOT"; return 2; }
  version="$("$bin" --version 2>/dev/null | head -n1)"
  bin="$(cje_stage_binary "$bin")" || { cje_log "FATAL: could not stage the codex binary for the judge user"; return 2; }

  local sc=""
  mkdir -p "$CODEX_JUDGE_SCRATCH_ROOT" 2>/dev/null && chmod 711 "$CODEX_JUDGE_SCRATCH_ROOT" 2>/dev/null
  # mktemp-ok: handed to CJE_SCRATCH, removed by the _cje_cleanup EXIT/INT/TERM traps
  [ -d "$CODEX_JUDGE_SCRATCH_ROOT" ] && [ -w "$CODEX_JUDGE_SCRATCH_ROOT" ] && \
    sc="$(mktemp -d "$CODEX_JUDGE_SCRATCH_ROOT/codex-judge-exec.XXXXXX" 2>/dev/null)"
  # mktemp-ok: same CJE_SCRATCH hand-off
  [ -n "$sc" ] || sc="$(mktemp -d "${TMPDIR:-/tmp}/codex-judge-exec.XXXXXX" 2>/dev/null)" || { cje_log "FATAL: no scratch"; return 2; }
  _cje_assert_safe_scratch "$sc" || { rm -rf "$sc" 2>/dev/null; return 2; }
  CJE_SCRATCH="$sc"
  # Re-armed here for the same reason as codex-quota-probe.sh: callers may run
  # this in a subshell, which gets its own CJE_SCRATCH.
  trap _cje_cleanup EXIT
  trap '_cje_cleanup; exit 130' INT
  trap '_cje_cleanup; exit 143' TERM
  mkdir -p "$sc/home" "$sc/work" "$sc/in"

  if ! CJE_ACCESS="$access" jq -n --arg account "$account" --arg sentinel "$CQP_SENTINEL_REFRESH" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '(env.CJE_ACCESS) as $access
         | {auth_mode: "chatgpt", OPENAI_API_KEY: null,
            tokens: {id_token: $access, access_token: $access, refresh_token: $sentinel, account_id: $account},
            last_refresh: $now}' > "$sc/home/auth.json" 2>/dev/null; then
    cje_log "FATAL: could not write scratch auth.json"; _cje_cleanup; return 2
  fi
  chmod 600 "$sc/home/auth.json"
  cp "$schema" "$sc/in/schema.json"
  local -a in_images=()
  local i=0
  for img in "${images[@]}"; do
    i=$((i + 1)); cp "$img" "$sc/in/image-$i.${img##*.}"; in_images+=("$sc/in/image-$i.${img##*.}")
  done
  # The prompt never touches argv; it is staged in the scratch dir and fed on stdin.
  cat > "$sc/in/prompt.txt"
  if [ "$(id -u)" -eq 0 ]; then
    id "$CODEX_JUDGE_USER" >/dev/null 2>&1 || { cje_log "FATAL: judge user '$CODEX_JUDGE_USER' does not exist (deploy.sh creates hydra-judge)"; _cje_cleanup; return 2; }
    chown -R "$CODEX_JUDGE_USER": "$sc"
  fi
  chmod 700 "$sc"

  cje_build_argv "$sc/home" "$sc/work" "$sc/in/schema.json" "$model" "$web" "$sc/out-last.txt" "${in_images[@]}"
  local t0 t1 rc=0 timed_out=false
  t0=$(date +%s%3N 2>/dev/null || echo $(( $(date +%s) * 1000 )))
  cje_run_as "$CODEX_JUDGE_USER" env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$sc/home" \
      CODEX_HOME="$sc/home" LANG=C.UTF-8 \
      timeout -k 5 "$timeout_s" "$bin" "${CJE_ARGV[@]}" < "$sc/in/prompt.txt" > "$sc/events.jsonl" 2> "$sc/stderr.txt" || rc=$?
  t1=$(date +%s%3N 2>/dev/null || echo $(( $(date +%s) * 1000 )))
  [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] && timed_out=true

  # ── credential verification BEFORE anything is reported (rc 9 is never squashed) ──
  local cur_refresh cur_access real_refresh safety=ok
  cur_refresh="$(jq -r '.tokens.refresh_token // empty' "$sc/home/auth.json" 2>/dev/null)"
  cur_access="$(jq -r '.tokens.access_token // empty' "$sc/home/auth.json" 2>/dev/null)"
  if [ "$cur_refresh" != "$CQP_SENTINEL_REFRESH" ] || [ "$cur_access" != "$access" ]; then
    safety="credential_rewritten"
  else
    real_refresh="$(cas_profile_field "$CQP_AUTH_PROFILE" "$key" refresh)" || safety="store_unreadable_at_verify"
    if [ "$safety" = ok ] && [ -n "$real_refresh" ] && [ "$real_refresh" != "$CQP_SENTINEL_REFRESH" ] \
       && printf '%s\n' "$real_refresh" | grep -raqFf - "$sc" 2>/dev/null; then
      safety="refresh_token_leaked"
    fi
  fi

  local census final_ok=false
  census="$(cje_tool_census "$sc/home/sessions")"
  [ -s "$sc/out-last.txt" ] && final_ok=true

  if [ -n "$keep" ] && [ "$safety" = ok ]; then
    mkdir -p "$keep" && find "$sc/home/sessions" -name '*.jsonl' -exec cp {} "$keep/" \; 2>/dev/null
    cp "$sc/stderr.txt" "$keep/codex-stderr.txt" 2>/dev/null
  fi

  local -a argv_meta=()
  local a
  for a in "${CJE_ARGV[@]}"; do argv_meta+=("${a//$sc/<scratch>}"); done
  if [ -n "$meta_out" ]; then
    jq -n --arg account "$key" --arg version "$version" --arg model "$model" --arg user "$CODEX_JUDGE_USER" \
      --argjson rc "$rc" --argjson timed_out "$timed_out" --argjson final_ok "$final_ok" \
      --arg safety "$safety" --argjson census "$census" --arg gate "$gate" \
      --argjson latency_ms "$(( t1 - t0 ))" \
      --argjson web "$( [ "$web" = 1 ] && echo true || echo false )" \
      --arg stderr_tail "$(tail -c 600 "$sc/stderr.txt" 2>/dev/null | tr -d '\000')" \
      --argjson argv "$(printf '%s\n' "${argv_meta[@]}" | jq -R . | jq -cs .)" \
      '{account:$account, codex_version:$version, model:$model, run_as:$user, rc:$rc,
        timed_out:$timed_out, final_message:$final_ok, safety:$safety, tool_census:$census,
        quota_gate:$gate, latency_ms:$latency_ms, web:$web,
        stderr_tail:$stderr_tail, argv:$argv}' > "$meta_out" 2>/dev/null \
      || cje_log "WARN: could not write --meta-out $meta_out"
  fi

  if [ "$safety" != ok ]; then
    cje_log "SAFETY VIOLATION ($safety) for $key — the refresh path was entered or a credential leaked. Refusing to report."
    # Same posture as codex-quota-refresh.sh on probe rc 9: stop every later
    # judge call until a human has understood why the credential moved.
    { mkdir -p "$(dirname "$CODEX_JUDGE_DISABLED_FLAG")" && \
      printf '%s codex-judge-exec SAFETY VIOLATION (%s) account=%s\n' "$(date -u +%FT%TZ)" "$safety" "$key" \
        > "$CODEX_JUDGE_DISABLED_FLAG"; } 2>/dev/null || cje_log "WARN: could not write $CODEX_JUDGE_DISABLED_FLAG"
    _cje_cleanup; return 9
  fi
  cat "$sc/events.jsonl"
  local violations
  violations="$(printf '%s' "$census" | jq -r '.violations | join(",")')"
  if [ -n "$violations" ]; then
    cje_log "TOOL VIOLATION: the rollout shows a tool that ran: $violations — answer must be discarded"
    _cje_cleanup; return 4
  fi
  if [ "$rc" -ne 0 ] || [ "$final_ok" != true ]; then
    cje_log "codex exec failed rc=$rc timed_out=$timed_out: $(tail -c 300 "$sc/stderr.txt" 2>/dev/null | tr '\n' ' ')"
    _cje_cleanup; return 1
  fi
  _cje_cleanup
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cje_main "$@"
  exit $?
fi
