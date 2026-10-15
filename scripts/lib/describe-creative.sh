#!/bin/bash
# ──────────────────────────────────────────────────────────────
# describe-creative.sh — one image URL (or a video's thumbnail URL) in, a short
# factual description on stdout. Jev is text-only, so the creative has to become
# text first; this helper does that and nothing else. It DESCRIBES, it never
# judges — approve/reject stays Jev's call so the suggestion is auditable.
# Humans on stderr only — stdout is the machine channel (same contract as jev.sh).
#
# Usage: describe-creative.sh <image-url>
#
# Key: OPENROUTER_API_KEY from the environment, else from ${JEV_ENV_FILE}
# (default /etc/hydra/jev.env) — the same file jev.sh reads; no new secret.
#
# SSRF boundary: only https URLs whose host is EXACTLY on the allowlist are
# fetched; redirects are never followed (a 3xx fails). Allowlist =
# DESCRIBE_CREATIVE_ALLOWED_HOSTS (comma-separated hostnames, no ports) from the
# environment, else from ${JEV_ENV_FILE} (non-secret config in the existing
# file). Unset = refuse everything. Callers pass Muso-hosted creative URLs only.
#
# Knobs (env):
#   DESCRIBE_CREATIVE_MODEL      default openai/gpt-5-mini
#   DESCRIBE_CREATIVE_TIMEOUT    seconds per HTTP call, default 30
#   DESCRIBE_CREATIVE_MAX_BYTES  image byte cap, default 5242880
#   DESCRIBE_CREATIVE_MAX_CHARS  description cap, default 1200
#
# Best-effort: any failure (no key, fetch/API error, timeout, oversized or
# non-image fetch, truncated or empty completion) prints NOTHING on stdout,
# WARNs on stderr and exits 1 — the caller screens with "creative could not be
# described" rather than a made-up description.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

: "${JEV_ENV_FILE:=/etc/hydra/jev.env}"
model="${DESCRIBE_CREATIVE_MODEL:-openai/gpt-5-mini}"
timeout_s="${DESCRIBE_CREATIVE_TIMEOUT:-30}"
max_bytes="${DESCRIBE_CREATIVE_MAX_BYTES:-5242880}"
max_chars="${DESCRIBE_CREATIVE_MAX_CHARS:-1200}"

fail() { echo "describe-creative: WARN: $*" >&2; exit 1; }

for v in "$timeout_s" "$max_bytes" "$max_chars"; do
  case "$v" in ''|*[!0-9]*|0*) fail "numeric knobs must be positive integers (got: $v)" ;; esac
done

url="${1:-}"
[ -n "$url" ] || fail "usage: describe-creative.sh <image-url>"

allowed="${DESCRIBE_CREATIVE_ALLOWED_HOSTS:-}"
if [ -z "$allowed" ] && [ -r "$JEV_ENV_FILE" ]; then
  allowed="$(grep -m1 '^DESCRIBE_CREATIVE_ALLOWED_HOSTS=' "$JEV_ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
fi
[ -n "$allowed" ] || fail "DESCRIBE_CREATIVE_ALLOWED_HOSTS is not set — refusing to fetch"

# https only; any char outside a conservative URL set (backslash, space, control,
# non-ASCII) is refused so no parser can disagree with curl about the host.
case "$url" in https://*) ;; *) fail "image URL must be https" ;; esac
case "$url" in *[!A-Za-z0-9._~:/?#@%\&=+,\;!*\'\(\)\[\]-]*) fail "image URL has disallowed characters" ;; esac
authority="${url#https://}"; authority="${authority%%[/?#]*}"
case "$authority" in *@*|*%*|*\[*|*:*) fail "image URL must be a bare host (no userinfo, port, IPv6 or escapes)" ;; esac
host="$(printf '%s' "$authority" | tr '[:upper:]' '[:lower:]')"
[ -n "$host" ] || fail "image URL has an empty host"
host_ok=0
IFS=',' read -r -a allowed_hosts <<<"$(printf '%s' "$allowed" | tr '[:upper:]' '[:lower:]')"
for h in "${allowed_hosts[@]}"; do
  [ -n "$h" ] && [ "$h" = "$host" ] && host_ok=1
done
[ "$host_ok" -eq 1 ] || fail "image host is not on the allowlist"

api_key="${OPENROUTER_API_KEY:-}"
if [ -z "$api_key" ] && [ -r "$JEV_ENV_FILE" ]; then
  api_key="$(grep -m1 '^OPENROUTER_API_KEY=' "$JEV_ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
fi
[ -n "$api_key" ] || fail "OPENROUTER_API_KEY is not set and not found in $JEV_ENV_FILE"

work="$(mktemp -d "${TMPDIR:-/tmp}/describe-creative.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Fetch the image ourselves so the byte cap is enforced and the model never
# fetches an arbitrary URL on our behalf.
meta="$(curl -sS --proto =https --max-time "$timeout_s" --max-filesize "$max_bytes" \
  -o "$work/img" -w '%{http_code} %{content_type}' "$url" 2>"$work/err")" \
  || fail "image fetch failed: $(head -c 200 "$work/err")"
code="${meta%% *}"; ctype="${meta#* }"; ctype="${ctype%%;*}"
case "$code" in 2??) ;; *) fail "image fetch returned HTTP $code" ;; esac
case "$ctype" in image/*) ;; *) fail "fetched content is not an image (got: $ctype)" ;; esac
size="$(wc -c <"$work/img" | tr -d '[:space:]')"
[ "$size" -gt 0 ] || fail "fetched image is empty"
[ "$size" -le "$max_bytes" ] || fail "image is $size bytes, over the $max_bytes cap"

prompt='Describe this advertising creative factually, in plain text, in at most a short paragraph. Report only what is visibly there: all text shown (quote it), imagery, logos and brands, people, and any claim, offer, price or call to action rendered in the image. Do not recommend, approve, reject, rate or judge it, and do not guess at anything you cannot see.'

{ printf 'data:%s;base64,' "$ctype"; base64 <"$work/img" | tr -d '\n'; } >"$work/dataurl"
jq -n --arg model "$model" --arg prompt "$prompt" --rawfile img "$work/dataurl" '{
  model: $model,
  max_completion_tokens: 2000,
  reasoning: {effort: "minimal"},
  messages: [{role: "user", content: [
    {type: "text", text: $prompt},
    {type: "image_url", image_url: {url: $img}}
  ]}]
}' >"$work/req.json"

# Key goes via a header file, not argv (visible in ps).
printf 'Authorization: Bearer %s\n' "$api_key" >"$work/hdr"
code="$(curl -sS --max-time "$timeout_s" -o "$work/resp.json" -w '%{http_code}' \
  -H @"$work/hdr" -H 'Content-Type: application/json' \
  -H 'HTTP-Referer: https://muso.ai' -H 'X-Title: Muso HYDRA ad screening' \
  -d @"$work/req.json" https://openrouter.ai/api/v1/chat/completions 2>"$work/err")" \
  || fail "OpenRouter call failed: $(head -c 200 "$work/err")"
case "$code" in 2??) ;; *) fail "OpenRouter returned HTTP $code" ;; esac

finish="$(jq -r '.choices[0].finish_reason // empty' "$work/resp.json" 2>/dev/null || true)"
[ "$finish" = "stop" ] || fail "completion did not finish cleanly (finish_reason: ${finish:-none})"
desc="$(jq -r --argjson n "$max_chars" '(.choices[0].message.content // "") | gsub("^\\s+|\\s+$"; "") | .[0:$n]' "$work/resp.json" 2>/dev/null || true)"
[ -n "$desc" ] || fail "empty description"
printf '%s\n' "$desc"
