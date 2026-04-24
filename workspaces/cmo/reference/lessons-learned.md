# Lessons Learned

Sharp, dated corrections Fede has given me. Each rule has the date and root cause so I can judge edge cases later.

## Never Cite Numbers From Memory (2026-04-11)

Fede called me out for saying "~199 contacts" when the actual count was 1,249. I pulled the number from stale memory instead of checking the sheet. Rule: NEVER quote a metric, count, or stat without pulling it live from the source system first. No approximations, no "roughly," no "I think." If you can't pull it right now, say "let me check" and go get the real number. This applies to: contact counts, MRR, pipeline numbers, email stats, campaign metrics — everything. Inaccuracy destroys trust.

## Never Hallucinate Domains (2026-04-11)

Posted a 50-company batch with 8 fake/dead domains I invented (ygaacoustics.com, minimalaudio.com, superbavox.com, etc.). None of them existed. Root cause: I guessed domain patterns instead of finding real URLs from search results. Fix: `muso-outreach-discovery` v2.0 now has mandatory 5-check validation gate (DNS, HTTP, content, industry relevance, acquisition check). Every domain must be verified before it ever hits #company-finder. Zero tolerance for guessed domains.

## #company-finder Format is LOCKED (2026-04-11)

Fede wants exactly: 3-column native Slack table (Domain | Company Name | Industry), tag Jan, exclusion list at bottom. I went through 5 wrong formats (fancy grouped list, code block, TSV, CSV, pipe-aligned code block) before learning Slack has native `table` blocks via Block Kit. Format is now hardcoded in `muso-outreach-discovery` v2.0. Never freestyle the format again.

## Validate Industry Relevance (2026-04-11)

Posted LingoAce (kids language learning), Domestika (general creative courses), Panda Corner (empty Shopify store) as "Music Education" companies. They had nothing to do with music. Fix: mandatory industry relevance check added to discovery skill. Fetch homepage content, confirm music/audio keywords exist.

## Check Acquisitions/Mergers (2026-04-11)

Posted Nura as a standalone company but they were acquired by Masimo/Denon. Community Loudspeakers was acquired by Biamp. Festicket rebranded to DICE years ago. Fix: acquisition check added to validation gate.

## No AI Filler in Outreach Copy (2026-04-10)

Fede taught me to cut all performative/framing lines from outreach. Full rules baked into `muso-outreach-writer` skill v2.0 (Writing Principles section + expanded Banned Phrases). Key test: "would a real person type this?"

## Bulk Destructive Actions — WAIT FOR CONFIRM (2026-04-09)

Fede said "bulk delete blank emails" then immediately reversed. I had already deleted 119 GHL orphans. Rule: for any bulk delete/write, confirm AGAIN right before executing even if Fede just said yes. People change their minds in real-time. A 10-second delay is worth it.

## Lead Sourcing — Athena Is NOT for Leads (2026-04-11, Fede correction)

Athena has NOTHING to do with sourcing or finding new B2B leads. Leads come from discovery tools (web search, Datagma/Snov.io when wired). Athena can help with stats or email personalization, but zero lead sourcing. I got this wrong by parroting old Clio migration notes. Never again.
