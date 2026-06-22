#!/usr/bin/env bats
# Hermetic tests for deep-research.sh — `curl` is PATH-shadowed by a stub so no
# network is touched. The stub reads the requested model from the POST body and
# returns a canned response (or a 500) per the STUB_* env knobs.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../deep-research.sh"
  STUBBIN="$(mktemp -d)"
  RESPFILE="$(mktemp)"
  # The stub copies each request body here so tests can assert on what was sent.
  LAST_BODY="$(mktemp)"
  export LAST_BODY

  # Canned OpenRouter success body: content + a citations array.
  cat > "$RESPFILE" <<'JSON'
{
  "choices": [
    { "message": {
        "content": "Muso.AI competes with Jaxsta on credits coverage.",
        "annotations": [
          { "url_citation": { "url": "https://example.com/b" } }
        ]
    } }
  ],
  "citations": ["https://example.com/a", "https://example.com/a"]
}
JSON

  # Stub curl: parse -o <out> and -d @<body>, choose code by model.
  cat > "$STUBBIN/curl" <<STUB
#!/usr/bin/env bash
out=""; data=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -d) data="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
bodyfile="\${data#@}"
[ -n "\${LAST_BODY:-}" ] && cp "\$bodyfile" "\$LAST_BODY" 2>/dev/null || true
model="\$(jq -r '.model' "\$bodyfile" 2>/dev/null)"
if [ "\${STUB_FAIL_ALL:-0}" = "1" ]; then
  echo '{"error":{"message":"boom"}}' > "\$out"; printf '500'; exit 0
fi
if [ -n "\${STUB_FAIL_MODEL:-}" ] && [ "\$model" = "\$STUB_FAIL_MODEL" ]; then
  echo '{"error":{"message":"boom"}}' > "\$out"; printf '500'; exit 0
fi
cat "$RESPFILE" > "\$out"; printf '200'
STUB
  chmod +x "$STUBBIN/curl"

  PATH="$STUBBIN:$PATH"
  export PATH
  export OPENROUTER_API_KEY="test-key"
  export HYDRA_SECRETS_FILE="/nonexistent/secrets.json"
}

teardown() {
  rm -rf "$STUBBIN" "$RESPFILE" "$LAST_BODY"
}

@test "--help exits 0 and prints usage" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"deep-research.sh"* ]]
  [[ "$output" == *"research question"* ]]
}

@test "no question exits 2" {
  run bash "$SCRIPT" </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"no research question"* ]]
}

@test "missing API key exits 3" {
  unset OPENROUTER_API_KEY
  run bash "$SCRIPT" "what is muso"
  [ "$status" -eq 3 ]
  [[ "$output" == *"OPENROUTER_API_KEY"* ]]
}

@test "happy path returns content, sources, and the default model (sonar-reasoning-pro)" {
  run bash "$SCRIPT" "compare muso and jaxsta"
  [ "$status" -eq 0 ]
  [[ "$output" == *"competes with Jaxsta"* ]]
  [[ "$output" == *"## Sources"* ]]
  [[ "$output" == *"https://example.com/a"* ]]
  [[ "$output" == *"https://example.com/b"* ]]
  [[ "$output" == *"perplexity/sonar-reasoning-pro"* ]]
}

@test "--exhaustive uses sonar-deep-research" {
  run bash "$SCRIPT" --exhaustive "x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"perplexity/sonar-deep-research"* ]]
}

@test "citations are de-duplicated" {
  run bash "$SCRIPT" "x"
  [ "$status" -eq 0 ]
  # example.com/a appears twice in .citations but must render once.
  count="$(printf '%s\n' "$output" | grep -c 'https://example.com/a')"
  [ "$count" -eq 1 ]
}

@test "primary failure falls back to the fallback model (sonar-pro)" {
  STUB_FAIL_MODEL="perplexity/sonar-reasoning-pro" run bash "$SCRIPT" "x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"competes with Jaxsta"* ]]
  [[ "$output" == *"perplexity/sonar-pro"* ]]
}

@test "both models failing exits 4 (fail-loud, no fabricated answer)" {
  STUB_FAIL_ALL=1 run bash "$SCRIPT" "x"
  [ "$status" -eq 4 ]
  [[ "$output" == *"failed on both"* ]]
}

@test "--json emits raw response" {
  run bash "$SCRIPT" --json "x"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"choices"'* ]]
  [[ "$output" != *"## Sources"* ]]
}

@test "--deepsearch uses sonar-deep-research (alias of --exhaustive)" {
  run bash "$SCRIPT" --deepsearch "x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"perplexity/sonar-deep-research"* ]]
}

@test "--deepsearch primary failure falls back to o4-mini-deep-research" {
  STUB_FAIL_MODEL="perplexity/sonar-deep-research" run bash "$SCRIPT" --deepsearch "x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"competes with Jaxsta"* ]]
  [[ "$output" == *"openai/o4-mini-deep-research"* ]]
}

@test "--x uses grok-4.3 and attaches the native X web_search tool scoped to x.com" {
  run bash "$SCRIPT" --x "what is X saying about muso"
  [ "$status" -eq 0 ]
  [[ "$output" == *"x-ai/grok-4.3"* ]]
  # the request body must carry OpenRouter's native web-search tool, scoped to x.com
  run cat "$LAST_BODY"
  [[ "$output" == *"openrouter:web_search"* ]]
  [[ "$output" == *"native"* ]]
  [[ "$output" == *"x.com"* ]]
}

@test "--x primary failure falls back to grok-4.1-fast" {
  STUB_FAIL_MODEL="x-ai/grok-4.3" run bash "$SCRIPT" --x "x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"x-ai/grok-4.1-fast"* ]]
}

@test "--x combined with --deepsearch exits 2 (mutually exclusive)" {
  run bash "$SCRIPT" --x --deepsearch "x"
  [ "$status" -eq 2 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "default and non-X modes send no web_search tool" {
  run bash "$SCRIPT" "plain question"
  [ "$status" -eq 0 ]
  run cat "$LAST_BODY"
  [[ "$output" != *"web_search"* ]]
}
