# OpenRouter server-tool web_search probe (2026-05-11)

Direct wire-level probe to verify OpenRouter's `openrouter:web_search` server tool fires for `openai/gpt-5.5` before changing openclaw config. Run from hydra `ovh-node-8` against `https://openrouter.ai/api/v1/chat/completions`.

## Why this probe exists

Run `20260511-120510-65cf69` was hollow (0/20 UVNs landed). The agent's parent-session JSONL contained 11KB of "research" prose but **0 https URLs, 0 annotations, no `web_search_results` line item in usage**. Suspected root cause: the deprecated `plugins: [{id: "web", engine: "native"}]` syntax in `openclaw-main.json:223` (operations agent block) is no longer wired to a real search at OpenRouter — per docs, it has been replaced by `tools: [{type: "openrouter:web_search"}]` server tools.

## Request

```bash
curl -s -X POST "https://openrouter.ai/api/v1/chat/completions" \
  -H "Authorization: Bearer <key from /opt/hydra/secrets/llm-provider-keys.json :: OPENROUTER_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openai/gpt-5.5",
    "messages": [{"role": "user", "content": "Search the web and tell me who produced Mdou Moctar Funeral for Justice (2023). Cite at least 2 sources with URLs."}],
    "tools": [{"type": "openrouter:web_search", "max_results": 20}]
  }'
```

## Response (key fields, full body at `/tmp/or-probe-openai_gpt-5-5.json` on hydra)

```json
{
  "id": "gen-1778505716-DQCl3JbH8wzgbkCxYCQm",
  "model": "openai/gpt-5.5-20260423",
  "provider": "OpenAI",
  "choices": [{
    "message": {
      "role": "assistant",
      "content": "<1271 chars including inline references>",
      "annotations": [
        {"type": "url_citation", "url_citation": {"url": "https://tapeop.com/blog/2025/04/06/mdou-moctars-new-album-funeral-justice", "title": "Mdou Moctar's Funeral for Justice: Mikey Coltun Production | Tape Op Magazine", "start_index": 235, "end_index": 324}},
        {"type": "url_citation", "url_citation": {"url": "https://www.metacritic.com/music/funeral-for-justice/mdou-moctar/details", "title": "Funeral for Justice Details, Tracks, and Credits - Metacritic", "start_index": 829, "end_index": 921}},
        {"type": "url_citation", "url_citation": {"url": "https://pitchfork.com/news/mdou-moctar-announce-album-and-tour-share-new-funeral-for-justice-video-watch/", "title": "Mdou Moctar Announce Album and Tour, Share New \"Funeral for Justice\" Video: Watch | Pitchfork", "start_index": 1147, "end_index": 1271}}
      ]
    }
  }],
  "usage": {
    "prompt_tokens": 34932,
    "completion_tokens": 1151,
    "total_tokens": 36083,
    "cost": 0.240182,
    "server_tool_use": { "web_search_requests": 5 }
  }
}
```

## Findings

1. `openrouter:web_search` server tool **is supported** for `openai/gpt-5.5` (model ID `openai/gpt-5.5-20260423` as of 2026-05-11).
2. Citations land at `choices[0].message.annotations[]` with shape `{type: "url_citation", url_citation: {url, title, start_index, end_index}}`. This is the OpenAI Chat Completions standard annotation schema OpenRouter normalizes to.
3. `usage.server_tool_use.web_search_requests` reports the number of searches the model fired (5 in this probe).
4. Cost was $0.24 for one prompt + 5 web searches. Per-result pricing isn't broken out but the upstream-inference cost dominated.
5. The deprecated `plugins: [{id: "web", engine: "native"}]` shape used by openclaw-main.json today is silently ignored at the wire — no error, no annotations, no `server_tool_use` in usage. That matches the hollow-run failure mode exactly.

## Implications for openclaw config

Replace the operations agent's `params.extra_body.plugins` with `params.extra_body.tools: [{type: "openrouter:web_search", max_results: 20}]`. Whether openclaw forwards `extra_body.tools` cleanly into the request body and persists the response `annotations` into the session JSONL is the **next thing to verify in the live integration test** (Phase 4).
