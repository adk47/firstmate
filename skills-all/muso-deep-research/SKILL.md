---
name: muso-deep-research
description: |
  Run an exhaustive, multi-source, CITED research report through a Perplexity
  deep-research model — or a real-time x.com/X search via Grok. Use for big
  "research everything about X" asks — market landscapes, competitor teardowns,
  deep background on a company/person/topic — where a couple of web_search calls
  are not enough and you want one synthesized, sourced report to then verify and
  frame. Use the --x mode for what people are saying on X right now.

  This is a TOOL, not your reasoning brain: Perplexity Sonar models can't drive
  the agent loop (no tool calling), but Sonar Deep Research is the strongest
  search-grounded research engine, so you call it and then sanity-check its claims.

  Use when: "deep research", "research everything about", "full landscape of",
  "competitor teardown", "exhaustive background on", "market map", "what is X
  saying about", "x.com sentiment", "trending on X".
  Triggers: "deep dive", "deep research", "comprehensive research", "landscape",
  "everything about", "on X", "on x.com", "X sentiment", "trending on X".
compatibility: |
  Scout agent (also usable by any main-profile agent with exec). Uses the host
  shell (`exec`) to call scripts/deep-research.sh, which POSTs to OpenRouter using
  the existing OPENROUTER_API_KEY — no new vendor key. Three modes: the default is
  perplexity/sonar-reasoning-pro (chain-of-thought over search, fast + cheap);
  --deepsearch (alias --exhaustive) uses perplexity/sonar-deep-research with an
  openai/o4-mini-deep-research fallback (comprehensive but slow + pricey); and --x
  searches x.com via x-ai/grok-4.3 with OpenRouter's native web+X search (fallback
  x-ai/grok-4.1-fast). Default curl timeout is 600s.
metadata:
  version: "0.1"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# muso-deep-research

The sanctioned path for reasoned, cited research. For a quick fact, use
`web_search` / `web_fetch` directly — reach for this skill only when the ask
genuinely needs broad multi-source synthesis. Three modes:

- **default** (`sonar-reasoning-pro`) — fast + cheap, right for most "deep" asks.
- **`--deepsearch`** (`sonar-deep-research`, fallback `o4-mini-deep-research`) —
  runs many searches for a comprehensive report but is slow + pricey; reserve it
  for true landscape / teardown asks and don't loop it. `--exhaustive` is a synonym.
  (Sonar deep research is the more accurate **and** cheaper of the two models, so
  it leads; the OpenAI model is the cross-vendor fallback.)
- **`--x`** (`x-ai/grok-4.3`, fallback `grok-4.1-fast`) — searches **x.com / X**
  via OpenRouter's native web+X search for real-time posts and sentiment.

## How to call it

```bash
SKILL_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-deep-research"

# Default reasoned report (sonar-reasoning-pro; markdown + a Sources list):
bash "$SKILL_DIR/scripts/deep-research.sh" "Map the B2B landscape of plugin/VST companies marketing to working producers in 2026"

# Deep research pass (sonar-deep-research → o4-mini-deep-research fallback; slow + pricey):
bash "$SKILL_DIR/scripts/deep-research.sh" --deepsearch --reasoning-effort high \
  "Full competitive teardown of Jaxsta vs Muso.AI: positioning, pricing, data coverage"

# Real-time X / x.com search (grok-4.3; what people are posting right now):
bash "$SKILL_DIR/scripts/deep-research.sh" --x "What is X saying about Muso.AI this week?"

# Pipe a long question in on stdin:
echo "Everything notable about <company>: funding, headcount, recent launches, marketing spend signals" \
  | bash "$SKILL_DIR/scripts/deep-research.sh"

# Raw JSON (when you want the structured response, not the rendered report):
bash "$SKILL_DIR/scripts/deep-research.sh" --json "..."
```

## After it returns (NON-NEGOTIABLE)

The report is a strong lead, not gospel. Before you present it:

1. **Spot-check the load-bearing claims** against the Sources it cites — open the
   primary source with `web_fetch` for anything you'll repeat as fact.
2. **Never add a citation the report didn't return.** A URL you recall is not
   evidence; if it's not in the Sources list (or you fetched it yourself), don't cite it.
3. **Frame and attribute.** Present a tight synthesis with sources; flag anything
   you could not verify as unverified rather than dropping or asserting it.

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--deepsearch` | off | deep-research tier: `perplexity/sonar-deep-research`, fallback `openai/o4-mini-deep-research` (comprehensive, slow, pricey). `--exhaustive` is an accepted synonym |
| `--x` | off | search x.com / X via `x-ai/grok-4.3` (OpenRouter native web+X search, fallback `x-ai/grok-4.1-fast`). Mutually exclusive with `--deepsearch` |
| `--reasoning-effort` | `medium` | `low`/`medium`/`high` — depth and cost of the reasoning pass |
| `--model` | `perplexity/sonar-reasoning-pro` | override the primary OpenRouter model |
| `--fallback` | `perplexity/sonar-pro` | used if the primary call fails or returns empty |
| `--max-time` | `600` | curl timeout in seconds |
| `--json` | off | emit the raw OpenRouter JSON instead of a rendered report |

## Failure behavior (fail-loud)

- No `OPENROUTER_API_KEY` (env or hydra-secrets) → exits 3 with a clear message.
- Primary model errors/empties → one automatic retry on the fallback model.
- Both fail → exits 4, prints the last HTTP code and response head. Report the
  failure; do NOT answer from memory in its place.
