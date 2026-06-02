#!/usr/bin/env bash
# harvest.sh — read-only session harvester for the devops self-improvement loop.
#
# Reads an agent's OpenClaw session JSONLs that are newer than a watermark and
# emits a COMPACT JSON digest on stdout: per-session counts, tool histogram,
# shell commands run, user asks, the assistant's closing summary, and a coarse
# error signal. The downstream skill (skills-all/devops-self-improve/SKILL.md)
# feeds this digest to the agent, which distills durable lessons into MEMORY.md
# and proposes reference/ + skill PRs.
#
# This script is PURE READ — it never writes the watermark or any agent file.
# The skill advances the watermark itself (after a successful distill) using the
# `watermark_suggestion` field in this digest.
#
# Session JSONL shape (verified on node-8, OpenClaw 2026.5.27, 2026-06-02):
#   {"type":"message","message":{"role":"assistant"|"user"|"toolResult",
#     "content":[ {"type":"text","text":...}
#               | {"type":"toolCall","name":"bash"|"exec"|...,"arguments":{"command":...}}
#               | {"type":"toolResult",...} ]  | "<string>" }}
# The shell tool is named "bash" for codex agents and "exec" for native agents,
# so we match BOTH.
set -euo pipefail

AGENT="devops"
SESSIONS_ROOT="/root/.openclaw-main/agents"
DAYS_DEFAULT=7          # lookback when no watermark exists
MAX_SESSIONS=50         # cap files processed per run
MAX_CMDS=40             # cap shell commands captured per session
MAX_ASKS=12             # cap user asks captured per session
SINCE=""                # explicit epoch override

usage() {
  cat <<'EOF'
Usage: harvest.sh [--agent NAME] [--since EPOCH] [--days N]
                  [--sessions-root DIR] [--max-sessions N]

Emits a compact JSON digest of an agent's recent sessions on stdout. Read-only.

  --agent NAME        agent id (default: devops)
  --since EPOCH       only sessions with mtime > EPOCH (overrides watermark/--days)
  --days N            lookback window when no watermark file exists (default: 7)
  --sessions-root DIR root holding <agent>/sessions/ (default: /root/.openclaw-main/agents)
  --max-sessions N    cap on files processed, newest first (default: 50)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)         AGENT="$2"; shift 2 ;;
    --since)         SINCE="$2"; shift 2 ;;
    --days)          DAYS_DEFAULT="$2"; shift 2 ;;
    --sessions-root) SESSIONS_ROOT="$2"; shift 2 ;;
    --max-sessions)  MAX_SESSIONS="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "harvest.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "harvest.sh: jq not found" >&2; exit 3; }

sessions_dir="${SESSIONS_ROOT}/${AGENT}/sessions"
[[ -d "$sessions_dir" ]] || { echo "harvest.sh: no sessions dir: $sessions_dir" >&2; exit 4; }

# Workspace memory dir holds the watermark (rsync-excluded → persists across deploys).
watermark_file="/opt/hydra/workspaces/${AGENT}/memory/.self-improve-watermark"

# Resolve the effective "since" epoch: explicit --since > watermark file > --days.
now_epoch="$(date +%s)"
if [[ -n "$SINCE" ]]; then
  since_epoch="$SINCE"
elif [[ -r "$watermark_file" ]]; then
  since_epoch="$(tr -dc '0-9' < "$watermark_file")"
  [[ -n "$since_epoch" ]] || since_epoch=$(( now_epoch - DAYS_DEFAULT*86400 ))
else
  since_epoch=$(( now_epoch - DAYS_DEFAULT*86400 ))
fi

# Eligible files: non-trajectory .jsonl with mtime > since, as tab-separated
# "mtime<TAB>path" (so filenames with spaces don't break us), sorted OLDEST first.
#
# We then process only the oldest MAX_SESSIONS of them. This is deliberate: the
# skill advances the watermark to max(mtime) of the PROCESSED batch, so taking the
# oldest first means the watermark only moves past sessions we actually read. Any
# overflow beyond the cap stays eligible (mtime still > the new watermark) and is
# drained on the next run. Newest-first would jump the watermark past unread older
# sessions and silently lose them.
mapfile -t eligible < <(
  find "$sessions_dir" -maxdepth 1 -type f -name '*.jsonl' ! -name '*trajectory*' -printf '%T@\t%p\n' \
    | awk -F'\t' -v s="$since_epoch" '$1 > s' \
    | sort -n
)
eligible_count=${#eligible[@]}
files=()
if (( eligible_count > 0 )); then
  mapfile -t files < <(printf '%s\n' "${eligible[@]}" | head -n "$MAX_SESSIONS" | cut -f2-)
fi
capped=false
(( eligible_count > MAX_SESSIONS )) && capped=true

# Per-file compact digest. One JSON object per session on stdout.
emit_one() {
  local f="$1" mtime errhits
  mtime="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  # Coarse error signal: cheap grep over the raw transcript.
  errhits="$(grep -ciE 'error|failed|exit code [1-9]|traceback|denied|timeout' "$f" 2>/dev/null || true)"
  jq -s \
     --arg   file    "$f" \
     --argjson mtime  "$mtime" \
     --argjson errh   "${errhits:-0}" \
     --argjson maxcmd "$MAX_CMDS" \
     --argjson maxask "$MAX_ASKS" '
    def trunc($n): if type=="string" and (length > $n) then (.[0:$n] + "…") else . end;
    def blocks: (.message.content // empty) | if type=="array" then .[] else empty end;
    (map(select(.type=="message"))) as $msgs
    | ([ $msgs[] | blocks ]) as $b
    | ($b | map(select(.type=="toolCall"))) as $tc
    | {
        session_id:  ($file | sub(".*/";"") | sub("\\.jsonl$";"")),
        mtime:       $mtime,
        messages:    ($msgs | length),
        tool_calls:  ($tc | length),
        error_hits:  $errh,
        tools:       ($tc | group_by(.name) | map({ (.[0].name // "unknown"): length }) | add // {}),
        shell_commands: (
          $tc | map(select(.name=="bash" or .name=="exec"))
              | map((.arguments.command // .input.command // "") | trunc(220))
              | .[0:$maxcmd]
        ),
        user_asks: (
          $msgs | map(select(.message.role=="user"))
                | map(.message.content
                      | (if type=="array" then (map(select(.type=="text") | .text) | join(" ")) else . end)
                      | trunc(300))
                | map(select(. != "" and . != null))
                | .[0:$maxask]
        ),
        assistant_tail: (
          [ $msgs[] | select(.message.role=="assistant") | .message.content
            | (if type=="array" then (.[] | select(.type=="text") | .text) else . end) ]
          | (last // "") | trunc(600)
        )
      }
  ' "$f"
}

# Stream per-session objects, then wrap with run metadata via a slurp.
{
  for f in "${files[@]}"; do
    [[ -n "$f" ]] && emit_one "$f"
  done
} | jq -s \
      --arg   agent    "$AGENT" \
      --argjson since    "$since_epoch" \
      --argjson now      "$now_epoch" \
      --argjson eligible "$eligible_count" \
      --argjson capped   "$capped" '
  {
    agent: $agent,
    since_epoch: $since,
    generated_epoch: $now,
    eligible_count: $eligible,                # total sessions with mtime > watermark
    session_count: length,                    # processed this run (oldest first)
    capped: $capped,                          # true => more eligible than the cap
    backlog_remaining: ($eligible - length),  # left for the next run (0 = caught up)
    # Skill advances the watermark to this after a successful distill. Because we
    # process oldest-first, it only moves past sessions actually read; any backlog
    # stays eligible (mtime > watermark) and is drained on the next run.
    # Note: mtime is whole-second (stat %Y) while eligibility compares the finer find
    # mtime, so the single boundary session can be re-read ONCE next run. That is
    # intentional — a harmless re-read (the skill dedups memory) beats any chance of
    # skipping, which is the data-loss this oldest-first ordering exists to prevent.
    watermark_suggestion: ( (map(.mtime) | max) // $now ),
    sessions: ( sort_by(.mtime) | reverse )
  }
'
