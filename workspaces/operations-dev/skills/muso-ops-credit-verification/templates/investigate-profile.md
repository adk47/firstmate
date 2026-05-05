# Investigate one profile — DEFERRED (subagent infrastructure not yet wired)

> ## ⚠️ This template is NOT used today. See SKILL.md Step B3 for the live inline investigation path.
>
> The subagent investigation pool was an attempted design (May 2026) that depended on subagents having a browser-capable node attached. Today's openclaw subagent sessions inherit the `browser` tool but **no browser node is registered to their session key** — every `browser.open()` call from a subagent times out with "No connected browser-capable nodes."
>
> A previous iteration of this template tried to substitute `web_fetch` against Tier-1 hosts (Spotify / Apple / MusicBrainz / Discogs / AllMusic). That violates the **two-layer Tier-1 web_fetch ban** (plugin hook `block-web-fetch-tier1` + bash gate `muso-admin-api.sh`), which exists because Tier-1 sources are JS-rendered SPAs whose credits are NOT in the HTML shell. See `feedback_browser_only_for_tier1.md` (CRITICAL).
>
> **Until subagent browser access is wired** (separate follow-up issue), all per-profile investigation runs **inline in the parent** agent — see SKILL.md Step B3. The parent has working browser, plus mechanical gates (`runlog.sh` exit 7 `acted_without_investigation`, `batch-verify-profile.sh` exit 5 `missing_profile_browse`) prevent any heuristic shortcut.
>
> **What needs to happen for this template to come back online:**
>
> 1. openclaw config / spawn config change so subagent sessions register with the browser server, OR
> 2. A "browser proxy" RPC subagents can call which routes through the parent's browser binding, OR
> 3. Headless playwright in subagent's bash (different parallelism mechanism)
>
> Then this template gets rewritten to use `browser` (NEVER `web_fetch`) for Tier-1 loads, and SKILL.md B3 switches back to the dispatch-investigations.sh / agent() / collect-investigations.sh flow.
